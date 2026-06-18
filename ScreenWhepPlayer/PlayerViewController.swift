import UIKit
import WebRTC

final class PlayerViewController: UIViewController {
    private let videoView = RTCMTLVideoView()
    private let urlField = UITextField()
    private let tokenField = UITextField()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    private lazy var player = WhepPlayer(videoRenderer: videoView)

    override func viewDidLoad() {
        super.viewDidLoad()
        player.delegate = self
        buildInterface()
    }

    private func buildInterface() {
        view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1)

        videoView.videoContentMode = .scaleAspectFit
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        let panel = UIStackView()
        panel.axis = .vertical
        panel.spacing = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        configureTextField(urlField, placeholder: "http://192.168.1.10:8889/mystream/whep")
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.text = "http://127.0.0.1:8889/mystream/whep"

        configureTextField(tokenField, placeholder: "Bearer token (optional)")
        tokenField.autocapitalizationType = .none
        tokenField.autocorrectionType = .no

        let buttonRow = UIStackView()
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        configureButton(startButton, title: "Start")
        configureButton(stopButton, title: "Stop")
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        buttonRow.addArrangedSubview(startButton)
        buttonRow.addArrangedSubview(stopButton)

        statusLabel.text = "Idle"
        statusLabel.textColor = UIColor(white: 0.86, alpha: 1)
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.numberOfLines = 0

        panel.addArrangedSubview(urlField)
        panel.addArrangedSubview(tokenField)
        panel.addArrangedSubview(buttonRow)
        panel.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.62),

            panel.topAnchor.constraint(equalTo: videoView.bottomAnchor, constant: 16),
            panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            urlField.heightAnchor.constraint(equalToConstant: 44),
            tokenField.heightAnchor.constraint(equalToConstant: 44),
            startButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func configureTextField(_ textField: UITextField, placeholder: String) {
        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.clearButtonMode = .whileEditing
        textField.textColor = .white
        textField.tintColor = .white
        textField.backgroundColor = UIColor(white: 0.14, alpha: 1)
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.62, alpha: 1)]
        )
    }

    private func configureButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(red: 0.02, green: 0.42, blue: 0.44, alpha: 1)
        button.layer.cornerRadius = 10
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    }

    @objc private func startTapped() {
        guard let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            statusLabel.text = "Invalid WHEP URL"
            return
        }

        let token = tokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = WhepEndpoint(url: url, bearerToken: token?.isEmpty == false ? token : nil)
        player.start(endpoint: endpoint)
    }

    @objc private func stopTapped() {
        player.stop()
    }
}

extension PlayerViewController: WhepPlayerDelegate {
    func whepPlayer(_ player: WhepPlayer, didChangeStatus status: String) {
        statusLabel.text = status
    }

    func whepPlayer(_ player: WhepPlayer, didFailWith error: Error) {
        statusLabel.text = "Error: \(error.localizedDescription)"
    }
}
