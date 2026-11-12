import Foundation
import CoreGraphics
@testable import HeadClickCore

final class FakeSink: CursorSink {
    enum Ev: Equatable { case move(CGPoint, Bool), down(MouseButton, Int), up(MouseButton, Int), scroll(Double) }
    var events: [Ev] = []
    var currentPosition = CGPoint(x: 720, y: 450)
    func move(to p: CGPoint, dragging: Bool) { currentPosition = p; events.append(.move(p, dragging)) }
    func button(_ b: MouseButton, down: Bool, at p: CGPoint, clickState: Int) {
        currentPosition = p; events.append(down ? .down(b, clickState) : .up(b, clickState))
    }
    func scroll(pixelsY: Double) { events.append(.scroll(pixelsY)) }
    var downs: [(MouseButton, Int)] { events.compactMap { if case .down(let b, let c) = $0 { return (b, c) }; return nil } }
    var leftClicks: Int { downs.filter { $0.0 == .left && $0.1 == 1 }.count }
    var rightClicks: Int { downs.filter { $0.0 == .right }.count }
    var doubleClicks: Int { downs.filter { $0.0 == .left && $0.1 == 2 }.count }
    var scrolls: [Double] { events.compactMap { if case .scroll(let d) = $0 { return d }; return nil } }
    var ups: Int { events.filter { if case .up = $0 { return true }; return false }.count }
}

let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
let dt = 1.0 / 30

/// Drives a controller with a synthetic frame stream: `make(t)` builds the frame at time t.
@discardableResult
func drive(_ c: Controller, from t0: Double = 0, seconds: Double, make: (Double) -> FaceFrame?) -> Double {
    var t = t0
    while t < t0 + seconds { c.process(make(t - t0), now: t); t += dt }
    return t
}

func frame(_ t: Double, yaw: Float = 0, pitch: Float = 0, roll: Float = 0, _ b: [Blend: Float] = [:]) -> FaceFrame {
    FaceFrame(time: t, yaw: yaw, pitch: pitch, roll: roll, blend: b)
}

func makeController(_ p: Profile = .quietDesk) -> (Controller, FakeSink) {
    let s = FakeSink()
    let c = Controller(profile: p, sink: s, bounds: screen)
    return (c, s)
}

/// 1 inside [start, start+len), else 0.
func pulse(_ t: Double, _ start: Double, _ len: Double) -> Float { (t >= start && t < start + len) ? 1 : 0 }
