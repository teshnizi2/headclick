import Foundation
import CoreGraphics

/// One click gesture the guide asks the user to try (taken from the current profile).
public struct GestureTask: Equatable, Identifiable {
    public let action: Action
    public let gesture: GestureID
    public let trigger: Trigger
    public var id: String { action.rawValue }
    public var binding: GestureBinding { GestureBinding(action, gesture, trigger) }
    public init(action: Action, gesture: GestureID, trigger: Trigger) { self.action = action; self.gesture = gesture; self.trigger = trigger }
}

public enum GuideStep: Int, CaseIterable {
    case camera, gaze, look, clicks, summary
    public var title: String { ["Camera", "Eyes", "Look", "Clicks", "Summary"][rawValue] }
}

public enum StepOutcome: String { case pending, passed, failed, skipped }

public struct GestureResult {
    public let task: GestureTask
    public var hits = 0
    public var peak: Float = 0
    public var outcome = StepOutcome.pending
    public var note = ""
}

/// The guided first run: camera check, gaze calibration (required), look-at-the-dots check, each click gesture, summary.
///
/// It is a pure state machine fed with camera frames and a clock (`feed`). It never touches the real cursor:
/// every piece of tracking it does runs through throw-away `Controller`s whose sink only counts.
/// All time limits are per action and at most 10 s.
public final class GuidedRun: ObservableObject {
    public enum Stage: Equatable { case camera, gazeIntro, gazeCal, dot(Int), gesture(Int), summary }
    public enum Phase: Equatable { case running, passed, failed }

    public static let cameraLimit = 10.0, dotLimit = 2.0, gestureLimit = 10.0, gazeIntroSeconds = 4.0
    /// A dot counts as looked at when the gaze dot stays within this many cm of it for `dotDwell` seconds.
    public static let reachCm = 4.5, dotDwell = 0.4
    public static let hitsNeeded = 3
    public static let dotNames = ["centre", "left", "right", "top", "bottom"]

    public let screen: CGRect
    public let widthCm: Double
    public private(set) var profile: Profile
    public private(set) var tasks: [GestureTask]
    public let dots: [CGPoint]
    public private(set) var order: [Stage] = []
    private var stepStarts: [Int] = []
    public private(set) var index = 0

    @Published public private(set) var stage: Stage = .camera
    @Published public private(set) var phase: Phase = .running
    @Published public private(set) var secondsLeft = 0.0
    @Published public private(set) var message = ""
    @Published public private(set) var hint = ""
    @Published public private(set) var faceVisible = false
    @Published public private(set) var pointerPos: CGPoint
    @Published public private(set) var dotProgress = 0.0
    @Published public private(set) var level: Float = 0
    @Published public private(set) var threshold: Float = 0.5
    @Published public private(set) var hits = 0
    @Published public private(set) var calibrator: Calibrator?
    /// Per dot: how far (cm) the closest 0.4 s of the gaze dot was from it.
    @Published public private(set) var dotErrorsCm: [Double?] = [Double?](repeating: nil, count: 5)
    @Published public private(set) var calibratingGesture = false
    @Published public private(set) var gaze: GazeCalibrator?
    @Published public private(set) var summaryPath = ""

    // results
    public private(set) var cameraOutcome = StepOutcome.pending
    public private(set) var faceWidth = 0.0
    public private(set) var dotOutcomes = [StepOutcome](repeating: .pending, count: 5)
    public private(set) var jitter: (x: Double, y: Double)?
    public private(set) var gestureResults: [GestureResult]
    public private(set) var gazeOutcome = StepOutcome.pending
    public private(set) var gazeErrorCm: Double?
    public private(set) var gazeNote = ""
    public private(set) var gazeEstimator: GazeEstimator?
    public private(set) var misfires: [String: Int] = [:]
    public private(set) var profileChanged = false
    /// Called once when the summary stage is entered (the app writes the file and adopts the calibrations there).
    public var onSummary: (() -> Void)?
    public let startedAt = Date()
    /// Shown in the summary header (the demo mode sets it so a fake run is never mistaken for a real one).
    public var label = ""

