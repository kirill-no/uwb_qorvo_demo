import UIKit
import ARKit
import simd

// Protocol to delegate UWB data
protocol UWBDataDelegate: AnyObject {
    func getCurrentUWBPosition() -> simd_float2?
}

class ARViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate, UIGestureRecognizerDelegate {

    // MARK: - Properties
    
    private let sceneView = ARSCNView()
    
    // Object Management
    private var placedObjectNodes: [SCNNode] = []
    private var manipulatedNode: SCNNode?
    private var initialScale: SCNVector3?
    private var heidentorNode: SCNNode?
    
    // UWB & Calibration
    private var uwbPositionNode: SCNNode?
    private struct CalibrationDebugSample {
        let arXZ: simd_float2
        let uwbXY: simd_float2
    }

    private struct UWBToARTransform {
        let rotationAngle: Float
        let translationXZ: simd_float2
        let mirrorsXAxis: Bool

        func map(_ uwbPoint: simd_float2) -> simd_float2 {
            let localPoint = simd_float2(
                mirrorsXAxis ? -uwbPoint.x : uwbPoint.x,
                uwbPoint.y
            )
            let cosAngle = cos(rotationAngle)
            let sinAngle = sin(rotationAngle)
            let rotatedX = localPoint.x * cosAngle - localPoint.y * sinAngle
            let rotatedY = localPoint.x * sinAngle + localPoint.y * cosAngle
            return translationXZ + simd_float2(rotatedX, rotatedY)
        }

        func inverseMap(_ arPoint: simd_float2) -> simd_float2 {
            let translated = arPoint - translationXZ
            let cosAngle = cos(rotationAngle)
            let sinAngle = sin(rotationAngle)
            let unrotatedX = translated.x * cosAngle + translated.y * sinAngle
            let unrotatedY = -translated.x * sinAngle + translated.y * cosAngle
            return simd_float2(
                mirrorsXAxis ? -unrotatedX : unrotatedX,
                unrotatedY
            )
        }

        func rotateIntoAR(_ vector: simd_float2) -> simd_float2 {
            let localVector = simd_float2(
                mirrorsXAxis ? -vector.x : vector.x,
                vector.y
            )
            let cosAngle = cos(rotationAngle)
            let sinAngle = sin(rotationAngle)
            let rotatedX = localVector.x * cosAngle - localVector.y * sinAngle
            let rotatedY = localVector.x * sinAngle + localVector.y * cosAngle
            return simd_float2(rotatedX, rotatedY)
        }
    }

    private enum DriftMode: Int {
        case arOnly
        case monitorOnly
        case uwbCorrection

        var title: String {
            switch self {
            case .arOnly:
                return "AR Only"
            case .monitorOnly:
                return "Monitor"
            case .uwbCorrection:
                return "Correct"
            }
        }
    }

    private enum RelocalizationState: String {
        case idle = "idle"
        case armed = "armed"
        case correcting = "correcting"
    }

    private struct DriftStats {
        var filteredDriftUWB = simd_float2.zero
        var peakDriftMeters: Float = 0
        var peakCorrectionMeters: Float = 0
        var timeAboveThreshold: TimeInterval = 0
        var correctionCount: Int = 0
        var totalCorrectionMeters: Float = 0
        var consecutiveAboveThresholdCount: Int = 0
        var armedStartedAt: TimeInterval?
        var lastFrameTimestamp: TimeInterval?
    }

    private enum CalibrationStep {
        case origin
        case topLeft
        case topRight
        case complete

        var titleIndex: Int {
            switch self {
            case .origin:
                return 1
            case .topLeft:
                return 2
            case .topRight:
                return 3
            case .complete:
                return 3
            }
        }
    }

    private var calibrationTransform: UWBToARTransform?
    private var capturedOriginSample: CalibrationDebugSample?
    private var capturedTopLeftSample: CalibrationDebugSample?
    private var capturedTopRightSample: CalibrationDebugSample?
    private var calibrationStep: CalibrationStep = .origin
    private let debugMarkersRootNode = SCNNode()
    private let contentRootNode = SCNNode()
    weak var uwbDataDelegate: UWBDataDelegate?
    
    // Configuration passed from parent VC
    var environmentMode: EnvironmentMode = .indoor
    var uwbAreaWidth: Float = 2.5
    var uwbAreaHeight: Float = 2.5
    var originBeaconName: String = "Origin"
    var topLeftBeaconName: String = "Top Left"
    var topRightBeaconName: String = "Top Right"

    // UI & State
    private enum PlacementMode: Int {
        case arkit, uwb
    }
    private var currentMode: PlacementMode = .arkit
    private let modeControl = UISegmentedControl(items: ["ARKit Mode", "UWB Mode"])
    private let driftModeControl = UISegmentedControl(items: ["AR Only", "Monitor", "Correct"])
    private let calibrateButton = UIButton(type: .system)
    private let placeUWBTreeButton = UIButton(type: .system)
    private let resetSceneButton = UIButton(type: .system)
    private let centerCrosshairView = UIView()
    private let floorLockLabel = UILabel()
    private let calibrationDebugLabel = UILabel()
    private var driftMode: DriftMode = .monitorOnly
    private var relocalizationState: RelocalizationState = .idle
    private var driftStats = DriftStats()
    private let driftEnterThresholdMeters: Float = 0.40
    private let driftExitThresholdMeters: Float = 0.22
    private let driftArmDuration: TimeInterval = 1.0
    private let driftArmConsecutiveSamples = 12
    private let driftFilterAlpha: Float = 0.12
    private let correctionAlpha: Float = 0.18
    private let maxCorrectionRateMetersPerSecond: Float = 0.10
    private let maxCorrectionDistancePerStep: Float = 0.03
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupSceneView()
        setupUI()
        setupGestures()
        createUWBPositionNode()
        createDebugMarkersRootNode()
        createContentRootNode()
        setupDebugOverlay()
        updateCalibrationDebugOverlay()
        updateUIState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sceneView.session.run(makeARConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }
    
