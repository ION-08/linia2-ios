//
//  BaseDb.swift
//  ios
//
//  Copyright © 2019-2024 Tinode. All rights reserved.
//

import Foundation
import SQLite
import SQLite3
import TinodeSDK

public class BaseDb {
    // Current database schema version. Increment on schema changes.
    public static let kSchemaVersion: Int32 = 111

    // Object statuses. Values are incremented by 10 to make it easier to add new statuses.
    public enum Status: Int, Comparable {
        // Status undefined/not set.
        case undefined = 0
        // Object is not ready to be sent to the server.
        case draft = 10
        // Object is ready but not yet sent to the server.
        case queued = 20
        // Object is in the process of being sent to the server.
        case sending = 30
        // Sending failed
        case failed = 40
        // Object is received by the server.
        case synced = 50
        // Object is hard-deleted.
        case deletedHard = 60
        // Object is soft-deleted.
        case deletedSoft = 70
        // Object is a deletion range marker synchronized with the server.
        case deletedSynced = 80

        public static func < (lhs: BaseDb.Status, rhs: BaseDb.Status) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    // Meta-status: object should be visible in the UI.
    public static let kStatusVisible = Status.synced

    public static let kBundleId = "info.codix.liniya2.db"
    public static let kAppGroupId = "group." + BaseDb.kBundleId
    // No direct access to the shared instance.
    private static var `default`: BaseDb?
    private static let accessQueue = DispatchQueue(label: BaseDb.kBundleId)
    var db: SQLite.Connection?
    private let pathToDatabase: String
    public var sqlStore: SqlStore?
    public var topicDb: TopicDb?
    public var accountDb: AccountDb?
    public var subscriberDb: SubscriberDb?
    public var userDb: UserDb?
    public var messageDb: MessageDb?

    var account: StoredAccount?
    var isCredValidationRequired: Bool {
        return !(self.account?.credMethods?.isEmpty ?? true)
    }
    public var isReady: Bool {
        return self.account != nil && !self.isCredValidationRequired
    }

    internal static let log = TinodeSDK.Log(subsystem: BaseDb.kBundleId)

    /// The init is private to ensure that the class is a singleton.
    private init() {
        var documentsDirectory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId)!.absoluteString
        if documentsDirectory.last! != "/" {
            documentsDirectory.append("/")
        }
        self.pathToDatabase = documentsDirectory.appending("database.sqlite")

        do {
            self.db = try SQLite.Connection(self.pathToDatabase)
            // LINIA2: базу одновременно открывает расширение уведомлений (каждый push) — без ожидания
            // занятая база сразу давала SQLITE_BUSY, а try! ниже (создание таблиц) — вылет при запуске.
            self.db?.busyTimeout = 3
            // LINIA2: удалённые записи затираются нулями (а не остаются в свободных страницах файла).
            try self.db?.execute("PRAGMA secure_delete = ON")
        } catch {
            BaseDb.log.error("BaseDb - init failed: %@", error.localizedDescription)
        }
        assert(self.db != nil)
        BaseDb.excludeFromBackup()

        self.sqlStore = SqlStore(dbh: self)
    }

