import XCTest
@testable import HeadClickCore

final class GestureTests: XCTestCase {
    func testMouthOpenTapIsLeftClick() {
        let (c, s) = makeController()
        drive(c, seconds: 2) { t in frame(t, [.jawOpen: 0.5 * pulse(t, 0.5, 0.3)]) }
        XCTAssertEqual(s.leftClicks, 1); XCTAssertEqual(s.rightClicks, 0)
    }

    func testMouthOpenHoldIsDragNotClick() {
        let (c, s) = makeController()
        drive(c, seconds: 3) { t in frame(t, [.jawOpen: 0.5 * pulse(t, 0.5, 1.2)]) }
        XCTAssertEqual(s.leftClicks, 1, "one mouse-down for the drag")
        XCTAssertEqual(s.ups, 1)
        XCTAssertTrue(s.events.contains(.up(.left, 1)))
        // pressed at ~1.1 s, released at ~1.7 s
        guard let di = s.events.firstIndex(of: .down(.left, 1)), let ui = s.events.firstIndex(of: .up(.left, 1)) else { return XCTFail() }
        XCTAssertLessThan(di, ui)
    }

    func testDragMovesWithHeadWhileHeld() {
        let (c, s) = makeController()
        drive(c, seconds: 3) { t in
            frame(t, yaw: t > 1.2 ? Float((t - 1.2) * 10) : 0, [.jawOpen: 0.5 * pulse(t, 0.5, 2.0)])
        }
        let dragMoves = s.events.filter { if case .move(_, true) = $0 { return true }; return false }
        XCTAssertGreaterThan(dragMoves.count, 5, "cursor follows the head while the button is down")
    }

    func testPuckerIsRightClickAndBrowsDoubleClick() {
        let (c, s) = makeController()
        drive(c, seconds: 4) { t in frame(t, [.mouthPucker: 0.6 * pulse(t, 0.5, 0.3), .browInnerUp: 0.6 * pulse(t, 2, 0.3), .browOuterUpLeft: 0.6 * pulse(t, 2, 0.3), .browOuterUpRight: 0.6 * pulse(t, 2, 0.3)]) }
        XCTAssertEqual(s.rightClicks, 1)
        XCTAssertEqual(s.doubleClicks, 1)
        XCTAssertEqual(s.leftClicks, 1, "the double click is two presses: click state 1 and 2")
    }

    func testRefractoryBlocksQuickRepeat() {
        let (c, s) = makeController(Profile(name: "t", bindings: [GestureBinding(.rightClick, .pucker, .tap)]))
        drive(c, seconds: 3) { t in frame(t, [.mouthPucker: 0.6 * (pulse(t, 0.5, 0.25) + pulse(t, 0.85, 0.25))]) }
        XCTAssertEqual(s.rightClicks, 1)
        let (c2, s2) = makeController(Profile(name: "t", bindings: [GestureBinding(.rightClick, .pucker, .tap)]))
        drive(c2, seconds: 3) { t in frame(t, [.mouthPucker: 0.6 * (pulse(t, 0.5, 0.25) + pulse(t, 1.5, 0.25))]) }
        XCTAssertEqual(s2.rightClicks, 2)
    }

    func testTooShortOrFlickerDoesNotClick() {
        let (c, s) = makeController(Profile(name: "t", bindings: [GestureBinding(.leftClick, .smile, .tap)]))
        drive(c, seconds: 2) { t in frame(t, [.mouthSmileLeft: 0.8 * pulse(t, 0.5, 0.05), .mouthSmileRight: 0.8 * pulse(t, 0.5, 0.05)]) }
        XCTAssertEqual(s.leftClicks, 0)
    }

    func testHysteresisNoDoubleFireOnJitter() {
        let (c, s) = makeController(Profile(name: "t", bindings: [GestureBinding(.leftClick, .smile, .tap)]))
        drive(c, seconds: 3) { t in
            let v: Float = t > 0.5 && t < 2.0 ? 0.55 + 0.1 * sin(Float(t) * 40) : 0   // wobbles around the threshold
            return frame(t, [.mouthSmileLeft: v, .mouthSmileRight: v])
        }
        XCTAssertLessThanOrEqual(s.leftClicks, 1)
    }

    func testCoupledGesturesStrongerWins() {
        // smile + wide jaw: mouth open dominates -> left click from mouth open only; smile is suppressed
        var p = Profile(name: "t", bindings: [GestureBinding(.leftClick, .mouthOpen, .tap), GestureBinding(.rightClick, .smile, .tap)])
        p.tuning["mouthOpen"] = GestureTuning()
        let (c, s) = makeController(p)
        drive(c, seconds: 2) { t in frame(t, [.jawOpen: 0.5 * pulse(t, 0.5, 0.3), .mouthSmileLeft: 0.35 * pulse(t, 0.5, 0.3), .mouthSmileRight: 0.35 * pulse(t, 0.5, 0.3)]) }
        XCTAssertEqual(s.leftClicks, 1); XCTAssertEqual(s.rightClicks, 0)
    }

