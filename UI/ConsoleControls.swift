// Input: touch positions on the 3DS screen and Circle Pad.
// Output: normalized touch and analog movement events.
// Pos: 3DS console controls.

import MetalKit
import UIKit

final class ConsoleTouchScreen: MTKView {
    var onTouch: ((CGPoint, UITouch.Phase) -> Void)?
    private var activeTouch: UITouch?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isUserInteractionEnabled = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func send(_ touch: UITouch, phase: UITouch.Phase) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let p = touch.location(in: self)
        onTouch?(CGPoint(x: min(max(p.x / bounds.width, 0), 0.999),
                         y: min(max(p.y / bounds.height, 0), 0.999)), phase)
    }
    func cancelTouch() {
        guard let touch = activeTouch else { return }
        send(touch, phase: .cancelled)
        activeTouch = nil
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch; send(touch, phase: .began)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        send(touch, phase: .moved)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        send(touch, phase: .ended); activeTouch = nil
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        send(touch, phase: .cancelled); activeTouch = nil
    }
}

final class ConsoleCirclePad: UIView {
    var onMove: (((x: Float, y: Float)) -> Void)?
    private var activeTouch: UITouch?
    private var touchOrigin = CGPoint.zero
    private var knobOrigin = CGPoint.zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let knob = UIImageView()

    func configure(image: UIImage?, size: CGFloat) {
        knob.image = image
        knob.contentMode = .scaleToFill
        knob.clipsToBounds = true
        knob.isUserInteractionEnabled = false
        addSubview(knob)
        knobSize = size
    }

    private var knobSize: CGFloat = 0.7
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.width * knobSize, height: bounds.height * knobSize)
        knob.bounds = CGRect(origin: .zero, size: size)
        knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
        knob.layer.cornerRadius = min(size.width, size.height) / 2
    }
    private func move(_ touch: UITouch) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = touch.location(in: self)
        let travel = min(bounds.width, bounds.height) * 0.28
        let x = point.x - touchOrigin.x
        let y = point.y - touchOrigin.y
        let distance = hypot(x, y)
        let scale = max(travel, distance)
        onMove?((Float(x / scale), Float(-y / scale)))
        knob.layer.removeAllAnimations()
        let visualX = knobOrigin.x + x
        let visualY = knobOrigin.y + y
        let visualScale = max(1, hypot(visualX, visualY) / travel)
        knob.transform = CGAffineTransform(translationX: visualX / visualScale,
                                           y: visualY / visualScale)
    }
    func cancelTouch() {
        guard activeTouch != nil else { return }
        activeTouch = nil
        onMove?((0, 0))
        UIView.animate(withDuration: 0.13, delay: 0, usingSpringWithDamping: 0.72,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.knob.transform = .identity
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        touchOrigin = touch.location(in: self)
        let current = knob.layer.presentation()?.affineTransform() ?? knob.transform
        knobOrigin = CGPoint(x: current.tx, y: current.ty)
        haptic.impactOccurred()
        haptic.prepare()
        move(touch)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        move(touch)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelTouch()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelTouch()
    }
}

final class ConsoleButton: UIButton {
    enum Shape { case circle, rounded }
    var shape: Shape = .rounded { didSet { setNeedsLayout() } }
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let pressLayer = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pressLayer.backgroundColor = UIColor.black.withAlphaComponent(0.16)
        pressLayer.layer.borderColor = UIColor.black.withAlphaComponent(0.12).cgColor
        pressLayer.layer.borderWidth = 1
        pressLayer.isUserInteractionEnabled = false
        pressLayer.alpha = 0
        addSubview(pressLayer)
        addAction(UIAction { [weak self] _ in self?.setPressed(true) }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.setPressed(false) },
                  for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressLayer.frame = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
        let side = min(pressLayer.bounds.width, pressLayer.bounds.height)
        pressLayer.layer.cornerRadius = shape == .circle ? side / 2 : side * 0.22
    }

    private func setPressed(_ pressed: Bool) {
        if pressed { feedback.impactOccurred(); feedback.prepare() }
        UIView.animate(withDuration: pressed ? 0.04 : 0.16, delay: 0,
                       options: [.beginFromCurrentState, .curveEaseOut]) {
            self.pressLayer.alpha = pressed ? 1 : 0
            self.pressLayer.transform = pressed ? CGAffineTransform(translationX: 0, y: 1).scaledBy(x: 0.93, y: 0.93) : .identity
        }
    }
}
