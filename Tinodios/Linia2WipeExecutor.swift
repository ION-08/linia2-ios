//
//  Linia2WipeExecutor.swift
//  Линия 2.0: выполнение стирания («код паники», 10 неверных PIN, удалённое стирание из админки).
//
//  Порядок (без предупреждений, анимаций и вопросов):
//   1. записать отчёт для сервера (без переписки и без токена — контракт 3.3) — уйдёт при первой связи;
//   2. УНИЧТОЖИТЬ КЛЮЧИ хранилища (L2Vault.destroyKeys) — с этого момента база и кэш не расшифровываются;
//      забыть код (до новой настройки с сервера); «горизонт» = сейчас (новые синхронизации не вернут старое);
//   3. отключить Tinode (без выхода на сервере), заменить базу новой пустой (вход сохраняется для уровней 1–2),
//      новые ключи; очистить память кэша картинок, уведомления (доставленные и запланированные), бейдж;
//   4. в фоне — Documents, Library (кроме Preferences/Application Support), Caches, tmp, общий контейнер,
//      URLCache, cookies, данные WKWebView, снимки экрана;
//   5. уровни 1–2: приложение открывается как обычно, пустым, и переподключается по сохранённому токену;
//      уровни 3–4: выход из аккаунта и нейтральная ошибка «Не удалось подключиться к серверу…».
//  Серверная часть (уровни 2–4: удаление; 3: выход везде; 4: удаление аккаунта) — POST /panic/trigger;
//  уровень берётся сервером из сохранённой настройки. Без сети отчёт хранится в Keychain и отправляется
//  при первой связи (запуск, возврат из фона, вход, появление сети).
//

import UIKit
import Firebase
import TinodeSDK
import TinodiosDB

enum Linia2WipeExecutor {
    private static var flushing = false

    /// При запуске приложения.
    static func install() {
        Linia2WipeSync.execute = { level, source, wipeId in run(level: level, source: source, wipeId: wipeId) }
        Linia2WipeSync.flushPending = { flush() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { flush() }
    }

    /// Только с главного потока.
    static func run(level: Int, source: Linia2WipeSource, wipeId: String?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { run(level: level, source: source, wipeId: wipeId) }
            return
        }
        let level = min(4, max(1, level))
        let uid = Linia2WipeSync.currentUid
        let device = Linia2WipeStore.deviceId
        let reportKey = Linia2WipeStore.reportKey
        let now = Date()

        // 1. Отчёт серверу (удалённое стирание — подтверждение ack).
        var item: [String: Any] = ["_id": UUID().uuidString, "device": device]
        if let u = uid { item["uid"] = u }
        if let k = reportKey { item["report_key"] = k }
        if let w = wipeId {
            item["kind"] = "ack"
            item["wipe"] = w
        } else {
            item["kind"] = "trigger"
            item["event_id"] = item["_id"]
            item["level"] = level
            item["at"] = Int64(now.timeIntervalSince1970 * 1000)
            item["source"] = source.rawValue
        }
        Linia2WipeStore.pending = Linia2WipeStore.pending + [item]

        // 2. Криптоудаление.
        L2Vault.destroyKeys()
        Linia2WipeStore.forgetCode()
        if let u = uid { L2Vault.setHorizon(uid: u, date: now) }

        // Уровни 3–4: пока токен ещё есть — отозвать VoIP и сразу попробовать отправить отчёт.
        let logout = level >= 3
        if logout {
            Linia2Voip.shared.unregister()
            flush()
        }

        // 3. Tinode и база.
        Cache.resetForWipe()
        BaseDb.wipeAndRecreate(keepAccount: !logout)
        L2Vault.bootstrap()
        Linia2Storage.wipeVisibleNow()
        Linia2TestProbe.wipes += 1

        // 4. Файлы — в фоне.
        Linia2Storage.wipeFiles()

        // 5. Интерфейс.
        let window = Linia2Root.window
        if logout {
            Linia2AppLock.shared.resetOnLogout()
            SharedUtils.removeAuthToken()
            Linia2Push.shared.forget()
            if Linia2Firebase.configured { Messaging.messaging().deleteToken { _ in } }
            window?.rootViewController = Linia2WelcomeViewController.makeRoot()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showNeutralError() }
        } else {
            window?.rootViewController = Linia2TabBarController.make()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = SharedUtils.connectAndLoginSync(using: Cache.tinode, inBackground: false)
            }
        }
        if !logout { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { flush() } }
    }

    private static func showNeutralError() {
        guard let root = Linia2Root.window?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let a = UIAlertController(title: nil, message: "Не удалось подключиться к серверу. Повторите попытку позже.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(a, animated: false)
    }

    // MARK: - Отправка отчётов

    /// Отправить неотправленные отчёты (с главного потока). Удаляется только принятое сервером
    /// (ok:true) или заведомо неверное (400); нет сети / нет API (404) — повтор позже.
    static func flush() {
        guard Thread.isMainThread else { DispatchQueue.main.async { flush() }; return }
        guard !flushing else { return }
        let items = Linia2WipeStore.pending
        guard !items.isEmpty else { return }
        flushing = true
        let token = SharedUtils.getAuthToken()
        let group = DispatchGroup()
        var done: Set<String> = []
        for item in items {
            guard let id = item["_id"] as? String else { continue }
            var body = item
            let kind = body.removeValue(forKey: "kind") as? String ?? "trigger"
            body.removeValue(forKey: "_id")
            group.enter()
            let finish: (Int, [String: Any]?) -> Void = { status, json in
                if (status == 200 && (json?["ok"] as? Bool) == true) || status == 400 { done.insert(id) }
                group.leave()
            }
            if kind == "ack" {
                Linia2WipeAPI.ack(token: token, body: body, completion: finish)
            } else {
                Linia2WipeAPI.trigger(token: token, body: body, completion: finish)
            }
        }
        group.notify(queue: .main) {
            flushing = false
            guard !done.isEmpty else { return }
            Linia2WipeStore.pending = Linia2WipeStore.pending.filter { !done.contains(($0["_id"] as? String) ?? "") }
        }
    }
}

// MARK: - Пустой вид после стирания: чаты не новее «горизонта» не показываются

enum Linia2Horizon {
    /// Чат виден: нет горизонта для текущего пользователя или последнее событие в чате новее него.
    static func isVisible(_ t: TopicProto) -> Bool {
        guard let h = L2Vault.horizon(for: Cache.tinode.myUid ?? BaseDb.sharedInstance.sqlStore?.myUid) else { return true }
        guard let touched = t.touched ?? t.updated else { return false }
        return touched > h
    }
}
