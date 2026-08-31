import AppKit
import Combine
import SwiftUI

struct ConversationMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    /// What the window shows. User timestamps stay out of the interface.
    var content: String
    /// What goes back to the model. User turns retain their original timestamp.
    var payloadContent: String
    let createdAt: Date
    var metrics: ChatClient.GenerationMetrics?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        payloadContent: String? = nil,
        createdAt: Date = Date(),
        metrics: ChatClient.GenerationMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.payloadContent = payloadContent ?? content
        self.createdAt = createdAt
        self.metrics = metrics
    }
}

struct Conversation: Identifiable, Equatable {
    let id: UUID
    var title: String
    var messages: [ConversationMessage]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New conversation",
        messages: [ConversationMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }

    static func title(from prompt: String) -> String {
        let singleLine = prompt
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard singleLine.count > 42 else {
            return singleLine.isEmpty ? "New conversation" : singleLine
        }
        return String(singleLine.prefix(41)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Session history for the chat window. Intentionally memory-only: closing the
/// app remains enough to erase every conversation until persistence receives a
/// visible retention design of its own.
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: Conversation.ID?
    @Published private(set) var activeConversationID: Conversation.ID?

    private var task: Task<Void, Never>?
    private var activeAssistantID: UUID?

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedID }
    }

    var isGenerating: Bool { activeConversationID != nil }

    @discardableResult
    func newConversation(select: Bool = true) -> Conversation.ID {
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        if select { selectedID = conversation.id }
        return conversation.id
    }

    /// Moves a completed Ask bar turn without asking the model to repeat work.
    @discardableResult
    func continueFromAskBar(
        question: String,
        answer: String,
        assistantID: UUID? = nil,
        metrics: ChatClient.GenerationMetrics? = nil
    ) -> Conversation.ID {
        let createdAt = Date()
        let user = ChatClient.Message.user(question, at: createdAt)
        let conversation = Conversation(
            title: Conversation.title(from: question),
            messages: [
                ConversationMessage(
                    role: .user, content: question, payloadContent: user.content,
                    createdAt: createdAt),
                ConversationMessage(
                    id: assistantID ?? UUID(), role: .assistant, content: answer,
                    createdAt: createdAt, metrics: metrics),
            ])
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        return conversation.id
    }

