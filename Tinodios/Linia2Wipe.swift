//
//  Linia2Wipe.swift
//  Линия 2.0: «код паники» — настройка с сервера и проверка на экране PIN.
//
//  В интерфейсе приложения этой функции НЕТ (ни пунктов, ни текстов): настройка задаётся только в вебе,
//  приложение получает её с сервера (POST /invite/api/panic/config, /opt/linia2/CONTRACTS-panic.md, 3.1) при
//  запуске, входе, возврате из фона и по тихому push linia2-config; хранит в Keychain (ThisDeviceOnly) для
//  работы без сети. Код вводится на обычном экране PIN.
//
//  Проверка за одинаковое время: на КАЖДЫЙ ввод считаются оба значения — scrypt(ввод, соль, N, r, p) с
//  параметрами сервера (или такими же фиктивными, если кода нет) и хеш PIN; сравнение — за постоянное время,
//  ответ экрана — через одну и ту же фиксированную задержку от последней цифры, какой бы ни был исход.
//  Совпал с PIN — это PIN (код ≠ PIN, контракт 5.4).
//

import CommonCrypto
import Foundation
import Security
import TinodeSDK
import TinodiosDB

// MARK: - scrypt (RFC 7914) — CommonCrypto его не умеет; PBKDF2-HMAC-SHA256 — из CommonCrypto