    func testTalkingDoesNotClickWithGuard() {
        let (c, s) = makeController()
        // 60 s of "speech": jaw oscillating at 4.5 Hz, amplitude up to 0.45 (above click threshold), brows bobbing too
        func speech(_ t: Double) -> FaceFrame {
            let j = Float(0.25 + 0.22 * sin(2 * .pi * 4.5 * t))
            let b = Float(0.3 + 0.3 * sin(2 * .pi * 1.7 * t))
            return frame(t, [.jawOpen: j, .browInnerUp: b, .browOuterUpLeft: b, .browOuterUpRight: b])
        }
        // The guard needs about half a second of speech to recognise it: the first moments may click.
        let t = drive(c, seconds: 1.0) { speech($0) }
        let early = s.downs.count
        drive(c, from: t, seconds: 59) { speech($0 + t) }
        XCTAssertEqual(s.downs.count - early, 0, "talk guard blocks mouth/brow clicks after the first second of speech")
        XCTAssertLessThanOrEqual(early, 2)
        XCTAssertTrue(c.status.talking)
    }

    func testTalkingWithoutGuardWouldClick() {
        var p = Profile.quietDesk; p.talkGuard = false
        let (c, s) = makeController(p)
        drive(c, seconds: 20) { t in frame(t, [.jawOpen: Float(0.25 + 0.22 * sin(2 * .pi * 2.0 * t))]) }
        XCTAssertGreaterThan(s.leftClicks, 0, "sanity: the same speech does click when the guard is off")
    }

    func testDeliberateTapStillWorksAfterTalking() {
        let (c, s) = makeController()
        drive(c, seconds: 8) { t in
            if t < 3 { return frame(t, [.jawOpen: Float(0.25 + 0.22 * sin(2 * .pi * 4.5 * t))]) }
            return frame(t, [.jawOpen: 0.5 * pulse(t, 5.0, 0.3)])
        }
        XCTAssertGreaterThanOrEqual(s.leftClicks, 1)
        XCTAssertLessThanOrEqual(s.leftClicks, 3)
    }

    func testTiltScrolls() {
        let (c, s) = makeController()
        drive(c, seconds: 2) { t in frame(t, roll: t > 0.5 && t < 1.5 ? 20 : 0) }
        XCTAssertGreaterThan(s.scrolls.count, 10)
        XCTAssertTrue(s.scrolls.allSatisfy { $0 < 0 }, "tilt right = scroll down")
        let (c2, s2) = makeController()
        drive(c2, seconds: 2) { t in frame(t, roll: t > 0.5 && t < 1.5 ? -20 : 0) }
        XCTAssertTrue(s2.scrolls.allSatisfy { $0 > 0 } && !s2.scrolls.isEmpty)
    }

    func testPauseByLongBlinkAndResume() {
        let (c, s) = makeController()
        func blink(_ t: Double, _ a: Double, _ l: Double) -> [Blend: Float] { let v = 0.9 * pulse(t, a, l); return [.eyeBlinkLeft: v, .eyeBlinkRight: v] }
        var t = drive(c, seconds: 3) { t in frame(t, blink(t, 0.5, 1.5)) }
        XCTAssertTrue(c.paused)
        // while paused a mouth tap does nothing
        t = drive(c, from: t, seconds: 2) { t in frame(t, [.jawOpen: 0.5 * pulse(t, 0.5, 0.3)]) }
        XCTAssertEqual(s.leftClicks, 0)
        drive(c, from: t, seconds: 3) { t in frame(t, blink(t, 0.5, 1.5)) }
        XCTAssertFalse(c.paused)
    }

    func testNaturalBlinkDoesNothing() {
        let (c, s) = makeController()
        drive(c, seconds: 20) { t in
            let phase = t.truncatingRemainder(dividingBy: 3.5)
            let v: Float = phase < 0.15 ? 0.9 : 0
            return frame(t, [.eyeBlinkLeft: v, .eyeBlinkRight: v])
        }
        XCTAssertEqual(s.leftClicks + s.rightClicks, 0)
        XCTAssertFalse(c.paused)
    }

