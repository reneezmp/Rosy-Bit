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

    private var task: Task<Void, Never>?

    var hasOutput: Bool { !answer.isEmpty || isStreaming || errorMessage != nil }

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

final class AskBarWindowController: NSWindowController, NSWindowDelegate {

    static let shared = AskBarWindowController()

    private let model = AskBarModel()
    private var hotKey: GlobalHotKey?
    private var hostingController: NSHostingController<AskBarView>?
    private var cancellables = Set<AnyCancellable>()

    private static let collapsedHeight: CGFloat = 56
    private static let maximumHeight: CGFloat = 460

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
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: panel)
        panel.delegate = self

        let controller = NSHostingController(
            rootView: AskBarView(model: model, onDismiss: { [weak self] in self?.hide() }))
        // Keeps preferredContentSize tracking what the SwiftUI content actually
        // wants, which is the number the window has to follow.
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        hostingController = controller

        // Any change to the answer, the error or the streaming flag can change
        // how tall the card wants to be.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeToFitContent() }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Grows the panel to whatever the card wants to be.
    ///
    /// A borderless window does not resize itself around its content, and the
    /// content cannot simply be measured either: SwiftUI compresses a view to
    /// the space it is given, so measuring inside a 56pt window reports 56 no
    /// matter what is in it. That is why the answer was invisible — it was
    /// being laid out into a window that never grew. The card is marked
    /// `fixedSize` vertically so it takes its ideal height regardless of the
    /// window, and the ideal height is read from the hosting controller rather
    /// than from a laid-out geometry proxy.
    private func resizeToFitContent() {
        guard let window, let hostingController else { return }

        var desired = hostingController.preferredContentSize.height
        if desired <= 0 {
            desired = hostingController.view.fittingSize.height
        }
        let target = min(max(desired, Self.collapsedHeight), Self.maximumHeight)

        var frame = window.frame
        guard abs(frame.height - target) > 0.5 else { return }

        // Anchored at the top, so the field stays put and the answer opens
        // downwards rather than shoving the bar up the screen.
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target
        window.setFrame(frame, display: true, animate: false)
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
    }

    func hide() {
        model.reset()
        window?.orderOut(nil)
    }

    /// Roughly where Spotlight puts itself: centred, a little above the middle.
    private func positionNearTop() {
        guard let window,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.22)
        window.setFrameOrigin(origin)
    }

    /// Behaves like Spotlight: clicking elsewhere puts it away.
    func windowDidResignKey(_ notification: Notification) {
        hide()
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
        // Takes its ideal height instead of shrinking into whatever the window
        // currently is; the controller then grows the window to match.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10)))
        .onAppear { promptFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.macro")
                .foregroundStyle(.secondary)

            TextField("Ask Rosy Bit…", text: $model.prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($promptFocused)
                .onSubmit { model.submit() }

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
                    Text(model.answer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxHeight: 320)

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
