import XCTest
@testable import HeadClickCore

/// A guide run failed with "Long blink (eyes closed) was too small to measure (rest 0.64, peak 0.67)":
/// his natural blinks during the 3 s rest window raised the "rest" level (a 95th percentile) up to the closed-eye level.
final class LongBlinkCalibrationTests: XCTestCase {
    /// A user who blinks naturally while resting (0.2 s blink every 1.2 s: about 17% of the frames are blink frames),
    /// then closes both eyes firmly three times. MediaPipe's eyeBlink tops out around 0.67 for fully closed eyes.
    func calibrate(_ g: GestureID, closed: Float = 0.67, restBlink: Float = 0.64) -> Calibrator {
        let c = Calibrator(kind: .gesture(g), profile: .quietDesk, screen: screen)
        var t = 0.0
        while !c.finished && t < 30 {
            var v: Float = 0.08
            if c.stepNumber == 1 {
                if (t.truncatingRemainder(dividingBy: 1.2)) > 0.9 { v = restBlink }
            } else if c.progress > 0.12 && c.progress < 0.7 { v = closed }
            var f = FaceFrame(time: t)
            f[.eyeBlinkLeft] = v; f[.eyeBlinkRight] = v
            c.feed(f, now: t); t += dt
        }
        return c
    }

    func testLongBlinkPassesWithNaturalBlinksInTheRestWindow() {
        let c = calibrate(.longBlink)
        XCTAssertTrue(c.finished); XCTAssertFalse(c.failed, c.result)
        let t = c.apply(to: .quietDesk).tuning(.longBlink)
        XCTAssertLessThan(t.neutral ?? 1, 0.2, "rest is the typical level, not the blink level")
        XCTAssertGreaterThan(t.peak ?? 0, 0.6)
    }

    func testDoubleBlinkPassesWithNaturalBlinksInTheRestWindow() {
        let c = calibrate(.doubleBlink)
        XCTAssertFalse(c.failed, c.result)
        XCTAssertLessThan(c.apply(to: .quietDesk).tuning(.doubleBlink).neutral ?? 1, 0.2)
    }

    func testStillRejectsAFaintEyeClose() {
        let c = calibrate(.longBlink, closed: 0.15, restBlink: 0.08)
        XCTAssertTrue(c.failed, "closing hardly at all is still too small")
        XCTAssertTrue(c.result.contains("too small"))
    }

    func testMouthGesturesStillUseTheHighRestLevel() {
        // a mouth that keeps twitching during rest must not make the threshold too low: non-eye gestures keep p95
        let c = Calibrator(kind: .gesture(.mouthOpen), profile: .quietDesk, screen: screen)
        var t = 0.0
        while !c.finished && t < 30 {
            var f = FaceFrame(time: t)
            f[.jawOpen] = c.stepNumber == 1 ? (t.truncatingRemainder(dividingBy: 1.0) > 0.8 ? 0.25 : 0.03) : (c.progress > 0.12 && c.progress < 0.7 ? 0.8 : 0.03)
            c.feed(f, now: t); t += dt
        }
        XCTAssertFalse(c.failed, c.result)
        XCTAssertGreaterThan(c.apply(to: .quietDesk).tuning(.mouthOpen).neutral ?? 0, 0.2)
    }
}
