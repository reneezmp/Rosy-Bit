import AppKit
import Combine
import SwiftUI

/// State behind the ask bar. One question, one answer, no history — history is
/// the chat window's job.
final class AskBarModel: ObservableObject {

    @Published var prompt = ""
    @Published private(set) var answer = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusRequest = 0

    private var task: Task<Void, Never>?

    var hasOutput: Bool { !answer.isEmpty || isStreaming || errorMessage != nil }

    func requestPromptFocus() {
        focusRequest &+= 1
    }

    func submit() {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }

        answer = ""
        errorMessage = nil

        // Say why nothing will happen, rather than letting a refused connection
        // read as the model declining to answer.
        let server = ServerController.shared
        guard server.state == .running || server.state == .starting else {
            errorMessage = server.state.menuTitle
            return
        }

        isStreaming = true

        var messages: [ChatClient.Message] = []
        if let systemPrompt = Config.systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(question))

        task = ChatClient.send(
            messages: messages,
            onDelta: { [weak self] delta in
                self?.answer += delta
            },
            onCompletion: { [weak self] result in
                guard let self else { return }
                self.isStreaming = false
                if case .failure(let error) = result {
                    self.errorMessage = error.localizedDescription
                }
            })
    }

    /// Stops the generation as well as clearing the view. On this machine an
    /// abandoned answer would otherwise keep both cores busy for minutes.
    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    func reset() {
        cancel()
        prompt = ""
        answer = ""
        errorMessage = nil
    }

    func copyAnswer() {
        guard !answer.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(answer, forType: .string)
    }
}

/// Borderless panel that can still take keystrokes — `canBecomeKey` is false by
/// default for a borderless window, which would make the field untypeable.
private final class AskBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Converts both complete and still-streaming Markdown into native attributed
/// text. The partial-input policy matters for fenced code, emphasis, and links
/// whose closing delimiter may arrive several tokens later.
enum AskBarMarkdown {
    struct Block: Identifiable {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case unorderedListItem
            case orderedListItem(Int)
            case codeBlock
            case blockQuote
            case thematicBreak
        }

        let id: Int
        let identity: Int
        let kind: Kind
        let indentation: Int
        var content: AttributedString
    }

    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }

    /// Turns Foundation's block presentation intents into concrete SwiftUI
    /// blocks. `Text(AttributedString)` handles inline intents but deliberately
    /// ignores headers, lists, quotes, and code-block presentation.
    static func blocks(_ source: String) -> [Block] {
        let rendered = render(source)
        var result: [Block] = []
        var fallbackIdentity = -1

        for run in rendered.runs {
            let components = run.presentationIntent?.components ?? []
            let description = describe(components: components, fallbackIdentity: fallbackIdentity)
            if components.isEmpty { fallbackIdentity -= 1 }
            let segment = AttributedString(rendered[run.range])

            if let last = result.indices.last,
               result[last].identity == description.identity,
               result[last].kind == description.kind {
                result[last].content.append(segment)
            } else {
                result.append(Block(
                    id: result.count,
                    identity: description.identity,
                    kind: description.kind,
                    indentation: description.indentation,
                    content: segment))
            }
        }

        if result.isEmpty, !source.isEmpty {
            result.append(Block(
                id: 0, identity: fallbackIdentity, kind: .paragraph,
                indentation: 0, content: AttributedString(source)))
        }
        return result
    }

    private static func describe(
        components: [PresentationIntent.IntentType],
        fallbackIdentity: Int
    ) -> (identity: Int, kind: Block.Kind, indentation: Int) {
        let indentation = max(0, components.count - 1)

        if let component = components.first(where: {
            if case .header = $0.kind { return true }
            return false
        }), case .header(let level) = component.kind {
            return (component.identity, .heading(level), indentation)
        }

        if let component = components.first(where: {
            if case .codeBlock = $0.kind { return true }
            return false
        }) {
            return (component.identity, .codeBlock, indentation)
        }

        if let item = components.first(where: {
            if case .listItem = $0.kind { return true }
            return false
        }), case .listItem(let ordinal) = item.kind {
            let ordered = components.contains {
                if case .orderedList = $0.kind { return true }
                return false
            }
            return (item.identity, ordered ? .orderedListItem(ordinal) : .unorderedListItem,
                    indentation)
        }

        if components.contains(where: {
            if case .blockQuote = $0.kind { return true }
            return false
        }) {
            let paragraph = components.first ?? components[0]
            return (paragraph.identity, .blockQuote, indentation)
        }

        if let component = components.first(where: {
            if case .thematicBreak = $0.kind { return true }
            return false
        }) {
            return (component.identity, .thematicBreak, indentation)
        }

        if let paragraph = components.first {
            return (paragraph.identity, .paragraph, indentation)
        }
        return (fallbackIdentity, .paragraph, 0)
    }
}

