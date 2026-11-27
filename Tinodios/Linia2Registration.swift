//
//  Linia2Registration.swift
//  Линия 2.0: первый запуск — «Добро пожаловать», код приглашения (6 ячеек), регистрация, вход,
//  создание PIN-кода и предложение Face ID, затем «Чаты».
//

import UIKit
import TinodeSDK
import TinodiosDB

// MARK: - Совместимость со старым кодом (цвета из дизайн-системы)

enum Linia2Style {
    static var dark: UIColor { L2.background }
    static var green: UIColor { L2.accent }
    static var errorRed: UIColor { L2.danger }
}

// MARK: - API сервера регистрации

enum Linia2API {
    static var base: String { "https://\(SharedUtils.kLinia2Host)/invite/api/" }

    /// POST JSON, ответ — JSON-словарь. Колбэк вызывается на главном потоке.
    static func post(_ path: String, _ body: [String: Any], token: String? = nil,
                     completion: @escaping (_ status: Int, _ json: [String: Any]?) -> Void) {
        guard let url = URL(string: base + path) else { completion(0, nil); return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { completion(status, json) }
        }.resume()
    }

    static let networkError = "Нет связи с сервером. Проверьте интернет и попробуйте ещё раз."
}

// MARK: - Вход (общий для экрана входа и регистрации)

enum Linia2Auth {
    /// Вход по логину и паролю. Колбэк на главном потоке: nil — успех, иначе текст ошибки.
    static func login(_ login: String, _ password: String, completion: @escaping (String?) -> Void) {
        attemptLogin(login, password, retriesLeft: 2, completion: completion)
    }

    /// Сразу после «Выйти» соединение ещё закрывается, и первая попытка входа падает сетевой ошибкой
    /// («Нет связи с сервером»), хотя сеть есть. Ошибку соединения (не ответ сервера) повторяем
    /// с новым соединением через 1 с, до двух раз; неверный пароль и прочие ответы сервера — сразу.
    private static func attemptLogin(_ login: String, _ password: String, retriesLeft: Int, completion: @escaping (String?) -> Void) {
        let tinode = Cache.tinode
        let retry: () -> Bool = {
            guard retriesLeft > 0 else { return false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                attemptLogin(login, password, retriesLeft: retriesLeft - 1, completion: completion)
            }
            return true
        }
        do {
            try tinode.connectDefault(inBackground: false)?
                .thenApply({ _ in tinode.loginBasic(uname: login, password: password) })
                .then(onSuccess: { _ in
                    SharedUtils.saveAuthToken(for: login, token: tinode.authToken, expires: tinode.authTokenExpires)
                    if let token = tinode.authToken { tinode.setAutoLoginWithToken(token: token) }
                    Linia2Turn.shared.prefetch()
                    Linia2Voip.shared.register()
                    DispatchQueue.main.async { completion(nil) }
                    return nil
                }, onFailure: { err in
                    var msg = Linia2API.networkError
                    var serverAnswered = false
                    if let e = err as? TinodeError, case .serverResponseError(let code, _, _) = e {
                        serverAnswered = true
                        msg = (code == 401 || code == 403)
                            ? "Неверный логин или пароль. После 5 ошибок вход блокируется на 15 минут."
                            : "Ошибка входа (\(code)). Попробуйте ещё раз."
                    }
                    Cache.invalidate()
                    DispatchQueue.main.async {
                        if !serverAnswered && retry() { return }
                        completion(msg)
                    }
                    return nil
                })
        } catch {
            tinode.logout()
            if retry() { return }
            completion(Linia2API.networkError)
        }
    }

    /// После входа: если PIN ещё не создан — создать (с предложением Face ID), затем открыть «Чаты».
    static func finishLogin(from nav: UINavigationController?) {
        if Linia2AppLock.shared.isEnabled || nav == nil {
            UiUtils.routeToChatListVC()
            return
        }
        nav?.pushViewController(Linia2PinOnboardingViewController(), animated: true)
    }
}

// MARK: - Базовый экран формы: прокрутка, клавиатура, центрирование

