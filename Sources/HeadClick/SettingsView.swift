import SwiftUI
import HeadClickCore

struct SettingsView: View {
    @ObservedObject var model = AppModel.shared
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                profileBar
                Divider()
                Text("Gestures → actions").font(.headline)
                Text("Pick any gesture for any action. The bar shows how strongly you are making each gesture; the line is where it fires.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Action.allCases) { a in ActionRow(action: a) }
                Divider()
                pointerBox
            }.padding(16)
        }
        .frame(minWidth: 940, minHeight: 640)
    }

    var profileBar: some View {
        HStack(spacing: 10) {
            Picker("Profile", selection: $model.profile) {
                ForEach(model.profiles, id: \.name) { Text($0.name).tag($0) }
            }.frame(width: 280)
            TextField("Save as…", text: $newName).frame(width: 140)
            Button("Save as") {
                guard !newName.isEmpty else { return }
                var p = model.profile; p.name = newName
                ProfileStore.save(p); model.profiles = ProfileStore.loadAll()
                model.profile = model.profiles.first { $0.name == newName } ?? p; newName = ""
            }.disabled(newName.isEmpty)
            Button("Reset to built-in") {
                if let b = Profile.builtIn.first(where: { $0.name == model.profile.name }) { model.profile = b }
            }.disabled(!Profile.builtIn.contains { $0.name == model.profile.name })
            Spacer()
            Button("Calibrate pointer…") { model.startCalibration(.pointer) }
            Button("Talk test…") { model.startCalibration(.talkTest) }
        }
    }

    var pointerBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pointer and guards").font(.headline)
            HStack {
                Text("Horizontal speed").frame(width: 130, alignment: .leading)
                Slider(value: $model.profile.pointer.gainX, in: 15...150)
                Text(String(format: "%.0f px/°", model.profile.pointer.gainX)).monospacedDigit().frame(width: 70)
            }
            HStack {
                Text("Vertical speed").frame(width: 130, alignment: .leading)
                Slider(value: $model.profile.pointer.gainY, in: 15...150)
                Text(String(format: "%.0f px/°", model.profile.pointer.gainY)).monospacedDigit().frame(width: 70)
            }
            HStack(spacing: 18) {
                Toggle("Invert horizontal", isOn: $model.profile.pointer.invertX)
                Toggle("Invert vertical", isOn: $model.profile.pointer.invertY)
                Toggle("Invert scroll", isOn: $model.profile.pointer.invertScroll)
            }
            HStack(spacing: 18) {
                Toggle("Talk guard (mute mouth/brow gestures while speaking)", isOn: $model.profile.talkGuard)
                Toggle("Swap left/right eye and mouth", isOn: $model.profile.swapLeftRight)
            }
            HStack(spacing: 18) {
                Toggle("Gaze jump (look somewhere, cursor jumps there)", isOn: $model.profile.gazeJump)
                Button("Calibrate gaze…") { model.startGazeCalibration() }
                Text(model.gazeSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ActionRow: View {
    let action: Action
    @ObservedObject var model = AppModel.shared

    var binding: GestureBinding? { model.profile.binding(for: action) }

    var allowed: [GestureID] {
        GestureID.allCases.filter { g in
            let s = Catalog.spec(g)
            switch binding?.trigger ?? action.triggers[0] {
            case .tap: return true
            case .hold, .continuous: return !s.isPoseEvent && !s.doublePattern
            case .long: return !s.isPoseEvent && !s.doublePattern
            }
        }
    }

    var body: some View {
        let g = binding?.gesture
        HStack(spacing: 10) {
            Circle().fill(model.firedRecently(action) ? Color.green : Color.gray.opacity(0.3)).frame(width: 12, height: 12)
            Text(action.title).frame(width: 120, alignment: .leading)
            Picker("", selection: Binding<GestureID?>(get: { g }, set: { setGesture($0) })) {
                Text("— none —").tag(GestureID?.none)
                ForEach(allowed) { id in
                    let used = model.profile.bindings.contains { $0.gesture == id && $0.trigger == (binding?.trigger ?? action.triggers[0]) && $0.action != action }
                    Text(Catalog.spec(id).title + (used ? " (used)" : "")).tag(GestureID?.some(id))
                }
            }.labelsHidden().frame(width: 190)
            Picker("", selection: Binding<Trigger>(get: { binding?.trigger ?? action.triggers[0] }, set: { setTrigger($0) })) {
                ForEach(action.triggers, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 100).disabled(g == nil || action.triggers.count < 2)
            if let g, !Catalog.spec(g).isPoseEvent {
                Meter(level: model.live.levels[g] ?? 0, threshold: model.profile.tuning(g).onThreshold ?? 0.5).frame(width: 120, height: 14)
                Picker("", selection: Binding<Float>(get: { model.profile.tuning(g).onThreshold ?? 0.5 }, set: { setThreshold(g, $0) })) {
                    ForEach(Sensitivity.allCases, id: \.self) { Text($0.title).tag($0.onThreshold) }
                }.labelsHidden().frame(width: 110)
                Button("Calibrate") { model.startCalibration(.gesture(g)) }
            } else if g != nil {
                Text("detected as an event").font(.caption).foregroundStyle(.secondary)
            }
            if let g { warnings(g) }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder func warnings(_ g: GestureID) -> some View {
        if model.profile.tuning(g).talkRisk {
            Label("fires while talking", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        } else if let n = Catalog.spec(g).note {
            Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    func setGesture(_ g: GestureID?) {
        var p = model.profile
        let trig = binding?.trigger ?? action.triggers[0]
        p.setBinding(action, gesture: g, trigger: trig)
        model.profile = p
    }
    func setTrigger(_ t: Trigger) {
        guard let b = binding else { return }
        var p = model.profile; p.setBinding(action, gesture: b.gesture, trigger: t); model.profile = p
    }
    func setThreshold(_ g: GestureID, _ v: Float) {
        var p = model.profile; var t = p.tuning(g); t.onThreshold = v; p.tuning[g.rawValue] = t; model.profile = p
    }
}

struct Meter: View {
    let level: Float, threshold: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(level >= threshold ? Color.green : Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
                Rectangle().fill(.primary).frame(width: 2).offset(x: geo.size.width * CGFloat(threshold) - 1)
            }
        }
    }
}