    // MARK: - Setup
    
    private func setupSceneView() {
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.autoenablesDefaultLighting = true
        sceneView.automaticallyUpdatesLighting = true
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.topAnchor.constraint(equalTo: view.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func setupUI() {
        // Mode Control
        modeControl.selectedSegmentIndex = 1 // Default to UWB Mode so placement button is visible
        currentMode = .uwb
        modeControl.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        driftModeControl.selectedSegmentIndex = DriftMode.monitorOnly.rawValue
        driftModeControl.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        driftModeControl.addTarget(self, action: #selector(driftModeChanged), for: .valueChanged)
        
        // Buttons
        calibrateButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        calibrateButton.setTitleColor(.white, for: .normal)
        calibrateButton.layer.cornerRadius = 8
        calibrateButton.addTarget(self, action: #selector(handleCalibrationStep), for: .touchUpInside)
        
        placeUWBTreeButton.setTitle("Place Heidentor at UWB Center", for: .normal)
        placeUWBTreeButton.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        placeUWBTreeButton.setTitleColor(.white, for: .normal)
        placeUWBTreeButton.layer.cornerRadius = 8
        placeUWBTreeButton.addTarget(self, action: #selector(placeObjectAtUWBCenter), for: .touchUpInside)

        resetSceneButton.setTitle("Reset Scene", for: .normal)
        resetSceneButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.8)
        resetSceneButton.setTitleColor(.white, for: .normal)
        resetSceneButton.layer.cornerRadius = 8
        resetSceneButton.addTarget(self, action: #selector(resetScene), for: .touchUpInside)

        // Stacks
        let controlsStack = UIStackView(arrangedSubviews: [calibrateButton, placeUWBTreeButton, resetSceneButton])
        controlsStack.axis = .vertical
        controlsStack.spacing = 10
        
        let mainStack = UIStackView(arrangedSubviews: [modeControl, driftModeControl, controlsStack])
        mainStack.axis = .vertical
        mainStack.spacing = 15
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)
        
        NSLayoutConstraint.activate([
            mainStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            mainStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: 280),
            calibrateButton.heightAnchor.constraint(equalToConstant: 44),
            placeUWBTreeButton.heightAnchor.constraint(equalToConstant: 44),
            resetSceneButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // Close Button
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Exit AR", for: .normal)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.layer.cornerRadius = 8
        closeButton.addTarget(self, action: #selector(closeARView), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 80),
            closeButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        setupCrosshair()
        
        view.bringSubviewToFront(mainStack)
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(centerCrosshairView)
        view.bringSubviewToFront(floorLockLabel)
        view.bringSubviewToFront(calibrationDebugLabel)
    }

    private func setupCrosshair() {
        centerCrosshairView.translatesAutoresizingMaskIntoConstraints = false
        centerCrosshairView.isUserInteractionEnabled = false
        view.addSubview(centerCrosshairView)

        let horizontal = UIView()
        horizontal.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.9)
        horizontal.layer.cornerRadius = 1
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        centerCrosshairView.addSubview(horizontal)

        let vertical = UIView()
        vertical.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.9)
        vertical.layer.cornerRadius = 1
        vertical.translatesAutoresizingMaskIntoConstraints = false
        centerCrosshairView.addSubview(vertical)

        NSLayoutConstraint.activate([
            centerCrosshairView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerCrosshairView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            centerCrosshairView.widthAnchor.constraint(equalToConstant: 28),
            centerCrosshairView.heightAnchor.constraint(equalToConstant: 28),

            horizontal.centerXAnchor.constraint(equalTo: centerCrosshairView.centerXAnchor),
            horizontal.centerYAnchor.constraint(equalTo: centerCrosshairView.centerYAnchor),
            horizontal.widthAnchor.constraint(equalToConstant: 28),
            horizontal.heightAnchor.constraint(equalToConstant: 2),

            vertical.centerXAnchor.constraint(equalTo: centerCrosshairView.centerXAnchor),
            vertical.centerYAnchor.constraint(equalTo: centerCrosshairView.centerYAnchor),
            vertical.widthAnchor.constraint(equalToConstant: 2),
            vertical.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupDebugOverlay() {
        floorLockLabel.translatesAutoresizingMaskIntoConstraints = false
        floorLockLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        floorLockLabel.textColor = .white
        floorLockLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        floorLockLabel.layer.cornerRadius = 8
        floorLockLabel.clipsToBounds = true
        floorLockLabel.textAlignment = .center
        floorLockLabel.text = "Floor lock: --"
        floorLockLabel.numberOfLines = 1
        view.addSubview(floorLockLabel)

        NSLayoutConstraint.activate([
            floorLockLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            floorLockLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            floorLockLabel.heightAnchor.constraint(equalToConstant: 28),
            floorLockLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        calibrationDebugLabel.translatesAutoresizingMaskIntoConstraints = false
        calibrationDebugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        calibrationDebugLabel.textColor = .white
        calibrationDebugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        calibrationDebugLabel.layer.cornerRadius = 10
        calibrationDebugLabel.clipsToBounds = true
        calibrationDebugLabel.textAlignment = .left
        calibrationDebugLabel.numberOfLines = 0
        view.addSubview(calibrationDebugLabel)

        NSLayoutConstraint.activate([
            calibrationDebugLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            calibrationDebugLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -100),
            calibrationDebugLabel.topAnchor.constraint(equalTo: floorLockLabel.bottomAnchor, constant: 12)
        ])
    }

    private func createUWBPositionNode() {
        let sphere = SCNSphere(radius: 0.05)
        sphere.firstMaterial?.diffuse.contents = UIColor.cyan
        uwbPositionNode = SCNNode(geometry: sphere)
        uwbPositionNode?.isHidden = true
        sceneView.scene.rootNode.addChildNode(uwbPositionNode!)
    }

    private func createDebugMarkersRootNode() {
        sceneView.scene.rootNode.addChildNode(debugMarkersRootNode)
    }

    private func createContentRootNode() {
        sceneView.scene.rootNode.addChildNode(contentRootNode)
    }
    
    private func setupGestures() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        sceneView.addGestureRecognizer(tapGesture)
        
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        sceneView.addGestureRecognizer(pinchGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        panGesture.delegate = self
        sceneView.addGestureRecognizer(panGesture)
    }

    // MARK: - UI Logic & State Management
    
    @objc private func modeChanged(_ sender: UISegmentedControl) {
        currentMode = PlacementMode(rawValue: sender.selectedSegmentIndex) ?? .arkit
        updateUIState()
    }

    @objc private func driftModeChanged(_ sender: UISegmentedControl) {
        driftMode = DriftMode(rawValue: sender.selectedSegmentIndex) ?? .monitorOnly
        setRelocalizationState(.idle)
        if driftMode == .arOnly {
            driftStats.consecutiveAboveThresholdCount = 0
            driftStats.armedStartedAt = nil
        }
        customPrint("AR drift mode: \(driftMode.title)")
        updateCalibrationDebugOverlay()
    }
    
    private func updateUIState() {
        placeUWBTreeButton.isHidden = (currentMode != .uwb)
        updateCalibrationButtonState()
    }
    
    private func updateCalibrationButtonState() {
        switch calibrationStep {
        case .origin:
            calibrateButton.setTitle("1. Set Origin at \(originBeaconName)", for: .normal)
        case .topLeft:
            calibrateButton.setTitle("2. Set Top Left at \(topLeftBeaconName)", for: .normal)
        case .topRight:
            calibrateButton.setTitle("3. Set Top Right at \(topRightBeaconName)", for: .normal)
        case .complete:
            calibrateButton.setTitle("Calibration Complete", for: .normal)
        }
        calibrateButton.isEnabled = calibrationStep != .complete
        calibrateButton.alpha = calibrationStep == .complete ? 0.7 : 1.0
    }
    
    @objc private func closeARView() {
        self.dismiss(animated: true)
    }
    
    // MARK: - Object Placement
    
    @objc private func handleTap(gesture: UITapGestureRecognizer) {
        guard currentMode == .arkit else { return }
        
        let touchLocation = gesture.location(in: sceneView)
        guard let query = sceneView.raycastQuery(from: touchLocation, allowing: .existingPlaneGeometry, alignment: .horizontal),
              let result = sceneView.session.raycast(query).first else { return }

        placeTree(at: result.worldTransform, isUWB: false)
    }

    @objc private func placeObjectAtUWBCenter() {
        loadHeidentorModelIfNeeded()
        guard calibrationTransform != nil else {
            customPrint("AR ERROR: Please calibrate first before placing a UWB object.")
            showUserMessage("Please complete the three calibration taps first.")
            return
        }
        guard let modelTemplate = heidentorNode else {
            showUserMessage("Heidentor model not found in app bundle. Make sure the .glb is included in target.")
            return
        }

        // UWB center of the rectangle (X,Z in meters)
        let uwbCenter = simd_float2(uwbAreaWidth / 2.0, uwbAreaHeight / 2.0)
        guard let xz = mapLayoutPointToARXZ(uwbCenter) else { return }

        // Raycast down to find the floor at that XZ
        guard let cameraTransform = sceneView.session.currentFrame?.camera.transform else { return }
        let startY = cameraTransform.columns.3.y
        let origin = simd_float3(xz.x, startY, xz.y)
        let down = simd_float3(0, -1, 0)

        func raycastFirstHit(allowing: ARRaycastQuery.Target) -> ARRaycastResult? {
            let q = ARRaycastQuery(origin: origin, direction: down, allowing: allowing, alignment: .horizontal)
            return sceneView.session.raycast(q).first
        }

        var hit: ARRaycastResult? = nil
        hit = raycastFirstHit(allowing: .existingPlaneGeometry)
        if hit == nil { hit = raycastFirstHit(allowing: .existingPlaneInfinite) }
        if hit == nil { hit = raycastFirstHit(allowing: .estimatedPlane) }

        guard let floorHitResult = hit else {
            customPrint("AR ERROR: Could not find a floor plane at the UWB center location.")
            showUserMessage("Could not find a horizontal surface at the UWB center. Try moving the device to help AR detect the ground.")
            return
        }

        // Create a fresh instance of the model (clone), compute scale for mode
        let model = modelTemplate.clone()
        let (minB, maxB) = model.boundingBox
        let size = SCNVector3(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
        let currentFootprint = max(size.x, size.z)
        let dominantSpan = max(uwbAreaWidth, uwbAreaHeight)
        // Indoor: fit within ~2.5m, Outdoor: ~90% of the dominant span
        let targetFootprint: Float = (environmentMode == .indoor) ? min(dominantSpan * 0.9, 2.5) : dominantSpan * 0.9
        let scaleFactor = currentFootprint > 0 ? (targetFootprint / currentFootprint) : 1.0
        model.scale = SCNVector3(scaleFactor, scaleFactor, scaleFactor)

        // Optional base marker
        let baseNode = SCNNode(geometry: SCNCylinder(radius: 0.2, height: 0.02))
        baseNode.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
        baseNode.position = SCNVector3(0, minB.y * scaleFactor, 0)
        model.addChildNode(baseNode)

        // Place model at the floor hit transform
        var finalTransform = floorHitResult.worldTransform
        finalTransform.columns.3.y = floorHitResult.worldTransform.columns.3.y
        model.transform = SCNMatrix4(finalTransform)

        // Add to scene
        contentRootNode.addChildNode(model)
        placedObjectNodes.append(model)
        showUserMessage("Heidentor placed at UWB center.", title: "Placed")
    }
    
    private func mapLayoutPointToARXZ(_ uwbPoint: simd_float2) -> simd_float2? {
        calibrationTransform?.map(uwbPoint)
    }
    
    private func placeTree(at transform: simd_float4x4, isUWB: Bool) {
        guard let treeScene = SCNScene(named: "tree.usdz") else { return }
        let treeContainerNode = SCNNode()
        
        treeScene.rootNode.childNodes.forEach { treeContainerNode.addChildNode($0.clone()) }
        
        let (min, max) = treeContainerNode.boundingBox
        let height = max.y - min.y
        
        // FIX: Target height of 20cm (20% of previous size, which was 40cm, so now 8cm is wrong. 20cm is better)
        let targetHeight: Float = 0.2
        let scaleFactor = targetHeight / height
        treeContainerNode.scale = SCNVector3(scaleFactor, scaleFactor, scaleFactor)
        
        let baseColor = isUWB ? UIColor.systemGreen : UIColor.systemBlue
        let baseNode = SCNNode(geometry: SCNCylinder(radius: 0.1, height: 0.02))
        baseNode.geometry?.firstMaterial?.diffuse.contents = baseColor
        baseNode.position.y = (min.y * scaleFactor)
        treeContainerNode.addChildNode(baseNode)
        
        var finalTransform = transform
        // The Y position from the raycast is the floor level.
        finalTransform.columns.3.y = transform.columns.3.y
        treeContainerNode.transform = SCNMatrix4(finalTransform)
        
        contentRootNode.addChildNode(treeContainerNode)
        placedObjectNodes.append(treeContainerNode)
    }
    
    // MARK: - Gesture Handlers
    
    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let node = getObjectToManipulate(from: gesture) else { return }

        switch gesture.state {
        case .began:
            initialScale = node.scale
        case .changed:
            guard let initialScale = initialScale else { return }
            let scale = gesture.scale
            node.scale = SCNVector3(
                initialScale.x * Float(scale),
                initialScale.y * Float(scale),
                initialScale.z * Float(scale)
            )
        case .ended, .cancelled:
            initialScale = nil
        default:
            break
        }
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let node = getObjectToManipulate(from: gesture) else { return }

        let touchLocation = gesture.location(in: sceneView)
        guard let query = sceneView.raycastQuery(from: touchLocation, allowing: .existingPlaneGeometry, alignment: .horizontal),
              let result = sceneView.session.raycast(query).first else { return }
        
        let newPosition = result.worldTransform.columns.3
        node.position = SCNVector3(newPosition.x, node.position.y, newPosition.z)
    }

    private func getObjectToManipulate(from gesture: UIGestureRecognizer) -> SCNNode? {
        let touchLocation = gesture.location(in: sceneView)
        
        switch gesture.state {
        case .began:
            manipulatedNode = nil // Reset on new gesture
            if let hitResult = sceneView.hitTest(touchLocation, options: nil).first {
                var currentNode = hitResult.node
                while let parent = currentNode.parent {
                    if placedObjectNodes.contains(parent) {
                        manipulatedNode = parent
                        break
                    }
                    currentNode = parent
                }
            }
        case .ended, .cancelled:
            manipulatedNode = nil
        default:
            break
        }
        
        return manipulatedNode
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    // MARK: - Calibration Logic
    
    @objc private func handleCalibrationStep() {
        switch calibrationStep {
        case .origin:
            setOrigin()
        case .topLeft:
            setTopLeft()
        case .topRight:
            setTopRight()
        case .complete:
            break
        }
    }
    
    private func setOrigin() {
        guard
            let uwbPosition = uwbDataDelegate?.getCurrentUWBPosition(),
            let currentARPosition = currentCalibrationPointXZ()
        else {
            customPrint("AR ERROR: UWB position or floor point not available. Cannot set origin.")
            showUserMessage("Aim the crosshair at the floor point for the origin beacon, then try again.")
            return
        }
        uwbPositionNode?.isHidden = false
        capturedOriginSample = CalibrationDebugSample(arXZ: currentARPosition, uwbXY: uwbPosition)
        capturedTopLeftSample = nil
        capturedTopRightSample = nil
        calibrationTransform = nil
        calibrationStep = .topLeft
        updateUIState()
        updateDebugMarkers()
        updateCalibrationDebugOverlay()
        customPrint("✅ AR Origin Calibrated.")
    }
    
    private func setTopLeft() {
        guard
            let uwbPosition = uwbDataDelegate?.getCurrentUWBPosition(),
            let originSample = capturedOriginSample,
            let currentARPosition = currentCalibrationPointXZ()
        else {
            customPrint("AR ERROR: UWB position, floor point, or origin not available.")
            showUserMessage("Aim the crosshair at the floor point for the top-left beacon, then try again.")
            return
        }
        let arVector = currentARPosition - originSample.arXZ
        guard simd_length(arVector) > 0.05 else {
            customPrint("AR ERROR: Top-left calibration point is too close to origin.")
            showUserMessage("Move to the configured top-left beacon and capture again.")
            return
        }
        capturedTopLeftSample = CalibrationDebugSample(arXZ: currentARPosition, uwbXY: uwbPosition)
        capturedTopRightSample = nil
        calibrationTransform = nil
        calibrationStep = .topRight
        updateUIState()
        updateDebugMarkers()
        updateCalibrationDebugOverlay()
        customPrint("✅ AR Top Left Calibrated.")
    }

    private func setTopRight() {
        guard
            let uwbPosition = uwbDataDelegate?.getCurrentUWBPosition(),
            let originSample = capturedOriginSample,
            let topLeftSample = capturedTopLeftSample,
            let currentARPosition = currentCalibrationPointXZ()
        else {
            customPrint("AR ERROR: UWB position, floor point, or prior calibration points not available.")
            showUserMessage("Aim the crosshair at the floor point for the top-right beacon, then try again.")
            return
        }
        capturedTopRightSample = CalibrationDebugSample(arXZ: currentARPosition, uwbXY: uwbPosition)
        let arVector = topLeftSample.arXZ - originSample.arXZ
        let uwbVector = simd_float2(0, uwbAreaHeight)
        guard simd_length(arVector) > 0.05, simd_length(uwbVector) > 0.05 else {
            customPrint("AR ERROR: Calibration points are too close together to solve transform.")
            showUserMessage("Move to the configured top-left beacon and capture again.")
            return
        }
        guard let solvedTransform = makeCalibrationTransform(
            originAR: originSample.arXZ,
            topLeftAR: topLeftSample.arXZ,
            topRightAR: currentARPosition
        ) else {
            customPrint("AR ERROR: Could not solve a stable transform from the three calibration points.")
            showUserMessage("The three captured pillar points are inconsistent. Please recalibrate.")
            return
        }
        calibrationTransform = solvedTransform
        calibrationStep = .complete
        updateUIState()
        updateDebugMarkers()
        updateCalibrationDebugOverlay()
        customPrint("✅ AR Transform Calibrated from 3 pillars.")
    }
    
    @objc private func resetScene() {
        calibrationTransform = nil
        capturedOriginSample = nil
        capturedTopLeftSample = nil
        capturedTopRightSample = nil
        calibrationStep = .origin
        uwbPositionNode?.isHidden = true
        contentRootNode.simdPosition = .zero
        setRelocalizationState(.idle)
        driftStats = DriftStats()
        clearDebugMarkers()
        updateCalibrationDebugOverlay()
        
        updateUIState()
        
        sceneView.session.run(makeARConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        
        placedObjectNodes.forEach { $0.removeFromParentNode() }
        placedObjectNodes.removeAll()
        
        customPrint("🔄 Calibration and scene reset.")
    }
    
    // MARK: - ARSCNViewDelegate & Helpers
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        DispatchQueue.main.async { [weak self] in
            self?.updateFloorLockUI()
        }

        guard let uwbPosition = uwbDataDelegate?.getCurrentUWBPosition(), let node = uwbPositionNode else { return }

        if let mapped = mapCurrentUWBPositionToARXZ(uwbPosition) {
            node.position = SCNVector3(mapped.x, 0.01, mapped.y)
        }

        updateDriftDiagnosticsAndCorrection(frame: frame, uwbPosition: uwbPosition)
    }
    
    private func rotateVector(_ vector: simd_float2, angle: Float) -> simd_float2 {
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        let x = vector.x * cosAngle - vector.y * sinAngle
        let y = vector.x * sinAngle + vector.y * cosAngle
        return simd_float2(x, y)
    }

    private func mapCurrentUWBPositionToARXZ(_ uwbPosition: simd_float2) -> simd_float2? {
        calibrationTransform?.map(uwbPosition)
    }

    private func currentCameraUWBPosition() -> simd_float2? {
        guard
            let transform = calibrationTransform,
            let worldXZ = currentCameraWorldXZ()
        else { return nil }
        let contentOffset = simd_float2(contentRootNode.simdPosition.x, contentRootNode.simdPosition.z)
        return transform.inverseMap(worldXZ - contentOffset)
    }

    private func updateDriftDiagnosticsAndCorrection(frame: ARFrame, uwbPosition: simd_float2) {
        let timestamp = frame.timestamp
        let dt = max(1.0 / 120.0, timestamp - (driftStats.lastFrameTimestamp ?? timestamp))
        driftStats.lastFrameTimestamp = timestamp

        guard let arInUWB = currentCameraUWBPosition() else {
            DispatchQueue.main.async { [weak self] in
                self?.updateCalibrationDebugOverlay()
            }
            return
        }

        let rawDriftUWB = uwbPosition - arInUWB
        if driftStats.filteredDriftUWB == .zero {
            driftStats.filteredDriftUWB = rawDriftUWB
        } else {
            driftStats.filteredDriftUWB = driftStats.filteredDriftUWB + (rawDriftUWB - driftStats.filteredDriftUWB) * driftFilterAlpha
        }

        let driftMagnitude = simd_length(rawDriftUWB)
        let filteredDriftMagnitude = simd_length(driftStats.filteredDriftUWB)
        driftStats.peakDriftMeters = max(driftStats.peakDriftMeters, driftMagnitude)

        if driftMagnitude > driftEnterThresholdMeters {
            driftStats.timeAboveThreshold += dt
            driftStats.consecutiveAboveThresholdCount += 1
            if driftStats.armedStartedAt == nil {
                driftStats.armedStartedAt = timestamp
            }
        } else if driftMagnitude < driftExitThresholdMeters {
            driftStats.consecutiveAboveThresholdCount = 0
            driftStats.armedStartedAt = nil
            if relocalizationState != .correcting {
                setRelocalizationState(.idle)
            }
        }

        let armedByCount = driftStats.consecutiveAboveThresholdCount >= driftArmConsecutiveSamples
        let armedByTime = driftStats.armedStartedAt.map { timestamp - $0 >= driftArmDuration } ?? false

        switch driftMode {
        case .arOnly:
            setRelocalizationState(.idle)
        case .monitorOnly:
            setRelocalizationState((armedByCount || armedByTime) ? .armed : .idle)
        case .uwbCorrection:
            if relocalizationState != .correcting {
                setRelocalizationState((armedByCount || armedByTime) ? .armed : .idle)
            }
            applyContentCorrectionIfNeeded(
                filteredDriftUWB: driftStats.filteredDriftUWB,
                filteredDriftMagnitude: filteredDriftMagnitude,
                dt: Float(dt)
            )
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateCalibrationDebugOverlay()
        }
    }

    private func applyContentCorrectionIfNeeded(
        filteredDriftUWB: simd_float2,
        filteredDriftMagnitude: Float,
        dt: Float
    ) {
        guard driftMode == .uwbCorrection else { return }

        if filteredDriftMagnitude < driftExitThresholdMeters {
            setRelocalizationState(.idle)
            driftStats.consecutiveAboveThresholdCount = 0
            driftStats.armedStartedAt = nil
            return
        }

        guard relocalizationState == .armed || relocalizationState == .correcting else { return }
        setRelocalizationState(.correcting)

        guard let transform = calibrationTransform else { return }
        let desiredCorrectionAR = transform.rotateIntoAR(filteredDriftUWB)
        var correctionStepAR = desiredCorrectionAR * correctionAlpha
        let desiredStepMagnitude = simd_length(correctionStepAR)
        let maxStepMagnitude = min(maxCorrectionDistancePerStep, maxCorrectionRateMetersPerSecond * dt)
        if desiredStepMagnitude > maxStepMagnitude, desiredStepMagnitude > 0 {
            correctionStepAR *= maxStepMagnitude / desiredStepMagnitude
        }

        guard simd_length_squared(correctionStepAR) > 1e-8 else { return }

        contentRootNode.simdPosition += simd_float3(correctionStepAR.x, 0, correctionStepAR.y)
        let appliedMagnitude = simd_length(correctionStepAR)
        driftStats.correctionCount += 1
        driftStats.totalCorrectionMeters += appliedMagnitude
        driftStats.peakCorrectionMeters = max(driftStats.peakCorrectionMeters, appliedMagnitude)
    }

    private func setRelocalizationState(_ newState: RelocalizationState) {
        guard relocalizationState != newState else { return }
        relocalizationState = newState
        customPrint("AR relocalization state -> \(newState.rawValue)")
    }

    private func makeCalibrationTransform(
        originAR: simd_float2,
        topLeftAR: simd_float2,
        topRightAR: simd_float2
    ) -> UWBToARTransform? {
        let uwbOrientationVector = simd_float2(0, uwbAreaHeight)
        let arVector = topLeftAR - originAR
        guard simd_length(arVector) > 0.05, simd_length(uwbOrientationVector) > 0.05 else { return nil }

        let solvedAngle = atan2(arVector.y, arVector.x) - atan2(uwbOrientationVector.y, uwbOrientationVector.x)
        let direct = UWBToARTransform(rotationAngle: solvedAngle, translationXZ: originAR, mirrorsXAxis: false)
        let mirrored = UWBToARTransform(rotationAngle: solvedAngle, translationXZ: originAR, mirrorsXAxis: true)

        let topRightUWB = simd_float2(uwbAreaWidth, uwbAreaHeight)
        let directResidual = simd_length(direct.map(topRightUWB) - topRightAR)
        let mirroredResidual = simd_length(mirrored.map(topRightUWB) - topRightAR)
        return directResidual <= mirroredResidual ? direct : mirrored
    }

    private func currentCameraWorldXZ() -> simd_float2? {
        guard let cameraTransform = sceneView.session.currentFrame?.camera.transform else { return nil }
        return simd_float2(cameraTransform.columns.3.x, cameraTransform.columns.3.z)
    }

    private func currentCalibrationPointXZ() -> simd_float2? {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 20)
        if let query = sceneView.raycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal),
           let result = sceneView.session.raycast(query).first {
            return simd_float2(result.worldTransform.columns.3.x, result.worldTransform.columns.3.z)
        }
        if let query = sceneView.raycastQuery(from: center, allowing: .existingPlaneInfinite, alignment: .horizontal),
           let result = sceneView.session.raycast(query).first {
            return simd_float2(result.worldTransform.columns.3.x, result.worldTransform.columns.3.z)
        }
        if let query = sceneView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .horizontal),
           let result = sceneView.session.raycast(query).first {
            return simd_float2(result.worldTransform.columns.3.x, result.worldTransform.columns.3.z)
        }
        return nil
    }

    private func updateFloorLockUI() {
        let hasFloorLock = currentCalibrationPointXZ() != nil
        floorLockLabel.text = hasFloorLock ? "Floor lock: YES" : "Floor lock: NO"
        floorLockLabel.textColor = hasFloorLock ? .systemGreen : .systemRed
        centerCrosshairView.alpha = hasFloorLock ? 1.0 : 0.45
    }

    private func updateDebugMarkers() {
        clearDebugMarkers()

        guard let originSample = capturedOriginSample else { return }

        debugMarkersRootNode.addChildNode(
            makeMarkerNode(
                title: "Origin",
                subtitle: "(0.00, 0.00)",
                color: .systemRed,
                worldXZ: originSample.arXZ
            )
        )

        guard calibrationTransform != nil else { return }

        if let topLeftSample = capturedTopLeftSample {
            debugMarkersRootNode.addChildNode(
                makeMarkerNode(
                    title: "Captured Top Left",
                    subtitle: "AR tap point",
                    color: .systemPurple,
                    worldXZ: topLeftSample.arXZ
                )
            )
        }

        if let topRightSample = capturedTopRightSample {
            debugMarkersRootNode.addChildNode(
                makeMarkerNode(
                    title: "Captured Top Right",
                    subtitle: "AR tap point",
                    color: .systemTeal,
                    worldXZ: topRightSample.arXZ
                )
            )
        }

        let markerDefinitions: [(String, simd_float2, UIColor)] = [
            ("Top Left", simd_float2(0, uwbAreaHeight), .systemOrange),
            ("Top Right", simd_float2(uwbAreaWidth, uwbAreaHeight), .systemBlue),
            ("Center", simd_float2(uwbAreaWidth / 2.0, uwbAreaHeight / 2.0), .systemGreen)
        ]

        for (title, uwbPoint, color) in markerDefinitions {
            guard let worldXZ = mapLayoutPointToARXZ(uwbPoint) else { continue }
            let subtitle = String(format: "(%.2f, %.2f)", uwbPoint.x, uwbPoint.y)
            debugMarkersRootNode.addChildNode(
                makeMarkerNode(title: title, subtitle: subtitle, color: color, worldXZ: worldXZ)
            )
        }
    }

    private func updateCalibrationDebugOverlay() {
        let transformAngleDegrees = calibrationTransform.map { $0.rotationAngle * 180.0 / .pi }
        let mappedOrigin = mapLayoutPointToARXZ(simd_float2(0, 0))
        let mappedTopLeft = mapLayoutPointToARXZ(simd_float2(0, uwbAreaHeight))
        let mappedTopRight = mapLayoutPointToARXZ(simd_float2(uwbAreaWidth, uwbAreaHeight))
        let mappedCenter = mapLayoutPointToARXZ(simd_float2(uwbAreaWidth / 2.0, uwbAreaHeight / 2.0))
        let arDeviceInUWB = currentCameraUWBPosition()
        let uwbDevice = uwbDataDelegate?.getCurrentUWBPosition()
        let liveDriftUWB = (arDeviceInUWB != nil && uwbDevice != nil) ? (uwbDevice! - arDeviceInUWB!) : nil
        let liveDriftMagnitude = liveDriftUWB.map(simd_length)
        let filteredDriftMagnitude = simd_length(driftStats.filteredDriftUWB)
        let contentOffset = simd_float2(contentRootNode.simdPosition.x, contentRootNode.simdPosition.z)
        let topLeftDelta = capturedTopLeftSample.flatMap { captured in
            mappedTopLeft.map { simd_length($0 - captured.arXZ) }
        }
        let topRightDelta = capturedTopRightSample.flatMap { captured in
            mappedTopRight.map { simd_length($0 - captured.arXZ) }
        }
        let mirroredX = calibrationTransform?.mirrorsXAxis == true ? "YES" : "NO"

        calibrationDebugLabel.text = [
            "AR Debug",
            "Step: \(calibrationStep.titleIndex)/3",
            "AR Origin: \(formattedPoint(capturedOriginSample?.arXZ))",
            "AR TopLeft: \(formattedPoint(capturedTopLeftSample?.arXZ))",
            "AR TopRight: \(formattedPoint(capturedTopRightSample?.arXZ))",
            "UWB@OriginTap: \(formattedPoint(capturedOriginSample?.uwbXY))",
            "UWB@TopLeftTap: \(formattedPoint(capturedTopLeftSample?.uwbXY))",
            "UWB@TopRightTap: \(formattedPoint(capturedTopRightSample?.uwbXY))",
            "Rot: \(formattedScalar(transformAngleDegrees, suffix: " deg"))",
            "Mirror X: \(mirroredX)",
            "Map Origin: \(formattedPoint(mappedOrigin))",
            "Map TopLeft: \(formattedPoint(mappedTopLeft))",
            "Map TopRight: \(formattedPoint(mappedTopRight))",
            "Map Center: \(formattedPoint(mappedCenter))",
            "TopLeft Err: \(formattedScalar(topLeftDelta, suffix: " m"))",
            "TopRight Err: \(formattedScalar(topRightDelta, suffix: " m"))",
            "Drift Mode: \(driftMode.title)",
            "Reloc: \(relocalizationState.rawValue)",
            "AR Dev@UWB: \(formattedPoint(arDeviceInUWB))",
            "UWB Dev: \(formattedPoint(uwbDevice))",
            "Delta: \(formattedPoint(liveDriftUWB))",
            "Delta |m|: \(formattedScalar(liveDriftMagnitude, suffix: " m"))",
            "Filtered Drift: \(formattedPoint(driftStats.filteredDriftUWB))",
            "Filtered |m|: \(formattedScalar(filteredDriftMagnitude, suffix: " m"))",
            "Above Enter: \(formattedScalar(Float(driftStats.timeAboveThreshold), suffix: " s"))",
            "Peak Drift: \(formattedScalar(driftStats.peakDriftMeters, suffix: " m"))",
            "Corrections: \(driftStats.correctionCount)",
            "Correction Sum: \(formattedScalar(driftStats.totalCorrectionMeters, suffix: " m"))",
            "Peak Step: \(formattedScalar(driftStats.peakCorrectionMeters, suffix: " m"))",
            "Content Offset: \(formattedPoint(contentOffset))"
        ].joined(separator: "\n")
    }

    private func formattedPoint(_ point: simd_float2?) -> String {
        guard let point else { return "--" }
        return String(format: "(%.2f, %.2f)", point.x, point.y)
    }

    private func formattedPoint(_ point: simd_float2) -> String {
        String(format: "(%.2f, %.2f)", point.x, point.y)
    }

    private func formattedScalar(_ value: Float?, suffix: String) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f%@", value, suffix)
    }

    private func clearDebugMarkers() {
        debugMarkersRootNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    private func makeMarkerNode(title: String, subtitle: String, color: UIColor, worldXZ: simd_float2) -> SCNNode {
        let container = SCNNode()
        let markerY = floorYForMarker(at: worldXZ) ?? 0.01
        container.position = SCNVector3(worldXZ.x, markerY, worldXZ.y)

        let base = SCNCylinder(radius: 0.06, height: 0.015)
        base.firstMaterial?.diffuse.contents = color
        let baseNode = SCNNode(geometry: base)
        container.addChildNode(baseNode)

        let pole = SCNCylinder(radius: 0.007, height: 0.20)
        pole.firstMaterial?.diffuse.contents = color
        let poleNode = SCNNode(geometry: pole)
        poleNode.position = SCNVector3(0, 0.10, 0)
        container.addChildNode(poleNode)

        let textNode = makeBillboardTextNode(text: "\(title)\n\(subtitle)", color: color)
        textNode.position = SCNVector3(0.03, 0.22, 0)
        container.addChildNode(textNode)

        return container
    }

    private func floorYForMarker(at worldXZ: simd_float2) -> Float? {
        guard let cameraTransform = sceneView.session.currentFrame?.camera.transform else { return nil }
        let startY = cameraTransform.columns.3.y + 0.5
        let origin = simd_float3(worldXZ.x, startY, worldXZ.y)
        let down = simd_float3(0, -1, 0)
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane]

        for target in targets {
            let query = ARRaycastQuery(origin: origin, direction: down, allowing: target, alignment: .horizontal)
            if let hit = sceneView.session.raycast(query).first {
                return hit.worldTransform.columns.3.y
            }
        }
        return nil
    }

    private func makeBillboardTextNode(text: String, color: UIColor) -> SCNNode {
        let textGeometry = SCNText(string: text, extrusionDepth: 0.002)
        textGeometry.font = UIFont.systemFont(ofSize: 0.10, weight: .semibold)
        textGeometry.flatness = 0.2
        textGeometry.alignmentMode = CATextLayerAlignmentMode.left.rawValue
        textGeometry.firstMaterial?.diffuse.contents = color
        textGeometry.firstMaterial?.isDoubleSided = true

        let textNode = SCNNode(geometry: textGeometry)
        let (minBounds, maxBounds) = textGeometry.boundingBox
        let width = maxBounds.x - minBounds.x
        let height = maxBounds.y - minBounds.y
        textNode.scale = SCNVector3(0.03, 0.03, 0.03)
        textNode.pivot = SCNMatrix4MakeTranslation(minBounds.x, minBounds.y + (height / 2.0), 0)
        textNode.constraints = [SCNBillboardConstraint()]
        textNode.position.x -= Float(width) * 0.0005
        return textNode
    }
    
    private func makeARConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = .horizontal
        
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            configuration.frameSemantics.insert(.personSegmentationWithDepth)
        }
        
        return configuration
    }
    
    private func applyHeidentorMaterials(to rootNode: SCNNode) {
        let diffuseTexture = UIImage(named: "Heidentor_AlbedoTransparency")
        let normalTexture = UIImage(named: "Heidentor_Normal")
        
        rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            
            if geometry.materials.isEmpty {
                geometry.materials = [SCNMaterial()]
            }
            
            for material in geometry.materials {
                if let diffuseTexture {
                    material.diffuse.contents = diffuseTexture
                }
                if let normalTexture {
                    material.normal.contents = normalTexture
                }
                material.lightingModel = .physicallyBased
                material.isDoubleSided = false
            }
        }
    }
    
    // MARK: - Heidentor Model Loading
    
    private func loadHeidentorModelIfNeeded() {
        guard heidentorNode == nil else { return }
        let candidateURLs: [URL?] = [
            Bundle.main.url(forResource: "heidentor_rebuilt", withExtension: "obj"),
            Bundle.main.url(forResource: "heidentor_rebuilt", withExtension: "usdz"),
            Bundle.main.url(forResource: "heidentor_rebuilt", withExtension: "glb"),
            Bundle.main.url(forResource: "heidentor", withExtension: "glb", subdirectory: "heidentor_rebuilt")
        ]
        
        guard let chosen = candidateURLs.compactMap({ $0 }).first else {
            customPrint("AR WARNING: No Heidentor model found in app bundle. Expected heidentor_rebuilt.obj or heidentor_rebuilt.usdz.")
            return
        }
        
        do {
            let scene = try SCNScene(url: chosen, options: nil)
            let container = SCNNode()
            for child in scene.rootNode.childNodes { container.addChildNode(child) }
            applyHeidentorMaterials(to: container)
            heidentorNode = container
            customPrint("Heidentor model loaded from: \(chosen.lastPathComponent)")
        } catch {
            customPrint("AR ERROR: Failed to load Heidentor model: \(error.localizedDescription)")
        }
    }
    
    // MARK: - User Message Helper
    
    private func showUserMessage(_ message: String, title: String = "Notice") {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
    }
}
