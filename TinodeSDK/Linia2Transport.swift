//
//  Linia2Transport.swift
//  TinodeSDK
//
//  LINIA2 (сборка 1019): несколько транспортов канала Tinode с автоматическим переключением.
//  Из России ТСПУ режет TCP до зарубежного сервера после первых пакетов, а UDP/QUIC (HTTP/3) проходит.
//    ws    — WebSocket wss://host/v0/channels (как было; по умолчанию первым);
//    lp-h3 — long-polling Tinode https://host/v0/channels/lp через URLSession с assumesHTTP3Capable (QUIC сразу);
//    lp    — тот же long-polling поверх HTTP/2 / HTTP/1.1.
//  Маршрут = транспорт + адрес (+ порт). Порядок и параметры — из app-config (features.transports, см. приложение),
//  без списка — встроенный: для каждого адреса ws → lp-h3 → lp.
//

import Foundation

// MARK: - Транспорт

/// Транспорт канала Tinode: подключение, отправка, закрытие; события — через WebSocketConnectionDelegate.
protocol Linia2Transport: AnyObject {
    var state: WebSocket.State { get }
    /// Момент начала текущего подключения (для «не перебивать идущее подключение»).
    var connectingSince: Date? { get }
    /// Сетевой протокол последнего запроса: «ws», «h3», «h2», «http/1.1» (URLSessionTaskMetrics).
    var linia2NetProtocol: String? { get }
    func connect(url: URL, apiKey: String)
    /// byUs = true — закрыли мы (не обрыв): onDisconnected с Tinode.linia2ClientCancelReason.
    func close(byUs: Bool)
    func send(data: Data)
    func linia2Ping(timeout: TimeInterval, done: @escaping (Bool) -> Void)
}

public enum Linia2TransportKind: String, CaseIterable {
    case ws = "ws"
    case lpH3 = "lp-h3"
    case lp = "lp"

    /// Тип из конфига (допускаются синонимы).
    public init?(config: String) {
        switch config.lowercased().trimmingCharacters(in: .whitespaces) {
        case "ws", "wss", "websocket": self = .ws
        case "lp-h3", "lph3", "h3", "http3", "quic": self = .lpH3
        case "lp", "longpoll", "long-polling", "http", "https": self = .lp
        default: return nil
        }
    }
}

/// Маршрут подключения: транспорт + адрес (+ нестандартный порт).
public struct Linia2Route: Equatable, Hashable, CustomStringConvertible {
    public let kind: Linia2TransportKind
    public let host: String
    public let port: Int?

    public init(kind: Linia2TransportKind, host: String, port: Int? = nil) {
        self.kind = kind
        self.host = host.lowercased()
        self.port = (port == 443) ? nil : port
    }

    /// «lp-h3://v2.chat-linia.site» / «ws://v2b.chat-linia.site:8443» — для запоминания и диагностики.
    public var id: String { "\(kind.rawValue)://\(host)" + (port.map { ":\($0)" } ?? "") }
    public var description: String { id }

    public init?(id: String) {
        guard let r = id.range(of: "://"), let kind = Linia2TransportKind(rawValue: String(id[..<r.lowerBound])) else { return nil }
        let rest = String(id[r.upperBound...])
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, Linia2TransportPlan.isValidHost(String(parts[0])) else { return nil }
        var port: Int?
        if parts.count == 2 {
            guard let p = Int(parts[1]), (1...65535).contains(p) else { return nil }
            port = p
        }
        self.init(kind: kind, host: String(parts[0]), port: port)
    }

    /// Адрес канала: wss://host[:port]/v0/channels или https://host[:port]/v0/channels/lp.
    public func url(path: String = "/v0/channels") -> URL? {
        var c = URLComponents()
        c.scheme = kind == .ws ? "wss" : "https"
        c.host = host
        c.port = port ?? 443
        c.path = kind == .ws ? path : (path.hasSuffix("/") ? path + "lp" : path + "/lp")
        return c.url
    }
}

// MARK: - Порядок маршрутов (чистая логика, юнит-тесты в Linia2SDKTests)

public enum Linia2TransportPlan {
    public static let defaultKinds: [Linia2TransportKind] = [.ws, .lpH3, .lp]
    public static let maxRoutes = 24

