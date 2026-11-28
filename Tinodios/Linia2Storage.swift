//
//  Linia2Storage.swift
//  Линия 2.0: защита файлов приложения и их стирание (код паники, удалённое стирание).
//
//  * Картинки в дисковом кэше Kingfisher хранятся зашифрованными (L2Vault.sealData, ключ Kc из Keychain).
//  * Видео-кружки: в кэше — зашифрованный файл .l2v, для проигрывания расшифровывается во временную
//    папку tmp/l2play (защита Complete, чистится при каждом запуске и при стирании).
//  * URLCache на диске отключён (только память) — HTTP-ответы не оседают в Library/Caches.
//  * Каталоги: защита файлов iOS и исключение из резервной копии (isExcludedFromBackup):
//      кэш картинок, кружки, tmp/l2play — Complete (нужны только на разблокированном экране);
//      Documents (сохранённые вложения), Caches (запись голосового) — CompleteUnlessOpen: загрузка
//      фоновой URLSession и запись голосового продолжаются, если экран заблокировали во время них;
//      tmp — CompleteUntilFirstUserAuthentication: тело выгрузки вложения читает nsurlsessiond в фоне
//      на заблокированном телефоне (Complete оборвал бы отправку);
//      база в общем контейнере — CompleteUntilFirstUserAuthentication (push/звонок, см. BaseDb.excludeFromBackup).
//  * WKWebView (движок звонка, страницы документов) — WKWebsiteDataStore.nonPersistent().
//  * Миграция: при первом запуске версии с шифрованием открытые значения в базе зашифровываются
//    на месте (BaseDb.encryptLegacyRows), старый незашифрованный кэш картинок и кружков удаляется
//    (он перезагружается с сервера по мере просмотра).
//

import UIKit
import UserNotifications
import WebKit
import Kingfisher
import TinodeSDK
import TinodiosDB

/// Дисковый кэш Kingfisher: на диск — только зашифрованное.
struct Linia2SealedImageSerializer: CacheSerializer {
    func data(with image: KFCrossPlatformImage, original: Data?) -> Data? {
        guard let plain = DefaultCacheSerializer.default.data(with: image, original: original) else { return nil }
        return L2Vault.sealData(plain)
    }

    func image(with data: Data, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
        guard let plain = L2Vault.openData(data) else { return nil }
        return DefaultCacheSerializer.default.image(with: plain, options: options)
    }
}

enum Linia2Storage {
    private static let fm = FileManager.default
    private static let kMigrated = L2Vault.kMigratedFlag
    private static var groupDefaults: UserDefaults? { UserDefaults(suiteName: BaseDb.kAppGroupId) }
    private static let migrationQueue = DispatchQueue(label: "info.codix.liniya2.vault-migration", qos: .utility)
    private static var migrating = false

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var library: URL { fm.urls(for: .libraryDirectory, in: .userDomainMask)[0] }
    static var caches: URL { fm.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    static var tmp: URL { fm.temporaryDirectory }
    static var kingfisherDir: URL { caches.appendingPathComponent("com.onevcat.Kingfisher.ImageCache.default", isDirectory: true) }
    static var roundDir: URL { dir(caches.appendingPathComponent("l2round", isDirectory: true), .complete) }
    static var playDir: URL { dir(tmp.appendingPathComponent("l2play", isDirectory: true), .complete) }

    /// Как можно раньше в didFinishLaunching.
    static func start() {
        // HTTP-кэш — только в памяти.
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        KingfisherManager.shared.defaultOptions += [.cacheSerializer(Linia2SealedImageSerializer())]
        DispatchQueue.global(qos: .utility).async {
            try? fm.removeItem(at: tmp.appendingPathComponent("l2play", isDirectory: true))
            BaseDb.purgeTrash()
            protectAll()
        }
        simulateUpgradeIfRequested()
    }

    /// При каждом выходе на экран: ключи (создать, если их ещё нет — телефон разблокирован), миграция.
    static func becameActive() {
        Linia2LaunchLog.shared.measure("vault-bootstrap") { _ = L2Vault.bootstrap() }
        Linia2LaunchLog.shared.measure("vault-prewarm") { L2Vault.prewarm() }
        migrateIfNeeded()
        dedupSubscriptionsIfNeeded()
    }

    /// LINIA2 (вылет 1013/1014: Topic.loadSubs на повторяющейся подписке): один раз за запуск, в фоне, через 8 с
    /// после выхода на экран — удалить дубли подписок и создать уникальный индекс (topic_id, user_id).
    private static var subsDedupScheduled = false
    private static func dedupSubscriptionsIfNeeded() {
        guard !subsDedupScheduled else { return }
        subsDedupScheduled = true
        migrationQueue.asyncAfter(deadline: .now() + 8) {
            let t0 = Date()
            let removed = BaseDb.sharedInstance.ensureUniqueSubscriptions()
            Linia2LaunchLog.shared.step("subs-dedup", ["removed": removed, "dur": Int(Date().timeIntervalSince(t0) * 1000)])
            if removed < 0 { DispatchQueue.main.async { subsDedupScheduled = false } }
        }
    }

    /// LINIA2 (баг 1006 «висит на логотипе» при первом запуске после обновления): миграция — в фоне, не раньше
    /// чем через 6 с после выхода на экран (сначала интерфейс, PIN, подключение), мелкими частями с паузами
    /// (BaseDb.encryptLegacyRows), без VACUUM на этом пути — он держал базу (и главный поток, читающий её) секундами.
    private static func migrateIfNeeded() {
        guard !(groupDefaults?.bool(forKey: kMigrated) ?? false), !migrating else {
            if Linia2TestProbe.migrated < 0, groupDefaults?.bool(forKey: kMigrated) ?? false { Linia2TestProbe.migrated = 1 }
            return
        }
        migrating = true
        Linia2TestProbe.migrated = 0
        migrationQueue.asyncAfter(deadline: .now() + 6) {
            defer { DispatchQueue.main.async { migrating = false } }
            Linia2LaunchLog.shared.step("migration-start")
            let t0 = Date()
            let ok = BaseDb.sharedInstance.encryptLegacyRows()
            Linia2LaunchLog.shared.step("migration-end", ["ok": ok ? 1 : 0, "dur": Int(Date().timeIntervalSince(t0) * 1000)])
            guard ok else { return }
            // Старый незашифрованный кэш файлов — удалить (перезагрузится с сервера).
            KingfisherManager.shared.cache.clearDiskCache()
            if let items = try? fm.contentsOfDirectory(at: roundDir, includingPropertiesForKeys: nil) {
                for f in items where f.pathExtension == "mp4" { try? fm.removeItem(at: f) }
            }
            try? fm.removeItem(at: caches.appendingPathComponent("linia2-urlcache"))
            URLCache.shared.removeAllCachedResponses()
            groupDefaults?.set(true, forKey: kMigrated)
            DispatchQueue.main.async { Linia2TestProbe.migrated = 1 }
            Cache.log.info("Linia2Storage: local store encrypted")
        }
    }

    /// Уход в фон: отложенный после миграции VACUUM (вне глаз пользователя, с фоновым заданием).
    static func didEnterBackground() {
        guard BaseDb.vacuumPending, !migrating else { return }
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "l2-vacuum") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        guard task != .invalid else { return }
        migrationQueue.async {
            BaseDb.sharedInstance.vacuum()
            BaseDb.vacuumPending = false
            DispatchQueue.main.async {
                if task != .invalid { app.endBackgroundTask(task); task = .invalid }
            }
        }
    }

