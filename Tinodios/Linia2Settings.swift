//
//  Linia2Settings.swift
//  Линия 2.0: вкладка «Настройки» и вложенные экраны (уведомления, конфиденциальность, внешний вид, о приложении).
//

import UIKit
import TinodeSDK
import TinodiosDB

// MARK: - Данные профиля

enum Linia2Profile {
    static var me: DefaultMeTopic? { Cache.tinode.getMeTopic() }

    /// Логин: псевдоним, тег basic:логин, сохранённое имя входа или uid.
    static var login: String? {
        if let alias = me?.alias, !alias.isEmpty { return alias }
        if let basic = me?.tagValueByPrefix("basic:"), !basic.isEmpty { return basic }
        if let saved = SharedUtils.getSavedLoginUserName(), !saved.isEmpty { return saved }
        return nil
    }

    static var name: String {
        if let fn = me?.pub?.fn?.trimmingCharacters(in: .whitespacesAndNewlines), !fn.isEmpty { return fn }
        return login ?? "Профиль"
    }
}

// MARK: - Ячейки

/// Строка меню: цветная круглая иконка SF Symbol, заголовок, необязательный подзаголовок, шеврон.
final class L2MenuCell: UITableViewCell {
    static let reuseId = "L2MenuCell"
    private let iconBack = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = L2.surface
        let sel = UIView()
        sel.backgroundColor = L2.surface2
        selectedBackgroundView = sel

        iconBack.layer.cornerRadius = 17
        iconBack.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBack.addSubview(icon)

        titleLabel.font = L2.font(17, .medium)
        titleLabel.textColor = L2.textPrimary
        titleLabel.numberOfLines = 0
        subtitleLabel.font = L2.font(14)
        subtitleLabel.textColor = L2.textSecondary
        subtitleLabel.numberOfLines = 0
        let texts = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        texts.axis = .vertical
        texts.spacing = 2
        texts.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconBack)
        contentView.addSubview(texts)
        NSLayoutConstraint.activate([
            iconBack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconBack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconBack.widthAnchor.constraint(equalToConstant: 34),
            iconBack.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: iconBack.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBack.centerYAnchor),
            texts.leadingAnchor.constraint(equalTo: iconBack.trailingAnchor, constant: 14),
            texts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            texts.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            texts.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -13),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).withPriority(.defaultHigh),
        ])
        separatorInset = UIEdgeInsets(top: 0, left: 64, bottom: 0, right: 0)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(symbol: String, color: UIColor, title: String, subtitle: String? = nil, chevron: Bool = true) {
        icon.image = L2.symbol(symbol, 15, .semibold)
        iconBack.backgroundColor = color
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        accessoryType = chevron ? .disclosureIndicator : .none
        selectionStyle = .default
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

/// Карточка профиля: большой аватар, имя, @логин.
final class L2ProfileCell: UITableViewCell {
    static let reuseId = "L2ProfileCell"
    let avatar = RoundImageView()
    private let nameLabel = UILabel()
    private let loginLabel = UILabel()
    private let hintLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = L2.surface
        let sel = UIView()
        sel.backgroundColor = L2.surface2
        selectedBackgroundView = sel
        accessoryType = .disclosureIndicator

        avatar.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = L2.rounded(22, .bold)
        nameLabel.textColor = L2.textPrimary
        nameLabel.numberOfLines = 2
        loginLabel.font = L2.font(16, .medium)
        loginLabel.textColor = L2.accent
        hintLabel.font = L2.font(13)
        hintLabel.textColor = L2.textSecondary
        hintLabel.text = "Имя, фото и описание"
        let texts = UIStackView(arrangedSubviews: [nameLabel, loginLabel, hintLabel])
        texts.axis = .vertical
        texts.spacing = 3
        texts.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatar)
        contentView.addSubview(texts)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatar.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            avatar.widthAnchor.constraint(equalToConstant: 72),
            avatar.heightAnchor.constraint(equalToConstant: 72),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16),
            texts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            texts.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 14),
            texts.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            contentView.heightAnchor.constraint(equalToConstant: 104).withPriority(.defaultLow),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func configure() {
        let me = Linia2Profile.me
        nameLabel.text = Linia2Profile.name
        if let login = Linia2Profile.login {
            loginLabel.text = "@" + login
        } else {
            loginLabel.text = Cache.tinode.myUid
        }
        avatar.set(pub: me?.pub, id: Cache.tinode.myUid, deleted: false)
        avatar.letterTileFont = L2.rounded(30, .semibold)
        accessibilityLabel = "Профиль: " + (nameLabel.text ?? "") + ", " + (loginLabel.text ?? "")
    }
}

