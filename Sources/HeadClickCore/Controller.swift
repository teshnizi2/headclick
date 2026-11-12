import Foundation
import CoreGraphics

/// Live state for the UI (debug window, settings meters, overlay).
public struct ControllerStatus {
    public var levels: [GestureID: Float] = [:]       // normalised 0...1 for every signal gesture
    public var active: Set<GestureID> = []              // trackers currently "on"
    public var paused = false
    public var autoPaused = false
    public var talking = false
    public var faceFound = false
    public var dragging = false
    public var arming = false
    public var position = CGPoint.zero
    public var yaw: Float = 0, pitch: Float = 0, roll: Float = 0
    public init() {}
}

/// Joins pose, gestures, profile and cursor: the whole "face -> mouse" logic, free of camera and UI so tests can drive it.
public final class Controller {
    public private(set) var profile: Profile
    public let sink: CursorSink
    public let pointer: HeadPointer
    public var bounds: CGRect { didSet { pointer.bounds = bounds } }
    public private(set) var status = ControllerStatus()
    /// Toast text for the overlay ("Pucker → Right click").
    public var onToast: ((String) -> Void)?
    /// Called after any action fires: (action, gesture).
    public var onAction: ((Action, GestureID) -> Void)?
    /// Optional hook: gaze jump target in screen points, given the latest frame.
    public var gaze: GazeJump?

    public private(set) var paused = false
    private var autoPaused = false
    private var trackers: [GestureID: SignalTracker] = [:]
    private let talk = TalkGuard()
    private let poseEvents = PoseEventDetector()
    private var history: [(Double, CGPoint)] = []
    private var dragging = false
    private var lastClick = -10.0
    private var armSince: Double?
    private var faceLostSince: Double?
    private var lastT = 0.0
    private var lastYawPitch: (Float, Float)?
    private var angularSpeed: Float = 0
    private var swapIndex: [Int] = []
    private let lock = NSRecursiveLock()

    public init(profile: Profile, sink: CursorSink, bounds: CGRect, startPaused: Bool = false) {
        paused = startPaused
        self.profile = profile; self.sink = sink; self.bounds = bounds
        pointer = HeadPointer(bounds: bounds, position: sink.currentPosition)
        pointer.settings = profile.pointer
        swapIndex = Controller.makeSwapIndex()
        rebuild()
    }

    static func makeSwapIndex() -> [Int] {
        Blend.allCases.map { b in
            let n = b.modelName
            var other = n
            if n.hasSuffix("Left") { other = String(n.dropLast(4)) + "Right" }
            else if n.hasSuffix("Right") { other = String(n.dropLast(5)) + "Left" }
            return Blend.byName[other]?.rawValue ?? b.rawValue
        }
    }

    public func snapshot() -> ControllerStatus { lock.lock(); defer { lock.unlock() }; return status }

    public func setProfile(_ p: Profile) {
        lock.lock(); defer { lock.unlock() }
        profile = p
        pointer.settings = p.pointer
        rebuild()
    }

    private func rebuild() {
        var t: [GestureID: SignalTracker] = [:]
        for b in profile.bindings where !Catalog.spec(b.gesture).isPoseEvent {
            let tr = trackers[b.gesture] ?? SignalTracker(spec: Catalog.spec(b.gesture))
            t[b.gesture] = tr
        }
        for (g, tr) in t {
            tr.onThreshold = profile.tuning(g).onThreshold ?? Sensitivity.normal.onThreshold
            tr.hasHold = profile.bindings.contains { $0.gesture == g && $0.trigger == .hold }
            tr.hasLong = profile.bindings.contains { $0.gesture == g && $0.trigger == .long }
        }
        trackers = t
    }

    public func setPaused(_ p: Bool, toast: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard p != paused else { return }
        paused = p; autoPaused = false
        if p { releaseDrag() }
        for tr in trackers.values { tr.reset() }
        pointer.resetFilters()
        if toast { onToast?(p ? "Paused" : "Tracking") }
    }

