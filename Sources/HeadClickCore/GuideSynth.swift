import Foundation
import CoreGraphics

/// A scripted, fake user for the guide: used by the unit tests and by the app's `--guide-demo` mode (screenshots without a face).
/// It looks at the screen like a person would: the head turns toward the current dot, and each click gesture is performed 3 times.
public final class GuideSynthUser {
    /// A real face frame (for the landmarks, so the mesh lines up with a real picture); blendshapes are zeroed.
    public var base: FaceFrame?
    /// Gesture indices the "user" cannot do (nothing happens), to show the failure screen.
    public var failTasks: Set<Int> = []
    /// Current head angles of the fake user, degrees.
    public var yaw = 0.0, pitch = 0.0

    public init(base: FaceFrame? = nil) { self.base = base }

    /// Landmarks of a centred face with the irises shifted by gx, gy in [-1, 1]. The face is 36% of the picture wide.
    public static func landmarks(gx: Double = 0, gy: Double = 0) -> [SIMD3<Float>] {
        var L = [SIMD3<Float>](repeating: SIMD3(0.5, 0.5, 0), count: 478)
        func set(_ i: Int, _ x: Float, _ y: Float) { L[i] = SIMD3(x, y, 0) }
        set(234, 0.32, 0.5); set(454, 0.68, 0.5); set(1, 0.5, 0.5)
        set(33, 0.38, 0.40); set(133, 0.46, 0.40); set(159, 0.42, 0.385); set(145, 0.42, 0.415)
        set(362, 0.54, 0.40); set(263, 0.62, 0.40); set(386, 0.58, 0.385); set(374, 0.58, 0.415)
        set(468, 0.42 + Float(gx) * 0.02, 0.40 + Float(gy) * 0.008)
        set(473, 0.58 + Float(gx) * 0.02, 0.40 + Float(gy) * 0.008)
        return L
    }

    /// Sets the gesture's signal to `level` (0 = rest, 1 = a full gesture at the catalog defaults).
    public static func apply(_ g: GestureID, level l: Float, to f: inout FaceFrame) {
        let spec = Catalog.spec(g)
        let v = spec.neutral + l * (spec.peak - spec.neutral)
        func both(_ a: Blend, _ b: Blend) { f[a] = v; f[b] = v }
        switch g {
        case .mouthOpen: f[.jawOpen] = v
        case .smile: both(.mouthSmileLeft, .mouthSmileRight)
        case .pucker: f[.mouthPucker] = v
        case .browRaise: f[.browInnerUp] = v; both(.browOuterUpLeft, .browOuterUpRight)
        case .browFurrow: both(.browDownLeft, .browDownRight)
        case .winkLeft: f[.eyeBlinkLeft] = v
        case .winkRight: f[.eyeBlinkRight] = v
        case .doubleBlink, .longBlink: both(.eyeBlinkLeft, .eyeBlinkRight)
        case .mouthLeft: f[.mouthLeft] = v
        case .mouthRight: f[.mouthRight] = v
        case .tiltLeft: f.roll = -v
        case .tiltRight: f.roll = v
        case .smirkLeft: f[.mouthSmileLeft] = v
        case .smirkRight: f[.mouthSmileRight] = v
        case .cheekPuff: f[.cheekPuff] = v
        case .noseScrunch: both(.noseSneerLeft, .noseSneerRight)
        case .jawLeft: f[.jawLeft] = v
        case .jawRight: f[.jawRight] = v
        case .lipsPressed: both(.mouthPressLeft, .mouthPressRight)
        case .headNod, .headShake: break
        }
    }

    /// How strongly the gesture is made `t` seconds into its step: three clean repetitions inside the 10 s limit.
    public static func pattern(_ task: GestureTask, t: Double) -> Float {
        if task.gesture == .doubleBlink {
            let u = (t - 0.6).truncatingRemainder(dividingBy: 2.0)
            return t >= 0.6 && (u < 0.12 || (u >= 0.3 && u < 0.42)) ? 1 : 0
        }
        let (on, period, start): (Double, Double, Double)
        switch task.trigger {
        case .long: (on, period, start) = (1.5, 2.4, 0.5)
        case .continuous: (on, period, start) = (1.0, 1.8, 0.6)
        case .hold: (on, period, start) = (1.0, 1.8, 0.6)
        case .tap: (on, period, start) = (0.5, 1.4, 0.6)
        }
        guard t >= start else { return 0 }
        return (t - start).truncatingRemainder(dividingBy: period) < on ? 1 : 0
    }

    /// The frame the fake user produces now, given what the guide is asking for (nil = no face).
    public func frame(for run: GuidedRun, now: Double) -> FaceFrame? {
        var f = base ?? FaceFrame()
        f.blend = [Float](repeating: 0, count: Blend.allCases.count)
        f.time = now
        if f.landmarks.isEmpty { f.landmarks = Self.landmarks() }
        let el = run.stageElapsed(at: now)
        var toYaw = 0.0, toPitch = 0.0, rate = 0.08
        var gazeTarget: CGPoint?
        switch run.stage {
        case .pointerCal:
            if let c = run.calibrator, c.stepNumber >= 2 {
                toYaw = 14 * sin(2 * .pi * c.progress * 1.5); toPitch = 8 * sin(2 * .pi * c.progress * 2.1 + 1); rate = 1
            }
        case .dot(let k):
            let s = run.profile.pointer
            let dx = Double(run.dots[k].x - run.pointerPos.x), dy = Double(run.dots[k].y - run.pointerPos.y)
            // Closed loop, like a person watching the cursor: turn toward the dot until the cursor is on it.
            if abs(dx) + abs(dy) > 20 {
                yaw += max(-0.5, min(0.5, 0.12 * dx / max(1, s.gainX))) * (s.invertX ? -1 : 1)
                pitch += max(-0.4, min(0.4, 0.12 * dy / max(1, s.gainY))) * (s.invertY ? -1 : 1)
            }
            toYaw = yaw; toPitch = pitch; rate = 1
        case .gesture(let g):
            if !failTasks.contains(g) { Self.apply(run.tasks[g].gesture, level: Self.pattern(run.tasks[g], t: el), to: &f) }
        case .gazeCal:
            if let t = run.gaze?.target { gazeTarget = t }
        default: break
        }
        if rate < 1 { yaw += (toYaw - yaw) * rate; pitch += (toPitch - pitch) * rate }
        else { yaw = toYaw; pitch = toPitch }
        f.yaw = Float(yaw); f.pitch = Float(pitch)
        if let t = gazeTarget {
            let w = Double(run.screen.width), h = Double(run.screen.height)
            f.landmarks = Self.landmarks(gx: (Double(t.x) - w / 2) / (0.486 * w), gy: (Double(t.y) - h / 2) / (0.478 * h))
            f.yaw = 0; f.pitch = 0
        }
        return f
    }
}