// MARK: - Базовый экран-список (insetGrouped, тёмный)

class Linia2GroupedTableViewController: UITableViewController {
    struct Row {
        let symbol: String
        let color: UIColor
        let title: String
        var subtitle: String? = nil
        let action: () -> Void
    }

    struct Group {
        var header: String? = nil
        var footer: String? = nil
        var rows: [Row]
    }

    /// Простые меню задают группы строк; экраны со своими ячейками переопределяют источник данных.
    var groups: [Group] = [] { didSet { if isViewLoaded { tableView.reloadData() } } }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.register(L2MenuCell.self, forCellReuseIdentifier: L2MenuCell.reuseId)
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        groups[section].header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        groups[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = groups[indexPath.section].rows[indexPath.row]
        guard let cell = tableView.dequeueReusableCell(withIdentifier: L2MenuCell.reuseId, for: indexPath) as? L2MenuCell else { return UITableViewCell() }
        cell.configure(symbol: row.symbol, color: row.color, title: row.title, subtitle: row.subtitle)
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Глобальное оформление красит ячейки в цвет фона — в сгруппированных списках нужны «карточки».
        cell.backgroundColor = L2.surface
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section < groups.count, indexPath.row < groups[indexPath.section].rows.count else { return }
        groups[indexPath.section].rows[indexPath.row].action()
    }
}

// MARK: - Экран «Настройки»

