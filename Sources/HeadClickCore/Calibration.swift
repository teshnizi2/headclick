import Foundation
import CoreGraphics

/// A guided capture: a list of timed steps fed by camera frames. Results are applied to a Profile.
public final class Calibrator: ObservableObject {
    public enum Kind: Equatable {
        case pointer
        case gesture(GestureID)
        case talkTest
    }
    enum Phase { case pointerNeutral, pointerRange, gestureNeutral, rep, talk }
    struct Step { let prompt: String; let duration: Double; let phase: Phase }

    public let kind: Kind
    let steps: [Step]
    let screen: CGRect
    let profile: Profile
    public private(set) var index = 0
    @Published public private(set) var prompt = ""
    @Published public private(set) var progress = 0.0        // 0...1 within the current step
    @Published public private(set) var stepNumber = 1
    @Published public private(set) var finished = false
    @Published public private(set) var result = ""
    public var stepCount: Int { steps.count }
    public private(set) var failed = false

    private var stepStart: Double?
    private var yaws: [Double] = [], pitches: [Double] = []
    private var raws: [Float] = []
    private var repPeaks: [Float] = []
    private var talkFrames: [FaceFrame] = []
    private var neutralYaw = 0.0, neutralPitch = 0.0, jitterSD = 0.0
    private var rangeYaw = (0.0, 0.0), rangePitch = (0.0, 0.0)
    private var neutralLevel: Float = 0
    private var blinkSwapVotes = 0
    // outputs
    private var out = Profile(name: "", bindings: [])

    public init(kind: Kind, profile: Profile, screen: CGRect) {
        self.kind = kind; self.profile = profile; self.screen = screen; out = profile
        switch kind {
        case .pointer:
            steps = [Step(prompt: "Look at the middle of the screen and hold still", duration: 2, phase: .pointerNeutral),
                     Step(prompt: "Turn your head to look at each edge of the screen, as far as is comfortable", duration: 5, phase: .pointerRange)]
        case .gesture(let g):
            let t = Catalog.spec(g).title
            steps = [Step(prompt: "Relax your face and look at the screen", duration: 3, phase: .gestureNeutral)]
                + (1...3).map { Step(prompt: "Rep \($0) of 3: \(t) — hold it", duration: 2.2, phase: .rep) }
        case .talkTest:
            steps = [Step(prompt: "Read aloud, normally: “The quick brown fox jumps over the lazy dog. She sells sea shells by the sea shore.” Keep reading.", duration: 20, phase: .talk)]
        }
        prompt = steps[0].prompt
    }

    /// Feed every frame (nil = no face).
    public func feed(_ f: FaceFrame?, now: Double) {
        guard !finished, index < steps.count else { return }
        if stepStart == nil { stepStart = now }
        let step = steps[index]
        let el = now - stepStart!
        progress = min(1, el / step.duration)
        if let f {
            switch step.phase {
            case .pointerNeutral, .pointerRange: yaws.append(Double(f.yaw)); pitches.append(Double(f.pitch))
            case .gestureNeutral, .rep:
                if case .gesture(let g) = kind {
                    var ff = f
                    if profile.swapLeftRight { ff = swapped(f) }
                    raws.append(Catalog.spec(g).signal(ff))
                    if g == .winkLeft || g == .winkRight, step.phase == .rep {
                        let l = f[.eyeBlinkLeft], r = f[.eyeBlinkRight]
                        let wantLeft = (g == .winkLeft) != profile.swapLeftRight
                        if abs(l - r) > 0.3 { blinkSwapVotes += ((l > r) == wantLeft) ? 1 : -1 }
                    }
                }
            case .talk: talkFrames.append(f)
            }
        }
        if el >= step.duration { complete(step); }
    }

    private func swapped(_ f: FaceFrame) -> FaceFrame {
        var o = f; let idx = Controller.makeSwapIndex(); for i in 0..<f.blend.count { o.blend[i] = f.blend[idx[i]] }; return o
    }

