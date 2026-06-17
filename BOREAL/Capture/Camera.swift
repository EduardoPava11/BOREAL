import AVFoundation
import UIKit

/// Minimal RAW camera for BOREAL: one bracketed capture → 4 RAW DNGs of the same
/// scene (the RGBT temporal axis), fed straight into Kernel's import pipeline.
///
/// Capture is DEVICE-ONLY (the simulator has no camera) — this compiles for the
/// simulator but does nothing useful there; run on a real iPhone to capture.
@MainActor
@Observable
final class CameraController: NSObject {

    enum CamError: Error, CustomStringConvertible {
        case denied, noDevice, noRAW, configFailed, capture(String)
        var description: String {
            switch self {
            case .denied:        return "Camera access denied — enable it in Settings."
            case .noDevice:      return "No camera available on this device."
            case .noRAW:         return "This camera can't capture RAW."
            case .configFailed:  return "Could not configure the camera."
            case .capture(let m): return "Capture failed: \(m)"
            }
        }
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "boreal.camera.session")
    private var configured = false

    // ── Live exposure read-out (pre-shutter) ────────────────────────────────
    // A second, non-essential output taps the live video feed so the Zig kernel
    // can compute an RGB histogram BEFORE the shutter fires. Coexists with the
    // photo output on the same .photo-preset session; the RAW bracket path is
    // untouched.
    private let videoOut = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "boreal.camera.video")
    /// PTS of the last frame we histogrammed — throttle state, touched ONLY on
    /// the serial videoQueue (the delegate callback), so no lock is needed.
    /// `nonisolated(unsafe)`: the class is @MainActor, but this field is read and
    /// written exclusively from the serial videoQueue's nonisolated callback, so
    /// the serial queue is its sole synchronization — never raced.
    private nonisolated(unsafe) var lastHistTime: CMTime = .invalid
    /// The live RGB histogram, computed by Zig off-main and published here for
    /// the capture overlay. Mutated ONLY on the main actor.
    private(set) var liveHist: Kernel.ChannelHistogram?
    /// PTS of the last histogram actually shown — drops out-of-order publishes so
    /// a late Task can't overwrite a newer frame with stale data. Main-actor only.
    private var lastShownPTS: CMTime = .invalid

    /// Main-actor publish that ignores stale (older-PTS) frames.
    private func publish(_ hist: Kernel.ChannelHistogram, pts: CMTime) {
        if lastShownPTS.isValid, pts.isValid, CMTimeCompare(pts, lastShownPTS) <= 0 { return }
        lastShownPTS = pts
        liveHist = hist
    }

    private(set) var running = false
    /// The EV offsets of the 4 bracketed frames (dark → shadow-lift). Tunable; the
    /// fusion aligns by recorded EXIF regardless of these nominal values.
    var biases: [Float] = [-2, 0, 2, 4]

    // ── Lifecycle ──────────────────────────────────────────────────────────

    func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default:             return false
        }
    }

    func start() async throws {
        guard await authorized() else { throw CamError.denied }
        if !configured { try configure() }
        if !session.isRunning {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                sessionQueue.async { self.session.startRunning(); c.resume() }
            }
        }
        running = true
    }

    func stop() {
        guard session.isRunning else { return }
        sessionQueue.async { self.session.stopRunning() }
        // Reset throttle + publish state so a stop→start of the SAME controller
        // starts fresh (PTS restarts near 0 on a new session).
        videoQueue.async { self.lastHistTime = .invalid }
        lastShownPTS = .invalid
        running = false
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CamError.noDevice }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CamError.configFailed }
        session.addInput(input)

        guard session.canAddOutput(output) else { throw CamError.configFailed }
        session.addOutput(output)

        // Live video tap for the pre-shutter Zig histogram overlay. Non-essential:
        // if the device can't add it, we degrade gracefully (no overlay) rather
        // than failing the whole capture session.
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true   // drop, don't queue → self-throttles
        if session.canAddOutput(videoOut) {
            session.addOutput(videoOut)
            videoOut.setSampleBufferDelegate(self, queue: videoQueue)
        }

        // Apple ProRAW when available → an LJPEG-tiled DNG the kernel decodes;
        // otherwise plain Bayer RAW DNG. Either feeds the same pipeline.
        if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
        output.maxPhotoQualityPrioritization = .quality
        configured = true
    }

    // ── Bracketed RAW capture ────────────────────────────────────────────────

    private var captureCont: CheckedContinuation<[Data], Error>?
    private var collected: [Data] = []
    private var expected = 0

    /// Fire one 4-frame RAW EV bracket; returns the 4 DNG blobs in capture order.
    func captureBracket() async throws -> [Data] {
        guard running else { throw CamError.capture("camera not started") }
        guard let rawFormat = output.availableRawPhotoPixelFormatTypes.first else { throw CamError.noRAW }

        let clamped = biases   // device clamps internally; nominal offsets only
        let bracket = clamped.map {
            AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: $0)
        }
        guard output.maxBracketedCapturePhotoCount >= bracket.count else {
            throw CamError.capture("device supports only \(output.maxBracketedCapturePhotoCount) bracketed frames")
        }
        let settings = AVCapturePhotoBracketSettings(rawPixelFormatType: rawFormat,
                                                     processedFormat: nil,
                                                     bracketedSettings: bracket)
        collected.removeAll(keepingCapacity: true)
        expected = bracket.count

        return try await withCheckedThrowingContinuation { c in
            captureCont = c
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard let c = captureCont else { return }
        captureCont = nil
        c.resume(with: result)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        // One callback per bracketed frame; collect DNG data until we have all 4.
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            if let error { self.finish(.failure(CamError.capture("\(error)"))); return }
            guard let data else { self.finish(.failure(CamError.capture("no DNG data"))); return }
            self.collected.append(data)
            if self.collected.count >= self.expected { self.finish(.success(self.collected)) }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Live-frame tap (background serial videoQueue). Throttles to ~18fps, locks
    /// the pixel buffer, stride-downsamples to a small contiguous BGRA scratch,
    /// hands the pixels to the Zig histogram kernel, then publishes ONLY the
    /// resulting Sendable ChannelHistogram to the main actor. The CVPixelBuffer
    /// never escapes this callback (it is invalid after the unlock/return).
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Throttle by presentation-timestamp delta — cap the UI publish to ~18fps
        // regardless of the camera's native frame rate. (Read/written only here,
        // on the serial videoQueue → no race.)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastHistTime.isValid, pts.isValid {
            let dt = CMTimeGetSeconds(CMTimeSubtract(pts, lastHistTime))
            if dt < (1.0 / 18.0) { return }
        }
        if pts.isValid { lastHistTime = pts }

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let srcW = CVPixelBufferGetWidth(pb)
        let srcH = CVPixelBufferGetHeight(pb)
        let srcStride = CVPixelBufferGetBytesPerRow(pb)
        guard srcW > 0, srcH > 0 else { return }

        // Step-downsample into a tight contiguous BGRA scratch (~256px max dim) so
        // the scalar Zig scatter never has to walk a full 12MP frame. The scratch
        // is unpadded → its row stride is dstW*4.
        let maxDim = 256
        let step = max(1, max(srcW, srcH) / maxDim)
        let dstW = max(1, srcW / step)
        let dstH = max(1, srcH / step)
        let srcPtr = base.assumingMemoryBound(to: UInt8.self)
        var scratch = [UInt8](repeating: 0, count: dstW * dstH * 4)
        scratch.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            for dy in 0..<dstH {
                let sy = dy * step
                let srcRow = srcPtr + sy * srcStride
                let dstRow = d + dy * dstW * 4
                for dx in 0..<dstW {
                    let so = (dx * step) * 4
                    let dofs = dx * 4
                    dstRow[dofs + 0] = srcRow[so + 0]   // B
                    dstRow[dofs + 1] = srcRow[so + 1]   // G
                    dstRow[dofs + 2] = srcRow[so + 2]   // R
                    dstRow[dofs + 3] = srcRow[so + 3]   // A
                }
            }
        }

        let hist: Kernel.ChannelHistogram = scratch.withUnsafeBufferPointer { p in
            Kernel.liveHistograms(bgra: p.baseAddress!, width: dstW, height: dstH,
                                  rowStride: dstW * 4)
        }
        // Publish only the Sendable result; the buffer is released on return.
        // Stamped with PTS so an out-of-order Task can't show a stale frame.
        Task { @MainActor in self.publish(hist, pts: pts) }
    }
}
