//
//  Linia2RemoteConfig.swift
//  Линия 2.0: удалённые настройки (https://v2.chat-linia.site/app-config.json) — без исполняемого кода.
//  Загрузка при запуске и раз в 15 минут; кэш последнего валидного конфига; встроенные значения по умолчанию.
//  Ошибка или недоступность конфига не влияет на работу приложения.
//

import UIKit
import WebKit
import ObjectiveC

final class Linia2Config {
    static let shared = Linia2Config()
    static let changedNotification = Notification.Name("Linia2ConfigChanged")

    private let url = "https://v2.chat-linia.site/app-config.json"
    private let queue = DispatchQueue(label: "info.codix.liniya2.config")
    private var data: [String: Any] = [:]
    private var lastFetch = Date.distantPast
    private var timer: Timer?

    private var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("linia2-app-config.json")
    }

    private init() {
        if let u = cacheURL, let d = try? Data(contentsOf: u), let obj = Self.validate(d) {
            data = obj
        }
    }

    // MARK: загрузка

    func start() {
        Self.installTextOverrides()
        fetch()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.fetch() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, Date().timeIntervalSince(self.lastFetch) > 15 * 60 else { return }
            self.fetch()
        }
        DispatchQueue.main.async { Linia2UpdateGate.checkAndShow() }
    }

    func fetch() {
        lastFetch = Date()
        guard let u = URL(string: url + "?t=\(Int(Date().timeIntervalSince1970))") else { return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { [weak self] d, resp, _ in
            guard let self = self, let d = d, (resp as? HTTPURLResponse)?.statusCode == 200, let obj = Self.validate(d) else { return }
            self.queue.async {
                let changed = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) !=
                    (try? JSONSerialization.data(withJSONObject: self.data, options: [.sortedKeys]))
                guard changed else { return }
                self.data = obj
                if let cu = self.cacheURL {
                    try? FileManager.default.createDirectory(at: cu.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? d.write(to: cu, options: .atomic)
                }
                DispatchQueue.main.async {
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
        queue.sync { (data[name] as? [String: Any]) ?? [:] }
    }

    // MARK: значения

    /// Цвет #RRGGBB из раздела colors.
    func color(_ key: String) -> UInt32? {
        guard let s = section("colors")[key] as? String else { return nil }
        let hex = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return v
    }

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

    func image(_ key: String) -> URL? {
        guard let s = section("images")[key] as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" else { return nil }
        return u
    }

    /// Встроенная функция включена? По умолчанию — да.
    func feature(_ name: String) -> Bool {
        (section("features")[name] as? Bool) ?? true
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
        queue.sync { (data["bannedWords"] as? [String]) ?? [] }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
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
        guard !swizzled,
              let m1 = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
              let m2 = class_getInstanceMethod(Bundle.self, #selector(Bundle.l2_localizedString(forKey:value:table:))) else { return }
        method_exchangeImplementations(m1, m2)
        swizzled = true
    }
}

extension Bundle {
    @objc func l2_localizedString(forKey key: String, value: String?, table: String?) -> String {
        if self === Bundle.main, let t = Linia2Config.shared.text(key) { return t }
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
