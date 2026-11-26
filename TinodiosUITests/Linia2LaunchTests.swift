//
//  Linia2LaunchTests.swift
//  Линия 2.0: запуск приложения при новых сообщениях — то, на чём вылетала сборка 1005
//  (push из чата «🛡 Безопасность» → открыть приложение, в т.ч. нажатием на уведомление → вылет; PIN включён).
//
//  test1 — холодный старт: пока приложение закрыто, собеседник B присылает сообщения в формате бота
//          (эмодзи 🚨⚠️ℹ️, флаги, длинные строки, кнопка BN, Drafty с жирным/ссылкой и смещениями «как в Python»)
//          → PIN → список → чат открывается и рисуется.
//  test2 — холодный старт нажатием на уведомление: приложение завершено, `simctl push` (payload как у Tinode FCM)
//          → нажатие на баннер / уведомление в Центре уведомлений → PIN → открыт чат с B.
//  test3 — короткий фон (< 30 с, без PIN): Home → сообщения + push → activate → живо.
//  test4 — длинный фон (> 30 с, таймаут PIN): Home → 35 с → сообщения + push → нажатие на уведомление → PIN → чат.
//  «Нет вылета»: app.state == .runningForeground на всём пути (опрос), плюс шаг workflow ловит crash .ips.
//
//  `simctl push` делает workflow (шаг «Запуск приложения из уведомления»): тест кладёт payload в L2_PUSH_DIR
//  (<имя>.apns), фоновый цикл шага отправляет его в симулятор и переименовывает в <имя>.apns.sent.
//  Окружение: L2_LOGIN/L2_PASSWORD (A), L2_PEER_LOGIN/L2_PEER_PASSWORD (B), L2_PEER_NAME, L2_IOS_UID (uid A), L2_PUSH_DIR.
//

import XCTest

