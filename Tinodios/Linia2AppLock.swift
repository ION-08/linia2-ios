//
//  Linia2AppLock.swift
//  Линия 2.0: блокировка приложения PIN-кодом или Face ID / Touch ID (включается в настройках).
//  PIN (4 цифры) хранится в Keychain только как солёный хеш SHA-256, доступный лишь на этом устройстве.
//

import CryptoKit
import LocalAuthentication
import Security
import UIKit

// MARK: - Хранилище PIN в Keychain

private enum Linia2PinStore {
    private static let service = "info.codix.liniya2.applock"
    private static let account = "pin"

    static func save(pin: String) -> Bool {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let record = salt + hash(pin, salt)
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                kSecValueData as String: record]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func verify(pin: String) -> Bool {
        guard let record = load(), record.count == 48 else { return false }
        let salt = record.prefix(16), stored = record.suffix(32)
        let calc = hash(pin, Data(salt))
        // сравнение за постоянное время
        return zip(calc, stored).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static var exists: Bool { load() != nil }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    private static func load() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func hash(_ pin: String, _ salt: Data) -> Data {
        Data(SHA256.hash(data: salt + Data(pin.utf8)))
    }
}

// MARK: - Менеджер блокировки

final class Linia2AppLock {
    static let shared = Linia2AppLock()

    private let kEnabled = "linia2.applock.enabled"
    private let kBiometrics = "linia2.applock.biometrics"
    private let kLockAfter: TimeInterval = 30   // блокировать после 30 с в фоне

    private var lockWindow: UIWindow?
    private var coverWindow: UIWindow?
    private var backgroundedAt: Date?
    private var locked = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: kEnabled) && Linia2PinStore.exists }

    var useBiometrics: Bool {
        get { UserDefaults.standard.bool(forKey: kBiometrics) }
        set { UserDefaults.standard.set(newValue, forKey: kBiometrics) }
    }

    /// Тип биометрии на устройстве: "Face ID", "Touch ID" или nil.
    var biometryName: String? {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return nil
        }
    }

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        if isEnabled { lock() }
    }

    func enable(pin: String) -> Bool {
        guard Linia2PinStore.save(pin: pin) else { return false }
        UserDefaults.standard.set(true, forKey: kEnabled)
        return true
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: kEnabled)
        useBiometrics = false
        Linia2PinStore.delete()
    }

    func verify(pin: String) -> Bool { Linia2PinStore.verify(pin: pin) }

    // MARK: жизненный цикл

    @objc private func willResignActive() {
        guard isEnabled, !locked else { return }
        showCover()   // скрываем содержимое в переключателе приложений
    }

    @objc private func didEnterBackground() {
        if backgroundedAt == nil { backgroundedAt = Date() }
    }

    @objc private func didBecomeActive() {
        defer { backgroundedAt = nil; hideCover() }
        guard isEnabled, !locked else { return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) >= kLockAfter {
            lock()
        }
    }

    // MARK: окна

    private func makeWindow(level: UIWindow.Level, root: UIViewController) -> UIWindow {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.windowLevel = level
        w.rootViewController = root
        return w
    }

    private func showCover() {
        guard coverWindow == nil else { return }
        let vc = UIViewController()
        vc.view.backgroundColor = Linia2Style.dark
        let logo = UIImageView(image: UIImage(named: "logo-ios"))
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.layer.cornerRadius = 24
        logo.clipsToBounds = true
        vc.view.addSubview(logo)
        NSLayoutConstraint.activate([logo.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
                                     logo.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
                                     logo.widthAnchor.constraint(equalToConstant: 112),
                                     logo.heightAnchor.constraint(equalToConstant: 112)])
        let w = makeWindow(level: .alert + 2, root: vc)
        w.isHidden = false
        coverWindow = w
    }

    private func hideCover() {
        coverWindow?.isHidden = true
        coverWindow = nil
    }

    func lock() {
        guard isEnabled, !locked else { return }
        locked = true
        let vc = Linia2PinViewController(mode: .unlock)
        vc.onFinish = { [weak self] ok in
            guard ok else { return }
            self?.unlock()
        }
        let w = makeWindow(level: .alert + 1, root: vc)
        w.makeKeyAndVisible()
        lockWindow = w
    }

    private func unlock() {
        locked = false
        lockWindow?.isHidden = true
        lockWindow = nil
        (UIApplication.shared.delegate as? AppDelegate)?.window?.makeKey()
    }

    /// «Забыли PIN?» — выход из аккаунта и сброс блокировки.
    func forgotPin() {
        disable()
        unlock()
        UiUtils.logoutAndRouteToLoginVC()
    }

    /// Вызывается при выходе из аккаунта: блокировка принадлежит пользователю, а не устройству.
    func resetOnLogout() {
        disable()
    }
}

// MARK: - Экран PIN-кода (разблокировка и установка)

