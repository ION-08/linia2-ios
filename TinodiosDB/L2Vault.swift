//
//  L2Vault.swift
//  TinodiosDB
//
//  Линия 2.0: шифрование локального хранилища ключами из Keychain и криптоудаление («код паники»).
//
//  Что шифруется (AES-256-GCM, CryptoKit, без новых зависимостей):
//  * messages.content            — ключом содержимого Kc (Keychain: WhenUnlockedThisDeviceOnly);
//  * messages.head, topics.pub/priv, users.pub, subscriptions.priv — ключом метаданных Km
//    (Keychain: AfterFirstUnlockThisDeviceOnly — нужен на заблокированном телефоне: входящий звонок,
//    имя отправителя в уведомлении, фоновая выборка по push);
//  * файлы кэша (картинки Kingfisher, видео-кружки) — ключом Kc (sealData/openData).
//  Сообщение, пришедшее, пока телефон заблокирован (Kc недоступен), шифруется на открытый ключ
//  X25519 (ECIES: эфемерный ключ + HKDF-SHA256 + AES-GCM, префикс l2p1:) — прочитать его можно только
//  после разблокировки (закрытый ключ X25519 = Kc-запись, WhenUnlockedThisDeviceOnly).
//  Ни один ключ не синхронизируется с iCloud (kSecAttrSynchronizable = false, *ThisDeviceOnly).
//
//  Формат поля в SQLite: "<префикс><base64(nonce|ciphertext|tag)>":
//    l2m1:  — Km;  l2m1w: — Km, заголовок звонка (нужен фильтр «Звонки» без расшифровки всей базы);
//    l2c1:  — Kc;  l2p1:  — ECIES на открытый ключ (эфемерный открытый ключ 32 байта + GCM).
//  Значение без префикса — открытый текст из версии до шифрования: читается как есть, а миграция
//  (BaseDb.encryptLegacyRows) при первом запуске новой версии зашифровывает его на месте.
//
//  Криптоудаление: destroyKeys() удаляет обе записи Keychain — всё, что осталось в базе и файлах
//  (в т.ч. в свободных страницах SQLite и на флеш-памяти), больше не расшифровать.
//

import CryptoKit
import Foundation
import Security

/// Обёртка над Keychain (общая группа приложения и расширения уведомлений; если подпись без групп
/// — в симуляторе CI — то без группы).
public struct L2Keychain {
    public let service: String

    public init(service: String) { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Чтение (без указания группы — ищет во всех доступных группах).
    public func read(_ account: String) -> (data: Data?, status: OSStatus) {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st == errSecSuccess ? out as? Data : nil, st)
    }

    /// Запись с заменой. access — kSecAttrAccessible…ThisDeviceOnly.
    @discardableResult
    public func write(_ account: String, _ data: Data, access: CFString) -> Bool {
        delete(account)
        var q = base(account)
        q[kSecAttrAccessible as String] = access
        q[kSecAttrSynchronizable as String] = false
        q[kSecValueData as String] = data
        q[kSecAttrAccessGroup as String] = BaseDb.kAppGroupId
        var st = SecItemAdd(q as CFDictionary, nil)
        if st == errSecMissingEntitlement {
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            st = SecItemAdd(q as CFDictionary, nil)
        }
        return st == errSecSuccess
    }

    public func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    /// Удалить все записи этой службы.
    public func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}

public enum L2Vault {
    public enum BootstrapResult { case ready, created, unavailable }

    private static let keychain = L2Keychain(service: "info.codix.liniya2.vault")
    private static let horizonKeychain = L2Keychain(service: "info.codix.liniya2.vault.h")
    private static let kMeta = "m1"       // Km (32) || открытый ключ X25519 (32), AfterFirstUnlockThisDeviceOnly
    private static let kContent = "c1"    // закрытый ключ X25519 (32), WhenUnlockedThisDeviceOnly; Kc = HKDF(него)
    private static let kReadyFlag = "l2.vault.ready"
    public static let kMigratedFlag = "l2.vault.migrated.v1"

