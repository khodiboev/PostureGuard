import AppKit
import AVFoundation
import Vision
import Combine

/// Your "sitting up straight" position, learned during calibration
struct Baseline: Codable {
    var faceSize: Double      // face width in the frame (bigger = closer to the screen)
    var faceY: Double         // vertical face position (lower = head dropping)
    var faceHeight: Double
    var pitch: Double         // head tilt up/down, degrees
    var neckGap: Double?      // distance from nose to shoulders (smaller = slouching)
}

struct Sample {
    var faceSize: Double
    var faceY: Double
    var faceHeight: Double
    var pitch: Double
    var neckGap: Double?
}

enum Sensitivity: String, CaseIterable, Identifiable {
    case gentle, normal, strict

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle: return "Gentle (warn after 45 s)"
        case .normal: return "Normal (warn after 25 s)"
        case .strict: return "Strict (warn after 10 s)"
        }
    }

    struct Limits {
        let closer: Double      // face this many times bigger than baseline = too close
        let drop: Double        // head lower by this many face heights = dropping
        let neck: Double        // nose-to-shoulder gap below this share of baseline = slouching
        let pitch: Double       // head tilted by more than this many degrees
        let warnAfter: Double   // bad posture must last this long (s) before the warning
    }

    var limits: Limits {
        switch self {
        case .gentle: return Limits(closer: 1.25, drop: 0.55, neck: 0.75, pitch: 18, warnAfter: 45)
        case .normal: return Limits(closer: 1.18, drop: 0.40, neck: 0.82, pitch: 13, warnAfter: 25)
        case .strict: return Limits(closer: 1.12, drop: 0.28, neck: 0.88, pitch: 9, warnAfter: 10)
        }
    }
}

enum PostureState {
    case starting, needsCalibration, calibrating, good, slouching, away, paused, noCamera, noAccess
}

final class PostureMonitor: NSObject, ObservableObject {

    // MARK: - UI state (main thread)

    @Published private(set) var state: PostureState = .starting
    @Published private(set) var reason = ""
    @Published private(set) var isSnoozed = false