class Linia2FormViewController: UIViewController {
    let scroll = UIScrollView()
    let stack = UIStackView()
    private var centerConstraint: NSLayoutConstraint!

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }   // Дизайн: по теме (в светлой «белые часы» были невидимы)

    /// Поля экрана: 28 — экраны входа/регистрации (крупный центрированный блок); карточки настроек — 16 (Профиль).
    var sideMargin: CGFloat { 28 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        // Центр — относительно содержимого, а не видимой рамки: привязка к frameLayoutGuide «приклеивала» блок
        // к рамке, и при прокрутке он ехал вместе с ней — длинный экран (Профиль под нижним меню) не прокручивался.
        // Пока блок ниже экрана, содержимое = высоте рамки, и блок по-прежнему по центру экрана.
        centerConstraint = stack.centerYAnchor.constraint(equalTo: scroll.contentLayoutGuide.centerYAnchor, constant: -20)
        centerConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            // Низ области — верх клавиатуры (iOS 15+): поле и кнопка всегда над клавиатурой.
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: sideMargin),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -sideMargin),
            scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),   // без горизонтальной прокрутки
            // Содержимое всегда вмещает весь блок — если он выше видимой области (клавиатура, iPhone SE), его можно прокрутить.
            scroll.contentLayoutGuide.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor, constant: 48),
            centerConstraint,
        ])
        let fit = scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        fit.priority = .defaultLow - 1
        fit.isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fieldBeganEditing(_:)),
                                               name: UITextField.textDidBeginEditingNotification, object: nil)
        let tap = UITapGestureRecognizer(target: view, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // Прозрачный навбар только со стрелкой «назад».
        let a = UINavigationBarAppearance()
        a.configureWithTransparentBackground()
        navigationItem.standardAppearance = a
        navigationItem.scrollEdgeAppearance = a
        navigationItem.backButtonDisplayMode = .minimal
    }

    @objc private func keyboardChanged(_ n: Notification) {
        guard let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = n.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        _ = overlap  // область уже уменьшена keyboardLayoutGuide — дополнительный отступ не нужен
        if overlap > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.revealFirstResponder() } }
    }

    private var lastScrollHeight: CGFloat = 0
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Область уменьшилась/выросла вместе с клавиатурой — после раскладки показываем поле и кнопку под ним.
        let h = scroll.bounds.height
        if abs(h - lastScrollHeight) > 1 {
            lastScrollHeight = h
            DispatchQueue.main.async { self.revealFirstResponder() }
        }
    }

    @objc private func fieldBeganEditing(_ n: Notification) {
        DispatchQueue.main.async { self.revealFirstResponder() }
    }

    /// Прокрутить так, чтобы были видны активное поле и то, что под ним (ошибка, кнопка).
    func revealFirstResponder() {
        guard let r = Self.findFirstResponder(in: stack) else { return }
        var rect = r.convert(r.bounds, to: scroll)
        rect.origin.y -= 24
        rect.size.height += 24 + 150
        scroll.scrollRectToVisible(rect, animated: true)
    }

    private static func findFirstResponder(in v: UIView) -> UIView? {
        if v.isFirstResponder { return v }
        for sub in v.subviews { if let r = findFirstResponder(in: sub) { return r } }
        return nil
    }

    func setBusy(_ busy: Bool, button: UIButton, title: String) {
        button.isEnabled = !busy
        button.setTitle(busy ? "Подождите…" : title, for: .normal)
        view.isUserInteractionEnabled = !busy
    }

    func bigTitle(_ text: String, _ subtitle: String?) -> [UIView] {
        let t = UILabel()
        t.text = text
        t.font = L2.rounded(30, .heavy)
        t.textColor = L2.textPrimary
        t.textAlignment = .center
        t.numberOfLines = 0
        guard let subtitle = subtitle else { return [t] }
        let s = UILabel()
        s.text = subtitle
        s.font = L2.font(16)
        s.textColor = L2.textSecondary
        s.textAlignment = .center
        s.numberOfLines = 0
        return [t, s]
    }

    func errorLabel() -> UILabel {
        let l = UILabel()
        l.font = L2.font(15, .medium)
        l.textColor = L2.danger
        l.numberOfLines = 0
        l.textAlignment = .center
        l.isHidden = true
        return l
    }

    func logoTile(_ size: CGFloat) -> UIView {
        let tile = UIView()
        tile.backgroundColor = L2.surface
        tile.layer.cornerRadius = size * 0.28
        tile.layer.borderWidth = 1
        tile.layer.borderColor = L2.separator.cgColor
        let pulse = L2PulseView()
        pulse.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(pulse)
        // LINIA2: логотип с сервера (images.logoUrl) поверх встроенного; без сети — встроенный.
        if let u = Linia2Config.shared.image("logoUrl") {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.frame = CGRect(x: size * 0.12, y: size * 0.12, width: size * 0.76, height: size * 0.76)
            tile.addSubview(iv)
            L2RemoteImage.load(u, into: iv) { _ in pulse.isHidden = true }
        }
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: size), tile.heightAnchor.constraint(equalToConstant: size),
                                     pulse.centerXAnchor.constraint(equalTo: tile.centerXAnchor), pulse.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                                     pulse.widthAnchor.constraint(equalTo: tile.widthAnchor, multiplier: 0.7),
                                     pulse.heightAnchor.constraint(equalTo: tile.heightAnchor, multiplier: 0.45)])
        let wrap = UIStackView(arrangedSubviews: [tile])
        wrap.axis = .vertical
        wrap.alignment = .center
        return wrap
    }
}

