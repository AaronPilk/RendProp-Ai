import SwiftUI
import UIKit
import AVFoundation
import CoreMotion

/// Still photos have their own session. No movie crop, digital imitation of an
/// ultra-wide lens, provider call or durable-save claim is involved here.
struct GuidedPhotoCamera: UIViewControllerRepresentable {
    let purpose: PhotoCapturePurpose
    let onPicked: @MainActor (UIImage) async -> String?
    let onCancel: () -> Void
    func makeUIViewController(context: Context) -> UIViewController {
        GuidedPhotoController(purpose: purpose, onPicked: onPicked, onCancel: onCancel)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? GuidedPhotoController)?.checkIdentity()
    }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? GuidedPhotoController)?.shutdown()
    }
}

private enum GuidedPhotoEvent {
    case ready(PhotoCapturePolicy.Lens, Bool, PhotoCapturePolicy.Dimensions, PhotoCapturePolicy.Orientation)
    case photo(UIImage)
    case failed(String)
}

/// All capture-session/device/output mutations, including shutter requests and
/// orientation changes, run on this one queue. Delegate ownership lasts through
/// didFinishCapture, not merely the first image-processing callback.
private final class GuidedPhotoSession: NSObject {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.rendprop.still-camera")
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var processor: GuidedPhotoProcessor?
    private weak var preview: AVCaptureVideoPreviewLayer?
    private var observers: [NSObjectProtocol] = []
    private var token = UUID()
    private var closed = false
    private var ready = false
    private var reviewing = false
    private var lens = PhotoCapturePolicy.Lens.wide
    private var orientation = PhotoCapturePolicy.Orientation.portrait
    private var dimensions = PhotoCapturePolicy.Dimensions(width: 4032, height: 3024)
    private let deliver: (UUID, GuidedPhotoEvent) -> Void

