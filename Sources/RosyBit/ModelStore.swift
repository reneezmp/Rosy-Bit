import AppKit
import Combine
import Foundation

/// Gotcha #3: the model lives outside the bundle, in
/// `~/Library/Application Support/RosyBit/`, so models can be swapped without
/// rebuilding the app. Anything with a `.gguf` extension dropped in there shows
/// up in the Model submenu the next time the menu is opened.
final class ModelStore: ObservableObject {

    static let shared = ModelStore()

    private static let selectionKey = "selectedModel"

    @Published private(set) var models: [URL] = []
    @Published private(set) var selectedName: String?

    private init() {
        refresh()
    }

    var selectedModel: URL? {
        guard let selectedName else { return nil }
        return models.first { $0.lastPathComponent == selectedName }
    }

    func isSelected(_ url: URL) -> Bool {
        url.lastPathComponent == selectedName
    }

    /// Rescans the model directory. Called on launch and whenever the menu
    /// opens, so assignments are guarded — republishing unchanged values would
    /// make SwiftUI rebuild the menu while the user is reading it.
    func refresh() {
        let directory = Config.modelDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []

        let found = contents
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        if models != found {
            models = found
        }

        let stored = UserDefaults.standard.string(forKey: Self.selectionKey)
        let resolved: String?
        if let stored, found.contains(where: { $0.lastPathComponent == stored }) {
            resolved = stored
        } else {
            resolved = found.first?.lastPathComponent
        }
        if selectedName != resolved {
            selectedName = resolved
            persistSelection()
        }
    }

    func select(_ url: URL) {
        guard url.lastPathComponent != selectedName else { return }
        selectedName = url.lastPathComponent
        persistSelection()
    }

    func revealModelFolder() {
        let directory = Config.modelDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func persistSelection() {
        if let selectedName {
            UserDefaults.standard.set(selectedName, forKey: Self.selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectionKey)
        }
    }
}
