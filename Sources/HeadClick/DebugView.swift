import SwiftUI
import HeadClickCore

struct DebugView: View {
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text(String(format: "FPS %.0f", model.fps)).monospacedDigit()
                Text(String(format: "Engine %.1f ms", model.engineMs)).monospacedDigit()
                Text(model.status).foregroundStyle(model.frame == nil ? .orange : .green)
                Spacer()
                Text(model.cameraName).foregroundStyle(.secondary)
            }
            if let f = model.frame {
                Text(String(format: "yaw %6.1f°   pitch %6.1f°   roll %6.1f°", f.yaw, f.pitch, f.roll))
                    .font(.system(.body, design: .monospaced))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 3) {
                    ForEach(Blend.allCases.dropFirst(), id: \.rawValue) { b in
                        BarRow(name: b.modelName, value: model.frame?[b] ?? 0)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 520)
    }
}

struct BarRow: View {
    let name: String
    let value: Float
    var body: some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 10, design: .monospaced)).frame(width: 130, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(value > 0.5 ? Color.orange : Color.accentColor).frame(width: g.size.width * CGFloat(min(1, max(0, value))))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.2f", value)).font(.system(size: 10, design: .monospaced)).frame(width: 32)
        }
    }
}
