//
//  Linia2DesignShots.swift
//  Линия 2.0: «фотограф» для дизайн-контроля — снимки всех основных экранов и состояний.
//
//  Каждый снимок — XCTAttachment (lifetime .keepAlways) с именем «design-<экран>-<состояние>».
//  В CI (uitest.yml, job «design», запуск вручную с design=true) гоняется на iPhone SE (3rd gen),
//  iPhone 16 и iPhone 16 Pro Max × светлая/тёмная тема × обычный/крупный шрифт; PNG выгружаются в артефакт
//  design-shots с именами <устройство>-<тема>-<шрифт>-<экран>-<состояние>.png.
//
//  Окружение (TEST_RUNNER_*): L2_LOGIN / L2_PASSWORD — пользователь A;
//  L2_D_NAME — собеседник с подготовленной перепиской («Дизайн CI»: длинная история, фото, голосовые,
//  кружок, ответ, реакции, закреплённое; метки «Метка: …» перед каждым видом);
//  L2_THEME = dark | light (аргумент запуска -l2-theme), L2_FONT = large — крупный шрифт
//  (-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL).
//  Тест не падает из-за отсутствующего экрана — снимает всё, что может (для дизайна важнее полнота).
//

import XCTest

final class Linia2DesignShots: Linia2CallTestBase {
    private var designPeer: String { env["L2_D_NAME"] ?? "Дизайн CI" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
        if let theme = env["L2_THEME"], theme == "dark" || theme == "light" {
            app.launchArguments += ["-l2-theme", theme]
        }
        if env["L2_FONT"] == "large" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
    }

