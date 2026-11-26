//
//  Linia2Profile.swift
//  Линия 2.0: экран «Профиль» — фото, имя, @псевдоним, описание, контакты, удаление аккаунта.
//  Логика сохранения повторяет AccountGeneralSettingsViewController (Tinode):
//  имя и описание — в pub (fn, note), псевдоним — уникальный тег «alias:».
//

import UIKit
import TinodeSDK

final class Linia2ProfileViewController: Linia2FormViewController, UITextFieldDelegate, UITextViewDelegate,
                                         UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let avatar = RoundImageView()
    private let photoButton = UIButton(type: .system)
    private let nameField = UITextField()
    private let aliasField = UITextField()
    private let aboutView = UITextView()
    private let aboutPlaceholder = UILabel()
    private let aliasHint = UILabel()
    private let saveButton = L2Button("Сохранить")
    private let deleteButton = L2Button("Удалить аккаунт", kind: .destructive, symbol: "trash")
    private let contactsStack = UIStackView()
    private var aliasCard: UIView?
    private var loaded = false

    private var me: DefaultMeTopic? { Cache.tinode.getMeTopic() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Профиль"
        navigationItem.largeTitleDisplayMode = .never
        stack.spacing = 12
        // Под плавающим нижним меню: без запаса снизу «Удалить аккаунт» оказывалась под меню
        // и не нажималась (прокрутить было некуда — содержимое ровно по высоте экрана).
        scroll.contentInset.bottom = Linia2TabBarController.reservedBottom
        scroll.verticalScrollIndicatorInsets.bottom = Linia2TabBarController.reservedBottom
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(textViewBegan(_:)),
                                               name: UITextView.textDidBeginEditingNotification, object: aboutView)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !loaded {
            loaded = true
            reloadData()
        } else {
            reloadAvatarAndContacts()
        }
    }

    // MARK: Вёрстка

    private func build() {
        // Аватар и кнопка «Изменить фото».
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 120).isActive = true
        avatar.isUserInteractionEnabled = true
        avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(changePhoto)))
        avatar.accessibilityLabel = "Фото профиля"
        photoButton.setTitle("Изменить фото", for: .normal)
        photoButton.setTitleColor(L2.accent, for: .normal)
        photoButton.titleLabel?.font = L2.font(16, .semibold)
        photoButton.addTarget(self, action: #selector(changePhoto), for: .touchUpInside)
        photoButton.accessibilityIdentifier = "l2.profile.photo"
        let avatarColumn = UIStackView(arrangedSubviews: [avatar, photoButton])
        avatarColumn.axis = .vertical
        avatarColumn.alignment = .center
        avatarColumn.spacing = 10
        stack.addArrangedSubview(avatarColumn)
        stack.setCustomSpacing(24, after: avatarColumn)

        // Имя.
        configure(nameField, placeholder: "Ваше имя")
        nameField.textContentType = .name
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .next
        nameField.accessibilityIdentifier = "l2.profile.name"
        stack.addArrangedSubview(fieldCard("Имя", nameField))

        // Псевдоним.
        configure(aliasField, placeholder: "псевдоним")
        aliasField.autocapitalizationType = .none
        aliasField.autocorrectionType = .no
        aliasField.spellCheckingType = .no
        aliasField.keyboardType = .asciiCapable
        aliasField.returnKeyType = .done
        aliasField.accessibilityIdentifier = "l2.profile.alias"
        aliasField.addTarget(self, action: #selector(aliasChanged), for: .editingChanged)
        let at = UILabel()
        at.text = "@"
        at.font = L2.font(17, .semibold)
        at.textColor = L2.accent
        at.setContentHuggingPriority(.required, for: .horizontal)
        let aliasRow = UIStackView(arrangedSubviews: [at, aliasField])
        aliasRow.axis = .horizontal
        aliasRow.spacing = 2
        let card = fieldCard("Псевдоним", aliasRow)
        aliasCard = card
        stack.addArrangedSubview(card)
        aliasHint.font = L2.font(13)
        aliasHint.textColor = L2.textSecondary
        aliasHint.numberOfLines = 0
        aliasHint.text = "По псевдониму вас смогут найти собеседники. Латинские буквы и цифры."
        stack.addArrangedSubview(aliasHint)

        // Описание.
        aboutView.backgroundColor = .clear
        aboutView.font = L2.font(17)
        aboutView.textColor = L2.textPrimary
        aboutView.tintColor = L2.accent
        aboutView.isScrollEnabled = false
        aboutView.textContainerInset = .zero
        aboutView.textContainer.lineFragmentPadding = 0
        aboutView.delegate = self
        aboutView.accessibilityIdentifier = "l2.profile.about"
        aboutView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        aboutPlaceholder.text = "Пара слов о себе (необязательно)"
        aboutPlaceholder.font = L2.font(17)
        aboutPlaceholder.textColor = L2.textSecondary
        aboutPlaceholder.numberOfLines = 0
        aboutPlaceholder.isUserInteractionEnabled = false
        aboutPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        aboutView.addSubview(aboutPlaceholder)
        NSLayoutConstraint.activate([
            aboutPlaceholder.topAnchor.constraint(equalTo: aboutView.topAnchor),
            aboutPlaceholder.leadingAnchor.constraint(equalTo: aboutView.leadingAnchor),
            aboutPlaceholder.widthAnchor.constraint(equalTo: aboutView.widthAnchor),
        ])
        stack.addArrangedSubview(fieldCard("Описание", aboutView))

        saveButton.accessibilityIdentifier = "l2.profile.save"
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last ?? aboutView)
        stack.addArrangedSubview(saveButton)

        // Контакты.
        let contactsTitle = sectionTitle("Контакты")
        stack.setCustomSpacing(30, after: saveButton)
        stack.addArrangedSubview(contactsTitle)
        contactsStack.axis = .vertical
        contactsStack.spacing = 12
        stack.addArrangedSubview(contactsStack)

        // Удаление аккаунта.
        deleteButton.accessibilityIdentifier = "l2.profile.delete"
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        stack.setCustomSpacing(36, after: contactsStack)
        stack.addArrangedSubview(deleteButton)
        let deleteHint = UILabel()
        deleteHint.text = "Профиль, переписка и данные на сервере будут удалены без возможности восстановления."
        deleteHint.font = L2.font(13)
        deleteHint.textColor = L2.textSecondary
        deleteHint.textAlignment = .center
        deleteHint.numberOfLines = 0
        stack.addArrangedSubview(deleteHint)
    }

    private func configure(_ f: UITextField, placeholder: String) {
        f.font = L2.font(17)
        f.textColor = L2.textPrimary
        f.tintColor = L2.accent
        f.borderStyle = .none
        f.backgroundColor = .clear
        f.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: L2.textSecondary])
        f.delegate = self
        f.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func sectionTitle(_ t: String) -> UILabel {
        let l = UILabel()
        l.text = t.uppercased()
        l.font = L2.font(13, .semibold)
        l.textColor = L2.textSecondary
        return l
    }

    /// Карточка-поле: подпись сверху, содержимое ниже.
    private func fieldCard(_ caption: String, _ content: UIView) -> UIView {
        let c = UIView()
        c.backgroundColor = L2.surface
        c.layer.cornerRadius = 18
        c.layer.borderWidth = 1
        c.layer.borderColor = UIColor.clear.cgColor
        let cap = UILabel()
        cap.text = caption
        cap.font = L2.font(13, .medium)
        cap.textColor = L2.textSecondary
        let v = UIStackView(arrangedSubviews: [cap, content])
        v.axis = .vertical
        v.spacing = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -16),
        ])
        return c
    }

    /// Карточка только для чтения (контакты, логин, ID). Нажатие копирует значение.
    private func infoCard(_ caption: String, _ value: String, note: String? = nil) -> UIView {
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = L2.font(17)
        valueLabel.textColor = L2.textPrimary
        valueLabel.numberOfLines = 0
        var content: UIView = valueLabel
        if let note = note {
            let n = UILabel()
            n.text = note
            n.font = L2.font(13, .medium)
            n.textColor = L2.danger
            let row = UIStackView(arrangedSubviews: [valueLabel, UIView(), n])
            row.axis = .horizontal
            row.spacing = 8
            content = row
        }
        let card = fieldCard(caption, content)
        let btn = L2CopyControl(value: value)
        btn.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: card.topAnchor),
            btn.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            btn.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        btn.accessibilityLabel = caption + ": " + value
        return card
    }

    // MARK: Данные

    private func reloadData() {
        guard let me = me else {
            UiUtils.showToast(message: "Профиль ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        nameField.text = me.pub?.fn
        aliasField.text = me.alias
        let note = me.pub?.note ?? ""
        aboutView.text = note == Tinode.kNullValue ? "" : note
        updatePlaceholder()
        reloadAvatarAndContacts()
    }

    private func reloadAvatarAndContacts() {
        let me = self.me
        avatar.set(pub: me?.pub, id: Cache.tinode.myUid, deleted: false)
        avatar.letterTileFont = L2.rounded(46, .semibold)

        contactsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for cred in me?.creds ?? [] {
            guard let val = cred.val, !val.isEmpty else { continue }
            let caption: String
            switch cred.meth {
            case "email": caption = "Эл. почта"
            case "tel": caption = "Телефон"
            default: caption = cred.meth ?? "Контакт"
            }
            contactsStack.addArrangedSubview(infoCard(caption, val, note: cred.isDone ? nil : "не подтверждён"))
        }
        if let login = Linia2Profile.login {
            contactsStack.addArrangedSubview(infoCard("Логин", "@" + login))
        }
        if let uid = Cache.tinode.myUid {
            contactsStack.addArrangedSubview(infoCard("ID", uid))
        }
    }

    private func updatePlaceholder() {
        aboutPlaceholder.isHidden = !(aboutView.text ?? "").isEmpty
    }

    private func setAliasInvalid(_ invalid: Bool) {
        aliasCard?.layer.borderColor = (invalid ? L2.danger : UIColor.clear).cgColor
    }

    private static func cleanAlias(_ s: String?) -> String {
        var a = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while a.hasPrefix("@") { a.removeFirst() }
        return a
    }

    // MARK: Действия

    @objc private func aliasChanged() {
        let a = Self.cleanAlias(aliasField.text)
        let ok = Tinode.isValidTagValueFormat(tag: a)
        setAliasInvalid(!ok)
        aliasHint.textColor = ok ? L2.textSecondary : L2.danger
        aliasHint.text = ok ? "По псевдониму вас смогут найти собеседники. Латинские буквы и цифры."
            : "Недопустимый псевдоним: используйте латинские буквы и цифры."
    }

    @objc private func textViewBegan(_ n: Notification) {
        DispatchQueue.main.async { [weak self] in self?.revealFirstResponder() }
    }

    @objc private func saveTapped() {
        view.endEditing(true)
        guard let me = me else {
            UiUtils.showToast(message: "Профиль ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            UiUtils.showToast(message: "Укажите имя.")
            return
        }
        let alias = Self.cleanAlias(aliasField.text)
        guard Tinode.isValidTagValueFormat(tag: alias) else {
            setAliasInvalid(true)
            UiUtils.showToast(message: "Недопустимый псевдоним: используйте латинские буквы и цифры.")
            return
        }

        // Как в AccountGeneralSettingsViewController.doneEditingClicked.
        var pub: TheCard? = nil
        if name != me.pub?.fn {
            pub = TheCard(fn: name)
        }
        let desc = (aboutView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let oldNote = me.pub?.note ?? ""
        let oldDesc = oldNote == Tinode.kNullValue ? "" : oldNote
        if desc != oldDesc {
            let card = pub ?? TheCard()
            card.note = desc.isEmpty ? Tinode.kNullValue : desc
            pub = card
        }
        var tags: [String]? = nil
        if alias != (me.alias ?? "") {
            if !alias.isEmpty {
                tags = Tinode.setUniqueTag(tags: me.tags, uniqueTag: "\(Tinode.kTagAlias)\(alias)")
            } else {
                tags = Tinode.clearTagPrefix(tags: me.tags, prefix: Tinode.kTagAlias)
            }
            if let t = tags, t.sorted() == (me.tags ?? []).sorted() {
                tags = nil
            }
        }

        // LINIA2: теги поиска пересчитывает сервер при смене имени (Tinode не принимает от клиента теги без префикса).

        if pub == nil && tags == nil {
            UiUtils.showToast(message: "Изменений нет", level: .info)
            return
        }

        setBusy(true, button: saveButton, title: "Сохранить")
        let desc2: MetaSetDesc<TheCard, PrivateType>? = pub != nil ? MetaSetDesc<TheCard, PrivateType>(pub: pub, priv: nil) : nil
        me.setMeta(meta: MsgSetMeta<TheCard, PrivateType>(desc: desc2, tags: tags)).then(
            onSuccess: { [weak self] msg in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setBusy(false, button: self.saveButton, title: "Сохранить")
                    if let code = msg?.ctrl?.code, code >= 300 {
                        UiUtils.showToast(message: "Не удалось сохранить профиль (\(code)).")
                    } else {
                        UiUtils.showToast(message: "Профиль сохранён", level: .info)
                        self.reloadData()
                    }
                }
                return nil
            },
            onFailure: { [weak self] err in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setBusy(false, button: self.saveButton, title: "Сохранить")
                    UiUtils.showToast(message: Self.errorText(err, tagsChanged: tags != nil))
                }
                return nil
            })
    }

    private static func errorText(_ err: Error, tagsChanged: Bool) -> String {
        if let e = err as? TinodeError {
            switch e {
            case .notConnected:
                return Linia2API.networkError
            case .serverResponseError(let code, _, _):
                if code == 409 && tagsChanged { return "Этот псевдоним уже занят. Выберите другой." }
                return "Не удалось сохранить профиль (\(code)). Попробуйте ещё раз."
            default:
                break
            }
        }
        return "Не удалось сохранить профиль. Проверьте интернет и попробуйте ещё раз."
    }

    // MARK: Фото

    @objc private func changePhoto() {
        view.endEditing(true)
        guard me != nil else {
            UiUtils.showToast(message: "Профиль ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        let sheet = UIAlertController(title: "Фото профиля", message: nil, preferredStyle: .actionSheet)
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(title: "Сделать фото", style: .default) { [weak self] _ in
                self?.presentPicker(.camera)
            })
        }
        if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
            sheet.addAction(UIAlertAction(title: "Выбрать из галереи", style: .default) { [weak self] _ in
                self?.presentPicker(.photoLibrary)
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        Linia2Moderation.anchor(sheet, in: self, sourceView: photoButton, barItem: nil)
        present(sheet, animated: true)
    }

    private func presentPicker(_ source: UIImagePickerController.SourceType) {
        guard UIImagePickerController.isSourceTypeAvailable(source) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = source
        picker.mediaTypes = ["public.image"]
        picker.allowsEditing = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let picked = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
        picker.dismiss(animated: true)
        guard let image = picked, let me = me else { return }
        let fixed = image.fixedOrientation() ?? image
        photoButton.isEnabled = false
        photoButton.setTitle("Загрузка…", for: .normal)
        // Как в AccountGeneralSettingsViewController: UiUtils.updateAvatar сам показывает ошибки.
        UiUtils.updateAvatar(forTopic: me, image: fixed).then(
            onSuccess: { [weak self] msg in
                DispatchQueue.main.async {
                    self?.photoDone()
                    if let code = msg?.ctrl?.code, code < 300 {
                        UiUtils.showToast(message: "Фото обновлено", level: .info)
                    }
                }
                return nil
            },
            onFailure: { [weak self] _ in
                DispatchQueue.main.async { self?.photoDone() }
                return nil
            })
    }

    private func photoDone() {
        photoButton.isEnabled = true
        photoButton.setTitle("Изменить фото", for: .normal)
        reloadAvatarAndContacts()
    }

    // MARK: Удаление аккаунта

    @objc private func deleteTapped() {
        view.endEditing(true)
        let alert = UIAlertController(title: "Удалить аккаунт навсегда?",
                                      message: "Будут удалены профиль, переписка и данные на сервере. Отменить нельзя.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            self?.deleteAccount()
        })
        present(alert, animated: true)
    }

    private func deleteAccount() {
        let tinode = Cache.tinode
        guard tinode.isConnected, tinode.myUid != nil else {
            UiUtils.showToast(message: Linia2API.networkError)
            return
        }
        setBusy(true, button: deleteButton, title: "Удалить аккаунт")
        tinode.delCurrentUser(hard: true).then(
            onSuccess: { _ in
                DispatchQueue.main.async {
                    UiUtils.logoutAndRouteToLoginVC()
                    UiUtils.showToast(message: "Аккаунт удалён", level: .info)
                }
                return nil
            },
            onFailure: { [weak self] err in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.setBusy(false, button: self.deleteButton, title: "Удалить аккаунт")
                    if let e = err as? TinodeError, case .notConnected = e {
                        UiUtils.showToast(message: Linia2API.networkError)
                    } else {
                        UiUtils.showToast(message: "Не удалось удалить аккаунт. Попробуйте ещё раз.")
                    }
                }
                return nil
            })
    }

    // MARK: UITextFieldDelegate / UITextViewDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField {
            aliasField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let newLength = (textField.text ?? "").count + (string.count - range.length)
        if textField === aliasField {
            return newLength <= UiUtils.kMaxAliasLength
        }
        return newLength <= UiUtils.kMaxTitleLength
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        return (textView.text ?? "").count + (text.count - range.length) <= UiUtils.kMaxTopicDescriptionLength
    }
}

