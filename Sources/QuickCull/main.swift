import AppKit

// QuickCull - prototype of a no-import, folder-native photo culling app.
// Entry point: builds the NSApplication by hand (no storyboard, no nib),
// which is what lets this run straight from `swift run`.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
