//
//  Linia2Calls.swift
//  Линия 2.0: вкладка «Звонки» — журнал звонков из локальной БД, фильтр «Пропущенные»,
//  перезвон по тапу, новый звонок и «Создать ссылку».
//

import UIKit
import TinodeSDK
import TinodiosDB

// MARK: - Модель строки журнала

private struct Linia2CallItem {
    enum Direction { case outgoing, incoming }

    let topicName: String
    let seq: Int
    let date: Date
    let direction: Direction
    let isVideo: Bool
    let state: MsgServerData.WebRTC?
    /// Длительность разговора в секундах (если звонок состоялся).
    let duration: Int?
    /// Гостевой звонок по ссылке: имя гостя и название ссылки.
    let guest: (name: String, link: String)?

    /// Пропущенный входящий: собеседник звонил, а разговор не состоялся —
    /// состояние `missed` (не ответили) или `busy` (были заняты другим звонком).
    /// `declined` (сами отклонили) пропущенным не считаем: показываем как «Отклонённый звонок».
    var isMissed: Bool {
        direction == .incoming && (state == .kMissed || state == .kBusy)
    }

    var isDeclinedIncoming: Bool {
        direction == .incoming && state == .kDeclined
    }

    init?(message m: StoredMessage) {
        guard let topic = m.topic, !topic.isEmpty, let state = m.webrtcCallState else { return nil }
        topicName = topic
        seq = m.seqId
        date = m.ts ?? Date.distantPast
        // Исходящий — если звонок начали мы (автор исходного сообщения). Неотправленное сообщение без from — тоже наше.
        if let from = m.from, !from.isEmpty {
            direction = Cache.tinode.isMe(uid: from) ? .outgoing : .incoming
        } else {
            direction = .outgoing
        }
        isVideo = !m.isAudioOnlyCall
        self.state = state
        duration = Linia2CallItem.durationSeconds(m.head?["webrtc-duration"])
        if Linia2GuestLinks.isGuest(topic) || m.head?["linia2-guest"] != nil {
            guest = Linia2GuestLinks.info(fromHead: m.head, seq: m.seqId) ?? (name: "Гость по ссылке", link: "")
        } else {
            guest = nil
        }
    }

    /// `webrtc-duration` хранится в миллисекундах; JSON-число может прийти как int, int64, double или строка.
    private static func durationSeconds(_ v: JSONValue?) -> Int? {
        guard let v = v else { return nil }
        var ms: Double?
        switch v {
        case .int(let x): ms = Double(x)
        case .int64(let x): ms = Double(x)
        case .double(let x): ms = x
        case .string(let s): ms = Double(s)
        default: ms = nil
        }
        guard let value = ms, value > 0 else { return nil }
        return Int((value / 1000).rounded())
    }
}

// MARK: - Экран «Звонки»