final class Linia2LaunchTests: Linia2CallTestBase {
    private static let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
    private var peerName: String { env["L2_PEER_NAME"] ?? "Собеседник CI" }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Разрешение на уведомления без Firebase (сборка CI) — только под этим флагом (см. UiUtils.setUpPushNotifications).
        app.launchArguments += ["-l2-push-auth"]
    }

    // MARK: - Сообщения «как у бота» (реальные шаблоны из guard/app/guard.py)

    /// Смещение в кодовых точках Unicode (так считает Python `len()` в guard.py), а не в графемах Swift.
    private func pyLen(_ s: String) -> Int { s.unicodeScalars.count }

    private func botMessages(tag: String) -> [(content: Any, drafty: Bool)] {
        let geo = "203.0.113.7 — 🇩🇪 DE, AS3320 Deutsche Telekom AG"
        // alert(): fmt_event(r) — 🚨 + тип, IP с флагом, детали, рекомендация, время.
        let crit = [
            "🚨 Вход в админку",
            "IP: \(geo)",
            "Сколько раз: 3 (с 09:58 по 10:15 МСК)",
            "Что пытались: вход @owner — пароль + Passkey (Safari 18, iPhone)",
            "Сделано автоматически: ничего, только оповещение",
            "Рекомендация: Если входили не вы — откройте админку → «Безопасность админки» → «Выйти на всех устройствах» и решите вопрос о смене пароля.",
            "Время: 26.11.2026 10:15:02 МСК \(tag)-1",
        ].joined(separator: "\n")
        // hourly(): «⚠️ Сводка за час» — группы, до 8 IP, длинные строки с деталями.
        var hourly = ["⚠️ Сводка за час (09:00–10:00 МСК)"]
        for (typ, n) in [("Сканирование путей", 8), ("Подбор паролей пользователей", 5), ("Флуд запросами", 3)] {
            hourly.append("")
            hourly.append("• \(typ) — \(n) IP")
            for i in 0..<n {
                hourly.append("  198.51.100.\(10 + i) — 🇳🇱 NL, AS14061 DigitalOcean, LLC: \(i + 2) раз, до \(40 + i)/мин; " +
                              "GET /wp-login.php, /.env, /.git/config, /phpmyadmin/index.php?route=/&lang=ru — 404; сделано: бан 1 ч (Caddy, fail2ban)")
            }
            hourly.append("  Рекомендация: IP блокируется автоматически (5 ошибок — 1 ч, 20 за сутки — 24 ч). Если атака идёт с разных IP — рассмотрите вход по Passkey/Face ID.")
        }
        hourly.append("")
        hourly.append("Подробности — админка → «Безопасность». \(tag)-2")
        // daily(): «ℹ️ Ежедневный отчёт» со строкой счётчиков.
        let daily = [
            "ℹ️ Ежедневный отчёт безопасности (25.11.2026 09:00 — 26.11.2026 09:00 МСК)",
            "🚨 срочных: 2 · ⚠️ внимание: 5 · ℹ️ информация: 12 · сообщений 🚨 отправлено: 2",
            "",
            "• Вход по SSH — 4 (IP известны) 👨‍💻",
            "• fail2ban [sshd] забанил IP — 37 🇨🇳🇷🇺🇺🇸🇧🇷",
            "\(tag)-3",
        ].joined(separator: "\n")
        // offer_unban(): Drafty с кнопкой BN; at/len — в кодовых точках (Python).
        let lead = "Если это вы (IP 203.0.113.7) — нажмите: ", title = "Это я — разблокировать"
        let button: [String: Any] = [
            "txt": lead + title,
            "fmt": [["at": pyLen(lead), "len": pyLen(title), "key": 0]] as [[String: Any]],
            "ent": [["tp": "BN", "data": ["act": "pub", "name": "unban", "val": "ci-\(tag)", "title": title]]] as [[String: Any]],
        ]
        // Drafty с жирным и ссылкой, смещения посчитаны «по-питоновски»: ⚠️ и флаг — 2 кодовые точки, 1 графема,
        // поэтому в Swift диапазоны съезжают и выходят за конец текста — клиент не должен падать.
        let head = "⚠️ Сводка: 🇩🇪 203.0.113.7 — флуд \(tag)-4\nПодробности: "
        let url = "https://v2.chat-linia.site/linia-admin/#security"
        let bold = "Сводка"
        let boldAt = pyLen(String(head[..<head.range(of: bold)!.lowerBound]))
        let rich: [String: Any] = [
            "txt": head + url,
            "fmt": [["tp": "ST", "at": boldAt, "len": pyLen(bold)], ["at": pyLen(head), "len": pyLen(url), "key": 0],
                    ["at": pyLen(head) + pyLen(url) + 5, "len": 3, "key": 7]] as [[String: Any]],
            "ent": [["tp": "LN", "data": ["url": url]]] as [[String: Any]],
        ]
        // review: «🛡 Разбор Claude» — длинный текст с markdown-разметкой (бот шлёт строкой).
        var review = "🛡 Разбор Claude (после 🚨 Вход в админку)\n\n**Итог:** вход выполнен владельцем, признаков атаки нет ✅\n\n"
        for i in 1...12 {
            review += "\(i). `fail2ban` / *Caddy*: проверено \(i * 7) записей журнала, https://v2.chat-linia.site/linia-admin/#security — без аномалий; " +
                      "_рекомендация_: ничего не делать 🙂 (ℹ️ повторная проверка через час)\n"
        }
        review += "\(tag)-5"
        return [(crit, false), (hourly.joined(separator: "\n"), false), (daily, false), (button, true), (rich, true), (review, false)]
    }

    // MARK: - Собеседник B

    private func peer() throws -> (L2PeerClient, String) {
        guard let login = env["L2_PEER_LOGIN"], let pass = env["L2_PEER_PASSWORD"], let a = env["L2_IOS_UID"],
              !login.isEmpty, !pass.isEmpty, !a.isEmpty else {
            throw XCTSkip("нет L2_PEER_LOGIN / L2_PEER_PASSWORD / L2_IOS_UID — собеседник не управляется из теста")
        }
        let c = L2PeerClient()
        XCTAssertTrue(c.login(login, pass), "собеседник не вошёл")
        c.open(a)
        return (c, a)
    }

    /// B присылает сообщения бота; возвращает seq последнего.
    @discardableResult
    private func sendBotMessages(_ c: L2PeerClient, to topic: String, tag: String, count: Int = 6) -> Int {
        var last = 0
        for m in botMessages(tag: tag).prefix(count) {
            let seq = c.publish(topic, content: m.content, head: m.drafty ? ["mime": "text/x-drafty"] : [:])
            XCTAssertNotNil(seq, "сообщение бота не отправлено")
            last = seq ?? last
        }
        return last
    }

    // MARK: - push через workflow (simctl push)

    private var pushDir: String? {
        if let d = env["L2_PUSH_DIR"], !d.isEmpty { return d }
        return env["SIMULATOR_HOST_HOME"].map { $0 + "/Library/Caches/l2push" }
    }

    /// Payload, как его доставляет APNs от Tinode FCM (server/push/fcm/payload.go + linia2.go):
    /// data-поля верхним уровнем, aps с alert «Новое сообщение от …», content-available и mutable-content.
    private func pushPayload(topic: String, from: String, seq: Int) -> [String: Any] {
        [
            "Simulator Target Bundle": "info.codix.liniya2",
            "aps": [
                "alert": ["title": "Новое сообщение", "body": "Новое сообщение от \(peerName)"] as [String: String],
                "badge": 6, "content-available": 1, "mutable-content": 1, "sound": "default",
                "thread-id": topic, "interruption-level": "time-sensitive",
            ] as [String: Any],
            "what": "msg", "topic": topic, "seq": String(seq), "xfrom": from,
            "ts": ISO8601DateFormatter().string(from: Date()), "mime": "text/x-drafty", "content": "",
            "gcm.message_id": String(Int(Date().timeIntervalSince1970 * 1000)), "google.c.a.e": "1",
        ]
    }

    private func requestPush(_ payload: [String: Any], name: String) throws {
        guard let dir = pushDir else { throw XCTSkip("нет L2_PUSH_DIR — push отправить некому (нужен шаг workflow)") }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = "\(dir)/\(name)-\(Self.stamp).apns", tmp = file + ".tmp"
        try? fm.removeItem(atPath: file + ".sent")
        try JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: tmp))
        try fm.moveItem(atPath: tmp, toPath: file)
        let end = Date().addingTimeInterval(60)
        while Date() < end {
            if fm.fileExists(atPath: file + ".sent") { return }
            if fm.fileExists(atPath: file + ".err") { XCTFail("simctl push не удался: \(file).err"); return }
            usleep(300_000)
        }
        XCTFail("push не отправлен за 60 с (нет фонового цикла simctl push в workflow?)")
    }

    // MARK: - «Нет вылета»

    private func assertAlive(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        if app.state != .runningForeground {
            screenshot("ВЫЛЕТ-" + step)
            XCTFail("приложение не на экране (\(app.state.rawValue)) — \(step)", file: file, line: line)
        }
    }

    /// Опрос состояния в течение `seconds`: каждое мгновение приложение должно быть на экране.
    private func watchAlive(_ step: String, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            assertAlive(step)
            usleep(250_000)
        } while Date() < end
    }

    /// Ждём выхода приложения на экран (после нажатия на уведомление / activate); при этом оно не должно упасть.
    private func waitForeground(_ step: String, timeout: TimeInterval = 20) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end && app.state != .runningForeground { usleep(200_000) }
        assertAlive(step)
    }

    /// PIN (если показан, или обязателен) — ввести; всё это время приложение живо.
    private func passPin(required: Bool, _ step: String) {
        let pinTitle = app.staticTexts["Введите PIN-код"]
        let end = Date().addingTimeInterval(required ? 20 : 4)
        while Date() < end && !pinTitle.exists {
            assertAlive(step + "-до-PIN")
            usleep(250_000)
        }
        if required { XCTAssertTrue(pinTitle.exists, "нет экрана PIN — \(step)") }
        guard pinTitle.exists else { return }
        screenshot(step + "-pin")
        enterPin()
        let gone = Date().addingTimeInterval(10)
        while Date() < gone && pinTitle.exists { assertAlive(step + "-PIN"); usleep(250_000) }
        XCTAssertFalse(pinTitle.exists, "PIN не принят — \(step)")
        assertAlive(step + "-после-PIN")
    }

    private func labelContains(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
    }

    /// Системное окно «Разрешить уведомления» (появляется после входа под -l2-push-auth).
    private func allowNotifications() {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            for t in ["Allow", "Разрешить"] where springboard.buttons[t].exists {
                springboard.buttons[t].tap()
                return
            }
            usleep(300_000)
        }
    }

    private func backToList() {
        for _ in 0..<3 where app.textViews["l2.chat.input"].firstMatch.exists {
            let b = app.navigationBars.buttons.element(boundBy: 0)
            if b.exists { b.tap() } else { app.swipeRight() }
            sleep(1)
        }
        tab("l2.tab.chats").tap()
        sleep(1)
    }

    /// Баннер или (если баннер уже скрылся) уведомление в Центре уведомлений — нажать.
    private func tapNotification(_ step: String) {
        let pred = NSPredicate(format: "label CONTAINS[c] %@", "Новое сообщение")
        var n = springboard.descendants(matching: .any).matching(pred).firstMatch
        if !n.waitForExistence(timeout: 8) {
            // Центр уведомлений: смахнуть вниз от верхнего края.
            let from = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.002))
            from.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75)))
            n = springboard.descendants(matching: .any).matching(pred).firstMatch
            if !n.waitForExistence(timeout: 8) {
                screenshot("НЕТ-УВЕДОМЛЕНИЯ-" + step)
                XCTFail("уведомление не появилось — \(step)")
                return
            }
        }
        screenshot(step + "-notification")
        n.tap()
        // Стопка уведомлений сначала раскрывается — нажать ещё раз.
        let end = Date().addingTimeInterval(4)
        while Date() < end && app.state != .runningForeground { usleep(200_000) }
        if app.state != .runningForeground {
            let again = springboard.descendants(matching: .any).matching(pred).firstMatch
            if again.exists { again.tap() }
        }
    }

    private func loginA() {
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        allowNotifications()
        assertAlive("вход")
    }

    // MARK: - (a) холодный старт с новыми непрочитанными

    func test1_ColdStartWithUnreadBotMessages() throws {
        let (c, topic) = try peer()
        loginA()
        app.terminate()
        let tag = "L1-" + Self.stamp
        sendBotMessages(c, to: topic, tag: tag)
        sleep(2)

        app.launch()
        passPin(required: true, "холодный-старт")
        wait(tab("l2.tab.chats"), "вкладки после PIN", timeout: 20)
        watchAlive("список-чатов", seconds: 5)
        screenshot("list-unread")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", peerName)).firstMatch
        wait(row, "чат с «\(peerName)» в списке", timeout: 30).tap()
        wait(app.textViews["l2.chat.input"].firstMatch, "чат открыт", timeout: 15)
        wait(labelContains("\(tag)-5"), "последнее сообщение бота в чате", timeout: 30)
        watchAlive("чат-с-сообщениями-бота", seconds: 4)
        // Прокрутка по длинным сообщениям (рендер всех ячеек).
        for _ in 0..<4 { app.swipeDown(); usleep(400_000) }
        for _ in 0..<4 { app.swipeUp(); usleep(400_000) }
        watchAlive("прокрутка", seconds: 2)
        screenshot("chat-bot-messages")
        backToList()
        assertAlive("назад в список")
        app.terminate()
    }

    // MARK: - (b) холодный старт нажатием на уведомление

    func test2_ColdStartFromNotificationTap() throws {
        let (c, topic) = try peer()
        loginA()
        guard let peerUid = c.uid else { XCTFail("нет uid собеседника"); return }
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "приложение не завершилось")
        let tag = "L2-" + Self.stamp
        let seq = sendBotMessages(c, to: topic, tag: tag)
        try requestPush(pushPayload(topic: peerUid, from: c.uid ?? "", seq: seq), name: "cold")

        tapNotification("холодный-push")
        waitForeground("открытие-по-уведомлению")
        passPin(required: true, "холодный-push")
        wait(app.textViews["l2.chat.input"].firstMatch, "открыт чат из уведомления", timeout: 20)
        wait(labelContains("\(tag)-5"), "новые сообщения в чате из уведомления", timeout: 30)
        watchAlive("чат-из-уведомления", seconds: 6)
        screenshot("chat-from-push")
        app.terminate()
    }

    // MARK: - (c) короткий фон, push, возврат

    func test3_ShortBackgroundPushActivate() throws {
        let (c, topic) = try peer()
        loginA()
        guard let peerUid = c.uid else { XCTFail("нет uid собеседника"); return }
        XCUIDevice.shared.press(.home)
        sleep(3)
        XCTAssertNotEqual(app.state, .runningForeground, "приложение не ушло в фон")
        let tag = "L3-" + Self.stamp
        let seq = sendBotMessages(c, to: topic, tag: tag, count: 3)
        try requestPush(pushPayload(topic: peerUid, from: peerUid, seq: seq), name: "short")
        sleep(3)
        XCTAssertNotEqual(app.state, .notRunning, "приложение упало в фоне после push")
        app.activate()
        waitForeground("возврат-из-фона")
        passPin(required: false, "короткий-фон")
        watchAlive("после-короткого-фона", seconds: 5)
        screenshot("after-short-background")
    }

    // MARK: - (d) длинный фон (> таймаута PIN), push, нажатие

    func test4_LongBackgroundPushTapPin() throws {
        let (c, topic) = try peer()
        loginA()
        guard let peerUid = c.uid else { XCTFail("нет uid собеседника"); return }
        tab("l2.tab.chats").tap()
        XCUIDevice.shared.press(.home)
        sleep(35)   // PIN — после 30 с в фоне (Linia2AppLock.kLockAfter)
        let tag = "L4-" + Self.stamp
        let seq = sendBotMessages(c, to: topic, tag: tag)
        try requestPush(pushPayload(topic: peerUid, from: peerUid, seq: seq), name: "long")
        sleep(2)
        XCTAssertNotEqual(app.state, .notRunning, "приложение упало в фоне после push")
        tapNotification("длинный-фон")
        waitForeground("открытие-после-длинного-фона")
        passPin(required: true, "длинный-фон")
        wait(app.textViews["l2.chat.input"].firstMatch, "открыт чат из уведомления", timeout: 20)
        wait(labelContains("\(tag)-5"), "новые сообщения после длинного фона", timeout: 30)
        watchAlive("после-длинного-фона", seconds: 5)
        screenshot("after-long-background")

        // И ещё раз: длинный фон → просто вернуться (без уведомления) → PIN → живо.
        XCUIDevice.shared.press(.home)
        sleep(33)
        app.activate()
        waitForeground("возврат-после-второго-фона")
        passPin(required: true, "второй-длинный-фон")
        watchAlive("после-второго-фона", seconds: 4)
    }
}
