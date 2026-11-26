//
//  Linia2ChatChrome.swift
//  Линия 2.0: экран чата как в Telegram —
//   • плавающие полупрозрачные (blur) кнопки в шапке: «‹ Назад», по центру имя и статус, справа 📞 📹 ⏱ 🔍
//     (без «⋮»: блокировка, жалоба, автоудаление, информация — по нажатию на аватар/имя, экран «Информация о чате»);
//   • поиск по чату: поле, ↑/↓ и счётчик «3 из 12», переход к сообщению с подсветкой (загруженные + догрузка истории);
//   • один фон чата с лёгким узором-пульсом (без серых полос), плавающая скруглённая полупрозрачная строка ввода;
//   • «Избранное» — чат с самим собой (топик slf): закреплено сверху списка чатов, пересылка «в Избранное».
//
//  Удалённые настройки (app-config.json; нет поля — значение по умолчанию):
//   features.chatFloatingHeader, features.chatSearch, features.chatPattern, features.chatFloatingInput,
//   features.savedMessages — по умолчанию true; features.chatBackTitle — «‹ Назад» с подписью (по умолчанию false: круглая «‹»);
//   chatHeader.buttons — кнопки справа по порядку, из "call", "video", "burn", "search", "more"
//     (по умолчанию ["call","video","burn","search"]; "more" — «⋮» только если сервер явно указал;
//      📞/📹/⏱ показываются, только если доступны в этом чате);
//   chatStyle.patternOpacity — заметность узора 0…0.12 (по умолчанию 0.035; 0 — без узора);
//   texts: l2.chat.back «Назад», l2.saved.title «Избранное», l2.saved.subtitle, l2.search.placeholder «Поиск в чате»,
//     l2.search.counter «{i} из {n}», l2.search.none «Нет совпадений», l2.search.loading «Ищу в истории…».
//

import UIKit
import TinodeSDK
import TinodiosDB

enum Linia2Chrome {
    static var floatingHeader: Bool { Linia2Config.shared.feature("chatFloatingHeader") }
    static var floatingInput: Bool { Linia2Config.shared.feature("chatFloatingInput") }
    static var searchOn: Bool { Linia2Config.shared.feature("chatSearch") }
    static var savedOn: Bool { Linia2Config.shared.feature("savedMessages") }
    static var patternOpacity: CGFloat {
        guard Linia2Config.shared.feature("chatPattern") else { return 0 }
        return CGFloat(min(0.12, max(0, Linia2Config.shared.number("chatStyle", "patternOpacity") ?? 0.035)))
    }

    static let knownButtons = ["call", "video", "burn", "search", "more"]
    static let defaultButtons = ["call", "video", "burn", "search"]
    static var headerButtons: [String] {
        guard let a = Linia2Config.shared.strings("chatHeader", "buttons") else { return defaultButtons }
        return a.filter { knownButtons.contains($0) }
    }

    static var savedTitle: String { L2T("l2.saved.title", "Избранное") }
    static var savedSubtitle: String { L2T("l2.saved.subtitle", "Сохранённые сообщения и заметки") }

    /// Плитка узора: тонкая линия «пульса» (кардиограмма), рисуется цветом текста — на фоне едва заметна.
    static func pulseTile(color: UIColor) -> UIImage {
        let size = CGSize(width: 240, height: 150)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setStrokeColor(color.cgColor)
            c.setLineWidth(1.6)
            c.setLineJoin(.round)
            c.setLineCap(.round)
            func pulse(y: CGFloat, x0: CGFloat) {
                let p = UIBezierPath()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: x0, y: y))
                p.addLine(to: CGPoint(x: x0 + 8, y: y - 6))
                p.addLine(to: CGPoint(x: x0 + 14, y: y))
                p.addLine(to: CGPoint(x: x0 + 20, y: y))
                p.addLine(to: CGPoint(x: x0 + 26, y: y - 26))
                p.addLine(to: CGPoint(x: x0 + 33, y: y + 18))
                p.addLine(to: CGPoint(x: x0 + 39, y: y))
                p.addLine(to: CGPoint(x: x0 + 48, y: y))
                p.addLine(to: CGPoint(x: x0 + 56, y: y - 8))
                p.addLine(to: CGPoint(x: x0 + 64, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                c.addPath(p.cgPath)
                c.strokePath()
            }
            pulse(y: 40, x0: 40)
            pulse(y: 115, x0: 150)
        }
    }
}

