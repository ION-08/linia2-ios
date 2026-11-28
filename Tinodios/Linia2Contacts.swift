//
//  Linia2Contacts.swift
//  Линия 2.0: вкладка «Контакты» (список p2p-собеседников с алфавитным индексом) и карточка контакта.
//

import UIKit
import TinodeSDK

// MARK: - Подписка на события Tinode (присутствие, метаданные, вход/разрыв связи)

/// Лёгкий слушатель событий Tinode: на любое значимое событие вызывает `handler` на главном потоке.
/// Частые события склеиваются (не чаще раза в 0,3 с). Tinode держит слушателя сильной ссылкой —
/// не забывайте вызывать `Cache.tinode.removeListener(_:)`.
final class Linia2TinodeListener: TinodeEventListener {
    private let handler: () -> Void
    private var scheduled = false   // меняется только на главном потоке

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.scheduled else { return }
            self.scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.scheduled = false
                self.handler()
            }
        }
    }

    func onLogin(code: Int, text: String) { fire() }
    func onDisconnect(byServer: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String) { fire() }
    func onPresMessage(pres: MsgServerPres?) { fire() }
    func onMetaMessage(meta: MsgServerMeta?) { fire() }
}

// MARK: - Общие помощники для контактов

enum Linia2ContactInfo {
    /// Логин собеседника: псевдоним (alias:) или тег basic:логин, если сервер их прислал.
    static func login(of topic: DefaultComTopic) -> String? {
        if let alias = topic.alias, !alias.isEmpty { return alias }
        if let basic = topic.tagValueByPrefix("basic:"), !basic.isEmpty { return basic }
        return nil
    }

    /// Отображаемое имя.
    static func name(of topic: DefaultComTopic) -> String {
        if let fn = topic.pub?.fn?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty { return fn }
        if let login = login(of: topic) { return login }
        return "Без имени"
    }

    /// L2_LASTSEEN: «был(а) только что» / «был(а) 5 мин назад» / «был(а) сегодня в 10:15» / «был(а) вчера в 22:04» /
    /// «был(а) 27 нояб. в 9:30» (другой год — с годом) / «был(а) недавно» (время неизвестно). Как в вебе (linia2.js l2SeenFmt).
    static func lastSeenText(of topic: DefaultComTopic) -> String {
        return lastSeenText(when: topic.lastSeen?.when)
    }

    static func lastSeenText(when: Date?, now: Date = Date()) -> String {
        guard let when = when else { return "был(а) недавно" }
        return "был(а) " + lastSeenWhen(when, now: now)
    }

    /// Без «был(а)»: «только что», «5 мин назад», «сегодня в 10:15», «вчера в 22:04», «27 нояб. в 9:30».
    static func lastSeenWhen(_ when: Date, now: Date = Date()) -> String {
        let sec = now.timeIntervalSince(when)
        if sec < 60 { return "только что" }
        if sec < 3600 { return "\(Int(sec / 60)) мин назад" }
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        let hm = String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
        if cal.isDate(when, inSameDayAs: now) { return "сегодня в " + hm }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(when, inSameDayAs: y) { return "вчера в " + hm }
        let months = ["янв.", "февр.", "марта", "апр.", "мая", "июня", "июля", "авг.", "сент.", "окт.", "нояб.", "дек."]
        let m = months[max(0, min(11, (c.month ?? 1) - 1))]
        let year = (c.year ?? 0) != cal.component(.year, from: now) ? " \(c.year ?? 0)" : ""
        return "\(c.day ?? 1) \(m)\(year) в " + hm
    }
}

/// L2_LASTSEEN: раз в минуту обновляет «был(а) N мин назад» на видимых экранах (шапка чата, контакты, профиль).
/// Один таймер на всё приложение (с допуском 10 с), слабые ссылки; работа на тике — только смена текста подписей.
protocol Linia2SeenRefreshable: AnyObject {
    func linia2RefreshSeen()
}

final class Linia2SeenTicker {
    static let shared = Linia2SeenTicker()
    private let targets = NSHashTable<AnyObject>.weakObjects()
    private var timer: Timer?

    func register(_ t: Linia2SeenRefreshable) {
        assert(Thread.isMainThread)
        targets.add(t)
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        tm.tolerance = 10
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func tick() {
        let list = targets.allObjects.compactMap { $0 as? Linia2SeenRefreshable }
        if list.isEmpty { timer?.invalidate(); timer = nil; return }
        list.forEach { $0.linia2RefreshSeen() }
    }
}

// MARK: - Ячейка контакта

final class Linia2ContactCell: UITableViewCell {
    static let reuseId = "Linia2ContactCell"