    public func recenter() {
        lock.lock(); defer { lock.unlock() }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        pointer.warp(to: c); sink.move(to: c, dragging: dragging)
    }

    // MARK: normalisation
    func normalised(_ g: GestureID, _ f: FaceFrame) -> Float {
        let spec = Catalog.spec(g)
        let t = profile.tuning(g)
        let n = t.neutral ?? spec.neutral, p = t.peak ?? spec.peak
        return max(0, min(1, (spec.signal(f) - n) / max(1e-3, p - n)))
    }

    func positionAt(_ time: Double) -> CGPoint? {
        guard let first = history.first, time >= first.0 else { return history.first?.1 }
        return history.last(where: { $0.0 <= time })?.1
    }

    // MARK: per frame
    /// Feed one camera frame (`nil` = no face found).
    public func process(_ frame: FaceFrame?, now: Double) {
        lock.lock(); defer { lock.unlock() }
        var st = ControllerStatus()
        st.paused = paused || autoPaused; st.autoPaused = autoPaused; st.dragging = dragging
        defer { st.position = pointer.position; status = st }

        guard var f = frame else {
            st.faceFound = false
            if faceLostSince == nil { faceLostSince = now }
            // Safety: losing the face for more than 1 s is a real pause; the user resumes explicitly.
            if now - faceLostSince! > 1, !paused { paused = true; autoPaused = true; releaseDrag(); pointer.resetFilters(); onToast?("Face lost: paused") }
            for tr in trackers.values { tr.reset() }
            poseEvents.reset(); lastYawPitch = nil
            return
        }
        faceLostSince = nil
        st.paused = paused
        st.faceFound = true
        if profile.swapLeftRight { let o = f.blend; for i in 0..<o.count { f.blend[i] = o[swapIndex[i]] } }
        st.yaw = f.yaw; st.pitch = f.pitch; st.roll = f.roll

        // angular speed (deg/s) for the "head moving fast" guard
        if let l = lastYawPitch, now > lastT {
            let d = ((f.yaw - l.0) * (f.yaw - l.0) + (f.pitch - l.1) * (f.pitch - l.1)).squareRoot() / Float(now - lastT)
            angularSpeed = angularSpeed * 0.6 + d * 0.4
        }
        lastYawPitch = (f.yaw, f.pitch); lastT = now

        // levels for every signal gesture (settings meters)
        for g in GestureID.allCases where !Catalog.spec(g).isPoseEvent { st.levels[g] = normalised(g, f) }

        talk.update(t: now, jawOpen: f[.jawOpen])
        let talking = profile.talkGuard && talk.isTalking(now)
        st.talking = talking
        let fast = angularSpeed > 60

        // coupled gestures: the weaker one is ignored while both are active
        var suppressed: Set<GestureID> = []
        for (a, b) in Catalog.coupled {
            guard let la = st.levels[a], let lb = st.levels[b], la > 0.3, lb > 0.3 else { continue }
            suppressed.insert(la >= lb ? b : a)
        }

        // trackers
        var anyArming = false, anyHolding = false
        let pauseGestures = Set(profile.bindings.filter { $0.action == .pauseToggle }.map { $0.gesture })
        var fired: [(GestureID, GestureEvent, GestureBinding)] = []
        for (g, tr) in trackers {
            let spec = tr.spec
            var allowed = !suppressed.contains(g)
            if spec.talkSensitive && talking { allowed = false }
            if fast && spec.group != .head { allowed = false }
            if paused || autoPaused { allowed = allowed && pauseGestures.contains(g) }
            let evs = tr.update(t: now, level: st.levels[g] ?? 0, allowed: allowed)
            if tr.arming && !(paused || autoPaused) { anyArming = true }
            if tr.holding { anyHolding = true }
            if tr.isOn { st.active.insert(g) }
            for e in evs {
                let trig: Trigger = { switch e { case .tap: .tap; case .holdStart, .holdEnd: .hold; case .long: .long } }()
                for b in profile.bindings where b.gesture == g && b.trigger == trig { fired.append((g, e, b)) }
            }
        }
        st.arming = anyArming

        // pose events (nod / shake)
        let poseBound = profile.bindings.contains { Catalog.spec($0.gesture).isPoseEvent }
        if poseBound {
            if let (g, start) = poseEvents.update(t: now, yaw: f.yaw, pitch: f.pitch) {
                for b in profile.bindings where b.gesture == g && b.trigger == .tap {
                    if paused || autoPaused { if b.action != .pauseToggle { continue } }
                    armSince = start
                    fired.append((g, .tap, b))
                }
            }
        }

        // arming: remember when the gesture began so the click can land where the cursor was
        if anyArming { if armSince == nil { armSince = now } } else if fired.isEmpty { armSince = nil }

        // pointer
        let frozen = (anyArming && !anyHolding) || paused || autoPaused
        if !(paused || autoPaused) {
            if let g = gaze, let target = g.target(frame: f, now: now, cursor: pointer.position), !frozen {
                pointer.warp(to: target)
                pointer.resetFilters()
            }
        }
        let before = pointer.position
        pointer.update(t: now, yaw: Double(f.yaw), pitch: Double(f.pitch), frozen: frozen)
        if pointer.position != before { sink.move(to: pointer.position, dragging: dragging) }
        history.append((now, pointer.position))
        history.removeAll { now - $0.0 > 1.0 }
        if !fired.isEmpty { st.position = pointer.position }

        // actions
        for (g, e, b) in fired { perform(b, event: e, gesture: g, now: now) }
        if !fired.isEmpty && !anyArming { armSince = nil }

        // continuous actions (scroll)
        if !(paused || autoPaused) {
            for b in profile.bindings where b.trigger == .continuous {
                guard let tr = trackers[b.gesture], tr.isOn else { continue }
                let on = tr.onThreshold
                let amount = max(0, (tr.level - on) / max(0.05, 1 - on))
                var px = Double(amount) * 900 / 30  // up to ~900 px/s at full tilt
                if b.action == .scrollDown { px = -px }
                if profile.pointer.invertScroll { px = -px }
                if abs(px) >= 1 { sink.scroll(pixelsY: px) }
            }
        }
        st.dragging = dragging; st.paused = paused || autoPaused
    }

