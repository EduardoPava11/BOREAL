import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Owns the AVCaptureSession + AVCapturePhotoOutput + readiness coordinator.
/// Single responsibility: deliver one `CapturedRaw` per `captureOne(slot:)` call, or
/// throw a `SkipReason`-encoded error if the ISP can't or won't deliver in time.
///
/// Concurrency model:
///   - The class is `@MainActor` because the readiness coordinator's delegate fires on
///     the main queue (Apple's design); SwiftUI binding also lives here.
///   - The AVCaptureSession is `nonisolated let` so `CameraPreviewView` can bind to it
///     without crossing actor boundaries.
///   - Heavy AVFoundation calls (`beginConfiguration` / `startRunning`) run on the
///     `sessionQueue` DispatchQueue, hopped via `withCheckedThrowingContinuation`.
@MainActor
final class CaptureService {

    // MARK: - Public API

    /// AVCaptureSession is not Sendable in Swift 6 strict concurrency, but Apple's
    /// own AVCam pattern (and Swift Forums #83622) treats it as effectively-Sendable
    /// since all mutation flows through the session queue. `nonisolated(unsafe)`
    /// formalizes "I'm taking responsibility for this."
    nonisolated(unsafe) let session = AVCaptureSession()

    /// True after the first successful prepare(). Subsequent prepare() calls are
    /// no-ops. The eager preview path in AppCoordinator (`preparePreviewIfNeeded`)
    /// and the burst-tap path (`runPrepare`) BOTH call prepare(); without this
    /// flag the second call ran `beginConfiguration` + `removeInput` + `removeOutput`
    /// on an already-running session, leaving FigCaptureSourceRemote mid-flight on
    /// the first config and bailing with err=-17281. See plan
    /// `~/.claude/plans/woolly-marinating-meteor.md` for the full diagnosis.
    private(set) var isConfigured: Bool = false

    /// Production initializer. Service starts unconfigured.
    init() {
        self.isConfigured = false
    }

    /// Test-only initializer: lets unit tests verify the early-return contract
    /// without invoking AVFoundation (which requires camera permissions and a
    /// real device). Production code uses the no-arg `init()`.
    ///
    /// Split from `init()` rather than added as a defaulted parameter because
    /// the default-argument symbol is not always exposed across `@testable`
    /// import boundaries — the linker on the test target failed to resolve
    /// `CaptureService(configuredFromTest: …)` when the param had a default.
    init(configuredFromTest: Bool) {
        self.isConfigured = configuredFromTest
    }

