//
//  Linia2Turn.swift
//  Линия 2.0: временные данные TURN для звонков.
//  Сервер Tinode до входа отдаёт только STUN; TURN (логин/пароль на 12 часов) выдаёт
//  /invite/api/turn по токену вошедшего пользователя. Чужие не могут пользоваться нашим TURN.
//

import Foundation
import WebRTC

final class Linia2Turn {
    static let shared = Linia2Turn()

    private struct Server: Codable {
        let urls: [String]
        let username: String
        let credential: String
    }

    private let queue = DispatchQueue(label: "info.codix.liniya2.turn")
    private var servers: [Server] = []
    private var validUntil = Date.distantPast
    private var inFlight = false
    private let kCache = "linia2.turn.cache"

    private struct Stored: Codable { let servers: [Server]; let validUntil: Date }

    private init() {
        // LINIA2: кэш на диске (TTL сервера, обычно 12 ч) — при холодном старте от входящего звонка TURN уже есть.
        if let d = UserDefaults.standard.data(forKey: kCache), let st = try? JSONDecoder().decode(Stored.self, from: d),
           st.validUntil.timeIntervalSinceNow > 600 {
            servers = st.servers
            validUntil = st.validUntil
        }
    }

    /// LINIA2 (1018): есть действующие данные TURN — соединение можно создать заранее без ожидания сервера.
    var hasFresh: Bool { queue.sync { validUntil.timeIntervalSinceNow > 60 && !servers.isEmpty } }

    /// Обновляет данные в фоне, если их нет или скоро истекут.
    func prefetch() {
        queue.async { self.fetchIfNeeded(completion: nil) }
    }

    /// Возвращает TURN-серверы для звонка; при необходимости ждёт ответа сервера (не дольше `timeout`).
    /// LINIA2: если в кэше есть действующие — сразу, без ожидания (раньше главный поток ждал до 4 с при каждом
    /// создании соединения — отсюда задержка ответа на offer); ожидание — только когда кэша нет совсем.
    func iceServers(timeout: TimeInterval = 1.5) -> [RTCIceServer] {
        let cached: [Server] = queue.sync { validUntil.timeIntervalSinceNow > 60 ? servers : [] }
        if !cached.isEmpty {
            if validUntil.timeIntervalSinceNow < 3600 { prefetch() }
            return cached.map { RTCIceServer(urlStrings: Self.withTcpFallback($0.urls), username: $0.username, credential: $0.credential) }
        }
        let sem = DispatchSemaphore(value: 0)
        var result: [Server] = []
        queue.async {
            self.fetchIfNeeded { list in
                result = list
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result.map { RTCIceServer(urlStrings: Self.withTcpFallback($0.urls), username: $0.username, credential: $0.credential) }
    }

    /// LINIA2: запасной путь TURN через TCP (сети, где UDP закрыт или рвётся при смене сети): для каждого
    /// `turn:хост:порт` (UDP или без указания транспорта) добавляется `?transport=tcp`, если сервер его не прислал.
    /// `turns:` (TLS) оставляем как есть. Сервер Линии сейчас отдаёт udp и tcp — тогда список не меняется.
    static func withTcpFallback(_ urls: [String]) -> [String] {
        var out = urls
        for u in urls where u.hasPrefix("turn:") {
            let base = u.components(separatedBy: "?").first ?? u
            let query = u.contains("?") ? (u.components(separatedBy: "?").last ?? "") : ""
            guard !query.contains("transport=tcp") else { continue }
            let tcp = base + "?transport=tcp"
            if !out.contains(tcp) { out.append(tcp) }
        }
        return out
    }

    // Вызывается только на `queue`.
    private func fetchIfNeeded(completion: (([Server]) -> Void)?) {
        if !servers.isEmpty && validUntil.timeIntervalSinceNow > 600 {
            completion?(servers)
            return
        }
        guard let token = Cache.tinode.authToken, !token.isEmpty,
              let url = URL(string: Linia2API.base + "turn") else {
            completion?(servers)
            return
        }
        if inFlight && completion == nil { return }
        inFlight = true
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        // LINIA2_NET (1020): HTTP/3 и хост рабочего маршрута, с повторами (обычный HTTPS до основного домена из России
        // режется — звонок 28.11: turn=false, iceServers=1).
        let t0 = Date()
        Linia2API.send(req, retries: 2) { data, resp, err in
            var parsed: [Server] = []
            var ttl: Double = 0
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["iceServers"] as? [[String: Any]] {
                ttl = json["ttl"] as? Double ?? 0
                for item in list {
                    guard let user = item["username"] as? String, let cred = item["credential"] as? String else { continue }
                    let urls = (item["urls"] as? [String]) ?? [(item["urls"] as? String)].compactMap { $0 }
                    if !urls.isEmpty { parsed.append(Server(urls: urls, username: user, credential: cred)) }
                }
            }
            Linia2LaunchLog.shared.step("turn-fetch", ["ok": parsed.isEmpty ? 0 : 1, "ms": Int(Date().timeIntervalSince(t0) * 1000),
                                                     "http": (resp as? HTTPURLResponse)?.statusCode ?? 0,
                                                     "err": (err as NSError?)?.code ?? 0, "host": url.host ?? ""])
            self.queue.async {
                self.inFlight = false
                if !parsed.isEmpty {
                    self.servers = parsed
                    self.validUntil = Date().addingTimeInterval(ttl > 0 ? ttl : 3600)
                    if let d = try? JSONEncoder().encode(Stored(servers: parsed, validUntil: self.validUntil)) {
                        UserDefaults.standard.set(d, forKey: self.kCache)
                    }
                }
                completion?(self.servers)
            }
        }
    }
}