final class Linia2CallsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private static let historyLimit = 200

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let chips = L2Chips(["Все", "Пропущенные"])
    private lazy var newCallButton = L2CircleButton(symbol: "phone.badge.plus", accessibility: "Новый звонок")
    /// LINIA2: «Ссылка на звонок» — круглая кнопка рядом с «Новый звонок» (флаг features.guestCalls).
    private lazy var guestLinkHeaderButton: L2CircleButton = {
        let b = L2CircleButton(symbol: "link", accessibility: "Ссылка на звонок")
        b.setImage(L2.symbol("link", 44 * 0.42, .light), for: .normal)
        b.tintColor = Linia2GuestLinkCreateViewController.mint
        b.accessibilityIdentifier = "l2.calls.createGuestLink"
        b.addTarget(self, action: #selector(createGuestLinkTapped), for: .touchUpInside)
        return b
    }()
    private lazy var header: L2TableHeader = {
        let top = L2Header(title: "Звонки", buttons: [guestLinkHeaderButton, newCallButton])
        return L2TableHeader([top, chips], spacing: 18)
    }()
    private lazy var emptyView = l2EmptyState("Звонков пока нет",
                                              "Здесь появятся входящие, исходящие и пропущенные звонки",
                                              symbol: "phone")

    private var allItems: [Linia2CallItem] = []
    private var items: [Linia2CallItem] = []
    private var lastHeaderWidth: CGFloat = 0
    private var loadGeneration = 0
    private var configObserver: NSObjectProtocol?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE"
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM"
        return f
    }()

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 20 + 56 + 14, bottom: 0, right: 20)
        tableView.rowHeight = 86
        tableView.estimatedRowHeight = 86
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(Linia2CallCell.self, forCellReuseIdentifier: Linia2CallCell.reuseId)
        tableView.contentInset.bottom = Linia2TabBarController.reservedBottom + 20
        tableView.verticalScrollIndicatorInsets.bottom = Linia2TabBarController.reservedBottom + 20
        if #available(iOS 15.0, *) { tableView.sectionHeaderTopPadding = 0 }
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        newCallButton.addTarget(self, action: #selector(newCallTapped), for: .touchUpInside)
        chips.onChange = { [weak self] _ in self?.applyFilter() }

        // Пустое состояние: текстовая кнопка «Создать ссылку на звонок» под подписью.
        if let s = emptyView.subviews.first as? UIStackView {
            s.setCustomSpacing(18, after: s.arrangedSubviews.last ?? s)
            s.addArrangedSubview(emptyLinkButton)
        }
        installGuestButtons()
        configObserver = NotificationCenter.default.addObserver(forName: Linia2Config.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.installGuestButtons()
        }

        header.install(in: tableView)

        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = tableView.bounds.width
        if w > 0 && w != lastHeaderWidth {
            lastHeaderWidth = w
            header.install(in: tableView)
            tableView.tableFooterView = UIView()
        }
    }

    /// LINIA2: подвал больше не нужен (ссылка на профиль — в листе «Ссылка на звонок»);
    /// кнопка ссылки в шапке и в пустом состоянии — по флагу features.guestCalls.
    private func installGuestButtons() {
        guestLinkHeaderButton.isHidden = !Linia2GuestLinks.enabled
        emptyLinkButton.isHidden = !Linia2GuestLinks.enabled
        tableView.tableFooterView = UIView()
    }

    private lazy var emptyLinkButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Создать ссылку на звонок", for: .normal)
        b.titleLabel?.font = L2.font(16, .semibold)
        b.titleLabel?.numberOfLines = 0
        b.titleLabel?.textAlignment = .center
        b.setTitleColor(Linia2GuestLinkCreateViewController.mint, for: .normal)
        b.accessibilityIdentifier = "l2.calls.emptyGuestLink"
        b.addTarget(self, action: #selector(createGuestLinkTapped), for: .touchUpInside)
        return b
    }()

    @objc private func createGuestLinkTapped() {
        L2.haptic()
        Linia2GuestLinkCreateViewController.presentSheet(from: self)
    }

    @objc private func appWillEnterForeground() {
        if viewIfLoaded?.window != nil { reload() }
    }

    // MARK: Данные

    private func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let limit = Linia2CallsViewController.historyLimit
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let messages = BaseDb.sharedInstance.messageDb?.queryRecentCalls(limit: limit) ?? []
            DispatchQueue.main.async {
                guard let self = self, generation == self.loadGeneration else { return }
                self.allItems = messages.compactMap { Linia2CallItem(message: $0) }
                self.applyFilter()
            }
        }
    }

    private func applyFilter() {
        items = chips.selected == 1 ? allItems.filter { $0.isMissed } : allItems
        tableView.reloadData()
        tableView.backgroundView = items.isEmpty ? emptyView : nil
    }

    private func topic(_ name: String) -> DefaultComTopic? {
        Cache.tinode.getTopic(topicName: name) as? DefaultComTopic
    }

    // MARK: Таблица

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.row < items.count,
              let cell = tableView.dequeueReusableCell(withIdentifier: Linia2CallCell.reuseId, for: indexPath) as? Linia2CallCell else { return UITableViewCell() }
        let item = items[indexPath.row]
        let t = topic(item.topicName)
        cell.configure(item: item, pub: t?.pub, timeText: Linia2CallsViewController.timeText(item.date))
        // L2_CALLINFO: ⓘ — лист «О звонке» (раньше открывался чат).
        cell.onInfo = { [weak self] in self?.showInfo(item) }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 86 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < items.count else { return }
        let item = items[indexPath.row]
        L2.haptic()
        if item.guest != nil {
            // Гостю перезвонить нельзя — открыть «Мои ссылки».
            navigationController?.pushViewController(Linia2GuestLinksViewController(), animated: true)
            return
        }
        // Перезвонить тем же типом звонка.
        Linia2Root.openChat(item.topicName, call: item.isVideo ? .video : .audio)
    }

    // MARK: Действия

    private func showInfo(_ item: Linia2CallItem) {
        let t = topic(item.topicName)
        let blocked = t.map { Linia2Moderation.isBlocked($0) } ?? false
        let info = Linia2CallInfoViewController(item: item, pub: t?.pub, blocked: blocked)
        info.onAction = { [weak self] action in
            switch action {
            case .audio: Linia2Root.openChat(item.topicName, call: .audio)
            case .video: Linia2Root.openChat(item.topicName, call: .video)
            case .chat: Linia2Root.openChat(item.topicName)
            case .links: self?.navigationController?.pushViewController(Linia2GuestLinksViewController(), animated: true)
            }
        }
        present(info, animated: true)
    }

    @objc private func newCallTapped() {
        L2.haptic()
        let picker = Linia2CallContactPicker(style: .plain)
        picker.onPick = { [weak self] topicName, kind in
            self?.dismiss(animated: true) {
                Linia2Root.openChat(topicName, call: kind)
            }
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.overrideUserInterfaceStyle = .dark
        present(nav, animated: true)
    }

    // MARK: Время справа

    /// Сегодня — «HH:mm», вчера — «Вчера», в пределах недели — «Пн», иначе «dd.MM».
    private static func timeText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeFormatter.string(from: date) }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let startOfToday = cal.startOfDay(for: Date())
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < startOfToday {
            let s = weekdayFormatter.string(from: date).replacingOccurrences(of: ".", with: "")
            return s.prefix(1).uppercased() + String(s.dropFirst())
        }
        return dateFormatter.string(from: date)
    }
}

