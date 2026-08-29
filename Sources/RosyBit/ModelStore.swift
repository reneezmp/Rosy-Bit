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

        // Fall back to the first model when the preferred one is not here, but
        // do not write that fallback down: a model that is temporarily missing
        // must not quietly overwrite a choice the user made.
        let resolved: String?
        if let preferred = preferredName, found.contains(where: { $0.lastPathComponent == preferred }) {
            resolved = preferred
        } else {
            resolved = found.first?.lastPathComponent
        }
        if selectedName != resolved {
            selectedName = resolved
        }
    }

    /// Records an explicit choice. Always writes the preference, even when this
    /// model is already the one being served — it may only be serving as a
    /// fallback for a preferred model that is currently missing, and picking it
    /// by hand should settle that.
    func select(_ url: URL) {
        let name = url.lastPathComponent
        preferredName = name
        guard name != selectedName else { return }
        selectedName = name
    }

    func revealModelFolder() {
        let directory = Config.modelDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// The model the user actually picked, which is not the same thing as the
    /// one currently being served. Only `select(_:)` writes it.
    private var preferredName: String? {
        get { UserDefaults.standard.string(forKey: Self.selectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.selectionKey) }
    }
}
