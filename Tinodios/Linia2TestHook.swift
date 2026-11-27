//
//  Linia2TestHook.swift
//  Линия 2.0: тестовый крючок — ТОЛЬКО под -l2-uitest (в обычном запуске не создаётся).
//
//  Невидимый элемент «l2.test.state» (окно 4×4 в углу, не принимает касаний); его accessibilityValue —
//  счётчики, которые XCUITest читает до и после стирания:
//    msgs  — сообщений с содержимым в базе;  plain — из них незашифрованных;  topics — чатов в базе;
//    chats — чатов в списке;  users, subs — записей пользователей/подписок;  files — файлов переписки;
//    notif — доставленных уведомлений;  pend — неотправленных отчётов;  cfg — есть код;  keys — ключ доступен;
//    pinms — время ответа экрана PIN на последний ввод;  wipes — стираний в этом запуске;  kdf — scrypt по RFC 7914.
//  Баг 1006: vpush/vdup/vign/vshown/vstep — VoIP push (всего / повтор того же звонка / отброшен / показан входящий /
//    шаг сценария L2_TEST_VOIP_REPLAY); ui — мс от запуска до интерфейса; lost — показов «Связь потеряна»;
//    conn — вошли на сервер; mig — миграция базы (−1 не нужна, 0 идёт, 1 готово).
//  Код паники: queued — неотправленных (outbox) в базе; oldf — файлов, оставшихся от состояния до стирания;
//    copyrows/copyplain/copyread — копия базы, снятая перед стиранием: значений / открытых / прочитанных новым ключом.
//    «l2.test.tree» — дерево файлов (Documents, Library, Caches, tmp, App Group) до и после.
//  L2_TEST_OUTBOX=текст — перед стиранием положить в очередь отправки неотправленное сообщение (не должно уйти).
//  L2_TEST_UNREACHABLE=N — «сервер недоступен» первые N с после запуска (подключение не идёт), затем — как обычно.
//  L2_TEST_VOIP_REPLAY=1 — после входа (PIN пройден): payload VoIP push «started» по звонку topic+seq → повтор →
//    «hang-up» → снова «started» с тем же topic+seq (повтор после завершения) → «started» устаревший (ts −120 с).
//  -l2-simulate-upgrade — база «старой версии» (открытый текст) и снятый флаг миграции (Linia2Storage).
//  Окружение: L2_TEST_SEED=1 — положить тестовые файлы (Documents, кэш кружков, общий контейнер) и локальное
//  уведомление, чтобы проверить, что стирание их убирает.
//

import UIKit
import UserNotifications
import TinodeSDK
import TinodiosDB

final class Linia2TestHookView: UIView {
    override var accessibilityValue: String? {
        get { Linia2TestHook.state() }
        set {}
    }
}

/// «l2.test.tree» — дерево файлов контейнера до и после стирания (для вложения в отчёт теста).
final class Linia2TestTreeView: UIView {
    override var accessibilityValue: String? {
        get { Linia2TestHook.treeReport() }
        set {}
    }
}

enum Linia2TestHook {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-l2-uitest") }
    private static var window: UIWindow?
    private static var delivered = 0
    private static var kdfOK = -1
    private static var voipStep = 0

