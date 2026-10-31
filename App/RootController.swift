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
    private var gameRate = (time: 0.0, frames: 0, fps: 30.0, shown: 0.0, gpuMilliseconds: 0.0)   // shown: top-screen images per second
    private var shownTop: PICAHighResFrame?, pendingTop: [PICAHighResFrame] = [], topTicks = 0   // top-screen cadence
    private var tick = 0
    private var shownFrame = -1
    // Default Temporal upscaling + 4x frame interpolation; TDS_EFFECT=<index into effects> overrides it for scripted checks.
    private var effectIndex = ProcessInfo.processInfo.environment["TDS_EFFECT"].flatMap { Int($0) }
        ?? UserDefaults.standard.object(forKey: "MetalFXSetting") as? Int ?? 4
    private let effectLabel = UILabel()
    private static let effects: [(mode: MetalFXMode, frameMultiple: Int)] = [
        (.off, 1), (.spatial, 1), (.temporal, 1), (.temporal, 2), (.temporal, 4)]
    private var runner: GameRunner?
    private var runningGame: URL?
    private var inLibrary = true   // the menu button pauses a running game here; opening it again resumes it
    private var consolePresentation: ConsolePresentation?
    private let stage = UIView()   // everything on screen; kept portrait to the device whatever the scene orientation
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
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
        MetalFXBench.runIfRequested()
        // TDS_OPEN=1 opens the selected game at launch, for scripted checks (see TDS_INPUT in GameRunner).
        if runner == nil, ProcessInfo.processInfo.environment["TDS_OPEN"] != nil { openSelected() }
        updateConsoleOrientation()
    }

    func updateConsoleOrientation() {
        guard let scene = view.window?.windowScene, scene.effectiveGeometry.interfaceOrientation != .portrait else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            NSLog("3duos console orientation: %@", error.localizedDescription)
        }
        view.setNeedsLayout()
    }

    // Duo can hand a reopened scene over in landscape despite the portrait-only Info.plist. The stage then turns against the
    // scene, so the console always stands upright along the phone's long side, like a rotation lock.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let angle: CGFloat = switch view.window?.windowScene?.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: -.pi / 2
        case .landscapeLeft: .pi / 2
        case .portraitUpsideDown: .pi
        default: 0
        }
        let size = view.bounds.size
        stage.transform = .identity
        stage.bounds = CGRect(origin: .zero, size: angle.truncatingRemainder(dividingBy: .pi) == 0 ? size : CGSize(width: size.height, height: size.width))
        stage.center = CGPoint(x: size.width / 2, y: size.height / 2)
        stage.transform = CGAffineTransform(rotationAngle: angle)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.94, alpha: 1)
        view.addSubview(stage)
        shell.frame = stage.bounds
        shell.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(shell)
        consolePresentation = ConsolePresentation(in: stage, shell: shell) { [weak self] suspended in
            self?.displayLink?.isPaused = suspended
            self?.updateRunnerPause()
        }
        install(screens.top, in: shell.topScreen)
        install(screens.bottom, in: shell.bottomScreen)
        shell.topScreen.isPaused = true
        shell.bottomScreen.isPaused = true
        screens.onSelect = { [weak self] url in self?.selected = url; self?.updateLibrary() }
        screens.onOpen = { [weak self] in self?.openSelected() }
        screens.onTest = { [weak self] in self?.runner?.cancel(); self?.runner = nil; self?.runningGame = nil; self?.showTestFrames() }
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
        screens.setEffectsTitle(setting.mode.title + (setting.frameMultiple > 1 ? " + FI \(setting.frameMultiple)x" : ""))
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
            metadata = Dictionary(uniqueKeysWithValues: games.map { ($0, library.info($0)) })
            updateLibrary()
        } catch { showError(error) }
    }

    private func updateLibrary() {
        screens.update(games: games, selected: selected, metadata: metadata)
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

    private func updateRunnerPause() {
        let paused = inLibrary || consolePresentation?.isSuspended == true
        runner?.setSuspended(paused)
        if paused { runner?.releaseInput() }
        UIApplication.shared.isIdleTimerDisabled = runner != nil && !paused   // play has no touches during cutscenes
    }

    private func openSelected() {
        guard let url = selected else { return }
        inLibrary = false
        if runner != nil, runningGame == url { updateRunnerPause(); showTestFrames(); return }
        runner?.cancel()
        runner = nil
        do {
            let cartridge = try CartridgeReader.read(url: url)
            let program = try CartridgeProgramLoader.load(cartridge, from: url)
            let saves = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("saves").appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            let kernel = try ProcessLoader.boot(program, source: CartridgeSource(url: url, cartridge: cartridge), saveRoot: saves)
            runner = GameRunner(kernel: kernel)
            runningGame = url
            let mode = Self.effects[effectIndex].mode
            runner?.setInternalScale(internalScale(for: mode))
            runner?.setTextureFiltering(true)
            runner?.setTexturePack(programID: cartridge.programID)
            runner?.setMetalFXInputs(mode == .temporal && MTLCreateSystemDefaultDevice().map(MetalFXScreenPipeline.supportsTemporal) == true)
            updateRunnerPause()
            runner?.start()
            shell.onButton = { [weak self] id, pressed in if self?.inLibrary == false { self?.runner?.button(id, pressed: pressed) } }
            shell.onStick = { [weak self] id, position in if id == .circlePad, self?.inLibrary == false { self?.runner?.stick(position) } }
            shell.onScreenTouch = { [weak self] point, phase in
                if self?.inLibrary == false { self?.runner?.touch(phase == .ended || phase == .cancelled ? nil : point) }
            }
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
            presenters[0].configureMetalFX(mode: setting.mode, frameMultiple: setting.frameMultiple)
            presenters[1].configureMetalFX(mode: setting.mode == .temporal && runner != nil ? .spatial : setting.mode,
                                           frameMultiple: runner == nil ? setting.frameMultiple : 1)
            scenes = runner == nil ? [TestScene(.top), TestScene(.bottom)] : []
            screens.top.isHidden = true
            screens.bottom.isHidden = true
            shell.layoutIfNeeded()
            effectLabel.text = "MetalFX \(setting.mode.title)\(setting.frameMultiple > 1 ? " + \(setting.frameMultiple)x Frame Interpolation" : "")"
            effectLabel.isHidden = runner != nil && !Self.showsFrameRate   // the status always goes to the device log
            tick = 0
            displayLink?.invalidate()
            let link: CADisplayLink
            if #available(iOS 27.0, *),
               let sceneLink = view.window?.windowScene?.displayLink(target: self, selector: #selector(step)) {
                link = sceneLink
            } else { link = CADisplayLink(target: self, selector: #selector(step)) }
            link.isPaused = consolePresentation?.isSuspended == true
            // ProMotion: games ask for 120 Hz (the system may lower it); refreshes without a new image draw nothing. Test scenes: 60 Hz.
            let hz: Float = runner == nil ? 60 : 120
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: hz, preferred: hz)
            link.add(to: .main, forMode: .common)
            displayLink = link
            _ = presenters.first?.takeStats()
            (gameRate, shownTop, pendingTop, topTicks) = ((CACurrentMediaTime(), runner?.snapshot.gameFrames ?? 0, 30, 0, 0), nil, [], 0)
        } catch {
            showLibrary()
            showError(error)
        }
    }

    // TDS_HUD=1 shows the frame-rate line over a running game.
    private static let showsFrameRate = ProcessInfo.processInfo.environment["TDS_HUD"] != nil

    // A game shows its newest frames. Test scenes run at 60 Hz with a 30 Hz source: even ticks produce a source frame and
    // show the interpolated (or raw) image, odd ticks show the real upscaled frame.
    @objc private func step() {
        defer { tick += 1 }
        if let runner {
            let state = runner.snapshot
            let setting = Self.effects[effectIndex]
            let output = presenters.first?.scaling.map { " · \(setting.mode.title)\(setting.frameMultiple > 1 ? "+FI\(setting.frameMultiple)x" : "") \($0)" }
                ?? state.topHighRes.map { " · \($0.color.width)×\($0.color.height)" } ?? ""
            guard let link = displayLink else { return }
            measureGameRate(state.gameFrames, at: link.timestamp)
            let hz = Int((1 / (link.targetTimestamp - link.timestamp)).rounded())
            effectLabel.text = state.stop.map { "Stopped: \($0)" }
                ?? String(format: "%d fps → %d shown · %d Hz · GPU %.1f ms · %d%%%@", Int(gameRate.fps.rounded()), Int(gameRate.shown.rounded()),
                          hz, gameRate.gpuMilliseconds, Int(state.speed * 100), output)
            effectLabel.isHidden = state.stop == nil && !Self.showsFrameRate
            let fresh = state.frames != shownFrame   // temporal scalers must see each game frame once
            shownFrame = state.frames
            // Steady cadence: each top frame holds the same number of refreshes (4 for 30 fps at 120 Hz), so a few milliseconds
            // of arrival jitter never turns into 3- and 5-refresh holds. An early frame waits for its turn; a late one extends
            // the current. Within the hold the presenter steps through the interpolated images and ends on the real one.
            // Up to two frames wait their turn, so one arriving early is shown late rather than skipped; a longer backlog drops the oldest.
            if let frame = state.topHighRes, frame.sequence > (pendingTop.last ?? shownTop)?.sequence ?? -1 { pendingTop = Array((pendingTop + [frame]).suffix(2)) }
            let hold = max(1, Int((Double(hz) / (gameRate.fps > 45 ? 60 : 30)).rounded()))
            topTicks += 1
            if let pending = pendingTop.first, topTicks >= hold || shownTop == nil { (shownTop, topTicks) = (pending, 0); pendingTop.removeFirst() }
            if let shownTop { presenters[0].present(shownTop, slot: min(topTicks, hold - 1), of: hold) }
            else if fresh, let framebuffer = state.top, let frame = try? FramebufferDecoder.decode(framebuffer) { presenters[0].present(frame) }
            if let bottom = state.bottomHighRes { presenters[1].present(bottom, slot: 0, of: 1) }
            else if fresh, let framebuffer = state.bottom, let frame = try? FramebufferDecoder.decode(framebuffer) { presenters[1].present(frame) }
            return
        }
        if tick % 2 == 0 {
            guard let frames = try? scenes.map({ try $0.frame(tick / 2) }) else { return }
            for (presenter, frame) in zip(presenters, frames) { presenter.present(frame) }
        } else {
            for presenter in presenters { presenter.presentEncoded(slot: 1, of: 2) }
        }
    }

    // The game's own frame rate (new top-screen images per second), measured each second; games switch between 30 and 60.
    private func measureGameRate(_ frames: Int, at time: CFTimeInterval) {
        guard time - gameRate.time >= 1 else { return }
        let elapsed = time - gameRate.time, stats = presenters.first?.takeStats() ?? (shown: 0, gpuMilliseconds: 0)
        gameRate = (time, frames, max(1, Double(frames - gameRate.frames) / elapsed), Double(stats.shown) / elapsed, stats.gpuMilliseconds)
        if Int(time) % 10 == 0 || Self.showsFrameRate {   // device logs, every ~10 s (every second with TDS_HUD)
            NSLog("3duos status: %@ · panel max %d Hz · thermal %d%@", effectLabel.text ?? "", view.window?.windowScene?.screen.maximumFramesPerSecond ?? 0,
                  ProcessInfo.processInfo.thermalState.rawValue, ProcessInfo.processInfo.isLowPowerModeEnabled ? " · Low Power Mode" : "")
        }
    }

    private func showLibrary() {
        inLibrary = true
        updateRunnerPause()
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
