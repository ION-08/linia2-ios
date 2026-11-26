//
//  Linia2SDKTests.swift
//  Линия 2.0: юнит-тесты SDK (вход, права доступа, диапазоны сообщений, текст сообщений).
//

import XCTest
@testable import TinodeSDK

final class Linia2SDKTests: XCTestCase {

    // MARK: Вход по логину и паролю

    func testBasicTokenRoundTrip() throws {
        let token = try AuthScheme.encodeBasicToken(uname: "appreview", password: "Пароль-123")
        XCTAssertEqual(try AuthScheme.decodeBasicToken(token: token), ["appreview", "Пароль-123"])
    }

    func testBasicTokenRejectsColonInLogin() {
        XCTAssertThrowsError(try AuthScheme.encodeBasicToken(uname: "a:b", password: "x"))
    }

    func testBasicTokenRejectsGarbage() {
        XCTAssertThrowsError(try AuthScheme.decodeBasicToken(token: "не base64"))
    }

    // MARK: Права доступа к чату

    func testAccessModeFullRights() {
        let a = AcsHelper(str: "JRWPASDO")
        XCTAssertTrue(a.isJoiner)
        XCTAssertTrue(a.isReader)
        XCTAssertTrue(a.isWriter)
        XCTAssertTrue(a.isOwner)
    }

    func testAccessModeReadOnly() {
        let a = AcsHelper(str: "JR")
        XCTAssertTrue(a.isReader)
        XCTAssertFalse(a.isWriter)
        XCTAssertFalse(a.isOwner)
    }

    func testAccessModeNoneAndEmpty() {
        XCTAssertFalse(AcsHelper(str: "N").isReader)
        XCTAssertFalse(AcsHelper(str: "").isWriter)
        XCTAssertFalse(AcsHelper(str: nil).isJoiner)
    }

    // MARK: Диапазоны сообщений (удаление/история)

    func testMsgRangeCollapseOverlapping() {
        let r = MsgRange.collapse([MsgRange(low: 1, hi: 5), MsgRange(low: 3, hi: 8), MsgRange(low: 10, hi: 12)])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].lower, 1)
        XCTAssertEqual(r[0].upper, 8)
        XCTAssertEqual(r[1].lower, 10)
    }

    func testMsgRangeSingleId() {
        let r = MsgRange(id: 7)
        XCTAssertEqual(r.lower, 7)
        XCTAssertEqual(r.upper, 8)
    }

    // MARK: Текст сообщений

    func testDraftyPlainTextRussian() {
        let d = Drafty(plainText: "Привет! Проверка связи")
        XCTAssertEqual(d.txt, "Привет! Проверка связи")
        XCTAssertTrue(d.isPlain)
    }

    func testDraftyParseBoldKeepsText() {
        let d = Drafty.parse(content: "Это *важно*")
        XCTAssertEqual(d.txt, "Это важно")
        XCTAssertFalse(d.isPlain)
    }

    func testDraftyMultilineParse() {
        // Перенос строки хранится как пробел + стиль BR.
        let d = Drafty.parse(content: "Строка 1\nСтрока 2")
        XCTAssertEqual(d.txt, "Строка 1 Строка 2")
        XCTAssertFalse(d.isPlain)
    }
}
