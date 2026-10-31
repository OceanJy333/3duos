// Input: device regions and New 3DS faceplate coordinates.
// Output: two Metal screens and touch targets aligned to the image.
// Pos: 3DS console presentation.

import MetalKit
import UIKit

struct ConsoleShellGeometry {
    // Coordinates are measured on the active all-white bitmap, not the earlier black-bezel skin.
    static let imageSize = CGSize(width: 1052, height: 1495)
    let area: CGRect
    private func imageRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: area.minX + x / Self.imageSize.width * area.width,
               y: area.minY + y / Self.imageSize.height * area.height,
               width: width / Self.imageSize.width * area.width, height: height / Self.imageSize.height * area.height)
    }
    var topScreen: CGRect { imageRect(75, 96, 900, 540) }
    var bottomScreen: CGRect { imageRect(215, 828, 620, 504) }
    var circlePad: CGRect { imageRect(28, 878, 164, 174) }
    // The pad reads movement from where the thumb lands, so its touch area reaches into the free faceplate above and to
    // the right: the thumb can rest away from the phone's edge and still push fully left.
    var circlePadTouch: CGRect { imageRect(28, 815, 186, 270) }
    var cStick: CGRect { imageRect(877, 852, 73, 74) }
    var dpad: [CGRect] { [imageRect(85, 1083, 48, 44), imageRect(44, 1127, 42, 50),
                            imageRect(132, 1127, 43, 50), imageRect(85, 1177, 48, 47)] }
    var faceButtons: [CGRect] { [imageRect(913, 938, 63, 64), imageRect(858, 998, 63, 63),
                                   imageRect(967, 998, 63, 63), imageRect(913, 1058, 63, 64)] }
    var shoulders: [CGRect] { [imageRect(0, 750, 100, 54), imageRect(951, 750, 100, 54),
                                imageRect(100, 750, 100, 54), imageRect(851, 750, 100, 54)] }
    var select: CGRect { imageRect(252, 1359, 164, 57) }
    var menu: CGRect { imageRect(463, 1359, 124, 57) }
    var start: CGRect { imageRect(634, 1359, 163, 57) }
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
    private let shellImage = UIImageView(image: UIImage(named: "New3DSWhiteFaceplateXLAllWhite"))
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let ratio = ConsoleShellGeometry.imageSize.width / ConsoleShellGeometry.imageSize.height
        let width = max(bounds.width, bounds.height * ratio)
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
        let touch = next.circlePadTouch
        stick.touchInsets = UIEdgeInsets(top: touch.minY - next.circlePad.minY, left: touch.minX - next.circlePad.minX,
                                         bottom: next.circlePad.maxY - touch.maxY, right: next.circlePad.maxX - touch.maxX)
        cStick.frame = next.cStick
        let frames = next.dpad + next.faceButtons + next.shoulders + [next.select, next.start]
        for (button, frame) in zip(buttons, frames) { button.frame = frame }
        menu.frame = next.menu
    }
}