    private var allowAuto = true
    private var stageStart: Double?
    private var advanceAt: Double?
    private var restartAt: Double?
    private var steadySince: Double?, noFaceSince: Double?, lastPose: (Double, Float, Float)?
    private var faceSeen = false
    private var gp: GazePointer?                // the same smoothing the real cursor uses, but it only draws a dot here
    private var inSince: Double?
    private var dwell: [CGPoint] = []
    private var errWindow: [(Double, Double)] = []
    private var bestErr = Double.greatestFiniteMagnitude
    private var dotJitters: [(Double, Double)] = []
    private var gc: Controller?                 // one gesture
    private var peak: Float = 0
    private var onSince: Double?, counted = false
    private var misfire: Controller?
    private var fpsSamples: [Double] = [], msSamples: [Double] = []

    public init(profile: Profile, screen: CGRect, widthCm: Double = 30) {
        self.profile = profile; self.screen = screen; self.widthCm = widthCm
        tasks = GuidedRun.tasks(for: profile)
        gestureResults = tasks.map { GestureResult(task: $0) }
        func pt(_ fx: Double, _ fy: Double) -> CGPoint { CGPoint(x: screen.minX + screen.width * fx, y: screen.minY + screen.height * fy) }
        dots = [pt(0.5, 0.5), pt(0.08, 0.5), pt(0.92, 0.5), pt(0.5, 0.15), pt(0.5, 0.82)]
        pointerPos = CGPoint(x: screen.midX, y: screen.midY)
        var o: [Stage] = [.camera, .gazeIntro, .gazeCal]
        o += (0..<5).map { Stage.dot($0) }
        o += tasks.indices.map { Stage.gesture($0) }
        o += [.summary]
        order = o
        stepStarts = [0, o.firstIndex(of: .gazeIntro)!, o.firstIndex(of: .dot(0))!]
            + tasks.indices.map { i in o.firstIndex(of: .gesture(i))! }
            + [o.firstIndex(of: .summary)!]
        enter(0, forward: true)
    }

    /// The click gestures to try: left, right, double, scroll and pause as the profile has them bound.
    public static func tasks(for p: Profile) -> [GestureTask] {
        var out: [GestureTask] = []
        for a in [Action.leftClick, .rightClick, .doubleClick, .scrollDown, .scrollUp, .pauseToggle] {
            guard let b = p.binding(for: a) else { continue }
            if a == .scrollUp && out.contains(where: { $0.action == .scrollDown }) { continue }
            out.append(GestureTask(action: a, gesture: b.gesture, trigger: b.trigger))
        }
        return out
    }

    // MARK: public state helpers
    public var visibleStep: GuideStep {
        switch stage {
        case .camera: .camera
        case .gazeIntro, .gazeCal: .gaze
        case .dot: .look
        case .gesture: .clicks
        case .summary: .summary
        }
    }
    public func outcome(of step: GuideStep) -> StepOutcome {
        switch step {
        case .camera: return cameraOutcome
        case .gaze: return gazeOutcome
        case .look: return Self.combine(dotOutcomes)
        case .clicks: return gestureResults.isEmpty ? .skipped : Self.combine(gestureResults.map { $0.outcome })
        case .summary: return stage == .summary ? .passed : .pending
        }
    }
    static func combine(_ o: [StepOutcome]) -> StepOutcome {
        if o.allSatisfy({ $0 == .pending }) { return .pending }
        if o.contains(.pending) { return .pending }
        if o.allSatisfy({ $0 == .skipped }) { return .skipped }
        return o.contains(.failed) ? .failed : .passed
    }
    public var currentTask: GestureTask? { if case .gesture(let i) = stage { return tasks[i] }; return nil }
    public var currentGestureIndex: Int? { if case .gesture(let i) = stage { return i }; return nil }
    public var currentDot: Int? { if case .dot(let k) = stage { return k }; return nil }
    public func stageElapsed(at now: Double) -> Double { stageStart.map { now - $0 } ?? 0 }
    public var canGoBack: Bool { stepStarts.contains { $0 < stepStart(containing: index) } }

