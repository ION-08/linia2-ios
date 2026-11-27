//
//  Linia2AppLock.swift
//  Линия 2.0: блокировка приложения PIN-кодом (включается в настройках).
//  PIN (4–6 цифр) хранится в Keychain только как солёный хеш SHA-256, доступный лишь на этом устройстве.
//  Вход — ТОЛЬКО по PIN: Face ID / Touch ID отключены полностью (LocalAuthentication не используется,
//  чтобы на том же экране можно было ввести код паники и чтобы биометрию нельзя было применить принудительно).
//

import CryptoKit
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
    /// Ключ прежней настройки «Разблокировка по Face ID» — только чтобы стереть её у обновившихся.
    private let kBiometricsLegacy = "linia2.applock.biometrics"
    private let kPinLength = "linia2.applock.pinlength"
    private let kLockAfter: TimeInterval = 30   // блокировать после 30 с в фоне

    private var lockWindow: UIWindow?
    private var coverWindow: UIWindow?
    private var backgroundedAt: Date?
    private var locked = false

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: kEnabled) && Linia2PinStore.exists }

    func start() {
        UserDefaults.standard.removeObject(forKey: kBiometricsLegacy)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        // LINIA2: запуск в фоне (push с content-available) — окно PIN не создаём сейчас (и Keychain при
        // заблокированном телефоне недоступен: isEnabled = false). Блокировка — при первом выходе на экран.
        if UIApplication.shared.applicationState == .background {
            backgroundedAt = .distantPast
        } else if isEnabled {
            lock()
        }
    }

    /// Длина PIN-кода (4–6 цифр).
    var pinLength: Int {
        let v = UserDefaults.standard.integer(forKey: kPinLength)
        return (4...6).contains(v) ? v : 4
    }

    func enable(pin: String) -> Bool {
        guard (4...6).contains(pin.count), Linia2PinStore.save(pin: pin) else { return false }
        UserDefaults.standard.set(pin.count, forKey: kPinLength)
        UserDefaults.standard.set(true, forKey: kEnabled)
        return true
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: kEnabled)
        Linia2PinStore.delete()
    }

    func verify(pin: String) -> Bool { Linia2PinStore.verify(pin: pin) }

    // MARK: жизненный цикл

    @objc private func willResignActive() {
        // Снимок в переключателе приложений — без переписки (всегда, даже без PIN).
        guard !locked else { return }
        showCover()
    }

    @objc private func didEnterBackground() {
        if backgroundedAt == nil { backgroundedAt = Date() }
    }

    @objc private func willEnterForeground() {
        // Раньше, чем didBecomeActive, — содержимое не мелькает до экрана PIN.
        guard isEnabled, !locked else { return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) >= kLockAfter {
            lock()
        }
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
        // Дизайн: окно PIN-кода — в выбранной теме приложения (раньше в тёмной теме PIN был светлым).
        w.overrideUserInterfaceStyle = Linia2Appearance.interfaceStyle
        w.tintColor = L2.accent
        w.rootViewController = root
        return w
    }

    private func showCover() {
        guard coverWindow == nil else { return }
        let vc = UIViewController()
        vc.view.backgroundColor = L2.background
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
    private let embedded: Bool
    private var entered = ""
    private var firstPin: String?
    private var failures = 0
    private var cooldownUntil: Date?
    private var pinLength: Int

    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let dots = UIStackView()
    private let lengthButton = UIButton(type: .system)

    init(mode: Mode, embedded: Bool = false) {
        self.mode = mode
        self.embedded = embedded
        self.pinLength = mode == .setNew ? 4 : Linia2AppLock.shared.pinLength
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { return nil }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }   // Дизайн: по теме (в светлой «белые часы» были невидимы)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background

        let logo = L2LogoView(size: 20)

        titleLabel.textColor = L2.textPrimary
        titleLabel.font = L2.rounded(26, .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        hintLabel.textColor = L2.textSecondary
        hintLabel.font = L2.font(15)
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        dots.axis = .horizontal
        dots.spacing = 16
        dots.alignment = .center
        rebuildDots()

        lengthButton.setTitleColor(L2.accent, for: .normal)
        lengthButton.titleLabel?.font = L2.font(15, .medium)
        lengthButton.addTarget(self, action: #selector(toggleLength), for: .touchUpInside)
        lengthButton.isHidden = mode != .setNew

        let pad = UIStackView()
        pad.axis = .vertical
        pad.spacing = 16
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["none", "0", "del"]]
        for row in rows {
            let h = UIStackView()
            h.axis = .horizontal
            h.spacing = 26
            h.distribution = .fillEqually
            for key in row { h.addArrangedSubview(keyButton(key)) }
            pad.addArrangedSubview(h)
        }

        let top = UIStackView(arrangedSubviews: [logo, titleLabel, hintLabel, dots, lengthButton])
        top.axis = .vertical
        top.alignment = .center
        top.spacing = 12
        top.setCustomSpacing(30, after: logo)
        top.setCustomSpacing(26, after: hintLabel)
        top.setCustomSpacing(14, after: dots)

        let main = UIStackView(arrangedSubviews: [top, pad])
        main.axis = .vertical
        main.alignment = .center
        main.spacing = 34
        main.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(main)

        var constraints = [main.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                           main.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                           main.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                           hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
                           dots.heightAnchor.constraint(equalToConstant: 18)]
        if mode == .unlock {
            let forgot = UIButton(type: .system)
            forgot.setTitle("Забыли PIN-код?", for: .normal)
            forgot.setTitleColor(L2.textSecondary, for: .normal)
            forgot.titleLabel?.font = L2.font(15, .medium)
            forgot.addTarget(self, action: #selector(forgotTapped), for: .touchUpInside)
            forgot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(forgot)
            constraints += [forgot.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                            forgot.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)]
        } else if !embedded {
            let cancel = UIButton(type: .system)
            cancel.setTitle("Отмена", for: .normal)
            cancel.setTitleColor(L2.accent, for: .normal)
            cancel.titleLabel?.font = L2.font(17)
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancel)
            constraints += [cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)]
        }
        NSLayoutConstraint.activate(constraints)
        resetTexts()
    }

    private func rebuildDots() {
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for _ in 0..<pinLength {
            let d = UIView()
            d.layer.cornerRadius = 8
            d.layer.borderWidth = 2
            d.layer.borderColor = L2.accent.cgColor
            d.widthAnchor.constraint(equalToConstant: 16).isActive = true
            d.heightAnchor.constraint(equalToConstant: 16).isActive = true
            dots.addArrangedSubview(d)
        }
        updateDots()
    }

    private func resetTexts() {
        switch mode {
        case .unlock:
            titleLabel.text = "Введите PIN-код"
            hintLabel.text = "для входа в «Линия 2.0»"
        case .confirmOld:
            titleLabel.text = "Текущий PIN-код"
            hintLabel.text = "Введите текущий PIN-код"
        case .setNew:
            titleLabel.text = firstPin == nil ? "Придумайте PIN-код" : "Повторите PIN-код"
            hintLabel.text = firstPin == nil ? "\(pinLength) цифр\(pinLength == 4 ? "ы" : "") — для входа в приложение" : "Введите тот же PIN-код ещё раз"
            lengthButton.setTitle(pinLength == 4 ? "PIN из 6 цифр" : "PIN из 4 цифр", for: .normal)
            lengthButton.isHidden = firstPin != nil
        }
    }

    @objc private func toggleLength() {
        pinLength = pinLength == 4 ? 6 : 4
        entered = ""
        rebuildDots()
        resetTexts()
    }

    private func keyButton(_ key: String) -> UIButton {
        let b = UIButton(type: .system)
        b.tintColor = L2.textPrimary
        b.setTitleColor(L2.textPrimary, for: .normal)
        // На небольших экранах (iPhone SE) клавиши меньше, чтобы всё помещалось.
        let side: CGFloat = UIScreen.main.bounds.height < 700 ? 64 : 76
        b.widthAnchor.constraint(equalToConstant: side).isActive = true
        b.heightAnchor.constraint(equalToConstant: side).isActive = true
        switch key {
        case "del":
            b.setImage(L2.symbol("delete.left", 24), for: .normal)
            b.accessibilityLabel = "Стереть"
            b.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        case "none":
            // Место бывшей кнопки Face ID — пустое (вход только по PIN).
            b.isEnabled = false
            b.isAccessibilityElement = false
        default:
            b.setTitle(key, for: .normal)
            b.titleLabel?.font = L2.rounded(32, .medium)
            b.backgroundColor = L2.surface
            b.layer.cornerRadius = (UIScreen.main.bounds.height < 700 ? 64 : 76) / 2
            b.addTarget(self, action: #selector(digitTapped(_:)), for: .touchUpInside)
        }
        return b
    }

    private func updateDots() {
        for (i, d) in dots.arrangedSubviews.enumerated() {
            d.backgroundColor = i < entered.count ? L2.accent : .clear
        }
    }

    @objc private func digitTapped(_ sender: UIButton) {
        if let until = cooldownUntil, until > Date() {
            hintLabel.text = "Слишком много попыток. Подождите \(Int(until.timeIntervalSinceNow) + 1) с"
            return
        }
        guard entered.count < pinLength, let d = sender.currentTitle else { return }
        L2.haptic()
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

    private func close() {
        if !embedded && presentingViewController != nil { dismiss(animated: true) }
    }

    private func complete() {
        let pin = entered
        entered = ""
        updateDots()
        switch mode {
        case .unlock, .confirmOld:
            if Linia2AppLock.shared.verify(pin: pin) {
                onFinish?(true)
                if mode == .confirmOld { close() }
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
                    close()
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
        close()
    }
}

// MARK: - Настройки блокировки (Настройки → Безопасность → «Блокировка приложения»)

final class Linia2AppLockSettingsViewController: UITableViewController {
    private let lockSwitch = UISwitch()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Блокировка приложения"
        lockSwitch.onTintColor = L2.accentStrong
        lockSwitch.accessibilityIdentifier = "l2.applock.switch"
        lockSwitch.addTarget(self, action: #selector(lockChanged), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private var lock: Linia2AppLock { Linia2AppLock.shared }

    private func refresh() {
        lockSwitch.isOn = lock.isEnabled
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { lock.isEnabled ? 2 : 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "При открытии приложения и после 30 секунд в фоне потребуется PIN-код." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0 {
            cell.textLabel?.text = "PIN-код для входа"
            cell.accessoryView = lockSwitch
        } else {
            cell.textLabel?.text = "Сменить PIN-код"
            cell.textLabel?.textColor = L2.accent
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
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
}
