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

    /// Микрофон и камера: выкл → вкл (по подписям доступности).
    func toggleMicAndCamera(_ what: String) {
        let mic = any("l2.call.mic")
        wait(mic, "кнопка микрофона")
        let mic0 = mic.label
        mic.tap(); sleep(1)
        XCTAssertNotEqual(any("l2.call.mic").label, mic0, "\(what): микрофон не переключился")
        any("l2.call.mic").tap(); sleep(1)
        XCTAssertEqual(any("l2.call.mic").label, mic0, "\(what): микрофон не вернулся")
        let cam = any("l2.call.video")
        wait(cam, "кнопка камеры")
        let cam0 = cam.label
        cam.tap(); sleep(2)
        XCTAssertNotEqual(any("l2.call.video").label, cam0, "\(what): камера не переключилась")
        any("l2.call.video").tap(); sleep(2)
        XCTAssertEqual(any("l2.call.video").label, cam0, "\(what): камера не вернулась")
        XCTAssertNotNil(connectedSeconds(), "\(what): звонок оборвался после переключения микрофона/камеры")
        screenshot("toggled")
    }

    func hangUp(_ what: String) {
        wait(any("l2.call.hangup"), "«Положить трубку»").tap()
        assertCallClosed(what, timeout: 15)
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

    private func outgoing(to name: String, video: Bool, _ what: String) {
        login()
        openChat(with: name)
        // Собеседник может быть ещё не готов (вход, предыдущий звонок) — до 4 попыток дозвона.
        for attempt in 1...4 {
            startCall(video: video)
            let end = Date().addingTimeInterval(75)
            while connectedSeconds() == nil && any("l2.call.hangup").exists && Date() < end { usleep(500_000) }
            if connectedSeconds() != nil { break }
            screenshot("no-answer-\(attempt)")
            if any("l2.call.hangup").exists { any("l2.call.hangup").tap() }
            assertCallClosed(what + " (не ответили, попытка \(attempt))", timeout: 15)
            if attempt == 4 { XCTFail("\(what): собеседник не ответил за 4 попытки"); return }
            sleep(15)
        }
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
    func test5_WebToIOSVideo() { incoming(from: peerName, video: true, "веб → iOS (видео)") }

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
