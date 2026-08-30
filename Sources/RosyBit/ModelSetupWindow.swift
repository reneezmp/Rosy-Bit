import AppKit
import SwiftUI

/// Shown on first run, when there is no model to serve.
final class ModelSetupWindowController: NSWindowController {

    static let shared = ModelSetupWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Rosy Bit"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: ModelSetupView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeIfOpen() {
        window?.close()
    }
}

struct ModelSetupView: View {

    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var models = ModelStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(models.models.isEmpty ? "Rosy Bit needs a model" : title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            status
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 460, height: 300)
    }

    @ViewBuilder
    private var status: some View {
        switch downloader.state {
        case .idle:
            EmptyView()

        case .resolving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up the model…").font(.callout)
            }

        case .downloading(let received, let expected):
            VStack(spacing: 4) {
                if expected > 0 {
                    ProgressView(value: Double(received), total: Double(expected))
                } else {
                    ProgressView()
                }
                Text(Self.progressLabel(received: received, expected: expected))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

        case .finished(let name):
            Label(name, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)

        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button("Open Models Folder…") { models.revealModelFolder() }

            Spacer()

            if downloader.state.isBusy {
                Button("Cancel") { downloader.cancel() }
            } else {
                Button(downloadTitle) { downloader.retry() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var title: String {
        downloader.activeModelName.map { "Downloading \($0)" } ?? "Add a model"
    }

    private var description: String {
        if models.models.isEmpty {
            return "Bonsai 1.7B by Prism ML is a 1-bit model, about 240 MB on disk. "
                + "It goes in Application Support, outside the app, so it can be "
                + "swapped later without reinstalling."
        }
        return "Models live in Application Support, outside the app. Bigger ones answer "
            + "short prompts perfectly well on modest hardware — it is long input that "
            + "makes them slow, since size and prompt length multiply."
    }

    private var downloadTitle: String {
        if case .failed = downloader.state { return "Try Again" }
        if let name = downloader.activeModelName { return "Download \(name)" }
        return "Download Bonsai 1.7B"
    }

    static func progressLabel(received: Int64, expected: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let got = formatter.string(fromByteCount: received)
        guard expected > 0 else { return got }
        let total = formatter.string(fromByteCount: expected)
        let percent = Int(Double(received) / Double(expected) * 100)
        return "\(got) of \(total)  ·  \(percent)%"
    }
}
