//
//  AgentLargeVC.swift
//  Loop
//
//  Modal host for `AgentLargeView`. Presents the immersive agent view with a
//  crossfade transition (so the orb visually "expands" out of the nav bar)
//  and supports tap-to-dismiss + pan-down-to-dismiss. The collapse animation
//  reverses the crossfade so the orb appears to shrink back into the nav bar.
//
//  The controller only handles presentation choreography — every live data
//  binding lives on AgentLargeView itself.
//

#if os(iOS)

import UIKit

final class AgentLargeVC: UIViewController {

    /// The immersive view this controller hosts. Exposed so callers can read
    /// orb state for things like preheat / transition snapshots later.
    let agentView = AgentLargeView()

    /// Receiver for the press-and-hold pill's voice events. Forwarded
    /// straight through to `agentView.voiceDelegate` — exposed at the
    /// controller level so the presenter (MainVC) doesn't have to reach
    /// into the view to wire it up.
    weak var voiceDelegate: AgentLargeViewVoiceDelegate? {
        get { agentView.voiceDelegate }
        set { agentView.voiceDelegate = newValue }
    }

    /// Called when the user taps the orb or drags past the dismiss
    /// threshold. When hosted as a child view controller (the default
    /// now), MainVC sets this to tear down the child; when presented as
    /// a modal it falls through to `dismiss(animated:)`.
    var onDismiss: ((_ panDismiss: Bool) -> Void)?

    /// Pan gesture used for the rubber-band drag-down dismiss. Tracked here
    /// so the gesture can be cancelled / reset cleanly on dismiss.
    private var panGesture: UIPanGestureRecognizer!

    /// The vertical offset at which we commit to dismissing on release. Less
    /// than this and the view springs back to center.
    private let dismissThreshold: CGFloat = 120

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        agentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(agentView)
        NSLayoutConstraint.activate([
            agentView.topAnchor.constraint(equalTo: view.topAnchor),
            agentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            agentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            agentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Tap the orb (or the surrounding hero area) to collapse. We attach
        // to the agent view so taps on the sub-agent chips at the bottom
        // don't accidentally dismiss the sheet — a chip tap fights the
        // dismiss gesture and wins, which is the right outcome.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        agentView.avatar.isUserInteractionEnabled = true
        agentView.avatar.addGestureRecognizer(tap)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(panGesture)
    }

    // MARK: - Dismiss interactions

    @objc private func handleTap() {
        if let onDismiss = onDismiss {
            onDismiss(false)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        // Transform the CONTENT view (`agentView`), not the controller's root
        // `view`, and measure translation against the root (which never moves,
        // so it's a stable reference). Transforming the constrained child-VC
        // root view directly doesn't render during the drag — the move only
        // appears on release — which is exactly the "animates on release, not
        // during the drag" bug. Sliding the pinned content subview instead
        // renders live, mirroring the working ImageViewerVC dismiss.
        let translation = pan.translation(in: view)
        switch pan.state {
        case .changed:
            // Only respond to downward drags. Upward / sideways feel weird
            // because the view doesn't have anywhere to go.
            let dy = max(0, translation.y)
            // Rubber-band — feels increasingly resistant the farther you drag.
            let damped = dy < dismissThreshold ? dy : dismissThreshold + (dy - dismissThreshold) * 0.4
            agentView.transform = CGAffineTransform(translationX: 0, y: damped)
            // Fade out as the user drags so the dismiss feels imminent before
            // the threshold trips.
            let progress = min(1, dy / 300)
            agentView.alpha = 1 - 0.4 * progress
        case .ended, .cancelled:
            if translation.y > dismissThreshold {
                if let onDismiss = onDismiss {
                    onDismiss(true)
                } else {
                    dismiss(animated: true)
                }
            } else {
                UIView.animate(withDuration: 0.3,
                               delay: 0,
                               usingSpringWithDamping: 0.75,
                               initialSpringVelocity: 0.4,
                               options: [.allowUserInteraction]) {
                    self.agentView.transform = .identity
                    self.agentView.alpha = 1
                }
            }
        default:
            break
        }
    }
}

#endif
