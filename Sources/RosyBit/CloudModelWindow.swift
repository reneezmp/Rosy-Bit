import AppKit
import Combine
import SwiftUI

final class CloudModelWindowController: NSWindowController {
    static let shared = CloudModelWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Cloud Model"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: CloudModelView(
            onSaved: { [weak window] in
                ServerController.shared.stop()
                window?.close()
            },
            onForgotten: { [weak window] in
                if ModelStore.shared.selectedModel != nil {
                    ServerController.shared.start()
                }
                window?.close()
            }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

final class CloudModelFormModel: ObservableObject {
    @Published var kind: CloudProviderKind = .deepSeek
    @Published var name = "DeepSeek"
    @Published var endpoint = CloudProviderConfiguration.deepSeekDefault.endpoint
    @Published var model = CloudProviderConfiguration.deepSeekDefault.model
    @Published var maxTokens = CloudProviderConfiguration.deepSeekDefault.maxTokens
    @Published var apiKey = ""
    @Published private(set) var notice: String?

    private var loadedKind: CloudProviderKind?

    var hasStoredKey: Bool {
        guard let saved = CloudModelStore.shared.configuration,
              saved.kind == kind,
              CloudCredentialStore.load() != nil else { return false }
        let currentEndpoint: String
        if kind == .deepSeek {
            currentEndpoint = CloudProviderConfiguration.deepSeekDefault.endpoint
        } else {
            guard let normalized = try? CloudProviderConfiguration.normalizedEndpoint(endpoint)
            else { return false }
            currentEndpoint = normalized.absoluteString
        }
        return saved.endpoint == currentEndpoint
    }

    func load() {
        let configuration = CloudModelStore.shared.configuration
            ?? CloudProviderConfiguration.deepSeekDefault
        kind = configuration.kind
        name = configuration.name
        endpoint = configuration.endpoint
        model = configuration.model
        maxTokens = configuration.maxTokens
        apiKey = ""
        loadedKind = configuration.kind
        notice = nil
    }

    func changeKind(to newKind: CloudProviderKind) {
        guard newKind != loadedKind else { return }
        kind = newKind
        apiKey = ""
        notice = nil
        switch newKind {
        case .deepSeek:
            let preset = CloudProviderConfiguration.deepSeekDefault
            name = preset.name
            endpoint = preset.endpoint
            model = preset.model
            maxTokens = preset.maxTokens
        case .custom:
            name = ""
            endpoint = ""
            model = ""
            maxTokens = 1024
        }
        loadedKind = newKind
    }

    func save() -> Bool {
        do {
            try CloudModelStore.shared.saveAndSelect(
                CloudProviderConfiguration(
                    kind: kind,
                    name: name,
                    endpoint: endpoint,
                    model: model,
                    maxTokens: maxTokens),
                apiKey: apiKey)
            notice = nil
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func forget() {
        CloudModelStore.shared.forget()
    }
}

struct CloudModelView: View {
    @StateObject private var form = CloudModelFormModel()
    let onSaved: () -> Void
    let onForgotten: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Cloud Model")
                    .font(.title2.weight(.semibold))
                Text("Connect Rosy directly to DeepSeek or an OpenAI-compatible provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Provider", selection: $form.kind) {
                ForEach(CloudProviderKind.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: form.kind) { newKind in form.changeKind(to: newKind) }

            VStack(spacing: 10) {
                if form.kind == .custom {
                    row("Name") {
                        TextField("My provider", text: $form.name)
                    }
                    row("API URL") {
                        TextField("https://host.example/v1", text: $form.endpoint)
                    }
                } else {
                    row("API URL") {
                        Text(CloudProviderConfiguration.deepSeekDefault.endpoint)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                row("Model ID") {
                    TextField("deepseek-v4-flash", text: $form.model)
                }
                row("API key") {
                    SecureField(
                        form.hasStoredKey ? "Saved in Keychain — leave blank to keep" : "Paste API key",
                        text: $form.apiKey)
                }
                row("Answer limit") {
                    HStack(spacing: 8) {
                        TextField("1024", value: $form.maxTokens, format: .number)
                            .frame(width: 72)
                        Text("tokens")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Text("The key is stored in this Mac's Keychain, never in Rosy Bit's preferences or Insights. Custom providers must use HTTPS.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let notice = form.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            HStack {
                if CloudModelStore.shared.configuration != nil {
                    Button("Forget Cloud Model", role: .destructive) {
                        form.forget()
                        onForgotten()
                    }
                }
                Spacer()
                Button("Save, Register & Use") {
                    if form.save() { onSaved() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 390)
        .onAppear { form.load() }
    }

    private func row<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
