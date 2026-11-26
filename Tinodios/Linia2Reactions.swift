//
//  Linia2Reactions.swift
//  Линия 2.0: реакции, меню долгого нажатия (как в Telegram) и ответ свайпом.
//
//  Реакция = обычное сообщение с текстом-эмодзи и заголовками:
//    "reply": "<seq сообщения>", "linia2-react": "<эмодзи>".
//  Снять — сообщение с "linia2-unreact": "<эмодзи>" (видно всем; удалять сообщения в личном чате права нет).
//  Обрабатываются по порядку seq; оба вида скрыты из ленты. Другие клиенты Tinode увидят ответ-эмодзи.
//  Эмодзи — только системные (Apple Color Emoji), никаких картинок и чужих анимаций.
//  Всё настраивается с сервера (app-config.json): features.reactions / reply / swipeReply / forward / edit /
//  delete / pins, reactions.primary / more / fullList, menus.message, limits.editWindowMinutes.
//

import UIKit
import TinodeSDK
import TinodiosDB

extension MessageViewController {
    static let kL2ReactHeader = "linia2-react"
    static let kL2UnreactHeader = "linia2-unreact"
    static let kL2PrimaryReactions = ["👍", "🤝", "🔥", "✅", "❤️", "👏", "😂", "🙏"]
    static let kL2MoreReactions = ["👎", "❌", "💯", "🤔", "👀", "💰", "🚀", "😮", "😢", "🎉", "⏳", "📌"]
    static let kL2DefaultMessageMenu = ["reply", "copy", "forward", "edit", "pin", "delete", "deleteAll", "report"]
    static let kL2ChipTag = 0x4C52   // ряд пилюль реакций под пузырём (MessageCell.point(inside:) учитывает его)

    /// Первый ряд реакций (reactions.primary; старое reactions.emoji — тоже первый ряд).
    static var l2PrimaryReactions: [String] { Linia2Config.shared.reactionList("primary") ?? Linia2Config.shared.reactionEmoji ?? kL2PrimaryReactions }
    /// Второй ряд по «+» (reactions.more).
    static var l2MoreReactions: [String] { Linia2Config.shared.reactionList("more") ?? kL2MoreReactions }

