// Input: imported cartridge files and touches on the console shell.
// Output: a local library and clearly labeled Metal test frames.
// Pos: standalone application coordinator; game execution is still under development.
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
    private var showingTest = false
    private var bootID: UUID?
    private var portraitLocked = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { portraitLocked }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            NSLog("3duos Lab portrait request: %@", error.localizedDescription)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if #available(iOS 26.0, *), !portraitLocked,
           view.window?.windowScene?.interfaceOrientation.isPortrait == true {
            portraitLocked = true
            setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        shell.frame = view.bounds
        shell.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(shell)
        install(screens.top, in: shell.topScreen)
        install(screens.bottom, in: shell.bottomScreen)
        shell.topScreen.isPaused = true
        shell.bottomScreen.isPaused = true
        screens.onSelect = { [weak self] url in self?.selected = url; self?.updateLibrary() }
        screens.onOpen = { [weak self] in self?.openSelected() }
        screens.onTest = { [weak self] in self?.showTestFrames() }
        screens.onImport = { [weak self] in self?.openPicker() }
        shell.onMenu = { [weak self] in self?.showLibrary() }
        refresh()
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
        let id = UUID()
        bootID = id
        let name = metadata[url].flatMap { $0.title.isEmpty ? nil : $0.title }
            ?? url.deletingPathExtension().lastPathComponent
        screens.showBoot(title: "Starting\n\(name)", detail: "Reading game and checking its entry point…\n\nPress HOME to return")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail: String
            do {
                let cartridge = try CartridgeReader.read(url: url)
                let program = try CartridgeProgramLoader.load(cartridge, from: url)
                let result = try BootProbe.run(program, limit: 500_000)
                let stop: String
                switch result.stop {
                case .running: stop = "Instruction limit reached"
                case .supervisorCall(let id): stop = String(format: "SVC 0x%02X", id)
                case .undefined(let address, let instruction):
                    stop = String(format: "Undefined instruction 0x%08X at 0x%08X", instruction, address)
                case .memoryFault(let address, let reason):
                    stop = String(format: "Memory fault at 0x%08X: %@", address, reason)
                case .unsupportedThumb(let instruction):
                    stop = String(format: "Unsupported Thumb instruction 0x%04X", instruction)
                }
                detail = String(format: "Instructions: %llu\nPC: 0x%08X\nStop: %@\n\nGame has not started. Press HOME to return.",
                                result.instructionCount, result.pc, stop)
            } catch {
                detail = "Unable to start: \(error.localizedDescription)\n\nGame has not started. Press HOME to return."
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.bootID == id else { return }
                self.screens.showBoot(title: "Start check\n\(name)", detail: detail)
            }
        }
    }

    private func showTestFrames() {
        guard let top = shell.topScreen.layer as? CAMetalLayer,
              let bottom = shell.bottomScreen.layer as? CAMetalLayer else { return }
        do {
            presenters = [try MetalScreenPresenter(layer: top), try MetalScreenPresenter(layer: bottom)]
            screens.top.isHidden = true
            screens.bottom.isHidden = true
            showingTest = true
            shell.layoutIfNeeded()
            let frames = try [TestFrame.make(.top), TestFrame.make(.bottom)]
            for (presenter, frame) in zip(presenters, frames) {
                if !presenter.present(frame) { throw TestFrameError.displayUnavailable }
            }
        } catch {
            showLibrary()
            showError(error)
        }
    }

    private func showLibrary() {
        bootID = nil
        showingTest = false
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
}
