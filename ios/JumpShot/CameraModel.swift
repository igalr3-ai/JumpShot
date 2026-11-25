import AVFoundation
import Combine
import UIKit
import Vision

/// Runs the camera, detects jumps with Apple Vision body-pose detection, and shoots bursts.
///
/// Threads: `sessionQueue` configures the session and issues captures; `visionQueue`
/// receives video frames and owns `detector`; published properties change on main.
final class CameraModel: NSObject, ObservableObject {
    @Published var status = "Starting camera…"
    @Published var info = ""
    @Published var lastBurst = ""
    @Published var pose: Pose = [:]
    @Published var result = JumpDetector.Result(state: .noPerson)
    @Published var frameSize = CGSize(width: 1080, height: 1440)
    @Published var mirrored = false
    @Published var bursting = false
    @Published var thumbnail: UIImage?
    @Published var errorText: String?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "jumpshot.session")
    private let visionQueue = DispatchQueue(label: "jumpshot.vision", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var configuredFront: Bool?
    private var configuredFullRes: Bool?

    // Vision side (visionQueue only)
    private let detector = JumpDetector()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private var armedFlag = true
    private var burstingFlag = false
    private var fpsCount = 0
    private var fpsStart = CACurrentMediaTime()
    private var fps = 0

    // Burst bookkeeping (sessionQueue only)
    private var burstTotal = 0
    private var burstDone = 0
    private var burstSaved = 0
    private var burstStart = Date()

    private let defaults = UserDefaults.standard

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.startSession() } else { self.errorText = Self.cameraDenied }
                }
            }
        default:
            errorText = Self.cameraDenied
        }
        PhotoLibrary.prepare { _ in self.refreshThumbnail() }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Re-read settings after the Settings screen closes.
    func reloadSettings() {
        applyDetectorSettings()
        sessionQueue.async {
            let front = self.defaults.bool(forKey: Key.front)
            let fullRes = self.defaults.bool(forKey: Key.fullRes)
            if front != self.configuredFront || fullRes != self.configuredFullRes {
                self.configure()
            } else {
                self.applyZoomAndExposure()
            }
        }
    }

    private static let cameraDenied =
        "JumpShot needs the camera. Allow it in Settings → JumpShot → Camera."

    private func startSession() {
        errorText = nil
        applyDetectorSettings()
        sessionQueue.async {
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func applyDetectorSettings() {
        let sens = defaults.double(forKey: Key.sensitivity) / 100
        let push = defaults.bool(forKey: Key.pushOff)
        let cool = defaults.double(forKey: Key.cooldown)
        let armed = defaults.bool(forKey: Key.armed)
        visionQueue.async {
            self.detector.sensitivity = CGFloat(sens)
            self.detector.mode = push ? .pushOff : .airborne
            self.detector.cooldown = cool
            self.armedFlag = armed
        }
    }

    func setArmed(_ armed: Bool) {
        defaults.set(armed, forKey: Key.armed)
        visionQueue.async { self.armedFlag = armed }
    }

    // MARK: - Session setup (sessionQueue)

    private func configure() {
        let front = defaults.bool(forKey: Key.front)
        let fullRes = defaults.bool(forKey: Key.fullRes)

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }

        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorText = "Could not open the camera." }
            return
        }
        session.addInput(input)
        device = dev

        if !session.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        configurePhotoOutput(device: dev, fullRes: fullRes)

        for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            setPortrait(conn)
        }
        session.commitConfiguration()

        configured = true
        configuredFront = front
        configuredFullRes = fullRes
        applyZoomAndExposure()
        visionQueue.async { self.detector.reset() }
        DispatchQueue.main.async { self.mirrored = front }
    }

    private func setPortrait(_ conn: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        } else if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }

    private func configurePhotoOutput(device dev: AVCaptureDevice, fullRes: Bool) {
        photoOutput.maxPhotoQualityPrioritization = .balanced

        // Photo size: the sensor maximum, or a smaller size (≈3 MP or more) for faster bursts.
        let dims = dev.activeFormat.supportedMaxPhotoDimensions.sorted { $0.width * $0.height < $1.width * $1.height }
        if let chosen = fullRes ? dims.last : (dims.first { Int($0.width) * Int($0.height) >= 3_000_000 } ?? dims.last) {
            photoOutput.maxPhotoDimensions = chosen
        }

        // Faster back-to-back captures and zero shutter lag where the phone supports them.
        if #available(iOS 17.0, *) {
            if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
            if photoOutput.isResponsiveCaptureSupported {
                photoOutput.isResponsiveCaptureEnabled = true
                if photoOutput.isFastCapturePrioritizationSupported {
                    photoOutput.isFastCapturePrioritizationEnabled = true
                }
            }
        }
    }

    private func applyZoomAndExposure() {
        guard let dev = device else { return }
        let zoom = CGFloat(defaults.double(forKey: Key.zoom))
        let ev = Float(defaults.double(forKey: Key.exposure))
        do {
            try dev.lockForConfiguration()
            let lo = dev.minAvailableVideoZoomFactor, hi = min(dev.maxAvailableVideoZoomFactor, 10)
            dev.videoZoomFactor = lo + min(1, max(0, zoom)) * (hi - lo)
            dev.setExposureTargetBias(min(dev.maxExposureTargetBias, max(dev.minExposureTargetBias, ev)), completionHandler: nil)
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            dev.unlockForConfiguration()
        } catch {
            print("JumpShot: lockForConfiguration failed", error)
        }
    }

    // MARK: - Pinch zoom (main)

    private var pinchStartZoom: CGFloat?

    func pinch(scale: CGFloat) {
        sessionQueue.async {
            guard let dev = self.device else { return }
            let start = self.pinchStartZoom ?? dev.videoZoomFactor
            self.pinchStartZoom = start
            let lo = dev.minAvailableVideoZoomFactor, hi = min(dev.maxAvailableVideoZoomFactor, 10)
            let z = min(hi, max(lo, start * scale))
            if (try? dev.lockForConfiguration()) != nil {
                dev.videoZoomFactor = z
                dev.unlockForConfiguration()
            }
            self.defaults.set(Double((z - lo) / max(0.001, hi - lo)), forKey: Key.zoom)
        }
    }

    func pinchEnded() { sessionQueue.async { self.pinchStartZoom = nil } }

    // MARK: - Burst

    func fireBurst() {
        guard !bursting, configured else { return }
        bursting = true
        status = "Shooting…"
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        visionQueue.async { self.burstingFlag = true }

        let shots = max(1, defaults.integer(forKey: Key.shots))
        let gap = 1.0 / max(1, defaults.double(forKey: Key.fps))
        sessionQueue.async {
            self.burstTotal = shots
            self.burstDone = 0
            self.burstSaved = 0
            self.burstStart = Date()
            for i in 0..<shots {
                self.sessionQueue.asyncAfter(deadline: .now() + gap * Double(i)) { self.captureOne() }
            }
        }
    }

    private func captureOne() {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .speed
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        if photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// One photo finished (saved or failed). sessionQueue.
    private func shotFinished(saved: Bool) {
        burstDone += 1
        if saved { burstSaved += 1 }
        guard burstDone == burstTotal else { return }
        let secs = Date().timeIntervalSince(burstStart)
        let text = String(format: "Saved %d/%d in %.1f s to the JumpShot album", burstSaved, burstTotal, secs)
        visionQueue.async { self.burstingFlag = false }
        DispatchQueue.main.async {
            self.bursting = false
            self.lastBurst = text
            self.refreshThumbnail()
        }
    }

    func refreshThumbnail() {
        PhotoLibrary.latestThumbnail(size: CGSize(width: 160, height: 160)) { self.thumbnail = $0 }
    }
}

