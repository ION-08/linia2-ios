//
//  Linia2NewChat.swift
//  Линия 2.0: экран «Новый чат» / «Добавить контакт» — поиск собеседника на сервере (fnd-топик Tinode),
//  создание группы и приглашение в мессенджер.
//

import UIKit
import TinodeSDK
import TinodiosDB

// MARK: - Модель строки (человек из локальных контактов или из поиска на сервере)

private struct L2NCPerson {
    /// Имя p2p-топика = uid пользователя («usr…»).
    let id: String
    let name: String
    let login: String?
    let subtitle: String?
    let pub: TheCard?
    /// Подписка из ответа fnd-топика (только для найденных на сервере).
    let sub: Subscription<TheCard, [String]>?
}

private struct L2NCSection {
    let title: String
    let people: [L2NCPerson]
}

// MARK: - Слушатель fnd-топика (по образцу FindInteractor.FndListener)

/// Tinode держит слушателя топика слабой ссылкой — экран хранит его сам.
/// `onSubsUpdated` приходит на сетевом потоке: снимок результатов берём там же и передаём на главный поток.
private final class L2NCFndListener: DefaultFndTopic.Listener {
    weak var fnd: DefaultFndTopic?
    var onSubs: (([Subscription<TheCard, [String]>]) -> Void)?

    override func onSubsUpdated() {
        let subs = fnd?.getSubscriptions() ?? []
        let callback = onSubs
        DispatchQueue.main.async { callback?(subs) }
    }
}

// MARK: - Ячейка-карточка (аватар 52, имя, подпись, значок справа)

private final class L2NCCardCell: UITableViewCell {
    static let reuseId = "L2NCCardCell"

    enum Accessory { case none, chevron, check(Bool) }

    private let card = UIView()
    private let avatar = RoundImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let accessoryIcon = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = L2.surface
        card.layer.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        accessoryIcon.translatesAutoresizingMaskIntoConstraints = false
        accessoryIcon.contentMode = .center

        nameLabel.font = L2.font(17, .semibold)
        nameLabel.textColor = L2.textPrimary
        subtitleLabel.font = L2.font(15)
        subtitleLabel.textColor = L2.textSecondary
        let texts = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 3
        texts.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        card.addSubview(avatar)
        card.addSubview(texts)
        card.addSubview(accessoryIcon)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            avatar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 52),
            avatar.heightAnchor.constraint(equalToConstant: 52),
            accessoryIcon.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            accessoryIcon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            accessoryIcon.widthAnchor.constraint(equalToConstant: 28),
            accessoryIcon.heightAnchor.constraint(equalToConstant: 28),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: accessoryIcon.leadingAnchor, constant: -10),
            texts.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        card.backgroundColor = highlighted ? L2.surface2 : L2.surface
    }

    func configure(_ p: L2NCPerson, accessory: Accessory) {
        nameLabel.text = p.name
        subtitleLabel.text = p.subtitle
        subtitleLabel.isHidden = (p.subtitle ?? "").isEmpty
        avatar.set(pub: p.pub, id: p.id, deleted: false)
        card.layer.borderWidth = 0
        card.layer.borderColor = UIColor.clear.cgColor
        accessibilityTraits = .button
        switch accessory {
        case .none:
            accessoryIcon.image = nil
        case .chevron:
            accessoryIcon.image = L2.symbol("chevron.right", 15, .semibold)
            accessoryIcon.tintColor = L2.textSecondary
        case .check(let on):
            accessoryIcon.image = L2.symbol(on ? "checkmark.circle.fill" : "circle", 24, .medium)
            accessoryIcon.tintColor = on ? L2.accent : L2.textSecondary
            if on {
                card.layer.borderWidth = 1.5
                card.layer.borderColor = L2.accent.cgColor
            }
            accessibilityTraits = on ? [.button, .selected] : .button
        }
        accessibilityLabel = p.name + ((p.subtitle ?? "").isEmpty ? "" : ", " + (p.subtitle ?? ""))
    }
}

// MARK: - Экран «Новый чат» / «Добавить контакт»