// MARK: - Ячейка звонка

private final class Linia2CallCell: UITableViewCell {
    static let reuseId = "Linia2CallCell"

    var onInfo: (() -> Void)?

    private let avatar = RoundImageView()
    private let lettersLabel = UILabel()
    private let nameLabel = UILabel()
    private let kindIcon = UIImageView()
    private let detailLabel = UILabel()
    private let timeLabel = UILabel()
    private let infoButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = L2.background
        contentView.backgroundColor = L2.background
        let selected = UIView()
        selected.backgroundColor = L2.surface
        selectedBackgroundView = selected

        avatar.translatesAutoresizingMaskIntoConstraints = false
        lettersLabel.translatesAutoresizingMaskIntoConstraints = false
        lettersLabel.font = L2.font(20, .semibold)
        lettersLabel.textColor = .white
        lettersLabel.textAlignment = .center

        nameLabel.font = L2.font(17, .semibold)
        nameLabel.textColor = L2.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail

        kindIcon.contentMode = .scaleAspectFit
        kindIcon.setContentHuggingPriority(.required, for: .horizontal)
        kindIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = L2.font(15)
        detailLabel.textColor = L2.textSecondary
        detailLabel.lineBreakMode = .byTruncatingTail

        let detailRow = UIStackView(arrangedSubviews: [kindIcon, detailLabel])
        detailRow.axis = .horizontal
        detailRow.alignment = .center
        detailRow.spacing = 8