    public static func isValidHost(_ h: String) -> Bool {
        h.count < 100 && h.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$",
                                 options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Встроенный порядок: для каждого адреса (по приоритету) ws → lp-h3 → lp.
    public static func defaultRoutes(hosts: [String]) -> [Linia2Route] {
        var seen = Set<Linia2Route>()
        return hosts.filter(isValidHost).flatMap { h in defaultKinds.map { Linia2Route(kind: $0, host: h) } }
            .filter { seen.insert($0).inserted }
    }

    /// Список из app-config (features.transports): [{"type":"ws","host":"…","port":443}, …].
    /// Записи без адреса — к первому адресу из hosts; неизвестный тип, неверный адрес/порт, "enabled": false — пропускаются;
    /// записи с "ip" (подключение по IP без DNS) этой версией не поддерживаются — пропускаются.
    /// Пустой / отсутствующий / целиком неверный список → встроенный порядок.
    public static func parse(_ spec: [[String: Any]]?, hosts: [String]) -> [Linia2Route] {
        let fallbackHost = hosts.first(where: isValidHost)
        guard let spec = spec, !spec.isEmpty else { return defaultRoutes(hosts: hosts) }
        var out: [Linia2Route] = []
        var seen = Set<Linia2Route>()
        for e in spec {
            guard let type = e["type"] as? String, let kind = Linia2TransportKind(config: type) else { continue }
            if let en = e["enabled"] as? Bool, !en { continue }
            if e["ip"] != nil { continue }
            var host = fallbackHost
            if let h = e["host"] as? String { host = h.lowercased().trimmingCharacters(in: .whitespaces) }
            guard let hh = host, isValidHost(hh) else { continue }
            var port: Int?
            if let p = e["port"] {
                guard let n = (p as? NSNumber)?.intValue ?? (p as? String).flatMap({ Int($0) }), (1...65535).contains(n) else { continue }
                port = n
            }
            let r = Linia2Route(kind: kind, host: hh, port: port)
            if seen.insert(r).inserted { out.append(r) }
            if out.count >= maxRoutes { break }
        }
        return out.isEmpty ? defaultRoutes(hosts: hosts) : out
    }

    /// Последний удачный маршрут (не старше maxAge) — первым, остальные в прежнем порядке.
    public static func order(_ routes: [Linia2Route], remembered: Linia2Route?, rememberedAt: Date?,
                             maxAge: TimeInterval, now: Date = Date()) -> [Linia2Route] {
        guard let r = remembered, let at = rememberedAt, at <= now.addingTimeInterval(60),
              now.timeIntervalSince(at) < maxAge, let i = routes.firstIndex(of: r), i > 0 else { return routes }
        var out = routes
        out.remove(at: i)
        out.insert(r, at: 0)
        return out
    }

    /// Следующий маршрут после неудачи на index (по кругу).
    public static func next(after index: Int, count: Int) -> Int {
        count > 0 ? (index + 1) % count : 0
    }

    /// Ожидает ли отправленное сообщение ответа сервера ({ctrl} по id). {note} (набор текста, прочтение) — без ответа.
    static func expectsReply(_ data: Data) -> Bool {
        data.range(of: Data("\"id\":\"".utf8)) != nil
    }

    /// Тело ответа long-polling: один или несколько JSON-объектов подряд (сервер пишет пачку без разделителей).
    static func splitMessages(_ data: Data) -> [String] {
        var out: [String] = []
        var depth = 0, inString = false, escape = false, start = -1
        let bytes = [UInt8](data)
        for (i, b) in bytes.enumerated() {
            if inString {
                if escape { escape = false } else if b == 0x5C { escape = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                if depth == 0 { start = i }
                depth += 1
            case 0x7D, 0x5D:
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, start >= 0 {
                    if let s = String(bytes: bytes[start...i], encoding: .utf8) { out.append(s) }
                    start = -1
                }
            default: break
            }
        }
        return out
    }
}

/// Состояние маршрута для диагностики (экран «О приложении», журнал, call-diag).
public struct Linia2RouteStatus {
    public let route: Linia2Route
    /// «ws», «h3», «h2», «http/1.1» или nil (ещё не известно).
    public let netProtocol: String?
    public let connected: Bool
    /// Номер маршрута в текущем списке (с 1) и длина списка.
    public let index: Int
    public let count: Int
    /// Сколько подряд маршрутов не удалось в текущем круге переключения (0 — переключения нет).
    public let failedInCycle: Int
}

// MARK: - Long-polling (lp-h3 / lp)

/// Long-polling Tinode (как в web SDK): POST без sid → 201 {ctrl params.sid}; далее GET ?sid — ожидание сообщений
/// (сервер отвечает через ~50 с пустым телом, если сообщений нет); POST ?sid с телом — отправка.
/// Порядок: один опрос и одна отправка одновременно, очередь отправки FIFO. Обрыв опроса — до 3 повторов с тем же sid.
final class Linia2LongPoll: NSObject, Linia2Transport, URLSessionTaskDelegate {
    static let kPollTimeout: TimeInterval = 75
    static let kSendTimeout: TimeInterval = 20
    static let kMaxPollRetries = 3

    let http3: Bool
    private var delegate: WebSocketConnectionDelegate?
    private let q = DispatchQueue(label: "co.tinode.longpoll", qos: .default)
    private lazy var opQueue: OperationQueue = {
        let o = OperationQueue()
        o.name = "Linia2LongPoll.delegateQueue"
        o.maxConcurrentOperationCount = 1
        o.underlyingQueue = q
        return o
    }()

    private let lock = NSLock()
    private var stateValue: WebSocket.State = .unopened
    private var connectingSinceValue: Date?
    private var protoValue: String?
    private var lastPollOKValue = Date.distantPast
    var state: WebSocket.State { lock.lock(); defer { lock.unlock() }; return stateValue }
    var connectingSince: Date? { lock.lock(); defer { lock.unlock() }; return connectingSinceValue }
    var linia2NetProtocol: String? { lock.lock(); defer { lock.unlock() }; return protoValue }
    private func set(state s: WebSocket.State) { lock.lock(); stateValue = s; lock.unlock() }

    // Только на очереди q.
    private var session: URLSession?
    private var gen = 0
    private var endpoint: URL?
    private var apiKey = ""
    private var sid: String?
    private var outbox: [Data] = []
    private var sending = false
    private var pollFails = 0
    private var finished = false
    private var opened: Date?
    private var bytesIn = 0

    init(http3: Bool, delegate: WebSocketConnectionDelegate?) {
        self.http3 = http3
        self.delegate = delegate
        super.init()
    }

    private var name: String { http3 ? "lp-h3" : "lp" }

    func connect(url: URL, apiKey: String) {
        q.async {
            self.teardown()
            self.gen += 1
            self.endpoint = url
            self.apiKey = apiKey
            self.sid = nil
            self.outbox = []
            self.sending = false
            self.pollFails = 0
            self.finished = false
            self.opened = nil
            self.bytesIn = 0
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = Self.kPollTimeout
            cfg.timeoutIntervalForResource = Self.kPollTimeout + 15
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            cfg.httpMaximumConnectionsPerHost = 4
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: self.opQueue)
            self.lock.lock(); self.connectingSinceValue = Date(); self.protoValue = nil; self.lock.unlock()
            self.set(state: .connecting)
            Tinode.linia2Event?("lp-connect", ["t": self.name, "host": url.host ?? ""])
            self.create(self.gen)
        }
    }

    private func teardown() {
        session?.invalidateAndCancel()
        session = nil
    }

    private func request(sid: String?, body: Data?) -> URLRequest? {
        guard let e = endpoint, var c = URLComponents(url: e, resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "apikey", value: apiKey)]
        if let s = sid { items.append(URLQueryItem(name: "sid", value: s)) }
        c.queryItems = items
        guard let u = c.url else { return nil }
        let isPoll = sid != nil && body == nil
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData,
                           timeoutInterval: isPoll ? Self.kPollTimeout : Self.kSendTimeout)
        r.assumesHTTP3Capable = http3
        r.setValue(apiKey, forHTTPHeaderField: "X-Tinode-APIKey")
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if !isPoll {
            r.httpMethod = "POST"
            // Не application/x-www-form-urlencoded: сервер (FormValue) разобрал бы тело как форму и потерял сообщение.
            r.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = body ?? Data()
        } else {
            r.httpMethod = "GET"
        }
        return r
    }

    private static func status(_ r: URLResponse?) -> Int { (r as? HTTPURLResponse)?.statusCode ?? 0 }

    static func parseSid(_ d: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ctrl = obj["ctrl"] as? [String: Any], let params = ctrl["params"] as? [String: Any],
              let sid = params["sid"] as? String, !sid.isEmpty else { return nil }
        return sid
    }

    private func create(_ g: Int) {
        guard g == gen, let s = session, let req = request(sid: nil, body: Data()) else { return }
        s.dataTask(with: req) { [weak self] d, resp, err in
            guard let self = self, g == self.gen else { return }
            if let e = err as NSError? { self.fail(code: e.code, desc: e.localizedDescription, stage: "create", server: false); return }
            let st = Self.status(resp)
            guard st == 201 || st == 200, let d = d, let sid = Self.parseSid(d) else {
                self.fail(code: st, desc: "create: HTTP \(st)", stage: "create", server: st >= 400)
                return
            }
            self.sid = sid
            self.opened = Date()
            self.set(state: .open)
            Tinode.linia2Event?("lp-open", ["t": self.name, "ms": Int(Date().timeIntervalSince(self.connectingSince ?? Date()) * 1000),
                                            "proto": self.linia2NetProtocol ?? ""])
            self.delegate?.onConnected(connection: self)
            self.poll(g)
            self.pumpSend(g)
        }.resume()
    }

    private func poll(_ g: Int) {
        guard g == gen, let s = session, let req = request(sid: sid, body: nil) else { return }
        s.dataTask(with: req) { [weak self] d, resp, err in
            guard let self = self, g == self.gen else { return }
            if let e = err as NSError? {
                // Таймаут опроса (сервер отвечает за ~50 с) — канал завис: не повторяем.
                if e.code != NSURLErrorTimedOut && self.pollFails + 1 < Self.kMaxPollRetries {
                    self.pollFails += 1
                    Tinode.linia2Event?("lp-poll-retry", ["t": self.name, "code": e.code, "n": self.pollFails])
                    self.q.asyncAfter(deadline: .now() + 1) { self.poll(g) }
                    return
                }
                self.fail(code: e.code, desc: e.localizedDescription, stage: "poll", server: false)
                return
            }
            let st = Self.status(resp)
            switch st {
            case 200:
                self.pollFails = 0
                self.lock.lock(); self.lastPollOKValue = Date(); self.lock.unlock()
                if let d = d, !d.isEmpty {
                    self.bytesIn += d.count
                    for text in Linia2TransportPlan.splitMessages(d) {
                        guard g == self.gen else { return }
                        self.delegate?.onMessage(connection: self, text: text)
                    }
                }
                self.poll(g)
            case 403, 404, 410:
                // Сессия на сервере истекла / неизвестна — новое подключение (вход заново).
                self.fail(code: st, desc: "session expired (HTTP \(st))", stage: "poll", server: true)
            default:
                // 502/503 (сервер перезапускается) и т.п. — повтор с тем же sid.
                if self.pollFails + 1 < Self.kMaxPollRetries {
                    self.pollFails += 1
                    Tinode.linia2Event?("lp-poll-retry", ["t": self.name, "http": st, "n": self.pollFails])
                    self.q.asyncAfter(deadline: .now() + 1) { self.poll(g) }
                } else {
                    self.fail(code: st, desc: "poll: HTTP \(st)", stage: "poll", server: true)
                }
            }
        }.resume()
    }

    func send(data: Data) {
        q.async {
            guard !self.finished, self.state == .connecting || self.state == .open else { return }
            self.outbox.append(data)
            self.pumpSend(self.gen)
        }
    }

    /// Отправка строго по одной (порядок сообщений сохраняется).
    private func pumpSend(_ g: Int) {
        guard g == gen, !sending, state == .open, !outbox.isEmpty, let s = session else { return }
        let body = outbox.removeFirst()
        guard let req = request(sid: sid, body: body) else { return }
        sending = true
        s.dataTask(with: req) { [weak self] _, resp, err in
            guard let self = self, g == self.gen else { return }
            self.sending = false
            if let e = err as NSError? {
                // Повтор мог бы задвоить сообщение — сообщаем об обрыве (ожидающие ответа получат ошибку, вход — заново).
                self.fail(code: e.code, desc: e.localizedDescription, stage: "send", server: false)
                return
            }
            let st = Self.status(resp)
            guard (200..<300).contains(st) else {
                self.fail(code: st, desc: "send: HTTP \(st)", stage: "send", server: true)
                return
            }
            self.pumpSend(g)
        }.resume()
    }

    private func fail(code: Int, desc: String, stage: String, server: Bool) {
        guard !finished else { return }
        finished = true
        gen += 1
        teardown()
        set(state: .closed)
        Tinode.linia2Event?("lp-error", ["t": name, "stage": stage, "code": code, "desc": String(desc.prefix(120)),
                                         "open_s": Int(Date().timeIntervalSince(opened ?? Date())), "in_kb": bytesIn / 1024])
        delegate?.onDisconnected(connection: self, isServerOriginated: server,
                                 closeCode: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .abnormalClosure, reason: desc)
    }

    func close(byUs: Bool) {
        q.async {
            let st = self.state
            guard !self.finished, st == .connecting || st == .open else { return }
            self.finished = true
            self.gen += 1
            self.teardown()
            self.set(state: .closed)
            Tinode.linia2Event?("lp-close", ["t": self.name, "by": byUs ? "client" : "drop",
                                             "open_s": Int(Date().timeIntervalSince(self.opened ?? Date()))])
            self.delegate?.onDisconnected(connection: self, isServerOriginated: !byUs, closeCode: .goingAway,
                                          reason: byUs ? Tinode.linia2ClientCancelReason : "long-poll dropped")
        }
    }

    /// Живость: опрос отвечал недавно (сервер отвечает не реже ~50 с).
    func linia2Ping(timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        lock.lock(); let last = lastPollOKValue; let st = stateValue; lock.unlock()
        let ok = st == .open && (Date().timeIntervalSince(last) < 65 || Date().timeIntervalSince(connectingSince ?? .distantPast) < 65)
        done(ok)
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let p = metrics.transactionMetrics.last?.networkProtocolName, !p.isEmpty else { return }
        lock.lock(); let changed = protoValue != p; protoValue = p; lock.unlock()
        if changed { Tinode.linia2Event?("lp-proto", ["t": name, "proto": p]) }
    }
}