    private func initDb() {
        BaseDb.log.info("Initializing local store.")
        self.accountDb = AccountDb(self.db!)
        self.userDb = UserDb(self.db!, baseDb: self)
        self.topicDb = TopicDb(self.db!, baseDb: self)
        self.subscriberDb = SubscriberDb(self.db!, baseDb: self)
        self.messageDb = MessageDb(self.db!, baseDb: self)

        var account: StoredAccount? = nil
        var deviceToken: String? = nil
        // LINIA2: версия схемы не прочиталась (база занята другим процессом) — это не «схема изменилась»:
        // раньше в этом случае база удалялась целиком (и падала на try! при удалении таблиц).
        var version: Int32? = self.db!.userVersion
        for _ in 0..<3 where version == nil {
            Thread.sleep(forTimeInterval: 0.2)
            version = self.db!.userVersion
        }
        if let v = version, v != BaseDb.kSchemaVersion {
            BaseDb.log.info("BaseDb - schema has changed from %d to %d", (self.db?.userVersion ?? -1), BaseDb.kSchemaVersion)

            // Retain active account accross DB upgrades to keep user logged in.
            account = self.accountDb!.getActiveAccount()
            deviceToken = self.accountDb!.getDeviceToken()

            // Schema has changed, delete database.
            self.dropDb()
            self.db!.userVersion = BaseDb.kSchemaVersion
        }

        BaseDb.log.info("Creating SQLite db tables.")
        self.accountDb!.createTable()
        self.userDb!.createTable()
        self.topicDb!.createTable()
        self.subscriberDb!.createTable()
        self.messageDb!.createTable()
        // Enable foreign key enforcement.
        try! self.db!.run("PRAGMA foreign_keys = ON")

        if let account = account {
            _ = self.accountDb!.addOrActivateAccount(for: account.uid, withCredMethods: account.credMethods)
            self.accountDb!.saveDeviceToken(token: deviceToken)
        }
        self.account = self.accountDb!.getActiveAccount()

        // LINIA2: ключи шифрования хранилища (создаёт только приложение). Ключи новые, а в базе уже есть
        // зашифрованные записи (ключи пропали: восстановление на другом устройстве, сброс Keychain) — их не
        // прочитать: очищаем кэш (вход сохраняется), Tinode заново загрузит чаты с сервера.
        // Первый запуск версии с шифрованием (ключей не было никогда) — это миграция, кэш не трогаем.
        let keysExistedBefore = L2Vault.everCreated
        if L2Vault.isAppProcess, L2Vault.bootstrap() == .created, keysExistedBefore, self.hasEncryptedRows() {
            BaseDb.log.info("BaseDb - encryption keys were recreated, dropping unreadable cache")
            self.clearCacheKeepingAccount()
        }
    }

    private func clearSequences() {
        let table = Table("sqlite_sequence")
        try! self.db!.run(table.delete())
    }

    private func clearDb() {
        BaseDb.log.info("Clearing local store (SQLite db).")
        try! self.db!.transaction {
            self.messageDb?.truncateTable()
            self.subscriberDb?.truncateTable()
            self.topicDb?.truncateTable()
            self.userDb?.truncateTable()
            self.accountDb?.truncateTable()
            self.clearSequences()
        }
    }

    private func dropDb() {
        BaseDb.log.info("Dropping local store (SQLite db).")
        self.messageDb?.destroyTable()
        self.subscriberDb?.destroyTable()
        self.topicDb?.destroyTable()
        self.userDb?.destroyTable()
        self.accountDb?.destroyTable()
    }

    public static var sharedInstance: BaseDb {
        return BaseDb.accessQueue.sync {
            if let instance = BaseDb.default {
                return instance
            }
            let instance = BaseDb()
            BaseDb.default = instance
            instance.initDb()
            return instance
        }
    }
    func isMe(uid: String?) -> Bool {
        guard let uid = uid, let acctUid = BaseDb.sharedInstance.uid else { return false }
        return uid == acctUid
    }
    var uid: String? {
        return self.account?.uid
    }
    func setUid(uid: String?, credMethods: [String]?) {
        guard let uid = uid else {
            self.account = nil
            return
        }
        do {
            if self.account != nil {
                try self.accountDb?.deactivateAll()
            }
            self.account = self.accountDb?.addOrActivateAccount(for: uid, withCredMethods: credMethods)
        } catch {
            BaseDb.log.error("BaseDb - setUid failed %@", error.localizedDescription)
            self.account = nil
        }
    }
    public func logout() {
        // Drop database altogether.
        // Db will be recreated when the user logs back in.
        //
        // Data can also be retained by deactivating the account:
        //
        // _ = try? self.accountDb?.deactivateAll()
        // self.setUid(uid: nil, credMethods: nil)
        BaseDb.accessQueue.sync {
            self.setUid(uid: nil, credMethods: nil)
            self.clearDb()
            BaseDb.default = nil
        }
    }