enum L2Scrypt {
    static func pbkdf2(_ password: [UInt8], _ salt: [UInt8], length: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: length)
        let pw = password.map { Int8(bitPattern: $0) }
        let rc = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
                                      CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1, &out, length)
        return rc == Int32(kCCSuccess) ? out : nil
    }

    @inline(__always) private static func rotl(_ a: UInt32, _ b: UInt32) -> UInt32 { (a << b) | (a >> (32 - b)) }

    /// Salsa20/8 на месте (16 слов).
    private static func salsa8(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        for _ in 0..<4 {
            x4 ^= rotl(x0 &+ x12, 7); x8 ^= rotl(x4 &+ x0, 9); x12 ^= rotl(x8 &+ x4, 13); x0 ^= rotl(x12 &+ x8, 18)
            x9 ^= rotl(x5 &+ x1, 7); x13 ^= rotl(x9 &+ x5, 9); x1 ^= rotl(x13 &+ x9, 13); x5 ^= rotl(x1 &+ x13, 18)
            x14 ^= rotl(x10 &+ x6, 7); x2 ^= rotl(x14 &+ x10, 9); x6 ^= rotl(x2 &+ x14, 13); x10 ^= rotl(x6 &+ x2, 18)
            x3 ^= rotl(x15 &+ x11, 7); x7 ^= rotl(x3 &+ x15, 9); x11 ^= rotl(x7 &+ x3, 13); x15 ^= rotl(x11 &+ x7, 18)
            x1 ^= rotl(x0 &+ x3, 7); x2 ^= rotl(x1 &+ x0, 9); x3 ^= rotl(x2 &+ x1, 13); x0 ^= rotl(x3 &+ x2, 18)
            x6 ^= rotl(x5 &+ x4, 7); x7 ^= rotl(x6 &+ x5, 9); x4 ^= rotl(x7 &+ x6, 13); x5 ^= rotl(x4 &+ x7, 18)
            x11 ^= rotl(x10 &+ x9, 7); x8 ^= rotl(x11 &+ x10, 9); x9 ^= rotl(x8 &+ x11, 13); x10 ^= rotl(x9 &+ x8, 18)
            x12 ^= rotl(x15 &+ x14, 7); x13 ^= rotl(x12 &+ x15, 9); x14 ^= rotl(x13 &+ x12, 13); x15 ^= rotl(x14 &+ x13, 18)
        }
        b[0] = b[0] &+ x0; b[1] = b[1] &+ x1; b[2] = b[2] &+ x2; b[3] = b[3] &+ x3
        b[4] = b[4] &+ x4; b[5] = b[5] &+ x5; b[6] = b[6] &+ x6; b[7] = b[7] &+ x7
        b[8] = b[8] &+ x8; b[9] = b[9] &+ x9; b[10] = b[10] &+ x10; b[11] = b[11] &+ x11
        b[12] = b[12] &+ x12; b[13] = b[13] &+ x13; b[14] = b[14] &+ x14; b[15] = b[15] &+ x15
    }

    /// scryptBlockMix: b (32·r слов) → b; y — буфер 32·r, x — буфер 16.
    private static func blockMix(_ b: UnsafeMutablePointer<UInt32>, _ y: UnsafeMutablePointer<UInt32>,
                                 _ x: UnsafeMutablePointer<UInt32>, _ r: Int) {
        x.update(from: b + (2 * r - 1) * 16, count: 16)
        for i in 0..<(2 * r) {
            let bi = b + i * 16
            for k in 0..<16 { x[k] ^= bi[k] }
            salsa8(x)
            let dst = i % 2 == 0 ? (i / 2) * 16 : (r + i / 2) * 16
            (y + dst).update(from: x, count: 16)
        }
        b.update(from: y, count: 32 * r)
    }

    /// scrypt(password, salt, N, r, p, dkLen). nil — недопустимые параметры (защита от «тяжёлых» значений).
    static func valid(n: Int, r: Int, p: Int, dkLen: Int) -> Bool {
        n >= 2 && n & (n - 1) == 0 && n <= 1 << 20 && (1...32).contains(r) && (1...16).contains(p) &&
            (16...64).contains(dkLen) && 128 * r * n <= 64 << 20
    }

    static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, dkLen: Int) -> [UInt8]? {
        guard valid(n: n, r: r, p: p, dkLen: dkLen) else { return nil }
        let blockLen = 128 * r, words = 32 * r
        guard var bytes = pbkdf2(password, salt, length: p * blockLen) else { return nil }
        let x = UnsafeMutablePointer<UInt32>.allocate(capacity: words)
        let y = UnsafeMutablePointer<UInt32>.allocate(capacity: words)
        let t = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        let v = UnsafeMutablePointer<UInt32>.allocate(capacity: words * n)
        defer {
            v.update(repeating: 0, count: words * n)
            x.update(repeating: 0, count: words)
            v.deallocate(); x.deallocate(); y.deallocate(); t.deallocate()
        }
        for i in 0..<p {
            let off = i * blockLen
            for w in 0..<words {
                let o = off + 4 * w
                x[w] = UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
            }
            for j in 0..<n {
                (v + j * words).update(from: x, count: words)
                blockMix(x, y, t, r)
            }
            let mask = UInt32(n - 1)
            for _ in 0..<n {
                let vk = v + Int(x[(2 * r - 1) * 16] & mask) * words
                for w in 0..<words { x[w] ^= vk[w] }
                blockMix(x, y, t, r)
            }
            for w in 0..<words {
                let o = off + 4 * w, val = x[w]
                bytes[o] = UInt8(truncatingIfNeeded: val)
                bytes[o + 1] = UInt8(truncatingIfNeeded: val >> 8)
                bytes[o + 2] = UInt8(truncatingIfNeeded: val >> 16)
                bytes[o + 3] = UInt8(truncatingIfNeeded: val >> 24)
            }
        }
        return pbkdf2(password, bytes, length: dkLen)
    }

    /// Контрольный пример RFC 7914 (scrypt("password", "NaCl", 1024, 8, 16, 64)) — для автотеста.
    static func selfTest() -> Bool {
        let expected = "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
        guard let d = derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1024, r: 8, p: 16, dkLen: 64) else { return false }
        return d.map { String(format: "%02x", $0) }.joined() == expected
    }
}

// MARK: - Настройка

struct Linia2WipeConfig {
    let raw: [String: Any]
    let enabled: Bool
    let level: Int
    let deletePeers: Bool
    let wipeOnFail: Bool
    let codeLen: Int
    let rev: Int
    /// Параметры scrypt и ожидаемое значение (nil — кода нет).
    let kdf: (n: Int, r: Int, p: Int, dkLen: Int, salt: [UInt8], hash: [UInt8])?
    /// ms; > 0 — скрывать всё не новее этой отметки (контракт, 4).
    let hideBefore: Double
    let wipe: (id: String, level: Int)?
    let reportKey: String?

    var hasCode: Bool { enabled && kdf != nil }

