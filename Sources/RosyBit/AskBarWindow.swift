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

    func submit() {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }

        answer = ""
        errorMessage = nil
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

    private init() {
        let panel = AskBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 60),
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
        panel.contentViewController = NSHostingController(
            rootView: AskBarView(model: model, onDismiss: { [weak self] in self?.hide() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func registerHotKey() {
        guard Config.askBarEnabled, hotKey == nil else { return }
        // ⌥Space. Carbon masks, not NSEvent ones.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !model.answer.isEmpty || model.isStreaming || model.errorMessage != nil {
                Divider()
                output
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10)))
        .frame(width: 560)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if !model.answer.isEmpty {
                    Text(model.answer)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.isStreaming {
                    // At a few tokens a second the first word takes a moment;
                    // without this the bar looks like it ignored the return key.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 260)
    }
}
