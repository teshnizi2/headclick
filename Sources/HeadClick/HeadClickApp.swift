import SwiftUI

struct HeadClickApp: App {
    @StateObject private var model = AppModel.shared

    init() {
        Task { @MainActor in
            AppModel.shared.bootstrap()
            if CommandLine.arguments.contains("--show-debug") { Windows.showDebug() }
            if CommandLine.arguments.contains("--show-settings") { Windows.showSettings() }
            if CommandLine.arguments.contains("--show-gaze-cal") { AppModel.shared.startGazeCalibration() }
            if CommandLine.arguments.contains("--show-guide") { AppModel.shared.startGuide() }
            if GuideDemo.enabled { GuideDemo.start() }
            if CommandLine.arguments.contains("--show-overlay") { AppModel.shared.overlayOn = true }
            if CommandLine.arguments.contains("--demo-toast") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.toastHold("Pucker → Right click") } }
            Snapshot.scheduleIfRequested(CommandLine.arguments)
        }
    }

    var body: some Scene {
        MenuBarExtra("HeadClick", systemImage: model.live.paused ? "pause.circle" : "face.smiling") {
            Text(model.status)
            if !model.accessibilityOK {
                Button("Grant Accessibility (needed to move the cursor)…") { model.requestAccessibility() }
            }
            Button("Guided start…") { model.startGuide() }
            Divider()
            Button(model.live.paused ? "Resume   ⌃⌥P" : "Pause   ⌃⌥P") { model.togglePause() }
            Button("Recenter cursor   ⌃⌥R") { model.controller.recenter() }
            Picker("Profile", selection: $model.profile) {
                ForEach(model.profiles, id: \.name) { Text($0.name).tag($0) }
            }
            Toggle("Filming overlay   ⌃⌥O", isOn: $model.overlayOn)
            Toggle("Gaze jump", isOn: $model.profile.gazeJump)
            Toggle("Gaze only (comparison mode)", isOn: $model.gazeOnly)
            Button("Calibrate gaze…") { model.startGazeCalibration() }
            Divider()
            Button("Settings…") { Windows.showSettings() }
            Button("Calibrate pointer…") { model.startCalibration(.pointer) }
            Button("Debug window") { Windows.showDebug() }
            Divider()
            Button("Quit HeadClick") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
