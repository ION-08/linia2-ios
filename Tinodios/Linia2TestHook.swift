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
        vc.view = v
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

    static func state() -> String {
        let c = BaseDb.sharedInstance.l2DebugCounts()
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
        ]
        return parts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
