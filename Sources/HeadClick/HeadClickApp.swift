import SwiftUI

struct HeadClickApp: App {
    var body: some Scene {
        MenuBarExtra("HeadClick", systemImage: "face.smiling") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