final class Linia2SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Sec: Int, CaseIterable { case profile, menu, logout }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var header: L2TableHeader?
    private var headerWidth: CGFloat = 0
    private var listener: Linia2TinodeListener?

    private lazy var menu: [Linia2GroupedTableViewController.Row] = [
        .init(symbol: "bell.fill", color: L2.hex(0xF0884A), title: "Уведомления") { [weak self] in
            self?.push(Linia2NotificationsViewController())
        },
        .init(symbol: "lock.fill", color: L2.hex(0x5B8DEF), title: "Конфиденциальность") { [weak self] in
            self?.push(Linia2PrivacyViewController())
        },
        .init(symbol: "paintbrush.fill", color: L2.accentStrong, title: "Внешний вид") { [weak self] in
            self?.push(Linia2AppearanceViewController())
        },
        .init(symbol: "info.circle.fill", color: L2.hex(0x2FB39A), title: "О приложении") { [weak self] in
            self?.push(Linia2AboutViewController())
        },
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.contentInset.bottom = Linia2TabBarController.reservedBottom + 20
        tableView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: Linia2TabBarController.reservedBottom, right: 0)
        tableView.register(L2ProfileCell.self, forCellReuseIdentifier: L2ProfileCell.reuseId)
        tableView.register(L2MenuCell.self, forCellReuseIdentifier: L2MenuCell.reuseId)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "logout")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        header = L2TableHeader([L2Header(title: "Настройки")])
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
            // Профиль (имя/аватар) может прийти с сервера уже после показа экрана.
            let l = Linia2TinodeListener { [weak self] in self?.reloadProfile() }
            listener = l
            Cache.tinode.addListener(l)
        }
        tableView.reloadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if let l = listener {
            Cache.tinode.removeListener(l)
            listener = nil
        }
    }

    private func reloadProfile() {
        guard isViewLoaded else { return }
        tableView.reloadSections(IndexSet(integer: Sec.profile.rawValue), with: .none)
    }

    private func push(_ vc: UIViewController) {
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openProfileEditor() {
        // Экран Tinode «General Settings» (AccountGeneralSettingsViewController) требует me-топик.
        guard Cache.tinode.getMeTopic() != nil else {
            UiUtils.showToast(message: "Профиль ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        let vc = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "General Settings")
        vc.title = "Профиль"
        push(vc)
    }

    private func confirmLogout() {
        let alert = UIAlertController(title: "Выйти из аккаунта?",
                                      message: "Чтобы снова войти, понадобятся логин и пароль.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Выйти", style: .destructive) { _ in
            UiUtils.logoutAndRouteToLoginVC()
        })
        present(alert, animated: true)
    }

    // MARK: UITableViewDataSource / Delegate

    func numberOfSections(in tableView: UITableView) -> Int { Sec.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Sec(rawValue: section) {
        case .menu: return menu.count
        case .profile, .logout: return 1
        case .none: return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Sec(rawValue: indexPath.section) {
        case .profile:
            guard let cell = tableView.dequeueReusableCell(withIdentifier: L2ProfileCell.reuseId, for: indexPath) as? L2ProfileCell else { return UITableViewCell() }
            cell.configure()
            return cell
        case .menu:
            let row = menu[indexPath.row]
            guard let cell = tableView.dequeueReusableCell(withIdentifier: L2MenuCell.reuseId, for: indexPath) as? L2MenuCell else { return UITableViewCell() }
            cell.configure(symbol: row.symbol, color: row.color, title: row.title, subtitle: row.subtitle)
            return cell
        default:
            let cell = tableView.dequeueReusableCell(withIdentifier: "logout", for: indexPath)
            cell.textLabel?.text = "Выйти"
            cell.textLabel?.textColor = L2.danger
            cell.textLabel?.font = L2.font(17, .semibold)
            cell.textLabel?.textAlignment = .center
            cell.accessoryType = .none
            let sel = UIView()
            sel.backgroundColor = L2.surface2
            cell.selectedBackgroundView = sel
            return cell
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cell.backgroundColor = L2.surface
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == Sec.profile.rawValue ? 8 : 18
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { 8 }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { UIView() }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Sec(rawValue: indexPath.section) {
        case .profile: openProfileEditor()
        case .menu: menu[indexPath.row].action()
        case .logout: confirmLogout()
        case .none: break
        }
    }
}

// MARK: - Уведомления

/// Те же настройки, что в экране Tinode SettingsNotificationsViewController
/// (у него нет storyboardIdentifier, поэтому повторяем логику здесь).
final class Linia2NotificationsViewController: Linia2GroupedTableViewController {
    private let incognitoSwitch = UISwitch()
    private let receiptsSwitch = UISwitch()
    private let typingSwitch = UISwitch()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Уведомления"
        for s in [incognitoSwitch, receiptsSwitch, typingSwitch] { s.onTintColor = L2.accentStrong }
        incognitoSwitch.addTarget(self, action: #selector(incognitoChanged), for: .valueChanged)
        receiptsSwitch.addTarget(self, action: #selector(receiptsChanged), for: .valueChanged)
        typingSwitch.addTarget(self, action: #selector(typingChanged), for: .valueChanged)
        groups = [
            Group(header: nil, footer: nil, rows: [
                Row(symbol: "eye.slash.fill", color: L2.hex(0x7C8CF8), title: "Режим инкогнито") {},
            ]),
            Group(header: nil, footer: "Собеседники увидят, что вы прочитали сообщение или печатаете ответ.", rows: [
                Row(symbol: "checkmark.circle.fill", color: L2.hex(0x2FB39A), title: "Отчёты о прочтении") {},
                Row(symbol: "ellipsis.bubble.fill", color: L2.hex(0x5B8DEF), title: "Индикатор набора текста") {},
            ]),
            Group(header: nil, footer: "Звук, баннеры и значки на иконке настраиваются в системных настройках iOS.", rows: [
                Row(symbol: "gearshape.fill", color: L2.hex(0x8A92A3), title: "Системные настройки уведомлений") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                },
            ]),
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func refresh() {
        incognitoSwitch.setOn(Cache.tinode.getMeTopic()?.isMuted ?? false, animated: false)
        incognitoSwitch.isEnabled = Cache.tinode.getMeTopic() != nil
        receiptsSwitch.setOn(SharedUtils.kAppDefaults.bool(forKey: SharedUtils.kTinodePrefReadReceipts), animated: false)
        typingSwitch.setOn(SharedUtils.kAppDefaults.bool(forKey: SharedUtils.kTinodePrefTypingNotifications), animated: false)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        switch (indexPath.section, indexPath.row) {
        case (0, 0): cell.accessoryView = incognitoSwitch
        case (1, 0): cell.accessoryView = receiptsSwitch
        case (1, 1): cell.accessoryView = typingSwitch
        default: cell.accessoryView = nil
        }
        if cell.accessoryView != nil {
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        return cell
    }

    @objc private func incognitoChanged() {
        guard let me = Cache.tinode.getMeTopic() else { refresh(); return }
        let isOn = incognitoSwitch.isOn
        me.updateMuted(muted: isOn).then(
            onSuccess: { msg in
                UiUtils.ToastSuccessHandler(msg: msg)
                DispatchQueue.main.async { [weak self] in self?.refresh() }
                return nil
            },
            onFailure: { err in
                DispatchQueue.main.async { [weak self] in self?.refresh() }
                return UiUtils.ToastFailureHandler(err: err)
            })
    }

    @objc private func receiptsChanged() {
        SharedUtils.kAppDefaults.set(receiptsSwitch.isOn, forKey: SharedUtils.kTinodePrefReadReceipts)
    }

    @objc private func typingChanged() {
        SharedUtils.kAppDefaults.set(typingSwitch.isOn, forKey: SharedUtils.kTinodePrefTypingNotifications)
    }
}

// MARK: - Конфиденциальность

final class Linia2PrivacyViewController: Linia2GroupedTableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Конфиденциальность"
        groups = [
            Group(header: nil, footer: "PIN-код и Face ID защищают переписку, если телефон попал в чужие руки.", rows: [
                Row(symbol: "faceid", color: L2.hex(0x2FB39A), title: "Блокировка приложения", subtitle: "PIN-код, Face ID") { [weak self] in
                    self?.navigationController?.pushViewController(Linia2AppLockSettingsViewController(), animated: true)
                },
            ]),
            Group(header: nil, footer: nil, rows: [
                Row(symbol: "key.fill", color: L2.hex(0x5B8DEF), title: "Безопасность аккаунта", subtitle: "Пароль, заблокированные") { [weak self] in
                    self?.navigationController?.pushViewController(Linia2AccountSecurityViewController(), animated: true)
                },
            ]),
        ]
    }
}

// MARK: - Безопасность аккаунта

/// Экран Tinode SettingsSecurityViewController не имеет storyboardIdentifier (открывается только сегвеем
/// из «Account Settings»), поэтому основные действия повторены здесь, а остальное доступно через «Account Settings».
final class Linia2AccountSecurityViewController: Linia2GroupedTableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Безопасность аккаунта"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let blocked = Cache.tinode.countFilteredTopics(filter: { t in t.topicType.matches(TopicType.user) && !t.isJoiner })
        groups = [
            Group(header: nil, footer: nil, rows: [
                Row(symbol: "key.fill", color: L2.hex(0x5B8DEF), title: "Сменить пароль") { [weak self] in
                    self?.changePassword()
                },
                Row(symbol: "hand.raised.fill", color: L2.danger, title: "Заблокированные",
                    subtitle: blocked > 0 ? "Контактов: \(blocked)" : "Никого нет") { [weak self] in
                    self?.navigationController?.pushViewController(Linia2BlockedContactsViewController(), animated: true)
                },
            ]),
            Group(header: nil, footer: "Права доступа по умолчанию, удаление аккаунта и прочие параметры Tinode.", rows: [
                Row(symbol: "slider.horizontal.3", color: L2.hex(0x8A92A3), title: "Расширенные настройки аккаунта") { [weak self] in
                    self?.openAccountSettings()
                },
            ]),
        ]
    }

    private func openAccountSettings() {
        guard Cache.tinode.getMeTopic() != nil else {
            UiUtils.showToast(message: "Профиль ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        // Экран Tinode «Account Settings» (AccountSettingsViewController): из него ведут сегвеи
        // в «Account and Security» (SettingsSecurityViewController), «Notifications» и т. д.
        let vc = UIStoryboard(name: "Main", bundle: nil).instantiateViewController(withIdentifier: "Account Settings")
        navigationController?.pushViewController(vc, animated: true)
    }

    private func changePassword() {
        let alert = UIAlertController(title: "Новый пароль", message: "Не короче 8 символов", preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "Новый пароль"
            f.isSecureTextEntry = true
            f.textContentType = .newPassword
        }
        alert.addTextField { f in
            f.placeholder = "Ещё раз"
            f.isSecureTextEntry = true
            f.textContentType = .newPassword
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self] _ in
            let p1 = alert.textFields?.first?.text ?? ""
            let p2 = alert.textFields?.last?.text ?? ""
            self?.updatePassword(p1, p2)
        })
        present(alert, animated: true)
    }

    private func updatePassword(_ p1: String, _ p2: String) {
        guard p1.count >= 8 else {
            UiUtils.showToast(message: "Пароль слишком короткий: нужно не меньше 8 символов.")
            return
        }
        guard p1 == p2 else {
            UiUtils.showToast(message: "Пароли не совпадают.")
            return
        }
        guard let userName = SharedUtils.getSavedLoginUserName() else {
            UiUtils.showToast(message: "Не найден логин. Выйдите и войдите снова.")
            return
        }
        Cache.tinode.updateAccountBasic(uid: nil, username: userName, password: p1).then(
            onSuccess: { msg in
                DispatchQueue.main.async {
                    if let ctrl = msg?.ctrl, 200 <= ctrl.code && ctrl.code < 300 {
                        UiUtils.showToast(message: "Пароль изменён", level: .info)
                    } else {
                        UiUtils.showToast(message: "Ошибка сервера")
                    }
                }
                return nil
            },
            onFailure: { err in
                DispatchQueue.main.async {
                    UiUtils.showToast(message: "Не удалось сменить пароль: " + err.localizedDescription)
                }
                return nil
            })
    }
}

// MARK: - Заблокированные контакты

/// Аналог BlockedContactsTableViewController (у него нет storyboardIdentifier).
final class Linia2BlockedContactsViewController: Linia2GroupedTableViewController {
    private var topics: [DefaultComTopic] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Заблокированные"
        tableView.register(Linia2ContactCell.self, forCellReuseIdentifier: Linia2ContactCell.reuseId)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        topics = (Cache.tinode.getFilteredTopics(filter: { t in t.topicType.matches(TopicType.user) && !t.isJoiner }) ?? [])
            .compactMap { $0 as? DefaultComTopic }
        tableView.backgroundView = topics.isEmpty ?
            l2EmptyState("Никого нет", "Заблокированные собеседники появятся здесь", symbol: "hand.raised") : nil
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { topics.isEmpty ? 0 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { topics.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { nil }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Нажмите на собеседника, чтобы разблокировать или удалить."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: Linia2ContactCell.reuseId, for: indexPath) as? Linia2ContactCell else { return UITableViewCell() }
        cell.configure(topics[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let topic = topics[indexPath.row]
        let sheet = UIAlertController(title: Linia2ContactInfo.name(of: topic), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Разблокировать", style: .default) { [weak self] _ in
            self?.unblock(topic)
        })
        sheet.addAction(UIAlertAction(title: "Удалить переписку", style: .destructive) { [weak self] _ in
            self?.deleteChat(topic)
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.rectForRow(at: indexPath)
        }
        present(sheet, animated: true)
    }

    // Как в BlockedContactsTableViewController: подписка восстанавливает доступ, затем топик отпускается.
    private func unblock(_ topic: DefaultComTopic) {
        topic.subscribe().then(
            onSuccess: { [weak self] _ in
                DispatchQueue.main.async { self?.reload() }
                return nil
            },
            onFailure: UiUtils.ToastFailureHandler)
        topic.leave()
    }

    private func deleteChat(_ topic: DefaultComTopic) {
        topic.delete(hard: true).then(
            onSuccess: { [weak self] _ in
                DispatchQueue.main.async { self?.reload() }
                return nil
            },
            onFailure: UiUtils.ToastFailureHandler)
    }
}

// MARK: - Внешний вид

/// В Tinode нет настройки размера текста сообщений, поэтому экран описывает фиксированную тему и показывает превью.
final class Linia2AppearanceViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Внешний вид"
        view.backgroundColor = L2.background
        navigationItem.largeTitleDisplayMode = .never

        let themeTitle = UILabel()
        themeTitle.text = "Тёмная тема с фиолетовым акцентом"
        themeTitle.font = L2.rounded(22, .bold)
        themeTitle.textColor = L2.textPrimary
        themeTitle.numberOfLines = 0
        let themeText = UILabel()
        themeText.text = "«Линия 2.0» всегда использует тёмное оформление: оно бережёт глаза вечером и экономит заряд на OLED-экранах."
        themeText.font = L2.font(15)
        themeText.textColor = L2.textSecondary
        themeText.numberOfLines = 0

        // Превью переписки.
        let preview = UIStackView(arrangedSubviews: [
            bubble("Привет! Как тебе новая тема?", incoming: true),
            bubble("Очень нравится 💜", incoming: false),
        ])
        preview.axis = .vertical
        preview.spacing = 8
        let previewCard = card(preview)

        // Палитра.
        let swatches: [(UIColor, String)] = [
            (L2.background, "Фон"), (L2.surface, "Карточки"), (L2.accent, "Акцент"),
            (L2.accentStrong, "Сообщения"), (L2.online, "В сети"),
        ]
        let palette = UIStackView(arrangedSubviews: swatches.map { swatch($0.0, $0.1) })
        palette.axis = .horizontal
        palette.distribution = .fillEqually
        palette.spacing = 8
        let paletteCard = card(palette)

        let stack = UIStackView(arrangedSubviews: [themeTitle, themeText, previewCard, paletteCard])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: themeText)
        stack.setCustomSpacing(16, after: previewCard)
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
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func card(_ content: UIView) -> UIView {
        let v = UIView()
        v.backgroundColor = L2.surface
        v.layer.cornerRadius = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
        ])
        return v
    }

    private func bubble(_ text: String, incoming: Bool) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = L2.font(16)
        label.textColor = L2.textPrimary
        label.numberOfLines = 0
        let b = UIView()
        b.backgroundColor = incoming ? L2.surface2 : L2.accentStrong
        b.layer.cornerRadius = 18
        label.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(label)
        b.translatesAutoresizingMaskIntoConstraints = false
        let row = UIView()
        row.addSubview(b)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: b.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -14),
            b.topAnchor.constraint(equalTo: row.topAnchor),
            b.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            b.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.8),
            incoming ? b.leadingAnchor.constraint(equalTo: row.leadingAnchor) : b.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    private func swatch(_ color: UIColor, _ name: String) -> UIView {
        let circle = UIView()
        circle.backgroundColor = color
        circle.layer.cornerRadius = 20
        circle.layer.borderWidth = 1
        circle.layer.borderColor = L2.hex(0xFFFFFF, 0.15).cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([circle.widthAnchor.constraint(equalToConstant: 40),
                                     circle.heightAnchor.constraint(equalToConstant: 40)])
        let label = UILabel()
        label.text = name
        label.font = L2.font(11, .medium)
        label.textColor = L2.textSecondary
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        let v = UIStackView(arrangedSubviews: [circle, label])
        v.axis = .vertical
        v.alignment = .center
        v.spacing = 6
        return v
    }
}