/// Lets the panel be dragged.
///
/// `isMovableByWindowBackground` alone does nothing here: the window's
/// background is covered by an `NSHostingView`, which handles the mouse itself,
/// so the drag never reaches the window. Calling `performDrag` from a view that
/// does see the event is the way through.
///
/// Placed behind the text field row only. As a `.background` it sits under the
/// field, so typing still wins where the field is and the surrounding strip
/// becomes the grab handle — the answer area is left alone so text stays
/// selectable.
struct WindowDragHandle: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

final class AskBarWindowController: NSWindowController, NSWindowDelegate {

    static let shared = AskBarWindowController()

    private let model = AskBarModel()
    private var hotKey: GlobalHotKey?
    private var hostingController: NSHostingController<AskBarView>?
    private var cancellables = Set<AnyCancellable>()

    /// Belt and braces against the recursion described above ever returning.
    private var isResizing = false

    /// Whether the panel has been placed once. After that its position is the
    /// user's to decide.
    private var hasBeenPositioned = false

    static let cardWidth: CGFloat = 560

    private static let collapsedHeight: CGFloat = 56
    private static let maximumHeight: CGFloat = 460
    private static let textInset: CGFloat = 32
    static let answerMaximumHeight: CGFloat = 320

    private init() {
        let panel = AskBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: Self.cardWidth, height: Self.collapsedHeight)
        panel.maxSize = NSSize(width: Self.cardWidth, height: Self.maximumHeight)
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: panel)
        panel.delegate = self

        let controller = NSHostingController(
            rootView: AskBarView(model: model, onDismiss: { [weak self] in self?.hide() }))
        // This controller alone owns the window height. If NSHostingController
        // also publishes its ideal size, a long Text can make AppKit grow the
        // borderless panel beyond our scroll viewport.
        controller.sizingOptions = []
        panel.contentViewController = controller
        hostingController = controller

        // Only output changes affect height. Debouncing coalesces streaming
        // tokens and also moves measurement past @Published's willSet timing.
        Publishers.CombineLatest3(model.$answer, model.$errorMessage, model.$isStreaming)
            .dropFirst()
            .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.resizeToFitContent() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Grows the panel to fit what the card is showing.
    ///
    /// The height is computed here rather than measured from the view, because
    /// both ways of asking SwiftUI are traps in a borderless window: a laid-out
    /// geometry proxy reports the size the content was squeezed into, and
    /// asking for the ideal size feeds a loop with whatever resizes the window.
    /// Text measurement through AppKit is deterministic and answers before the
    /// layout exists, which is exactly what is needed to decide how much room
    /// to give it.
    private func resizeToFitContent() {
        guard let window, !isResizing else { return }

        let target = min(max(desiredHeight(), Self.collapsedHeight), Self.maximumHeight)
        var frame = window.frame
        guard abs(frame.height - target) > 0.5 else { return }

        isResizing = true
        defer { isResizing = false }

        // Anchored at the top, so the field stays put and the answer opens
        // downwards rather than shoving the bar up the screen.
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target
        window.setFrame(frame, display: true, animate: false)
    }

    private func desiredHeight() -> CGFloat {
        var height = Self.collapsedHeight
        guard model.hasOutput else { return height }
        height += 1  // divider

        if let error = model.errorMessage {
            return height + textHeight(error) + Self.textInset
        }
        if !model.answer.isEmpty {
            return height
                + min(textHeight(model.answer) + Self.textInset, Self.answerMaximumHeight)
                + 34  // copy row
        }
        return height + 46  // "Thinking…"
    }

    /// Laid out at the same width and text style the card uses, so the estimate
    /// tracks what is actually drawn.
    private func textHeight(_ text: String) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .callout)])
        // Both operands typed, or the literals leave the type checker choosing
        // between CGFloat and Double.
        let available: CGFloat = Self.cardWidth - Self.textInset
        let bounds = attributed.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// True once a shortcut is actually held. `RegisterEventHotKey` fails when
    /// the combination belongs to something else, and that failure is otherwise
    /// invisible — the shortcut simply does nothing.
    private(set) var hotKeyRegistered = false

    func registerHotKey() {
        hotKey = nil
        hotKeyRegistered = false
        guard Config.askBarEnabled else { return }

        hotKey = GlobalHotKey(
            keyCode: UInt32(Config.hotKeyCode),
            modifiers: GlobalHotKey.Modifiers(rawValue: UInt32(Config.hotKeyModifiers))
        ) { [weak self] in
            self?.toggle()
        }
        hotKeyRegistered = hotKey != nil
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        resizeToFitContent()
        positionNearTop()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.requestPromptFocus()
    }

    func hide() {
        model.reset()
        window?.orderOut(nil)
    }

    /// Roughly where Spotlight puts itself: centred, a little above the middle.
    ///
    /// Only until it is moved. Somewhere the user dragged it to is a choice, and
    /// re-centring on every open would quietly undo it — so this places the
    /// panel the first time, and afterwards only when it would otherwise open
    /// off-screen, which happens when a display is disconnected.
    private func positionNearTop() {
        guard let window,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let visible = screen.visibleFrame
        if hasBeenPositioned, visible.intersects(window.frame) { return }

        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.22))
        hasBeenPositioned = true
    }

    /// An untouched prompt behaves like Spotlight and disappears on click-away.
    /// Once work has started, the result belongs to the user: keep it visible
    /// until an explicit Escape or hotkey dismissal.
    func windowDidResignKey(_ notification: Notification) {
        if !model.hasOutput { hide() }
    }
}

