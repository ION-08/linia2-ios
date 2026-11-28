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

    /// LINIA2 (1019): встроенные адреса конфига (bootstrap) — на случай, если основной домен заблокирован.
    static let bootstrapURLs = ["https://v2.chat-linia.site/app-config.json", "https://v2b.chat-linia.site/app-config.json"]
    private static let kLastConfigURL = "linia2.config.lastURL"

    /// Адреса конфига по порядку: последний удачный → активный адрес сервера → остальные адреса (servers.hosts) →
    /// servers.configUrls из последнего полученного конфига → встроенные. Только https, без повторов, не больше 16.
    func configURLs() -> [URL] {
        var list: [String] = []
        if let last = UserDefaults.standard.string(forKey: Self.kLastConfigURL) { list.append(last) }
        let active = SharedUtils.linia2ActiveHost
        for h in [active] + SharedUtils.linia2Hosts.filter({ $0 != active }) { list.append("https://\(h)/app-config.json") }
        list += strings("servers", "configUrls") ?? []
        list += Self.bootstrapURLs
        var seen = Set<String>()
        var out: [URL] = []
        for s in list {
            guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme?.lowercased() == "https", u.host != nil,
                  s.count < 300, seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
            if out.count >= 16 { break }
        }
        return out
    }

    func fetch() {
        if testOverride { return }
        lastFetch = Date()
        // По очереди: последний удачный, активный адрес, резервные, bootstrap — сначала по HTTP/3 (QUIC проходит там,
        // где TCP режется), затем те же адреса обычным HTTP.
        let urls = configURLs()
        fetch(from: urls.map { ($0, true) } + urls.map { ($0, false) })
    }

    private func fetch(from attempts: [(URL, Bool)]) {
        guard let first = attempts.first else { return }
        let base = first.0, h3 = first.1
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        guard let u = c.url else { return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: h3 ? 6 : 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.assumesHTTP3Capable = h3
        URLSession.shared.dataTask(with: req) { [weak self] d, resp, _ in
            guard let self = self else { return }
            guard let d = d, (resp as? HTTPURLResponse)?.statusCode == 200, let obj = Self.validate(d) else {
                if attempts.count > 1 { self.fetch(from: Array(attempts.dropFirst())) }
                return
            }
            UserDefaults.standard.set(base.absoluteString, forKey: Self.kLastConfigURL)
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

    /// LINIA2 (1019): список транспортов features.transports (см. Linia2Transports).
    var transportSpec: [[String: Any]]? {
        guard let a = section("features")["transports"] as? [Any] else { return nil }
        return a.compactMap { $0 as? [String: Any] }
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
    // Журнал пути сети (net-path) — не чаще раза в 2 с; одинаковые подряд не пишутся.
    // Интерфейсы/адреса НЕ считаются признаком смены сети (IPv6 / NAT64 / VPN меняют их без обрыва).
    private static let pathQueue = DispatchQueue(label: "linia2.net.path")
    private static var lastPathLine = "", lastPathLog = Date.distantPast
    private static var checkScheduled = false
    /// Только на очереди монитора (linia2.net).
    private static var pathSeen = false
    static func logPath(_ p: NWPath) {
        let ifs = p.availableInterfaces.map { i -> String in
            switch i.type { case .wifi: return "wifi"; case .cellular: return "cell"; case .wiredEthernet: return "eth"
            case .loopback: return "lo"; case .other: return "other"; @unknown default: return "?" }
        }.joined(separator: ",")
        let st: String = p.status == .satisfied ? "ok" : (p.status == .unsatisfied ? "none" : "req")
        let line = "\(st)|\(ifs)|\(p.isExpensive)|\(p.isConstrained)|\(p.supportsIPv4)|\(p.supportsIPv6)"
        Linia2Failover.pathQueue.async {
            let now = Date()
            guard line != Linia2Failover.lastPathLine, now.timeIntervalSince(Linia2Failover.lastPathLog) >= 2 else { return }
            Linia2Failover.lastPathLine = line; Linia2Failover.lastPathLog = now
            Linia2LaunchLog.shared.step("net-path", ["status": st, "ifs": ifs, "expensive": p.isExpensive ? 1 : 0,
                                                     "constrained": p.isConstrained ? 1 : 0,
                                                     "ipv4": p.supportsIPv4 ? 1 : 0, "ipv6": p.supportsIPv6 ? 1 : 0])
        }
    }
    static func coalescedNetworkCheck() {
        Linia2Failover.pathQueue.async {
            guard !Linia2Failover.checkScheduled else { return }
            Linia2Failover.checkScheduled = true
            Linia2Failover.pathQueue.asyncAfter(deadline: .now() + 2) {
                Linia2Failover.checkScheduled = false
                // Автотест: каждая вторая проверка — ping с таймаутом 1 мс (как мёртвый сокет → переподключение).
                var timeout: TimeInterval = 5
                if Linia2Failover.testForcePing { Linia2Failover.testShortPing.toggle(); if Linia2Failover.testShortPing { timeout = 0.001 } }
                DispatchQueue.global(qos: .userInitiated).async { Cache.tinode.linia2NetworkChanged(pingTimeout: timeout) }
            }
        }
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
    private var banner: Linia2ConnectionPill?

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
            Linia2Failover.logPath(path)
            self?.linia2HandlePath(ok: path.status == .satisfied)
        }
        monitor.start(queue: netQueue)
        // LINIA2 (1019): перебор маршрутов — сразу обновить плашку («резервный канал K из N»).
        nc.addObserver(forName: Linia2Transports.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateBanner()
        }
        attemptStarted = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
    }

    private let netQueue = DispatchQueue(label: "linia2.net")
    /// Автотест (-l2-uitest, L2_TEST_PATH_STORM=1): ws ping включён независимо от features.netPathPing.
    static var testForcePing = false
    private static var testShortPing = false

    /// Событие пути сети (на очереди монитора linia2.net) — из NWPathMonitor и из теста «шторм смены сети».
    /// Сеть появилась / сменилась. Живое соединение не рвём: при features.netPathPing открытый сокет проверяется
    /// ws ping (5 с), переподключение — только без ответа; нет сокета — мгновенная попытка (как в 1012).
    /// LINIA2 (hotfix 1014, вылет 1013 при запуске на 5G): первое событие пути (сразу после start) — как в 1012;
    /// состояние соединения — только синхронно (linia2IsConnectedSafe); netPathPing по умолчанию выкл.
    func linia2HandlePath(ok: Bool) {
        let first = !Linia2Failover.pathSeen
        Linia2Failover.pathSeen = true
        if ok, Linia2Failover.reconnectAllowed, Cache.tinode.myUid != nil {
            let ping = Linia2Failover.testForcePing || Linia2Config.shared.feature("netPathPing", default: false)
            if !first, ping, Cache.tinode.linia2IsConnectedSafe {
                Linia2Failover.coalescedNetworkCheck()
            } else {
                Cache.tinode.linia2ResumeNow(reason: "network")
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if ok && !self.networkOK { self.consecutiveFails = 0 }   // новая сеть — счёт неудач заново
            self.networkOK = ok
            self.updateBanner()
        }
    }

    /// Автотест: каждые 200 мс в течение `seconds` — событие пути (тот же обработчик), каждое 15-е — «сети нет».
    func linia2TestPathStorm(seconds: Double) {
        let n = Int(seconds / 0.2)
        for i in 0..<n {
            netQueue.asyncAfter(deadline: .now() + Double(i) * 0.2) { [weak self] in
                self?.linia2HandlePath(ok: i % 15 != 14)
                DispatchQueue.main.async { Linia2TestProbe.pathEvents += 1 }
            }
        }
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
        // LINIA2 (1019): адреса перебирает список маршрутов (Linia2Transports) — здесь адрес не меняем.
        guard !Linia2Transports.shared.handlesHosts else { return }
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
        if !Linia2Transports.shared.handlesHosts,
           !connected, !Cache.tinode.isConnected, SharedUtils.linia2ActiveHost != primary, Date().timeIntervalSince(lastProbe) > 60 {
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
        // Живое (открытое или авторизованное) соединение не рвём ради другого адреса — никогда.
        let t = Cache.tinode
        guard !t.isConnected, !t.isConnectionAuthenticated else {
            L2Log.event("l2_switch_host_skip", ["why": why])
            return
        }
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
            let l = Linia2ConnectionPill()
            l.accessibilityIdentifier = "l2.connection.status"
            l.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(l)
            NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                                         l.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
                                         l.heightAnchor.constraint(equalToConstant: 28)])
            banner = l
            return l
        }()
        // «Подключение…» — с маленькой пульсирующей линией логотипа; «Нет соединения» — без неё.
        // LINIA2 (1019): идёт переход на резервный маршрут — «Плохое соединение — … резервный канал K из N…».
        var text = networkOK ? L2T("l2.net.connecting", "Подключение…") : L2T("l2.net.offline", "Нет соединения")
        if networkOK, let fb = Linia2Transports.shared.fallbackText { text = fb }
        l.set(text: text, pulse: networkOK)
        window.bringSubviewToFront(l)
    }
}

/// Плашка состояния соединения: [~ импульс] «Подключение…». Тихо, касания проходят насквозь.
final class Linia2ConnectionPill: UIView {
    private let label = UILabel()
    private let pulse = Linia2PulseLine()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = L2.surface2.withAlphaComponent(0.95)
        layer.cornerRadius = 14
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
        label.font = L2.font(13, .semibold)
        label.textColor = L2.textPrimary
        label.textAlignment = .center
        pulse.lineColor = L2.accent
        pulse.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([pulse.widthAnchor.constraint(equalToConstant: 22),
                                     pulse.heightAnchor.constraint(equalToConstant: 13)])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.addArrangedSubview(pulse)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        // LINIA2 (1019): длинный текст («резервный канал K из N») — уменьшается, не выходит за экран.
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        label.lineBreakMode = .byTruncatingTail
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let sv = superview else { return }
        widthAnchor.constraint(lessThanOrEqualTo: sv.widthAnchor, constant: -24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(text: String, pulse show: Bool) {
        label.text = text
        accessibilityLabel = text
        pulse.isHidden = !show
    }
}

final class PaddedLabelL2: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 0)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height)
    }
}

