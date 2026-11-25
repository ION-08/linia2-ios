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

    /// «был(а) 5 минут назад» / «был(а) недавно».
    static func lastSeenText(of topic: DefaultComTopic) -> String {
        guard let when = topic.lastSeen?.when else { return "был(а) недавно" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .full
        return "был(а) " + f.localizedString(for: when, relativeTo: Date())
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
        } else if let login = Linia2ContactInfo.login(of: topic) {
            subtitleLabel.text = "@" + login
            subtitleLabel.textColor = L2.textSecondary
        } else {
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
            t.topicType == .p2p && !t.deleted && t.isJoiner
        }) ?? []
        allTopics = topics.compactMap { $0 as? DefaultComTopic }
        applyFilter()
    }

    private func applyFilter() {
        var q = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.hasPrefix("@") { q.removeFirst() }
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

        if allTopics.isEmpty {
            tableView.backgroundView = l2EmptyState("Контактов пока нет",
                                                    "Нажмите «добавить», чтобы найти собеседника по логину",
                                                    symbol: "person.2")
        } else if sections.isEmpty {
            tableView.backgroundView = l2EmptyState("Ничего не найдено", "Попробуйте изменить запрос", symbol: "magnifyingglass")
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
        applyFilter()
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

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].topics.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: Linia2ContactCell.reuseId, for: indexPath) as? Linia2ContactCell else { return UITableViewCell() }
        cell.configure(sections[indexPath.section].topics[indexPath.row])
        return cell
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        sections.count > 1 ? sections.map { $0.key } : nil
    }

    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        index
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 30 }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let v = UIView()
        v.backgroundColor = L2.background
        let l = UILabel()
        l.text = sections[section].key
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

        let stack = UIStackView(arrangedSubviews: [info, actions])
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
            return
        }
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
}