    let avatar = RoundImageView()
    private let dot = UIView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = L2.background
        contentView.backgroundColor = L2.background
        let sel = UIView()
        sel.backgroundColor = L2.surface
        selectedBackgroundView = sel

        avatar.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = L2.online
        dot.layer.cornerRadius = 8
        dot.layer.borderWidth = 2.5
        dot.layer.borderColor = L2.background.cgColor

        nameLabel.font = L2.font(17, .semibold)
        nameLabel.textColor = L2.textPrimary
        subtitleLabel.font = L2.font(15)
        subtitleLabel.textColor = L2.textSecondary
        let texts = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 3
        texts.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatar)
        contentView.addSubview(dot)
        contentView.addSubview(texts)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 52),
            avatar.heightAnchor.constraint(equalToConstant: 52),
            avatar.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            dot.widthAnchor.constraint(equalToConstant: 16),
            dot.heightAnchor.constraint(equalToConstant: 16),
            dot.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 1),
            dot.bottomAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 1),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -28),
            texts.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        separatorInset = UIEdgeInsets(top: 0, left: 86, bottom: 0, right: 0)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(_ topic: DefaultComTopic) {
        let name = Linia2ContactInfo.name(of: topic)
        nameLabel.text = name
        avatar.set(pub: topic.pub, id: topic.name, deleted: topic.deleted)
        let online = topic.online && !topic.deleted
        dot.isHidden = !online
        if online {
            subtitleLabel.text = "в сети"
            subtitleLabel.textColor = L2.online
        } else {
            // L2_LASTSEEN: в списке контактов — когда был(а) в сети (логин — в карточке контакта)
            subtitleLabel.text = Linia2ContactInfo.lastSeenText(of: topic)
            subtitleLabel.textColor = L2.textSecondary
        }
        accessibilityLabel = name + ", " + (subtitleLabel.text ?? "")
    }
}

// MARK: - Экран «Контакты»

final class Linia2ContactsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private struct Section {
        let key: String
        var topics: [DefaultComTopic]
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchField = L2SearchField(placeholder: "Поиск по имени или логину")
    private let addButton = L2CircleButton(symbol: "person.badge.plus", accessibility: "Добавить контакт")
    private var header: L2TableHeader?
    private var headerWidth: CGFloat = 0

