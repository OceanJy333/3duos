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
    var isFoldable = false { didSet { setNeedsLayout() } }
    private let upperImage = UIImageView()
    private let lowerImage = UIImageView()
    private let stick = ConsoleCirclePad()
    private let cStick = ConsoleCirclePad()
    private var buttons: [UIButton] = []
    private let menu = ConsoleButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        clipsToBounds = true
        isMultipleTouchEnabled = true
        if let image = UIImage(named: "New3DSWhiteFaceplateXLAllWhite")?.cgImage {
            let split = CGFloat(image.height) * ConsoleShellGeometry.splitY / ConsoleShellGeometry.imageSize.height
            upperImage.image = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int(split)))
                .map { UIImage(cgImage: $0) }
            lowerImage.image = image.cropping(to: CGRect(x: 0, y: Int(split), width: image.width, height: image.height - Int(split)))
                .map { UIImage(cgImage: $0) }
        }
        for image in [upperImage, lowerImage] { image.contentMode = .scaleToFill; addSubview(image) }
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
        // Small hardware artwork keeps its exact position; enlarged touch targets choose the closest key.
        return (buttons + [menu]).filter { $0.point(inside: convert(point, to: $0), with: event) }
            .min { hypot($0.center.x - point.x, $0.center.y - point.y)
                < hypot($1.center.x - point.x, $1.center.y - point.y) } ?? hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = isFoldable ? bounds : bounds.inset(by: safeAreaInsets)
        let next = ConsoleShellGeometry(in: viewport, spread: !isFoldable && viewport.width > viewport.height)
        if geometry?.bottomScreen != next.bottomScreen { bottomScreen.cancelTouch() }
        if geometry?.circlePad != next.circlePad { stick.cancelTouch() }
        if geometry?.cStick != next.cStick { cStick.cancelTouch() }
        geometry = next
        upperImage.frame = next.upperPanel
        lowerImage.frame = next.lowerPanel
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