    /// Убирает сообщения-реакции из ленты и пересчитывает таблицу реакций.
    func linia2ExtractReactions(_ all: [StoredMessage]) -> [StoredMessage] {
        if !all.isEmpty { view.viewWithTag(Self.kL2RetryTag)?.removeFromSuperview() }   // история пришла — убрать «Повторить»
        var map: [Int: [String: [String]]] = [:]
        var mine: [Int: [String: Int]] = [:]
        var visible: [StoredMessage] = []
        visible.reserveCapacity(all.count)
        for m in all {
            if Linia2Disappearing.isExpired(m) { continue }   // истёкшие исчезающие сообщения не показываем
            if let head = m.head, case .string(let emoji)? = head[Self.kL2UnreactHeader],
               case .string(let target)? = head["reply"], let seq = Int(target) {
                let from = m.from ?? ""
                map[seq]?[emoji]?.removeAll { $0 == from }
                if map[seq]?[emoji]?.isEmpty ?? false { map[seq]?[emoji] = nil }
                if map[seq]?.isEmpty ?? false { map[seq] = nil }
                if Cache.tinode.isMe(uid: from) { mine[seq]?[emoji] = nil }
                continue
            }
            if let head = m.head, case .string(let emoji)? = head[Self.kL2ReactHeader],
               case .string(let target)? = head["reply"], let seq = Int(target) {
                if m.isDeleted || emoji.isEmpty { continue }
                let from = m.from ?? ""
                if !(map[seq]?[emoji]?.contains(from) ?? false) {
                    map[seq, default: [:]][emoji, default: []].append(from)
                }
                if Cache.tinode.isMe(uid: from) && m.seqId > 0 {
                    mine[seq, default: [:]][emoji] = m.seqId
                }
                continue
            }
            visible.append(m)
        }
        let changed = map != linia2Reactions || mine.mapValues { Set($0.keys) } != linia2MyReactions.mapValues { Set($0.keys) }
        linia2Reactions = map
        linia2MyReactions = mine
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.collectionView?.collectionViewLayout.invalidateLayout()
                self?.collectionView?.reloadData()
            }
        }
        return visible
    }

    /// Дополнительный отступ под сообщением с реакциями.
    func linia2ReactionSpacing(for seq: Int) -> CGFloat {
        (linia2Reactions[seq]?.isEmpty ?? true) || !Linia2Config.shared.feature("reactions") ? 0 : 30
    }

    /// Пилюли «эмодзи + счётчик» под пузырём; своя — мятная; нажатие ставит/снимает.
    func linia2RenderReactions(cell: MessageCell, message: Message) {
        cell.contentView.viewWithTag(Self.kL2ChipTag)?.removeFromSuperview()
        guard Linia2Config.shared.feature("reactions"), !message.isDeleted,
              let r = linia2Reactions[message.seqId], !r.isEmpty else { return }
        cell.clipsToBounds = false
        cell.contentView.clipsToBounds = false

        let mineSet = Set(linia2MyReactions[message.seqId]?.keys.map { $0 } ?? [])
        let sorted = r.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.tag = Self.kL2ChipTag
        row.accessibilityIdentifier = "l2.reactions.\(message.seqId)"
        for (emoji, users) in sorted.prefix(6) {
            let my = mineSet.contains(emoji)
            let b = UIButton(type: .custom)
            b.setTitle(users.count > 1 ? "\(emoji) \(users.count)" : emoji, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            b.setTitleColor(my ? L2.onAccent : L2.textPrimary, for: .normal)
            b.backgroundColor = my ? L2.hex(Linia2Config.shared.color("accent") ?? 0x7EE0C3) : L2.surface2
            b.layer.cornerRadius = 13
            b.contentEdgeInsets = UIEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
            b.isAccessibilityElement = true
            b.accessibilityLabel = "Реакция \(emoji) \(users.count)" + (my ? ", моя" : "")
            b.accessibilityIdentifier = "l2.reaction.\(emoji)"
            let seq = message.seqId
            b.addAction(UIAction { [weak self] _ in self?.linia2ToggleReaction(emoji, on: seq) }, for: .touchUpInside)
            row.addArrangedSubview(b)
        }
        row.isAccessibilityElement = false
        row.accessibilityLabel = "Реакции: " + sorted.map { "\($0.key) \($0.value.count)" }.joined(separator: ", ")
        let size = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let c = cell.containerView.frame
        let x = isFromCurrentSender(message: message) ? max(4, c.maxX - size.width - 4) : c.minX + 4
        row.frame = CGRect(x: x, y: c.maxY + 2, width: size.width, height: max(26, size.height))
        cell.contentView.addSubview(row)
    }

    /// Двойное касание по сообщению — первая реакция первого ряда.
    func linia2InstallReactionGestures() {
        let dbl = UITapGestureRecognizer(target: self, action: #selector(linia2DoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        dbl.cancelsTouchesInView = false
        dbl.delaysTouchesBegan = false
        collectionView?.addGestureRecognizer(dbl)
        linia2InstallSwipeReply()
    }

    @objc private func linia2DoubleTap(_ g: UITapGestureRecognizer) {
        guard Linia2Config.shared.feature("reactions") else { return }
        guard let cv = collectionView, let ip = cv.indexPathForItem(at: g.location(in: cv)), ip.item < messages.count else { return }
        let msg = messages[ip.item]
        guard !msg.isDeleted, msg.seqId > 0 else { return }
        linia2ToggleReaction(Self.l2PrimaryReactions.first ?? "👍", on: msg.seqId)
    }

    /// Пункт «Реакция» исходного меню (оставлен для совместимости).
    @objc func linia2ReactMenu(sender: UIMenuController) {}

    /// Поставить реакцию или снять свою.
    func linia2ToggleReaction(_ emoji: String, on seq: Int) {
        guard let topic = topic else { return }
        L2.haptic()
        let remove = linia2MyReactions[seq]?[emoji] != nil
        var head: [String: JSONValue] = ["reply": .string(String(seq)), (remove ? Self.kL2UnreactHeader : Self.kL2ReactHeader): .string(emoji)]
        for (k, v) in Linia2Burn.extraHead(topic: topic.name) ?? [:] { head[k] = v }   // режим самоуничтожения
        // Сервер не присылает своё сообщение обратно (noecho), поэтому ленту перечитываем сами:
        // сразу (черновик реакции уже в кэше) и после подтверждения (seq — «моя» реакция).
        // Раньше пилюля появлялась/исчезала только после повторного открытия чата.
        topic.publish(content: Drafty(content: emoji), withExtraHeaders: head).then(
            onSuccess: { [weak self] _ in
                DispatchQueue.main.async { self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false) }
                return nil
            },
            onFailure: { err in
                Cache.log.error("Linia2: реакция не отправлена: %@", err.localizedDescription)
                DispatchQueue.main.async { UiUtils.showToast(message: remove ? "Не удалось снять реакцию" : "Не удалось отправить реакцию") }
                return nil
            })
        interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
    }
}

