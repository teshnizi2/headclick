import Foundation
import CoreGraphics
import ApplicationServices

/// How the cursor is driven. `gaze` (default in the app): the cursor goes where the eyes look, the head does not matter.
/// `head`: the older relative head pointer (an option in Settings).
public enum PointerMode: String, Codable, CaseIterable {
    case gaze, head
    public var title: String { self == .gaze ? "Eyes (where I look)" : "Head (relative, like a mouse)" }
}

/// Finds clickable things (buttons, links, menu items...) near a point. The real one uses Accessibility.
public protocol ClickTargetFinder: AnyObject {
    func targetRects(near p: CGPoint, radius: CGFloat) -> [CGRect]
}

public enum SnapPicker {
    /// The centre of the nearest rectangle whose edge is within `radius` of `gaze`; nil if none is.
    public static func pick(gaze: CGPoint, rects: [CGRect], radius: CGFloat) -> CGPoint? {
        var best: (CGFloat, CGRect)?
        for r in rects where r.width > 2 && r.height > 2 {
            let dx = max(r.minX - gaze.x, 0, gaze.x - r.maxX), dy = max(r.minY - gaze.y, 0, gaze.y - r.maxY)
            let d = hypot(dx, dy)
            if d <= radius, best == nil || d < best!.0 { best = (d, r) }
        }
        guard let r = best?.1 else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }
}

/// Turns the gaze estimate into a steady cursor position.
///  - strong smoothing with a fixation lock: while the eyes stay in one place (within `exitRadius`) the output does not shake,
///    it only drifts slowly; a real jump of the gaze (a saccade) moves it after about 0.1 s;
///  - eyes closed (blinks, winks, long blinks) freeze it, so a blink never throws the cursor around;
///  - optional snap: once the gaze has rested on one spot for 0.2 s, the cursor goes to the centre of the nearest clickable
///    element within `snapRadius`.
public final class GazePointer {
    public let estimator: GazeEstimator
    public var snapFinder: ClickTargetFinder?
    public var snapRadius: CGFloat = 60
    public var window = 0.25
    public var exitRadius = 70.0
    public var drift = 0.05
    public var blinkGrace = 0.15

    public private(set) var position: CGPoint?
    /// The latest unsmoothed estimate (for the debug picture).
    public private(set) var raw: CGPoint?
    public private(set) var snapped = false

    private var samples: [(Double, CGPoint)] = []
    private var fixation: CGPoint?
    private var fixationID = 0
    private var fixSince = 0.0
    private var lastClosed = -10.0
    private var snapAskedFor = -1
    private let lock = NSLock()
    private var snapResult: (id: Int, point: CGPoint?)?
    private let snapQueue = DispatchQueue(label: "headclick.snap", qos: .userInitiated)
    /// Tests set this to find targets synchronously.
    public var synchronousSnap = false

    public init(estimator: GazeEstimator) { self.estimator = estimator }

    public func reset() {
        samples.removeAll(); fixation = nil; position = nil; snapped = false; snapAskedFor = -1
        lock.lock(); snapResult = nil; lock.unlock()
    }

    /// Feed one frame. Returns the cursor position (nil until a calibrated estimate exists).
    @discardableResult
    public func update(_ f: FaceFrame, now: Double, eyesClosed: Bool = false) -> CGPoint? {
        if eyesClosed { lastClosed = now; return position }
        if now - lastClosed < blinkGrace { return position }
        guard let feat = GazeFeatures.extract(f), let p = estimator.estimate(feat) else { return position }
        raw = p
        samples.append((now, p))
        samples.removeAll { now - $0.0 > window }
        guard samples.count >= 3 else { if position == nil { position = p }; return position }
        let m = CGPoint(x: Self.median(samples.map { Double($0.1.x) }), y: Self.median(samples.map { Double($0.1.y) }))
        guard let c = fixation else {
            fixation = m; position = m; fixSince = now; return m
        }
        if hypot(Double(m.x - c.x), Double(m.y - c.y)) > exitRadius {
            fixation = m; fixationID += 1; fixSince = now; snapped = false
            lock.lock(); snapResult = nil; lock.unlock()
        } else {
            fixation = CGPoint(x: c.x + CGFloat(drift) * (m.x - c.x), y: c.y + CGFloat(drift) * (m.y - c.y))
        }
        var out = fixation!
        if let finder = snapFinder {
            if now - fixSince >= 0.2, snapAskedFor != fixationID {
                snapAskedFor = fixationID
                let id = fixationID, at = out, r = snapRadius
                let work = { [weak self] in
                    let point = SnapPicker.pick(gaze: at, rects: finder.targetRects(near: at, radius: r), radius: r)
                    self?.lock.lock(); self?.snapResult = (id, point); self?.lock.unlock()
                }
                if synchronousSnap { work() } else { snapQueue.async(execute: work) }
            }
            lock.lock(); let res = snapResult; lock.unlock()
            if let res, res.id == fixationID, let pt = res.point { out = pt; snapped = true }
        }
        position = out
        return out
    }

