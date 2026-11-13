import Foundation
import CoreGraphics

/// Camera -> face engine -> consumer. Runs entirely on the camera queue.
public final class Pipeline {
    public let camera = Camera()
    public private(set) var engine: FaceEngine?
    /// Called on the camera queue for every processed frame; `nil` means no face was found.
    public var onResult: ((FaceFrame?, Double) -> Void)?
    public private(set) var fps: Double = 0
    public private(set) var engineMs: Double = 0
    public private(set) var framesSeen = 0
    private var lastTime: Double = 0
    public var lastError: String?
    /// Optional live picture (about 10 per second) for the guided start window. Nil = no pictures are made.
    public var onPreview: ((CGImage) -> Void)?

    public init() {}

    public func start(engine: FaceEngine? = nil) throws {
        self.engine = try engine ?? MediaPipeFaceEngine()
        camera.onFrame = { [weak self] rgba, w, h, t in self?.handle(rgba, w, h, t) }
        try camera.start()
    }

    public func stop() { camera.stop() }

    static func image(_ rgba: UnsafePointer<UInt8>, _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes: rgba, count: w * h * 4) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private func handle(_ rgba: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ t: Double) {
        framesSeen += 1
        if lastTime > 0, t > lastTime { let inst = 1 / (t - lastTime); fps = fps == 0 ? inst : fps * 0.9 + inst * 0.1 }
        lastTime = t
        if let cb = onPreview, framesSeen % 3 == 0, let img = Self.image(rgba, w, h) { cb(img) }
        do {
            let frame = try engine?.detect(rgba: rgba, width: w, height: h, time: t)
            if let f = frame { engineMs = engineMs == 0 ? f.engineMs : engineMs * 0.9 + f.engineMs * 0.1 }
            onResult?(frame, t)
        } catch {
            lastError = "\(error)"
            onResult?(nil, t)
        }
    }
}
