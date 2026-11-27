//
//  Linia2CallTests.swift
//  Линия 2.0: сквозные звонки (обязательны для выпуска; «пропущен» недопустим).
//
//  Linia2CallTests — основной симулятор, пользователь A (L2_LOGIN):
//    1. iOS → iOS (аудио): A звонит C — на втором симуляторе Linia2CallPeerTests принимает;
//    2. iOS → веб (аудио) и 3. iOS → веб (видео): веб-собеседник B (ci/web-tests/call-scenario.mjs) принимает;
//    4. веб → iOS (аудио) и 5. веб → iOS (видео): B звонит, A принимает.
//  В каждом: гудки → «Принять» → соединение держится 60+ с («Идёт звонок» и таймер ≥ 01:00) →
//  микрофон и камера выкл/вкл → «Положить трубку» (кладёт iOS) → экран звонка закрылся → запись в «Звонках».
//  Linia2CallPeerTests — второй симулятор, пользователь C: ждёт входящий, принимает, держит, проверяет кнопки,
//  ждёт завершения со стороны A и запись в «Звонках».
//  7–9. Обрыв сети посреди звонка iOS → веб (аудио) на 5, 15 и 35 с: тестовые кнопки экрана звонка (только под
//  -l2-uitest) закрывают веб-сокет Tinode и запрещают переподключение на N с, останавливают отправку RTP и
//  помечают медиапуть потерянным (как при смене сети) → после паузы — вход, подписка, ICE restart (offer/answer
//  через Tinode, тот же seq). 5 и 15 с: «Переподключение…», затем снова «Идёт звонок» и байты аудио растут в обе
//  стороны; 35 с: через 30 с «Связь потеряна» и экран звонка закрывается. Веб (B) в это время держит звонок.
//
//  Окружение (TEST_RUNNER_*): L2_LOGIN/L2_PASSWORD (A), L2_PEER_NAME (B, «Собеседник CI»),
//  L2_C_LOGIN/L2_C_PASSWORD (C), L2_C_NAME («Собеседник iOS»), L2_A_NAME (имя A у C, «Тест CI»).
//

import XCTest
import UIKit

class Linia2CallTestBase: XCTestCase {
    var app: XCUIApplication!
    let env = ProcessInfo.processInfo.environment
    private var shot = 0
    private let pin = ["1", "3", "5", "7"]
    static let holdSeconds = 62

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-l2-uitest"]
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Системные запросы") { alert in
            for t in ["Allow", "Разрешить", "OK", "Allow While Using App"] where alert.buttons[t].exists {
                alert.buttons[t].tap(); return true
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 || run.unexpectedExceptionCount > 0 {
            screenshot("ПАДЕНИЕ")
        }
    }