    static let pMeta = "l2m1:", pMetaCall = "l2m1w:", pContent = "l2c1:", pPub = "l2p1:"

    private static let lock = NSRecursiveLock()
    private static var metaKey: SymmetricKey?
    private static var contentPub: Curve25519.KeyAgreement.PublicKey?
    private static var contentPriv: Curve25519.KeyAgreement.PrivateKey?
    private static var contentKey: SymmetricKey?
    private static var lastMetaMiss = Date.distantPast
    private static var lastPrivMiss = Date.distantPast

    /// Процесс приложения (не расширение уведомлений). Ключи создаёт только приложение.
    public static var isAppProcess: Bool { !Bundle.main.bundlePath.hasSuffix(".appex") }

    static var groupDefaults: UserDefaults? { UserDefaults(suiteName: BaseDb.kAppGroupId) }

    /// Ключи на этом устройстве уже создавались (после этого открытый текст в базу больше не пишется).
    public static var everCreated: Bool { groupDefaults?.bool(forKey: kReadyFlag) ?? false }

    // MARK: - Ключи

    /// Загрузить ключи; приложение создаёт их, если их нет. Возвращает .created, если ключи новые.
    @discardableResult
    public static func bootstrap() -> BootstrapResult {
        lock.lock(); defer { lock.unlock() }
        if loadMetaLocked(force: true) {
            if loadContentLocked(force: true) { return .ready }
            // Запись Km есть, а закрытого ключа нет (не «телефон заблокирован», а именно нет) — пара
            // неполная: содержимое шифровалось бы на ключ, который не прочитать. Создаём заново.
            guard isAppProcess, keychain.read(kContent).status == errSecItemNotFound else { return .ready }
            metaKey = nil
            contentPub = nil
        } else {
            guard isAppProcess, keychain.read(kMeta).status == errSecItemNotFound else { return .unavailable }
        }
        // Ключей нет: создаём (сначала обе старые записи — на случай частичной записи).
        keychain.delete(kMeta)
        keychain.delete(kContent)
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let km = SymmetricKey(size: .bits256)
        guard keychain.write(kContent, priv.rawRepresentation, access: kSecAttrAccessibleWhenUnlockedThisDeviceOnly) else {
            return .unavailable   // телефон заблокирован — создадим при следующей возможности
        }
        let meta = km.withUnsafeBytes { Data($0) } + priv.publicKey.rawRepresentation
        guard keychain.write(kMeta, meta, access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) else {
            keychain.delete(kContent)
            return .unavailable
        }
        metaKey = km
        contentPub = priv.publicKey
        contentPriv = priv
        contentKey = deriveContentKey(priv)
        groupDefaults?.set(true, forKey: kReadyFlag)
        return .created
    }

    /// Подгрузить ключ содержимого (после разблокировки телефона / выхода на экран).
    public static func prewarm() {
        lock.lock(); defer { lock.unlock() }
        _ = loadMetaLocked(force: true)
        _ = loadContentLocked(force: true)
    }

