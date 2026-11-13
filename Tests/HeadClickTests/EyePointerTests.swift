import XCTest
@testable import HeadClickCore

/// The eye pointer: the cursor goes where the eyes look; the head does not matter.
final class EyePointerTests: XCTestCase {
    /// Synthetic face looking at screen point (gx, gy in [-1, 1]) with the head turned by `yaw` / `pitch` degrees.
    /// Physically, turning the head moves the irises in their sockets, so the iris offset compensates part of the turn
    /// and the nose moves in the picture; the model has to learn that from calibration data.
    func face(gx: Double, gy: Double, yaw: Double = 0, pitch: Double = 0, noise: Double = 0) -> FaceFrame {
        var f = FaceFrame(time: 0, yaw: Float(yaw), pitch: Float(pitch))
        f.landmarks = GuideSynthUser.landmarks(gx: gx - 0.03 * yaw, gy: gy - 0.05 * pitch)
        f.landmarks[1] = SIMD3(0.5 + Float(0.004 * yaw), 0.5 + Float(0.004 * pitch), 0)
        if noise > 0 {
            for i in [468, 473] { f.landmarks[i].x += Float(noise * Double.random(in: -1...1)); f.landmarks[i].y += Float(noise * Double.random(in: -1...1)) }
        }
        return f
    }

    func truth(_ gx: Double, _ gy: Double) -> CGPoint { CGPoint(x: 720 + gx * 700, y: 450 + gy * 430) }

    /// Calibrated with the head moving a little between the dots, like a person who is not clamped in a chin rest.
    func calibrated(headSpread: Double = 10) throws -> GazeEstimator {
        let est = GazeEstimator()
        var samples: [([Double], CGPoint)] = []
        for gy in [-0.9, 0, 0.9] { for gx in [-0.9, 0, 0.9] {
            for k in 0..<12 {
                let yaw = headSpread * sin(Double(k) * 1.7 + gx * 3), pitch = headSpread * 0.5 * sin(Double(k) * 2.3 + gy * 5)
                samples.append((try XCTUnwrap(GazeFeatures.extract(face(gx: gx, gy: gy, yaw: yaw, pitch: pitch, noise: 0.0004))), truth(gx, gy)))
            }
        } }
        est.fit(samples)
        XCTAssertTrue(est.isCalibrated)
        return est
    }

    func eyeController(_ est: GazeEstimator, snap: ClickTargetFinder? = nil) -> (Controller, FakeSink, GazePointer) {
        let (c, s) = makeController()
        let gp = GazePointer(estimator: est)
        gp.snapFinder = snap; gp.synchronousSnap = true
        c.pointerMode = .gaze; c.gazePointer = gp
        c.setPaused(false, toast: false)
        return (c, s, gp)
    }

