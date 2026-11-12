import XCTest
@testable import HeadClickCore

final class PointerTests: XCTestCase {
    func testJitterWithStillHeadUnder3px() {
        var rng = SystemRandomNumberGenerator()
        let (c, s) = makeController()
        var positions: [CGPoint] = []
        var t = 0.0
        while t < 5 {
            // sensor noise of 0.08 degrees sd (roughly +-0.2 deg peaks)
            func n() -> Float { Float.random(in: -0.16...0.16, using: &rng) }
            c.process(frame(t, yaw: 3 + n(), pitch: -2 + n()), now: t)
            positions.append(c.pointer.position)
            t += dt
        }
        let xs = positions.dropFirst(30).map { $0.x }, ys = positions.dropFirst(30).map { $0.y }
        let spread = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        XCTAssertLessThanOrEqual(spread, 3.0, "still head: cursor wanders \(spread) px")
        _ = s
    }

    func testReachesAllCornersWithinComfortableHeadRange() {
        var p = Profile.quietDesk
        // calibration-like gain: +-14 degrees of yaw spans the screen width, +-9 degrees of pitch the height
        p.pointer.gainX = 1440.0 / 28; p.pointer.gainY = 900.0 / 18
        let (c, _) = makeController(p)
        func sweep(yaw: Float, pitch: Float, from: Double) -> Double {
            drive(c, from: from, seconds: 2) { t in frame(t, yaw: yaw * Float(min(1, t / 1.5)), pitch: pitch * Float(min(1, t / 1.5))) }
        }
        var t = drive(c, seconds: 1) { t in frame(t) }
        t = sweep(yaw: 16, pitch: 10, from: t)
        XCTAssertEqual(c.pointer.position.x, screen.maxX - 1, accuracy: 1); XCTAssertEqual(c.pointer.position.y, screen.maxY - 1, accuracy: 1)
        t = drive(c, from: t, seconds: 1) { t in frame(t, yaw: 16, pitch: 10) }
        t = drive(c, from: t, seconds: 2) { t in frame(t, yaw: 16 - Float(t) * 16 - Float(t) * 0, pitch: 10 - Float(t) * 10) }
        t = drive(c, from: t, seconds: 2) { t in frame(t, yaw: -Float(t) * 16, pitch: -Float(t) * 10) }
        XCTAssertLessThan(c.pointer.position.x, 40); XCTAssertLessThan(c.pointer.position.y, 40)
    }

    func testHeadTurnRightMovesCursorRightAndDownMovesDown() {
        let (c, _) = makeController()
        drive(c, seconds: 2) { t in frame(t, yaw: Float(t * 8), pitch: Float(t * 5)) }
        XCTAssertGreaterThan(c.pointer.position.x, 720 + 50)
        XCTAssertGreaterThan(c.pointer.position.y, 450 + 50)
    }

    func testCursorFreezesAndClickLandsWhereItWasBeforeOnset() {
        // head drifts 6 px/frame-ish while the mouth opens: the click must land at the pre-onset spot
        let (c, s) = makeController(Profile(name: "t", bindings: [GestureBinding(.leftClick, .mouthOpen, .tap)]))
        var before = CGPoint.zero
        var t = 0.0
        while t < 3 {
            let yaw = Float(t < 1.5 ? t * 6 : 9 + (t - 1.5) * 12)   // starts a bigger move just as the mouth opens at 1.5
            if abs(t - 1.5) < dt / 2 { before = c.pointer.position }
            c.process(frame(t, yaw: yaw, [.jawOpen: 0.5 * pulse(t, 1.5, 0.3)]), now: t)
            t += dt
        }
        XCTAssertEqual(s.leftClicks, 1)
        // find the position where the button went down
        var pos = CGPoint.zero
        for (i, e) in s.events.enumerated() { if case .down = e, i > 0, case .move(let p, _) = s.events[i - 1] { pos = p } }
        XCTAssertLessThanOrEqual(pos.x, before.x + 1)
        XCTAssertLessThan(before.x - pos.x, 80, "click at \(pos), cursor was at \(before) when the gesture began")
    }

    func testOneEuroSmoothsNoise() {
        var f = OneEuro()
        var out: [Double] = []
        for i in 0..<90 { out.append(f.filter(Double.random(in: -0.2...0.2), at: Double(i) / 30)) }
        XCTAssertLessThan((out.suffix(60).max()! - out.suffix(60).min()!), 0.15)
    }
}