    /// Ключ содержимого доступен (телефон разблокирован и ключ есть).
    public static var contentKeyAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadContentLocked(force: false)
    }

    public static var metaKeyAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadMetaLocked(force: false)
    }

    /// КРИПТОУДАЛЕНИЕ: ключи стираются из Keychain и из памяти. После этого всё зашифрованное ими
    /// (база, кэш файлов, старые страницы SQLite) нерасшифровываемо.
    public static func destroyKeys() {
        lock.lock(); defer { lock.unlock() }
        keychain.delete(kMeta)
        keychain.delete(kContent)
        keychain.deleteAll()
        metaKey = nil
        contentPub = nil
        contentPriv = nil
        contentKey = nil
        lastMetaMiss = .distantPast
        lastPrivMiss = .distantPast
    }

    /// Уничтожить старые ключи и создать новые (пустое хранилище после срабатывания).
    @discardableResult
    public static func regenerate() -> BootstrapResult {
        lock.lock(); defer { lock.unlock() }
        destroyKeys()
        return bootstrap()
    }

    private static func deriveContentKey(_ priv: Curve25519.KeyAgreement.PrivateKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: priv.rawRepresentation),
                               salt: Data("l2c1".utf8), info: Data("linia2-content".utf8), outputByteCount: 32)
    }

    /// lock удерживается.
    private static func loadMetaLocked(force: Bool) -> Bool {
        if metaKey != nil { return true }
        if !force && Date().timeIntervalSince(lastMetaMiss) < 2 { return false }
        guard let d = keychain.read(kMeta).data, d.count == 64,
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: d.suffix(32)) else {
            lastMetaMiss = Date()
            return false
        }
        metaKey = SymmetricKey(data: d.prefix(32))
        contentPub = pub
        return true
    }

    /// lock удерживается.
    private static func loadContentLocked(force: Bool) -> Bool {
        if contentKey != nil { return true }
        if !force && Date().timeIntervalSince(lastPrivMiss) < 2 { return false }
        guard let d = keychain.read(kContent).data, d.count == 32,
              let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d) else {
            lastPrivMiss = Date()
            return false
        }
        contentPriv = priv
        contentKey = deriveContentKey(priv)
        if contentPub == nil { contentPub = priv.publicKey }
        return true
    }

    private static func currentMeta() -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return loadMetaLocked(force: false) ? metaKey : nil
    }

    private static func currentContent() -> (key: SymmetricKey?, priv: Curve25519.KeyAgreement.PrivateKey?, pub: Curve25519.KeyAgreement.PublicKey?) {
        lock.lock(); defer { lock.unlock() }
        _ = loadContentLocked(force: false)
        if contentPub == nil { _ = loadMetaLocked(force: false) }
        return (contentKey, contentPriv, contentPub)
    }

    // MARK: - Низкий уровень (Data)

    private static func gcmSeal(_ plain: Data, _ key: SymmetricKey) -> Data? {
        (try? AES.GCM.seal(plain, using: key))?.combined
    }

    private static func gcmOpen(_ combined: Data, _ key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private static func eciesKey(shared: SharedSecret, ephPub: Data, recipientPub: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephPub + recipientPub,
                                       sharedInfo: Data("linia2-l2p1".utf8), outputByteCount: 32)
    }

    private static func eciesSeal(_ plain: Data, to pub: Curve25519.KeyAgreement.PublicKey) -> Data? {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        let key = eciesKey(shared: shared, ephPub: eph.publicKey.rawRepresentation, recipientPub: pub.rawRepresentation)
        guard let c = gcmSeal(plain, key) else { return nil }
        return eph.publicKey.rawRepresentation + c
    }

    private static func eciesOpen(_ blob: Data, with priv: Curve25519.KeyAgreement.PrivateKey) -> Data? {
        guard blob.count > 32 + 28, let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(32)),
              let shared = try? priv.sharedSecretFromKeyAgreement(with: eph) else { return nil }
        let key = eciesKey(shared: shared, ephPub: Data(blob.prefix(32)), recipientPub: priv.publicKey.rawRepresentation)
        return gcmOpen(Data(blob.dropFirst(32)), key)
    }

    // MARK: - Поля базы

    /// Зашифровать метаданные (head, pub, priv). Ключа нет: до первого создания ключей — как раньше
    /// (открытый текст, его зашифрует миграция), после — nil (лучше потерять кэш, чем записать открыто).
    public static func sealMeta(_ s: String?) -> String? {
        guard let s = s else { return nil }
        guard let k = currentMeta() else { return everCreated ? nil : s }
        guard let c = gcmSeal(Data(s.utf8), k) else { return nil }
        // Заголовок звонка помечается, чтобы «Звонки» находили его SQL-фильтром (утечка одного бита: «это звонок»).
        return (s.contains("\"webrtc\"") ? pMetaCall : pMeta) + c.base64EncodedString()
    }

    public static func openMeta(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let body: Substring
        if s.hasPrefix(pMetaCall) {
            body = s.dropFirst(pMetaCall.count)
        } else if s.hasPrefix(pMeta) {
            body = s.dropFirst(pMeta.count)
        } else {
            return s   // открытый текст (до миграции)
        }
        guard let d = Data(base64Encoded: String(body)) else { return s }
        guard let k = currentMeta(), let p = gcmOpen(d, k) else { return nil }
        return String(data: p, encoding: .utf8)
    }

    /// Зашифровать содержимое сообщения: Kc, а если телефон заблокирован — на открытый ключ (ECIES).
    public static func sealContent(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let plain = Data(s.utf8)
        let cur = currentContent()
        if let k = cur.key, let c = gcmSeal(plain, k) { return pContent + c.base64EncodedString() }
        if let pub = cur.pub, let c = eciesSeal(plain, to: pub) { return pPub + c.base64EncodedString() }
        return everCreated ? nil : s
    }

    public static func openContent(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let isSym = s.hasPrefix(pContent), isPub = s.hasPrefix(pPub)
        guard isSym || isPub else { return s }   // открытый текст (до миграции)
        // Открытый текст, случайно начинающийся с префикса, base64 не декодируется — показываем как есть.
        guard let d = Data(base64Encoded: String(s.dropFirst(isSym ? pContent.count : pPub.count))), d.count >= 28 else { return s }
        let cur = currentContent()
        let p: Data?
        if isSym {
            guard let k = cur.key else { return nil }   // телефон заблокирован / ключ уничтожен
            p = gcmOpen(d, k)
        } else {
            guard let priv = cur.priv else { return nil }
            p = eciesOpen(d, with: priv)
        }
        return p.flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Файлы

    private static let fileMagic: [UInt8] = [0x4C, 0x32, 0x56]   // "L2V"

    /// Зашифровать содержимое файла кэша (Kc или ECIES). nil — ключа нет (такой файл не кэшируется).
    public static func sealData(_ plain: Data) -> Data? {
        let cur = currentContent()
        if let k = cur.key, let c = gcmSeal(plain, k) { return Data(fileMagic + [1]) + c }
        if let pub = cur.pub, let c = eciesSeal(plain, to: pub) { return Data(fileMagic + [2]) + c }
        return nil
    }

    public static func openData(_ blob: Data) -> Data? {
        guard blob.count > 4, Array(blob.prefix(3)) == fileMagic else { return nil }
        let body = Data(blob.dropFirst(4))
        let cur = currentContent()
        switch blob[blob.startIndex + 3] {
        case 1: return cur.key.flatMap { gcmOpen(body, $0) }
        case 2: return cur.priv.flatMap { eciesOpen(body, with: $0) }
        default: return nil
        }
    }

    // MARK: - «Горизонт» стирания

    private static var horizonCache: (uid: String, date: Date)??
    /// delId отметок «удалено по горизонту» (больше любых реальных delId сервера — поглощает их диапазоны).
    static let horizonDelId = 1 << 30

    /// После срабатывания (особенно уровня 1, когда сервер не трогается): сообщения этого пользователя
    /// не новее даты стирания в базу больше не сохраняются, а чаты без новых сообщений не показываются.
    public static func setHorizon(uid: String, date: Date) {
        lock.lock(); defer { lock.unlock() }
        let obj: [String: Any] = ["u": uid, "t": date.timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            horizonKeychain.write("h", d, access: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        }
        horizonCache = .some((uid, date))
    }

    public static func horizon(for uid: String?) -> Date? {
        guard let uid = uid, !uid.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if horizonCache == nil {
            if let d = horizonKeychain.read("h").data,
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let u = o["u"] as? String, let t = o["t"] as? Double {
                horizonCache = .some((u, Date(timeIntervalSince1970: t)))
            } else {
                horizonCache = .some(nil)
            }
        }
        guard let h = horizonCache ?? nil, h.uid == uid else { return nil }
        return h.date
    }
}