    func delete(_ id: Conversation.ID) {
        if activeConversationID == id { cancel() }
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.first?.id }
    }

    func send(_ rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating else { return }

        let id = selectedID ?? newConversation()
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        let createdAt = Date()
        let user = ChatClient.Message.user(prompt, at: createdAt)
        conversations[index].messages.append(ConversationMessage(
            role: .user, content: prompt, payloadContent: user.content, createdAt: createdAt))
        if conversations[index].messages.count == 1 {
            conversations[index].title = Conversation.title(from: prompt)
        }

        startAssistantResponse(in: id)
    }

    /// Editing a past question changes the branch from that point onward. Keep
    /// the message's original timestamp, discard answers that depended on the
    /// old wording, then generate the replacement response.
    @discardableResult
    func editUserMessage(_ messageID: UUID, content rawContent: String) -> Bool {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isGenerating,
              let conversationIndex = selectedConversationIndex,
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
                  $0.id == messageID && $0.role == .user
              }) else { return false }

        let createdAt = conversations[conversationIndex].messages[messageIndex].createdAt
        conversations[conversationIndex].messages[messageIndex].content = content
        conversations[conversationIndex].messages[messageIndex].payloadContent =
            ChatClient.Message.user(content, at: createdAt).content
        conversations[conversationIndex].messages.removeSubrange(
            (messageIndex + 1)..<conversations[conversationIndex].messages.endIndex)
        refreshTitle(at: conversationIndex)
        startAssistantResponse(in: conversations[conversationIndex].id)
        return true
    }

    /// A question and every later turn form one causal branch. Removing only
    /// the sentence while retaining answers to it would manufacture a false
    /// transcript, so deletion deliberately trims the branch at that point.
    func deleteMessageAndFollowing(_ messageID: UUID) {
        guard !isGenerating,
              let conversationIndex = selectedConversationIndex,
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
                  $0.id == messageID
              }) else { return }
        conversations[conversationIndex].messages.removeSubrange(
            messageIndex..<conversations[conversationIndex].messages.endIndex)
        refreshTitle(at: conversationIndex)
    }

    func regenerateAssistant(_ messageID: UUID) {
        guard !isGenerating,
              let conversationIndex = selectedConversationIndex,
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
                  $0.id == messageID && $0.role == .assistant
              }), messageIndex > 0,
              conversations[conversationIndex].messages[messageIndex - 1].role == .user else {
            return
        }
        conversations[conversationIndex].messages.removeSubrange(
            messageIndex..<conversations[conversationIndex].messages.endIndex)
        startAssistantResponse(in: conversations[conversationIndex].id)
    }

    /// User-turn Insights belongs to the answer it produced, mirroring
    /// Osaurus's request/response model.
    func responseMessageID(for userMessageID: UUID) -> UUID? {
        guard let conversation = selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == userMessageID }),
              conversation.messages.indices.contains(index + 1),
              conversation.messages[index + 1].role == .assistant else { return nil }
        return conversation.messages[index + 1].id
    }

    private var selectedConversationIndex: Int? {
        conversations.firstIndex { $0.id == selectedID }
    }

    private func refreshTitle(at index: Int) {
        let firstQuestion = conversations[index].messages.first(where: { $0.role == .user })?.content
        conversations[index].title = firstQuestion.map(Conversation.title(from:)) ?? "New conversation"
    }

    private func startAssistantResponse(in id: Conversation.ID) {
        guard !isGenerating,
              let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].messages.last?.role == .user else { return }

        let assistantID = UUID()
        conversations[index].messages.append(ConversationMessage(
            id: assistantID, role: .assistant, content: ""))
        activeConversationID = id
        activeAssistantID = assistantID

        var payload: [ChatClient.Message] = []
        if let systemPrompt = Config.systemPrompt { payload.append(.system(systemPrompt)) }
        let recentMessages = Self.recentContext(
            from: conversations[index].messages.filter { $0.id != assistantID })
        payload.append(contentsOf: recentMessages.map { message in
            return ChatClient.Message(
                role: message.role.rawValue,
                content: message.payloadContent)
        })

        task = ChatClient.send(
            messages: payload,
            messageID: assistantID,
            onDelta: { [weak self] delta in
                self?.append(delta, to: assistantID, in: id)
            },
            onCompletion: { [weak self] result in
                self?.finish(result, assistantID: assistantID, conversationID: id)
            })
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let conversationID = activeConversationID,
           let assistantID = activeAssistantID,
           let conversation = conversations.firstIndex(where: { $0.id == conversationID }),
           let message = conversations[conversation].messages.firstIndex(where: {
               $0.id == assistantID
           }) {
            let prefix = conversations[conversation].messages[message].content.isEmpty
                ? "" : "\n\n"
            let stopped = "\(prefix)*Stopped.*"
            conversations[conversation].messages[message].content += stopped
            conversations[conversation].messages[message].payloadContent += stopped
        }
        activeAssistantID = nil
        activeConversationID = nil
    }

    private func append(_ delta: String, to messageID: UUID, in conversationID: UUID) {
        guard let conversation = conversations.firstIndex(where: { $0.id == conversationID }),
              let message = conversations[conversation].messages.firstIndex(where: {
                  $0.id == messageID
              }) else { return }
        conversations[conversation].messages[message].content += delta
        conversations[conversation].messages[message].payloadContent += delta
    }

    private func finish(
        _ result: Result<ChatClient.GenerationMetrics, Error>,
        assistantID: UUID,
        conversationID: UUID
    ) {
        defer {
            task = nil
            activeAssistantID = nil
            activeConversationID = nil
        }
        guard let conversation = conversations.firstIndex(where: { $0.id == conversationID }),
              let message = conversations[conversation].messages.firstIndex(where: {
                  $0.id == assistantID
              }) else { return }
        if case .success(let metrics) = result {
            conversations[conversation].messages[message].metrics = metrics
            return
        }
        guard case .failure(let error) = result else { return }
        let prefix = conversations[conversation].messages[message].content.isEmpty ? "" : "\n\n"
        conversations[conversation].messages[message].content +=
            "\(prefix)*Rosy Bit stopped: \(error.localizedDescription)*"
        conversations[conversation].messages[message].payloadContent =
            conversations[conversation].messages[message].content
    }

    /// The sidebar keeps the whole visible session, but Rosy's 2,048-token
    /// context cannot. Keep the newest complete messages within a conservative
    /// character budget, leaving room for the system prompt, tool schema, and
    /// answer. Old turns age out of model context rather than making every new
    /// turn slower until the server refuses the request.
    static func recentContext(from messages: [ConversationMessage]) -> [ConversationMessage] {
        guard !messages.isEmpty else { return [] }
        let promptCost = Config.systemPrompt?.count ?? 0
        let budget = max(800, (Config.contextSize - 700) * 3 - promptCost)
        var remaining = budget
        var result: [ConversationMessage] = []

        for message in messages.reversed() {
            let cost = message.payloadContent.count + 16
            if result.isEmpty {
                // The newest user turn is never silently discarded. If it is
                // enormous, llama-server remains the final authority on fit.
                result.append(message)
                remaining = max(0, remaining - cost)
            } else if cost <= remaining {
                result.append(message)
                remaining -= cost
            } else {
                break
            }
        }
        var chronological = Array(result.reversed())
        // If the budget split an old user/assistant pair, do not begin with an
        // answer whose question is missing.
        while chronological.first?.role == .assistant {
            chronological.removeFirst()
        }
        return chronological
    }
}