// MARK: - Меню долгого нажатия как в Telegram

struct Linia2MenuAction {
    let id: String
    let title: String
    let symbol: String
    let destructive: Bool
    let action: Selector
}

final class Linia2MessageMenuViewController: UIViewController {
    private let anchor: CGRect
    private let primary: [String]
    private let more: [String]
    private let fullList: Bool
    private let selected: Set<String>
    private let actions: [Linia2MenuAction]
    var onReact: ((String) -> Void)?
    var onAction: ((Selector) -> Void)?

    private let column = UIStackView()
    private let reactBox = UIView()
    private let moreRow = UIStackView()
    private var reactButtons: [UIButton] = []
    private var listHeight: NSLayoutConstraint?
    private weak var listHolder: UIView?

    init(anchor: CGRect, primary: [String], more: [String], fullList: Bool, selected: Set<String>, actions: [Linia2MenuAction]) {
        self.anchor = anchor
        self.primary = primary
        self.more = more
        self.fullList = fullList
        self.selected = selected
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { return nil }

    /// Ширина ячейки эмодзи: 46 pt, на узком экране — меньше (до 36), чтобы ряд с «+» влез целиком.
    private var emojiSide: CGFloat = 46

    private func emojiButton(_ e: String) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(e, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: (emojiSide * 36 / 46).rounded())   // системные эмодзи (Apple Color Emoji)
        b.layer.cornerRadius = emojiSide / 2 - 1
        if selected.contains(e) { b.backgroundColor = L2.accent.withAlphaComponent(0.35) }
        b.accessibilityIdentifier = "l2.react." + e
        b.accessibilityLabel = e + (selected.contains(e) ? ", снять реакцию" : "")
        b.widthAnchor.constraint(equalToConstant: emojiSide).isActive = true
        b.heightAnchor.constraint(equalToConstant: emojiSide + 2).isActive = true
        b.addAction(UIAction { [weak self, weak b] _ in
            guard let self = self, let b = b else { return }
            self.pick(e, from: b)
        }, for: .touchUpInside)
        reactButtons.append(b)
        return b
    }