    // MARK: navigation
    private func stepStart(containing i: Int) -> Int { stepStarts.last { $0 <= i } ?? 0 }

    public func next() { advance(auto: false) }
    private func advance(auto: Bool) {
        guard index + 1 < order.count else { return }
        enter(index + 1, forward: true)
    }
    public func back() {
        let cur = stepStart(containing: index)
        if let prev = stepStarts.last(where: { $0 < cur }) { enter(prev, forward: false) }
    }
    /// Skip the whole current step.
    public func skip() {
        switch stage {
        case .camera: cameraOutcome = .skipped
        case .dot: for k in 0..<5 where dotOutcomes[k] != .passed { dotOutcomes[k] = .skipped }
        case .gesture(let i): gestureResults[i].outcome = .skipped
        case .gazeIntro, .gazeCal, .summary: return     // the eye calibration is required: no skipping
        }
        let next = stepStarts.first { $0 > index } ?? order.count - 1
        enter(next, forward: true)
    }
    /// Run the current step again from its start.
    public func retry() { enter(stepStart(containing: index), forward: true) }

    /// For a failed gesture: measure this gesture with the existing per-gesture calibration, then try again.
    public func calibrateGesture() {
        guard case .gesture(let i) = stage, !Catalog.spec(tasks[i].gesture).isPoseEvent else { return }
        calibrator = Calibrator(kind: .gesture(tasks[i].gesture), profile: profile, screen: screen)
        calibratingGesture = true; phase = .running; advanceAt = nil
        stageStart = nil
        message = calibrator!.prompt; hint = ""
        secondsLeft = 10
    }

    // MARK: entering a stage
    private func enter(_ i: Int, forward: Bool) {
        index = i; stage = order[i]; phase = .running
        stageStart = nil; advanceAt = nil; restartAt = nil; allowAuto = forward
        hint = ""; hits = 0; level = 0; dotProgress = 0; calibrator = nil; calibratingGesture = false; gaze = nil
        steadySince = nil; noFaceSince = nil; lastPose = nil; inSince = nil; peak = 0; onSince = nil; counted = false
        switch stage {
        case .camera:
            cameraOutcome = .pending; faceSeen = false
            message = "Look at the screen. I am checking that I can see your face."
            secondsLeft = Self.cameraLimit
            makeMisfire()
        case .dot(let k):
            if k == 0 { dotOutcomes = [StepOutcome](repeating: .pending, count: 5); dotErrorsCm = [Double?](repeating: nil, count: 5); dotJitters = []; jitter = nil; gp = nil; makeMisfire() }
            dotOutcomes[k] = .pending; dotErrorsCm[k] = nil
            if gp == nil, let e = gazeEstimator ?? gazeCalibratedElsewhere { gp = GazePointer(estimator: e) }
            errWindow = []; bestErr = .greatestFiniteMagnitude
            message = "Look at the dot. Keep your head wherever is comfortable."
            secondsLeft = Self.dotLimit
            if k == 0 { pointerPos = CGPoint(x: screen.midX, y: screen.midY) }
        case .gesture(let g):
            startGesture(g)
        case .gazeIntro:
            gazeOutcome = .pending
            message = "Next I learn where you look: follow each dot with your eyes."
            secondsLeft = Self.gazeIntroSeconds
            makeMisfire()
        case .gazeCal:
            gazeOutcome = .pending
            let c = GazeCalibrator(screen: CGRect(origin: .zero, size: screen.size), screenWidthCm: widthCm)
            gaze = c; message = c.prompt
            makeMisfire()
        case .summary:
            summaryPath = ""
            onSummary?()
        }
    }

