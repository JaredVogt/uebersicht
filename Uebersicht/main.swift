import AppKit

// Replaces the NSApplicationMain + MainMenu.xib bootstrap. We keep the Obj-C
// `UBAppDelegate` (it still owns considerable state — screens, windows,
// widget coordinator, Sparkle wiring). `NSApplication.shared` respects the
// `NSPrincipalClass=UBApplication` entry in Info.plist, so we get the
// `sendEvent:` subclass behavior without extra work.
//
// Once `UBAppDelegate` is ported to Swift we can revisit and move to a true
// `@main SwiftUI App` with `MenuBarExtra`. For now, programmatic AppKit is
// what gives us a XIB-free boot without forcing that larger rewrite.
let app = NSApplication.shared
let delegate = UBAppDelegate()
app.delegate = delegate
app.run()