    init?(json: [String: Any]) {
        if let ok = json["ok"] as? Bool, !ok { return nil }
        raw = json
        enabled = json["enabled"] as? Bool ?? false
        level = min(4, max(1, (json["level"] as? NSNumber)?.intValue ?? 2))
        deletePeers = json["delete_peers"] as? Bool ?? true
        wipeOnFail = json["wipe_on_fail"] as? Bool ?? false
        codeLen = (json["code_len"] as? NSNumber)?.intValue ?? 0
        rev = (json["rev"] as? NSNumber)?.intValue ?? 0
        hideBefore = (json["hide_before"] as? NSNumber)?.doubleValue ?? 0
        reportKey = json["report_key"] as? String
        if let h = json["hash"] as? [String: Any], (h["alg"] as? String ?? "scrypt") == "scrypt",
           let salt = (h["salt"] as? String).flatMap(Linia2WipeConfig.b64), let hash = (h["hash"] as? String).flatMap(Linia2WipeConfig.b64),
           !hash.isEmpty {
            kdf = ((h["n"] as? NSNumber)?.intValue ?? 16384, (h["r"] as? NSNumber)?.intValue ?? 8,
                   (h["p"] as? NSNumber)?.intValue ?? 1, (h["dklen"] as? NSNumber)?.intValue ?? hash.count, salt, hash)
        } else {
            kdf = nil
        }
        if let w = json["wipe"] as? [String: Any], let id = (w["id"] as? String) ?? (w["id"] as? NSNumber)?.stringValue, !id.isEmpty {
            wipe = (id, min(4, max(1, (w["level"] as? NSNumber)?.intValue ?? 2)))
        } else {
            wipe = nil
        }
    }

    /// base64 или base64url.
    static func b64(_ s: String) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }
}

// MARK: - Хранение (Keychain, только это устройство)

enum Linia2WipeStore {
    private static let kc = L2Keychain(service: "info.codix.liniya2.applock.x")
    private static let kConfig = "c", kFails = "f", kDevice = "d", kReportKey = "k", kPending = "p", kSeen = "s"
    private static var cached: Linia2WipeConfig??

    /// Последняя настройка с сервера.
    static var config: Linia2WipeConfig? {
        if let c = cached { return c }
        let c = kc.read(kConfig).data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.flatMap(Linia2WipeConfig.init(json:))
        cached = .some(c)
        return c
    }

    static func save(_ json: [String: Any]) {
        guard let cfg = Linia2WipeConfig(json: json), let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        kc.write(kConfig, d, access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        if let k = cfg.reportKey, !k.isEmpty { kc.write(kReportKey, Data(k.utf8), access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) }
        cached = .some(cfg)
    }

    /// После срабатывания код больше не хранится (до новой настройки с сервера).
    static func forgetCode() {
        kc.delete(kConfig)
        cached = .some(nil)
    }

    /// Стабильный id установки (8–64 [A-Za-z0-9_-]).
    static var deviceId: String {
        if let d = kc.read(kDevice).data, let s = String(data: d, encoding: .utf8), s.count >= 8 { return s }
        let s = "i" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        kc.write(kDevice, Data(s.utf8), access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        return s
    }

    static var reportKey: String? { kc.read(kReportKey).data.flatMap { String(data: $0, encoding: .utf8) } }

    /// Неверных PIN подряд (переживает перезапуск).
    static var failures: Int {
        get { kc.read(kFails).data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int($0) } ?? 0 }
        set {
            if newValue <= 0 { kc.delete(kFails) } else { kc.write(kFails, Data(String(newValue).utf8), access: kSecAttrAccessibleWhenUnlockedThisDeviceOnly) }
        }
    }

    /// Неотправленные отчёты о срабатывании (без переписки и без токена — контракт 3.3).
    static var pending: [[String: Any]] {
        get { kc.read(kPending).data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? [] }
        set {
            if newValue.isEmpty { kc.delete(kPending); return }
            if let d = try? JSONSerialization.data(withJSONObject: newValue) {
                kc.write(kPending, d, access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            }
        }
    }

    /// Выполненные удалённые команды стирания.
    static var seenWipes: [String] {
        get { kc.read(kSeen).data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String] } ?? [] }
        set {
            if let d = try? JSONSerialization.data(withJSONObject: Array(newValue.suffix(50))) {
                kc.write(kSeen, d, access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            }
        }
    }
}

// MARK: - Получение с сервера

/// Слой API (контракт /opt/linia2/CONTRACTS-panic.md, раздел 3). Все колбэки — на главном потоке.
enum Linia2WipeAPI {
    static func config(token: String, body: [String: Any], completion: @escaping (Int, [String: Any]?) -> Void) {
        Linia2API.post("panic/config", body, token: token, completion: completion)
    }