final class ChatWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ChatWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Chat with Rosy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: ChatWindowView())
        // Attaching a hosting controller can make AppKit adopt SwiftUI's
        // minimum size and discard the 900×650 content rect above. Restore the
        // intended opening size after attachment; the user remains free to
        // resize it down to Rosy's compact minimum afterwards.
        window.setContentSize(NSSize(width: 900, height: 650))
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 440)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        if ConversationStore.shared.conversations.isEmpty {
            ConversationStore.shared.newConversation()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func continueFromAskBar(
        question: String,
        answer: String,
        assistantID: UUID?,
        metrics: ChatClient.GenerationMetrics?
    ) {
        ConversationStore.shared.continueFromAskBar(
            question: question,
            answer: answer,
            assistantID: assistantID,
            metrics: metrics)
        show()
    }
}

struct ChatWindowView: View {
    @ObservedObject private var store = ConversationStore.shared
    @State private var sidebarVisible = true
    @State private var prompt = ""
    @State private var hoveredMessageID: UUID?
    @State private var moreMessageID: UUID?
    @State private var hoveredInspectMessageID: UUID?
    @State private var editingMessageID: UUID?
    @State private var editDraft = ""
    @State private var deleteCandidateID: UUID?
    @State private var insightsUnavailable = false
    @FocusState private var composerFocused: Bool