        let texts = UIStackView(arrangedSubviews: [nameLabel, detailRow])
        texts.axis = .vertical
        texts.spacing = 4
        texts.alignment = .leading   // имя может быть уже строки статуса (справа от имени — время)
        texts.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = L2.font(15)
        timeLabel.textColor = L2.textSecondary
        timeLabel.textAlignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        infoButton.setImage(L2.symbol("info.circle", 22, .regular), for: .normal)
        infoButton.tintColor = L2.textPrimary
        infoButton.accessibilityLabel = "О звонке"
        infoButton.accessibilityIdentifier = "l2.calls.info"
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.addTarget(self, action: #selector(infoTapped), for: .touchUpInside)

        contentView.addSubview(avatar)
        contentView.addSubview(lettersLabel)
        contentView.addSubview(texts)
        contentView.addSubview(timeLabel)
        contentView.addSubview(infoButton)

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 56),
            avatar.heightAnchor.constraint(equalToConstant: 56),
            lettersLabel.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            lettersLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),

            infoButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            infoButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 44),
            infoButton.heightAnchor.constraint(equalToConstant: 44),

            timeLabel.trailingAnchor.constraint(equalTo: infoButton.leadingAnchor, constant: -8),
            timeLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor, constant: 2),

            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            texts.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            // Дизайн: время — только в строке имени; строка «Видеозвонок · Нет ответа» идёт до кнопки (i)
            // (на SE обрезалась до «Не…»).
            texts.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            kindIcon.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        // Не даём системе перекрашивать фон аватара-заглушки при подсветке.
        if !avatarHasPhoto { avatar.backgroundColor = avatarColor }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        if !avatarHasPhoto { avatar.backgroundColor = avatarColor }
    }

    private var avatarHasPhoto = false
    private var avatarColor: UIColor = L2.surface

    @objc private func infoTapped() {
        L2.haptic()
        onInfo?()
    }

    func configure(item: Linia2CallItem, pub: TheCard?, timeText: String) {
        var name = (pub?.fn?.isEmpty == false ? pub?.fn : nil) ?? "Неизвестный контакт"
        if let g = item.guest { name = "🔗 " + g.name }
        nameLabel.text = name
        timeLabel.text = timeText

        // Аватар: фото из pub.photo (через RoundImageView), иначе — буквы на цветном круге в стиле Линии 2.0.
        // Дизайн: как в чатах и контактах — та же плитка (цвет и одна буква), а не своя «ДС» другого цвета.
        if pub?.photo != nil || (item.guest == nil && pub != nil) {
            avatarHasPhoto = true
            lettersLabel.isHidden = true
            avatar.set(pub: pub, id: item.topicName, deleted: false)
        } else {
            avatarHasPhoto = false
            avatarColor = L2Avatar.color(for: item.topicName)
            avatar.initials = nil
            avatar.image = nil
            avatar.backgroundColor = avatarColor
            lettersLabel.isHidden = false
            lettersLabel.text = L2Avatar.letters(for: pub?.fn)
        }

        // Строка типа звонка.
        let kind = item.isVideo ? "Видеозвонок" : "Аудиозвонок"
        let symbol: String
        let iconColor: UIColor
        var text: String
        var textColor = L2.textSecondary
        if item.isMissed {
            symbol = "phone.arrow.down.left"
            iconColor = L2.danger
            text = "Пропущенный звонок"
            textColor = L2.danger
        } else if item.isDeclinedIncoming {
            symbol = "phone.down"
            iconColor = L2.danger
            text = "Отклонённый звонок"
        } else {
            if item.isVideo {
                symbol = "video"
                iconColor = L2.textPrimary
            } else if item.direction == .outgoing {
                symbol = "arrow.up.right"
                iconColor = L2.callOutgoing
            } else {
                symbol = "arrow.down.left"
                iconColor = L2.accent
            }
            text = kind
            if let d = item.duration {
                text += " · " + String(format: "%d:%02d", d / 60, d % 60)
            } else if item.direction == .outgoing {
                switch item.state {
                case .kMissed?: text += " · Нет ответа"
                case .kDeclined?: text += " · Отклонён"
                case .kBusy?: text += " · Занято"
                default: break
                }
            }
        }
        if let g = item.guest {
            text += g.link.isEmpty ? " · по ссылке" : " · по ссылке «\(g.link)»"
        }
        kindIcon.image = L2.symbol(symbol, 15, .semibold)
        kindIcon.tintColor = iconColor
        detailLabel.text = text
        detailLabel.textColor = textColor

        let dir = item.direction == .outgoing ? "исходящий" : "входящий"
        accessibilityLabel = "\(name), \(text), \(dir), \(timeText)"
    }
}

