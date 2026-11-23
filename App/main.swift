import AppKit

// AppKit lifecycle, no storyboard and no SwiftUI `App`, so a test run can configure the process
// before anything reaches the screen. Info.plist sets LSUIElement: no Dock icon, no menu bar.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
