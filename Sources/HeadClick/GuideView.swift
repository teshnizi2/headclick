import SwiftUI
import AppKit
import HeadClickCore

/// Borderless full-screen window for the guided start. Esc stops the guide.
final class GuideWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) } }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private let guideGreen = Color(red: 0.30, green: 0.85, blue: 0.50)
private let guideBg = Color(red: 0.06, green: 0.07, blue: 0.09)
private let guideAccent = Color(red: 1.0, green: 0.62, blue: 0.20)

/// Full-screen guide: shows where to look and what to do, step by step. The real cursor is never driven from here.
struct GuideView: View {
    @ObservedObject var run: GuidedRun
    @ObservedObject var model = AppModel.shared
    let stop: () -> Void
    let startControl: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                guideBg
                content(geo.size)
                if run.stage == .gazeCal {
                    // the 13 dots use the whole screen: keep only the stop hint, between the dots
                    Text("Esc = stop").font(.system(size: 14)).foregroundStyle(.white.opacity(0.5)).position(x: geo.size.width * 0.75, y: 34)
                } else {
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        bottomBar
                    }
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    // MARK: pieces
    var topBar: some View {
        HStack(spacing: 10) {
            ForEach(GuideStep.allCases, id: \.rawValue) { s in
                let o = run.outcome(of: s), cur = run.visibleStep == s
                HStack(spacing: 6) {
                    Text(o == .passed ? "✓" : o == .failed ? "!" : o == .skipped ? "–" : "\(s.rawValue + 1)")
                        .font(.system(size: 14, weight: .bold)).frame(width: 24, height: 24)
                        .background(Circle().fill(o == .passed ? guideGreen : o == .failed ? Color.orange : cur ? Color.white : Color.white.opacity(0.18)))
                        .foregroundStyle(o == .pending && !cur ? Color.white : Color.black)
                    Text(s.title).font(.system(size: 16, weight: cur ? .bold : .regular)).foregroundStyle(.white.opacity(cur ? 1 : 0.55))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(cur ? Color.white.opacity(0.14) : .clear))
            }
            Spacer()
            Text("Your real cursor is NOT controlled during this guide").font(.system(size: 14)).foregroundStyle(guideGreen)
            Button("Stop   Esc") { stop() }.controlSize(.large)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }

    var bottomBar: some View {
        HStack(spacing: 14) {
            Button("‹ Back") { run.back() }.disabled(!run.canGoBack).controlSize(.large)
            Spacer()
            if run.phase == .running, run.secondsLeft > 0, run.stage != .summary, run.stage != .gazeIntro {
                Text("⏱ \(Int(run.secondsLeft.rounded(.up))) s").font(.system(size: 22, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            if run.stage != .summary {
                if run.phase == .failed { Button("Try again") { run.retry() }.controlSize(.large) }
                if run.phase == .running { if run.stage != .gazeIntro { Button("Skip ›") { run.skip() }.controlSize(.large) } }
                else { Button(run.phase == .failed ? "Continue anyway ›" : "Next ›") { run.next() }.controlSize(.large).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }

    @ViewBuilder func content(_ size: CGSize) -> some View {
        switch run.stage {
        case .camera: cameraPanel
        case .dot: dotsPanel(size)
        case .gesture: gesturePanel
        case .gazeIntro: gazeIntro
        case .gazeCal: if let g = run.gaze { GazeDotPanel(cal: g, screen: size) }
        case .summary: summaryPanel
        }
    }

    func big(_ s: String, _ size: CGFloat = 34, _ w: Font.Weight = .semibold) -> some View {
        Text(s).font(.system(size: size, weight: w, design: .rounded)).foregroundStyle(.white).multilineTextAlignment(.center)
    }

    // MARK: 1 camera
    var cameraPanel: some View {
        let img = model.preview
        let aspect = img.map { CGFloat($0.width) / CGFloat($0.height) } ?? 4.0 / 3.0
        let ok = run.phase == .passed
        return HStack(spacing: 56) {
            ZStack {
                if let img {
                    Image(decorative: img, scale: 1).resizable().scaleEffect(x: -1, y: 1)
                } else {
                    Color.black
                    Text("Waiting for the camera…\n\(model.status)").foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                }
                MeshView(frame: model.frame)
            }
            .frame(width: 440 * aspect, height: 440)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(ok ? guideGreen : .white.opacity(0.25), lineWidth: 4))
            VStack(alignment: .leading, spacing: 16) {
                Text(ok ? "✓" : run.faceVisible ? "◌" : "!").font(.system(size: 120, weight: .bold)).foregroundStyle(ok ? guideGreen : run.faceVisible ? .white : .orange)
                Text(ok ? "I can see your face" : run.phase == .failed ? "I can't get a steady face yet" : run.faceVisible ? "Hold still for a moment…" : "Looking for your face…")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(run.phase == .failed ? run.message : run.hint.isEmpty ? " " : run.hint).font(.system(size: 22)).foregroundStyle(.orange).frame(maxWidth: 520, alignment: .leading)
                Text(String(format: "camera %.0f fps · engine %.1f ms · %@", model.fps, model.engineMs, model.cameraName.isEmpty ? "no camera yet" : model.cameraName))
                    .font(.system(size: 16, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.top, 20)
    }

    // MARK: 3 look at the dots
    func dotsPanel(_ size: CGSize) -> some View {
        ZStack {
            ForEach(0..<5, id: \.self) { k in
                let o = run.dotOutcomes[k], cur = run.currentDot == k
                ZStack {
                    Circle().stroke(Color.white.opacity(cur ? 0.6 : 0.25), lineWidth: 3).frame(width: 64, height: 64)
                    if o == .passed { Circle().fill(guideGreen).frame(width: 34, height: 34); Text("✓").font(.system(size: 22, weight: .heavy)).foregroundStyle(.black) }
                    else if o == .failed { Text("✗").font(.system(size: 30, weight: .bold)).foregroundStyle(.red.opacity(0.7)) }
                    else if cur {
                        Circle().fill(.red).frame(width: 28, height: 28)
                        Circle().trim(from: 0, to: run.dotProgress).stroke(guideGreen, lineWidth: 6).frame(width: 64, height: 64).rotationEffect(.degrees(-90))
                    } else { Circle().fill(Color.white.opacity(0.25)).frame(width: 14, height: 14) }
                }
                .position(run.dots[k])
                Text(GuidedRun.dotNames[k]).font(.system(size: 14)).foregroundStyle(.white.opacity(0.45))
                    .position(x: run.dots[k].x, y: run.dots[k].y + 52)
            }
            VStack(spacing: 10) {
                big(run.message, 38)
                Text("The orange dot is where I think you look. Your head does not move it.").font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
                if !run.hint.isEmpty { Text(run.hint).foregroundStyle(.orange) }
                dotErrorLine
            }
            .frame(maxWidth: 760).position(x: size.width / 2, y: size.height * 0.31)
            Circle().fill(guideAccent).frame(width: 30, height: 30)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: guideAccent.opacity(0.8), radius: 12)
                .position(run.pointerPos)
        }
    }

    /// "centre 1.8 cm · left 2.6 cm · ..." for the dots checked so far.
    var dotErrorLine: some View {
        let parts = (0..<5).compactMap { k in run.dotErrorsCm[k].map { String(format: "%@ %.1f cm", GuidedRun.dotNames[k], $0) } }
        return Text(parts.isEmpty ? " " : "Error: " + parts.joined(separator: " · "))
            .font(.system(size: 18, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
    }

    // MARK: 4 gestures
    var gesturePanel: some View {
        let i = run.currentGestureIndex ?? 0
        let t = run.tasks[i]
        let spec = Catalog.spec(t.gesture)
        return VStack(spacing: 14) {
            Text("Click gesture \(i + 1) of \(run.tasks.count)").font(.system(size: 16)).foregroundStyle(.white.opacity(0.55))
            Text(t.action.title.uppercased()).font(.system(size: 26, weight: .heavy)).tracking(4).foregroundStyle(guideAccent)
            Text(GuideText.emoji(t.gesture)).font(.system(size: 140)).rotationEffect(.degrees(GuideText.emojiRotation(t.gesture)))
                .animation(.easeInOut(duration: 0.2), value: run.level)
            if run.calibratingGesture, let c = run.calibrator {
                big("Calibrating: " + run.message, 30).frame(maxWidth: 800)
                CalibBar(cal: c)
            } else {
                big(run.message, 32).frame(maxWidth: 820)
                Text("\(spec.title) · \(t.trigger.title)").font(.system(size: 18)).foregroundStyle(.white.opacity(0.55))
                Meter(level: run.level, threshold: run.threshold).frame(width: 620, height: 34)
                HStack(spacing: 14) {
                    ForEach(0..<GuidedRun.hitsNeeded, id: \.self) { n in
                        Text(n < run.hits ? "●" : "○").font(.system(size: 40)).foregroundStyle(n < run.hits ? guideGreen : .white.opacity(0.4))
                    }
                    if run.phase == .passed { Text("✓").font(.system(size: 54, weight: .heavy)).foregroundStyle(guideGreen) }
                }
                if run.phase == .failed {
                    Text(run.message).font(.system(size: 20)).foregroundStyle(.orange).frame(maxWidth: 760)
                    if !spec.isPoseEvent { Button("Calibrate this gesture (10 s)") { run.calibrateGesture() }.controlSize(.large) }
                }
            }
        }
    }

    // MARK: 2 eyes
    var gazeIntro: some View {
        VStack(spacing: 24) {
            Text("👀").font(.system(size: 110))
            big("Eye calibration", 26, .bold).foregroundStyle(guideAccent)
            big("Look at each dot as it appears. 13 dots, about 15 seconds.", 32).frame(maxWidth: 780)
            Text("Let your head move naturally; only your eyes matter. This is how the cursor learns where you look.").font(.system(size: 18)).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: 700).multilineTextAlignment(.center)
            Text("Starting in \(Int(run.secondsLeft.rounded(.up)))…").font(.system(size: 20, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            Button("Start now") { run.next() }.controlSize(.extraLarge).buttonStyle(.borderedProminent)
        }
    }

    // MARK: 5 summary
    var summaryPanel: some View {
        VStack(spacing: 18) {
            Text("Summary").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white).padding(.top, 70)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.summaryLines()) { l in
                        HStack(alignment: .top, spacing: 12) {
                            Text(l.mark).font(.system(size: 22, weight: .bold)).foregroundStyle(l.mark == "✓" ? guideGreen : l.mark == "✗" ? .red : .white.opacity(0.5)).frame(width: 26)
                            Text(l.text).font(.system(size: 19)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 980, alignment: .leading).padding(.horizontal, 20)
            }
            .frame(maxHeight: 380)
            Text(run.summaryPath.isEmpty ? " " : "Saved to \(run.summaryPath)").font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            Button { startControl() } label: { Text("Start controlling the cursor").font(.system(size: 24, weight: .bold)).padding(.horizontal, 24).padding(.vertical, 10) }
                .buttonStyle(.borderedProminent).tint(guideGreen).controlSize(.extraLarge)
            Text("Safety stays on: HeadClick starts the moment you press this. Esc, ⌃⌥P or touching the mouse or trackpad pauses it at once.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: 760).multilineTextAlignment(.center)
            Button("Close, stay paused") { stop() }.controlSize(.large)
            Spacer(minLength: 70)
        }
    }
}

struct GuideMeter: View {
    let level: Float, threshold: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.14))
                RoundedRectangle(cornerRadius: 8).fill(level >= threshold ? guideGreen : guideAccent).frame(width: g.size.width * CGFloat(min(1, max(0, level))))
                Rectangle().fill(.white).frame(width: 4).offset(x: g.size.width * CGFloat(threshold) - 2)
                Text("fires here").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).offset(x: g.size.width * CGFloat(threshold) + 6, y: -20)
            }
        }
    }
}

struct CalibBar: View {
    @ObservedObject var cal: Calibrator
    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: cal.progress).frame(width: 420)
            Text("Step \(cal.stepNumber) of \(cal.stepCount)").font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

struct GazeDotPanel: View {
    @ObservedObject var cal: GazeCalibrator
    let screen: CGSize
    var body: some View {
        ZStack {
            Text(cal.finished ? cal.result : cal.prompt + "  (eyes on the dot)")
                .font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                .frame(maxWidth: 800).position(x: screen.width / 2, y: screen.height * 0.30)
            if !cal.finished {
                ZStack {
                    Circle().stroke(.white.opacity(0.35), lineWidth: 2).frame(width: 52, height: 52)
                    Circle().fill(.red).frame(width: 16, height: 16)
                    Circle().trim(from: 0, to: cal.progress).stroke(guideGreen, lineWidth: 4).frame(width: 52, height: 52).rotationEffect(.degrees(-90))
                }
                .position(cal.target).animation(.easeInOut(duration: 0.25), value: cal.target)
            }
        }
    }
}