// MARK: - L2_CALLINFO: лист «О звонке» (как в вебе apply-callinfo.py)

private final class Linia2CallInfoViewController: UIViewController {
    enum Action { case audio, video, chat, links }
    var onAction: ((Action) -> Void)?

    private let item: Linia2CallItem
    private let pub: TheCard?
    private let blocked: Bool

    private static let whenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM y 'г.', HH:mm"
        return f
    }()

    init(item: Linia2CallItem, pub: TheCard?, blocked: Bool) {
        self.item = item
        self.pub = pub
        self.blocked = blocked
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { return nil }

    /// «2:05», «1:02:05»; без разговора — «—».
    static func durationText(_ secs: Int?) -> String {
        guard let d = secs, d > 0 else { return "—" }
        let h = d / 3600, m = d % 3600 / 60, s = d % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        view.accessibilityIdentifier = "l2.callinfo.sheet"

        let title = UILabel()
        title.text = "О звонке"
        title.font = L2.font(18, .bold)
        title.textColor = L2.textPrimary
        title.accessibilityIdentifier = "l2.callinfo.title"
        title.accessibilityTraits = .header
        let close = UIButton(type: .system)
        close.setImage(L2.symbol("xmark", 15, .bold), for: .normal)
        close.tintColor = L2.textSecondary
        close.backgroundColor = L2.surface
        close.layer.cornerRadius = 15
        close.accessibilityLabel = "Закрыть"
        close.accessibilityIdentifier = "l2.callinfo.close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        // Аватар и имя.
        let avatar = RoundImageView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 72).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 72).isActive = true
        var name = (pub?.fn?.isEmpty == false ? pub?.fn : nil) ?? "Неизвестный контакт"
        if let g = item.guest { name = "🔗 " + g.name }
        if pub?.photo != nil || (item.guest == nil && pub != nil) {
            avatar.set(pub: pub, id: item.topicName, deleted: false)
            avatar.letterTileFont = L2.rounded(28, .semibold)
        } else {
            avatar.initials = nil
            avatar.image = nil
            avatar.backgroundColor = L2Avatar.color(for: item.topicName)
            let letters = UILabel()
            letters.text = L2Avatar.letters(for: pub?.fn)
            letters.font = L2.font(26, .semibold)
            letters.textColor = .white
            letters.textAlignment = .center
            letters.translatesAutoresizingMaskIntoConstraints = false
            avatar.addSubview(letters)
            NSLayoutConstraint.activate([
                letters.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
                letters.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            ])
        }
        avatar.isAccessibilityElement = false
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = L2.font(19, .bold)
        nameLabel.textColor = L2.textPrimary
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.accessibilityIdentifier = "l2.callinfo.name"
        let head = UIStackView(arrangedSubviews: [avatar, nameLabel])
        head.axis = .vertical
        head.alignment = .center
        head.spacing = 10

        // Строки.
        let out = item.direction == .outgoing
        let dir: String
        if item.guest != nil { dir = "Звонок по ссылке" }
        else if item.isMissed { dir = "Пропущенный" }
        else if item.isDeclinedIncoming { dir = "Отклонённый" }
        else { dir = out ? "Исходящий" : "Входящий" }
        var res = ""
        if out && (item.duration ?? 0) == 0 {
            switch item.state {
            case .kMissed?: res = "нет ответа"
            case .kDeclined?: res = "отклонён"
            case .kBusy?: res = "занято"
            default: break
            }
        }
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 0
        rows.backgroundColor = L2.surface
        rows.layer.cornerRadius = 14
        rows.isLayoutMarginsRelativeArrangement = true
        rows.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
        func row(_ key: String, _ value: String, id: String, danger: Bool = false) {
            if !rows.arrangedSubviews.isEmpty {
                let line = UIView()
                line.backgroundColor = L2.separator
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                rows.addArrangedSubview(line)
            }
            let k = UILabel()
            k.text = key
            k.font = L2.font(15)
            k.textColor = L2.textSecondary
            k.setContentHuggingPriority(.required, for: .horizontal)
            k.setContentCompressionResistancePriority(.required, for: .horizontal)
            let v = UILabel()
            v.text = value
            v.font = L2.font(15, .semibold)
            v.textColor = danger ? L2.danger : L2.textPrimary
            v.textAlignment = .right
            v.numberOfLines = 0
            v.accessibilityIdentifier = id
            let r = UIStackView(arrangedSubviews: [k, v])
            r.axis = .horizontal
            r.spacing = 12
            r.alignment = .firstBaseline
            r.isLayoutMarginsRelativeArrangement = true
            r.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            r.isAccessibilityElement = true
            r.accessibilityLabel = key + ": " + value
            r.accessibilityIdentifier = id + ".row"
            rows.addArrangedSubview(r)
        }
        row("Тип", item.isVideo ? "Видеозвонок" : "Аудиозвонок", id: "l2.callinfo.type")
        row("Звонок", dir + (res.isEmpty ? "" : " · " + res), id: "l2.callinfo.dir", danger: item.isMissed)
        if item.date > Date.distantPast {
            row("Дата и время", Self.whenFormatter.string(from: item.date), id: "l2.callinfo.when")
        }
        row("Длительность", Self.durationText(item.duration), id: "l2.callinfo.duration")

        // Кнопки.
        let acts = UIStackView()
        acts.axis = .horizontal
        acts.spacing = 10
        acts.distribution = .fillEqually
        func act(_ symbol: String, _ label: String, id: String, _ action: Action) {
            var cfg = UIButton.Configuration.filled()
            cfg.baseBackgroundColor = L2.surface
            cfg.baseForegroundColor = L2.accent
            cfg.image = L2.symbol(symbol, 20, .semibold)
            cfg.imagePlacement = .top
            cfg.imagePadding = 6
            cfg.cornerStyle = .large
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 4, bottom: 12, trailing: 4)
            var t = AttributedString(label)
            t.font = L2.font(13, .semibold)
            t.foregroundColor = L2.textPrimary
            cfg.attributedTitle = t
            let b = UIButton(configuration: cfg)
            b.accessibilityIdentifier = id
            b.accessibilityLabel = label
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
            b.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                L2.haptic()
                let cb = self.onAction
                self.dismiss(animated: true) { cb?(action) }
            }, for: .touchUpInside)
            acts.addArrangedSubview(b)
        }
        var note: UILabel?
        if item.guest == nil && Linia2Config.shared.feature("calls") {
            if blocked {
                let n = UILabel()
                n.text = "Собеседник заблокирован — позвонить нельзя."
                n.font = L2.font(15)
                n.textColor = L2.textSecondary
                n.textAlignment = .center
                n.numberOfLines = 0
                n.accessibilityIdentifier = "l2.callinfo.blocked"
                note = n
            } else {
                act("phone.fill", "Позвонить", id: "l2.callinfo.call", .audio)
                if Linia2Config.shared.feature("videoCalls") { act("video.fill", "Видео", id: "l2.callinfo.video", .video) }
            }
        }
        if item.guest != nil {
            act("link", "Мои ссылки", id: "l2.callinfo.links", .links)
        } else {
            act("bubble.left.fill", "Написать", id: "l2.callinfo.chat", .chat)
        }

        var parts: [UIView] = [head, rows]
        if let n = note { parts.append(n) }
        parts.append(acts)
        let content = UIStackView(arrangedSubviews: parts)
        content.axis = .vertical
        content.spacing = 18
        content.setCustomSpacing(20, after: head)
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        for v in [title, close, scroll] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            close.widthAnchor.constraint(equalToConstant: 30),
            close.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }
}

