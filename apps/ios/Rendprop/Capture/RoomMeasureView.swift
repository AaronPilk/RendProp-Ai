import SwiftUI
import UIKit
import ARKit
import SceneKit
import AVFoundation
import simd

/// A user-reviewed AR estimate, returned in metres. This is not a survey or
/// a verified building measurement; manual entry remains available on return.
@MainActor
struct RoomMeasureView: View {
    let unit: FloorMeasurementUnit
    let onUse: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = RoomMeasureBridge()

    init(unit: FloorMeasurementUnit, onUse: @escaping (Double) -> Void) {
        self.unit = unit; self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            RoomMeasureCamera(unit: unit, bridge: bridge) { metres in
                onUse(metres)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Measure room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { bridge.stop(); dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .onDisappear { bridge.stop() }
    }
}

@MainActor
private final class RoomMeasureBridge: ObservableObject {
    weak var controller: RoomMeasureController?
    var closed = false
    func stop() { closed = true; controller?.shutdown() }
}

private struct RoomMeasureCamera: UIViewControllerRepresentable {
    let unit: FloorMeasurementUnit
    let bridge: RoomMeasureBridge
    let onUse: (Double) -> Void
    func makeUIViewController(context: Context) -> RoomMeasureController {
        let controller = RoomMeasureController(unit: unit, bridge: bridge, onUse: onUse)
        bridge.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: RoomMeasureController, context: Context) {}
    static func dismantleUIViewController(_ controller: RoomMeasureController, coordinator: ()) { controller.shutdown() }
}

private final class RoomMeasureController: UIViewController, ARSessionDelegate {
    private struct Endpoint { let position: SIMD3<Float>; let estimated: Bool }
    private let unit: FloorMeasurementUnit
    private let bridge: RoomMeasureBridge
    private let onUse: (Double) -> Void
    private let camera = ARSCNView()
    private let status = UILabel(), distance = UILabel(), instruction = UILabel()
    private let pointButton = UIButton(type: .system), useButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system), settingsButton = UIButton(type: .system)
    private let estimatedSwitch = UISwitch()
    private var startPoint: Endpoint?, endPoint: Endpoint?, candidate: Endpoint?
    private var observers: [NSObjectProtocol] = []
    private var token = UUID(), closed = false, running = false
    private var lastUpdate: TimeInterval = 0

    init(unit: FloorMeasurementUnit, bridge: RoomMeasureBridge, onUse: @escaping (Double) -> Void) {
        self.unit = unit; self.bridge = bridge; self.onUse = onUse
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        camera.translatesAutoresizingMaskIntoConstraints = false
        camera.scene = SCNScene(); view.addSubview(camera)
        let reticle = UILabel(); reticle.text = "+"; reticle.textColor = .white
        reticle.font = .systemFont(ofSize: 42, weight: .light)
        reticle.isAccessibilityElement = true; reticle.accessibilityLabel = "Aim the centre at the measurement endpoint"
        reticle.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(reticle)
        NSLayoutConstraint.activate([reticle.centerXAnchor.constraint(equalTo: camera.centerXAnchor),
                                     reticle.centerYAnchor.constraint(equalTo: camera.centerYAnchor)])
        status.font = .preferredFont(forTextStyle: .subheadline)
        distance.font = .preferredFont(forTextStyle: .title2)
        instruction.font = .preferredFont(forTextStyle: .footnote)
        for label in [status, distance, instruction] {
            label.textColor = .white; label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true
        }
        instruction.text = "Move slowly to find a wall or floor. Aim the centre at one end, then the other. Keep points at the same height for length or width. Review the approximate distance; check important dimensions with a tape measure."
        estimatedSwitch.onTintColor = UIColor(Theme.accent)
        estimatedSwitch.accessibilityLabel = "Allow estimated surfaces, less reliable"
        estimatedSwitch.addTarget(self, action: #selector(surfaceModeChanged), for: .valueChanged)
        let estimateLabel = UILabel(); estimateLabel.text = "Allow estimated surfaces (less reliable)"
        estimateLabel.textColor = .white; estimateLabel.font = .preferredFont(forTextStyle: .footnote); estimateLabel.numberOfLines = 0
        let estimateRow = UIStackView(arrangedSubviews: [estimateLabel, estimatedSwitch]); estimateRow.spacing = 8
        configure(pointButton, "Start point", #selector(pickPoint), primary: true)
        configure(useButton, "Use approximate measurement", #selector(useMeasurement), primary: true)
        configure(resetButton, "Reset / restart", #selector(restart))
        configure(settingsButton, "Open camera settings", #selector(openSettings))
        let panel = UIStackView(arrangedSubviews: [status, distance, instruction, estimateRow,
                                                  pointButton, useButton, resetButton, settingsButton])
        panel.axis = .vertical; panel.spacing = 9
        panel.isLayoutMarginsRelativeArrangement = true; panel.layoutMargins = .init(top: 14, left: 16, bottom: 14, right: 16)
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.82); panel.layer.cornerRadius = 16
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(panel); view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                                     scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                                     scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                                     scroll.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.52),
                                     panel.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                                     panel.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                                     panel.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                                     panel.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                                     panel.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                                     camera.topAnchor.constraint(equalTo: view.topAnchor),
                                     camera.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     camera.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     camera.bottomAnchor.constraint(equalTo: scroll.topAnchor, constant: -8)])
        pointButton.isEnabled = false; useButton.isEnabled = false; settingsButton.isHidden = true
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                     ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                DispatchQueue.main.async { self?.lifecycle(note.name) }
            })
        }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); restart() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); shutdown() }

    private func configure(_ button: UIButton, _ title: String, _ action: Selector, primary: Bool = false) {
        var config = primary ? UIButton.Configuration.filled() : .tinted()
        config.title = title; config.baseBackgroundColor = UIColor(Theme.accent)
        config.baseForegroundColor = .white; config.cornerStyle = .medium
        button.configuration = config; button.addTarget(self, action: action, for: .touchUpInside)
    }
    private var active: Bool { !closed && !bridge.closed && UIApplication.shared.applicationState == .active }
    private var tooWarm: Bool { ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical }

    @objc private func restart() {
        guard active else { return }
        invalidate("Starting camera…")
        guard ARWorldTrackingConfiguration.isSupported else {
            status.text = "AR measurement is unavailable on this device. Close this screen and enter the dimension manually."
            resetButton.isHidden = true; estimatedSwitch.isEnabled = false; return
        }
        guard !tooWarm else { status.text = "This phone is too warm for reliable tracking. Let it cool, then restart, or enter the dimension manually."; return }
        let request = token
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: runSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.active, self.token == request else { return }
                    if granted { self.runSession() } else { self.cameraDenied() }
                }
            }
        default: cameraDenied()
        }
    }
    private func cameraDenied() {
        status.text = "Camera access is needed for AR measurement. Allow it in Settings, or close and enter the dimension manually."
        settingsButton.isHidden = false
    }
    private func runSession() {
        guard active, !tooWarm, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        // A new session makes queued callbacks from a previous coordinate space
        // distinguishable; never compare endpoints across reset or relocalization.
        let session = ARSession(); session.delegateQueue = .main; session.delegate = self
        camera.session = session
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        running = true; settingsButton.isHidden = true; resetButton.isHidden = false
        status.text = "Scan nearby surfaces slowly. Waiting for normal tracking…"
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    private func clearPoints() {
        startPoint = nil; endPoint = nil; candidate = nil; distance.text = "Approximate measurement"
        camera.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        pointButton.configuration?.title = "Start point"
        pointButton.isEnabled = false; useButton.isEnabled = false
    }
    private func invalidate(_ message: String) {
        token = UUID(); running = false; lastUpdate = 0
        camera.session.delegate = nil; camera.session.pause(); clearPoints(); status.text = message
    }
    func shutdown() {
        guard !closed else { return }
        closed = true; invalidate("Measurement closed")
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
    private func lifecycle(_ name: Notification.Name) {
        guard !closed, !bridge.closed else { return }
        if name == UIApplication.willResignActiveNotification {
            invalidate("Measurement paused. Both points were cleared.")
        } else if name == UIApplication.didBecomeActiveNotification { restart() }
        else if tooWarm { invalidate("Phone too warm. Both points were cleared. Let it cool, then restart.") }
    }
    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString), active else { return }
        UIApplication.shared.open(url)
    }
    @objc private func surfaceModeChanged() { clearPoints(); refresh() }

    private func normalFrame() -> ARFrame? {
        guard active, running, !tooWarm, let frame = camera.session.currentFrame,
              case .normal = frame.camera.trackingState,
              CACurrentMediaTime() - frame.timestamp >= 0,
              CACurrentMediaTime() - frame.timestamp < 0.5 else { return nil }
        return frame
    }
    private func hit() -> Endpoint? {
        guard normalFrame() != nil, camera.bounds.width > 0, camera.bounds.height > 0 else { return nil }
        let centre = CGPoint(x: camera.bounds.midX, y: camera.bounds.midY)
        let targets: [ARRaycastQuery.Target] = estimatedSwitch.isOn ? [.existingPlaneGeometry, .estimatedPlane] : [.existingPlaneGeometry]
        for target in targets {
            guard let query = camera.raycastQuery(from: centre, allowing: target, alignment: .any),
                  let result = camera.session.raycast(query).first else { continue }
            let t = result.worldTransform.columns.3, p = SIMD3<Float>(t.x, t.y, t.z)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
            return Endpoint(position: p, estimated: target == .estimatedPlane)
        }
        return nil
    }
    private func metres(_ a: Endpoint, _ b: Endpoint) -> Double? {
        let value = Double(simd_distance(a.position, b.position))
        return value.isFinite && value >= 0.1 && value <= 100 ? value : nil
    }
    private func formatted(_ metres: Double) -> String {
        switch unit {
        case .meters: return String(format: "%.2f m · approximate", metres)
        case .feet:
            let inches = Int((metres / 0.0254).rounded())
            return "\(inches / 12) ft \(inches % 12) in · approximate"
        }
    }
    private func refresh() {
        guard normalFrame() != nil else { pointButton.isEnabled = false; useButton.isEnabled = false; return }
        candidate = hit()
        if let start = startPoint, let end = endPoint, let value = metres(start, end) {
            distance.text = formatted(value); pointButton.isEnabled = false; useButton.isEnabled = true
            status.text = start.estimated || end.estimated ? "Review: estimated surface used. This may be less reliable." : "Review: both points on detected surfaces. Still approximate."
        } else {
            pointButton.isEnabled = candidate != nil; useButton.isEnabled = false
            status.text = candidate == nil ? "Aim at a detected wall or floor. Move slowly to scan more of the surface."
                : (candidate!.estimated ? "Estimated surface · less reliable" : "Detected surface · approximate")
            if let start = startPoint, let current = candidate, let value = metres(start, current) { distance.text = formatted(value) }
            else { distance.text = "Approximate measurement" }
        }
    }
    @objc private func pickPoint() {
        guard normalFrame() != nil, endPoint == nil, let point = hit() else { refresh(); return }
        if let start = startPoint {
            guard metres(start, point) != nil else { status.text = "Choose endpoints 0.1 to 100 metres apart, or enter the dimension manually."; return }
            endPoint = point
        } else { startPoint = point; pointButton.configuration?.title = "End point" }
        let sphere = SCNSphere(radius: 0.012); sphere.firstMaterial?.diffuse.contents = UIColor(Theme.accent)
        let marker = SCNNode(geometry: sphere); marker.simdPosition = point.position
        camera.scene.rootNode.addChildNode(marker); refresh()
    }
    @objc private func useMeasurement() {
        guard normalFrame() != nil, let start = startPoint, let end = endPoint, let value = metres(start, end) else { refresh(); return }
        shutdown(); onUse(value)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard session === camera.session, active, running, frame.timestamp - lastUpdate >= 0.1 else { return }
        lastUpdate = frame.timestamp; refresh()
    }
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard session === self.camera.session, active, running else { return }
        if case .normal = camera.trackingState { refresh(); return }
        clearPoints()
        let reason: String
        switch camera.trackingState {
        case .limited(.excessiveMotion): reason = "Move the phone more slowly."
        case .limited(.insufficientFeatures): reason = "Aim at a textured, well-lit wall or floor."
        case .limited(.relocalizing): reason = "Tracking changed. Restart and choose both points again."
        default: reason = "Scan nearby surfaces to initialize tracking."
        }
        status.text = "Tracking is not ready. Both points were cleared. " + reason
    }
    func sessionWasInterrupted(_ session: ARSession) {
        guard session === camera.session, !closed else { return }
        running = false; token = UUID(); clearPoints(); status.text = "Camera interrupted. Both points were cleared."
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        guard session === camera.session, active else { return }; restart()
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === camera.session, !closed else { return }
        invalidate("AR tracking stopped. Both points were cleared. Restart, or enter the dimension manually.")
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
}
