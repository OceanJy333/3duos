// Input: device regions and New 3DS faceplate coordinates.
// Output: two Metal screens and touch targets aligned to the image.
// Pos: 3DS console presentation.

import MetalKit
import UIKit

final class ConsoleShellView: UIView {
    let topScreen = MTKView()
    let bottomScreen = ConsoleTouchScreen()
    var onButton: ((ConsoleButtonID, Bool) -> Void)?
    var onStick: ((ConsoleStickID, (x: Float, y: Float)) -> Void)?
    var onScreenTouch: ((CGPoint, UITouch.Phase) -> Void)?
    var onMenu: (() -> Void)?
    var menuFrame: CGRect { geometry?.menu ?? bounds }
    private var geometry: ConsoleShellGeometry?
    private let shellImage = UIImageView()
    private let topBacking = UIView()
    private let bottomBacking = UIView()
    var isFoldable = false { didSet { setNeedsLayout() } }
    private var skinAsset: String?
    private let stick = ConsoleCirclePad()
    private let cStick = ConsoleCirclePad()
    private var buttons: [UIButton] = []
    private let menu = ConsoleButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        clipsToBounds = true
        isMultipleTouchEnabled = true
        shellImage.contentMode = .scaleToFill
        addSubview(shellImage)
        for backing in [topBacking, bottomBacking] { backing.backgroundColor = .white; addSubview(backing) }
        stick.configure(image: UIImage(named: "New3DSWhitePadKnob"), size: 0.7)
        cStick.configure(image: UIImage(named: "New3DSWhiteCStickKnob"), size: 0.8)
        topScreen.backgroundColor = .black
        bottomScreen.backgroundColor = .black
        addSubview(topScreen)
        addSubview(bottomScreen)
        bottomScreen.onTouch = { [weak self] point, phase in self?.onScreenTouch?(point, phase) }
        stick.onMove = { [weak self] position in self?.onStick?(.circlePad, position) }
        cStick.onMove = { [weak self] position in self?.onStick?(.cStick, position) }
        stick.accessibilityLabel = "Circle Pad"
        cStick.accessibilityLabel = "C-stick"
        addSubview(stick)
        addSubview(cStick)
        for (index, item) in [("Up", ConsoleButtonID.up), ("Left", .left), ("Right", .right), ("Down", .down),
                                ("X", .x), ("Y", .y), ("A", .a), ("B", .b),
                                ("L", .leftTrigger), ("R", .rightTrigger), ("ZL", .zl), ("ZR", .zr),
                                ("Select", .select), ("Start", .start)].enumerated() {
            let (label, button) = item
            let control = ConsoleButton()
            control.shape = (4...7).contains(index) ? .circle : .rounded
            control.accessibilityLabel = label
            control.addAction(UIAction { [weak self] _ in self?.onButton?(button, true) }, for: .touchDown)
            control.addAction(UIAction { [weak self] _ in self?.onButton?(button, false) },
                              for: .touchCancel)
            // Accessibility can activate on release without a touchDown; cancellation must never synthesize a press.
            control.addAction(UIAction { [weak self] _ in self?.onButton?(button, true); self?.onButton?(button, false) },
                              for: [.touchUpInside, .touchUpOutside, .primaryActionTriggered])
            addSubview(control)
            buttons.append(control)
        }
        menu.accessibilityLabel = "HOME, return to library"
        menu.addAction(UIAction { [weak self] _ in self?.onMenu?() }, for: .touchUpInside)
        addSubview(menu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancelInput() {
        bottomScreen.cancelTouch()
        stick.cancelTouch()
        cStick.cancelTouch()
        for button in buttons + [menu] {
            button.cancelTracking(with: nil)
            button.sendActions(for: .touchCancel)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit === self || hit is ConsoleButton else { return hit }
        // Enlarged touch targets choose the closest key while artwork stays fixed.
        return (buttons + [menu]).filter { $0.point(inside: convert(point, to: $0), with: event) }
            .min { hypot($0.center.x - point.x, $0.center.y - point.y)
                < hypot($1.center.x - point.x, $1.center.y - point.y) } ?? hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = isFoldable ? bounds : bounds.inset(by: safeAreaInsets)
        let profile = ConsoleSkinProfile.choose(isFoldable: isFoldable,
            isPad: traitCollection.userInterfaceIdiom == .pad, ratio: bounds.width / max(1, bounds.height))
        let next = ConsoleShellGeometry(profile: profile, in: viewport)
        if skinAsset != profile.asset { shellImage.image = UIImage(named: profile.asset); skinAsset = profile.asset }
        if geometry?.bottomScreen != next.bottomScreen { bottomScreen.cancelTouch() }
        if geometry?.circlePad != next.circlePad { stick.cancelTouch() }
        if geometry?.cStick != next.cStick { cStick.cancelTouch() }
        geometry = next
        shellImage.frame = next.area
        topBacking.frame = next.topAperture
        bottomBacking.frame = next.bottomAperture
        topScreen.frame = next.topScreen
        bottomScreen.frame = next.bottomScreen
        stick.frame = next.circlePad
        let touch = next.circlePadTouch
        stick.touchInsets = UIEdgeInsets(top: touch.minY - next.circlePad.minY, left: touch.minX - next.circlePad.minX,
                                         bottom: next.circlePad.maxY - touch.maxY, right: next.circlePad.maxX - touch.maxX)
        cStick.frame = next.cStick
        let frames = next.dpad + next.faceButtons + next.shoulders + [next.select, next.start]
        for (button, frame) in zip(buttons, frames) { button.frame = frame }
        menu.frame = next.menu
    }
}
