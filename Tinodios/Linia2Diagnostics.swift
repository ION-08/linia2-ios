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
import MetricKit
import UIKit
import TinodiosDB
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
            // LINIA2: {hi dev} до входа сервер отвергает («device ID update requires authentication») — только после входа.
            guard tinode.isConnected, tinode.isConnectionAuthenticated else {
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

    /// LINIA2: было ли событие такого типа (главный поток), напр. «offer» — accept дошёл до звонящего.
    func has(_ type: String) -> Bool { events.contains { ($0["type"] as? String) == type } }

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
        // Движок WKWebView: статистика собрана страницей (getStats) — те же поля arx/atx/vrx/vtx/alevel.
        if let w = client.web {
            let s = w.lastStats
            func n(_ k: String) -> Double { (s[k] as? NSNumber)?.doubleValue ?? 0 }
            var ev: [String: Any] = ["type": "stats", "engine": "web", "arx": Int(n("aIn")), "atx": Int(n("aOut")),
                                     "vrx": Int(n("vIn")), "vtx": Int(n("vOut")), "alevel": n("level"), "llevel": n("micLevel"),
                                     "lost": Int(n("lost")), "rtt": Int(n("rtt") * 1000), "lt": (s["pair"] as? String) ?? "?",
                                     "akind": (s["aKind"] as? String) ?? "", "ein": n("energyIn"),
                                     "rtp": (s["rtp"] as? String) ?? "", "tr": (s["tr"] as? String) ?? "",
                                     "aout": AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none",
                                     "ain": AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none",
                                     "acat": AVAudioSession.sharedInstance().category.rawValue]
            for (k, v) in rtcState { ev[k] = v }
            ev["ice"] = client.iceStateName
            for (k, v) in stateProvider?() ?? [:] { ev[k] = v }
            add(ev)
            flush()
            return
        }
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
            // LINIA2: кандидаты, ошибки addIceCandidate, ufrag, пары и STUN-проверки — в каждом stats (не только в конце).
            for (k, v) in client.diagStatsFields(report) { ev[k] = v }
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

    /// LINIA2: не больше одной отправки одновременно. Сервер дописывает события чтением-записью строки (SELECT, затем
    /// UPDATE) — параллельные POST одного звонка затирали друг друга: в call_diag пропадали offer/ice/pair
    /// (звонок 27.11 15:36, id 574/575), а другие события дублировались.
    private var flushInFlight = false

    private func flush() {
        guard !flushInFlight else { return }   // уйдёт после завершения текущей отправки
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
        flushInFlight = true
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let failed = err != nil || status >= 500
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.flushInFlight = false
                if failed {
                    // Нет сети (обрыв во время звонка) — вернуть пачку в очередь, уйдёт со следующей отправкой.
                    if self.events.count < 300 { self.events.insert(contentsOf: batch, at: 0) }
                } else if !self.events.isEmpty {
                    self.flush()
                }
            }
        }.resume()
    }
}


// MARK: - LINIA2: «чёрный ящик» запуска (шаги старта с временем) + MetricKit → POST /invite/api/call-diag

/// Шаги запуска пишутся сразу в файл App Group (переживают вылет и убийство сторожем iOS). При следующем запуске
/// прошлый журнал отправляется на сервер (call-diag, topic = "launch", sid = "launch-<id>") после входа;
/// текущий — через 90 с после запуска. Отчёты MetricKit (вылеты, зависания) — туда же (topic = "metrickit").
final class Linia2LaunchLog: NSObject, MXMetricManagerSubscriber {
    static let shared = Linia2LaunchLog()
    private let queue = DispatchQueue(label: "info.codix.liniya2.launchlog", qos: .utility)
    private let started = Date()
    private let launchId = String(UUID().uuidString.prefix(8)).lowercased()
    private var handle: FileHandle?
    private var count = 0
    private var netCount = 0
    private var uploadedPrev = false