    func screenshot(_ name: String) {
        shot += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%@-%02d-%@", String(self.name.split(separator: " ").last ?? "t").replacingOccurrences(of: "]", with: ""), shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    func requireEnv(_ k: String) -> String {
        guard let v = env[k], !v.isEmpty else { XCTFail("Нет переменной окружения \(k)"); return "" }
        return v
    }

    @discardableResult
    func wait(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 20) -> XCUIElement {
        if !e.waitForExistence(timeout: timeout) {
            screenshot("НЕ НАЙДЕНО-" + what)
            XCTFail("Не появился элемент: \(what)")
        }
        return e
    }

    func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func tab(_ id: String) -> XCUIElement {
        app.otherElements[id].firstMatch.exists ? app.otherElements[id].firstMatch : any(id)
    }

    func dismissSpringboardAlerts() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for t in ["Allow", "Разрешить", "OK", "Allow While Using App"] where sb.buttons[t].exists { sb.buttons[t].tap() }
    }

    func enterPin() { for d in pin { app.buttons[d].firstMatch.tap() } }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap() }
        sleep(1)
    }

    /// Запуск и вход нужным пользователем (если уже вошёл кто-то другой — выход).
    func ensureLoggedIn(_ login: String, _ password: String) {
        app.launch()
        dismissSpringboardAlerts()
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if app.staticTexts["Введите PIN-код"].exists { enterPin(); _ = tab("l2.tab.chats").waitForExistence(timeout: 20) }
            if tab("l2.tab.chats").exists || app.buttons["l2.welcome.login"].exists { break }
            usleep(300_000)
        }
        if tab("l2.tab.chats").exists {
            if currentLogin() == login { tab("l2.tab.chats").tap(); sleep(1); return }
            logout()
        }
        if !app.buttons["l2.welcome.login"].exists { for _ in 0..<3 where !app.buttons["l2.welcome.login"].exists { back() } }
        wait(app.buttons["l2.welcome.login"], "стартовый экран").tap()
        let lf = wait(app.textFields["l2.login.login"], "поле логина")
        lf.tap()
        for t in ["Continue", "Продолжить"] where app.buttons[t].firstMatch.waitForExistence(timeout: 1) { app.buttons[t].firstMatch.tap() }
        lf.typeText(login + "\n")
        app.typeText(password + "\n")
        wait(app.staticTexts["Придумайте PIN-код"], "создание PIN", timeout: 40)
        enterPin()
        wait(app.staticTexts["Повторите PIN-код"], "повтор PIN", timeout: 10)
        enterPin()
        let skip = app.buttons["Не сейчас"]
        if skip.waitForExistence(timeout: 3) { skip.tap() }
        wait(tab("l2.tab.chats"), "вкладки после входа", timeout: 30)
        UserDefaults.standard.set(login, forKey: "l2.calltests.login")
        sleep(2)
    }

    /// Кто вошёл — запоминаем сами (в пределах симулятора тест-раннер один).
    private func currentLogin() -> String? { UserDefaults.standard.string(forKey: "l2.calltests.login") }

    func logout() {
        tab("l2.tab.settings").tap(); sleep(1)
        let out = app.staticTexts["Выйти"].firstMatch
        if !out.isHittable { app.swipeUp() }
        wait(out, "«Выйти»").tap()
        let confirm = app.alerts.buttons["Выйти"].firstMatch.waitForExistence(timeout: 4) ? app.alerts.buttons["Выйти"].firstMatch : app.sheets.buttons["Выйти"].firstMatch
        wait(confirm, "подтверждение выхода").tap()
        wait(app.buttons["l2.welcome.login"], "стартовый экран после выхода", timeout: 20)
        UserDefaults.standard.removeObject(forKey: "l2.calltests.login")
    }

    func openChat(with name: String) {
        tab("l2.tab.chats").tap(); sleep(1)
        let cell = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        wait(cell, "чат с «\(name)»", timeout: 30).tap()
        let input = app.textViews["l2.chat.input"].firstMatch
        _ = input.waitForExistence(timeout: 15)
        sleep(2)
    }

    /// Позвонить из открытого чата.
    func startCall(video: Bool) {
        // Отдельные кнопки 📞 / 📹 в шапке — звонок начинается сразу.
        let direct = app.buttons[video ? "l2.chat.video" : "l2.chat.call"].firstMatch
        if direct.waitForExistence(timeout: 5) {
            direct.tap()
            dismissSpringboardAlerts()
            let allowMic = any("l2.call.micAllow")
            if allowMic.waitForExistence(timeout: 3) { allowMic.tap(); sleep(1); dismissSpringboardAlerts() }
            wait(any("l2.call.state"), "экран звонка", timeout: 20)
            screenshot(video ? "video-dialing" : "audio-dialing")
            return
        }
        let call = app.buttons["l2.chat.call"].firstMatch.exists ? app.buttons["l2.chat.call"].firstMatch : app.navigationBars.buttons["Позвонить"].firstMatch
        wait(call, "кнопка звонка в шапке чата").tap()
        let item = video ? (app.buttons["Видео"].firstMatch.exists ? app.buttons["Видео"].firstMatch : app.buttons["Video"].firstMatch)
                         : (app.buttons["Только звук"].firstMatch.exists ? app.buttons["Только звук"].firstMatch : app.buttons["Audio-only"].firstMatch)
        if !item.waitForExistence(timeout: 5) {
            // Подписи меню могут быть другими — ищем по смыслу.
            let p = video ? NSPredicate(format: "label CONTAINS[c] 'видео' OR label CONTAINS[c] 'video'")
                          : NSPredicate(format: "label CONTAINS[c] 'звук' OR label CONTAINS[c] 'аудио' OR label CONTAINS[c] 'audio'")
            wait(app.buttons.matching(p).firstMatch, video ? "пункт «Видео»" : "пункт «Аудио»", timeout: 5).tap()
        } else {
            item.tap()
        }
        dismissSpringboardAlerts()
        wait(any("l2.call.state"), "экран звонка", timeout: 20)
        screenshot(video ? "video-dialing" : "audio-dialing")
    }

    /// Ждать входящий (алерт приложения под -l2-uitest) и принять.
    func acceptIncoming(timeout: TimeInterval) {
        let alert = app.alerts["Входящий звонок"].firstMatch
        if !alert.waitForExistence(timeout: timeout) {
            screenshot("нет-входящего")
            XCTFail("Не пришёл входящий звонок за \(Int(timeout)) с")
            return
        }
        screenshot("incoming")
        alert.buttons["Принять"].tap()
        dismissSpringboardAlerts()
        wait(any("l2.call.state"), "экран звонка после «Принять»", timeout: 30)
    }

    /// Байты аудио (приём, передача) из accessibilityValue «arx=N atx=M» у l2.call.state.
    func audioBytes() -> (rx: Int, tx: Int)? {
        let e = any("l2.call.state")
        guard e.exists, let v = e.value as? String else { return nil }
        let nums = v.split(separator: " ").compactMap { Int($0.split(separator: "=").last ?? "") }
        return nums.count == 2 ? (nums[0], nums[1]) : nil
    }

    /// Байты аудио растут в обе стороны (за `timeout` с); возвращает время ожидания или nil.
    func waitAudioBothWays(timeout: TimeInterval) -> TimeInterval? {
        let t0 = Date()
        var base: (rx: Int, tx: Int)?
        while Date().timeIntervalSince(t0) < timeout {
            if let b = audioBytes() {
                if let b0 = base {
                    if b.rx > b0.rx && b.tx > b0.tx { return Date().timeIntervalSince(t0) }
                } else {
                    base = b
                }
            }
            usleep(250_000)
        }
        return nil
    }

    var callStateLabel: String { any("l2.call.state").exists ? any("l2.call.state").label : "нет экрана" }

    /// Секунды из «Идёт звонок мм:сс» / «Плохая связь · мм:сс»; nil — не соединено.
    func connectedSeconds() -> Int? {
        let e = any("l2.call.state")
        guard e.exists else { return nil }
        let s = e.label
        guard s.hasPrefix("Идёт звонок") || s.hasPrefix("Плохая связь") else { return nil }
        let parts = s.split(separator: " ").last?.split(separator: ":") ?? []
        guard parts.count == 2, let m = Int(parts[0]), let sec = Int(parts[1]) else { return nil }
        return m * 60 + sec
    }

    /// Соединение установилось и держится не меньше holdSeconds (таймер идёт).
    func holdConnected(_ what: String) {
        let end = Date().addingTimeInterval(90)
        while connectedSeconds() == nil && Date() < end { usleep(500_000) }
        guard let first = connectedSeconds() else {
            screenshot("не-соединилось")
            XCTFail("\(what): не соединилось за 90 с (состояние: \(any("l2.call.state").exists ? any("l2.call.state").label : "нет экрана"))")
            return
        }
        screenshot("connected")
        let holdEnd = Date().addingTimeInterval(TimeInterval(Self.holdSeconds - first + 3))
        var last = first
        while Date() < holdEnd {
            guard any("l2.call.state").exists, let s = connectedSeconds() else {
                screenshot("обрыв")
                XCTFail("\(what): звонок оборвался через \(last) с")
                return
            }
            last = s
            sleep(2)
        }
        XCTAssertGreaterThanOrEqual(last, 60, "\(what): таймер не дошёл до 01:00 (\(last) с)")
        screenshot("held-\(last)s")
    }

    /// Подпись элемента стала (`equal: true`) или перестала быть (`false`) равной `label` — ждём до `timeout` с.
    private func waitLabel(_ id: String, _ label: String, equal: Bool, timeout: TimeInterval) -> String {
        let end = Date().addingTimeInterval(timeout)
        var cur = any(id).label
        while (cur == label) != equal && Date() < end { usleep(200_000); cur = any(id).label }
        return cur
    }

    /// Микрофон и камера: выкл → вкл (по подписям доступности). Подпись должна смениться не позже чем через 2 с.
    func toggleMicAndCamera(_ what: String) {
        let mic = any("l2.call.mic")
        wait(mic, "кнопка микрофона")
        let mic0 = mic.label
        mic.tap()
        XCTAssertNotEqual(waitLabel("l2.call.mic", mic0, equal: false, timeout: 2), mic0, "\(what): микрофон не переключился")
        screenshot("mic-off")
        any("l2.call.mic").tap()
        XCTAssertEqual(waitLabel("l2.call.mic", mic0, equal: true, timeout: 2), mic0, "\(what): микрофон не вернулся")
        let cam = any("l2.call.video")
        wait(cam, "кнопка камеры")
        let cam0 = cam.label
        cam.tap()
        XCTAssertNotEqual(waitLabel("l2.call.video", cam0, equal: false, timeout: 2), cam0, "\(what): камера не переключилась")
        screenshot("camera-toggled")
        any("l2.call.video").tap()
        XCTAssertEqual(waitLabel("l2.call.video", cam0, equal: true, timeout: 2), cam0, "\(what): камера не вернулась")
        XCTAssertNotNil(connectedSeconds(), "\(what): звонок оборвался после переключения микрофона/камеры")
        screenshot("toggled")
    }

    /// «Положить трубку» — экран звонка должен исчезнуть мгновенно (< 300 мс):
    ///  • в приложении — hupms (от «Завершить» до закрытия экрана, тестовый крючок l2.test.state);
    ///  • в тесте — от возврата tap() до первого «экрана нет» (опрос каждые 20 мс).
    /// Время нажатия (мс с 1970) — в $L2_SYNC_DIR/ios-hangup.txt: веб (call-scenario.mjs) проверяет, что у него
    /// звонок закрылся < 2 с после нажатия (симулятор и браузер на одном Mac — общие часы).
    func hangUp(_ what: String) {
        let button = wait(any("l2.call.hangup"), "«Положить трубку»")
        let tapAt = Date()
        button.tap()
        let tapped = Date()
        syncWrite("ios-hangup", tapAt)
        while any("l2.call.hangup").exists && Date().timeIntervalSince(tapped) < 15 { usleep(20_000) }
        let goneMs = Int(Date().timeIntervalSince(tapped) * 1000)
        let totalMs = Int(Date().timeIntervalSince(tapAt) * 1000)
        let appMs = callHook("hangup")["hupms"] ?? -1
        note("\(what): «Завершить» → экран закрыт: в приложении \(appMs) мс, в тесте \(goneMs) мс после tap (всего с tap \(totalMs) мс)")
        XCTAssertTrue(appMs >= 0 && appMs < 300, "\(what): экран звонка закрывается \(appMs) мс после «Завершить» (нужно < 300)")
        XCTAssertLessThan(goneMs, 300, "\(what): экран звонка исчез через \(goneMs) мс после нажатия (нужно < 300)")
        assertCallClosed(what, timeout: 15)
    }

    /// Звонок завершил собеседник (веб): экран звонка у iOS закрывается < 2 с после его «Завершить»
    /// (метка времени веба — $L2_SYNC_DIR/web-hangup.txt, пишет call-scenario.mjs).
    func waitRemoteHangup(_ what: String, timeout: TimeInterval) {
        let start = Date()
        while any("l2.call.hangup").exists && Date().timeIntervalSince(start) < timeout { usleep(20_000) }
        let closedAt = Date()
        XCTAssertFalse(any("l2.call.hangup").exists, "\(what): собеседник не завершил / экран звонка не закрылся за \(Int(timeout)) с")
        if let web = syncRead("web-hangup"), web > start.addingTimeInterval(-120) {
            let ms = Int(closedAt.timeIntervalSince(web) * 1000)
            note("\(what): веб завершил → экран iOS закрыт через \(ms) мс")
            XCTAssertLessThan(ms, 2000, "\(what): после завершения у веба экран iOS закрылся через \(ms) мс (нужно < 2 с)")
        } else {
            XCTFail("\(what): нет метки времени завершения от веба (L2_SYNC_DIR)")
        }
        assertCallClosed(what, timeout: 5)
    }

    // MARK: Обмен метками времени с веб-собеседником (общий каталог на Mac)

    private var syncDir: String? { env["L2_SYNC_DIR"].flatMap { $0.isEmpty ? nil : $0 } }

    func syncWrite(_ name: String, _ t: Date) {
        guard let d = syncDir else { return }
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try? String(Int64(t.timeIntervalSince1970 * 1000)).write(toFile: d + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }

    func syncRead(_ name: String) -> Date? {
        guard let d = syncDir, let s = try? String(contentsOfFile: d + "/" + name + ".txt", encoding: .utf8),
              let ms = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    func note(_ text: String) {
        let a = XCTAttachment(string: text)
        a.name = "timing"
        a.lifetime = .keepAlways
        add(a)
        print("L2TIMING " + text)
    }

    /// Значения тестового крючка l2.test.state (hupms, rend, …).
    func callHook(_ step: String) -> [String: Int] {
        let e = any("l2.test.state")
        guard e.waitForExistence(timeout: 5), let v = e.value as? String else { return [:] }
        var out: [String: Int] = [:]
        for part in v.split(separator: " ") {
            let kv = part.split(separator: "=")
            if kv.count == 2, let n = Int(kv[1]) { out[String(kv[0])] = n }
        }
        return out
    }

    func assertCallClosed(_ what: String, timeout: TimeInterval) {
        let end = Date().addingTimeInterval(timeout)
        while any("l2.call.hangup").exists && Date() < end { usleep(500_000) }
        XCTAssertFalse(any("l2.call.hangup").exists, "\(what): экран звонка не закрылся")
        XCTAssertEqual(app.state, .runningForeground, "\(what): вылет после звонка")
        screenshot("ended")
    }

    /// Запись в «Звонках»: имя собеседника и тип звонка (длительность — разговор состоялся).
    func assertInCallLog(name: String, video: Bool, _ what: String) {
        tab("l2.tab.calls").tap(); sleep(2)
        let kind = video ? "Видеозвонок" : "Аудиозвонок"
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", name, kind)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(what): нет записи «\(name) · \(kind)» в «Звонках»")
        screenshot("call-log")
        tab("l2.tab.chats").tap(); sleep(1)
    }
}

