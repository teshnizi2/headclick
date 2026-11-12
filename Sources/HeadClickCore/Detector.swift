import Foundation

public enum GestureEvent: Equatable { case tap, holdStart, holdEnd, long }

/// Turns a normalised 0...1 gesture level into tap / hold / long events with hysteresis and a refractory period.
public final class SignalTracker {
    public let spec: GestureSpec
    public var onThreshold: Float = 0.5
    public var offThreshold: Float { max(0.1, onThreshold - 0.2) }
    public var hasHold = false
    public var hasLong = false
    public var holdTime = 0.6
    public var longTime = 1.2
    public var refractory = 0.4

    public private(set) var isOn = false
    public private(set) var holding = false
    public private(set) var level: Float = 0
    /// True once the gesture starts (level above 0.25): used to freeze the pointer before the click lands.
    public private(set) var arming = false
    public private(set) var peak: Float = 0
    private var t0 = 0.0
    private var tapFired = false, longFired = false, suppressed = false
    private var lastFire = -10.0
    private var pendingTap: Double?

    public init(spec: GestureSpec) { self.spec = spec }

    public func reset() {
        isOn = false; holding = false; arming = false; tapFired = false; longFired = false; pendingTap = nil
    }

    /// Time the current episode began (for rewinding the cursor).
    public var onsetTime: Double { t0 }

    public func update(t: Double, level s: Float, allowed: Bool) -> [GestureEvent] {
        level = s
        var ev: [GestureEvent] = []
        if !allowed {
            if holding { ev.append(.holdEnd) }
            reset()
            return ev
        }
        if !isOn {
            if s >= onThreshold {
                isOn = true; t0 = t; holding = false; tapFired = false; longFired = false; peak = s
                suppressed = t - lastFire < refractory
            }
        } else if s < offThreshold {
            // release
            let dur = t - t0
            isOn = false
            if !suppressed {
                if holding { ev.append(.holdEnd); lastFire = t }
                else if !tapFired && !longFired && dur >= spec.minHold && dur <= spec.maxHold { if registerTap(t) { ev.append(.tap) } }
            }
            holding = false
        }
        if isOn {
            peak = max(peak, s)
            if !suppressed {
                let dur = t - t0
                if hasHold && !holding && !longFired && dur >= holdTime { holding = true; ev.append(.holdStart) }
                if hasLong && !longFired && !holding && dur >= longTime { longFired = true; lastFire = t; ev.append(.long) }
                if spec.earlyTap && !hasHold && !hasLong && !tapFired && dur >= spec.minHold {
                    tapFired = true
                    if registerTap(t) { ev.append(.tap) }
                }
            }
        }
        arming = isOn || s >= 0.25
        return ev
    }

    /// Single taps pass straight through; for the double pattern the second tap within 0.5 s fires.
    private func registerTap(_ t: Double) -> Bool {
        if spec.doublePattern {
            if let p = pendingTap, t - p <= 0.5 { pendingTap = nil; lastFire = t; return true }
            pendingTap = t
            return false
        }
        lastFire = t
        return true
    }
}

/// Counts fast back-and-forth movements of a value (degrees or blendshape level).
public final class SwingCounter {
    public struct Swing { public var tStart: Double; public var tEnd: Double; public var dir: Int }
    let amp: Float, rev: Float
    private var ready = false
    private var anchorV: Float = 0, anchorT = 0.0, extV: Float = 0, extT = 0.0, dir = 0, counted = false
    public private(set) var swings: [Swing] = []

    public init(amplitude: Float, reversal: Float) { amp = amplitude; rev = reversal }

    public func reset() { ready = false; swings.removeAll(); dir = 0 }

    @discardableResult
    public func update(t: Double, _ v: Float) -> Swing? {
        swings.removeAll { t - $0.tEnd > 3 }
        if !ready { ready = true; anchorV = v; anchorT = t; extV = v; extT = t; dir = 0; counted = false; return nil }
        if dir == 0 {
            if abs(v - anchorV) >= rev {
                dir = v > anchorV ? 1 : -1; extV = v; extT = t; counted = false
            } else { anchorV += (v - anchorV) * 0.1; anchorT = t; return nil }
        } else if (v - extV) * Float(dir) > 0 {
            extV = v; extT = t
        } else if (extV - v) * Float(dir) >= rev {
            anchorV = extV; anchorT = extT; dir = -dir; extV = v; extT = t; counted = false
        } else if t - extT > 0.5 {
            dir = 0; anchorV = v; anchorT = t; return nil
        }
        if !counted && abs(extV - anchorV) >= amp {
            counted = true
            let s = Swing(tStart: anchorT, tEnd: t, dir: dir)
            swings.append(s)
            return s
        }
        return nil
    }
}

/// Spots speech: the jaw opening and closing 4+ times in one second.
public final class TalkGuard {
    private let counter = SwingCounter(amplitude: 0.06, reversal: 0.02)
    public private(set) var talkingUntil = -1.0
    public init() {}
    public func isTalking(_ t: Double) -> Bool { t < talkingUntil }
    public func reset() { counter.reset(); talkingUntil = -1 }
    public func update(t: Double, jawOpen: Float) {
        if counter.update(t: t, jawOpen) != nil {
            let recent = counter.swings.filter { t - $0.tEnd <= 1.0 && $0.tEnd - $0.tStart <= 0.35 }
            if recent.count >= 4 { talkingUntil = t + 1.0 }
        }
    }
}

/// Nod and shake from head-pose history.
public final class PoseEventDetector {
    private let pitch = SwingCounter(amplitude: 6, reversal: 2)
    private let yaw = SwingCounter(amplitude: 7, reversal: 2)
    private var lastFire = -10.0
    public init() {}
    public func reset() { pitch.reset(); yaw.reset() }

    /// Returns the event and the time the movement began.
    public func update(t: Double, yaw y: Float, pitch p: Float) -> (GestureID, Double)? {
        let sp = pitch.update(t: t, p)
        let sy = yaw.update(t: t, y)
        guard t - lastFire > 0.8 else { return nil }
        if sp != nil {
            let s = pitch.swings
            if s.count >= 2, let b = s.last, let a = s.dropLast().last, a.dir == 1, b.dir == -1,
               b.tEnd - a.tStart <= 0.9, a.tEnd - a.tStart <= 0.4, b.tEnd - b.tStart <= 0.4, b.tStart - a.tEnd < 0.3 {
                lastFire = t; pitch.reset(); yaw.reset()
                return (.headNod, a.tStart)
            }
        }
        if sy != nil {
            let s = yaw.swings
            if s.count >= 3 {
                let l3 = Array(s.suffix(3))
                if l3[2].tEnd - l3[0].tStart <= 1.3, l3.allSatisfy({ $0.tEnd - $0.tStart <= 0.4 }) {
                    lastFire = t; pitch.reset(); yaw.reset()
                    return (.headShake, l3[0].tStart)
                }
            }
        }
        return nil
    }
}