// MARK: - LINIA2 (сборка 1019): транспорты канала Tinode (ws / lp-h3 / lp) и зеркала

/// Список маршрутов подключения (транспорт + адрес) из app-config и автоматическое переключение (TinodeSDK/Connection).
/// app-config, раздел features:
///   "transports": [{"type":"ws","host":"v2.chat-linia.site"}, {"type":"lp-h3","host":"v2.chat-linia.site"},
///                  {"type":"lp","host":"v2b.chat-linia.site","port":8443}, …]   — порядок попыток;
///                  нет поля — для каждого адреса servers.hosts: ws → lp-h3 → lp;
///   "transportFailover": true      — включатель (false — только WebSocket и прежняя смена адресов);
///   "transportSwitchSeconds": 5    — не подключилось за столько секунд — следующий маршрут (2…30);
///   "transportStallSeconds": 30    — запрос без ответа столько секунд — канал «завис», следующий (0 — выкл.);
///   "transportRememberHours": 24   — удачный маршрут первым при следующих подключениях столько часов;
///   "transportReturnMinutes": 15   — раз в N минут проверять первый маршрут списка и вернуться на него (0 — выкл.).
final class Linia2Transports {
    static let shared = Linia2Transports()
    static let changedNotification = Notification.Name("Linia2TransportsChanged")
    private static let kLast = "linia2.transport.last"
    private static let kLastAt = "linia2.transport.lastAt"