    private var allTopics: [DefaultComTopic] = []
    private var sections: [Section] = []
    /// L2_CSEARCH: «Найдены в Линии» — люди с сервера (fnd), которых нет в своих контактах; последняя секция.
    private var found: [Linia2FoundPerson] = []
    private var foundAll: [Linia2FoundPerson] = []
    private var foundQuery = ""
    private var foundBusy = false
    private var foundWork: DispatchWorkItem?
    private var foundGen = 0
    private var foundSection: Int? { found.isEmpty ? nil : sections.count }
    private var listener: Linia2TinodeListener?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 72
        tableView.keyboardDismissMode = .onDrag
        tableView.sectionIndexColor = L2.accent
        tableView.sectionIndexBackgroundColor = .clear
        tableView.sectionIndexTrackingBackgroundColor = L2.accent.withAlphaComponent(0.12)
        tableView.tableFooterView = UIView()
        tableView.contentInset.bottom = Linia2TabBarController.reservedBottom + 20
        tableView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: Linia2TabBarController.reservedBottom, right: 0)
        if #available(iOS 15.0, *) { tableView.sectionHeaderTopPadding = 0 }
        tableView.register(Linia2ContactCell.self, forCellReuseIdentifier: Linia2ContactCell.reuseId)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.accessibilityIdentifier = "l2.contacts.search"
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        header = L2TableHeader([L2Header(title: "Контакты", buttons: [addButton]), searchField])
        header?.install(in: tableView)
        headerWidth = tableView.bounds.width
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.bounds.width > 0, tableView.bounds.width != headerWidth {
            headerWidth = tableView.bounds.width
            header?.install(in: tableView)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        if listener == nil {
            let l = Linia2TinodeListener { [weak self] in self?.reload() }
            listener = l
            Cache.tinode.addListener(l)
        }
        reload()
        Linia2SeenTicker.shared.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if let l = listener {
            Cache.tinode.removeListener(l)
            listener = nil
        }
    }

    // MARK: Данные

    private func reload() {
        let topics = Cache.tinode.getFilteredTopics(filter: { (t: TopicProto) in
            t.topicType == .p2p && !t.deleted && t.isJoiner && Linia2Horizon.isVisible(t)
        }) ?? []
        allTopics = topics.compactMap { $0 as? DefaultComTopic }
        applyFilter()
    }

    private var searchQuery: String {
        var q = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while q.hasPrefix("@") { q.removeFirst() }
        return q
    }

    private func applyFilter() {
        let q = searchQuery
        let filtered = q.isEmpty ? allTopics : allTopics.filter { t in
            Linia2ContactInfo.name(of: t).lowercased().contains(q) ||
                (Linia2ContactInfo.login(of: t)?.lowercased().contains(q) ?? false)
        }

        var groups: [String: [DefaultComTopic]] = [:]
        for t in filtered {
            groups[Self.sectionKey(for: Linia2ContactInfo.name(of: t)), default: []].append(t)
        }
        sections = groups.keys
            .sorted { a, b in
                let ra = Self.rank(a), rb = Self.rank(b)
                return ra != rb ? ra < rb : a < b
            }
            .map { key in
                let sorted = (groups[key] ?? []).sorted {
                    Linia2ContactInfo.name(of: $0).localizedCaseInsensitiveCompare(Linia2ContactInfo.name(of: $1)) == .orderedAscending
                }
                return Section(key: key, topics: sorted)
            }

        let mine = Set(allTopics.map { $0.name })
        found = q.count >= 2 && q == foundQuery ? foundAll.filter { !mine.contains($0.id) } : []
        if !q.isEmpty && sections.isEmpty && found.isEmpty {
            tableView.backgroundView = foundBusy && q.count >= 2
                ? l2EmptyState("Ищем в Линии…", "Поиск по имени, логину и @псевдониму", symbol: "magnifyingglass")
                : l2EmptyState("Ничего не найдено", "Попробуйте изменить запрос", symbol: "magnifyingglass")
        } else if allTopics.isEmpty && found.isEmpty {
            tableView.backgroundView = l2EmptyState("Контактов пока нет",
                                                    "Нажмите «добавить», чтобы найти собеседника по логину",
                                                    symbol: "person.2")
        } else {
            tableView.backgroundView = nil
        }
        tableView.reloadData()
    }

    /// Первая буква имени: А–Я (Ё → Е), A–Z, иначе «#».
    private static func sectionKey(for name: String) -> String {
        guard let ch = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "#" }
        var s = String(ch).uppercased()
        if s == "Ё" { s = "Е" }
        guard s.unicodeScalars.count == 1, let u = s.unicodeScalars.first else { return "#" }
        if (0x0410...0x042F).contains(u.value) || (0x41...0x5A).contains(u.value) { return s }
        return "#"
    }

    /// Порядок секций: кириллица, латиница, «#».
    private static func rank(_ key: String) -> Int {
        guard key != "#", let u = key.unicodeScalars.first else { return 2 }
        return (0x0410...0x042F).contains(u.value) ? 0 : 1
    }

    // MARK: Действия

    @objc private func searchChanged() {
        scheduleRemoteSearch()
        applyFilter()
    }

    /// L2_CSEARCH: от 2 символов — поиск на сервере с задержкой ввода 300 мс (ответ разбирается вне главного потока).
    private func scheduleRemoteSearch() {
        foundWork?.cancel()
        foundGen += 1
        let q = searchQuery
        guard q.count >= 2 else {
            foundBusy = false
            foundAll = []
            foundQuery = ""
            return
        }
        if q == foundQuery && !foundBusy { return }
        foundBusy = true
        let gen = foundGen
        let work = DispatchWorkItem { [weak self] in
            Linia2PeopleSearch.search(q) { [weak self] people in
                guard let self = self, gen == self.foundGen else { return }
                self.foundBusy = false
                self.foundQuery = q
                self.foundAll = people ?? []
                self.applyFilter()
            }
        }
        foundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func addTapped() {
        L2.haptic()
        view.endEditing(true)
        navigationController?.pushViewController(Linia2NewChatViewController(mode: .addContact), animated: true)
    }

    // MARK: UITableViewDataSource / Delegate

    func numberOfSections(in tableView: UITableView) -> Int { sections.count + (found.isEmpty ? 0 : 1) }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == foundSection ? found.count : sections[section].topics.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == foundSection {
            let cell = (tableView.dequeueReusableCell(withIdentifier: Linia2FoundPersonCell.reuseId) as? Linia2FoundPersonCell) ?? Linia2FoundPersonCell(style: .default, reuseIdentifier: Linia2FoundPersonCell.reuseId)
            cell.configure(found[indexPath.row])
            return cell
        }
        guard let cell = tableView.dequeueReusableCell(withIdentifier: Linia2ContactCell.reuseId, for: indexPath) as? Linia2ContactCell else { return UITableViewCell() }
        cell.configure(sections[indexPath.section].topics[indexPath.row])
        return cell
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.count > 1 && found.isEmpty ? sections.map { $0.key } : nil
    }

    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        index
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 30 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let v = UIView()
        v.backgroundColor = L2.background
        let l = UILabel()
        l.text = section == foundSection ? "Найдены в Линии" : sections[section].key
        l.accessibilityIdentifier = section == foundSection ? "l2.contacts.foundHeader" : nil
        l.font = L2.rounded(15, .bold)
        l.textColor = L2.accent
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 22),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        view.endEditing(true)
        if indexPath.section == foundSection {
            L2.haptic()
            Linia2PeopleSearch.open(found[indexPath.row], from: navigationController)
            return
        }
        let topic = sections[indexPath.section].topics[indexPath.row]
        navigationController?.pushViewController(Linia2ContactCardViewController(topicName: topic.name), animated: true)
    }
}

