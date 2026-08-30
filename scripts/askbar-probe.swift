// Watches what RosyBit's ask bar panel actually does when it is triggered.
//
//   swiftc -O scripts/askbar-probe.swift -o /tmp/askbar-probe && /tmp/askbar-probe
//
// Then press the ask-bar shortcut, or pick "Ask…" from the menu, while it runs.
//
// The panel not appearing has several very different causes, and they are
// indistinguishable by eye:
//
//   nothing is ever listed        -> show() is not being reached at all
//   listed, onscreen, sane bounds -> it IS being displayed; the bug is drawing
//   listed, bounds off the display-> positioning put it where nobody can see it
//   onscreen then offscreen fast  -> it opened and something closed it again
//
// The last one is invisible to a human on a fast machine and looks exactly like
// "nothing happened" on a slow one, which is why this samples rather than takes
// a single reading. Bounds and alpha need no permissions; only window titles
// and images do, so this asks for nothing.

import CoreGraphics
import Foundation

let started = Date()
var previous: String?

print("main display: \(CGDisplayBounds(CGMainDisplayID()))")
print("watching for RosyBit windows — trigger the ask bar now (12s)\n")

while Date().timeIntervalSince(started) < 12 {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    let raw = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    // The owner name is the bundle display name, "Rosy Bit" with a space, and
    // not the executable "RosyBit". Matching the wrong one reports no windows
    // on a perfectly healthy machine, which is a very convincing way to be
    // wrong — so this matches loosely and prints the owner it settled on.
    let mine = raw.filter {
        ($0[kCGWindowOwnerName as String] as? String)?
            .lowercased().replacingOccurrences(of: " ", with: "")
            .contains("rosybit") ?? false
    }

    let snapshot = mine.map { w -> String in
        let layer = w[kCGWindowLayer as String] as? Int ?? -999
        let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
        let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let x = Int(b["X"] ?? 0), y = Int(b["Y"] ?? 0)
        let width = Int(b["Width"] ?? 0), height = Int(b["Height"] ?? 0)
        return "layer \(layer)  alpha \(alpha)  onscreen \(onScreen)  "
             + "at (\(x), \(y))  \(width)x\(height)"
    }.sorted().joined(separator: "\n    ")

    let current = snapshot.isEmpty ? "(no windows)" : snapshot
    if current != previous {
        let stamp = String(format: "%6.2fs", Date().timeIntervalSince(started))
        print("\(stamp)  \(current)")
        previous = current
    }
    usleep(50_000)  // 20 Hz — fast enough to catch a panel that is closed again
}

print("\ndone")