// MARK: - а) «Добро пожаловать в Линия 2.0»

final class Linia2WelcomeViewController: Linia2FormViewController {
    static func makeRoot() -> UINavigationController {
        let nav = UINavigationController(rootViewController: Linia2WelcomeViewController())
        nav.view.backgroundColor = L2.background
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let logo = logoTile(128)
        let wordmark = L2LogoView(size: 26)
        let wmWrap = UIStackView(arrangedSubviews: [wordmark])
        wmWrap.axis = .vertical
        wmWrap.alignment = .center
        let titles = bigTitle(L2T("l2.welcome.title", "Добро пожаловать\nв «Линия 2.0»"),
                              L2T("l2.welcome.subtitle", "Мессенджер для своих. Регистрация — только по приглашению."))
        let code = L2Button(L2T("l2.welcome.code", "У меня есть код приглашения"), kind: .primary, symbol: "ticket")
        code.addTarget(self, action: #selector(codeTapped), for: .touchUpInside)
        code.accessibilityIdentifier = "l2.welcome.code"
        let login = L2Button(L2T("l2.welcome.login", "Войти"), kind: .secondary)
        login.accessibilityIdentifier = "l2.welcome.login"
        login.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)

        // LINIA2: картинка экрана приветствия с сервера (images.welcomeSlides / welcomeImageUrl).
        if let wu = Linia2Config.shared.welcomeImageURL {
            let hero = UIImageView()
            hero.contentMode = .scaleAspectFit
            hero.clipsToBounds = true
            hero.layer.cornerRadius = L2.r("card", 16)
            hero.isHidden = true
            hero.heightAnchor.constraint(equalToConstant: 180).isActive = true
            hero.accessibilityIdentifier = "l2.welcome.image"
            stack.addArrangedSubview(hero)
            stack.setCustomSpacing(18, after: hero)
            L2RemoteImage.load(wu, into: hero) { _ in hero.isHidden = false }
        }
        stack.addArrangedSubview(logo)
        stack.setCustomSpacing(18, after: logo)
        stack.addArrangedSubview(wmWrap)
        stack.setCustomSpacing(28, after: wmWrap)
        titles.forEach { stack.addArrangedSubview($0) }
        if let last = titles.last { stack.setCustomSpacing(36, after: last) }
        // Регистрация по коду выключается с сервера (features.inviteRegistration).
        if Linia2Config.shared.feature("inviteRegistration") { stack.addArrangedSubview(code) }
        stack.addArrangedSubview(login)

        // Плавное появление.
        stack.alpha = 0
        stack.transform = CGAffineTransform(translationX: 0, y: 16)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.5, delay: 0, options: .curveEaseOut) {
            self.stack.alpha = 1
            self.stack.transform = .identity
        }
    }

    @objc private func codeTapped() {
        navigationController?.pushViewController(Linia2InviteCodeViewController(), animated: true)
    }

    @objc private func loginTapped() {
        navigationController?.pushViewController(Linia2LoginViewController(), animated: true)
    }
}

// MARK: - Вход по логину и паролю

final class Linia2LoginViewController: Linia2FormViewController, UITextFieldDelegate {
    private let loginField = L2TextField(placeholder: "Логин")
    private let passwordField = L2TextField(placeholder: "Пароль")
    private lazy var errorText = errorLabel()
    private let loginButton = L2Button("Войти")

