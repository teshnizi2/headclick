import Foundation
import CoreGraphics

/// Gaze features from one face frame: iris position inside each eye, head angles and face position in the image.
public enum GazeFeatures {
    static let aspect: Float = 640.0 / 480.0   // landmarks are normalised per axis; scale x so distances are isotropic

    public static func extract(_ f: FaceFrame) -> [Double]? {
        let L = f.landmarks
        guard L.count >= 478 else { return nil }
        func p(_ i: Int) -> SIMD2<Float> { SIMD2(L[i].x * aspect, L[i].y) }
        func eye(outer: Int, inner: Int, upper: Int, lower: Int, iris: Int, reversed: Bool) -> (Float, Float)? {
            let a = p(outer), b = p(inner), ir = p(iris)
            let axis = b - a
            let w = (axis.x * axis.x + axis.y * axis.y).squareRoot()
            guard w > 1e-4 else { return nil }
            let u = axis / w, n = SIMD2<Float>(-u.y, u.x)       // along the eye, and perpendicular to it
            let mid = (p(upper) + p(lower)) / 2
            let rel = ir - a, relMid = mid - (a + b) / 2
            let h = (rel.x * u.x + rel.y * u.y) / w - 0.5
            let v = ((ir - mid).x * n.x + (ir - mid).y * n.y) / w
            _ = relMid
            return (reversed ? -h : h, v)
        }
        // User's right eye = image left: corners 33 (outer) -> 133 (inner). Left eye: 362 (inner) -> 263 (outer).
        guard let r = eye(outer: 33, inner: 133, upper: 159, lower: 145, iris: 468, reversed: false),
              let l = eye(outer: 362, inner: 263, upper: 386, lower: 374, iris: 473, reversed: false) else { return nil }
        let nose = p(1)
        return [Double(r.0), Double(r.1), Double(l.0), Double(l.1),
                Double((r.0 + l.0) / 2), Double((r.1 + l.1) / 2),
                Double(f.yaw), Double(f.pitch), Double(nose.x), Double(nose.y)]
    }
}

/// Ridge regression from gaze features to screen points. Features are standardised, the bias is not penalised.
public final class GazeEstimator: Codable {
    public private(set) var mean: [Double] = []
    public private(set) var std: [Double] = []
    public private(set) var wx: [Double] = []
    public private(set) var wy: [Double] = []
    public var isCalibrated: Bool { !wx.isEmpty }
    public init() {}
    public func adopt(_ o: GazeEstimator) { mean = o.mean; std = o.std; wx = o.wx; wy = o.wy }

    public func fit(_ samples: [([Double], CGPoint)], lambda: Double = 1.0) {
        guard let n = samples.first?.0.count, samples.count >= 4 else { return }
        var mu = [Double](repeating: 0, count: n), sd = [Double](repeating: 0, count: n)
        for s in samples { for i in 0..<n { mu[i] += s.0[i] } }
        mu = mu.map { $0 / Double(samples.count) }
        for s in samples { for i in 0..<n { sd[i] += (s.0[i] - mu[i]) * (s.0[i] - mu[i]) } }
        sd = sd.map { max(1e-6, ($0 / Double(samples.count)).squareRoot()) }
        let m = n + 1
        var A = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        var bx = [Double](repeating: 0, count: m), by = bx
        for s in samples {
            var x = [1.0] + (0..<n).map { (s.0[$0] - mu[$0]) / sd[$0] }
            for i in 0..<m { for j in 0..<m { A[i][j] += x[i] * x[j] }; bx[i] += x[i] * Double(s.1.x); by[i] += x[i] * Double(s.1.y) }
            x.removeAll()
        }
        for i in 1..<m { A[i][i] += lambda * Double(samples.count) / 10 }
        guard let sx = GazeEstimator.solve(A, bx), let sy = GazeEstimator.solve(A, by) else { return }
        mean = mu; std = sd; wx = sx; wy = sy
    }

    public func estimate(_ feat: [Double]) -> CGPoint? {
        guard isCalibrated, feat.count == mean.count else { return nil }
        var x = wx[0], y = wy[0]
        for i in 0..<mean.count { let z = (feat[i] - mean[i]) / std[i]; x += wx[i + 1] * z; y += wy[i + 1] * z }
        return CGPoint(x: x, y: y)
    }

    static func solve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var M = A, v = b
        for c in 0..<n {
            var piv = c
            for r in c..<n where abs(M[r][c]) > abs(M[piv][c]) { piv = r }
            guard abs(M[piv][c]) > 1e-12 else { return nil }
            M.swapAt(c, piv); v.swapAt(c, piv)
            for r in (c + 1)..<max(n, c + 1) {
                let k = M[r][c] / M[c][c]
                for j in c..<n { M[r][j] -= k * M[c][j] }
                v[r] -= k * v[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = v[r]
            for j in (r + 1)..<max(n, r + 1) { s -= M[r][j] * x[j] }
            x[r] = s / M[r][r]
        }
        return x
    }

    // MARK: persistence
    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HeadClick")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gaze.json")
    }
    public func save() { try? JSONEncoder().encode(self).write(to: GazeEstimator.fileURL) }
    public static func load() -> GazeEstimator {
        (try? JSONDecoder().decode(GazeEstimator.self, from: Data(contentsOf: fileURL))) ?? GazeEstimator()
    }
}

