import AppKit
import SwiftUI

final class HuggingFaceImportWindowController: NSWindowController {
    static let shared = HuggingFaceImportWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Import from Hugging Face"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: HuggingFaceImportView())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeIfOpen() { window?.close() }
}

struct HuggingFaceImportView: View {
    @ObservedObject private var importer = HuggingFaceModelImporter.shared
    @State private var source = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import a GGUF model")
                .font(.title3.bold())
            Text("Paste owner/repository, a Hugging Face repository link, or a direct .gguf link. Rosy will show the available files before downloading anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Qwen/Qwen3.5-0.8B", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { importer.discover(source) }
                Button("Find GGUF Files") { importer.discover(source) }
                    .disabled(importer.state.isBusy || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !importer.files.isEmpty {
                HStack {
                    Text("File")
                        .foregroundStyle(.secondary)
                    Picker("File", selection: $importer.selectedPath) {
                        ForEach(importer.files) { file in
                            Text(file.displayName).tag(file.path)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            status
            Spacer(minLength: 0)

            HStack {
                Button("Open Models Folder…") { ModelStore.shared.revealModelFolder() }
                Spacer()
                if importer.state.isBusy {
                    Button("Cancel") { importer.cancel() }
                } else if !importer.files.isEmpty {
                    Button("Download") { importer.downloadSelected() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 500, height: 330)
    }

    @ViewBuilder
    private var status: some View {
        switch importer.state {
        case .idle, .ready:
            EmptyView()
        case .resolving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the repository…").font(.callout)
            }
        case .downloading(let received, let expected):
            VStack(alignment: .leading, spacing: 5) {
                if expected > 0 {
                    ProgressView(value: Double(received), total: Double(expected))
                } else {
                    ProgressView()
                }
                Text(ModelSetupView.progressLabel(received: received, expected: expected))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .finished(let name):
            Label("Installed \(name)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