// MARK: - Основной симулятор (A)

final class Linia2CallTests: Linia2CallTestBase {
    private var peerName: String { env["L2_PEER_NAME"] ?? "Собеседник CI" }
    private var cName: String { env["L2_C_NAME"] ?? "Собеседник iOS" }

    private func login() { ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD")) }

    /// Позвонить из открытого чата и дождаться соединения: собеседник может быть ещё не готов — до 4 попыток.
    private func dial(video: Bool, _ what: String) -> Bool {
        for attempt in 1...4 {
            startCall(video: video)
            let end = Date().addingTimeInterval(75)
            while connectedSeconds() == nil && any("l2.call.hangup").exists && Date() < end { usleep(500_000) }
            if connectedSeconds() != nil { return true }
            screenshot("no-answer-\(attempt)")
            if any("l2.call.hangup").exists { any("l2.call.hangup").tap() }
            assertCallClosed(what + " (не ответили, попытка \(attempt))", timeout: 15)
            if attempt == 4 { XCTFail("\(what): собеседник не ответил за 4 попытки"); return false }
            sleep(15)
        }
        return false
    }

    private func outgoing(to name: String, video: Bool, _ what: String) {
        login()
        openChat(with: name)
        guard dial(video: video, what) else { return }
        holdConnected(what)
        toggleMicAndCamera(what)
        hangUp(what)
        assertInCallLog(name: name, video: video, what)
    }

    private func incoming(from name: String, video: Bool, _ what: String) {
        login()
        tab("l2.tab.chats").tap()
        acceptIncoming(timeout: 600)
        holdConnected(what)
        toggleMicAndCamera(what)
        hangUp(what)
        assertInCallLog(name: name, video: video, what)
    }

    func test1_IOSToIOSAudio() { outgoing(to: cName, video: false, "iOS → iOS (аудио)") }
    func test2_IOSToWebAudio() { outgoing(to: peerName, video: false, "iOS → веб (аудио)") }
    func test3_IOSToWebVideo() { outgoing(to: peerName, video: true, "iOS → веб (видео)") }
    func test4_WebToIOSAudio() { incoming(from: peerName, video: false, "веб → iOS (аудио)") }
    /// Веб → iOS (видео); трубку кладёт ВЕБ (call-scenario.mjs, звонок 4, через ~90 с): экран iOS закрывается < 2 с.
    func test5_WebToIOSVideo() {
        let what = "веб → iOS (видео, завершает веб)"
        login()
        tab("l2.tab.chats").tap()
        acceptIncoming(timeout: 600)
        holdConnected(what)
        toggleMicAndCamera(what)
        waitRemoteHangup(what, timeout: 90)
        assertInCallLog(name: peerName, video: true, what)
    }

    /// Звонок веб → iOS сразу после перезапуска приложения (вход, загрузка и звонок одновременно):
    /// ответ — и уже через ≤ 5 с соединение и звук в обе стороны (байты аудио растут на приём и на передачу).
    /// Веб (call-scenario.mjs, шаг 5) звонит через ~40 с после предыдущего звонка — перезапускаемся к этому моменту.
    func test6_WebToIOSAudioColdStart() {
        let what = "веб → iOS (аудио, холодный старт)"
        login()
        app.terminate()
        sleep(34)
        app.launch()
        dismissSpringboardAlerts()
        if app.staticTexts["Введите PIN-код"].waitForExistence(timeout: 15) { for d in ["1", "3", "5", "7"] { app.buttons[d].firstMatch.tap() } }
        acceptIncoming(timeout: 420)
        let accepted = Date()
        // Соединение и аудио в обе стороны — не позже 5 с после «Принять» (+1 с на опрос статистики).
        var rx0 = -1, tx0 = -1, bothAt: Date?
        while Date().timeIntervalSince(accepted) < 20 && bothAt == nil {
            if connectedSeconds() != nil, let v = any("l2.call.state").value as? String {
                let nums = v.split(separator: " ").compactMap { Int($0.split(separator: "=").last ?? "") }
                if nums.count == 2 {
                    if rx0 < 0 { rx0 = nums[0]; tx0 = nums[1] } else if nums[0] > rx0 && nums[1] > tx0 { bothAt = Date() }
                }
            }
            usleep(250_000)
        }
        let dt = bothAt.map { $0.timeIntervalSince(accepted) }
        screenshot(dt == nil ? "нет-звука" : "audio-both-ways")
        XCTAssertNotNil(dt, "\(what): за 20 с после ответа нет звука в обе стороны (состояние: \(any("l2.call.state").exists ? any("l2.call.state").label : "нет экрана"))")
        if let dt = dt { XCTAssertLessThanOrEqual(dt, 6.0, "\(what): звук в обе стороны только через \(String(format: "%.1f", dt)) с после ответа") }
        holdConnected(what)
        hangUp(what)
        assertInCallLog(name: peerName, video: false, what)
        XCTAssertEqual(app.state, .runningForeground, "\(what): вылет")
    }

    func test7_ReconnectAfter5s() { reconnect(outage: 5) }
    func test8_ReconnectAfter15s() { reconnect(outage: 15) }
    func test9_ConnectionLostAfter35s() { reconnect(outage: 35) }

    /// Обрыв сети посреди звонка iOS → веб (аудио) на `outage` с (эмуляция — см. CallViewController.linia2AddUITestHooks).
    private func reconnect(outage: Int) {
        let what = "обрыв связи \(outage) с (iOS → веб, аудио)"
        login()
        openChat(with: peerName)
        guard dial(video: false, what) else { return }
        // До обрыва: звук идёт в обе стороны.
        XCTAssertNotNil(waitAudioBothWays(timeout: 20), "\(what): до обрыва нет звука в обе стороны (\(callStateLabel))")
        sleep(5)
        screenshot("before-drop")
        let drop = any("l2.call.uitest.drop\(outage)")
        wait(drop, "тестовая кнопка обрыва \(outage) с").tap()
        let dropped = Date()
        // «Переподключение…» — сразу (≤ 3 с).
        while !callStateLabel.hasPrefix("Переподключение") && Date().timeIntervalSince(dropped) < 3 { usleep(100_000) }
        XCTAssertTrue(callStateLabel.hasPrefix("Переподключение"), "\(what): нет «Переподключение…» (\(callStateLabel))")
        screenshot("reconnecting")
        // Пока связи нет — звонок не завершается и остаётся «Переподключение…».
        let holdUntil = Double(min(outage, 28)) - 1
        while Date().timeIntervalSince(dropped) < holdUntil {
            guard any("l2.call.hangup").exists else {
                screenshot("закрылся-при-обрыве")
                XCTFail("\(what): экран звонка закрылся через \(Int(Date().timeIntervalSince(dropped))) с обрыва")
                return
            }
            let l = callStateLabel
            if !l.hasPrefix("Переподключение") {
                XCTFail("\(what): во время обрыва состояние «\(l)» через \(Int(Date().timeIntervalSince(dropped))) с")
                break
            }
            usleep(500_000)
        }
        if outage < 30 {
            // Связь вернулась: снова «Идёт звонок» (ICE restart + повторная подписка) не позже чем через 20 с.
            let end = dropped.addingTimeInterval(TimeInterval(outage + 20))
            while connectedSeconds() == nil && any("l2.call.hangup").exists && Date() < end { usleep(250_000) }
            guard connectedSeconds() != nil else {
                screenshot("не-восстановился")
                XCTFail("\(what): звонок не восстановился за \(outage + 20) с (\(callStateLabel))")
                return
            }
            let restoredIn = Date().timeIntervalSince(dropped) - Double(outage)
            screenshot(String(format: "restored-%.0fs", max(0, restoredIn)))
            // Звук снова идёт в обе стороны.
            let dt = waitAudioBothWays(timeout: 15)
            let bytes = audioBytes()
            let bytesText = bytes == nil ? "нет байтов" : "rx=\(bytes!.rx) tx=\(bytes!.tx)"
            XCTAssertNotNil(dt, "\(what): после восстановления нет звука в обе стороны (\(callStateLabel), \(bytesText))")
            screenshot("audio-both-ways")
            // И держится дальше (ещё 15 с без нового обрыва).
            let holdEnd = Date().addingTimeInterval(15)
            while Date() < holdEnd {
                guard any("l2.call.hangup").exists, connectedSeconds() != nil || callStateLabel.hasPrefix("Плохая") else {
                    screenshot("обрыв-после-восстановления")
                    XCTFail("\(what): после восстановления звонок оборвался (\(callStateLabel))")
                    return
                }
                sleep(1)
            }
            hangUp(what)
        } else {
            // 30 с без связи — «Связь потеряна», затем экран закрывается (сам, без «Завершить»).
            var lostAt: Date?
            let end = dropped.addingTimeInterval(45)
            while Date() < end && any("l2.call.hangup").exists {
                if callStateLabel == "Связь потеряна" { lostAt = Date(); break }
                usleep(200_000)
            }
            guard let lost = lostAt else {
                screenshot("нет-связь-потеряна")
                XCTFail("\(what): нет «Связь потеряна» за 45 с (\(callStateLabel))")
                return
            }
            screenshot("connection-lost")
            let after = lost.timeIntervalSince(dropped)
            XCTAssertGreaterThanOrEqual(after, 28, "\(what): «Связь потеряна» слишком рано — через \(Int(after)) с")
            XCTAssertLessThanOrEqual(after, 36, "\(what): «Связь потеряна» слишком поздно — через \(Int(after)) с")
            assertCallClosed(what, timeout: 10)
            // Сеть «вернулась» (35 с) — приложение снова на связи, вылета нет.
            sleep(8)
            XCTAssertEqual(app.state, .runningForeground, "\(what): вылет")
        }
    }
}

// MARK: - Второй симулятор (C, «принимающий»)

final class Linia2CallPeerTests: Linia2CallTestBase {
    func testAnswerIncomingCall() {
        let what = "iOS ← iOS (принимающий)"
        ensureLoggedIn(requireEnv("L2_C_LOGIN"), requireEnv("L2_C_PASSWORD"))
        tab("l2.tab.chats").tap()
        acceptIncoming(timeout: 900)
        holdConnected(what)
        toggleMicAndCamera(what)
        // Трубку кладёт звонящий (A) — ждём завершения у себя.
        assertCallClosed(what, timeout: 120)
        assertInCallLog(name: env["L2_A_NAME"] ?? "Тест CI", video: false, what)
    }
}
