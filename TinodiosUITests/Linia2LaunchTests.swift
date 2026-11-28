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
//  Баги сборки 1006 (состояние — тестовый крючок «l2.test.state», Tinodios/Linia2TestHook.swift):
//  test5 — старт после обновления: база «старой версии» (-l2-simulate-upgrade: открытый текст, флаг миграции снят)
//          → PIN → интерфейс сразу, вкладки отзываются, пока база шифруется в фоне → plain=0, mig=1; без «Связь
//          с сервером потеряна»; после перезапуска переписка читается.
//  test6 — старт при недоступном сервере (L2_TEST_UNREACHABLE=8): интерфейс ≤ 2 с и список чатов из базы
//          (conn=0) ≤ 3 с от старта процесса (часы приложения), после PIN строка списка ≤ 3 с, всего < 12 с;
//          без ошибки первые 5 с (только «Подключение…»), затем подключение (conn=1) без перезапуска.
//  test7 — повторный VoIP push по завершённому звонку (L2_TEST_VOIP_REPLAY=1, без CallKit): «started» → входящий;
//          повтор того же topic+seq — без второго; «hang-up» — входящий закрыт; снова «started» по тому же звонку
//          и устаревший «started» — экран звонка не появляется, приложение живо и отзывается.
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
        // Главный поток не должен зависать при открытии чата (1128c81: 60 с «Timed out while evaluating UI query»).
        let tapAt = Date()
        let opened = app.textViews["l2.chat.input"].firstMatch.waitForExistence(timeout: 5)
        let openSec = Date().timeIntervalSince(tapAt)
        if !opened || openSec > 5.5 { screenshot("ЗАВИСАНИЕ-открытие-чата") }
        XCTAssertTrue(opened && openSec <= 5.5, String(format: "приложение не отвечало после тапа по чату: %.1f с (норма ≤5 с)", openSec))
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
        // Состояние процесса XCTest узнаёт у системы с задержкой (на экране уже «Домой», а app.state ещё
        // .runningForeground — прогон 45921914236). Ждём смены до 15 с; требование то же: приложение ушло в фон.
        let bgEnd = Date().addingTimeInterval(15)
        while Date() < bgEnd && app.state == .runningForeground { usleep(250_000) }
        XCTAssertNotEqual(app.state, .runningForeground, "приложение не ушло в фон")
        XCTAssertNotEqual(app.state, .notRunning, "приложение упало при уходе в фон")
        sleep(1)
        let tag = "L3-" + Self.stamp
        let seq = sendBotMessages(c, to: topic, tag: tag, count: 3)
        try requestPush(pushPayload(topic: peerUid, from: peerUid, seq: seq), name: "short")
        sleep(3)
        XCTAssertNotEqual(app.state, .notRunning, "приложение упало в фоне после push")
        app.activate()
        waitForeground("возврат-из-фона")
        // 1018: PIN — сразу при любом уходе из приложения (без «30 с в фоне»).
        passPin(required: true, "короткий-фон")
        watchAlive("после-короткого-фона", seconds: 5)
        screenshot("after-short-background")
        // И мгновенный возврат (как после гашения/блокировки экрана): «Домой» → сразу назад → PIN.
        XCUIDevice.shared.press(.home)
        let bg2 = Date().addingTimeInterval(10)
        while Date() < bg2 && app.state == .runningForeground { usleep(200_000) }
        app.activate()
        waitForeground("мгновенный-возврат")
        passPin(required: true, "мгновенный-возврат")
        watchAlive("после-мгновенного-возврата", seconds: 3)
    }

    // MARK: - (d) длинный фон (> таймаута PIN), push, нажатие

    func test4_LongBackgroundPushTapPin() throws {
        let (c, topic) = try peer()
        loginA()
        guard let peerUid = c.uid else { XCTFail("нет uid собеседника"); return }
        tab("l2.tab.chats").tap()
        XCUIDevice.shared.press(.home)
        sleep(5)   // 1018: PIN — сразу при уходе из приложения (задержки больше нет)
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
        sleep(3)
        app.activate()
        waitForeground("возврат-после-второго-фона")
        passPin(required: true, "второй-длинный-фон")
        watchAlive("после-второго-фона", seconds: 4)
    }

    // MARK: - Баги сборки 1006

    /// Значения тестового крючка (msgs, plain, ui, lost, conn, mig, vpush, vign, vshown, vstep, …).
    private func hook(_ step: String) -> [String: Int] {
        let e = any("l2.test.state")
        guard e.exists || e.waitForExistence(timeout: 10), let v = e.value as? String else {
            XCTFail("нет тестового крючка l2.test.state — \(step)")
            return [:]
        }
        var out: [String: Int] = [:]
        for part in v.split(separator: " ") {
            let kv = part.split(separator: "=")
            if kv.count == 2, let n = Int(kv[1]) { out[String(kv[0])] = n }
        }
        let a = XCTAttachment(string: v)
        a.name = "state-" + step
        a.lifetime = .keepAlways
        add(a)
        return out
    }

    @discardableResult
    private func waitHook(_ step: String, timeout: TimeInterval, _ ok: ([String: Int]) -> Bool) -> [String: Int] {
        let end = Date().addingTimeInterval(timeout)
        var s = hook(step)
        while !ok(s) && Date() < end {
            assertAlive(step)
            usleep(700_000)
            s = hook(step)
        }
        return s
    }

    /// Тост «Связь с сервером потеряна» (ru/en) на экране.
    private var lostToast: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                             "Связь с сервером", "Connection to server lost")).firstMatch
    }

    /// Интерфейс отзывается: переключение вкладок — каждое ≤ 2 с.
    private func assertTabsRespond(_ step: String) {
        for id in ["l2.tab.calls", "l2.tab.chats"] {
            let t0 = Date()
            tab(id).tap()
            assertAlive(step)
            XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5, "вкладка \(id) отозвалась медленно — \(step)")
        }
    }

    func test5_StartAfterUpgradeMigration() throws {
        let (c, topic) = try peer()
        loginA()
        let tag = "L5-" + Self.stamp
        sendBotMessages(c, to: topic, tag: tag, count: 3)
        // История в локальной базе: открыть чат с B.
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", peerName)).firstMatch
        wait(row, "чат с «\(peerName)»", timeout: 30).tap()
        wait(labelContains("\(tag)-3"), "сообщения в чате", timeout: 30)
        backToList()
        app.terminate()

        // «Первый запуск новой версии»: база в открытом виде, миграция не выполнялась.
        app.launchArguments += ["-l2-simulate-upgrade"]
        app.launch()
        let before = waitHook("до-миграции", timeout: 10) { ($0["plain"] ?? 0) > 0 }
        XCTAssertGreaterThan(before["plain"] ?? 0, 0, "эмуляция старой базы не сработала (нет открытых записей)")
        passPin(required: true, "после-обновления")
        wait(tab("l2.tab.chats"), "вкладки сразу после PIN", timeout: 3)
        XCTAssertFalse(lostToast.exists, "«Связь с сервером потеряна» сразу после PIN")
        // Пока идёт миграция — интерфейс отзывается, ошибок нет.
        let end = Date().addingTimeInterval(60)
        var st = hook("миграция")
        while Date() < end && !((st["plain"] ?? 1) == 0 && (st["mig"] ?? 0) == 1) {
            assertTabsRespond("во-время-миграции")
            XCTAssertFalse(lostToast.exists, "«Связь с сервером потеряна» во время миграции")
            sleep(1)
            st = hook("миграция")
        }
        XCTAssertEqual(st["plain"], 0, "база не зашифрована за 60 с")
        XCTAssertEqual(st["mig"], 1, "миграция не завершилась")
        XCTAssertEqual(st["lost"], 0, "показано «Связь с сервером потеряна»")
        screenshot("after-migration")

        // Следующий запуск — обычный; переписка читается.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-l2-simulate-upgrade" }
        app.launch()
        passPin(required: true, "после-миграции")
        wait(tab("l2.tab.chats"), "вкладки", timeout: 10)
        wait(row, "чат с «\(peerName)» после миграции", timeout: 20).tap()
        wait(labelContains("\(tag)-3"), "сообщения читаются после миграции", timeout: 30)
        watchAlive("чат-после-миграции", seconds: 3)
        app.terminate()
    }

    func test6_StartWithServerUnreachable() throws {
        loginA()
        let row = app.cells.firstMatch
        wait(row, "в списке есть чат (кэш)", timeout: 20)
        app.terminate()

        app.launchEnvironment["L2_TEST_UNREACHABLE"] = "8"
        let t0 = Date()
        app.launch()
        // app.launch() возвращается, когда XCUITest настроил сеанс автоматизации (на CI — 2–9 с, это не время
        // приложения). Время приложения — по его собственным часам (крючок): ui, list — мс от старта процесса.
        let tReady = Date()
        let s0 = waitHook("старт", timeout: 5) { ($0["ui"] ?? -1) >= 0 && ($0["list"] ?? -1) >= 0 }
        XCTAssertGreaterThanOrEqual(s0["ui"] ?? -1, 0, "интерфейс не построен")
        XCTAssertLessThanOrEqual(s0["ui"] ?? 99_999, 2000, "интерфейс построен дольше 2 с")
        // Список чатов из локальной базы готов (под экраном PIN) без сервера: ≤ 3 с от старта процесса.
        XCTAssertGreaterThanOrEqual(s0["list"] ?? -1, 0, "список чатов из базы не построен без сервера")
        XCTAssertLessThanOrEqual(s0["list"] ?? 99_999, 3000, "список чатов из базы построен дольше 3 с")
        XCTAssertEqual(s0["conn"], 0, "сервер должен быть недоступен первые 8 с")
        passPin(required: true, "недоступный-сервер")
        // От снятия PIN до вкладок и строки списка — без ожидания сети: ≤ 3 с (опрос каждые 100 мс,
        // а не waitForExistence — тот первый раз проверяет только через 1 с).
        let tPin = Date()
        let cell = app.cells.firstMatch, chats = tab("l2.tab.chats")
        while Date().timeIntervalSince(tPin) < 3 && !(chats.exists && cell.exists) { usleep(100_000) }
        let pinToList = Date().timeIntervalSince(tPin)
        XCTAssertTrue(chats.exists, "вкладки без сервера")
        XCTAssertTrue(cell.exists, "список чатов из кэша без сервера")
        XCTAssertLessThan(pinToList, 3, "после PIN список чатов из кэша не показан за 3 с")
        let total = Date().timeIntervalSince(tReady)
        XCTAssertLessThan(total, 12, "интерфейс с кэшем не показан вовремя")
        let s1h = hook("после-PIN")   // unl — мс до снятия PIN (часы приложения)
        let launch = any("l2.test.launch")
        let steps = launch.exists ? (launch.value as? String ?? "") : ""
        let a = XCTAttachment(string: steps)
        a.name = "launch-steps"
        a.lifetime = .keepAlways
        add(a)
        print(String(format: "L2-TIME test6: ui=%dms list=%dms unlock=%dms pin→list=%.2fs total=%.2fs (XCUITest launch %.2fs) | %@",
                     s0["ui"] ?? -1, s0["list"] ?? -1, s1h["unl"] ?? -1, pinToList, total,
                     tReady.timeIntervalSince(t0), steps))
        // Первые 5 с после запуска — никаких ошибок.
        while Date().timeIntervalSince(t0) < 5 {
            XCTAssertFalse(lostToast.exists, "ошибка соединения в первые 5 с")
            assertAlive("первые-5-с")
            usleep(250_000)
        }
        screenshot("unreachable-ui")
        // Сервер «вернулся» через 8 с — подключение само, без перезапуска.
        let s1 = waitHook("подключение", timeout: 40) { ($0["conn"] ?? 0) == 1 }
        XCTAssertEqual(s1["conn"], 1, "не подключились после того, как сервер стал доступен")
        XCTAssertEqual(s1["lost"], 0, "показано «Связь с сервером потеряна» при запуске")
        let banner = any("l2.connection.status")
        let gone = Date().addingTimeInterval(10)
        while Date() < gone && banner.exists { usleep(300_000) }
        XCTAssertFalse(banner.exists, "«Подключение…» не исчезло после подключения")
        assertTabsRespond("после-подключения")
        screenshot("unreachable-connected")
        app.terminate()
        app.launchEnvironment["L2_TEST_UNREACHABLE"] = nil
    }

    /// Сборка 1007: «Подключение…» при живом сервере. Холодный старт с доступным сервером — вход (conn=1)
    /// не позже 5 с после экрана PIN, плашка «Подключение…» исчезает, список чатов на месте.
    func test8_StartOnlineWithin5s() throws {
        loginA()
        wait(app.cells.firstMatch, "в списке есть чат", timeout: 20)
        app.terminate()
        app.launch()
        passPin(required: true, "онлайн-старт")
        let t0 = Date()
        let s = waitHook("онлайн", timeout: 15) { ($0["conn"] ?? 0) == 1 }
        XCTAssertEqual(s["conn"], 1, "нет входа на сервер (статус не «онлайн»)")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(t0), 5.5, "вход дольше 5 с после PIN")
        let banner = any("l2.connection.status")
        let gone = Date().addingTimeInterval(6)
        while Date() < gone && banner.exists { usleep(300_000) }
        XCTAssertFalse(banner.exists, "«Подключение…» не исчезло при живом сервере")
        wait(app.cells.firstMatch, "список чатов после входа", timeout: 5)
        XCTAssertEqual(s["lost"], 0, "показано «Связь с сервером потеряна»")
        assertTabsRespond("онлайн-старт")
        screenshot("online-start")
    }

    func test7_RepeatedVoipPushForEndedCall() throws {
        loginA()
        app.terminate()
        app.launchEnvironment["L2_TEST_VOIP_REPLAY"] = "1"
        app.launch()
        passPin(required: true, "voip-replay")
        wait(tab("l2.tab.chats"), "вкладки", timeout: 10)
        let incoming = app.alerts["Входящий звонок"].firstMatch
        // 1: «started» — входящий показан (крючок работает).
        wait(incoming, "входящий по VoIP push", timeout: 20)
        screenshot("voip-incoming")
        // 2: повтор того же topic+seq — второго входящего нет.
        let s2 = waitHook("повтор", timeout: 6) { ($0["vstep"] ?? 0) >= 2 }
        XCTAssertEqual(s2["vdup"], 1, "повтор push по тому же звонку не распознан")
        XCTAssertEqual(s2["vshown"], 1, "повтор push показал второй входящий")
        // 3: «hang-up» — входящий закрыт.
        waitHook("отбой", timeout: 6) { ($0["vstep"] ?? 0) >= 3 }
        let closed = Date().addingTimeInterval(4)
        while Date() < closed && incoming.exists { usleep(200_000) }
        XCTAssertFalse(incoming.exists, "push «hang-up» не закрыл входящий")
        // 4–5: тот же звонок после завершения и устаревший push — экран звонка не появляется.
        let end = Date().addingTimeInterval(8)
        var st = hook("после-отбоя")
        while Date() < end && (st["vstep"] ?? 0) < 6 {
            XCTAssertFalse(incoming.exists, "фантомный входящий после завершения звонка")
            XCTAssertFalse(any("l2.call.hangup").exists, "экран звонка после завершения")
            assertAlive("повторный-push")
            usleep(300_000)
            st = hook("после-отбоя")
        }
        XCTAssertEqual(st["vstep"], 6, "сценарий крючка не дошёл до конца")
        XCTAssertEqual(st["vshown"], 1, "по завершённому звонку снова показан входящий")
        XCTAssertGreaterThanOrEqual(st["vign"] ?? 0, 2, "push по завершённому / устаревшему звонку не отброшен")
        XCTAssertFalse(incoming.exists, "фантомный входящий")
        assertTabsRespond("после-повторного-push")
        watchAlive("после-повторного-push", seconds: 3)
        screenshot("voip-replay-done")
        app.terminate()
        app.launchEnvironment["L2_TEST_VOIP_REPLAY"] = nil
    }

    /// Сборка 1013 вылетала при запуске на iPhone 17 (5G): частые события NWPathMonitor + ws ping. Холодный старт
    /// под «штормом смены сети» (L2_TEST_PATH_STORM=1: с запуска 30 с, каждые 200 мс, ping включён, каждая
    /// вторая проверка — как мёртвый сокет) → PIN → список чатов; приложение живо все 30 с, вход на сервер есть.
    func test9_ColdStartUnderNetworkPathStorm() throws {
        loginA()
        wait(app.cells.firstMatch, "в списке есть чат", timeout: 20)
        app.terminate()
        app.launchEnvironment["L2_TEST_PATH_STORM"] = "1"
        defer { app.launchEnvironment["L2_TEST_PATH_STORM"] = nil }
        let t0 = Date()
        app.launch()
        passPin(required: true, "шторм-сети")
        wait(tab("l2.tab.chats"), "вкладки под штормом сети", timeout: 5)
        wait(app.cells.firstMatch, "список чатов под штормом сети", timeout: 10)
        screenshot("path-storm-list")
        let rest = 32 - Date().timeIntervalSince(t0)
        if rest > 0 { watchAlive("шторм-сети", seconds: rest) }
        assertTabsRespond("шторм-сети")
        let s = waitHook("шторм-сети-итог", timeout: 20) { ($0["conn"] ?? 0) == 1 && ($0["pstorm"] ?? 0) >= 140 }
        XCTAssertGreaterThanOrEqual(s["pstorm"] ?? 0, 140, "шторм событий пути не отработал (pstorm)")
        XCTAssertEqual(s["conn"], 1, "нет входа на сервер после шторма смены сети")
        print("L2TIMING path-storm pstorm=\(s["pstorm"] ?? -1) conn=\(s["conn"] ?? -1)")
        screenshot("path-storm-done")
        app.terminate()
    }
}