    private let rosy = Color(red: 0.92, green: 0.43, blue: 0.58)

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(width: 230)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            conversation
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 600, minHeight: 440)
        .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        .confirmationDialog(
            "Delete this message and everything after it?",
            isPresented: Binding(
                get: { deleteCandidateID != nil },
                set: { if !$0 { deleteCandidateID = nil } })) {
            Button("Delete branch", role: .destructive) {
                if let id = deleteCandidateID { store.deleteMessageAndFollowing(id) }
                deleteCandidateID = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidateID = nil }
        } message: {
            Text("Later replies depend on this message, so they will be removed too.")
        }
        .alert("Insights unavailable", isPresented: $insightsUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That request has aged out of the memory-only Insights buffer.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    store.newConversation()
                    composerFocused = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                Button { sidebarVisible = false } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide conversations")
            }
            .padding(.horizontal, 14)
            .frame(height: 56)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    sessionGroup("Today", conversations: todaysConversations)
                    sessionGroup("Earlier", conversations: earlierConversations)
                }
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

            Text("Memory only · clears when Rosy Bit quits")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.94))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
        }
    }

    private var todaysConversations: [Conversation] {
        store.conversations.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    private var earlierConversations: [Conversation] {
        store.conversations.filter { !Calendar.current.isDateInToday($0.createdAt) }
    }

    @ViewBuilder
    private func sessionGroup(_ title: String, conversations: [Conversation]) -> some View {
        if !conversations.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)

                ForEach(conversations) { conversation in
                    Button {
                        store.selectedID = conversation.id
                    } label: {
                        Text(conversation.title)
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(store.selectedID == conversation.id
                                  ? rosy.opacity(0.14)
                                  : Color.clear))
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            store.delete(conversation.id)
                        }
                    }
                }
            }
        }
    }

    private var conversation: some View {
        ZStack(alignment: .topLeading) {
            transcript
                .padding(.top, 50)
                .padding(.bottom, 104)

            if !sidebarVisible {
                HStack(spacing: 16) {
                    Button { sidebarVisible = true } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Show conversations")

                    Button {
                        store.newConversation()
                        composerFocused = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("New conversation")
                }
                .font(.system(size: 16, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // The collapsed controls sit in the title-bar safe area, while
                // transcript content does not. A small optical inset aligns the
                // first glyph with assistant prose and its Copy control; the old
                // 84-point inset accidentally reserved that space twice.
                .padding(.leading, 38)
                .padding(.top, 15)
            }

            composer
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = store.selectedConversation,
           !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(conversation.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                    }
                    // The former 720-point cap looked right at the opening
                    // size but became a narrow island in a large window. A
                    // higher ceiling still protects readable line lengths
                    // while allowing the feed to grow responsively.
                    .frame(maxWidth: sidebarVisible ? 960 : .infinity)
                    .padding(.horizontal, sidebarVisible ? 26 : 40)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: conversation.messages.last?.content) { _ in
                    if let id = conversation.messages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        } else {
            VStack(spacing: 9) {
                Spacer()
                Image(systemName: "camera.macro")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(rosy.opacity(0.75))
                Text("What shall we make of it?")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("A small, private conversation on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func messageView(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 0) }
            VStack(
                alignment: message.role == .user ? .trailing : .leading,
                spacing: message.role == .user ? 5 : 8
            ) {
                if message.content.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Rosy is thinking…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    if message.role == .user {
                        if editingMessageID == message.id {
                            editView(for: message)
                        } else {
                            userBubble(message)
                        }
                    } else {
                        MarkdownAnswer(source: message.content)
                    }
                    if message.role == .user, editingMessageID != message.id {
                        // Keep this compact footer in the layout even while it
                        // is invisible. Hover therefore changes opacity only;
                        // later messages never jump down to make room for it.
                        userActions(for: message)
                            .opacity(hoveredMessageID == message.id ? 1 : 0)
                            .allowsHitTesting(hoveredMessageID == message.id)
                            .accessibilityHidden(hoveredMessageID != message.id)
                    } else if message.role == .assistant {
                        assistantFooter(for: message)
                    }
                }
            }
            .frame(
                maxWidth: message.role == .user ? 440 : 640,
                alignment: message.role == .user ? .trailing : .leading)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard message.role == .user else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    hoveredMessageID = hovering ? message.id :
                        (hoveredMessageID == message.id ? nil : hoveredMessageID)
                }
            }
            if message.role == .assistant { Spacer(minLength: 0) }
        }
    }

    private func userBubble(_ message: ConversationMessage) -> some View {
        Text(AskBarMarkdown.render(message.content))
            .font(.callout)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.secondary.opacity(0.16)))
    }

    private func editView(for message: ConversationMessage) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $editDraft)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(width: 416)
                .frame(minHeight: 74, maxHeight: 150)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.13)))
            HStack(spacing: 8) {
                Button("Cancel") {
                    editingMessageID = nil
                    editDraft = ""
                }
                Button("Save & Regenerate") {
                    if store.editUserMessage(message.id, content: editDraft) {
                        editingMessageID = nil
                        editDraft = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(rosy)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func userActions(for message: ConversationMessage) -> some View {
        HStack(spacing: 3) {
            actionButton("doc.on.doc", help: "Copy message") { copy(message.content) }
            actionButton("pencil", help: "Edit message", enabled: !store.isGenerating) {
                editDraft = message.content
                editingMessageID = message.id
            }
            actionButton("trash", help: "Delete message", enabled: !store.isGenerating) {
                deleteCandidateID = message.id
            }
            moreButton(for: message, insightMessageID: store.responseMessageID(for: message.id))
        }
    }

    private func assistantFooter(for message: ConversationMessage) -> some View {
        HStack(spacing: 3) {
            actionButton("doc.on.doc", help: "Copy answer") { copy(message.content) }
            actionButton(
                "arrow.counterclockwise",
                help: "Regenerate answer",
                enabled: !store.isGenerating
            ) {
                store.regenerateAssistant(message.id)
            }
            moreButton(for: message, insightMessageID: message.id)
            Text(metricSummary(message.metrics))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
        }
    }

    private func actionButton(
        _ systemName: String,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9.5, weight: .medium))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .help(help)
    }

    private func moreButton(
        for message: ConversationMessage,
        insightMessageID: UUID?
    ) -> some View {
        Button {
            moreMessageID = message.id
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.07)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("More")
        .popover(
            isPresented: Binding(
                get: { moreMessageID == message.id },
                set: { if !$0, moreMessageID == message.id { moreMessageID = nil } }),
            arrowEdge: .bottom
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Inspect response") {
                    moreMessageID = nil
                    guard let insightMessageID,
                          InsightsWindowController.shared.show(recordFor: insightMessageID) else {
                        insightsUnavailable = true
                        return
                    }
                }
                .buttonStyle(.plain)
                .disabled(insightMessageID == nil)
                .foregroundStyle(
                    hoveredInspectMessageID == message.id && insightMessageID != nil
                        ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            hoveredInspectMessageID == message.id && insightMessageID != nil
                                ? rosy : Color.clear))
                .contentShape(Rectangle())
                .onHover { hovering in
                    hoveredInspectMessageID = hovering ? message.id :
                        (hoveredInspectMessageID == message.id ? nil : hoveredInspectMessageID)
                }
            }
            .padding(13)
            .frame(width: 190, alignment: .leading)
        }
    }

    private func metricSummary(_ metrics: ChatClient.GenerationMetrics?) -> String {
        let ttft: String
        if let seconds = metrics?.timeToFirstToken {
            ttft = seconds < 0.01
                ? String(format: "%.0f ms", seconds * 1_000)
                : String(format: "%.2f s", seconds)
        } else {
            ttft = "—"
        }
        let speed = metrics?.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "— tok/s"
        let tokens = metrics?.totalTokens.map { "\($0) tokens" } ?? "— tokens"
        return "TTFT \(ttft) · \(speed) · \(tokens)"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Send a message", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit(submit)

            HStack {
                Image(systemName: "camera.macro")
                    .font(.caption)
                    .foregroundStyle(rosy.opacity(0.75))
                Text("Rosy Bit")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()

                if store.isGenerating {
                    Button(action: store.cancel) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(rosy))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    let canSend = !prompt.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(
                                canSend ? rosy : Color.secondary.opacity(0.16)))
                            .foregroundStyle(canSend ? Color.white : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }
            }
        }
        .padding(.leading, 17)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: sidebarVisible ? 720 : 960, minHeight: 76)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.secondary.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(composerFocused ? rosy.opacity(0.40) : Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        let message = prompt
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prompt = ""
        store.send(message)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
