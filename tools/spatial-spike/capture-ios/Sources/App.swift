import UIKit
import ARKit
import AVFoundation
import RealityKit
import Darwin

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = CaptureViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class CaptureViewController: UIViewController {
    private var arView: ARView?
    private let recorder = CaptureRecorder()
    private let start = UIButton(type: .system)
    private let stop = UIButton(type: .system)
    private let export = UIButton(type: .system)
    private let status = UILabel()
    private var controls = CaptureControls()
    private var finishedURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        status.text = ARWorldTrackingConfiguration.isSupported
            ? "Local Phase A capture. Walk slowly around one room, then stop. Files stay on this phone."
            : "A physical iPhone supporting AR world tracking is required. The simulator cannot capture a room."
        status.accessibilityIdentifier = "spatial.status"
        start.accessibilityIdentifier = "spatial.start"
        stop.accessibilityIdentifier = "spatial.stop"
        export.accessibilityIdentifier = "spatial.export"
        status.numberOfLines = 0
        status.textColor = .white
        status.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .body)
        let stack = UIStackView(arrangedSubviews: [status, start, stop, export])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        for (button, title, action) in [(start, "Start new room", #selector(startTapped)),
                                        (stop, "Stop and save", #selector(stopTapped)),
                                        (export, "Export completed capture", #selector(exportTapped))] {
            var config = UIButton.Configuration.filled()
            config.title = title
            button.configuration = config
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        refreshControls()
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        recorder.onStatus = { [weak self] message in if self?.controls.isRecording == true { self?.status.text = message } }
        recorder.onFinished = { [weak self] url, message, ready in
            guard let self else { return }
            self.releasePreview()
            UIApplication.shared.isIdleTimerDisabled = false
            self.controls.captureFinished(exportable: ready)
            self.finishedURL = url
            self.status.text = message
            self.refreshControls()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func startTapped() {
        guard ARWorldTrackingConfiguration.isSupported else {
            status.text = "A physical iPhone supporting AR world tracking is required. The simulator cannot capture a room."
            return
        }
        guard controls.beginStart() else { return }
        finishedURL = nil
        refreshControls()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.status.text = "Camera access is required for local capture. Enable it in Settings."
                    self.controls.startFailed()
                    self.refreshControls()
                    return
                }
                self.recorder.start(deviceModel: "\(UIDevice.current.model) (\(Self.hardwareModel()))", operatingSystem: UIDevice.current.systemVersion) { result in
                    switch result {
                    case .failure(let error):
                        self.status.text = error.localizedDescription
                        self.controls.startFailed()
                        self.refreshControls()
                    case .success:
                        guard UIApplication.shared.applicationState == .active else {
                            self.recorder.finish(status: "interrupted", detail: "App became inactive before capture started.")
                            return
                        }
                        guard self.controls.captureStarted() else {
                            self.recorder.finish(status: "interrupted", detail: "Capture start was cancelled before tracking began.")
                            return
                        }
                        self.refreshControls()
                        self.status.text = "Starting world tracking. Move slowly until tracking is normal."
                        UIApplication.shared.isIdleTimerDisabled = true
                        let configuration = ARWorldTrackingConfiguration()
                        configuration.worldAlignment = .gravity
                        configuration.isAutoFocusEnabled = true
                        // Keep one sensor format for the epoch; each frame still carries exact K.
                        if let format = ARWorldTrackingConfiguration.supportedVideoFormats
                            .filter({ $0.imageResolution.width <= 1920 && $0.framesPerSecond == 30 })
                            .max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
                            configuration.videoFormat = format
                        }
                        self.makePreview().session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                    }
                }
            }
        }
    }
    @objc private func stopTapped() {
        guard controls.beginStop() else { return }
        refreshControls()
        status.text = "Saving the last frame…"
        recorder.finish()
        arView?.session.pause()
    }
    @objc private func willResignActive() {
        guard controls.beginStop() else { return }
        refreshControls()
        recorder.finish(status: "interrupted", detail: "App became inactive. Files preserved; start a fresh capture.")
    }
    @objc private func exportTapped() {
        guard let finishedURL, controls.beginExport() else { return }
        refreshControls()
        status.text = "Verifying every image and sidecar before export…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NativeRasterWriter.validateCapture(at: finishedURL) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.controls.exportChecked(valid: false)
                    self.refreshControls()
                    self.status.text = error.localizedDescription
                case .success:
                    self.controls.exportChecked(valid: true)
                    self.refreshControls()
                    self.status.text = "Capture verified. Choose a local folder for its copy."
                    self.present(UIDocumentPickerViewController(forExporting: [finishedURL], asCopy: true), animated: true)
                }
            }
        }
    }
    private func refreshControls() {
        start.isEnabled = controls.startEnabled
        stop.isEnabled = controls.stopEnabled
        export.isEnabled = controls.exportEnabled
    }
    private func makePreview() -> ARView {
        if let arView { return arView }
        // Unsupported devices never allocate a renderer or ask for the camera.
        // Permission and hardware support have already been checked by the caller.
        let preview = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        preview.accessibilityIdentifier = "spatial.preview"
        preview.session.delegate = recorder
        preview.session.delegateQueue = recorder.delegateQueue
        preview.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(preview, at: 0)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor), preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.topAnchor.constraint(equalTo: view.topAnchor), preview.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        arView = preview
        return preview
    }
    private func releasePreview() {
        // This renderer belongs to the finished epoch. Detach before pausing so
        // its lifecycle callbacks cannot be routed into a later room session.
        arView?.session.delegate = nil
        arView?.session.pause()
        arView?.removeFromSuperview()
        arView = nil
    }
    private static func hardwareModel() -> String {
        // Product hardware identifier (e.g. iPhone17,3), never serial/UDID/name.
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown-hardware" }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}
