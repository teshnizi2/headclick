import Foundation

public enum GestureGroup: String { case eyes, brows, mouth, head }

public enum GestureID: String, Codable, CaseIterable, Identifiable {
    case mouthOpen, smile, pucker, browRaise, browFurrow
    case winkLeft, winkRight, doubleBlink, longBlink
    case mouthLeft, mouthRight, tiltLeft, tiltRight
    case smirkLeft, smirkRight, cheekPuff, noseScrunch, jawLeft, jawRight, lipsPressed
    case headNod, headShake
    public var id: String { rawValue }
}

/// How a gesture is measured and what its natural click timing is.
public struct GestureSpec {
    public let id: GestureID
    public let title: String
    public let group: GestureGroup
    /// Raw signal from a frame (blendshape value, or degrees for head tilt).
    public let signal: (FaceFrame) -> Float
    /// Defaults used until the user calibrates: resting level and a typical full gesture.
    public let neutral: Float
    public let peak: Float
    /// A tap must stay on at least `minHold` and at most `maxHold` seconds.
    public let minHold: Double
    public let maxHold: Double
    /// Tap fires the moment minHold is reached (no wait for release), if no hold/long binding exists.
    public let earlyTap: Bool
    /// Two taps within 0.5 s count as one event (double blink).
    public let doublePattern: Bool
    /// Muted by the talk guard (mouth and brow movements happen while speaking).
    public let talkSensitive: Bool
    /// Moving the head with this gesture would drag the head pointer.
    public let note: String?
    /// Head events (nod, shake) are detected from pose history, not from a signal.
    public let isPoseEvent: Bool
}

public enum Catalog {
    static func avg(_ f: FaceFrame, _ a: Blend, _ b: Blend) -> Float { (f[a] + f[b]) / 2 }

    public static let specs: [GestureID: GestureSpec] = {
        func s(_ id: GestureID, _ title: String, _ group: GestureGroup, neutral: Float, peak: Float,
               minHold: Double = 0.12, maxHold: Double = 0.6, early: Bool = true, double: Bool = false,
               talk: Bool = false, note: String? = nil, pose: Bool = false, _ sig: @escaping (FaceFrame) -> Float) -> GestureSpec {
            GestureSpec(id: id, title: title, group: group, signal: sig, neutral: neutral, peak: peak, minHold: minHold,
                        maxHold: maxHold, earlyTap: early, doublePattern: double, talkSensitive: talk, note: note, isPoseEvent: pose)
        }
        let list: [GestureSpec] = [
            s(.mouthOpen, "Mouth open", .mouth, neutral: 0.03, peak: 0.45, talk: true) { $0[.jawOpen] },
            s(.smile, "Smile", .mouth, neutral: 0.10, peak: 0.70, talk: true, note: "Fires when you laugh or react") { avg($0, .mouthSmileLeft, .mouthSmileRight) },
            s(.pucker, "Pucker (kiss)", .mouth, neutral: 0.03, peak: 0.55, talk: true) { $0[.mouthPucker] },
            s(.browRaise, "Raise eyebrows", .brows, neutral: 0.05, peak: 0.55, talk: true) { f in (f[.browInnerUp] + avg(f, .browOuterUpLeft, .browOuterUpRight)) / 2 },
            s(.browFurrow, "Frown (brows down)", .brows, neutral: 0.15, peak: 0.75, talk: true, note: "Fires when concentrating") { avg($0, .browDownLeft, .browDownRight) },
            s(.winkLeft, "Wink left eye", .eyes, neutral: 0.05, peak: 0.80, minHold: 0.12, maxHold: 0.7, early: false) { max(0, $0[.eyeBlinkLeft] - $0[.eyeBlinkRight]) },
            s(.winkRight, "Wink right eye", .eyes, neutral: 0.05, peak: 0.80, minHold: 0.12, maxHold: 0.7, early: false) { max(0, $0[.eyeBlinkRight] - $0[.eyeBlinkLeft]) },
            s(.doubleBlink, "Double blink", .eyes, neutral: 0.15, peak: 0.80, minHold: 0.05, maxHold: 0.3, early: false, double: true) { min($0[.eyeBlinkLeft], $0[.eyeBlinkRight]) },
            s(.longBlink, "Long blink (eyes closed)", .eyes, neutral: 0.15, peak: 0.80, minHold: 0.5, maxHold: 1.0, early: false) { min($0[.eyeBlinkLeft], $0[.eyeBlinkRight]) },
            s(.mouthLeft, "Mouth to the left", .mouth, neutral: 0.03, peak: 0.45) { $0[.mouthLeft] },
            s(.mouthRight, "Mouth to the right", .mouth, neutral: 0.03, peak: 0.45) { $0[.mouthRight] },
            s(.tiltLeft, "Head tilt left", .head, neutral: 3, peak: 24, minHold: 0.25, maxHold: 1.5) { max(0, -$0.roll) },
            s(.tiltRight, "Head tilt right", .head, neutral: 3, peak: 24, minHold: 0.25, maxHold: 1.5) { max(0, $0.roll) },
            s(.smirkLeft, "Half smile left", .mouth, neutral: 0.05, peak: 0.55, talk: true) { max(0, $0[.mouthSmileLeft] - $0[.mouthSmileRight]) },
            s(.smirkRight, "Half smile right", .mouth, neutral: 0.05, peak: 0.55, talk: true) { max(0, $0[.mouthSmileRight] - $0[.mouthSmileLeft]) },
            s(.cheekPuff, "Cheek puff", .mouth, neutral: 0.03, peak: 0.45) { $0[.cheekPuff] },
            s(.noseScrunch, "Nose scrunch", .mouth, neutral: 0.05, peak: 0.45, talk: true) { avg($0, .noseSneerLeft, .noseSneerRight) },
            s(.jawLeft, "Jaw to the left", .mouth, neutral: 0.03, peak: 0.35) { $0[.jawLeft] },
            s(.jawRight, "Jaw to the right", .mouth, neutral: 0.03, peak: 0.35) { $0[.jawRight] },
            s(.lipsPressed, "Lips pressed", .mouth, neutral: 0.10, peak: 0.60, talk: true) { avg($0, .mouthPressLeft, .mouthPressRight) },
            s(.headNod, "Nod (yes)", .head, neutral: 0, peak: 1, note: "Moves the pointer; the click goes to where the cursor was", pose: true) { _ in 0 },
            s(.headShake, "Shake (no)", .head, neutral: 0, peak: 1, pose: true) { _ in 0 },
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }()

    public static func spec(_ id: GestureID) -> GestureSpec { specs[id]! }

    /// Gestures whose muscles overlap: when both are active, the weaker one is ignored.
    public static let coupled: [(GestureID, GestureID)] = [
        (.smile, .mouthOpen), (.smile, .smirkLeft), (.smile, .smirkRight), (.smile, .pucker),
        (.pucker, .mouthOpen), (.browRaise, .browFurrow), (.winkLeft, .doubleBlink), (.winkRight, .doubleBlink),
        (.winkLeft, .longBlink), (.winkRight, .longBlink), (.mouthLeft, .jawLeft), (.mouthRight, .jawRight),
        (.mouthLeft, .mouthRight), (.tiltLeft, .tiltRight), (.jawLeft, .jawRight), (.lipsPressed, .pucker),
    ]
}