    override func viewDidLoad() {
        super.viewDidLoad()
        loginField.textContentType = ProcessInfo.processInfo.arguments.contains("-l2-uitest") ? nil : .username
        loginField.autocapitalizationType = .none
        loginField.autocorrectionType = .no
        loginField.keyboardType = .asciiCapable
        loginField.returnKeyType = .next
        loginField.delegate = self
        loginField.text = SharedUtils.getSavedLoginUserName()
        passwordField.textContentType = ProcessInfo.processInfo.arguments.contains("-l2-uitest") ? nil : .password
        passwordField.addSecureToggle()
        passwordField.returnKeyType = .go
        passwordField.delegate = self
        for f in [loginField, passwordField] { f.addTarget(self, action: #selector(edited), for: .editingChanged) }
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        loginField.accessibilityIdentifier = "l2.login.login"
        passwordField.accessibilityIdentifier = "l2.login.password"
        loginButton.accessibilityIdentifier = "l2.login.submit"
        let code = UIButton(type: .system)
        code.setTitle("У меня есть код приглашения", for: .normal)
        code.setTitleColor(L2.accent, for: .normal)
        code.titleLabel?.font = L2.font(16, .medium)
        code.addTarget(self, action: #selector(codeTapped), for: .touchUpInside)

        let logo = logoTile(84)
        stack.addArrangedSubview(logo)
        stack.setCustomSpacing(22, after: logo)
        let titles = bigTitle("Вход", "Введите логин и пароль")
        titles.forEach { stack.addArrangedSubview($0) }
        if let last = titles.last { stack.setCustomSpacing(28, after: last) }
        stack.addArrangedSubview(loginField)
        stack.addArrangedSubview(passwordField)
        stack.addArrangedSubview(errorText)
        stack.setCustomSpacing(22, after: errorText)
        stack.addArrangedSubview(loginButton)
        stack.addArrangedSubview(code)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (loginField.text?.isEmpty ?? true ? loginField : passwordField).becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === loginField { passwordField.becomeFirstResponder() } else { loginTapped() }
        return true
    }

    @objc private func edited() {
        errorText.isHidden = true
        loginField.isInvalid = false
        passwordField.isInvalid = false
    }

    @objc private func codeTapped() {
        navigationController?.pushViewController(Linia2InviteCodeViewController(), animated: true)
    }

    @objc private func loginTapped() {
        let login = (loginField.text ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let password = passwordField.text ?? ""
        guard !login.isEmpty else { loginField.isInvalid = true; loginField.becomeFirstResponder(); return }
        guard !password.isEmpty else { passwordField.isInvalid = true; passwordField.becomeFirstResponder(); return }
        view.endEditing(true)
        setBusy(true, button: loginButton, title: "Войти")
        Linia2Auth.login(login, password) { [weak self] err in
            guard let self = self else { return }
            self.setBusy(false, button: self.loginButton, title: "Войти")
            if let err = err {
                self.errorText.text = err
                self.errorText.isHidden = false
                self.passwordField.isInvalid = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            Linia2Auth.finishLogin(from: self.navigationController)
        }
    }
}

// MARK: - б) Код приглашения: 6 закруглённых ячеек

final class Linia2CodeCellsView: UIControl, UIKeyInput, UITextInputTraits {
    var onComplete: ((String) -> Void)?
    var onChange: (() -> Void)?
    private(set) var code = ""
    private let length = 6
    private var cells: [UILabel] = []
    private let row = UIStackView()

    // UITextInputTraits
    var keyboardType: UIKeyboardType = .numberPad
    var textContentType: UITextContentType! = .oneTimeCode
    var keyboardAppearance: UIKeyboardAppearance = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isUserInteractionEnabled = false
        addSubview(row)
        for _ in 0..<length {
            let l = UILabel()
            l.textAlignment = .center
            l.font = L2.rounded(28, .semibold)
            l.textColor = L2.textPrimary
            l.backgroundColor = L2.surface
            l.layer.cornerRadius = 16
            l.layer.borderWidth = 1.5
            l.clipsToBounds = true
            cells.append(l)
            row.addArrangedSubview(l)
        }
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     heightAnchor.constraint(equalToConstant: 64)])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = "Код приглашения, 6 цифр"
        render()
    }

    required init?(coder: NSCoder) { return nil }

    override var canBecomeFirstResponder: Bool { true }
    @objc private func tapped() { becomeFirstResponder() }
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); render(); return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); render(); return r }

    var hasText: Bool { !code.isEmpty }

    func insertText(_ text: String) {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return }
        code = String((code + digits).prefix(length))
        L2.haptic()
        render()
        onChange?()
        if code.count == length { onComplete?(code) }
    }

    func deleteBackward() {
        guard !code.isEmpty else { return }
        code.removeLast()
        render()
        onChange?()
    }

    func clear() { code = ""; render() }

    var isInvalid = false { didSet { render() } }

    func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [-12, 12, -8, 8, -4, 4, 0]
        a.duration = 0.4
        layer.add(a, forKey: "shake")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func render() {
        let chars = Array(code)
        for (i, l) in cells.enumerated() {
            l.text = i < chars.count ? String(chars[i]) : ""
            let active = isFirstResponder && i == min(chars.count, length - 1)
            l.layer.borderColor = (isInvalid ? L2.danger : (active ? L2.accent : UIColor.clear)).cgColor
        }
        accessibilityValue = code.isEmpty ? "пусто" : code.map(String.init).joined(separator: " ")
    }
}

