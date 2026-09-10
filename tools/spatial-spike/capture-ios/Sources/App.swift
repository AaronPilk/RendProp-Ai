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
    private let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    private let recorder = CaptureRecorder()
    private let start = UIButton(type: .system)
    private let stop = UIButton(type: .system)
    private let export = UIButton(type: .system)
    private let status = UILabel()
    private var recording = false
    private var finishedURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        arView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(arView)
        arView.session.delegate = recorder
        arView.session.delegateQueue = recorder.delegateQueue
        status.text = "Local Phase A capture. Walk slowly around one room, then stop. Files stay on this phone."
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
        stop.isEnabled = false
        export.isEnabled = false
        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor), arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            arView.topAnchor.constraint(equalTo: view.topAnchor), arView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        recorder.onStatus = { [weak self] message in if self?.recording == true { self?.status.text = message } }
        recorder.onFinished = { [weak self] url, message, ready in
            guard let self else { return }
            self.arView.session.pause()
            UIApplication.shared.isIdleTimerDisabled = false
            self.recording = false
            self.finishedURL = url
            self.status.text = message
            self.start.isEnabled = true
            self.stop.isEnabled = false
            self.export.isEnabled = ready
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func startTapped() {
        guard ARWorldTrackingConfiguration.isSupported else {
            status.text = "A physical iPhone supporting AR world tracking is required. The simulator cannot capture a room."
            return
        }
        start.isEnabled = false
        export.isEnabled = false
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.status.text = "Camera access is required for local capture. Enable it in Settings."; self.start.isEnabled = true; return }
                self.recorder.start(deviceModel: "\(UIDevice.current.model) (\(Self.hardwareModel()))", operatingSystem: UIDevice.current.systemVersion) { result in
                    switch result {
                    case .failure(let error): self.status.text = error.localizedDescription; self.start.isEnabled = true
                    case .success:
                        guard UIApplication.shared.applicationState == .active else {
                            self.recorder.finish(status: "interrupted", detail: "App became inactive before capture started.")
                            return
                        }
                        self.recording = true
                        self.stop.isEnabled = true
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
                        self.arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                    }
                }
            }
        }
    }
    @objc private func stopTapped() {
        guard recording else { return }
        stop.isEnabled = false
        status.text = "Saving the last frame…"
        recorder.finish()
        arView.session.pause()
    }
    @objc private func willResignActive() {
        guard recording else { return }
        recorder.finish(status: "interrupted", detail: "App became inactive. Files preserved; start a fresh capture.")
    }
    @objc private func exportTapped() {
        guard let finishedURL, !recording else { return }
        export.isEnabled = false
        status.text = "Verifying every image and sidecar before export…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try NativeRasterWriter.validateCapture(at: finishedURL) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): self.status.text = error.localizedDescription
                case .success:
                    self.export.isEnabled = true
                    self.status.text = "Capture verified. Choose a local folder for its copy."
                    self.present(UIDocumentPickerViewController(forExporting: [finishedURL], asCopy: true), animated: true)
                }
            }
        }
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
