import Foundation
import CMediaPipe

public enum EngineError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { if case .message(let s) = self { return s }; return "" }
}

/// Anything that turns a camera image into a FaceFrame (the MediaPipe engine, or a fallback).
public protocol FaceEngine: AnyObject {
    /// `rgba` is 8-bit RGBA, `width*height*4` bytes.
    func detect(rgba: UnsafePointer<UInt8>, width: Int, height: Int, time: Double) throws -> FaceFrame?
}

/// MediaPipe Face Landmarker through its C API, loaded at runtime with dlopen
/// (pinned: MediaPipe 1.2.3; struct layouts are mirrored in CMediaPipe/include/mp.h).
public final class MediaPipeFaceEngine: FaceEngine {
    typealias CreateFn = @convention(c) (UnsafeMutablePointer<MpFaceLandmarkerOptions>, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias DetectFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?, Int64, UnsafeMutablePointer<MpFaceLandmarkerResult>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias CloseResultFn = @convention(c) (UnsafeMutablePointer<MpFaceLandmarkerResult>) -> Void
    typealias CloseFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias ImageFileFn = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias ImageDataFn = @convention(c) (Int32, Int32, Int32, UnsafePointer<UInt8>, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias ImageFreeFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    /// MpImage pixel format for 8-bit RGBA ("SRGBA" in MediaPipe's ImageFormat enum).
    static let formatSRGBA: Int32 = 2

    private let handle: UnsafeMutableRawPointer
    private var landmarker: UnsafeMutableRawPointer?
    private let detectFn: DetectFn, closeResultFn: CloseResultFn, closeFn: CloseFn?
    private let imageFileFn: ImageFileFn, imageDataFn: ImageDataFn, imageFreeFn: ImageFreeFn
    private var lastTs: Int64 = -1
    private var modelPathStorage: UnsafeMutablePointer<CChar>

    // MARK: locating files
    public static func locate(_ name: String) -> String? {
        var dirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["HEADCLICK_VENDOR"] { dirs.append(env) }
        if let p = Bundle.main.privateFrameworksPath { dirs.append(p) }
        if let p = Bundle.main.resourcePath { dirs.append(p) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        dirs += [exe.path, exe.appendingPathComponent("../Frameworks").path, exe.appendingPathComponent("../Resources").path]
        let cwd = FileManager.default.currentDirectoryPath
        dirs += [cwd + "/vendor", cwd + "/app/vendor", cwd + "/Resources"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    public init(libraryPath: String? = nil, modelPath: String? = nil) throws {
        guard let lib = libraryPath ?? Self.locate("libmediapipe.dylib") else {
            throw EngineError.message("libmediapipe.dylib not found (run scripts/fetch-mediapipe.sh)")
        }
        guard let model = modelPath ?? Self.locate("face_landmarker.task") else {
            throw EngineError.message("face_landmarker.task not found (run scripts/fetch-mediapipe.sh)")
        }
        guard let h = dlopen(lib, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineError.message("dlopen failed: \(String(cString: dlerror()))")
        }
        handle = h
        func sym<T>(_ n: String, _ t: T.Type) throws -> T {
            guard let p = dlsym(h, n) else { throw EngineError.message("missing symbol \(n)") }
            return unsafeBitCast(p, to: T.self)
        }
        let createFn = try sym("MpFaceLandmarkerCreate", CreateFn.self)
        detectFn = try sym("MpFaceLandmarkerDetectForVideo", DetectFn.self)
        closeResultFn = try sym("MpFaceLandmarkerCloseResult", CloseResultFn.self)
        closeFn = try? sym("MpFaceLandmarkerClose", CloseFn.self)
        imageFileFn = try sym("MpImageCreateFromFile", ImageFileFn.self)
        imageDataFn = try sym("MpImageCreateFromUint8Data", ImageDataFn.self)
        imageFreeFn = try sym("MpImageFree", ImageFreeFn.self)

        modelPathStorage = strdup(model)
        var opts = MpFaceLandmarkerOptions()
        opts.base_options.model_asset_path = UnsafePointer(modelPathStorage)
        opts.running_mode = 2  // VIDEO
        opts.num_faces = 1
        opts.min_face_detection_confidence = 0.5
        opts.min_face_presence_confidence = 0.5
        opts.min_tracking_confidence = 0.5
        opts.output_face_blendshapes = true
        opts.output_facial_transformation_matrixes = true
        var lm: UnsafeMutableRawPointer? = nil
        var err: UnsafeMutablePointer<CChar>? = nil
        let st = createFn(&opts, &lm, &err)
        guard st == 0, let lm else {
            throw EngineError.message("MpFaceLandmarkerCreate failed (\(st)): \(err.map { String(cString: $0) } ?? "")")
        }
        landmarker = lm
    }

    deinit {
        if let lm = landmarker, let closeFn { _ = closeFn(lm, nil) }
        free(modelPathStorage)
    }

    public func detect(rgba: UnsafePointer<UInt8>, width: Int, height: Int, time: Double) throws -> FaceFrame? {
        var img: UnsafeMutableRawPointer? = nil
        var err: UnsafeMutablePointer<CChar>? = nil
        let st = imageDataFn(Self.formatSRGBA, Int32(width), Int32(height), rgba, Int32(width * height * 4), &img, &err)
        guard st == 0, let img else { throw EngineError.message("image create failed (\(st)): \(err.map { String(cString: $0) } ?? "")") }
        defer { imageFreeFn(img) }
        return try run(image: img, time: time)
    }

    /// For --selftest: detect on an image file.
    public func detect(file: String, time: Double = 0) throws -> FaceFrame? {
        var img: UnsafeMutableRawPointer? = nil
        var err: UnsafeMutablePointer<CChar>? = nil
        let st = imageFileFn(file, &img, &err)
        guard st == 0, let img else { throw EngineError.message("image load failed (\(st)): \(err.map { String(cString: $0) } ?? "")") }
        defer { imageFreeFn(img) }
        return try run(image: img, time: time)
    }

    private func run(image: UnsafeMutableRawPointer, time: Double) throws -> FaceFrame? {
        guard let lm = landmarker else { return nil }
        var ts = Int64(time * 1000)
        if ts <= lastTs { ts = lastTs + 1 }
        lastTs = ts
        var res = MpFaceLandmarkerResult()
        var err: UnsafeMutablePointer<CChar>? = nil
        let t0 = CFAbsoluteTimeGetCurrent()
        let st = detectFn(lm, image, nil, ts, &res, &err)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard st == 0 else { throw EngineError.message("detect failed (\(st)): \(err.map { String(cString: $0) } ?? "")") }
        defer { closeResultFn(&res) }
        guard res.face_landmarks_count > 0, let lms = res.face_landmarks?.pointee else { return nil }

        var f = FaceFrame()
        f.time = time
        f.engineMs = ms
        let n = Int(lms.landmarks_count)
        f.landmarks.reserveCapacity(n)
        for i in 0..<n { let l = lms.landmarks[i]; f.landmarks.append(SIMD3(l.x, l.y, l.z)) }
        if res.face_blendshapes_count > 0, let bs = res.face_blendshapes?.pointee {
            for k in 0..<Int(bs.categories_count) {
                let c = bs.categories[k]
                if let name = c.category_name, let b = Blend.byName[String(cString: name)] { f.blend[b.rawValue] = c.score }
            }
        }
        if res.facial_transformation_matrixes_count > 0, let m = res.facial_transformation_matrixes?.pointee, m.rows == 4, m.cols == 4, let d = m.data {
            let arr = Array(UnsafeBufferPointer(start: d, count: 16))
            if let a = HeadPose.angles(matrix: arr) { f.yaw = a.yaw; f.pitch = a.pitch; f.roll = a.roll; f.scale = a.scale }
        }
        return f
    }
}
