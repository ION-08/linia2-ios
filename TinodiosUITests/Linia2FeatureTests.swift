//
//  Linia2FeatureTests.swift
//  Линия 2.0: видео-кружки, самоуничтожение, «Информация» о доставке (XCUITest).
//
//  Класс назван TinodiosUITestsFeatures, чтобы идти ПОСЛЕ TinodiosUITests (XCTest сортирует по имени).
//  Собеседник B управляется из теста напрямую по WebSocket Tinode (L2_PEER_LOGIN / L2_PEER_PASSWORD):
//  отмечает прочитанным, пересылает кружок обратно.
//  Окружение: L2_LOGIN, L2_PASSWORD, L2_PEER_NAME, L2_PEER_LOGIN, L2_PEER_PASSWORD, L2_IOS_UID (uid пользователя A).
//

import XCTest

/// Минимальный клиент Tinode (WebSocket) для собеседника в тестах.
final class L2PeerClient {
    private let task: URLSessionWebSocketTask
    private var nextId = 100
    private(set) var uid: String?
    /// Полученные {data} (по порядку).
    private(set) var datas: [[String: Any]] = []

    init() {
        task = URLSession.shared.webSocketTask(with: URL(string: "wss://v2.chat-linia.site/v0/channels?apikey=AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K")!)
        task.resume()
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }

    private func receiveOne(timeout: TimeInterval) -> [String: Any]? {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        task.receive { r in
            if case .success(let m) = r {
                var d: Data?
                switch m {
                case .string(let s): d = s.data(using: .utf8)
                case .data(let x): d = x
                @unknown default: break
                }
                out = d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            }
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success ? out : nil
    }

    /// Отправить {key: body} с id и дождаться ctrl с этим id.
    @discardableResult
    func request(_ key: String, _ body: [String: Any], timeout: TimeInterval = 15) -> [String: Any]? {
        nextId += 1
        let id = String(nextId)
        var b = body
        b["id"] = id
        guard let raw = try? JSONSerialization.data(withJSONObject: [key: b]), let s = String(data: raw, encoding: .utf8) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        task.send(.string(s)) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            guard let m = receiveOne(timeout: max(0.5, end.timeIntervalSinceNow)) else { continue }
            if let d = m["data"] as? [String: Any] { datas.append(d) }
            if let c = m["ctrl"] as? [String: Any], c["id"] as? String == id { return c }
        }
        return nil
    }

    /// Отправить без ожидания ответа (note).
    func fire(_ key: String, _ body: [String: Any]) {
        guard let raw = try? JSONSerialization.data(withJSONObject: [key: body]), let s = String(data: raw, encoding: .utf8) else { return }
        let sem = DispatchSemaphore(value: 0)
        task.send(.string(s)) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
    }

    func login(_ login: String, _ password: String) -> Bool {
        _ = request("hi", ["ver": "0.25"])
        let secret = Data((login + ":" + password).utf8).base64EncodedString()
        guard let c = request("login", ["scheme": "basic", "secret": secret]), (c["code"] as? Int ?? 500) < 300 else { return false }
        uid = (c["params"] as? [String: Any])?["user"] as? String
        return true
    }

    /// Подписаться на чат с пользователем и загрузить последние сообщения.
    func open(_ topic: String) {
        request("sub", ["topic": topic, "get": ["what": "desc data", "data": ["limit": 30]]])
    }

    func fetchLatest(_ topic: String) {
        datas.removeAll()
        request("get", ["topic": topic, "what": "data", "data": ["limit": 30]])
    }

    func noteRead(_ topic: String, seq: Int) {
        fire("note", ["topic": topic, "what": "recv", "seq": seq])
        fire("note", ["topic": topic, "what": "read", "seq": seq])
    }

    @discardableResult
    func publish(_ topic: String, content: Any, head: [String: Any]) -> Int? {
        let c = request("pub", ["topic": topic, "noecho": true, "head": head, "content": content])
        return (c?["params"] as? [String: Any])?["seq"] as? Int
    }
}

final class TinodiosUITestsFeatures: Linia2CallTestBase {
    private static let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
    private var peerName: String { env["L2_PEER_NAME"] ?? "Собеседник CI" }

