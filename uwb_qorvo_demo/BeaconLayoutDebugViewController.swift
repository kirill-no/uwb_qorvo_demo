import UIKit
import simd

struct BeaconDefinition: Equatable {
    let shortName: String
    let uuid: UUID
}

enum BeaconLayoutRole: CaseIterable {
    case origin
    case topLeft
    case topRight

    var title: String {
        switch self {
        case .origin:
            return "Origin"
        case .topLeft:
            return "Top Left"
        case .topRight:
            return "Top Right"
        }
    }

    var coordinateLabel: String {
        switch self {
        case .origin:
            return "(0, 0)"
        case .topLeft:
            return "(0, H)"
        case .topRight:
            return "(W, H)"
        }
    }
}

struct BeaconLayoutConfiguration: Codable, Equatable {
    var originBeaconUUID: UUID
    var topLeftBeaconUUID: UUID
    var topRightBeaconUUID: UUID
    var widthMeters: Double
    var heightMeters: Double

    func assignedBeacon(for role: BeaconLayoutRole) -> UUID {
        switch role {
        case .origin:
            return originBeaconUUID
        case .topLeft:
            return topLeftBeaconUUID
        case .topRight:
            return topRightBeaconUUID
        }
    }

    mutating func setAssignedBeacon(_ uuid: UUID, for role: BeaconLayoutRole) {
        switch role {
        case .origin:
            originBeaconUUID = uuid
        case .topLeft:
            topLeftBeaconUUID = uuid
        case .topRight:
            topRightBeaconUUID = uuid
        }
    }

    func anchorSetups(using definitions: [BeaconDefinition]) -> [AnchorSetup] {
        BeaconLayoutRole.allCases.compactMap { role in
            guard let definition = definitions.first(where: { $0.uuid == assignedBeacon(for: role) }) else { return nil }
            let point = point(for: role)
            return AnchorSetup(
                name: "\(definition.shortName) (\(role.title))",
                targetUUID: definition.uuid,
                designatedPosition: simd_double3(point.x, point.y, 0.0)
            )
        }
    }

    func anchorSetup(for uuid: UUID, using definitions: [BeaconDefinition]) -> AnchorSetup? {
        anchorSetups(using: definitions).first(where: { $0.targetUUID == uuid })
    }

    func point(for role: BeaconLayoutRole) -> simd_double2 {
        switch role {
        case .origin:
            return simd_double2(0.0, 0.0)
        case .topLeft:
            return simd_double2(0.0, heightMeters)
        case .topRight:
            return simd_double2(widthMeters, heightMeters)
        }
    }

    var distancesSummary: String {
        let vertical = heightMeters
        let horizontal = widthMeters
        let diagonal = hypot(widthMeters, heightMeters)
        return String(
            format: "Origin ↔ Top Left: %.2f m   Top Left ↔ Top Right: %.2f m   Origin ↔ Top Right: %.2f m",
            vertical,
            horizontal,
            diagonal
        )
    }

    var hasUniqueAssignments: Bool {
        Set([originBeaconUUID, topLeftBeaconUUID, topRightBeaconUUID]).count == 3
    }
}

final class BeaconLayoutStore {
    private let defaultsKey = "BeaconLayoutConfiguration"
    private let defaults = UserDefaults.standard

    static let defaultBeaconDefinitions: [BeaconDefinition] = [
        BeaconDefinition(shortName: "B1", uuid: beaconUUID_6392),
        BeaconDefinition(shortName: "B2", uuid: beaconUUID_A3F1),
        BeaconDefinition(shortName: "B3", uuid: beaconUUID_67F7)
    ]

    static let defaultConfiguration = BeaconLayoutConfiguration(
        originBeaconUUID: beaconUUID_6392,
        topLeftBeaconUUID: beaconUUID_67F7,
        topRightBeaconUUID: beaconUUID_A3F1,
        widthMeters: 5.3,
        heightMeters: 3.0
    )

    func load() -> BeaconLayoutConfiguration {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let configuration = try? JSONDecoder().decode(BeaconLayoutConfiguration.self, from: data),
            configuration.hasUniqueAssignments
        else {
            return Self.defaultConfiguration
        }
        return configuration
    }

