//
//  Linia2PanicTests.swift
//  Линия 2.0: стирание данных по коду, введённому на экране PIN («код паники»), — XCUITest.
//
//  В интерфейсе приложения функции нет; состояние проверяется через тестовый крючок «l2.test.state»
//  (только под -l2-uitest, см. Tinodios/Linia2TestHook.swift): счётчики записей базы и файлов.
//
//  P1 — Face ID / Touch ID нигде не запрашивается и не упоминается (PIN, настройки, системные окна).
//  P2…P4, P9 — уровни 1, 2, 3, 4: до — в базе есть сообщения (зашифрованные), файлы, код; ввод кода →
//        приложение открывается пустым (1–2) или экран входа с нейтральной ошибкой (3–4) → перезапуск →
//        нет ни чата, ни сообщения, ни файла, уведомления очищены, код больше не хранится, обычный PIN
//        работает как раньше (1–2); время ответа экрана на код и на PIN совпадает (±150 мс).
//  P5 — 10 неверных PIN подряд (флаг wipe_on_fail) → стирание.
//  Настройка — L2_WIPE_OVERRIDE (как ответ сервера; поле "code" — открытый код для теста).
//  Серверная проверка (L2_WIPE_SERVER=1; уровень — L2_WIPE_SERVER_LEVEL, по умолчанию 2): код задаётся
//  через POST /invite/api/panic/settings (пароль A), приложение берёт настройку с сервера, после
//  срабатывания у собеседника B сообщения A удалены (L2PeerClient). На сервере код срабатывает один раз
//  на пользователя (дальше «Вернуть» в админке), поэтому так проверяется один уровень.
//  Окружение: L2_LOGIN/L2_PASSWORD (A), L2_PEER_LOGIN/L2_PEER_PASSWORD (B), L2_PEER_NAME, L2_IOS_UID (uid A).
//

import XCTest

final class Linia2PanicTests: Linia2CallTestBase {
    private static let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
    private let code = "2468"
    private var peerName: String { env["L2_PEER_NAME"] ?? "Собеседник CI" }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var serverMode: Bool { env["L2_WIPE_SERVER"] == "1" }
    private var serverLevel: Int { Int(env["L2_WIPE_SERVER_LEVEL"] ?? "") ?? 2 }