// MARK: - Полупрозрачная «пилюля» (blur)

final class L2GlassView: UIView {
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    let content = UIStackView()
    private let radius: CGFloat?

    init(radius: CGFloat? = nil, insets: UIEdgeInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)) {
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.isUserInteractionEnabled = false
        blur.clipsToBounds = true
        blur.contentView.backgroundColor = L2.surface.withAlphaComponent(0.35)
        addSubview(blur)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 2
        addSubview(content)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.layer.cornerRadius = radius ?? bounds.height / 2
    }

    /// Круглая кнопка-значок внутри пилюли.
    static func iconButton(_ symbol: String, id: String, label: String, size: CGFloat = 32, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(L2.symbol(symbol, 17, .regular), for: .normal)
        b.tintColor = L2.textPrimary
        b.accessibilityIdentifier = id
        b.accessibilityLabel = label
        b.layer.cornerRadius = size / 2
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: size), b.heightAnchor.constraint(equalToConstant: size)])
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
}

// MARK: - Свайп назад при своей кнопке «Назад»

/// Системный свайп от края выключается, если заменить кнопку «Назад»; этот делегат возвращает его.
final class Linia2PopGesture: NSObject, UIGestureRecognizerDelegate {
    static let shared = Linia2PopGesture()
    weak var nav: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (nav?.viewControllers.count ?? 0) > 1
    }
}

// MARK: - Экран чата: шапка, фон

extension MessageViewController {
    static let kL2PatternTag = 0x4C3270

    /// «‹ Назад» в полупрозрачной пилюле.
    func linia2BackCapsule() -> UIView {
        let g = L2GlassView(insets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        let b = UIButton(type: .system)
        b.setImage(L2.symbol("chevron.left", 16, .semibold), for: .normal)
        // Дизайн: подпись «Назад» отнимала место у имени («Диз…» даже на Pro Max, на SE — «‹ …»).
        // Кнопка — круглая «‹» 38×38, как в iOS 26 / Telegram; подпись «Назад» остаётся для VoiceOver и тестов.
        // Вернуть текст на широких экранах: features.chatBackTitle = true в app-config.
        let compact = !Linia2Config.shared.feature("chatBackTitle", default: false)
        if !compact { b.setTitle(" " + L2T("l2.chat.back", "Назад"), for: .normal) }
        b.titleLabel?.font = L2.font(16, .medium)
        b.tintColor = L2.accent
        b.setTitleColor(L2.accent, for: .normal)
        b.accessibilityIdentifier = "l2.chat.back"
        b.accessibilityLabel = L2T("l2.chat.back", "Назад")
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        let pad = UIView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 4).isActive = true
        g.content.addArrangedSubview(b)
        if compact {
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        } else {
            g.content.addArrangedSubview(pad)
        }
        g.heightAnchor.constraint(equalToConstant: 38).isActive = true
        if compact { g.widthAnchor.constraint(equalToConstant: 38).isActive = true }
        return g
    }

