import Foundation
import AVFoundation
import Accelerate

/// Captures the built-in camera at 640x480 and hands out RGBA frames.
public final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public typealias FrameHandler = (_ rgba: UnsafePointer<UInt8>, _ width: Int, _ height: Int, _ time: Double) -> Void
    public var onFrame: FrameHandler?
    public private(set) var deviceName: String = ""
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "headclick.camera", qos: .userInteractive)
    private var rgba = [UInt8]()

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    public static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }

    public override init() { super.init() }

    /// Starts capture. Throws if there is no camera or access was denied.
    public func start() throws {
        guard Self.authorization == .authorized else { throw EngineError.message("Camera access not granted") }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            throw EngineError.message("No camera found")
        }
        deviceName = device.localizedName
        // Center Stage crops and pans the picture, which would move the face and break calibration.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw EngineError.message("Cannot use camera input") }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw EngineError.message("Cannot read camera output") }
        session.addOutput(out)
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
        session.startRunning()
    }

    public func stop() {
        if session.isRunning { session.stopRunning() }
        for i in session.inputs { session.removeInput(i) }
        for o in session.outputs { session.removeOutput(o) }
    }

    public var isRunning: Bool { session.isRunning }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer), let handler = onFrame else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        if rgba.count != w * h * 4 { rgba = [UInt8](repeating: 0, count: w * h * 4) }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        rgba.withUnsafeMutableBytes { dst in
            var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: CVPixelBufferGetBytesPerRow(pb))
            var out = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var map: [UInt8] = [2, 1, 0, 3]  // BGRA -> RGBA
            vImagePermuteChannels_ARGB8888(&src, &out, &map, vImage_Flags(kvImageNoFlags))
            handler(dst.baseAddress!.assumingMemoryBound(to: UInt8.self), w, h, t)
        }
    }
}