    public func deleteUid(_ uid: String) -> Bool {
        var acc: StoredAccount?
        if self.uid == uid {
            acc = self.account
            self.account = nil
        } else {
            acc = self.accountDb?.getByUid(uid: uid)
        }
        guard let acc2 = acc else {
            BaseDb.log.error("Could not find account for uid [%@]", uid)
            return false
        }
        let savepointName = "BaseDb.deleteUid"
        do {
            try self.db?.savepoint(savepointName) {
                if !(self.topicDb?.deleteAll(forAccount: acc2.id) ?? true) {
                    BaseDb.log.error("Failed to clear topics/messages/subscribers for account id [%lld]", acc2.id)
                }
                if !(self.userDb?.delete(forAccount: acc2.id) ?? true) {
                    BaseDb.log.error("Failed to clear users for account id [%lld]", acc2.id)
                }
                if !(self.accountDb?.delete(accountId: acc2.id) ?? true) {
                    BaseDb.log.error("Failed to delete account for id [%lld]", acc2.id)
                }
            }
        } catch {
            // Explicitly releasing savepoint since ROLLBACK TO (SQLite.swift behavior) won't release the savepoint transaction.
            self.db?.releaseSavepoint(withName: savepointName)
            BaseDb.log.error("BaseDb - deleteUid operation failed: uid = %@, error = %@", uid, error.localizedDescription)
            return false
        }
        return true
    }

    public static func updateCounter(db: SQLite.Connection, table: Table,
                                     usingIdColumn idColumn: SQLite.Expression<Int64>, forId id: Int64,
                                     in column: SQLite.Expression<Int?>, with value: Int) -> Bool {
        let record = table.filter(idColumn == id && column < value)
        do {
            return try db.run(record.update(column <- value)) > 0
        } catch {
            if let result = error as? Result {
                // Skip logging "success" errors: they just mean the row was not found and some such.
                switch result {
                case let .error(_, code, _):
                    if code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW {
                        return false
                    }
                default:
                    break
                }
            }
            BaseDb.log.error("BaseDb - updateCounter failed %@", error.localizedDescription)
            return false
        }
    }
}

// Database schema versioning.
extension SQLite.Connection {
    public var schemaVersion: Int32 {
        get { return Int32((try? scalar("PRAGMA user_version") as? Int64) ?? -1) }
        set { try! run("PRAGMA user_version = \(newValue)") }
    }

    /// Releases a savepoint explicitly.
    public func releaseSavepoint(withName savepointName: String) {
        do {
            try self.execute("RELEASE '\(savepointName)'")
        } catch {
            BaseDb.log.error("BaseDb - failed to release savepoint %@: %@", savepointName, error.localizedDescription)
        }
    }
}

// MARK: - LINIA2: шифрование, миграция, криптоудаление