    func testDoubleBlinkDoubleClickAndSingleBlinkNot() {
        func blinkProfile() -> Profile { Profile(name: "t", bindings: [GestureBinding(.leftClick, .doubleBlink, .tap)]) }
        func b(_ t: Double, _ starts: [Double]) -> [Blend: Float] { let v = 0.9 * starts.map { pulse(t, $0, 0.15) }.max()!; return [.eyeBlinkLeft: v, .eyeBlinkRight: v] }
        let (c, s) = makeController(blinkProfile())
        drive(c, seconds: 3) { t in frame(t, b(t, [1.0, 1.4])) }
        XCTAssertEqual(s.leftClicks, 1)
        let (c2, s2) = makeController(blinkProfile())
        drive(c2, seconds: 3) { t in frame(t, b(t, [1.0])) }
        XCTAssertEqual(s2.leftClicks, 0)
    }

    func testWinkLeftNotBothEyes() {
        let p = Profile(name: "t", bindings: [GestureBinding(.leftClick, .winkLeft, .tap)])
        let (c, s) = makeController(p)
        drive(c, seconds: 2) { t in frame(t, [.eyeBlinkLeft: 0.9 * pulse(t, 0.5, 0.3)]) }
        XCTAssertEqual(s.leftClicks, 1)
        let (c2, s2) = makeController(p)
        drive(c2, seconds: 2) { t in frame(t, [.eyeBlinkLeft: 0.9 * pulse(t, 0.5, 0.3), .eyeBlinkRight: 0.9 * pulse(t, 0.5, 0.3)]) }
        XCTAssertEqual(s2.leftClicks, 0, "both eyes closing is a blink, not a wink")
    }

    func testSwapLeftRight() {
        var p = Profile(name: "t", bindings: [GestureBinding(.leftClick, .winkLeft, .tap)]); p.swapLeftRight = true
        let (c, s) = makeController(p)
        drive(c, seconds: 2) { t in frame(t, [.eyeBlinkRight: 0.9 * pulse(t, 0.5, 0.3)]) }
        XCTAssertEqual(s.leftClicks, 1)
    }

    func testNodAndShakeRecenter() {
        let nod = Profile(name: "t", bindings: [GestureBinding(.leftClick, .headNod, .tap)])
        let (c, s) = makeController(nod)
        drive(c, seconds: 3) { t in
            let x = t - 1.0
            let pitch: Float = (x > 0 && x < 0.5) ? Float(10 * sin(.pi * x / 0.5)) : 0
            return frame(t, pitch: pitch)
        }
        XCTAssertEqual(s.leftClicks, 1, "a quick 10 degree dip and return is a nod")
        let (c1, s1) = makeController(nod)
        drive(c1, seconds: 4) { t in frame(t, pitch: Float(10 * sin(2 * .pi * t / 4))) }   // slow glance down and up
        XCTAssertEqual(s1.leftClicks, 0, "slow pointing movement is not a nod")

        let (c2, s2) = makeController(Profile(name: "t", bindings: [GestureBinding(.recenter, .headShake, .tap)]))
        s2.currentPosition = CGPoint(x: 100, y: 100)
        c2.pointer.warp(to: CGPoint(x: 100, y: 100))
        drive(c2, seconds: 3) { t in
            let x = t - 1.0
            let yaw: Float = (x > 0 && x < 0.8) ? Float(12 * sin(2 * .pi * 1.9 * x)) : 0
            return frame(t, yaw: yaw)
        }
        XCTAssertTrue(s2.events.contains(.move(CGPoint(x: screen.midX, y: screen.midY), false)), "shake recentres the cursor")
    }

    func testNoFaceFreezesAndAutoPauses() {
        let (c, s) = makeController()
        drive(c, seconds: 1) { t in frame(t, yaw: Float(t * 5)) }
        let n = s.events.count
        drive(c, from: 1, seconds: 3) { _ in nil }
        XCTAssertEqual(s.events.count, n, "no cursor events without a face")
        XCTAssertTrue(c.status.autoPaused)
        XCTAssertTrue(c.paused)
        let m = s.events.count
        drive(c, from: 4, seconds: 1) { t in frame(t, yaw: Float(t * 5)) }
        XCTAssertTrue(c.paused, "a lost face needs an explicit resume")
        XCTAssertEqual(s.events.count, m)
        c.setPaused(false)
        drive(c, from: 5, seconds: 0.2) { t in frame(t) }
        XCTAssertFalse(c.status.autoPaused)
    }

    func testProfileJSONRoundTrip() throws {
        var p = Profile.quietDesk
        p.tuning["mouthOpen"] = { var t = GestureTuning(); t.neutral = 0.04; t.peak = 0.5; t.onThreshold = 0.35; t.talkRisk = true; return t }()
        p.pointer.gainX = 71.5; p.swapLeftRight = true
        let d = try ProfileStore.encode(p)
        let q = try ProfileStore.decode(d)
        XCTAssertEqual(p, q)
        for b in Profile.builtIn { XCTAssertEqual(try ProfileStore.decode(try ProfileStore.encode(b)), b) }
    }
}
