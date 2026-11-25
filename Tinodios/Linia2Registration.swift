//
//  Linia2Registration.swift
//  Линия 2.0: регистрация только по коду приглашения (2 экрана).
//  Экран 1 — код из 6 цифр (проверка на сервере), экран 2 — имя, логин, пароль.
//

import UIKit
import TinodiosDB

// MARK: - Фирменный стиль

enum Linia2Style {
    static let dark = UIColor(red: 0x0E / 255.0, green: 0x1F / 255.0, blue: 0x17 / 255.0, alpha: 1)
    static let green = UIColor(red: 0x1F / 255.0, green: 0x8F / 255.0, blue: 0x55 / 255.0, alpha: 1)
    static let errorRed = UIColor.systemRed

    static func primaryButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.setTitleColor(UIColor.white.withAlphaComponent(0.6), for: .disabled)
        b.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        b.backgroundColor = green
        b.layer.cornerRadius = 12
        b.heightAnchor.constraint(equalToConstant: 50).isActive = true
        return b
    }

    static func linkButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(green, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        return b
    }

    static func field(_ placeholder: String) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.borderStyle = .none
        f.backgroundColor = .secondarySystemBackground
        f.layer.cornerRadius = 10
        f.layer.borderWidth = 1
        f.layer.borderColor = UIColor.separator.cgColor
        f.font = .systemFont(ofSize: 17)
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        f.leftViewMode = .always
        f.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        f.rightViewMode = .always
        f.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return f
    }

    static func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        return l
    }

    static func errorLabel() -> UILabel {
        let l = UILabel()
        l.font = .systemFont(ofSize: 15)
        l.textColor = errorRed
        l.numberOfLines = 0
        l.textAlignment = .center
        l.isHidden = true
        return l
    }

    static func mark(_ field: UITextField, bad: Bool) {
        field.layer.borderColor = bad ? errorRed.cgColor : UIColor.separator.cgColor
    }
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

// MARK: - Базовый экран с прокруткой и клавиатурой

class Linia2FormViewController: UIViewController {
    let scroll = UIScrollView()
    let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        let tap = UITapGestureRecognizer(target: view, action: #selector(UIView.endEditing(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func keyboardChanged(_ n: Notification) {
        guard let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = n.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        scroll.contentInset.bottom = overlap
        scroll.verticalScrollIndicatorInsets.bottom = overlap
    }

    func setBusy(_ busy: Bool, button: UIButton, title: String) {
        button.isEnabled = !busy
        button.setTitle(busy ? "Подождите…" : title, for: .normal)
        view.isUserInteractionEnabled = !busy
    }
}

// MARK: - Экран 1: «Добро пожаловать в Линия 2.0» + код приглашения

class Linia2InviteCodeViewController: Linia2FormViewController, UITextFieldDelegate {
    private let codeField = Linia2Style.field("••••••")
    private let errorLabel = Linia2Style.errorLabel()
    private let nextButton = Linia2Style.primaryButton("Далее")

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Регистрация"

