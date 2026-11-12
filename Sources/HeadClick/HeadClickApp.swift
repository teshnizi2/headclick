import SwiftUI

struct HeadClickApp: App {
    @StateObject private var model = AppModel.shared

    init() { Task { @MainActor in AppModel.shared.bootstrap(); if CommandLine.arguments.contains("--show-debug") { Windows.showDebug() }; Snapshot.scheduleIfRequested(CommandLine.arguments) } }

    var body: some Scene {
        MenuBarExtra("HeadClick", systemImage: "face.smiling") {
            Text(model.status)
            Divider()
            Button("Debug window") { Windows.showDebug() }
            Divider()
            Button("Quit HeadClick") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