// MARK: - О приложении

final class Linia2AboutViewController: UIViewController {
    private static let siteURL = URL(string: "https://\(SharedUtils.kLinia2Host)")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "О приложении"
        view.backgroundColor = L2.background
        navigationItem.largeTitleDisplayMode = .never

        let logo = L2LogoView(size: 34)
        let logoRow = UIStackView(arrangedSubviews: [logo])
        logoRow.axis = .vertical
        logoRow.alignment = .center

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"

        let versionLabel = label("Версия \(version) (сборка \(build))", L2.font(17, .semibold), L2.textPrimary)
        let serverLabel = label("Сервер: \(SharedUtils.kLinia2Host)", L2.font(15), L2.textSecondary)
        let tinodeLabel = label("Основано на Tinode (Apache 2.0)", L2.font(15), L2.textSecondary)

        let infoStack = UIStackView(arrangedSubviews: [versionLabel, serverLabel, tinodeLabel])
        infoStack.axis = .vertical
        infoStack.spacing = 8
        let infoCard = UIView()
        infoCard.backgroundColor = L2.surface
        infoCard.layer.cornerRadius = 20
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoCard.addSubview(infoStack)
        NSLayoutConstraint.activate([
            infoStack.topAnchor.constraint(equalTo: infoCard.topAnchor, constant: 20),
            infoStack.bottomAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: -20),
            infoStack.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -16),
        ])

        let site = L2Button("Открыть \(SharedUtils.kLinia2Host)", kind: .outline, symbol: "safari")
        site.addTarget(self, action: #selector(openSite), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [logoRow, infoCard, site])
        stack.axis = .vertical
        stack.spacing = 24
        stack.setCustomSpacing(36, after: logoRow)
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
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func label(_ text: String, _ font: UIFont, _ color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font
        l.textColor = color
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }

    @objc private func openSite() {
        guard let url = Self.siteURL else { return }
        UIApplication.shared.open(url)
    }
}