    private let lock = NSLock()
    private var routesValue: [Linia2Route] = []
    private var baseValue: [Linia2Route] = []
    private var started = false
    private var timer: Timer?
    private var lastReturnCheck = Date()
    private var notAuthedSince: Date?
    private var loginStallCount = 0
    private var lastLoginStall = Date.distantPast
    private var probing = false

    /// Список для Connection (под замком — читается с очереди операций Tinode).
    func routes() -> [Linia2Route] { lock.lock(); defer { lock.unlock() }; return routesValue }
    private var baseRoutes: [Linia2Route] { lock.lock(); defer { lock.unlock() }; return baseValue }

    var enabled: Bool { Linia2Config.shared.feature("transportFailover", default: true) }
    /// Адреса перебирает список маршрутов (Linia2Failover адрес не меняет).
    var handlesHosts: Bool { routes().count > 1 }

    /// Запоминать удачный маршрут: в автотестах — только при L2_TEST_REMEMBER=1 (не переносить «lp» между тестами).
    private var rememberAllowed: Bool {
        !Linia2TestHook.enabled || ProcessInfo.processInfo.environment["L2_TEST_REMEMBER"] == "1"
    }

    func start() {
        guard !started else { return }
        started = true
        rebuild()
        Tinode.linia2RoutesProvider = { Linia2Transports.shared.routes() }
        Tinode.linia2RouteUp = { r, p in Linia2Transports.shared.routeUp(r, p) }
        Tinode.linia2RouteChanged = {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Linia2Transports.changedNotification, object: nil) }
        }
        NotificationCenter.default.addObserver(forName: Linia2Config.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
            DispatchQueue.global(qos: .utility).async { Cache.tinode.linia2RefreshRoutes() }
        }
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func clamp(_ v: Double?, _ def: Double, _ lo: Double, _ hi: Double) -> Double {
        guard let v = v else { return def }
        return min(hi, max(lo, v))
    }

    private var rememberHours: Double { clamp(Linia2Config.shared.number("features", "transportRememberHours"), 24, 0, 24 * 30) }
    private var returnMinutes: Double {
        let v = Linia2Config.shared.number("features", "transportReturnMinutes") ?? 15
        return v <= 0 ? 0 : min(24 * 60, max(2, v))
    }

    /// Пересобрать список из настроек и запомненного маршрута.
    func rebuild() {
        let cfg = Linia2Config.shared
        Connection.linia2SwitchTimeout = clamp(cfg.number("features", "transportSwitchSeconds"), 5, 2, 30)
        let stall = cfg.number("features", "transportStallSeconds") ?? 30
        Connection.linia2StallTimeout = stall <= 0 ? 0 : min(300, max(10, stall))
        var base: [Linia2Route] = []
        var list: [Linia2Route] = []
        if enabled {
            base = Linia2TransportPlan.parse(cfg.transportSpec, hosts: SharedUtils.linia2Hosts)
            let d = UserDefaults.standard
            let last = d.string(forKey: Self.kLast).flatMap { Linia2Route(id: $0) }
            let at = d.object(forKey: Self.kLastAt) as? Date
            list = Linia2TransportPlan.order(base, remembered: rememberAllowed ? last : nil, rememberedAt: at,
                                             maxAge: rememberHours * 3600)
        }
        lock.lock(); baseValue = base; routesValue = list; lock.unlock()
    }

    private func routeUp(_ r: Linia2Route, _ proto: String?) {
        if rememberAllowed {
            let d = UserDefaults.standard
            d.set(r.id, forKey: Self.kLast)
            d.set(Date(), forKey: Self.kLastAt)
        }
        if SharedUtils.linia2Hosts.contains(r.host), SharedUtils.linia2ActiveHost != r.host {
            SharedUtils.linia2ActiveHost = r.host
        }
        L2Log.event("l2_transport", ["route": r.id, "proto": proto ?? ""])
    }

    private func forgetRemembered() {
        UserDefaults.standard.removeObject(forKey: Self.kLast)
        UserDefaults.standard.removeObject(forKey: Self.kLastAt)
        rebuild()
    }

    private var inCall: Bool { CallManager.state.uuid != nil || CallManager.state.inConversation }

    private func tick() {
        guard routes().count > 1 else { return }
        let t = Cache.tinode
        let active = UIApplication.shared.applicationState == .active
        // Транспорт открыт, а вход не проходит дольше 15 с (канал пропускает мелкие пакеты и режет крупные) —
        // следующий маршрут. Не чаще раза в 30 с и не больше 3 раз подряд (вдруг дело не в канале).
        if t.myUid != nil, t.isConnected, !t.isConnectionAuthenticated {
            if notAuthedSince == nil { notAuthedSince = Date() }
            if active, let s = notAuthedSince, Date().timeIntervalSince(s) > 15, Date().timeIntervalSince(lastLoginStall) > 30,
               loginStallCount < 3 {
                lastLoginStall = Date()
                loginStallCount += 1
                notAuthedSince = nil
                L2Log.event("l2_transport_login_stall")
                DispatchQueue.global(qos: .userInitiated).async { t.linia2AbandonRoute(why: "login-stall") }
            }
        } else {
            notAuthedSince = nil
            if t.isConnectionAuthenticated { loginStallCount = 0 }
        }
        // На резервном маршруте — раз в N минут проверить первый маршрут списка (без входа) и вернуться на него.
        let every = returnMinutes
        guard every > 0, !probing, active, !inCall, t.isConnectionAuthenticated,
              Date().timeIntervalSince(lastReturnCheck) > every * 60,
              let first = baseRoutes.first, let cur = t.linia2RouteStatus, cur.connected, cur.route != first else { return }
        lastReturnCheck = Date()
        probing = true
        Linia2RouteProbe.probe(first, apiKey: SharedUtils.linia2ApiKey) { [weak self] ok, proto in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.probing = false
                L2Log.event("l2_transport_return_probe", ["route": first.id, "ok": ok ? 1 : 0, "proto": proto ?? ""])
                guard ok, !self.inCall, UIApplication.shared.applicationState == .active else { return }
                self.forgetRemembered()
                DispatchQueue.global(qos: .userInitiated).async { Cache.tinode.linia2ReturnToFirstRoute() }
            }
        }
    }

    /// Плашка при переходе: «Плохое соединение — подключаемся через резервный канал K из N…» (nil — обычный текст).
    var fallbackText: String? {
        guard routes().count > 1, let st = Cache.tinode.linia2RouteStatus, !st.connected, st.count > 1,
              st.index > 1 || st.failedInCycle > 0 else { return nil }
        let fmt = L2T("l2.net.fallback", "Плохое соединение — подключаемся через резервный канал %d из %d…")
        return String(format: fmt, st.index, st.count)
    }

    /// Строка диагностики: «lp-h3 · v2.chat-linia.site · h3 · 2/6».
    var statusLine: String {
        guard let st = Cache.tinode.linia2RouteStatus else { return "—" }
        var s = "\(st.route.kind.rawValue) · \(st.route.host)" + (st.route.port.map { ":\($0)" } ?? "")
        s += " · " + (st.netProtocol ?? "?")
        if st.count > 1 { s += " · \(st.index)/\(st.count)" }
        if !st.connected { s += " · подключение" }
        return s
    }

    /// Для тестового крючка: 0 — ws, 1 — lp-h3, 2 — lp, −1 — не подключены.
    var testCode: Int {
        guard let st = Cache.tinode.linia2RouteStatus, st.connected, Cache.tinode.isConnectionAuthenticated else { return -1 }
        switch st.route.kind { case .ws: return 0; case .lpH3: return 1; case .lp: return 2 }
    }

    /// Файлы (загрузка/скачивание) — тоже по HTTP/3, если канал идёт через lp-h3.
    var preferHTTP3: Bool { Cache.tinode.linia2RouteStatus?.route.kind == .lpH3 }
}
