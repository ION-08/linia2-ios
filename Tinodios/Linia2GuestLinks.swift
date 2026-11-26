//
//  Linia2GuestLinks.swift
//  Линия 2.0: гостевые ссылки на звонок (CONTRACTS.md «Гостевые ссылки на звонок», сервис linia2-guestcall).
//  Владелец создаёт ссылку https://v2.chat-linia.site/call/<token>; гость звонит из браузера без аккаунта.
//  Здесь: API владельца, «Создать ссылку на звонок», «Мои ссылки», карточка ссылки (QR, копировать, поделиться,
//  деактивировать, удалить, история), имя гостя для входящего звонка и истории. Флаг features.guestCalls.
//

import CoreImage
import TinodiosDB
import TinodeSDK
import UIKit

// MARK: - Модель и API

struct Linia2GuestLink {
    struct Call {
        let name: String
        let ts: Date?
        let duration: Int
        let result: String

        var resultText: String {
            switch result {
            case "accepted": return "принят"
            case "declined": return "отклонён"
            case "missed": return "пропущен"
            case "cancelled": return "гость сбросил"
            case "busy": return "занято"
            case "failed": return "ошибка связи"
            default: return result
            }
        }
    }

    let id: String
    let token: String
    let url: String
    let title: String
    let mode: String
    let ttl: String
    let once: Bool
    let expires: Date?
    let state: String
    let calls: Int
    let history: [Call]

    var active: Bool { state == "active" }

    var stateText: String {
        switch state {
        case "active": return "Действует"
        case "expired": return "Срок истёк"
        case "disabled": return "Отключена"
        case "used": return "Использована"
        default: return state
        }
    }

