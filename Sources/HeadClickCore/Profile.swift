import Foundation

public enum Action: String, Codable, CaseIterable, Identifiable {
    case leftClick, rightClick, doubleClick, middleClick, drag, scrollUp, scrollDown, pauseToggle, recenter
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .leftClick: "Left click"
        case .rightClick: "Right click"
        case .doubleClick: "Double click"
        case .middleClick: "Middle click"
        case .drag: "Drag (hold)"
        case .scrollUp: "Scroll up"
        case .scrollDown: "Scroll down"
        case .pauseToggle: "Pause / resume"
        case .recenter: "Recenter cursor"
        }
    }
    /// Triggers that make sense for this action.
    public var triggers: [Trigger] {
        switch self {
        case .drag: [.hold]
        case .scrollUp, .scrollDown: [.continuous]
        case .pauseToggle: [.tap, .long]
        default: [.tap, .long]
        }
    }
}

public enum Trigger: String, Codable, CaseIterable {
    case tap, hold, long, continuous
    public var title: String {
        switch self {
        case .tap: "quick"
        case .hold: "hold"
        case .long: "hold 1.2 s"
        case .continuous: "while held"
        }
    }
}

public struct GestureBinding: Codable, Equatable, Hashable, Identifiable {
    public var action: Action
    public var gesture: GestureID
    public var trigger: Trigger
    public var id: String { action.rawValue }
    public init(_ action: Action, _ gesture: GestureID, _ trigger: Trigger) {
        self.action = action; self.gesture = gesture; self.trigger = trigger
    }
}

public enum Sensitivity: String, Codable, CaseIterable {
    case slight, normal, exaggerated
    public var onThreshold: Float { switch self { case .slight: 0.35; case .normal: 0.5; case .exaggerated: 0.7 } }
    public var title: String { switch self { case .slight: "Slight"; case .normal: "Default"; case .exaggerated: "Exaggerated" } }
}

/// Per-gesture user data: calibrated levels, sensitivity and the result of the talk test.
public struct GestureTuning: Codable, Equatable, Hashable {
    public var neutral: Float?
    public var peak: Float?
    public var onThreshold: Float?
    public var talkRisk: Bool = false
    public init() {}
}

public struct PointerSettings: Codable, Equatable, Hashable {
    /// Pixels per degree of head turn. Set by pointer calibration.
    public var gainX: Double = 55
    public var gainY: Double = 65
    /// Extra gain for fast movement (0 = none).
    public var acceleration: Double = 0.012
    public var deadZoneDeg: Double = 0.12
    public var invertX = false
    public var invertY = false
    public var invertScroll = false
    public var calibrated = false
    public init() {}
}

public struct Profile: Codable, Equatable, Hashable {
    public var name: String
    public var bindings: [GestureBinding]
    public var tuning: [String: GestureTuning] = [:]
    public var pointer = PointerSettings()
    /// Swap what MediaPipe calls left/right (set from the wink check if your left wink moves the right one).
    public var swapLeftRight = false
    public var talkGuard = true
    public var gazeJump = false

    public init(name: String, bindings: [GestureBinding]) { self.name = name; self.bindings = bindings }

    public func binding(for action: Action) -> GestureBinding? { bindings.first { $0.action == action } }
    public func tuning(_ g: GestureID) -> GestureTuning { tuning[g.rawValue] ?? GestureTuning() }
    public mutating func setBinding(_ action: Action, gesture: GestureID?, trigger: Trigger) {
        bindings.removeAll { $0.action == action }
        if let gesture { bindings.append(GestureBinding(action, gesture, trigger)) }
    }

    public static let quietDesk = Profile(name: "Quiet desk", bindings: [
        GestureBinding(.leftClick, .mouthOpen, .tap), GestureBinding(.drag, .mouthOpen, .hold),
        GestureBinding(.rightClick, .pucker, .tap), GestureBinding(.doubleClick, .browRaise, .tap),
        GestureBinding(.scrollUp, .tiltLeft, .continuous), GestureBinding(.scrollDown, .tiltRight, .continuous),
        GestureBinding(.pauseToggle, .longBlink, .long), GestureBinding(.recenter, .headShake, .tap),
    ])
    public static let talkSafe = Profile(name: "Talk-safe", bindings: [
        GestureBinding(.leftClick, .winkLeft, .tap), GestureBinding(.rightClick, .winkRight, .tap),
        GestureBinding(.doubleClick, .doubleBlink, .tap), GestureBinding(.drag, .winkLeft, .hold),
        GestureBinding(.scrollUp, .tiltLeft, .continuous), GestureBinding(.scrollDown, .tiltRight, .continuous),
        GestureBinding(.pauseToggle, .longBlink, .long), GestureBinding(.recenter, .headShake, .tap),
    ])
    public static let eyesOnly = Profile(name: "Eyes only", bindings: [
        GestureBinding(.leftClick, .doubleBlink, .tap), GestureBinding(.rightClick, .longBlink, .tap),
        GestureBinding(.scrollUp, .tiltLeft, .continuous), GestureBinding(.scrollDown, .tiltRight, .continuous),
        GestureBinding(.pauseToggle, .longBlink, .long), GestureBinding(.recenter, .headShake, .tap),
    ])
    public static let expressive = Profile(name: "Expressive", bindings: [
        GestureBinding(.leftClick, .smile, .tap), GestureBinding(.rightClick, .smirkRight, .tap),
        GestureBinding(.doubleClick, .browRaise, .tap), GestureBinding(.drag, .cheekPuff, .hold),
        GestureBinding(.scrollUp, .mouthLeft, .continuous), GestureBinding(.scrollDown, .mouthRight, .continuous),
        GestureBinding(.pauseToggle, .longBlink, .long), GestureBinding(.recenter, .headShake, .tap),
    ])
    public static let builtIn: [Profile] = [quietDesk, talkSafe, eyesOnly, expressive]
}

/// Profiles as JSON files in ~/Library/Application Support/HeadClick/.
public enum ProfileStore {
    public static var directory: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HeadClick/profiles")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func url(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent(safe + ".json")
    }
    public static func encode(_ p: Profile) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(p)
    }
    public static func decode(_ d: Data) throws -> Profile { try JSONDecoder().decode(Profile.self, from: d) }
    public static func save(_ p: Profile) { try? encode(p).write(to: url(p.name)) }
    public static func loadAll() -> [Profile] {
        var all = builtIn()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let p = try? decode(d) {
                if let i = all.firstIndex(where: { $0.name == p.name }) { all[i] = p } else { all.append(p) }
            }
        }
        return all
    }
    static func builtIn() -> [Profile] { Profile.builtIn }
    public static var currentKey = "HeadClick.currentProfile"
}