    /// Справа: 📞 📹 ⏱ 🔍 (по chatHeader.buttons) в одной пилюле.
    func linia2RightCapsule() -> UIView? {
        var buttons: [UIButton] = []
        let calls = (topic?.callsAllowed ?? false) && Linia2Config.shared.feature("calls")
        for id in Linia2Chrome.headerButtons {
            switch id {
            case "call" where calls:
                buttons.append(L2GlassView.iconButton("phone", id: "l2.chat.call", label: "Аудиозвонок") { [weak self] in
                    self?.navBarCallTapped(sender: UIMenuController.shared)
                })
            case "video" where calls && Linia2Config.shared.feature("videoCalls"):
                buttons.append(L2GlassView.iconButton("video", id: "l2.chat.video", label: "Видеозвонок") { [weak self] in
                    self?.navBarVideoCallTapped(sender: UIBarButtonItem())
                })
            case "burn":
                if let b = linia2BurnButton() { buttons.append(b) }
            case "search" where Linia2Chrome.searchOn:
                buttons.append(L2GlassView.iconButton("magnifyingglass", id: "l2.chat.search", label: L2T("l2.search.title", "Поиск по чату")) { [weak self] in
                    self?.linia2StartSearch()
                })
            case "more":
                buttons.append(L2GlassView.iconButton("ellipsis", id: "l2.chat.more", label: "Информация о чате") { [weak self] in
                    guard let self = self, !(self.topic?.deleted ?? false) else { return }
                    self.performSegue(withIdentifier: "Messages2TopicInfo", sender: nil)
                })
            default:
                break
            }
        }
        guard !buttons.isEmpty else { return nil }
        let g = L2GlassView(insets: UIEdgeInsets(top: 2, left: 3, bottom: 2, right: 3))
        buttons.forEach { g.content.addArrangedSubview($0) }
        g.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return g
    }

    /// ⏱ кнопкой (для пилюли): серый — выкл., красный на розовом — вкл.
    func linia2BurnButton() -> UIButton? {
        guard Linia2Burn.featureOn, let t = topic, t.isP2PType, t.isWriter else { return nil }
        let on = Linia2Burn.isOn(t.name)
        let b = L2GlassView.iconButton(on ? "timer.circle.fill" : "timer", id: "l2.chat.burn",
                                       label: on ? "Исчезающие сообщения включены" : "Исчезающие сообщения выключены") { [weak self] in
            self?.linia2BurnTapped(nil)
        }
        b.tintColor = on ? L2.hex(0xFF5A5F) : L2.textPrimary
        b.backgroundColor = on ? L2.hex(0xFF5A5F, 0.14) : .clear
        b.accessibilityValue = on ? "включено" : "выключено"
        return b
    }

    /// Прозрачная шапка: видны фон чата и «плавающие» пилюли.
    func linia2ApplyFloatingAppearance() {
        let a = UINavigationBarAppearance()
        a.configureWithTransparentBackground()
        a.shadowColor = .clear
        navigationItem.standardAppearance = a
        navigationItem.scrollEdgeAppearance = a
        navigationItem.compactAppearance = a
        navigationItem.hidesBackButton = true
        navigationItem.leftItemsSupplementBackButton = false
    }

    /// Один фон чата с лёгким узором-пульсом (под шапкой, лентой и строкой ввода — без полос).
    func linia2InstallChatBackground() {
        let alpha = Linia2Chrome.patternOpacity
        view.viewWithTag(Self.kL2PatternTag)?.removeFromSuperview()
        collectionView?.backgroundColor = alpha > 0 || Linia2Chrome.floatingInput ? .clear : L2.background
        guard alpha > 0 else { return }
        let v = UIView()
        v.tag = Self.kL2PatternTag
        v.isUserInteractionEnabled = false
        v.accessibilityIdentifier = "l2.chat.pattern"
        v.backgroundColor = UIColor(patternImage: Linia2Chrome.pulseTile(color: L2.textPrimary.resolvedColor(with: traitCollection)))
        v.alpha = alpha
        v.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(v, at: 0)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Свайп от края — назад (своя кнопка «Назад» выключает системный).
    func linia2EnablePopGesture() {
        guard Linia2Chrome.floatingHeader, let nav = navigationController, let g = nav.interactivePopGestureRecognizer else { return }
        if g.delegate !== Linia2PopGesture.shared {
            linia2SavedPopDelegate = g.delegate
            Linia2PopGesture.shared.nav = nav
            g.delegate = Linia2PopGesture.shared
        }
        g.isEnabled = true
    }

    func linia2RestorePopGesture() {
        guard let g = navigationController?.interactivePopGestureRecognizer, g.delegate === Linia2PopGesture.shared else { return }
        g.delegate = linia2SavedPopDelegate
        linia2SavedPopDelegate = nil
    }
}

// MARK: - Поиск по чату

final class Linia2ChatSearch: NSObject, UITextFieldDelegate {
    weak var vc: MessageViewController?
    let bar = L2GlassView(radius: 20, insets: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 6))
    let field = UITextField()
    let counter = UILabel()
    private var up: UIButton!
    private var down: UIButton!
    /// Совпадения — seq, от новых к старым.
    private(set) var matches: [Int] = []
    private(set) var index = 0
    private var query = ""
    private var debounce: DispatchWorkItem?
    private var loadingMore = false
    private var autoLoads = 0