final class Linia2NewChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    enum Mode { case newChat, addContact }

    private static let minQueryLength = 2          // сервер Tinode отбрасывает теги короче 2 символов
    private static let searchDelay = 0.4
    private static let maxNoteLength = 300

    private let mode: Mode

    // Общие элементы
    private let chips = L2Chips(["Новый чат", "Новая группа", "Пригласить"])
    private let chipsScroll = UIScrollView()
    private let pagesContainer = UIView()

    // Страница 1: поиск
    private let searchPage = UIView()
    private let searchField = L2SearchField(placeholder: "Логин или имя")
    private let hintLabel = UILabel()
    private let searchTable = UITableView(frame: .zero, style: .plain)
    private var searchSections: [L2NCSection] = []
    private var localMatches: [L2NCPerson] = []
    private var remoteAll: [L2NCPerson] = []
    private var searching = false
    private var searchFailed = false
    private var searchGen = 0
    /// Поколение запроса, для которого уже принят ответ setMeta — только его результаты показываем.
    private var acceptGen = -1
    private var pendingSearch: DispatchWorkItem?

    // fnd-топик
    private let fndListener = L2NCFndListener()
    private weak var fndTopic: DefaultFndTopic?
    private var fndAttaching = false
    private var fndReady: ((DefaultFndTopic) -> Void)?
    private var fndFailed: (() -> Void)?

    // Страница 2: новая группа
    private let groupPage = UIView()
    private let groupTable = UITableView(frame: .zero, style: .plain)
    private let groupNameField = L2TextField(placeholder: "Название группы")
    private let groupNoteField = L2TextField(placeholder: "Описание (необязательно)")
    private let membersLabel = UILabel()
    private let createButton = L2Button("Создать группу", kind: .primary)
    private var createButtonBottom: NSLayoutConstraint?
    private var groupHeader: L2TableHeader?
    private var groupHeaderWidth: CGFloat = 0
    private var selectedIds = Set<String>()
    private var isCreatingGroup = false

    // Страница 3: приглашение
    private let invitePage = UIScrollView()
    private let shareButton = L2Button("Поделиться ссылкой", kind: .primary, symbol: "square.and.arrow.up")
    private let copyLoginButton = L2Button("Скопировать мой логин", kind: .outline, symbol: "doc.on.doc")

    // Данные
    private var contacts: [L2NCPerson] = []
    private var keyboardOverlap: CGFloat = 0

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        navigationItem.title = mode == .newChat ? "Новый чат" : "Добавить контакт"
        navigationItem.largeTitleDisplayMode = .never

        fndListener.onSubs = { [weak self] subs in self?.applyRemoteSnapshot(subs) }

        pagesContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pagesContainer)

        if mode == .newChat {
            chipsScroll.translatesAutoresizingMaskIntoConstraints = false
            chipsScroll.showsHorizontalScrollIndicator = false
            chipsScroll.contentInsetAdjustmentBehavior = .never
            chipsScroll.backgroundColor = .clear
            chips.translatesAutoresizingMaskIntoConstraints = false
            chips.onChange = { [weak self] i in self?.showPage(i) }
            view.addSubview(chipsScroll)
            chipsScroll.addSubview(chips)
            NSLayoutConstraint.activate([
                chipsScroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                chipsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                chipsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                chipsScroll.heightAnchor.constraint(equalToConstant: 40),
                chips.topAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.topAnchor),
                chips.bottomAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.bottomAnchor),
                chips.leadingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.leadingAnchor, constant: 20),
                chips.trailingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.trailingAnchor, constant: -20),
                chips.heightAnchor.constraint(equalTo: chipsScroll.frameLayoutGuide.heightAnchor),
                pagesContainer.topAnchor.constraint(equalTo: chipsScroll.bottomAnchor, constant: 16),
            ])
        } else {
            pagesContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8).isActive = true
        }
        NSLayoutConstraint.activate([
            pagesContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pagesContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagesContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        buildSearchPage()
        if mode == .newChat {
            buildGroupPage()
            buildInvitePage()
        }
        showPage(0)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingSearch?.cancel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        loadContacts()
        updateLocalMatches()
        renderSearch()
        if mode == .newChat {
            groupTable.reloadData()
            updateGroupState()
        }
        // Вернулись на экран, а поиск был прерван — повторяем.
        if searching, currentQuery().count >= Linia2NewChatViewController.minQueryLength {
            restartSearch()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pendingSearch?.cancel()
        pendingSearch = nil
        // Отцепляемся от fnd-топика (сам топик не покидаем: им может пользоваться и другой экран).
        if let fnd = fndTopic, fnd.listener === fndListener {
            fnd.listener = nil
        }
        fndReady = nil
        fndFailed = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if mode == .newChat, groupTable.bounds.width > 0, groupTable.bounds.width != groupHeaderWidth {
            groupHeaderWidth = groupTable.bounds.width
            groupHeader?.install(in: groupTable)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyKeyboardInsets()
    }

    // MARK: Построение страниц

    private func pin(_ page: UIView) {
        page.translatesAutoresizingMaskIntoConstraints = false
        pagesContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pagesContainer.topAnchor),
            page.bottomAnchor.constraint(equalTo: pagesContainer.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: pagesContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pagesContainer.trailingAnchor),
        ])
    }

    private func setupTable(_ table: UITableView) {
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = L2.background
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 82
        table.keyboardDismissMode = .onDrag
        table.tableFooterView = UIView(frame: .zero)
        if #available(iOS 15.0, *) { table.sectionHeaderTopPadding = 0 }
        table.register(L2NCCardCell.self, forCellReuseIdentifier: L2NCCardCell.reuseId)
    }

    private func buildSearchPage() {
        pin(searchPage)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.autocapitalizationType = .none
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)

        hintLabel.text = "Найдите собеседника по логину"
        hintLabel.font = L2.font(14)
        hintLabel.textColor = L2.textSecondary
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        setupTable(searchTable)
        searchPage.addSubview(searchField)
        searchPage.addSubview(hintLabel)
        searchPage.addSubview(searchTable)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: searchPage.topAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchPage.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: searchPage.trailingAnchor, constant: -20),
            hintLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: searchPage.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: searchPage.trailingAnchor, constant: -20),
            searchTable.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8),
            searchTable.leadingAnchor.constraint(equalTo: searchPage.leadingAnchor),
            searchTable.trailingAnchor.constraint(equalTo: searchPage.trailingAnchor),
            searchTable.bottomAnchor.constraint(equalTo: searchPage.bottomAnchor),
        ])
    }

    private func buildGroupPage() {
        pin(groupPage)
        setupTable(groupTable)

        groupNameField.delegate = self
        groupNameField.returnKeyType = .next
        groupNameField.autocapitalizationType = .sentences
        groupNameField.addTarget(self, action: #selector(groupNameChanged), for: .editingChanged)
        groupNoteField.delegate = self
        groupNoteField.returnKeyType = .done
        groupNoteField.autocapitalizationType = .sentences

        membersLabel.font = L2.font(15, .semibold)
        membersLabel.textColor = L2.textSecondary

        let header = L2TableHeader([groupNameField, groupNoteField, membersLabel], spacing: 12)
        header.stack.setCustomSpacing(24, after: groupNoteField)
        groupHeader = header
        header.install(in: groupTable)

        createButton.translatesAutoresizingMaskIntoConstraints = false
        createButton.addTarget(self, action: #selector(createGroupTapped), for: .touchUpInside)

        groupPage.addSubview(groupTable)
        groupPage.addSubview(createButton)
        let bottom = createButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        createButtonBottom = bottom
        NSLayoutConstraint.activate([
            groupTable.topAnchor.constraint(equalTo: groupPage.topAnchor),
            groupTable.leadingAnchor.constraint(equalTo: groupPage.leadingAnchor),
            groupTable.trailingAnchor.constraint(equalTo: groupPage.trailingAnchor),
            groupTable.bottomAnchor.constraint(equalTo: createButton.topAnchor, constant: -8),
            createButton.leadingAnchor.constraint(equalTo: groupPage.leadingAnchor, constant: 20),
            createButton.trailingAnchor.constraint(equalTo: groupPage.trailingAnchor, constant: -20),
            bottom,
        ])
        updateGroupState()
    }

    private func buildInvitePage() {
        pin(invitePage)
        invitePage.alwaysBounceVertical = true
        invitePage.keyboardDismissMode = .onDrag
        invitePage.backgroundColor = L2.background

        let iconBack = UIView()
        iconBack.backgroundColor = L2.accent.withAlphaComponent(0.16)
        iconBack.layer.cornerRadius = 28
        iconBack.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: L2.symbol("person.badge.plus", 24, .semibold))
        icon.tintColor = L2.accent
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBack.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBack.widthAnchor.constraint(equalToConstant: 56),
            iconBack.heightAnchor.constraint(equalToConstant: 56),
            icon.centerXAnchor.constraint(equalTo: iconBack.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBack.centerYAnchor),
        ])

        let title = UILabel()
        title.text = "Пригласите друзей"
        title.font = L2.rounded(22, .bold)
        title.textColor = L2.textPrimary
        title.numberOfLines = 0
        title.accessibilityTraits = .header

        let body = UILabel()
        body.text = "Регистрация в «Линия 2.0» — только по коду приглашения. Код выдаёт администратор."
        body.font = L2.font(16)
        body.textColor = L2.textSecondary
        body.numberOfLines = 0

        var cardViews: [UIView] = [iconBack, title, body]
        if let login = Linia2Profile.login {
            let loginLabel = UILabel()
            loginLabel.text = "Ваш логин: @" + login
            loginLabel.font = L2.font(16, .semibold)
            loginLabel.textColor = L2.accent
            loginLabel.numberOfLines = 0
            cardViews.append(loginLabel)
        }
        let cardStack = UIStackView(arrangedSubviews: cardViews)
        cardStack.axis = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 10
        cardStack.setCustomSpacing(16, after: iconBack)
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = L2.surface
        card.layer.cornerRadius = 20
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
        ])

        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        copyLoginButton.addTarget(self, action: #selector(copyLoginTapped), for: .touchUpInside)
        copyLoginButton.isHidden = Linia2Profile.login == nil

        let stack = UIStackView(arrangedSubviews: [card, shareButton, copyLoginButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(24, after: card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        invitePage.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: invitePage.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: invitePage.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: invitePage.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: invitePage.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    private func showPage(_ index: Int) {
        view.endEditing(true)
        // LINIA2: создание групп можно выключить в удалённых настройках.
        if index == 1 && !Linia2Config.shared.feature("groups") {
            chips.select(0)
            UiUtils.showToast(message: "Создание групп временно отключено.", level: .info)
            showPage(0)
            return
        }
        searchPage.isHidden = index != 0
        groupPage.isHidden = index != 1
        invitePage.isHidden = index != 2
    }

    // MARK: Контакты (p2p-топики, как во вкладке «Контакты»)

    private func loadContacts() {
        let topics = Cache.tinode.getFilteredTopics(filter: { (t: TopicProto) in
            t.topicType == .p2p && !t.deleted && t.isJoiner && Linia2Horizon.isVisible(t)
        }) ?? []
        contacts = topics.compactMap { $0 as? DefaultComTopic }
            .map { Linia2NewChatViewController.person(from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func person(from topic: DefaultComTopic) -> L2NCPerson {
        let login = Linia2ContactInfo.login(of: topic)
        let subtitle: String
        if topic.online && !topic.deleted {
            subtitle = "в сети"
        } else if let login = login {
            subtitle = "@" + login
        } else {
            subtitle = Linia2ContactInfo.lastSeenText(of: topic)
        }
        return L2NCPerson(id: topic.name, name: Linia2ContactInfo.name(of: topic), login: login,
                          subtitle: subtitle, pub: topic.pub, sub: nil)
    }

    /// Логин из совпавших тегов ответа fnd (alias:…, basic:… или тег без пространства имён).
    private static func login(fromTags tags: [String]?) -> String? {
        guard let tags = tags else { return nil }
        for prefix in ["alias:", "basic:"] {
            if let tag = tags.first(where: { $0.hasPrefix(prefix) }) {
                let value = String(tag.dropFirst(prefix.count))
                if !value.isEmpty { return value }
            }
        }
        if let plain = tags.first(where: { !$0.isEmpty && !$0.contains(":") }) { return plain }
        return nil
    }

    private static func person(from sub: Subscription<TheCard, [String]>) -> L2NCPerson? {
        guard let uid = sub.user ?? sub.uniqueId, uid.hasPrefix("usr"), !Cache.tinode.isMe(uid: uid) else { return nil }
        let login = Linia2NewChatViewController.login(fromTags: sub.priv)
        var name = sub.pub?.fn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = login ?? "Без имени" }
        return L2NCPerson(id: uid, name: name, login: login, subtitle: login.map { "@" + $0 }, pub: sub.pub, sub: sub)
    }

    // MARK: Поиск

    /// Запрос без пробелов по краям и без ведущего «@», в нижнем регистре.
    private func currentQuery() -> String {
        var q = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while q.hasPrefix("@") { q.removeFirst() }
        return q.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Запрос к fnd: как в FindInteractor — одиночное слово превращается в «alias:x,x»;
    /// дополнительно ищем по тегу basic:логин (его выставляет наш сервер авторизации).
    static func tagQuery(_ raw: String) -> String {
        // LINIA2: «@ann» = «ann»; теги в Tinode — в нижнем регистре; слова имени ищутся каждое отдельно.
        let words = raw.lowercased().split(whereSeparator: { " ,".contains($0) })
            .map { $0.hasPrefix("@") ? String($0.dropFirst()) : String($0) }.filter { !$0.isEmpty && !$0.contains(":") }
        guard let first = words.first else { return raw }
        if words.count > 1 { return words.joined(separator: ",") }
        return "\(Tinode.kTagAlias)\(first),basic:\(first),\(first)"
    }

    private func updateLocalMatches() {
        let q = currentQuery()
        guard !q.isEmpty else { localMatches = []; return }
        localMatches = contacts.filter { p in
            p.name.lowercased().contains(q) || (p.login?.lowercased().contains(q) ?? false)
        }
    }

    @objc private func searchChanged() {
        restartSearch()
    }

    private func restartSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchGen += 1
        remoteAll = []
        searchFailed = false
        updateLocalMatches()
        let q = currentQuery()
        guard q.count >= Linia2NewChatViewController.minQueryLength else {
            searching = false
            renderSearch()
            return
        }
        searching = true
        renderSearch()
        let gen = searchGen
        let work = DispatchWorkItem { [weak self] in self?.runRemoteSearch(q, gen: gen) }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Linia2NewChatViewController.searchDelay, execute: work)
    }

    private func runRemoteSearch(_ q: String, gen: Int) {
        guard gen == searchGen else { return }
        withFnd(ready: { [weak self] fnd in
            guard let self = self, gen == self.searchGen else { return }
            let query = Linia2NewChatViewController.tagQuery(q)
            _ = fnd.setMeta(pub: query, priv: nil).then(
                onSuccess: { [weak self] _ in
                    // Сначала разрешаем приём результатов этого запроса, потом запрашиваем их.
                    DispatchQueue.main.async { self?.acceptGen = gen }
                    _ = fnd.getMeta(query: MsgGetMeta.sub()).then(
                        onSuccess: { [weak self] _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.finishSearch(gen: gen, failed: false) }
                            return nil
                        },
                        onFailure: { [weak self] _ in
                            DispatchQueue.main.async { self?.finishSearch(gen: gen, failed: false) }
                            return nil
                        })
                    return nil
                },
                onFailure: { [weak self] _ in
                    DispatchQueue.main.async { self?.finishSearch(gen: gen, failed: false) }
                    return nil
                })
        }, failed: { [weak self] in
            self?.finishSearch(gen: gen, failed: true)
        })
    }

    /// Подключиться к fnd-топику (как UiUtils.attachToFndTopic) и выполнить `ready` на главном потоке.
    private func withFnd(ready: @escaping (DefaultFndTopic) -> Void, failed: @escaping () -> Void) {
        let tinode = Cache.tinode
        let fnd = tinode.getOrCreateFndTopic()
        fndListener.fnd = fnd
        fnd.listener = fndListener
        fndTopic = fnd
        if fnd.attached {
            ready(fnd)
            return
        }
        guard tinode.isConnected else {
            failed()
            return
        }
        // Пока идёт подписка — запоминаем только последний запрос.
        fndReady = ready
        fndFailed = failed
        guard !fndAttaching else { return }
        fndAttaching = true
        _ = fnd.subscribe(set: nil, get: nil).then(
            onSuccess: { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.fndAttaching = false
                    let callback = self.fndReady
                    self.fndReady = nil
                    self.fndFailed = nil
                    callback?(fnd)
                }
                return nil
            },
            onFailure: { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.fndAttaching = false
                    let callback = self.fndFailed
                    self.fndReady = nil
                    self.fndFailed = nil
                    callback?()
                }
                return nil
            })
    }

    private func applyRemoteSnapshot(_ subs: [Subscription<TheCard, [String]>]) {
        guard acceptGen == searchGen, currentQuery().count >= Linia2NewChatViewController.minQueryLength else { return }
        remoteAll = subs.compactMap { Linia2NewChatViewController.person(from: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        renderSearch()
    }

    private func finishSearch(gen: Int, failed: Bool) {
        guard gen == searchGen else { return }
        searching = false
        searchFailed = failed
        renderSearch()
    }

    private func renderSearch() {
        let localIds = Set(localMatches.map { $0.id })
        var seen = Set<String>()
        let remote = remoteAll.filter { p in
            guard !localIds.contains(p.id), !seen.contains(p.id) else { return false }
            seen.insert(p.id)
            return true
        }
        var sections: [L2NCSection] = []
        if !localMatches.isEmpty { sections.append(L2NCSection(title: "Ваши контакты", people: localMatches)) }
        if !remote.isEmpty { sections.append(L2NCSection(title: "Найдено на сервере", people: remote)) }
        searchSections = sections

        let q = currentQuery()
        if q.isEmpty {
            searchTable.backgroundView = l2EmptyState("Найдите собеседника",
                                                      "Введите логин, например @ivan, или имя контакта",
                                                      symbol: "magnifyingglass")
        } else if sections.isEmpty {
            if searching {
                searchTable.backgroundView = makeLoadingView()
            } else if searchFailed {
                searchTable.backgroundView = l2EmptyState("Нет соединения",
                                                          "Не удалось связаться с сервером. Проверьте интернет и попробуйте ещё раз",
                                                          symbol: "wifi.exclamationmark")
            } else if q.count < Linia2NewChatViewController.minQueryLength {
                searchTable.backgroundView = l2EmptyState("Слишком короткий запрос",
                                                          "Введите хотя бы \(Linia2NewChatViewController.minQueryLength) символа",
                                                          symbol: "magnifyingglass")
            } else {
                searchTable.backgroundView = makeNotFoundView(q)
            }
        } else {
            searchTable.backgroundView = nil
        }
        searchTable.tableFooterView = (searching && !sections.isEmpty) ? makeLoadingFooter() : UIView(frame: .zero)
        searchTable.reloadData()
    }

    private func makeNotFoundView(_ q: String) -> UIView {
        l2EmptyState("Ничего не найдено",
                     "Пользователь «@\(q)» не найден. Проверьте логин и попробуйте ещё раз",
                     symbol: "person.crop.circle.badge.questionmark")
    }

    private func makeLoadingView() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = L2.accent
        spinner.startAnimating()
        let label = UILabel()
        label.text = "Ищем на сервере…"
        label.font = L2.font(15)
        label.textColor = L2.textSecondary
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let wrap = UIView()
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: wrap.centerYAnchor, constant: -40),
        ])
        return wrap
    }

    private func makeLoadingFooter() -> UIView {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: max(searchTable.bounds.width, 1), height: 56))
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = L2.accent
        spinner.startAnimating()
        let label = UILabel()
        label.text = "Ищем на сервере…"
        label.font = L2.font(14)
        label.textColor = L2.textSecondary
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        return footer
    }

    private func searchPerson(at indexPath: IndexPath) -> L2NCPerson? {
        guard indexPath.section >= 0, indexPath.section < searchSections.count else { return nil }
        let people = searchSections[indexPath.section].people
        guard indexPath.row >= 0, indexPath.row < people.count else { return nil }
        return people[indexPath.row]
    }

    private func contact(at indexPath: IndexPath) -> L2NCPerson? {
        guard indexPath.section == 0, indexPath.row >= 0, indexPath.row < contacts.count else { return nil }
        return contacts[indexPath.row]
    }

    /// Открыть найденного человека. Для найденного на сервере сначала сохраняем топик и пользователя —
    /// как FindInteractor.saveRemoteTopic (иначе экран переписки не найдёт топик в кэше).
    private func open(_ p: L2NCPerson) {
        view.endEditing(true)
        L2.haptic()
        let tinode = Cache.tinode
        if !tinode.isTopicTracked(topicName: p.id) {
            guard let topic = tinode.newTopic(for: p.id) as? DefaultComTopic else {
                UiUtils.showToast(message: "Не удалось открыть контакт. Попробуйте ещё раз")
                return
            }
            topic.pub = p.pub
            topic.persist()
        }
        if let sub = p.sub, BaseDb.sharedInstance.userDb != nil {
            ContactsManager.default.processSubscription(sub: sub)
        }
        switch mode {
        case .newChat:
            pendingSearch?.cancel()
            if let nav = navigationController, nav !== Linia2Root.chatsNavigator() {
                nav.popViewController(animated: false)
            }
            Linia2Root.openChat(p.id)
        case .addContact:
            navigationController?.pushViewController(Linia2ContactCardViewController(topicName: p.id), animated: true)
        }
    }

    // MARK: Новая группа

    private var trimmedGroupName: String {
        (groupNameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Выбранные участники, которые всё ещё есть в списке контактов.
    private var selectedMembers: [String] {
        contacts.map { $0.id }.filter { selectedIds.contains($0) && !Cache.tinode.isMe(uid: $0) }
    }

    @objc private func groupNameChanged() {
        groupNameField.isInvalid = false
        updateGroupState()
    }

    private func updateGroupState() {
        let count = selectedMembers.count
        membersLabel.text = count > 0 ? "Участники · выбрано \(count)" : "Участники"
        createButton.isEnabled = !trimmedGroupName.isEmpty && count > 0 && !isCreatingGroup
        createButton.setTitle(isCreatingGroup ? "Создаём группу…" : "Создать группу", for: .normal)

        if contacts.isEmpty {
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: max(groupTable.bounds.width, 1), height: 90))
            label.text = "Контактов пока нет.\nНайдите собеседника во вкладке «Новый чат»."
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = L2.font(15)
            label.textColor = L2.textSecondary
            groupTable.tableFooterView = label
        } else if groupTable.tableFooterView is UILabel {
            groupTable.tableFooterView = UIView(frame: .zero)
        }
    }

    @objc private func createGroupTapped() {
        guard !isCreatingGroup else { return }
        view.endEditing(true)
        let name = String(trimmedGroupName.prefix(UiUtils.kMaxTitleLength))
        guard !name.isEmpty else {
            groupNameField.isInvalid = true
            UiUtils.showToast(message: "Введите название группы")
            return
        }
        let members = selectedMembers
        guard !members.isEmpty else {
            UiUtils.showToast(message: "Выберите хотя бы одного участника")
            return
        }
        let tinode = Cache.tinode
        guard tinode.isConnected else {
            UiUtils.showToast(message: "Нет соединения с сервером. Попробуйте позже")
            return
        }
        let note = String((groupNoteField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Linia2NewChatViewController.maxNoteLength))

        L2.haptic()
        isCreatingGroup = true
        updateGroupState()

        // Как NewGroupViewController.createGroupTopic: новый топик, pub = карточка, subscribe → приглашения → leave → чат.
        let topic = DefaultComTopic(in: tinode, forwardingEventsTo: nil, isChannel: false)
        let card = TheCard(fn: name)
        if !note.isEmpty { card.note = note }
        topic.pub = card
        _ = topic.subscribe().then(
            onSuccess: { [weak self] _ in
                for uid in members {
                    _ = topic.invite(user: uid, in: nil)
                }
                // Экран переписки подпишется на топик заново.
                _ = topic.leave()
                let topicName = topic.name
                DispatchQueue.main.async {
                    self?.isCreatingGroup = false
                    self?.updateGroupState()
                    if let nav = self?.navigationController, nav !== Linia2Root.chatsNavigator() {
                        nav.popViewController(animated: false)
                    }
                    Linia2Root.openChat(topicName)
                }
                return nil
            },
            onFailure: { [weak self] err in
                DispatchQueue.main.async {
                    self?.isCreatingGroup = false
                    self?.updateGroupState()
                    UiUtils.showToast(message: Linia2NewChatViewController.errorText(err, prefix: "Не удалось создать группу"))
                }
                return nil
            })
    }

    private static func errorText(_ err: Error, prefix: String) -> String {
        if let e = err as? TinodeError, case .notConnected = e {
            return prefix + ": нет соединения с сервером"
        }
        let details = err.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? prefix : prefix + ": " + details
    }

    // MARK: Приглашение

    @objc private func shareTapped() {
        L2.haptic()
        var text = "Присоединяйся к мессенджеру «Линия 2.0»: https://v2.chat-linia.site — попроси у администратора код приглашения."
        if let login = Linia2Profile.login, !login.isEmpty {
            text += " Мой логин: @" + login
        }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        present(activity, animated: true)
    }

    @objc private func copyLoginTapped() {
        guard let login = Linia2Profile.login, !login.isEmpty else {
            UiUtils.showToast(message: "Логин пока недоступен")
            return
        }
        L2.haptic()
        UIPasteboard.general.string = "@" + login
        UiUtils.showToast(message: "Логин @\(login) скопирован", level: .info)
    }

    // MARK: Клавиатура

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let local = view.convert(value.cgRectValue, from: nil)
        keyboardOverlap = max(0, view.bounds.maxY - local.minY)
        animateKeyboard(note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardOverlap = 0
        animateKeyboard(note)
    }

    private func animateKeyboard(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        applyKeyboardInsets()
        UIView.animate(withDuration: duration) { [weak self] in
            self?.view.layoutIfNeeded()
        }
    }

    private func applyKeyboardInsets() {
        let safeBottom = view.safeAreaInsets.bottom
        let extra = max(0, keyboardOverlap - safeBottom)
        createButtonBottom?.constant = -(max(keyboardOverlap, safeBottom) + 12)
        for scroll in [searchTable as UIScrollView, invitePage as UIScrollView] {
            scroll.contentInset.bottom = extra
            scroll.verticalScrollIndicatorInsets.bottom = extra
        }
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === groupNameField {
            groupNoteField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            if textField === searchField {
                // Поиск сразу, без ожидания паузы ввода.
                if let work = pendingSearch {
                    pendingSearch = nil
                    work.cancel()
                    let q = currentQuery()
                    if q.count >= Linia2NewChatViewController.minQueryLength { runRemoteSearch(q, gen: searchGen) }
                }
            }
        }
        return true
    }

    // MARK: UITableViewDataSource / Delegate

    func numberOfSections(in tableView: UITableView) -> Int {
        tableView === searchTable ? searchSections.count : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === searchTable {
            guard section >= 0, section < searchSections.count else { return 0 }
            return searchSections[section].people.count
        }
        return section == 0 ? contacts.count : 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: L2NCCardCell.reuseId, for: indexPath) as? L2NCCardCell else {
            return UITableViewCell()
        }
        if tableView === searchTable {
            if let p = searchPerson(at: indexPath) {
                cell.configure(p, accessory: .chevron)
            }
        } else if let p = contact(at: indexPath) {
            cell.configure(p, accessory: .check(selectedIds.contains(p.id)))
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        tableView === searchTable ? 34 : CGFloat.leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard tableView === searchTable, section >= 0, section < searchSections.count else { return nil }
        let v = UIView()
        v.backgroundColor = L2.background
        let l = UILabel()
        l.text = searchSections[section].title
        l.font = L2.font(14, .semibold)
        l.textColor = L2.textSecondary
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -6),
        ])
        return v
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView === searchTable {
            guard let p = searchPerson(at: indexPath) else { return }
            open(p)
            return
        }
        guard !isCreatingGroup, let p = contact(at: indexPath) else { return }
        L2.haptic()
        if selectedIds.contains(p.id) {
            selectedIds.remove(p.id)
        } else {
            selectedIds.insert(p.id)
        }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateGroupState()
    }
}

