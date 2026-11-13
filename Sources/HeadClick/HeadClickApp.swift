import SwiftUI
import HeadClickCore

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
            Picker("Pointer", selection: $model.pointerMode) {
                ForEach(PointerMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Snap to buttons and links", isOn: $model.snapEnabled).disabled(model.pointerMode != .gaze)
            Button("Calibrate eyes (13 dots)…") { model.startGazeCalibration() }
            Button("Fix drift: look at the centre dot") { model.startDriftFix() }
            Divider()
            Button("Settings…") { Windows.showSettings() }
            Button("Calibrate head pointer…") { model.startCalibration(.pointer) }
            Button("Debug window") { Windows.showDebug() }
            Divider()
            Button("Quit HeadClick") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
