// Input: imported cartridge files and touches on the console shell.
// Output: a local library, labeled Metal test frames, and the self-developed core running a selected game with live LCD frames.
// Pos: standalone application coordinator: library, effect setting, game start and the per-refresh present loop.
import UIKit
import MetalKit
import UniformTypeIdentifiers

final class RootController: UIViewController, UIDocumentPickerDelegate {
    private let shell = ConsoleShellView()
    private let library = GameLibrary()
    private let screens = LibraryScreens()
    private var games: [URL] = []
    private var selected: URL?
    private var metadata: [URL: LibraryGameInfo] = [:]
    private var presenters: [MetalScreenPresenter] = []
    private var scenes: [TestScene] = []
    private var displayLink: CADisplayLink?
    private var tick = 0
    private var shownFrame = -1
    private var effectIndex = UserDefaults.standard.object(forKey: "MetalFXSetting") as? Int ?? 1   // Spatial until the renderer offers real high-resolution frames
    private let effectLabel = UILabel()
    private static let effects: [(mode: MetalFXMode, interpolates: Bool)] = [
        (.off, false), (.spatial, false), (.temporal, false), (.temporal, true)]
    private var runner: GameRunner?
    private var consolePresentation: ConsolePresentation?
    private var orientationLocked = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { orientationLocked }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // Mac keyboard: Return Start, Space Select, arrows D-pad, Z A, X B, S X, A Y, Q L, W R.
    private static let keys: [UIKeyboardHIDUsage: ConsoleButtonID] = [
        .keyboardReturnOrEnter: .start, .keyboardSpacebar: .select, .keyboardUpArrow: .up, .keyboardDownArrow: .down,
        .keyboardLeftArrow: .left, .keyboardRightArrow: .right, .keyboardZ: .a, .keyboardX: .b, .keyboardS: .x, .keyboardA: .y,
        .keyboardQ: .leftTrigger, .keyboardW: .rightTrigger]
    override var canBecomeFirstResponder: Bool { true }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard consolePresentation?.isSuspended != true else { return }
        var unhandled = presses
        for press in presses { if let key = press.key, let id = Self.keys[key.keyCode] { runner?.button(id, pressed: true); unhandled.remove(press) } }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses { if let key = press.key, let id = Self.keys[key.keyCode] { runner?.button(id, pressed: false); unhandled.remove(press) } }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { pressesEnded(presses, with: event) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // TDS_OPEN=1 opens the selected game at launch, for scripted checks (see TDS_INPUT in GameRunner).
        if runner == nil, ProcessInfo.processInfo.environment["TDS_OPEN"] != nil { openSelected() }
        updateConsoleOrientation()
    }

    func updateConsoleOrientation() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let scene = view.window?.windowScene,
              scene.effectiveGeometry.interfaceOrientation != preferredInterfaceOrientationForPresentation else { return }
        orientationLocked = false
        setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { error in
            NSLog("3duos console orientation: %@", error.localizedDescription)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !orientationLocked, view.window?.windowScene?.effectiveGeometry.interfaceOrientation == preferredInterfaceOrientationForPresentation {
            orientationLocked = true
            setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.94, alpha: 1)
        shell.frame = view.bounds
        shell.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(shell)
        consolePresentation = ConsolePresentation(in: view, shell: shell) { [weak self] suspended in
            self?.displayLink?.isPaused = suspended
            self?.runner?.setSuspended(suspended)
            if suspended { self?.runner?.releaseInput() }
        }
        install(screens.top, in: shell.topScreen)
        install(screens.bottom, in: shell.bottomScreen)
        shell.topScreen.isPaused = true
        shell.bottomScreen.isPaused = true
        screens.onSelect = { [weak self] url in self?.selected = url; self?.updateLibrary() }
        screens.onOpen = { [weak self] in self?.openSelected() }
        screens.onTest = { [weak self] in self?.showTestFrames() }
        screens.onEffects = { [weak self] in
            guard let self else { return }
            self.effectIndex = (self.effectIndex + 1) % Self.effects.count
            self.updateEffectsTitle()
        }
        effectIndex = min(max(effectIndex, 0), Self.effects.count - 1)
        updateEffectsTitle()
        effectLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        effectLabel.textColor = .white
        effectLabel.layer.shadowColor = UIColor.black.cgColor
        effectLabel.layer.shadowOpacity = 1
        effectLabel.layer.shadowRadius = 1
        effectLabel.layer.shadowOffset = .zero
        effectLabel.frame = CGRect(x: 4, y: 2, width: 300, height: 14)
        effectLabel.isHidden = true
        shell.topScreen.addSubview(effectLabel)
        screens.onImport = { [weak self] in self?.openPicker() }
        shell.onMenu = { [weak self] in self?.showLibrary() }
        refresh()
        if UserDefaults.standard.bool(forKey: "AutoTestScreens") { showTestFrames() }
    }

