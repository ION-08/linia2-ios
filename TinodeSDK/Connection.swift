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

    // MARK: LINIA2 (сборка 1019): маршруты (транспорт + адрес) и автоматическое переключение

    /// Только автотесты (-l2-uitest -l2-block-ws): WebSocket «заблокирован» — подключение висит, как под ТСПУ.
    public static var linia2TestBlockWS = false
    /// Переход на следующий маршрут, если подключение не открылось за столько секунд (features.transportSwitchSeconds).
    public static var linia2SwitchTimeout: TimeInterval = 5
    /// Отправили запрос (с id) и ни одного сообщения от сервера столько секунд — канал «завис» (ТСПУ пропускает
    /// первые пакеты и режет дальше): следующий маршрут. 0 — выключено (features.transportStallSeconds).
    public static var linia2StallTimeout: TimeInterval = 30

    private let routeLock = NSLock()
    /// Текущий транспорт (под routeLock). Отдельный объект на каждый тип; WebSocket — тот же, что и раньше.
    private var transportValue: Linia2Transport?
    private var webSocketConnection: Linia2Transport? {
        get { routeLock.lock(); defer { routeLock.unlock() }; return transportValue }
        set { routeLock.lock(); transportValue = newValue; routeLock.unlock() }
    }
    private var transports: [Linia2TransportKind: Linia2Transport] = [:]
    /// Маршруты по порядку. Один маршрут (по умолчанию / расширение уведомлений) — поведение как до 1019:
    /// без таймаута перехода и без проверки «зависания».
    private var routes: [Linia2Route] = []
    private var routeIndex = 0
    private var activeRoute: Linia2Route?
    private var attemptSeq = 0
    private var awaitingFirstMessage = false
    private var failedInCycle = 0
    private var lastSendWithReply = Date.distantPast
    private var lastReceive = Date.distantPast
    private var basePath = "/v0/channels"
    /// Маршрутов больше одного (пишется под routeLock вместе со списком).
    private var multiRouteValue = false
    private var multiRoute: Bool { multiRouteValue }
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

    init(open url: URL, with apiKey: String, notify listener: ConnectionListener?, routes: [Linia2Route] = []) {
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
        let ws = WebSocket(timeout: kConnectionTimeout, delegate: self)
        self.transports[.ws] = ws
        self.webSocketConnection = ws
        if !endpointComponenets.path.isEmpty { basePath = endpointComponenets.path }
        self.routes = routes
        self.multiRouteValue = routes.count > 1
        maybeInitReconnectClosure()
    }

    /// Транспорт нужного типа (создаётся один раз). Под routeLock.
    private func transportLocked(_ kind: Linia2TransportKind) -> Linia2Transport {
        if kind == .ws && Connection.linia2TestBlockWS {
            if let t = transports[.ws], t is Linia2BlackholeTransport { return t }
            let t = Linia2BlackholeTransport()
            transports[.ws] = t
            return t
        }
        if let t = transports[kind] { return t }
        let t: Linia2Transport
        switch kind {
        case .ws: t = WebSocket(timeout: kConnectionTimeout, delegate: self)
        case .lpH3: t = Linia2LongPoll(http3: true, delegate: self)
        case .lp: t = Linia2LongPoll(http3: false, delegate: self)
        }
        transports[kind] = t
        return t
    }

    /// Новый список маршрутов (изменились настройки). Живое соединение не трогаем — список для следующих подключений.
    func linia2SetRoutes(_ newRoutes: [Linia2Route]) {
        routeLock.lock()
        let cur = activeRoute ?? (routes.indices.contains(routeIndex) ? routes[routeIndex] : nil)
        routes = newRoutes
        multiRouteValue = newRoutes.count > 1
        if let c = cur, let i = newRoutes.firstIndex(of: c), transportValue?.state == .open || transportValue?.state == .connecting {
            routeIndex = i
        } else {
            routeIndex = 0
        }
        failedInCycle = 0
        routeLock.unlock()
    }

    /// Следующее подключение — с маршрута номер index (возврат на основной).
    func linia2SelectRoute(_ index: Int) {
        routeLock.lock()
        if routes.indices.contains(index) { routeIndex = index }
        failedInCycle = 0
        routeLock.unlock()
    }

    var linia2RouteStatus: Linia2RouteStatus? {
        routeLock.lock(); defer { routeLock.unlock() }
        let r: Linia2Route?
        if let a = activeRoute { r = a } else if routes.indices.contains(routeIndex) { r = routes[routeIndex] } else { r = nil }
        guard let route = r ?? endpointRoute else { return nil }
        let n = max(routes.count, 1)
        let idx = (routes.firstIndex(of: route) ?? 0) + 1
        return Linia2RouteStatus(route: route, netProtocol: transportValue?.linia2NetProtocol,
                                 connected: transportValue?.state == .open && !awaitingFirstMessage,
                                 index: idx, count: n, failedInCycle: failedInCycle)
    }

    private var endpointRoute: Linia2Route? {
        guard let h = endpointComponenets.host else { return nil }
        return Linia2Route(kind: .ws, host: h, port: endpointComponenets.port)
    }

    /// Маршрут не удался (ошибка до первого ответа, таймаут, «зависание»): следующий по кругу.
    /// true — пробовать следующий сразу; false — круг пройден, дальше — обычные паузы переподключения.
    private func noteRouteFailure(_ why: String) -> Bool {
        routeLock.lock()
        guard routes.count > 1 else { routeLock.unlock(); return false }
        let failed = activeRoute ?? routes[min(routeIndex, routes.count - 1)]
        routeIndex = Linia2TransportPlan.next(after: routes.firstIndex(of: failed) ?? routeIndex, count: routes.count)
        failedInCycle += 1
        let again = failedInCycle < routes.count
        if !again { failedInCycle = 0 }
        let next = routes[routeIndex]
        routeLock.unlock()
        Tinode.linia2Event?("route-fail", ["route": failed.id, "why": why, "next": next.id, "now": again ? 1 : 0])
        connectionListener?.onRouteChanged()
        return again
    }

    /// Бросить текущий маршрут: транспорт отцепляется (его события больше не приходят), ожидающим — обрыв,
    /// подключение по следующему маршруту.
    private func abandonRoute(_ why: String, wasOpen: Bool) {
        routeLock.lock()
        let old = transportValue
        transportValue = nil
        awaitingFirstMessage = false
        routeLock.unlock()
        let again = noteRouteFailure(why)
        old?.close(byUs: true)
        if wasOpen {
            enqueue { self.connectionListener?.onDisconnect(isServerOriginated: false, code: .abnormalClosure, reason: "route-\(why)") }
        }
        guard autoreconnect else { return }
        if again {
            connectQueue.async { self.connectSocket() }
        }
        if !reconnecting {
            reconnecting = true
            connectWithBackoffAsync()
        }
    }

    private func scheduleRouteChecks(attempt: Int) {
        guard multiRoute else { return }
        let timeout = max(1, Connection.linia2SwitchTimeout)
        connectQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            self.routeLock.lock()
            let stuck = self.attemptSeq == attempt && self.transportValue?.state == .connecting
            self.routeLock.unlock()
            if stuck { self.abandonRoute("timeout", wasOpen: false) }
        }
    }

    /// После открытия: первый ответ сервера за 2 × таймаут перехода; дальше — проверка «зависания» каждые 5 с.
    private func scheduleOpenChecks(attempt: Int) {
        guard multiRoute else { return }
        let timeout = max(2, Connection.linia2SwitchTimeout * 2)
        connectQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            self.routeLock.lock()
            let silent = self.attemptSeq == attempt && self.awaitingFirstMessage && self.transportValue?.state == .open
            self.routeLock.unlock()
            if silent { self.abandonRoute("no-reply", wasOpen: true) }
        }
        scheduleStallCheck(attempt: attempt)
    }

    private func scheduleStallCheck(attempt: Int) {
        connectQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            let stall = Connection.linia2StallTimeout
            self.routeLock.lock()
            let same = self.attemptSeq == attempt && self.transportValue?.state == .open && self.routes.count > 1
            let stuck = same && stall > 0 && self.lastSendWithReply > self.lastReceive
                && Date().timeIntervalSince(self.lastSendWithReply) > stall
            self.routeLock.unlock()
            guard same else { return }
            if stuck { self.abandonRoute("stall", wasOpen: true) } else { self.scheduleStallCheck(attempt: attempt) }
        }
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

    private func isCurrent(_ t: Linia2Transport) -> Bool {
        routeLock.lock(); defer { routeLock.unlock() }
        return t === transportValue
    }

    func onConnected(connection: Linia2Transport) {
        guard isCurrent(connection) else { return }
        routeLock.lock()
        let attempt = attemptSeq
        awaitingFirstMessage = multiRoute
        lastReceive = Date()
        lastSendWithReply = .distantPast
        routeLock.unlock()
        scheduleOpenChecks(attempt: attempt)
        self.backoffSteps.reset()
        let r = self.reconnecting
        self.reconnecting = false
        let p = self.param
        self.param = nil
        enqueue { self.connectionListener?.onConnect(reconnecting: r, param: p) }
    }

    func onDisconnected(connection: Linia2Transport, isServerOriginated clean: Bool, closeCode: URLSessionWebSocketTask.CloseCode, reason: String) {
        // LINIA2 (1019): события отцепленного транспорта (сменили маршрут) не трогают текущее соединение.
        guard isCurrent(connection) else { return }
        routeLock.lock()
        let neverAnswered = awaitingFirstMessage || activeRoute == nil
        awaitingFirstMessage = false
        activeRoute = nil
        routeLock.unlock()
        enqueue { self.connectionListener?.onDisconnect(isServerOriginated: clean, code: closeCode, reason: reason) }
        // LINIA2: закрыли мы сами — переподключение решает тот, кто закрыл (не запускаем цикл).
        guard reason != Tinode.linia2ClientCancelReason else { return }
        // Маршрут не дал ни одного ответа сервера — следующий маршрут сразу (без паузы), пока круг не пройден.
        if multiRoute && neverAnswered && autoreconnect {
            if noteRouteFailure("error") {
                connectQueue.async { self.connectSocket() }
            }
        }
        guard !self.reconnecting else {
            return
        }
        self.reconnecting = self.autoreconnect
        if self.autoreconnect {
            self.connectWithBackoffAsync()
        }
    }

    func onError(connection: Linia2Transport, error: Error) {
        // LINIA2: обрыв сообщается один раз — через onDisconnected (раньше onError + onDisconnected давали
        // два handleDisconnect подряд: двойной сброс тем/обещаний и двойной счёт обрывов в Linia2Failover).
        Tinode.log.error("Connection error: %@", error.localizedDescription)
    }

    func onMessage(connection: Linia2Transport, text: String) {
        guard isCurrent(connection) else { return }
        routeLock.lock()
        lastReceive = Date()
        var proven: Linia2Route?
        if awaitingFirstMessage || activeRoute == nil {
            awaitingFirstMessage = false
            failedInCycle = 0
            if routes.indices.contains(routeIndex) { activeRoute = routes[routeIndex] } else { activeRoute = endpointRoute }
            proven = activeRoute
        }
        let n = routes.count
        routeLock.unlock()
        if let r = proven {
            let proto = connection.linia2NetProtocol
            Tinode.linia2Event?("route-up", ["route": r.id, "proto": proto ?? "", "n": n])
            connectionListener?.onRouteUp(route: r, netProtocol: proto)
        }
        if Connection.isUrgentCallSignal(text) {
            // Сигналы звонка — между собой по порядку (все на очереди сокета), без ожидания разбора остального.
            self.connectionListener?.onMessage(with: text)
            return
        }
        let n = incomingBacklog
        if n > 0 && n % 200 == 0 { Tinode.log.info("Connection: %d incoming messages waiting", n) }
        enqueue { self.connectionListener?.onMessage(with: text) }
    }

    func onMessage(connection: Linia2Transport, data: Data) {
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

    /// LINIA2 (1019): транспорт и адрес текущего маршрута. Без списка маршрутов — WebSocket на адрес из Tinode (как раньше).
    private func openConnection() {
        routeLock.lock()
        var url = endpointComponenets.url!
        var kind = Linia2TransportKind.ws
        if !routes.isEmpty {
            if !routes.indices.contains(routeIndex) { routeIndex = 0 }
            let r = routes[routeIndex]
            if let u = r.url(path: basePath) { url = u; kind = r.kind }
        }
        let t = transportLocked(kind)
        let prev = transportValue
        transportValue = t
        attemptSeq += 1
        let attempt = attemptSeq
        awaitingFirstMessage = multiRoute
        activeRoute = nil
        let n = routes.count
        let idx = routeIndex
        routeLock.unlock()
        if let p = prev, p !== t { p.close(byUs: true) }
        if n > 1 { Tinode.linia2Event?("route-try", ["route": "\(kind.rawValue)://\(url.host ?? "")", "i": idx + 1, "n": n]) }
        t.connect(url: url, apiKey: apiKey)
        scheduleRouteChecks(attempt: attempt)
        if n > 1 { connectionListener?.onRouteChanged() }
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
        self.openConnection()
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
        webSocketConnection?.close(byUs: true)
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

    /// LINIA2 (1019): маршрут не работает, хотя транспорт открыт (например, вход не проходит) — следующий маршрут.
    func linia2AbandonRoute(_ why: String) {
        guard multiRoute, let t = webSocketConnection, t.state == .open || t.state == .connecting else { return }
        connectQueue.async { self.abandonRoute(why, wasOpen: t.state == .open) }
    }

    func send(payload data: Data) {
        if multiRoute && Linia2TransportPlan.expectsReply(data) {
            routeLock.lock()
            if lastSendWithReply <= lastReceive { lastSendWithReply = Date() }
            routeLock.unlock()
        }
        webSocketConnection?.send(data: data)
    }

}

protocol ConnectionListener {
    func onConnect(reconnecting: Bool, param: Any?)
    func onMessage(with message: String)
    func onDisconnect(isServerOriginated: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String)
    func onError(error: Error)
    /// LINIA2 (1019): маршрут дал первый ответ сервера.
    func onRouteUp(route: Linia2Route, netProtocol: String?)
    /// LINIA2 (1019): начата попытка по другому маршруту / маршрут не удался (для статуса в интерфейсе).
    func onRouteChanged()
}

extension ConnectionListener {
    func onRouteUp(route: Linia2Route, netProtocol: String?) {}
    func onRouteChanged() {}
}