/// Прозрачная кнопка поверх карточки: копирует значение в буфер обмена.
private final class L2CopyControl: UIControl {
    private let value: String

    init(value: String) {
        self.value = value
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Нажмите, чтобы скопировать"
        addTarget(self, action: #selector(copyValue), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? L2.surface2.withAlphaComponent(0.5) : .clear } }

    @objc private func copyValue() {
        UIPasteboard.general.string = value
        L2.haptic()
        UiUtils.showToast(message: "Скопировано", level: .info)
    }
}


// MARK: - Теги поиска (как auth/l2tags.py на сервере)

enum Linia2SearchTags {
    static let maxTags = 16

    private static func clean(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
    }

    /// Логин, слова имени и начала (от 2 букв) логина и первых двух слов.
    static func compute(login: String, name: String) -> [String] {
        let login = login.lowercased()
        if login.hasPrefix("l2-") { return [] }
        if login.range(of: "^ci[0-9]+[lr]?$", options: .regularExpression) != nil {
            // тестовые: точный логин и слова имени с цифрами (уникальные метки автотестов)
            let uniq = name.lowercased().components(separatedBy: .whitespaces).map(clean)
                .filter { $0.count >= 4 && $0.rangeOfCharacter(from: .decimalDigits) != nil && $0 != login }
            return [login] + uniq
        }
        var out: [String] = []
        func add(_ t: String) {
            let c = clean(t)
            if c.count >= 2 && c.count <= 96 && !out.contains(c) { out.append(c) }
        }
        add(login)
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .filter { clean($0).count >= 2 }.prefix(4)
        words.forEach { add($0) }
        for src in [login] + Array(words.prefix(2)) {
            let c = clean(src)
            if c.count > 2 { for n in 2..<min(c.count, 12) { add(String(c.prefix(n))) } }
        }
        return out
    }

    /// Сохраняет служебные теги (basic:, alias: …) и заменяет теги поиска на новые.
    static func merge(existing: [String], name: String) -> [String] {
        let prefixed = existing.filter { $0.contains(":") }
        guard let login = prefixed.first(where: { $0.hasPrefix("basic:") }).map({ String($0.dropFirst(6)) }) else { return existing }
        let mine = compute(login: login, name: name).filter { !prefixed.contains($0) }
        return Array((prefixed + mine).prefix(maxTags))
    }
}