    /// Только автотесты (-l2-uitest -l2-simulate-upgrade): база «как у старой версии» — открытый текст и
    /// флаг миграции снят; дальше запуск идёт как первый запуск после обновления.
    private static func simulateUpgradeIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-l2-uitest"), args.contains("-l2-simulate-upgrade") else { return }
        let n = BaseDb.sharedInstance.l2DebugDowngradeToPlaintext()
        groupDefaults?.set(false, forKey: kMigrated)
        Cache.log.info("Linia2Storage: TEST — simulated pre-encryption database (%d values)", n)
    }

    // MARK: - Каталоги

    /// Классы защиты и «не в резервную копию» для всех каталогов приложения (при запуске и после стирания).
    static func protectAll() {
        protect(documents, .completeUnlessOpen)
        protect(caches, .completeUnlessOpen)
        protect(tmp, .completeUntilFirstUserAuthentication)
        protect(kingfisherDir, .complete)
        protect(roundDir, .complete)
        protect(playDir, .complete)
    }

    @discardableResult
    private static func dir(_ u: URL, _ protection: FileProtectionType) -> URL {
        if !fm.fileExists(atPath: u.path) {
            try? fm.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
            protect(u, protection)
        }
        return u
    }

    /// Защита файлов iOS для каталога (новые файлы в нём наследуют класс) и «не в резервную копию».
    static func protect(_ u: URL, _ protection: FileProtectionType) {
        guard fm.fileExists(atPath: u.path) else { return }
        try? fm.setAttributes([.protectionKey: protection], ofItemAtPath: u.path)
        var url = u
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? url.setResourceValues(v)
    }

    // MARK: - Видео-кружки

    /// Готовый к проигрыванию файл кружка: расшифровать из кэша (или nil — кэша нет / ключ недоступен).
    static func roundPlayableFile(key: String) -> URL? {
        let name = key.replacingOccurrences(of: "/", with: "_")
        let play = playDir.appendingPathComponent(name + ".mp4")
        if fm.fileExists(atPath: play.path) { return play }
        let sealed = roundDir.appendingPathComponent(name + ".l2v")
        guard let blob = try? Data(contentsOf: sealed), let plain = L2Vault.openData(blob) else { return nil }
        return (try? plain.write(to: play, options: [.atomic, .completeFileProtection])) != nil ? play : nil
    }

    /// Сохранить кружок: в кэш — зашифрованным, для проигрывания — во временную папку.
    static func storeRound(key: String, data: Data) -> URL? {
        let name = key.replacingOccurrences(of: "/", with: "_")
        if let blob = L2Vault.sealData(data) {
            try? blob.write(to: roundDir.appendingPathComponent(name + ".l2v"), options: [.atomic, .completeFileProtection])
        }
        let play = playDir.appendingPathComponent(name + ".mp4")
        return (try? data.write(to: play, options: [.atomic, .completeFileProtection])) != nil ? play : nil
    }

    // MARK: - Очистка кэша (Настройки → Данные)

    /// LINIA2: база заменяется пустой (вход и ключи сохраняются), кэш картинок/файлов/кружков удаляется,
    /// Tinode пересоздаётся и переподключается в фоне — переписка загрузится заново. Только с главного потока.
    static func clearCache() {
        guard Thread.isMainThread else { DispatchQueue.main.async { clearCache() }; return }
        Cache.log.info("Linia2Storage: clearing local cache")
        L2Log.event("l2_clear_cache")
        BaseDb.wipeAndRecreate(keepAccount: true)
        Cache.resetForWipe()
        KingfisherManager.shared.cache.clearMemoryCache()
        KingfisherManager.shared.cache.clearDiskCache()
        URLCache.shared.removeAllCachedResponses()
        DispatchQueue.global(qos: .utility).async {
            removeContents(of: documents)
            removeContents(of: tmp)
            removeContents(of: caches.appendingPathComponent("l2round", isDirectory: true))
            BaseDb.purgeTrash()
            protect(documents, .completeUnlessOpen)
        }
        Linia2Root.window?.rootViewController = Linia2TabBarController.make()
        AppDelegate.connectInBackground(attempt: 0)
        UiUtils.showToast(message: "Кэш очищен")
    }

    // MARK: - Стирание (код паники)

    /// Синхронная часть (быстро, на главном потоке): то, что видно сразу.
    static func wipeVisibleNow() {
        KingfisherManager.shared.cache.clearMemoryCache()
        URLCache.shared.removeAllCachedResponses()
        let nc = UNUserNotificationCenter.current()
        nc.removeAllDeliveredNotifications()
        nc.removeAllPendingNotificationRequests()
        UIApplication.shared.applicationIconBadgeNumber = 0
        Linia2EndedCalls.reset()
        // Настройки, привязанные к чатам (имена топиков в ключах): самоуничтожение, срок хранения, гостевой звонок.
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where isChatScopedDefaultsKey(k) { d.removeObject(forKey: k) }
    }

    static func isChatScopedDefaultsKey(_ k: String) -> Bool {
        for p in ["linia2.burn2.", "linia2.burnat.", "linia2.ttl.", "linia2.guestcall.", "inputMessage"] where k.hasPrefix(p) { return true }
        return k.range(of: "(usr|grp|p2p|chn)[A-Za-z0-9_-]{6,}", options: .regularExpression) != nil
    }

    /// Файлы — в фоне (ключи к зашифрованному уже уничтожены). completion — на главном потоке.
    static func wipeFiles(completion: (() -> Void)? = nil) {
        // WKWebView и cookies — на главном.
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        KingfisherManager.shared.cache.clearDiskCache()
        DispatchQueue.global(qos: .userInitiated).async {
            removeContents(of: documents)
            removeContents(of: caches)
            removeContents(of: tmp)
            // Library: всё, кроме настроек (Preferences: тема, длина PIN) и Application Support (публичный
            // конфиг приложения и служебные файлы Firebase — без переписки).
            removeContents(of: library, keep: ["Preferences", "Application Support", "Caches"])
            if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId) {
                // Общий контейнер с расширением уведомлений: всё, кроме новой базы и настроек группы.
                removeContents(of: group, keep: ["database.sqlite", "database.sqlite-journal", "database.sqlite-wal",
                                                 "database.sqlite-shm", "Library"])
                removeContents(of: group.appendingPathComponent("Library", isDirectory: true), keep: ["Preferences"])
            }
            BaseDb.purgeTrash()
            protectAll()
            DispatchQueue.main.async { completion?() }
        }
    }

    private static func removeContents(of dir: URL, keep: Set<String> = []) {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        for u in items where !keep.contains(u.lastPathComponent) {
            try? fm.removeItem(at: u)
        }
    }

    // MARK: - Автотесты

    /// Сколько файлов переписки на устройстве (Documents, кэш картинок и кружков, tmp, общий контейнер).
    static func debugFileCount() -> Int {
        var n = 0
        func count(_ u: URL, skip: Set<String> = []) {
            guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [],
                                        errorHandler: nil) else { return }
            for case let f as URL in e {
                if skip.contains(where: { f.path.contains("/" + $0) }) { continue }
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
            }
        }
        count(documents)
        count(kingfisherDir)
        count(caches.appendingPathComponent("l2round", isDirectory: true))
        count(tmp, skip: ["com.apple", "WebKit"])
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId) {
            count(group, skip: ["database.sqlite", "Library/Preferences"])
        }
        return n
    }
}
