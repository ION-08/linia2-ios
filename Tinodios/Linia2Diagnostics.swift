//
//  Linia2Diagnostics.swift
//  Линия 2.0: Firebase (Crashlytics + Analytics) и доставка push-токенов на сервер.
//
//  Firebase включается, только если в сборке настоящий GoogleService-Info.plist (в CI-тестах — заглушка
//  ci/GoogleService-Info.stub.plist, тогда всё здесь молча ничего не делает).
//  В журнал событий НЕ пишутся персональные данные: ни тексты сообщений, ни логины, ни имена, ни топики.
//

import AVFoundation
import Foundation
import WebRTC
import FirebaseCore
import FirebaseCrashlytics
import FirebaseAnalytics
import FirebaseMessaging
import TinodeSDK

enum Linia2Firebase {
    /// Firebase настроен (FirebaseApp.configure вызван ровно один раз).
    private(set) static var configured = false

    /// Вызывать как можно раньше в didFinishLaunching (Crashlytics должен успеть поймать ранние вылеты).
    /// Только с главного потока.
    static func configureIfNeeded() {
        guard !configured, UiUtils.firebaseAvailable else { return }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        configured = true
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        let info = Bundle.main.infoDictionary
        Crashlytics.crashlytics().setCustomValue(info?["CFBundleShortVersionString"] as? String ?? "?", forKey: "l2_version")
        Crashlytics.crashlytics().setCustomValue(info?["CFBundleVersion"] as? String ?? "?", forKey: "l2_build")
    }
}

/// Журнал ключевых событий: Crashlytics.log (виден рядом с отчётом о вылете) + Analytics.logEvent.
/// Параметры — только технические (тип чата, вид звонка, состояние приложения), без персональных данных.
enum L2Log {
    static func event(_ name: String, _ params: [String: Any] = [:]) {
        let line = params.isEmpty ? name : name + " " + params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        Cache.log.info("L2: %@", line)
        guard Linia2Firebase.configured else { return }
        Crashlytics.crashlytics().log(line)
        Analytics.logEvent(name, parameters: params.isEmpty ? nil : params)
    }

    /// Тип чата по имени топика (без самого имени).
    static func topicKind(_ name: String?) -> String {
        guard let n = name else { return "none" }
        if n.hasPrefix("usr") || n.hasPrefix("p2p") { return "p2p" }
        if n.hasPrefix("grp") || n.hasPrefix("new") { return "grp" }
        if n.hasPrefix("chn") || n.hasPrefix("nch") { return "chn" }
        if n == "slf" { return "slf" }
        return "other"
    }
}

// MARK: - Push: FCM-токен → сервер Tinode, VoIP-токен → linia2-auth

/// Отвечает за то, чтобы сервер Tinode ВСЕГДА знал FCM-токен этого устройства:
/// при каждом запуске, при обновлении токена (MessagingDelegate) и после каждого входа (если токен пришёл
/// раньше, чем установилось соединение, — Tinode отбрасывает его, поэтому повторяем после onLogin).
final class Linia2Push: TinodeEventListener {
    static let shared = Linia2Push()
    private let kFcm = "linia2.fcm.token"

    private(set) var fcmToken: String? {
        get { UserDefaults.standard.string(forKey: kFcm) }
        set { UserDefaults.standard.set(newValue, forKey: kFcm) }
    }

    /// Новый (или тот же) FCM-токен от Firebase.
    func didReceive(fcmToken token: String) {
        guard !token.isEmpty else { return }
        let changed = token != fcmToken
        fcmToken = token
        L2Log.event("l2_push_token", ["kind": "fcm", "changed": changed ? 1 : 0])
        send()
    }

    /// Выход из аккаунта: токен удаляется в Firebase (Cache.invalidate), забываем и мы.
    func forget() { fcmToken = nil }

    /// Отправить токен на сервер Tinode ({hi dev}). Без соединения Tinode токен теряет — тогда ждём onLogin.
    func send() {
        DispatchQueue.main.async {
            guard let token = self.fcmToken, !token.isEmpty else { return }
            let tinode = Cache.tinode
            guard tinode.isConnected else {
                Cache.log.info("Linia2Push: нет соединения, FCM-токен уйдёт после входа")
                return
            }
            tinode.setDeviceToken(token: token).thenApply { _ in
                L2Log.event("l2_push_token_sent", ["kind": "fcm"])
                return nil
            }
        }
    }

    // Успешный вход (в т.ч. автоматический по токену при запуске/переподключении).
    func onLogin(code: Int, text: String) {
        guard code < 300 else {
            L2Log.event("l2_login_failed", ["code": code])
            return
        }
        L2Log.event("l2_login", ["code": code])
        send()
        Linia2Voip.shared.register()
        Linia2Turn.shared.prefetch()
    }
}

// MARK: - Диагностика звонка → сервер (POST /invite/api/call-diag), формат как у веба (l2Diag в linia2.js)

