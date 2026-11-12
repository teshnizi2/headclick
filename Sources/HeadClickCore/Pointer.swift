import Foundation
import CoreGraphics
import ApplicationServices

/// One Euro filter (Casiez et al.): smooth when still, responsive when moving.
public struct OneEuro {
    public var minCutoff = 0.4, beta = 0.04, dCutoff = 1.0
    private var x: Double?, dx = 0.0, t = 0.0
    public init() {}
    public mutating func reset() { x = nil; dx = 0 }
    private func alpha(_ cutoff: Double, _ dt: Double) -> Double { let r = 2 * Double.pi * cutoff * dt; return r / (r + 1) }
    public mutating func filter(_ v: Double, at time: Double) -> Double {
        guard let px = x else { x = v; t = time; return v }
        let dt = max(1e-3, time - t); t = time
        let d = (v - px) / dt
        dx += alpha(dCutoff, dt) * (d - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let nx = px + alpha(cutoff, dt) * (v - px)
        x = nx
        return nx
    }
}

/// Relative head pointer: head angle changes move the cursor like a mouse, with a speed-dependent gain.
public final class HeadPointer {
    public var settings = PointerSettings()
    public var bounds: CGRect
    public private(set) var position: CGPoint
    private var fy = OneEuro(), fp = OneEuro()
    private var last: (Double, Double)?
    private var acc = (0.0, 0.0)
    public private(set) var speedDegPerSec = 0.0

    public init(bounds: CGRect, position: CGPoint) { self.bounds = bounds; self.position = position }

    public func warp(to p: CGPoint) { position = clamp(p) }
    public func resetFilters() { fy.reset(); fp.reset(); last = nil; acc = (0, 0) }

    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1), y: min(max(p.y, bounds.minY), bounds.maxY - 1))
    }

    /// Feed one pose sample. When `frozen`, the reference angle is tracked but the cursor stays put.
    @discardableResult
    public func update(t: Double, yaw: Double, pitch: Double, frozen: Bool) -> CGPoint {
        let ys = fy.filter(yaw, at: t), ps = fp.filter(pitch, at: t)
        defer { last = (ys, ps) }
        guard let l = last else { return position }
        var dy = ys - l.0, dp = ps - l.1
        let dt = 1.0 / 30
        speedDegPerSec = (dy * dy + dp * dp).squareRoot() / dt
        if frozen { acc = (0, 0); return position }
        // Dead zone as an accumulator so slow, deliberate movement still gets through.
        acc.0 += dy; acc.1 += dp
        dy = 0; dp = 0
        if abs(acc.0) >= settings.deadZoneDeg { dy = acc.0; acc.0 = 0 }
        if abs(acc.1) >= settings.deadZoneDeg { dp = acc.1; acc.1 = 0 }
        let mult = 1 + settings.acceleration * speedDegPerSec
        let sx = settings.invertX ? -1.0 : 1.0, sy = settings.invertY ? -1.0 : 1.0
        position = clamp(CGPoint(x: position.x + sx * dy * settings.gainX * mult, y: position.y + sy * dp * settings.gainY * mult))
        return position
    }
}

public enum MouseButton { case left, right, middle }

public protocol CursorSink: AnyObject {
    var currentPosition: CGPoint { get }
    func move(to p: CGPoint, dragging: Bool)
    func button(_ b: MouseButton, down: Bool, at p: CGPoint, clickState: Int)
    func scroll(pixelsY: Double)
}

public extension CursorSink {
    func click(_ b: MouseButton, at p: CGPoint, count: Int = 1) {
        for i in 1...count {
            button(b, down: true, at: p, clickState: i)
            button(b, down: false, at: p, clickState: i)
        }
    }
}

/// Posts real mouse events. Needs the Accessibility permission.
public final class CursorDriver: CursorSink {
    public init() {}
    public static var isTrusted: Bool { AXIsProcessTrusted() }
    public static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    public var currentPosition: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public func move(to p: CGPoint, dragging: Bool) {
        let e = CGEvent(mouseEventSource: nil, mouseType: dragging ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        e?.post(tap: .cghidEventTap)
    }

    public func button(_ b: MouseButton, down: Bool, at p: CGPoint, clickState: Int) {
        let type: CGEventType, btn: CGMouseButton
        switch (b, down) {
        case (.left, true): type = .leftMouseDown; btn = .left
        case (.left, false): type = .leftMouseUp; btn = .left
        case (.right, true): type = .rightMouseDown; btn = .right
        case (.right, false): type = .rightMouseUp; btn = .right
        case (.middle, true): type = .otherMouseDown; btn = .center
        case (.middle, false): type = .otherMouseUp; btn = .center
        }
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: btn)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e?.post(tap: .cghidEventTap)
    }

    public func scroll(pixelsY: Double) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(pixelsY.rounded()), wheel2: 0, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }
}
