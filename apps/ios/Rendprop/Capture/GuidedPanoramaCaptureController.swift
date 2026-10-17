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
    private let chooseSpot = UIButton(type: .system)
    private let useCurrentSpot = UIButton(type: .system)
    private let recoverSpot = UIButton(type: .system)
    private let target = UIView()
    private let reticle = UIView()
    private let controlScroll = UIScrollView()
    private var update: StationCaptureUpdate?
    private var closing = false
    private var closed = false
    private var sessionRunning = false
    private var previousIdleTimer: Bool?
    private var previewCancellation: GuidedPanoramaPreviewCancellation?
    private var previewController: PanoramaPreviewViewController?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastGuidanceTime = -Double.infinity
    private var confirmingEarlyFinish = false
    private var survey = RoomScanSurveyStability()
    private var surveyPlan: RoomScanPlan?
    private var surveyFrozen = false
    private var choosingViewpoint = true
    private var selectedSuggestedNumber: Int?
    private var lastSurveyTime = -Double.infinity
    private var floorMarkers: [Int: UIButton] = [:]
    private var lastSurveyPlaneID: String?
    private var manualSpotChosen = false
    private var presentedSurveyPlan: RoomScanPlan?
    private var recoverySince: Double?
    private var lastSavedFrameCount = 0
    private let photoFeedback = UIImpactFeedbackGenerator(style: .light)
    private static let suggestionArrivalMetres = 0.45

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
            cameraView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
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
        instruction.text = "Stand in a clear place near the middle of the room. Hold the phone comfortably in front of you."
        direction.text = "Start here, then turn in place. The phone takes the photos for you."
        progress.progressTintColor = UIColor(Theme.accent)
        scan.accessibilityIdentifier = "panorama.capture.scan"
        preview.accessibilityIdentifier = "panorama.capture.preview"
        finish.accessibilityIdentifier = "panorama.capture.finish"
        chooseSpot.accessibilityIdentifier = "panorama.capture.chooseSpot"
        useCurrentSpot.accessibilityIdentifier = "panorama.capture.useCurrentSpot"
        recoverSpot.accessibilityIdentifier = "panorama.capture.recoverSpot"
        scan.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        preview.addTarget(self, action: #selector(previewTapped), for: .touchUpInside)
        finish.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        chooseSpot.addTarget(self, action: #selector(chooseSpotTapped), for: .touchUpInside)
        useCurrentSpot.addTarget(self, action: #selector(useCurrentSpotTapped), for: .touchUpInside)
        recoverSpot.addTarget(self, action: #selector(recoverSpotTapped), for: .touchUpInside)
        setButton(scan, title: "Starting camera…", enabled: false, primary: true)
        setButton(preview, title: "Preview this position", enabled: false)
        setButton(finish, title: "Close room capture", enabled: true)
        setButton(chooseSpot, title: "Choose a suggested spot", enabled: false)
        setButton(useCurrentSpot, title: "Use my current clear spot instead", enabled: false)
        setButton(recoverSpot, title: "Help me start this view again", enabled: false)
        chooseSpot.isHidden = true; useCurrentSpot.isHidden = true; recoverSpot.isHidden = true
        let buttons = UIStackView(arrangedSubviews: [scan, chooseSpot, useCurrentSpot, recoverSpot, preview, finish])
        buttons.axis = .vertical; buttons.spacing = 8
        let content = UIStackView(arrangedSubviews: [heading, progress, instruction, direction, buttons])
        content.axis = .vertical; content.spacing = 10
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        content.backgroundColor = UIColor(Theme.card).withAlphaComponent(0.97)
        content.layer.cornerRadius = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        controlScroll.translatesAutoresizingMaskIntoConstraints = false
        controlScroll.backgroundColor = UIColor(Theme.card)
        controlScroll.layer.cornerRadius = 20
        controlScroll.addSubview(content)
        view.addSubview(controlScroll)
        NSLayoutConstraint.activate([
            controlScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controlScroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controlScroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controlScroll.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.48),
            content.leadingAnchor.constraint(equalTo: controlScroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: controlScroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: controlScroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: controlScroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: controlScroll.frameLayoutGuide.widthAnchor),
            cameraView.bottomAnchor.constraint(equalTo: controlScroll.topAnchor, constant: -8)
        ])
        // Numbered purple floor markers suggest where to stand. A yellow camera
        // target means turn toward a photograph, never walk to another spot.
        for (indicator, diameter, color) in [(reticle, CGFloat(52), UIColor.white), (target, CGFloat(48), UIColor.systemYellow)] {
            indicator.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            indicator.layer.cornerRadius = diameter / 2
            indicator.layer.borderWidth = 3
            indicator.layer.borderColor = color.cgColor
            indicator.backgroundColor = color.withAlphaComponent(0.15)
            indicator.isUserInteractionEnabled = false
            view.insertSubview(indicator, belowSubview: controlScroll)
        }
        let cameraIcon = UIImageView(image: UIImage(systemName: "camera.fill"))
        cameraIcon.tintColor = .systemYellow
        cameraIcon.contentMode = .scaleAspectFit
        cameraIcon.frame = CGRect(x: 12, y: 12, width: 24, height: 24)
        target.addSubview(cameraIcon)
        target.accessibilityLabel = "Next photo direction. Turn the phone; stay where you are."
        target.isHidden = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reticle.center = cameraView.convert(CGPoint(x: cameraView.bounds.midX, y: cameraView.bounds.midY), to: view)
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
            configuration.planeDetection = [.horizontal]
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
        let frameCount = recorder.manifest?.frameCount ?? 0
        if frameCount > lastSavedFrameCount, sessionRunning, !closing,
           UIApplication.shared.applicationState == .active {
            // Feedback follows the completed disk write, never just alignment.
            // High/low photos can therefore finish without watching the screen.
            photoFeedback.impactOccurred()
            photoFeedback.prepare()
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: "Photo saved. \(update.target?.phaseTitle ?? "Room view")")
            }
        }
        lastSavedFrameCount = frameCount
        if update.state == .ready, choosingViewpoint {
            updateSurveyPresentation(frame: cameraView.session.currentFrame)
            refreshButtons()
            return
        }
        instruction.text = update.message
        progress.isHidden = false
        reticle.isHidden = update.state != .capturing
        hideFloorMarkers()
        let stationNumber = recorder.currentStationID == nil ? max(1, recorder.manifest?.stations.count ?? 0) : (recorder.manifest?.stations.count ?? 1)
        let savedTargets = update.state == .ready ? (recorder.manifest?.stations.last?.frames.count ?? 0) : update.savedTargets
        let phase = update.target?.progressTitle ?? "Viewpoint saved"
        heading.text = update.state == .capturing || (update.state == .saving && recorder.currentStationID != nil)
            ? "Stay here · \(savedTargets) of \(update.totalTargets) photos saved\n\(phase)"
            : (recorder.manifest?.stations.isEmpty == false ? "Viewpoint \(stationNumber) · \(savedTargets)/\(update.totalTargets) saved" : "Start with one viewpoint")
        progress.progress = Float(savedTargets) / Float(max(1, update.totalTargets))
        target.isHidden = update.state != .capturing || update.guidanceMode == .waiting
        reticle.layer.borderColor = (update.guidanceMode == .steady ? UIColor.systemGreen : UIColor.white).cgColor
        if update.state == .ready {
            direction.text = (recorder.manifest?.frameCount ?? 0) > 0
                ? "Preview this viewpoint first. Add another only for an area hidden from this spot."
                : "Stay here for one full room view. Turn toward the yellow camera target; do not walk to it."
        } else if update.state == .saving {
            direction.text = "Saving automatically. Stay in this spot."
        }
        refreshButtons()
    }

    private func refreshButtons() {
        presentedSurveyPlan = surveyPlan
        let busyPreview = previewCancellation != nil
        let trackingReady: Bool
        if let frame = cameraView.session.currentFrame, case .normal = frame.camera.trackingState { trackingReady = true }
        else { trackingReady = false }
        let ready = recorder.state == .ready && !closing && !busyPreview
        let active = (recorder.state == .capturing || recorder.state == .saving) && recorder.currentStationID != nil && !closing
        let full = (recorder.manifest?.stations.count ?? 0) >= StationCaptureLimits.maximumStations
        let upright = cameraView.session.currentFrame.map { StationCapturePolicy.canBeginFacingStraightAhead(forwardY: Double(-$0.camera.transform.columns.2.y)) } ?? false
        let title: String
        if active { title = "Capturing automatically…" }
        else if full { title = "Viewpoint limit reached" }
        else if !choosingViewpoint { title = "Add another viewpoint (optional)" }
        else if !upright { title = "Point straight ahead to start" }
        else { title = "This spot is clear — start here" }
        // Suggestions help choose a place, but exact arrival never blocks a
        // person's own clear spot. Camera tracking and a level start still do.
        setButton(scan, title: title, enabled: ready && sessionRunning && trackingReady && !full && (!choosingViewpoint || upright), primary: true)
        scan.isHidden = active
        chooseSpot.isHidden = !ready || !choosingViewpoint || (surveyPlan?.positions.count ?? 0) < 2
        useCurrentSpot.isHidden = !ready || !choosingViewpoint || surveyPlan == nil || manualSpotChosen
        setButton(chooseSpot, title: "Choose a suggested spot", enabled: ready && trackingReady)
        setButton(useCurrentSpot, title: "Use my current clear spot instead", enabled: ready && trackingReady && !full)
        setButton(preview, title: busyPreview ? "Cancel preview" : "Preview this position",
                  enabled: !closing && (busyPreview || (ready && recorder.manifest?.stations.last?.frames.isEmpty == false)))
        preview.isHidden = active || (recorder.manifest?.stations.last?.frames.isEmpty != false && !busyPreview)
        let stalled = recoverySince.flatMap { since in cameraView.session.currentFrame.map { $0.timestamp - since >= 3 } } ?? false
        recoverSpot.isHidden = !active || !stalled
        setButton(recoverSpot, title: full ? "Viewpoint limit reached — save this tour" : "Help me start this view again", enabled: active && !full && !confirmingEarlyFinish)
        setButton(finish, title: closing ? "Saving your tour…" : active ? "Finish early…" : "Done — save room tour", enabled: !closing)
    }

    @objc private func scanTapped() {
        guard recorder.state == .ready else { return }
        guard let frame = cameraView.session.currentFrame, previewCancellation == nil else { return }
        // A floor observation may invalidate the old suggestion between a
        // display refresh and a tap. Require the displayed plan to stay current.
        guard presentedSurveyPlan == surveyPlan else {
            updateSurveyPresentation(frame: frame); refreshButtons(); return
        }
        if !choosingViewpoint {
            choosingViewpoint = true; manualSpotChosen = false
            let previous = recorder.manifest?.stations.map(\.origin) ?? []
            selectedSuggestedNumber = surveyPlan?.positions.first { point in previous.allSatisfy { RoomScanPlanner.distance($0, point.position) > 0.75 } }?.number
            updateSurveyPresentation(frame: frame); refreshButtons(); return
        }
        beginFromCurrentSpot(frame)
    }

    private func beginFromCurrentSpot(_ frame: ARFrame) {
        guard !closing, recorder.state == .ready, previewCancellation == nil,
              case .normal = frame.camera.trackingState else { return }
        do {
            try recorder.beginStation(frame: frame)
            recoverySince = nil
            photoFeedback.prepare()
            surveyFrozen = true; choosingViewpoint = false
            hideFloorMarkers()
            refreshButtons()
        } catch { instruction.text = error.localizedDescription }
    }

    @objc private func useCurrentSpotTapped() {
        guard choosingViewpoint, let frame = cameraView.session.currentFrame else { return }
        selectedSuggestedNumber = nil; manualSpotChosen = true
        if StationCapturePolicy.canBeginFacingStraightAhead(forwardY: Double(-frame.camera.transform.columns.2.y)) { beginFromCurrentSpot(frame) }
        else { updateSurveyPresentation(frame: frame); refreshButtons() }
    }

    @objc private func recoverSpotTapped() {
        guard !closing, !confirmingEarlyFinish, recorder.state == .capturing,
              recorder.currentStationID != nil,
              (recorder.manifest?.stations.count ?? 0) < StationCaptureLimits.maximumStations else { return }
        confirmingEarlyFinish = true
        let alert = UIAlertController(title: "Start this view again?",
            message: "Your saved photos will stay as an incomplete view. For the next try, keep your feet in place, tuck your elbows in and turn the phone toward each yellow camera target. For the ceiling, tilt the phone up and keep your back upright.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep this view going", style: .cancel) { [weak self] _ in self?.confirmingEarlyFinish = false })
        alert.addAction(UIAlertAction(title: "Save partial view and choose a spot", style: .default) { [weak self] _ in
            guard let self, !self.closing else { return }
            self.confirmingEarlyFinish = false
            self.choosingViewpoint = true; self.manualSpotChosen = true; self.selectedSuggestedNumber = nil
            self.recoverySince = nil
            self.recorder.finishStation()
        })
        present(alert, animated: true)
    }

    @objc private func chooseSpotTapped() {
        guard recorder.state == .ready, choosingViewpoint, let plan = surveyPlan,
              let frame = cameraView.session.currentFrame else { return }
        let alert = UIAlertController(title: "Suggested standing spots", message: "Choose a spot only if the floor and your way there are clear. These are suggestions from visible floor, not a checked walking route.", preferredStyle: .actionSheet)
        for point in plan.positions {
            let distance = RoomScanPlanner.distance(point.position, cameraPosition(frame))
            alert.addAction(UIAlertAction(title: "Spot \(point.number) · about \(String(format: "%.1f", distance)) m away", style: .default) { [weak self] _ in
                guard let self, !self.closing, self.recorder.state == .ready, self.surveyPlan == plan else { return }
                self.manualSpotChosen = false
                self.selectedSuggestedNumber = point.number
                self.updateSurveyPresentation(frame: self.cameraView.session.currentFrame); self.refreshButtons()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = chooseSpot
        alert.popoverPresentationController?.sourceRect = chooseSpot.bounds
        present(alert, animated: true)
    }

    @objc private func floorMarkerTapped(_ marker: UIButton) {
        guard recorder.state == .ready, choosingViewpoint, surveyPlan?.positions.contains(where: { $0.number == marker.tag }) == true else { return }
        manualSpotChosen = false
        selectedSuggestedNumber = marker.tag
        updateSurveyPresentation(frame: cameraView.session.currentFrame); refreshButtons()
    }

    private var selectedSuggestion: RoomScanSuggestedPosition? {
        surveyPlan?.positions.first { $0.number == selectedSuggestedNumber }
    }
    private func cameraPosition(_ frame: ARFrame) -> [Double] {
        let value = frame.camera.transform.columns.3
        return [Double(value.x), Double(value.y), Double(value.z)]
    }

    private func observeRoomSurvey(_ frame: ARFrame) {
        guard !surveyFrozen else { return }
        guard case .normal = frame.camera.trackingState else {
            survey.reset(); surveyPlan = nil; selectedSuggestedNumber = nil; lastSurveyPlaneID = nil
            hideFloorMarkers(); return
        }
        guard frame.timestamp - lastSurveyTime >= 1, presentedViewController == nil else { return }
        lastSurveyTime = frame.timestamp
        let camera = cameraPosition(frame)
        // A horizontal table is not a floor. Unclassified/unsupported geometry
        // uses the explicit manual fallback instead of inventing a room plan.
        let floors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal && $0.classification == .floor }
            .sorted { $0.planeExtent.width * $0.planeExtent.height > $1.planeExtent.width * $1.planeExtent.height }
        var observation: (id: String, boundary: [[Double]])?
        for anchor in floors.prefix(8) {
            let vertices = anchor.geometry.boundaryVertices
            guard (3...64).contains(vertices.count) else { continue }
            let boundary = vertices.map { vertex -> [Double] in
                let world = anchor.transform * SIMD4<Float>(vertex, 1)
                return [Double(world.x), Double(world.y), Double(world.z)]
            }
            guard RoomScanPlanner.plan(boundary: boundary, cameraPosition: camera) != nil else { continue }
            observation = (anchor.identifier.uuidString, boundary); break
        }
        guard let observation else {
            survey.reset(); surveyPlan = nil; selectedSuggestedNumber = nil; lastSurveyPlaneID = nil
            hideFloorMarkers(); return
        }
        if lastSurveyPlaneID != observation.id {
            survey.reset(); surveyPlan = nil; selectedSuggestedNumber = nil
            lastSurveyPlaneID = observation.id
        }
        if let plan = survey.observe(planeID: observation.id, boundary: observation.boundary,
                                     cameraPosition: camera, timestamp: frame.timestamp) {
            surveyPlan = plan
            if !manualSpotChosen, !plan.positions.contains(where: { $0.number == selectedSuggestedNumber }) {
                selectedSuggestedNumber = plan.positions.first?.number
            }
        } else {
            // Same-anchor area/centre changes also restart stability. A prior
            // suggestion must not remain selectable during the next two seconds.
            surveyPlan = nil; selectedSuggestedNumber = nil; hideFloorMarkers()
        }
    }

    private func updateSurveyPresentation(frame: ARFrame?) {
        target.isHidden = true; reticle.isHidden = true; progress.isHidden = true
        if manualSpotChosen {
            heading.text = "Use your current clear spot"
            instruction.text = "Stand comfortably with a clear view of the room. Keep your feet here while taking the photos."
            direction.text = "Hold the phone at chest height, tuck your elbows in and point straight ahead. No exact floor-marker alignment is needed."
        } else if let plan = surveyPlan {
            heading.text = "Choose a clear spot · \(plan.positions.count) suggested"
            instruction.text = "Purple floor numbers suggest where to stand. Choose somewhere clear with a good view of the room. You can also start right where you are."
            if let selected = selectedSuggestion, let frame {
                let distance = RoomScanPlanner.distance(selected.position, cameraPosition(frame))
                direction.text = distance <= Self.suggestionArrivalMetres
                    ? "Near suggested spot \(selected.number). Exact positioning is not needed. Point straight ahead and start when comfortable."
                    : "Suggested spot \(selected.number) is ahead. Look toward the floor to find it, or start from your current clear spot."
            } else {
                direction.text = "Choose another suggested spot, or use your current clear spot."
            }
        } else {
            heading.text = surveyFrozen ? "Choose another clear spot" : "Find a clear place to stand"
            instruction.text = surveyFrozen
                ? "Move to a clear spot that shows an area hidden from your first viewpoint. Keep some of the same room in view."
                : "Start near the middle where you can see most of the room. Looking toward the floor can show optional standing suggestions."
            direction.text = "You do not need to wait for floor markers. Point straight ahead and start here when the spot is clear."
        }
        if let frame { updateFloorMarkers(frame) }
        else { hideFloorMarkers() }
    }

    private func hideFloorMarkers() { for marker in floorMarkers.values { marker.isHidden = true } }

    private func updateFloorMarkers(_ frame: ARFrame) {
        hideFloorMarkers()
        guard choosingViewpoint, !manualSpotChosen, recorder.state == .ready, case .normal = frame.camera.trackingState,
              let plan = surveyPlan else { return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let matrix = frame.camera.viewMatrix(for: orientation)
        for point in plan.positions {
            let marker: UIButton
            if let existing = floorMarkers[point.number] { marker = existing }
            else {
                marker = UIButton(type: .system); marker.tag = point.number
                marker.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
                marker.layer.cornerRadius = 24; marker.backgroundColor = UIColor(Theme.accent)
                marker.setTitleColor(.white, for: .normal)
                marker.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
                marker.setTitle(String(point.number), for: .normal)
                marker.accessibilityLabel = "Suggested standing spot \(point.number)"
                marker.accessibilityIdentifier = "panorama.suggestedSpot.\(point.number)"
                marker.addTarget(self, action: #selector(floorMarkerTapped(_:)), for: .touchUpInside)
                view.insertSubview(marker, belowSubview: controlScroll)
                floorMarkers[point.number] = marker
            }
            marker.layer.borderWidth = point.number == selectedSuggestedNumber ? 3 : 0
            marker.layer.borderColor = UIColor.white.cgColor
            let world = SIMD3<Float>(Float(point.position[0]), Float(point.position[1] + 0.03), Float(point.position[2]))
            let local = matrix * SIMD4<Float>(world, 1)
            let pixel = frame.camera.projectPoint(world, orientation: orientation, viewportSize: cameraView.bounds.size)
            guard local.z < -0.05, cameraView.bounds.insetBy(dx: 26, dy: 26).contains(pixel) else {
                if point.number == selectedSuggestedNumber,
                   RoomScanPlanner.distance(point.position, cameraPosition(frame)) > Self.suggestionArrivalMetres {
                    let cue = StationCapturePolicy.aimDirection(viewVector: [Double(local.x), Double(local.y), Double(local.z)], angularErrorDegrees: nil)?.instruction ?? "Point toward the floor"
                    direction.text = cue + " to see spot \(point.number). Check the floor before moving."
                }
                continue
            }
            marker.center = cameraView.convert(pixel, to: view); marker.isHidden = false
        }
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

    @objc private func finishTapped() {
        guard !closing, !confirmingEarlyFinish else { return }
        guard recorder.currentStationID != nil else { end(reason: nil); return }
        confirmingEarlyFinish = true
        let saved = update?.savedTargets ?? 0
        let alert = UIAlertController(title: "Save an incomplete viewpoint?",
            message: "Only \(saved) of 38 photos are saved from this spot. Missing directions will remain blank. Keep scanning to finish the room view.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep scanning", style: .cancel) { [weak self] _ in self?.confirmingEarlyFinish = false })
        alert.addAction(UIAlertAction(title: "Save with missing coverage", style: .default) { [weak self] _ in
            self?.confirmingEarlyFinish = false; self?.end(reason: nil)
        })
        present(alert, animated: true)
    }
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
        guard !confirmingEarlyFinish else { return }
        observeRoomSurvey(frame)
        recorder.process(frame: frame)
        guard frame.timestamp - lastGuidanceTime >= 0.1 else { return }
        lastGuidanceTime = frame.timestamp
        refreshButtons()
        if recorder.state == .ready, choosingViewpoint {
            updateSurveyPresentation(frame: frame)
            return
        }
        guard recorder.state == .capturing, let vector = update?.targetDirection, vector.count == 3,
              recorder.currentStationID != nil else { target.isHidden = true; return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix = frame.camera.viewMatrix(for: orientation)
        let origin = frame.camera.transform.columns.3
        let returning = update?.guidanceMode == .returnToPivot
        if returning { if recoverySince == nil { recoverySince = frame.timestamp } }
        else { recoverySince = nil }
        refreshButtons()
        guard update?.guidanceMode == .aim || update?.guidanceMode == .steady || returning else { target.isHidden = true; direction.text = "Hold the phone comfortably and let it settle"; return }
        // Admission tests the orientation-only ray. Project that same ray from
        // the current camera, so the yellow target and acceptance cannot disagree
        // because of camera translation. Pivot correction is a separate cue above.
        let world = SIMD3<Float>(origin.x + Float(vector[0] * 2), origin.y + Float(vector[1] * 2), origin.z + Float(vector[2] * 2))
        let local = viewMatrix * SIMD4<Float>(Float(vector[0]), Float(vector[1]), Float(vector[2]), 0)
        let projected = frame.camera.projectPoint(world, orientation: orientation, viewportSize: cameraView.bounds.size)
        let visible = local.z < 0 && cameraView.bounds.insetBy(dx: 28, dy: 28).contains(projected)
        target.isHidden = !visible
        if visible {
            target.center = cameraView.convert(projected, to: view)
        }
        if returning {
            // A camera-relative XYZ correction flips as someone turns or tilts.
            // Keep one coarse instruction and leave the next photo visible.
            direction.text = "Pause and tuck your elbows in. Hold the phone near where you began; keep your feet in place."
        } else if update?.guidanceMode == .steady {
            direction.text = "On target — hold still · \(Int((update?.steadyProgress ?? 0) * 100))%"
        } else {
            let cue = StationCapturePolicy.captureAimDirection(cameraToWorld: CaptureGeometry.rows(frame.camera.transform), targetDirection: vector,
                                                               angularErrorDegrees: update?.angularErrorDegrees)?.instruction ?? "Turn toward the yellow camera target"
            if update?.target?.id == "ceiling" || update?.target?.id.hasPrefix("upper-") == true {
                direction.text = cue + ". Tilt the phone, not your back. A short tap means the photo saved."
            } else if update?.target?.id == "floor" || update?.target?.id.hasPrefix("lower-") == true {
                direction.text = cue + ". Keep your back upright and tilt the phone down. A short tap means the photo saved."
            } else {
                direction.text = cue + ". Stay where you are; do not walk to the target."
            }
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