/// Только технические данные соединения: ICE, тип кандидатов, протокол, аудиотрек, уровень, байты, RTT, потери.
/// Содержимое разговора не передаётся. Отчёты копятся и отправляются пачками (каждые 5 с и в конце звонка).
/// Переподключение (смена сети, обрыв): события
///   reconnect {state: start|update|done|lost, reason, ws, ice, ms} — начало/конец «Переподключение…» (ms — длительность);
///   ice-restart {relay, signaling} — наш ICE restart offer; ice-restart {state: answer-applied|answered};
///   signaling {state: down|restored, reason, seq}, resubscribe, net {status, if} — смена сети (NWPathMonitor);
///   glare {action: ignore|rollback} — встречные offer; uitest-outage {s}, uitest-media {paused} — эмуляция в автотестах.
/// В stats: rc=1 — идёт переподключение. Пачки, не ушедшие из-за отсутствия сети, отправляются повторно.
final class Linia2CallDiag {
    let sid = "i" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1_000_000), radix: 36)
    private let topic: String
    private let seqProvider: () -> Int
    private var seq = 0
    private weak var client: WebRTCClient?
    private var events: [[String: Any]] = []
    private var timer: Timer?
    private var ended = false
    private let started = Date()
    /// Дополнительные поля для stats (состояние переподключения) — с главного потока.
    var stateProvider: (() -> [String: Any])?

    init(topic: String, seq: @escaping () -> Int, client: WebRTCClient) {
        self.topic = topic
        self.seqProvider = seq
        self.client = client
    }

    /// Только с главного потока.
    func start(_ info: [String: Any]) {
        var ev = info
        ev["type"] = "start"
        add(ev)
        flush()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
    }

    /// Событие (с любого потока).
    func add(_ ev: [String: Any]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.add(ev) }
            return
        }
        guard !ended || (ev["type"] as? String) == "end" else { return }
        var e = ev
        e["t"] = Int(Date().timeIntervalSince1970 * 1000)
        e["ms"] = Int(Date().timeIntervalSince(started) * 1000)   // от начала звонка на устройстве
        events.append(e)
        let s = seqProvider()
        if s > 0 { seq = s }
        // LINIA2: ключевые шаги сигнализации — сразу на сервер: если поток звонка зависнет или приложение
        // закроется, видно, до какого шага дошли (раньше уходили только «start», stats и «end»).
        let key: Set<String> = ["pair", "pc", "accept-sent", "accepted", "offer", "answer", "offer-sent", "answer-sent", "error", "ice"]
        if events.count >= 40 || key.contains((ev["type"] as? String) ?? "") { flush() }
    }

    func end(_ reason: String) {
        guard !ended else { return }
        timer?.invalidate()
        timer = nil
        add(["type": "end", "reason": reason])
        ended = true
        flush()
    }

    private func sample() {
        guard !ended, let client = client else { return }
        let rtc = RTCAudioSession.sharedInstance()
        let rtcState: [String: Any] = ["rtcAudio": rtc.isAudioEnabled ? 1 : 0, "rtcActive": rtc.isActive ? 1 : 0,
                                       "atrack": client.hasLocalAudioTrack, "aon": client.isAudioEnabled,
                                       "route": AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none"]
        client.statistics { report in
            var ev: [String: Any] = ["type": "stats", "arx": 0, "atx": 0, "vrx": 0, "vtx": 0, "alevel": 0.0]
            var arx = 0.0, atx = 0.0, vrx = 0.0, vtx = 0.0
            var cands: [String: [String: NSObject]] = [:]
            var pair: [String: NSObject]?
            for (id, st) in report.statistics {
                let v = st.values
                let kind = (v["kind"] as? String) ?? (v["mediaType"] as? String) ?? ""
                func num(_ k: String) -> Double { (v[k] as? NSNumber)?.doubleValue ?? 0 }
                switch st.type {
                case "candidate-pair":
                    if (v["state"] as? String) == "succeeded", (v["nominated"] as? NSNumber)?.boolValue ?? false { pair = v }
                case "local-candidate", "remote-candidate":
                    cands[id] = v
                case "inbound-rtp":
                    if kind == "audio" {
                        arx += num("bytesReceived")
                        if v["audioLevel"] != nil { ev["alevel"] = num("audioLevel") }
                        ev["lost"] = Int(num("packetsLost"))
                    } else if kind == "video" { vrx += num("bytesReceived") }
                case "outbound-rtp":
                    if kind == "audio" { atx += num("bytesSent") } else if kind == "video" { vtx += num("bytesSent") }
                case "media-source":
                    if kind == "audio", v["audioLevel"] != nil { ev["llevel"] = num("audioLevel") }
                default: break
                }
            }
            ev["arx"] = Int(arx); ev["atx"] = Int(atx); ev["vrx"] = Int(vrx); ev["vtx"] = Int(vtx)
            if let p = pair {
                let l = cands[(p["localCandidateId"] as? String) ?? ""] ?? [:]
                let r = cands[(p["remoteCandidateId"] as? String) ?? ""] ?? [:]
                ev["lt"] = (l["candidateType"] as? String) ?? "?"
                ev["rt"] = (r["candidateType"] as? String) ?? "?"
                ev["proto"] = (l["protocol"] as? String) ?? ""
                if let rtt = (p["currentRoundTripTime"] as? NSNumber)?.doubleValue { ev["rtt"] = Int(rtt * 1000) }
            }
            for (k, v) in rtcState { ev[k] = v }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                ev["ice"] = client.iceStateName
                for (k, v) in self.stateProvider?() ?? [:] { ev[k] = v }
                self.add(ev)
                self.flush()
            }
        }
    }

    private func flush() {
        guard !events.isEmpty, let token = Cache.tinode.authToken, !token.isEmpty,
              let url = URL(string: Linia2API.base + "call-diag") else { return }
        let batch = Array(events.prefix(60))
        events.removeFirst(batch.count)
        let body: [String: Any] = ["sid": sid, "topic": topic, "seq": seq, "client": "ios", "events": batch]
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            // Нет сети (обрыв во время звонка) — вернуть пачку в очередь, уйдёт со следующей отправкой.
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err != nil || status >= 500 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.events.count < 300 else { return }
                self.events.insert(contentsOf: batch, at: 0)
            }
        }.resume()
    }
}
