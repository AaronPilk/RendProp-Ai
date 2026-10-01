import UIKit
import SceneKit
import ImageIO

struct PanoramaPreviewStation {
    let id: String
    let label: String
    let panoramaURL: URL
    let position: [Double]
    let coverage: Double
}

/// A local photographic look-around viewer. Numbered positions are explicit
/// choices, not an assertion of unobstructed navigation or validated geometry.
final class PanoramaPreviewViewController: UIViewController {
    var onClose: (() -> Void)?
    private let stations: [PanoramaPreviewStation]
    private var selectedIndex: Int
    private let sceneView = SCNView()
    private let cameraNode = SCNNode()
    private let sphereNode = SCNNode()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let stationStrip = UIStackView()
    private var stationButtons: [UIButton] = []
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var panStart = SIMD2<Float>(repeating: 0)
    private let previewTint: UIColor

    init(stations: [PanoramaPreviewStation], initialStationID: String? = nil, tintColor: UIColor = .systemPurple) {
        self.stations = stations
        self.selectedIndex = stations.firstIndex(where: { $0.id == initialStationID }) ?? 0
        self.previewTint = tintColor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(stations:initialStationID:tintColor:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.tintColor = previewTint
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityIdentifier = "panorama.preview.title"
        let close = UIButton(type: .system)
        close.setTitle("Done", for: .normal)
        close.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.accessibilityIdentifier = "panorama.preview.close"
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [titleLabel, close])
        heading.spacing = 12
        heading.alignment = .center
        heading.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.text = "Drag to look around. Gray areas were not captured. This is a photo preview; edges may not line up yet."
        detailLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.accessibilityIdentifier = "panorama.preview.detail"
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.backgroundColor = .gray
        sceneView.antialiasingMode = .multisampling2X
        sceneView.preferredFramesPerSecond = 30
        sceneView.isPlaying = false
        sceneView.rendersContinuously = false
        sceneView.allowsCameraControl = false
        sceneView.accessibilityLabel = "Photographic room panorama"
        sceneView.accessibilityHint = "Drag with one finger to look around, or use the look direction controls."
        sceneView.accessibilityIdentifier = "panorama.preview.scene"
        let scene = SCNScene()
        scene.background.contents = UIColor.gray
        let camera = SCNCamera()
        camera.fieldOfView = 70
        camera.zNear = 0.01
        camera.zFar = 20
        camera.wantsHDR = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        sphereNode.geometry = Self.sphereGeometry()
        scene.rootNode.addChildNode(sphereNode)
        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
        sceneView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))

        let lookControls = UIStackView()
        lookControls.distribution = .fillEqually
        lookControls.spacing = 8
        lookControls.translatesAutoresizingMaskIntoConstraints = false
        for (name, symbol, tag) in [("Look left", "arrow.left", 0), ("Look up", "arrow.up", 1),
                                    ("Reset view", "arrow.counterclockwise", 2), ("Look down", "arrow.down", 3),
                                    ("Look right", "arrow.right", 4)] {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.tinted()
            config.image = UIImage(systemName: symbol)
            button.configuration = config
            button.accessibilityLabel = name
            button.tag = tag
            button.addTarget(self, action: #selector(lookTapped(_:)), for: .touchUpInside)
            lookControls.addArrangedSubview(button)
        }
        let positionLabel = UILabel()
        positionLabel.text = "Scan positions · choose a saved view"
        positionLabel.font = .preferredFont(forTextStyle: .caption1)
        positionLabel.adjustsFontForContentSizeCategory = true
        positionLabel.numberOfLines = 0
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = true
        stationStrip.axis = .horizontal
        stationStrip.spacing = 10
        stationStrip.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stationStrip)
        for (index, station) in stations.enumerated() {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.tinted()
            configuration.title = station.label
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.image = Self.thumbnail(at: station.panoramaURL)
            configuration.cornerStyle = .medium
            button.configuration = configuration
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.tag = index
            button.accessibilityLabel = "\(station.label), \(Self.percentage(station.coverage)) percent photographed"
            button.accessibilityIdentifier = "panorama.preview.station.\(index + 1)"
            button.addTarget(self, action: #selector(stationTapped(_:)), for: .touchUpInside)
            stationStrip.addArrangedSubview(button)
            stationButtons.append(button)
        }
        for child in [heading, sceneView, detailLabel, lookControls, positionLabel, scroll] { view.addSubview(child) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            sceneView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: sceneView.bottomAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            lookControls.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),
            lookControls.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            lookControls.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            lookControls.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            positionLabel.topAnchor.constraint(equalTo: lookControls.bottomAnchor, constant: 8),
            positionLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            positionLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: positionLabel.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: 104),
            stationStrip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stationStrip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stationStrip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stationStrip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stationStrip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        showSelectedStation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sceneView.isPlaying = false
    }

    private func showSelectedStation() {
        guard stations.indices.contains(selectedIndex) else {
            titleLabel.text = "No saved panorama"
            return
        }
        let station = stations[selectedIndex]
        do {
            let image = try Self.loadPanorama(at: station.panoramaURL)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .clamp
            material.diffuse.minificationFilter = .linear
            material.diffuse.magnificationFilter = .linear
            material.isDoubleSided = true
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            sphereNode.geometry?.materials = [material]
            titleLabel.text = "\(station.label) · \(Self.percentage(station.coverage))% photographed"
            detailLabel.text = "Drag to look around. Gray areas were not captured. This is a photo preview; edges may not line up yet."
            for (index, button) in stationButtons.enumerated() {
                button.isSelected = index == selectedIndex
                button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : [.button]
                button.layer.borderWidth = index == selectedIndex ? 2 : 0
                button.layer.borderColor = previewTint.cgColor
                button.layer.cornerRadius = 12
            }
        } catch {
            // Do not leave another station's photograph displayed under the
            // newly selected station label after an unavailable/corrupt asset.
            sphereNode.geometry?.materials = []
            titleLabel.text = station.label
            detailLabel.text = error.localizedDescription
        }
        updateCamera()
    }

    @objc private func stationTapped(_ sender: UIButton) {
        guard stations.indices.contains(sender.tag) else { return }
        selectedIndex = sender.tag
        showSelectedStation() // Yaw/pitch deliberately stay in the common world frame.
    }
    @objc private func closeTapped() {
        if let onClose { onClose() } else { dismiss(animated: true) }
    }
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { panStart = SIMD2(yaw, pitch) }
        let translation = recognizer.translation(in: sceneView)
        let scale = Float(.pi / 180 * 70 / max(1, sceneView.bounds.height))
        yaw = panStart.x - Float(translation.x) * scale
        pitch = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, panStart.y + Float(translation.y) * scale))
        updateCamera()
    }
    @objc private func lookTapped(_ sender: UIButton) {
        let step = Float.pi / 8
        switch sender.tag {
        case 0: yaw -= step
        case 1: pitch += step
        case 2: yaw = 0; pitch = 0
        case 3: pitch -= step
        default: yaw += step
        }
        pitch = max(-Float.pi / 2 + 0.01, min(Float.pi / 2 - 0.01, pitch))
        updateCamera()
    }
    private func updateCamera() {
        // Default SceneKit camera looks down -Z. Positive pitch looks up;
        // negative Y Euler rotation looks toward positive world longitude.
        cameraNode.eulerAngles = SCNVector3(pitch, -yaw, 0)
        sceneView.setNeedsDisplay()
    }

    /// Explicit mapping avoids relying on an undocumented primitive sphere's
    /// seam/orientation: u=0.5 is -Z, u increases toward +X, v=0 is +Y.
    static func sphereGeometry() -> SCNGeometry {
        let columns = 96, rows = 48
        var vertices: [SCNVector3] = [], coordinates: [CGPoint] = [], indices: [UInt32] = []
        for y in 0...rows {
            for x in 0...columns {
                let u = Double(x) / Double(columns), v = Double(y) / Double(rows)
                let direction = PanoramaProjection.direction(longitude: (u * 2 - 1) * .pi, latitude: .pi / 2 - v * .pi)
                vertices.append(SCNVector3(Float(direction.x * 10), Float(direction.y * 10), Float(direction.z * 10)))
                coordinates.append(CGPoint(x: u, y: v))
                if x < columns && y < rows {
                    let a = UInt32(y * (columns + 1) + x), b = a + 1
                    let c = a + UInt32(columns + 1), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
        }
        let source = SCNGeometrySource(vertices: vertices)
        let texture = SCNGeometrySource(textureCoordinates: coordinates)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [source, texture], elements: [element])
    }

    private static func validatedSource(at url: URL) throws -> CGImageSource {
        let bytes = try NativeRasterWriter.boundedJSONData(at: url, maximumBytes: 40 * 1024 * 1024)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int,
              width >= 64, width <= PanoramaRenderer.maximumWidth, height == width / 2,
              metadata[kCGImagePropertyDepth] as? Int == 8,
              (metadata[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else {
            throw CaptureError.invalid("This panorama preview is unavailable. Your original scan is still saved.")
        }
        return source
    }

    private static func loadPanorama(at url: URL) throws -> UIImage {
        let source = try validatedSource(at: url)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.invalid("This panorama preview could not be decoded. Your original scan is still saved.")
        }
        return UIImage(cgImage: image)
    }

    private static func thumbnail(at url: URL) -> UIImage? {
        // Metadata is bounded before thumbnail decode. Never decode every full
        // panorama simply to populate the station strip.
        guard let source = try? validatedSource(at: url),
              let original = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceThumbnailMaxPixelSize: 224,
                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 56))
        return renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 112, height: 56))
            UIImage(cgImage: original).draw(in: CGRect(x: 0, y: 0, width: 112, height: 56))
        }
    }

    private static func percentage(_ coverage: Double) -> Int {
        coverage.isFinite ? Int(max(0, min(1, coverage)) * 100) : 0
    }
}