    /// Configure inputs/output, start the session, set up the readiness coordinator,
    /// and snapshot the clock reference for hardware-timestamp conversion.
    /// Returns when the session is running and ready to accept captures.
    ///
    /// Idempotent: the second and subsequent calls return immediately without
    /// touching the session.
    func prepare() async throws {
        if isConfigured {
            Log.capture.info("prepare() skipped — already configured")
            return
        }

        // 1. Permissions
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw err("Camera access denied") }
        } else if status != .authorized {
            throw err("Camera access not authorized (status=\(status.rawValue))")
        }

        // 2. Session configuration on the session queue
        let rawFmt: OSType = try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                do {
                    let fmt = try self.configureLocked()
                    if !self.session.isRunning { self.session.startRunning() }
                    cont.resume(returning: fmt)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        self.bayerRawFmt = rawFmt

        // 3. Snapshot the synchronization clock + wall clock so we can convert
        //    photo.timestamp (CMTime) → Date later.
        if let clk = session.synchronizationClock {
            let cmNow = CMClockGetTime(clk)
            self.clockRef = ClockRef(cmTime: cmNow, wall: Date())
            Log.capture.info("Clock ref: cmTime=\(cmNow.value)/\(cmNow.timescale) wall=\(self.clockRef!.wall.timeIntervalSince1970)")
        } else {
            Log.capture.error("No synchronizationClock — wall-clock timestamps will be approximate")
            self.clockRef = ClockRef(cmTime: .zero, wall: Date())
        }

        // 4. Readiness coordinator (iOS 17+)
        self.readiness = ReadinessCoordinatorBridge(photoOutput: photoOutput)
        Log.capture.info("ReadinessCoordinator attached")

        // 5. Subscribe to runtime-error notifications so any future Fig/XPC error
        //    lands in our breadcrumb stream rather than only in Apple's stderr.
        //    Today's `err=-17281` only appears in the iOS log; we want it in
        //    `Log.capture` so a future device run captures it for us.
        installRuntimeErrorObserver()

        isConfigured = true
    }

    /// Capture one frame. Awaits ISP readiness, fires `capturePhoto`, races the photo
    /// delegate against a 5-second timeout. On success returns a `CapturedRaw` with
    /// hardware CMTime + wall-clock Date. On timeout throws `CaptureError.timeout(slot:)`.
    func captureOne(slot: Int) async throws -> CapturedRaw {
        guard let rawFmt = bayerRawFmt,
              let readiness = readiness,
              let clockRef = clockRef else {
            throw err("CaptureService.prepare() was not called")
        }

        // Wait for the ISP to be .ready (up to 2s). If it never reaches .ready, the
        // bridge throws and this slot becomes a SkipReason.ispNotReady upstream.
        do {
            try await readiness.awaitReady(timeoutMs: 2_000)
        } catch {
            Log.capture.error("Slot \(slot) ispNotReady: \(String(describing: error), privacy: .public)")
            throw CaptureError.ispNotReady(slot: slot)
        }

        // Settings + delegate, retained by uniqueID.
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFmt)
        let oneShot = OneShotRaw()
        let captureDelegate = PhotoDelegate(slot: slot,
                                            uniqueID: settings.uniqueID,
                                            clockRef: clockRef,
                                            oneShot: oneShot)
        delegates[settings.uniqueID] = captureDelegate

        // Fire the timeout race: succeed-on-delivery vs. fail-on-5s-elapsed.
        Task.detached { [slot] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            oneShot.fail(CaptureError.timeout(slot: slot))
        }

        // Issue the capture (this is what eventually triggers the delegate's success).
        readiness.startTracking(settings)
        photoOutput.capturePhoto(with: settings, delegate: captureDelegate)

        // Await the first signal: delegate success OR timeout failure.
        do {
            let raw = try await oneShot.wait()
            delegates[settings.uniqueID] = nil
            return raw
        } catch {
            // Delegate may still fire later; it'll find oneShot already-resumed and no-op.
            delegates[settings.uniqueID] = nil
            readiness.stopTracking(uniqueID: settings.uniqueID)
            throw error
        }
    }

    /// Stop the session (for app-background or explicit teardown).
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                cont.resume()
            }
        }
    }

    // MARK: - Internals

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.daniel.boreal.capture")
    private var bayerRawFmt: OSType?
    private var readiness: ReadinessCoordinatorBridge?
    private var clockRef: ClockRef?

    /// Delegates retained per-frame by their settings' uniqueID. AVFoundation also
    /// retains them until `didFinishCaptureFor` fires, but we hold our own reference
    /// so they survive even if the photo output drops them early.
    private var delegates: [Int64: PhotoDelegate] = [:]

    private struct ClockRef: Sendable {
        let cmTime: CMTime
        let wall: Date
    }

    enum CaptureError: Error, CustomStringConvertible {
        case timeout(slot: Int)
        case ispNotReady(slot: Int)
        case noPhotoData(slot: Int)

        var description: String {
            switch self {
            case .timeout(let s):     "slot \(s) timed out after 5s"
            case .ispNotReady(let s): "slot \(s) ISP not ready within 2s"
            case .noPhotoData(let s): "slot \(s) delegate finished but no photo data"
            }
        }

        var skipReason: SkipReason {
            switch self {
            case .timeout:     .timeout
            case .ispNotReady: .ispNotReady
            case .noPhotoData: .captureError
            }
        }
    }

    /// Runs on `sessionQueue`. Returns the hard-coded Bayer FourCC.
    ///
    /// MVP recipe — no format probing, no per-format property accessors.
    ///   - sessionPreset = .photo
    ///   - device = .builtInWideAngleCamera
    ///   - addInput → addOutput → commitConfiguration
    ///   - return kCVPixelFormatType_14Bayer_BGGR ('bgg4' = 0x62676734).
    ///
    /// Why BGGR (not RGGB): iPhone 17 Pro / iOS 26 main wide camera offers
    /// EXACTLY ONE Bayer RAW format and it is BGGR. Confirmed by device-log
    /// capture 2026-05-15 (`availableRawPhotoPixelFormatTypes count=1
    /// allRaw=[1650943796]` → 0x62676734 → 'bgg4'). Earlier rounds assumed
    /// RGGB based on an incorrect entry in `reference_iphone17pro_avfoundation.md`
    /// (since corrected). The DNG bytes record their CFA pattern in tag 33422,
    /// so Phase 2 reads the pattern from the file and dispatches accordingly —
    /// no need to encode RGGB-vs-BGGR knowledge here at capture time.
    ///
    /// Why no probing: iPhone 17 Pro / iOS 26 returns 70 entries in
    /// `device.formats`, several of which are video-only and TRAP the Swift
    /// runtime when their `.supportedMaxPhotoDimensions` is read. Same risk
    /// class for `availableRawPhotoPixelFormatTypes` enumeration with the
    /// `isBayerRAWPixelFormat` / `isAppleProRAWPixelFormat` static accessors.
    /// We replace iteration with a single `contains()` check that touches no
    /// per-format properties.
    private func configureLocked() throws -> OSType {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = DeviceConfig.mainCamera() else {
            session.commitConfiguration()
            throw err("No back camera")
        }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw err("Cannot add input")
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw err("Cannot add photo output")
        }
        session.addOutput(photoOutput)

        photoOutput.maxPhotoQualityPrioritization = .quality

        session.commitConfiguration()

        // Hard-coded Bayer FourCC = BGGR (the iPhone 17 Pro / iOS 26 wide
        // camera's only-on-offer Bayer pattern, per device-log capture).
        let bayerFourCC: OSType = kCVPixelFormatType_14Bayer_BGGR

        // Single defensive check — `contains` on `[OSType]` does integer
        // comparisons only, no per-element property access. Logging the array
        // via os_log emits one integer-array print, no accessors involved.
        let allRaw = photoOutput.availableRawPhotoPixelFormatTypes
        Log.capture.info("availableRawPhotoPixelFormatTypes count=\(allRaw.count)")
        if !allRaw.contains(bayerFourCC) {
            Log.capture.error("HARDCODED Bayer 'bgg4' (0x\(String(bayerFourCC, radix: 16))) not in availableRawPhotoPixelFormatTypes — capture will fail. allRaw=\(allRaw, privacy: .public)")
            // Continue anyway — the user directed hardcode-or-bust. The capture
            // failure (if it happens) will be a clean NSInvalidArgumentException
            // from -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:].
        }

        Log.capture.info("Using hard-coded Bayer fmt=bgg4 (kCVPixelFormatType_14Bayer_BGGR = 0x\(String(bayerFourCC, radix: 16)))")
        return bayerFourCC
    }

    /// Subscribes to `AVCaptureSession.runtimeErrorNotification` so any session-
    /// level Fig/XPC error gets routed through `Log.capture`. Without this, errors
    /// like `-17281` only appear in Apple's stderr stream — invisible to anyone
    /// reading our breadcrumbs after the fact.
    private func installRuntimeErrorObserver() {
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.capture.error("AVCaptureSession runtimeError: \(err?.localizedDescription ?? "<no error>", privacy: .public) code=\(err?.code ?? 0) domain=\(err?.domain ?? "<none>", privacy: .public)")
        }
    }

    private nonisolated func err(_ msg: String) -> NSError {
        NSError(domain: "BOREAL", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private nonisolated func fourCC(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8)  & 0xFF),
            UInt8(code & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(code, radix: 16)
        }
        return "0x" + String(code, radix: 16)
    }

    // MARK: - Per-frame photo delegate (private, scoped to CaptureService)

    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        let slot: Int
        let uniqueID: Int64
        let clockRef: ClockRef
        let oneShot: OneShotRaw

        private let lock = NSLock()
        private var bufferedData: Data?
        private var bufferedHwTime: CMTime?
        private var bufferedError: Error?

        init(slot: Int, uniqueID: Int64, clockRef: ClockRef, oneShot: OneShotRaw) {
            self.slot = slot
            self.uniqueID = uniqueID
            self.clockRef = clockRef
            self.oneShot = oneShot
            super.init()
        }

        // didFinishProcessingPhoto fires on AVFoundation's internal queue. We BUFFER
        // the bytes + timestamp here and wait for didFinishCaptureFor (the official
        // "all done, safe to release delegate" signal) to deliver via the oneShot.
        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishProcessingPhoto photo: AVCapturePhoto,
                         error: Error?) {
            lock.lock(); defer { lock.unlock() }
            if let error {
                bufferedError = error
                return
            }
            if let data = photo.fileDataRepresentation() {
                bufferedData = data
                bufferedHwTime = photo.timestamp
                let magic = data.prefix(4).map { String(format: "%02X", $0) }.joined()
                Log.capture.info("slot \(self.slot) processed: bytes=\(data.count) isRaw=\(photo.isRawPhoto) magic=\(magic, privacy: .public)")
            } else {
                bufferedError = NSError(domain: "BOREAL", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No DNG data"])
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                         error: Error?) {
            lock.lock()
            let data = bufferedData
            let hwTime = bufferedHwTime
            let buffErr = bufferedError
            lock.unlock()

            if let error = error ?? buffErr {
                oneShot.fail(error)
                return
            }
            guard let data, let hwTime else {
                oneShot.fail(CaptureError.noPhotoData(slot: slot))
                return
            }

            let deltaSec = CMTimeGetSeconds(CMTimeSubtract(hwTime, clockRef.cmTime))
            let wall = clockRef.wall.addingTimeInterval(deltaSec)
            let raw = CapturedRaw(
                slot: slot,
                dngBytes: data,
                hardwareTimestamp: hwTime,
                wallClock: wall
            )
            oneShot.succeed(raw)
        }
    }
}