/// Gaze jump ("MAGIC pointing"): when the smoothed gaze point is far from the cursor and stable, jump there; the head fine-tunes.
/// `onlyMode` = gaze-only comparison mode: the cursor follows the smoothed gaze point.
public final class GazeJumper: GazeJump {
    public let estimator: GazeEstimator
    public var onlyMode = false
    public var jumpDistance = 250.0
    public var stableWindow = 0.15
    public var cooldown = 0.8
    private var samples: [(Double, CGPoint)] = []
    private var lastJump = -10.0
    public private(set) var lastEstimate: CGPoint?

    public init(estimator: GazeEstimator) { self.estimator = estimator }

    public func target(frame: FaceFrame, now: Double, cursor: CGPoint) -> CGPoint? {
        guard let feat = GazeFeatures.extract(frame), let p = estimator.estimate(feat) else { return nil }
        lastEstimate = p
        samples.append((now, p))
        let window = onlyMode ? 0.35 : stableWindow
        samples.removeAll { now - $0.0 > window }
        guard samples.count >= 3, now - samples[0].0 >= window * 0.75 else { return nil }
        let mx = samples.map { Double($0.1.x) }.reduce(0, +) / Double(samples.count)
        let my = samples.map { Double($0.1.y) }.reduce(0, +) / Double(samples.count)
        let c = CGPoint(x: mx, y: my)
        let dist = hypot(mx - Double(cursor.x), my - Double(cursor.y))
        if onlyMode { return dist > 25 ? c : nil }
        let spread = samples.map { hypot(Double($0.1.x) - mx, Double($0.1.y) - my) }.max() ?? 0
        guard dist > jumpDistance, spread < 90, now - lastJump > cooldown else { return nil }
        lastJump = now
        return c
    }

    public func reset() { samples.removeAll() }
}

/// 9-point calibration followed by a 4-point accuracy check. The UI shows `target` (screen points) and feeds frames.
public final class GazeCalibrator: ObservableObject {
    public enum Phase { case calibrate, check, done }
    let screen: CGRect
    let cmPerPx: Double
    public let estimator = GazeEstimator()
    @Published public private(set) var target: CGPoint
    @Published public private(set) var prompt = "Look at the dot"
    @Published public private(set) var finished = false
    @Published public private(set) var failed = false
    @Published public private(set) var result = ""
    @Published public private(set) var progress = 0.0
    public private(set) var meanErrorCm = 0.0
    public private(set) var phase = Phase.calibrate

    static let settle = 0.9, collect = 1.1
    let calPoints: [CGPoint], checkPoints: [CGPoint]
    var index = 0
    var stepStart: Double?
    var feats: [[Double]] = []
    var samples: [([Double], CGPoint)] = []
    var errors: [Double] = []

    public init(screen: CGRect, screenWidthCm: Double) {
        self.screen = screen
        cmPerPx = screenWidthCm / Double(screen.width)
        func pt(_ fx: Double, _ fy: Double) -> CGPoint { CGPoint(x: screen.minX + screen.width * fx, y: screen.minY + screen.height * fy) }
        var cal: [CGPoint] = []
        for fy in [0.08, 0.5, 0.92] { for fx in [0.06, 0.5, 0.94] { cal.append(pt(fx, fy)) } }
        calPoints = cal
        checkPoints = [pt(0.25, 0.25), pt(0.75, 0.25), pt(0.25, 0.75), pt(0.75, 0.75)]
        target = cal[0]
    }

    public func feed(_ f: FaceFrame?, now: Double) {
        guard !finished else { return }
        if stepStart == nil { stepStart = now }
        let t = now - stepStart!
        progress = min(1, t / (Self.settle + Self.collect))
        if t >= Self.settle, let f, let x = GazeFeatures.extract(f) { feats.append(x) }
        guard t >= Self.settle + Self.collect else { return }
        completeStep()
    }

    func completeStep() {
        let n = feats.count
        stepStart = nil
        guard n >= 8 else {
            if n < 8 { fail("Face or eyes not tracked well enough at point \(index + 1). Sit centred, keep the screen lit and try again.") }
            return
        }
        switch phase {
        case .calibrate:
            for x in feats { samples.append((x, calPoints[index])) }
            feats = []
            index += 1
            if index < calPoints.count { target = calPoints[index]; return }
            estimator.fit(samples)
            guard estimator.isCalibrated else { fail("Could not fit the gaze model."); return }
            phase = .check; index = 0; target = checkPoints[0]; prompt = "Accuracy check: look at the dot"
        case .check:
            // Median of the estimates over the point.
            let ests = feats.compactMap { estimator.estimate($0) }
            let mx = ests.map { Double($0.x) }.sorted()[ests.count / 2], my = ests.map { Double($0.y) }.sorted()[ests.count / 2]
            errors.append(hypot(mx - Double(checkPoints[index].x), my - Double(checkPoints[index].y)) * cmPerPx)
            feats = []
            index += 1
            if index < checkPoints.count { target = checkPoints[index]; return }
            meanErrorCm = errors.reduce(0, +) / Double(errors.count)
            phase = .done; finished = true
            let px = meanErrorCm / cmPerPx
            result = String(format: "Mean gaze error %.1f cm (%.0f px) over %d check points. %@", meanErrorCm, px, errors.count,
                            meanErrorCm < 4 ? "Good enough for gaze jump." : "Rough: gaze jump will land near the target and the head fine-tunes. Try again sitting closer and more centred.")
        case .done: break
        }
    }

    func fail(_ msg: String) { failed = true; finished = true; result = msg }
}