// MARK: - L2_CSEARCH: поиск людей на сервере для вкладки «Контакты» (как веб: fnd «alias:x,basic:x,x»)

struct Linia2FoundPerson {
    let id: String
    let name: String
    let login: String?
    let pub: TheCard?
    let sub: Subscription<TheCard, [String]>?
}

enum Linia2PeopleSearch {
    /// Найти людей по запросу (≥ 2 символов, «@x» = «x»). completion — на главном потоке; nil — нет связи / ошибка.
    /// Ответ берётся из самого {meta} (без слушателя fnd — им пользуется экран «Добавить контакт»).
    static func search(_ raw: String, completion: @escaping ([Linia2FoundPerson]?) -> Void) {
        let tinode = Cache.tinode
        guard tinode.isConnected else { completion(nil); return }
        let fnd = tinode.getOrCreateFndTopic()
        let query = Linia2NewChatViewController.tagQuery(raw)
        let start: PromisedReply<ServerMessage> = fnd.attached ? PromisedReply<ServerMessage>(value: ServerMessage()) : fnd.subscribe(set: nil, get: nil)
        start.thenApply { _ in
            return fnd.setMeta(pub: query, priv: nil)
        }.thenApply { _ in
            return fnd.getMeta(query: MsgGetMeta.sub())
        }.then(onSuccess: { msg in
            var out: [Linia2FoundPerson] = []
            for s in msg?.meta?.sub ?? [] {
                guard let sub = s as? Subscription<TheCard, [String]>,
                      let uid = sub.user ?? sub.topic, uid.hasPrefix("usr"), !tinode.isMe(uid: uid),
                      !out.contains(where: { $0.id == uid }) else { continue }
                let lg = Linia2PeopleSearch.login(fromTags: sub.priv)
                var name = sub.pub?.fn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty { name = lg ?? "Без имени" }
                out.append(Linia2FoundPerson(id: uid, name: name, login: lg, pub: sub.pub, sub: sub))
            }
            out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { completion(out) }
            return nil
        }, onFailure: { _ in
            DispatchQueue.main.async { completion(nil) }
            return nil
        })
    }