    func testHeadTurnsWithSteadyGazeDoNotMoveTheCursor() throws {
        let est = try calibrated()
        let (c, s, _) = eyeController(est)
        // look at one spot for 1 s, then turn the head left and right by up to 20° and nod while still looking at it
        let spot = (0.3, -0.2)
        drive(c, seconds: 1) { _ in self.face(gx: spot.0, gy: spot.1, noise: 0.0004) }
        let settled = s.currentPosition
        XCTAssertEqual(Double(settled.x), Double(truth(spot.0, spot.1).x), accuracy: 60)
        var lo = CGPoint(x: 1e9, y: 1e9), hi = CGPoint(x: -1e9, y: -1e9)
        drive(c, from: 1, seconds: 4) { t in
            let yaw = 20 * sin(t * 2.0), pitch = 10 * sin(t * 1.3)
            return self.face(gx: spot.0, gy: spot.1, yaw: yaw, pitch: pitch, noise: 0.0004)
        }
        for case .move(let p, _) in s.events.suffix(200) { lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y)); hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y)) }
        XCTAssertLessThan(hi.x - lo.x, 40, "head turns moved the cursor sideways by \(hi.x - lo.x) px")
        XCTAssertLessThan(hi.y - lo.y, 40, "head nods moved the cursor up/down by \(hi.y - lo.y) px")
        XCTAssertLessThan(Double(hypot(s.currentPosition.x - settled.x, s.currentPosition.y - settled.y)), 40)
    }

    func testTheCursorFollowsTheEyes() throws {
        let est = try calibrated()
        let (c, s, _) = eyeController(est)
        var t = 0.0
        for spot in [(-0.7, -0.6), (0.7, 0.5), (0.0, 0.0)] {
            t = drive(c, from: t, seconds: 1.2) { _ in self.face(gx: spot.0, gy: spot.1, noise: 0.0004) }
            let want = truth(spot.0, spot.1)
            XCTAssertLessThan(Double(hypot(s.currentPosition.x - want.x, s.currentPosition.y - want.y)), 70, "looking at \(spot)")
        }
    }

    func testFixationLockKeepsTheCursorStillWhileLookingAtOneSpot() throws {
        let est = try calibrated(headSpread: 0)
        let gp = GazePointer(estimator: est)
        var t = 0.0
        var out: [CGPoint] = [], raw: [CGPoint] = []
        // 3 s of looking at one spot with webcam-sized iris noise
        while t < 3 {
            let p = gp.update(face(gx: 0.2, gy: 0.1, noise: 0.0006), now: t)
            if t > 0.8, let p, let r = gp.raw { out.append(p); raw.append(r) }
            t += dt
        }
        func spread(_ a: [CGPoint]) -> Double { max(Double(a.map { $0.x }.max()! - a.map { $0.x }.min()!), Double(a.map { $0.y }.max()! - a.map { $0.y }.min()!)) }
        XCTAssertGreaterThan(spread(raw), 15, "the raw estimate does shake: \(spread(raw)) px")
        XCTAssertLessThan(spread(out), 10, "the locked cursor shook \(spread(out)) px")
    }

    func testARealLookAwayMovesTheCursorQuickly() throws {
        let est = try calibrated(headSpread: 0)
        let gp = GazePointer(estimator: est)
        var t = 0.0
        while t < 1 { gp.update(face(gx: -0.5, gy: 0, noise: 0.0004), now: t); t += dt }
        var arrived = -1.0
        let t1 = t
        while t < t1 + 1.5 {
            if let p = gp.update(face(gx: 0.5, gy: 0, noise: 0.0004), now: t), arrived < 0, hypot(Double(p.x) - Double(truth(0.5, 0).x), Double(p.y) - Double(truth(0.5, 0).y)) < 60 { arrived = t - t1 }
            t += dt
        }
        XCTAssertGreaterThan(arrived, 0, "the cursor never arrived")
        XCTAssertLessThan(arrived, 0.5, "arrived after \(arrived) s")
    }

    func testBlinkDoesNotThrowTheCursorAround() throws {
        let est = try calibrated(headSpread: 0)
        let (c, s, _) = eyeController(est)
        drive(c, seconds: 1) { _ in self.face(gx: 0.2, gy: 0.1, noise: 0.0004) }
        let before = s.currentPosition
        // a blink: the lids cover the eyes for 0.25 s and the irises read nonsense
        drive(c, from: 1, seconds: 1) { t in
            var f = self.face(gx: 0.2, gy: 0.1, noise: 0.0004)
            if t > 0.3 && t < 0.55 {
                f[.eyeBlinkLeft] = 0.9; f[.eyeBlinkRight] = 0.9
                f.landmarks = GuideSynthUser.landmarks(gx: -3, gy: 4)
            }
            return f
        }
        XCTAssertLessThan(Double(hypot(s.currentPosition.x - before.x, s.currentPosition.y - before.y)), 40)
    }

    func testCursorFreezesWhileAClickGestureArms() throws {
        let est = try calibrated(headSpread: 0)
        var p = Profile.quietDesk; p.bindings = [GestureBinding(.leftClick, .mouthOpen, .tap)]
        let s = FakeSink()
        let c = Controller(profile: p, sink: s, bounds: screen)
        let gp = GazePointer(estimator: est)
        c.pointerMode = .gaze; c.gazePointer = gp; c.setPaused(false, toast: false)
        drive(c, seconds: 1) { _ in self.face(gx: 0, gy: 0, noise: 0.0004) }
        // the mouth opens (the gesture arms) while the gaze swings away: the click lands where the cursor was
        drive(c, from: 1, seconds: 1.5) { t in
            var f = self.face(gx: t > 0.3 ? 0.8 : 0, gy: 0, noise: 0.0004)
            if t > 0.2 && t < 0.9 { f[.jawOpen] = 0.9 }
            return f
        }
        XCTAssertEqual(s.leftClicks, 1)
        // the press happened where the cursor rested, not where the eyes swung to
        var press: CGPoint?
        for (i, e) in s.events.enumerated() { if case .down = e { for k in stride(from: i - 1, through: 0, by: -1) { if case .move(let p, _) = s.events[k] { press = p; break } }; break } }
        let at = try XCTUnwrap(press)
        XCTAssertLessThan(Double(hypot(at.x - truth(0, 0).x, at.y - truth(0, 0).y)), 90, "the cursor stayed near the middle")
    }

    // MARK: snapping
    final class FakeTargets: ClickTargetFinder {
        var rects: [CGRect]
        init(_ r: [CGRect]) { rects = r }
        func targetRects(near p: CGPoint, radius: CGFloat) -> [CGRect] { rects }
    }

    func testSnapPicksTheNearestTargetWithinSixtyPixels() {
        let near = CGRect(x: 100, y: 100, width: 80, height: 30)       // edge 20 px from the gaze point
        let far = CGRect(x: 300, y: 100, width: 80, height: 30)
        let nearest = CGRect(x: 60, y: 90, width: 20, height: 20)       // edge 12 px away: this one wins
        let g = CGPoint(x: 60, y: 140)
        XCTAssertEqual(SnapPicker.pick(gaze: g, rects: [far, near], radius: 60), CGPoint(x: near.midX, y: near.midY))
        XCTAssertEqual(SnapPicker.pick(gaze: g, rects: [far, near, nearest], radius: 60), CGPoint(x: nearest.midX, y: nearest.midY))
        XCTAssertNil(SnapPicker.pick(gaze: g, rects: [far], radius: 60), "nothing within 60 px: no snap")
        XCTAssertEqual(SnapPicker.pick(gaze: CGPoint(x: 140, y: 115), rects: [far, near], radius: 60), CGPoint(x: near.midX, y: near.midY), "inside a target")
    }

    func testPointerSnapsToTheButtonAfterTheGazeRests() throws {
        let est = try calibrated(headSpread: 0)
        let want = truth(0.3, 0.2)
        let button = CGRect(x: want.x + 30, y: want.y - 15, width: 120, height: 40)       // 30 px right of the gaze point
        let farButton = CGRect(x: want.x - 400, y: want.y, width: 100, height: 40)
        let finder = FakeTargets([farButton, button])
        let gp = GazePointer(estimator: est); gp.snapFinder = finder; gp.synchronousSnap = true
        var t = 0.0, last: CGPoint?
        while t < 1.2 { last = gp.update(face(gx: 0.3, gy: 0.2, noise: 0.0004), now: t); t += dt }
        XCTAssertTrue(gp.snapped)
        let l = try XCTUnwrap(last)
        XCTAssertEqual(Double(l.x), Double(button.midX), accuracy: 0.5)
        XCTAssertEqual(Double(l.y), Double(button.midY), accuracy: 0.5)
        // with nothing near, the cursor stays on the gaze point
        let gp2 = GazePointer(estimator: est); gp2.snapFinder = FakeTargets([farButton]); gp2.synchronousSnap = true
        t = 0
        while t < 1.2 { last = gp2.update(face(gx: 0.3, gy: 0.2, noise: 0.0004), now: t); t += dt }
        XCTAssertFalse(gp2.snapped)
        XCTAssertEqual(Double(last!.x), Double(want.x), accuracy: 60)
    }

    func testSnapReleasesWhenTheGazeMovesOn() throws {
        let est = try calibrated(headSpread: 0)
        let want = truth(0.3, 0.2)
        let finder = FakeTargets([CGRect(x: want.x - 40, y: want.y - 20, width: 80, height: 40)])
        let gp = GazePointer(estimator: est); gp.snapFinder = finder; gp.synchronousSnap = true
        var t = 0.0
        while t < 1 { gp.update(face(gx: 0.3, gy: 0.2, noise: 0.0004), now: t); t += dt }
        XCTAssertTrue(gp.snapped)
        let t1 = t; var p: CGPoint?
        while t < t1 + 1 { p = gp.update(face(gx: -0.6, gy: -0.4, noise: 0.0004), now: t); t += dt }
        XCTAssertFalse(gp.snapped)
        XCTAssertEqual(Double(p!.x), Double(truth(-0.6, -0.4).x), accuracy: 70)
    }

    // MARK: drift fix
    func testDriftFixRecentresOnTheMiddleDot() throws {
        let est = try calibrated(headSpread: 0)
        // the world drifts: the eyes now read 90 px right and 40 px down of the truth
        func drifted(_ gx: Double, _ gy: Double) -> FaceFrame { face(gx: gx + 90 / 700, gy: gy + 40 / 430, noise: 0.0004) }
        let fix = DriftFixer(estimator: est, screen: screen)
        var t = 0.0
        while !fix.finished && t < 5 { fix.feed(drifted(0, 0), now: t); t += dt }
        XCTAssertTrue(fix.finished); XCTAssertFalse(fix.failed, fix.result)
        XCTAssertLessThan(t, 2.0)
        let after = try XCTUnwrap(est.estimate(try XCTUnwrap(GazeFeatures.extract(drifted(0, 0)))))
        XCTAssertEqual(Double(after.x), Double(fix.target.x), accuracy: 15)
        XCTAssertEqual(Double(after.y), Double(fix.target.y), accuracy: 15)
        // an absurd offset is refused
        let est2 = try calibrated(headSpread: 0)
        let fix2 = DriftFixer(estimator: est2, screen: screen)
        t = 0
        while !fix2.finished { fix2.feed(face(gx: 0.95, gy: 0.9), now: t); t += dt }
        XCTAssertTrue(fix2.failed)
    }

    func testDefaultPointerModeInTheLibraryStaysHeadSoOlderCallersKeepWorking() {
        let (c, _) = makeController()
        XCTAssertEqual(c.pointerMode, .head)
    }
}