    private func makeMisfire() {
        let c = Controller(profile: profile, sink: CountingSink(), bounds: screen)
        c.onAction = { [weak self] a, g in self?.misfires["\(a.title) via \(Catalog.spec(g).title)", default: 0] += 1 }
        misfire = c
    }

    private func startGesture(_ g: Int) {
        let t = tasks[g]
        hits = 0; peak = 0; onSince = nil; counted = false
        gestureResults[g].hits = 0; gestureResults[g].peak = 0; gestureResults[g].outcome = .pending; gestureResults[g].note = ""
        var p = profile; p.bindings = [t.binding]
        let c = Controller(profile: p, sink: CountingSink(), bounds: screen)
        c.onAction = { [weak self] _, _ in guard let self, self.phase == .running else { return }; self.hits += 1 }
        gc = c
        threshold = profile.tuning(t.gesture).onThreshold ?? Sensitivity.normal.onThreshold
        message = GuideText.instruction(t)
        secondsLeft = Self.gestureLimit
    }

    // MARK: per frame
    /// Feed every camera frame (`nil` = no face) with its timestamp in seconds. `fps` / `engineMs` are optional performance readings.
    public func feed(_ f: FaceFrame?, now: Double, fps: Double = 0, engineMs: Double = 0) {
        if stageStart == nil { stageStart = now }
        let el = now - stageStart!
        if faceVisible != (f != nil) { faceVisible = f != nil }
        if fps > 0, stage != .summary { fpsSamples.append(fps); if engineMs > 0 { msSamples.append(engineMs) } }
        if let r = restartAt, now >= r { restartAt = nil; if case .gesture(let g) = stage { startGesture(g); stageStart = now } ; return }
        if restartAt != nil { return }    // showing "Calibrated, trying again" for a moment
        switch stage {
        case .camera: feedMisfire(f, now); tickCamera(f, now, el)
        case .dot(let k): feedMisfire(f, now); tickDot(k, f, now, el)
        case .gesture(let g): tickGesture(g, f, now, el)
        case .summary: break
        case .gazeIntro:
            feedMisfire(f, now)
            secondsLeft = max(0, Self.gazeIntroSeconds - el)
            if el >= Self.gazeIntroSeconds, allowAuto { advance(auto: true) }
        case .gazeCal: feedMisfire(f, now); tickGaze(f, now)
        }
        if let a = advanceAt, now >= a { advanceAt = nil; if allowAuto { advance(auto: true) } }
    }

    private func feedMisfire(_ f: FaceFrame?, _ now: Double) {
        guard let m = misfire else { return }
        m.process(f, now: now)
        if f != nil, m.snapshot().autoPaused { m.setPaused(false, toast: false) }
    }

    static func faceWidth(_ f: FaceFrame) -> Double {
        guard f.landmarks.count > 100 else { return 0 }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for p in f.landmarks { lo = min(lo, p.x); hi = max(hi, p.x) }
        return Double(hi - lo)
    }

    private func finish(_ ok: Bool, _ msg: String, now: Double, autoAfter: Double?) {
        phase = ok ? .passed : .failed; message = msg
        if let a = autoAfter { advanceAt = now + a }
    }

    private func tickCamera(_ f: FaceFrame?, _ now: Double, _ el: Double) {
        guard phase == .running else { return }
        secondsLeft = max(0, Self.cameraLimit - el)
        if let f {
            noFaceSince = nil; faceSeen = true
            faceWidth = Self.faceWidth(f)
            var speed = 0.0
            if let l = lastPose, now > l.0 { speed = hypot(Double(f.yaw - l.1), Double(f.pitch - l.2)) / (now - l.0) }
            lastPose = (now, f.yaw, f.pitch)
            let small = faceWidth > 0 && faceWidth < 0.16, big = faceWidth > 0.85, moving = speed > 40
            hint = small ? "Move a bit closer to the screen." : big ? "Move back a little." : moving ? "Hold your head still for a moment." : ""
            if small || big || moving { steadySince = nil } else if steadySince == nil { steadySince = now }
            if let s = steadySince, now - s >= 1.5 {
                cameraOutcome = .passed
                finish(true, "I can see your face.", now: now, autoAfter: 1.2)
                return
            }
        } else {
            lastPose = nil; steadySince = nil
            if noFaceSince == nil { noFaceSince = now }
            if now - noFaceSince! > 0.8 {
                hint = "I can't see your face. Face the camera, put light on your face (not behind you) and sit about an arm's length away."
            }
        }
        if el >= Self.cameraLimit {
            cameraOutcome = .failed
            let why = !faceSeen ? "No face found in 10 seconds. Light on your face, an arm's length from the screen." : hint.isEmpty ? "The face never stayed steady for 1.5 s." : hint
            finish(false, why, now: now, autoAfter: nil)
        }
    }