    var expiresText: String {
        guard let e = expires else { return "Бессрочно" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return "до " + f.string(from: e)
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    init?(_ d: [String: Any]?) {
        guard let d = d, let id = d["id"] as? String, let url = d["url"] as? String else { return nil }
        self.id = id
        token = d["token"] as? String ?? ""
        self.url = url
        title = d["title"] as? String ?? "Ссылка"
        mode = d["mode"] as? String ?? "audio"
        ttl = d["ttl"] as? String ?? ""
        once = d["once"] as? Bool ?? false
        expires = Self.date(d["expires"])
        state = d["state"] as? String ?? ((d["active"] as? Bool) == true ? "active" : "disabled")
        calls = (d["calls"] as? NSNumber)?.intValue ?? 0
        history = ((d["history"] as? [[String: Any]]) ?? []).map {
            Call(name: $0["name"] as? String ?? "Гость", ts: Self.date($0["ts"]),
                 duration: ($0["duration"] as? NSNumber)?.intValue ?? 0, result: $0["result"] as? String ?? "")
        }
    }
}

enum Linia2GuestLinks {
    static var enabled: Bool { Linia2Config.shared.feature("guestCalls") }
    static var base: String { "https://\(SharedUtils.kLinia2Host)/call/api/" }

    private static let kGuestUid = "linia2.guestcall.uid"
    private static let kInfo = "linia2.guestcall.info"   // [seq: [name, link]]

    /// uid системного пользователя «Гость по ссылке» (из GET /call/api/links).
    static var guestUid: String? {
        get { UserDefaults.standard.string(forKey: kGuestUid) }
        set { UserDefaults.standard.set(newValue, forKey: kGuestUid) }
    }

    static func isGuest(_ uidOrTopic: String?) -> Bool {
        guard let u = uidOrTopic, !u.isEmpty, let g = guestUid else { return false }
        return u == g
    }

    /// Запрос к API владельца. Колбэк на главном потоке.
    static func request(_ method: String, _ path: String, _ body: [String: Any]? = nil,
                        completion: @escaping (_ status: Int, _ json: [String: Any]?) -> Void) {
        guard let url = URL(string: base + path) else { completion(0, nil); return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = method
        if let token = Cache.tinode.authToken { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { completion(status, json) }
        }.resume()
    }

    static func errorText(_ status: Int, _ json: [String: Any]?) -> String {
        if let e = json?["error"] as? String, !e.isEmpty { return e }
        if status == 0 { return Linia2API.networkError }
        if status == 403 { return "Звонки по ссылке временно отключены" }
        return "Не удалось выполнить запрос (\(status))"
    }

    static func list(completion: @escaping ([Linia2GuestLink]?, String?) -> Void) {
        request("GET", "links") { status, json in
            guard status == 200, (json?["ok"] as? Bool) == true else { completion(nil, errorText(status, json)); return }
            if let g = json?["guestUid"] as? String, !g.isEmpty { guestUid = g }
            completion(((json?["links"] as? [[String: Any]]) ?? []).compactMap { Linia2GuestLink($0) }, nil)
        }
    }

    /// Обновить uid «Гостя по ссылке» (для входящих и истории) — тихо, при входе.
    static func refreshGuestUid() {
        guard enabled, Cache.tinode.authToken != nil else { return }
        list { _, _ in }
    }

    // MARK: Кто звонит в гостевом звонке

    static func cachedInfo(seq: Int) -> (name: String, link: String)? {
        guard let d = UserDefaults.standard.dictionary(forKey: kInfo)?[String(seq)] as? [String] , d.count == 2 else { return nil }
        return (d[0], d[1])
    }

    static func remember(seq: Int, name: String, link: String) {
        var d = UserDefaults.standard.dictionary(forKey: kInfo) ?? [:]
        d[String(seq)] = [name, link]
        if d.count > 300, let k = d.keys.compactMap({ Int($0) }).min() { d.removeValue(forKey: String(k)) }
        UserDefaults.standard.set(d, forKey: kInfo)
    }

    /// Из head исходного сообщения звонка (поле "linia2-guest").
    static func info(fromHead head: [String: JSONValue]?, seq: Int) -> (name: String, link: String)? {
        guard let g = head?["linia2-guest"]?.asDict(), let name = g["name"]?.asString() else { return cachedInfo(seq: seq) }
        let link = g["link"]?.asString() ?? ""
        remember(seq: seq, name: name, link: link)
        return (name, link)
    }

    static func callInfo(seq: Int, completion: @escaping ((name: String, link: String)?) -> Void) {
        if let c = cachedInfo(seq: seq) { completion(c); return }
        request("GET", "call-info?seq=\(seq)") { status, json in
            guard status == 200, let g = json?["guest"] as? [String: Any], let name = g["name"] as? String else { completion(nil); return }
            let link = g["link"] as? String ?? ""
            remember(seq: seq, name: name, link: link)
            completion((name, link))
        }
    }

    /// «<имя> (по ссылке «<название>»)» — для CallKit.
    static func callKitName(_ i: (name: String, link: String)) -> String {
        i.link.isEmpty ? "\(i.name) (по ссылке)" : "\(i.name) (по ссылке «\(i.link)»)"
    }

    /// «<имя> звонит по ссылке «<название>»» — для экрана входящего.
    static func incomingText(_ i: (name: String, link: String)) -> String {
        i.link.isEmpty ? "\(i.name) звонит по ссылке" : "\(i.name) звонит по ссылке «\(i.link)»"
    }

    // MARK: QR

    static func qr(_ text: String, size: CGFloat = 220) -> UIImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = f.outputImage else { return nil }
        let scale = size / img.extent.width
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Открытие ссылки в приложении (liniya2://call/<token>, https://…/call/<token>)

    static func token(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "liniya2" {
            // liniya2://call/<token>: host = call, path = /<token>
            if url.host == "call", let t = parts.first { return t }
            if parts.count >= 2, parts[0] == "call" { return parts[1] }
            return nil
        }
        if parts.count >= 2, parts[0] == "call" { return parts[1] }
        return nil
    }

    static func open(token: String) {
        guard enabled else { return }
        list { links, _ in
            if let link = links?.first(where: { $0.token == token }) {
                Linia2GuestLinks.show(Linia2GuestLinkDetailViewController(link: link))
                return
            }
            // Чужая ссылка — карточка и «Открыть в браузере».
            URLSession.shared.dataTask(with: URL(string: base + "guest/" + token)!) { data, _, _ in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async {
                    let ok = (json?["ok"] as? Bool) == true
                    let title = ok ? (json?["title"] as? String ?? "Звонок по ссылке") : "Ссылка на звонок"
                    let owner = json?["owner"] as? String ?? ""
                    let msg = ok ? "Это ссылка для звонка \(owner.isEmpty ? "" : "пользователю «\(owner)» ")из браузера. Вы можете позвонить ему обычным звонком в приложении."
                                 : ((json?["error"] as? String) ?? "Ссылка больше не действует")
                    let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
                    if ok, let u = URL(string: "https://\(SharedUtils.kLinia2Host)/call/\(token)") {
                        a.addAction(UIAlertAction(title: "Открыть в браузере", style: .default) { _ in UIApplication.shared.open(u) })
                    }
                    a.addAction(UIAlertAction(title: "Закрыть", style: .cancel))
                    topController()?.present(a, animated: true)
                }
            }.resume()
        }
    }

    static func topController() -> UIViewController? {
        var top = Linia2Root.window?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }

    /// Показать экран в навигаторе вкладки «Звонки» (или модально).
    static func show(_ vc: UIViewController) {
        if let tc = Linia2TabBarController.current {
            tc.selectTab(.calls)
            if let nav = tc.selectedViewController as? UINavigationController {
                nav.pushViewController(vc, animated: true)
                return
            }
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.overrideUserInterfaceStyle = .dark
        topController()?.present(nav, animated: true)
    }

    static func share(_ link: Linia2GuestLink, from vc: UIViewController, source: UIView) {
        let text = "Позвоните мне в «Линия 2.0» — без регистрации, прямо из браузера: \(link.url)"
        let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = source
        share.popoverPresentationController?.sourceRect = source.bounds
        vc.present(share, animated: true)
    }

    static func copy(_ link: Linia2GuestLink) {
        UIPasteboard.general.string = link.url
        UiUtils.showToast(message: "Ссылка скопирована", level: .info)
    }
}

// MARK: - Базовый экран (тёмный, со скроллом)

class Linia2GuestBaseViewController: UIViewController {
    let scroll = UIScrollView()
    let stack = UIStackView()
    /// Отступ снизу под плавающее меню вкладок (в нижнем листе — меньше).
    var bottomReserve: CGFloat { Linia2TabBarController.reservedBottom + 24 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        navigationItem.largeTitleDisplayMode = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -bottomReserve),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = L2.font(13, .semibold)
        l.textColor = L2.textSecondary
        return l
    }

    func segmented(_ items: [String], selected: Int, id: String) -> UISegmentedControl {
        let s = UISegmentedControl(items: items)
        s.selectedSegmentIndex = selected
        s.selectedSegmentTintColor = L2.accent
        s.setTitleTextAttributes([.foregroundColor: L2.onAccent, .font: L2.font(14, .semibold)], for: .selected)
        s.setTitleTextAttributes([.foregroundColor: L2.textPrimary, .font: L2.font(14)], for: .normal)
        s.backgroundColor = L2.surface
        s.accessibilityIdentifier = id
        s.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return s
    }
}

// MARK: - «Ссылка на звонок» (нижний лист)

final class Linia2GuestLinkCreateViewController: Linia2GuestBaseViewController, UITextFieldDelegate {
    static let mint = L2.hex(0x7EE0C3)
    private let titleField = L2TextField(placeholder: "Название (необязательно)")
    private lazy var modeControl = segmented(Linia2Config.shared.feature("videoCalls") ? ["Аудио", "Видео"] : ["Аудио"], selected: 0, id: "l2.guestlink.mode")
    private lazy var ttlControl = segmented(["1 ч", "24 ч", "7 дней", "Бессрочно"], selected: 1, id: "l2.guestlink.ttl")
    private let onceSwitch = UISwitch()
    private let createButton = L2Button("Создать", kind: .primary, symbol: "link")
    private let form = UIStackView()
    private let result = UIStackView()
    private static let ttls = ["1h", "24h", "7d", "never"]
    private var link: Linia2GuestLink?

    /// Открыть нижним листом (.medium / .large) поверх `from`.
    static func presentSheet(from vc: UIViewController) {
        let nav = UINavigationController(rootViewController: Linia2GuestLinkCreateViewController())
        nav.overrideUserInterfaceStyle = Linia2Appearance.interfaceStyle
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        vc.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Ссылка на звонок"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Готово", style: .done, target: self, action: #selector(close))
        stack.spacing = 12
        titleField.accessibilityIdentifier = "l2.guestlink.title"
        titleField.delegate = self
        titleField.returnKeyType = .done
        titleField.autocapitalizationType = .sentences
        createButton.accessibilityIdentifier = "l2.guestlink.create"
        createButton.addTarget(self, action: #selector(create), for: .touchUpInside)
        onceSwitch.onTintColor = L2.accentStrong
        onceSwitch.accessibilityIdentifier = "l2.guestlink.once"
        let onceLabel = UILabel()
        onceLabel.text = "Одноразовая (гаснет после звонка)"
        onceLabel.font = L2.font(15)
        onceLabel.textColor = L2.textPrimary
        onceLabel.numberOfLines = 0
        let onceRow = UIStackView(arrangedSubviews: [onceLabel, onceSwitch])
        onceRow.alignment = .center
        onceRow.spacing = 12

        form.axis = .vertical
        form.spacing = 12
        for v in [titleField, modeControl, caption("Срок действия"), ttlControl, onceRow, createButton] as [UIView] {
            form.addArrangedSubview(v)
        }
        form.setCustomSpacing(4, after: form.arrangedSubviews[2])
        result.axis = .vertical
        result.spacing = 12
        result.isHidden = true
        stack.addArrangedSubview(form)
        stack.addArrangedSubview(result)
        stack.addArrangedSubview(hint())
        stack.addArrangedSubview(textButton("Мои ссылки", id: "l2.calls.myLinks", action: #selector(myLinks)))
        if Linia2Config.shared.feature("createLink") {
            // Прежняя «Создать ссылку» (на профиль) — здесь, функция сохранена.
            stack.addArrangedSubview(textButton("Поделиться ссылкой на профиль", id: "l2.calls.profileLink", action: #selector(profileLink(_:))))
        }
    }

    // В нижнем листе меню вкладок не мешает — отступ снизу небольшой.
    override var bottomReserve: CGFloat { 24 }

    private func hint() -> UILabel {
        let l = UILabel()
        l.text = "Гость сможет позвонить вам из браузера без регистрации."
        l.font = L2.font(13)
        l.textColor = L2.textSecondary
        l.numberOfLines = 0
        l.textAlignment = .center
        return l
    }

    private func textButton(_ title: String, id: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = L2.font(16, .semibold)
        b.titleLabel?.numberOfLines = 0
        b.titleLabel?.textAlignment = .center
        b.setTitleColor(Self.mint, for: .normal)
        b.accessibilityIdentifier = id
        b.addTarget(self, action: action, for: .touchUpInside)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func myLinks() {
        navigationController?.pushViewController(Linia2GuestLinksViewController(), animated: true)
    }

    @objc private func profileLink(_ sender: UIView) {
        guard let uid = Cache.tinode.myUid, !uid.isEmpty else { return }
        let text = "Напишите или позвоните мне в «Линия 2.0»: https://\(SharedUtils.kLinia2Host)/#/\(uid)"
        let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = sender
        share.popoverPresentationController?.sourceRect = sender.bounds
        present(share, animated: true)
    }

    @objc private func create() {
        var t = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let video = modeControl.selectedSegmentIndex == 1
        if t.isEmpty { t = video ? "Видеозвонок" : "Звонок" }
        view.endEditing(true)
        createButton.isEnabled = false
        let body: [String: Any] = [
            "title": String(t.prefix(60)),
            "mode": video ? "video" : "audio",
            "ttl": Self.ttls[max(0, min(3, ttlControl.selectedSegmentIndex))],
            "once": onceSwitch.isOn,
        ]
        Linia2GuestLinks.request("POST", "links", body) { [weak self] status, json in
            guard let self = self else { return }
            self.createButton.isEnabled = true
            guard status == 200, let link = Linia2GuestLink(json?["link"] as? [String: Any]) else {
                UiUtils.showToast(message: Linia2GuestLinks.errorText(status, json))
                return
            }
            L2.haptic()
            self.show(link)
        }
    }

    /// Готовая ссылка: поле со ссылкой, «Скопировать», «Поделиться», QR.
    private func show(_ link: Linia2GuestLink) {
        self.link = link
        form.isHidden = true
        result.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let name = UILabel()
        name.text = "\(link.title) · \(link.mode == "video" ? "видео" : "аудио") · \(link.expiresText)"
        name.font = L2.font(15, .semibold)
        name.textColor = L2.textSecondary
        name.numberOfLines = 0
        name.textAlignment = .center
        let url = UITextField()
        url.text = link.url
        url.font = L2.font(14, .medium)
        url.textColor = L2.textPrimary
        url.backgroundColor = L2.surface
        url.layer.cornerRadius = 12
        url.adjustsFontSizeToFitWidth = true
        url.minimumFontSize = 10
        url.textAlignment = .center
        url.accessibilityIdentifier = "l2.guestlink.url"
        url.accessibilityValue = link.url
        url.delegate = self
        url.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let copy = L2Button("Скопировать", kind: .primary, symbol: "doc.on.doc")
        copy.accessibilityIdentifier = "l2.guestlink.copy"
        copy.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        let share = L2Button("Поделиться", kind: .secondary, symbol: "square.and.arrow.up")
        share.accessibilityIdentifier = "l2.guestlink.share"
        share.addTarget(self, action: #selector(shareTapped(_:)), for: .touchUpInside)
        for b in [copy, share] {
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.7
        }
        let row = UIStackView(arrangedSubviews: [copy, share])
        row.spacing = 12
        row.distribution = .fillEqually
        let qr = UIImageView(image: Linia2GuestLinks.qr(link.url, size: 400))
        qr.contentMode = .scaleAspectFit
        qr.backgroundColor = .white
        qr.layer.cornerRadius = 14
        qr.clipsToBounds = true
        qr.accessibilityIdentifier = "l2.guestlink.qr"
        qr.accessibilityLabel = "QR-код ссылки"
        qr.translatesAutoresizingMaskIntoConstraints = false
        let qrBox = UIView()
        qrBox.addSubview(qr)
        NSLayoutConstraint.activate([
            qr.widthAnchor.constraint(equalToConstant: 180), qr.heightAnchor.constraint(equalToConstant: 180),
            qr.centerXAnchor.constraint(equalTo: qrBox.centerXAnchor),
            qr.topAnchor.constraint(equalTo: qrBox.topAnchor), qr.bottomAnchor.constraint(equalTo: qrBox.bottomAnchor),
        ])
        let another = textButton("Создать ещё одну", id: "l2.guestlink.another", action: #selector(another))
        for v in [name, url, row, qrBox, another] as [UIView] { result.addArrangedSubview(v) }
        result.isHidden = false
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        // Поле со ссылкой — только для чтения (копирование — кнопкой).
        textField === titleField
    }

    @objc private func another() {
        result.isHidden = true
        form.isHidden = false
        titleField.text = nil
    }

    @objc private func copyTapped() {
        guard let l = link else { return }
        L2.haptic()
        Linia2GuestLinks.copy(l)
    }

    @objc private func shareTapped(_ sender: UIView) {
        guard let l = link else { return }
        Linia2GuestLinks.share(l, from: self, source: sender)
    }
}

// MARK: - Карточка ссылки

final class Linia2GuestLinkDetailViewController: Linia2GuestBaseViewController {
    private var link: Linia2GuestLink
    private let content = UIStackView()

    init(link: Linia2GuestLink) {
        self.link = link
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Ссылка на звонок"
        content.axis = .vertical
        content.spacing = 14
        stack.addArrangedSubview(content)
        render()
        refresh()
    }

    private func refresh() {
        Linia2GuestLinks.request("GET", "links/\(link.id)") { [weak self] status, json in
            guard let self = self, status == 200, let l = Linia2GuestLink(json?["link"] as? [String: Any]) else { return }
            self.link = l
            self.render()
        }
    }

    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let name = UILabel()
        name.text = link.title
        name.font = L2.font(24, .bold)
        name.textColor = L2.textPrimary
        name.numberOfLines = 0
        let meta = UILabel()
        meta.text = "\(link.mode == "video" ? "Видео" : "Аудио") · \(link.once ? "одноразовая" : "многоразовая") · \(link.stateText) · \(link.expiresText)"
        meta.font = L2.font(14)
        meta.textColor = link.active ? L2.accent : L2.danger
        meta.numberOfLines = 0
        meta.accessibilityIdentifier = "l2.guestlink.state"

        let qrView = UIImageView(image: Linia2GuestLinks.qr(link.url, size: 440))
        qrView.contentMode = .scaleAspectFit
        qrView.layer.magnificationFilter = .nearest
        qrView.backgroundColor = .white
        qrView.layer.cornerRadius = 16
        qrView.clipsToBounds = true
        qrView.accessibilityLabel = "QR-код ссылки"
        qrView.accessibilityIdentifier = "l2.guestlink.qr"
        let qrBox = UIView()
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrBox.addSubview(qrView)
        NSLayoutConstraint.activate([
            qrView.widthAnchor.constraint(equalToConstant: 220),
            qrView.heightAnchor.constraint(equalToConstant: 220),
            qrView.centerXAnchor.constraint(equalTo: qrBox.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: qrBox.topAnchor),
            qrView.bottomAnchor.constraint(equalTo: qrBox.bottomAnchor),
        ])
        qrBox.alpha = link.active ? 1 : 0.35

        let url = UILabel()
        url.text = link.url
        url.font = L2.font(14, .medium)
        url.textColor = L2.textPrimary
        url.numberOfLines = 0
        url.textAlignment = .center
        url.backgroundColor = L2.surface
        url.layer.cornerRadius = 12
        url.clipsToBounds = true
        url.accessibilityIdentifier = "l2.guestlink.url"
        url.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        let copy = L2Button("Скопировать", kind: .primary, symbol: "doc.on.doc")
        copy.accessibilityIdentifier = "l2.guestlink.copy"
        copy.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        let share = L2Button("Поделиться", kind: .secondary, symbol: "square.and.arrow.up")
        share.accessibilityIdentifier = "l2.guestlink.share"
        share.addTarget(self, action: #selector(shareTapped(_:)), for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [copy, share])
        row.spacing = 12
        row.distribution = .fillEqually

        for v in [name, meta, qrBox, url, row] as [UIView] { content.addArrangedSubview(v) }

        if link.active {
            let deact = L2Button("Деактивировать", kind: .outline, symbol: "pause.circle")
            deact.accessibilityIdentifier = "l2.guestlink.deactivate"
            deact.addTarget(self, action: #selector(deactivateTapped), for: .touchUpInside)
            content.addArrangedSubview(deact)
        }
        let del = L2Button("Удалить", kind: .destructive, symbol: "trash")
        del.accessibilityIdentifier = "l2.guestlink.delete"
        del.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        content.addArrangedSubview(del)

        // История звонков по ссылке.
        let hist = UIStackView()
        hist.axis = .vertical
        hist.spacing = 0
        hist.backgroundColor = L2.surface
        hist.layer.cornerRadius = L2.radius
        hist.clipsToBounds = true
        hist.isAccessibilityElement = false
        hist.accessibilityIdentifier = "l2.guestlink.history"
        let head = caption("ЗВОНКИ ПО ССЫЛКЕ · \(link.calls)")
        content.setCustomSpacing(26, after: del)
        content.addArrangedSubview(head)
        if link.history.isEmpty {
            let empty = UILabel()
            empty.text = "Пока никто не звонил"
            empty.font = L2.font(15)
            empty.textColor = L2.textSecondary
            empty.textAlignment = .center
            empty.heightAnchor.constraint(equalToConstant: 56).isActive = true
            hist.addArrangedSubview(empty)
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateFormat = "d MMM, HH:mm"
            for c in link.history {
                let r = UILabel()
                r.numberOfLines = 2
                let when = c.ts.map { f.string(from: $0) } ?? ""
                let dur = c.duration > 0 ? " · " + String(format: "%d:%02d", c.duration / 60, c.duration % 60) : ""
                let t = NSMutableAttributedString(string: c.name + "\n", attributes: [.font: L2.font(16, .semibold), .foregroundColor: L2.textPrimary])
                t.append(NSAttributedString(string: "\(when) · \(c.resultText)\(dur)",
                                            attributes: [.font: L2.font(13), .foregroundColor: c.result == "accepted" ? L2.textSecondary : L2.danger]))
                r.attributedText = t
                let cell = UIView()
                r.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(r)
                NSLayoutConstraint.activate([
                    r.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                    r.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                    r.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
                    r.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -10),
                ])
                cell.isAccessibilityElement = true
                cell.accessibilityLabel = "\(c.name), \(when), \(c.resultText)\(dur)"
                hist.addArrangedSubview(cell)
            }
        }
        content.addArrangedSubview(hist)
    }

    @objc private func copyTapped() {
        L2.haptic()
        Linia2GuestLinks.copy(link)
    }

    @objc private func shareTapped(_ sender: UIView) {
        Linia2GuestLinks.share(link, from: self, source: sender)
    }

    @objc private func deactivateTapped() {
        let a = UIAlertController(title: "Деактивировать ссылку?", message: "По ней больше нельзя будет позвонить. Включить её снова нельзя.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        a.addAction(UIAlertAction(title: "Деактивировать", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            Linia2GuestLinks.request("POST", "links/\(self.link.id)/deactivate") { status, json in
                if status == 200, let l = Linia2GuestLink(json?["link"] as? [String: Any]) {
                    self.link = l
                    self.render()
                    UiUtils.showToast(message: "Ссылка деактивирована", level: .info)
                } else {
                    UiUtils.showToast(message: Linia2GuestLinks.errorText(status, json))
                }
            }
        })
        present(a, animated: true)
    }

    @objc private func deleteTapped() {
        let a = UIAlertController(title: "Удалить ссылку?", message: "Ссылка и история звонков по ней пропадут.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        a.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            Linia2GuestLinks.request("POST", "links/\(self.link.id)/delete") { status, json in
                if status == 200 {
                    UiUtils.showToast(message: "Ссылка удалена", level: .info)
                    self.navigationController?.popViewController(animated: true)
                } else {
                    UiUtils.showToast(message: Linia2GuestLinks.errorText(status, json))
                }
            }
        })
        present(a, animated: true)
    }
}

// MARK: - «Мои ссылки»

final class Linia2GuestLinksViewController: UITableViewController {
    private var links: [Linia2GuestLink] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Мои ссылки"
        view.backgroundColor = L2.background
        tableView.backgroundColor = L2.background
        tableView.separatorColor = L2.separator
        tableView.accessibilityIdentifier = "l2.guestlinks.list"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        tableView.contentInset.bottom = Linia2TabBarController.reservedBottom
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: self, action: #selector(add))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Создать ссылку на звонок"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(load), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        load()
    }

    @objc private func add() {
        navigationController?.pushViewController(Linia2GuestLinkCreateViewController(), animated: true)
    }

    @objc private func load() {
        Linia2GuestLinks.list { [weak self] links, err in
            guard let self = self else { return }
            self.refreshControl?.endRefreshing()
            if let links = links {
                self.links = links
            } else if let err = err {
                UiUtils.showToast(message: err)
            }
            self.tableView.backgroundView = self.links.isEmpty
                ? l2EmptyState("Ссылок пока нет", "Создайте ссылку — по ней вам смогут позвонить без регистрации", symbol: "link")
                : nil
            self.tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { links.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let l = links[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = L2.surface
        cell.textLabel?.text = l.title
        cell.textLabel?.font = L2.font(17, .semibold)
        cell.textLabel?.textColor = l.active ? L2.textPrimary : L2.textSecondary
        let calls = l.calls == 0 ? "звонков нет" : "звонков: \(l.calls)"
        cell.detailTextLabel?.text = "\(l.stateText) · \(l.expiresText) · \(calls)"
        cell.detailTextLabel?.font = L2.font(13)
        cell.detailTextLabel?.textColor = l.active ? L2.textSecondary : L2.danger
        cell.imageView?.image = L2.symbol(l.mode == "video" ? "video.fill" : "phone.fill", 17, .semibold)
        cell.imageView?.tintColor = l.active ? L2.accent : L2.textSecondary
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "l2.guestlink.row"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(Linia2GuestLinkDetailViewController(link: links[indexPath.row]), animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let l = links[indexPath.row]
        let copy = UIContextualAction(style: .normal, title: "Скопировать") { _, _, done in
            Linia2GuestLinks.copy(l)
            done(true)
        }
        copy.backgroundColor = L2.hex(0x5B8DEF)
        let del = UIContextualAction(style: .destructive, title: "Удалить") { [weak self] _, _, done in
            Linia2GuestLinks.request("POST", "links/\(l.id)/delete") { status, json in
                if status != 200 { UiUtils.showToast(message: Linia2GuestLinks.errorText(status, json)) }
                self?.load()
                done(status == 200)
            }
        }
        var actions = [del, copy]
        if l.active {
            let deact = UIContextualAction(style: .normal, title: "Отключить") { [weak self] _, _, done in
                Linia2GuestLinks.request("POST", "links/\(l.id)/deactivate") { status, json in
                    if status != 200 { UiUtils.showToast(message: Linia2GuestLinks.errorText(status, json)) }
                    self?.load()
                    done(status == 200)
                }
            }
            deact.backgroundColor = L2.hex(0xE0A14A)
            actions.insert(deact, at: 1)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }
}
