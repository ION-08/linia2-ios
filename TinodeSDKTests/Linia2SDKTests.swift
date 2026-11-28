//
//  Linia2SDKTests.swift
//  Линия 2.0: юнит-тесты SDK (вход, права доступа, диапазоны сообщений, текст сообщений).
//

import XCTest
import SQLite3
@testable import TinodeSDK

final class Linia2SDKTests: XCTestCase {

    // MARK: Вход по логину и паролю

    func testBasicTokenRoundTrip() throws {
        let token = try AuthScheme.encodeBasicToken(uname: "appreview", password: "Пароль-123")
        XCTAssertEqual(try AuthScheme.decodeBasicToken(token: token), ["appreview", "Пароль-123"])
    }

    func testBasicTokenRejectsColonInLogin() {
        XCTAssertThrowsError(try AuthScheme.encodeBasicToken(uname: "a:b", password: "x"))
    }

    func testBasicTokenRejectsGarbage() {
        XCTAssertThrowsError(try AuthScheme.decodeBasicToken(token: "не base64"))
    }

    // MARK: Права доступа к чату

    func testAccessModeFullRights() {
        let a = AcsHelper(str: "JRWPASDO")
        XCTAssertTrue(a.isJoiner)
        XCTAssertTrue(a.isReader)
        XCTAssertTrue(a.isWriter)
        XCTAssertTrue(a.isOwner)
    }

    func testAccessModeReadOnly() {
        let a = AcsHelper(str: "JR")
        XCTAssertTrue(a.isReader)
        XCTAssertFalse(a.isWriter)
        XCTAssertFalse(a.isOwner)
    }

    func testAccessModeNoneAndEmpty() {
        XCTAssertFalse(AcsHelper(str: "N").isReader)
        XCTAssertFalse(AcsHelper(str: "").isWriter)
        XCTAssertFalse(AcsHelper(str: nil).isJoiner)
    }

    // MARK: Диапазоны сообщений (удаление/история)