    private func scrollRow(_ items: [UIView], id: String) -> UIScrollView {
        let row = UIStackView(arrangedSubviews: items)
        row.axis = .horizontal
        row.spacing = 0
        row.alignment = .center   // «+» и эмодзи — по центру ряда по вертикали
        row.translatesAutoresizingMaskIntoConstraints = false
        let sc = UIScrollView()
        sc.showsHorizontalScrollIndicator = false
        sc.accessibilityIdentifier = id
        sc.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: sc.contentLayoutGuide.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: sc.contentLayoutGuide.trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: sc.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: sc.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: sc.frameLayoutGuide.heightAnchor),
            sc.heightAnchor.constraint(equalToConstant: 52)])
        return sc
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "l2.menu"
        // Размытие фона, как в Telegram.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blur)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        // Закрытие: тап по затемнённому фону, свайп вниз, после выбора пункта или реакции.
        let backdrop = UIButton(type: .custom)
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.accessibilityIdentifier = "l2.menu.backdrop"
        backdrop.accessibilityLabel = "Закрыть меню"
        backdrop.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        view.addSubview(backdrop)
        let tap = UITapGestureRecognizer(target: self, action: #selector(close(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown(_:)))
        swipe.direction = .down
        view.addGestureRecognizer(swipe)

        // Ширина: целиком в экране с отступами 12 pt.
        let screenW = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let width = min(screenW - 24, 470)
        let plusW: CGFloat = (!more.isEmpty || fullList) ? 48 : 0
        let fixed: CGFloat = 8 + 12 + plusW   // поля пилюли и ряда + «+»
        if !primary.isEmpty {
            let fit = (width - fixed) / CGFloat(primary.count)
            emojiSide = max(36, min(46, fit.rounded(.down)))   // не влезло и при 36 — ряд прокручивается
        }

        column.axis = .vertical
        column.spacing = 10
        column.alignment = .fill
        column.translatesAutoresizingMaskIntoConstraints = false

        // Тёмная «пилюля» с эмодзи: первый ряд + «+».
        if !primary.isEmpty {
            reactBox.backgroundColor = L2.dyn(0x1B2133, 0xFFFFFF, 0.96, 0.98)   // Дизайн: в светлой теме — светлая подложка
            reactBox.layer.cornerRadius = 28
            reactBox.accessibilityIdentifier = "l2.menu.reactions"
            var items: [UIView] = primary.map { emojiButton($0) }
            if !more.isEmpty || fullList {
                let plus = UIButton(type: .system)
                plus.setImage(L2.symbol("plus", 20, .bold), for: .normal)
                plus.tintColor = L2.textPrimary
                plus.backgroundColor = L2.surface2
                plus.layer.cornerRadius = 19
                plus.accessibilityIdentifier = "l2.react.more"
                plus.accessibilityLabel = "Ещё реакции"
                plus.widthAnchor.constraint(equalToConstant: 38).isActive = true
                plus.heightAnchor.constraint(equalToConstant: 38).isActive = true
                plus.addAction(UIAction { [weak self] _ in self?.showMore() }, for: .touchUpInside)
                let wrap = UIView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                plus.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(plus)
                // Высота обёртки обязательна: в ряду с alignment .center у пустого UIView она 0 —
                // «+» рисовался за её пределами, не нажимался и не был виден VoiceOver/XCUITest.
                NSLayoutConstraint.activate([wrap.widthAnchor.constraint(equalToConstant: 48),
                                             wrap.heightAnchor.constraint(equalToConstant: 48),
                                             plus.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                                             plus.centerYAnchor.constraint(equalTo: wrap.centerYAnchor)])
                items.append(wrap)
            }
            let inner = UIStackView(arrangedSubviews: [scrollRow(items, id: "l2.menu.row1")])
            inner.axis = .vertical
            inner.spacing = 2
            inner.translatesAutoresizingMaskIntoConstraints = false
            reactBox.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.topAnchor.constraint(equalTo: reactBox.topAnchor, constant: 2),
                inner.bottomAnchor.constraint(equalTo: reactBox.bottomAnchor, constant: -2),
                inner.leadingAnchor.constraint(equalTo: reactBox.leadingAnchor, constant: 4),
                inner.trailingAnchor.constraint(equalTo: reactBox.trailingAnchor, constant: -4)])
            column.addArrangedSubview(reactBox)
        }

        // Действия.
        let list = UIStackView()
        list.axis = .vertical
        let listBox = UIView()
        listBox.backgroundColor = L2.dyn(0x1B2133, 0xFFFFFF, 0.96, 0.98)   // Дизайн: в светлой теме тёмный текст был на тёмном
        listBox.layer.cornerRadius = 16
        listBox.clipsToBounds = true
        for (i, a) in actions.enumerated() {
            let b = UIButton(type: .system)
            b.contentHorizontalAlignment = .leading
            b.setTitle(a.title, for: .normal)
            let color = a.destructive ? L2.danger : L2.textPrimary
            b.tintColor = color
            b.setTitleColor(color, for: .normal)
            b.titleLabel?.font = L2.font(16)
            // Дизайн: значки в колонке фиксированной ширины 24 pt — подписи начинаются с одной линии
            // (раньше текст сдвигался на ширину значка: «Изменить» левее «Копировать»).
            let icon = UIImageView(image: L2.symbol(a.symbol, 18, .medium))
            icon.tintColor = color
            icon.contentMode = .center
            icon.isUserInteractionEnabled = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 16),
                icon.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 24),
                icon.heightAnchor.constraint(equalToConstant: 24)])
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16 + 24 + 12, bottom: 0, right: 16)
            b.heightAnchor.constraint(equalToConstant: 46).isActive = true
            b.accessibilityIdentifier = "l2.menu." + a.id
            b.accessibilityLabel = a.title
            let sel = a.action
            b.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) { self?.onAction?(sel) } }, for: .touchUpInside)
            list.addArrangedSubview(b)
            if i < actions.count - 1 {
                let sep = UIView()
                sep.backgroundColor = L2.textSecondary.withAlphaComponent(0.15)
                sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                list.addArrangedSubview(sep)
            }
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        let listScroll = UIScrollView()
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.showsVerticalScrollIndicator = true
        listScroll.alwaysBounceVertical = false
        listScroll.accessibilityIdentifier = "l2.menu.actions"
        listBox.addSubview(listScroll)
        listScroll.addSubview(list)
        let lh = listScroll.heightAnchor.constraint(equalToConstant: CGFloat(actions.count) * 46.5)
        listHeight = lh
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: listBox.topAnchor), listScroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            listScroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor), listScroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
            lh,
            list.topAnchor.constraint(equalTo: listScroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: listScroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: listScroll.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: listScroll.frameLayoutGuide.widthAnchor)])
        if !actions.isEmpty {
            let holder = UIView()
            listHolder = listBox
            holder.addSubview(listBox)
            listBox.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                listBox.topAnchor.constraint(equalTo: holder.topAnchor), listBox.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                listBox.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                listBox.widthAnchor.constraint(equalToConstant: min(250, width))])
            column.addArrangedSubview(holder)
        }
        view.addSubview(column)

        let safe = view.safeAreaLayoutGuide.layoutFrame.isEmpty ? view.bounds.insetBy(dx: 0, dy: 50) : view.safeAreaLayoutGuide.layoutFrame
        // Список действий не выше экрана (SE, крупный шрифт) — иначе прокрутка.
        let reactH: CGFloat = primary.isEmpty ? 0 : 66
        let listMax = max(140, safe.height - 16 - reactH)
        let listH = min(CGFloat(actions.count) * 46.5, listMax)
        listHeight?.constant = listH
        let height = reactH + listH + 4
        var y = anchor.maxY + 8
        if y + height > safe.maxY - 8 { y = anchor.minY - height - 8 }
        y = max(safe.minY + 8, min(y, safe.maxY - height - 8))
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: width),
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: y)])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Эмодзи появляются с лёгким «прыжком».
        for (i, b) in reactButtons.enumerated() {
            b.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(withDuration: 0.35, delay: Double(i) * 0.02, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.8, options: []) {
                b.transform = .identity
            }
        }
    }

    /// «+»: второй ряд; при fullList — кнопка «Все эмодзи» с поиском.
    private func showMore() {
        guard moreRow.superview == nil, let inner = reactBox.subviews.first as? UIStackView else {
            if fullList { openFullList() }
            return
        }
        var items: [UIView] = more.map { emojiButton($0) }
        if fullList {
            let all = UIButton(type: .system)
            all.setImage(L2.symbol("magnifyingglass", 18, .bold), for: .normal)
            all.tintColor = L2.textPrimary
            all.accessibilityIdentifier = "l2.react.all"
            all.accessibilityLabel = "Все эмодзи"
            all.widthAnchor.constraint(equalToConstant: 48).isActive = true
            all.addAction(UIAction { [weak self] _ in self?.openFullList() }, for: .touchUpInside)
            items.append(all)
        }
        let sc = scrollRow(items, id: "l2.menu.row2")
        sc.alpha = 0
        inner.addArrangedSubview(sc)
        moreRow.tag = 1
        inner.addSubview(moreRow)   // признак, что второй ряд уже показан
        UIView.animate(withDuration: 0.25) { sc.alpha = 1; self.view.layoutIfNeeded() }
        for b in reactButtons.suffix(more.count) {
            b.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.8, options: []) { b.transform = .identity }
        }
    }

    private func openFullList() {
        let picker = Linia2EmojiPickerViewController()
        picker.onPick = { [weak self] e in
            // Закрыть и список эмодзи, и само меню.
            guard let self = self else { return }
            let react = self.onReact
            if let host = self.presentingViewController {
                host.dismiss(animated: true) { react?(e) }
            } else {
                self.dismiss(animated: false) { react?(e) }
            }
        }
        present(picker, animated: true)
    }

    /// Эмодзи увеличивается, подпрыгивает и «летит» в сообщение; лёгкая вибрация.
    private func pick(_ e: String, from b: UIButton) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let fly = UILabel()
        fly.text = e
        fly.font = .systemFont(ofSize: 36)
        fly.sizeToFit()
        fly.center = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: view)
        view.addSubview(fly)
        b.alpha = 0
        let target = CGPoint(x: anchor.midX, y: anchor.maxY)
        UIView.animateKeyframes(withDuration: 0.55, delay: 0, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                fly.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
                fly.center.y -= 24
            }
            UIView.addKeyframe(withRelativeStartTime: 0.3, relativeDuration: 0.7) {
                fly.center = target
                fly.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }
        } completion: { [weak self] _ in
            fly.removeFromSuperview()
            self?.dismiss(animated: true) { self?.onReact?(e) }
        }
    }

    @objc private func close(_ g: UITapGestureRecognizer) {
        let p = g.location(in: view)
        if view.hitTest(p, with: nil) is UIButton { return }   // кнопки (в т.ч. фон-«закрыть») обрабатывают сами
        // Вне пилюли реакций и списка действий (а не всей колонки) — закрыть.
        let boxes = [reactBox, listHolder].compactMap { $0 }.filter { $0.window != nil }
        if !boxes.contains(where: { $0.convert($0.bounds, to: view).contains(p) }) && presentedViewController == nil {
            dismiss(animated: true)
        }
    }

    @objc private func swipedDown(_ g: UISwipeGestureRecognizer) {
        guard presentedViewController == nil else { return }
        dismiss(animated: true)
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }
}