final class Linia2PinViewController: UIViewController {
    enum Mode { case unlock, setNew, confirmOld }

    var onFinish: ((Bool) -> Void)?
    private let mode: Mode
    private var entered = ""
    private var firstPin: String?
    private var failures = 0
    private var cooldownUntil: Date?
    private let pinLength = 4

    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let dots = UIStackView()
    private var bioButton: UIButton?

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Linia2Style.dark

        let logo = UIImageView(image: UIImage(named: "logo-ios"))
        logo.layer.cornerRadius = 18
        logo.clipsToBounds = true
        logo.widthAnchor.constraint(equalToConstant: 72).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 72).isActive = true

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textAlignment = .center
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        dots.axis = .horizontal
        dots.spacing = 18
        for _ in 0..<pinLength {
            let d = UIView()
            d.layer.cornerRadius = 8
            d.layer.borderWidth = 2
            d.layer.borderColor = UIColor.white.cgColor
            d.widthAnchor.constraint(equalToConstant: 16).isActive = true
            d.heightAnchor.constraint(equalToConstant: 16).isActive = true
            dots.addArrangedSubview(d)
        }

        let pad = UIStackView()
        pad.axis = .vertical
        pad.spacing = 14
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["bio", "0", "del"]]
        for row in rows {
            let h = UIStackView()
            h.axis = .horizontal
            h.spacing = 24
            h.distribution = .fillEqually
            for key in row { h.addArrangedSubview(keyButton(key)) }
            pad.addArrangedSubview(h)
        }

        let top = UIStackView(arrangedSubviews: [logo, titleLabel, hintLabel, dots])
        top.axis = .vertical
        top.alignment = .center
        top.spacing = 14
        top.setCustomSpacing(22, after: hintLabel)

        let main = UIStackView(arrangedSubviews: [top, pad])
        main.axis = .vertical
        main.alignment = .center
        main.spacing = 36
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(main)

        var constraints = [main.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                           main.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                           main.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                           hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320)]
        if mode == .unlock {
            let forgot = UIButton(type: .system)
            forgot.setTitle("Забыли PIN-код?", for: .normal)
            forgot.setTitleColor(UIColor.white.withAlphaComponent(0.8), for: .normal)
            forgot.addTarget(self, action: #selector(forgotTapped), for: .touchUpInside)
            forgot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(forgot)
            constraints += [forgot.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                            forgot.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)]
        } else {
            let cancel = UIButton(type: .system)
            cancel.setTitle("Отмена", for: .normal)
            cancel.setTitleColor(.white, for: .normal)
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancel)
            constraints += [cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)]
        }
        NSLayoutConstraint.activate(constraints)
        resetTexts()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if mode == .unlock && Linia2AppLock.shared.useBiometrics && Linia2AppLock.shared.biometryName != nil {
            biometricTapped()
        }
    }

    private func resetTexts() {
        switch mode {
        case .unlock:
            titleLabel.text = "Введите PIN-код"
            hintLabel.text = "«Линия 2.0» защищена PIN-кодом"
        case .confirmOld:
            titleLabel.text = "Текущий PIN-код"
            hintLabel.text = "Введите текущий PIN-код"
        case .setNew:
            titleLabel.text = firstPin == nil ? "Придумайте PIN-код" : "Повторите PIN-код"
            hintLabel.text = firstPin == nil ? "4 цифры — для открытия приложения" : "Введите тот же PIN-код ещё раз"
        }
    }

    private func keyButton(_ key: String) -> UIButton {
        let b = UIButton(type: .system)
        b.tintColor = .white
        b.setTitleColor(.white, for: .normal)
        b.widthAnchor.constraint(equalToConstant: 72).isActive = true
        b.heightAnchor.constraint(equalToConstant: 72).isActive = true
        switch key {
        case "del":
            b.setImage(UIImage(systemName: "delete.left"), for: .normal)
            b.accessibilityLabel = "Стереть"
            b.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        case "bio":
            if mode == .unlock && Linia2AppLock.shared.useBiometrics, let name = Linia2AppLock.shared.biometryName {
                b.setImage(UIImage(systemName: name == "Face ID" ? "faceid" : "touchid"), for: .normal)
                b.accessibilityLabel = name
                b.addTarget(self, action: #selector(biometricTapped), for: .touchUpInside)
                bioButton = b
            } else {
                b.isEnabled = false
            }
        default:
            b.setTitle(key, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 30, weight: .regular)
            b.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            b.layer.cornerRadius = 36
            b.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
        }
        return b
    }

    private func updateDots() {
        for (i, d) in dots.arrangedSubviews.enumerated() {
            d.backgroundColor = i < entered.count ? .white : .clear
        }
    }

    @objc private func digitTapped(_ sender: UIButton) {
        if let until = cooldownUntil, until > Date() {
            hintLabel.text = "Слишком много попыток. Подождите \(Int(until.timeIntervalSinceNow) + 1) с"
            return
        }
        guard entered.count < pinLength, let d = sender.currentTitle else { return }
        entered += d
        updateDots()
        if entered.count == pinLength {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.complete() }
        }
    }

    @objc private func deleteTapped() {
        guard !entered.isEmpty else { return }
        entered.removeLast()
        updateDots()
    }

    private func shake() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [-12, 12, -8, 8, -4, 4, 0]
        a.duration = 0.4
        dots.layer.add(a, forKey: "shake")
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func complete() {
        let pin = entered
        entered = ""
        updateDots()
        switch mode {
        case .unlock, .confirmOld:
            if Linia2AppLock.shared.verify(pin: pin) {
                onFinish?(true)
                if mode == .confirmOld { dismiss(animated: true) }
            } else {
                failures += 1
                shake()
                if failures >= 5 {
                    cooldownUntil = Date().addingTimeInterval(TimeInterval(30 * (failures - 4)))
                    hintLabel.text = "Неверный PIN-код. Подождите \(30 * (failures - 4)) с"
                } else {
                    hintLabel.text = "Неверный PIN-код. Осталось попыток: \(5 - failures)"
                }
            }
        case .setNew:
            if let first = firstPin {
                if first == pin {
                    let ok = Linia2AppLock.shared.enable(pin: pin)
                    onFinish?(ok)
                    dismiss(animated: true)
                } else {
                    firstPin = nil
                    shake()
                    resetTexts()
                    hintLabel.text = "PIN-коды не совпали. Попробуйте ещё раз"
                }
            } else {
                firstPin = pin
                resetTexts()
            }
        }
    }

    @objc private func biometricTapped() {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Ввести PIN-код"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Разблокировать «Линия 2.0»") { ok, _ in
            DispatchQueue.main.async { if ok { self.onFinish?(true) } }
        }
    }

    @objc private func forgotTapped() {
        let a = UIAlertController(title: "Забыли PIN-код?",
                                  message: "Чтобы сбросить PIN-код, нужно выйти из аккаунта и снова войти по логину и паролю.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        a.addAction(UIAlertAction(title: "Выйти", style: .destructive) { _ in Linia2AppLock.shared.forgotPin() })
        present(a, animated: true)
    }

    @objc private func cancelTapped() {
        onFinish?(false)
        dismiss(animated: true)
    }
}

