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
    /// L2_PROFEDIT: «✓ Сохранено» после успешного сохранения.
    private let doneLabel = UILabel()
    /// Сохранённые значения — «Сохранить» показывается только при отличии полей от них.
    private var orig = (fn: "", note: "", alias: "")
    /// Проверка занятости псевдонима (fnd «alias:<x>»): для какого значения, итог, идёт ли.
    private var check = (value: "", taken: false, busy: false)
    private var checkTimer: Timer?
    private var saving = false
    private var doneTimer: Timer?
    static let aliasRegex = "^[a-z0-9_]{3,32}$"
    static let aliasHelp = "Латиница, цифры и _, от 3 до 32 символов. По псевдониму вас смогут найти."

    private var me: DefaultMeTopic? { Cache.tinode.getMeTopic() }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }
    /// Дизайн: единая сетка — карточки настроек в 16 pt от края (как «Настройки»), было 28.
    override var sideMargin: CGFloat { 16 }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Профиль"
        navigationItem.largeTitleDisplayMode = .never
        stack.spacing = 12
        // Низ области прокрутки — над плавающим нижним меню (безопасная зона снизу + меню). Отступ contentInset
        // не помогал: кнопка «Удалить аккаунт» оставалась в границах прокрутки, но под меню — прокрутка и
        // «scroll to visible» считали её видимой, а нажать было нельзя.
        // Профиль — вложенный экран: нижнего меню здесь нет (27.11), запас снизу не нужен.
        additionalSafeAreaInsets.bottom = 0
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
        aliasField.textContentType = .username
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
        aliasHint.text = Self.aliasHelp
        aliasHint.accessibilityIdentifier = "l2.profile.aliasHint"
        stack.addArrangedSubview(aliasHint)
        nameField.addTarget(self, action: #selector(fieldsChanged), for: .editingChanged)

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
        saveButton.isHidden = true
        // «✓ Сохранено» — вместо кнопки после сохранения (L2_PROFEDIT, как в вебе).
        let doneText = NSMutableAttributedString(attributedString: NSAttributedString(attachment: NSTextAttachment(image: L2.symbol("checkmark", 15, .bold)?.withTintColor(L2.accent, renderingMode: .alwaysOriginal) ?? UIImage())))
        doneText.append(NSAttributedString(string: " Сохранено", attributes: [.foregroundColor: L2.accent, .font: L2.font(16, .semibold)]))
        doneLabel.attributedText = doneText
        doneLabel.textAlignment = .center
        doneLabel.accessibilityIdentifier = "l2.profile.saved"
        doneLabel.accessibilityLabel = "Сохранено"
        doneLabel.isHidden = true
        let saveBar = UIStackView(arrangedSubviews: [saveButton, doneLabel])
        saveBar.axis = .vertical
        saveBar.spacing = 0
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last ?? aboutView)
        stack.addArrangedSubview(saveBar)

        // Контакты.
        let contactsTitle = sectionTitle("Контакты")
        stack.setCustomSpacing(30, after: saveBar)
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
        let note = me.pub?.note ?? ""
        orig = (fn: (me.pub?.fn ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                note: (note == Tinode.kNullValue ? "" : note).trimmingCharacters(in: .whitespacesAndNewlines),
                alias: Self.aliasOf(me.tags))
        nameField.text = orig.fn
        aliasField.text = orig.alias
        aboutView.text = orig.note
        updatePlaceholder()
        reloadAvatarAndContacts()
        updateState()
        // Теги me могли ещё не прийти или устареть — подтянуть с сервера и показать текущий псевдоним.
        Self.fetchTags(me) { [weak self] tags in
            guard let self = self, let tags = tags else { return }
            let a0 = Self.aliasOf(tags)
            if a0 != self.orig.alias {
                let untouched = self.aliasValue == self.orig.alias
                self.orig.alias = a0
                if untouched { self.aliasField.text = a0 }
            }
            self.updateState()
        }
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
        var v = aliasField.text ?? ""
        while v.hasPrefix("@") { v.removeFirst() }
        if v != aliasField.text { aliasField.text = v }
        check = (value: "", taken: false, busy: false)
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in self?.runCheck(nil) }
        updateState()
    }

    @objc private func fieldsChanged() {
        updateState()
    }

    @objc private func textViewBegan(_ n: Notification) {
        DispatchQueue.main.async { [weak self] in self?.revealFirstResponder() }
    }

    // MARK: L2_PROFEDIT: состояние формы, проверка и сохранение (повторяет веб apply-profedit.py)

    private var aliasValue: String { Self.cleanAlias(aliasField.text).lowercased() }
    private var nameValue: String { (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var noteValue: String { (aboutView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    static func aliasOf(_ tags: [String]?) -> String {
        guard let t = (tags ?? []).first(where: { $0.hasPrefix(Tinode.kTagAlias) }) else { return "" }
        return String(t.dropFirst(Tinode.kTagAlias.count))
    }

    static func aliasFormatError(_ a: String) -> String? {
        if a.isEmpty || a.range(of: aliasRegex, options: .regularExpression) != nil { return nil }
        if a.count < 3 { return "Не короче 3 символов" }
        if a.range(of: "[^a-z0-9_]", options: .regularExpression) != nil { return "Только латинские буквы, цифры и _" }
        return "Не длиннее 32 символов"
    }

    private enum AliasState { case ok, free, pending, bad(String) }

    private func aliasState() -> AliasState {
        let a = aliasValue
        if a.isEmpty { return .ok }
        if let e = Self.aliasFormatError(a) { return .bad(e) }
        if a == orig.alias { return .ok }
        if check.value == a && !check.busy { return check.taken ? .bad("Псевдоним занят") : .free }
        return .pending
    }

    private var isDirty: Bool { nameValue != orig.fn || noteValue != orig.note || aliasValue != orig.alias }

    private func updateState() {
        let st = aliasState()
        var ok = true, pending = false
        switch st {
        case .bad(let msg):
            ok = false
            aliasHint.text = msg
            aliasHint.textColor = L2.danger
        case .pending:
            pending = true
            aliasHint.text = "Проверяем…"
            aliasHint.textColor = L2.textSecondary
        case .free:
            aliasHint.text = "Псевдоним свободен"
            aliasHint.textColor = L2.accent
        case .ok:
            aliasHint.text = Self.aliasHelp
            aliasHint.textColor = L2.textSecondary
        }
        setAliasInvalid(!ok)
        let dirty = isDirty
        if saveButton.isHidden == dirty { saveButton.isHidden = !dirty }
        if dirty { doneLabel.isHidden = true }
        saveButton.isEnabled = !saving && ok && !pending && !nameValue.isEmpty
        saveButton.alpha = saveButton.isEnabled || saving ? 1 : 0.55
    }

    /// Проверить занятость текущего псевдонима; completion — на главном потоке.
    private func runCheck(_ completion: (() -> Void)?) {
        checkTimer?.invalidate()
        let a = aliasValue
        if a.isEmpty || a == orig.alias || Self.aliasFormatError(a) != nil || (check.value == a && !check.busy) {
            updateState()
            completion?()
            return
        }
        check = (value: a, taken: false, busy: true)
        updateState()
        Self.aliasTaken(a) { [weak self] taken in
            guard let self = self else { return }
            if self.check.value == a {
                // Нет ответа — не мешаем: сервер всё равно не примет занятый псевдоним.
                self.check = (value: a, taken: taken ?? false, busy: false)
            }
            self.updateState()
            completion?()
        }
    }

    /// Занят ли псевдоним: точный поиск fnd «alias:<x>»; nil — не удалось проверить. completion — на главном потоке.
    static func aliasTaken(_ alias: String, completion: @escaping (Bool?) -> Void) {
        let tinode = Cache.tinode
        guard tinode.isConnected, let myUid = tinode.myUid else { completion(nil); return }
        let fnd = tinode.getOrCreateFndTopic()
        let tag = Tinode.kTagAlias + alias
        let start: PromisedReply<ServerMessage> = fnd.attached ? PromisedReply<ServerMessage>(value: ServerMessage()) : fnd.subscribe(set: nil, get: nil)
        start.thenApply { _ in
            return fnd.setMeta(desc: MetaSetDesc(pub: tag, priv: nil))
        }.thenApply { _ in
            return fnd.getMeta(query: MsgGetMeta.sub())
        }.then(onSuccess: { msg in
            var taken = false
            if msg?.ctrl?.code != 204 {
                for s in msg?.meta?.sub ?? [] {
                    guard let uid = s.user ?? s.topic, uid != myUid else { continue }
                    let tags = (s as? Subscription<TheCard, [String]>)?.priv ?? []   // в fnd private — совпавшие теги
                    if tags.isEmpty || tags.contains(tag) { taken = true }
                }
            }
            DispatchQueue.main.async { completion(taken) }
            return nil
        }, onFailure: { _ in
            DispatchQueue.main.async { completion(nil) }
            return nil
        })
    }

    /// Свежие теги me с сервера (nil — не получили). completion — на главном потоке.
    /// strict — только ответ сервера (для проверки после сохранения), иначе при пустом ответе — кэш me.tags.
    static func fetchTags(_ me: DefaultMeTopic, strict: Bool = false, completion: @escaping ([String]?) -> Void) {
        me.getMeta(query: me.metaGetBuilder().withTags().build()).then(onSuccess: { msg in
            let tags = msg?.meta?.tags ?? (strict ? [] : (me.tags ?? []))
            DispatchQueue.main.async { completion(tags) }
            return nil
        }, onFailure: { _ in
            DispatchQueue.main.async { completion(nil) }
            return nil
        })
    }

    /// Новые теги: свой alias: заменить; при превышении лимита — убрать самые короткие теги поиска без префикса.
    static func tagsWithAlias(_ current: [String], alias: String) -> [String] {
        var tags = current.filter { !$0.hasPrefix(Tinode.kTagAlias) }
        if !alias.isEmpty { tags.append(Tinode.kTagAlias + alias) }
        while tags.count > Linia2SearchTags.maxTags {
            let plain = tags.filter { !$0.contains(":") }
            guard let victim = plain.min(by: { $0.count < $1.count }), let i = tags.firstIndex(of: victim) else { break }
            tags.remove(at: i)
        }
        return tags
    }

    @objc private func saveTapped() {
        guard !saving, isDirty else { return }
        guard me != nil else {
            UiUtils.showToast(message: "Профиль ещё загружается, попробуйте через пару секунд.", level: .warning)
            return
        }
        runCheck { [weak self] in self?.doSave() }
    }

    private func doSave() {
        guard !saving, isDirty, let me = me else { return }
        let st = aliasState()
        updateState()
        if case .bad = st { aliasField.becomeFirstResponder(); return }
        if case .pending = st { return }
        if nameValue.isEmpty {
            nameField.becomeFirstResponder()
            UiUtils.showToast(message: "Укажите имя.")
            return
        }
        view.endEditing(true)
        saving = true
        setBusy(true, button: saveButton, title: "Сохранить")
        saveButton.setTitle("Сохраняем…", for: .normal)
        let nfn = String(nameValue.prefix(60)), nnote = String(noteValue.prefix(360)), a = aliasValue
        let descChanged = nfn != orig.fn || nnote != orig.note
        let aliasChanged = a != orig.alias

        func finish(_ error: String?) {
            saving = false
            setBusy(false, button: saveButton, title: "Сохранить")
            if let e = error {
                updateState()
                UiUtils.showToast(message: "Не удалось сохранить: " + e)
                return
            }
            updateState()
            doneLabel.isHidden = false
            doneTimer?.invalidate()
            doneTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                guard let self = self, !self.isDirty else { return }
                self.doneLabel.isHidden = true
            }
            L2.haptic()
        }

        func saveAlias() {
            guard aliasChanged else { finish(nil); return }
            Self.fetchTags(me) { [weak self] cur in
                guard let self = self else { return }
                guard let cur = cur else { finish("нет связи с сервером"); return }
                let tags = Self.tagsWithAlias(cur, alias: a)
                me.setMeta(meta: MsgSetMeta<TheCard, PrivateType>(desc: nil, tags: tags)).then(onSuccess: { _ in
                    DispatchQueue.main.async {
                        Self.fetchTags(me, strict: true) { [weak self] now in
                            guard let self = self else { return }
                            if Self.aliasOf(now) != a {
                                finish(a.isEmpty ? "псевдоним не удалился" : "псевдоним не сохранился")
                            } else {
                                self.orig.alias = a
                                finish(nil)
                            }
                        }
                    }
                    return nil
                }, onFailure: { err in
                    DispatchQueue.main.async {
                        if let e = err as? TinodeError, case .serverResponseError(let code, _, _) = e, code == 409 {
                            self.check = (value: a, taken: true, busy: false)
                            finish("псевдоним занят")
                        } else {
                            finish(Self.errorText(err))
                        }
                    }
                    return nil
                })
            }
        }

        guard descChanged else { saveAlias(); return }
        let card = TheCard()
        if nfn != orig.fn { card.fn = nfn }
        if nnote != orig.note { card.note = nnote.isEmpty ? Tinode.kNullValue : nnote }
        me.setMeta(meta: MsgSetMeta<TheCard, PrivateType>(desc: MetaSetDesc<TheCard, PrivateType>(pub: card, priv: nil), tags: nil)).then(
            onSuccess: { [weak self] msg in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let code = msg?.ctrl?.code, code >= 300, code != 304 {
                        finish("ошибка \(code)")
                        return
                    }
                    self.orig.fn = nfn
                    self.orig.note = nnote
                    saveAlias()
                }
                return nil
            },
            onFailure: { err in
                DispatchQueue.main.async { finish(Self.errorText(err)) }
                return nil
            })
    }

    private static func errorText(_ err: Error) -> String {
        if let e = err as? TinodeError {
            switch e {
            case .notConnected:
                return "нет связи с сервером"
            case .serverResponseError(let code, _, _):
                return "ошибка \(code)"
            default:
                break
            }
        }
        return "нет связи с сервером"
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

    /// Return в имени или псевдониме — сохранить (как Enter в вебе); без изменений — к следующему полю / скрыть клавиатуру.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if isDirty {
            saveTapped()
        } else if textField === nameField {
            aliasField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let newLength = (textField.text ?? "").count + (string.count - range.length)
        if textField === aliasField {
            return newLength <= 33   // «@» + 32
        }
        return newLength <= UiUtils.kMaxTitleLength
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholder()
        updateState()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        return (textView.text ?? "").count + (text.count - range.length) <= 360
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