        let logo = UIImageView(image: UIImage(named: "logo-ios"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 24
        logo.clipsToBounds = true
        logo.heightAnchor.constraint(equalToConstant: 112).isActive = true
        logo.widthAnchor.constraint(equalToConstant: 112).isActive = true
        let logoWrap = UIStackView(arrangedSubviews: [logo])
        logoWrap.axis = .vertical
        logoWrap.alignment = .center

        let titleLabel = UILabel()
        titleLabel.text = "Добро пожаловать в «Линия 2.0»"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let sub = Linia2Style.caption("Регистрация — только по приглашению. Введите код из 6 цифр, который выдал администратор.")
        sub.textAlignment = .center
        sub.numberOfLines = 0

        codeField.keyboardType = .numberPad
        codeField.textContentType = .oneTimeCode
        codeField.textAlignment = .center
        codeField.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        codeField.defaultTextAttributes[.kern] = 10
        codeField.delegate = self
        codeField.accessibilityLabel = "Код приглашения"
        codeField.heightAnchor.constraint(equalToConstant: 60).isActive = true

        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        stack.addArrangedSubview(logoWrap)
        stack.setCustomSpacing(20, after: logoWrap)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(24, after: sub)
        stack.addArrangedSubview(Linia2Style.caption("Код приглашения"))
        stack.addArrangedSubview(codeField)
        stack.addArrangedSubview(errorLabel)
        stack.setCustomSpacing(20, after: errorLabel)
        stack.addArrangedSubview(nextButton)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeField.becomeFirstResponder()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = (textField.text ?? "") as NSString
        let updated = current.replacingCharacters(in: range, with: string).filter { $0.isASCII && $0.isNumber }
        textField.text = String(updated.prefix(6))
        errorLabel.isHidden = true
        Linia2Style.mark(codeField, bad: false)
        return false
    }

    private func showError(_ text: String) {
        errorLabel.text = text
        errorLabel.isHidden = false
        Linia2Style.mark(codeField, bad: true)
    }

    @objc private func nextTapped() {
        let code = codeField.text ?? ""
        guard code.count == 6 else { showError("Код состоит из 6 цифр."); return }
        setBusy(true, button: nextButton, title: "Далее")
        Linia2API.post("check", ["code": code]) { [weak self] status, json in
            guard let self = self else { return }
            self.setBusy(false, button: self.nextButton, title: "Далее")
            if json?["ok"] as? Bool == true {
                self.navigationController?.pushViewController(Linia2RegisterViewController(code: code), animated: true)
            } else if status == 0 || json == nil {
                self.showError(Linia2API.networkError)
            } else {
                self.showError(json?["error"] as? String ?? "Код недействителен.")
            }
        }
    }
}

// MARK: - Экран 2: имя, логин, пароль

class Linia2RegisterViewController: Linia2FormViewController, UITextFieldDelegate {
    private let code: String
    private let nameField = Linia2Style.field("Как вас будут видеть собеседники")
    private let loginField = Linia2Style.field("латиница, цифры, точка, _ или -")
    private let passwordField = Linia2Style.field("не короче 8 символов")
    private let password2Field = Linia2Style.field("ещё раз")
    private let errorLabel = Linia2Style.errorLabel()
    private let registerButton = Linia2Style.primaryButton("Зарегистрироваться")

    init(code: String) {
        self.code = code
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Регистрация"

        nameField.textContentType = .name
        nameField.autocapitalizationType = .words
        loginField.textContentType = .username
        loginField.autocapitalizationType = .none
        loginField.autocorrectionType = .no
        loginField.spellCheckingType = .no
        loginField.keyboardType = .asciiCapable
        for f in [passwordField, password2Field] {
            f.isSecureTextEntry = true
            f.textContentType = .newPassword
        }
        let fields: [(String, UITextField)] = [("Имя", nameField), ("Логин", loginField),
                                                ("Пароль", passwordField), ("Повтор пароля", password2Field)]
        for (i, (caption, field)) in fields.enumerated() {
            field.delegate = self
            field.returnKeyType = i == fields.count - 1 ? .go : .next
            field.addTarget(self, action: #selector(edited(_:)), for: .editingChanged)
            stack.addArrangedSubview(Linia2Style.caption(caption))
            stack.addArrangedSubview(field)
            stack.setCustomSpacing(16, after: field)
        }
        registerButton.addTarget(self, action: #selector(registerTapped), for: .touchUpInside)
        stack.addArrangedSubview(errorLabel)
        stack.setCustomSpacing(20, after: errorLabel)
        stack.addArrangedSubview(registerButton)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nameField.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let order = [nameField, loginField, passwordField, password2Field]
        if let i = order.firstIndex(of: textField), i + 1 < order.count {
            order[i + 1].becomeFirstResponder()
        } else {
            registerTapped()
        }
        return true
    }

    @objc private func edited(_ f: UITextField) {
        Linia2Style.mark(f, bad: false)
        errorLabel.isHidden = true
    }

    private func fail(_ text: String, _ field: UITextField?) {
        errorLabel.text = text
        errorLabel.isHidden = false
        if let field = field {
            Linia2Style.mark(field, bad: true)
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
            self.setBusy(false, button: self.registerButton, title: "Зарегистрироваться")
            if json?["ok"] as? Bool == true {
                self.loginAfterRegistration(login: json?["login"] as? String ?? login, password: password)
                return
            }
            if status == 0 || json == nil { return self.fail(Linia2API.networkError, nil) }
            let msg = json?["error"] as? String ?? "Не удалось зарегистрироваться."
            switch json?["field"] as? String {
            case "code":
                // Код успел сгореть или истечь — возвращаем на первый экран.
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

    /// После регистрации — сразу входим обычным способом через экран входа.
    private func loginAfterRegistration(login: String, password: String) {
        guard let nav = navigationController,
              let loginVC = nav.viewControllers.first(where: { $0 is LoginViewController }) as? LoginViewController else {
            navigationController?.popToRootViewController(animated: true)
            return
        }
        nav.popToViewController(loginVC, animated: true)
        loginVC.loadViewIfNeeded()
        loginVC.userNameTextEdit.text = login
        loginVC.passwordTextEdit.text = password
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            loginVC.loginClicked(self)
        }
    }
}