// MARK: - Настройки блокировки (Настройки → Безопасность → «Блокировка приложения»)

final class Linia2AppLockSettingsViewController: UITableViewController {
    private let lockSwitch = UISwitch()
    private let bioSwitch = UISwitch()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Блокировка приложения"
        lockSwitch.onTintColor = Linia2Style.green
        bioSwitch.onTintColor = Linia2Style.green
        lockSwitch.addTarget(self, action: #selector(lockChanged), for: .valueChanged)
        bioSwitch.addTarget(self, action: #selector(bioChanged), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private var lock: Linia2AppLock { Linia2AppLock.shared }

    private func refresh() {
        lockSwitch.isOn = lock.isEnabled
        bioSwitch.isOn = lock.useBiometrics
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { lock.isEnabled ? 2 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        return lock.biometryName != nil ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "При открытии приложения и после 30 секунд в фоне потребуется PIN-код" +
            (lock.biometryName.map { " или \($0)" } ?? "") + "." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            cell.textLabel?.text = "PIN-код для входа"
            cell.accessoryView = lockSwitch
        case (1, 0) where lock.biometryName != nil:
            cell.textLabel?.text = "Разблокировка по \(lock.biometryName!)"
            cell.accessoryView = bioSwitch
        default:
            cell.textLabel?.text = "Сменить PIN-код"
            cell.textLabel?.textColor = Linia2Style.green
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, tableView.cellForRow(at: indexPath)?.accessoryView == nil else { return }
        // Сменить PIN: сначала текущий, потом новый.
        let check = Linia2PinViewController(mode: .confirmOld)
        check.onFinish = { [weak self] ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.presentSetNew() }
        }
        present(check, animated: true)
    }

    private func presentSetNew() {
        let vc = Linia2PinViewController(mode: .setNew)
        vc.onFinish = { [weak self] _ in self?.refresh() }
        present(vc, animated: true)
    }

    @objc private func lockChanged() {
        if lockSwitch.isOn {
            presentSetNew()
        } else {
            // Выключить можно только зная текущий PIN.
            let check = Linia2PinViewController(mode: .confirmOld)
            check.onFinish = { [weak self] ok in
                if ok { self?.lock.disable() }
                self?.refresh()
            }
            present(check, animated: true)
        }
    }

    @objc private func bioChanged() {
        guard bioSwitch.isOn else { lock.useBiometrics = false; return }
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "Включить разблокировку «Линия 2.0»") { ok, _ in
            DispatchQueue.main.async {
                self.lock.useBiometrics = ok
                self.refresh()
            }
        }
    }
}