struct AskBarView: View {

    @ObservedObject var model: AskBarModel
    let onDismiss: () -> Void

    @FocusState private var promptFocused: Bool
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if model.hasOutput {
                Divider()
                output
            }
        }
        // No `fixedSize` here: it proposes a nil height, and the ScrollView
        // below has no ideal height to answer with, which is a well-worn route
        // to NaN in the layout maths. The window is sized by the controller, and
        // the card simply fills it from the top.
        .frame(width: AskBarWindowController.cardWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10)))
        .onAppear { promptFocused = true }
        .onChange(of: model.focusRequest) { _ in promptFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.macro")
                .foregroundStyle(.secondary)

            TextField("Ask Rosy Bit…", text: $model.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($promptFocused)
                .onSubmit {
                    model.submit()
                    // NSTextField selects its contents after Return. Releasing
                    // focus avoids that surprising overwrite-ready state.
                    promptFocused = false
                }

            if model.isStreaming {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop generating")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(WindowDragHandle())
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            if !model.answer.isEmpty {
                ScrollView {
                    MarkdownAnswer(source: model.answer)
                        .padding(16)
                }
                .frame(maxHeight: AskBarWindowController.answerMaximumHeight)
                .scrollIndicators(.visible)

                answerActions
            } else if model.isStreaming {
                // At a few tokens a second the first word takes a moment;
                // without this the bar looks like it ignored the return key.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(16)
            }
        }
    }

    private var answerActions: some View {
        HStack {
            Spacer()
            Button {
                model.copyAnswer()
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy the answer")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

private struct MarkdownAnswer: View {
    let source: String

    private var blocks: [AskBarMarkdown.Block] { AskBarMarkdown.blocks(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AskBarMarkdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.content)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level):
            Text(block.content)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .unorderedListItem:
            listRow(marker: "•", block: block)

        case .orderedListItem(let ordinal):
            listRow(marker: "\(ordinal).", block: block)

        case .codeBlock:
            ScrollView(.horizontal) {
                Text(block.content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

        case .blockQuote:
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                Text(block.content)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .thematicBreak:
            Divider()
        }
    }

    private func listRow(marker: String, block: AskBarMarkdown.Block) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 14, alignment: .trailing)
            Text(block.content)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(max(0, block.indentation - 2)) * 14)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}