    func save(_ configuration: BeaconLayoutConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

final class BeaconLayoutDebugViewController: UIViewController {
    var onSave: ((BeaconLayoutConfiguration) -> Void)?

    private let availableBeacons: [BeaconDefinition]
    private let positionProvider: () -> simd_double2?
    private var workingConfiguration: BeaconLayoutConfiguration

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let plotView = BeaconLayoutPlotView()
    private let widthField = UITextField()
    private let heightField = UITextField()
    private let distancesLabel = UILabel()
    private let statusLabel = UILabel()
    private var assignmentButtons: [BeaconLayoutRole: UIButton] = [:]
    private var updateTimer: Timer?
    private weak var activeTextField: UITextField?

    init(
        initialConfiguration: BeaconLayoutConfiguration,
        availableBeacons: [BeaconDefinition],
        positionProvider: @escaping () -> simd_double2?
    ) {
        self.workingConfiguration = initialConfiguration
        self.availableBeacons = availableBeacons
        self.positionProvider = positionProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        applyConfigurationToUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startLiveUpdates()
        startKeyboardTracking()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopLiveUpdates()
        stopKeyboardTracking()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Beacon Layout"

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Default Preset", for: .normal)
        resetButton.addTarget(self, action: #selector(resetPresetTapped), for: .touchUpInside)

        let headerStack = UIStackView(arrangedSubviews: [closeButton, UIView(), resetButton])
        headerStack.alignment = .center
        view.addSubview(headerStack)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let introLabel = UILabel()
        introLabel.numberOfLines = 0
        introLabel.text = "Assign physical beacons to the three layout corners, set real-world distances, and compare the live solved position against this coordinate system."
        contentStack.addArrangedSubview(introLabel)

        plotView.translatesAutoresizingMaskIntoConstraints = false
        plotView.heightAnchor.constraint(equalToConstant: 320).isActive = true
        contentStack.addArrangedSubview(plotView)

        let zoomHint = UILabel()
        zoomHint.text = "Pinch to zoom. Drag to pan."
        zoomHint.font = .systemFont(ofSize: 12)
        zoomHint.textColor = .secondaryLabel
        contentStack.addArrangedSubview(zoomHint)

        let resetViewButton = UIButton(type: .system)
        resetViewButton.setTitle("Reset View", for: .normal)
        resetViewButton.addTarget(self, action: #selector(resetViewTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(resetViewButton)

        for role in BeaconLayoutRole.allCases {
            contentStack.addArrangedSubview(makeAssignmentRow(for: role))
        }

        contentStack.addArrangedSubview(makeDistanceFieldsRow())

        distancesLabel.numberOfLines = 0
        distancesLabel.font = .systemFont(ofSize: 13)
        distancesLabel.textColor = .secondaryLabel
        contentStack.addArrangedSubview(distancesLabel)

        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        contentStack.addArrangedSubview(statusLabel)

        let saveButton = UIButton(type: .system)
        var saveConfiguration = UIButton.Configuration.filled()
        saveConfiguration.title = "Save Layout"
        saveConfiguration.baseBackgroundColor = .systemBlue
        saveConfiguration.baseForegroundColor = .white
        saveConfiguration.cornerStyle = .medium
        saveConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        saveButton.configuration = saveConfiguration
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func makeAssignmentRow(for role: BeaconLayoutRole) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = "\(role.title) \(role.coordinateLabel)"
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)

        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .left
        button.configuration = .plain()
        assignmentButtons[role] = button

        let stack = UIStackView(arrangedSubviews: [titleLabel, button])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func makeDistanceFieldsRow() -> UIView {
        configureNumberField(widthField, placeholder: "Width")
        configureNumberField(heightField, placeholder: "Height")

        let widthStack = UIStackView(arrangedSubviews: [
            makeFieldLabel("Top Left ↔ Top Right (m)"),
            widthField
        ])
        widthStack.axis = .vertical
        widthStack.spacing = 6

        let heightStack = UIStackView(arrangedSubviews: [
            makeFieldLabel("Origin ↔ Top Left (m)"),
            heightField
        ])
        heightStack.axis = .vertical
        heightStack.spacing = 6

        let stack = UIStackView(arrangedSubviews: [widthStack, heightStack])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        return stack
    }

    private func makeFieldLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        return label
    }

    private func configureNumberField(_ textField: UITextField, placeholder: String) {
        textField.borderStyle = .roundedRect
        textField.placeholder = placeholder
        textField.keyboardType = .decimalPad
        textField.addTarget(self, action: #selector(textFieldChanged), for: .editingChanged)
        textField.addTarget(self, action: #selector(textFieldEditingDidBegin(_:)), for: .editingDidBegin)
    }

    private func applyConfigurationToUI() {
        widthField.text = String(format: "%.2f", workingConfiguration.widthMeters)
        heightField.text = String(format: "%.2f", workingConfiguration.heightMeters)
        updateAssignmentMenus()
        refreshPlot()
    }

    private func updateAssignmentMenus() {
        for role in BeaconLayoutRole.allCases {
            guard let button = assignmentButtons[role] else { continue }
            let assignedUUID = workingConfiguration.assignedBeacon(for: role)
            let title = availableBeacons.first(where: { $0.uuid == assignedUUID })?.shortName ?? "Select Beacon"
            button.setTitle(title, for: .normal)
            button.menu = UIMenu(children: availableBeacons.map { beacon in
                UIAction(title: beacon.shortName, state: beacon.uuid == assignedUUID ? .on : .off) { [weak self] _ in
                    self?.workingConfiguration.setAssignedBeacon(beacon.uuid, for: role)
                    self?.updateAssignmentMenus()
                    self?.refreshPlot()
                }
            })
            button.showsMenuAsPrimaryAction = true
        }
    }

    private func refreshPlot() {
        plotView.configuration = workingConfiguration
        plotView.currentPosition = positionProvider()
        distancesLabel.text = workingConfiguration.distancesSummary
        if workingConfiguration.hasUniqueAssignments {
            statusLabel.text = "Live plot uses the saved coordinate system candidate shown above."
            statusLabel.textColor = .secondaryLabel
        } else {
            statusLabel.text = "Each corner must use a different physical beacon."
            statusLabel.textColor = .systemRed
        }
    }

    private func parseCurrentFields() -> BeaconLayoutConfiguration? {
        guard
            let widthText = widthField.text?.replacingOccurrences(of: ",", with: "."),
            let heightText = heightField.text?.replacingOccurrences(of: ",", with: "."),
            let width = Double(widthText),
            let height = Double(heightText),
            width > 0.05,
            height > 0.05
        else {
            return nil
        }
        var configuration = workingConfiguration
        configuration.widthMeters = width
        configuration.heightMeters = height
        return configuration
    }

    private func startLiveUpdates() {
        stopLiveUpdates()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.plotView.currentPosition = self?.positionProvider()
        }
    }

    private func stopLiveUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func startKeyboardTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func stopKeyboardTracking() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    private func updateScrollInsets(bottomInset: CGFloat) {
        scrollView.contentInset.bottom = bottomInset
        scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
    }

    private func scrollActiveFieldIntoView(extraBottomInset: CGFloat = 0) {
        guard let activeTextField else { return }
        let targetRect = activeTextField.convert(activeTextField.bounds, to: scrollView).insetBy(dx: 0, dy: -20)
        let visibleRect = CGRect(
            x: targetRect.origin.x,
            y: targetRect.origin.y,
            width: targetRect.width,
            height: targetRect.height + extraBottomInset
        )
        scrollView.scrollRectToVisible(visibleRect, animated: true)
    }

    @objc private func closeTapped() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func resetPresetTapped() {
        workingConfiguration = BeaconLayoutStore.defaultConfiguration
        applyConfigurationToUI()
    }

    @objc private func resetViewTapped() {
        plotView.resetViewTransform()
    }

    @objc private func textFieldChanged() {
        guard let configuration = parseCurrentFields() else { return }
        workingConfiguration = configuration
        refreshPlot()
    }

    @objc private func textFieldEditingDidBegin(_ sender: UITextField) {
        activeTextField = sender
        scrollActiveFieldIntoView()
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let keyboardFrameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else {
            return
        }

        let keyboardFrameInView = view.convert(keyboardFrameValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrameInView.minY - view.safeAreaInsets.bottom)
        updateScrollInsets(bottomInset: overlap + 16)
        scrollActiveFieldIntoView(extraBottomInset: overlap)
    }

    @objc private func handleKeyboardWillHide(_ notification: Notification) {
        updateScrollInsets(bottomInset: 0)
    }

    @objc private func saveTapped() {
        guard let configuration = parseCurrentFields() else {
            statusLabel.text = "Enter valid positive distances before saving."
            statusLabel.textColor = .systemRed
            return
        }
        guard configuration.hasUniqueAssignments else {
            statusLabel.text = "Use B1, B2 and B3 only once each."
            statusLabel.textColor = .systemRed
            return
        }
        workingConfiguration = configuration
        onSave?(configuration)
        dismiss(animated: true)
    }
}

final class BeaconLayoutPlotView: UIView {
    var configuration: BeaconLayoutConfiguration = BeaconLayoutStore.defaultConfiguration {
        didSet { setNeedsDisplay() }
    }

    var currentPosition: simd_double2? {
        didSet { setNeedsDisplay() }
    }

    private var zoomScale: CGFloat = 1.0 {
        didSet {
            zoomScale = min(max(zoomScale, 0.5), 8.0)
            setNeedsDisplay()
        }
    }
    private var panOffsetWorld = simd_double2.zero {
        didSet { setNeedsDisplay() }
    }
    private var pinchStartZoom: CGFloat = 1.0
    private var panStartOffset = simd_double2.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func resetViewTransform() {
        zoomScale = 1.0
        panOffsetWorld = .zero
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let drawRect = bounds.insetBy(dx: 16, dy: 16)
        let autoFrame = worldFrame()
        let autoCenter = simd_double2(autoFrame.midX, autoFrame.midY) + panOffsetWorld
        let pixelsPerMeter = min(
            drawRect.width / CGFloat(max(autoFrame.width, 1.0)),
            drawRect.height / CGFloat(max(autoFrame.height, 1.0))
        ) * zoomScale

        context.setFillColor(UIColor.secondarySystemBackground.cgColor)
        context.fill(bounds)

        drawGrid(in: context, drawRect: drawRect, autoFrame: autoFrame, center: autoCenter, pixelsPerMeter: pixelsPerMeter)
        drawBeaconTriangle(in: context, drawRect: drawRect, center: autoCenter, pixelsPerMeter: pixelsPerMeter)
        drawCurrentPosition(in: context, drawRect: drawRect, center: autoCenter, pixelsPerMeter: pixelsPerMeter)
    }

    private func worldFrame() -> CGRect {
        let points = [
            configuration.point(for: .origin),
            configuration.point(for: .topLeft),
            configuration.point(for: .topRight),
            currentPosition
        ].compactMap { $0 }

        let minX = points.map(\.x).min() ?? 0.0
        let maxX = points.map(\.x).max() ?? 1.0
        let minY = points.map(\.y).min() ?? 0.0
        let maxY = points.map(\.y).max() ?? 1.0
        let padding = max(1.0, max(configuration.widthMeters, configuration.heightMeters) * 0.25)
        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: max(2.0, (maxX - minX) + padding * 2.0),
            height: max(2.0, (maxY - minY) + padding * 2.0)
        )
    }

    private func drawGrid(
        in context: CGContext,
        drawRect: CGRect,
        autoFrame: CGRect,
        center: simd_double2,
        pixelsPerMeter: CGFloat
    ) {
        let visibleWidth = Double(drawRect.width / pixelsPerMeter)
        let visibleHeight = Double(drawRect.height / pixelsPerMeter)
        let minX = center.x - visibleWidth / 2.0
        let maxX = center.x + visibleWidth / 2.0
        let minY = center.y - visibleHeight / 2.0
        let maxY = center.y + visibleHeight / 2.0
        let step = gridStep(for: max(visibleWidth, visibleHeight))

        context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
        context.setLineWidth(0.6)

        var x = floor(minX / step) * step
        while x <= maxX {
            let start = map(simd_double2(x, minY), drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter)
            let end = map(simd_double2(x, maxY), drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter)
            context.move(to: start)
            context.addLine(to: end)
            x += step
        }

        var y = floor(minY / step) * step
        while y <= maxY {
            let start = map(simd_double2(minX, y), drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter)
            let end = map(simd_double2(maxX, y), drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter)
            context.move(to: start)
            context.addLine(to: end)
            y += step
        }
        context.strokePath()

        let borderPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12)
        UIColor.separator.setStroke()
        borderPath.lineWidth = 1
        borderPath.stroke()
    }

    private func drawBeaconTriangle(
        in context: CGContext,
        drawRect: CGRect,
        center: simd_double2,
        pixelsPerMeter: CGFloat
    ) {
        let roles = BeaconLayoutRole.allCases
        let screenPoints = roles.map { map(configuration.point(for: $0), drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter) }

        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(2)
        context.move(to: screenPoints[0])
        context.addLine(to: screenPoints[1])
        context.addLine(to: screenPoints[2])
        context.addLine(to: screenPoints[0])
        context.strokePath()

        for role in roles {
            let worldPoint = configuration.point(for: role)
            let point = map(worldPoint, drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter)
            let beaconLabel = beaconLabel(for: role)
            UIColor.systemBlue.setFill()
            context.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            drawText(
                "\(beaconLabel)\n\(role.title)",
                at: CGPoint(x: point.x + 10, y: point.y - 22),
                color: .label,
                font: .systemFont(ofSize: 12, weight: .semibold)
            )
        }
    }

    private func drawCurrentPosition(
        in context: CGContext,
        drawRect: CGRect,
        center: simd_double2,
        pixelsPerMeter: CGFloat
    ) {
        guard let currentPosition else { return }
        let point = map(currentPosition, drawRect: drawRect, center: center, pixelsPerMeter: pixelsPerMeter)

        context.setFillColor(UIColor.systemRed.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))

        let boxRect = CGRect(x: point.x + 12, y: point.y - 18, width: 128, height: 42)
        let path = UIBezierPath(roundedRect: boxRect, cornerRadius: 8)
        UIColor.systemBackground.setFill()
        UIColor.systemRed.setStroke()
        path.lineWidth = 1
        path.fill()
        path.stroke()

        let label = String(format: "Tag\n(%.2f, %.2f)", currentPosition.x, currentPosition.y)
        drawText(label, in: boxRect.insetBy(dx: 8, dy: 5), color: .label, font: .monospacedSystemFont(ofSize: 11, weight: .medium))
    }

    private func beaconLabel(for role: BeaconLayoutRole) -> String {
        switch role {
        case .origin:
            return shortName(for: configuration.originBeaconUUID)
        case .topLeft:
            return shortName(for: configuration.topLeftBeaconUUID)
        case .topRight:
            return shortName(for: configuration.topRightBeaconUUID)
        }
    }

    private func shortName(for uuid: UUID) -> String {
        BeaconLayoutStore.defaultBeaconDefinitions.first(where: { $0.uuid == uuid })?.shortName ?? uuid.uuidString
    }

    private func map(
        _ worldPoint: simd_double2,
        drawRect: CGRect,
        center: simd_double2,
        pixelsPerMeter: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: drawRect.midX + CGFloat(worldPoint.x - center.x) * pixelsPerMeter,
            y: drawRect.midY - CGFloat(worldPoint.y - center.y) * pixelsPerMeter
        )
    }

    private func gridStep(for visibleSpan: Double) -> Double {
        if visibleSpan < 4 { return 0.5 }
        if visibleSpan < 12 { return 1.0 }
        if visibleSpan < 30 { return 2.0 }
        return 5.0
    }

    private func drawText(_ text: String, at point: CGPoint, color: UIColor, font: UIFont) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawText(_ text: String, in rect: CGRect, color: UIColor, font: UIFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = zoomScale
        case .changed:
            zoomScale = pinchStartZoom * gesture.scale
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let drawRect = bounds.insetBy(dx: 16, dy: 16)
        let autoFrame = worldFrame()
        let pixelsPerMeter = min(
            drawRect.width / CGFloat(max(autoFrame.width, 1.0)),
            drawRect.height / CGFloat(max(autoFrame.height, 1.0))
        ) * zoomScale

        switch gesture.state {
        case .began:
            panStartOffset = panOffsetWorld
        case .changed:
            let translation = gesture.translation(in: self)
            panOffsetWorld = simd_double2(
                panStartOffset.x - Double(translation.x / pixelsPerMeter),
                panStartOffset.y + Double(translation.y / pixelsPerMeter)
            )
        default:
            break
        }
    }
}
