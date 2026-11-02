// Input: UIKit hinge status and scene activity.
// Output: the closed XL lid or the existing interactive dual-screen shell, and playback suspension.
// Pos: presentation state for the same emulator session as it moves between Duo displays.
import UIKit

final class ConsolePresentation {
    private let shell: ConsoleShellView
    private let lid = ConsoleLidView()
    private let onSuspension: (Bool) -> Void
    private var isClosed = false
    private(set) var hasHinge = false
    private var isSceneActive = true
    private(set) var isSuspended = false

    init(in host: UIView, shell: ConsoleShellView, onHingeDetected: @escaping () -> Void,
         onSuspension: @escaping (Bool) -> Void) {
        self.shell = shell
        self.onSuspension = onSuspension
        lid.frame = host.bounds
        lid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lid.clipsToBounds = true
        lid.backgroundColor = UIColor(white: 0.92, alpha: 1)
        lid.isAccessibilityElement = true
        lid.accessibilityLabel = "合盖的白色 3DS XL"
        lid.accessibilityHint = "展开 iPhone Duo，显示游戏双屏和按键"
        lid.isHidden = true
        host.addSubview(lid)
        if #available(iOS 27.1, *) {
            host.addInteraction(UIHingeInteraction { [weak self] _, update in
                guard let self, let hinge = update.hinge, hinge.status != .unknown else { return }
                if !self.hasHinge {
                    self.hasHinge = true
                    shell.isFoldable = true
                    onHingeDetected()
                }
                // Nil updates occur during display handoff; keep the last known lid until a real status arrives.
                let closed = hinge.status == .closed
                guard self.isClosed != closed else { return }
                self.isClosed = closed
                self.update()
            })
        }
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        update()
    }

    private func update() {
        lid.isHidden = !isClosed
        shell.isHidden = isClosed
        let suspended = isClosed || !isSceneActive
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { shell.cancelInput() }
        onSuspension(suspended)
        NSLog("3duos presentation: lid=%@ playback=%@", isClosed ? "closed" : "open", suspended ? "paused" : "running")
    }
}

private final class ConsoleLidView: UIView {
    private let image = UIImageView(image: UIImage(named: "New3DSWhiteClosedLid"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        addSubview(image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The lid is landscape when held sideways. Rotate its texture, so unfolding never leaves a portrait game letterboxed.
        let portrait = bounds.height > bounds.width
        image.transform = .identity
        image.bounds = CGRect(x: 0, y: 0, width: portrait ? bounds.height : bounds.width,
                              height: portrait ? bounds.width : bounds.height)
        image.center = CGPoint(x: bounds.midX, y: bounds.midY)
        image.transform = CGAffineTransform(rotationAngle: portrait ? -.pi / 2 : .pi)
    }
}
