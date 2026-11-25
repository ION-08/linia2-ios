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

    private struct Server {
        let urls: [String]
        let username: String
        let credential: String
    }

    private let queue = DispatchQueue(label: "info.codix.liniya2.turn")
    private var servers: [Server] = []
    private var validUntil = Date.distantPast
    private var inFlight = false

    /// Обновляет данные в фоне, если их нет или скоро истекут.
    func prefetch() {
        queue.async { self.fetchIfNeeded(completion: nil) }
    }

    /// Возвращает TURN-серверы для звонка; при необходимости ждёт ответа сервера (не дольше `timeout`).
    func iceServers(timeout: TimeInterval = 4) -> [RTCIceServer] {
        let sem = DispatchSemaphore(value: 0)
        var result: [Server] = []
        queue.async {
            self.fetchIfNeeded { list in
                result = list
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
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
        URLSession.shared.dataTask(with: req) { data, _, _ in
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
            self.queue.async {
                self.inFlight = false
                if !parsed.isEmpty {
                    self.servers = parsed
                    self.validUntil = Date().addingTimeInterval(ttl > 0 ? ttl : 3600)
                }
                completion?(self.servers)
            }
        }.resume()
    }
}