    private static func login(fromTags tags: [String]?) -> String? {
        guard let tags = tags else { return nil }
        for prefix in ["alias:", "basic:"] {
            if let tag = tags.first(where: { $0.hasPrefix(prefix) }) {
                let value = String(tag.dropFirst(prefix.count))
                if !value.isEmpty { return value }
            }
        }
        return tags.first(where: { !$0.isEmpty && !$0.contains(":") })
    }

    /// Открыть карточку найденного (как «Добавить контакт»: топик создаётся локально, подписка — в контакты).
    static func open(_ p: Linia2FoundPerson, from nav: UINavigationController?) {
        let tinode = Cache.tinode
        if !tinode.isTopicTracked(topicName: p.id) {
            guard let topic = tinode.newTopic(for: p.id) as? DefaultComTopic else {
                UiUtils.showToast(message: "Не удалось открыть контакт. Попробуйте ещё раз")
                return
            }
            topic.pub = p.pub
            topic.persist()
        }
        if let sub = p.sub, BaseDb.sharedInstance.userDb != nil {
            ContactsManager.default.processSubscription(sub: sub)
        }
        nav?.pushViewController(Linia2ContactCardViewController(topicName: p.id), animated: true)
    }
}

/// Строка «Найдены в Линии» во вкладке «Контакты» (вид как у Linia2ContactCell).
final class Linia2FoundPersonCell: UITableViewCell {
    static let reuseId = "Linia2FoundPersonCell"

    private let avatar = RoundImageView()
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
        nameLabel.font = L2.font(17, .semibold)
        nameLabel.textColor = L2.textPrimary
        subtitleLabel.font = L2.font(15)
        subtitleLabel.textColor = L2.textSecondary
        let texts = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 3
        texts.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatar)
        contentView.addSubview(texts)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 52),
            avatar.heightAnchor.constraint(equalToConstant: 52),
            avatar.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -28),
            texts.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        separatorInset = UIEdgeInsets(top: 0, left: 86, bottom: 0, right: 0)
        accessibilityIdentifier = "l2.contacts.found"
    }

    required init?(coder: NSCoder) { return nil }

    func configure(_ p: Linia2FoundPerson) {
        nameLabel.text = p.name
        subtitleLabel.text = p.login.map { "@" + $0 }
        subtitleLabel.isHidden = p.login == nil
        avatar.set(pub: p.pub, id: p.id, deleted: false)
        accessibilityLabel = p.name + (p.login.map { ", @" + $0 } ?? "")
    }
}
