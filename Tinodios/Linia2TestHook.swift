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
//  Окружение: L2_TEST_SEED=1 — положить тестовые файлы (Documents, кэш кружков, общий контейнер) и локальное
//  уведомление, чтобы проверить, что стирание их убирает.
//

import UIKit
import UserNotifications
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
        ]
        return parts.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
}