extension BaseDb {
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId)
    }
    static let kDbFileName = "database.sqlite"

    /// Файлы базы — не в резервную копию iCloud/компьютера (ключи *ThisDeviceOnly туда всё равно не попадают)
    /// и с защитой iOS CompleteUntilFirstUserAuthentication: базу открывают на ЗАБЛОКИРОВАННОМ телефоне
    /// расширение уведомлений (каждый push — запись сообщения, имя отправителя) и приложение при входящем
    /// звонке (CallKit/PushKit: имя звонящего, запись о звонке). С классом Complete эти записи падали бы
    /// (SQLITE_IOERR / «файл недоступен»), а уведомления и звонки — без имени. Содержимое строк при этом
    /// зашифровано L2Vault (содержимое сообщений — ключом WhenUnlockedThisDeviceOnly либо на открытый ключ),
    /// так что «после первой разблокировки» открыт только шифротекст. Общий контейнер целиком — тоже не в копию.
    static func excludeFromBackup() {
        guard let dir = containerURL else { return }
        let fm = FileManager.default
        func exclude(_ url: URL) {
            var u = url
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        }
        exclude(dir)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let u = dir.appendingPathComponent(kDbFileName + suffix)
            guard fm.fileExists(atPath: u.path) else { continue }
            exclude(u)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: u.path)
        }
    }

    private func hasEncryptedRows() -> Bool {
        guard let db = self.db else { return false }
        let sql = "SELECT (SELECT count(*) FROM \(MessageDb.kTableName) WHERE substr(content,1,5) IN ('l2c1:','l2p1:')" +
            " OR substr(head,1,5) IN ('l2m1:','l2m1w')) + (SELECT count(*) FROM \(TopicDb.kTableName) WHERE substr(pub,1,5) = 'l2m1:')"
        guard let v = try? db.scalar(sql), let n = v as? Int64 else { return false }
        return n > 0
    }

    /// Очистить все таблицы, кроме учётной записи (вход и токен устройства сохраняются).
    private func clearCacheKeepingAccount() {
        let account = self.account
        let deviceToken = self.accountDb?.getDeviceToken()
        clearDb()
        if let a = account {
            _ = self.accountDb?.addOrActivateAccount(for: a.uid, withCredMethods: a.credMethods)
            self.accountDb?.saveDeviceToken(token: deviceToken)
        }
        self.account = self.accountDb?.getActiveAccount()
    }

    /// Миграция при первом запуске версии с шифрованием: открытые значения зашифровываются на месте
    /// (сравнение со старым значением — параллельная запись Tinode не затирается), затем VACUUM
    /// убирает открытый текст из свободных страниц файла. Данные не теряются: незашифрованное читается
    /// как есть, пока миграция не дошла до этой строки. Возвращает true, если всё зашифровано.
    /// LINIA2 (баг 1006 «висит на логотипе»): частями по `batch` записей с паузой `pause` между частями —
    /// каждая часть — короткая транзакция, между ними база свободна для главного потока и Tinode. VACUUM здесь
    /// больше не выполняется (держал базу секундами при первом запуске после обновления) — его делает
    /// приложение при уходе в фон (`vacuumPending`).
    public func encryptLegacyRows(batch: Int = 50, pause: TimeInterval = 0.04) -> Bool {
        guard let db = self.db, L2Vault.metaKeyAvailable, L2Vault.contentKeyAvailable else { return false }
        let jobs: [(table: String, column: String, content: Bool)] = [
            (MessageDb.kTableName, "content", true), (MessageDb.kTableName, "head", false),
            (TopicDb.kTableName, "pub", false), (TopicDb.kTableName, "priv", false),
            (UserDb.kTableName, "pub", false), (SubscriberDb.kTableName, "priv", false),
        ]
        var total = 0
        for job in jobs {
            let select = "SELECT id, \(job.column) FROM \(job.table) WHERE \(job.column) IS NOT NULL AND " +
                "substr(\(job.column),1,5) NOT IN ('l2c1:','l2p1:','l2m1:','l2m1w') LIMIT \(max(1, batch))"
            let update = "UPDATE \(job.table) SET \(job.column) = ? WHERE id = ? AND \(job.column) = ?"
            while true {
                var batch: [(Int64, String)] = []
                do {
                    for row in try db.prepare(select) {
                        if let id = row[0] as? Int64, let v = row[1] as? String { batch.append((id, v)) }
                    }
                } catch {
                    BaseDb.log.error("BaseDb - migration select failed: %@", error.localizedDescription)
                    return false
                }
                if batch.isEmpty { break }
                var changed = 0
                do {
                    try db.transaction {
                        for (id, v) in batch {
                            guard let enc = job.content ? L2Vault.sealContent(v) : L2Vault.sealMeta(v), enc != v else { continue }
                            try db.run(update, enc, id, v)
                            changed += db.changes
                        }
                    }
                } catch {
                    BaseDb.log.error("BaseDb - migration update failed: %@", error.localizedDescription)
                    return false
                }
                // Ничего не зашифровалось (ключ стал недоступен) — не крутиться, повторим при следующем запуске.
                if changed == 0 { return false }
                total += changed
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            }
        }
        if total > 0 { BaseDb.vacuumPending = true }
        BaseDb.log.info("BaseDb - migration: %d values encrypted", total)
        return true
    }

    /// После миграции: сжать файл (VACUUM) при ближайшем уходе приложения в фон.
    public static var vacuumPending: Bool {
        get { UserDefaults(suiteName: BaseDb.kAppGroupId)?.bool(forKey: "linia2.vault.vacuumPending") ?? false }
        set { UserDefaults(suiteName: BaseDb.kAppGroupId)?.set(newValue, forKey: "linia2.vault.vacuumPending") }
    }

    /// Только автотесты: «база старой версии» — зашифрованные значения переписываются открытым текстом
    /// (как до версии с шифрованием). Возвращает число изменённых значений.
    public func l2DebugDowngradeToPlaintext() -> Int {
        guard let db = self.db else { return 0 }
        let jobs: [(table: String, column: String, content: Bool)] = [
            (MessageDb.kTableName, "content", true), (MessageDb.kTableName, "head", false),
            (TopicDb.kTableName, "pub", false), (TopicDb.kTableName, "priv", false),
            (UserDb.kTableName, "pub", false), (SubscriberDb.kTableName, "priv", false),
        ]
        var total = 0
        for job in jobs {
            var rows: [(Int64, String)] = []
            do {
                for row in try db.prepare("SELECT id, \(job.column) FROM \(job.table) WHERE \(job.column) IS NOT NULL") {
                    if let id = row[0] as? Int64, let v = row[1] as? String { rows.append((id, v)) }
                }
                try db.transaction {
                    for (id, v) in rows {
                        guard let plain = job.content ? L2Vault.openContent(v) : L2Vault.openMeta(v), plain != v else { continue }
                        try db.run("UPDATE \(job.table) SET \(job.column) = ? WHERE id = ?", plain, id)
                        total += db.changes
                    }
                }
            } catch {
                BaseDb.log.error("BaseDb - test downgrade failed: %@", error.localizedDescription)
            }
        }
        return total
    }

    /// Сжать файл (после стирания/миграции): VACUUM переписывает базу без свободных страниц.
    public func vacuum() {
        try? self.db?.execute("VACUUM")
    }

    /// КОД ПАНИКИ: база заменяется новой пустой (учётная запись и токен устройства переносятся — вход
    /// не теряется). Старые файлы сразу переименовываются (мгновенно, без долгого DELETE) и стираются
    /// в фоне: ключи к ним к этому моменту уже уничтожены (L2Vault.destroyKeys), содержимое не прочитать.
    /// keepAccount = false — без учётной записи (выход из аккаунта).
    public static func wipeAndRecreate(keepAccount: Bool) {
        var trash: URL?
        accessQueue.sync {
            let old = BaseDb.default
            let account = keepAccount ? old?.account : nil
            let deviceToken = keepAccount ? old?.accountDb?.getDeviceToken() : nil
            BaseDb.default = nil
            // Старый экземпляр больше ничего не читает и не пишет: SqlStore старого Tinode обращается к таблицам
            // через dbh?.messageDb? — после обнуления getQueuedMessages и т.п. возвращают nil, т.е. неотправленные
            // сообщения (outbox) старой базы не будут отправлены, даже если старый Tinode ещё успеет подключиться.
            // Соединение SQLite закрывается вместе с последней ссылкой на него.
            old?.messageDb = nil
            old?.subscriberDb = nil
            old?.topicDb = nil
            old?.userDb = nil
            old?.accountDb = nil
            old?.db = nil
            if let dir = containerURL {
                let t = dir.appendingPathComponent("l2trash", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
                for suffix in ["", "-journal", "-wal", "-shm"] {
                    let src = dir.appendingPathComponent(kDbFileName + suffix)
                    guard FileManager.default.fileExists(atPath: src.path) else { continue }
                    if (try? FileManager.default.moveItem(at: src, to: t.appendingPathComponent(kDbFileName + suffix))) == nil {
                        try? FileManager.default.removeItem(at: src)
                    }
                }
                trash = t
            }
            let instance = BaseDb()
            BaseDb.default = instance
            instance.initDb()
            if let a = account {
                _ = instance.accountDb?.addOrActivateAccount(for: a.uid, withCredMethods: a.credMethods)
                instance.accountDb?.saveDeviceToken(token: deviceToken)
                instance.account = instance.accountDb?.getActiveAccount()
            }
        }
        if trash != nil { DispatchQueue.global(qos: .utility).async { purgeTrash() } }
    }

    /// Стереть переименованные старые базы (в т.ч. оставшиеся от прерванного стирания).
    public static func purgeTrash() {
        guard let dir = containerURL?.appendingPathComponent("l2trash", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Только для автотестов (-l2-uitest): сколько записей в базе.
    public func l2DebugCounts() -> [String: Int] {
        guard let db = self.db else { return [:] }
        func n(_ sql: String) -> Int {
            guard let v = try? db.scalar(sql), let i = v as? Int64 else { return -1 }
            return Int(i)
        }
        return [
            "msgs": n("SELECT count(*) FROM \(MessageDb.kTableName) WHERE content IS NOT NULL AND status <= \(BaseDb.Status.synced.rawValue)"),
            "plain": n("SELECT count(*) FROM \(MessageDb.kTableName) WHERE content IS NOT NULL AND substr(content,1,5) NOT IN ('l2c1:','l2p1:')"),
            "topics": n("SELECT count(*) FROM \(TopicDb.kTableName) WHERE topic NOT IN ('me','fnd','sys')"),
            "users": n("SELECT count(*) FROM \(UserDb.kTableName)"),
            "subs": n("SELECT count(*) FROM \(SubscriberDb.kTableName)"),
            // Неотправленные (outbox): черновик / в очереди / отправляется / ошибка.
            "queued": n("SELECT count(*) FROM \(MessageDb.kTableName) WHERE status IN (\(Status.draft.rawValue),\(Status.queued.rawValue),\(Status.sending.rawValue),\(Status.failed.rawValue))"),
        ]
    }

    /// Только для автотестов: скопировать файлы базы (как это сделал бы злоумышленник до стирания).
    public static func l2DebugCopyDbFiles(to dir: URL) -> Int {
        guard let src = containerURL else { return 0 }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        accessQueue.sync {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let u = src.appendingPathComponent(kDbFileName + suffix)
                guard fm.fileExists(atPath: u.path) else { continue }
                if (try? fm.copyItem(at: u, to: dir.appendingPathComponent(kDbFileName + suffix))) != nil { n += 1 }
            }
        }
        return n
    }

    /// Только для автотестов: открыть сохранённую копию базы и попытаться прочитать её ТЕКУЩИМИ ключами.
    /// rows — значений (содержимое/заголовки сообщений, pub/priv чатов и пользователей) в копии;
    /// plain — из них без шифрования; read — расшифровано текущими ключами (после стирания должно быть 0).
    public static func l2DebugReadCopy(at dir: URL) -> [String: Int] {
        let path = dir.appendingPathComponent(kDbFileName).path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? SQLite.Connection(path, readonly: true) else { return ["rows": -1, "plain": -1, "read": -1] }
        var rows = 0, plain = 0, read = 0
        let jobs: [(String, String, Bool)] = [
            (MessageDb.kTableName, "content", true), (MessageDb.kTableName, "head", false),
            (TopicDb.kTableName, "pub", false), (TopicDb.kTableName, "priv", false),
            (UserDb.kTableName, "pub", false), (SubscriberDb.kTableName, "priv", false),
        ]
        for (table, col, content) in jobs {
            guard let stmt = try? db.prepare("SELECT \(col) FROM \(table) WHERE \(col) IS NOT NULL") else { continue }
            for row in stmt {
                guard let v = row[0] as? String, !v.isEmpty else { continue }
                rows += 1
                let enc = v.hasPrefix(L2Vault.pContent) || v.hasPrefix(L2Vault.pPub) || v.hasPrefix(L2Vault.pMeta) || v.hasPrefix(L2Vault.pMetaCall)
                if !enc { plain += 1; continue }
                let out = content ? L2Vault.openContent(v) : L2Vault.openMeta(v)
                if let o = out, o != v { read += 1 }
            }
        }
        return ["rows": rows, "plain": plain, "read": read]
    }
}
