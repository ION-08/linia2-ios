//
//  WebSocket.swift
//  TinodeSDK
//
//  Copyright © 2022 Tinode LLC. All rights reserved.
//

import Foundation

protocol WebSocketConnectionDelegate {
    func onConnected(connection: WebSocket)
    func onDisconnected(connection: WebSocket, isServerOriginated clean: Bool, closeCode: URLSessionWebSocketTask.CloseCode, reason: String)
    func onError(connection: WebSocket, error: Error)
    func onMessage(connection: WebSocket, text: String)
    func onMessage(connection: WebSocket, data: Data)
}

class WebSocket: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {
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
        self.delegate?.onConnected(connection: self)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === socket else { return }
        self.state = .closed
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
        session?.invalidateAndCancel()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: req)
        socket = task
        state = .connecting
        task.resume()

        listen(on: task)
    }

    // LINIA2: до первого connect() socket — nil (раньше «!» и падение).
    func close() {
        state = .closing
        socket?.cancel(with: .goingAway, reason: nil)
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
        guard let error = error else { return }

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
