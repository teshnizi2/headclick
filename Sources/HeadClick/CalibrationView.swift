import SwiftUI
import HeadClickCore

struct CalibrationView: View {
    @ObservedObject var cal: Calibrator
    @ObservedObject var model = AppModel.shared
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if cal.finished {
                Image(systemName: cal.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(cal.failed ? .orange : .green)
                Text(cal.result).multilineTextAlignment(.center).frame(maxWidth: 440)
                HStack {
                    Button("Cancel") { model.endCalibration(cal, apply: false); close() }
                    Button(cal.failed ? "Close" : "Apply") { model.endCalibration(cal, apply: !cal.failed); close() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Step \(cal.stepNumber) of \(cal.stepCount)").font(.caption).foregroundStyle(.secondary)
                Text(cal.prompt).font(.title3).multilineTextAlignment(.center).frame(maxWidth: 440, minHeight: 90)
                ProgressView(value: cal.progress).frame(width: 300)
                Text(model.frame == nil ? "No face seen — move into view" : " ").font(.caption).foregroundStyle(.orange)
                Button("Cancel") { model.endCalibration(cal, apply: false); close() }
            }
        }
        .padding(28).frame(width: 520, height: 320)
    }
}