    @Published var isEnabled: Bool = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    @Published var sensitivity: Sensitivity = Sensitivity(rawValue: UserDefaults.standard.string(forKey: Keys.sensitivity) ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Keys.sensitivity)
            let limits = sensitivity.limits
            queue.async { self.limits = limits; self.badSince = nil }
        }
    }

    var statusText: String {
        switch state {
        case .starting: return "Starting…"
        case .needsCalibration: return reason.isEmpty ? "Calibration needed" : reason
        case .calibrating: return "Calibrating…"
        case .good: return isSnoozed ? "Snoozed" : "Good posture ✓"
        case .slouching: return "Sit up straight: \(reason)"
        case .away: return "Away from the camera"
        case .paused: return "Paused"
        case .noCamera: return "No camera found"
        case .noAccess: return "No camera access → System Settings › Privacy › Camera"
        }
    }

    private enum Keys {
        static let enabled = "enabled"
        static let sensitivity = "sensitivity"
        static let baseline = "baseline"
    }

    // MARK: - Camera (main thread)

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "postureguard.video")
    private var cameraReady = false
    private let glow = GlowOverlay()
    private var snoozeTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    // MARK: - Tracking state (only used on `queue`)

    private var limits = Sensitivity.normal.limits
    private var baseline: Baseline?
    private var recent: [Sample] = []
    private var badSince: Double?
    private var goodSince: Double?
    private var lastSeen = 0.0
    private var lastFrame = 0.0
    private var warning = false
    private var snoozed = false
    private var calibrating = false
    private var collecting: [Sample]? = nil

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3   // gives head pitch
        return r
    }()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    // MARK: - Lifecycle

    override init() {
        super.init()
        limits = sensitivity.limits
        if let data = UserDefaults.standard.data(forKey: Keys.baseline) {
            baseline = try? JSONDecoder().decode(Baseline.self, from: data)
        }

        // Turn the camera off while the Mac sleeps or is locked (privacy + battery)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(pause), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(resumeCamera), name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(pause), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(resumeCamera), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        if isEnabled { start() } else { state = .paused }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if !cameraReady { setupCamera() }
            guard cameraReady else { state = .noCamera; return }
            runSession(true)
            if baseline == nil {
                state = .needsCalibration
                // First launch: calibrate right away
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.calibrate() }
            } else {
                state = .good
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { self.start() }
            }
        default:
            state = .noAccess
        }
    }

    private func stop() {
        runSession(false)
        glow.hide()
        queue.async { self.resetTracking() }
        state = .paused
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        cameraReady = true
    }

    private func runSession(_ on: Bool) {
        guard cameraReady else { return }
        queue.async {
            if on && !self.session.isRunning { self.session.startRunning() }
            if !on && self.session.isRunning { self.session.stopRunning() }
        }
    }

    @objc private func pause() {
        runSession(false)
        glow.hide()
        queue.async { self.resetTracking() }
    }

    @objc private func resumeCamera() {
        if isEnabled { runSession(true) }
    }

    // MARK: - Snooze and preview

    func snooze(minutes: Double) {
        isSnoozed = true
        glow.hide()
        queue.async { self.snoozed = true; self.resetTracking() }
        snoozeTask?.cancel()
        snoozeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.resume()
        }
    }

    func resume() {
        snoozeTask?.cancel()
        isSnoozed = false
        queue.async { self.snoozed = false }
    }

    /// Shows the glow for 3 seconds so you can see what a warning looks like
    func previewWarning() {
        glow.show(message: "This is how a posture warning looks")
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.state != .slouching else { return }
            self.glow.hide()
        }
    }

    // MARK: - Calibration

    func calibrate() {
        guard state != .calibrating else { return }
        if !isEnabled { isEnabled = true }
        guard cameraReady else { return }

        state = .calibrating
        reason = ""
        glow.hide()
        queue.async { self.calibrating = true; self.resetTracking() }

        let hud = CalibrationHUD()
        Task { @MainActor in
            for n in stride(from: 3, through: 1, by: -1) {
                hud.show("Sit up straight and look at your main screen\n\(n)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            hud.show("Hold still…")
            self.queue.sync { self.collecting = [] }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let samples: [Sample] = self.queue.sync {
                let s = self.collecting ?? []
                self.collecting = nil
                return s
            }
            hud.close()

            guard samples.count >= 8 else {
                self.queue.async { self.calibrating = false }
                self.reason = "Face not detected. Check the lighting and calibrate again"
                self.state = .needsCalibration
                return
            }

            let avg = Self.average(samples)
            let newBaseline = Baseline(faceSize: avg.faceSize, faceY: avg.faceY, faceHeight: avg.faceHeight,
                                       pitch: avg.pitch, neckGap: avg.neckGap)
            if let data = try? JSONEncoder().encode(newBaseline) {
                UserDefaults.standard.set(data, forKey: Keys.baseline)
            }
            self.queue.async {
                self.baseline = newBaseline
                self.calibrating = false
            }
            self.state = .good
        }
    }

    // MARK: - Measuring (queue)

    private func measure(_ pixelBuffer: CVPixelBuffer) -> Sample? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest, bodyRequest])
        } catch {
            return nil
        }
        guard let face = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            return nil
        }
        let box = face.boundingBox
        let pitch = (face.pitch?.doubleValue ?? 0) * 180 / .pi

        // Shoulders are optional: they may be outside the camera's view
        var neckGap: Double?
        if let body = bodyRequest.results?.first,
           let nose = try? body.recognizedPoint(.nose), nose.confidence > 0.3,
           let left = try? body.recognizedPoint(.leftShoulder), left.confidence > 0.3,
           let right = try? body.recognizedPoint(.rightShoulder), right.confidence > 0.3 {
            neckGap = Double(nose.location.y - (left.location.y + right.location.y) / 2)
        }

        return Sample(faceSize: Double(box.width), faceY: Double(box.midY),
                      faceHeight: Double(box.height), pitch: pitch, neckGap: neckGap)
    }

    private func evaluate(_ sample: Sample?, now: Double) {
        guard let baseline else { return }

        // Nobody in front of the camera for a few seconds → you stepped away
        guard let sample else {
            if now - lastSeen > 3 {
                resetTracking()
                publish(.away)
            }
            return
        }
        lastSeen = now

        // Average the last ~2 seconds so a single movement doesn't count
        recent.append(sample)
        if recent.count > 10 { recent.removeFirst() }
        let s = Self.average(recent)

        var reasons: [String] = []
        if s.faceSize / baseline.faceSize > limits.closer {
            reasons.append("too close to the screen")
        }
        if baseline.faceHeight > 0, (baseline.faceY - s.faceY) / baseline.faceHeight > limits.drop {
            reasons.append("head is dropping")
        }
        if let gap = s.neckGap, let base = baseline.neckGap, base > 0.01, gap / base < limits.neck {
            reasons.append("slouching")
        }
        if abs(s.pitch - baseline.pitch) > limits.pitch {
            reasons.append("head is tilted")
        }

        if reasons.isEmpty || snoozed {
            badSince = nil
            if warning {
                // Turn the glow off after 1.5 s of good posture
                if goodSince == nil { goodSince = now }
                if let since = goodSince, now - since >= 1.5 { setWarning(false, reason: "") }
            } else {
                publish(.good)
            }
        } else {
            goodSince = nil
            if badSince == nil { badSince = now }
            if let since = badSince, now - since >= limits.warnAfter {
                setWarning(true, reason: reasons[0])
            } else if !warning {
                publish(.good)
            }
        }
    }

    private func setWarning(_ on: Bool, reason text: String) {
        guard on != warning else { return }
        warning = on
        goodSince = nil
        DispatchQueue.main.async {
            self.reason = text
            self.state = on ? .slouching : .good
            if on {
                self.glow.show(message: "Sit up straight: \(text)")
            } else {
                self.glow.hide()
            }
        }
    }

    private var lastPublished: PostureState?

    private func publish(_ newState: PostureState) {
        guard newState != lastPublished else { return }
        lastPublished = newState
        if newState == .away, warning {
            warning = false
            DispatchQueue.main.async { self.glow.hide() }
        }
        DispatchQueue.main.async {
            if self.state != .calibrating { self.state = newState }
        }
    }

    private func resetTracking() {
        recent.removeAll()
        badSince = nil
        goodSince = nil
        warning = false
        lastPublished = nil
    }

    private static func average(_ items: [Sample]) -> Sample {
        let n = Double(items.count)
        func mean(_ key: KeyPath<Sample, Double>) -> Double {
            items.reduce(0) { $0 + $1[keyPath: key] } / n
        }
        let gaps = items.compactMap { $0.neckGap }
        let neck: Double? = gaps.count * 2 >= items.count ? gaps.reduce(0, +) / Double(gaps.count) : nil
        return Sample(faceSize: mean(\.faceSize), faceY: mean(\.faceY), faceHeight: mean(\.faceHeight),
                      pitch: mean(\.pitch), neckGap: neck)
    }
}

// MARK: - Camera frames

extension PostureMonitor: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Posture changes slowly, so 5 frames per second is plenty (and easy on the battery)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.2 else { return }
        lastFrame = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sample = measure(pixelBuffer)

        if collecting != nil {
            if let sample { collecting?.append(sample) }
            return
        }
        if calibrating { return }
        evaluate(sample, now: now)
    }
}