    override class func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "l2.calltests.login")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        app.launchArguments += ["-l2-push-auth"]
        app.launchEnvironment["L2_TEST_SEED"] = "1"
    }

    // MARK: - Крючок

    private func state(_ step: String) -> [String: Int] {
        let e = any("l2.test.state")
        guard e.waitForExistence(timeout: 10), let v = e.value as? String else {
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

    /// Дождаться, пока значение крючка удовлетворит условию (до timeout).
    @discardableResult
    private func waitState(_ step: String, timeout: TimeInterval = 20, _ ok: ([String: Int]) -> Bool) -> [String: Int] {
        let end = Date().addingTimeInterval(timeout)
        var s = state(step)
        while !ok(s) && Date() < end {
            sleep(1)
            s = state(step)
        }
        return s
    }

    // MARK: - Помощники

    private func override(level: Int, failWipe: Bool = false) -> String {
        "{\"code\":\"\(code)\",\"level\":\(level),\"delete_peers\":true,\"wipe_on_fail\":\(failWipe),\"show\":true}"
    }

    private func type(_ digits: String) {
        for d in digits { app.buttons[String(d)].firstMatch.tap() }
    }

    private var pinTitle: XCUIElement { app.staticTexts["Введите PIN-код"] }

    private func allowNotifications() {
        let end = Date().addingTimeInterval(6)
        while Date() < end {
            for t in ["Allow", "Разрешить"] where springboard.buttons[t].exists {
                springboard.buttons[t].tap()
                return
            }
            usleep(300_000)
        }
    }

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

    /// Холодный запуск → экран PIN → ввод; время ответа экрана (мс, по крючку).
    private func relaunchAndEnter(_ digits: String, _ step: String) -> Int {
        app.terminate()
        app.launch()
        wait(pinTitle, "экран PIN — \(step)", timeout: 25)
        sleep(1)
        screenshot(step + "-pin")
        type(digits)
        let gone = Date().addingTimeInterval(10)
        while Date() < gone && pinTitle.exists { usleep(100_000) }
        return state(step)["pinms"] ?? -1
    }

    private func assertNoBiometry(_ step: String) {
        for t in ["Face ID", "Touch ID", "faceid", "touchid"] {
            let p = NSPredicate(format: "label CONTAINS[c] %@", t)
            XCTAssertFalse(app.descendants(matching: .any).matching(p).firstMatch.exists, "в приложении «\(t)» — \(step)")
            XCTAssertFalse(springboard.descendants(matching: .any).matching(p).firstMatch.exists, "системный запрос «\(t)» — \(step)")
        }
    }

    /// Состояние «до»: A вошёл, B прислал свежее сообщение, чат открыт — в базе есть сообщения, файлы, код.
    private func prepare(level: Int, failWipe: Bool = false, server: Bool = false) throws -> (L2PeerClient, String, String) {
        let (c, topic) = try peer()
        if server {
            app.launchEnvironment["L2_WIPE_OVERRIDE"] = nil
        } else {
            app.launchEnvironment["L2_WIPE_OVERRIDE"] = override(level: level, failWipe: failWipe)
        }
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        allowNotifications()
        if server { try enableOnServer(level: level) }
        let tag = "W\(level)-" + Self.stamp
        XCTAssertNotNil(c.publish(topic, content: "Перед стиранием \(tag)", head: [:]), "B не отправил сообщение")
        openChat(with: peerName)
        // Своё сообщение — чтобы проверить удаление у собеседника.
        let input = app.textViews["l2.chat.input"].firstMatch
        if input.waitForExistence(timeout: 10) {
            input.tap()
            for t in ["Continue", "Продолжить"] where app.buttons[t].firstMatch.waitForExistence(timeout: 1) { app.buttons[t].firstMatch.tap() }
            input.typeText("Моё \(tag)")
            app.buttons["l2.chat.send"].firstMatch.tap()
            sleep(2)
        }
        let s = waitState("до-\(level)", timeout: server ? 40 : 20) { ($0["msgs"] ?? 0) > 0 && ($0["cfg"] ?? 0) == 1 && ($0["files"] ?? 0) > 0 }
        XCTAssertGreaterThan(s["msgs"] ?? 0, 0, "до стирания в базе нет сообщений")
        XCTAssertEqual(s["plain"], 0, "в базе есть незашифрованные сообщения")
        XCTAssertEqual(s["cfg"], 1, "код не получен")
        XCTAssertEqual(s["kdf"], 1, "scrypt не совпал с RFC 7914")
        XCTAssertGreaterThan(s["files"] ?? 0, 0, "тестовые файлы не созданы")
        screenshot("before-\(level)")
        app.launchEnvironment["L2_TEST_SEED"] = "0"   // дальше файлы не подкладывать (иначе появятся после стирания)
        return (c, topic, tag)
    }

    // MARK: - Сервер (L2_WIPE_SERVER=1)

    private func enableOnServer(level: Int) throws {
        let ws = L2PeerClient()
        _ = ws.request("hi", ["ver": "0.25"])
        let secret = Data((requireEnv("L2_LOGIN") + ":" + requireEnv("L2_PASSWORD")).utf8).base64EncodedString()
        guard let ctrl = ws.request("login", ["scheme": "basic", "secret": secret]),
              let token = (ctrl["params"] as? [String: Any])?["token"] as? String else {
            XCTFail("A не вошёл для настройки на сервере"); return
        }
        var req = URLRequest(url: URL(string: "https://v2.chat-linia.site/invite/api/panic/settings")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "password": requireEnv("L2_PASSWORD"), "enabled": true, "code": code, "level": level,
            "delete_peers": true, "wipe_on_fail": false,
        ] as [String: Any])
        let sem = DispatchSemaphore(value: 0)
        var status = 0
        var body = ""
        URLSession.shared.dataTask(with: req) { d, r, _ in
            status = (r as? HTTPURLResponse)?.statusCode ?? 0
            body = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        XCTAssertEqual(status, 200, "panic/settings: \(status) \(body)")
        // Приложение перечитывает настройку при возврате из фона.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        if pinTitle.waitForExistence(timeout: 3) { enterPin() }
    }

    /// У собеседника B больше нет сообщения A с меткой.
    private func assertPeerDeleted(_ c: L2PeerClient, _ topic: String, _ tag: String) {
        let end = Date().addingTimeInterval(120)
        var still = true
        while Date() < end {
            c.fetchLatest(topic)
            still = c.datas.contains { d in
                (d["content"] as? String)?.contains("Моё \(tag)") == true ||
                    ((d["content"] as? [String: Any])?["txt"] as? String)?.contains("Моё \(tag)") == true
            }
            if !still { break }
            sleep(5)
        }
        XCTAssertFalse(still, "у собеседника осталось сообщение A после серверного удаления")
    }

    // MARK: - Общий сценарий уровня

    private func runLevel(_ level: Int) throws {
        let server = serverMode && level == serverLevel
        let (c, topic, tag) = try prepare(level: level, server: server)

        // Обычный PIN: время ответа экрана.
        let pinMs = relaunchAndEnter("1357", "pin-\(level)")
        wait(tab("l2.tab.chats"), "вкладки после PIN", timeout: 20)
        XCTAssertEqual(state("после-PIN-\(level)")["wipes"], 0, "обычный PIN что-то стёр")

        // Код.
        let codeMs = relaunchAndEnter(code, "code-\(level)")
        assertNoBiometry("после кода \(level)")
        XCTAssertGreaterThan(pinMs, 0)
        XCTAssertGreaterThan(codeMs, 0)
        XCTAssertLessThanOrEqual(abs(codeMs - pinMs), 150, "время ответа: PIN \(pinMs) мс, код \(codeMs) мс")
        let a = XCTAttachment(string: "PIN \(pinMs) мс, код \(codeMs) мс")
        a.name = "timing-\(level)"
        a.lifetime = .keepAlways
        add(a)

        if level <= 2 {
            wait(tab("l2.tab.chats"), "приложение открылось после кода", timeout: 20)
            XCTAssertFalse(app.alerts.firstMatch.exists, "после кода показан вопрос/предупреждение")
        } else {
            wait(app.buttons["l2.welcome.login"], "экран входа после кода (уровень \(level))", timeout: 20)
            let msg = app.alerts.staticTexts["Не удалось подключиться к серверу. Повторите попытку позже."].firstMatch
            wait(msg, "нейтральная ошибка", timeout: 10)
            screenshot("neutral-error-\(level)")
            app.alerts.buttons.firstMatch.tap()
            UserDefaults.standard.removeObject(forKey: "l2.calltests.login")
        }
        let after = waitState("после-кода-\(level)", timeout: 25) { ($0["files"] ?? 1) == 0 && ($0["msgs"] ?? 1) == 0 }
        XCTAssertEqual(after["wipes"], 1, "стирание не выполнено")
        XCTAssertEqual(after["msgs"], 0, "остались сообщения")
        XCTAssertEqual(after["chats"], 0, "остались чаты в списке")
        XCTAssertEqual(after["files"], 0, "остались файлы")
        XCTAssertEqual(after["notif"], 0, "остались уведомления")
        XCTAssertEqual(after["cfg"], 0, "код всё ещё хранится")
        if level >= 3 {
            XCTAssertEqual(after["topics"], 0, "после выхода в базе остались чаты")
            XCTAssertEqual(after["users"], 0, "после выхода в базе остались пользователи")
        }
        screenshot("after-\(level)")

        // Перезапуск без настройки: всё так же пусто; код больше не действует; PIN — как раньше.
        app.launchEnvironment["L2_WIPE_OVERRIDE"] = nil
        if level <= 2 {
            _ = relaunchAndEnter(code, "code-again-\(level)")
            XCTAssertTrue(pinTitle.exists, "код сработал повторно / не отклонён")
            XCTAssertEqual(state("код-повторно-\(level)")["wipes"], 0)
            sleep(1)
            type("1357")
            let gone = Date().addingTimeInterval(10)
            while Date() < gone && pinTitle.exists { usleep(100_000) }
            wait(tab("l2.tab.chats"), "PIN работает после стирания", timeout: 20)
            sleep(6)   // переподключение и синхронизация с сервером
            let s = state("перезапуск-\(level)")
            XCTAssertEqual(s["msgs"], 0, "после синхронизации вернулись сообщения")
            XCTAssertEqual(s["chats"], 0, "после синхронизации вернулись чаты")
            XCTAssertEqual(s["files"], 0)
            XCTAssertEqual(s["notif"], 0)
            XCTAssertEqual(s["keys"], 1, "нет нового ключа хранилища")
            // Новое сообщение после стирания показывается как обычно.
            XCTAssertNotNil(c.publish(topic, content: "После стирания \(tag)", head: [:]))
            let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", peerName)).firstMatch
            wait(row, "чат с новым сообщением после стирания", timeout: 30)
        } else {
            app.terminate()
            app.launch()
            wait(app.buttons["l2.welcome.login"], "после перезапуска — экран входа", timeout: 25)
            let s = state("перезапуск-\(level)")
            XCTAssertEqual(s["msgs"], 0)
            XCTAssertEqual(s["topics"], 0)
            XCTAssertEqual(s["files"], 0)
        }
        assertNoBiometry("перезапуск \(level)")
        if server {
            assertPeerDeleted(c, topic, tag)
        }
    }

    // MARK: - Тесты

    func testP1_NoBiometryAnywhere() {
        app.launchEnvironment["L2_WIPE_OVERRIDE"] = nil
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        assertNoBiometry("после входа")
        tab("l2.tab.settings").tap(); sleep(1)
        wait(app.staticTexts["Конфиденциальность"].firstMatch, "«Конфиденциальность»").tap(); sleep(1)
        assertNoBiometry("Конфиденциальность")
        wait(app.staticTexts["Блокировка приложения"].firstMatch, "«Блокировка приложения»").tap(); sleep(1)
        assertNoBiometry("Блокировка приложения")
        screenshot("applock-settings")
        app.terminate()
        app.launch()
        wait(pinTitle, "экран PIN", timeout: 25)
        sleep(2)
        assertNoBiometry("экран PIN")
        screenshot("pin-no-biometry")
        enterPin()
        wait(tab("l2.tab.chats"), "вход по PIN", timeout: 20)
    }

    func testP2_Level1_DeviceOnly() throws { try runLevel(1) }

    func testP3_Level2_DeviceAndServer() throws { try runLevel(2) }

    func testP4_Level3_Logout() throws { try runLevel(3) }

    func testP5_TenWrongPins() throws {
        _ = try prepare(level: 1, failWipe: true)
        app.launchEnvironment["L2_PIN_COOLDOWN"] = "0"
        app.terminate()
        app.launch()
        wait(pinTitle, "экран PIN", timeout: 25)
        sleep(1)
        for i in 1...10 {
            type("0000")
            usleep(1_200_000)
            if i < 10 { XCTAssertEqual(state("неверный-\(i)")["wipes"], 0, "стёрто раньше 10-й попытки (\(i))") }
        }
        let s = waitState("после-10", timeout: 20) { ($0["wipes"] ?? 0) == 1 && ($0["files"] ?? 1) == 0 }
        XCTAssertEqual(s["wipes"], 1, "10 неверных PIN — стирания нет")
        XCTAssertEqual(s["msgs"], 0)
        XCTAssertEqual(s["chats"], 0)
        XCTAssertEqual(s["files"], 0)
        app.launchEnvironment["L2_PIN_COOLDOWN"] = nil
        app.launchEnvironment["L2_WIPE_OVERRIDE"] = nil
    }

    /// Последним: на сервере уровень 4 удаляет аккаунт.
    func testP9_Level4_DeleteAccount() throws { try runLevel(4) }
}