    private func updateEffectsTitle() {
        let setting = Self.effects[effectIndex]
        screens.setEffectsTitle(setting.mode.title + (setting.interpolates ? " + FI" : ""))
        UserDefaults.standard.set(effectIndex, forKey: "MetalFXSetting")
    }

    private func install(_ child: UIView, in parent: UIView) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    private func refresh() {
        do {
            games = try library.games()
            if selected == nil || !games.contains(selected!) { selected = games.first }
            metadata = [:]
            for url in games {
                do {
                    let cartridge = try CartridgeReader.read(url: url)
                    let titles = cartridge.icon?.titles ?? []
                    let title = (titles.count > 11 && !titles[11].short.isEmpty ? titles[11].short :
                                 titles.count > 1 && !titles[1].short.isEmpty ? titles[1].short :
                                 titles.first(where: { !$0.short.isEmpty })?.short) ?? ""
                    metadata[url] = LibraryGameInfo(title: title, icon: cartridge.icon.flatMap { Self.icon($0.pixels) },
                                                    detail: cartridge.productCode)
                } catch {
                    metadata[url] = LibraryGameInfo(title: "", icon: nil, detail: error.localizedDescription)
                }
            }
            updateLibrary()
        } catch { showError(error) }
    }

    private func updateLibrary() {
        screens.update(games: games, selected: selected, metadata: metadata)
    }

    private static func icon(_ pixels: [UInt16]) -> UIImage? {
        var rgba = [UInt8]()
        rgba.reserveCapacity(pixels.count * 4)
        for pixel in pixels {
            let r = UInt8((pixel >> 11) & 31), g = UInt8((pixel >> 5) & 63), b = UInt8(pixel & 31)
            rgba.append(contentsOf: [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255])
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: 48, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image).withRenderingMode(.alwaysOriginal)
    }