// MARK: - Выбор собеседника для нового звонка

private final class Linia2CallContactPicker: UITableViewController {
    var onPick: ((String, Linia2Root.CallKind) -> Void)?
    private var topics: [DefaultComTopic] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Новый звонок"
        view.backgroundColor = L2.background
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 20 + 44 + 14, bottom: 0, right: 0)
        tableView.rowHeight = 64
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))

        topics = (Cache.tinode.getFilteredTopics(filter: { $0.topicType == .p2p && !$0.isBlocked && Linia2Horizon.isVisible($0) }) ?? [])
            .compactMap { $0 as? DefaultComTopic }
        if topics.isEmpty {
            tableView.backgroundView = l2EmptyState("Нет контактов", "Начните чат с кем-нибудь, чтобы позвонить", symbol: "person.2")
        }
    }

    @objc private func cancel() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { topics.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        let t = topics[indexPath.row]
        cell.backgroundColor = L2.background
        cell.textLabel?.text = (t.pub?.fn?.isEmpty == false ? t.pub?.fn : nil) ?? "Неизвестный контакт"
        cell.textLabel?.font = L2.font(17, .medium)
        cell.textLabel?.textColor = L2.textPrimary
        cell.imageView?.image = L2.symbol("phone", 18, .medium)
        cell.imageView?.tintColor = L2.accent
        let selected = UIView()
        selected.backgroundColor = L2.surface
        cell.selectedBackgroundView = selected
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let t = topics[indexPath.row]
        let name = t.name
        let sheet = UIAlertController(title: t.pub?.fn, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Аудиозвонок", style: .default) { [weak self] _ in
            self?.onPick?(name, .audio)
        })
        if Linia2Config.shared.feature("videoCalls") {
            sheet.addAction(UIAlertAction(title: "Видеозвонок", style: .default) { [weak self] _ in
                self?.onPick?(name, .video)
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        if let pop = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }
}

// MARK: - L2_CALLENC: плашка «🔒 Зашифровано» под статусом звонка (только оформление; WebRTC шифрует медиа всегда — DTLS-SRTP)

private final class Linia2EncryptedBadge: UIView {
    private let label = UILabel()
    private var timer: Timer?
    /// Подсказки о разрешениях кладутся туда же (под статус) — пока они видны, плашку прячем, чтобы не наложилась.
    private static let overlapIds: Set<String> = ["l2.call.permissionHint", "l2.call.micPill"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerRadius = 11
        isUserInteractionEnabled = false
        label.text = "🔒 " + L2T("l2.call.encrypted", "Зашифровано")
        label.font = L2.font(12, .semibold)
        label.textColor = L2.hex(0xC9F2E5)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Зашифровано"
        accessibilityIdentifier = "l2.call.encrypted"
    }

    required init?(coder: NSCoder) { return nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateOverlap() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        updateOverlap()
    }

    private func updateOverlap() {
        guard let sv = superview else { return }
        let covered = sv.subviews.contains { v in
            !v.isHidden && v.alpha > 0.01 && Self.overlapIds.contains(v.accessibilityIdentifier ?? "")
        }
        if isHidden != covered { isHidden = covered }
    }
}

extension CallViewController {
    /// Плашка под строкой статуса (stateLabel); звонковую логику не трогает.
    func linia2AddEncryptedBadge() {
        guard stateLabel.superview === view, !view.subviews.contains(where: { $0 is Linia2EncryptedBadge }) else { return }
        let badge = Linia2EncryptedBadge()
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 6),
            badge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }
}