    override class func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "l2.calltests.login")   // состояние после TinodiosUITests неизвестно
    }

    override class func tearDown() {
        UserDefaults.standard.removeObject(forKey: "l2.calltests.login")
        super.tearDown()
    }

    private func labelContains(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func openPeerChat() {
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        openChat(with: peerName)
        wait(app.textViews["l2.chat.input"].firstMatch, "поле ввода")
    }

    private func send(_ text: String) {
        let input = app.textViews["l2.chat.input"].firstMatch
        input.tap()
        for t in ["Continue", "Продолжить"] where app.buttons[t].firstMatch.waitForExistence(timeout: 1) { app.buttons[t].firstMatch.tap() }
        input.typeText(text)
        app.buttons["l2.chat.send"].firstMatch.tap()
        wait(labelContains(text), "отправленное «\(text)»", timeout: 15)
    }

    private func peer() throws -> (L2PeerClient, String) {
        guard let login = env["L2_PEER_LOGIN"], let pass = env["L2_PEER_PASSWORD"], let a = env["L2_IOS_UID"],
              !login.isEmpty, !pass.isEmpty, !a.isEmpty else {
            throw XCTSkip("нет L2_PEER_PASSWORD / L2_IOS_UID — собеседник не управляется из теста")
        }
        let c = L2PeerClient()
        XCTAssertTrue(c.login(login, pass), "собеседник не вошёл")
        c.open(a)
        return (c, a)
    }

    private func closeSheet() {
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    // MARK: - «Информация» о доставке

    func testF1_ReceiptInfoOpens() {
        openPeerChat()
        let text = "Инфо " + Self.stamp
        send(text)
        sleep(2)
        let pill = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'l2.delivery.'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "нет галочек у своего сообщения")
        labelContains(text).press(forDuration: 1.0)
        wait(any("l2.menu"), "меню сообщения", timeout: 5)
        let info = any("l2.menu.info")
        wait(info, "пункт «Информация»", timeout: 5)
        XCTAssertEqual(info.label, "Информация")
        info.tap()
        wait(any("l2.receipt.sheet"), "лист «Информация о сообщении»", timeout: 10)
        XCTAssertTrue(app.staticTexts["Информация о сообщении"].exists, "нет заголовка листа")
        let p2p = any("l2.receipt.p2p"), none = any("l2.receipt.none")
        let end = Date().addingTimeInterval(15)
        while Date() < end && !p2p.exists && !none.exists { usleep(300_000) }
        XCTAssertTrue(p2p.exists, "нет строки «Отправлено · Доставлено · Прочитано» (или сервер ответил «Нет сведений»)")
        if p2p.exists { XCTAssertTrue(p2p.label.hasPrefix("Отправлено"), "строка: \(p2p.label)") }
        screenshot("receipt-info")
        closeSheet()
    }

    // MARK: - Видео-кружок: отправить, получить, воспроизвести

    private func roundElements() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'l2.round.' AND identifier != 'l2.round.recording'"))
    }

    func testF2_RoundVideoSendReceivePlay() throws {
        openPeerChat()
        let before = roundElements().count
        let rec = app.buttons["l2.chat.send"].firstMatch
        wait(rec, "кнопка записи")
        if rec.value as? String != "камера" { rec.tap(); sleep(1) }
        XCTAssertEqual(rec.value as? String, "камера", "кнопка не переключилась на камеру")
        screenshot("round-camera-mode")
        rec.press(forDuration: 3.0)
        // Кружок появляется в ленте и начинает играть без звука.
        let end = Date().addingTimeInterval(40)
        while Date() < end && roundElements().count <= before { usleep(500_000) }
        XCTAssertGreaterThan(roundElements().count, before, "кружок не появился в чате")
        let mine = roundElements().element(boundBy: roundElements().count - 1)
        let playing = NSPredicate(format: "value CONTAINS 'играет'")
        expectation(for: playing, evaluatedWith: mine)
        waitForExpectations(timeout: 30)
        XCTAssertTrue(mine.label.contains("исчезнет через"), "нет значка «исчезнет через N дн.»: \(mine.label)")
        screenshot("round-sent")
        mine.tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'со звуком'"), evaluatedWith: mine)
        waitForExpectations(timeout: 10)
        mine.tap()   // снова без звука
        rec.tap()    // вернуть микрофон
        sleep(1)

        // Получить: собеседник присылает кружок обратно (то же содержимое).
        let (b, topic) = try peer()
        b.fetchLatest(topic)
        let src = b.datas.reversed().first { d in
            guard let c = d["content"] as? [String: Any], let ents = c["ent"] as? [[String: Any]] else { return false }
            return ents.contains { ($0["tp"] as? String) == "VD" && (($0["data"] as? [String: Any])?["round"] as? Bool) == true }
        }
        guard let content = src?["content"] else { XCTFail("собеседник не видит отправленный кружок"); return }
        let seq = b.publish(topic, content: content, head: ["mime": "text/x-drafty", "linia2-ttl": 604800])
        XCTAssertNotNil(seq, "собеседник не смог отправить кружок")
        let got = any("l2.round.\(seq ?? -1)")
        wait(got, "полученный кружок", timeout: 30)
        expectation(for: playing, evaluatedWith: got)
        waitForExpectations(timeout: 40)
        got.tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'со звуком'"), evaluatedWith: got)
        waitForExpectations(timeout: 10)
        screenshot("round-received-playing")
        got.tap()
    }

    // MARK: - Самоуничтожение: включить → отправить → прочитали → исчезло

    private func isOn(_ burn: XCUIElement) -> Bool {
        burn.label == "Исчезающие сообщения включены" || (burn.value as? String) == "включено"
    }

    func testF3_BurnModeReadThenGone() throws {
        openPeerChat()
        let burn = app.buttons["l2.chat.burn"].firstMatch
        wait(burn, "⏱ в шапке чата")
        if isOn(burn) {   // остался с прошлой попытки
            burn.tap()
            wait(app.alerts.buttons["Выключить"].firstMatch, "«Выключить»").tap()
            sleep(2)
        }
        burn.tap()
        let alert = app.alerts.firstMatch
        wait(alert, "окно исчезающих сообщений", timeout: 5)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'после прочтения'")).firstMatch.exists, "нет пояснения в окне")
        screenshot("burn-alert")
        wait(alert.buttons["Для обоих"], "«Для обоих»").tap()
        let secs = app.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH '20 с'")).firstMatch
        wait(secs, "срок «20 с»", timeout: 5).tap()
        let label = wait(any("l2.chat.burnLabel"), "подпись «Исчезающие сообщения: 20 с после прочтения»", timeout: 15)
        XCTAssertTrue(label.label.contains("20 с после прочтения"), "подпись у поля ввода: \(label.label)")
        wait(labelContains("Вы включили исчезающие сообщения"), "строка «Вы включили исчезающие сообщения» в чате", timeout: 15)
        XCTAssertTrue(isOn(app.buttons["l2.chat.burn"].firstMatch), "значок ⏱ не стал красным (включено)")
        let text = "Сгорит " + Self.stamp
        send(text)
        screenshot("burn-sent")

        // Собеседник читает.
        let (b, topic) = try peer()
        b.fetchLatest(topic)
        let seq = b.datas.compactMap { d -> Int? in
            guard let c = d["content"] as? String, c == text else { return nil }
            return d["seq"] as? Int
        }.max()
        XCTAssertNotNil(seq, "собеседник не получил сообщение")
        b.noteRead(topic, seq: seq ?? 0)
        // Исчезает у обоих.
        let gone = NSPredicate(format: "exists == false")
        // На сообщении — таймер, после прочтения идёт обратный отсчёт (⏱0:1x).
        let timer = any("l2.burn.timer.\(seq ?? -1)")
        if timer.waitForExistence(timeout: 15) {
            let counting = NSPredicate(format: "label BEGINSWITH '⏱0:1' OR label BEGINSWITH '⏱0:0'")
            expectation(for: counting, evaluatedWith: timer)
            waitForExpectations(timeout: 20)
        }
        screenshot("burn-countdown")
        expectation(for: gone, evaluatedWith: labelContains(text))
        waitForExpectations(timeout: 60)   // 20 с после прочтения + доставка
        screenshot("burn-gone")
        b.fetchLatest(topic)
        XCTAssertFalse(b.datas.contains { ($0["content"] as? String) == text }, "у собеседника сообщение осталось")

        // Выключить.
        app.buttons["l2.chat.burn"].firstMatch.tap()
        wait(app.alerts.buttons["Выключить"].firstMatch, "«Выключить»").tap()
        wait(labelContains("Вы выключили исчезающие сообщения"), "строка «Вы выключили исчезающие сообщения»", timeout: 15)
        XCTAssertFalse(any("l2.chat.burnLabel").isHittable, "подпись об исчезающих сообщениях осталась")
    }

    // MARK: - Исчезающие сообщения: совместимость с вебом (переключатель собеседника, linia2-burn у своих)

    func testF4_BurnModeFromPeerWebFormat() throws {
        openPeerChat()
        let (b, topic) = try peer()
        let burn = app.buttons["l2.chat.burn"].firstMatch
        wait(burn, "⏱ в шапке чата")
        if isOn(burn) {   // остался с прошлой попытки
            b.publish(topic, content: "выкл", head: ["linia2-burnmode": "off"])
            sleep(3)
        }
        // Собеседник (веб) включает «для обоих» на 10 с — строками/числами, как шлёт веб.
        let on = b.publish(topic, content: peerName + " включил(а) исчезающие сообщения: 10 с после прочтения",
                           head: ["linia2-burnmode": "on", "linia2-burn-scope": "both", "linia2-burn-secs": 10])
        XCTAssertNotNil(on, "собеседник не смог включить режим")
        wait(labelContains("включил(а) исчезающие сообщения: 10 с после прочтения"), "системная строка от собеседника", timeout: 20)
        let label = wait(any("l2.chat.burnLabel"), "подпись у поля ввода", timeout: 15)
        XCTAssertTrue(label.label.contains("10 с после прочтения"), "подпись: \(label.label)")
        let end = Date().addingTimeInterval(10)
        while Date() < end && !isOn(app.buttons["l2.chat.burn"].firstMatch) { usleep(300_000) }
        XCTAssertTrue(isOn(app.buttons["l2.chat.burn"].firstMatch), "⏱ не покраснел у получателя")
        screenshot("burn-peer-on")

        // Своё сообщение уходит с "linia2-burn": 10 (число).
        let text = "Веб-формат " + Self.stamp
        send(text)
        sleep(2)
        b.fetchLatest(topic)
        let mine = b.datas.last(where: { ($0["content"] as? String) == text })
        let head = mine?["head"] as? [String: Any]
        XCTAssertEqual((head?["linia2-burn"] as? NSNumber)?.intValue, 10, "нет linia2-burn: 10 в head: \(String(describing: head))")

        // Сообщение собеседника в режиме исчезает у получателя (чат открыт — прочитано).
        let ptext = "От собеседника " + Self.stamp
        let pseq = b.publish(topic, content: ptext, head: ["linia2-burn": 10])
        XCTAssertNotNil(pseq, "собеседник не отправил сообщение")
        wait(labelContains(ptext), "сообщение собеседника", timeout: 20)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: labelContains(ptext))
        waitForExpectations(timeout: 45)
        screenshot("burn-peer-gone")

        // Собеседник выключает — у получателя тоже выкл. (режим был «для обоих»).
        b.publish(topic, content: peerName + " выключил(а) исчезающие сообщения", head: ["linia2-burnmode": "off"])
        wait(labelContains("выключил(а) исчезающие сообщения"), "строка «выключил(а)»", timeout: 20)
        let end2 = Date().addingTimeInterval(10)
        while Date() < end2 && isOn(app.buttons["l2.chat.burn"].firstMatch) { usleep(300_000) }
        XCTAssertFalse(isOn(app.buttons["l2.chat.burn"].firstMatch), "⏱ остался красным после выключения собеседником")
        // После выключения новые сообщения хранятся (без linia2-burn).
        let keep = "Хранится " + Self.stamp
        send(keep)
        sleep(2)
        b.fetchLatest(topic)
        let kh = b.datas.last(where: { ($0["content"] as? String) == keep })?["head"] as? [String: Any]
        XCTAssertNil(kh?["linia2-burn"], "после выключения сообщение всё ещё с linia2-burn")
    }

    // MARK: - Звонок: разговорный динамик по умолчанию, кнопка «Динамик», датчик приближения

    private func speakerValue() -> String { (any("l2.call.speaker").value as? String) ?? "" }

    private func waitSpeaker(_ prefix: String, _ what: String) {
        let end = Date().addingTimeInterval(8)
        while Date() < end && !speakerValue().hasPrefix(prefix) { usleep(300_000) }
        XCTAssertTrue(speakerValue().hasPrefix(prefix), "\(what): «Динамик» = «\(speakerValue())», ожидалось «\(prefix)…»")
    }

    func testF5_CallSpeakerDefaults() {
        openPeerChat()
        // Аудиозвонок: у уха (динамик выкл.), датчик приближения включён.
        startCall(video: false)
        wait(any("l2.call.speaker"), "кнопка «Динамик»")
        waitSpeaker("выключен", "аудио по умолчанию")
        XCTAssertTrue(speakerValue().contains("датчик приближения"), "аудиозвонок: датчик приближения не включён (\(speakerValue()))")
        screenshot("call-audio-earpiece")
        any("l2.call.speaker").tap()
        waitSpeaker("включён", "после нажатия «Динамик»")
        XCTAssertFalse(speakerValue().contains("датчик приближения"), "громкая связь: датчик приближения должен выключиться")
        screenshot("call-audio-speaker")
        any("l2.call.speaker").tap()
        waitSpeaker("выключен", "повторное нажатие «Динамик»")
        XCTAssertTrue(speakerValue().contains("датчик приближения"), "у уха снова: датчик приближения не включился")
        hangUp("аудио (динамик)")
        sleep(3)

        // Видеозвонок: громкий динамик по умолчанию, датчик выключен.
        startCall(video: true)
        wait(any("l2.call.speaker"), "кнопка «Динамик» (видео)")
        waitSpeaker("включён", "видео по умолчанию")
        XCTAssertFalse(speakerValue().contains("датчик приближения"), "видеозвонок: датчик приближения должен быть выключен")
        screenshot("call-video-speaker")
        hangUp("видео (динамик)")
    }
}