    /// До подключения (в начале didFinishLaunching).
    static func applyLaunchOverrides() {
        guard enabled else { return }
        if let n = ProcessInfo.processInfo.environment["L2_TEST_UNREACHABLE"].flatMap({ Double($0) }), n > 0 {
            Connection.linia2StartupBlockedUntil = Date().addingTimeInterval(n)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + n + 0.2) {
                Cache.tinode.reconnectNow(interactively: true, reset: false)
            }
        }
    }

    static func install() {
        guard enabled else { return }
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        w.windowLevel = .alert + 50
        w.isUserInteractionEnabled = false
        let vc = UIViewController()
        let v = Linia2TestHookView(frame: w.bounds)
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "l2.test.state"
        v.accessibilityLabel = "test-state"
        v.backgroundColor = .clear
        let tv = Linia2TestTreeView(frame: w.bounds)
        tv.isAccessibilityElement = true
        tv.accessibilityIdentifier = "l2.test.tree"
        tv.accessibilityLabel = "test-tree"
        tv.backgroundColor = .clear
        let box = UIView(frame: w.bounds)
        box.backgroundColor = .clear
        box.addSubview(v)
        box.addSubview(tv)
        vc.view = box
        w.rootViewController = vc
        w.isHidden = false
        window = w
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            UNUserNotificationCenter.current().getDeliveredNotifications { list in
                DispatchQueue.main.async { delivered = list.count }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            let ok = L2Scrypt.selfTest()
            DispatchQueue.main.async { kdfOK = ok ? 1 : 0 }
        }
        if ProcessInfo.processInfo.environment["L2_TEST_SEED"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { seed() }
        }
        if ProcessInfo.processInfo.environment["L2_TEST_VOIP_REPLAY"] == "1" {
            waitThenReplayVoip()
        }
        if bgAnswer { keepAliveInBackground() }
        if ProcessInfo.processInfo.environment["L2_TEST_PATH_STORM"] == "1" {
            // Шторм смены сети (вылет 1013 на 5G): с запуска 30 с, каждые 200 мс, ws ping включён принудительно.
            Linia2Failover.testForcePing = true
            DispatchQueue.main.async { Linia2Failover.shared.linia2TestPathStorm(seconds: 30) }
        }
    }

    /// L2_TEST_BG_ANSWER=1 — «ответ из фона»: в симуляторе нет CallKit и VoIP push, поэтому входящий, пришедший,
    /// когда приложение не активно, принимается сразу (как «Ответить» CallKit на заблокированном экране,
    /// CallManager.displayIncomingCall), а процесс в фоне держится фоновой задачей (~30 с; на iPhone будит PushKit).
    static var bgAnswer: Bool { enabled && ProcessInfo.processInfo.environment["L2_TEST_BG_ANSWER"] == "1" }
    private static var bgTask: UIBackgroundTaskIdentifier = .invalid

    private static func keepAliveInBackground() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            guard bgTask == .invalid else { return }
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "l2-uitest-bg") {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            guard bgTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    /// Ждём интерфейс (вкладки) и снятый PIN, затем — сценарий повторного VoIP push.
    private static func waitThenReplayVoip() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard Linia2TestProbe.uiReadyMs >= 0, !Linia2AppLock.shared.isLocked else { return waitThenReplayVoip() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { replayVoip() }
        }
    }

    /// Payload — как от linia2-auth (AppDelegate.pushRegistry → CallManager.handleVoipPush).
    private static func push(_ event: String, topic: String, seq: Int, sentAt: Date) {
        Cache.callManager.handleVoipPush(event: event, topic: topic, from: topic, seq: seq, audioOnly: true,
                                         callerName: "Тестовый звонок", sentAt: sentAt) {}
    }

    private static func replayVoip() {
        let topic = "usrL2TestVoip01"   // нет такого пользователя: звонок только локальный
        let seq = 900_000 + Int.random(in: 0..<99_999)
        let steps: [(TimeInterval, () -> Void)] = [
            (0, { push("started", topic: topic, seq: seq, sentAt: Date()) }),            // 1: входящий показан
            (2, { push("started", topic: topic, seq: seq, sentAt: Date()) }),            // 2: повтор — без нового показа
            (4, { push("hang-up", topic: topic, seq: seq, sentAt: Date()) }),            // 3: отбой — входящий закрыт
            (7, { push("started", topic: topic, seq: seq, sentAt: Date()) }),            // 4: тот же звонок после конца
            (9, { push("started", topic: topic, seq: seq + 1, sentAt: Date().addingTimeInterval(-120)) }),  // 5: устаревший
            (11, { }),                                                                    // 6: готово
        ]
        for (i, st) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + st.0) {
                st.1()
                voipStep = i + 1
            }
        }
    }

    private static func seed() {
        let blob = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try? blob.write(to: Linia2Storage.documents.appendingPathComponent("l2-test-attachment.bin"))
        _ = Linia2Storage.storeRound(key: "l2-test-round", data: blob)
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId) {
            try? blob.write(to: g.appendingPathComponent("l2-test-shared.bin"))
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized else { return }
            let c = UNMutableNotificationContent()
            c.title = "Линия 2.0"
            c.body = "Новое сообщение"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "l2-test", content: c, trigger: nil))
        }
    }

    // MARK: - Код паники: дерево файлов, копия базы, неотправленное

    private struct FileRec { let path: String; let created: Date; let size: Int }
    private static var treeBefore: [String: FileRec]?
    private static var wipeAt: Date?
    private static var copyDir: URL {
        Linia2Storage.library.appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("l2test-dbcopy", isDirectory: true)
    }

    /// Корни: контейнер приложения (Documents, Library с Caches, tmp) и общий контейнер (App Group).
    private static func roots() -> [(String, URL)] {
        var r: [(String, URL)] = [("Documents", Linia2Storage.documents), ("Library", Linia2Storage.library),
                                  ("tmp", Linia2Storage.tmp)]
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BaseDb.kAppGroupId) {
            r.append(("Group", g))
        }
        return r
    }

    private static func tree() -> [String: FileRec] {
        var out: [String: FileRec] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .fileSizeKey]
        for (name, root) in roots() {
            let base = root.resolvingSymlinksInPath().path
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else { continue }
            for case let f as URL in e {
                guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                var rel = f.resolvingSymlinksInPath().path
                if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
                let p = name + rel
                out[p] = FileRec(path: p, created: v.creationDate ?? .distantPast, size: v.fileSize ?? 0)
            }
        }
        return out
    }

    /// Не данные переписки: настройки (UserDefaults; ключи чатов из них удаляются), Application Support
    /// (публичный конфиг, служебные файлы Firebase, копия базы этого теста), системные метаданные контейнера.
    private static func allowed(_ p: String) -> Bool {
        if p.contains("/.com.apple.") { return true }
        for pre in ["Library/Preferences/", "Library/Application Support/", "Group/Library/Preferences/"] where p.hasPrefix(pre) { return true }
        return false
    }

    /// Вызывается исполнителем стирания (до уничтожения ключей).
    static func beforeWipe() {
        guard enabled else { return }
        // «Неотправленное» сообщение в очереди (outbox) последнего личного чата — не должно уйти после стирания.
        if let text = ProcessInfo.processInfo.environment["L2_TEST_OUTBOX"], !text.isEmpty,
           let t = Cache.tinode.getFilteredTopics(filter: { $0.topicType == .p2p })?
            .max(by: { ($0.touched ?? .distantPast) < ($1.touched ?? .distantPast) }) {
            _ = BaseDb.sharedInstance.sqlStore?.msgSend(topic: t, data: Drafty(plainText: text), head: nil)
        }
        _ = BaseDb.l2DebugCopyDbFiles(to: copyDir)
        treeBefore = tree()
        wipeAt = Date()
    }

    /// Файлы, оставшиеся от состояния до стирания, кроме разрешённых: созданные ДО стирания (переименование
    /// дату создания сохраняет — так ловится и база, перенесённая в l2trash, но не стёртая) или с тем же путём
    /// и той же датой создания, что в снимке «до».
    private static func oldFiles() -> [String] {
        guard let before = treeBefore, let at = wipeAt else { return [] }
        return tree().values.filter { r in
            guard !allowed(r.path) else { return false }
            if r.created < at { return true }
            if let b = before[r.path], abs(b.created.timeIntervalSince(r.created)) < 0.001 { return true }
            return false
        }.map { $0.path }.sorted()
    }

    static func treeReport() -> String {
        guard let before = treeBefore else { return "no-wipe" }
        func list(_ t: [String: FileRec]) -> String {
            t.values.sorted { $0.path < $1.path }.map { "\($0.path) \($0.size)" + (allowed($0.path) ? " [allowed]" : "") }
                .joined(separator: "\n")
        }
        return "BEFORE (\(before.count)):\n" + list(before) + "\n\nAFTER:\n" + list(tree()) +
            "\n\nOLD (left from before):\n" + oldFiles().joined(separator: "\n")
    }

    static func state() -> String {
        let c = BaseDb.sharedInstance.l2DebugCounts()
        // После стирания: oldf — файлов старого состояния; copyrows/copyplain/copyread — копия старой базы:
        // значений / открытым текстом / прочитано новыми ключами (−1 — стирания не было).
        let wiped = treeBefore != nil
        let copy = wiped ? BaseDb.l2DebugReadCopy(at: copyDir) : [:]
        let chats = Utils.fetchTopics(archived: false)?.count ?? -1
        let cfg = Linia2WipeStore.config
        let parts: [(String, Int)] = [
            ("msgs", c["msgs"] ?? -1), ("plain", c["plain"] ?? -1), ("topics", c["topics"] ?? -1), ("chats", chats),
            ("users", c["users"] ?? -1), ("subs", c["subs"] ?? -1), ("files", Linia2Storage.debugFileCount()),
            ("notif", delivered), ("pend", Linia2WipeStore.pending.count), ("cfg", cfg?.hasCode == true ? 1 : 0),
            ("lvl", cfg?.level ?? 0), ("keys", L2Vault.contentKeyAvailable ? 1 : 0), ("pinms", Linia2TestProbe.lastPinMs),
            ("wipes", Linia2TestProbe.wipes), ("kdf", kdfOK),
            ("vpush", Linia2TestProbe.voipPushes), ("vdup", Linia2TestProbe.voipDuplicates),
            ("vign", Linia2TestProbe.voipIgnored), ("vshown", Linia2TestProbe.incomingShown), ("vstep", voipStep),
            ("ui", Linia2TestProbe.uiReadyMs), ("lost", Linia2TestProbe.lostToasts),
            ("conn", Cache.tinode.isConnectionAuthenticated ? 1 : 0), ("mig", Linia2TestProbe.migrated),
            ("hupms", Linia2TestProbe.lastHangupCloseMs), ("rend", Linia2TestProbe.remoteEnds),
            ("eng", Linia2TestProbe.callEngine), ("nbg", Linia2TestProbe.nativeBg), ("wsw", Linia2TestProbe.webSwitches),
            ("wswice", Linia2TestProbe.webSwitchIceMs), ("bga", Linia2TestProbe.bgAnswers), ("pstorm", Linia2TestProbe.pathEvents),
            ("queued", c["queued"] ?? -1), ("oldf", wiped ? oldFiles().count : -1),
            ("copyrows", copy["rows"] ?? -1), ("copyplain", copy["plain"] ?? -1), ("copyread", copy["read"] ?? -1),
        ]
        return parts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