    init(preview: AVCaptureVideoPreviewLayer, deliver: @escaping (UUID, GuidedPhotoEvent) -> Void) {
        self.preview = preview; self.deliver = deliver
        super.init()
        // Attach before starting any queue work. Layout stays on the main actor.
        preview.session = session
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, !self.closed, !self.reviewing else { return }
                    self.ready = false
                    // A pending delegate owns this shot through didFinishCapture.
                    // Do not turn an interruption into a retry that loses it.
                    guard self.processor == nil else { return }
                    self.emit(.failed("The camera was interrupted. Finish your call or close other camera apps, then tap Retry."))
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    private func emit(_ event: GuidedPhotoEvent) {
        let current = token
        DispatchQueue.main.async { [weak self] in self?.deliver(current, event) }
    }
    func start(purpose: PhotoCapturePurpose, preferred: PhotoCapturePolicy.Lens?, orientation: PhotoCapturePolicy.Orientation, token: UUID) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            guard self.processor == nil else {
                DispatchQueue.main.async { [weak self] in self?.deliver(token, .failed("The previous photo is still finishing. Wait a moment, then tap Retry.")) }; return
            }
            self.token = token; self.ready = false; self.reviewing = false; self.orientation = orientation
            let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            let requested = preferred ?? PhotoCapturePolicy.defaultLens(purpose: purpose, supportsUltraWide: ultra != nil)
            let device = requested == .ultraWide ? ultra : AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            guard let device else {
                self.emit(.failed(requested == .ultraWide ? "This iPhone doesn’t have an available 0.5× camera. Close and reopen to use 1×." : "A camera is not available on this device. You can close this screen and add an existing photo instead.")); return
            }
            do {
                let next = try AVCaptureDeviceInput(device: device)
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                if let old = self.input { self.session.removeInput(old) }
                guard self.session.canAddInput(next) else {
                    if let old = self.input, self.session.canAddInput(old) { self.session.addInput(old) }
                    self.session.commitConfiguration()
                    self.emit(.failed("Couldn’t open this lens. Tap Retry to try again.")); return
                }
                self.session.addInput(next); self.input = next
                if self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
                if !self.session.outputs.contains(self.output) {
                    guard self.session.canAddOutput(self.output) else {
                        self.session.commitConfiguration(); self.emit(.failed("Still-photo capture is unavailable. Close this screen and add an existing photo.")); return
                    }
                    self.session.addOutput(self.output)
                }
                // Commit the photo preset/input first: dimensions must come
                // from the resulting active format, not the previous lens.
                self.session.commitConfiguration()
                self.output.maxPhotoQualityPrioritization = .quality
                let supported = device.activeFormat.supportedMaxPhotoDimensions.map { PhotoCapturePolicy.Dimensions(width: $0.width, height: $0.height) }
                guard let selected = PhotoCapturePolicy.preferredDimensions(supported) else {
                    self.emit(.failed("Couldn’t configure a full-resolution photo. Tap Retry.")); return
                }
                self.dimensions = selected
                self.output.maxPhotoDimensions = CMVideoDimensions(width: selected.width, height: selected.height)
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = 1 // physical camera's full field of view
                    if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = true }
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                    device.unlockForConfiguration()
                } catch {
                    self.emit(.failed("Couldn’t configure this camera. Tap Retry.")); return
                }
                // Device GDC applies consistently to preview and JPEG. Photo-only
                // content-aware warping is left off: SDK documents a changed FOV.
                // Connections exist after committing the input/output graph.
                self.applyOrientation()
                self.lens = requested
                self.session.startRunning()
                guard self.session.isRunning else { self.emit(.failed("The camera couldn’t start. Tap Retry.")); return }
                self.ready = true
                self.emit(.ready(self.lens, ultra != nil, self.dimensions, self.orientation))
            } catch { self.emit(.failed("Couldn’t open the camera. Tap Retry.")) }
        }
    }
    private func applyOrientation() {
        guard let value = AVCaptureVideoOrientation(rawValue: orientation.captureOrientationRawValue) else { return }
        for connection in [output.connection(with: .video), preview?.connection].compactMap({ $0 }) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = value }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
        }
    }
    func orient(_ value: PhotoCapturePolicy.Orientation, token: UUID) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            guard self.ready, self.processor == nil, self.session.isRunning else {
                DispatchQueue.main.async { [weak self] in self?.deliver(token, .failed("The camera was interrupted. Tap Retry before taking a photo.")) }; return
            }
            self.token = token; self.orientation = value; self.applyOrientation()
            self.emit(.ready(self.lens, AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil, self.dimensions, value))
        }
    }
    func capture(orientation: PhotoCapturePolicy.Orientation, token: UUID) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.ready, self.processor == nil, self.session.isRunning else {
                DispatchQueue.main.async { [weak self] in self?.deliver(token, .failed("The camera isn’t ready. Tap Retry before taking another photo.")) }; return
            }
            self.token = token; self.ready = false
            // The shutter freezes both output and preview orientation; later
            // gravity/lens changes are refused until review or retake.
            self.orientation = orientation; self.applyOrientation()
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            // AVFoundation does not retain this delegate. Keep the engine and
            // processor alive through the terminal callback even after Close;
            // clearing processor below deliberately breaks the ownership cycle.
            let processor = GuidedPhotoProcessor { [self] data, error in
                self.queue.async { [self] in
                    self.processor = nil
                    guard !self.closed, self.token == token else { return }
                    guard error == nil, let data, let image = UIImage(data: data) else {
                        self.emit(.failed("That photo couldn’t be captured. Hold the phone steady and tap Retry.")); return
                    }
                    self.reviewing = true
                    if self.session.isRunning { self.session.stopRunning() }
                    self.emit(.photo(image))
                }
            }
            self.processor = processor
            self.output.capturePhoto(with: settings, delegate: processor)
        }
    }
    func stop() {
        // The controller may disappear immediately after enqueueing shutdown.
        // Retain this engine until its serialized stop has actually executed.
        queue.async { [self] in
            self.closed = true; self.ready = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}

private final class GuidedPhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let lock = NSLock()
    private var data: Data?
    private var processingError: Error?
    private let completion: (Data?, Error?) -> Void
    init(completion: @escaping (Data?, Error?) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let bytes = error == nil ? photo.fileDataRepresentation() : nil
        lock.lock(); data = bytes; processingError = error; lock.unlock()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        lock.lock(); let bytes = data, failure = error ?? processingError; lock.unlock()
        completion(bytes, failure)
    }
}

