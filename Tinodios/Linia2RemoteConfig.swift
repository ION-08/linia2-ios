//
//  Linia2RemoteConfig.swift
//  Линия 2.0: удалённые настройки (https://v2.chat-linia.site/app-config.json) — без исполняемого кода.
//  Загрузка при запуске и раз в 15 минут; кэш последнего валидного конфига; встроенные значения по умолчанию.
//  Ошибка или недоступность конфига не влияет на работу приложения.
//

import UIKit
import WebKit
import ObjectiveC
import Network
import TinodeSDK
import TinodiosDB

final class Linia2Config {
    static let shared = Linia2Config()
    static let changedNotification = Notification.Name("Linia2ConfigChanged")

    private let url = "https://v2.chat-linia.site/app-config.json"
    private let queue = DispatchQueue(label: "info.codix.liniya2.config")
    private static let queueKey = DispatchSpecificKey<Bool>()
    /// LINIA2: чтение настроек из любого потока; если уже внутри очереди настроек — без queue.sync
    /// (повторный вход в ту же очередь = мгновенный вылет, см. c2ec87a). Тексты (L2T/NSLocalizedString)
    /// читаются отовсюду, поэтому защита общая, а не точечная.
    private func read<T>(_ f: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) == true ? f() : queue.sync(execute: f)
    }
    private var data: [String: Any] = [:]
    private var lastFetch = Date.distantPast
    private var timer: Timer?

    private var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("linia2-app-config.json")
    }

    /// Автотесты: конфиг подменяется из окружения (L2_CONFIG_OVERRIDE = JSON как есть, может быть битым), сеть и кэш не используются.
    private let testOverride: Bool

    private init() {
        queue.setSpecific(key: Self.queueKey, value: true)
        let env = ProcessInfo.processInfo.environment
        if ProcessInfo.processInfo.arguments.contains("-l2-uitest"), let raw = env["L2_CONFIG_OVERRIDE"] {
            testOverride = true
            data = Self.validate(Data(raw.utf8)) ?? [:]
            return
        }
        testOverride = false
        if let u = cacheURL, let d = try? Data(contentsOf: u), let obj = Self.validate(d) {
            data = obj
        }
        applyHosts()
    }

    /// Адреса сервера (servers.hosts) → общие настройки для подключения и расширения уведомлений.
    var serverHosts: [String]? {
        guard let a = section("servers")["hosts"] as? [Any] else { return nil }
        let h = a.compactMap { $0 as? String }.filter(SharedUtils.linia2IsValidHost)
        return h.isEmpty ? nil : h
    }
    var probePath: String {
        let p = section("servers")["probe"] as? String ?? ""
        return p.hasPrefix("/") && p.count < 100 ? p : "/l2-version.json"
    }
    private func applyHosts() {
        guard !testOverride || serverHosts != nil else { return }
        if let h = serverHosts { SharedUtils.linia2SetHosts(h) }
    }

    /// Как часто перечитывать конфиг (live.pollSeconds, не чаще раза в минуту).
    var pollSeconds: TimeInterval {
        guard let v = section("live")["pollSeconds"] as? NSNumber else { return 900 }
        return min(86400, max(60, v.doubleValue))
    }

    // MARK: загрузка

    func start() {
        Self.installTextOverrides()
        fetch()
        scheduleTimer()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, Date().timeIntervalSince(self.lastFetch) > 60 else { return }
            self.fetch()
        }
        DispatchQueue.main.async { Linia2UpdateGate.checkAndShow() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollSeconds, repeats: true) { [weak self] _ in self?.fetch() }
    }

    /// Тихий push FCM на тему linia2-config ({"l2cfg": "<версия>"}) — перечитать сразу.
    static func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["l2cfg"] != nil else { return false }
        shared.fetch()
        return true
    }

    func fetch() {
        if testOverride { return }
        lastFetch = Date()
        // По очереди: активный адрес, затем остальные (резервные) — конфиг доступен, даже если основной заблокирован.
        let active = SharedUtils.linia2ActiveHost
        let hosts = [active] + SharedUtils.linia2Hosts.filter { $0 != active }
        fetch(from: hosts)
    }

    private func fetch(from hosts: [String]) {
        guard let host = hosts.first,
              let u = URL(string: "https://\(host)/app-config.json?t=\(Int(Date().timeIntervalSince1970))") else { return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { [weak self] d, resp, _ in
            guard let self = self else { return }
            guard let d = d, (resp as? HTTPURLResponse)?.statusCode == 200, let obj = Self.validate(d) else {
                if hosts.count > 1 { self.fetch(from: Array(hosts.dropFirst())) }
                return
            }
            self.queue.async {
                let changed = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) !=
                    (try? JSONSerialization.data(withJSONObject: self.data, options: [.sortedKeys]))
                guard changed else { return }
                self.data = obj
                // applyHosts() читает section() через queue.sync — внутри этой же очереди это взаимная блокировка
                // (iOS аварийно завершает приложение при каждом изменении конфига). Вызываем вне очереди, на главном потоке.
                if let cu = self.cacheURL {
                    try? FileManager.default.createDirectory(at: cu.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? d.write(to: cu, options: .atomic)
                }
                DispatchQueue.main.async {
                    self.applyHosts()
                    self.scheduleTimer()
                    NotificationCenter.default.post(name: Self.changedNotification, object: nil)
                    Linia2UpdateGate.checkAndShow()
                }
            }
        }.resume()
    }

    private static func validate(_ d: Data) -> [String: Any]? {
        guard d.count < 1_000_000, let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let schema = obj["schema"] as? Int, schema > 1 { return nil }   // новая схема, которую эта версия не понимает
        return obj
    }

    private func section(_ name: String) -> [String: Any] {
        read { (data[name] as? [String: Any]) ?? [:] }
    }

    private func array(_ name: String) -> [Any]? {
        read { data[name] as? [Any] }
    }

    private static func hex(_ any: Any?) -> UInt32? {
        guard let s = any as? String else { return nil }
        let h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return v
    }

    /// Цвет светлой темы (colorsLight).
    func colorLight(_ key: String) -> UInt32? { Self.hex(section("colorsLight")[key]) }

    /// Радиус скругления (radii), 0…40, иначе встроенный.
    func radius(_ key: String, _ builtin: CGFloat) -> CGFloat {
        guard let v = section("radii")[key] as? NSNumber else { return builtin }
        return CGFloat(min(40, max(0, v.doubleValue)))
    }

    struct TabSpec: Equatable { let id: String; let title: String?; let iconURL: URL? }
    static let builtinTabs = ["chats", "calls", "contacts", "settings"]

    /// Видимые вкладки по порядку. «Чаты» и «Настройки» скрыть нельзя; неизвестные id игнорируются.
    var tabs: [TabSpec] {
        var out: [TabSpec] = []
        for case let t as [String: Any] in array("tabs") ?? [] {
            guard let id = t["id"] as? String, Self.builtinTabs.contains(id), !out.contains(where: { $0.id == id }) else { continue }
            let visible = (t["visible"] as? Bool) ?? true
            if !visible && id != "chats" && id != "settings" { continue }
            var title = (t["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tt = title, tt.isEmpty || tt.count > 20 { title = nil }
            var icon: URL?
            if let s = t["iconUrl"] as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" { icon = u }
            out.append(TabSpec(id: id, title: title, iconURL: icon))
        }
        for id in ["chats", "settings"] where !out.contains(where: { $0.id == id }) {
            out.insert(TabSpec(id: id, title: nil, iconURL: nil), at: id == "chats" ? 0 : out.count)
        }
        if out.count == 2, array("tabs") == nil {   // поля нет — встроенный набор
            return Self.builtinTabs.map { TabSpec(id: $0, title: nil, iconURL: nil) }
        }
        return out
    }

    /// Набор эмодзи реакций (reactions.emoji), 1…12 штук.
    var reactionEmoji: [String]? {
        guard let a = section("reactions")["emoji"] as? [Any] else { return nil }
        let e = a.compactMap { $0 as? String }.filter { !$0.isEmpty && $0.count <= 4 }
        return e.isEmpty ? nil : Array(e.prefix(12))
    }

    /// Ряд реакций (reactions.primary / reactions.more), 1…24 системных эмодзи; nil — встроенный.
    func reactionList(_ key: String) -> [String]? {
        guard let a = section("reactions")[key] as? [Any] else { return nil }
        var seen = Set<String>()
        let e = a.compactMap { $0 as? String }.filter { !$0.isEmpty && $0.count <= 2 && $0.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x238C } && seen.insert($0).inserted }
        return e.isEmpty ? nil : Array(e.prefix(24))
    }

    /// Полный список эмодзи с поиском по «+» (reactions.fullList), по умолчанию — да.
    var reactionsFullList: Bool { (section("reactions")["fullList"] as? Bool) ?? true }

    /// Порядок и видимость пунктов меню (menus.message / menus.settings); nil — встроенный.
    func menu(_ name: String) -> [String]? {
        guard let a = section("menus")[name] as? [Any] else { return nil }
        let ids = a.compactMap { $0 as? String }
        return ids.isEmpty && !a.isEmpty ? nil : ids
    }

    private func limit(_ key: String) -> Double? {
        guard let v = section("limits")[key] as? NSNumber, v.doubleValue > 0 else { return nil }
        return v.doubleValue
    }
    /// Максимальный размер вложения в байтах (limits.maxFileMB, 1…100).
    var maxFileBytes: Int64? { limit("maxFileMB").map { Int64(min(100, max(1, $0)) * 1024 * 1024) } }
    /// Максимальная длина сообщения (limits.maxMessageLength, 100…20000).
    var maxMessageLength: Int? { limit("maxMessageLength").map { Int(min(20000, max(100, $0))) } }
    /// Время на изменение своего сообщения, секунд (limits.editWindowMinutes; нет/0 — без ограничения).
    var editWindowSeconds: TimeInterval? { limit("editWindowMinutes").map { $0 * 60 } }

    /// Контакты поддержки (support.*).
    func support(_ key: String) -> String? {
        guard let s = section("support")[key] as? String, !s.isEmpty, s.count < 200 else { return nil }
        return s
    }

    // MARK: значения

    /// Цвет #RRGGBB из раздела colors.
    func color(_ key: String) -> UInt32? { Self.hex(section("colors")[key]) }

    var defaultTheme: String? { section("colors")["defaultTheme"] as? String }

    func text(_ key: String) -> String? {
        guard let s = section("texts")[key] as? String, !s.isEmpty, s.count < 2000 else { return nil }
        return s
    }

    func link(_ key: String) -> URL? {
        guard let s = section("links")[key] as? String, let u = URL(string: s),
              ["https", "mailto"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }

    /// Слайды экрана приветствия (images.welcomeSlides, только https).
    var welcomeSlides: [URL] {
        ((section("images")["welcomeSlides"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(URL.init(string:)) }
            .filter { $0.scheme?.lowercased() == "https" }
    }

    func image(_ key: String) -> URL? {
        guard let s = section("images")[key] as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    /// Число из раздела (например, roundVideo.ttlDays); nil — нет или не число.
    func number(_ sectionName: String, _ key: String) -> Double? {
        guard let v = section(sectionName)[key] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID() else { return nil }
        return v.doubleValue
    }

    /// Список чисел из раздела (например, burnMode.options).
    func numbers(_ sectionName: String, _ key: String) -> [Double]? {
        guard let a = section(sectionName)[key] as? [Any] else { return nil }
        let n = a.compactMap { ($0 as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
        return n.isEmpty ? nil : n
    }

    /// Список строк из раздела (например, chatHeader.buttons); nil — нет или не список.
    func strings(_ sectionName: String, _ key: String) -> [String]? {
        guard let a = section(sectionName)[key] as? [Any] else { return nil }
        return a.compactMap { $0 as? String }
    }

    /// Встроенная функция включена? По умолчанию — да.
    func feature(_ name: String) -> Bool {
        (section("features")[name] as? Bool) ?? true
    }

    /// Функция с заданным значением по умолчанию (для выключенных по умолчанию).
    func feature(_ name: String, default value: Bool) -> Bool {
        (section("features")[name] as? Bool) ?? value
    }

    struct Banner { let text: String; let color: UInt32?; let url: URL? }
    var banner: Banner? {
        let b = section("banner")
        guard (b["enabled"] as? Bool) == true, let t = b["text"] as? String, !t.isEmpty else { return nil }
        var color: UInt32?
        if let c = b["color"] as? String { color = UInt32(c.replacingOccurrences(of: "#", with: ""), radix: 16) }
        var url: URL?
        if let s = b["url"] as? String, let u = URL(string: s), ["https", "mailto"].contains(u.scheme?.lowercased() ?? "") { url = u }
        return Banner(text: String(t.prefix(300)), color: color, url: url)
    }

    var minVersionIOS: String? { section("minVersion")["ios"] as? String }
    var updateMessage: String? { section("minVersion")["message"] as? String }
    var storeURL: URL? {
        guard let s = section("minVersion")["storeUrl"] as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    var bannedWords: [String] {
        read { (data["bannedWords"] as? [String]) ?? [] }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Первое запрещённое слово в тексте (без учёта регистра) или nil.
    func bannedWord(in text: String) -> String? {
        let t = text.lowercased()
        return bannedWords.first { t.contains($0) }
    }

    func page(_ name: String) -> String? {
        guard let s = section("pages")[name] as? String, !s.isEmpty else { return nil }
        return s
    }

    // MARK: тексты интерфейса: словарь с сервера поверх встроенных строк

    private static var swizzled = false
    static func installTextOverrides() {
        // Системные окна (выбор фото, «Поделиться» и т.п.) — тоже на русском, со следующего запуска.
        // Под автотестом не трогаем: в симуляторе это переключает клавиатуру на русскую раскладку.
        if !ProcessInfo.processInfo.arguments.contains("-l2-uitest"),
           (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first != "ru" {
            UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")
        }
        guard !swizzled,
              let m1 = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
              let m2 = class_getInstanceMethod(Bundle.self, #selector(Bundle.l2_localizedString(forKey:value:table:))) else { return }
        method_exchangeImplementations(m1, m2)
        swizzled = true
    }
}

extension Bundle {
    /// Русская локализация — приложение всегда на русском, даже если язык телефона другой.
    static let l2Russian: Bundle? = Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap { Bundle(path: $0) }

    @objc func l2_localizedString(forKey key: String, value: String?, table: String?) -> String {
        if self === Bundle.main {
            if let t = Linia2Config.shared.text(key) { return t }
            if let fixed = Linia2Texts.ru[key] { return fixed }
            if let ru = Bundle.l2Russian {
                let marker = "\u{1}l2-missing"
                // Для ru-бандла self !== main, поэтому вызов уходит в исходную реализацию.
                let v = ru.localizedString(forKey: key, value: marker, table: table)
                if v != marker { return v }
            }
        }
        // После обмена реализаций этот вызов — исходный localizedString.
        return l2_localizedString(forKey: key, value: value, table: table)
    }
}

/// Текст своих экранов: серверный словарь (ключ l2.*) или встроенный вариант.
func L2T(_ key: String, _ fallback: String) -> String {
    Linia2Config.shared.text(key) ?? fallback
}

// MARK: - «Требуется обновление»

enum Linia2UpdateGate {
    private static var window: UIWindow?

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    static func checkAndShow() {
        guard let min = Linia2Config.shared.minVersionIOS,
              let cur = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { hide(); return }
        if compare(cur, min) < 0 { show() } else { hide() }
    }

    private static func show() {
        guard window == nil else { return }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.windowLevel = .alert + 3
        w.rootViewController = Linia2UpdateViewController()
        w.isHidden = false
        window = w
    }

    private static func hide() {
        window?.isHidden = true
        window = nil
    }
}

final class Linia2UpdateViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        let icon = UIImageView(image: L2.symbol("arrow.down.app.fill", 64, .regular))
        icon.tintColor = L2.accent
        icon.contentMode = .center
        let title = UILabel()
        title.text = L2T("l2.update.title", "Требуется обновление")
        title.font = L2.rounded(28, .heavy)
        title.textColor = L2.textPrimary
        title.textAlignment = .center
        let text = UILabel()
        text.text = Linia2Config.shared.updateMessage ?? "Доступна новая версия «Линия 2.0». Обновите приложение, чтобы продолжить."
        text.font = L2.font(16)
        text.textColor = L2.textSecondary
        text.numberOfLines = 0
        text.textAlignment = .center
        let button = L2Button(L2T("l2.update.button", "Обновить"))
        button.addTarget(self, action: #selector(openStore), for: .touchUpInside)
        button.isHidden = Linia2Config.shared.storeURL == nil
        let stack = UIStackView(arrangedSubviews: [icon, title, text, button])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                     stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
                                     stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28)])
    }

    @objc private func openStore() {
        if let u = Linia2Config.shared.storeURL { UIApplication.shared.open(u) }
    }
}

// MARK: - HTML-страницы с сервера («О приложении», «Помощь», «Что нового»)

final class Linia2HTMLPageViewController: UIViewController, WKNavigationDelegate {
    private let pageTitle: String
    private let html: String

    init(title: String, html: String) {
        self.pageTitle = title
        self.html = html
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = pageTitle
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = L2.background
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false   // только разметка, без кода
        cfg.websiteDataStore = WKWebsiteDataStore.nonPersistent()   // LINIA2: без кэша страниц на диске
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = L2.background
        web.scrollView.backgroundColor = L2.background
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([web.topAnchor.constraint(equalTo: view.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        let tc = traitCollection
        func hex(_ c: UIColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.resolvedColor(with: tc).getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        let css = "body{font:17px -apple-system,system-ui;color:\(hex(L2.textPrimary));background:\(hex(L2.background));padding:8px 20px 40px;line-height:1.5}" +
            "a{color:\(hex(L2.accent))}h1,h2,h3{line-height:1.25}img{max-width:100%;border-radius:12px}"
        web.loadHTMLString("<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'><style>\(css)</style></head><body>\(html)</body></html>", baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let u = navigationAction.request.url {
            UIApplication.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Исправленные/недостающие русские тексты (поверх ru.lproj).
enum Linia2Texts {
    static let ru: [String: String] = [
        "Attachment": "Вложение",
        // Статусы звонков в ленте и списке (ключи — состояния WebRTC сервера).
        "missed": "Пропущенный",
        "busy": "Занято",
        "declined": "Отклонён",
        "disconnected": "Не состоялся",
        "cancelled": "Отменён",
        "connecting": "Соединение…",
        "in progress": "Идёт звонок",
        "Image / Video": "Фото или видео",
        "File": "Файл",
        "Cancel": "Отмена",
        "Take photo": "Сделать фото",
        "Camera roll": "Фотоплёнка",
        "Photo library": "Медиатека",
        "Scan QR code": "Сканировать QR-код",
        "Avatar successfully updated": "Фото профиля обновлено",
        "Server error": "Ошибка сервера",
        "Failed to connect to server": "Не удалось подключиться к серверу",
        "Video playback error": "Ошибка воспроизведения видео",
        "Invalid input": "Некорректные данные",
        "Removed non-existent user.": "Пользователь не найден и удалён из списка.",
        "Added non-existent user": "Пользователь не найден",
        "Invalid member selection. Try again.": "Неверный выбор участников. Попробуйте ещё раз.",
        "Confirmation code sent": "Код подтверждения отправлен",
        "Credentials confirmed": "Подтверждено",
        "Password successfully updated": "Пароль обновлён",
        "Invalid or incorrect code": "Неверный код",
        "Invalid params": "Некорректные данные",
    ]

    /// Для строк, зашитых в код без NSLocalizedString.
    static func t(_ s: String) -> String { ru[s] ?? s }
}


// MARK: - Картинки по URL из удалённых настроек (логотип, экран приветствия, иконки)

enum L2RemoteImage {
    private static var cache: [URL: UIImage] = [:]

    /// Загрузить картинку (https, до 2 МБ) в imageView; при ошибке ничего не меняется (остаётся встроенное).
    static func load(_ url: URL?, into iv: UIImageView, onLoad: ((UIImage) -> Void)? = nil) {
        guard let url = url else { return }
        if let img = cache[url] { iv.image = img; onLoad?(img); return }
        URLSession.shared.dataTask(with: url) { [weak iv] d, r, _ in
            guard let d = d, d.count < 2_000_000, (r as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: d) else { return }
            DispatchQueue.main.async {
                cache[url] = img
                iv?.image = img
                onLoad?(img)
            }
        }.resume()
    }
}

extension Linia2Config {
    /// Картинки экрана приветствия: images.welcomeSlides (первая) или images.welcomeImageUrl.
    var welcomeImageURL: URL? {
        if let first = welcomeSlides.first { return first }
        return image("welcomeImageUrl")
    }
}


// MARK: - Резервные адреса и статус соединения (LINIA2_FAILOVER)

/// Следит за соединением: при таймауте/обрывах переключает на следующий адрес из servers.hosts,
/// раз в минуту проверяет основной и возвращается на него. Пользователь видит только «Подключение…».
final class Linia2Failover: TinodeEventListener {
    static let shared = Linia2Failover()
    /// LINIA2 (сборка 1011, цикл переподключения): резервный адрес — только после стольких подряд неудачных
    /// подключений (не отмен нами); после смены адреса счёт начинается заново, смены не чаще раза в 30 с.
    private static let kFailsBeforeSwitch = 3
    private static let kMinSwitchInterval: TimeInterval = 30
    private var consecutiveFails = 0
    private var lastFailAt = Date.distantPast
    private var lastSwitchAt = Date.distantPast

    // Приложение на экране — читается с очередей соединения, поэтому под замком.
    private static let stateLock = NSLock()
    private static var appActiveValue = true
    static var appActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return appActiveValue }
        set { stateLock.lock(); appActiveValue = newValue; stateLock.unlock() }
    }
    /// Переподключаться можно: приложение на экране или идёт звонок (CallKit / VoIP).
    static var reconnectAllowed: Bool {
        appActive || CallManager.state.uuid != nil || CallManager.state.inConversation
    }
    private var attemptStarted: Date?
    private var connected = false
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private var networkOK = true
    private var banner: UILabel?

    func start() {
        Cache.tinode.addListener(self)
        Linia2Failover.appActive = UIApplication.shared.applicationState != .background
        Connection.linia2ReconnectAllowed = { Linia2Failover.reconnectAllowed }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Linia2Failover.appActive = true
            // Возврат в приложение — мгновенная попытка (пауза сброшена), вне главного потока.
            DispatchQueue.global(qos: .userInitiated).async { Cache.tinode.linia2ResumeNow(reason: "active") }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Linia2Failover.appActive = false
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            // Сеть появилась / сменилась — мгновенная попытка (если можно переподключаться).
            if ok, Linia2Failover.reconnectAllowed, Cache.tinode.myUid != nil {
                Cache.tinode.linia2ResumeNow(reason: "network")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok && !self.networkOK { self.consecutiveFails = 0 }   // новая сеть — счёт неудач заново
                self.networkOK = ok
                self.updateBanner()
            }
        }
        monitor.start(queue: DispatchQueue(label: "linia2.net"))
        attemptStarted = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
    }

    func onConnect(code: Int, reason: String, params: [String: JSONValue]?) {
        DispatchQueue.main.async {
            self.connected = true
            self.connectedAt = Date()
            self.consecutiveFails = 0
            self.attemptStarted = nil
            self.updateBanner()
        }
    }

    func onDisconnect(byServer: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String) {
        DispatchQueue.main.async {
            self.connected = false
            let now = Date()
            if self.attemptStarted == nil { self.attemptStarted = now }
            defer { self.updateBanner() }
            // Сокет закрыли мы (отмена / смена адреса / выход) — не обрыв.
            guard reason != Tinode.linia2ClientCancelReason else { return }
            // В фоне без звонка обрыв нормален (iOS рвёт сокет) — адрес не меняем, ждём возврата.
            guard Linia2Failover.reconnectAllowed else { return }
            self.countFailure(now, why: "обрыв")
        }
    }

    /// Неудачное подключение (обрыв до/после входа или таймаут). Повторы одной и той же неудачи в пределах 1 с
    /// считаются одной. Смена адреса — после kFailsBeforeSwitch подряд, не чаще kMinSwitchInterval.
    private func countFailure(_ now: Date, why: String) {
        guard now.timeIntervalSince(lastFailAt) >= 1 else { return }
        lastFailAt = now
        consecutiveFails += 1
        guard consecutiveFails >= Linia2Failover.kFailsBeforeSwitch,
              now.timeIntervalSince(lastSwitchAt) >= Linia2Failover.kMinSwitchInterval else { return }
        switchToNext("\(consecutiveFails) неудачных подключений подряд (\(why))")
    }

    private var lastProbe = Date.distantPast
    /// LINIA2: момент ответа сервера на {hi} — сокет жив; вход ({login}) должен последовать за ним.
    private var connectedAt: Date?
    private var lastLoginHeal = Date.distantPast

    /// Сокет открыт, но вход не выполнен дольше 6 с (сборка 1007: «Подключение…» навсегда при живом сокете).
    private var connectedButNotLoggedIn: Bool {
        let t = Cache.tinode
        guard connected, t.myUid != nil, !t.isConnectionAuthenticated, let c = connectedAt else { return false }
        return Date().timeIntervalSince(c) > 6
    }

    func onLogin(code: Int, text: String) {
        DispatchQueue.main.async { self.updateBanner() }
    }

    private func tick() {
        // LINIA2 (большой аккаунт: «подключилось с 3-й попытки»): флаг connected ставится через main.async из
        // onConnect и при занятом главном потоке / очереди разбора отстаёт — раньше по нему рвался рабочий сокет.
        // Состояние сокета — напрямую.
        if !connected && Cache.tinode.isConnected {
            connected = true
            if connectedAt == nil { connectedAt = Date() }
            attemptStarted = nil
        }
        updateBanner()
        // Соединение есть, а входа нет — войти заново (не чаще раза в 20 с, пока приложение на экране).
        if connectedButNotLoggedIn, UIApplication.shared.applicationState == .active,
           Date().timeIntervalSince(lastLoginHeal) > 20, SharedUtils.getAuthToken() != nil {
            lastLoginHeal = Date()
            Cache.log.info("Linia2Failover: connected but not logged in — retrying login")
            L2Log.event("l2_login_heal")
            AppDelegate.connectInBackground(attempt: 0)
        }
        guard Linia2Failover.reconnectAllowed else { return }
        // Нет ответа дольше 8 с при живой сети — одна неудачная попытка (адрес меняет countFailure).
        if !connected, networkOK, let t = attemptStarted, Date().timeIntervalSince(t) > 8, Cache.tinode.myUid != nil {
            attemptStarted = Date()
            countFailure(Date(), why: "таймаут")
        }
        // На резервном и без связи — раз в минуту проверяем основной. Рабочее соединение на резервном НЕ рвём
        // (сборка 1011: возврат на основной через 4 с после входа рвал живой сокет и запускал цикл).
        let primary = SharedUtils.linia2Hosts[0]
        if !connected, !Cache.tinode.isConnected, SharedUtils.linia2ActiveHost != primary, Date().timeIntervalSince(lastProbe) > 60 {
            lastProbe = Date()
            probe(primary) { [weak self] ok in if ok { self?.use(primary, why: "основной снова доступен") } }
        }
    }

    private func probe(_ host: String, _ done: @escaping (Bool) -> Void) {
        guard let u = URL(string: "https://\(host)\(Linia2Config.shared.probePath)?t=\(Int(Date().timeIntervalSince1970))") else { return done(false) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { _, r, e in
            DispatchQueue.main.async { done(e == nil && (r as? HTTPURLResponse)?.statusCode == 200) }
        }.resume()
    }

    private func switchToNext(_ why: String) {
        // Сокет открыт (вход может ещё идти — на большом аккаунте долго) — не рвать.
        if Cache.tinode.isConnected { attemptStarted = Date(); return }
        let hosts = SharedUtils.linia2Hosts
        guard hosts.count > 1 else { attemptStarted = Date(); return }
        let i = hosts.firstIndex(of: SharedUtils.linia2ActiveHost) ?? 0
        use(hosts[(i + 1) % hosts.count], why: why)
    }

    private func use(_ host: String, why: String) {
        guard host != SharedUtils.linia2ActiveHost || !connected else { return }
        Cache.log.info("Linia2: адрес сервера → %@ (%@)", host, why)
        SharedUtils.linia2ActiveHost = host
        attemptStarted = Date()
        lastSwitchAt = Date()
        consecutiveFails = 0
        L2Log.event("l2_switch_host", ["why": why])
        // linia2SwitchHost синхронно ждёт очередь операций Tinode — не на главном потоке.
        DispatchQueue.global(qos: .userInitiated).async { Cache.tinode.linia2SwitchHost(to: host) }
    }

    /// Плашка сверху: «Нет соединения» (нет сети) или «Подключение…» (сеть есть, сервер ещё не ответил).
    private func updateBanner() {
        let show = Cache.tinode.myUid != nil && ((!connected && (attemptStarted.map { Date().timeIntervalSince($0) > 2 } ?? true))
                                                 || connectedButNotLoggedIn)
        guard let window = Linia2Root.window else { return }
        if !show { banner?.removeFromSuperview(); banner = nil; return }
        let l = banner ?? {
            let l = PaddedLabelL2()
            l.font = L2.font(13, .semibold)
            l.textColor = L2.textPrimary
            l.backgroundColor = L2.surface2.withAlphaComponent(0.95)
            l.layer.cornerRadius = 14
            l.clipsToBounds = true
            l.textAlignment = .center
            l.accessibilityIdentifier = "l2.connection.status"
            l.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(l)
            NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                                         l.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
                                         l.heightAnchor.constraint(equalToConstant: 28)])
            banner = l
            return l
        }()
        l.text = networkOK ? L2T("l2.net.connecting", "Подключение…") : L2T("l2.net.offline", "Нет соединения")
        window.bringSubviewToFront(l)
    }
}

final class PaddedLabelL2: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 0)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height)
    }
}
