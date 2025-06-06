import UIKit

class RecordingSetupViewController: UIViewController {

    weak var delegate: RecordingSetupDelegate?

    private var currentIsRecording: Bool = false
    private var currentTaskForDisplay: RecordingTask = .none
    private var currentSessionStartTimeForDisplay: Date?
    private var uiUpdateTimer: Timer?

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Test & Recording"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let staticWizardButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Launch Static Test Wizard", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let dynamicDescriptionLabel: UILabel = {
        let label = UILabel()
        label.text = "Manual dynamic recording for walk tests."
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let dynamicRecordButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        staticWizardButton.addTarget(self, action: #selector(openStaticWizard), for: .touchUpInside)
        dynamicRecordButton.addTarget(self, action: #selector(toggleDynamicRecording), for: .touchUpInside)
        buildLayout()
        refreshState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshState()
    }

    private func buildLayout() {
        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            staticWizardButton,
            dynamicDescriptionLabel,
            dynamicRecordButton,
            statusLabel
        ])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    private func refreshState() {
        if let state = delegate?.getCurrentRecordingState() {
            currentIsRecording = state.isRecording
            currentTaskForDisplay = state.task
            currentSessionStartTimeForDisplay = state.startTime
        }

        if currentIsRecording && currentTaskForDisplay == .dynamicTest {
            dynamicRecordButton.setTitle("Stop Dynamic Recording \(formattedElapsedTime())", for: .normal)
            dynamicRecordButton.backgroundColor = .systemRed
            dynamicRecordButton.setTitleColor(.white, for: .normal)
            staticWizardButton.isEnabled = false
            staticWizardButton.alpha = 0.5
            statusLabel.text = "Dynamic walk test is running."
            startTimer()
        } else if currentIsRecording && currentTaskForDisplay == .staticTest {
            dynamicRecordButton.setTitle("Dynamic Recording Busy", for: .normal)
            dynamicRecordButton.backgroundColor = .systemGray
            dynamicRecordButton.setTitleColor(.white, for: .normal)
            dynamicRecordButton.isEnabled = false
            staticWizardButton.isEnabled = false
            staticWizardButton.alpha = 0.5
            statusLabel.text = "Static wizard is currently running."
            startTimer()
        } else {
            dynamicRecordButton.setTitle("Start Dynamic Recording", for: .normal)
            dynamicRecordButton.backgroundColor = .systemGreen
            dynamicRecordButton.setTitleColor(.white, for: .normal)
            dynamicRecordButton.isEnabled = true
            staticWizardButton.isEnabled = true
            staticWizardButton.alpha = 1.0
            statusLabel.text = "Use the wizard for fixed-marker accuracy tests."
            stopTimer()
        }
    }

    private func formattedElapsedTime() -> String {
        guard let start = currentSessionStartTimeForDisplay else { return "" }
        let interval = Int(Date().timeIntervalSince(start))
        let seconds = interval % 60
        let minutes = (interval / 60) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startTimer() {
        guard uiUpdateTimer == nil else { return }
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    private func stopTimer() {
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
    }

    @objc private func openStaticWizard() {
        let wizard = StaticTestWizardViewController()
        wizard.delegate = delegate
        wizard.modalPresentationStyle = .pageSheet
        present(wizard, animated: true)
    }

    @objc private func toggleDynamicRecording() {
        if currentIsRecording && currentTaskForDisplay == .dynamicTest {
            delegate?.didRequestStopRecording(task: .dynamicTest)
        } else {
            delegate?.didRequestStartRecording(task: .dynamicTest)
        }
        refreshState()
    }

    deinit {
        stopTimer()
    }
}
