import UIKit
import simd

class StaticTestWizardViewController: UIViewController {

    weak var delegate: RecordingSetupDelegate?

    private enum Step: Int {
        case intro
        case marker
        case readiness
        case capture
        case results
    }

    private var step: Step = .intro
    private var captureTimer: Timer?
    private var captureStartDate: Date?
    private var pendingCaptureDuration: TimeInterval = 30

    private let stepLabel = UILabel()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let statusLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let markerNameField = UITextField()
    private let xField = UITextField()
    private let yField = UITextField()
    private let phoneHeightField = UITextField()
    private let durationControl = UISegmentedControl(items: ["15s", "30s", "60s"])
    private let formStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
        applyStep()
    }

    private func buildLayout() {
        [stepLabel, titleLabel, bodyLabel, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.numberOfLines = 0
        }

        stepLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        stepLabel.textColor = .secondaryLabel
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        bodyLabel.font = .systemFont(ofSize: 16, weight: .regular)
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .secondaryLabel

        configureTextField(markerNameField, placeholder: "Marker name", value: "Center")
        configureTextField(xField, placeholder: "Ground truth X (m)", value: "5.0")
        configureTextField(yField, placeholder: "Ground truth Y (m)", value: "5.0")
        configureTextField(phoneHeightField, placeholder: "Phone height (m)", value: "1.2")
        [xField, yField, phoneHeightField].forEach { $0.keyboardType = .decimalPad }

        durationControl.selectedSegmentIndex = 1
        durationControl.translatesAutoresizingMaskIntoConstraints = false

        formStack.axis = .vertical
        formStack.spacing = 10
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.addArrangedSubview(makeLabeledField(title: "Marker", field: markerNameField))
        formStack.addArrangedSubview(makeLabeledField(title: "Ground truth X", field: xField))
        formStack.addArrangedSubview(makeLabeledField(title: "Ground truth Y", field: yField))
        formStack.addArrangedSubview(makeLabeledField(title: "Phone height", field: phoneHeightField))
        formStack.addArrangedSubview(durationControl)

        [primaryButton, secondaryButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.layer.cornerRadius = 10
            $0.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
            $0.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        }

        primaryButton.backgroundColor = .systemBlue
        primaryButton.setTitleColor(.white, for: .normal)
        secondaryButton.backgroundColor = .secondarySystemBackground
        secondaryButton.setTitleColor(.label, for: .normal)
        closeButton.setTitle("Close", for: .normal)

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [secondaryButton, primaryButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(closeButton)
        view.addSubview(stepLabel)
        view.addSubview(titleLabel)
        view.addSubview(bodyLabel)
        view.addSubview(formStack)
        view.addSubview(statusLabel)
        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            stepLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 16),
            stepLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stepLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            titleLabel.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: stepLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: stepLabel.trailingAnchor),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            formStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),
            formStack.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: formStack.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: bodyLabel.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: bodyLabel.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func configureTextField(_ textField: UITextField, placeholder: String, value: String) {
        textField.placeholder = placeholder
        textField.text = value
        textField.borderStyle = .roundedRect
        textField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeLabeledField(title: String, field: UITextField) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func applyStep() {
        stepLabel.text = "Step \(step.rawValue + 1) of 5"
        statusLabel.text = currentStatusText()
        formStack.isHidden = step != .marker

        switch step {
        case .intro:
            titleLabel.text = "Static Accuracy Wizard"
            bodyLabel.text = "This flow records one fixed-marker session on a 10 x 10 meter test area.\n\nYou will define the marker coordinates, verify all anchors are ranging, then stand still while the app captures data automatically."
            primaryButton.setTitle("Next", for: .normal)
            secondaryButton.setTitle("Use Center Preset", for: .normal)
            secondaryButton.isHidden = false
        case .marker:
            titleLabel.text = "Define Ground Truth"
            bodyLabel.text = "Enter the marker label and its exact coordinates inside your self-defined 10 x 10 meter rectangle.\n\nHold the phone upright during the test. Set the approximate phone height you will maintain while standing still."
            primaryButton.setTitle("Continue", for: .normal)
            secondaryButton.setTitle("Center 5,5", for: .normal)
            secondaryButton.isHidden = false
        case .readiness:
            titleLabel.text = "Check Readiness"
            bodyLabel.text = "Stand on the chosen marker, face a feature-rich scene, keep the phone upright, and wait for 3 ranging anchors.\n\nDo not start capture while walking."
            primaryButton.setTitle("Start Capture", for: .normal)
            secondaryButton.setTitle("Refresh Status", for: .normal)
            secondaryButton.isHidden = false
        case .capture:
            titleLabel.text = "Capture In Progress"
            bodyLabel.text = "Remain still. Keep the phone at the chosen height and avoid turning your body. The capture stops automatically."
            primaryButton.setTitle("Finish Early", for: .normal)
            secondaryButton.setTitle("Cancel Capture", for: .normal)
            secondaryButton.isHidden = false
        case .results:
            titleLabel.text = "Results"
            bodyLabel.text = currentResultText()
            primaryButton.setTitle("Record Another Marker", for: .normal)
            secondaryButton.setTitle("Done", for: .normal)
            secondaryButton.isHidden = false
        }
    }

    private func currentStatusText() -> String {
        let status = delegate?.getEstimatorStatus()
        let anchorText = "Anchors: \(status?.rangingAnchors ?? 0)/3 ranging, \(status?.connectedAnchors ?? 0) connected"
        let confidenceText = status?.overallConfidence.map { String(format: "Confidence: %.2f", $0) } ?? "Confidence: N/A"
        let positionText: String
        if let pos = status?.latestPosition {
            positionText = String(format: "Latest UWB: (%.2f, %.2f)", pos.x, pos.y)
        } else {
            positionText = "Latest UWB: N/A"
        }
        return [anchorText, confidenceText, positionText].joined(separator: "\n")
    }

    private func currentResultText() -> String {
        guard let session = delegate?.getMostRecentCompletedSession() else {
            return "No completed session found."
        }

        switch analyzeSession(session: session) {
        case .success(let result):
            return String(
                format: """
                Marker: %@
                Ground truth: (%.2f, %.2f)

                RAW mean error: %.3f m
                RAW RMSE: %.3f m
                RAW p95: %.3f m

                FILTERED mean error: %.3f m
                FILTERED RMSE: %.3f m
                FILTERED p95: %.3f m
                """,
                session.staticContext?.markerName ?? "Unknown",
                result.groundTruth.x,
                result.groundTruth.y,
                result.rawMeanError,
                result.rawRmse,
                result.rawP95,
                result.filteredMeanError,
                result.filteredRmse,
                result.filteredP95
            )
        case .failure(let error):
            return "Analysis failed: \(error.localizedDescription)"
        }
    }

    private func validateMarkerInput() -> StaticTestSessionContext? {
        guard
            let markerName = markerNameField.text, !markerName.isEmpty,
            let xText = xField.text, let yText = yField.text,
            let x = Double(xText), let y = Double(yText),
            let phoneHeightText = phoneHeightField.text, let phoneHeight = Double(phoneHeightText)
        else {
            statusLabel.text = "Enter valid marker coordinates and phone height."
            return nil
        }

        let durations: [TimeInterval] = [15, 30, 60]
        pendingCaptureDuration = durations[max(0, durationControl.selectedSegmentIndex)]
        return StaticTestSessionContext(
            markerName: markerName,
            groundTruth: simd_double2(x, y),
            areaSizeMeters: simd_double2(10, 10),
            captureDuration: pendingCaptureDuration,
            phoneHeightMeters: phoneHeight,
            instructions: "Stand still, phone upright, feature-rich background."
        )
    }

    @objc private func primaryTapped() {
        switch step {
        case .intro:
            step = .marker
        case .marker:
            guard validateMarkerInput() != nil else { return }
            step = .readiness
        case .readiness:
            guard let context = validateMarkerInput() else { return }
            let status = delegate?.getEstimatorStatus()
            guard (status?.rangingAnchors ?? 0) >= 3 else {
                statusLabel.text = "Wait for 3 ranging anchors before starting capture."
                return
            }
            delegate?.prepareStaticTestSession(context: context)
            delegate?.didRequestStartRecording(task: .staticTest)
            captureStartDate = Date()
            step = .capture
            startCaptureTimer()
        case .capture:
            finishCapture()
        case .results:
            resetForAnotherMarker()
        }
        applyStep()
    }

    @objc private func secondaryTapped() {
        switch step {
        case .intro, .marker:
            markerNameField.text = "Center"
            xField.text = "5.0"
            yField.text = "5.0"
            phoneHeightField.text = "1.2"
        case .readiness:
            statusLabel.text = currentStatusText()
        case .capture:
            cancelCapture()
        case .results:
            dismiss(animated: true)
        }
        applyStep()
    }

    @objc private func closeTapped() {
        if step == .capture {
            cancelCapture()
        }
        dismiss(animated: true)
    }

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self, let start = self.captureStartDate else { return }
            let remaining = max(0, self.pendingCaptureDuration - Date().timeIntervalSince(start))
            self.statusLabel.text = self.currentStatusText() + "\nRemaining: " + String(format: "%.1f s", remaining)
            if remaining <= 0 {
                timer.invalidate()
                self.finishCapture()
            }
        }
    }

    private func finishCapture() {
        captureTimer?.invalidate()
        delegate?.didRequestStopRecording(task: .staticTest)
        step = .results
        applyStep()
    }

    private func cancelCapture() {
        captureTimer?.invalidate()
        delegate?.didRequestStopRecording(task: .staticTest)
        step = .readiness
        applyStep()
    }

    private func resetForAnotherMarker() {
        captureTimer?.invalidate()
        captureStartDate = nil
        step = .marker
    }
}