    init(vc: MessageViewController) {
        self.vc = vc
        super.init()
        let icon = UIImageView(image: L2.symbol("magnifyingglass", 15, .medium))
        icon.tintColor = L2.textSecondary
        icon.setContentHuggingPriority(.required, for: .horizontal)
        field.placeholder = L2T("l2.search.placeholder", "Поиск в чате")
        field.font = L2.font(16)
        field.textColor = L2.textPrimary
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.delegate = self
        field.accessibilityIdentifier = "l2.search.field"
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        counter.font = L2.font(13, .medium)
        counter.textColor = L2.textSecondary
        counter.accessibilityIdentifier = "l2.search.counter"
        counter.setContentHuggingPriority(.required, for: .horizontal)
        counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        up = L2GlassView.iconButton("chevron.up", id: "l2.search.up", label: "Предыдущее (старее)", size: 32) { [weak self] in self?.older() }
        down = L2GlassView.iconButton("chevron.down", id: "l2.search.down", label: "Следующее (новее)", size: 32) { [weak self] in self?.newer() }
        let close = L2GlassView.iconButton("xmark", id: "l2.search.close", label: "Закрыть поиск", size: 32) { [weak self] in self?.dismiss() }
        for v in [icon, field, counter, up!, down!, close] as [UIView] { bar.content.addArrangedSubview(v) }
        bar.content.spacing = 6
        bar.accessibilityIdentifier = "l2.search.bar"
        updateCounter()
    }

    func show(in view: UIView) {
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        bar.alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.bar.alpha = 1
            self.setPinnedHidden(true)
        }
        field.becomeFirstResponder()
    }

    func dismiss() {
        field.resignFirstResponder()
        vc?.linia2Search = nil   // до раскладки: плашка «Закреплённое» снова видна
        UIView.animate(withDuration: 0.2, animations: {
            self.bar.alpha = 0
            self.setPinnedHidden(false)
        }, completion: { _ in self.bar.removeFromSuperview() })
    }

    /// Дизайн: строка поиска встаёт на место плашки «Закреплённое» — плашку на время поиска прячем (не накладываются).
    private func setPinnedHidden(_ hidden: Bool) {
        guard let cv = vc?.collectionView else { return }
        for v in cv.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) { v.alpha = hidden ? 0 : 1 }
        cv.collectionViewLayout.invalidateLayout()
    }

    @objc private func changed() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.run(keepSeq: nil) }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if matches.isEmpty && !query.isEmpty { loadMore() } else { textField.resignFirstResponder() }
        return true
    }

    /// Совпадения по загруженной ленте (без учёта регистра); keepSeq — остаться на этом сообщении.
    func run(keepSeq: Int?) {
        guard let vc = vc else { return }
        query = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            matches = []
            index = 0
            updateCounter()
            return
        }
        var found: [Int] = []
        for m in vc.messages.reversed() where m.seqId > 0 && !m.isDeleted && !vc.linia2IsServiceMessage(m) {
            guard let text = m.content?.string, text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            found.append(m.seqId)
        }
        matches = found
        if let k = keepSeq, let i = found.firstIndex(of: k) { index = i } else { index = 0 }
        updateCounter()
        if keepSeq == nil {
            if let seq = current { vc.scrollToAndAnimate(seqId: seq) } else if autoLoads < 3 { autoLoads += 1; loadMore() }
        }
    }

    private var current: Int? { index < matches.count ? matches[index] : nil }

    private func older() {
        guard let vc = vc else { return }
        if index + 1 < matches.count {
            index += 1
            updateCounter()
            if let seq = current { vc.scrollToAndAnimate(seqId: seq) }
        } else {
            loadMore()   // дальше — в ещё не загруженной истории
        }
    }

    private func newer() {
        guard let vc = vc, index > 0 else { return }
        index -= 1
        updateCounter()
        if let seq = current { vc.scrollToAndAnimate(seqId: seq) }
    }

    /// Догрузить историю и искать дальше (страница за страницей).
    private func loadMore() {
        guard let vc = vc, !loadingMore, !query.isEmpty else { return }
        let first = vc.messages.first?.seqId ?? 0
        guard first > 1 else { updateCounter(); return }
        loadingMore = true
        counter.text = L2T("l2.search.loading", "Ищу в истории…")
        let before = matches.count
        let keep = current
        vc.interactor?.loadPreviousPage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let vc = self.vc else { return }
            self.loadingMore = false
            self.run(keepSeq: keep)
            if self.matches.count > before {
                // Появились более старые совпадения — перейти к следующему старому.
                self.index = keep == nil ? 0 : min(self.matches.count - 1, self.index + 1)
                self.updateCounter()
                if let seq = self.current { vc.scrollToAndAnimate(seqId: seq) }
            } else if (vc.messages.first?.seqId ?? 0) < first && self.autoLoads < 6 {
                self.autoLoads += 1
                self.loadMore()   // в этой странице нет — ещё одну
            }
        }
    }

    private func updateCounter() {
        if query.isEmpty {
            counter.text = ""
        } else if matches.isEmpty {
            counter.text = L2T("l2.search.none", "Нет совпадений")
        } else {
            counter.text = L2T("l2.search.counter", "{i} из {n}")
                .replacingOccurrences(of: "{i}", with: String(index + 1))
                .replacingOccurrences(of: "{n}", with: String(matches.count))
        }
        counter.accessibilityLabel = counter.text
        up?.isEnabled = !matches.isEmpty || !query.isEmpty
        down?.isEnabled = index > 0
    }
}

