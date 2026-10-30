// Input: device regions and New 3DS faceplate coordinates.
// Output: two Metal screens and touch targets aligned to the image.
// Pos: 3DS console presentation.

import MetalKit
import UIKit

struct ConsoleShellGeometry {
    let area: CGRect
    private func imageRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: area.minX + x / 1051 * area.width,
               y: area.minY + y / 1497 * area.height,
               width: width / 1051 * area.width, height: height / 1497 * area.height)
    }
    var topScreen: CGRect { imageRect(139, 113, 775, 518) }
    var bottomScreen: CGRect { imageRect(215, 828, 620, 504) }
    var circlePad: CGRect { imageRect(28, 890, 162, 164) }
    var cStick: CGRect { imageRect(878, 856, 74, 74) }
    var dpad: [CGRect] { [imageRect(83, 1088, 50, 50), imageRect(40, 1137, 47, 48),
                            imageRect(130, 1137, 47, 48), imageRect(83, 1183, 50, 50)] }
    var faceButtons: [CGRect] { [imageRect(916, 948, 60, 60), imageRect(860, 1010, 60, 60),
                                   imageRect(971, 1010, 60, 60), imageRect(916, 1068, 60, 60)] }
    var shoulders: [CGRect] { [imageRect(0, 750, 100, 54), imageRect(951, 750, 100, 54),
                                imageRect(100, 750, 100, 54), imageRect(851, 750, 100, 54)] }
    var select: CGRect { imageRect(251, 1372, 163, 54) }
    var menu: CGRect { imageRect(464, 1372, 122, 54) }
    var start: CGRect { imageRect(638, 1372, 163, 54) }
}

final class ConsoleShellView: UIView {
    let topScreen = MTKView()
    let bottomScreen = ConsoleTouchScreen()
    var onButton: ((ConsoleButtonID, Bool) -> Void)?
    var onStick: ((ConsoleStickID, (x: Float, y: Float)) -> Void)?
    var onScreenTouch: ((CGPoint, UITouch.Phase) -> Void)?
    var onMenu: (() -> Void)?
    var menuFrame: CGRect { geometry?.menu ?? bounds }
    private var geometry: ConsoleShellGeometry?
    private let shellImage = UIImageView(image: UIImage(named: "New3DSWhiteFaceplateXLV5"))
    private let stick = ConsoleCirclePad()
    private let cStick = ConsoleCirclePad()
    private var buttons: [UIButton] = []
    private let menu = ConsoleButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        shellImage.contentMode = .scaleToFill
        addSubview(shellImage)
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
            // Accessibility and keyboard activation send only the release; pressing again first is a no-op for real touches.
            control.addAction(UIAction { [weak self] _ in self?.onButton?(button, true); self?.onButton?(button, false) },
                              for: [.touchUpInside, .touchUpOutside, .touchCancel, .primaryActionTriggered])
            addSubview(control)
            buttons.append(control)
        }
        menu.accessibilityLabel = "HOME, return to library"
        menu.addAction(UIAction { [weak self] _ in self?.onMenu?() }, for: .touchUpInside)
        addSubview(menu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ratio: CGFloat = 1051 / 1497
        let width = min(bounds.width, bounds.height * ratio)
        let height = width / ratio
        let area = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                          width: width, height: height)
        let next = ConsoleShellGeometry(area: area)
        if geometry?.bottomScreen != next.bottomScreen { bottomScreen.cancelTouch() }
        if geometry?.circlePad != next.circlePad { stick.cancelTouch() }
        if geometry?.cStick != next.cStick { cStick.cancelTouch() }
        geometry = next
        shellImage.frame = area
        topScreen.frame = next.topScreen
        bottomScreen.frame = next.bottomScreen
        stick.frame = next.circlePad
        cStick.frame = next.cStick
        let frames = next.dpad + next.faceButtons + next.shoulders + [next.select, next.start]
        for (button, frame) in zip(buttons, frames) { button.frame = frame }
        menu.frame = next.menu
    }
}