    static func median(_ a: [Double]) -> CGFloat { CGFloat(a.sorted()[a.count / 2]) }
}

/// Finds clickable elements through Accessibility (AXUIElementCopyElementAtPosition around the point).
public final class AXClickTargets: ClickTargetFinder {
    private let system = AXUIElementCreateSystemWide()
    static let roles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem",
                                     "AXMenuButton", "AXComboBox", "AXTextField", "AXDisclosureTriangle", "AXTab"]
    public init() { AXUIElementSetMessagingTimeout(system, 0.08) }

    public func targetRects(near p: CGPoint, radius: CGFloat) -> [CGRect] {
        var probes = [p]
        for ring in [radius * 0.5, radius] {
            for k in 0..<8 { let a = Double(k) * .pi / 4; probes.append(CGPoint(x: p.x + ring * CGFloat(cos(a)), y: p.y + ring * CGFloat(sin(a)))) }
        }
        var rects: [CGRect] = []
        let me = getpid()
        for q in probes {
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(q.x), Float(q.y), &el) == .success, var e = el else { continue }
            var pid: pid_t = 0
            AXUIElementGetPid(e, &pid)
            if pid == me { continue }
            for _ in 0..<3 {
                if let r = Self.clickableRect(e) { if !rects.contains(r) { rects.append(r) }; break }
                var parent: AnyObject?
                guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success, let par = parent else { break }
                e = par as! AXUIElement
            }
        }
        return rects
    }

    static func clickableRect(_ e: AXUIElement) -> CGRect? {
        var role: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success, let r = role as? String, roles.contains(r) else { return nil }
        var pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pv = pos, let sv = size else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}

/// One-dot recentre: the user looks at the centre dot for about a second, and the gaze model's offset is shifted so the
/// estimate lands on it (fixes slow drift without redoing all 13 dots).
public final class DriftFixer: ObservableObject {
    public let target: CGPoint
    public let estimator: GazeEstimator
    @Published public private(set) var progress = 0.0
    @Published public private(set) var finished = false
    @Published public private(set) var failed = false
    @Published public private(set) var result = "Look at the dot."
    public private(set) var shift = CGPoint.zero
    public var settle = 0.5, collect = 1.0, maxShift = 400.0
    private var start: Double?
    private var estimates: [CGPoint] = []

    public init(estimator: GazeEstimator, screen: CGRect) {
        self.estimator = estimator
        target = CGPoint(x: screen.midX, y: screen.midY)
    }

    public func feed(_ f: FaceFrame?, now: Double) {
        guard !finished else { return }
        if start == nil { start = now }
        let t = now - start!
        progress = min(1, t / (settle + collect))
        if t >= settle, let f, let x = GazeFeatures.extract(f), let p = estimator.estimate(x) { estimates.append(p) }
        guard t >= settle + collect else { return }
        finished = true
        guard estimates.count >= 5, estimator.isCalibrated else { failed = true; result = "I could not see your eyes well enough. Try again."; return }
        let mx = GazePointer.median(estimates.map { Double($0.x) }), my = GazePointer.median(estimates.map { Double($0.y) })
        let dx = Double(target.x - mx), dy = Double(target.y - my)
        guard hypot(dx, dy) <= maxShift else { failed = true; result = "That is too far off for a quick fix: run the full eye calibration instead."; return }
        estimator.shiftBias(dx: dx, dy: dy)
        shift = CGPoint(x: dx, y: dy)
        result = String(format: "Recentred (moved %.0f px).", hypot(dx, dy))
    }
}
