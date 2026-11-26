//
//  Linia2E2ETests.swift
//  Линия 2.0: большой автотест «как живые люди» (.github/workflows/e2e.yml).
//
//  Два симулятора запускают ОДИН и тот же тест с разными ролями (L2_ROLE = iphone1 | iphone2),
//  третий участник — веб (Playwright, e2e/web.mjs). Шаги синхронизируются через «доску» —
//  маленький HTTP-сервер на раннере (e2e/board.mjs, http://127.0.0.1:8765; симулятор видит localhost хоста).
//  К доске ходим через POSIX-сокет (не URLSession), чтобы не зависеть от App Transport Security.
//
//  Каждый сценарий: участники делают свою часть → /part → общий /verdict. Если у кого-то часть не прошла,
//  сценарий повторяют все участники (до 3 попыток) — повтор виден в отчёте.
//

import XCTest
import UIKit
import Darwin

private struct E2EFail: Error { let msg: String }
private struct E2ESkip: Error { let msg: String }

// MARK: - Доска

private final class Board {
    let port: UInt16
    let role: String
    init(port: UInt16, role: String) { self.port = port; self.role = role }

    /// GET path?query → (код, JSON). Код 0 — доска недоступна.
    func call(_ path: String, _ q: [String: String], timeout: Int = 30) -> (Int, [String: Any]) {
        var comps = URLComponents()
        comps.path = path
        comps.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        let query = (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let target = path + (query.isEmpty ? "" : "?" + query)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (0, [:]) }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout + 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { return (0, [:]) }
        let req = Array("GET \(target) HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
        var sent = 0
        while sent < req.count {
            let n = req[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return (0, [:]) }
            sent += n
        }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let text = String(data: data, encoding: .utf8), let sep = text.range(of: "\r\n\r\n") else { return (0, [:]) }
        let status = Int(text[..<sep.lowerBound].split(separator: " ").dropFirst().first ?? "0") ?? 0
        let body = Data(text[sep.upperBound...].utf8)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return (status, json)
    }

    func set(_ k: String, _ v: String = "1") { _ = call("/set", ["k": k, "v": v]) }
    func wait(_ k: String, timeout: Int) -> (Int, String, Double) {
        let (c, j) = call("/wait", ["k": k, "t": String(timeout)], timeout: timeout)
        return (c, j["v"] as? String ?? "\(j["v"] ?? "")", (j["ts"] as? Double) ?? 0)
    }
    func log(_ m: String) { _ = call("/log", ["role": role, "m": m]) }
    func net(_ op: String) -> [String: Any] { call("/net", ["op": op], timeout: 40).1 }
    func barrier(_ n: String, roles: [String], timeout: Int) -> Bool {
        call("/barrier", ["n": n, "role": role, "roles": roles.joined(separator: ","), "t": String(timeout)], timeout: timeout).0 == 200
    }
}

// MARK: - Контекст попытки сценария

private struct Ctx {
    let s: String
    let a: Int
    let role: String
    let board: Board
    let run: String
    /// Уникальная метка текста для этой попытки.
    var tag: String { "\(s)-\(a)-\(run)" }
    func key(_ n: String, _ r: String) -> String { "\(s)#\(a):\(n)@\(r)" }
    func sig(_ n: String, _ v: String = "1") { board.set(key(n, role), v) }
    /// Ждать сигнал n от участника r; возвращает (значение, время сигнала в мс эпохи).
    @discardableResult
    func wait(_ n: String, from r: String, _ timeout: Int = 120) throws -> (String, Double) {
        let (c, v, ts) = board.wait(key(n, r), timeout: timeout)
        switch c {
        case 200: return (v, ts)
        case 409: throw E2EFail(msg: "попытка прервана: у другого участника шаг не прошёл (ждали «\(n)» от \(r))")
        case 410: throw E2EFail(msg: "\(r) уже завершил работу (ждали «\(n)»)")
        case 0: throw E2EFail(msg: "доска недоступна")
        default: throw E2EFail(msg: "не дождались «\(n)» от \(r) за \(timeout) с")
        }
    }
}

private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

final class Linia2E2ETests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private var role = ""
    private var board: Board!
    private var pin = ["1", "3", "5", "7"]
    private var shot = 0
    private var failed: [String] = []
    private var run = ""
    private var p2Password = ""

