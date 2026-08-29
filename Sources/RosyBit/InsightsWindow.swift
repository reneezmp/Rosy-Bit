import AppKit
import SwiftUI

/// Hosts the Insights window. AppKit rather than a SwiftUI `Window` scene
/// because the menu that opens it is AppKit, and an `LSUIElement` app has to
/// activate itself explicitly or the window opens behind everything.
final class InsightsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = InsightsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Insights"
        window.contentViewController = NSHostingController(rootView: InsightsView())
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
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
}

struct InsightsView: View {

    @ObservedObject private var store = InsightsStore.shared
    @State private var selection: RequestRecord.ID?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    private var selected: RequestRecord? {
        store.records.first { $0.id == selection }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.records.count) captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clear() }
                    .controlSize(.small)
                    .disabled(store.records.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.records.isEmpty {
                emptyState
            } else {
                List(store.records, selection: $selection) { record in
                    row(for: record).tag(record.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Nothing captured yet")
                .foregroundStyle(.secondary)
            Text("Requests appear here as clients call the endpoint.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private func row(for record: RequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.method)
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.secondary)
                Text(record.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                statusBadge(record)
            }
            HStack(spacing: 8) {
                Text(record.startedAt, style: .time)
                if let duration = record.durationMs {
                    Text(Self.duration(duration))
                }
                if record.streamed {
                    Text("stream")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ record: RequestRecord) -> some View {
        let text: String
        let colour: Color
        if record.parseFailed && record.statusCode == nil {
            text = "—"
            colour = .secondary
        } else if let status = record.statusCode {
            text = String(status)
            colour = (200..<300).contains(status) ? .green : .orange
        } else {
            text = "…"
            colour = .secondary
        }
        return Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(colour)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let record = selected {
            RequestDetailView(record: record)
        } else {
            VStack {
                Spacer()
                Text("Select a request")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    static func duration(_ milliseconds: Double) -> String {
        milliseconds < 1000
            ? String(format: "%.0f ms", milliseconds)
            : String(format: "%.1f s", milliseconds / 1000)
    }
}

private struct RequestDetailView: View {

    let record: RequestRecord

    enum Tab: String, CaseIterable, Identifiable {
        case prompt = "Prompt"
        case request = "Request"
        case response = "Response"
        case params = "Params"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(record.method)
                .font(.caption.monospaced().bold())
            Text(record.path)
                .font(.headline)
            Spacer()
            if let duration = record.durationMs {
                Text(InsightsView.duration(duration))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .prompt:
            promptTab
        case .request:
            monospaced(record.requestBody, placeholder: "No request body")
        case .response:
            monospaced(
                record.responseText ?? record.responseBody,
                placeholder: "No response body")
        case .params:
            paramsTab
        }
    }

    /// The laid-out view: each message as its own labelled block, which is far
    /// easier to read than the raw JSON when a system prompt runs to pages.
    @ViewBuilder
    private var promptTab: some View {
        let messages = record.promptMessages
        if messages.isEmpty {
            placeholderView("No messages — see the Request tab for the raw body")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text(message.content)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.10)))
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var paramsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Inference")
                field("Model", record.model)
                field("Tokens", tokenSummary)
                field("Speed", record.tokensPerSecond.map { String(format: "%.2f tok/s", $0) })
                field("Temperature", record.temperature.map { String(format: "%g", $0) })
                field("Max tokens", record.maxTokens.map(String.init))
                field("Finish reason", record.finishReason)
                field("Streamed", record.streamed ? "yes" : "no")

                section("Request")
                field("Method", record.method)
                field("Path", record.path)
                field("Status", record.statusCode.map(String.init))
                field("Duration", record.durationMs.map(InsightsView.duration))
                field("Started", record.startedAt.formatted(date: .omitted, time: .standard))
                if record.parseFailed {
                    field("Note", "Response could not be parsed; the request itself was forwarded normally")
                }
            }
            .padding(12)
        }
    }

    private var tokenSummary: String? {
        switch (record.promptTokens, record.completionTokens) {
        case let (input?, output?): return "\(input) → \(output)"
        case let (input?, nil): return "\(input) → ?"
        case let (nil, output?): return "? → \(output)"
        default: return nil
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func field(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value ?? "—")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private func monospaced(_ text: String?, placeholder: String) -> some View {
        Group {
            if let text, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                placeholderView(placeholder)
            }
        }
    }

    private func placeholderView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
