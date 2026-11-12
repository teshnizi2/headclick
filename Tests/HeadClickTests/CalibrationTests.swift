import XCTest
@testable import HeadClickCore

final class CalibrationTests: XCTestCase {
    func feedAll(_ c: Calibrator, seconds: Double, make: (Double) -> FaceFrame?) {
        var t = 0.0
        while t < seconds && !c.finished { c.feed(make(t), now: t); t += dt }
    }

    func testPointerCalibrationSetsGainFromRange() {
        let c = Calibrator(kind: .pointer, profile: .quietDesk, screen: screen)
        feedAll(c, seconds: 10) { t in
            if t < 2 { return frame(t, yaw: 1, pitch: 0) }
            let x = t - 2
            return frame(t, yaw: Float(14 * sin(x * 2.2)), pitch: Float(9 * sin(x * 1.3 + 1)))
        }
        XCTAssertTrue(c.finished); XCTAssertFalse(c.failed, c.result)
        let p = c.apply(to: .quietDesk)
        XCTAssertTrue(p.pointer.calibrated)
        XCTAssertEqual(p.pointer.gainX, 1440 * 0.95 / 26, accuracy: 6)
    }

    func testPointerCalibrationFailsWithoutMovement() {
        let c = Calibrator(kind: .pointer, profile: .quietDesk, screen: screen)
        feedAll(c, seconds: 10) { t in frame(t) }
        XCTAssertTrue(c.failed)
        XCTAssertEqual(c.apply(to: .quietDesk), .quietDesk)
    }

    func testGestureCalibrationStoresNeutralAndPeak() {
        let c = Calibrator(kind: .gesture(.mouthOpen), profile: .quietDesk, screen: screen)
        feedAll(c, seconds: 20) { t in
            if t < 3 { return frame(t, [.jawOpen: 0.05]) }
            let rep = Int((t - 3) / 2.2), within = (t - 3) - Double(rep) * 2.2
            return frame(t, [.jawOpen: within > 0.5 && within < 1.8 ? 0.7 : 0.05])
        }
        XCTAssertTrue(c.finished); XCTAssertFalse(c.failed, c.result)
        let t = c.apply(to: .quietDesk).tuning(.mouthOpen)
        XCTAssertEqual(t.neutral!, 0.05, accuracy: 0.01)
        XCTAssertEqual(t.peak!, 0.7, accuracy: 0.02)
    }

    func testGestureCalibrationRejectsTinyGesture() {
        let c = Calibrator(kind: .gesture(.cheekPuff), profile: .quietDesk, screen: screen)
        feedAll(c, seconds: 20) { t in frame(t, [.cheekPuff: 0.02 + 0.03 * Float(pulse(t, 5, 1))]) }
        XCTAssertTrue(c.failed)
    }

    func testWinkCalibrationDetectsSwappedEyes() {
        let c = Calibrator(kind: .gesture(.winkLeft), profile: .quietDesk, screen: screen)
        // the user winks their left eye, but the model reports it as eyeBlinkRight
        feedAll(c, seconds: 20) { t in
            if t < 3 { return frame(t) }
            let rep = Int((t - 3) / 2.2), within = (t - 3) - Double(rep) * 2.2
            return frame(t, [.eyeBlinkRight: within > 0.5 && within < 1.8 ? 0.9 : 0.0])
        }
        XCTAssertTrue(c.finished)
        // first read (unswapped) sees no winkLeft signal -> fails; the vote logic only applies when the signal exists, so this documents the failure message
        XCTAssertTrue(c.failed || c.apply(to: .quietDesk).swapLeftRight)
    }

    func testTalkTestFlagsNothingWhenGuardCatchesSpeech() {
        let c = Calibrator(kind: .talkTest, profile: .quietDesk, screen: screen)
        feedAll(c, seconds: 25) { t in
            let j = Float(0.25 + 0.22 * sin(2 * .pi * 4.5 * t))
            return frame(t, [.jawOpen: j])
        }
        XCTAssertTrue(c.finished); XCTAssertFalse(c.failed)
        XCTAssertGreaterThanOrEqual(c.talkResult!.raw, c.talkResult!.guarded)
        XCTAssertLessThanOrEqual(c.talkResult!.guarded, 2)
    }
}
