//
//  WebSocket.swift
//  TinodeSDK
//
//  Copyright © 2022 Tinode LLC. All rights reserved.
//

import Foundation

/// LINIA2 (сборка 1019, транспорты): события любого транспорта (WebSocket, long-polling) — см. Linia2Transport.swift.
protocol WebSocketConnectionDelegate {
    func onConnected(connection: Linia2Transport)
    func onDisconnected(connection: Linia2Transport, isServerOriginated clean: Bool, closeCode: URLSessionWebSocketTask.CloseCode, reason: String)
    func onError(connection: Linia2Transport, error: Error)
    func onMessage(connection: Linia2Transport, text: String)
    func onMessage(connection: Linia2Transport, data: Data)
}

class WebSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate, Linia2Transport {
    /// LINIA2: протокол транспорта для диагностики (WebSocket поверх HTTP/1.1 upgrade).
    var linia2NetProtocol: String? { "ws" }

    /// LINIA2: Linia2Transport — запрос как раньше (ключ API в заголовке X-Tinode-APIKey).
    func connect(url: URL, apiKey: String) {
        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "X-Tinode-APIKey")
        connect(req: request)
    }

    /// LINIA2: максимальный размер одного входящего сообщения. По умолчанию у URLSessionWebSocketTask — 1 МБ:
    /// ответ {meta sub} на 'me' большого аккаунта (сотни чатов с аватарами в pub) больше — receive падал
    /// («Message too long»), сокет закрывался клиентом (на сервере — 1005), вход не завершался.
    static let kMaxMessageSize = 64 * 1024 * 1024
    /// LINIA2: момент начала текущего подключения (для «не перебивать идущее подключение»).
    private(set) var connectingSince: Date?
    private var opened: Date?
    private var bytesIn = 0
    private var maxMsg = 0
    /// LINIA2 (сборка 1011, цикл переподключения): сокет закрыли мы сами (cancel) — это не обрыв.
    private var closedByUs = false
    /// LINIA2: об окончании текущей задачи уже сообщили (receive-ошибка и didCompleteWithError приходят оба —
    /// раньше одна отмена давала 2 ошибки и 4 «обрыва»).
    private var finishReported = false
    enum State: CustomDebugStringConvertible {
        case unopened
        case connecting
        case open
        case closing
        case closed

        var debugDescription: String {
            switch self {
            case .unopened: return "unopened"
            case .connecting: return "connecting"
            case .open: return "open"
            case .closing: return "closing"
            case .closed: return "closed"
            }
        }
    }

    private var delegate: WebSocketConnectionDelegate?
    // LINIA2: текущая задача читается из потоков URLSession и пишется из connect() — под замком.
    private let socketLock = NSLock()
    private var currentSocket: URLSessionWebSocketTask?
    private var socket: URLSessionWebSocketTask? {
        get { socketLock.lock(); defer { socketLock.unlock() }; return currentSocket }
        set { socketLock.lock(); currentSocket = newValue; socketLock.unlock() }
    }
    private var session: URLSession!
    private let webSocketQueue: DispatchQueue = DispatchQueue(
        label: "co.tinode.tinodios.websocket",
        qos: .default,
        autoreleaseFrequency: .workItem
    )
    private lazy var delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WebSocket.delegateQueue"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = webSocketQueue
        return queue
    }()
    private var timeout: TimeInterval!
    private(set) var state: State = .unopened

    init(timeout: TimeInterval, delegate: WebSocketConnectionDelegate?) {
        super.init()
        self.timeout = timeout
        self.delegate = delegate
    }

    // LINIA2: события устаревшей задачи (после повторного connect()) не трогают текущее соединение.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === socket else { return }
        self.state = .open
        opened = Date()
        Tinode.linia2Event?("ws-open", ["ms": Int(Date().timeIntervalSince(connectingSince ?? Date()) * 1000)])
        self.delegate?.onConnected(connection: self)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === socket, !finishReported else { return }
        finishReported = true
        self.state = .closed
        if closedByUs {
            Tinode.linia2Event?("ws-close", ["code": closeCode.rawValue, "by": "client"])
            self.delegate?.onDisconnected(connection: self, isServerOriginated: false, closeCode: .goingAway, reason: Tinode.linia2ClientCancelReason)
            return
        }
        Tinode.linia2Event?("ws-close", ["code": closeCode.rawValue, "by": "server", "reason": String(decoding: reason ?? Data(), as: UTF8.self),
                                         "open_s": Int(Date().timeIntervalSince(opened ?? Date())), "in_kb": bytesIn / 1024, "max_kb": maxMsg / 1024])
        self.delegate?.onDisconnected(connection: self, isServerOriginated: true, closeCode: closeCode, reason: String(decoding: reason ?? Data(), as: UTF8.self))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        /// Don't call delegate?.onDisconnected in this method. It would close the next connection.
        // LINIA2: без serverTrust (не TLS-вызов) — стандартная обработка вместо падения на «!».
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === socket else { return }
        errorHandler(error)
    }

    func connect(req: URLRequest) {
        // Предыдущая сессия держит делегат (self) — закрываем её (её события дальше игнорируются).
        if session != nil {
            Tinode.linia2Event?("ws-replace", ["prev": state.debugDescription, "open_s": Int(Date().timeIntervalSince(opened ?? Date()))])
        }
        session?.invalidateAndCancel()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = WebSocket.kMaxMessageSize
        socket = task
        connectingSince = Date()
        opened = nil
        bytesIn = 0
        maxMsg = 0
        state = .connecting
        closedByUs = false
        finishReported = false
        task.resume()

        listen(on: task)
    }

    // LINIA2: до первого connect() socket — nil (раньше «!» и падение).
    /// byUs = false — только автотесты (эмуляция пропажи сети): закрытие считается обрывом.
    func close(byUs: Bool = true) {
        Tinode.linia2Event?("ws-cancel", ["prev": state.debugDescription, "open_s": Int(Date().timeIntervalSince(opened ?? Date()))])
        if state == .closed || state == .unopened {
            // Уже закрыт — повторная отмена ничего не даёт (и не должна порождать «обрыв»).
            if socket != nil { finishReported = true }
            return
        }
        closedByUs = byUs
        state = .closing
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// LINIA2: проверка живости сокета (ws ping). done(true) — pong пришёл за timeout; вызывается один раз.
    func linia2Ping(timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        guard let task = socket, state == .open else { done(false); return }
        let lock = NSLock(); var finished = false
        let finish: (Bool) -> Void = { ok in
            lock.lock(); let first = !finished; finished = true; lock.unlock()
            if first { done(ok) }
        }
        task.sendPing { error in finish(error == nil) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    func send(text: String) {
        guard let socket = socket else { return }
        socket.send(URLSessionWebSocketTask.Message.string(text)) { error in
            guard socket === self.socket else { return }
            self.errorHandler(error)
        }
    }

    func send(data: Data) {
        guard let socket = socket else { return }
        socket.send(URLSessionWebSocketTask.Message.data(data)) { error in
            guard socket === self.socket else { return }
            self.errorHandler(error)
        }
    }

    // LINIA2: слушаем конкретную задачу (раньше каждый раз перечитывалось self.socket — после повторного
    // connect() старая задача начинала читать из новой).
    private func listen(on socket: URLSessionWebSocketTask)  {
        guard socket.state == .running else { return }

        socket.receive { [weak self] result in
            guard let self = self, socket === self.socket else { return }

            switch result {
            case .failure(let error):
                self.errorHandler(error)
            case .success(let message):
                switch message {
                case .string(let text):
                    let n = text.utf8.count
                    self.bytesIn += n
                    if n > self.maxMsg { self.maxMsg = n }
                    self.delegate?.onMessage(connection: self, text: text)
                case .data(let data):
                    self.delegate?.onMessage(connection: self, data: data)
                @unknown default:
                    Tinode.log.error("Unknown WebSocket message type: %@", String(describing: message))
                }

                self.listen(on: socket)
            }
        }
    }

    private func errorHandler(_ error: Error?) {
        guard let error = error, !finishReported else { return }
        finishReported = true

        let ns = error as NSError
        // LINIA2: отмена нами (cancel / замена адреса / -999) — не обрыв: без onError, один onDisconnected
        // с особой причиной, по которой ни переподключение, ни смена адреса не запускаются.
        if closedByUs || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled && state == .closing) {
            Tinode.linia2Event?("ws-cancelled", ["prev": state.debugDescription, "code": ns.code])
            self.state = .closed
            self.delegate?.onDisconnected(connection: self, isServerOriginated: false, closeCode: .goingAway, reason: Tinode.linia2ClientCancelReason)
            return
        }
        Tinode.linia2Event?("ws-error", ["prev": state.debugDescription, "domain": ns.domain, "code": ns.code,
                                         "desc": String(ns.localizedDescription.prefix(120)),
                                         "open_s": Int(Date().timeIntervalSince(opened ?? Date())),
                                         "in_kb": bytesIn / 1024, "max_kb": maxMsg / 1024])
        self.state = .closed

        var code = -1
        var serverOriginated = false
        if let error = error as NSError? {
            code = error.code
            switch Int32(code) {
            case ENETDOWN, ENETUNREACH, ECONNRESET, ETIMEDOUT, ECONNREFUSED:
                socket?.cancel(with: .goingAway, reason: nil)
                delegate?.onError(connection: self, error: WebSocketError.network(code: error.code))
            default:
                delegate?.onError(connection: self, error: error)
                serverOriginated = true
            }
        }

        self.delegate?.onDisconnected(connection: self, isServerOriginated: serverOriginated, closeCode: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .abnormalClosure, reason: error.localizedDescription)
    }
}

public enum WebSocketError: Error {
    // Network error code
    case network(code: Int)

    public var description: String {
        switch self {
        case .network(let code):
            switch Int32(code) {
            case ENETDOWN:
                return "ENETDOWN: network is down"
            case ENETUNREACH:
                return "ENETUNREACH: network is unreachable";
            case ECONNRESET:
                return "ECONNRESET: connection reset by peer"
            case ETIMEDOUT:
                return "ETIMEDOUT: network timeout"
            case ECONNREFUSED:
                return "ECONNREFUSED: connection refused"
            default:
                return "Network error: \(code)"
            }
        }
    }
}