    func testMsgRangeCollapseOverlapping() {
        let r = MsgRange.collapse([MsgRange(low: 1, hi: 5), MsgRange(low: 3, hi: 8), MsgRange(low: 10, hi: 12)])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].lower, 1)
        XCTAssertEqual(r[0].upper, 8)
        XCTAssertEqual(r[1].lower, 10)
    }

    func testMsgRangeSingleId() {
        let r = MsgRange(id: 7)
        XCTAssertEqual(r.lower, 7)
        XCTAssertEqual(r.upper, 8)
    }

    // MARK: Текст сообщений

    func testDraftyPlainTextRussian() {
        let d = Drafty(plainText: "Привет! Проверка связи")
        XCTAssertEqual(d.txt, "Привет! Проверка связи")
        XCTAssertTrue(d.isPlain)
    }

    func testDraftyParseBoldKeepsText() {
        let d = Drafty.parse(content: "Это *важно*")
        XCTAssertEqual(d.txt, "Это важно")
        XCTAssertFalse(d.isPlain)
    }

    func testDraftyMultilineParse() {
        // Перенос строки хранится как пробел + стиль BR.
        let d = Drafty.parse(content: "Строка 1\nСтрока 2")
        XCTAssertEqual(d.txt, "Строка 1 Строка 2")
        XCTAssertFalse(d.isPlain)
    }

    // MARK: Подписки: дубли в локальной базе (вылет 1013/1014 в Topic.loadSubs)

    func testLoadSubsWithDuplicatesDoesNotCrash() {
        let store = Linia2SubsStoreStub()
        func mk(_ user: String?, _ updated: TimeInterval, read: Int) -> DefaultSubscription {
            let s = DefaultSubscription()
            s.user = user
            s.updated = Date(timeIntervalSince1970: updated)
            s.read = read
            return s
        }
        store.subs = [mk("usrA", 100, read: 1), mk("usrA", 200, read: 5), mk(nil, 300, read: 7),
                      mk("usrB", 100, read: 2), mk("usrA", 150, read: 3)]
        let topic = DefaultTopic(tinode: nil, name: "grpLinia2Dups")
        topic.store = store
        XCTAssertEqual(topic.loadSubs(), 2)
        XCTAssertEqual(topic.getSubscription(for: "usrA")?.read, 5, "остаётся самая свежая подписка")
        XCTAssertEqual(topic.getSubscription(for: "usrB")?.read, 2)
        XCTAssertEqual(topic.getSubscriptions()?.count, 2)
        withExtendedLifetime(store) {}
    }

    private func l2Exec(_ db: OpaquePointer?, _ sql: String) -> Int32 {
        return sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func l2Count(_ db: OpaquePointer?, _ sql: String) -> Int64 {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : -1
    }

    private func l2OpenSubsDb() -> (OpaquePointer?, String) {
        let path = NSTemporaryDirectory() + "l2subs-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        // Схема как в TinodiosDB (UserDb / SubscriberDb): индекс по topic_id, уникального ключа исторически нет.
        XCTAssertEqual(l2Exec(db, "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER, uid TEXT, updated TEXT, pub TEXT)"), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, "CREATE TABLE subscriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, topic_id INTEGER, user_id INTEGER, status INTEGER, mode TEXT, updated TEXT, read INTEGER, recv INTEGER, clear INTEGER, priv TEXT, last_seen TEXT, user_agent TEXT, subscription_class TEXT NOT NULL)"), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, "CREATE INDEX subscriptions_topic_id ON subscriptions (topic_id)"), SQLITE_OK)
        return (db, path)
    }

    /// Миграция: дубли (в т.ч. через задвоенную строку users с тем же uid) и подписки без user удаляются,
    /// остаётся самая свежая; затем уникальный индекс не даёт вставить дубль.
    func testSubscriptionsDedupMigrationKeepsNewest() {
        let (db, path) = l2OpenSubsDb()
        defer { sqlite3_close(db); try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(l2Exec(db, "INSERT INTO users (id, uid) VALUES (1, 'usrA'), (2, 'usrB'), (3, 'usrA')"), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, """
            INSERT INTO subscriptions (topic_id, user_id, updated, read, subscription_class) VALUES
            (10, 1, '2026-11-27T10:00:00.000', 1, 'S'),
            (10, 1, '2026-11-27T12:00:00.000', 5, 'S'),
            (10, 3, '2026-11-27T11:00:00.000', 3, 'S'),
            (10, 2, '2026-11-27T10:00:00.000', 2, 'S'),
            (11, 1, '2026-11-27T09:00:00.000', 9, 'S'),
            (10, NULL, '2026-11-27T13:00:00.000', 0, 'S'),
            (10, 99, '2026-11-27T13:00:00.000', 0, 'S')
            """), SQLITE_OK)
        XCTAssertEqual(l2Count(db, Linia2SubsSQL.hasUniqueIndex), 0)
        XCTAssertEqual(l2Exec(db, "BEGIN"), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, Linia2SubsSQL.deleteOrphans), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, Linia2SubsSQL.deleteDuplicates), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, Linia2SubsSQL.createUniqueIndex), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, "COMMIT"), SQLITE_OK)
        XCTAssertEqual(l2Count(db, Linia2SubsSQL.hasUniqueIndex), 1)
        XCTAssertEqual(l2Count(db, "SELECT count(*) FROM subscriptions"), 3)
        XCTAssertEqual(l2Count(db, "SELECT read FROM subscriptions s JOIN users u ON u.id = s.user_id WHERE topic_id = 10 AND u.uid = 'usrA'"), 5)
        XCTAssertEqual(l2Count(db, "SELECT count(*) FROM subscriptions WHERE topic_id = 11"), 1)
        XCTAssertNotEqual(l2Exec(db, "INSERT INTO subscriptions (topic_id, user_id, subscription_class) VALUES (10, 2, 'S')"), SQLITE_OK,
                          "уникальный индекс (topic_id, user_id) отвергает дубль")
    }

    /// Две (и больше) параллельные записи одной подписки — одна строка: поиск существующей по (топик, uid) и
    /// вставка в одной транзакции (как SubscriberDb.insert в точке сохранения SQLite.Connection).
    func testParallelSubscriptionInsertsProduceOneRow() {
        let (db, path) = l2OpenSubsDb()
        defer { sqlite3_close(db); try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(l2Exec(db, "INSERT INTO users (id, uid) VALUES (1, 'usrA')"), SQLITE_OK)
        XCTAssertEqual(l2Exec(db, Linia2SubsSQL.createUniqueIndex), SQLITE_OK)
        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            var c: OpaquePointer?
            guard sqlite3_open(path, &c) == SQLITE_OK else { lock.lock(); failures += 1; lock.unlock(); return }
            defer { sqlite3_close(c) }
            sqlite3_busy_timeout(c, 10_000)
            var ok = l2Exec(c, "BEGIN IMMEDIATE") == SQLITE_OK
            var st: OpaquePointer?
            var existing: Int64 = -1
            if ok, sqlite3_prepare_v2(c, Linia2SubsSQL.findExisting, -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_int64(st, 1, 10)
                sqlite3_bind_text(st, 2, "usrA", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(st) == SQLITE_ROW { existing = sqlite3_column_int64(st, 0) }
                sqlite3_finalize(st)
            } else { ok = false }
            if ok {
                let sql = existing > 0
                    ? "UPDATE subscriptions SET read = \(i) WHERE id = \(existing)"
                    : "INSERT INTO subscriptions (topic_id, user_id, read, subscription_class) VALUES (10, 1, \(i), 'S')"
                ok = l2Exec(c, sql) == SQLITE_OK && l2Exec(c, "COMMIT") == SQLITE_OK
            }
            if !ok { _ = l2Exec(c, "ROLLBACK"); lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(l2Count(db, "SELECT count(*) FROM subscriptions WHERE topic_id = 10 AND user_id = 1"), 1)
    }
}

/// Хранилище-заглушка: отдаёт заданный список подписок (как SqlStore.getSubscriptions при дублях в базе).
final class Linia2SubsStoreStub: Storage {
    var subs: [SubscriptionProto] = []
    var myUid: String?
    var deviceToken: String?
    var isReady: Bool { return true }
    func setMyUid(uid: String, credMethods: [String]?) { myUid = uid }
    func getSubscriptions(topic: TopicProto) -> [SubscriptionProto]? { return subs }
    func logout() {  }
    func deleteAccount(_ uid: String) {  }
    func setTimeAdjustment(adjustment: TimeInterval) {  }
    func topicGetAll(from tinode: Tinode?) -> [TopicProto]? { return nil }
    func topicGet(from tinode: Tinode?, withName name: String?) -> TopicProto? { return nil }
    func topicAdd(topic: TopicProto) -> Int64 { return 0 }
    func topicUpdate(topic: TopicProto) -> Bool { return false }
    func topicDelete(topic: TopicProto, hard: Bool) -> Bool { return false }
    func setRead(topic: TopicProto, read: Int) -> Bool { return false }
    func setRecv(topic: TopicProto, recv: Int) -> Bool { return false }
    func subAdd(topic: TopicProto, sub: SubscriptionProto) -> Int64 { return 0 }
    func subUpdate(topic: TopicProto, sub: SubscriptionProto) -> Bool { return false }
    func subNew(topic: TopicProto, sub: SubscriptionProto) -> Int64 { return 0 }
    func subDelete(topic: TopicProto, sub: SubscriptionProto) -> Bool { return false }
    func userGet(uid: String) -> UserProto? { return nil }
    func userAdd(user: UserProto) -> Int64 { return 0 }
    func userUpdate(user: UserProto) -> Bool { return false }
    func msgReceived(topic: TopicProto, sub: SubscriptionProto?, msg: MsgServerData?) -> Message? { return nil }
    func msgSend(topic: TopicProto, data: Drafty, head: [String: JSONValue]?) -> Message? { return nil }
    func msgDraft(topic: TopicProto, data: Drafty, head: [String: JSONValue]?) -> Message? { return nil }
    func msgDraftUpdate(topic: TopicProto, dbMessageId: Int64, data: Drafty) -> Bool { return false }
    func msgReady(topic: TopicProto, dbMessageId: Int64, data: Drafty) -> Bool { return false }
    func msgSyncing(topic: TopicProto, dbMessageId: Int64, sync: Bool) -> Bool { return false }
    func msgFailed(topic: TopicProto, dbMessageId: Int64) -> Bool { return false }
    func msgPruneFailed(topic: TopicProto) -> Bool { return false }
    func msgDiscard(topic: TopicProto, dbMessageId: Int64) -> Bool { return false }
    func msgDiscard(topic: TopicProto, seqId: Int) -> Bool { return false }
    func msgDelivered(topic: TopicProto, dbMessageId: Int64, timestamp: Date, seq: Int) -> Bool { return false }
    func msgMarkToDelete(topic: TopicProto, from idLo: Int, to idHi: Int, markAsHard: Bool) -> Bool { return false }
    func msgMarkToDelete(topic: TopicProto, ranges: [MsgRange]?, markAsHard: Bool) -> Bool { return false }
    func msgDelete(topic: TopicProto, delete id: Int, deleteFrom idLo: Int, deleteTo idHi: Int) -> Bool { return false }
    func msgDelete(topic: TopicProto, delete id: Int, deleteAllIn ranges: [MsgRange]?) -> Bool { return false }
    func msgRecvByRemote(sub: SubscriptionProto, recv: Int?) -> Bool { return false }
    func msgReadByRemote(sub: SubscriptionProto, read: Int?) -> Bool { return false }
    func getCachedMessagesRange(topic: TopicProto) -> MsgRange? { return nil }
    func msgIsCached(topic: TopicProto, ranges: [MsgRange]) -> [MsgRange] { return [] }
    func getMissingRanges(topic: TopicProto, startFrom: Int, pageSize: Int, newer: Bool) -> [MsgRange] { return [] }
    func getMessageById(dbMessageId: Int64) -> Message? { return nil }
    func getMessagePreviewById(dbMessageId: Int64) -> Message? { return nil }
    func getQueuedMessages(topic: TopicProto) -> [Message]? { return nil }
    func getQueuedMessageDeletes(topic: TopicProto, hard: Bool) -> [MsgRange]? { return nil }
    func getLatestMessagePreviews() -> [Message]? { return nil }
    func getMessagePage(topic: TopicProto, from: Int, limit: Int, forward: Bool) -> [Message]? { return nil }
    func getMessage(fromTopic topic: TopicProto, byEffectiveSeqId seqId: Int) -> Message? { return nil }
    func getAllMsgVersions(fromTopic topic: TopicProto, forSeq seqId: Int, limit: Int?) -> [Int]? { return nil }
}

// MARK: - LINIA2 (1019): транспорты (порядок, конфиг, переключение, long-polling)

final class Linia2TransportTests: XCTestCase {
    private let hosts = ["v2.chat-linia.site", "v2b.chat-linia.site"]

    func testDefaultOrderWsThenLpH3ThenLpForEachHost() {
        let r = Linia2TransportPlan.parse(nil, hosts: hosts).map { $0.id }
        XCTAssertEqual(r, ["ws://v2.chat-linia.site", "lp-h3://v2.chat-linia.site", "lp://v2.chat-linia.site",
                           "ws://v2b.chat-linia.site", "lp-h3://v2b.chat-linia.site", "lp://v2b.chat-linia.site"])
        XCTAssertEqual(Linia2TransportPlan.parse([], hosts: hosts).count, 6)
    }

    func testParseConfigOrderPortsAndInvalidEntries() {
        let spec: [[String: Any]] = [
            ["type": "lp-h3", "host": "V2.chat-linia.site"],
            ["type": "ws"],                                         // без адреса — первый из hosts
            ["type": "lp", "host": "bridge.example.ru", "port": 8443],
            ["type": "lp", "host": "bridge.example.ru", "port": 8443], // повтор
            ["type": "ftp", "host": "x.example.com"],              // неизвестный тип
            ["type": "ws", "host": "bad host"],                     // неверный адрес
            ["type": "ws", "host": "a.example.com", "port": 70000], // неверный порт
            ["type": "lp", "host": "off.example.com", "enabled": false],
            ["type": "lp-h3", "ip": "1.2.3.4", "host": "v2.chat-linia.site"], // по IP — не поддерживается
            ["type": "ws", "host": "v2b.chat-linia.site", "port": 443],      // 443 = без порта
        ]
        let r = Linia2TransportPlan.parse(spec, hosts: hosts).map { $0.id }
        XCTAssertEqual(r, ["lp-h3://v2.chat-linia.site", "ws://v2.chat-linia.site", "lp://bridge.example.ru:8443",
                           "ws://v2b.chat-linia.site"])
    }

    func testParseAllInvalidFallsBackToDefault() {
        let r = Linia2TransportPlan.parse([["type": "nope"], ["host": "x.example.com"]], hosts: hosts)
        XCTAssertEqual(r, Linia2TransportPlan.defaultRoutes(hosts: hosts))
    }

    func testRememberedRouteFirstWithin24h() {
        let base = Linia2TransportPlan.defaultRoutes(hosts: hosts)
        let lp = Linia2Route(kind: .lpH3, host: "v2.chat-linia.site")
        let now = Date()
        let o = Linia2TransportPlan.order(base, remembered: lp, rememberedAt: now.addingTimeInterval(-3600), maxAge: 86400, now: now)
        XCTAssertEqual(o.first, lp)
        XCTAssertEqual(o.count, base.count)
        XCTAssertEqual(o[1], base[0])
        // Старше 24 ч — встроенный порядок.
        let old = Linia2TransportPlan.order(base, remembered: lp, rememberedAt: now.addingTimeInterval(-90000), maxAge: 86400, now: now)
        XCTAssertEqual(old, base)
        // Маршрута нет в списке — без изменений.
        let gone = Linia2TransportPlan.order(base, remembered: Linia2Route(kind: .lp, host: "x.example.com"),
                                             rememberedAt: now, maxAge: 86400, now: now)
        XCTAssertEqual(gone, base)
    }

    func testRouteIdRoundTripAndURLs() {
        let r = Linia2Route(kind: .lp, host: "v2b.chat-linia.site", port: 8443)
        XCTAssertEqual(Linia2Route(id: r.id), r)
        XCTAssertNil(Linia2Route(id: "zz://host.example.com"))
        XCTAssertNil(Linia2Route(id: "ws://host.example.com:0"))
        XCTAssertEqual(r.url()?.absoluteString, "https://v2b.chat-linia.site:8443/v0/channels/lp")
        XCTAssertEqual(Linia2Route(kind: .ws, host: "v2.chat-linia.site").url()?.absoluteString, "wss://v2.chat-linia.site:443/v0/channels")
        XCTAssertEqual(Linia2Route(kind: .lpH3, host: "v2.chat-linia.site").url()?.absoluteString, "https://v2.chat-linia.site:443/v0/channels/lp")
    }

    func testNextRouteWrapsAround() {
        XCTAssertEqual(Linia2TransportPlan.next(after: 0, count: 6), 1)
        XCTAssertEqual(Linia2TransportPlan.next(after: 5, count: 6), 0)
        XCTAssertEqual(Linia2TransportPlan.next(after: 0, count: 0), 0)
    }

    func testTransportKindSynonyms() {
        XCTAssertEqual(Linia2TransportKind(config: "WSS"), .ws)
        XCTAssertEqual(Linia2TransportKind(config: "h3"), .lpH3)
        XCTAssertEqual(Linia2TransportKind(config: "longpoll"), .lp)
        XCTAssertNil(Linia2TransportKind(config: "vless"))
    }

    func testLongPollBodySplitsConcatenatedMessages() {
        let body = #"{"ctrl":{"id":"1","code":200}}{"data":{"content":"a}{b \"q\" ]","seq":3}} {"pres":{"what":"on"}}"#
        let parts = Linia2TransportPlan.splitMessages(Data(body.utf8))
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], #"{"ctrl":{"id":"1","code":200}}"#)
        XCTAssertTrue(parts[1].contains(#"a}{b \"q\" ]"#))
        XCTAssertEqual(parts[2], #"{"pres":{"what":"on"}}"#)
        XCTAssertEqual(Linia2TransportPlan.splitMessages(Data()).count, 0)
        // Кириллица и эмодзи — целиком.
        let ru = #"{"data":{"content":"Привет 👋"}}"#
        XCTAssertEqual(Linia2TransportPlan.splitMessages(Data(ru.utf8)), [ru])
    }

    func testSidParsing() {
        let d = Data(#"{"ctrl":{"params":{"sid":"RcRe3iNi3Qk"},"code":201,"text":"created"}}"#.utf8)
        XCTAssertEqual(Linia2LongPoll.parseSid(d), "RcRe3iNi3Qk")
        XCTAssertNil(Linia2LongPoll.parseSid(Data(#"{"ctrl":{"code":403}}"#.utf8)))
    }

    func testExpectsReply() {
        XCTAssertTrue(Linia2TransportPlan.expectsReply(Data(#"{"pub":{"id":"12345","topic":"usrX"}}"#.utf8)))
        XCTAssertFalse(Linia2TransportPlan.expectsReply(Data(#"{"note":{"topic":"usrX","what":"kp"}}"#.utf8)))
    }

    func testCallSignalDataMessageIsUrgentRegardlessOfTransport() {
        // Звонковая сигнализация — обычные {info what=call} в том же канале: по long-polling приходят теми же строками.
        let offer = #"{"info":{"topic":"usrA","from":"usrB","what":"call","event":"offer","seq":5,"payload":{}}}"#
        let parts = Linia2TransportPlan.splitMessages(Data((offer + offer).utf8))
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { Connection.isUrgentCallSignal($0) })
    }
}

/// Переключение маршрутов в Connection: WebSocket «заблокирован» (висит) → через таймаут — следующий маршрут.
final class Linia2ConnectionFailoverTests: XCTestCase {
    final class Listener: ConnectionListener {
        var routesTried: [String] = []
        var connected = false
        func onConnect(reconnecting: Bool, param: Any?) { connected = true }
        func onMessage(with message: String) {}
        func onDisconnect(isServerOriginated: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String) {}
        func onError(error: Error) {}
        func onRouteChanged() {}
    }

    func testBlockedWsSwitchesToNextRouteAfterTimeout() throws {
        Connection.linia2TestBlockWS = true
        let oldTimeout = Connection.linia2SwitchTimeout
        Connection.linia2SwitchTimeout = 1
        defer { Connection.linia2TestBlockWS = false; Connection.linia2SwitchTimeout = oldTimeout }
        // Адрес .invalid не резолвится: второй маршрут (lp) быстро падает — проверяем только порядок попыток.
        let routes = [Linia2Route(kind: .ws, host: "blocked.invalid"), Linia2Route(kind: .lp, host: "next.invalid")]
        let l = Listener()
        let c = Connection(open: URL(string: "wss://blocked.invalid/v0/channels")!, with: "key", notify: l, routes: routes)
        var tried: [String] = []
        let lock = NSLock()
        let prev = Tinode.linia2Event
        Tinode.linia2Event = { name, extra in
            if name == "route-try" || name == "route-fail" {
                lock.lock(); tried.append(name + ":" + ((extra["route"] as? String) ?? "")); lock.unlock()
            }
        }
        defer { Tinode.linia2Event = prev }
        try c.connect(reconnectAutomatically: true, withParam: nil)
        XCTAssertEqual(c.linia2RouteStatus?.route.kind, .ws)
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            lock.lock(); let done = tried.contains("route-try:lp://next.invalid"); lock.unlock()
            if done { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        c.disconnect()
        lock.lock(); let t = tried; lock.unlock()
        XCTAssertTrue(t.contains("route-fail:ws://blocked.invalid"), "заблокированный WebSocket не брошен по таймауту: \(t)")
        XCTAssertTrue(t.contains("route-try:lp://next.invalid"), "следующий маршрут (lp) не пробовали: \(t)")
    }

    func testSingleRouteKeepsOldBehaviour() throws {
        let l = Listener()
        let c = Connection(open: URL(string: "wss://v2.chat-linia.site/v0/channels")!, with: "key", notify: l)
        let st = c.linia2RouteStatus
        XCTAssertEqual(st?.route.kind, .ws)
        XCTAssertEqual(st?.count, 1)
        XCTAssertEqual(st?.index, 1)
    }
}
