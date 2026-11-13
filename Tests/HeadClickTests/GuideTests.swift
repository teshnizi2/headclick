import XCTest
@testable import HeadClickCore

final class GuideTests: XCTestCase {
    let scr = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Runs the guide with a fake user until `until` is true or 400 s of fake time pass. Returns the fake clock.
    @discardableResult
    func run(_ g: GuidedRun, _ u: GuideSynthUser, from t0: Double = 0, until: (GuidedRun) -> Bool) -> Double {
        var t = t0
        while t < t0 + 400 && !until(g) {
            g.feed(u.frame(for: g, now: t), now: t, fps: 30, engineMs: 8)
            XCTAssertLessThanOrEqual(g.secondsLeft, 10.0001, "every action is at most 10 s: \(g.stage)")
            t += dt
        }
        return t
    }

    func calibratedProfile(_ p: Profile = .quietDesk) -> Profile {
        var q = p; q.pointer.calibrated = true; q.pointer.gainX = 52; q.pointer.gainY = 90; return q
    }

    func testCameraStepPassesOnSteadyFace() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        XCTAssertEqual(g.stage, .camera)
        run(g, GuideSynthUser()) { $0.stage != .camera }
        XCTAssertEqual(g.cameraOutcome, .passed)
        XCTAssertEqual(g.stage, .gazeIntro)
        XCTAssertEqual(g.faceWidth, 0.36, accuracy: 0.01)
    }

    func testCameraStepSaysWhatToFix() {
        // no face at all
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        var t = 0.0
        while t < 12 { g.feed(nil, now: t); t += dt }
        XCTAssertEqual(g.phase, .failed)
        XCTAssertEqual(g.cameraOutcome, .failed)
        XCTAssertTrue(g.message.lowercased().contains("light"), g.message)
        XCTAssertEqual(g.stage, .camera, "a failed camera check waits for the user, no auto advance")
        // face too far away
        let g2 = GuidedRun(profile: calibratedProfile(), screen: scr)
        t = 0
        while t < 3 { var f = FaceFrame(time: t); f.landmarks = GuideSynthUser.landmarks(); for i in 0..<f.landmarks.count { f.landmarks[i].x = 0.5 + (f.landmarks[i].x - 0.5) * 0.3 }; g2.feed(f, now: t); t += dt }
        XCTAssertTrue(g2.hint.contains("closer"), g2.hint)
        // moving head
        let g3 = GuidedRun(profile: calibratedProfile(), screen: scr)
        t = 0
        while t < 3 { var f = FaceFrame(time: t, yaw: Float(30 * sin(t * 6))); f.landmarks = GuideSynthUser.landmarks(); g3.feed(f, now: t); t += dt }
        XCTAssertTrue(g3.hint.contains("still"), g3.hint)
        XCTAssertNotEqual(g3.cameraOutcome, .passed)
    }

    func testGuideOrderIsCameraEyesLookClicksSummary() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        XCTAssertEqual(Array(g.order.prefix(3)), [.camera, .gazeIntro, .gazeCal])
        XCTAssertEqual(Array(g.order[3..<8]), (0..<5).map { GuidedRun.Stage.dot($0) })
        XCTAssertEqual(g.order.last, .summary)
        XCTAssertEqual(GuideStep.allCases.map { $0.title }, ["Camera", "Eyes", "Look", "Clicks", "Summary"])
    }

    func testEyeCalibrationThenDotsAreReachedWithTheHeadWandering() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr, widthCm: 30)
        let u = GuideSynthUser()
        var yawSeen = 0.0
        run(g, u) { if case .dot = $0.stage { yawSeen = max(yawSeen, abs(u.yaw)) }; if case .gesture = $0.stage { return true }; return false }
        XCTAssertEqual(g.gazeOutcome, .passed, g.gazeNote)
        XCTAssertGreaterThan(yawSeen, 3, "the fake head turned while the eyes looked at the dots")
        XCTAssertEqual(g.dotOutcomes, [StepOutcome](repeating: .passed, count: 5), "dots: \(g.dotOutcomes) errors \(g.dotErrorsCm)")
        for e in g.dotErrorsCm { XCTAssertLessThan(e ?? 99, GuidedRun.reachCm) }
        XCTAssertLessThan(g.jitter!.x, 40); XCTAssertLessThan(g.jitter!.y, 40)
        XCTAssertTrue(g.summaryLines().contains { $0.text.contains("reached 5 of 5 dots") && $0.text.contains("cm") })
    }

    func testEachGuidePartFitsTenSeconds() {
        let c = GazeCalibrator(screen: scr, screenWidthCm: 30)
        XCTAssertLessThanOrEqual(c.calibrationSeconds, 10, "9 calibration dots")
        XCTAssertLessThanOrEqual(c.checkSeconds, 10, "4 check dots")
        XCTAssertLessThanOrEqual(GuidedRun.dotLimit * 5, 10, "5 look dots")
    }

    func testDotsMissedWhenTheEyesStayInTheMiddle() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr, widthCm: 30)
        let u = GuideSynthUser()
        var t = run(g, u) { $0.stage == .dot(0) }
        // eyes stay on the middle of the screen the whole time: the centre dot is reached, the others time out after 2 s each
        while g.stage != .gesture(0) && t < 200 {
            var f = FaceFrame(time: t); f.landmarks = GuideSynthUser.landmarks()
            g.feed(f, now: t); t += dt
        }
        XCTAssertEqual(g.dotOutcomes[0], .passed)
        XCTAssertEqual(Array(g.dotOutcomes[1...]), [StepOutcome](repeating: .failed, count: 4))
        XCTAssertTrue(g.summaryLines().contains { $0.text.contains("reached 1 of 5 dots") })
        XCTAssertGreaterThan(g.dotErrorsCm[1] ?? 0, 10, "the left dot is ~14 cm from where the eyes were")
    }

    func testEveryDefaultGestureIsCountedThreeTimes() {
        for profile in [Profile.quietDesk, .talkSafe, .eyesOnly, .expressive] {
            let g = GuidedRun(profile: calibratedProfile(profile), screen: scr)
            XCTAssertFalse(g.tasks.isEmpty)
            let u = GuideSynthUser()
            run(g, u) { $0.stage == .summary }
            for r in g.gestureResults { XCTAssertEqual(r.outcome, .passed, "\(profile.name): \(r.task.action) via \(r.task.gesture) hits \(r.hits) peak \(r.peak)") }
        }
    }

    func testDefaultProfileAsksFiveGestures() {
        let g = GuidedRun(profile: .quietDesk, screen: scr)
        XCTAssertEqual(g.tasks.map { $0.gesture }, [.mouthOpen, .pucker, .browRaise, .tiltRight, .longBlink])
        XCTAssertEqual(g.tasks.last?.trigger, .long)
    }

    func testFailedGestureWaitsThenCalibrationHelps() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        let u = GuideSynthUser(); u.failTasks = [1]
        var t = run(g, u) { $0.stage == .gesture(1) && $0.phase == .failed }
        XCTAssertEqual(g.gestureResults[1].outcome, .failed)
        XCTAssertTrue(g.message.contains("Calibrate"), g.message)
        XCTAssertEqual(g.stage, .gesture(1), "failure waits for the user")
        // The user presses "Calibrate this gesture" and now does the gesture properly.
        u.failTasks = []
        g.calibrateGesture()
        XCTAssertTrue(g.calibratingGesture)
        // synthetic user for the calibrator: neutral for 3 s, then 3 reps of the gesture
        var cal = 0.0
        while g.calibratingGesture && cal < 30 {
            var f = FaceFrame(time: t); f.landmarks = GuideSynthUser.landmarks()
            if let c = g.calibrator, c.stepNumber >= 2 { GuideSynthUser.apply(g.tasks[1].gesture, level: 1, to: &f) }
            g.feed(f, now: t); t += dt; cal += dt
        }
        XCTAssertTrue(g.profileChanged)
        t = run(g, u, from: t) { $0.stage != .gesture(1) }
        XCTAssertEqual(g.gestureResults[1].outcome, .passed, "after calibration: hits \(g.gestureResults[1].hits)")
    }

    func testSkipAndBack() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        g.skip()
        XCTAssertEqual(g.cameraOutcome, .skipped)
        XCTAssertEqual(g.stage, .gazeIntro)
        XCTAssertTrue(g.canGoBack)
        g.skip()
        XCTAssertEqual(g.stage, .gazeIntro, "the eye calibration is required: skip does nothing")
        g.next(); XCTAssertEqual(g.stage, .gazeCal)
        g.skip(); XCTAssertEqual(g.stage, .gazeCal)
        g.next(); XCTAssertEqual(g.stage, .dot(0))
        g.skip()
        XCTAssertEqual(g.stage, .gesture(0))
        XCTAssertEqual(g.dotOutcomes, [StepOutcome](repeating: .skipped, count: 5))
        g.skip(); XCTAssertEqual(g.stage, .gesture(1))
        g.back(); XCTAssertEqual(g.stage, .gesture(0))
        g.back(); XCTAssertEqual(g.stage, .dot(0))
        g.back(); XCTAssertEqual(g.stage, .gazeIntro)
        g.back(); XCTAssertEqual(g.stage, .camera)
        XCTAssertFalse(g.canGoBack)
        // skipping everything optional ends at the summary, which says the eyes are not calibrated
        for _ in 0..<30 where g.stage != .summary { if g.stage == .gazeIntro || g.stage == .gazeCal { g.next() } else { g.skip() } }
        XCTAssertEqual(g.stage, .summary)
        XCTAssertNotEqual(g.gazeOutcome, .passed)
        XCTAssertTrue(g.summaryLines().contains { $0.mark == "✗" && $0.text.contains("Eyes: not calibrated") })
    }

    func testBackToCameraDoesNotAutoAdvance() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        let u = GuideSynthUser()
        run(g, u) { $0.stage == .gazeIntro }
        g.back()
        XCTAssertEqual(g.stage, .camera)
        run(g, u, from: 50) { _ in false }   // 400 s of steady face
        XCTAssertEqual(g.stage, .camera); XCTAssertEqual(g.phase, .passed)
        g.next(); XCTAssertEqual(g.stage, .gazeIntro)
    }

    func testGazeStepReportsErrorInCm() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr, widthCm: 30)
        let u = GuideSynthUser()
        run(g, u) { $0.stage == .gazeCal }
        run(g, u, from: 300) { $0.stage == .dot(0) }
        XCTAssertEqual(g.gazeOutcome, .passed, g.gazeNote)
        XCTAssertLessThan(g.gazeErrorCm ?? 99, 2.0)
        XCTAssertNotNil(g.gazeEstimator)
        XCTAssertTrue(g.summaryLines().contains { $0.text.contains("Eyes: calibrated, mean error") })
    }

    func testFullRunWritesSummaryFile() throws {
        let g = GuidedRun(profile: .quietDesk, screen: scr, widthCm: 30)
        var summaryCalls = 0
        g.onSummary = { summaryCalls += 1 }
        let u = GuideSynthUser(); u.failTasks = [2]
        run(g, u) { if $0.phase == .failed, case .gesture = $0.stage { $0.next() }; return $0.stage == .summary }
        XCTAssertEqual(summaryCalls, 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guided-run-test-\(UUID().uuidString).txt")
        XCTAssertTrue(g.writeSummary(to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("✓ Camera"), text)
        XCTAssertTrue(text.contains("reached 5 of 5 dots"), text)
        XCTAssertTrue(text.contains("jitter"), text)
        XCTAssertTrue(text.contains("Eyes: calibrated"), text)
        XCTAssertTrue(text.contains("Left click: Mouth open"), text)
        XCTAssertTrue(text.contains("✗ Double click: Raise eyebrows"), text)
        XCTAssertTrue(text.contains("fps"), text)
                XCTAssertTrue(text.contains("Misfires"), text)
        XCTAssertEqual(g.summaryPath, url.path)
        try? FileManager.default.removeItem(at: url)
        XCTAssertEqual(g.outcome(of: .clicks), .failed)
    }

    func testMisfiresWhileJustLookingAreReported() {
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        var t = 0.0
        while t < 2.5 {      // a steady face that yawns (mouth open) during the camera check
            var f = FaceFrame(time: t); f.landmarks = GuideSynthUser.landmarks()
            if t > 0.5 && t < 0.8 { f[.jawOpen] = 0.6 }
            g.feed(f, now: t); t += dt
        }
        XCTAssertEqual(g.misfires["Left click via Mouth open"], 1)
        XCTAssertTrue(g.summaryLines().contains { $0.text.contains("Misfires") && $0.text.contains("Mouth open ×1") })
    }

    func testGuideNeverDrivesTheRealCursor() {
        // The guide builds its controllers with a counting sink only; the module has no path from GuidedRun to CursorDriver.
        let g = GuidedRun(profile: calibratedProfile(), screen: scr)
        let u = GuideSynthUser()
        let before = CursorDriver().currentPosition
        run(g, u) { $0.stage == .summary }
        let after = CursorDriver().currentPosition
        XCTAssertEqual(before, after, "the real cursor did not move during a full guided run")
    }
}
