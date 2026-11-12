import SwiftUI
import AppKit

/// Plain AppKit windows hosting SwiftUI views (controllable from menus, hotkeys and launch flags).
@MainActor
enum Windows {
    private static var cache: [String: NSWindow] = [:]

    static func show(_ id: String, title: String, size: NSSize, @ViewBuilder content: () -> some View) {
        if let w = cache[id] {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.contentViewController = NSHostingController(rootView: content())
        w.isReleasedWhenClosed = false
        w.center()
        cache[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(_ id: String) { cache[id]?.close(); cache[id] = nil }

    static func showSettings() { show("settings", title: "HeadClick settings", size: NSSize(width: 960, height: 700)) { SettingsView() } }

    static func showDebug() { show("debug", title: "HeadClick debug", size: NSSize(width: 600, height: 560)) { DebugView() } }
}