private final class GuidedPhotoSurface: UIView {
    let preview = AVCaptureVideoPreviewLayer()
    let imageView = UIImageView()
    private let grid = CAShapeLayer()
    var showGrid = true { didSet { setNeedsLayout() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        preview.videoGravity = .resizeAspect // never crop the camera frame to fill a tall screen
        layer.addSublayer(preview)
        grid.strokeColor = UIColor.white.withAlphaComponent(0.42).cgColor; grid.lineWidth = 1
        grid.fillColor = UIColor.clear.cgColor; layer.addSublayer(grid)
        imageView.contentMode = .scaleAspectFit; addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds; imageView.frame = bounds
        // Normalized camera picture converted through the preview's real
        // orientation/gravity, so thirds never mark letterbox padding.
        let rect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)).intersection(bounds)
        let path = UIBezierPath()
        if showGrid, !rect.isNull, rect.width > 0, rect.height > 0 {
            for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                let x = rect.minX + rect.width * fraction, y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        grid.path = path.cgPath; CATransaction.commit()
    }
}

@MainActor private final class GuidedPhotoController: UIViewController {
    private let purpose: PhotoCapturePurpose
    private let onPicked: @MainActor (UIImage) async -> String?
    private let onCancel: () -> Void
    private let owner: String?
    private let revision: UInt64
    private let workspaceID: UUID?
    private let canvas = UIView(), surface = GuidedPhotoSurface(), closeButton = UIButton(type: .system)
    private let titleLabel = UILabel(), hint = UILabel(), status = UILabel(), level = UILabel()
    private let wideButton = UIButton(type: .system), ultraButton = UIButton(type: .system)
    private let shutter = UIButton(type: .system), retry = UIButton(type: .system)
    private let usePhoto = UIButton(type: .system), retake = UIButton(type: .system)
    private let motion = CMMotionManager()
    private var orientation = PhotoCapturePolicy.Orientation.portrait
    private var appliedOrientation = PhotoCapturePolicy.Orientation.portrait
    private var selectedLens: PhotoCapturePolicy.Lens?
    private var token = UUID(), closed = false, permissionDenied = false
    private var phase = PhotoCapturePolicy.Phase.idle
    private var busy: Bool { phase.isBusy }
    private var captured: UIImage?
    private var foreground: NSObjectProtocol?
    private lazy var engine = GuidedPhotoSession(preview: surface.preview) { [weak self] token, event in
        MainActor.assumeIsolated { self?.receive(token: token, event: event) }
    }

