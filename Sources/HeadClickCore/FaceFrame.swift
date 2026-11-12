import Foundation

/// The 52 MediaPipe face blendshapes, in the model's own order.
public enum Blend: Int, CaseIterable {
    case neutral, browDownLeft, browDownRight, browInnerUp, browOuterUpLeft, browOuterUpRight
    case cheekPuff, cheekSquintLeft, cheekSquintRight, eyeBlinkLeft, eyeBlinkRight
    case eyeLookDownLeft, eyeLookDownRight, eyeLookInLeft, eyeLookInRight
    case eyeLookOutLeft, eyeLookOutRight, eyeLookUpLeft, eyeLookUpRight
    case eyeSquintLeft, eyeSquintRight, eyeWideLeft, eyeWideRight
    case jawForward, jawLeft, jawOpen, jawRight
    case mouthClose, mouthDimpleLeft, mouthDimpleRight, mouthFrownLeft, mouthFrownRight
    case mouthFunnel, mouthLeft, mouthLowerDownLeft, mouthLowerDownRight
    case mouthPressLeft, mouthPressRight, mouthPucker, mouthRight, mouthRollLower, mouthRollUpper
    case mouthShrugLower, mouthShrugUpper, mouthSmileLeft, mouthSmileRight
    case mouthStretchLeft, mouthStretchRight, mouthUpperUpLeft, mouthUpperUpRight
    case noseSneerLeft, noseSneerRight

    public var modelName: String { self == .neutral ? "_neutral" : "\(self)" }
    public static let byName: [String: Blend] = Dictionary(uniqueKeysWithValues: allCases.map { ($0.modelName, $0) })
}

/// One processed camera frame: blendshapes, landmarks and head pose.
/// Angles are degrees: yaw > 0 = head turned to the user's right, pitch > 0 = head down,
/// roll > 0 = head tilted toward the user's right shoulder.
public struct FaceFrame {
    public var time: Double = 0
    public var blend = [Float](repeating: 0, count: Blend.allCases.count)
    public var landmarks: [SIMD3<Float>] = []
    public var yaw: Float = 0
    public var pitch: Float = 0
    public var roll: Float = 0
    public var scale: Float = 1
    public var engineMs: Double = 0

    public init() {}
    public init(time: Double, yaw: Float = 0, pitch: Float = 0, roll: Float = 0, blend: [Blend: Float] = [:]) {
        self.time = time; self.yaw = yaw; self.pitch = pitch; self.roll = roll
        for (k, v) in blend { self.blend[k.rawValue] = v }
    }
    public subscript(b: Blend) -> Float {
        get { blend[b.rawValue] }
        set { blend[b.rawValue] = newValue }
    }
}

public enum HeadPose {
    /// Euler angles in degrees from MediaPipe's 4x4 facial transformation matrix.
    /// Handles both row-major and column-major storage (detected from where the translation sits).
    public static func angles(matrix m: [Float]) -> (yaw: Float, pitch: Float, roll: Float, scale: Float)? {
        guard m.count == 16 else { return nil }
        let rowMajor = abs(m[15] - 1) < 1e-3 && abs(m[12]) < 1e-3 && abs(m[13]) < 1e-3 && abs(m[14]) < 1e-3
        func r(_ row: Int, _ col: Int) -> Float { rowMajor ? m[row * 4 + col] : m[col * 4 + row] }
        // Third column = where the face's forward axis (+z, toward the camera) points; second = up.
        let fx = r(0, 2), fy = r(1, 2), fz = r(2, 2)
        let ux = r(0, 1), uy = r(1, 1)
        let scale = (r(0, 0) * r(0, 0) + r(1, 0) * r(1, 0) + r(2, 0) * r(2, 0)).squareRoot()
        guard scale > 1e-6 else { return nil }
        let d: Float = 180 / .pi
        // Camera image is not mirrored: the user's right is image-left (-x).
        let yaw = -atan2(fx, fz) * d
        let pitch = -asin(max(-1, min(1, fy / scale))) * d
        let roll = -atan2(ux, uy) * d
        return (yaw, pitch, roll, scale)
    }
}