// MARK: - Полный список эмодзи с поиском (системные эмодзи)

final class Linia2EmojiPickerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate {
    var onPick: ((String) -> Void)?
    private var all: [(String, String)] = []   // эмодзи, ключевые слова
    private var shown: [String] = []
    private var collection: UICollectionView!

    /// Русские ключевые слова для частых эмодзи (поиск по-русски); остальные — по английскому названию Unicode.
    private static let ru: [String: String] = [
        "👍": "класс лайк да хорошо", "👎": "нет плохо дизлайк", "❤️": "сердце любовь", "🔥": "огонь круто",
        "😂": "смех ржу", "😮": "удивление вау", "😢": "грусть слёзы", "👏": "аплодисменты браво", "🙏": "спасибо пожалуйста",
        "🤝": "рукопожатие договорились", "✅": "готово галочка да", "❌": "нет крестик", "💯": "сто идеально",
        "🤔": "думаю хм", "👀": "смотрю глаза", "💰": "деньги", "🚀": "ракета быстро", "🎉": "праздник ура",
        "⏳": "ждём время", "📌": "закрепить важно", "😀": "улыбка радость", "😍": "влюблён", "😡": "злость",
        "🥳": "праздник", "😎": "круто очки", "🤣": "смех", "😘": "поцелуй", "👌": "окей хорошо", "💪": "сила",
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        view.accessibilityIdentifier = "l2.emoji.picker"
        all = Self.buildList()
        shown = all.map { $0.0 }
        let search = UISearchBar()
        search.placeholder = L2T("l2.emoji.search", "Поиск эмодзи")
        search.searchBarStyle = .minimal
        search.delegate = self
        search.searchTextField.accessibilityIdentifier = "l2.emoji.search"
        search.translatesAutoresizingMaskIntoConstraints = false
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 48, height: 48)
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "e")
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.keyboardDismissMode = .onDrag
        view.addSubview(search)
        view.addSubview(collection)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            collection.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4),
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
    }

    private static func buildList() -> [(String, String)] {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F600...0x1F64F, 0x1F44D...0x1F4FF, 0x1F300...0x1F44C, 0x1F680...0x1F6FF,
                                             0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF]
        var seen = Set<String>()
        for r in ranges {
            for v in r {
                guard let sc = Unicode.Scalar(v) else { continue }
                let p = sc.properties
                guard p.isEmoji else { continue }
                var s = String(Character(sc))
                if !p.isEmojiPresentation { s += "\u{FE0F}" }   // текстовые символы — в эмодзи-виде
                guard seen.insert(s).inserted else { continue }
                let name = (p.name ?? "").lowercased()
                out.append((s, name + " " + (ru[s] ?? ru[String(Character(sc))] ?? "")))
            }
        }
        // Сначала наши ряды, затем остальное.
        let first = MessageViewController.l2PrimaryReactions + MessageViewController.l2MoreReactions
        let head = first.map { e in (e, ru[e] ?? "") }
        return head + out.filter { !first.contains($0.0) }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? all.map { $0.0 } : all.filter { $0.1.contains(q) || $0.0 == q }.map { $0.0 }
        collection.reloadData()
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip)
        let l = (cell.contentView.viewWithTag(1) as? UILabel) ?? {
            let l = UILabel(frame: cell.contentView.bounds)
            l.tag = 1
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 32)
            l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cell.contentView.addSubview(l)
            return l
        }()
        l.text = shown[ip.item]
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = shown[ip.item]
        cell.accessibilityIdentifier = "l2.emoji." + shown[ip.item]
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let e = shown[ip.item]
        dismiss(animated: true) { [weak self] in self?.onPick?(e) }
    }
}

