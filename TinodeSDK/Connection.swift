//
//  Connection.swift
//  TinodeSDK
//
//  Copyright © 2019-2022 Tinode LLC. All rights reserved.
//

import Foundation

public class Connection: WebSocketConnectionDelegate {
    private class ExpBackoffSteps {
        // LINIA2 (сборка 1011, цикл переподключения): паузы 1 → 2 → 4 → 8 → 16 → 30 с (+ до 10 % разброса),
        // дальше — каждые 30 с. Мгновенная попытка — только при смене сети и возврате в приложение (reset).
        private let kStepsMs = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]
        private var attempt: Int = 0

        func getNextDelay() -> Int {
            let base = kStepsMs[min(attempt, kStepsMs.count - 1)]
            attempt += 1
            return base + Int(arc4random_uniform(UInt32(base / 10)))
        }
        func reset() {
            attempt = 0
        }
    }

    // Connection timeout in seconds.
    fileprivate let kConnectionTimeout: TimeInterval = 3.0

    var isConnected: Bool {
        guard let conn = webSocketConnection else { return false }
        return conn.state == .open
    }

    var isWaitingToConnect: Bool {
        guard let conn = webSocketConnection else { return false }
        return conn.state == .connecting
    }

    /// LINIA2: подключение идёт меньше 10 с — не перебивать его новым (новое закрывало начатое).
    var isFreshlyConnecting: Bool {
        guard let conn = webSocketConnection, conn.state == .connecting, let t = conn.connectingSince else { return false }
        return Date().timeIntervalSince(t) < 10
    }

    private var webSocketConnection: WebSocket?
    private var connectionListener: ConnectionListener?
    private var endpointComponenets: URLComponents
    private var apiKey: String
    private var useTLS = false
    private var connectQueue = DispatchQueue(label: "co.tinode.connection")
    /// LINIA2 (только автотесты, -l2-uitest): до этого момента подключение к серверу запрещено — эмуляция обрыва сети.
    private var linia2BlockedUntilValue: Date?
    private let linia2BlockLock = NSLock()
    var linia2BlockedUntil: Date? {
        get { linia2BlockLock.lock(); defer { linia2BlockLock.unlock() }; return linia2BlockedUntilValue }
        set { linia2BlockLock.lock(); linia2BlockedUntilValue = newValue; linia2BlockLock.unlock() }
    }
    /// LINIA2 (только автотесты): «сервер недоступен» с момента запуска — до этого времени подключение не идёт.
    public static var linia2StartupBlockedUntil: Date?
    /// LINIA2: можно ли переподключаться автоматически (приложение на экране или идёт звонок / VoIP).
    /// Нет — попытка откладывается до linia2ResumeNow() (didBecomeActive / смена сети).
    public static var linia2ReconnectAllowed: (() -> Bool)?
    /// LINIA2: не чаще одной попытки подключения в секунду (защита от любых циклов).
    private static let kMinAttemptInterval: TimeInterval = 1.0
    private let attemptLock = NSLock()
    private var lastAttemptAt = Date.distantPast
    private var deferredWhileInactive = false
    /// Растёт при disconnect(): отложенная ограничителем попытка после отключения не выполняется.
    private var closeGeneration = 0
    private var autoreconnect: Bool = false
    private var reconnecting: Bool = false
    private var backoffSteps = ExpBackoffSteps()
    private var reconnectClosure: DispatchWorkItem?
    // Opaque parameter passed to onConnect. Used once then discarded.
    private var param: Any?

    init(open url: URL, with apiKey: String, notify listener: ConnectionListener?) {
        self.apiKey = apiKey
        // TODO: apply necessary URL modifications.
        self.endpointComponenets = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        self.connectionListener = listener
        if let scheme = endpointComponenets.scheme, scheme == "wss" || scheme == "https" {
            endpointComponenets.scheme = "wss"
            useTLS = true
        } else {
            endpointComponenets.scheme = "ws"
        }
        if endpointComponenets.port == nil {
            endpointComponenets.port = useTLS ? 443 : 80
        }
        self.webSocketConnection = WebSocket(timeout: kConnectionTimeout, delegate: self)
        maybeInitReconnectClosure()
    }

    // LINIA2 (большой аккаунт: сигналы звонка доходили с задержкой 3–7 с): входящие сообщения разбираются
    // в отдельной последовательной очереди (порядок сохраняется), чтобы чтение сокета не ждало разбора
    // (запись в базу по сотням pres/meta/data). Сигналы звонка (offer / answer / ice-candidate / hang-up)
    // обрабатываются сразу, без ожидания очереди. «accept» / «ringing» — по порядку (зависят от ответа
    // сервера с seq звонка, который может стоять в очереди).
    private let incomingQueue = DispatchQueue(label: "co.tinode.incoming", qos: .userInitiated)
    private let backlogLock = NSLock()
    private var backlog = 0
    private func enqueue(_ work: @escaping () -> Void) {
        backlogLock.lock(); backlog += 1; backlogLock.unlock()
        incomingQueue.async {
            work()
            self.backlogLock.lock(); self.backlog -= 1; self.backlogLock.unlock()
        }
    }
    /// Сколько входящих ждут разбора (для диагностики задержек).
    public var incomingBacklog: Int { backlogLock.lock(); defer { backlogLock.unlock() }; return backlog }

    static func isUrgentCallSignal(_ text: String) -> Bool {
        guard text.hasPrefix("{\"info\""), text.contains("\"what\":\"call\"") else { return false }
        return text.contains("\"event\":\"offer\"") || text.contains("\"event\":\"answer\"")
            || text.contains("\"event\":\"ice-candidate\"") || text.contains("\"event\":\"hang-up\"")
    }

    func onConnected(connection: WebSocket) {
        self.backoffSteps.reset()
        let r = self.reconnecting
        self.reconnecting = false
        let p = self.param
        self.param = nil
        enqueue { self.connectionListener?.onConnect(reconnecting: r, param: p) }
    }

    func onDisconnected(connection: WebSocket, isServerOriginated clean: Bool, closeCode: URLSessionWebSocketTask.CloseCode, reason: String) {
        enqueue { self.connectionListener?.onDisconnect(isServerOriginated: clean, code: closeCode, reason: reason) }
        // LINIA2: закрыли мы сами — переподключение решает тот, кто закрыл (не запускаем цикл).
        guard reason != Tinode.linia2ClientCancelReason else { return }
        guard !self.reconnecting else {
            return
        }
        self.reconnecting = self.autoreconnect
        if self.autoreconnect {
            self.connectWithBackoffAsync()
        }
    }

    func onError(connection: WebSocket, error: Error) {
        // LINIA2: обрыв сообщается один раз — через onDisconnected (раньше onError + onDisconnected давали
        // два handleDisconnect подряд: двойной сброс тем/обещаний и двойной счёт обрывов в Linia2Failover).
        Tinode.log.error("Connection error: %@", error.localizedDescription)
    }

    func onMessage(connection: WebSocket, text: String) {
        if Connection.isUrgentCallSignal(text) {
            // Сигналы звонка — между собой по порядку (все на очереди сокета), без ожидания разбора остального.
            self.connectionListener?.onMessage(with: text)
            return
        }
        let n = incomingBacklog
        if n > 0 && n % 200 == 0 { Tinode.log.info("Connection: %d incoming messages waiting", n) }
        enqueue { self.connectionListener?.onMessage(with: text) }
    }

    func onMessage(connection: WebSocket, data: Data) {
        // Unexpected data message.
    }

    private func maybeInitReconnectClosure() {
        if reconnectClosure?.isCancelled ?? true {
            reconnectClosure = DispatchWorkItem {
                if let allowed = Connection.linia2ReconnectAllowed, !allowed() {
                    // В фоне без звонка — ждём возврата в приложение (не жжём батарею и главный поток).
                    self.deferredWhileInactive = true
                    Tinode.linia2Event?("reconnect-deferred", [:])
                    return
                }
                self.connectSocket()
                if self.isConnected {
                    self.reconnecting = false
                    return
                }
                self.connectWithBackoffAsync()
            }
        }
    }

    private func createUrlRequest() throws -> URLRequest {
        var request = URLRequest(url: endpointComponenets.url!)
        request.addValue(apiKey, forHTTPHeaderField: "X-Tinode-APIKey")
        return request
    }

    private func openConnection(with urlRequest: URLRequest) {
        self.webSocketConnection?.connect(req: urlRequest)
    }
    private func connectSocket() {
        guard !isConnected else { return }
        // LINIA2: идущее подключение не перебиваем (новое закрыло бы начатое).
        guard !isFreshlyConnecting else { return }
        if let until = linia2BlockedUntil, until > Date() { return }
        if let until = Connection.linia2StartupBlockedUntil, until > Date() { return }
        attemptLock.lock()
        let since = Date().timeIntervalSince(lastAttemptAt)
        if since < Connection.kMinAttemptInterval {
            let gen = closeGeneration
            attemptLock.unlock()
            connectQueue.asyncAfter(deadline: .now() + (Connection.kMinAttemptInterval - since)) { [weak self] in
                guard let self = self, self.closeGeneration == gen else { return }
                self.connectSocket()
            }
            return
        }
        lastAttemptAt = Date()
        attemptLock.unlock()
        let request = try! createUrlRequest()
        self.openConnection(with: request)
    }

    private func connectWithBackoffAsync() {
        let delay = Double(self.backoffSteps.getNextDelay()) / 1000
        maybeInitReconnectClosure()
        self.connectQueue.asyncAfter(deadline: .now() + delay, execute: reconnectClosure!)
    }

    @discardableResult
    func connect(reconnectAutomatically: Bool = true, withParam param: Any?) throws -> Bool {
        self.autoreconnect = reconnectAutomatically
        self.param = param
        if self.autoreconnect && self.reconnecting {
            // If we are trying to reconnect, do it now
            // (we simply reset the exp backoff steps).
            reconnectClosure!.cancel()
            backoffSteps.reset()
            // LINIA2: «сейчас» — значит сейчас (ограничитель 1 с в connectSocket), а не через первую паузу.
            deferredWhileInactive = false
            maybeInitReconnectClosure()
            connectQueue.async(execute: reconnectClosure!)
        } else {
            connectSocket()
        }
        return true
    }

    /// LINIA2: соединение заменяется другим (смена адреса) — его события больше никому не нужны.
    func linia2Detach() {
        connectionListener = nil
        disconnect()
    }

    func disconnect() {
        attemptLock.lock(); closeGeneration += 1; attemptLock.unlock()
        webSocketConnection?.close()
        if autoreconnect {
            autoreconnect = false
            reconnectClosure!.cancel()
        }
    }

    /// LINIA2 (автотесты): закрыть сокет, не выключая автопереподключение (как при пропаже сети).
    func linia2DropSocket() {
        webSocketConnection?.close(byUs: false)
    }

    func linia2Ping(timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        guard let ws = webSocketConnection else { done(false); return }
        ws.linia2Ping(timeout: timeout, done: done)
    }

    func send(payload data: Data) {
        webSocketConnection?.send(data: data)
    }

}

protocol ConnectionListener {
    func onConnect(reconnecting: Bool, param: Any?)
    func onMessage(with message: String)
    func onDisconnect(isServerOriginated: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String)
    func onError(error: Error)
}