    /// Another estimator the app already has (loaded from disk) can be handed in, so the dots can be checked without recalibrating.
    public var gazeCalibratedElsewhere: GazeEstimator?

    private func tickDot(_ k: Int, _ f: FaceFrame?, _ now: Double, _ el: Double) {
        guard phase == .running else { return }
        secondsLeft = max(0, Self.dotLimit - el)
        guard let gp else {
            dotOutcomes[k] = .skipped
            finish(false, "No gaze calibration yet, so I cannot check where you look.", now: now, autoAfter: 0.3)
            return
        }
        let cmPerPx = widthCm / Double(screen.width)
        if let f {
            let closed = max(f[.eyeBlinkLeft], f[.eyeBlinkRight]) > 0.4
            if let p = gp.update(f, now: now, eyesClosed: closed) { pointerPos = p }
        }
        let err = hypot(Double(pointerPos.x - dots[k].x), Double(pointerPos.y - dots[k].y)) * cmPerPx
        // the best 0.3 s window (median error) is this dot's error: it ignores the time the eyes were still travelling
        errWindow.append((now, err)); errWindow.removeAll { now - $0.0 > 0.3 }
        if errWindow.count >= 5, now - errWindow[0].0 >= 0.25 {
            let m = errWindow.map { $0.1 }.sorted()[errWindow.count / 2]
            if el > 0.3 { bestErr = min(bestErr, m) }
        }
        let need = Self.dotDwell
        if err < Self.reachCm, f != nil {
            if inSince == nil { inSince = now; dwell = [] }
            dwell.append(pointerPos)
            dotProgress = min(1, (now - inSince!) / need)
            if now - inSince! >= need {
                dotOutcomes[k] = .passed
                dotErrorsCm[k] = min(bestErr, err)
                if dwell.count > 3 {
                    dotJitters.append((Double(dwell.map { $0.x }.max()! - dwell.map { $0.x }.min()!), Double(dwell.map { $0.y }.max()! - dwell.map { $0.y }.min()!)))
                    jitter = (dotJitters.map { $0.0 }.reduce(0, +) / Double(dotJitters.count), dotJitters.map { $0.1 }.reduce(0, +) / Double(dotJitters.count))
                }
                finish(true, "Got it.", now: now, autoAfter: 0.3)
                return
            }
        } else { inSince = nil; dotProgress = 0 }
        if el >= Self.dotLimit {
            dotOutcomes[k] = .failed
            dotErrorsCm[k] = bestErr < .greatestFiniteMagnitude ? bestErr : err
            finish(false, String(format: "Missed: the closest I got was %.1f cm.", dotErrorsCm[k]!), now: now, autoAfter: 0.3)
        }
    }

