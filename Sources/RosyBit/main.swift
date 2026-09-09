import AppKit

// The menu bar item is the entire interface, and it is built in AppKit by
// StatusItemController — see the note there for why it is not a MenuBarExtra.
//
// This was a SwiftUI `App` whose only scene was `Settings { EmptyView() }`,
// kept as "the inert one" until a real settings window existed. That window
// arrived in AppKit instead, and the placeholder was never removed — so the
// app shipped two windows both titled "Rosy Bit Settings", one of them blank,
// and a ⌘, that opened the blank one. An AppKit app with no scenes cannot
// have that problem.
//
// The main menu below is not decoration. An LSUIElement app never displays
// it, but NSApplication still dispatches its key equivalents to the key
// window, and that is what makes ⌘X/⌘C/⌘V/⌘A work inside a text field.
// SwiftUI used to provide it for free; losing that silently would have made
// the API key field impossible to paste into.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