    private func clickPosition() -> CGPoint {
        if let s = armSince, let p = positionAt(s - 0.12) { return p }
        return pointer.position
    }

    private func perform(_ b: GestureBinding, event: GestureEvent, gesture: GestureID, now: Double) {
        let name = Catalog.spec(gesture).title
        func toast(_ s: String) { onToast?("\(name) → \(s)") }
        switch b.action {
        case .drag:
            if event == .holdStart {
                let p = clickPosition()
                pointer.warp(to: p); sink.move(to: p, dragging: false)
                sink.button(.left, down: true, at: p, clickState: 1); dragging = true
                toast("Drag")
            } else if event == .holdEnd { releaseDrag() }
        case .pauseToggle:
            setPaused(!paused, toast: false); toast(paused ? "Pause" : "Resume")
        case .recenter:
            recenter(); toast("Recenter")
        case .scrollUp, .scrollDown:
            break
        case .leftClick, .rightClick, .doubleClick, .middleClick:
            guard now - lastClick > 0.25 else { return }
            lastClick = now
            let p = clickPosition()
            pointer.warp(to: p); sink.move(to: p, dragging: false)
            switch b.action {
            case .leftClick: sink.click(.left, at: p); toast("Left click")
            case .rightClick: sink.click(.right, at: p); toast("Right click")
            case .doubleClick: sink.click(.left, at: p, count: 2); toast("Double click")
            default: sink.click(.middle, at: p); toast("Middle click")
            }
        }
        onAction?(b.action, gesture)
    }

    private func releaseDrag() {
        guard dragging else { return }
        sink.button(.left, down: false, at: pointer.position, clickState: 1)
        dragging = false
    }
}

/// Gaze add-on (M7): proposes a cursor jump when the estimated gaze point is far from the cursor and stable.
public protocol GazeJump: AnyObject {
    func target(frame: FaceFrame, now: Double, cursor: CGPoint) -> CGPoint?
}