extension MessageViewController {
    @objc func linia2StartSearch() {
        if let s = linia2Search { s.field.becomeFirstResponder(); return }
        let s = Linia2ChatSearch(vc: self)
        linia2Search = s
        s.show(in: view)
    }
}

// MARK: - «Избранное» (slf) сверху списка чатов

extension ChatListViewController {
    /// Строка «Избранное» над списком (как закреплённый чат), id l2.chats.saved.
    func linia2SavedRow() -> UIView {
        let v = UIControl()
        v.accessibilityIdentifier = "l2.chats.saved"
        v.isAccessibilityElement = true
        v.accessibilityTraits = .button
        v.accessibilityLabel = Linia2Chrome.savedTitle
        let icon = UIImageView(image: L2.symbol("bookmark.fill", 22, .semibold))
        icon.tintColor = L2.onAccent
        icon.contentMode = .center
        icon.backgroundColor = L2.accent
        icon.layer.cornerRadius = 28
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56)])
        let title = UILabel()
        title.text = Linia2Chrome.savedTitle
        title.font = L2.font(18, .semibold)
        title.textColor = L2.textPrimary
        let sub = UILabel()
        sub.text = Linia2Chrome.savedSubtitle
        sub.font = L2.font(15)
        sub.textColor = L2.textSecondary
        let pin = UIImageView(image: L2.symbol("pin.fill", 12, .semibold))
        pin.tintColor = L2.textSecondary
        pin.setContentHuggingPriority(.required, for: .horizontal)
        let texts = UIStackView(arrangedSubviews: [title, sub])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, texts, pin])
        row.spacing = 14
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(row)
        // Высота как у строки чата (72 + отступ шапки 18 ≈ 88), содержимое — по вертикальному центру.
        let h = v.heightAnchor.constraint(equalToConstant: 72)
        h.priority = .defaultHigh
        NSLayoutConstraint.activate([
            h,
            row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: v.topAnchor, constant: 4),
            row.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        v.addAction(UIAction { [weak self] _ in
            self?.performSegue(withIdentifier: "Chats2Messages", sender: Tinode.kTopicSlf)
        }, for: .touchUpInside)
        return v
    }
}