final class Linia2InviteCodeViewController: Linia2FormViewController {
    private let cells = Linia2CodeCellsView()
    private lazy var errorText = errorLabel()
    private let nextButton = L2Button("Далее")

    override func viewDidLoad() {
        super.viewDidLoad()
        let logo = logoTile(84)
        let titles = bigTitle("Код приглашения", "Введите 6 цифр, которые прислал администратор")
        cells.onChange = { [weak self] in
            self?.errorText.isHidden = true
            self?.cells.isInvalid = false
            self?.nextButton.isEnabled = (self?.cells.code.count ?? 0) == 6
        }
        cells.onComplete = { [weak self] _ in self?.check() }
        nextButton.isEnabled = false
        nextButton.accessibilityIdentifier = "l2.code.next"
        cells.accessibilityIdentifier = "l2.code.cells"
        nextButton.addTarget(self, action: #selector(check), for: .touchUpInside)
        let paste = UIButton(type: .system)
        paste.setTitle("Вставить из буфера", for: .normal)
        paste.setTitleColor(L2.accent, for: .normal)
        paste.titleLabel?.font = L2.font(15, .medium)
        paste.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        stack.addArrangedSubview(logo)
        stack.setCustomSpacing(22, after: logo)
        titles.forEach { stack.addArrangedSubview($0) }
        if let last = titles.last { stack.setCustomSpacing(30, after: last) }
        stack.addArrangedSubview(cells)
        stack.addArrangedSubview(errorText)
        stack.setCustomSpacing(26, after: errorText)
        stack.addArrangedSubview(nextButton)
        stack.addArrangedSubview(paste)
        // Только для автотеста (флаг -l2-uitest): обычное поле ввода, которое передаёт цифры в ячейки —
        // XCUITest не умеет печатать в собственное поле ввода кода. В приложении у пользователей его нет.
        if ProcessInfo.processInfo.arguments.contains("-l2-uitest") {
            let t = UITextField()
            t.accessibilityIdentifier = "l2.code.testinput"
            t.keyboardType = .numberPad
            t.textColor = L2.textSecondary
            t.font = L2.font(12)
            t.placeholder = "автотест"
            t.heightAnchor.constraint(equalToConstant: 32).isActive = true
            t.addTarget(self, action: #selector(testInputChanged(_:)), for: .editingChanged)
            stack.addArrangedSubview(t)
        }
    }

    @objc private func testInputChanged(_ t: UITextField) {
        let digits = (t.text ?? "").filter { $0.isNumber }
        guard digits.count >= 6 else { return }
        t.text = ""
        cells.clear()
        cells.insertText(String(digits.prefix(6)))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = cells.becomeFirstResponder()
    }

    @objc private func pasteTapped() {
        guard let s = UIPasteboard.general.string else { return }
        cells.clear()
        cells.insertText(s)
    }

    @objc private func check() {
        let code = cells.code
        guard code.count == 6 else { return }
        setBusy(true, button: nextButton, title: "Далее")
        Linia2API.post("check", ["code": code]) { [weak self] status, json in
            guard let self = self else { return }
            self.setBusy(false, button: self.nextButton, title: "Далее")
            if json?["ok"] as? Bool == true {
                self.navigationController?.pushViewController(Linia2RegisterViewController(code: code), animated: true)
                return
            }
            let msg = (status == 0 || json == nil) ? Linia2API.networkError
                : (json?["error"] as? String ?? "Код недействителен.") + (status == 400 && (json?["error"] as? String)?.contains("15 минут") != true
                    ? " Проверьте цифры или попросите у администратора новый код." : "")
            self.errorText.text = msg
            self.errorText.isHidden = false
            self.cells.isInvalid = true
            self.revealFirstResponder()
            self.cells.shake()
            self.cells.clear()
            _ = self.cells.becomeFirstResponder()
        }
    }
}

// MARK: - в) Регистрация: имя, логин, пароль, повтор

final class Linia2RegisterViewController: Linia2FormViewController, UITextFieldDelegate {
    private let code: String
    private let nameField = L2TextField(placeholder: "Имя")
    private let loginField = L2TextField(placeholder: "Логин")
    private let passwordField = L2TextField(placeholder: "Пароль (не короче 8 символов)")
    private let password2Field = L2TextField(placeholder: "Повтор пароля")
    private lazy var errorText = errorLabel()
    private let registerButton = L2Button("Зарегистрироваться")

    init(code: String) {
        self.code = code
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        nameField.textContentType = .name
        nameField.autocapitalizationType = .words
        loginField.textContentType = .username
        loginField.autocapitalizationType = .none
        loginField.autocorrectionType = .no
        loginField.spellCheckingType = .no
        loginField.keyboardType = .asciiCapable
        // Под UI-тестом (флаг -l2-uitest) без «надёжного пароля» iOS — он перехватывает ввод в симуляторе.
        let uiTest = ProcessInfo.processInfo.arguments.contains("-l2-uitest")
        for f in [passwordField, password2Field] {
            f.addSecureToggle()
            // .oneTimeCode — единственный тип, при котором симулятор не подставляет «Automatic Strong Password».
            f.textContentType = uiTest ? .oneTimeCode : .newPassword
        }
        let hint = UILabel()
        hint.text = "Логин — латиница, цифры, точка, _ или -. По нему вас найдут собеседники."
        hint.font = L2.font(13)
        hint.textColor = L2.textSecondary
        hint.numberOfLines = 0

        let titles = bigTitle("Регистрация", "Код принят. Осталось придумать логин и пароль.")
        titles.forEach { stack.addArrangedSubview($0) }
        if let last = titles.last { stack.setCustomSpacing(26, after: last) }
        let fields = [nameField, loginField, passwordField, password2Field]
        for (i, f) in fields.enumerated() {
            f.delegate = self
            f.returnKeyType = i == fields.count - 1 ? .go : .next
            f.addTarget(self, action: #selector(edited(_:)), for: .editingChanged)
            stack.addArrangedSubview(f)
            if f === loginField { stack.addArrangedSubview(hint) }
        }
        registerButton.addTarget(self, action: #selector(registerTapped), for: .touchUpInside)
        registerButton.accessibilityIdentifier = "l2.reg.submit"
        nameField.accessibilityIdentifier = "l2.reg.name"
        loginField.accessibilityIdentifier = "l2.reg.login"
        passwordField.accessibilityIdentifier = "l2.reg.password"
        password2Field.accessibilityIdentifier = "l2.reg.password2"
        stack.addArrangedSubview(errorText)
        stack.setCustomSpacing(22, after: errorText)
        stack.addArrangedSubview(registerButton)
        // Согласие с документами — без галочки, ссылки открываются в SFSafariViewController.
        let legal = L2LegalTextView(parts: [
            ("Регистрируясь, вы соглашаетесь с ", nil),
            ("Условиями", Linia2Links.terms),
            (" и ", nil),
            ("Политикой конфиденциальности", Linia2Links.privacy),
        ])
        legal.presenter = self
        stack.setCustomSpacing(12, after: registerButton)
        stack.addArrangedSubview(legal)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nameField.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order = [nameField, loginField, passwordField, password2Field]
        if let i = order.firstIndex(where: { $0 === textField }), i + 1 < order.count {
            order[i + 1].becomeFirstResponder()
        } else {
            registerTapped()
        }
        return true
    }

    @objc private func edited(_ f: L2TextField) {
        f.isInvalid = false
        errorText.isHidden = true
    }

    private func fail(_ text: String, _ field: L2TextField?) {
        errorText.text = text
        errorText.isHidden = false
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if let field = field {
            field.isInvalid = true
            field.becomeFirstResponder()
        }
    }

    @objc private func registerTapped() {
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let login = (loginField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let password = passwordField.text ?? ""
        let password2 = password2Field.text ?? ""

        if name.isEmpty { return fail("Укажите имя.", nameField) }
        if login.range(of: "^[a-z0-9_.-]{3,32}$", options: .regularExpression) == nil {
            return fail("Логин: 3–32 символа, латинские буквы, цифры, точка, _ или -.", loginField)
        }
        if password.count < 8 { return fail("Пароль должен быть не короче 8 символов.", passwordField) }
        if password != password2 { return fail("Пароли не совпадают.", password2Field) }

        view.endEditing(true)
        setBusy(true, button: registerButton, title: "Зарегистрироваться")
        let body: [String: Any] = ["code": code, "name": name, "login": login, "password": password, "password2": password2]
        Linia2API.post("register", body) { [weak self] status, json in
            guard let self = self else { return }
            if json?["ok"] as? Bool == true {
                // Сразу входим тем же логином и паролем.
                Linia2Auth.login(json?["login"] as? String ?? login, password) { err in
                    self.setBusy(false, button: self.registerButton, title: "Зарегистрироваться")
                    if let err = err { return self.fail("Аккаунт создан, но войти не удалось: \(err)", nil) }
                    Linia2Auth.finishLogin(from: self.navigationController)
                }
                return
            }
            self.setBusy(false, button: self.registerButton, title: "Зарегистрироваться")
            if status == 0 || json == nil { return self.fail(Linia2API.networkError, nil) }
            let msg = json?["error"] as? String ?? "Не удалось зарегистрироваться."
            switch json?["field"] as? String {
            case "code":
                let alert = UIAlertController(title: "Код недействителен", message: msg, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    self.navigationController?.popViewController(animated: true)
                })
                self.present(alert, animated: true)
            case "name": self.fail(msg, self.nameField)
            case "login": self.fail(msg, self.loginField)
            case "password": self.fail(msg, self.passwordField)
            case "password2": self.fail(msg, self.password2Field)
            default: self.fail(msg, nil)
            }
        }
    }
}

// MARK: - г) Создание PIN-кода (в онбординге) и предложение Face ID

final class Linia2PinOnboardingViewController: UIViewController {
    override var preferredStatusBarStyle: UIStatusBarStyle { .default }   // Дизайн: по теме (в светлой «белые часы» были невидимы)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        navigationItem.hidesBackButton = true
        let pin = Linia2PinViewController(mode: .setNew, embedded: true)
        pin.onFinish = { [weak self] ok in
            guard ok else { return }
            self?.offerBiometrics()
        }
        addChild(pin)
        pin.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pin.view)
        NSLayoutConstraint.activate([pin.view.topAnchor.constraint(equalTo: view.topAnchor), pin.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     pin.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), pin.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        pin.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    private func offerBiometrics() {
        guard let name = Linia2AppLock.shared.biometryName else {
            UiUtils.routeToChatListVC()
            return
        }
        let vc = Linia2BiometryOfferViewController(name: name)
        navigationController?.pushViewController(vc, animated: true)
    }
}

final class Linia2BiometryOfferViewController: Linia2FormViewController {
    private let name: String

    init(name: String) {
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.hidesBackButton = true
        let icon = UIImageView(image: L2.symbol(name == "Face ID" ? "faceid" : "touchid", 72, .light))
        icon.tintColor = L2.accent
        icon.contentMode = .center
        icon.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let titles = bigTitle("Включить \(name)?", "Открывайте «Линия 2.0» по \(name) — быстрее, чем вводить PIN-код. PIN останется запасным способом.")
        let yes = L2Button("Включить \(name)")
        yes.addTarget(self, action: #selector(enable), for: .touchUpInside)
        let no = L2Button("Не сейчас", kind: .secondary)
        no.addTarget(self, action: #selector(skip), for: .touchUpInside)
        stack.addArrangedSubview(icon)
        titles.forEach { stack.addArrangedSubview($0) }
        if let last = titles.last { stack.setCustomSpacing(34, after: last) }
        stack.addArrangedSubview(yes)
        stack.addArrangedSubview(no)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    @objc private func enable() {
        Linia2AppLock.shared.enableBiometrics { _ in UiUtils.routeToChatListVC() }
    }

    @objc private func skip() {
        UiUtils.routeToChatListVC()
    }
}
