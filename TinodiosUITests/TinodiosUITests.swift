//
//  TinodiosUITests.swift
//  Линия 2.0: автопроверка перед загрузкой в TestFlight (iOS Simulator, XCUITest).
//
//  Тесты идут по порядку номеров (XCTest запускает их по алфавиту) и при перезапуске
//  (xcodebuild -retry-tests-on-failure) сами приводят приложение в нужное состояние.
//
//  Данные приходят из окружения (xcodebuild TEST_RUNNER_*):
//    L2_CODE, L2_REG_LOGIN, L2_REG_PASSWORD — регистрация по коду (этот аккаунт тест потом удаляет);
//    L2_LOGIN, L2_PASSWORD — тестовый пользователь с готовой перепиской с «Собеседник CI»;
//    L2_PEER_LOGIN, L2_PEER_NAME — собеседник;
//    L2_REVIEW_LOGIN, L2_REVIEW_PASSWORD — аккаунт для проверки Apple (только вход и просмотр).
//  Скриншоты экранов и скриншот при каждом падении — во вложениях xcresult.
//

import XCTest
import UIKit

final class TinodiosUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shot = 0
    private var launched = false
    private let env = ProcessInfo.processInfo.environment
    private let pin = ["1", "3", "5", "7"]

    /// Кто сейчас вошёл в приложение (между тестами одного прогона).
    private static var session: String?
    /// Регистрация в тесте 03 прошла — дальше работаем этим аккаунтом.
    private static var registered = false
    private static var regAttempts = 0
    private static let sentText = "Ответ из теста " + String(Int(Date().timeIntervalSince1970) % 100000)

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-l2-uitest"]
        XCUIDevice.shared.orientation = .portrait
        addUIInterruptionMonitor(withDescription: "Системные запросы") { alert in
            for title in ["Allow", "Разрешить", "OK", "Don’t Allow", "Don't Allow", "Не разрешать", "Allow While Using App"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        // Скриншот при падении + проверка, что приложение не вылетело.
        if let run = testRun, run.failureCount > 0 || run.unexpectedExceptionCount > 0 {
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = "ПАДЕНИЕ-\(name)"
            a.lifetime = .keepAlways
            add(a)
        }
        if launched && app.state == .notRunning {
            Self.session = nil
            XCTFail("Приложение закрылось во время теста (вылет)")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Помощники

    private func screenshot(_ name: String) {
        shot += 1
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = String(format: "%@-%02d-%@", String(self.name.split(separator: " ").last ?? "t").replacingOccurrences(of: "]", with: ""), shot, name)
        a.lifetime = .keepAlways
        add(a)
    }

    @discardableResult
    private func wait(_ e: XCUIElement, _ what: String, timeout: TimeInterval = 20) -> XCUIElement {
        if !e.waitForExistence(timeout: timeout) {
            screenshot("НЕ НАЙДЕНО-" + what)
            XCTFail("Не появился элемент: \(what)")
        }
        return e
    }

    private func requireEnv(_ k: String) -> String {
        guard let v = env[k], !v.isEmpty else {
            XCTFail("Нет переменной окружения \(k) (секрет GitHub не задан)")
            return ""
        }
        return v
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Кнопка подтверждения — в алерте или в листе действий.
    private func dialogButton(_ title: String) -> XCUIElement {
        if app.alerts.buttons[title].firstMatch.exists { return app.alerts.buttons[title].firstMatch }
        if app.sheets.buttons[title].firstMatch.exists { return app.sheets.buttons[title].firstMatch }
        let a = app.alerts.buttons[title].firstMatch
        if a.waitForExistence(timeout: 4) { return a }
        return app.sheets.buttons[title].firstMatch
    }

    private func labelContains(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func launch() {
        app.launch()
        launched = true
        dismissSpringboardAlerts()
    }

    private func dismissSpringboardAlerts() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "Разрешить", "OK", "Don’t Allow", "Don't Allow", "Не разрешать"] {
            let b = sb.buttons[title]
            if b.exists { b.tap() }
        }
    }

    /// Подсказка клавиатуры при первом запуске («Speed up your typing… Continue»).
    private func dismissKeyboardTips() {
        for title in ["Continue", "Продолжить"] {
            let b = app.buttons[title].firstMatch
            if b.waitForExistence(timeout: 1) { b.tap() }
        }
    }

    private func tapVisible(_ e: XCUIElement, _ what: String) {
        wait(e, what)
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
            ti.tap()
            ti.typeText(digits)
            return
        }
        for ch in digits {
            let k = app.keys[String(ch)].firstMatch
            if k.waitForExistence(timeout: 2) && k.isHittable { k.tap() } else { app.typeText(String(ch)) }
            usleep(150_000)
        }
    }

    private func tab(_ id: String) -> XCUIElement {
        app.otherElements[id].firstMatch.exists ? app.otherElements[id].firstMatch : any(id)
    }

    private var tabBarVisible: Bool { tab("l2.tab.chats").exists && tab("l2.tab.chats").isHittable }

    private func back() {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap() }
        sleep(1)
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

    /// Создание PIN после входа/регистрации; Face ID в симуляторе нет — «Не сейчас».
    private func createPinAndReachChats() {
        wait(app.staticTexts["Придумайте PIN-код"], "экран создания PIN", timeout: 30)
        screenshot("pin-create")
        enterPin()
        wait(app.staticTexts["Повторите PIN-код"], "экран повтора PIN", timeout: 10)
        enterPin()
        let skip = app.buttons["Не сейчас"]
        if skip.waitForExistence(timeout: 3) { screenshot("faceid"); skip.tap() }
        wait(tab("l2.tab.chats"), "вкладки после входа", timeout: 30)
        sleep(1)
    }

    private func logoutFromMain() {
        tab("l2.tab.settings").tap(); sleep(1)
        let out = app.staticTexts["Выйти"].firstMatch
        if !out.isHittable { app.swipeUp() }
        wait(out, "«Выйти»").tap()
        wait(dialogButton("Выйти"), "подтверждение выхода").tap()
        wait(app.buttons["l2.welcome.login"], "стартовый экран после выхода", timeout: 20)
        Self.session = nil
    }

    private func ensureLoggedOut() {
        launch()
        switch currentScreen() {
        case .welcome: return
        case .pinEnter: enterPin(); wait(tab("l2.tab.chats"), "Чаты после PIN"); logoutFromMain()
        case .main: logoutFromMain()
        case .pinCreate, .unknown:
            // Незавершённый вход — перезапуск с чистого листа не нужен: возвращаемся назад.
            for _ in 0..<3 where !app.buttons["l2.welcome.login"].exists { back() }
        }
        wait(app.buttons["l2.welcome.login"], "стартовый экран")
    }

    private func loginWith(_ login: String, _ password: String) {
        wait(app.buttons["l2.welcome.login"], "стартовый экран").tap()
        let lf = wait(app.textFields["l2.login.login"], "поле логина")
        lf.tap()
        if let v = lf.value as? String, !v.isEmpty, v != "Логин" {
            lf.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: v.count + 2))
        }
        dismissKeyboardTips()
        lf.typeText(login + "\n")      // «Далее» → пароль
        app.typeText(password)
        screenshot("login-filled")
        app.typeText("\n")             // «Войти» с клавиатуры
        createPinAndReachChats()
        Self.session = login
    }

    /// Приложение запущено, вошли нужным пользователем, открыта вкладка «Чаты».
    private func ensureLoggedIn(_ login: String, _ password: String) {
        launch()
        var s = currentScreen()
        if s == .pinEnter { enterPin(); wait(tab("l2.tab.chats"), "Чаты после PIN"); s = .main }
        if s == .main && Self.session == login { tab("l2.tab.chats").tap(); sleep(1); return }
        if s == .main { logoutFromMain() }
        if s == .pinCreate || s == .unknown { for _ in 0..<3 where !app.buttons["l2.welcome.login"].exists { back() } }
        loginWith(login, password)
    }

    /// Любой рабочий аккаунт: зарегистрированный в тесте 03, иначе тестовый пользователь CI.
    private func ensureSomeUser() {
        if Self.registered {
            ensureLoggedIn(requireEnv("L2_REG_LOGIN"), requireEnv("L2_REG_PASSWORD"))
        } else {
            ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        }
    }

    private var peerName: String { env["L2_PEER_NAME"] ?? "Собеседник CI" }

    private func peerChatCell() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] 'История'", peerName)).firstMatch
    }

    private func chatInput() -> XCUIElement {
        let byId = app.textViews["l2.chat.input"].firstMatch
        return byId.exists ? byId : app.textViews.firstMatch
    }

    /// Тестовый пользователь CI → чат с собеседником (история создана workflow).
    private func openPeerChat() {
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        tab("l2.tab.chats").tap(); sleep(1)
        let cell = wait(peerChatCell(), "чат с собеседником", timeout: 20)
        cell.tap()
        wait(chatInput(), "поле ввода в чате", timeout: 15)
        sleep(2)
    }

    private func sendMessage(_ text: String) {
        let input = chatInput()
        input.tap()
        dismissKeyboardTips()
        input.typeText(text)
        let send = app.buttons["l2.chat.send"].firstMatch
        if send.exists && send.isHittable { send.tap() } else { app.typeText("\n") }
    }

    private func assertOnChatList(_ how: String) {
        XCTAssertTrue(app.buttons["Новый чат"].firstMatch.waitForExistence(timeout: 8), "после «\(how)» не открылся список чатов")
        XCTAssertTrue(tabBarVisible, "после «\(how)» не видно нижнего меню")
    }

    // MARK: - 1. Вход и регистрация

    func test01_WelcomeScreen() {
        ensureLoggedOut()
        XCTAssertTrue(app.buttons["l2.welcome.code"].exists, "нет кнопки «У меня есть код»")
        XCTAssertTrue(app.buttons["l2.welcome.login"].isHittable, "кнопка «Войти» недоступна")
        screenshot("welcome")
    }

    func test02_InviteCodeSixDigits() {
        ensureLoggedOut()
        app.buttons["l2.welcome.code"].tap()
        let cells = wait(any("l2.code.cells"), "ячейки кода")
        screenshot("code-empty")
        cells.tap(); sleep(1)
        typeDigits("0000001")          // седьмая цифра не должна поместиться
        sleep(3)
        screenshot("code-wrong")
        XCTAssertEqual(app.state, .runningForeground, "приложение упало на неверном коде")
        XCTAssertFalse(app.textFields["l2.reg.name"].exists, "неверный код принят")
        back()
        wait(app.buttons["l2.welcome.login"], "стартовый экран после «назад»")
    }

    func test03_RegistrationByCode() {
        let code = requireEnv("L2_CODE"), login = requireEnv("L2_REG_LOGIN"), password = requireEnv("L2_REG_PASSWORD")
        if Self.registered { ensureLoggedIn(login, password); return }   // перезапуск после успешной регистрации
        Self.regAttempts += 1
        if Self.regAttempts > 1 {
            // Перезапуск после сбоя: код одноразовый. Если аккаунт уже создан — проверяем вход им.
            ensureLoggedIn(login, password)
            Self.registered = true
            return
        }
        ensureLoggedOut()
        app.buttons["l2.welcome.code"].tap()
        let cells = wait(any("l2.code.cells"), "ячейки кода")
        cells.tap(); sleep(1)
        typeDigits(code)
        wait(app.textFields["l2.reg.name"], "форма регистрации (код не принят?)", timeout: 25)
        dismissKeyboardTips()
        screenshot("register")
        for (id, text) in [("l2.reg.name", "Test CI"), ("l2.reg.login", login)] {
            tapVisible(app.textFields[id], id)
            dismissKeyboardTips()
            app.textFields[id].typeText(text)
        }
        tapVisible(app.secureTextFields["l2.reg.password"], "пароль")
        app.secureTextFields["l2.reg.password"].typeText(password)
        app.typeText("\n")
        app.typeText(password)
        screenshot("register-filled")
        app.typeText("\n")
        createPinAndReachChats()
        Self.session = login
        Self.registered = true
        screenshot("chats-after-register")
    }

    func test04_PinOnRelaunch() {
        ensureSomeUser()
        app.terminate()
        launch()
        wait(app.staticTexts["Введите PIN-код"], "экран PIN при запуске")
        screenshot("pin-enter")
        enterPin(["0", "0", "0", "0"])
        sleep(2)
        // Вкладки есть в иерархии и под экраном PIN — проверяем, что экран PIN остался.
        XCTAssertTrue(app.staticTexts["Введите PIN-код"].exists || app.staticTexts["Неверный PIN-код"].exists
                      || !tab("l2.tab.chats").isHittable, "неверный PIN пропустил в приложение")
        screenshot("pin-wrong")
        enterPin()
        wait(tab("l2.tab.chats"), "Чаты после верного PIN")
    }

    // MARK: - 2. Вкладки и меню

    func test05_TabChats() {
        ensureSomeUser()
        tab("l2.tab.chats").tap(); sleep(1)
        wait(app.buttons["Новый чат"].firstMatch, "кнопка «Новый чат»")
        XCTAssertTrue(tabBarVisible, "нет нижнего меню")
        screenshot("chats")
    }

    func test06_TabCalls() {
        ensureSomeUser()
        tab("l2.tab.calls").tap(); sleep(2)
        XCTAssertTrue(labelContains("Звонки").exists, "не открылась вкладка «Звонки»")
        XCTAssertTrue(tabBarVisible, "нет нижнего меню")
        screenshot("calls")
    }

    func test07_TabContacts() {
        ensureSomeUser()
        tab("l2.tab.contacts").tap(); sleep(2)
        wait(app.buttons["Добавить контакт"].firstMatch, "кнопка «Добавить контакт»")
        XCTAssertTrue(tabBarVisible, "нет нижнего меню")
        screenshot("contacts")
    }

    func test08_TabSettings() {
        ensureSomeUser()
        tab("l2.tab.settings").tap(); sleep(2)
        wait(app.staticTexts["Внешний вид"].firstMatch, "пункт «Внешний вид»")
        XCTAssertTrue(any("l2.settings.profile").exists, "нет карточки профиля")
        XCTAssertTrue(tabBarVisible, "нет нижнего меню")
        screenshot("settings")
    }

    func test09_TabBarOnInnerScreens() {
        ensureSomeUser()
        tab("l2.tab.settings").tap(); sleep(1)
        wait(app.staticTexts["О приложении"].firstMatch, "«О приложении»").tap(); sleep(2)
        // Требование владельца 27.11: нижнее меню только на главных экранах вкладок.
        XCTAssertFalse(tabBarVisible, "нижнее меню видно на вложенном экране «О приложении»")
        screenshot("about-no-tabbar")
        back()
        tab("l2.tab.contacts").tap(); sleep(1)
        wait(app.buttons["Добавить контакт"].firstMatch, "«Добавить контакт»").tap(); sleep(2)
        XCTAssertFalse(tabBarVisible, "нижнее меню видно на вложенном экране «Добавить контакт»")
        back()
        XCTAssertTrue(tabBarVisible, "на главном экране «Контакты» нет нижнего меню")
    }

    // MARK: - 3. Настройки

    func test10_SettingsEachItem() {
        ensureSomeUser()
        for item in ["Уведомления", "Конфиденциальность", "Внешний вид", "О приложении"] {
            tab("l2.tab.settings").tap(); sleep(1)
            wait(app.staticTexts[item].firstMatch, "пункт «\(item)»").tap()
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "вылет в «\(item)»")
            screenshot("settings-" + item)
            if item == "Конфиденциальность" {
                for sub in ["Блокировка приложения (PIN-код, Face ID)", "Безопасность аккаунта"] {
                    let s = app.staticTexts[sub].firstMatch
                    if s.waitForExistence(timeout: 3) { s.tap(); sleep(2); screenshot("privacy-" + sub); back() }
                }
            }
            back()
        }
        // Профиль: поля и клавиатура.
        tab("l2.tab.settings").tap(); sleep(1)
        any("l2.settings.profile").tap(); sleep(2)
        wait(any("l2.profile.name"), "поле имени в профиле")
        screenshot("profile")
        back()
    }

    private func openAppearance() {
        tab("l2.tab.settings").tap(); sleep(1)
        wait(app.staticTexts["Внешний вид"].firstMatch, "«Внешний вид»").tap(); sleep(2)
    }

    func test11_ThemeChange() {
        ensureSomeUser()
        openAppearance()
        let light = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Тема: Светлая'")).firstMatch
        wait(light, "кнопка темы «Светлая»").tap(); sleep(2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Тема: Светлая, выбрана'")).firstMatch.waitForExistence(timeout: 5),
                      "светлая тема не выбралась")
        screenshot("theme-light")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Тема: Тёмная'")).firstMatch.tap(); sleep(2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Тема: Тёмная, выбрана'")).firstMatch.waitForExistence(timeout: 5),
                      "тёмная тема не вернулась")
        screenshot("theme-dark")
        back()
    }

    func test12_AccentChange() {
        ensureSomeUser()
        openAppearance()
        wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Фиолетовый'")).firstMatch, "цвет «Фиолетовый»").tap(); sleep(2)
        XCTAssertTrue(app.buttons["Фиолетовый, выбран"].waitForExistence(timeout: 5), "цвет не выбрался")
        screenshot("accent-violet")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Мятный'")).firstMatch.tap(); sleep(2)
        XCTAssertTrue(app.buttons["Мятный, выбран"].waitForExistence(timeout: 5), "мятный не вернулся")
        back()
    }

    // MARK: - 4. Поиск и контакты

    func test13_SearchChats() {
        ensureSomeUser()
        tab("l2.tab.chats").tap(); sleep(1)
        let search = wait(app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch, "поле поиска")
        search.tap()
        dismissKeyboardTips()
        search.typeText("История")
        sleep(2)
        screenshot("search")
        XCTAssertEqual(app.state, .runningForeground, "вылет при поиске")
        let cancel = app.buttons["Отмена"].firstMatch
        if cancel.exists { cancel.tap() } else { app.typeText("\n") }
    }

    func test14_AddContactFindsUser() {
        ensureSomeUser()
        tab("l2.tab.contacts").tap(); sleep(1)
        wait(app.buttons["Добавить контакт"].firstMatch, "«Добавить контакт»").tap(); sleep(2)
        let f = wait(app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch, "поле поиска контакта")
        f.tap()
        dismissKeyboardTips()
        f.typeText(requireEnv("L2_PEER_LOGIN"))
        XCTAssertTrue(labelContains(peerName).waitForExistence(timeout: 15), "поиск не нашёл пользователя по логину")
        screenshot("add-contact-found")
        back()
    }

    func test15_DeleteAccount() {
        guard Self.registered else {
            XCTFail("Удалять нечего: регистрация в тесте 03 не прошла")
            return
        }
        ensureLoggedIn(requireEnv("L2_REG_LOGIN"), requireEnv("L2_REG_PASSWORD"))
        tab("l2.tab.settings").tap(); sleep(1)
        any("l2.settings.profile").tap(); sleep(2)
        let del = any("l2.profile.delete")
        tapVisible(del, "кнопка «Удалить аккаунт»")
        wait(app.alerts["Удалить аккаунт навсегда?"], "подтверждение удаления")
        screenshot("delete-confirm")
        dialogButton("Удалить").tap()
        wait(app.buttons["l2.welcome.login"], "стартовый экран после удаления", timeout: 30)
        Self.session = nil
        Self.registered = false
        screenshot("deleted")
    }

    // MARK: - 5. Вход/выход аккаунтом проверки Apple

    func test16_LoginReviewAccount() {
        ensureLoggedIn(requireEnv("L2_REVIEW_LOGIN"), requireEnv("L2_REVIEW_PASSWORD"))
        wait(app.buttons["Новый чат"].firstMatch, "список чатов")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 15), "у аккаунта проверки Apple не видно переписки")
        screenshot("review-chats")
    }

    func test17_Logout() {
        ensureLoggedIn(requireEnv("L2_REVIEW_LOGIN"), requireEnv("L2_REVIEW_PASSWORD"))
        logoutFromMain()
        screenshot("after-logout")
        XCTAssertTrue(app.buttons["l2.welcome.code"].exists, "после выхода нет стартового экрана")
    }

    // MARK: - 6. Чат

    func test18_OpenChatShowsHistory() {
        openPeerChat()
        XCTAssertTrue(labelContains("История 1").waitForExistence(timeout: 10), "в чате не видна история")
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists, "в чате нет кнопки «назад»")
        XCTAssertTrue(labelContains(peerName).exists, "в шапке чата нет имени собеседника")
        screenshot("chat-history")
    }

    func test19_TabBarVisibleInChat() {
        // Требование владельца 27.11 (баг сборки 1006): в открытом чате нижнего меню нет, только «Назад».
        openPeerChat()
        XCTAssertFalse(tabBarVisible, "в чате видно нижнее меню «Чаты / Звонки / Контакты / Настройки»")
        let input = chatInput()
        XCTAssertGreaterThan(input.frame.maxY, app.frame.height - 140, "панель ввода не у нижнего края (оставлено место под меню)")
        screenshot("chat-no-tabbar")
    }

    func test20_SendMessageAppears() {
        openPeerChat()
        sendMessage(Self.sentText)
        XCTAssertTrue(labelContains(Self.sentText).waitForExistence(timeout: 15), "отправленное сообщение не появилось")
        screenshot("chat-sent")
    }

    func test21_BackButton() {
        openPeerChat()
        back()
        assertOnChatList("назад")
    }

    func test22_BackViaTabBar() {
        // Меню в чате больше нет (27.11): выход из чата — «Назад», после этого меню снова видно.
        openPeerChat()
        XCTAssertFalse(tabBarVisible, "в чате видно нижнее меню")
        back(); sleep(2)
        assertOnChatList("«Назад» из чата")
        XCTAssertTrue(tabBarVisible, "в списке чатов нет нижнего меню")
    }

    func test23_SwipeBack() {
        openPeerChat()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
        sleep(2)
        assertOnChatList("свайп назад")
    }

    func test24_AttachmentMenuRussian() {
        openPeerChat()
        let attach = app.buttons["l2.chat.attach"].firstMatch
        wait(attach, "кнопка вложения").tap()
        sleep(1)
        for t in ["Фото или видео", "Файл", "Отмена"] {
            XCTAssertTrue(app.buttons[t].firstMatch.waitForExistence(timeout: 5), "в меню вложений нет «\(t)»")
        }
        XCTAssertTrue(labelContains("Вложение").exists, "нет заголовка «Вложение»")
        XCTAssertFalse(app.buttons["Image / Video"].exists || app.buttons["Cancel"].exists, "в меню вложений английский текст")
        screenshot("attach-menu")
        app.buttons["Отмена"].firstMatch.tap()
    }

    func test25_KeyboardDoesNotCoverInput() {
        openPeerChat()
        let input = chatInput()
        input.tap()
        dismissKeyboardTips()
        let kb = app.keyboards.firstMatch
        wait(kb, "клавиатура", timeout: 8)
        sleep(1)
        XCTAssertLessThanOrEqual(input.frame.maxY, kb.frame.minY + 2, "клавиатура перекрывает поле ввода")
        XCTAssertTrue(input.isHittable, "поле ввода недоступно при открытой клавиатуре")
        screenshot("chat-keyboard")
    }

    func test26_RotationNoCrash() {
        openPeerChat()
        for o in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = o
            sleep(2)
            XCTAssertEqual(app.state, .runningForeground, "вылет при повороте")
            XCTAssertTrue(chatInput().exists, "после поворота пропало поле ввода")
        }
        screenshot("rotated")
        back()
        XCUIDevice.shared.orientation = .landscapeLeft; sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "вылет при повороте списка чатов")
        XCUIDevice.shared.orientation = .portrait; sleep(1)
    }

    // MARK: - 7. Жалоба и блокировка

    func test27_ReportMessage() {
        openPeerChat()
        let msg = wait(labelContains("История 2"), "сообщение собеседника")
        msg.press(forDuration: 1.2)
        sleep(1)
        screenshot("message-menu")
        let report = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Пожаловаться'")).firstMatch
        wait(report, "пункт «Пожаловаться»").tap()
        wait(app.buttons["Спам"].firstMatch, "причины жалобы").tap()
        wait(app.alerts.buttons["Отправить"].firstMatch, "отправка жалобы").tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "вылет при жалобе")
        screenshot("report-sent")
    }

    func test28_BlockAndUnblockUser() {
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        tab("l2.tab.contacts").tap(); sleep(2)
        wait(labelContains(peerName), "собеседник в контактах").tap(); sleep(2)
        let block = any("l2.contact.block")
        tapVisible(block, "кнопка «Заблокировать»")
        wait(dialogButton("Заблокировать"), "подтверждение блокировки").tap(); sleep(2)
        screenshot("blocked")
        // Разблокировать обратно, чтобы переписка продолжала работать.
        tapVisible(any("l2.contact.block"), "кнопка «Разблокировать»")
        wait(dialogButton("Разблокировать"), "подтверждение разблокировки").tap(); sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "вылет при блокировке")
        screenshot("unblocked")
    }

    // MARK: - 7б. Как в Telegram: меню, реакции, ответ, шапка, единый фон

    private func longPressMessage(_ text: String) {
        let m = wait(labelContains(text), "сообщение «\(text)»")
        m.press(forDuration: 1.0)
        wait(any("l2.menu"), "меню сообщения", timeout: 5)
        sleep(1)
    }

    private func closeMenu() {
        if any("l2.menu").exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap(); sleep(1) }
    }

    func test30_ChatHeaderBackAvatarNameCall() {
        openPeerChat()
        let nav = app.navigationBars.firstMatch
        XCTAssertTrue(nav.exists && nav.isHittable, "в чате нет шапки")
        XCTAssertTrue(nav.buttons.element(boundBy: 0).isHittable, "в шапке нет «Назад»")
        XCTAssertTrue(labelContains(peerName).exists, "в шапке нет имени собеседника")
        XCTAssertTrue(app.buttons["l2.chat.call"].firstMatch.exists || nav.buttons["Позвонить"].exists, "в шапке нет кнопки звонка")
        XCTAssertTrue(tabBarVisible, "в чате нет нижнего меню")
        XCTAssertTrue(labelContains("История").exists, "экран чата пустой — нет сообщений из истории")
        screenshot("chat-header")
    }

    func test31_MessageMenuRussianAndOrder() {
        openPeerChat()
        longPressMessage("История ответ")       // своё сообщение: есть «Изменить»
        screenshot("menu-own")
        for e in ["👍", "🤝", "🔥", "✅", "❤️", "👏", "😂", "🙏"] {
            XCTAssertTrue(any("l2.react." + e).exists, "в меню нет реакции \(e)")
        }
        var lastY: CGFloat = -1
        for (id, title) in [("reply", "Ответить"), ("copy", "Копировать"), ("forward", "Переслать"), ("edit", "Изменить"), ("delete", "Удалить у меня")] {
            let b = any("l2.menu." + id)
            XCTAssertTrue(b.exists, "в меню нет «\(title)»")
            XCTAssertEqual(b.label, title, "пункт меню не по-русски")
            XCTAssertGreaterThan(b.frame.minY, lastY, "порядок пунктов меню нарушен на «\(title)»")
            lastY = b.frame.minY
        }
        XCTAssertFalse(app.buttons["Reply"].exists || app.buttons["Copy"].exists, "в меню английский текст")
        closeMenu()
        longPressMessage("История 1")            // чужое: есть «Пожаловаться»
        XCTAssertTrue(any("l2.menu.report").exists, "в меню чужого сообщения нет «Пожаловаться»")
        screenshot("menu-peer")
        closeMenu()
    }

    func test32_ReactionAddAndRemove() {
        openPeerChat()
        longPressMessage("История 1")
        any("l2.react.🔥").tap()
        let chip = any("l2.reaction.🔥")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "реакция не появилась под сообщением")
        XCTAssertTrue(chip.label.contains("моя"), "своя реакция не подсвечена")
        screenshot("reaction-on")
        // Повторное нажатие на пилюлю снимает реакцию.
        chip.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: chip)
        waitForExpectations(timeout: 15)
        screenshot("reaction-off")
    }

    func test32b_ReactionPlusAndFullList() {
        openPeerChat()
        longPressMessage("История 2")
        wait(any("l2.react.more"), "кнопка «+»").tap()
        sleep(1)
        for e in ["👎", "❌", "💯", "🚀", "🎉", "📌"] {
            XCTAssertTrue(any("l2.react." + e).exists, "во втором ряду нет \(e)")
        }
        screenshot("reactions-more")
        wait(any("l2.react.all"), "кнопка «Все эмодзи»").tap()
        let search = wait(app.searchFields.firstMatch, "поиск эмодзи")
        search.tap()
        search.typeText("ракета")
        sleep(1)
        wait(any("l2.emoji.🚀"), "эмодзи 🚀 в поиске").tap()
        let chip = any("l2.reaction.🚀")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "реакция из полного списка не появилась")
        screenshot("reaction-from-list")
        chip.tap()   // снять
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: chip)
        waitForExpectations(timeout: 15)
    }

    func test32c_PinAndUnpin() {
        openPeerChat()
        longPressMessage("История 1")
        wait(any("l2.menu.pin"), "пункт «Закрепить»").tap()
        let counter = any("l2.pinned.counter")
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "плашка закреплённого не появилась")
        XCTAssertTrue(counter.label.contains("Закреплённое"), "на плашке нет «Закреплённое»")
        screenshot("pinned")
        wait(any("l2.pinned.unpin"), "крестик «Открепить»").tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: counter)
        waitForExpectations(timeout: 15)
        screenshot("unpinned")
    }

    func test33_ReplyViaMenu() {
        openPeerChat()
        longPressMessage("История 3")
        any("l2.menu.reply").tap()
        sleep(1)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'История 3'")).count, 2,
                                    "над полем ввода нет цитаты")
        screenshot("reply-preview")
        let text = "Ответ на цитату " + String(Int(Date().timeIntervalSince1970) % 100000)
        sendMessage(text)
        XCTAssertTrue(labelContains(text).waitForExistence(timeout: 15), "ответ не появился")
        screenshot("reply-sent")
        back()
        assertOnChatList("назад после ответа")
    }

    func test34_SwipeToReply() {
        openPeerChat()
        let m = wait(labelContains("История 2"), "сообщение «История 2»")
        let from = m.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 160, dy: 0)))
        sleep(1)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'История 2'")).count, 2,
                                    "свайп вправо не открыл ответ")
        screenshot("swipe-reply")
    }

    /// Цвет точки скриншота (в точках экрана).
    private func rgb(_ img: UIImage, _ p: CGPoint) -> [Int] {
        guard let cg = img.cgImage else { return [0, 0, 0] }
        let sx = CGFloat(cg.width) / img.size.width, sy = CGFloat(cg.height) / img.size.height
        let x = min(cg.width - 1, max(0, Int(p.x * sx))), y = min(cg.height - 1, max(0, Int(p.y * sy)))
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height - 1 - y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        return [Int(px[0]), Int(px[1]), Int(px[2])]
    }

    func test35_ChatBackgroundUniform() {
        openPeerChat()
        if app.keyboards.firstMatch.exists { app.swipeDown(); sleep(1) }
        let input = chatInput()
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = "background-check"; a.lifetime = .keepAlways; add(a)
        let img = shot.image
        let x: CGFloat = 4
        let ref = rgb(img, CGPoint(x: x, y: input.frame.minY - 60))          // фон ленты сообщений
        let probes: [(String, CGFloat)] = [("рядом с полем «Сообщение»", input.frame.midY),
                                           ("под полем «Сообщение»", input.frame.maxY + 6)]
        for (name, y) in probes {
            let c = rgb(img, CGPoint(x: x, y: y))
            let d = zip(ref, c).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThanOrEqual(d, 14, "фон \(name) отличается от фона чата: \(c) vs \(ref) — серая полоса")
        }
    }

    // MARK: - 7в. Удалённые настройки: старый / пустой / битый / новый конфиг

    /// Запуск с подменённым конфигом (приложение не ходит в сеть за конфигом и не трогает кэш).
    private func openPeerChat(config: String) {
        app.launchEnvironment["L2_CONFIG_OVERRIDE"] = config
        openPeerChat()
    }

    private func assertDefaultTabs() {
        for id in ["chats", "calls", "contacts", "settings"] {
            XCTAssertTrue(tab("l2.tab." + id).exists, "нет вкладки \(id)")
        }
    }

    func test36_EmptyConfig() {
        openPeerChat(config: "{}")
        assertDefaultTabs()
        XCTAssertTrue(labelContains("История").exists, "с пустым конфигом не видна история")
        longPressMessage("История 1")
        XCTAssertTrue(any("l2.react.👍").exists, "с пустым конфигом нет встроенных реакций")
        XCTAssertTrue(any("l2.menu.reply").exists, "с пустым конфигом нет «Ответить»")
        closeMenu()
    }

    func test37_BrokenConfig() {
        openPeerChat(config: "{ \"schema\": 1, \"tabs\": [ это не JSON")
        assertDefaultTabs()
        XCTAssertTrue(app.buttons["l2.chat.attach"].firstMatch.exists, "с битым конфигом пропали вложения")
        sendMessage("Битый конфиг " + String(Int(Date().timeIntervalSince1970) % 100000))
        XCTAssertEqual(app.state, .runningForeground, "вылет с битым конфигом")
    }

    func test38_OldConfig() {
        // Формат сборок 1.2.0 (9–11): без tabs/menus/reactions.primary.
        let old = """
        {"schema":1,"version":3,"colors":{"accent":"#7EE0C3","background":"#0A0E1B"},"texts":{},
         "features":{"reactions":true,"videoCalls":true},"reactions":{"emoji":["❤️","👍"]},"banner":{"enabled":false}}
        """
        openPeerChat(config: old)
        assertDefaultTabs()
        longPressMessage("История 1")
        XCTAssertTrue(any("l2.react.❤️").exists && any("l2.react.👍").exists, "старый набор реакций не применился")
        XCTAssertFalse(any("l2.react.🤝").exists, "старый конфиг: показан встроенный ряд вместо заданного")
        closeMenu()
    }

    func test39_CustomConfigAppliedLive() {
        let cfg = """
        {"schema":1,"tabs":[{"id":"chats","title":"Беседы","visible":true},{"id":"calls","visible":false},
          {"id":"contacts","visible":true},{"id":"settings","visible":true}],
         "features":{"reactions":false,"attachments":false,"pins":false,"forward":false},
         "menus":{"message":["copy","reply","report"]}}
        """
        openPeerChat(config: cfg)
        XCTAssertFalse(tab("l2.tab.calls").exists, "скрытая вкладка «Звонки» видна")
        XCTAssertEqual(tab("l2.tab.chats").label, "Беседы", "название вкладки не из конфига")
        let attach = app.buttons["l2.chat.attach"].firstMatch
        XCTAssertFalse(attach.exists && attach.isHittable, "вложения не выключились")
        longPressMessage("История 1")
        XCTAssertFalse(any("l2.menu.reactions").exists, "реакции не выключились")
        XCTAssertFalse(any("l2.menu.forward").exists, "«Переслать» не выключилось")
        XCTAssertFalse(any("l2.menu.pin").exists, "«Закрепить» не выключилось")
        let copy = any("l2.menu.copy"), reply = any("l2.menu.reply")
        XCTAssertTrue(copy.exists && reply.exists, "нет пунктов из menus.message")
        XCTAssertLessThan(copy.frame.minY, reply.frame.minY, "порядок меню не из конфига")
        screenshot("custom-config")
        closeMenu()
    }

    func test40_FutureSchemaIgnored() {
        openPeerChat(config: "{\"schema\": 2, \"tabs\": [{\"id\": \"chats\"}, {\"id\": \"settings\"}]}")
        assertDefaultTabs()   // конфиг новой схемы этой версией не применяется
    }

    // MARK: - 7г. Звонок iOS → веб (веб-собеседник ci/web-tests/call-peer.mjs принимает в браузере)

    func test00_CallToWebPeer() throws {
        guard env["L2_WEB_PEER"] == "1" else { throw XCTSkip("веб-собеседник не запущен (L2_WEB_PEER != 1)") }
        openPeerChat()
        let call = app.buttons["l2.chat.call"].firstMatch.exists ? app.buttons["l2.chat.call"].firstMatch : app.navigationBars.buttons["Позвонить"].firstMatch
        wait(call, "кнопка звонка в шапке чата").tap()
        let audio = app.buttons["Только звук"].firstMatch
        if audio.waitForExistence(timeout: 2) { audio.tap() }   // старое меню выбора; теперь 📞 звонит сразу
        dismissSpringboardAlerts()   // разрешение на микрофон
        let allowMic = any("l2.call.micAllow")   // свой экран «Разрешить микрофон» (доступ ещё не спрашивали)
        if allowMic.waitForExistence(timeout: 4) { allowMic.tap(); sleep(1); dismissSpringboardAlerts() }
        let state = any("l2.call.state")
        wait(state, "экран звонка", timeout: 20)
        screenshot("call-dialing")
        let connected = NSPredicate(format: "label BEGINSWITH 'Идёт звонок'")
        expectation(for: connected, evaluatedWith: state)
        waitForExpectations(timeout: 90)
        sleep(5)
        screenshot("call-connected")
        XCTAssertTrue(any("l2.call.hangup").exists, "нет кнопки «Положить трубку»")
        XCTAssertTrue(any("l2.call.mic").exists, "нет кнопки микрофона")
        any("l2.call.mic").tap(); sleep(1); any("l2.call.mic").tap()
        any("l2.call.hangup").tap()
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "вылет после звонка")
        screenshot("call-ended")
    }

    // MARK: - 8. Обход всех экранов без вылетов

    func test29_AllScreensNoCrash() {
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))
        for id in ["l2.tab.chats", "l2.tab.calls", "l2.tab.contacts", "l2.tab.settings"] {
            tab(id).tap(); sleep(1)
            XCUIDevice.shared.orientation = .landscapeLeft; sleep(1)
            XCUIDevice.shared.orientation = .portrait; sleep(1)
            XCTAssertEqual(app.state, .runningForeground, "вылет на вкладке \(id)")
        }
        tab("l2.tab.chats").tap(); sleep(1)
        app.buttons["Новый чат"].firstMatch.tap(); sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "вылет на «Новый чат»")
        back()
        app.terminate()
        launch()
        wait(app.staticTexts["Введите PIN-код"], "PIN после перезапуска")
        enterPin()
        wait(tab("l2.tab.chats"), "Чаты после перезапуска")
        screenshot("relaunch-ok")
    }

    // MARK: - 9. Стабильность: быстрое переключение вкладок во время загрузки (вылет 5a)

    func testS1_TabSwitchStress() {
        ensureSomeUser()
        // Перезапуск: подключение, вход и загрузка чатов/контактов/конфига идут параллельно с переключениями.
        app.terminate()
        launch()
        if app.staticTexts["Введите PIN-код"].waitForExistence(timeout: 15) { enterPin() }
        let ids = ["l2.tab.chats", "l2.tab.calls", "l2.tab.contacts", "l2.tab.settings"]
        wait(tab(ids[0]), "вкладки сразу после входа", timeout: 30)
        let tabs = ids.map { tab($0) }
        var order: [Int] = []
        for i in 0..<60 {
            // Все вкладки по кругу, вперемешку с повторным нажатием той же вкладки и «назад» через одну.
            order.append(i % 7 == 6 ? (order.last ?? 0) : (i % 2 == 0 ? (i / 2) % 4 : (3 - (i / 2) % 4)))
        }
        for (n, i) in order.enumerated() {
            let t = tabs[i]
            if t.exists && t.isHittable { t.tap() }
            if n % 10 == 9 {
                XCTAssertEqual(app.state, .runningForeground, "вылет после \(n + 1) переключений вкладок")
                if app.state != .runningForeground { return }
            }
        }
        XCTAssertEqual(app.state, .runningForeground, "вылет при быстром переключении вкладок")
        screenshot("after-60-switches")
        // Вкладки отвечают: каждая открывается и показывает своё содержимое.
        tabs[1].tap()
        XCTAssertTrue(labelContains("Звонки").waitForExistence(timeout: 10), "вкладка «Звонки» не отвечает")
        tabs[2].tap()
        wait(app.buttons["Добавить контакт"].firstMatch, "вкладка «Контакты» отвечает", timeout: 10)
        tabs[3].tap()
        wait(app.staticTexts["Внешний вид"].firstMatch, "вкладка «Настройки» отвечает", timeout: 10)
        tabs[0].tap()
        wait(app.buttons["Новый чат"].firstMatch, "вкладка «Чаты» отвечает", timeout: 10)
        XCTAssertTrue(tabBarVisible, "нет нижнего меню после стресс-теста")
        XCTAssertEqual(app.state, .runningForeground, "вылет после проверки вкладок")
        screenshot("tabs-responsive")
    }
}