    init(purpose: PhotoCapturePurpose, onPicked: @escaping @MainActor (UIImage) async -> String?, onCancel: @escaping () -> Void) {
        self.purpose = purpose; self.onPicked = onPicked; self.onCancel = onCancel
        owner = AuthStore.shared.userID; revision = AuthStore.shared.syncSessionRevision
        workspaceID = WorkspaceContext.selectedOrgID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black; canvas.backgroundColor = .black; view.addSubview(canvas)
        for label in [titleLabel, hint, status, level] {
            label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true; canvas.addSubview(label)
        }
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.adjustsFontSizeToFitWidth = true; titleLabel.minimumScaleFactor = 0.7
        titleLabel.text = purpose == .interior ? "Room photo" : "Exterior photo"
        hint.adjustsFontForContentSizeCategory = false
        hint.text = compositionHint
        status.font = .preferredFont(forTextStyle: .body)
        level.adjustsFontForContentSizeCategory = false; level.numberOfLines = 1
        level.adjustsFontSizeToFitWidth = true; level.minimumScaleFactor = 0.7
        level.text = "Hold phone upright"
        canvas.addSubview(surface)
        button(closeButton, title: "Close", id: "camera.close", action: #selector(close))
        button(shutter, title: "Take photo", id: "camera.capture", action: #selector(capture))
        button(wideButton, title: "1×", id: "camera.lens.wide", action: #selector(wide))
        button(ultraButton, title: "0.5×", id: "camera.lens.ultraWide", action: #selector(ultra))
        button(retry, title: "Retry", id: "camera.retry", action: #selector(retryCamera))
        button(usePhoto, title: "Use photo", id: "camera.review.use", action: #selector(accept))
        button(retake, title: "Retake", id: "camera.review.retake", action: #selector(retakePhoto))
        shutter.backgroundColor = UIColor(Theme.accent); usePhoto.backgroundColor = UIColor(Theme.accent)
        _ = engine
        showWorking("Opening camera…")
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.checkIdentity()
                if self.phase.canResume { self.openCamera() }
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); startMotion(); openCamera()
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); shutdown() }
    private func button(_ value: UIButton, title: String, id: String, action: Selector) {
        value.setTitle(title, for: .normal); value.accessibilityIdentifier = id
        value.titleLabel?.numberOfLines = 1
        value.titleLabel?.adjustsFontForContentSizeCategory = false
        value.titleLabel?.adjustsFontSizeToFitWidth = true
        value.titleLabel?.minimumScaleFactor = 0.65
        value.setTitleColor(.white, for: .normal); value.layer.cornerRadius = 12
        value.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        value.addTarget(self, action: action, for: .touchUpInside); canvas.addSubview(value)
    }
    private var compositionHint: String {
        purpose == .interior
            ? "Hold landscape from a corner. Keep walls straight. Step back for 1×."
            : "Hold landscape. Fit the roof and both sides. Keep phone upright."
    }
    private func updateControlFonts() {
        // The body/error message retains full Dynamic Type. Fixed-height camera
        // controls scale to a readable bound and fit, rather than becoming an
        // ellipsis at accessibility sizes. Recalculate on every layout/trait change.
        let navigation = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 17, weight: .semibold), maximumPointSize: 26, compatibleWith: traitCollection)
        titleLabel.font = navigation
        for control in [closeButton, shutter, wideButton, ultraButton, retry, usePhoto, retake] {
            control.titleLabel?.font = navigation
        }
        hint.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15), maximumPointSize: 20, compatibleWith: traitCollection)
        level.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12), maximumPointSize: 18, compatibleWith: traitCollection)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateControlFonts()
        let landscape = appliedOrientation.isLandscape
        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero, size: landscape ? CGSize(width: view.bounds.height, height: view.bounds.width) : view.bounds.size)
        canvas.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        canvas.transform = CGAffineTransform(rotationAngle: appliedOrientation.canvasRotationRadians)
        let safe = view.safeAreaInsets
        let pad: CGFloat = landscape ? max(20, max(safe.top, safe.bottom)) : 20
        let top: CGFloat = landscape ? 12 : max(14, safe.top)
        let width = canvas.bounds.width - 2 * pad, height = canvas.bounds.height
        let closeFont = closeButton.titleLabel?.font ?? UIFont.systemFont(ofSize: 17, weight: .semibold)
        let closeTextWidth = ("Close" as NSString).size(withAttributes: [.font: closeFont]).width
        let closeWidth = min(width * 0.38, max(72, ceil(closeTextWidth) + 24))
        closeButton.frame = CGRect(x: pad, y: top, width: closeWidth, height: 44)
        titleLabel.frame = CGRect(x: pad + closeWidth + 12, y: top, width: max(40, width - closeWidth - 12), height: 44)
        let hasError = !status.isHidden && !busy
        if hasError {
            surface.frame = .zero; hint.isHidden = true; level.isHidden = true
            let available = max(44, height - top - 160)
            status.frame = CGRect(x: pad, y: top + 55, width: width, height: available)
            status.adjustsFontSizeToFitWidth = true; status.minimumScaleFactor = 0.65
            retry.frame = CGRect(x: pad, y: height - max(20, safe.bottom) - 64, width: width, height: 52)
            return
        }
        status.adjustsFontSizeToFitWidth = false
        if landscape {
            let side: CGFloat = min(220, width * 0.34), gap: CGFloat = 16
            let right = pad + width - side, areaTop = top + 50
            surface.frame = CGRect(x: pad, y: areaTop, width: max(40, width - side - gap), height: max(40, height - areaTop - 16))
            hint.frame = CGRect(x: right, y: areaTop, width: side, height: max(44, height - areaTop - 154))
            hint.adjustsFontSizeToFitWidth = true; hint.minimumScaleFactor = 0.7
            level.frame = CGRect(x: right, y: height - 142, width: side, height: 28)
            ultraButton.frame = CGRect(x: right, y: height - 112, width: (side - 8) / 2, height: 44)
            wideButton.frame = CGRect(x: right + (side + 8) / 2, y: height - 112, width: (side - 8) / 2, height: 44)
            shutter.frame = CGRect(x: right, y: height - 60, width: side, height: 48)
            status.frame = CGRect(x: right, y: areaTop, width: side, height: max(44, height - areaTop - 100))
        } else {
            let bottom = height - max(16, safe.bottom)
            shutter.frame = CGRect(x: pad, y: bottom - 56, width: width, height: 52)
            ultraButton.frame = CGRect(x: pad, y: bottom - 108, width: (width - 12) / 2, height: 44)
            wideButton.frame = CGRect(x: pad + (width + 12) / 2, y: bottom - 108, width: (width - 12) / 2, height: 44)
            level.frame = CGRect(x: pad, y: bottom - 140, width: width, height: 28)
            hint.frame = CGRect(x: pad, y: top + 52, width: width, height: 72)
            hint.adjustsFontSizeToFitWidth = true; hint.minimumScaleFactor = 0.7
            surface.frame = CGRect(x: pad, y: top + 128, width: width, height: max(60, bottom - 148 - top - 128))
            status.frame = surface.frame
        }
        usePhoto.frame = shutter.frame
        retake.frame = CGRect(x: shutter.frame.minX, y: shutter.frame.minY - 52, width: shutter.frame.width, height: 44)
        surface.setNeedsLayout()
    }
    private var identityIsCurrent: Bool { AuthStore.shared.userID == owner && AuthStore.shared.syncSessionRevision == revision && WorkspaceContext.selectedOrgID == workspaceID }
    func checkIdentity() {
        guard !closed, !identityIsCurrent else { return }
        engine.stop(); captured = nil
        showError("The account or workspace changed. Close this camera and reopen it from the intended home.", retryAllowed: false)
    }
    func shutdown() {
        guard !closed else { return }
        closed = true; phase = .closed; token = UUID(); motion.stopDeviceMotionUpdates(); engine.stop()
        if let foreground { NotificationCenter.default.removeObserver(foreground); self.foreground = nil }
    }
    private func openCamera() {
        guard !closed, identityIsCurrent, phase.canResume else { return }
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil ||
                AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil else {
            showError("A camera is not available on this device. You can close this screen and add an existing photo instead.", retryAllowed: false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined:
            phase = .awaitingPermission
            showWorking("Allow camera access to take a photo.")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed, self.identityIsCurrent, self.phase == .awaitingPermission else { return }
                    self.phase = .idle; self.openCamera()
                }
            }
        case .denied, .restricted:
            permissionDenied = true
            showError("Camera access is off. Allow Camera in iPhone Settings, or close this screen and add an existing photo.")
        @unknown default: showError("Camera access is unavailable. Close this screen and add an existing photo.", retryAllowed: false)
        }
    }
    private func begin() {
        guard !closed, identityIsCurrent, phase.canStart else { return }
        phase = .opening
        permissionDenied = false; token = UUID(); showWorking("Opening camera…")
        engine.start(purpose: purpose, preferred: selectedLens, orientation: orientation, token: token)
    }
    private func showWorking(_ message: String) {
        status.text = message; status.isHidden = false
        hint.isHidden = true; level.isHidden = true; shutter.isHidden = true
        ultraButton.isHidden = true; wideButton.isHidden = true; retry.isHidden = true; usePhoto.isHidden = true; retake.isHidden = true
        view.setNeedsLayout()
    }
    private func showError(_ message: String, retryAllowed: Bool = true) {
        phase = .failed; closeButton.isEnabled = true; status.text = message; status.isHidden = false
        shutter.isHidden = true; ultraButton.isHidden = true; wideButton.isHidden = true; usePhoto.isHidden = true; retake.isHidden = true
        retry.isHidden = !retryAllowed; retry.setTitle(permissionDenied ? "Open Settings" : "Retry", for: .normal)
        view.setNeedsLayout()
    }
    private func receive(token incoming: UUID, event: GuidedPhotoEvent) {
        guard !closed, incoming == token else { return }
        guard identityIsCurrent else { checkIdentity(); return }
        switch event {
        case .ready(let lens, let hasUltra, _, let applied):
            phase = .ready; selectedLens = lens; appliedOrientation = applied
            status.isHidden = true; hint.isHidden = false; level.isHidden = false; retry.isHidden = true
            surface.imageView.image = nil; surface.showGrid = true
            shutter.isHidden = false; ultraButton.isHidden = !hasUltra; wideButton.isHidden = false
            ultraButton.backgroundColor = lens == .ultraWide ? UIColor(Theme.accent) : UIColor.white.withAlphaComponent(0.12)
            wideButton.backgroundColor = lens == .wide ? UIColor(Theme.accent) : UIColor.white.withAlphaComponent(0.12)
            ultraButton.accessibilityValue = lens == .ultraWide ? "Selected" : ""
            wideButton.accessibilityValue = lens == .wide ? "Selected" : ""
            if !hasUltra && purpose == .interior { hint.text = "This iPhone uses 1×. Hold landscape from a corner. Keep walls straight." }
        case .photo(let image):
            phase = .reviewing; captured = image; surface.imageView.image = image; surface.showGrid = false
            hint.text = "Check the whole frame and straight walls before using this photo."
            hint.isHidden = false; status.isHidden = true; level.isHidden = true; retry.isHidden = true
            shutter.isHidden = true; ultraButton.isHidden = true; wideButton.isHidden = true; usePhoto.isHidden = false; retake.isHidden = false
        case .failed(let message): showError(message)
        }
        view.setNeedsLayout()
    }
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { level.text = "Align walls with grid"; return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] reading, _ in
            guard let self, !self.closed, self.phase.canOrient, self.identityIsCurrent else { return }
            guard let gravity = reading?.gravity else {
                self.level.text = "Align walls with grid"
                self.level.textColor = .systemYellow
                return
            }
            let next = PhotoCapturePolicy.orientation(gravityX: gravity.x, gravityY: gravity.y, previous: self.orientation)
            if next != self.orientation {
                self.orientation = next; self.token = UUID(); self.phase = .orienting
                self.engine.orient(next, token: self.token)
            }
            if let value = PhotoCapturePolicy.level(gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z, orientation: next) {
                self.level.text = value.isLevel ? "Level — hold steady" : (abs(value.rollRadians) > 2 * .pi / 180 ? "Straighten phone" : "Hold phone upright")
                self.level.textColor = value.isLevel ? .systemGreen : .systemYellow
            } else {
                self.level.text = "Align walls with grid"
                self.level.textColor = .systemYellow
            }
        }
    }
    @objc private func close() {
        guard !closed, phase != .saving else { return }
        shutdown(); onCancel()
    }
    @objc private func retryCamera() {
        guard !closed, phase == .failed, identityIsCurrent else { return }
        if permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        else { begin() }
    }
    @objc private func wide() { switchLens(.wide) }
    @objc private func ultra() { switchLens(.ultraWide) }
    private func switchLens(_ lens: PhotoCapturePolicy.Lens) {
        guard !closed, phase.canCapture, identityIsCurrent else { return }
        selectedLens = lens; begin()
    }
    @objc private func capture() {
        guard !closed, phase.canCapture, identityIsCurrent else { return }
        // Read the latest gravity at shutter time, not a delayed UI publication.
        if let gravity = motion.deviceMotion?.gravity {
            orientation = PhotoCapturePolicy.orientation(gravityX: gravity.x, gravityY: gravity.y, previous: orientation)
        }
        phase = .capturing; appliedOrientation = orientation; token = UUID(); showWorking("Taking photo… Hold steady.")
        engine.capture(orientation: orientation, token: token)
    }
    @objc private func retakePhoto() {
        guard !closed, phase == .reviewing, identityIsCurrent else { return }
        captured = nil; surface.imageView.image = nil
        hint.text = compositionHint
        begin()
    }
    @objc private func accept() {
        guard !closed, phase == .reviewing, identityIsCurrent, let image = captured else { checkIdentity(); return }
        phase = .saving; usePhoto.isEnabled = false; retake.isEnabled = false; closeButton.isEnabled = false
        usePhoto.setTitle("Saving…", for: .normal)
        let saveToken = token
        Task { @MainActor [weak self] in
            guard let self else { return }
            let failure = await self.onPicked(image)
            guard !self.closed, self.token == saveToken else { return }
            guard self.identityIsCurrent else { self.checkIdentity(); return }
            if let failure {
                self.phase = .reviewing
                self.hint.text = failure
                self.usePhoto.setTitle("Use photo", for: .normal)
                self.usePhoto.isEnabled = true; self.retake.isEnabled = true; self.closeButton.isEnabled = true
                self.view.setNeedsLayout()
            } else {
                // Parent acknowledged a durable save and dismisses its cover.
                self.shutdown()
            }
        }
    }
}