// MARK: - Большая кнопка-плитка (иконка + подпись)

final class L2ActionTile: UIControl {
    init(title: String, symbol: String) {
        super.init(frame: .zero)
        backgroundColor = L2.surface
        layer.cornerRadius = 20
        let icon = UIImageView(image: L2.symbol(symbol, 22, .semibold))
        icon.tintColor = L2.accent
        icon.contentMode = .center
        let label = UILabel()
        label.text = title
        label.font = L2.font(14, .medium)
        label.textColor = L2.textPrimary
        label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            heightAnchor.constraint(equalToConstant: 84),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}

// MARK: - Карточка контакта

final class Linia2ContactCardViewController: UIViewController {
    private let topicName: String
    private let avatar = RoundImageView()
    private let dot = UIView()
    private let nameLabel = UILabel()
    private let loginLabel = UILabel()
    private let statusLabel = UILabel()
    private var listener: Linia2TinodeListener?
    // Жалоба и блокировка (Linia2Report.swift).
    private let reportButton = L2Button("Пожаловаться", kind: .secondary, symbol: "exclamationmark.bubble")
    private let blockButton = L2Button("Заблокировать", kind: .destructive, symbol: "hand.raised")
    private let moderation = UIStackView()

    init(topicName: String) {
        self.topicName = topicName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        navigationItem.largeTitleDisplayMode = .never

        avatar.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = L2.online
        dot.layer.cornerRadius = 13
        dot.layer.borderWidth = 4
        dot.layer.borderColor = L2.background.cgColor
        let avatarBox = UIView()
        avatarBox.translatesAutoresizingMaskIntoConstraints = false
        avatarBox.addSubview(avatar)
        avatarBox.addSubview(dot)
        NSLayoutConstraint.activate([
            avatarBox.widthAnchor.constraint(equalToConstant: 128),
            avatarBox.heightAnchor.constraint(equalToConstant: 128),
            avatar.topAnchor.constraint(equalTo: avatarBox.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: avatarBox.bottomAnchor),
            avatar.leadingAnchor.constraint(equalTo: avatarBox.leadingAnchor),
            avatar.trailingAnchor.constraint(equalTo: avatarBox.trailingAnchor),
            dot.widthAnchor.constraint(equalToConstant: 26),
            dot.heightAnchor.constraint(equalToConstant: 26),
            dot.trailingAnchor.constraint(equalTo: avatarBox.trailingAnchor, constant: -4),
            dot.bottomAnchor.constraint(equalTo: avatarBox.bottomAnchor, constant: -4),
        ])

        nameLabel.font = L2.rounded(28, .bold)
        nameLabel.textColor = L2.textPrimary
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.accessibilityTraits = .header
        loginLabel.font = L2.font(17, .medium)
        loginLabel.textColor = L2.accent
        loginLabel.textAlignment = .center
        statusLabel.font = L2.font(15)
        statusLabel.textColor = L2.textSecondary
        statusLabel.textAlignment = .center

        let write = L2ActionTile(title: "Написать", symbol: "bubble.left.fill")
        let audio = L2ActionTile(title: "Аудио", symbol: "phone.fill")
        let video = L2ActionTile(title: "Видео", symbol: "video.fill")
        write.addTarget(self, action: #selector(writeTapped), for: .touchUpInside)
        audio.addTarget(self, action: #selector(audioTapped), for: .touchUpInside)
        video.addTarget(self, action: #selector(videoTapped), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [write, audio, video])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 12

        let info = UIStackView(arrangedSubviews: [avatarBox, nameLabel, loginLabel, statusLabel])
        info.axis = .vertical
        info.alignment = .center
        info.spacing = 8
        info.setCustomSpacing(18, after: avatarBox)

        reportButton.accessibilityIdentifier = "l2.contact.report"
        blockButton.accessibilityIdentifier = "l2.contact.block"
        reportButton.addTarget(self, action: #selector(reportTapped), for: .touchUpInside)
        blockButton.addTarget(self, action: #selector(blockTapped), for: .touchUpInside)
        moderation.axis = .vertical
        moderation.spacing = 12
        moderation.addArrangedSubview(reportButton)
        moderation.addArrangedSubview(blockButton)

        let stack = UIStackView(arrangedSubviews: [info, actions, moderation])
        stack.axis = .vertical
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if listener == nil {
            let l = Linia2TinodeListener { [weak self] in self?.refresh() }
            listener = l
            Cache.tinode.addListener(l)
        }
        refresh()
        Linia2SeenTicker.shared.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let l = listener {
            Cache.tinode.removeListener(l)
            listener = nil
        }
    }

    private func refresh() {
        guard let topic = Cache.tinode.getTopic(topicName: topicName) as? DefaultComTopic else {
            nameLabel.text = "Контакт"
            loginLabel.isHidden = true
            statusLabel.text = nil
            dot.isHidden = true
            avatar.set(pub: nil, id: topicName, deleted: false)
            moderation.isHidden = true
            return
        }
        moderation.isHidden = !topic.isP2PType
        blockButton.setTitle(Linia2Moderation.isBlocked(topic) ? "Разблокировать" : "Заблокировать", for: .normal)
        nameLabel.text = Linia2ContactInfo.name(of: topic)
        avatar.set(pub: topic.pub, id: topic.name, deleted: topic.deleted)
        avatar.letterTileFont = L2.rounded(48, .semibold)
        if let login = Linia2ContactInfo.login(of: topic) {
            loginLabel.text = "@" + login
            loginLabel.isHidden = false
        } else {
            loginLabel.isHidden = true
        }
        let online = topic.online && !topic.deleted
        dot.isHidden = !online
        statusLabel.text = online ? "в сети" : Linia2ContactInfo.lastSeenText(of: topic)
        statusLabel.textColor = online ? L2.online : L2.textSecondary
    }

    @objc private func writeTapped() {
        L2.haptic()
        Linia2Root.openChat(topicName)
    }

    @objc private func audioTapped() {
        L2.haptic()
        Linia2Root.openChat(topicName, call: .audio)
    }

    @objc private func videoTapped() {
        L2.haptic()
        Linia2Root.openChat(topicName, call: .video)
    }

    @objc private func reportTapped() {
        L2.haptic()
        // Жалоба на профиль: без seq и текста сообщения.
        Linia2Moderation.report(from: self, topic: topicName, reported: topicName, sourceView: reportButton)
    }

    @objc private func blockTapped() {
        L2.haptic()
        guard let topic = Cache.tinode.getTopic(topicName: topicName) as? DefaultComTopic else {
            UiUtils.showToast(message: "Контакт ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        Linia2Moderation.confirmToggleBlock(from: self, topic: topic, sourceView: blockButton) { [weak self] _ in
            self?.refresh()
        }
    }
}

// MARK: - L2_LASTSEEN: обновление «был(а) …» раз в минуту

extension Linia2ContactsViewController: Linia2SeenRefreshable {
    func linia2RefreshSeen() {
        guard viewIfLoaded?.window != nil else { return }
        for case let cell as Linia2ContactCell in tableView.visibleCells {
            guard let ip = tableView.indexPath(for: cell), ip.section < sections.count,
                  ip.row < sections[ip.section].topics.count else { continue }
            cell.configure(sections[ip.section].topics[ip.row])
        }
    }
}

extension Linia2ContactCardViewController: Linia2SeenRefreshable {
    func linia2RefreshSeen() {
        guard viewIfLoaded?.window != nil else { return }
        refresh()
    }
}
