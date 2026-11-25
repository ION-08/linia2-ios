//
//  Linia2ChatStyle.swift
//  Линия 2.0: оформление списка чатов и экрана переписки по макету.
//

import UIKit
import TinodeSDK
import TinodiosDB

// MARK: - Список чатов: шапка, поиск, фильтры «Все / Непрочитанные»

extension ChatListViewController: UITextFieldDelegate {
    func linia2Setup() {
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 100, bottom: 0, right: 20)
        tableView.rowHeight = 88
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInset.bottom = Linia2TabBarController.reservedBottom + 20
        tableView.verticalScrollIndicatorInsets.bottom = Linia2TabBarController.reservedBottom
        linia2InstallHeader()
    }

    func linia2InstallHeader() {
        let addContact = L2CircleButton(symbol: "person.badge.plus", accessibility: "Добавить контакт")
        addContact.addTarget(self, action: #selector(linia2NewChat), for: .touchUpInside)
        let compose = L2CircleButton(symbol: "square.and.pencil", accessibility: "Новый чат")
        compose.addTarget(self, action: #selector(linia2NewChat), for: .touchUpInside)
        let header = L2Header(title: "Чаты", buttons: [addContact, compose])
        let search = L2SearchField()
        search.text = linia2Query
        search.delegate = self
        search.addTarget(self, action: #selector(linia2SearchChanged(_:)), for: .editingChanged)
        let chips = L2Chips(["Все", "Непрочитанные"])
        chips.select(linia2FilterIndex)
        chips.onChange = { [weak self] i in
            self?.linia2FilterIndex = i
            self?.linia2Refilter()
        }
        let h = L2TableHeader([header, search, chips], spacing: 18)
        h.install(in: tableView)
        linia2Header = h
        linia2HeaderWidth = tableView.bounds.width
    }

    func linia2LayoutHeaderIfNeeded() {
        if abs(tableView.bounds.width - linia2HeaderWidth) > 0.5, !(tableView.tableHeaderView?.subviews.contains { $0.isFirstResponder } ?? false) {
            linia2InstallHeader()
        }
    }

    func linia2Filtered(_ all: [DefaultComTopic]) -> [DefaultComTopic] {
        let q = linia2Query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { t in
            if linia2FilterIndex == 1 && t.unread <= 0 { return false }
            guard !q.isEmpty else { return true }
            let name = (t.pub?.fn ?? "").lowercased()
            let tags = (t.tags ?? []).joined(separator: " ").lowercased()
            return name.contains(q) || tags.contains(q)
        }
    }

    func linia2Refilter() {
        topics = linia2Filtered(linia2All)
        rowIndex = Dictionary(uniqueKeysWithValues: topics.enumerated().map { ($0.element.name, $0.offset) })
        tableView.reloadData()
    }

    @objc func linia2SearchChanged(_ f: UITextField) {
        linia2Query = f.text ?? ""
        linia2Refilter()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc func linia2NewChat() {
        performSegue(withIdentifier: "Chats2NewChat", sender: nil)
    }

    func linia2EmptyNote() -> UIView {
        if linia2FilterIndex == 1 { return l2EmptyState("Всё прочитано", "Непрочитанных сообщений нет", symbol: "checkmark.bubble") }
        if !linia2Query.isEmpty { return l2EmptyState("Ничего не найдено", "Попробуйте другое имя", symbol: "magnifyingglass") }
        return l2EmptyState("Чатов пока нет", "Нажмите на карандаш, чтобы начать переписку", symbol: "bubble.left.and.bubble.right")
    }
}

// MARK: - Ячейка чата

extension ChatListViewCell {
    private static let kTimeTag = 0x4C32

    /// Подпись времени справа: сегодня — ЧЧ:ММ, вчера — «Вчера», на неделе — день, иначе — дата.
    static func linia2Time(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return f.string(from: date) }
        if cal.isDateInYesterday(date) { return "Вчера" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            f.dateFormat = "EEEEEE"
            return f.string(from: date).capitalized
        }
        f.dateFormat = "dd.MM.yy"
        return f.string(from: date)
    }

    func linia2Style(_ topic: DefaultComTopic) {
        backgroundColor = L2.background
        contentView.backgroundColor = L2.background
        let sel = UIView()
        sel.backgroundColor = L2.surface
        selectedBackgroundView = sel

        title.font = L2.font(18, .semibold)
        title.textColor = L2.textPrimary
        subtitle.textColor = L2.textSecondary
        if let att = subtitle.attributedText, att.length > 0 {
            let m = NSMutableAttributedString(attributedString: att)
            m.addAttribute(.foregroundColor, value: L2.textSecondary, range: NSRange(location: 0, length: m.length))
            subtitle.attributedText = m
        }

        // Бейдж непрочитанных — фиолетовый круг.
        unreadCount.backgroundColor = L2.accent
        unreadCount.textColor = L2.onAccent
        unreadCount.font = L2.font(13, .bold)
        unreadCount.textAlignment = .center
        unreadCount.layer.cornerRadius = 11
        unreadCount.clipsToBounds = true
        if !unreadCount.isHidden { unreadCountWidth.constant = 22 }

        // Время последней активности справа сверху.
        var time = contentView.viewWithTag(Self.kTimeTag) as? UILabel
        if time == nil {
            let l = UILabel()
            l.tag = Self.kTimeTag
            l.font = L2.font(14)
            l.textAlignment = .right
            l.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(l)
            NSLayoutConstraint.activate([l.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                                         l.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14)])
            time = l
        }
        time?.text = Self.linia2Time(topic.touched)
        time?.textColor = topic.unread > 0 ? L2.accent : L2.textSecondary
    }
}

// MARK: - Индикатор «в сети»: только зелёная точка

extension AvatarWithOnlineIndicator {
    func linia2StyleIndicator() {
        onlineIndicator.layer.borderWidth = 2.5
        onlineIndicator.layer.borderColor = L2.background.cgColor
        if onlineIndicator.backgroundColor != AvatarWithOnlineIndicator.kOnlineColor {
            onlineIndicator.isHidden = true
        }
    }
}

// MARK: - Экран переписки: шапка «аватар + имя + в сети», справа звонок и «⋮»

extension MessageViewController {
    private static let kL2Name = 0x4C41, kL2Status = 0x4C42, kL2Dot = 0x4C43

    private func linia2TitleView() -> UIView {
        if let v = navigationItem.leftBarButtonItem?.customView, v.viewWithTag(Self.kL2Name) != nil { return v }
        let name = UILabel()
        name.tag = Self.kL2Name
        name.font = L2.font(18, .bold)
        name.textColor = L2.textPrimary
        let dot = UIView()
        dot.tag = Self.kL2Dot
        dot.backgroundColor = L2.online
        dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let status = UILabel()
        status.tag = Self.kL2Status
        status.font = L2.font(13)
        status.textColor = L2.textSecondary
        let statusRow = UIStackView(arrangedSubviews: [dot, status])
        statusRow.axis = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .center
        let texts = UIStackView(arrangedSubviews: [name, statusRow])
        texts.axis = .vertical
        texts.spacing = 1
        let row = UIStackView(arrangedSubviews: [navBarAvatarView, texts])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        let tap = UITapGestureRecognizer(target: self, action: #selector(linia2TitleTapped))
        row.addGestureRecognizer(tap)
        row.isUserInteractionEnabled = true
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: row)
        return row
    }

    @objc private func linia2TitleTapped() {
        if topic?.deleted ?? false { return }
        performSegue(withIdentifier: "Messages2TopicInfo", sender: nil)
    }

    func linia2StyleTitleBar(pub: TheCard?, online: Bool?) {
        navigationItem.backButtonDisplayMode = .minimal
        let tv = linia2TitleView()
        (tv.viewWithTag(Self.kL2Name) as? UILabel)?.text = navigationItem.title
        navigationItem.title = nil
        navBarAvatarView.linia2StyleIndicator()
        linia2SetStatus(online)

        var items: [UIBarButtonItem] = []
        let more = UIBarButtonItem(image: L2.symbol("ellipsis", 18, .semibold), style: .plain,
                                   target: self, action: #selector(linia2TitleTapped))
        more.accessibilityLabel = "Информация о чате"
        items.append(more)
        if let t = topic, t.callsAllowed {
            navBarCallBtn.image = L2.symbol("phone", 20, .regular)
            navBarCallBtn.accessibilityLabel = "Позвонить"
            items.append(navBarCallBtn)
        }
        navigationItem.setRightBarButtonItems(items, animated: false)
    }

    func linia2SetStatus(_ online: Bool?) {
        guard let tv = navigationItem.leftBarButtonItem?.customView else { return }
        let status = tv.viewWithTag(Self.kL2Status) as? UILabel
        let dot = tv.viewWithTag(Self.kL2Dot)
        if topic?.isSlfType ?? false {
            status?.text = "заметки для себя"
            dot?.isHidden = true
        } else if topic?.isGrpType ?? false {
            status?.text = online == true ? "кто-то в сети" : "группа"
            dot?.isHidden = online != true
        } else {
            status?.text = online == true ? "в сети" : "не в сети"
            dot?.isHidden = online != true
        }
    }

    func linia2SetTyping() {
        guard let tv = navigationItem.leftBarButtonItem?.customView,
              let status = tv.viewWithTag(Self.kL2Status) as? UILabel else { return }
        status.text = "печатает…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.linia2SetStatus(self?.topic?.online)
        }
    }
}

// MARK: - Панель ввода: «+», поле «Сообщение», фиолетовая кнопка микрофона/отправки

extension SendMessageBar {
    func linia2Style(container: UIView) {
        container.backgroundColor = L2.background
        inputField.backgroundColor = L2.surface
        inputField.layer.cornerRadius = 20
        inputField.placeholderText = "Сообщение"
        inputField.font = L2.font(17)
        inputField.keyboardAppearance = .dark
        attachButton.setImage(L2.symbol("plus", 20, .medium), for: .normal)
        attachButton.tintColor = L2.textPrimary
        attachButton.backgroundColor = L2.surface
        attachButton.layer.cornerRadius = 18
        sendButton.tintColor = L2.accent
    }
}