    override class func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "l2.calltests.login")
    }

    /// Снимок «design-<экран>-<состояние>».
    private func shot(_ screen: String, _ state: String = "default") {
        sleep(1)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "design-\(screen)-\(state)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func labelContains(_ text: String) -> XCUIElement {
        // Текст пузыря (UITextView) виден тестам как value, а не label — ищем по обоим.
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
    }

    private func goBack() {
        if any("l2.chat.back").exists { any("l2.chat.back").tap(); sleep(1); return }
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists { b.tap() }
        sleep(1)
    }

    /// Прокрутить ленту вверх, пока элемент не станет видимым (до N попыток).
    @discardableResult
    private func scrollTo(_ e: XCUIElement, attempts: Int = 12) -> Bool {
        let feed = app.collectionViews.firstMatch
        for _ in 0..<attempts {
            if e.exists && e.isHittable { return true }
            feed.exists ? feed.swipeDown() : app.swipeDown()
            usleep(400_000)
        }
        return e.exists && e.isHittable
    }

    func testF9_ScreensAllSizes() throws {
        ensureLoggedIn(requireEnv("L2_LOGIN"), requireEnv("L2_PASSWORD"))

        // Список чатов.
        tab("l2.tab.chats").tap(); sleep(2)
        shot("chats", "list")
        if app.tables.firstMatch.exists {
            app.tables.firstMatch.swipeUp(); shot("chats", "scrolled")
            app.tables.firstMatch.swipeDown(); sleep(1)
        }

        // Чат пустой — «Избранное» у свежего пользователя.
        if any("l2.chats.saved").waitForExistence(timeout: 5) {
            any("l2.chats.saved").tap()
            _ = app.textViews["l2.chat.input"].firstMatch.waitForExistence(timeout: 15)
            shot("chat", "empty")
            goBack()
        }

        // Чат с подготовленной перепиской.
        openChat(with: designPeer)
        shot("chat", "latest")
        app.textViews["l2.chat.input"].firstMatch.tap()
        for t in ["Continue", "Продолжить"] where app.buttons[t].firstMatch.waitForExistence(timeout: 1) { app.buttons[t].firstMatch.tap() }
        shot("chat", "keyboard")
        // Спрятать клавиатуру: лента с keyboardDismissMode = .interactive — протянуть палец сквозь клавиатуру вниз.
        let feedC = app.collectionViews.firstMatch
        feedC.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        sleep(1)
        if app.keyboards.firstMatch.exists { app.collectionViews.firstMatch.swipeDown(velocity: .fast); sleep(1) }

        let marks: [(String, String)] = [("Метка: реакции", "reactions"), ("Метка: ответ", "reply"), ("Метка: кружок", "round"),
                                         ("Метка: голосовое", "voice"), ("Метка: фото", "photo"),
                                         ("Метка: время", "time"), ("Метка: звонки", "time-calls")]
        for (mark, state) in marks {
            if scrollTo(labelContains(mark)) {
                // Метка — над содержимым: сдвинуть, чтобы содержимое было в кадре.
                // Метку — к верху ленты (под шапку), чтобы содержимое под ней целиком было в кадре.
                let m = labelContains(mark)
                if m.exists {
                    m.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
                } else {
                    app.collectionViews.firstMatch.swipeUp(velocity: .slow)
                }
                sleep(1)
                if !labelContains(mark).isHittable { _ = scrollTo(labelContains(mark), attempts: 3) }
                shot("chat", state)
            } else {
                shot("chat", state + "-notfound")
            }
        }
        // Длинная переписка (начало) и закреплённое.
        for _ in 0..<6 { app.collectionViews.firstMatch.swipeDown(); usleep(300_000) }
        shot("chat", "long-history")
        shot("chat", "pinned")

        // Меню сообщения (долгое нажатие).
        let msg = app.collectionViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Сообщение'")).firstMatch
        let target = msg.exists ? msg : app.collectionViews.firstMatch.staticTexts.firstMatch
        if target.exists {
            target.press(forDuration: 1.0)
            if any("l2.menu").waitForExistence(timeout: 5) {
                shot("chat", "menu")
                if any("l2.react.more").exists { any("l2.react.more").tap(); shot("chat", "menu-more") }
                if any("l2.menu.backdrop").exists {
                    any("l2.menu.backdrop").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
                }
                sleep(1)
            }
        }

        // Поиск по чату.
        if any("l2.chat.search").exists {
            any("l2.chat.search").tap()
            if any("l2.search.field").waitForExistence(timeout: 5) {
                shot("chat", "search")
                any("l2.search.field").typeText("Сообщение")
                sleep(2)
                shot("chat", "search-results")
                if any("l2.search.close").exists { any("l2.search.close").tap() }
            }
        }

        // Информация о чате (по нажатию на имя).
        if any("l2.chat.title").exists {
            any("l2.chat.title").tap(); sleep(2)
            shot("chatinfo", "default")
            if any("l2.topicinfo.more").exists {
                any("l2.topicinfo.more").tap(); sleep(1)
                shot("chatinfo", "actions")
                if app.sheets.buttons["Отмена"].firstMatch.exists { app.sheets.buttons["Отмена"].firstMatch.tap() }
            }
            goBack()
        }

        // Звонок: исходящий аудио и видео (собеседник не отвечает — экран «Вызов…»).
        for (video, state) in [(false, "outgoing-audio"), (true, "outgoing-video")] {
            let b = app.buttons[video ? "l2.chat.video" : "l2.chat.call"].firstMatch
            guard b.waitForExistence(timeout: 5) else { continue }
            b.tap()
            dismissSpringboardAlerts()
            if any("l2.call.micAllow").waitForExistence(timeout: 3) { any("l2.call.micAllow").tap(); sleep(1); dismissSpringboardAlerts() }
            if any("l2.call.state").waitForExistence(timeout: 20) {
                sleep(2)
                shot("call", state)
                if any("l2.call.hangup").exists { any("l2.call.hangup").tap() }
                let end = Date().addingTimeInterval(15)
                while any("l2.call.hangup").exists && Date() < end { usleep(500_000) }
                sleep(2)
            }
        }
        goBack()

        // Вкладки.
        for (id, name) in [("l2.tab.contacts", "contacts"), ("l2.tab.calls", "calls"), ("l2.tab.settings", "settings")] {
            let t = tab(id)
            guard t.waitForExistence(timeout: 5) else { continue }
            t.tap(); sleep(2)
            shot(name, "default")
            app.swipeUp(); shot(name, "scrolled")
            app.swipeDown(); sleep(1)
        }

        // Профиль.
        let profile = any("l2.settings.profile")
        if profile.waitForExistence(timeout: 5) {
            profile.tap(); sleep(2)
            shot("profile", "default")
            goBack()
        }

        // Заставка запуска: бегущий импульс по кардиограмме, кадр из середины цикла
        // (-l2-splash-hold: держится 6 с, анимация остановлена на 0,6 с из 1,2 с).
        app.terminate()
        app.launchArguments += ["-l2-splash-hold"]
        app.launch()
        if any("l2.splash").waitForExistence(timeout: 5) {
            usleep(500_000)
            let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            a.name = "design-launch-pulse"
            a.lifetime = .keepAlways
            add(a)
        } else {
            shot("launch", "pulse-notfound")
        }
        app.launchArguments.removeAll { $0 == "-l2-splash-hold" }

        // PIN при повторном запуске.
        app.terminate()
        app.launch()
        dismissSpringboardAlerts()
        if app.staticTexts["Введите PIN-код"].waitForExistence(timeout: 15) {
            shot("pin", "enter")
            enterPin()
            _ = tab("l2.tab.chats").waitForExistence(timeout: 20)
        }

        // Вход и регистрация — после выхода.
        if tab("l2.tab.settings").waitForExistence(timeout: 10) { logout() }
        if app.buttons["l2.welcome.login"].waitForExistence(timeout: 15) {
            shot("welcome", "default")
            app.buttons["l2.welcome.login"].tap(); sleep(2)
            shot("login", "default")
            if app.textFields["l2.login.login"].exists {
                app.textFields["l2.login.login"].tap()
                for t in ["Continue", "Продолжить"] where app.buttons[t].firstMatch.waitForExistence(timeout: 1) { app.buttons[t].firstMatch.tap() }
                shot("login", "keyboard")
            }
            goBack()
            if app.buttons["l2.welcome.code"].waitForExistence(timeout: 5) {
                app.buttons["l2.welcome.code"].tap(); sleep(2)
                shot("register", "code")
                goBack()
            }
        }
    }
}
