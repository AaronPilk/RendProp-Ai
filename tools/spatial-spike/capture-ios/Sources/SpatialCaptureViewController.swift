import UIKit
import ARKit
import AVFoundation
import RealityKit
import Darwin

// Shared by the standalone diagnostic target and Rendprop's explicit TestFlight
// build overlay. This file has no app entry point or production service dependency.
final class SpatialCaptureViewController: UIViewController {
    static let captureInstructions = "Take small steps and slow turns. Pause near bright windows until the picture settles. Gently look toward the upper wall corners, keeping a doorway or furniture in view. Revisit corners from another position."
    /// Product handoff is deliberately separate from the Files export. Only a
    /// fully re-read archive may enter upload; recorder completion alone proves
    /// neither that every JPEG is readable nor that its pose belongs to this room.
    var onVerifiedCapture: ((URL) -> Void)?
    private var arView: ARView?
    private let recorder = CaptureRecorder()
    private let start = UIButton(type: .system)
    private let stop = UIButton(type: .system)
    private let export = UIButton(type: .system)
    private let saved = UIButton(type: .system)
    private let status = UILabel()
    private let instructions = UILabel()
    private let messageScroll = UIScrollView()
    private var controls = CaptureControls()
    private var finishedURL: URL?
    private var finishedStopReason: CaptureStopReason?
    private var idleTimerBeforeCapture: Bool?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        status.text = ARWorldTrackingConfiguration.isSupported
            ? (onVerifiedCapture == nil ? "Room photos stay on this phone until you export them." : "Start a new room when you're ready.")
            : "A physical iPhone supporting AR world tracking is required. The simulator cannot capture a room."
        status.accessibilityIdentifier = "spatial.status"
        start.accessibilityIdentifier = "spatial.start"
        stop.accessibilityIdentifier = "spatial.stop"
        export.accessibilityIdentifier = "spatial.export"
        saved.accessibilityIdentifier = "spatial.saved"
        instructions.text = Self.captureInstructions
        instructions.accessibilityIdentifier = "spatial.instructions"
        for label in [instructions, status] {
            label.numberOfLines = 0
            label.textColor = .white
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(UILayoutPriority(751), for: .vertical)
        }
        // Advice has its own label: saved-count and tracking callbacks cannot
        // replace it. Long text can scroll at larger Dynamic Type sizes while
        // Stop and the other controls remain outside the scrolling region.
        let messages = UIStackView(arrangedSubviews: [status, instructions])
        messages.axis = .vertical
        messages.spacing = 12
        messages.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        messageScroll.layer.cornerRadius = 12
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.addSubview(messages)
        view.addSubview(messageScroll)
        let stack = UIStackView(arrangedSubviews: [start, stop, export, saved])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        for (button, title, action) in [(start, "Start new room", #selector(startTapped)),
                                        (stop, "Stop and save", #selector(stopTapped)),
                                        (export, "Export completed capture", #selector(exportTapped)),
                                        (saved, "Saved captures", #selector(savedTapped))] {
            var config = UIButton.Configuration.filled()
            config.title = title
            button.configuration = config
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        refreshControls()
        let preferredMessageHeight = messageScroll.heightAnchor.constraint(equalTo: messages.heightAnchor, constant: 16)
        preferredMessageHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            messageScroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            messageScroll.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            messageScroll.bottomAnchor.constraint(equalTo: stack.topAnchor, constant: -12),
            messages.leadingAnchor.constraint(equalTo: messageScroll.contentLayoutGuide.leadingAnchor, constant: 8),
            messages.trailingAnchor.constraint(equalTo: messageScroll.contentLayoutGuide.trailingAnchor, constant: -8),
            messages.topAnchor.constraint(equalTo: messageScroll.contentLayoutGuide.topAnchor, constant: 8),
            messages.bottomAnchor.constraint(equalTo: messageScroll.contentLayoutGuide.bottomAnchor, constant: -8),
            messages.widthAnchor.constraint(equalTo: messageScroll.frameLayoutGuide.widthAnchor, constant: -16),
            preferredMessageHeight
        ])
        recorder.onStatus = { [weak self] message in if self?.controls.isRecording == true { self?.status.text = message } }
        recorder.onFinished = { [weak self] url, message, ready, stopReason in
            self?.captureFinished(url: url, message: message, exportable: ready, stopReason: stopReason)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    private func captureFinished(url: URL?, message: String, exportable: Bool, stopReason: CaptureStopReason?) {
        guard !controls.isClosed else { return }
        releasePreview()
        restoreIdleTimer()
        controls.captureFinished(exportable: exportable)
        finishedURL = url
        finishedStopReason = stopReason
        status.text = message
        refreshControls()
        // An automatic ceiling is not a request to start paid generation.
        // Show the existing export/use control and wait for an explicit tap.
        if exportable, stopReason == nil, let url, onVerifiedCapture != nil, controls.beginExport() {
            verifyAndExport(id: url.lastPathComponent)
        }
    }

    @objc private func startTapped() {
        guard !controls.isClosed else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            status.text = "A physical iPhone supporting AR world tracking is required. The simulator cannot capture a room."
            return
        }
        guard controls.beginStart() else { return }
        finishedURL = nil
        finishedStopReason = nil
        refreshControls()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, !self.controls.isClosed else { return }
                guard granted else {
                    self.status.text = "Camera access is required for local capture. Enable it in Settings."
                    self.controls.startFailed()
                    self.refreshControls()
                    return
                }
                self.recorder.start(deviceModel: "\(UIDevice.current.model) (\(Self.hardwareModel()))", operatingSystem: UIDevice.current.systemVersion) { [weak self] result in
                    guard let self else { return }
                    guard !self.controls.isClosed else {
                        self.recorder.finish(status: "interrupted", detail: "Capture screen closed before tracking began. Files preserved.")
                        return
                    }
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
                        self.idleTimerBeforeCapture = UIApplication.shared.isIdleTimerDisabled
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
                        // A device-dependent default must satisfy the same
                        // native-raster limits as encoding and saved export.
                        // Fail before starting AR; do not crop/scale or alter K.
                        let nativeSize = configuration.videoFormat.imageResolution
                        guard let width = Int(exactly: nativeSize.width), let height = Int(exactly: nativeSize.height) else {
                            self.recorder.finish(status: "failed", detail: "ARKit selected an invalid native raster size. Files preserved.")
                            return
                        }
                        do { try CaptureRasterLimits.validate(ImageResolution(width: width, height: height)) }
                        catch {
                            self.recorder.finish(status: "failed", detail: error.localizedDescription)
                            return
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
        verifyAndExport(id: finishedURL.lastPathComponent)
    }
    @objc private func savedTapped() {
        guard controls.startEnabled else { return }
        let list = SpatialSavedCapturesController()
        list.onSelect = { [weak self] id in
            guard let self, self.controls.beginSavedExport() else { return }
            self.verifyAndExport(id: id)
        }
        present(UINavigationController(rootViewController: list), animated: true)
    }
    private func verifyAndExport(id: String) {
        refreshControls()
        status.text = "Verifying every image and sidecar before export…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CaptureArchive.local().validateForExport(id: id) }
            DispatchQueue.main.async {
                guard let self, !self.controls.isClosed else { return }
                switch result {
                case .failure(let error):
                    self.controls.exportChecked(valid: false)
                    self.refreshControls()
                    self.status.text = error.localizedDescription
                case .success(let url):
                    self.finishedURL = url
                    self.controls.exportChecked(valid: true)
                    self.refreshControls()
                    if let onVerifiedCapture = self.onVerifiedCapture {
                        self.status.text = "Capture verified. Preparing your private 3D walkthrough…"
                        onVerifiedCapture(url)
                    } else {
                        self.status.text = "Capture verified. Choose a local folder for its copy."
                        self.present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
                    }
                }
            }
        }
    }
    private func refreshControls() {
        instructions.isHidden = !ARWorldTrackingConfiguration.isSupported || !controls.instructionsVisible
        messageScroll.setContentOffset(.zero, animated: false)
        start.isEnabled = controls.startEnabled
        stop.isEnabled = controls.stopEnabled
        export.isEnabled = controls.exportEnabled
        export.isHidden = onVerifiedCapture != nil && finishedStopReason == nil
        export.configuration?.title = onVerifiedCapture != nil ? "Use this scan" : "Export completed capture"
        saved.isEnabled = controls.startEnabled
    }

    // Idempotent and terminal for this controller instance. The permission request
    // cannot be cancelled, so all asynchronous callbacks also check isClosed.
    // A queued recorder.start precedes finish on its serial delegate queue, which
    // preserves an interrupted manifest even if dismissal races file creation.
    func endPresentation() {
        let shouldInterrupt = controls.endPresentation()
        if shouldInterrupt {
            recorder.finish(status: "interrupted", detail: "Capture screen closed. Files preserved; start a fresh capture.")
        }
        releasePreview()
        restoreIdleTimer()
        refreshControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            endPresentation()
        }
    }

    private func restoreIdleTimer() {
        guard let previous = idleTimerBeforeCapture else { return }
        UIApplication.shared.isIdleTimerDisabled = previous
        idleTimerBeforeCapture = nil
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

// Minimal local recovery browser, shared by both targets. Pages replace rather
// than accumulate rows, so arbitrarily many older attempts are not hidden by a
// fixed cap and cannot grow retained UI memory without bound.
private final class SpatialSavedCapturesController: UITableViewController {
    var onSelect: ((String) -> Void)?
    private var entries: [CaptureArchiveEntry] = []
    private var offset = 0
    private var loading = false
    private lazy var previous = UIBarButtonItem(title: "Previous", style: .plain, target: self, action: #selector(previousPage))
    private lazy var more = UIBarButtonItem(title: "More", style: .plain, target: self, action: #selector(nextPage))
    private lazy var refresh = UIBarButtonItem(title: "Refresh", style: .plain, target: self, action: #selector(refreshList))

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Saved captures"
        tableView.accessibilityIdentifier = "spatial.saved.list"
        let done = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(closeList))
        done.accessibilityIdentifier = "spatial.saved.done"
        refresh.accessibilityIdentifier = "spatial.saved.refresh"
        previous.accessibilityIdentifier = "spatial.saved.previous"
        more.accessibilityIdentifier = "spatial.saved.more"
        navigationItem.rightBarButtonItems = [done, refresh]
        toolbarItems = [previous, UIBarButtonItem(systemItem: .flexibleSpace), more]
        navigationController?.setToolbarHidden(false, animated: false)
        loadPage()
    }

    @objc private func closeList() { dismiss(animated: true) }
    @objc private func refreshList() { guard !loading else { return }; offset = 0; loadPage() }
    @objc private func previousPage() { guard !loading else { return }; offset = max(0, offset - CaptureArchive.pageSize); loadPage() }
    @objc private func nextPage() { guard !loading else { return }; offset += CaptureArchive.pageSize; loadPage() }

    private func loadPage() {
        loading = true
        previous.isEnabled = false
        more.isEnabled = false
        refresh.isEnabled = false
        let pageOffset = offset
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CaptureArchive.local().page(offset: pageOffset) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.refresh.isEnabled = true
                self.previous.isEnabled = pageOffset > 0
                switch result {
                case .failure:
                    self.entries = []
                    self.showMessage("Saved captures could not be listed. Files are preserved. Tap Refresh to try again.", id: "spatial.saved.error")
                case .success(let page):
                    self.entries = page.entries
                    self.more.isEnabled = page.hasMore
                    self.tableView.backgroundView = nil
                    if page.entries.isEmpty {
                        self.showMessage(pageOffset == 0 ? "No saved captures yet. Capture a room on a supported iPhone." : "No captures on this page. Use Previous or Refresh.", id: "spatial.saved.empty")
                    }
                }
                self.tableView.reloadData()
            }
        }
    }

    private func showMessage(_ text: String, id: String) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.accessibilityIdentifier = id
        tableView.backgroundView = label
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Local attempts in storage order. Previous/More shows all pages. Tap an attempt to verify it for export."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "capture") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "capture")
        let date = entry.createdAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Unknown date"
        let count = entry.frameCount.map(String.init) ?? "unknown"
        let status = entry.status == "complete" ? "complete (not yet verified)" : entry.status
        cell.textLabel?.text = "\(date) · \(count) frames · \(status)"
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = entry.id + (entry.issue.map { "\n" + $0 } ?? "")
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessibilityIdentifier = "spatial.saved.attempt.\(entry.id)"
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !loading else { return }
        let id = entries[indexPath.row].id
        let selection = onSelect
        dismiss(animated: true) { selection?(id) }
    }
}
