#if SPATIAL_CAPTURE_LAB
import ARKit
import AVFoundation
import RealityKit
import SwiftUI

/// One AR session is one tour coordinate epoch. Leaving or interrupting capture
/// finalizes that epoch; a saved tour can be viewed, never silently resumed.
@MainActor
final class GuidedPanoramaCaptureController: UIViewController, @preconcurrency ARSessionDelegate {
    var onClose: ((URL?, String) -> Void)?
    private let recorder = StationCaptureRecorder()
    private let cameraView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    private let heading = UILabel()
    private let instruction = UILabel()
    private let direction = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let scan = UIButton(type: .system)
    private let preview = UIButton(type: .system)
    private let finish = UIButton(type: .system)
    private let target = UIView()
    private let reticle = UIView()
    private var update: StationCaptureUpdate?
    private var closing = false
    private var closed = false
    private var sessionRunning = false
    private var previousIdleTimer: Bool?
    private var previewCancellation: GuidedPanoramaPreviewCancellation?
    private var previewController: PanoramaPreviewViewController?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastGuidanceTime = -Double.infinity

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.bg)
        view.tintColor = UIColor(Theme.accent)
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.accessibilityIdentifier = "panorama.cameraPreview"
        view.addSubview(cameraView)
        NSLayoutConstraint.activate([
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        cameraView.session.delegateQueue = .main
        cameraView.session.delegate = self
        configureControls()
        recorder.onUpdate = { [weak self] update in self?.apply(update) }
        recorder.onFinished = { [weak self] url, message in self?.complete(url: url, message: message) }
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        Task { await start() }
    }

    private func configureControls() {
        for label in [heading, instruction, direction] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(Theme.ink)
        }
        heading.font = .preferredFont(forTextStyle: .headline)
        instruction.font = .preferredFont(forTextStyle: .body)
        direction.font = .preferredFont(forTextStyle: .subheadline)
        heading.text = "Room tour · starting camera"
        instruction.text = "Stand in a clear spot. Keep the camera over that spot while you turn around it."
        direction.text = "Line up the purple target with the center circle."
        progress.progressTintColor = UIColor(Theme.accent)
        scan.accessibilityIdentifier = "panorama.capture.scan"
        preview.accessibilityIdentifier = "panorama.capture.preview"
        finish.accessibilityIdentifier = "panorama.capture.finish"
        scan.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        preview.addTarget(self, action: #selector(previewTapped), for: .touchUpInside)
        finish.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        setButton(scan, title: "Starting camera…", enabled: false, primary: true)
        setButton(preview, title: "Preview this position", enabled: false)
        setButton(finish, title: "Finish and save", enabled: true)
        let buttons = UIStackView(arrangedSubviews: [scan, preview, finish])
        buttons.axis = .vertical; buttons.spacing = 8
        let content = UIStackView(arrangedSubviews: [heading, progress, instruction, direction, buttons])
        content.axis = .vertical; content.spacing = 10
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        content.backgroundColor = UIColor(Theme.card).withAlphaComponent(0.97)
        content.layer.cornerRadius = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        for (indicator, diameter, color) in [(reticle, CGFloat(52), UIColor.white), (target, CGFloat(34), UIColor(Theme.accent))] {
            indicator.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            indicator.layer.cornerRadius = diameter / 2
            indicator.layer.borderWidth = 3
            indicator.layer.borderColor = color.cgColor
            indicator.backgroundColor = color.withAlphaComponent(0.15)
            indicator.isUserInteractionEnabled = false
            view.insertSubview(indicator, belowSubview: content)
        }
        target.isHidden = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reticle.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    private func setButton(_ button: UIButton, title: String, enabled: Bool, primary: Bool = false) {
        var configuration = primary ? UIButton.Configuration.filled() : .tinted()
        configuration.title = title
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = enabled ? UIColor(Theme.accent) : UIColor(Theme.disabledFill)
        configuration.baseForegroundColor = enabled ? (primary ? .white : UIColor(Theme.accent)) : UIColor(Theme.disabledInk)
        configuration.contentInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12)
        button.configuration = configuration
        button.isEnabled = enabled
    }

    private func start() async {
        guard ARWorldTrackingConfiguration.isSupported else {
            complete(url: nil, message: "Room capture requires an ARKit-capable iPhone."); return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard !closing, !closed else { return }
        guard authorized else {
            complete(url: nil, message: "Allow camera access in iPhone Settings → Rendprop to capture a room."); return
        }
        guard UIApplication.shared.applicationState == .active else {
            complete(url: nil, message: "Capture did not start because the app left the foreground."); return
        }
        do {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.isAutoFocusEnabled = true
            if let format = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter({ $0.imageResolution.width <= 1920 && $0.framesPerSecond == 30 })
                .max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
                configuration.videoFormat = format
            }
            let size = configuration.videoFormat.imageResolution
            guard let width = Int(exactly: size.width), let height = Int(exactly: size.height) else {
                throw CaptureError.invalid("The camera selected an unsupported photo size.")
            }
            try CaptureRasterLimits.validate(ImageResolution(width: width, height: height))
            let depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            if depthSupported { configuration.frameSemantics.insert(.sceneDepth) }
            try await recorder.startTour(deviceModel: UIDevice.current.model,
                                         operatingSystem: UIDevice.current.systemVersion, depthSupported: depthSupported)
            guard !closing, !closed, UIApplication.shared.applicationState == .active else {
                end(reason: "Capture closed before tracking started. Saved files are preserved."); return
            }
            previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            sessionRunning = true
            cameraView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            refreshButtons()
        } catch {
            guard !closed, !closing else { return }
            if recorder.state == .idle || recorder.state == .finished {
                complete(url: recorder.tourURL, message: error.localizedDescription)
            } else { end(reason: error.localizedDescription) }
        }
    }

    private func apply(_ update: StationCaptureUpdate) {
        self.update = update
        instruction.text = update.message
        let stationNumber = recorder.currentStationID == nil ? max(1, recorder.manifest?.stations.count ?? 0) : (recorder.manifest?.stations.count ?? 1)
        let savedTargets = update.state == .ready ? (recorder.manifest?.stations.last?.frames.count ?? 0) : update.savedTargets
        heading.text = "Position \(stationNumber) · \(savedTargets)/\(update.totalTargets) photos"
        progress.progress = Float(savedTargets) / Float(max(1, update.totalTargets))
        target.isHidden = update.state != .capturing
        if update.state == .ready {
            direction.text = (recorder.manifest?.frameCount ?? 0) > 0
                ? "Next: move a few feet, keeping some of the same room in view."
                : "Start in a clear spot, away from nearby furniture."
        }
        refreshButtons()
    }

    private func refreshButtons() {
        let busyPreview = previewCancellation != nil
        let trackingReady: Bool
        if let frame = cameraView.session.currentFrame, case .normal = frame.camera.trackingState { trackingReady = true }
        else { trackingReady = false }
        let ready = recorder.state == .ready && !closing && !busyPreview
        let active = (recorder.state == .capturing || recorder.state == .saving) && recorder.currentStationID != nil && !closing
        let full = (recorder.manifest?.stations.count ?? 0) >= StationCaptureLimits.maximumStations
        let title = active ? "Save this position early" : full ? "All 8 positions saved" :
            ((recorder.manifest?.stations.isEmpty ?? true) ? "Scan this position" : "Scan next position")
        setButton(scan, title: title, enabled: active || (ready && sessionRunning && trackingReady && !full), primary: true)
        setButton(preview, title: busyPreview ? "Cancel preview" : "Preview this position",
                  enabled: !closing && (busyPreview || (ready && recorder.manifest?.stations.last?.frames.isEmpty == false)))
        setButton(finish, title: closing ? "Saving your tour…" : "Finish and save", enabled: !closing)
    }

    @objc private func scanTapped() {
        if recorder.state == .capturing || recorder.state == .saving {
            recorder.finishStation(); return
        }
        guard let frame = cameraView.session.currentFrame, previewCancellation == nil else { return }
        do { try recorder.beginStation(frame: frame) }
        catch { instruction.text = error.localizedDescription }
    }

    @objc private func previewTapped() {
        if let cancellation = previewCancellation { cancellation.cancel(); return }
        guard recorder.state == .ready, let url = recorder.tourURL,
              let station = recorder.manifest?.stations.last, !station.frames.isEmpty else { return }
        let cancellation = GuidedPanoramaPreviewCancellation()
        previewCancellation = cancellation
        refreshButtons()
        GuidedPanoramaPreviewStore.queue.async { [weak self] in
            let result = Result {
                try GuidedPanoramaPreviewStore.build(tourURL: url, stationIDs: [station.id], cancellation: cancellation) { fraction, message in
                    DispatchQueue.main.async {
                        guard let self, !self.closing, self.previewCancellation === cancellation else { return }
                        self.instruction.text = message; self.progress.progress = Float(fraction)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.previewCancellation === cancellation else { return }
                self.previewCancellation = nil
                guard !self.closing, !self.closed else { return }
                self.refreshButtons()
                switch result {
                case .success(let stations):
                    guard !cancellation.isCancelled else { return }
                    let viewer = PanoramaPreviewViewController(stations: stations, tintColor: UIColor(Theme.accent))
                    viewer.onClose = { [weak self, weak viewer] in
                        viewer?.dismiss(animated: true)
                        self?.previewController = nil
                        if let update = self?.update { self?.apply(update) }
                    }
                    viewer.modalPresentationStyle = .fullScreen
                    self.previewController = viewer
                    self.present(viewer, animated: true)
                case .failure(let error): self.instruction.text = error.localizedDescription
                }
            }
        }
    }

    @objc private func finishTapped() { end(reason: nil) }
    @objc private func backgrounded() {
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save room tour") { [weak self] in self?.endBackgroundTask() }
        }
        end(reason: "Capture was interrupted. Saved photos are preserved; start a new tour to continue scanning.")
    }

    func endPresentation() {
        if !closed { end(reason: "Capture closed. Saved photos are preserved.") }
        stopCamera()
        endBackgroundTask()
    }

    private func end(reason: String?) {
        guard !closing, !closed else { return }
        closing = true
        previewCancellation?.cancel()
        // ARKit callbacks may hold session work. Stop admission immediately,
        // then pause after the callback returns; retain until cleanup executes.
        DispatchQueue.main.async { self.stopCamera() }
        previewController?.dismiss(animated: false)
        previewController = nil
        if recorder.state == .idle || recorder.state == .finished {
            complete(url: recorder.tourURL, message: reason ?? "No photos captured.")
        } else { recorder.endTour(reason: reason); refreshButtons() }
    }

    private func complete(url: URL?, message: String) {
        guard !closed else { return }
        closed = true; closing = true
        previewCancellation?.cancel()
        stopCamera()
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
        onClose?(url, message)
    }

    private func stopCamera() {
        cameraView.session.delegate = nil
        if sessionRunning { cameraView.session.pause() }
        sessionRunning = false
        if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !closing else { return }
        if case .limited(.relocalizing) = frame.camera.trackingState {
            end(reason: "Camera tracking restarted. Saved positions are safe; start a new tour for further scanning."); return
        }
        recorder.process(frame: frame)
        guard frame.timestamp - lastGuidanceTime >= 0.1 else { return }
        lastGuidanceTime = frame.timestamp
        refreshButtons()
        guard recorder.state == .capturing, let vector = update?.targetDirection, vector.count == 3,
              let station = recorder.manifest?.stations.last else { target.isHidden = true; return }
        let world = SIMD3<Float>(Float(station.origin[0] + vector[0] * 2), Float(station.origin[1] + vector[1] * 2), Float(station.origin[2] + vector[2] * 2))
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let local = frame.camera.viewMatrix(for: orientation) * SIMD4<Float>(world, 1)
        let projected = frame.camera.projectPoint(world, orientation: orientation, viewportSize: cameraView.bounds.size)
        let visible = local.z < 0 && cameraView.bounds.insetBy(dx: 28, dy: 28).contains(projected)
        target.isHidden = !visible
        if visible {
            target.center = projected
            direction.text = "Center the target, then hold still for the photo."
        } else if abs(local.y) > abs(local.x), abs(local.y) > 0.2 {
            direction.text = local.y > 0 ? "↑ Tilt up toward the target" : "↓ Tilt down toward the target"
        } else {
            direction.text = local.x > 0 ? "→ Turn right toward the target" : "← Turn left toward the target"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        end(reason: "The camera was interrupted. Saved photos are safe; start a new tour for further scanning.")
    }
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        if case .limited(.relocalizing) = camera.trackingState {
            end(reason: "Camera tracking restarted. Saved photos are safe; start a new tour for further scanning.")
        }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        end(reason: "Camera stopped: \(error.localizedDescription). Saved photos are preserved.")
    }
}
#endif