    static func trigger(token: String?, body: [String: Any], completion: @escaping (Int, [String: Any]?) -> Void) {
        Linia2API.post("panic/trigger", body, token: token, completion: completion)
    }

    static func ack(token: String?, body: [String: Any], completion: @escaping (Int, [String: Any]?) -> Void) {
        Linia2API.post("panic/ack", body, token: token, completion: completion)
    }
}

/// Что сработало.
enum Linia2WipeSource: String {
    case pin = "ios-pin", failures = "ios-fail10", remote = "ios-remote"
}

final class Linia2WipeSync: TinodeEventListener {
    static let shared = Linia2WipeSync()
    private var lastFetch = Date.distantPast
    private var inFlight = false

    /// Выполнить стирание (задаётся исполнителем при запуске приложения). level, source.
    static var execute: ((Int, Linia2WipeSource, String?) -> Void)?
    /// Отправить неотправленные отчёты (задаётся исполнителем).
    static var flushPending: (() -> Void)?

    /// Автотесты: настройка из окружения (L2_WIPE_OVERRIDE = JSON как у сервера; поле "code" — открытый код,
    /// соль и scrypt считаются здесь). Сеть тогда не используется.
    static var testOverride: [String: Any]? {
        guard ProcessInfo.processInfo.arguments.contains("-l2-uitest"),
              let raw = ProcessInfo.processInfo.environment["L2_WIPE_OVERRIDE"], !raw.isEmpty,
              var obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        if let code = obj["code"] as? String {
            let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
            let n = (obj["n"] as? NSNumber)?.intValue ?? 16384
            if let h = L2Scrypt.derive(password: Array(code.utf8), salt: salt, n: n, r: 8, p: 1, dkLen: 32) {
                obj["hash"] = ["alg": "scrypt", "n": n, "r": 8, "p": 1, "dklen": 32,
                               "salt": Data(salt).base64EncodedString(), "hash": Data(h).base64EncodedString()]
            }
            obj["code"] = nil
            obj["enabled"] = obj["enabled"] ?? true
            obj["code_len"] = code.count
        }
        obj["ok"] = true
        return obj
    }

    /// При запуске приложения.
    func start() {
        if let o = Self.testOverride {
            Linia2WipeStore.save(o)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh(force: true) }
    }

    func onLogin(code: Int, text: String) {
        guard code < 300 else { return }
        DispatchQueue.main.async {
            Self.flushPending?()
            self.refresh(force: true)
        }
    }

    /// Перечитать настройку (не чаще раза в 30 с, если не force). Только с главного потока.
    func refresh(force: Bool = false) {
        Self.flushPending?()
        guard Self.testOverride == nil, !inFlight, force || Date().timeIntervalSince(lastFetch) > 30,
              let token = SharedUtils.getAuthToken(), !token.isEmpty else { return }
        inFlight = true
        lastFetch = Date()
        var body: [String: Any] = ["device": Linia2WipeStore.deviceId]
        if Linia2AppLock.shared.isEnabled { body["pin_len"] = Linia2AppLock.shared.pinLength }
        Linia2WipeAPI.config(token: token, body: body) { [weak self] status, json in
            self?.inFlight = false
            guard status == 200, let json = json, (json["ok"] as? Bool) == true else { return }   // нет связи / нет API — хранимое остаётся
            Linia2WipeStore.save(json)
            Self.apply(Linia2WipeStore.config)
        }
    }

    /// hide_before и удалённое стирание.
    static func apply(_ cfg: Linia2WipeConfig?) {
        guard let cfg = cfg else { return }
        if cfg.hideBefore > 0, let uid = Linia2WipeSync.currentUid {
            let d = Date(timeIntervalSince1970: cfg.hideBefore / 1000)
            if (L2Vault.horizon(for: uid) ?? .distantPast) < d { L2Vault.setHorizon(uid: uid, date: d) }
        }
        if let w = cfg.wipe, !Linia2WipeStore.seenWipes.contains(w.id) {
            Linia2WipeStore.seenWipes += [w.id]
            execute?(w.level, .remote, w.id)
        }
    }

    static var currentUid: String? {
        if let u = Cache.tinode.myUid, !u.isEmpty { return u }
        return BaseDb.sharedInstance.sqlStore?.myUid
    }