    private let p1Name = "Айфон1 CI"
    private let p2Name = "Айфон2 CI"
    private let p2Match = "Айфон2"
    private let wName = "Веб CI"
    private let allRoles = ["iphone1", "iphone2", "web"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        role = env["L2_ROLE"] ?? ""
        run = env["L2_RUN"] ?? String(Int(Date().timeIntervalSince1970) % 100000)
        board = Board(port: UInt16(env["L2_BOARD_PORT"] ?? "8765") ?? 8765, role: role)
        p2Password = env["L2_P2_PASSWORD"] ?? ""
        app = XCUIApplication()
        app.launchArguments = ["-l2-uitest"]
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Системные запросы") { alert in
            for t in ["Allow", "Разрешить", "OK", "Allow While Using App", "Allow Full Access", "Разрешить доступ ко всем фото"] {
                if alert.buttons[t].exists { alert.buttons[t].tap(); return true }
            }
            return false
        }
    }

    // MARK: Единственный тест: вся «пьеса» за свою роль

    func testE2E() throws {
        guard ["iphone1", "iphone2"].contains(role) else {
            throw XCTSkip("L2_ROLE не задан — тест запускается только из e2e.yml")
        }
        let (c, _) = board.call("/ping", [:])
        guard c == 200 else { XCTFail("Доска e2e недоступна на 127.0.0.1:\(board.port)"); return }
        board.log("старт роли \(role)")
        if role == "iphone1" { playIphone1() } else { playIphone2() }
        board.log("роль \(role) закончила; упало: \(failed.joined(separator: ", "))")
        _ = board.call("/gone", ["role": role])
        if !failed.isEmpty { XCTFail("Не прошли сценарии: \(failed.joined(separator: ", "))") }
    }

    // MARK: - Сценарий с повтором (до 3 попыток, общий вердикт)

    @discardableResult
    private func scenario(_ s: String, _ title: String, _ roles: [String], timeout: Int = 240,
                          _ body: (Ctx) throws -> String?) -> String {
        guard roles.contains(role) else { return "" }
        let r = roles.joined(separator: ",")
        for a in 1...3 {
            // Все участники начинают попытку вместе (кто завершился — не ждём).
            if roles.count > 1 { _ = board.barrier("\(s)#\(a)", roles: roles, timeout: 1500) }
            let c = Ctx(s: s, a: a, role: role, board: board, run: run)
            _ = board.call("/start", ["s": s, "a": String(a), "title": title, "roles": r, "role": role])
            var ok = "true", note = "", metric = ""
            do {
                metric = try body(c) ?? ""
            } catch let e as E2EFail {
                ok = "false"; note = e.msg
            } catch let e as E2ESkip {
                ok = "skip"; note = e.msg
            } catch {
                ok = "false"; note = "\(error)"
            }
            if ok == "false" { failureEvidence("\(s)-a\(a)", note) } else { screenshot("\(s)-a\(a)-итог") }
            _ = board.call("/part", ["s": s, "a": String(a), "title": title, "roles": r, "role": role,
                                     "ok": ok, "note": String(note.prefix(400)), "metric": metric])
            let (_, v) = board.call("/verdict", ["s": s, "a": String(a), "roles": r, "t": String(timeout)], timeout: timeout)
            let status = v["status"] as? String ?? "fail"
            let final = v["final"] as? Bool ?? true
            if final {
                if status == "fail" { failed.append(s) }
                return status
            }
            board.log("\(s): повтор (попытка \(a + 1))")
            recover()
        }
        return "fail"
    }

    private func solo(_ s: String, _ title: String, _ body: (Ctx) throws -> String?) {
        scenario(s, title, [role], timeout: 30, body)
    }

    // MARK: - Помощники UI

    private func screenshot(_ name: String) {
        shot += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%@-%03d-%@", role, shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    private func failureEvidence(_ name: String, _ note: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "ПАДЕНИЕ-\(role)-\(name)"
        a.lifetime = .keepAlways
        add(a)
        let t = XCTAttachment(string: note + "\n\n" + String(app.debugDescription.prefix(60000)))
        t.name = "ДЕРЕВО-\(role)-\(name)"
        t.lifetime = .keepAlways
        add(t)
    }

    private func fail(_ m: String) -> E2EFail { E2EFail(msg: m) }

    @discardableResult
    private func need(_ e: XCUIElement, _ what: String, _ timeout: TimeInterval = 20) throws -> XCUIElement {
        if !e.waitForExistence(timeout: timeout) { throw fail("не появилось: \(what)") }
        return e
    }

    private func needGone(_ e: XCUIElement, _ what: String, _ timeout: TimeInterval = 20) throws {
        let end = Date().addingTimeInterval(timeout)
        while e.exists && Date() < end { usleep(300_000) }
        if e.exists { throw fail("не исчезло: \(what)") }
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func labelContains(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func countContains(_ text: String) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).count
    }

    private func tab(_ id: String) -> XCUIElement {
        app.otherElements[id].firstMatch.exists ? app.otherElements[id].firstMatch : any(id)
    }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists && b.isHittable { b.tap() }
        sleep(1)
    }

    private func dialogButton(_ title: String) -> XCUIElement {
        if app.alerts.buttons[title].firstMatch.exists { return app.alerts.buttons[title].firstMatch }
        if app.sheets.buttons[title].firstMatch.exists { return app.sheets.buttons[title].firstMatch }
        let a = app.alerts.buttons[title].firstMatch
        if a.waitForExistence(timeout: 4) { return a }
        return app.sheets.buttons[title].firstMatch
    }

    private func dismissKeyboardTips() {
        for t in ["Continue", "Продолжить"] {
            let b = app.buttons[t].firstMatch
            if b.waitForExistence(timeout: 1) { b.tap() }
        }
    }

    private func dismissSpringboardAlerts() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for t in ["Allow", "Разрешить", "OK", "Allow While Using App"] where sb.buttons[t].exists { sb.buttons[t].tap() }
    }

    private func launch() {
        app.launch()
        dismissSpringboardAlerts()
    }

    private func tapVisible(_ e: XCUIElement, _ what: String) throws {
        try need(e, what)
        var tries = 0
        while !e.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        e.tap()
    }

    private func enterPin(_ digits: [String]? = nil) {
        for d in digits ?? pin { app.buttons[d].firstMatch.tap() }
    }

    private func typeDigits(_ digits: String) {
        let ti = app.textFields["l2.code.testinput"].firstMatch
        if ti.waitForExistence(timeout: 2) {
            if !ti.isHittable { app.swipeUp() }
            ti.tap(); ti.typeText(digits); return
        }
        for ch in digits {
            let k = app.keys[String(ch)].firstMatch
            if k.waitForExistence(timeout: 2) && k.isHittable { k.tap() } else { app.typeText(String(ch)) }
            usleep(150_000)
        }
    }

    private enum Screen { case welcome, pinEnter, pinCreate, main, unknown }

    private func currentScreen(timeout: TimeInterval = 25) -> Screen {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if app.buttons["l2.welcome.login"].exists { return .welcome }
            if app.staticTexts["Введите PIN-код"].exists { return .pinEnter }
            if app.staticTexts["Придумайте PIN-код"].exists { return .pinCreate }
            if tab("l2.tab.chats").exists { return .main }
            usleep(300_000)
        } while Date() < end
        return .unknown
    }

    /// Если приложение спросило PIN (после фона > 30 с) — ввести.
    private func unlockIfNeeded() {
        if app.staticTexts["Введите PIN-код"].exists { enterPin(); sleep(1) }
    }

    private func createPinAndReachChats() throws {
        try need(app.staticTexts["Придумайте PIN-код"], "экран создания PIN", 40)
        screenshot("pin-create")
        enterPin()
        try need(app.staticTexts["Повторите PIN-код"], "экран повтора PIN", 10)
        enterPin()
        let skip = app.buttons["Не сейчас"]
        if skip.waitForExistence(timeout: 3) { skip.tap() }
        try need(tab("l2.tab.chats"), "вкладки после входа", 30)
        sleep(1)
    }

    private func logoutFromMain() throws {
        tab("l2.tab.settings").tap(); sleep(1)
        let out = app.staticTexts["Выйти"].firstMatch
        if out.exists && !out.isHittable { app.swipeUp() }
        if !out.exists { app.swipeUp() }
        try need(out, "«Выйти»").tap()
        try need(dialogButton("Выйти"), "подтверждение выхода").tap()
        try need(app.buttons["l2.welcome.login"], "стартовый экран после выхода", 20)
    }

    private func ensureLoggedOut() throws {
        if app.state != .runningForeground { launch() }
        switch currentScreen() {
        case .welcome: return
        case .pinEnter: enterPin(); try need(tab("l2.tab.chats"), "Чаты после PIN"); try logoutFromMain()
        case .main: try logoutFromMain()
        case .pinCreate, .unknown:
            for _ in 0..<3 where !app.buttons["l2.welcome.login"].exists { back() }
        }
        try need(app.buttons["l2.welcome.login"], "стартовый экран")
    }

    private func loginWith(_ login: String, _ password: String) throws {
        try need(app.buttons["l2.welcome.login"], "стартовый экран").tap()
        let lf = try need(app.textFields["l2.login.login"], "поле логина")
        lf.tap()
        if let v = lf.value as? String, !v.isEmpty, v != "Логин", v != "Ваш логин" {
            lf.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 2))
        }
        dismissKeyboardTips()
        lf.typeText(login + "\n")
        app.typeText(password)
        screenshot("login-filled")
        app.typeText("\n")
        try createPinAndReachChats()
    }

    private var session: String?

    private func ensureLoggedIn(_ login: String, _ password: String) throws {
        if app.state != .runningForeground { launch() }
        var s = currentScreen()
        if s == .pinEnter { enterPin(); try need(tab("l2.tab.chats"), "Чаты после PIN"); s = .main }
        if s == .main && session == login { return }
        if s == .main { try logoutFromMain() }
        if s == .pinCreate || s == .unknown { for _ in 0..<3 where !app.buttons["l2.welcome.login"].exists { back() } }
        try loginWith(login, password)
        session = login
    }

    /// Привести приложение в рабочее состояние после неудачной попытки.
    private func recover() {
        if app.state != .runningForeground { launch(); sleep(2) }
        unlockIfNeeded()
        hangUpIfInCall()
        for t in ["Отмена", "Cancel", "OK", "Закрыть"] where app.alerts.buttons[t].exists || app.sheets.buttons[t].exists {
            dialogButton(t).tap()
        }
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        if any("l2.menu").exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap(); sleep(1) }
        for _ in 0..<3 where !tab("l2.tab.chats").exists { back() }
        if !tab("l2.tab.chats").exists {
            app.terminate(); launch()
            if currentScreen() == .pinEnter { enterPin() }
        }
    }

    // MARK: Чаты

    private func chatInput() -> XCUIElement {
        let byId = app.textViews["l2.chat.input"].firstMatch
        return byId.exists ? byId : app.textViews.firstMatch
    }

    private func goChats() throws {
        unlockIfNeeded()
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        for _ in 0..<3 where !tab("l2.tab.chats").isHittable { back() }
        try need(tab("l2.tab.chats"), "вкладка «Чаты»").tap()
        sleep(1)
        // Второй тап — к корню списка, если внутри был открыт чат.
        if !app.buttons["Новый чат"].firstMatch.exists { tab("l2.tab.chats").tap(); sleep(1) }
    }

    private var openedChat: String?

    /// Открыть чат, где в названии есть `name`. Принять приглашение, если спросили.
    private func openChat(_ name: String, timeout: TimeInterval = 30) throws {
        if openedChat == name && chatInput().exists && labelContains(name).exists { return }
        try goChats()
        let cell = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        let txt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        let end = Date().addingTimeInterval(timeout)
        while !cell.exists && !txt.exists && Date() < end { usleep(400_000) }
        if cell.exists { cell.tap() } else if txt.exists { txt.tap() } else { throw fail("в списке нет чата «\(name)»") }
        acceptInviteIfAsked()
        try need(chatInput(), "поле ввода в чате «\(name)»", 15)
        openedChat = name
        sleep(1)
    }

    private func acceptInviteIfAsked() {
        let acc = app.alerts.buttons["Принять"].firstMatch
        if acc.waitForExistence(timeout: 2) { acc.tap(); sleep(1) }
        let b = app.buttons["Принять"].firstMatch
        if b.exists && b.isHittable { b.tap(); sleep(1) }
    }

    private func typeIntoInput(_ text: String) {
        let input = chatInput()
        input.tap()
        dismissKeyboardTips()
        input.typeText(text)
    }

    private func tapSend() {
        let send = app.buttons["l2.chat.send"].firstMatch
        if send.exists && send.isHittable { send.tap() } else { app.typeText("\n") }
    }

    /// Набрать и отправить; возвращает момент нажатия «Отправить» (мс эпохи).
    @discardableResult
    private func sendMessage(_ text: String) -> Double {
        typeIntoInput(text)
        let t0 = nowMs()
        tapSend()
        return t0
    }

    /// Ждать появления текста; возвращает момент, когда увидели (мс эпохи).
    private func waitText(_ text: String, _ timeout: TimeInterval = 30) throws -> Double {
        let e = labelContains(text)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if e.exists { return nowMs() }
            usleep(50_000)
        }
        throw fail("не пришло сообщение «\(text)» за \(Int(timeout)) с")
    }

    private func longPress(_ text: String) throws {
        let m = try need(labelContains(text), "сообщение «\(text)»")
        if app.keyboards.firstMatch.exists { app.swipeDown(); sleep(1) }
        m.press(forDuration: 1.0)
        try need(any("l2.menu"), "меню сообщения", 6)
        sleep(1)
    }

    private func closeMenu() {
        if any("l2.menu").exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap(); sleep(1) }
    }

    private func deliveryMetric(_ t0: Double, _ t1: Double) -> String {
        let ms = Int(t1 - t0)
        return "доставка \(ms) мс (цель < 1000 мс: \(ms < 1000 ? "да" : "нет"); замер XCUITest с точностью опроса ~0,1–0,5 с)"
    }

    // MARK: Звонки

    private func springboard() -> XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// Входящий звонок CallKit: кнопка «Принять»/«Отклонить» (в симуляторе — баннер SpringBoard или InCallService).
    private func incomingCallButton(_ accept: Bool, timeout: TimeInterval) -> XCUIElement? {
        let titles = accept ? ["Accept", "Принять", "Answer", "Ответить", "slide to answer"] : ["Decline", "Отклонить", "Reject"]
        let apps = [springboard(), XCUIApplication(bundleIdentifier: "com.apple.InCallService"), app!]
        // Под -l2-uitest приложение показывает свой алерт «Входящий звонок» (id l2.call.incoming) вместо CallKit.
        let own = app.alerts.buttons[accept ? "Принять" : "Отклонить"].firstMatch
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if own.exists { return own }
            for a in apps {
                for t in titles {
                    let b = a.buttons[t].firstMatch
                    if b.exists { return b }
                }
            }
            usleep(300_000)
        } while Date() < end
        return nil
    }

    private func hangUpButton() -> XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "identifier == 'l2.call.hangup' OR label CONTAINS[c] 'end call' OR label CONTAINS[c] 'заверш' OR label CONTAINS[c] 'phone.down' OR label CONTAINS[c] 'phone down' OR label CONTAINS[c] 'отбой' OR identifier CONTAINS[c] 'phone.down'"))
            .firstMatch
    }

    /// Экран звонка: есть кнопка «Завершить», поля ввода чата не видно.
    private func waitCallScreen(_ timeout: TimeInterval = 30) throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if hangUpButton().exists || any("l2.call.state").exists { return }
            usleep(300_000)
        }
        throw fail("не открылся экран звонка (нет кнопки «Завершить»)")
    }

    /// Текст состояния экрана звонка («Идёт звонок 00:05» / «Соединение…»).
    private func callState() -> String {
        let e = any("l2.call.state")
        return e.exists ? e.label : ""
    }

    /// Ждать «Идёт звонок» (соединение установлено) — если приложение показывает состояние.
    private func waitInCall(_ timeout: TimeInterval = 30) -> String {
        let end = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < end {
            last = callState()
            if last.localizedCaseInsensitiveContains("идёт звонок") { return last }
            usleep(500_000)
        }
        return last
    }

    /// Если экран показывает состояние — оно должно стать «Идёт звонок»; иначе (старая сборка) — только пометка.
    private func inCallCheck() throws -> String {
        let st = waitInCall(30)
        if st.isEmpty { return "состояние звонка не показано (нет l2.call.state)" }
        if !st.localizedCaseInsensitiveContains("идёт звонок") { throw fail("соединение не установлено: «\(st)»") }
        return "iOS: «\(st)»"
    }

    private func micEnabled() -> Bool {
        let mic = app.buttons.matching(NSPredicate(format: "identifier == 'l2.call.mic' OR label CONTAINS[c] 'mic'")).firstMatch
        return mic.exists && mic.isEnabled
    }

    private func hangUpIfInCall() {
        let h = hangUpButton()
        if h.exists && h.isHittable { h.tap(); sleep(2) }
    }

    private func waitCallClosed(_ timeout: TimeInterval = 20) throws {
        let end = Date().addingTimeInterval(timeout)
        while hangUpButton().exists && Date() < end { usleep(300_000) }
        if hangUpButton().exists { throw fail("экран звонка не закрылся после завершения") }
    }

    private func startAudioCall() throws {
        if app.keyboards.firstMatch.exists { app.swipeDown(); sleep(1) }
        let call = app.buttons["l2.chat.call"].firstMatch.exists ? app.buttons["l2.chat.call"].firstMatch : app.navigationBars.buttons["Позвонить"].firstMatch
        try need(call, "кнопка звонка в шапке чата").tap()
        let audio = app.sheets.buttons["Только звук"].firstMatch.exists ? app.sheets.buttons["Только звук"].firstMatch : app.buttons["Только звук"].firstMatch
        if audio.waitForExistence(timeout: 5) { audio.tap() } else {
            let alt = app.buttons["Audio-only"].firstMatch
            try need(alt, "пункт «Только звук»", 3).tap()
        }
        sleep(1)
        dismissSpringboardAlerts()
    }

    /// Ответить на входящий звонок; true — экран звонка открыт.
    private func answerIncoming(_ timeout: TimeInterval = 40) throws {
        guard let b = incomingCallButton(true, timeout: timeout) else {
            screenshot("нет-входящего")
            throw fail("входящий звонок не показан (CallKit-баннера «Принять» нет за \(Int(timeout)) с)")
        }
        screenshot("входящий")
        b.tap()
        sleep(2)
        if app.state != .runningForeground { app.activate(); sleep(1) }
        unlockIfNeeded()
        try waitCallScreen(25)
    }

    private func openCallsTab() throws {
        unlockIfNeeded()
        for _ in 0..<3 where !tab("l2.tab.calls").isHittable { back() }
        try need(tab("l2.tab.calls"), "вкладка «Звонки»").tap()
        sleep(2)
    }

    // MARK: - Роль iPhone 1: регистрация по коду, новые чаты, действия с сообщениями, звонки, удаление аккаунта

    private func playIphone1() {
        let code = env["L2_CODE"] ?? "", login = env["L2_P1_LOGIN"] ?? "", pw = env["L2_P1_PASSWORD"] ?? ""
        var registered = false

        solo("R01", "Регистрация по коду → PIN") { c in
            if c.a > 1 && registered { try ensureLoggedIn(login, pw); return "повтор: аккаунт уже создан, вход проверен" }
            if c.a > 1 {
                // Код одноразовый: если аккаунт успел создаться — проверяем вход.
                try? ensureLoggedOut()
                if (try? loginWith(login, pw)) != nil { registered = true; session = login; return "код уже использован в попытке 1, вход созданным аккаунтом" }
            }
            guard !code.isEmpty else { throw fail("нет кода приглашения") }
            launch()
            try ensureLoggedOut()
            app.buttons["l2.welcome.code"].tap()
            try need(any("l2.code.cells"), "ячейки кода").tap()
            sleep(1)
            typeDigits(code)
            try need(app.textFields["l2.reg.name"], "форма регистрации (код не принят?)", 25)
            dismissKeyboardTips()
            screenshot("register")
            for (id, text) in [("l2.reg.name", p1Name), ("l2.reg.login", login)] {
                try tapVisible(app.textFields[id], id)
                dismissKeyboardTips()
                app.textFields[id].typeText(text)
            }
            try tapVisible(app.secureTextFields["l2.reg.password"], "пароль")
            app.secureTextFields["l2.reg.password"].typeText(pw)
            app.typeText("\n")
            app.typeText(pw)
            screenshot("register-filled")
            app.typeText("\n")
            try createPinAndReachChats()
            registered = true; session = login
            return nil
        }

        solo("R02", "Выход → вход по логину и паролю") { _ in
            try ensureLoggedIn(login, pw)
            try logoutFromMain()
            session = nil
            screenshot("logged-out")
            try loginWith(login, pw)
            session = login
            return nil
        }

        solo("R03", "Перезапуск → PIN (неверный не пускает, верный пускает)") { _ in
            try ensureLoggedIn(login, pw)
            app.terminate()
            launch()
            try need(app.staticTexts["Введите PIN-код"], "экран PIN при запуске")
            enterPin(["0", "0", "0", "0"])
            sleep(2)
            if tab("l2.tab.chats").exists { throw fail("неверный PIN пропустил в приложение") }
            screenshot("pin-wrong")
            enterPin()
            try need(tab("l2.tab.chats"), "Чаты после верного PIN")
            return nil
        }

        solo("T01", "Вкладки: Чаты, Звонки, Контакты, Настройки") { _ in
            try ensureLoggedIn(login, pw)
            let marks: [(String, XCUIElement)] = [
                ("l2.tab.chats", app.buttons["Новый чат"].firstMatch),
                ("l2.tab.calls", labelContains("Звонки")),
                ("l2.tab.contacts", app.buttons["Добавить контакт"].firstMatch),
                ("l2.tab.settings", app.staticTexts["Внешний вид"].firstMatch),
            ]
            for (id, mark) in marks {
                try need(tab(id), id).tap(); sleep(1)
                try need(mark, "содержимое вкладки \(id)", 10)
                screenshot(id)
            }
            return nil
        }

        solo("S01", "Настройки: каждый пункт открывается (iPhone 1)") { _ in
            try ensureLoggedIn(login, pw)
            for item in ["Уведомления", "Конфиденциальность", "Внешний вид", "О приложении"] {
                tab("l2.tab.settings").tap(); sleep(1)
                for _ in 0..<2 where !app.staticTexts[item].firstMatch.exists { back() }
                try need(app.staticTexts[item].firstMatch, "пункт «\(item)»").tap()
                sleep(2)
                if app.state != .runningForeground { throw fail("вылет в «\(item)»") }
                screenshot("settings-" + item)
                back()
            }
            tab("l2.tab.settings").tap(); sleep(1)
            try need(any("l2.settings.profile"), "карточка профиля").tap(); sleep(2)
            try need(any("l2.profile.name"), "поле имени")
            screenshot("profile")
            back()
            return nil
        }

        _ = board.barrier("chats", roles: allRoles, timeout: 1500)

        // --- Новые чаты и доставка ---
        let p2Login = env["L2_P2_LOGIN"] ?? "", wLogin = env["L2_W_LOGIN"] ?? ""

        scenario("C01", "Новый чат iPhone 1 → iPhone 2", ["iphone1", "iphone2"]) { c in
            try ensureLoggedIn(login, pw)
            try newChat(p2Login)
            let text = "Привет, iPhone 2! \(c.tag)"
            let t0 = sendMessage(text)
            _ = try waitText(text, 15)
            c.sig("sent", "\(Int(t0))")
            try c.wait("seen", from: "iphone2", 90)
            openedChat = p2Match
            return nil
        }
        deliveryPair("D01", "D02", "iPhone 1", "iPhone 2", peerRole: "iphone2", chat: p2Match)

        scenario("C02", "Новый чат iPhone 1 → веб", ["iphone1", "web"]) { c in
            try ensureLoggedIn(login, pw)
            try newChat(wLogin)
            let text = "Привет, веб! \(c.tag)"
            let t0 = sendMessage(text)
            _ = try waitText(text, 15)
            c.sig("sent", "\(Int(t0))")
            try c.wait("seen", from: "web", 90)
            openedChat = wName
            return nil
        }
        deliveryPair("D03", "D04", "iPhone 1", "веб", peerRole: "web", chat: wName)

        // --- Действия с сообщениями в чате iPhone 1 ↔ iPhone 2 ---
        let pair = ["iphone1", "iphone2"]
        scenario("M01", "Ответ на сообщение (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p2Match)
            try c.wait("ready", from: "iphone2")
            let base = "База \(c.tag)", reply = "Ответ \(c.tag)"
            sendMessage(base)
            _ = try waitText(base)
            try longPress(base)
            try need(any("l2.menu.reply"), "«Ответить»").tap()
            sleep(1)
            if countContains(base) < 2 { throw fail("над полем ввода нет цитаты") }
            sendMessage(reply)
            _ = try waitText(reply)
            c.sig("sent")
            try c.wait("checked", from: "iphone2")
            return nil
        }
        scenario("M02", "Реакция 🔥 (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p2Match)
            try c.wait("ready", from: "iphone2")
            let base = "Реакция \(c.tag)"
            sendMessage(base)
            _ = try waitText(base)
            c.sig("base")
            try c.wait("seen", from: "iphone2")
            try longPress(base)
            try need(any("l2.react.🔥"), "реакция 🔥 в меню").tap()
            try need(any("l2.reaction.🔥"), "пилюля 🔥 под сообщением", 15)
            c.sig("reacted")
            try c.wait("checked", from: "iphone2")
            return nil
        }
        scenario("M03", "Закрепить и открепить (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p2Match)
            try c.wait("ready", from: "iphone2")
            let base = "Закреп \(c.tag)"
            sendMessage(base)
            _ = try waitText(base)
            try longPress(base)
            try need(any("l2.menu.pin"), "«Закрепить»").tap()
            try need(any("l2.pinned.counter"), "плашка закреплённого", 15)
            c.sig("pinned")
            try c.wait("seenPinned", from: "iphone2")
            try need(any("l2.pinned.unpin"), "крестик «Открепить»").tap()
            if dialogButton("Открепить").exists { dialogButton("Открепить").tap() }
            try needGone(any("l2.pinned.counter"), "плашка закреплённого", 15)
            c.sig("unpinned")
            try c.wait("seenUnpinned", from: "iphone2")
            return nil
        }
        scenario("M04", "Изменить сообщение (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p2Match)
            try c.wait("ready", from: "iphone2")
            let base = "Черновик \(c.tag)", edited = "Исправлено \(c.tag)"
            sendMessage(base)
            _ = try waitText(base)
            c.sig("base")
            try c.wait("seen", from: "iphone2")
            try longPress(base)
            try need(any("l2.menu.edit"), "«Изменить»").tap()
            sleep(1)
            let input = chatInput()
            input.tap()
            let cur = (input.value as? String) ?? ""
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(cur.count, base.count) + 2))
            input.typeText(edited)
            tapSend()
            _ = try waitText(edited)
            c.sig("edited")
            try c.wait("checked", from: "iphone2")
            return nil
        }
        scenario("M05", "Удалить сообщение (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p2Match)
            try c.wait("ready", from: "iphone2")
            let base = "Удалить \(c.tag)"
            sendMessage(base)
            _ = try waitText(base)
            c.sig("base")
            try c.wait("seen", from: "iphone2")
            try longPress(base)
            var mode = "self"
            if any("l2.menu.deleteAll").exists { any("l2.menu.deleteAll").tap(); mode = "all" } else {
                try need(any("l2.menu.delete"), "«Удалить»").tap()
            }
            for t in ["Удалить у всех", "Удалить", "Удалить у меня"] where dialogButton(t).exists { dialogButton(t).tap(); break }
            try needGone(labelContains(base), "удалённое сообщение у отправителя", 15)
            c.sig("deleted", mode)
            try c.wait("checked", from: "iphone2")
            return mode == "all" ? "удалено у всех" : "«Удалить у всех» нет в меню личного чата — проверено «Удалить у меня»"
        }

        // --- Чат iPhone 1 ↔ веб: пересылка, фото, файл, «печатает…», «прочитано» ---
        let withWeb = ["iphone1", "web"]
        scenario("M06", "Переслать из чата с iPhone 2 в чат с вебом", withWeb) { c in
            try openChat(p2Match)
            let text = "Переслать \(c.tag)"
            sendMessage(text)
            _ = try waitText(text)
            try longPress(text)
            try need(any("l2.menu.forward"), "«Переслать»").tap()
            sleep(2)
            let target = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", wName)).firstMatch
            let ttxt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", wName)).firstMatch
            if target.waitForExistence(timeout: 10) { target.tap() } else { try need(ttxt, "получатель «\(wName)» в списке пересылки").tap() }
            sleep(2)
            try need(chatInput(), "чат с вебом после выбора получателя", 15)
            openedChat = wName
            tapSend()
            c.sig("sent")
            try c.wait("seen", from: "web")
            return nil
        }
        scenario("M07", "Фото iPhone 1 → веб", withWeb) { c in
            try openChat(wName)
            try c.wait("ready", from: "web")
            try need(app.buttons["l2.chat.attach"].firstMatch, "кнопка вложения").tap()
            try need(app.buttons["Фото или видео"].firstMatch, "«Фото или видео»", 5).tap()
            sleep(3)
            try pickFirstPhoto()
            try sendPreview()
            c.sig("sent")
            try c.wait("seen", from: "web", 60)
            return nil
        }
        scenario("M08", "Файл веб → iPhone 1", withWeb) { c in
            try openChat(wName)
            c.sig("ready")
            let (name, _) = try c.wait("sent", from: "web", 120)
            _ = try waitText(name.isEmpty ? "e2e-file" : name, 40)
            return nil
        }
        scenario("M09", "Файл iPhone 1 → веб (из «Файлов»)", withWeb) { c in
            try openChat(wName)
            try c.wait("ready", from: "web")
            try need(app.buttons["l2.chat.attach"].firstMatch, "кнопка вложения").tap()
            try need(app.buttons["Файл"].firstMatch, "«Файл»", 5).tap()
            sleep(3)
            try pickFileInFiles("e2e-doc")
            try sendPreview()
            c.sig("sent")
            try c.wait("seen", from: "web", 60)
            return nil
        }
        scenario("M10", "«печатает…» веб → iPhone 1", withWeb) { c in
            try openChat(wName)
            c.sig("ready")
            let e = labelContains("печатает")
            if !e.waitForExistence(timeout: 30) { throw fail("не показано «печатает…»") }
            screenshot("typing")
            c.sig("seen")
            return nil
        }
        scenario("M11", "«печатает…» iPhone 1 → веб", withWeb) { c in
            try openChat(wName)
            try c.wait("ready", from: "web")
            let input = chatInput()
            input.tap()
            for w in ["печатаю ", "медленно ", "как ", "человек ", "…"] { input.typeText(w); sleep(1) }
            try c.wait("seen", from: "web", 30)
            let cur = (input.value as? String) ?? ""
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: cur.count + 2))
            return nil
        }
        scenario("M12", "«прочитано»: веб видит, что iPhone 1 прочитал", withWeb) { c in
            try openChat(wName)
            c.sig("ready")
            let (text, _) = try c.wait("sent", from: "web")
            _ = try waitText(text, 30)
            c.sig("read")
            try c.wait("checked", from: "web", 40)
            return "отметка «прочитано» проверена на вебе; на iOS у значка доставки нет accessibility-метки"
        }

        // --- Звонки ---
        scenario("K01", "Звонок веб → iPhone 1: входящий, принять, соединение, завершить", withWeb, timeout: 300) { c in
            try openChat(wName)
            c.sig("ready")
            try c.wait("calling", from: "web", 120)
            try answerIncoming(45)
            screenshot("call-in-progress")
            c.sig("answered")
            sleep(4)
            let st = try inCallCheck()
            let mic = micEnabled()
            try c.wait("connected", from: "web", 60)
            try c.wait("hungup", from: "web", 60)
            try waitCallClosed(25)
            return "\(st); экран звонка открыт, кнопки звука \(mic ? "активны (SDP согласован)" : "не активны/не найдены"); звук/видео в симуляторе не проверяются"
        }
        scenario("K02", "Звонок iPhone 1 → iPhone 2: принять, соединение, завершить", pair, timeout: 300) { c in
            try openChat(p2Match)
            try c.wait("ready", from: "iphone2")
            try startAudioCall()
            try waitCallScreen(20)
            c.sig("calling")
            try c.wait("answered", from: "iphone2", 90)
            sleep(6)
            let st = try inCallCheck()
            let mic = micEnabled()
            screenshot("call-1-2")
            c.sig("talked")
            try c.wait("checked", from: "iphone2", 30)
            hangUpIfInCall()
            try waitCallClosed(20)
            c.sig("hungup")
            try c.wait("closed", from: "iphone2", 40)
            return "\(st); сигнализация и экран звонка у обоих; кнопки звука \(mic ? "активны" : "не активны/не найдены"); ICE iPhone↔iPhone без веб-стороны не измерить"
        }
        scenario("K05", "Пропущенный звонок веб → iPhone 1 + вкладка «Звонки»", withWeb, timeout: 300) { c in
            try openChat(wName)
            c.sig("ready")
            try c.wait("calling", from: "web", 120)
            if incomingCallButton(true, timeout: 30) == nil { throw fail("входящий звонок не показан") }
            screenshot("missed-ringing")
            try c.wait("hungup", from: "web", 60)
            sleep(3)
            if app.state != .runningForeground { app.activate() }
            unlockIfNeeded()
            try openCallsTab()
            try need(labelContains("Пропущенный"), "«Пропущенный звонок» во вкладке «Звонки»", 20)
            screenshot("calls-missed")
            return nil
        }

        // --- Сеть ---
        scenario("F01", "Обрыв сети на вебе 10 с → очередь ушла", withWeb, timeout: 300) { c in
            try openChat(wName)
            c.sig("ready")
            let (text, _) = try c.wait("queued", from: "web", 120)
            let t = try waitText(text, 90)
            let (_, tOnline) = try c.wait("online", from: "web", 5)
            return "пришло через \(Int((t - tOnline) / 1000)) с после восстановления сети"
        }
        scenario("F02", "Обрыв сети раннера (iOS) 10 с → очередь ушла", withWeb, timeout: 300) { c in
            try openChat(wName)
            try c.wait("ready", from: "web")
            let r = board.net("block")
            board.log("сеть заблокирована: \(r)")
            sleep(1)
            let text = "Офлайн iOS \(c.tag)"
            sendMessage(text)
            screenshot("offline-sent")
            sleep(10)
            _ = board.net("unblock")
            c.sig("online", text)
            try c.wait("seen", from: "web", 150)
            return nil
        }
        scenario("F03", "Переключение на резервный адрес", allRoles, timeout: 300) { c in
            let info = board.net("backup-info")
            let usable = info["usable"] as? [String] ?? []
            if usable.isEmpty {
                throw E2ESkip(msg: "пропущен: нет DNS резервного адреса (servers.hosts=\(info["hosts"] ?? "[]"))")
            }
            try openChat(wName)
            _ = board.net("hosts-break")
            defer { _ = board.net("hosts-restore") }
            app.terminate(); launch()
            unlockIfNeeded()
            try openChat(wName, timeout: 60)
            let text = "Резерв \(c.tag)"
            sendMessage(text)
            c.sig("sent", text)
            try c.wait("seen", from: "web", 120)
            return "резервный: \(usable.joined(separator: ", "))"
        }

        // --- Удаление аккаунта у отдельного пользователя ---
        scenario("X01", "Удаление аккаунта (отдельный тест-пользователь)", withWeb, timeout: 200) { c in
            let dl = env["L2_D_LOGIN"] ?? "", dp = env["L2_D_PASSWORD"] ?? ""
            try ensureLoggedIn(dl, dp)
            tab("l2.tab.settings").tap(); sleep(1)
            try need(any("l2.settings.profile"), "профиль").tap(); sleep(2)
            try tapVisible(any("l2.profile.delete"), "кнопка «Удалить аккаунт»")
            try need(app.alerts.firstMatch, "подтверждение удаления", 8)
            screenshot("delete-confirm")
            try need(dialogButton("Удалить"), "«Удалить»").tap()
            try need(app.buttons["l2.welcome.login"], "стартовый экран после удаления", 30)
            session = nil
            c.sig("deleted")
            try c.wait("checked", from: "web", 60)
            return nil
        }
    }

    private func newChat(_ login: String) throws {
        try goChats()
        try need(app.buttons["Новый чат"].firstMatch, "«Новый чат»").tap()
        sleep(1)
        let f = app.textFields["Логин или имя"].firstMatch.exists ? app.textFields["Логин или имя"].firstMatch
            : (app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch)
        try need(f, "поле поиска нового чата").tap()
        dismissKeyboardTips()
        f.typeText(login)
        let found = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", login)).firstMatch
        let ftxt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", login)).firstMatch
        let end = Date().addingTimeInterval(20)
        while !found.exists && !ftxt.exists && Date() < end { usleep(300_000) }
        screenshot("new-chat-found")
        if found.exists { found.tap() } else if ftxt.exists { ftxt.tap() } else { throw fail("поиск не нашёл @\(login)") }
        acceptInviteIfAsked()
        try need(chatInput(), "поле ввода нового чата", 20)
        sleep(1)
    }

    /// Две доставки в открытом чате: я → собеседник, собеседник → я.
    private func deliveryPair(_ s1: String, _ s2: String, _ me: String, _ peer: String, peerRole: String, chat: String) {
        let roles = [role, peerRole].sorted()
        scenario(s1, "Доставка \(me) → \(peer)", roles) { c in
            try openChat(chat)
            try c.wait("ready", from: peerRole)
            let text = "Доставка \(c.tag)"
            typeIntoInput(text)
            let t0 = nowMs()
            tapSend()
            c.sig("sent", "\(Int(t0))")
            try c.wait("seen", from: peerRole, 60)
            return nil
        }
        scenario(s2, "Доставка \(peer) → \(me)", roles) { c in
            try openChat(chat)
            c.sig("ready")
            let text = "Доставка \(c.tag)"
            let t1 = try waitText(text, 60)
            let (v, _) = try c.wait("sent", from: peerRole, 10)
            c.sig("seen")
            return deliveryMetric(Double(v) ?? t1, t1)
        }
    }

    /// Получатель первой доставки (зеркально к deliveryPair).
    private func deliveryPairPeer(_ s1: String, _ s2: String, _ me: String, _ peer: String, peerRole: String, chat: String) {
        let roles = [role, peerRole].sorted()
        scenario(s1, "Доставка \(peer) → \(me)", roles) { c in
            try openChat(chat)
            c.sig("ready")
            let text = "Доставка \(c.tag)"
            let t1 = try waitText(text, 60)
            let (v, _) = try c.wait("sent", from: peerRole, 10)
            c.sig("seen")
            return deliveryMetric(Double(v) ?? t1, t1)
        }
        scenario(s2, "Доставка \(me) → \(peer)", roles) { c in
            try openChat(chat)
            try c.wait("ready", from: peerRole)
            let text = "Доставка \(c.tag)"
            typeIntoInput(text)
            let t0 = nowMs()
            tapSend()
            c.sig("sent", "\(Int(t0))")
            try c.wait("seen", from: peerRole, 60)
            return nil
        }
    }

    private func pickFirstPhoto() throws {
        // Галерея (UIImagePickerController / PHPicker): первая картинка, затем «Выбрать»/«Choose», если есть.
        let candidates = [
            app.scrollViews.images.firstMatch,
            app.images.matching(NSPredicate(format: "label BEGINSWITH[c] 'Photo' OR label BEGINSWITH[c] 'Фото' OR label CONTAINS[c] ', '")).firstMatch,
            app.cells.images.firstMatch,
            app.collectionViews.cells.firstMatch,
        ]
        let end = Date().addingTimeInterval(15)
        var tapped = false
        while !tapped && Date() < end {
            for e in candidates where e.exists && e.isHittable { e.tap(); tapped = true; break }
            if !tapped { usleep(500_000) }
        }
        if !tapped { throw fail("в галерее не найдено фото (simctl addmedia?)") }
        sleep(2)
        for t in ["Choose", "Выбрать", "Add", "Добавить", "Done", "Готово"] {
            let b = app.buttons[t].firstMatch
            if b.exists && b.isHittable { b.tap(); sleep(2); break }
        }
    }

    private func pickFileInFiles(_ name: String) throws {
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", name)).firstMatch
        if file.waitForExistence(timeout: 5) { file.tap(); sleep(2); return }
        for t in ["Browse", "Обзор"] where app.buttons[t].firstMatch.exists { app.buttons[t].firstMatch.tap(); sleep(2) }
        for t in ["On My iPhone", "На iPhone"] {
            let loc = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", t)).firstMatch
            if loc.waitForExistence(timeout: 3) { loc.tap(); sleep(2); break }
        }
        try need(file, "файл «\(name)» в «Файлах»", 10).tap()
        sleep(2)
        let open = app.buttons["Open"].firstMatch.exists ? app.buttons["Open"].firstMatch : app.buttons["Открыть"].firstMatch
        if open.exists && open.isHittable { open.tap(); sleep(2) }
    }

    /// Экран предпросмотра вложения → «Отправить».
    private func sendPreview() throws {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            let byLabel = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'отправ' OR label CONTAINS[c] 'send' OR identifier CONTAINS[c] 'send'")).allElementsBoundByIndex
            if let b = byLabel.last(where: { $0.isHittable }) { b.tap(); sleep(2); return }
            usleep(500_000)
        }
        throw fail("нет кнопки «Отправить» на экране вложения")
    }

    // MARK: - Роль iPhone 2: вход, все настройки, собеседник iPhone 1 и веба

    private func playIphone2() {
        let login = env["L2_P2_LOGIN"] ?? "", newPw = env["L2_P2_NEWPASS"] ?? ""

        solo("R04", "Вход по логину (iPhone 2)") { _ in
            launch()
            try ensureLoggedIn(login, p2Password)
            screenshot("chats")
            return nil
        }

        solo("P01", "Push через FCM (токен iPhone 2 принят Firebase)") { c in
            try ensureLoggedIn(login, p2Password)
            dismissSpringboardAlerts()
            sleep(c.a == 1 ? 15 : 30)
            dismissSpringboardAlerts()
            let (_, j) = board.call("/push-check", ["login": login], timeout: 40)
            let http = j["http"] as? Int ?? 0
            if http == 404 { throw E2ESkip(msg: "пропущен: нет endpoint /invite/api/ci/push-check на сервере") }
            guard http == 200 else { throw fail("push-check: HTTP \(http) \(j["error"] ?? "")") }
            let n = j["tokens"] as? Int ?? 0, k = j["ok"] as? Int ?? 0
            let errs = (j["errors"] as? [Any])?.map { "\($0)" }.joined(separator: "; ") ?? ""
            if n < 1 { throw fail("у iPhone 2 нет FCM-токена на сервере (разрешение на уведомления/APNs в симуляторе?)") }
            if k != n { throw fail("Firebase принял \(k) из \(n) токенов: \(errs)") }
            return "токенов \(n), Firebase принял \(k) (validate_only)"
        }

        solo("N01", "Настройки: имя") { _ in
            try ensureLoggedIn(login, p2Password)
            try openProfile()
            let f = try need(any("l2.profile.name"), "поле имени")
            f.tap()
            let cur = (f.value as? String) ?? ""
            f.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: cur.count + 2))
            f.typeText(p2Name)
            if app.keyboards.firstMatch.exists { app.swipeDown() }
            try tapVisible(any("l2.profile.save"), "«Сохранить»")
            sleep(3)
            back()
            tab("l2.tab.settings").tap(); sleep(1)
            try need(labelContains(p2Name), "новое имя на карточке профиля", 10)
            return nil
        }

        solo("N02", "Настройки: аватар (фото из галереи)") { _ in
            try ensureLoggedIn(login, p2Password)
            try openProfile()
            try tapVisible(any("l2.profile.photo"), "кнопка фото")
            try need(dialogButton("Выбрать из галереи"), "«Выбрать из галереи»").tap()
            sleep(3)
            try pickFirstPhoto()
            let done = labelContains("Фото обновлено")
            let end = Date().addingTimeInterval(30)
            var ok = false
            while Date() < end { if done.exists { ok = true; break }; usleep(300_000) }
            screenshot("avatar")
            back()
            if !ok { throw fail("нет подтверждения «Фото обновлено»") }
            return nil
        }

        solo("N03", "Настройки: тема (светлая → тёмная)") { _ in
            try ensureLoggedIn(login, p2Password)
            try openSettingsItem("Внешний вид")
            try need(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Тема: Светлая'")).firstMatch, "«Светлая»").tap(); sleep(2)
            try need(app.buttons["Тема: Светлая, выбрана"].firstMatch, "светлая тема выбрана", 5)
            screenshot("theme-light")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Тема: Тёмная'")).firstMatch.tap(); sleep(2)
            try need(app.buttons["Тема: Тёмная, выбрана"].firstMatch, "тёмная тема вернулась", 5)
            back()
            return nil
        }

        solo("N04", "Настройки: цвет акцента") { _ in
            try ensureLoggedIn(login, p2Password)
            try openSettingsItem("Внешний вид")
            try need(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Фиолетовый'")).firstMatch, "«Фиолетовый»").tap(); sleep(2)
            try need(app.buttons["Фиолетовый, выбран"], "фиолетовый выбран", 5)
            screenshot("accent-violet")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Мятный'")).firstMatch.tap(); sleep(2)
            try need(app.buttons["Мятный, выбран"], "мятный вернулся", 5)
            back()
            return nil
        }

        solo("N05", "Настройки: уведомления (переключатель туда-обратно)") { _ in
            try ensureLoggedIn(login, p2Password)
            try openSettingsItem("Уведомления")
            let sw = app.switches.element(boundBy: 0)
            try need(sw, "переключатель в «Уведомлениях»")
            let before = (sw.value as? String) ?? ""
            sw.tap(); sleep(1)
            let mid = (sw.value as? String) ?? ""
            sw.tap(); sleep(1)
            let after = (sw.value as? String) ?? ""
            screenshot("notifications")
            back()
            if before == mid || before != after { throw fail("переключатель не переключается (\(before)→\(mid)→\(after))") }
            return nil
        }

        solo("N06", "Настройки: конфиденциальность (блокировка, безопасность, заблокированные)") { _ in
            try ensureLoggedIn(login, p2Password)
            try openSettingsItem("Конфиденциальность")
            try need(labelContains("Блокировка приложения"), "«Блокировка приложения»").tap(); sleep(2)
            try need(labelContains("PIN-код для входа"), "«PIN-код для входа»")
            screenshot("applock"); back()
            try need(labelContains("Безопасность аккаунта"), "«Безопасность аккаунта»").tap(); sleep(2)
            try need(labelContains("Сменить пароль"), "«Сменить пароль»")
            try need(labelContains("Заблокированные"), "«Заблокированные»").tap(); sleep(2)
            screenshot("blocked"); back(); back(); back()
            return nil
        }

        solo("N07", "Настройки: смена пароля → вход с новым паролем") { _ in
            guard !newPw.isEmpty else { throw fail("нет L2_P2_NEWPASS") }
            try ensureLoggedIn(login, p2Password)
            try openSettingsItem("Конфиденциальность")
            try need(labelContains("Безопасность аккаунта"), "«Безопасность аккаунта»").tap(); sleep(2)
            try need(labelContains("Сменить пароль"), "«Сменить пароль»").tap()
            let alert = try need(app.alerts.firstMatch, "окно «Новый пароль»", 5)
            let f1 = alert.secureTextFields.element(boundBy: 0), f2 = alert.secureTextFields.element(boundBy: 1)
            f1.tap(); f1.typeText(newPw)
            f2.tap(); f2.typeText(newPw)
            alert.buttons["Сохранить"].tap()
            let okToast = labelContains("Пароль изменён")
            let end = Date().addingTimeInterval(15)
            var seen = false
            while Date() < end { if okToast.exists { seen = true; break }; usleep(200_000) }
            back(); back()
            try logoutFromMain()
            session = nil
            try loginWith(login, newPw)
            session = login
            p2Password = newPw
            return seen ? nil : "подсказка «Пароль изменён» не поймана, но вход с новым паролем прошёл"
        }

        solo("N08", "Настройки: смена PIN → перезапуск с новым PIN") { _ in
            try ensureLoggedIn(login, p2Password)
            try openSettingsItem("Конфиденциальность")
            try need(labelContains("Блокировка приложения"), "«Блокировка приложения»").tap(); sleep(2)
            try need(app.staticTexts["Сменить PIN-код"].firstMatch, "«Сменить PIN-код»").tap()
            try need(app.staticTexts["Текущий PIN-код"].firstMatch, "ввод текущего PIN", 8)
            enterPin()
            let newPin = ["2", "4", "6", "8"]
            try need(app.staticTexts["Придумайте PIN-код"].firstMatch, "ввод нового PIN", 8)
            enterPin(newPin)
            try need(app.staticTexts["Повторите PIN-код"].firstMatch, "повтор нового PIN", 8)
            enterPin(newPin)
            sleep(2)
            pin = newPin
            app.terminate(); launch()
            try need(app.staticTexts["Введите PIN-код"], "PIN при запуске")
            enterPin()
            try need(tab("l2.tab.chats"), "Чаты после нового PIN")
            return nil
        }

        _ = board.barrier("chats", roles: allRoles, timeout: 1500)

        // --- Собеседник iPhone 1 ---
        scenario("C01", "Новый чат iPhone 1 → iPhone 2", ["iphone1", "iphone2"]) { c in
            try ensureLoggedIn(login, p2Password)
            try goChats()
            let (v, _) = try c.wait("sent", from: "iphone1", 180)
            let text = "Привет, iPhone 2! \(c.tag)"
            let cell = labelContains(p1Name)
            let end = Date().addingTimeInterval(60)
            while !cell.exists && Date() < end { usleep(100_000) }
            let tList = nowMs()
            if !cell.exists { throw fail("новый чат от iPhone 1 не появился в списке") }
            try openChat(p1Name)
            _ = try waitText(text, 20)
            c.sig("seen")
            return "в списке через \(Int(tList - (Double(v) ?? tList))) мс после отправки"
        }
        deliveryPairPeer("D01", "D02", "iPhone 2", "iPhone 1", peerRole: "iphone1", chat: p1Name)

        // --- Доставка iPhone 2 ↔ веб ---
        deliveryPair("D05", "D06", "iPhone 2", "веб", peerRole: "web", chat: wName)

        // --- Проверка действий iPhone 1 ---
        let pair = ["iphone1", "iphone2"]
        scenario("M01", "Ответ на сообщение (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p1Name)
            c.sig("ready")
            try c.wait("sent", from: "iphone1", 120)
            let base = "База \(c.tag)", reply = "Ответ \(c.tag)"
            _ = try waitText(reply, 20)
            if countContains(base) < 2 { throw fail("у получателя у ответа нет цитаты исходного сообщения") }
            c.sig("checked")
            return nil
        }
        scenario("M02", "Реакция 🔥 (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p1Name)
            c.sig("ready")
            try c.wait("base", from: "iphone1", 120)
            _ = try waitText("Реакция \(c.tag)", 20)
            c.sig("seen")
            try c.wait("reacted", from: "iphone1", 90)
            let t0 = nowMs()
            try need(any("l2.reaction.🔥"), "реакция 🔥 у получателя", 20)
            c.sig("checked")
            return "реакция видна через \(Int(nowMs() - t0)) мс"
        }
        scenario("M03", "Закрепить и открепить (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p1Name)
            c.sig("ready")
            try c.wait("pinned", from: "iphone1", 120)
            try need(any("l2.pinned.counter"), "плашка закреплённого у получателя", 20)
            screenshot("pinned-peer")
            c.sig("seenPinned")
            try c.wait("unpinned", from: "iphone1", 60)
            try needGone(any("l2.pinned.counter"), "плашка после открепления", 20)
            c.sig("seenUnpinned")
            return nil
        }
        scenario("M04", "Изменить сообщение (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p1Name)
            c.sig("ready")
            try c.wait("base", from: "iphone1", 120)
            _ = try waitText("Черновик \(c.tag)", 20)
            c.sig("seen")
            try c.wait("edited", from: "iphone1", 90)
            _ = try waitText("Исправлено \(c.tag)", 20)
            c.sig("checked")
            return nil
        }
        scenario("M05", "Удалить сообщение (iPhone 1 → iPhone 2)", pair) { c in
            try openChat(p1Name)
            c.sig("ready")
            try c.wait("base", from: "iphone1", 120)
            let base = "Удалить \(c.tag)"
            _ = try waitText(base, 20)
            c.sig("seen")
            let (mode, _) = try c.wait("deleted", from: "iphone1", 90)
            if mode == "all" { try needGone(labelContains(base), "удалённое у всех сообщение у получателя", 20) }
            c.sig("checked")
            return mode == "all" ? nil : "у получателя сообщение остаётся (удалено только у отправителя)"
        }
        scenario("K02", "Звонок iPhone 1 → iPhone 2: принять, соединение, завершить", pair, timeout: 300) { c in
            try openChat(p1Name)
            c.sig("ready")
            try c.wait("calling", from: "iphone1", 120)
            try answerIncoming(45)
            screenshot("call-2")
            c.sig("answered")
            try c.wait("talked", from: "iphone1", 60)
            c.sig("checked")
            try c.wait("hungup", from: "iphone1", 60)
            try waitCallClosed(25)
            c.sig("closed")
            return nil
        }
        let withWeb = ["iphone2", "web"]
        scenario("K03", "Звонок iPhone 2 → веб: принять, соединение, завершить", withWeb, timeout: 300) { c in
            try openChat(wName)
            try c.wait("ready", from: "web")
            try startAudioCall()
            try waitCallScreen(20)
            c.sig("calling")
            try c.wait("connected", from: "web", 90)
            sleep(3)
            let st = try inCallCheck()
            let mic = micEnabled()
            screenshot("call-2-web")
            hangUpIfInCall()
            try waitCallClosed(20)
            c.sig("hungup")
            try c.wait("ended", from: "web", 40)
            return "\(st); кнопки звука \(mic ? "активны" : "не активны/не найдены")"
        }
        scenario("K04", "Отклонённый звонок веб → iPhone 2 + вкладка «Звонки»", withWeb, timeout: 300) { c in
            try openChat(wName)
            c.sig("ready")
            try c.wait("calling", from: "web", 120)
            guard let d = incomingCallButton(false, timeout: 40) else { throw fail("входящий звонок не показан (нет «Отклонить»)") }
            screenshot("decline")
            d.tap()
            sleep(2)
            c.sig("declined")
            if app.state != .runningForeground { app.activate() }
            unlockIfNeeded()
            try c.wait("ended", from: "web", 40)
            try openCallsTab()
            try need(labelContains("Отклон"), "«Отклонённый звонок» во вкладке «Звонки»", 20)
            screenshot("calls-declined")
            return nil
        }
        scenario("F03", "Переключение на резервный адрес", allRoles, timeout: 300) { c in
            let info = board.net("backup-info")
            if (info["usable"] as? [String] ?? []).isEmpty { throw E2ESkip(msg: "пропущен: нет DNS резервного адреса") }
            try c.wait("sent", from: "iphone1", 200)
            return nil
        }
    }

    private func openProfile() throws {
        unlockIfNeeded()
        tab("l2.tab.settings").tap(); sleep(1)
        for _ in 0..<2 where !any("l2.settings.profile").exists { back() }
        try need(any("l2.settings.profile"), "карточка профиля").tap()
        sleep(2)
    }

    private func openSettingsItem(_ item: String) throws {
        unlockIfNeeded()
        tab("l2.tab.settings").tap(); sleep(1)
        for _ in 0..<3 where !app.staticTexts[item].firstMatch.exists { back(); tab("l2.tab.settings").tap() }
        try need(app.staticTexts[item].firstMatch, "пункт «\(item)»").tap()
        sleep(2)
    }
}