// MARK: - Только автотесты: «WebSocket заблокирован» (как ТСПУ: подключение висит)

final class Linia2BlackholeTransport: Linia2Transport {
    private let lock = NSLock()
    private var stateValue: WebSocket.State = .unopened
    private var since: Date?
    var state: WebSocket.State { lock.lock(); defer { lock.unlock() }; return stateValue }
    var connectingSince: Date? { lock.lock(); defer { lock.unlock() }; return since }
    var linia2NetProtocol: String? { "blocked" }
    func connect(url: URL, apiKey: String) {
        lock.lock(); stateValue = .connecting; since = Date(); lock.unlock()
        Tinode.linia2Event?("ws-blocked-test", [:])
    }
    func close(byUs: Bool) { lock.lock(); stateValue = .closed; lock.unlock() }
    func send(data: Data) {}
    func linia2Ping(timeout: TimeInterval, done: @escaping (Bool) -> Void) { done(false) }
}

// MARK: - Проверка маршрута без входа (возврат на основной)

/// Открывает отдельное соединение по маршруту, отправляет {hi} и ждёт ответ сервера; закрывает. Вход не выполняется.
public final class Linia2RouteProbe: WebSocketConnectionDelegate {
    private var transport: Linia2Transport?
    private var done: ((Bool, String?) -> Void)?
    private let lock = NSLock()
    private var keepAlive: Linia2RouteProbe?

