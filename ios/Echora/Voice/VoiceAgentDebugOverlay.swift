import UIKit

/// On-device readout for testing the voice agent without Xcode attached: one
/// small line at the top of the screen ("connecting", what was heard, which tool
/// the agent called). Touches pass through and VoiceOver ignores it.
/// Turn off with the UserDefaults key `voice.debugOverlay`.
@MainActor
final class VoiceAgentDebugOverlay {
    static let shared = VoiceAgentDebugOverlay()

    private let hideDelaySeconds: TimeInterval = 5
    private var label: UILabel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        guard let label = installedLabel() else {
            return
        }
        label.text = "  voice: \(text)  "
        label.isHidden = false

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.label?.isHidden = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelaySeconds, execute: work)
    }

    private func installedLabel() -> UILabel? {
        if let label, label.window != nil {
            return label
        }
        guard let window = keyWindow() else {
            return nil
        }

        let newLabel = UILabel()
        newLabel.translatesAutoresizingMaskIntoConstraints = false
        newLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        newLabel.textColor = .white
        newLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        newLabel.numberOfLines = 2
        newLabel.layer.cornerRadius = 6
        newLabel.layer.masksToBounds = true
        newLabel.isUserInteractionEnabled = false
        newLabel.isAccessibilityElement = false

        window.addSubview(newLabel)
        let guide = window.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            newLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            newLabel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            newLabel.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, constant: -16)
        ])
        label = newLabel
        return newLabel
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            for window in windowScene.windows {
                if window.isKeyWindow {
                    return window
                }
            }
        }
        return nil
    }
}
