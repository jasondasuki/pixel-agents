import AppKit
import PixelMenuBarCore

// `PixelMenuBar --dump-frame out.png` renders a demo of the lane to a PNG and exits,
// so the sprites can be checked by eye without a menu bar.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--dump-frame"), i + 1 < args.count {
    _ = NSApplication.shared
    exit(MainActor.assumeIsolated { DemoDump.run(path: args[i + 1]) })
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
