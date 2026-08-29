import AppKit
import SwiftUI

@main
struct RosyBitApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu bar icon.
///
/// This *must* be a monochrome template image: macOS tints template images
/// automatically to match the menu bar and the current appearance mode, which
/// means the rosy colour cannot live here. It lives on the app icon instead —
/// same sakura motif, two assets.
struct MenuBarLabel: View {

    @ObservedObject private var server = ServerController.shared

    var body: some View {
        // The dot's space is reserved whether or not it is showing, so the
        // sakura does not shuffle sideways every time a request arrives.
        HStack(spacing: 2) {
            if let image = Self.templateImage {
                Image(nsImage: image)
            } else {
                // The app should never fail to appear just because art is missing.
                Image(systemName: "camera.macro")
            }

            Circle()
                .fill(server.activeRequests > 0 ? Color.green : Color.clear)
                .frame(width: 5, height: 5)
        }
    }

    private static let templateImage: NSImage? = {
        let pointSize = NSSize(width: 18, height: 18)
        let image = NSImage(size: pointSize)
        var didAddRepresentation = false

        for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            // Both files claim the same 18×18 point size while keeping their
            // native pixel dimensions, which is what marks the 36px file as @2x.
            representation.size = pointSize
            image.addRepresentation(representation)
            didAddRepresentation = true
        }

        guard didAddRepresentation else { return nil }
        image.isTemplate = true
        return image
    }()
}