    private func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }
    private func percentile(_ a: [Float], _ p: Double) -> Float { Float(percentile(a.map(Double.init), p)) }

    private func complete(_ step: Step) {
        switch step.phase {
        case .pointerNeutral:
            neutralYaw = yaws.isEmpty ? 0 : yaws.reduce(0, +) / Double(yaws.count)
            neutralPitch = pitches.isEmpty ? 0 : pitches.reduce(0, +) / Double(pitches.count)
            let m = neutralYaw
            jitterSD = yaws.isEmpty ? 0 : (yaws.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(yaws.count)).squareRoot()
            yaws = []; pitches = []
        case .pointerRange:
            rangeYaw = (percentile(yaws, 0.05), percentile(yaws, 0.95))
            rangePitch = (percentile(pitches, 0.05), percentile(pitches, 0.95))
            finishPointer()
        case .gestureNeutral:
            neutralLevel = percentile(raws, 0.95); raws = []
        case .rep:
            repPeaks.append(percentile(raws, 0.98)); raws = []
            if repPeaks.count == 3 { finishGesture() }
        case .talk:
            finishTalk()
        }
        if !finished {
            index += 1; stepNumber = index + 1; stepStart = nil; progress = 0
            if index < steps.count { prompt = steps[index].prompt }
        }
    }

    private func finishPointer() {
        let ry = rangeYaw.1 - rangeYaw.0, rp = rangePitch.1 - rangePitch.0
        if ry < 6 || rp < 3 || yaws.count < 30 {
            fail("Not enough head movement or no face seen (yaw range \(Int(ry))°, pitch range \(Int(rp))°). Try again, turning further.")
            return
        }
        out.pointer.gainX = Double(screen.width) * 0.95 / ry
        out.pointer.gainY = Double(screen.height) * 0.95 / max(rp, 8)
        out.pointer.deadZoneDeg = max(0.06, min(0.3, jitterSD * 1.5))
        out.pointer.calibrated = true
        finished = true
        result = String(format: "Pointer calibrated. Comfortable range: yaw %.0f°, pitch %.0f°. Gain %.0f / %.0f px per degree. Still-head jitter %.2f° (dead zone %.2f°).",
                        ry, rp, out.pointer.gainX, out.pointer.gainY, jitterSD, out.pointer.deadZoneDeg)
    }

    private func finishGesture() {
        guard case .gesture(let g) = kind else { return }
        let spec = Catalog.spec(g)
        let peak = repPeaks.sorted()[1]
        let minRange: Float = spec.group == .head ? 6 : 0.12
        if peak - neutralLevel < minRange {
            fail(String(format: "%@ was too small to measure (rest %.2f, peak %.2f). Exaggerate it more, or pick another gesture.", spec.title, neutralLevel, peak))
            return
        }
        var t = out.tuning(g)
        t.neutral = neutralLevel; t.peak = peak
        out.tuning[g.rawValue] = t
        var msg = String(format: "%@ calibrated: rest %.2f → peak %.2f.", spec.title, neutralLevel, peak)
        if blinkSwapVotes < -3 {
            out.swapLeftRight.toggle()
            msg += " Your left/right eyes were swapped relative to the model, so left/right are now flipped."
        }
        finished = true; result = msg
    }

    private func finishTalk() {
        guard !talkFrames.isEmpty else { fail("No face seen during the talk test."); return }
        // Replay the recorded speech through a throw-away controller with the real profile: count clicks with and without the guard.
        func replay(guardOn: Bool) -> [GestureID: Int] {
            let sink = CountingSink()
            var p = profile; p.talkGuard = guardOn
            p.bindings = p.bindings.filter { !Catalog.spec($0.gesture).isPoseEvent && $0.action != .pauseToggle }
            let c = Controller(profile: p, sink: sink, bounds: screen)
            var counts: [GestureID: Int] = [:]
            c.onAction = { a, g in counts[g, default: 0] += 1 }
            for f in talkFrames { c.process(f, now: f.time) }
            return counts
        }
        let raw = replay(guardOn: false), guarded = replay(guardOn: true)
        for (g, _) in raw { var t = out.tuning(g); t.talkRisk = (guarded[g] ?? 0) > 0; out.tuning[g.rawValue] = t }
        for g in guarded.keys where raw[g] == nil { var t = out.tuning(g); t.talkRisk = true; out.tuning[g.rawValue] = t }
        let rawTotal = raw.values.reduce(0, +), gTotal = guarded.values.reduce(0, +)
        finished = true
        let names = { (d: [GestureID: Int]) in d.map { "\(Catalog.spec($0.key).title) ×\($0.value)" }.joined(separator: ", ") }
        result = "While you spoke: \(rawTotal) false trigger(s) without the talk guard (\(rawTotal == 0 ? "none" : names(raw))); \(gTotal) with it (\(gTotal == 0 ? "none" : names(guarded))). " + (gTotal == 0 ? "Safe to talk." : "Gestures listed still fire while talking: they are flagged in Settings.")
        talkResult = (rawTotal, gTotal)
    }
    public private(set) var talkResult: (raw: Int, guarded: Int)?

    private func fail(_ m: String) { failed = true; finished = true; result = m }

    /// The profile with this calibration applied (unchanged if it failed).
    public func apply(to p: Profile) -> Profile {
        guard finished, !failed else { return p }
        var q = p
        switch kind {
        case .pointer: q.pointer = out.pointer
        case .gesture(let g): q.tuning[g.rawValue] = out.tuning[g.rawValue]; q.swapLeftRight = out.swapLeftRight
        case .talkTest: for (k, v) in out.tuning { var t = q.tuning[k] ?? GestureTuning(); t.talkRisk = v.talkRisk; q.tuning[k] = t }
        }
        return q
    }
}

final class CountingSink: CursorSink {
    var currentPosition = CGPoint(x: 100, y: 100)
    func move(to p: CGPoint, dragging: Bool) { currentPosition = p }
    func button(_ b: MouseButton, down: Bool, at p: CGPoint, clickState: Int) {}
    func scroll(pixelsY: Double) {}
}