// MARK: - Сборка меню, ответ свайпом

final class Linia2SwipeReplyDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = Linia2SwipeReplyDelegate()
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard Linia2Config.shared.feature("reply"), Linia2Config.shared.feature("swipeReply"),
              let pan = g as? UIPanGestureRecognizer, let v = pan.view else { return false }
        let vel = pan.velocity(in: v)
        // Только вправо, почти горизонтально и не от самого края (там «свайп назад»).
        return vel.x > 0 && abs(vel.x) > abs(vel.y) * 1.5 && pan.location(in: v.window).x > 40
    }
}

extension MessageViewController {
    private static var l2SwipeIndex: IndexPath?
    private static let kL2SwipeName = "l2.swipeReply"

    /// Выполнить действие исходного меню Tinode для сообщения seq (оно читает seq из UIMenuController).
    func linia2Perform(_ action: Selector, seq: Int) {
        UIMenuController.shared.menuItems = [MessageMenuItem(title: "", action: action, seqId: seq)]
        perform(action, with: UIMenuController.shared)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UIMenuController.shared.menuItems = nil }
    }

    /// Меню по долгому нажатию: реакции сверху, затем действия по порядку из menus.message.
    func linia2PresentMessageMenu(items: [MessageMenuItem], cell: MessageCell) {
        sendMessageBar.inputField.nextResponderOverride = nil
        let seq = cell.seqId
        let cfg = Linia2Config.shared
        // id → (селектор, название, иконка, «опасное», флаг функции)
        let builtin: [String: [(Selector, String, String, Bool, String)]] = [
            "reply": [(#selector(showReplyPreview(sender:)), L2T("l2.menu.reply", "Ответить"), "arrowshape.turn.up.left", false, "reply")],
            "copy": [(#selector(copyMessageContent(sender:)), L2T("l2.menu.copy", "Копировать"), "doc.on.doc", false, "")],
            "forward": [(#selector(showForwardSelector(sender:)), L2T("l2.menu.forward", "Переслать"), "arrowshape.turn.up.right", false, "forward")],
            "edit": [(#selector(showEditPreview(sender:)), L2T("l2.menu.edit", "Изменить"), "pencil", false, "edit")],
            "pin": [(#selector(pinMessage(sender:)), L2T("l2.menu.pin", "Закрепить"), "pin", false, "pins"),
                    (#selector(unpinMessage(sender:)), L2T("l2.menu.unpin", "Открепить"), "pin.slash", false, "pins")],
            "delete": [(#selector(deleteMessageSoft(sender:)), L2T("l2.menu.delete", "Удалить у меня"), "trash", true, "delete")],
            "deleteAll": [(#selector(deleteMessageHard(sender:)), L2T("l2.menu.deleteAll", "Удалить у всех"), "trash.fill", true, "delete")],
            "report": [(#selector(linia2ReportMessage(sender:)), L2T("l2.menu.report", "Пожаловаться"), "exclamationmark.bubble", true, "")],
            "info": [(#selector(linia2ShowReceiptInfo(sender:)), L2T("l2.msg.info", "Информация"), "info.circle", false, "readInfo")],
        ]
        let available = Set(items.map { $0.action })
        // Время на изменение своего сообщения.
        var editAllowed = true
        if let win = cfg.editWindowSeconds, let ts = cell.timeStamp, Date().timeIntervalSince(ts) > win { editAllowed = false }
        var order = cfg.menu("message") ?? Self.kL2DefaultMessageMenu
        if !order.contains("info") { order.append("info") }   // «Информация» — в конец, если её нет в списке
        var actions: [Linia2MenuAction] = []
        var used = Set<String>()
        for id in order where !used.contains(id) {
            used.insert(id)
            for (sel, title, sym, destr, flag) in builtin[id] ?? [] where available.contains(sel) {
                if !flag.isEmpty && !cfg.feature(flag) { continue }
                if id == "edit" && !editAllowed { continue }
                // В «Избранном» (self-чат) один пункт «Удалить».
                let t = (id == "deleteAll" && !available.contains(#selector(deleteMessageSoft(sender:)))) ? L2T("l2.menu.deleteSelf", "Удалить") : title
                actions.append(Linia2MenuAction(id: sel == #selector(unpinMessage(sender:)) ? "unpin" : id, title: t, symbol: sym, destructive: destr, action: sel))
            }
        }
        let canReact = cfg.feature("reactions") && seq > 0 && !cell.isDeleted && (messageSeqIdIndex[seq].map { messages[$0].isSynced } ?? false)
        let frame = cell.containerView.convert(cell.containerView.bounds, to: nil)
        let menu = Linia2MessageMenuViewController(anchor: frame,
                                                   primary: canReact ? Self.l2PrimaryReactions : [],
                                                   more: canReact ? Self.l2MoreReactions : [],
                                                   fullList: canReact && cfg.reactionsFullList,
                                                   selected: Set(linia2MyReactions[seq]?.keys.map { $0 } ?? []),
                                                   actions: actions)
        menu.onReact = { [weak self] e in self?.linia2ToggleReaction(e, on: seq) }
        menu.onAction = { [weak self] sel in self?.linia2Perform(sel, seq: seq) }
        L2.haptic()
        self.present(menu, animated: true)
    }

    /// Свайп вправо по сообщению — «Ответить».
    func linia2InstallSwipeReply() {
        guard let cv = collectionView, !(cv.gestureRecognizers ?? []).contains(where: { $0.name == Self.kL2SwipeName }) else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(linia2SwipeReply(_:)))
        pan.name = Self.kL2SwipeName
        pan.delegate = Linia2SwipeReplyDelegate.shared
        cv.addGestureRecognizer(pan)
    }

    @objc private func linia2SwipeReply(_ g: UIPanGestureRecognizer) {
        guard let cv = collectionView else { return }
        switch g.state {
        case .began:
            Self.l2SwipeIndex = cv.indexPathForItem(at: g.location(in: cv))
        case .changed:
            guard let ip = Self.l2SwipeIndex, let cell = cv.cellForItem(at: ip) else { return }
            let dx = min(max(0, g.translation(in: cv).x), 90)
            cell.contentView.transform = CGAffineTransform(translationX: dx * 0.8, y: 0)
        default:
            guard let ip = Self.l2SwipeIndex else { return }
            Self.l2SwipeIndex = nil
            let cell = cv.cellForItem(at: ip)
            let dx = g.translation(in: cv).x
            UIView.animate(withDuration: 0.2) { cell?.contentView.transform = .identity }
            guard g.state == .ended, dx > 60, ip.item < messages.count else { return }
            let msg = messages[ip.item]
            guard !msg.isDeleted, msg.seqId > 0, msg.isSynced else { return }
            L2.haptic()
            linia2Perform(#selector(showReplyPreview(sender:)), seq: msg.seqId)
        }
    }
}