    private func tickGesture(_ g: Int, _ f: FaceFrame?, _ now: Double, _ el: Double) {
        if calibratingGesture, let c = calibrator {
            c.feed(f, now: now)
            secondsLeft = max(0, 10 - el)
            if !c.finished { message = c.prompt; return }
            calibratingGesture = false
            if c.failed {
                message = c.result; phase = .failed
            } else {
                profile = c.apply(to: profile); profileChanged = true
                message = c.result + " Trying again…"
                restartAt = now + 1.6
            }
            return
        }
        guard phase == .running, let c = gc else { return }
        let t = tasks[g]
        c.process(f, now: now)
        let st = c.snapshot()
        if f != nil, st.autoPaused { c.setPaused(false, toast: false) }
        level = st.levels[t.gesture] ?? 0
        peak = max(peak, level)
        if t.trigger == .continuous {
            if st.active.contains(t.gesture) {
                if onSince == nil { onSince = now }
                if !counted, now - onSince! >= 0.3 { hits += 1; counted = true }
            } else { onSince = nil; counted = false }
        }
        secondsLeft = max(0, Self.gestureLimit - el)
        gestureResults[g].hits = hits; gestureResults[g].peak = peak
        if hits >= Self.hitsNeeded {
            gestureResults[g].outcome = .passed
            finish(true, "Three out of three.", now: now, autoAfter: 0.9)
        } else if el >= Self.gestureLimit {
            gestureResults[g].outcome = .failed
            let pct = Int(peak * 100), line = Int(threshold * 100)
            let note = peak < threshold
                ? "Only \(hits) of 3. The meter peaked at \(pct)%, below the \(line)% line: make the face bigger, or press Calibrate this gesture."
                : "Only \(hits) of 3 although the meter reached \(pct)%: try holding it a little longer, or release between tries."
            gestureResults[g].note = note
            finish(false, note, now: now, autoAfter: nil)
        }
    }

    private func tickGaze(_ f: FaceFrame?, _ now: Double) {
        guard phase == .running, let c = gaze else { return }
        c.feed(f, now: now)
        message = c.prompt
        secondsLeft = 0
        guard c.finished else { return }
        gazeNote = c.result
        if c.failed {
            gazeOutcome = .failed
            finish(false, c.result, now: now, autoAfter: nil)
        } else {
            gazeOutcome = .passed; gazeErrorCm = c.meanErrorCm; gazeEstimator = c.estimator
            finish(true, c.result, now: now, autoAfter: 2.0)
        }
    }

    // MARK: summary
    public struct SummaryLine: Identifiable { public let id = UUID(); public let mark: String; public let text: String }

    private static func median(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.sorted()[a.count / 2] }
    private static func p95(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.sorted()[min(a.count - 1, Int(Double(a.count - 1) * 0.95))] }
    private func mark(_ o: StepOutcome) -> String { o == .passed ? "✓" : o == .failed ? "✗" : "–" }

