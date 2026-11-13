import XCTest
@testable import HeadClickCore

final class GazeTests: XCTestCase {
    /// Synthetic face: eye corners fixed, irises shifted by (gx, gy) in [-1, 1].
    func face(gx: Double, gy: Double, yaw: Float = 0, noise: Double = 0) -> FaceFrame {
        var f = FaceFrame(time: 0, yaw: yaw)
        f.landmarks = [SIMD3<Float>](repeating: SIMD3(0.5, 0.5, 0), count: 478)
        func set(_ i: Int, _ x: Float, _ y: Float) { f.landmarks[i] = SIMD3(x, y, 0) }
        let n = { Float(noise * Double.random(in: -1...1)) }
        set(1, 0.5, 0.5)
        set(33, 0.38, 0.40); set(133, 0.46, 0.40); set(159, 0.42, 0.385); set(145, 0.42, 0.415)
        set(362, 0.54, 0.40); set(263, 0.62, 0.40); set(386, 0.58, 0.385); set(374, 0.58, 0.415)
        set(468, 0.42 + Float(gx) * 0.02 + n(), 0.40 + Float(gy) * 0.008 + n())
        set(473, 0.58 + Float(gx) * 0.02 + n(), 0.40 + Float(gy) * 0.008 + n())
        return f
    }

    func testRegressionRecoversScreenPoint() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func truth(_ gx: Double, _ gy: Double) -> CGPoint { CGPoint(x: 720 + gx * 700, y: 450 + gy * 430) }
        let est = GazeEstimator()
        var samples: [([Double], CGPoint)] = []
        for gy in [-0.9, 0, 0.9] { for gx in [-0.9, 0, 0.9] {
            for _ in 0..<25 { samples.append((try XCTUnwrap(GazeFeatures.extract(face(gx: gx, gy: gy, noise: 0.0004))), truth(gx, gy))) }
        } }
        est.fit(samples)
        XCTAssertTrue(est.isCalibrated)
        var worst = 0.0
        for (gx, gy) in [(-0.45, -0.45), (0.45, -0.45), (-0.45, 0.45), (0.45, 0.45)] {
            let p = try XCTUnwrap(est.estimate(try XCTUnwrap(GazeFeatures.extract(face(gx: gx, gy: gy)))))
            let t = truth(gx, gy)
            worst = max(worst, Double(hypot(p.x - t.x, p.y - t.y)))
        }
        XCTAssertLessThan(worst, 80, "synthetic gaze error in px")
        XCTAssertTrue(screen.contains(CGPoint(x: 700, y: 450)))
    }

    func testCalibratorRunsNinePlusFourAndReportsCm() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cal = GazeCalibrator(screen: screen, screenWidthCm: 30)
        var t = 0.0
        var guardCount = 0
        while !cal.finished && guardCount < 5000 {
            let tp = cal.target
            let gx = (Double(tp.x) - 720) / 700, gy = (Double(tp.y) - 450) / 430
            cal.feed(face(gx: gx, gy: gy, noise: 0.0004), now: t)
            t += 1 / 30; guardCount += 1
        }
        XCTAssertTrue(cal.finished); XCTAssertFalse(cal.failed, cal.result)
        XCTAssertLessThan(cal.meanErrorCm, 2.0, cal.result)
        XCTAssertGreaterThan(t, 9 * 1.0, "9 calibration dots take about 9.5 s")
        XCTAssertLessThan(t, 17, "13 dots in under 17 s")
    }

    func testJumperJumpsOnlyWhenFarAndStable() throws {
        let est = GazeEstimator()
        var samples: [([Double], CGPoint)] = []
        for gy in [-0.9, 0, 0.9] { for gx in [-0.9, 0, 0.9] {
            for _ in 0..<10 { samples.append((GazeFeatures.extract(face(gx: gx, gy: gy, noise: 0.0004))!, CGPoint(x: 720 + gx * 700, y: 450 + gy * 430))) }
        } }
        est.fit(samples)
        let j = GazeJumper(estimator: est)
        // Looking at the right edge while the cursor is on the left: should jump after ~150 ms of steady gaze.
        var jumped: CGPoint?
        for i in 0..<30 { if let p = j.target(frame: face(gx: 0.9, gy: 0), now: Double(i) / 30, cursor: CGPoint(x: 100, y: 450)) { jumped = p; break } }
        let p = try XCTUnwrap(jumped)
        XCTAssertEqual(Double(p.x), 1350, accuracy: 120)
        // Near the cursor: no jump.
        let j2 = GazeJumper(estimator: est)
        for i in 0..<30 { XCTAssertNil(j2.target(frame: face(gx: 0, gy: 0), now: Double(i) / 30, cursor: CGPoint(x: 700, y: 450))) }
        // Flicking across: unstable, no jump.
        let j3 = GazeJumper(estimator: est)
        for i in 0..<30 { XCTAssertNil(j3.target(frame: face(gx: i % 2 == 0 ? -0.9 : 0.9, gy: 0), now: Double(i) / 30, cursor: CGPoint(x: 720, y: 450))) }
    }
}