    public static func probe(_ route: Linia2Route, apiKey: String, timeout: TimeInterval = 6,
                             done: @escaping (_ ok: Bool, _ netProtocol: String?) -> Void) {
        let p = Linia2RouteProbe()
        p.done = done
        p.keepAlive = p
        guard let url = route.url() else { p.finish(false); return }
        let t: Linia2Transport
        switch route.kind {
        case .ws: t = Connection.linia2TestBlockWS ? Linia2BlackholeTransport() : WebSocket(timeout: timeout, delegate: p)
        case .lpH3: t = Linia2LongPoll(http3: true, delegate: p)
        case .lp: t = Linia2LongPoll(http3: false, delegate: p)
        }
        p.transport = t
        t.connect(url: url, apiKey: apiKey)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { p.finish(false) }
    }

    private func finish(_ ok: Bool) {
        lock.lock()
        let d = done; done = nil
        let t = transport; transport = nil
        lock.unlock()
        guard let d = d else { return }
        let proto = t?.linia2NetProtocol
        t?.close(byUs: true)
        d(ok, proto)
        // Отпустить себя после закрытия (события закрытия приходят асинхронно и игнорируются).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { self.keepAlive = nil }
    }

    func onConnected(connection: Linia2Transport) {
        let hi = "{\"hi\":{\"id\":\"l2probe\",\"ver\":\"0.22\",\"ua\":\"Linia2-probe\"}}"
        connection.send(data: Data(hi.utf8))
    }
    func onDisconnected(connection: Linia2Transport, isServerOriginated clean: Bool, closeCode: URLSessionWebSocketTask.CloseCode, reason: String) {
        finish(false)
    }
    func onError(connection: Linia2Transport, error: Error) {}
    func onMessage(connection: Linia2Transport, text: String) {
        finish(text.contains("\"ctrl\""))
    }
    func onMessage(connection: Linia2Transport, data: Data) {}
}
