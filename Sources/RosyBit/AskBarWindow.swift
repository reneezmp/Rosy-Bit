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
        // Deliberately no `sizingOptions`. With .preferredContentSize, AppKit
        // resizes the window itself whenever the content's ideal size changes —
        // and this class resizes it too, so each setFrame triggered a relayout,
        // which changed the ideal size, which triggered another resize. That
        // recursion is what made the app vanish on the first token.
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
            return height + min(textHeight(model.answer) + Self.textInset, 320) + 34  // + copy row
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
                    collapsePromptSelection()
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

    /// Returning in an `NSTextField` selects everything it contains. The text is
    /// kept so the question can be edited and asked again, but leaving it
    /// highlighted looks like the field is about to be overwritten. Collapsing
    /// the field editor's selection to the end puts the caret where it would be
    /// if you had simply stopped typing.
    private func collapsePromptSelection() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.fieldEditor(false, for: nil) as? NSTextView
            else { return }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
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