    public func summaryLines() -> [SummaryLine] {
        var L: [SummaryLine] = []
        func add(_ m: String, _ t: String) { L.append(SummaryLine(mark: m, text: t)) }
        // camera
        var cam = cameraOutcome == .passed ? "Camera: I could see a steady face" : cameraOutcome == .skipped ? "Camera check skipped" : "Camera: no steady face found"
        if faceWidth > 0 { cam += String(format: " (face fills %.0f%% of the picture width)", faceWidth * 100) }
        if let f = Self.median(fpsSamples) { cam += String(format: "; %.0f fps", f) }
        if let m = Self.median(msSamples) { cam += String(format: ", engine %.1f ms (p95 %.1f)", m, Self.p95(msSamples) ?? m) }
        add(mark(cameraOutcome), cam)
        // gaze calibration
        if gazeOutcome == .passed, let cm = gazeErrorCm {
            add("✓", String(format: "Eyes: calibrated, mean error %.1f cm. %@", cm, cm < 4 ? "Good enough: the cursor follows where you look." : "Rough: the cursor lands near where you look."))
        } else if gazeOutcome == .failed { add("✗", "Eyes: \(gazeNote)") } else { add("✗", "Eyes: not calibrated, so the cursor cannot follow your gaze yet") }
        // look-at-the-dots check
        let lo = outcome(of: .look)
        let reached = dotOutcomes.filter { $0 == .passed }.count
        let errs = dotErrorsCm.compactMap { $0 }
        var look = lo == .skipped ? "Look-at-the-dots check skipped" : "Look check: reached \(reached) of 5 dots"
        if !errs.isEmpty { look += String(format: ", error %.1f cm on average (worst %.1f cm)", errs.reduce(0, +) / Double(errs.count), errs.max()!) }
        if let j = jitter { look += String(format: "; steady-gaze jitter %.0f px across, %.0f px up/down", j.x, j.y) }
        add(mark(lo == .passed && reached < 5 ? .failed : lo), look)
        // gestures
        for r in gestureResults {
            let spec = Catalog.spec(r.task.gesture)
            var s = "\(r.task.action.title): \(spec.title) (\(r.task.trigger.title)), "
            s += r.outcome == .skipped ? "skipped" : "\(r.hits) of 3 times, strongest \(Int(r.peak * 100))%"
            if r.outcome == .failed, !r.note.isEmpty { s += ". " + r.note }
            add(mark(r.outcome), s)
        }
        // misfires
        let total = misfires.values.reduce(0, +)
        if cameraOutcome == .skipped && outcome(of: .look) == .skipped { add("·", "Misfires: not measured (those steps were skipped)") }
        else if total == 0 { add("✓", "Misfires while you only looked around: none") }
        else { add("✗", "Misfires while you only looked around: " + misfires.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")) }
        return L
    }

    public func summaryText() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "HeadClick guided run, \(df.string(from: startedAt))\n" + (label.isEmpty ? "" : "*** \(label) ***\n") + "Profile: \(profile.name)\n\n"
        for l in summaryLines() { s += "\(l.mark) \(l.text)\n" }
        s += "\nCursor control was OFF during the whole guide (the guide draws its own pointer dot).\n"
        return s
    }

    @discardableResult
    public func writeSummary(to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try summaryText().write(to: url, atomically: true, encoding: .utf8)
            summaryPath = url.path
            return true
        } catch { return false }
    }
}

/// Words and pictures for the guide.
public enum GuideText {
    public static func emoji(_ g: GestureID) -> String {
        switch g {
        case .mouthOpen: "😮"
        case .smile: "😀"
        case .pucker: "😗"
        case .browRaise: "🤨"
        case .browFurrow: "😠"
        case .winkLeft, .winkRight: "😉"
        case .doubleBlink: "😉"
        case .longBlink: "😌"
        case .tiltLeft, .tiltRight: "🙂"
        case .cheekPuff: "😤"
        case .noseScrunch: "😖"
        case .headNod: "🙂"
        case .headShake: "🙂"
        default: "🙂"
        }
    }

    /// Degrees to rotate the emoji for head tilts.
    public static func emojiRotation(_ g: GestureID) -> Double { g == .tiltRight ? 22 : g == .tiltLeft ? -22 : 0 }

    public static func instruction(_ t: GestureTask) -> String {
        let hold = t.trigger == .long
        switch t.gesture {
        case .mouthOpen: return "Open your mouth wide, then close it."
        case .pucker: return "Pucker your lips like a kiss, then relax."
        case .browRaise: return "Raise both eyebrows high, then relax."
        case .browFurrow: return "Frown: pull your eyebrows down, then relax."
        case .smile: return "Smile widely, then relax."
        case .tiltRight: return "Tilt your head toward your right shoulder and hold it, then straighten up."
        case .tiltLeft: return "Tilt your head toward your left shoulder and hold it, then straighten up."
        case .longBlink: return hold ? "Close both eyes and keep them closed for 1.2 seconds, then open." : "Close both eyes for a moment, then open."
        case .doubleBlink: return "Blink twice, quickly."
        case .winkLeft: return "Wink with your left eye only."
        case .winkRight: return "Wink with your right eye only."
        case .headNod: return "Nod your head: yes, yes."
        case .headShake: return "Shake your head: no, no."
        default: return "Make this face: \(Catalog.spec(t.gesture).title), then relax."
        }
    }
}