    private static var dir: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId)?
            .appendingPathComponent("l2launch", isDirectory: true)
    }
    private var curURL: URL? { Self.dir?.appendingPathComponent("cur.jsonl") }
    private var prevURL: URL? { Self.dir?.appendingPathComponent("prev.jsonl") }

    /// Первым делом в didFinishLaunching.
    func start() {
        // События сокета/входа из TinodeSDK — в журнал (первые 150 за запуск — их хватает на разбор входа).
        Tinode.linia2Event = { name, extra in Linia2LaunchLog.shared.step("net-" + name, extra) }
        queue.sync {
            guard let dir = Self.dir, let cur = curURL, let prev = prevURL else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if fm.fileExists(atPath: cur.path) {
                // Прошлый журнал ещё не отправлен — не затирать (дописать к нему).
                if fm.fileExists(atPath: prev.path), let old = try? Data(contentsOf: cur), let h = try? FileHandle(forWritingTo: prev) {
                    _ = try? h.seekToEnd(); try? h.write(contentsOf: old); try? h.close()
                    try? fm.removeItem(at: cur)
                } else {
                    try? fm.moveItem(at: cur, to: prev)
                }
            }
            fm.createFile(atPath: cur.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            handle = try? FileHandle(forWritingTo: cur)
        }
        let info = Bundle.main.infoDictionary
        step("launch", ["build": info?["CFBundleVersion"] as? String ?? "", "ver": info?["CFBundleShortVersionString"] as? String ?? "",
                        "os": UIDevice.current.systemVersion, "state": UIApplication.shared.applicationState.rawValue,
                        "prot": UIApplication.shared.isProtectedDataAvailable ? 1 : 0])
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { didReceive(past) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.uploadCurrent() }
    }

    /// Шаг запуска (с любого потока). ms — от старта процесса.
    func step(_ name: String, _ extra: [String: Any] = [:]) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let main = Thread.isMainThread ? 1 : 0
        if !name.hasPrefix("net-") {
            stepsLock.lock()
            if stepsMem.count < 150 { stepsMem.append("\(name):\(ms)" + ((extra["dur"] as? Int).map { "/\($0)" } ?? "")) }
            stepsLock.unlock()
        }
        queue.async {
            // LINIA2 (сборка 1011): цикл переподключения забивал все 400 мест событиями net-* — отметки
            // сторожа главного потока (main-stall / main-blocked) и этапы после цикла терялись.
            // net-* — не больше 250; сторож — всегда (до 450).
            let isNet = name.hasPrefix("net-"), isWatchdog = name.hasPrefix("main-")
            if isNet {
                guard self.netCount < 250 else { return }
                self.netCount += 1
            }
            guard self.count < (isWatchdog ? 450 : 400) else { return }
            self.count += 1
            var e: [String: Any] = ["type": "launch", "step": name, "ms": ms, "main": main,
                                    "t": Int(Date().timeIntervalSince1970 * 1000), "lid": self.launchId]
            for (k, v) in extra { e[k] = v }
            guard JSONSerialization.isValidJSONObject(e), var d = try? JSONSerialization.data(withJSONObject: e) else { return }
            d.append(0x0A)
            try? self.handle?.write(contentsOf: d)
        }
    }

    /// Автотесты (-l2-uitest): шаги текущего запуска «имя:мс[/длительность]» — из памяти, без чтения файла
    /// (значение читается при каждом снимке доступности XCUITest).
    private let stepsLock = NSLock()
    private var stepsMem: [String] = []
    func debugSteps() -> String {
        stepsLock.lock(); defer { stepsLock.unlock() }
        return stepsMem.joined(separator: " ")
    }

    /// Шаг с замером длительности блока.
    @discardableResult
    func measure<T>(_ name: String, _ block: () -> T) -> T {
        let t0 = Date()
        let r = block()
        step(name, ["dur": Int(Date().timeIntervalSince(t0) * 1000)])
        return r
    }

    /// Вход выполнен — отправить журнал прошлого запуска.
    func onLogin() {
        queue.async {
            guard !self.uploadedPrev, let prev = self.prevURL, let data = try? Data(contentsOf: prev) else { return }
            self.uploadedPrev = true
            let events = Self.parse(data)
            let lid = (events.last?["lid"] as? String) ?? "prev"
            var summary: [String: Any] = ["type": "launch", "step": "prev-summary", "n": events.count,
                                          "last": (events.last?["step"] as? String) ?? "", "last_ms": (events.last?["ms"] as? Int) ?? 0]
            let clean = events.contains(where: { ($0["step"] as? String) == "terminate" || ($0["step"] as? String) == "background" })
            summary["clean_exit"] = clean ? 1 : 0
            self.upload(sid: "launch-" + lid, topic: "launch", events: events + [summary]) { ok in
                if ok { self.queue.async { try? FileManager.default.removeItem(at: prev) } }
            }
        }
    }

    private func uploadCurrent() {
        queue.async {
            guard let cur = self.curURL, let data = try? Data(contentsOf: cur) else { return }
            self.upload(sid: "launch-" + self.launchId, topic: "launch", events: Self.parse(data)) { _ in }
        }
    }

    private static func parse(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// Отправка пачками по 50 событий (сервер: ≤60 событий и ≤64 КБ на запрос, значения — только скаляры).
    private func upload(sid: String, topic: String, events: [[String: Any]], done: @escaping (Bool) -> Void) {
        guard !events.isEmpty, let token = Cache.tinode.authToken ?? SharedUtils.getAuthToken(), !token.isEmpty,
              let url = URL(string: Linia2API.base + "call-diag") else { done(false); return }
        var rest = events
        func next() {
            guard !rest.isEmpty else { done(true); return }
            let batch = Array(rest.prefix(50))
            rest.removeFirst(batch.count)
            let body: [String: Any] = ["sid": sid, "topic": topic, "seq": 0, "client": "ios", "events": batch]
            guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body),
                  data.count < 60_000 else { next(); return }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.httpBody = data
            URLSession.shared.dataTask(with: req) { _, resp, err in
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if err != nil || status >= 300 { done(false); return }
                next()
            }.resume()
        }
        next()
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var events: [[String: Any]] = []
        for p in payloads {
            let range = ["from": Int(p.timeStampBegin.timeIntervalSince1970), "to": Int(p.timeStampEnd.timeIntervalSince1970)]
            func add(_ kind: String, _ d: MXDiagnostic, _ extra: [String: Any]) {
                var e: [String: Any] = ["type": "mx-" + kind, "build": d.metaData.applicationBuildVersion,
                                        "os": d.metaData.osVersion, "device": d.metaData.deviceType]
                for (k, v) in range { e[k] = v }
                for (k, v) in extra { e[k] = v }
                // Стек вызовов — частями по 7 КБ (значения на сервере — строки).
                if let json = String(data: d.jsonRepresentation(), encoding: .utf8) {
                    let chars = Array(json)
                    var i = 0, part = 0
                    while i < chars.count && part < 7 {
                        e["js\(part)"] = String(chars[i..<min(i + 7000, chars.count)])
                        i += 7000; part += 1
                    }
                    e["js_len"] = chars.count
                }
                events.append(e)
            }
            for c in p.crashDiagnostics ?? [] {
                add("crash", c, ["exc": c.exceptionType?.intValue ?? -1, "code": c.exceptionCode?.intValue ?? -1,
                                 "signal": c.signal?.intValue ?? -1, "reason": c.terminationReason ?? "",
                                 "vm": c.virtualMemoryRegionInfo ?? ""])
            }
            for h in p.hangDiagnostics ?? [] {
                add("hang", h, ["dur_ms": Int(h.hangDuration.converted(to: .milliseconds).value)])
            }
            for c in p.cpuExceptionDiagnostics ?? [] {
                add("cpu", c, ["cpu_s": Int(c.totalCPUTime.converted(to: .seconds).value)])
            }
            for w in p.diskWriteExceptionDiagnostics ?? [] {
                add("disk", w, ["mb": Int(w.totalWritesCaused.converted(to: .megabytes).value)])
            }
        }
        guard !events.isEmpty else { return }
        step("metrickit", ["n": events.count])
        // По одному отчёту в запросе (большие стеки). До входа токена может не быть — повтор при входе.
        queue.async {
            self.pendingMX.append(contentsOf: events)
            self.flushMX()
        }
    }

    private var pendingMX: [[String: Any]] = []
    func flushMX() {
        queue.async {
            guard !self.pendingMX.isEmpty else { return }
            let e = self.pendingMX.removeFirst()
            self.upload(sid: "mx-" + self.launchId + "-\(self.pendingMX.count)", topic: "metrickit", events: [e]) { ok in
                if ok { self.flushMX() } else { self.queue.async { self.pendingMX.insert(e, at: 0) } }
            }
        }
    }
}