// MARK: - Photo capture delegate

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            if let error { print("JumpShot capture failed:", error) }
            sessionQueue.async { self.shotFinished(saved: false) }
            return
        }
        PhotoLibrary.save(data) { ok in
            self.sessionQueue.async { self.shotFinished(saved: ok) }
        }
    }
}

// MARK: - Video frames → Vision → detector

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    private static let visionNames: [Joint: VNHumanBodyPoseObservation.JointName] = [
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow, .rightElbow: .rightElbow,
        .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip,
        .leftKnee: .leftKnee, .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CGFloat(CVPixelBufferGetWidth(pixels)), h = CGFloat(CVPixelBufferGetHeight(pixels))
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        // Buffers are already rotated to portrait by the connection, so orientation is .up.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        var pose: Pose = [:]
        do {
            try handler.perform([poseRequest])
            // Several people: follow the one Vision is most confident about.
            let best = poseRequest.results?.max { $0.confidence < $1.confidence }
            if let obs = best, let points = try? obs.recognizedPoints(.all) {
                for (joint, name) in Self.visionNames {
                    if let p = points[name], p.confidence > 0.3 {
                        // Vision: normalised, origin bottom-left → pixels, origin top-left.
                        pose[joint] = CGPoint(x: p.location.x * w, y: (1 - p.location.y) * h)
                    }
                }
            }
        } catch {
            print("JumpShot vision error:", error)
        }

        let r = detector.update(pose, time: t, armed: armedFlag && !burstingFlag)

        fpsCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 { fps = fpsCount; fpsCount = 0; fpsStart = now }

        let status: String
        switch r.state {
        case .noPerson: status = "Step into frame — whole body"
        case .learning: status = "Stand still…"
        case .ready, .dipping: status = "Ready — jump!"
        case .cooldown: status = "Cooldown"
        case .disarmed: status = "Auto-trigger off"
        }
        let info = String(format: "rise %+.2f · up %.1f/s · %d fps · %d×%d", r.rise, r.vUp, fps, Int(w), Int(h))
        let size = CGSize(width: w, height: h)

        DispatchQueue.main.async {
            self.pose = pose
            self.result = r
            self.frameSize = size
            self.info = info
            if !self.bursting { self.status = status }
            if r.triggered { self.fireBurst() }
        }
    }
}
