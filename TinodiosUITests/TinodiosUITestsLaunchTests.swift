//
//  TinodiosUITestsLaunchTests.swift
//  TinodiosUITests
//
//  Copyright © 2022 Tinode LLC. All rights reserved.
//

import XCTest

final class TinodiosUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        // Линия 2.0: запуск в каждой конфигурации (светлая/тёмная, ориентации) — без вылета.
        let app = XCUIApplication()
        app.launchArguments = ["-l2-uitest"]
        app.launch()
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "приложение не запустилось или упало при запуске")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
