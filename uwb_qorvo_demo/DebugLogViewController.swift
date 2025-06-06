import UIKit

class DebugLogViewController: UIViewController {
    var logText: String = "No logs yet."

    private lazy var textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.backgroundColor = .secondarySystemBackground
        tv.layer.cornerRadius = 8
        return tv
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Close", for: .normal)
        button.addTarget(self, action: #selector(closeSheet), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .tertiarySystemBackground
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return button
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(textView)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        
        textView.text = logText
        
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLogs), name: .didUpdateLogBuffer, object: nil)
    }
    
    @objc private func closeSheet() {
        dismiss(animated: true, completion: nil)
    }
    
    @objc private func refreshLogs() {
        textView.text = globalLogBuffer.joined(separator: "\n")
        // Scroll to bottom
        if !textView.text.isEmpty {
            let bottom = NSRange(location: textView.text.count - 1, length: 1)
            textView.scrollRangeToVisible(bottom)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}