    private func openPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        do {
            try library.importGames(urls)
            selected = urls.first.map { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("games").appendingPathComponent($0.lastPathComponent) }
        } catch { showError(error) }
        refresh()
    }

    private func openSelected() {
        guard let url = selected else { return }
        do {
            let cartridge = try CartridgeReader.read(url: url)
            let program = try CartridgeProgramLoader.load(cartridge, from: url)
            let saves = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("saves").appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            let kernel = try ProcessLoader.boot(program, source: CartridgeSource(url: url, cartridge: cartridge), saveRoot: saves)
            runner = GameRunner(kernel: kernel)
            let mode = Self.effects[effectIndex].mode
            runner?.setInternalScale(internalScale(for: mode))
            runner?.setTextureFiltering(true)
            runner?.setTexturePack(programID: cartridge.programID)
            runner?.setMetalFXInputs(mode == .temporal && MTLCreateSystemDefaultDevice().map(MetalFXScreenPipeline.supportsTemporal) == true)
            runner?.setSuspended(consolePresentation?.isSuspended == true)
            runner?.start()
            shell.onButton = { [weak self] id, pressed in self?.runner?.button(id, pressed: pressed) }
            shell.onStick = { [weak self] id, position in if id == .circlePad { self?.runner?.stick(position) } }
            shell.onScreenTouch = { [weak self] point, phase in self?.runner?.touch(phase == .ended || phase == .cancelled ? nil : point) }
            showTestFrames()
        } catch {
            showError(error)
        }
    }

    // With MetalFX the game renders at about two thirds of the display's pixels and the scaler reconstructs the rest
    // (temporal: from jittered frames and exact motion); that saves over half the pixel work. Without it, native pixels.
    private func internalScale(for mode: MetalFXMode) -> Int {
        let native = Double(shell.topScreen.bounds.width * shell.topScreen.contentScaleFactor) / 400
        let reconstructed: Double = mode == .off ? 1 : 1.5
        return min(4, max(1, Int((native / reconstructed - 0.05).rounded(.up))))
    }

    private func showTestFrames() {
        guard let top = shell.topScreen.layer as? CAMetalLayer,
              let bottom = shell.bottomScreen.layer as? CAMetalLayer else { return }
        let setting = Self.effects[effectIndex]
        do {
            presenters = [try MetalScreenPresenter(layer: top), try MetalScreenPresenter(layer: bottom)]
            // The bottom screen has no motion source (its UI changes without geometry), so it gets the single-frame scaler.
            presenters[0].configureMetalFX(mode: setting.mode, interpolates: setting.interpolates)
            presenters[1].configureMetalFX(mode: setting.mode == .temporal && runner != nil ? .spatial : setting.mode,
                                           interpolates: setting.interpolates && runner == nil)
            scenes = runner == nil ? [TestScene(.top), TestScene(.bottom)] : []
            screens.top.isHidden = true
            screens.bottom.isHidden = true
            shell.layoutIfNeeded()
            effectLabel.text = runner == nil ? "MetalFX \(setting.mode.title)\(setting.interpolates ? " + Frame Interpolation" : "")" : "Starting game…"
            effectLabel.isHidden = false
            tick = 0
            displayLink?.invalidate()
            let link: CADisplayLink
            if #available(iOS 27.0, *),
               let sceneLink = view.window?.windowScene?.displayLink(target: self, selector: #selector(step)) {
                link = sceneLink
            } else { link = CADisplayLink(target: self, selector: #selector(step)) }
            link.isPaused = consolePresentation?.isSuspended == true
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } catch {
            showLibrary()
            showError(error)
        }
    }

    // The display runs at 60 Hz and the emulated source at 30 Hz: even ticks produce a source frame and show
    // the interpolated (or raw) image, odd ticks show the real upscaled frame.
    @objc private func step() {
        defer { tick += 1 }
        if let runner {
            let state = runner.snapshot
            let setting = Self.effects[effectIndex]
            let output = presenters.first?.scaling.map { " · \(setting.mode.title)\(setting.interpolates ? "+FI" : "") \($0)" }
                ?? state.topHighRes.map { " · \($0.color.width)×\($0.color.height)" } ?? ""
            effectLabel.text = state.stop.map { "Stopped: \($0)" } ?? "Frame \(state.frames) · \(Int(state.speed * 100))%\(output)"
            let fresh = state.frames != shownFrame   // temporal scalers must see each game frame once
            shownFrame = state.frames
            for (presenter, (highRes, framebuffer)) in zip(presenters, [(state.topHighRes, state.top), (state.bottomHighRes, state.bottom)]) {
                if let highRes { presenter.present(highRes) }
                else if fresh, let framebuffer, let frame = try? FramebufferDecoder.decode(framebuffer) { presenter.present(frame) }
            }
            return
        }
        if tick % 2 == 0 {
            guard let frames = try? scenes.map({ try $0.frame(tick / 2) }) else { return }
            for (presenter, frame) in zip(presenters, frames) { presenter.present(frame) }
        } else {
            for presenter in presenters where presenter.interpolates { presenter.presentUpscaled() }
        }
    }

    private func showLibrary() {
        runner?.cancel()
        runner = nil
        displayLink?.invalidate()
        displayLink = nil
        effectLabel.isHidden = true
        scenes.removeAll()
        presenters.removeAll()
        screens.top.isHidden = false
        screens.bottom.isHidden = false
        screens.showLibrary()
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "3duos Lab", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func setSceneActive(_ active: Bool) { consolePresentation?.setSceneActive(active) }
}
