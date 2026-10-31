// Input: game filenames, SMDH details, and the selected game.
// Output: 3DS HOME-style library screens and user actions.
// Pos: standalone app library presentation.

import UIKit

struct LibraryGameInfo {
    let title: String
    let icon: UIImage?
    let detail: String
}

@MainActor
final class LibraryScreens {
    let top = UIView()
    let bottom = UIView()
    var onSelect: ((URL) -> Void)?
    var onOpen: (() -> Void)?
    var onTest: (() -> Void)?
    var onEffects: (() -> Void)?
    var onImport: (() -> Void)?
    private let emblem = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let cards = UIStackView()
    private let open = UIButton(type: .system)
    private let effects = UIButton(type: .system)
    private let bootTop = UILabel()
    private let bootBottom = UILabel()
    private var libraryTop: UIView!
    private var libraryBottom: UIView!
    private let ink = UIColor(red: 0.27, green: 0.32, blue: 0.31, alpha: 1)
    private let mint = UIColor(red: 0.32, green: 0.70, blue: 0.62, alpha: 1)

    init() {
        top.backgroundColor = .white
        bottom.backgroundColor = .white
        top.clipsToBounds = true
        bottom.clipsToBounds = true

        let topBar = bar(left: "HOME MENU", right: "3duos")
        emblem.tintColor = mint
        emblem.contentMode = .scaleAspectFit
        emblem.layer.magnificationFilter = .nearest
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = ink
        title.textAlignment = .center
        title.adjustsFontSizeToFitWidth = true
        title.numberOfLines = 2
        subtitle.font = .systemFont(ofSize: 9, weight: .medium)
        subtitle.textColor = .gray
        subtitle.textAlignment = .center
        let preview = UIStackView(arrangedSubviews: [emblem, title, subtitle])
        preview.axis = .vertical
        preview.alignment = .fill
        preview.spacing = 3
        emblem.heightAnchor.constraint(equalTo: preview.heightAnchor, multiplier: 0.55).isActive = true
        let topStack = UIStackView(arrangedSubviews: [topBar, preview])
        topStack.axis = .vertical
        topStack.spacing = 5
        pin(topStack, inside: top, inset: 0)
        libraryTop = topStack
        topBar.heightAnchor.constraint(equalToConstant: 20).isActive = true
        preview.layoutMargins = UIEdgeInsets(top: 3, left: 10, bottom: 8, right: 10)
        preview.isLayoutMarginsRelativeArrangement = true

        let bottomBar = bar(left: "HOME", right: "SOFTWARE")
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        cards.axis = .horizontal
        cards.alignment = .center
        cards.spacing = 4
        scroll.addSubview(cards)
        cards.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cards.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 9),
            cards.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -9),
            cards.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            cards.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            cards.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        let importButton = UIButton(type: .system)
        importButton.setTitle("＋  Import", for: .normal)
        importButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        importButton.tintColor = ink
        importButton.addAction(UIAction { [weak self] _ in self?.onImport?() }, for: .touchUpInside)
        let test = UIButton(type: .system)
        test.setTitle("Test screens", for: .normal)
        test.titleLabel?.font = .systemFont(ofSize: 10, weight: .semibold)
        test.tintColor = ink
        test.addAction(UIAction { [weak self] _ in self?.onTest?() }, for: .touchUpInside)
        effects.titleLabel?.font = .systemFont(ofSize: 10, weight: .semibold)
        effects.titleLabel?.adjustsFontSizeToFitWidth = true
        effects.tintColor = ink
        effects.addAction(UIAction { [weak self] _ in self?.onEffects?() }, for: .touchUpInside)
        open.setTitle("Open  ▶", for: .normal)
        open.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        open.tintColor = UIColor(red: 0.18, green: 0.48, blue: 0.42, alpha: 1)
        open.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [importButton, test, effects, open])
        actions.distribution = .fillEqually
        actions.backgroundColor = UIColor.white.withAlphaComponent(0.72)
        let bottomStack = UIStackView(arrangedSubviews: [bottomBar, scroll, actions])
        bottomStack.axis = .vertical
        pin(bottomStack, inside: bottom, inset: 0)
        libraryBottom = bottomStack
        bottomBar.heightAnchor.constraint(equalToConstant: 20).isActive = true
        actions.heightAnchor.constraint(equalToConstant: 28).isActive = true

        for (label, screen) in [(bootTop, top), (bootBottom, bottom)] {
            label.textColor = ink
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textAlignment = .center
            label.numberOfLines = 0
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            label.isHidden = true
            pin(label, inside: screen, inset: 10)
        }
    }

    func setEffectsTitle(_ title: String) {
        effects.setTitle("MetalFX: \(title)", for: .normal)
    }

    func update(games: [URL], selected: URL?, metadata: [URL: LibraryGameInfo]) {
        let info = selected.flatMap { metadata[$0] }
        let fallback = UIImage(systemName: "gamecontroller.fill")
        title.text = info.flatMap { $0.title.isEmpty ? nil : $0.title }
            ?? selected?.deletingPathExtension().lastPathComponent ?? "Your game library"
        emblem.image = info?.icon ?? fallback
        subtitle.text = selected == nil ? "Import a ROM to inspect" : (info?.detail.isEmpty == false ? info?.detail : "ROM information")
        open.isEnabled = selected != nil
        cards.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for game in games {
            let button = UIButton(type: .system)
            button.backgroundColor = .white
            button.layer.cornerRadius = 5
            button.layer.borderWidth = game == selected ? 2.5 : 1
            button.layer.borderColor = (game == selected ? mint : UIColor.white).cgColor
            button.layer.shadowColor = UIColor.black.cgColor
            button.layer.shadowOpacity = 0.12
            button.layer.shadowRadius = 1
            button.layer.shadowOffset = CGSize(width: 0, height: 2)
            var configuration = UIButton.Configuration.plain()
            configuration.image = metadata[game]?.icon ?? fallback
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            configuration.baseForegroundColor = mint
            button.configuration = configuration
            button.imageView?.contentMode = .scaleAspectFit
            button.imageView?.layer.magnificationFilter = .nearest
            button.accessibilityLabel = metadata[game].flatMap { $0.title.isEmpty ? nil : $0.title }
                ?? game.deletingPathExtension().lastPathComponent
            button.accessibilityTraits = game == selected ? [.button, .selected] : .button
            button.addAction(UIAction { [weak self] _ in
                if game == selected { self?.onOpen?() } else { self?.onSelect?(game) }
            }, for: .touchUpInside)
            addTile(button)
        }
        for _ in games.count..<max(games.count, 5) {
            let empty = UIView()
            empty.backgroundColor = UIColor.white.withAlphaComponent(0.45)
            empty.layer.cornerRadius = 5
            empty.layer.borderWidth = 1
            empty.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
            addTile(empty)
        }
    }

    func showBoot(title: String, detail: String) {
        bootTop.text = title
        bootBottom.text = detail
        libraryTop.isHidden = true
        libraryBottom.isHidden = true
        bootTop.isHidden = false
        bootBottom.isHidden = false
    }

    func showLibrary() {
        bootTop.isHidden = true
        bootBottom.isHidden = true
        libraryTop.isHidden = false
        libraryBottom.isHidden = false
    }

    private func addTile(_ tile: UIView) {
        cards.addArrangedSubview(tile)
        tile.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.18).isActive = true
        tile.heightAnchor.constraint(equalTo: tile.widthAnchor).isActive = true
    }

    private func bar(left: String, right: String) -> UIView {
        let leftLabel = UILabel()
        leftLabel.text = left
        leftLabel.font = .systemFont(ofSize: 9, weight: .bold)
        leftLabel.textColor = ink
        let rightLabel = UILabel()
        rightLabel.text = right
        rightLabel.font = .systemFont(ofSize: 8, weight: .medium)
        rightLabel.textColor = .gray
        rightLabel.textAlignment = .right
        let row = UIStackView(arrangedSubviews: [leftLabel, rightLabel])
        row.distribution = .equalSpacing
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.backgroundColor = UIColor.white.withAlphaComponent(0.65)
        return row
    }

    private func pin(_ child: UIView, inside parent: UIView, inset: CGFloat) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}