    /// Тихий push: {"l2cfg": …} (тема linia2-config) или {"l2wipe": …}.
    static func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["l2cfg"] != nil || userInfo["l2wipe"] != nil else { return false }
        DispatchQueue.main.async { shared.refresh(force: true) }
        return userInfo["l2wipe"] != nil
    }
}

// MARK: - Проверка ввода на экране PIN

enum Linia2PinGate {
    enum Outcome { case pin, wipe, wrong }

    /// Ответ экрана — ровно через это время от последней цифры, при любом исходе.
    static let fixedDelay: TimeInterval = 0.6
    private static let queue = DispatchQueue(label: "info.codix.liniya2.pin", qos: .userInitiated)
    private static let dummySalt: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }

    @inline(__always) static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt8(a.count == b.count ? 0 : 1)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }

    /// Обе проверки (одна и та же функция scrypt в обоих путях), затем решение.
    static func evaluate(_ pin: String) -> Outcome {
        let cfg = Linia2WipeStore.config
        let k = cfg?.kdf
        let usable = cfg?.hasCode == true && k.map { L2Scrypt.valid(n: $0.n, r: $0.r, p: $0.p, dkLen: $0.dkLen) } == true
        // Без кода (или с недопустимыми параметрами) — те же вычисления с фиктивными параметрами.
        let n = usable ? k!.n : 16384, r = usable ? k!.r : 8, p = usable ? k!.p : 1, dk = usable ? k!.dkLen : 32
        let salt = usable ? k!.salt : dummySalt
        let expected = usable ? k!.hash : [UInt8](repeating: 0, count: 32)
        let derived = L2Scrypt.derive(password: Array(pin.utf8), salt: salt, n: n, r: r, p: p, dkLen: dk) ?? []
        let codeMatch = constantTimeEqual(derived, expected)
        let pinMatch = Linia2AppLock.shared.verify(pin: pin)
        if pinMatch { return .pin }
        return codeMatch && usable ? .wipe : .wrong
    }

    /// Проверить ввод; completion — на главном потоке через fixedDelay от `since`.
    /// Для .wipe стирание (быстрая часть) выполняется ДО ответа, внутри той же задержки.
    static func check(_ pin: String, since: Date, completion: @escaping (Outcome) -> Void) {
        queue.async {
            let outcome = evaluate(pin)
            DispatchQueue.main.async {
                var result = outcome
                switch outcome {
                case .pin:
                    Linia2WipeStore.failures = 0
                case .wipe:
                    Linia2WipeStore.failures = 0
                    Linia2WipeSync.execute?(Linia2WipeStore.config?.level ?? 2, .pin, nil)
                case .wrong:
                    let f = Linia2WipeStore.failures + 1
                    Linia2WipeStore.failures = f
                    if f >= 10, Linia2WipeStore.config?.wipeOnFail == true {
                        Linia2WipeStore.failures = 0
                        Linia2WipeSync.execute?(Linia2WipeStore.config?.level ?? 2, .failures, nil)
                        result = .wipe
                    }
                }
                let wait = max(0, fixedDelay - Date().timeIntervalSince(since))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    Linia2TestProbe.lastPinMs = Int(Date().timeIntervalSince(since) * 1000)
                    completion(result)
                }
            }
        }
    }
}

/// Значения для автотестов (-l2-uitest), см. Linia2TestHook.
enum Linia2TestProbe {
    static var lastPinMs = -1
    static var wipes = 0
    // Звонки (баг 1006): VoIP push всего / повторы того же звонка / отброшены (завершён, устарел) / показан входящий.
    static var voipPushes = 0
    static var voipDuplicates = 0
    static var voipIgnored = 0
    static var incomingShown = 0
    // Запуск (баг 1006): время до интерфейса (мс от старта процесса), показанных «Связь потеряна», миграция базы.
    static var uiReadyMs = -1
    static var lostToasts = 0
    static var migrated = -1
    // Завершение звонка: мс от «Завершить» до закрытия экрана; число завершений собеседником.
    static var lastHangupCloseMs = -1
    static var remoteEnds = 0
    // Движок звонка (1 — нативный, 2 — WKWebView), ответов из фона на нативном движке, переходов на WKWebView,
    // мс от начала перехода до ICE connected; ответов тестовым крючком L2_TEST_BG_ANSWER (в фоне).
    static var callEngine = 0
    static var nativeBg = 0
    static var webSwitches = 0
    static var webSwitchIceMs = -1
    static var bgAnswers = 0
}
