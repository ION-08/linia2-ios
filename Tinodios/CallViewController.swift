//
//  CallViewController.swift
//  Tinodios
//
//  Copyright © 2022-2025 Tinode LLC. All rights reserved.
//


import AVFoundation
import AVKit
import Foundation
import Network
import TinodeSDK
import UIKit
import WebRTC

@objc
protocol CameraCaptureDelegate: AnyObject {
    func captureVideoOutput(sampleBuffer: CMSampleBuffer)
}

class CameraManager: NSObject {
    var videoCaptureDevice: AVCaptureDevice?
    let captureSession = AVCaptureSession()
    let videoDataOutput = AVCaptureVideoDataOutput()
    let audioDataOutput = AVCaptureAudioDataOutput()
    let dataOutputQueue = DispatchQueue(label: "VideoDataQueue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    weak var delegate: CameraCaptureDelegate?

    var isCapturing = false
    /// LINIA2: движок WKWebView — камерой владеет страница (getUserMedia), здесь только желаемое состояние.
    weak var web: Linia2WebCallEngine?

    func setupCamera() {
        if web != nil { return }
        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else { return }

        self.videoCaptureDevice = videoCaptureDevice

        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }

        // Cap video camera resolution (best effort).
        // Otherwise, remote video stream may freeze
        // https://stackoverflow.com/questions/55841076/webrtc-remote-video-freeze-after-few-seconds
        if captureSession.canSetSessionPreset(.iFrame1280x720) {
            captureSession.sessionPreset = .iFrame1280x720
        } else if captureSession.canSetSessionPreset(.iFrame960x540) {
            captureSession.sessionPreset = .iFrame960x540
        } else if captureSession.canSetSessionPreset(.vga640x480) {
            captureSession.sessionPreset = .vga640x480
        } else {
            Cache.log.error("CallVC - Could not scale down video resolution")
        }

        // Add a video data output
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
            videoDataOutput.setSampleBufferDelegate(self, queue: dataOutputQueue)
            videoDataOutput.connection(with: .video)?.videoOrientation = .portrait
            videoDataOutput.connection(with: .video)?.automaticallyAdjustsVideoMirroring = false
            videoDataOutput.connection(with: .video)?.isVideoMirrored = true
        } else {
            Cache.log.error("CallVC - Could not add video data output to the session")
            captureSession.commitConfiguration()
        }
    }

    /// LINIA2: переключение фронтальной / основной камеры.
    private(set) var position: AVCaptureDevice.Position = .front
    func switchCamera() {
        let newPos: AVCaptureDevice.Position = position == .front ? .back : .front
        if let w = web {
            position = newPos
            w.call("switchCamera", nil)
            return
        }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        dataOutputQueue.async {
            self.captureSession.beginConfiguration()
            for i in self.captureSession.inputs { self.captureSession.removeInput(i) }
            if self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
                self.videoCaptureDevice = dev
                self.position = newPos
            } else if let old = self.videoCaptureDevice, let oldInput = try? AVCaptureDeviceInput(device: old), self.captureSession.canAddInput(oldInput) {
                self.captureSession.addInput(oldInput)
            }
            if let c = self.videoDataOutput.connection(with: .video) {
                c.videoOrientation = .portrait
                c.automaticallyAdjustsVideoMirroring = false
                if c.isVideoMirroringSupported { c.isVideoMirrored = (self.position == .front) }
            }
            self.captureSession.commitConfiguration()
        }
    }

    /// LINIA2: запуск/остановка камеры — по порядку, на своей последовательной очереди с приоритетом
    /// «по действию пользователя». Раньше — глобальная очередь .background: система её притормаживает
    /// (на загруженном устройстве/симуляторе — секундами), кнопка «Камера» всё это время была выключена
    /// и подпись не менялась; два быстрых нажатия могли выполниться не по порядку.
    private let sessionQueue = DispatchQueue(label: "l2.camera.session", qos: .userInitiated)

    /// `isCapturing` (желаемое состояние) меняется сразу, на главном потоке; сама сессия — в sessionQueue.
    func startCapture(completion: (() -> Void)? = nil) {
        Cache.log.info("CallVC - CameraManager: start capture")

        guard !isCapturing else { return }
        isCapturing = true
        if let w = web {
            w.setCamera(true)
            DispatchQueue.main.async { completion?() }
            return
        }

        #if arch(arm64)
        sessionQueue.async {
            if !self.captureSession.isRunning { self.captureSession.startRunning() }
            completion?()
        }
        #else
        completion?()
        #endif
    }
    func stopCapture(completion: (() -> Void)? = nil) {
        Cache.log.info("CallVC - CameraManager: end capture")
        guard isCapturing else { return }
        isCapturing = false
        if let w = web {
            w.setCamera(false)
            DispatchQueue.main.async { completion?() }
            return
        }

        #if arch(arm64)
        sessionQueue.async {
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
            completion?()
        }
        #else
        completion?()
        #endif
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if connection == videoDataOutput.connection(with: .video) {
            delegate?.captureVideoOutput(sampleBuffer: sampleBuffer)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    }
}

/// WebRTCClient
/// Methods for dispatching local events to the peer.
protocol WebRTCClientDelegate: AnyObject {
    func handleRemoteStream(_ client: WebRTCClient, receivedStream stream: RTCMediaStream)
    func sendOffer(withDescription sdp: RTCSessionDescription)
    func sendAnswer(withDescription sdp: RTCSessionDescription)
    func sendIceCandidate(_ candidate: RTCIceCandidate)
    func closeCall()
    func canSendOffer() -> Bool
    func markConnectionSetupComplete()
    func enableMediaControls()
    // Toggle remote video.
    func toggleRemoteVideo(remoteLive: Bool)
    // Returns true is the call is originated as audio only.
    var isAudioOnlyCall: Bool { get }
    /// LINIA2: мы звоним (первый offer создаём сами, не дожидаясь negotiationneeded).
    var linia2IsCaller: Bool { get }
    /// LINIA2 (переподключение): состояние ICE — на главном потоке.
    func linia2IceStateChanged(_ state: RTCIceConnectionState)
    /// LINIA2: ответ собеседника на наш offer применён / мы ответили на offer собеседника (в т.ч. ICE restart).
    func linia2NegotiationDone(remoteOffer: Bool)
    /// LINIA2: перенастройка уже соединённого звонка не удалась — звонок не рвём, повторим ICE restart.
    func linia2NegotiationFailed(_ stage: String)
}

/// TinodeVideoCallDelegate
/// Methods for handling remote messages received from the peer.
protocol TinodeVideoCallDelegate: AnyObject {
    func eventMatchesCallInProgress(info: MsgServerInfo) -> Bool
    func handleAcceptedMsg()
    func handleOfferMsg(with payload: JSONValue?)
    func handleAnswerMsg(with payload: JSONValue?)
    func handleIceCandidateMsg(with payload: JSONValue?)
    func handleRemoteHangup()
    func handleRinging()
    /// LINIA2: веб-сокет Tinode закрылся / вход после переподключения выполнен.
    func linia2SignalingDown(reason: String)
    func linia2SignalingLoggedIn(code: Int)
}

class WebRTCClient: NSObject {
    /// LINIA2: закрытие соединений (pc.close() блокирует на секунды) — не на главном потоке.
    static let closeQueue = DispatchQueue(label: "linia2.webrtc.close", qos: .userInitiated)

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    private static let kVideoCallMediaConstraints = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                    kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue]
    private static let kAudioOnlyMediaConstraints = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue]
    // Video muted/unmuted events.
    public static let kVideoEventMuted = "video:muted"
    public static let kVideoEventUnmuted = "video:unmuted"

    private var localPeer: RTCPeerConnection?
    private var localDataChannel: RTCDataChannel?
    private var localVideoSource: RTCVideoSource?
    private var localVideoTrack: RTCVideoTrack?
    private var videoCapturer: RTCVideoCapturer?
    private var remoteVideoTrack: RTCVideoTrack?

    private var localAudioTrack: RTCAudioTrack?

    /// LINIA2: первый offer уже создан (звонящий) / ответ собеседника применён — дальше разрешена перенастройка.
    private(set) var initialOfferSent = false
    private var remoteAnswerApplied = false
    /// LINIA2: ICE хотя бы раз соединился — дальше ошибки ICE/SDP не завершают звонок (переподключение, ICE restart).
    private(set) var linia2Established = false
    /// Диагностика звонка (события ICE/соединения/треков) — см. Linia2CallDiag.
    var onDiagEvent: (([String: Any]) -> Void)?

    private var remoteIceCandidatesCacheQueue = DispatchQueue(label: "co.tinode.webrtc.ice-candidates-queue")
    private var remoteIceCandidatesCache: [RTCIceCandidate] = []
    /// LINIA2: буфер удалённых кандидатов уже разгружен (удалённое описание применено) — новые кандидаты сразу в соединение.
    private var remoteCandidatesDrained = false
    /// LINIA2: удалённое описание (offer/answer собеседника) применено — флаг под remoteIceCandidatesCacheQueue.
    /// Раньше вместо него внутри queue.sync на главном потоке читалось localPeer.remoteDescription — это
    /// синхронный вызов в signaling-поток WebRTC, а signaling-поток в это же время (завершение setRemote/
    /// setLocalDescription → drainIceCandidatesCache) ждал ту же очередь: взаимная блокировка, главный поток
    /// зависал навсегда («Соединение…», входящий звонок 27.11 seq 30: после «start» — ни одного события).
    private var remoteDescriptionApplied = false
    /// LINIA2 (диагностика реальной сети): счётчики кандидатов «тип/протокол», напр. "relay/udp".
    private let diagLock = NSLock()
    private var diagLocalCands: [String: Int] = [:]
    private var diagRemoteCands: [String: Int] = [:]
    /// Отправлено собеседнику локальных кандидатов по типу (host/srflx/relay/prflx) и не отправлено (нет seq/топика).
    private var diagLocalSent: [String: Int] = [:]
    private var diagLocalDropped = 0
    /// Удалённые кандидаты: добавлено в соединение / ошибка addIceCandidate (последняя ошибка — текстом).
    private var diagRemoteAddOk = 0
    private var diagRemoteAddFail = 0
    private var diagLastAddErr = ""
    /// ufrag (4 символа) последнего своего и чужого описания.
    var diagLocalUfrag = "-"
    var diagRemoteUfrag = "-"

    func diagNoteLocalSent(_ c: RTCIceCandidate, sent: Bool) {
        let type = Self.candKind(c.sdp).components(separatedBy: "/").first ?? "?"
        diagLock.lock()
        if sent { diagLocalSent[type, default: 0] += 1 } else { diagLocalDropped += 1 }
        diagLock.unlock()
    }

    /// Добавить удалённый кандидат в соединение с учётом результата (счётчики для диагностики).
    private func addRemoteToPeer(_ candidate: RTCIceCandidate) {
        guard let pc = localPeer else {
            diagLock.lock(); diagRemoteAddFail += 1; diagLastAddErr = "no-pc"; diagLock.unlock()
            return
        }
        pc.add(candidate) { [weak self] err in
            guard let self = self else { return }
            self.diagLock.lock()
            if let err = err {
                self.diagRemoteAddFail += 1
                self.diagLastAddErr = String(err.localizedDescription.prefix(80))
            } else {
                self.diagRemoteAddOk += 1
            }
            self.diagLock.unlock()
            if let err = err {
                // LINIA2: кандидат прошлого поколения (после ICE restart) или с уже недоступного адреса — не повод
                // завершать звонок: остальные кандидаты/TURN продолжают работать.
                Cache.log.error("WebRTCClient: could not add ICE candidate: %@", err.localizedDescription)
                self.onDiagEvent?(["type": "error", "where": "addIceCandidate", "err": String(err.localizedDescription.prefix(80)),
                                   "mid": candidate.sdpMid ?? "nil", "idx": Int(candidate.sdpMLineIndex)])
            }
        }
    }

    /// LINIA2: поля для периодических stats (только скаляры — сервер диагностики отбрасывает вложенные объекты).
    /// Сводка по парам кандидатов и STUN-проверкам: если запросы уходят, а ответов нет — видно сразу.
    func diagStatsFields(_ report: RTCStatisticsReport) -> [String: Any] {
        var f: [String: Any] = [:]
        diagLock.lock()
        for (k, v) in diagLocalSent { f["ls_" + k] = v }
        for (k, v) in diagRemoteCands { f["rc_" + k.replacingOccurrences(of: "/", with: "_")] = v }
        f["ls_drop"] = diagLocalDropped
        f["ra_ok"] = diagRemoteAddOk
        f["ra_fail"] = diagRemoteAddFail
        if !diagLastAddErr.isEmpty { f["ra_err"] = diagLastAddErr }
        diagLock.unlock()
        f["lu"] = diagLocalUfrag
        f["ru"] = diagRemoteUfrag
        var reqS = 0, respR = 0, reqR = 0, respS = 0
        var states: [String: Int] = [:]
        var lcTypes: [String: Int] = [:]
        for (_, st) in report.statistics {
            let v = st.values
            func n(_ k: String) -> Int { (v[k] as? NSNumber)?.intValue ?? 0 }
            if st.type == "candidate-pair" {
                states[(v["state"] as? String) ?? "?", default: 0] += 1
                reqS += n("requestsSent"); respR += n("responsesReceived")
                reqR += n("requestsReceived"); respS += n("responsesSent")
            } else if st.type == "local-candidate" {
                lcTypes[((v["candidateType"] as? String) ?? "?") + "_" + ((v["protocol"] as? String) ?? "?"), default: 0] += 1
            }
        }
        for (k, v) in states { f["p_" + k.replacingOccurrences(of: "-", with: "")] = v }
        for (k, v) in lcTypes { f["lc_" + k] = v }
        f["stun_reqS"] = reqS; f["stun_respR"] = respR; f["stun_reqR"] = reqR; f["stun_respS"] = respS
        return f
    }

    /// "candidate:… 1 udp 2122… 10.0.0.1 5000 typ host …" → "host/udp".
    static func candKind(_ sdp: String) -> String {
        let t = sdp.split(separator: " ").map(String.init)
        let proto = t.count > 2 ? t[2].lowercased() : "?"
        let type = t.firstIndex(of: "typ").flatMap { $0 + 1 < t.count ? t[$0 + 1] : nil } ?? "?"
        return type + "/" + proto
    }

    /// Первые 4 символа a=ice-ufrag (пароль не берём никогда).
    static func ufrag4(_ sdp: String) -> String {
        for line in sdp.components(separatedBy: "\n") where line.hasPrefix("a=ice-ufrag:") {
            return String(line.dropFirst("a=ice-ufrag:".count).trimmingCharacters(in: .whitespacesAndNewlines).prefix(4))
        }
        return "-"
    }

    func diagCountRemote(_ c: RTCIceCandidate) {
        let k = Self.candKind(c.sdp)
        diagLock.lock(); diagRemoteCands[k, default: 0] += 1; diagLock.unlock()
    }

    /// Итог для диагностики: кандидаты и выбранная пара (при connected / failed).
    func diagReportPair(_ reason: String) {
        diagLock.lock(); let lc = diagLocalCands; let rc = diagRemoteCands; diagLock.unlock()
        guard let pc = localPeer else { return }
        pc.statistics { [weak self] report in
            var cands: [String: [String: NSObject]] = [:]
            var pairs: [[String: NSObject]] = []
            for (id, st) in report.statistics {
                if st.type == "local-candidate" || st.type == "remote-candidate" { cands[id] = st.values }
                if st.type == "candidate-pair" { pairs.append(st.values) }
            }
            var states: [String: Int] = [:]
            for p in pairs { states[(p["state"] as? String) ?? "?", default: 0] += 1 }
            // Только скаляры: сервер диагностики отбрасывает вложенные словари.
            func flat(_ d: [String: Int]) -> String { d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
            var ev: [String: Any] = ["type": "pair", "reason": reason, "lc": flat(lc), "rc": flat(rc), "pairs": flat(states)]
            if let self = self { for (k, v) in self.diagStatsFields(report) { ev[k] = v } }
            let sel = pairs.first { ($0["nominated"] as? NSNumber)?.boolValue == true && ($0["state"] as? String) == "succeeded" }
                ?? pairs.first { ($0["state"] as? String) == "succeeded" }
            if let p = sel {
                let l = cands[(p["localCandidateId"] as? String) ?? ""] ?? [:]
                let r = cands[(p["remoteCandidateId"] as? String) ?? ""] ?? [:]
                ev["sel"] = "\((l["candidateType"] as? String) ?? "?")/\((l["protocol"] as? String) ?? "?") -> \((r["candidateType"] as? String) ?? "?")/\((r["protocol"] as? String) ?? "?")"
                if let rtt = (p["currentRoundTripTime"] as? NSNumber)?.doubleValue { ev["rtt"] = Int(rtt * 1000) }
            }
            self?.onDiagEvent?(ev)
        }
    }

    weak var delegate: WebRTCClientDelegate?

    /// LINIA2 (вариант Б): звонковый движок в WKWebView (features.webCallEngine) — см. Linia2WebCallEngine.
    /// Если задан, медиа и RTCPeerConnection — в JS; методы ниже передают ему команды, события приходят обратно
    /// через linia2Web* и становятся теми же вызовами делегата, что и у нативного движка.
    private(set) var web: Linia2WebCallEngine?
    /// Соединение в JS создано (аналог localPeer != nil).
    private var webPC = false
    var isWebEngine: Bool { web != nil }

    /// Включить движок WKWebView для этого звонка (до setup()).
    func linia2EnableWebEngine(audioOnly: Bool, caller: Bool, video: Bool) {
        guard web == nil else { return }
        let w = Linia2WebCallEngine(client: self)
        web = w
        CallManager.linia2WebAudio = true
        // Если CallKit уже включил звук для нативного движка — выключить нативный аудиомодуль (сессию не трогаем).
        let rtc = RTCAudioSession.sharedInstance()
        if rtc.useManualAudio && rtc.isAudioEnabled { rtc.isAudioEnabled = false }
        onDiagEvent?(["type": "engine", "name": "web"])
        w.start(audioOnly: audioOnly, caller: caller, video: video)
    }

    /// LINIA2 (ответ из фона): страница движка для перехода «нативный → WKWebView» посреди звонка. Пока переход не
    /// выполнен (linia2CommitWebSwitch), нативный движок работает как прежде — страница только загружается.
    private var pendingWeb: Linia2WebCallEngine?

    func linia2PrepareWebSwitch() -> Linia2WebCallEngine? {
        guard web == nil else { return nil }
        if let p = pendingWeb { return p }
        let w = Linia2WebCallEngine(client: self)
        pendingWeb = w
        return w
    }

    func linia2CancelWebSwitch() {
        pendingWeb?.close()
        pendingWeb = nil
    }

    /// Закрыть нативное соединение (без hang-up и без событий экрану) и передать звонок странице: медиа —
    /// getUserMedia в JS, новое соединение и offer создаёт экран (createPeerConnection + makeInitialOffer).
    func linia2CommitWebSwitch(audioOnly: Bool, caller: Bool, video: Bool) -> Bool {
        guard web == nil, let w = pendingWeb, w.isReady else { return false }
        pendingWeb = nil
        if let pc = localPeer {
            localPeer = nil
            for sender in pc.senders { sender.track?.isEnabled = false }
            pc.delegate = nil
            WebRTCClient.closeQueue.async { pc.close() }
        }
        localDataChannel?.delegate = nil
        localDataChannel = nil
        localAudioTrack = nil
        localVideoSource = nil
        localVideoTrack = nil
        videoCapturer = nil
        remoteVideoTrack = nil
        remoteIceCandidatesCacheQueue.sync {
            remoteCandidatesDrained = false
            remoteDescriptionApplied = false
            remoteIceCandidatesCache.removeAll()
        }
        initialOfferSent = false
        remoteAnswerApplied = false
        web = w
        webPC = false
        CallManager.linia2WebAudio = true
        // Нативный аудиомодуль — выключить (микрофон берёт WebKit); сессию AVAudioSession не трогаем.
        let rtc = RTCAudioSession.sharedInstance()
        if rtc.useManualAudio && rtc.isAudioEnabled { rtc.isAudioEnabled = false }
        onDiagEvent?(["type": "engine", "name": "web", "switch": 1, "app": Linia2WebCallEngine.appState()])
        w.start(audioOnly: audioOnly, caller: caller, video: video, established: linia2Established)
        return true
    }

    /// LINIA2: страница движка не готова (фон, не загрузилась) — этот звонок на нативном движке. Только до setup().
    func linia2DisableWebEngine(reason: String) {
        guard let w = web else { return }
        web = nil
        webPC = false
        w.close()
        CallManager.linia2WebAudio = false
        // CallKit уже включил звук (пока ждали страницу) — передать сессию нативному WebRTC, как в didActivate.
        if CallManager.linia2AudioActive {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.audioSessionDidActivate(AVAudioSession.sharedInstance())
            rtc.isAudioEnabled = true
        }
        onDiagEvent?(["type": "engine", "name": "native-fallback", "reason": reason])
    }

    func setup() {
        if web != nil { return }   // медиа берёт страница (getUserMedia)
        createMediaSenders()
    }

    func toggleAudio() -> Bool {
        if let w = web { w.setAudio(!w.audioEnabled); return w.audioEnabled }
        guard let track = self.localAudioTrack else { return false }
        track.isEnabled = !track.isEnabled
        return track.isEnabled
    }

    // LINIA2: явные состояния (для CallKit «Выключить звук» и удержания).
    var isAudioEnabled: Bool { web.map { $0.hasAudio && $0.audioEnabled } ?? (localAudioTrack?.isEnabled ?? false) }
    var hasLocalAudioTrack: Bool { web?.hasAudio ?? (localAudioTrack != nil) }
    var iceStateName: String {
        if let w = web { return w.iceState }
        return localPeer.map { WebRTCClient.iceName($0.iceConnectionState) } ?? "none"
    }
    func setAudioEnabled(_ on: Bool) {
        if let w = web { w.setAudio(on); return }
        localAudioTrack?.isEnabled = on
    }
    func setVideoEnabled(_ on: Bool) {
        if let w = web { w.setVideoEnabled(on); return }
        localVideoTrack?.isEnabled = on
    }
    var isVideoTrackEnabled: Bool { web?.videoEnabled ?? (localVideoTrack?.isEnabled ?? false) }

    /// Статистика WebRTC (потери, RTT) — для «Плохая связь».
    func statistics(_ completion: @escaping (RTCStatisticsReport) -> Void) {
        guard web == nil else { return }   // движок WKWebView: статистика — web.lastStats
        guard let peer = localPeer else { return }
        peer.statistics(completionHandler: completion)
    }

    /// Дополнительный получатель удалённого видео (картинка-в-картинке).
    func addRemoteRenderer(_ renderer: RTCVideoRenderer) { remoteVideoTrack?.add(renderer) }
    func removeRemoteRenderer(_ renderer: RTCVideoRenderer) { remoteVideoTrack?.remove(renderer) }

    func toggleVideo() -> Bool {
        guard let track = self.localVideoTrack else { return false }
        track.isEnabled = !track.isEnabled
        return track.isEnabled
    }

    // Adds remote ICE candidate to either the peer connection when it exists
    // or the cache when the hasn't been created yet.
    func handleRemoteIceCandidate(_ candidate: RTCIceCandidate, saveInCache: Bool) {
        if let w = web {
            // Буфер до удалённого описания — в JS (как веб-CallPanel).
            var c: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex)]
            if let mid = candidate.sdpMid { c["sdpMid"] = mid }
            w.call("remoteIce", c)
            return
        }
        if !saveInCache {
            addRemoteToPeer(candidate)
        } else {
            // LINIA2: гонка «буфер уже разгружен, а флаг ещё не виден на главном потоке» — кандидат попадал в буфер
            // ПОСЛЕ разгрузки и не применялся никогда (iOS не знал адресов собеседника: ICE «checking» 30+ с,
            // звука нет — реальный звонок 27.11 11:07). Решение под той же очередью, что и разгрузка.
            var addNow = false
            self.remoteIceCandidatesCacheQueue.sync {
                if self.remoteCandidatesDrained || self.remoteDescriptionApplied {
                    addNow = true
                } else {
                    self.remoteIceCandidatesCache.append(candidate)
                }
            }
            if addNow {
                self.handleRemoteIceCandidate(candidate, saveInCache: false)
            }
        }
    }

    // Adds all locally cached remote ICE candidates to the peer connection.
    func drainIceCandidatesCache() {
        if web != nil { return }   // JS разгружает свой буфер сам после setRemoteDescription
        Cache.log.info("Draining iceCandidateCache: %d items", self.remoteIceCandidatesCache.count)
        var pending: [RTCIceCandidate] = []
        self.remoteIceCandidatesCacheQueue.sync {
            self.remoteCandidatesDrained = true
            pending = self.remoteIceCandidatesCache
            self.remoteIceCandidatesCache.removeAll()
        }
        onDiagEvent?(["type": "candidates", "drained": pending.count])
        // LINIA2: результат каждого добавления — в счётчиках ra_ok/ra_fail (раньше флаг success проверялся
        // до асинхронных completion — ошибка не видна никогда).
        pending.forEach { addRemoteToPeer($0) }
    }

    var hasPeerConnection: Bool { web != nil ? webPC : localPeer != nil }

    /// Вызывается из signaling-потока (завершение setRemoteDescription). Внутри очереди — без вызовов WebRTC.
    private func markRemoteDescriptionApplied() {
        remoteIceCandidatesCacheQueue.sync { remoteDescriptionApplied = true }
    }

    func createPeerConnection(withDataChannel dataChannel: Bool) -> Bool {
        if let w = web {
            if webPC { return true }
            guard let config = generateRTCConfig() else { return false }
            webPC = true
            w.createPeerConnection(iceServers: config.iceServers, relayOnly: false, dataChannel: dataChannel)
            return true
        }
        // LINIA2: повторный вызов (соединение создано заранее, при «Принять») — используем готовое.
        if localPeer != nil { return true }
        // LINIA2: действительно новое соединение — буфер удалённых кандидатов снова копится до применения удалённого описания.
        remoteIceCandidatesCacheQueue.sync {
            remoteCandidatesDrained = false
            remoteDescriptionApplied = false
            remoteIceCandidatesCache.removeAll()
        }
        diagLock.lock()
        diagLocalCands = [:]; diagRemoteCands = [:]; diagLocalSent = [:]; diagLocalDropped = 0
        diagRemoteAddOk = 0; diagRemoteAddFail = 0; diagLastAddErr = ""
        diagLock.unlock()
        // Треки создаются в setup(); после disconnect() их нет — не падаем на force-unwrap.
        guard let audioTrack = self.localAudioTrack, let videoTrack = self.localVideoTrack else {
            Cache.log.error("WebRTCClient - no local tracks (call already closed?)")
            return false
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let config = generateRTCConfig() else {
            Cache.log.info("WebRTCClient - missing configuration. Quitting.")
            return false
        }

        localPeer = WebRTCClient.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        guard localPeer != nil else {
            Cache.log.error("WebRtCClient - failed to create peer connection. Quitting.")
            return false
        }

        // LINIA2: сначала медиа, потом канал данных. Раньше канал создавался первым: negotiationneeded
        // приходил (в потоке signaling), пока поток ещё не добавлен, senders были пусты — и offer не
        // создавался вовсе (веб принимал звонок и ждал offer, звонок обрывался по таймауту).
        // LINIA2: Unified Plan (как в браузерах) — треки через addTrack с общим streamId; addStream есть только в Plan B.
        _ = localPeer!.add(audioTrack, streamIds: ["ARDAMS"])
        _ = localPeer!.add(videoTrack, streamIds: ["ARDAMS"])

        if dataChannel {
            let chanConfig = RTCDataChannelConfiguration()
            chanConfig.isOrdered = true
            self.localDataChannel = localPeer!.dataChannel(forLabel: "events", configuration: chanConfig)
            self.localDataChannel?.delegate = self
        }
        onDiagEvent?(["type": "pc", "iceServers": config.iceServers.count,
                      "turn": config.iceServers.contains { $0.urlStrings.contains { $0.hasPrefix("turn") } }])
        return true
    }

    /// LINIA2: первый offer звонящего — сразу после создания соединения (не ждём negotiationneeded).
    func makeInitialOffer() {
        if let w = web {
            guard !initialOfferSent, webPC else { return }
            initialOfferSent = true
            w.call("makeOffer", nil)
            return
        }
        guard !initialOfferSent, let pc = localPeer else { return }
        initialOfferSent = true
        offer(pc)
    }

    func offer(_ peerConnection: RTCPeerConnection) {
        Cache.log.info("WebRTCClient - creating offer")
        let constraints = self.delegate?.isAudioOnlyCall ?? false ? WebRTCClient.kAudioOnlyMediaConstraints : WebRTCClient.kVideoCallMediaConstraints
        peerConnection.offer(for: RTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil), completionHandler: { [weak self](sdp, error) in
            guard let self = self else { return }

            guard let sdp = sdp else {
                // Missing SDP.
                if let error = error {
                    Cache.log.error("WebRTCClient - failed to make offer SDP %@", error.localizedDescription)
                }
                self.delegate?.closeCall()
                return
            }

            peerConnection.setLocalDescription(sdp, completionHandler: { (error) in
                if let error = error {
                    Cache.log.error("WebRTCClient - failed to set local SDP (offer) %@", error.localizedDescription)
                    self.delegate?.closeCall()
                    return
                }
                self.delegate?.sendOffer(withDescription: sdp)
            })
        })
    }

    func answer(_ peerConnection: RTCPeerConnection) {
        Cache.log.info("WebRTCClient - creating answer")
        let constraints = self.delegate?.isAudioOnlyCall ?? false ? WebRTCClient.kAudioOnlyMediaConstraints : WebRTCClient.kVideoCallMediaConstraints
        peerConnection.answer(
            for: RTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil),
            completionHandler: { [weak self](sdp, error) in
                guard let self = self, let sdp = sdp else {
                    if let error = error {
                        Cache.log.error("WebRTCClient - failed to make answer SDP %@", error.localizedDescription)
                    }
                    if self?.linia2Established ?? false {
                        DispatchQueue.main.async { self?.delegate?.linia2NegotiationFailed("answer") }
                    } else {
                        self?.delegate?.closeCall()
                    }
                    return
                }

                peerConnection.setLocalDescription(sdp, completionHandler: { [weak self](error) in
                    if let error = error {
                        Cache.log.error("WebRTCClient - failed to set local SDP (answer) %@", error.localizedDescription)
                        if self?.linia2Established ?? false {
                            DispatchQueue.main.async { self?.delegate?.linia2NegotiationFailed("setLocalAnswer") }
                        } else {
                            self?.delegate?.closeCall()
                        }
                        return
                    }
                    self?.delegate?.sendAnswer(withDescription: sdp)
                    self?.delegate?.markConnectionSetupComplete()
                    DispatchQueue.main.async { self?.delegate?.linia2NegotiationDone(remoteOffer: true) }
                })
            })
    }

    var iceIsConnected: Bool {
        if let w = web { return w.iceState == "connected" || w.iceState == "completed" }
        guard let pc = localPeer else { return false }
        return pc.iceConnectionState == .connected || pc.iceConnectionState == .completed
    }
    var signalingIsStable: Bool { web.map { $0.signalingState == "stable" } ?? (localPeer?.signalingState == .stable) }

    /// LINIA2: ICE restart — новый offer с новыми ufrag/pwd (IceRestart), собеседнику через Tinode «offer» с тем же seq.
    /// `relayOnly` — только через TURN (в т.ч. TCP): после неудачных попыток напрямую.
    /// Возвращает false, если сейчас нельзя (нет соединения, ждём ответ собеседника на его offer).
    @discardableResult
    func linia2RestartIce(relayOnly: Bool) -> Bool {
        if let w = web {
            guard webPC, w.signalingState != "have-remote-offer" else { return false }
            var servers = generateRTCConfig()?.iceServers ?? []
            let fresh = Linia2Turn.shared.iceServers(timeout: 0.3)
            if !fresh.isEmpty {
                let freshUrls = Set(fresh.flatMap { $0.urlStrings })
                servers = servers.filter { Set($0.urlStrings).isDisjoint(with: freshUrls) } + fresh
            }
            w.restartIce(iceServers: servers, relayOnly: relayOnly)
            return true
        }
        guard let pc = localPeer else { return false }
        if pc.signalingState == .haveRemoteOffer { return false }
        // Свежие TURN-данные и (при необходимости) только relay.
        let cfg = pc.configuration
        let fresh = Linia2Turn.shared.iceServers(timeout: 0.3)
        if !fresh.isEmpty {
            let freshUrls = Set(fresh.flatMap { $0.urlStrings })
            cfg.iceServers = cfg.iceServers.filter { Set($0.urlStrings).isDisjoint(with: freshUrls) } + fresh
        }
        if relayOnly { cfg.iceTransportPolicy = .relay }
        if !pc.setConfiguration(cfg) {
            Cache.log.error("WebRTCClient: setConfiguration before ICE restart failed")
            onDiagEvent?(["type": "error", "where": "setConfiguration"])
        }
        let start: () -> Void = { [weak self] in
            guard let self = self, self.localPeer === pc else { return }
            var c = self.delegate?.isAudioOnlyCall ?? false ? WebRTCClient.kAudioOnlyMediaConstraints : WebRTCClient.kVideoCallMediaConstraints
            c[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: c, optionalConstraints: nil), completionHandler: { [weak self] sdp, error in
                guard let self = self else { return }
                guard let sdp = sdp else {
                    Cache.log.error("WebRTCClient - ICE restart offer failed %@", error?.localizedDescription ?? "")
                    DispatchQueue.main.async { self.delegate?.linia2NegotiationFailed("restartOffer") }
                    return
                }
                pc.setLocalDescription(sdp, completionHandler: { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        Cache.log.error("WebRTCClient - ICE restart setLocalDescription failed %@", error.localizedDescription)
                        DispatchQueue.main.async { self.delegate?.linia2NegotiationFailed("restartSetLocal") }
                        return
                    }
                    self.delegate?.sendOffer(withDescription: sdp)
                })
            })
        }
        onDiagEvent?(["type": "ice-restart", "relay": relayOnly, "signaling": pc.signalingState.rawValue])
        if pc.signalingState == .haveLocalOffer {
            // Прошлый offer остался без ответа (потерялся при обрыве) — откатываем и шлём новый.
            pc.setLocalDescription(RTCSessionDescription(type: .rollback, sdp: ""), completionHandler: { _ in
                DispatchQueue.main.async { start() }
            })
        } else {
            start()
        }
        return true
    }

    /// LINIA2 (автотесты): приостановить/возобновить отправку RTP (encodings.isActive) — эмуляция пропажи медиапути.
    func linia2SetSendingPaused(_ paused: Bool) {
        if let w = web { w.call("setPaused", paused); return }
        guard let pc = localPeer else { return }
        for sender in pc.senders {
            let p = sender.parameters
            guard !p.encodings.isEmpty else { continue }
            for e in p.encodings { e.isActive = !paused }
            sender.parameters = p
        }
        onDiagEvent?(["type": "uitest-media", "paused": paused])
    }

    /// LINIA2: при завершении — сразу перестать передавать звук и видео (до закрытия соединения).
    func linia2MuteAllForClose() {
        web?.call("muteAll", nil)
        localAudioTrack?.isEnabled = false
        localVideoTrack?.isEnabled = false
        localPeer?.senders.forEach { $0.track?.isEnabled = false }
    }

    func sendOverDataChannel(event: String) {
        if let w = web { w.call("sendDC", event); return }
        self.localDataChannel?.sendData(RTCDataBuffer(data: Data(event.utf8), isBinary: false))
    }

    func disconnect() {
        linia2CancelWebSwitch()
        initialOfferSent = false
        remoteAnswerApplied = false
        linia2Established = false
        if let w = web {
            w.close()
            web = nil
            webPC = false
        }
        // LINIA2 (баг «Завершить» срабатывает через ~5 с): RTCPeerConnection.close() синхронный и на iPhone
        // занимает секунды (освобождение TURN-выделений, остановка аудиоблока VPIO, потоки WebRTC) — раньше он
        // шёл на главном потоке ДО закрытия экрана. Теперь: треки выключаются сразу (микрофон/камера не
        // передаются), а close() — в фоновой очереди; события старого соединения экрану больше не приходят.
        if let pc = localPeer {
            localPeer = nil
            for sender in pc.senders { sender.track?.isEnabled = false }
            localAudioTrack?.isEnabled = false
            localVideoTrack?.isEnabled = false
            pc.delegate = nil
            WebRTCClient.closeQueue.async { pc.close() }
        }

        // Clean up audio.
        localAudioTrack = nil

        // ... and video.
        localVideoSource = nil
        localVideoTrack = nil
        videoCapturer = nil
        remoteVideoTrack = nil
    }
}

extension WebRTCClient: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        debugPrint("channel state \(dataChannel.readyState)")
        switch dataChannel.readyState {
        case .open:
            if !(self.delegate?.isAudioOnlyCall ?? true) {
                sendOverDataChannel(event: WebRTCClient.kVideoEventUnmuted)
            }
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let event = String(decoding: buffer.data, as: UTF8.self)
        switch event {
        case WebRTCClient.kVideoEventMuted:
            self.delegate?.toggleRemoteVideo(remoteLive: false)
        case WebRTCClient.kVideoEventUnmuted:
            self.delegate?.toggleRemoteVideo(remoteLive: true)
        default:
            break
        }
    }
}

// MARK: Preparation/setup.
extension WebRTCClient {
    // TODO: ICE/WebRTC config should be obtained from the server.
    func generateRTCConfig() -> RTCConfiguration? {
        let tinode = Cache.tinode
        // LINIA2: без параметра iceServers от сервера (ещё не пришёл {ctrl} после входа) звонок не обрываем —
        // соединяемся через наш TURN (Linia2Turn) и публичный STUN.
        var iceConfig = tinode.getServerParam(for: "iceServers")?.asArray() ?? []
        if iceConfig.isEmpty {
            Cache.log.error("WebRTCClient.generateRTCConfig: Missing/invalid iceServers server parameter — TURN/STUN fallback")
            onDiagEvent?(["type": "error", "where": "iceServersParam"])
            iceConfig = [.dict(["urls": .array([.string("stun:stun.l.google.com:19302")])])]
        }

        let config = RTCConfiguration()
        // LINIA2: Unified Plan — как у веб-клиента и гостевой страницы (Chrome/Safari поддерживают только его).
        // Plan B (было) в WebRTC устарел; SDP Plan B с современным Chrome согласуется непредсказуемо.
        config.sdpSemantics = .unifiedPlan
        // TCP candidates are only useful when connecting to a server that supports
        // ICE-TCP.
        config.tcpCandidatePolicy = .disabled
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        // Use ECDSA encryption.
        config.keyType = .ECDSA

        for v in iceConfig {
            guard let vals = v.asDict() else {
                continue
            }
            if let urls = vals["urls"]?.asArray() {
                let iceStrings = urls.compactMap { $0.asString() }
                var ice: RTCIceServer
                if let username = vals["username"]?.asString() {
                    let credential = vals["credential"]?.asString()
                    ice = RTCIceServer(urlStrings: Linia2Turn.withTcpFallback(iceStrings), username: username, credential: credential)
                } else {
                    ice = RTCIceServer(urlStrings: iceStrings)
                }
                config.iceServers.append(ice)
            } else {
                Cache.log.info("Invalid ICE server config: no URLs")
            }
        }
        // LINIA2: TURN с временным паролем, выданным нашим сервером после входа.
        config.iceServers.append(contentsOf: Linia2Turn.shared.iceServers())
        return config
    }

    private func createMediaSenders() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: nil)
        let audioSource = WebRTCClient.factory.audioSource(with: constraints)
        let audioTrack = WebRTCClient.factory.audioTrack(with: audioSource, trackId: "ARDAMSa0")
        localAudioTrack = audioTrack

        let videoSource = WebRTCClient.factory.videoSource()
        localVideoSource = videoSource
        let videoTrack = WebRTCClient.factory.videoTrack(with: videoSource, trackId: "ARDAMSv0")
        localVideoTrack = videoTrack
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
    }
}

// MARK: UI Handling
extension WebRTCClient {
    func setupLocalRenderer(_ renderer: RTCVideoRenderer) {
        guard let localVideoTrack = localVideoTrack else { return }
        localVideoTrack.add(renderer)
    }

    func setupRemoteRenderer(_ renderer: RTCVideoRenderer, withTrack track: RTCVideoTrack?) {
        // LINIA2: в Unified Plan трек может прийти и через didAdd stream, и через didAdd rtpReceiver — один раз.
        guard let track = track, track !== self.remoteVideoTrack else { return }
        self.remoteVideoTrack = track
        track.add(renderer)
    }

    func didCaptureLocalFrame(_ videoFrame: RTCVideoFrame) {
        guard let videoSource = localVideoSource,
            let videoCapturer = videoCapturer else { return }
        videoSource.capturer(videoCapturer, didCapture: videoFrame)
    }
}

// MARK: Message Handling
extension WebRTCClient {
    // Processes remote offer SDP.
    func handleRemoteOfferDescription(_ desc: RTCSessionDescription) {
        if let w = web { w.call("remoteOffer", ["type": "offer", "sdp": desc.sdp]); return }
        guard let peerConnection = localPeer else { return }
        // LINIA2: встречные offer (оба переподключаются одновременно, ICE restart) — «вежливый» (принимающий звонок)
        // откатывает свой offer и отвечает; «невежливый» (звонящий) offer собеседника игнорирует — тот откатит свой.
        if peerConnection.signalingState == .haveLocalOffer {
            if delegate?.linia2IsCaller ?? false {
                Cache.log.info("WebRTCClient: glare — ignoring remote offer (impolite)")
                onDiagEvent?(["type": "glare", "action": "ignore"])
                return
            }
            onDiagEvent?(["type": "glare", "action": "rollback"])
            peerConnection.setLocalDescription(RTCSessionDescription(type: .rollback, sdp: ""), completionHandler: { [weak self] err in
                if let err = err {
                    Cache.log.error("WebRTCClient: rollback failed: %@", err.localizedDescription)
                }
                DispatchQueue.main.async { self?.applyRemoteOffer(desc, peerConnection) }
            })
            return
        }
        applyRemoteOffer(desc, peerConnection)
    }

    private func applyRemoteOffer(_ desc: RTCSessionDescription, _ peerConnection: RTCPeerConnection) {
        peerConnection.setRemoteDescription(desc, completionHandler: { [weak self](error) in
            guard let self = self else { return }
            if let error = error {
                Cache.log.error("WebRTCClient.handleRemoteOfferDescription failure: %@", error.localizedDescription)
                if self.linia2Established {
                    DispatchQueue.main.async { self.delegate?.linia2NegotiationFailed("remoteOffer") }
                } else {
                    self.delegate?.closeCall()
                }
                return
            }
            self.markRemoteDescriptionApplied()
            self.answer(peerConnection)
        })
    }

    // Processes remote answer SDP.
    func handleRemoteAnswerDescription(_ desc: RTCSessionDescription) {
        if let w = web { w.call("remoteAnswer", ["type": "answer", "sdp": desc.sdp]); return }
        // LINIA2: запоздалый/повторный answer (мы уже откатили свой offer) — не ошибка звонка.
        if let pc = localPeer, pc.signalingState != .haveLocalOffer, linia2Established {
            onDiagEvent?(["type": "answer-ignored", "signaling": pc.signalingState.rawValue])
            return
        }
        self.localPeer?.setRemoteDescription(desc, completionHandler: { (error) in
            if let e = error {
                Cache.log.error("WebRTCClient.handleRemoteAnswerDescription failure: %@", e.localizedDescription)
                if self.linia2Established {
                    DispatchQueue.main.async { self.delegate?.linia2NegotiationFailed("remoteAnswer") }
                } else {
                    self.delegate?.closeCall()
                }
                return
            }
            self.remoteAnswerApplied = true
            self.markRemoteDescriptionApplied()
            self.delegate?.markConnectionSetupComplete()
            DispatchQueue.main.async { self.delegate?.linia2NegotiationDone(remoteOffer: false) }
        })
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        switch stateChanged {
        case .closed:
            self.delegate?.closeCall()
        case .stable:
            self.delegate?.enableMediaControls()
        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Cache.log.info("WebRTCClient: Received remote stream %@", stream)
        onDiagEvent?(["type": "track", "kind": stream.videoTracks.isEmpty ? "audio" : "audio+video",
                      "audio": stream.audioTracks.count, "video": stream.videoTracks.count])
        self.delegate?.handleRemoteStream(self, receivedStream: stream)
    }

    /// LINIA2 (Unified Plan): удалённые треки приходят сюда (didAdd stream — только в Plan B).
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        let kind = rtpReceiver.track?.kind ?? "?"
        onDiagEvent?(["type": "track", "kind": kind, "streams": mediaStreams.count])
        guard let stream = mediaStreams.first else { return }
        // Видео подключаем к экрану, когда пришёл видеотрек; аудио играет само.
        if rtpReceiver.track is RTCVideoTrack {
            self.delegate?.handleRemoteStream(self, receivedStream: stream)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Cache.log.info("WebRTCClient: Removed media stream %@", stream)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        // LINIA2: решение принимаем на главном потоке (там же создаются соединение и первый offer).
        DispatchQueue.main.async {
            guard self.localPeer === peerConnection, peerConnection.signalingState == .stable,
                  let d = self.delegate, d.canSendOffer(), !peerConnection.senders.isEmpty else { return }
            if d.linia2IsCaller {
                if !self.initialOfferSent {
                    self.makeInitialOffer()
                    return
                }
                // Перенастройка — только после того, как первый обмен offer/answer завершён.
                guard self.remoteAnswerApplied else { return }
            }
            Cache.log.info("WebRTCClient: negotiating connection")
            self.offer(peerConnection)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onDiagEvent?(["type": "ice", "state": Self.iceName(newState)])
        if newState == .connected || newState == .completed { linia2Established = true }
        if newState == .connected || newState == .failed {
            let r = newState == .connected ? "connected" : "failed"
            DispatchQueue.main.async { [weak self] in self?.diagReportPair(r) }
        }
        // LINIA2: состояние — экрану звонка (переподключение при обрыве, ICE restart).
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.localPeer === peerConnection else { return }
            self.delegate?.linia2IceStateChanged(newState)
        }
        linia2HandleIceState(newState)
    }

    /// Общая реакция на состояние ICE (нативный движок и движок WKWebView).
    func linia2HandleIceState(_ newState: RTCIceConnectionState) {
        switch newState {
        case .closed:
            self.delegate?.closeCall()
        case .failed:
            // LINIA2: соединённый звонок при обрыве не завершаем — экран звонка делает ICE restart и ждёт до 30 с.
            // Не соединился ни разу — как раньше, завершаем.
            if !linia2Established { self.delegate?.closeCall() }
        case .connected, .completed:
            // LINIA2: соединение установлено — экран звонка показывает «Идёт звонок» и таймер.
            DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallConnected, object: nil) }
        case .disconnected:
            // Связь прервалась (WebRTC пытается восстановить) — «Плохая связь».
            DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallUnstable, object: nil) }
        default:
            break
        }
    }

    // MARK: События движка WKWebView (главный поток)

    func linia2WebIceState(_ name: String) {
        let map: [String: RTCIceConnectionState] = ["new": .new, "checking": .checking, "connected": .connected,
                                                    "completed": .completed, "failed": .failed,
                                                    "disconnected": .disconnected, "closed": .closed]
        guard web != nil, let st = map[name] else { return }
        onDiagEvent?(["type": "ice", "state": name, "engine": "web"])
        if st == .connected || st == .completed { linia2Established = true }
        delegate?.linia2IceStateChanged(st)
        linia2HandleIceState(st)
    }

    /// Ответ применён (звонящий) или наш answer отправлен (принимающий).
    func linia2WebSetupComplete(remoteOffer: Bool) {
        guard web != nil else { return }
        if !remoteOffer { remoteAnswerApplied = true }
        delegate?.markConnectionSetupComplete()
        DispatchQueue.main.async { self.delegate?.linia2NegotiationDone(remoteOffer: remoteOffer) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let names: [RTCPeerConnectionState: String] = [.new: "new", .connecting: "connecting", .connected: "connected",
                                                       .disconnected: "disconnected", .failed: "failed", .closed: "closed"]
        onDiagEvent?(["type": "conn", "state": names[newState] ?? "\(newState.rawValue)"])
    }

    static func iceName(_ s: RTCIceConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return "\(s.rawValue)"
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Cache.log.info("WebRTCClient: ice rtc gathering state - %d", newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Cache.log.info("WebRTCClient: new local ice candidate %@", candidate)
        let k = Self.candKind(candidate.sdp)
        diagLock.lock(); diagLocalCands[k, default: 0] += 1; diagLock.unlock()
        self.delegate?.sendIceCandidate(candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Cache.log.info("WebRTCClient: removed ice candidates %@", candidates)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Cache.log.info("WebRTCClient: opened data channel %@", dataChannel)
        self.localDataChannel = dataChannel
        self.localDataChannel!.delegate = self
    }
}

extension RTCSessionDescription {
    func serialize() -> JSONValue? {
        let typeStr = RTCSessionDescription.string(for: self.type)
        let dict = ["type": JSONValue.string(typeStr),
                    "sdp": JSONValue.string(self.sdp)]
        return .dict(dict)
    }

    static func deserialize(from dict: [String: JSONValue]) -> RTCSessionDescription? {
        guard let type = dict["type"]?.asString(), let sdp = dict["sdp"]?.asString() else {
            return nil
        }
        return RTCSessionDescription(type: RTCSessionDescription.type(for: type), sdp: sdp)
    }
}

extension RTCIceCandidate {
    func serialize() -> JSONValue? {
        var dict = ["type": JSONValue.string("candidate"),
                    "sdpMLineIndex": JSONValue.int(Int(self.sdpMLineIndex)),
                    "candidate": JSONValue.string(self.sdp)
        ]
        if let sdpMid = self.sdpMid {
            dict["sdpMid"] = JSONValue.string(sdpMid)
        }
        return .dict(dict)
    }

    static func deserialize(from dict: [String: JSONValue]) -> RTCIceCandidate? {
        guard let sdp = dict["candidate"]?.asString() else {
            return nil
        }
        let idx = dict["sdpMLineIndex"]?.asInt()
        let sdpMid = dict["sdpMid"]?.asString()
        return RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(idx ?? 0), sdpMid: sdpMid)
    }
}


/// CallViewController
/// LINIA2: экран звонка «как на iPhone» в стиле Линии 2.0 (тёмный фон, круглые кнопки с подписями).
/// Показывается модально (fullScreen); «Чат» сворачивает его в зелёную плашку «Идёт звонок» (Linia2CallCenter),
/// звонок при этом продолжается. Звонок завершают только «Завершить», собеседник или сервер.
class CallViewController: UIViewController {
    private enum Constants {
        static let kDialingAnimationDuration: Double = 1.5
        static let kDialingAnimationColor = UIColor(red: 0x7E/255.0, green: 0xE0/255.0, blue: 0xC3/255.0, alpha: 1).cgColor
    }

    enum CallDirection {
        case none
        case outgoing
        case incoming
    }

    @IBOutlet weak var remoteView: UIView!
    @IBOutlet weak var localView: UIView!

    @IBOutlet weak var localViewHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var localViewWidthConstraint: NSLayoutConstraint!

    @IBOutlet weak var speakerToggleButton: UIButton!
    @IBOutlet weak var micToggleButton: UIButton!
    @IBOutlet weak var videoToggleButton: UIButton!
    @IBOutlet weak var hangUpButton: UIButton!

    @IBOutlet weak var peerNameLabel: PaddedLabel!
    @IBOutlet weak var peerAvatarImageView: RoundImageView!
    @IBOutlet weak var peerNameRemoteVideoLabel: PaddedLabel!

    @IBOutlet weak var dialingAnimationContainer: UIView!

    weak var topic: DefaultComTopic? {
        didSet { if let t = topic { strongTopic = t } }
    }
    /// Звонок может идти при свёрнутом экране — держим топик сами.
    private var strongTopic: DefaultComTopic?
    let cameraManager = CameraManager()
    let webRTCClient = WebRTCClient()
    // Peer messasges listener.
    var listener: InfoListener!

    var remoteRenderer: RTCVideoRenderer?

    var callDirection: CallDirection = .none
    var callSeqId: Int = -1
    var isAudioOnlyCall: Bool = false
    // If true, the client has received a remote SDP from the peer and has sent a local SDP to the peer.
    var callInitialSetupComplete = false
    // Audio output destination (.none = default).
    var audioOutput: AVAudioSession.PortOverride = .none
    /// LINIA2: датчик приближения должен быть включён (в симуляторе датчика нет — для автотестов).
    var linia2ProximityWanted = false
    // Audio route change notification observer.
    var routeChangeObserver: NSObjectProtocol?
    // For playing sound effects.
    var audioPlayer: AVAudioPlayer?

    // LINIA2: состояние экрана и звонка.
    private(set) var started = false
    private(set) var closed = false
    /// Этот экран владеет звонком в CallManager (иначе закрытие не трогает чужой звонок).
    private var ownsCall = false
    private(set) var connectedAt: Date?
    private(set) var isPoorConnection = false
    private var unstableUntil: Date?
    private(set) var isHeld = false
    private var isMuted = false
    private var heldRestore: (audio: Bool, video: Bool)?
    private var remoteVideoLive = false
    private var observers: [NSObjectProtocol] = []
    private var uiTimer: Timer?
    private var lastStats: (lost: Double, received: Double)?
    private var lastStatsPoor = false
    private var micDenied = false
    private var linia2MicObserver = false
    private var cameraDenied = false
    let stateLabel = UILabel()
    let flipButton = UIButton(type: .system)
    let backButton = UIButton(type: .system)
    private var captions: [UIButton: UILabel] = [:]
    private var routePicker: UIView?
    private var pip: AnyObject?
    /// LINIA2: диагностика звонка на сервер (/invite/api/call-diag).
    private(set) var diag: Linia2CallDiag?

    // LINIA2: переподключение при смене сети / обрыве (как в Telegram/WhatsApp): звонок держится до kReconnectGrace с,
    // на экране «Переподключение…»; не восстановилось — «Связь потеряна».
    static let kReconnectGrace: TimeInterval = 30
    /// Начало текущего переподключения (nil — связь в порядке).
    private(set) var reconnectingSince: Date?
    /// Нет связи с сервером Tinode (веб-сокет закрыт или топик ещё не подписан заново).
    private var wsDown = false
    /// Медиапуть потерян (ICE disconnected/failed, сменилась сеть) — до успешного ICE restart.
    private var iceDown = false
    /// Нужно сделать ICE restart, как только будет связь с сервером.
    private var needIceRestart = false
    /// Наш ICE restart offer отправлен, ждём answer.
    private var iceRestartPending = false
    private var lastIceRestartAt: Date?
    private var iceRestartAttempts = 0
    private var iceDisconnectedAt: Date?
    private var reconnectTimer: Timer?
    private var reconnectTicks = 0
    private var resubscribing = false
    private(set) var connectionLost = false
    private var pathMonitor: NWPathMonitor?
    private var lastPathKey: String?

    class InfoListener: TinodeEventListener {
        private weak var delegate: TinodeVideoCallDelegate?
        init(delegateEventsTo callDelegate: TinodeVideoCallDelegate) {
            self.delegate = callDelegate
        }

        func onInfoMessage(info: MsgServerInfo?) {
            guard let info = info, self.delegate?.eventMatchesCallInProgress(info: info) ?? false else { return }
            switch info.event {
            case "accept":
                DispatchQueue.main.async { self.delegate?.handleAcceptedMsg() }
            case "offer":
                DispatchQueue.main.async { self.delegate?.handleOfferMsg(with: info.payload) }
            case "answer":
                DispatchQueue.main.async { self.delegate?.handleAnswerMsg(with: info.payload) }
            case "ice-candidate":
                DispatchQueue.main.async { self.delegate?.handleIceCandidateMsg(with: info.payload) }
            case "hang-up":
                DispatchQueue.main.async { self.delegate?.handleRemoteHangup() }
            case "ringing":
                DispatchQueue.main.async { self.delegate?.handleRinging() }
            default:
                debugPrint(info)
            }
        }

        // LINIA2: обрыв и восстановление связи с сервером — звонок не завершаем (см. «Переподключение»).
        func onDisconnect(byServer: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String) {
            DispatchQueue.main.async { self.delegate?.linia2SignalingDown(reason: reason) }
        }

        func onLogin(code: Int, text: String) {
            DispatchQueue.main.async { self.delegate?.linia2SignalingLoggedIn(code: code) }
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        self.audioOutput = self.isAudioOnlyCall ? .none : .speaker
        self.listener = InfoListener(delegateEventsTo: self)
        if callDirection == .incoming { ownsCall = true }
        Linia2CallCenter.shared.register(self)
        linia2BuildLayout()
        linia2SetupCallStatus()

        if let topic = topic {
            peerNameLabel.text = topic.pub?.fn ?? "Собеседник"
            peerNameRemoteVideoLabel.text = peerNameLabel.text
            peerAvatarImageView.set(pub: topic.pub, id: topic.name, deleted: false)
            // Гостевой звонок по ссылке — имя гостя и название ссылки.
            if Linia2GuestLinks.isGuest(topic.name), let g = Linia2GuestLinks.cachedInfo(seq: callSeqId) {
                peerNameLabel.text = g.name
                peerNameLabel.accessibilityValue = g.link.isEmpty ? "по ссылке" : "по ссылке «\(g.link)»"
            }
        }
        linia2UpdateButtons()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        linia2StartIfNeeded()
        if let w = webRTCClient.web, !closed {
            w.attach(to: view, below: remoteView)
            linia2UpdateWebLayout()
        }
        linia2UpdateRoute()
        linia2UpdateProximity()
        Linia2CallCenter.shared.refreshBanner()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        linia2UpdateWebLayout()
    }

    /// Движок WKWebView: положение своего видео — по окну localView.
    func linia2UpdateWebLayout() {
        guard let w = webRTCClient.web, !closed, let wv = w.webView, wv.superview === view else { return }
        w.setLocalRect(localView.isHidden ? nil : localView.convert(localView.bounds, to: wv))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Свёрнут — страница движка WKWebView уходит в окно приложения (вне окна WebKit останавливает медиа).
        if !closed { webRTCClient.web?.park() }
        linia2UpdateProximity()   // свёрнут — экран не гасить
        // Свёрнут — показать плашку «Идёт звонок».
        Linia2CallCenter.shared.refreshBanner()
        // Экран звонка закрыт — нижнее меню снова видно (под модальным окном оно прячется).
        DispatchQueue.main.async { Linia2TabBarController.current?.updateBarVisibility(animated: true) }
    }

    /// Запуск звонка — один раз (экран может быть свёрнут и открыт снова).
    /// Вызывается и без показа экрана: звонок, принятый на заблокированном экране.
    func linia2StartIfNeeded() {
        guard !started, !closed else { return }
        started = true
        loadViewIfNeeded()
        let d = Linia2CallDiag(topic: topic?.name ?? "", seq: { [weak self] in self?.callSeqId ?? 0 }, client: webRTCClient)
        diag = d
        webRTCClient.onDiagEvent = { [weak d] ev in d?.add(ev) }
        d.stateProvider = { [weak self] in
            guard let self = self else { return [:] }
            return ["rc": self.reconnectingSince != nil ? 1 : 0, "wsDown": self.wsDown ? 1 : 0, "iceDown": self.iceDown ? 1 : 0]
        }
        let st = UIApplication.shared.applicationState
        d.start(["dir": callDirection == .outgoing ? "out" : "in", "audioOnly": isAudioOnlyCall,
                 "app": st == .active ? "active" : (st == .background ? "background" : "inactive"),
                 "mic": AVAudioSession.sharedInstance().recordPermission == .granted ? "granted" : "no",
                 "connected": Cache.tinode.isConnected, "attached": topic?.attached ?? false,
                 "rtcAudio": RTCAudioSession.sharedInstance().isAudioEnabled,
                 "ua": "iOS " + UIDevice.current.systemVersion])
        self.permissionsCheck { result in
            DispatchQueue.main.async {
                switch result {
                case .ok:
                    break
                case .micUndetermined, .micDenied:
                    // Звонок не обрываем: можно слушать; собеседник вас не слышит, пока не разрешите микрофон.
                    Cache.log.error("No permission to access microphone")
                    self.micDenied = true
                    self.linia2ShowMicCard(denied: result == .micDenied)
                case .cameraDenied:
                    // Видео без своей камеры: собеседника видно, вас — нет.
                    Cache.log.error("No permission to access camera")
                    self.cameraDenied = true
                    self.linia2PermissionHint("Нет доступа к камере — собеседник вас не видит. Разрешите доступ в Настройках iPhone.")
                }
                self.setupCaptureSessionAndStartCall()
            }
        }
    }

    /// Подсказка о доступе (звонок продолжается) с кнопкой «Настройки».
    private func linia2PermissionHint(_ text: String) {
        let hint = UIButton(type: .system)
        hint.setTitle(text + " Открыть Настройки", for: .normal)
        hint.titleLabel?.numberOfLines = 0
        hint.titleLabel?.textAlignment = .center
        hint.titleLabel?.font = L2.font(14, .medium)
        hint.setTitleColor(.white, for: .normal)
        hint.backgroundColor = L2.hex(0xB5462F, 0.92)
        hint.layer.cornerRadius = 14
        hint.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        hint.accessibilityIdentifier = "l2.call.permissionHint"
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.addAction(UIAction { _ in
            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        }, for: .touchUpInside)
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    // MARK: Кнопки

    @IBAction func didToggleSpeaker(_ sender: Any) {
        let newOutput: AVAudioSession.PortOverride = self.audioOutput == .speaker ? .none : .speaker
        Cache.log.info("User requested overridde audio output port to %d", newOutput.rawValue)
        // Выбор запоминаем сразу: если сессия ещё не активна (дозвон, CallKit), он применится в didActivate.
        self.audioOutput = newOutput
        CallManager.setOutputPort(newOutput)
        linia2UpdateRoute()
        linia2UpdateProximity()
    }

    /// Датчик приближения (у уха экран гаснет): только аудиозвонок, разговорный динамик, без камеры и наушников,
    /// экран звонка на виду. Иначе — выключен (громкая связь, видео, свёрнутый звонок, завершение).
    func linia2UpdateProximity() {
        let on = isAudioOnlyCall && started && !closed && audioOutput != .speaker && !cameraManager.isCapturing
            && isViewLoaded && view.window != nil && !Linia2CallCenter.hasExternalOutput()
        if UIDevice.current.isProximityMonitoringEnabled != on { UIDevice.current.isProximityMonitoringEnabled = on }
        linia2ProximityWanted = on
        linia2UpdateRoute()
    }

    @IBAction func didToggleMic(_ sender: Any) {
        setMuted(!isMuted)
        Cache.callManager.setMutedInSystem(isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        // Сначала кнопка (вид и подпись), потом трек: включение/выключение трека WebRTC синхронно ждёт
        // свой поток и не должно задерживать отклик кнопки.
        linia2UpdateButtons()
        if !isHeld { webRTCClient.setAudioEnabled(!muted) } else { heldRestore?.audio = !muted }
    }

    /// «Камера»: состояние, вид и подпись кнопки меняются сразу по нажатию; запуск/остановка сессии камеры —
    /// в фоне по порядку (CameraManager.sessionQueue). Раньше кнопка выключалась до завершения startRunning/
    /// stopRunning в фоновой очереди .background — это занимало секунды, нажатие «не срабатывало».
    @IBAction func didToggleCamera(_ sender: Any) {
        if cameraManager.isCapturing {
            cameraManager.stopCapture()
            localView.isHidden = true
            webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventMuted)
        } else {
            localView.isHidden = false
            cameraManager.startCapture { [weak self] in
                // Собеседнику «видео есть» — когда камера действительно запущена (и её не выключили снова).
                DispatchQueue.main.async {
                    guard let self = self, !self.closed, self.cameraManager.isCapturing, !self.isHeld else { return }
                    self.webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventUnmuted)
                }
            }
        }
        linia2UpdateButtons()
        linia2UpdateProximity()
        linia2UpdateWebLayout()
    }

    @objc func didTapFlip() {
        cameraManager.switchCamera()
        UIView.transition(with: localView, duration: 0.3, options: .transitionFlipFromLeft, animations: nil)
    }

    /// «Чат»: свернуть экран звонка, звонок продолжается (сверху — плашка «Идёт звонок»).
    @objc func didTapBack() {
        Linia2CallCenter.shared.minimize()
    }

    @IBAction func didTapHangUp(_ sender: Any) {
        self.handleCallClose()
    }

    // MARK: Запуск

    private func setupCaptureSessionAndStartCall() {
        // LINIA2 (вариант Б): звонковый движок WKWebView — по флагу удалённого конфига features.webCallEngine.
        // Выбор движка — ДО accept/offer (сигнализация ещё не началась, переключать нечего).
        if Linia2WebCallEngine.enabled && !linia2EngineChosen {
            linia2ChooseEngine { [weak self] in self?.setupCaptureSessionAndStartCall() }
            return
        }
        cameraManager.web = webRTCClient.web
        Linia2TestProbe.callEngine = webRTCClient.isWebEngine ? 2 : 1
        cameraManager.setupCamera()
        if !self.isAudioOnlyCall && !cameraDenied {
            cameraManager.startCapture()
        }
        setupViews()

        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: handleRouteChange)

        webRTCClient.delegate = self
        cameraManager.delegate = self
        Cache.tinode.addListener(self.listener)
        linia2StartPathMonitor()
        // Prevent screen from dimming/going to sleep.
        UIApplication.shared.isIdleTimerDisabled = true
        // LINIA2: аудиозвонок у уха — экран гаснет (датчик приближения).
        linia2UpdateProximity()

        if let topic = self.topic {
            if !topic.attached {
                topic.subscribe().then(
                    onSuccess: { [weak self] msg in
                        if let ctrl = msg?.ctrl, ctrl.code < 300 {
                            self?.handleCallInvite()
                        } else {
                            self?.handleCallClose()
                        }
                        return nil
                    },
                    onFailure: { [weak self] err in
                        self?.handleCallClose()
                        return nil
                    })
            } else {
                self.handleCallInvite()
            }
        } else {
            self.handleCallClose()
        }
    }

    private func checkMicPermissions(completion: @escaping ((Bool) -> Void)) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            completion(granted)
        }
    }

    private func checkCameraPermissions(completion: @escaping ((Bool) -> Void)) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)  // success
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            fallthrough
        @unknown default:
            completion(false)  // failure
        }
    }

    private enum PermissionsCheckResult {
        case ok
        case micUndetermined
        case micDenied
        case cameraDenied
    }

    private func permissionsCheck(completion: @escaping (PermissionsCheckResult) -> Void) {
        // LINIA2: разрешение уже есть — не спрашиваем; не спрашивали — свой экран «Разрешить микрофон»;
        // запрещено — инструкция «Настройки → Линия 2.0 → Микрофон».
        let mic = AVAudioSession.sharedInstance().recordPermission
        let micResult: PermissionsCheckResult = mic == .granted ? .ok : (mic == .undetermined ? .micUndetermined : .micDenied)
        if self.isAudioOnlyCall {
            completion(micResult)
            return
        }
        self.checkCameraPermissions { success in
            if micResult != .ok {
                if !success { self.cameraDenied = true }
                completion(micResult)
            } else {
                completion(success ? .ok : .cameraDenied)
            }
        }
    }

    // MARK: LINIA2: доступ к микрофону во время звонка

    private static let kMicCardTag = 0x4C324D43
    private static let kMicPillTag = 0x4C324D50

    /// Карточка: «Разрешить микрофон» (не спрашивали) или «Открыть настройки» / «Проверить снова» (запрещено).
    func linia2ShowMicCard(denied: Bool) {
        view.viewWithTag(Self.kMicCardTag)?.removeFromSuperview()
        linia2ShowMicPill()
        let card = UIView()
        card.tag = Self.kMicCardTag
        card.backgroundColor = L2.hex(0x1B2133, 0.97)
        card.layer.cornerRadius = 20
        card.accessibilityIdentifier = "l2.call.micCard"
        let icon = UIImageView(image: L2.symbol(denied ? "mic.slash.fill" : "mic.fill", 30, .semibold))
        icon.tintColor = denied ? L2.danger : L2.accent
        icon.contentMode = .center
        let title = UILabel()
        title.numberOfLines = 0
        title.textAlignment = .center
        title.font = L2.font(17, .semibold)
        title.textColor = .white
        title.text = denied ? L2T("l2.call.micDeniedTitle", "Доступ к микрофону запрещён")
                            : L2T("l2.call.micAsk", "Разрешите доступ к микрофону, чтобы собеседник вас слышал")
        let text = UILabel()
        text.numberOfLines = 0
        text.textAlignment = .center
        text.font = L2.font(15)
        text.textColor = UIColor.white.withAlphaComponent(0.75)
        text.text = denied ? L2T("l2.call.micDeniedText", "Откройте Настройки → Линия 2.0 → Микрофон и включите доступ.") : nil
        text.isHidden = !denied
        var buttons: [UIView] = []
        if denied {
            let open = L2Button(L2T("l2.call.openSettings", "Открыть настройки"))
            open.accessibilityIdentifier = "l2.call.micSettings"
            open.addAction(UIAction { _ in
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }, for: .touchUpInside)
            let check = L2Button(L2T("l2.call.checkAgain", "Проверить снова"), kind: .secondary)
            check.accessibilityIdentifier = "l2.call.micCheck"
            check.addAction(UIAction { [weak self] _ in self?.linia2RecheckMic(toast: true) }, for: .touchUpInside)
            buttons = [open, check]
        } else {
            let allow = L2Button(L2T("l2.call.micAllow", "Разрешить микрофон"), symbol: "mic.fill")
            allow.accessibilityIdentifier = "l2.call.micAllow"
            allow.addAction(UIAction { [weak self] _ in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted { self?.linia2MicGranted() } else { self?.linia2ShowMicCard(denied: true) }
                    }
                }
            }, for: .touchUpInside)
            buttons = [allow]
        }
        let listen = UIButton(type: .system)
        listen.setTitle(L2T("l2.call.listenOnly", "Только слушать"), for: .normal)
        listen.setTitleColor(UIColor.white.withAlphaComponent(0.8), for: .normal)
        listen.titleLabel?.font = L2.font(15, .medium)
        listen.accessibilityIdentifier = "l2.call.micListen"
        listen.addAction(UIAction { [weak card] _ in card?.removeFromSuperview() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, title, text] + buttons + [listen])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
        if denied && !linia2MicObserver {
            linia2MicObserver = true
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.linia2RecheckMic(toast: false)
            })
        }
    }

    /// Плашка «Вас не слышно — разрешите микрофон» (нажатие — снова карточка).
    private func linia2ShowMicPill() {
        guard view.viewWithTag(Self.kMicPillTag) == nil else { return }
        let pill = UIButton(type: .system)
        pill.tag = Self.kMicPillTag
        pill.setTitle("🎙 " + L2T("l2.call.micPill", "Вас не слышно — разрешите микрофон"), for: .normal)
        pill.titleLabel?.numberOfLines = 0
        pill.titleLabel?.textAlignment = .center
        pill.titleLabel?.font = L2.font(14, .medium)
        pill.setTitleColor(.white, for: .normal)
        pill.backgroundColor = L2.hex(0xB5462F, 0.92)
        pill.layer.cornerRadius = 14
        pill.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        pill.accessibilityIdentifier = "l2.call.micPill"
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addAction(UIAction { [weak self] _ in
            self?.linia2ShowMicCard(denied: AVAudioSession.sharedInstance().recordPermission == .denied)
        }, for: .touchUpInside)
        view.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 14),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
        ])
    }

    private func linia2RecheckMic(toast: Bool) {
        guard micDenied, !closed else { return }
        if AVAudioSession.sharedInstance().recordPermission == .granted {
            linia2MicGranted()
        } else if toast {
            UiUtils.showToast(message: L2T("l2.call.micStillDenied", "Доступа к микрофону всё ещё нет"), level: .info)
        }
    }

    /// Разрешили посреди звонка: включить запись звука.
    private func linia2MicGranted() {
        micDenied = false
        view.viewWithTag(Self.kMicCardTag)?.removeFromSuperview()
        view.viewWithTag(Self.kMicPillTag)?.removeFromSuperview()
        if CallManager.linia2WebAudio {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            CallManager.setOutputPort(self.audioOutput)
            webRTCClient.web?.call("audioResume", ["reason": "mic-granted"])
        } else { CallManager.audioSessionChange { s in
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            if s.useManualAudio && s.isAudioEnabled {
                s.isAudioEnabled = false   // перезапуск аудиомодуля WebRTC — теперь с микрофоном
                s.isAudioEnabled = true
            }
            try? s.overrideOutputAudioPort(self.audioOutput)
        } }
        if !isHeld { webRTCClient.setAudioEnabled(!isMuted) }
        linia2UpdateButtons()
    }

    @objc func handleRouteChange(notification: Notification) {
        guard let info = notification.userInfo,
            let value = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }

        switch reason {
        case .categoryChange, .oldDeviceUnavailable:
            // Наушники отключили / категория сменилась — вернуть выбранный выход (динамик или трубка).
            if !Linia2CallCenter.hasExternalOutput() {
                Cache.log.info("Audio route change: restoring audio output to %d", self.audioOutput.rawValue)
                CallManager.setOutputPort(self.audioOutput)
            }
        case .newDeviceAvailable:
            // Подключили AirPods / гарнитуру — звук идёт в них (как на iPhone), динамик выключается.
            self.audioOutput = .none
        default:
            Cache.log.debug("CallVC - audio route change: other - %@, reason: %d", value.description, reason.rawValue)
        }
        DispatchQueue.main.async {
            self.linia2UpdateRoute()
            self.linia2UpdateProximity()
        }
    }

    func setupViews() {
        #if arch(arm64)
            // Using metal (arm64 only)
            let localRenderer = RTCMTLVideoView(frame: self.localView.frame)
            let remoteRenderer = RTCMTLVideoView(frame: self.remoteView.frame)
            localRenderer.videoContentMode = .scaleAspectFill
            remoteRenderer.videoContentMode = .scaleAspectFill
        #else
            // Using OpenGLES for the rest
            let localRenderer = RTCEAGLVideoView(frame: self.localView.frame)
            let remoteRenderer = RTCEAGLVideoView(frame: self.remoteView.frame)
        #endif

        webRTCClient.setup()
        webRTCClient.setupLocalRenderer(localRenderer)
        if let w = webRTCClient.web {
            // Видео собеседника и своё окошко рисует страница (под затемнением и кнопками); нативные окна — пустые.
            localView.backgroundColor = .clear
            w.attach(to: view, below: remoteView)
            linia2UpdateWebLayout()
        }

        self.embedView(localRenderer, into: localView)
        self.embedView(remoteRenderer, into: remoteView)

        self.remoteRenderer = remoteRenderer
        if self.isAudioOnlyCall {
            remoteView.isHidden = true
            peerNameRemoteVideoLabel.isHidden = true
        localView.isHidden = isAudioOnlyCall
            localView.isHidden = true
        }
    }

    func stopMedia() {
        // Allow screen dimming/going to sleep.
        UIApplication.shared.isIdleTimerDisabled = false
        UIDevice.current.isProximityMonitoringEnabled = false
        linia2ProximityWanted = false

        if #available(iOS 15.0, *), let pip = self.pip as? Linia2CallPiP {
            webRTCClient.removeRemoteRenderer(pip.renderer)
            pip.stop()
        }
        self.pip = nil
        self.webRTCClient.disconnect()
        cameraManager.stopCapture()
        if let observer = self.routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            self.routeChangeObserver = nil
        }
    }

    /// Завершить звонок и закрыть экран (в том числе свёрнутый). Повторные вызовы игнорируются.
    /// LINIA2: всё локально и мгновенно — сигнал «hang-up» серверу уходит первым (без ожидания ответа),
    /// экран закрывается без анимации, звук выключается, CallKit завершается, pc.close() — в фоне.
    /// `remoteEnded` — завершила другая сторона: серверу ничего не шлём, CallKit — reportCall(.remoteEnded).
    func handleCallClose(remoteEnded: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleCallClose(remoteEnded: remoteEnded) }
            return
        }
        guard !closed else { return }
        closed = true
        let closeStarted = Date()
        // 1. Сигнал собеседнику — сразу (note по веб-сокету, ответа не ждём).
        if ownsCall && !remoteEnded && self.callSeqId > 0 {
            self.topic?.videoCall(event: "hang-up", seq: self.callSeqId)
        }
        // 2. Микрофон/камера — выключить сейчас же.
        webRTCClient.linia2MuteAllForClose()
        let rtc = RTCAudioSession.sharedInstance()
        if !CallManager.linia2WebAudio && rtc.useManualAudio && rtc.isAudioEnabled { rtc.isAudioEnabled = false }
        // 3. Экран — закрыть немедленно (без анимации).
        Linia2CallCenter.shared.callDidEnd(self)
        if let presenter = self.presentingViewController {
            // Через presenter — закрывается и экран звонка, и то, что поверх него (алерт, меню выхода звука).
            presenter.dismiss(animated: false)
        } else if let nav = self.navigationController {
            nav.popViewController(animated: false)
        }
        Linia2TestProbe.lastHangupCloseMs = Int(Date().timeIntervalSince(closeStarted) * 1000)
        diag?.add(["type": "close", "ms": Linia2TestProbe.lastHangupCloseMs, "remote": remoteEnded ? 1 : 0])
        diag?.end(connectionLost ? "connection-lost" : (connectedAt != nil ? "connected" : "not-connected"))
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        playSoundEffect(nil)
        uiTimer?.invalidate()
        uiTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        if ownsCall {
            // 4. CallKit: наш отбой — CXEndCallAction (fulfill сразу); отбой собеседника — reportCall(.remoteEnded).
            if remoteEnded, let name = self.topic?.name {
                Cache.callManager.endCallInProgressRemotely(topic: name, why: "vc-remote")
            }
            // Запасной путь (или наш отбой): звонок не должен остаться «идущим».
            Cache.callManager.completeCallInProgress(reportToSystem: true, reportToPeer: false)
        }
        self.callSeqId = -1
        Cache.tinode.removeListener(self.listener)
        // 5. Медиа: остановка захвата, pc.close() — в фоне (WebRTCClient.disconnect).
        stopMedia()
    }

    func handleCallInvite() {
        switch self.callDirection {
        case .outgoing:
            guard Cache.callManager.registerOutgoingCall(onTopic: self.topic!.name, isAudioOnly: self.isAudioOnlyCall, peerName: self.topic?.pub?.fn) else {
                UiUtils.showToast(message: "Уже идёт другой звонок")
                self.handleCallClose()
                return
            }
            ownsCall = true
            playSoundEffect("dialing")
            // Send out a call invitation to the peer.
            self.topic?.publish(content: Drafty.videoCall(),
                                withExtraHeaders:["webrtc": .string(MsgServerData.WebRTC.kStarted.rawValue),
                                                  "aonly": .bool(self.isAudioOnlyCall)]).then(onSuccess: { msg in
                guard let ctrl = msg?.ctrl else { return nil }
                if ctrl.code < 300, let seq = ctrl.getIntParam(for: "seq"), seq > 0 {
                    // All good. Register the call.
                    self.callSeqId = seq
                    Cache.callManager.updateOutgoingCall(withNewSeqId: seq)
                    return nil
                }
                self.handleCallClose()
                return nil
            },
            onFailure: UiUtils.ToastFailureHandler)
        case .incoming:
            // LINIA2: соединение (ICE-серверы, микрофон) готовим ДО «accept» — offer собеседника приходит
            // через доли секунды и обрабатывается сразу (раньше pc и TURN создавались только по приходу offer).
            if !self.webRTCClient.createPeerConnection(withDataChannel: false) {
                Cache.log.error("CallVC.handleCallInvite - early createPeerConnection failed, will retry on offer")
            }
            // The callee (we) has accepted the call. Notify the caller.
            diag?.add(["type": "accept-sent"])
            self.topic?.videoCall(event: "accept", seq: self.callSeqId)
            if !self.isAudioOnlyCall {
                DispatchQueue.main.async {
                    self.linia2SetAvatarVisible(false)
                }
            }
        case .none:
            Cache.log.error("CallVC - Invalid call direction in handleCallInvite()")
        }
    }

    private func playSoundEffect(_ effect: String?, loop: Bool = false) {
        audioPlayer?.stop()

        guard let effect = effect else {
            return
        }

        guard let path = Bundle.main.path(forResource: "\(effect).m4a", ofType: nil) else { return }
        let url = URL(fileURLWithPath: path)

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = loop ? -1 : 0
            audioPlayer?.play()
        } catch {
            Cache.log.error("CallVC - Unable to play sound effect '%@': %@", effect, error.localizedDescription)
        }
    }

    private func dialingAnimation(on: Bool) {
        if on {
            self.addDialingRipple(offset: 10, opacity: 0.4)
            self.addDialingRipple(offset: 30, opacity: 0.2)
            self.addDialingRipple(offset: 60, opacity: 0.1)
        } else {
            self.dialingAnimationContainer.layer.sublayers = nil
        }
    }

    private func addDialingRipple(offset: CGFloat, opacity: Float) {
        let diameter: CGFloat = dialingAnimationContainer.bounds.width
        guard diameter > 0 else { return }

        let layerRipple = CAShapeLayer()
        layerRipple.frame = dialingAnimationContainer.bounds
        layerRipple.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: dialingAnimationContainer.frame.size)).cgPath
        layerRipple.fillColor = Constants.kDialingAnimationColor
        layerRipple.opacity = opacity

        dialingAnimationContainer.layer.addSublayer(layerRipple)

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.duration = Constants.kDialingAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.repeatCount = .infinity
        animation.fromValue = 1.0
        animation.toValue = (diameter + offset) / diameter

        layerRipple.add(animation, forKey: nil)
    }
}

extension CallViewController {
    func embedView(_ addingView: UIView, into containerView: UIView) {
        addingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addingView.frame = containerView.bounds
        containerView.addSubview(addingView)
        containerView.layoutIfNeeded()
    }
}

extension CallViewController: CameraCaptureDelegate {
    func captureVideoOutput(sampleBuffer: CMSampleBuffer) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let rtcpixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
            let timeStampNs: Int64 = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000000000)
            let videoFrame = RTCVideoFrame(buffer: rtcpixelBuffer, rotation: RTCVideoRotation._0, timeStampNs: timeStampNs)

            webRTCClient.didCaptureLocalFrame(videoFrame)
        }
    }
}

extension CallViewController: WebRTCClientDelegate {
    func sendOffer(withDescription sdp: RTCSessionDescription) {
        webRTCClient.diagLocalUfrag = WebRTCClient.ufrag4(sdp.sdp)
        diag?.add(["type": "offer-sent", "seq": self.callSeqId, "ufrag": WebRTCClient.ufrag4(sdp.sdp)])
        self.topic?.videoCall(event: "offer", seq: self.callSeqId, payload: sdp.serialize())
    }

    func sendAnswer(withDescription sdp: RTCSessionDescription) {
        webRTCClient.diagLocalUfrag = WebRTCClient.ufrag4(sdp.sdp)
        diag?.add(["type": "answer-sent", "seq": self.callSeqId, "ufrag": WebRTCClient.ufrag4(sdp.sdp)])
        self.topic?.videoCall(event: "answer", seq: self.callSeqId, payload: sdp.serialize())
    }

    func sendIceCandidate(_ candidate: RTCIceCandidate) {
        webRTCClient.diagNoteLocalSent(candidate, sent: self.topic != nil && self.callSeqId > 0)
        self.topic?.videoCall(event: "ice-candidate", seq: self.callSeqId, payload: candidate.serialize())
    }

    func closeCall() {
        self.handleCallClose()
    }

    func handleRemoteStream(_ client: WebRTCClient, receivedStream stream: RTCMediaStream) {
        DispatchQueue.main.async {
            guard let renderer = self.remoteRenderer, !self.closed else { return }
            client.setupRemoteRenderer(renderer, withTrack: stream.videoTracks.first)
            if !self.isAudioOnlyCall {
                self.linia2SetupPiP()
            }
        }
    }

    func canSendOffer() -> Bool {
        return self.callDirection != .incoming || self.callInitialSetupComplete
    }

    var linia2IsCaller: Bool { callDirection == .outgoing }

    func enableMediaControls() {
        DispatchQueue.main.async {
            self.micToggleButton.isEnabled = true
            self.videoToggleButton.isEnabled = true
            self.speakerToggleButton.isEnabled = true
            self.linia2UpdateButtons()
        }
    }

    func markConnectionSetupComplete() {
        // LINIA2: вызывается из signaling-потока WebRTC — флаг экрана меняем только на главном.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.markConnectionSetupComplete() }
            return
        }
        self.callInitialSetupComplete = true
        self.webRTCClient.drainIceCandidatesCache()
    }

    func toggleRemoteVideo(remoteLive: Bool) {
        DispatchQueue.main.async {
            self.remoteVideoLive = remoteLive
            if let w = self.webRTCClient.web {
                w.call("setRemoteVisible", remoteLive)
                self.remoteView.isHidden = true
                self.linia2SetAvatarVisible(!remoteLive)
                return
            }
            self.remoteView.isHidden = !remoteLive
            self.linia2SetAvatarVisible(!remoteLive)
        }
    }

    func linia2IceStateChanged(_ state: RTCIceConnectionState) {
        guard started, !closed, !connectionLost else { return }
        switch state {
        case .connected, .completed:
            iceDisconnectedAt = nil
            linia2NoteWebSwitchConnected()
            if iceDown { linia2CheckIceRecovered(reason: "ice-connected") }
        case .disconnected:
            guard linia2WasConnected else { return }
            // WebRTC часто сам восстанавливается за 1–2 с; дольше — «Переподключение…» и ICE restart.
            iceDisconnectedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, !self.closed, let d = self.iceDisconnectedAt, Date().timeIntervalSince(d) >= 1.9 else { return }
                self.needIceRestart = true
                self.linia2SetLinkState(ice: true, reason: "ice-disconnected")
                self.linia2MaybeRestartIce()
            }
        case .failed:
            guard linia2WasConnected else { return }
            needIceRestart = true
            iceRestartPending = false
            linia2SetLinkState(ice: true, reason: "ice-failed")
            linia2MaybeRestartIce()
        default:
            break
        }
    }

    func linia2NegotiationDone(remoteOffer: Bool) {
        guard !closed else { return }
        if remoteOffer {
            // Собеседник сам сделал ICE restart — наш больше не нужен.
            needIceRestart = false
        }
        if iceRestartPending || remoteOffer { diag?.add(["type": "ice-restart", "state": remoteOffer ? "answered" : "answer-applied"]) }
        iceRestartPending = false
        // Проверить чуть позже: после смены ufrag ICE может на мгновение уйти в checking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.linia2CheckIceRecovered(reason: "ice-restarted") }
    }

    func linia2NegotiationFailed(_ stage: String) {
        guard !closed, !connectionLost else { return }
        diag?.add(["type": "error", "where": stage])
        iceRestartPending = false
        needIceRestart = true
        if reconnectingSince == nil { linia2SetLinkState(ice: true, reason: "negotiation-failed") }
    }
}

extension CallViewController: TinodeVideoCallDelegate {
    func eventMatchesCallInProgress(info: MsgServerInfo) -> Bool {
        // Make sure it's a "call" info message on the topic & seq of the present call.
        return info.what == "call" && info.topic == self.topic?.name && info.seq == self.callSeqId
    }

    func handleAcceptedMsg() {
        assert(Thread.isMainThread)
        self.playSoundEffect(nil)

        // Stop animation, hide peer name & avatar.
        self.dialingAnimation(on: false)
        if !self.isAudioOnlyCall {
            self.linia2SetAvatarVisible(false)
        }
        guard !closed else { return }
        diag?.add(["type": "accepted"])
        // The callee has informed us (the caller) of the call acceptance.
        guard self.webRTCClient.createPeerConnection(withDataChannel: true) else {
            Cache.log.error("CallVC.handleAcceptedMsg - createPeerConnection failed")
            diag?.add(["type": "error", "where": "createPeerConnection"])
            self.handleCallClose()
            return
        }
        // LINIA2: offer — сразу, не полагаясь на negotiationneeded (см. WebRTCClient.createPeerConnection).
        self.webRTCClient.makeInitialOffer()
    }

    func handleOfferMsg(with payload: JSONValue?) {
        assert(Thread.isMainThread)
        guard case let .dict(offer) = payload, let desc = RTCSessionDescription.deserialize(from: offer) else {
            Cache.log.error("CallVC.handleOfferMsg - invalid offer payload")
            self.handleCallClose()
            return
        }
        guard !closed else { return }
        webRTCClient.diagRemoteUfrag = WebRTCClient.ufrag4(desc.sdp)
        diag?.add(["type": "offer", "ufrag": WebRTCClient.ufrag4(desc.sdp)])
        // Data channel should be created by the peer. Not creating one.
        // LINIA2: обычно соединение уже создано при «Принять» (handleCallInvite) — тогда ответ мгновенный.
        guard self.webRTCClient.createPeerConnection(withDataChannel: false) else {
            Cache.log.error("CallVC.handleOfferMsg - createPeerConnection failed")
            self.handleCallClose()
            return
        }
        self.webRTCClient.handleRemoteOfferDescription(desc)
    }

    func handleAnswerMsg(with payload: JSONValue?) {
        assert(Thread.isMainThread)
        guard case let .dict(answer) = payload, let desc = RTCSessionDescription.deserialize(from: answer) else {
            Cache.log.error("CallVC.handleAnswerMsg - invalid answer payload")
            self.handleCallClose()
            return
        }
        webRTCClient.diagRemoteUfrag = WebRTCClient.ufrag4(desc.sdp)
        diag?.add(["type": "answer", "ufrag": WebRTCClient.ufrag4(desc.sdp)])
        self.webRTCClient.handleRemoteAnswerDescription(desc)
    }

    func handleIceCandidateMsg(with payload: JSONValue?) {
        assert(Thread.isMainThread)
        guard case let .dict(iceDict) = payload, let candidate = RTCIceCandidate.deserialize(from: iceDict) else {
            Cache.log.error("CallVC.handleIceCandidateMsg - invalid ICE candidate payload")
            self.handleCallClose()
            return
        }
        self.webRTCClient.diagCountRemote(candidate)
        self.webRTCClient.handleRemoteIceCandidate(candidate, saveInCache: !self.callInitialSetupComplete)
    }

    func handleRemoteHangup() {
        assert(Thread.isMainThread)
        self.playSoundEffect("call-end")
        self.handleCallClose(remoteEnded: true)
    }

    func handleRinging() {
        assert(Thread.isMainThread)
        self.dialingAnimation(on: true)
        self.playSoundEffect("call-out", loop: true)
    }

    func linia2SignalingDown(reason: String) {
        guard started, !closed, !connectionLost else { return }
        diag?.add(["type": "signaling", "state": "down", "reason": reason])
        // Звонок продолжается (медиа может идти напрямую); hang-up не отправляем — сервер ждёт переподключения.
        linia2SetLinkState(ws: true, reason: "ws-closed")
    }

    func linia2SignalingLoggedIn(code: Int) {
        guard started, !closed, !connectionLost, wsDown, code < 300 else { return }
        linia2Resubscribe()
    }
}


// MARK: - LINIA2: переподключение звонка (смена сети Wi‑Fi ↔ LTE/5G, смена IP, кратковременный обрыв)
//
// Звонок не завершается при потере связи: экран показывает «Переподключение…», CallKit-звонок и аудиосессия
// не трогаются. Восстановление:
//  • веб-сокет Tinode закрылся → переподключение без экспоненциальной паузы (каждые 2 с), вход (autoLogin),
//    повторная подписка на топик; звонок продолжается с тем же seq (hang-up не отправляется);
//  • медиапуть потерян (ICE disconnected > 2 с / failed, сменилась сеть — NWPathMonitor) → ICE restart:
//    offer с новыми ufrag/pwd через Tinode «offer» (тот же seq), собеседник отвечает «answer»; со 2-й попытки —
//    только через TURN (relay, в т.ч. TURN/TCP);
//  • не восстановилось за kReconnectGrace (30 с) → «Связь потеряна», CallKit reportCall(endedAt:reason: .failed).
extension CallViewController {
    var linia2StatusColor: UIColor {
        if connectionLost { return L2.hex(0xFF6B5E) }
        return reconnectingSince != nil || isPoorConnection || isHeld ? L2.hex(0xFFB547) : L2.hex(0xC9D1DE)
    }

    /// Звонок уже соединялся (иначе — обычные правила: не соединился — завершаем).
    private var linia2WasConnected: Bool { connectedAt != nil || webRTCClient.linia2Established }

    /// Обновить «упало/восстановилось»; начать или закончить переподключение.
    func linia2SetLinkState(ws: Bool? = nil, ice: Bool? = nil, reason: String) {
        guard started, !closed, !connectionLost else { return }
        if let w = ws { wsDown = w }
        if let i = ice { iceDown = i }
        if wsDown || iceDown {
            if reconnectingSince == nil {
                reconnectingSince = Date()
                reconnectTicks = 0
                iceRestartAttempts = 0
                Cache.log.info("CallVC: reconnecting (%@)", reason)
                diag?.add(["type": "reconnect", "state": "start", "reason": reason, "ws": wsDown, "ice": iceDown])
                reconnectTimer?.invalidate()
                reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.linia2ReconnectStep() }
            } else {
                diag?.add(["type": "reconnect", "state": "update", "reason": reason, "ws": wsDown, "ice": iceDown])
            }
        } else if let since = reconnectingSince {
            reconnectingSince = nil
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            iceRestartAttempts = 0
            Cache.log.info("CallVC: reconnected (%@)", reason)
            diag?.add(["type": "reconnect", "state": "done", "reason": reason, "ms": Int(Date().timeIntervalSince(since) * 1000)])
        }
        stateLabel.text = linia2StatusText
        stateLabel.textColor = linia2StatusColor
        Linia2CallCenter.shared.refreshBanner()
    }

    /// Раз в секунду, пока идёт переподключение.
    private func linia2ReconnectStep() {
        guard let since = reconnectingSince, !closed, !connectionLost else {
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            return
        }
        if Date().timeIntervalSince(since) >= Self.kReconnectGrace {
            linia2ConnectionLost()
            return
        }
        reconnectTicks += 1
        let tinode = Cache.tinode
        if !tinode.isConnected {
            wsDown = true
            // Без экспоненциальной паузы SDK (после 15 с обрыва она уже 8–16 с): пробуем каждые 2 с.
            // interactively: false — не перебивает уже идущую попытку подключения.
            if reconnectTicks % 2 == 0 {
                DispatchQueue.global(qos: .userInitiated).async { _ = tinode.reconnectNow(interactively: false, reset: false) }
            }
        } else if wsDown, tinode.isConnectionAuthenticated {
            linia2Resubscribe()
        }
        if !wsDown {
            linia2MaybeRestartIce()
            linia2CheckIceRecovered(reason: "ice-restarted")
        }
    }

    /// Сервер снова доступен: подписка на топик (сообщения звонка приходят только подписчикам), затем — ICE restart.
    private func linia2Resubscribe() {
        guard wsDown, !closed, !connectionLost, !resubscribing, let topic = topic else { return }
        if topic.attached {
            linia2SignalingRestored()
            return
        }
        resubscribing = true
        diag?.add(["type": "resubscribe"])
        topic.subscribe().then(
            onSuccess: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resubscribing = false
                    self?.linia2SignalingRestored()
                }
                return nil
            },
            onFailure: { [weak self, weak topic] err in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.resubscribing = false
                    // Уже подписан другим экраном (чат) — тоже годится; иначе повторим на следующем шаге.
                    if topic?.attached ?? false {
                        self.linia2SignalingRestored()
                    } else {
                        self.diag?.add(["type": "error", "where": "resubscribe", "err": err.localizedDescription])
                    }
                }
                return nil
            })
    }

    private func linia2SignalingRestored() {
        guard wsDown else { return }
        diag?.add(["type": "signaling", "state": "restored", "seq": callSeqId])
        linia2SetLinkState(ws: false, reason: "ws-restored")
        linia2MaybeRestartIce()
    }

    /// ICE restart, если он нужен и есть связь с сервером (offer/answer идут через Tinode).
    private func linia2MaybeRestartIce() {
        guard !closed, !connectionLost, !wsDown, linia2WasConnected, callSeqId > 0,
              Cache.tinode.isConnected, topic?.attached ?? false else { return }
        let sinceLast = lastIceRestartAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if iceRestartPending {
            // Ответ на наш restart не пришёл (потерялся при обрыве) — повторяем через 6 с.
            guard sinceLast > 6 else { return }
        } else if !needIceRestart {
            // Restart прошёл, но ICE ещё не соединился — даём 6 с, затем следующая попытка (уже через TURN).
            guard iceDown, sinceLast > 6 else { return }
        }
        if sinceLast < 2 { return }
        let relay = iceRestartAttempts >= 1
        guard webRTCClient.linia2RestartIce(relayOnly: relay) else { return }
        iceRestartAttempts += 1
        lastIceRestartAt = Date()
        iceRestartPending = true
        needIceRestart = false
        Cache.log.info("CallVC: ICE restart #%d (relay: %@)", iceRestartAttempts, relay ? "yes" : "no")
    }

    /// После ICE restart: соединение есть и переговоры закончены — медиапуть восстановлен.
    private func linia2CheckIceRecovered(reason: String) {
        guard iceDown, !needIceRestart, !iceRestartPending, webRTCClient.signalingIsStable, webRTCClient.iceIsConnected else { return }
        iceDisconnectedAt = nil
        linia2SetLinkState(ice: false, reason: reason)
    }

    /// Не восстановилось за 30 с: «Связь потеряна» на экране ~3 с, затем экран закрывается.
    private func linia2ConnectionLost() {
        guard !closed, !connectionLost else { return }
        let since = reconnectingSince ?? Date()
        connectionLost = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        Cache.log.info("CallVC: connection lost — ending call")
        diag?.add(["type": "reconnect", "state": "lost", "ms": Int(Date().timeIntervalSince(since) * 1000), "ws": wsDown, "ice": iceDown])
        stateLabel.text = linia2StatusText
        stateLabel.textColor = linia2StatusColor
        Linia2CallCenter.shared.refreshBanner()
        if ownsCall { Cache.callManager.failCallInProgress() }
        playSoundEffect("call-end")
        UIAccessibility.post(notification: .announcement, argument: "Связь потеряна")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, !self.closed else { return }
            let shown = self.viewIfLoaded?.window != nil
            self.handleCallClose()
            if !shown { UiUtils.showToast(message: "Звонок завершён: связь потеряна") }
        }
    }

    // MARK: Смена сети (NWPathMonitor)

    func linia2StartPathMonitor() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            let key = (ok ? "ok|" : "none|") + (path.availableInterfaces.first?.name ?? "")
            let ifType: String = path.usesInterfaceType(.wifi) ? "wifi" : (path.usesInterfaceType(.cellular) ? "cellular" :
                                 (path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"))
            DispatchQueue.main.async { self?.linia2PathChanged(key: key, satisfied: ok, type: ifType) }
        }
        m.start(queue: DispatchQueue(label: "info.codix.liniya2.call-path"))
        pathMonitor = m
    }

    private func linia2PathChanged(key: String, satisfied: Bool, type: String) {
        guard !closed, !connectionLost else { return }
        guard let prev = lastPathKey else { lastPathKey = key; return }   // первое значение — текущая сеть
        guard prev != key else { return }
        lastPathKey = key
        diag?.add(["type": "net", "status": satisfied ? "ok" : "none", "if": type, "key": key])
        guard linia2WasConnected else { return }
        // Сеть сменилась: старые пути ICE и TCP-сокет сервера, скорее всего, мертвы. Звонок НЕ завершаем,
        // CallKit/аудиосессию не трогаем: «Переподключение…», новый сокет к серверу и ICE restart.
        needIceRestart = true
        linia2SetLinkState(ice: true, reason: satisfied ? "path-change" : "path-lost")
        guard satisfied else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = Cache.tinode.reconnectNow(interactively: true, reset: true) }
    }

    // MARK: Автотесты: эмуляция обрыва сети (-l2-uitest)

    /// Симулятор нельзя отключить от сети с хоста. Кнопки (только под -l2-uitest) эмулируют обрыв на N секунд:
    ///  1) веб-сокет Tinode закрывается и переподключение запрещено N с (настоящий обрыв сигнализации — сервер
    ///     видит отключение участника);
    ///  2) отправка RTP останавливается (encodings.isActive = false) — исходящий звук пропадает; приём от собеседника
    ///     при этом идёт (входящий UDP с хоста не перекрыть);
    ///  3) медиапуть считается потерянным, как при смене сети (NWPathMonitor): «Переподключение…» и ICE restart
    ///     через Tinode offer/answer, как только сервер снова доступен.
    func linia2AddUITestHooks() {
        guard ProcessInfo.processInfo.arguments.contains("-l2-uitest") else { return }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for sec in [5, 15, 35] {
            let b = UIButton(type: .custom)
            b.tag = sec
            b.backgroundColor = UIColor.white.withAlphaComponent(0.03)
            b.accessibilityIdentifier = "l2.call.uitest.drop\(sec)"
            b.accessibilityLabel = "Тест: обрыв связи \(sec) с"
            b.addTarget(self, action: #selector(linia2UITestDrop(_:)), for: .touchUpInside)
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(b)
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 2),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 120),
        ])
    }

    @objc func linia2UITestDrop(_ sender: UIButton) {
        linia2SimulateOutage(seconds: TimeInterval(sender.tag))
    }

    func linia2SimulateOutage(seconds: TimeInterval) {
        guard started, !closed else { return }
        diag?.add(["type": "uitest-outage", "s": Int(seconds)])
        webRTCClient.linia2SetSendingPaused(true)
        needIceRestart = true
        linia2SetLinkState(ice: true, reason: "uitest-outage")
        Cache.tinode.linia2SimulateOutage(seconds: seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, !self.closed else { return }
            self.webRTCClient.linia2SetSendingPaused(false)
        }
    }
}


// MARK: - LINIA2: оформление, состояние звонка, удержание, качество связи, PiP

extension Notification.Name {
    static let linia2CallConnected = Notification.Name("Linia2CallConnected")
    static let linia2CallUnstable = Notification.Name("Linia2CallUnstable")
}

extension CallViewController {
    static let background = L2.hex(0x0A0E1B)
    static let mint = L2.hex(0x7EE0C3)
    static let red = L2.hex(0xFF3B30)

    /// Текст состояния: «Соединение…», «Идёт звонок мм:сс», «Плохая связь · мм:сс», «На удержании».
    var linia2StatusText: String {
        if connectionLost { return "Связь потеряна" }
        if reconnectingSince != nil { return "Переподключение…" }
        if isHeld { return "На удержании" }
        guard let s = connectedAt else {
            return callDirection == .outgoing && callSeqId > 0 ? "Вызов…" : "Соединение…"
        }
        let sec = Int(Date().timeIntervalSince(s))
        let time = String(format: "%02d:%02d", sec / 60, sec % 60)
        return isPoorConnection ? "Плохая связь · \(time)" : "Идёт звонок \(time)"
    }

    /// Строит экран поверх элементов из Main.storyboard (outlets и действия кнопок сохраняются).
    func linia2BuildLayout() {
        view.backgroundColor = Self.background
        let stack = micToggleButton.superview as? UIStackView
        let mine: [UIView?] = [remoteView, localView, peerNameLabel, peerAvatarImageView, peerNameRemoteVideoLabel, dialingAnimationContainer, stack]
        let mineSet = Set(mine.compactMap { $0 }.map { ObjectIdentifier($0) })
        NSLayoutConstraint.deactivate(view.constraints.filter { c in
            if let a = c.firstItem as? UIView, mineSet.contains(ObjectIdentifier(a)) { return true }
            if let b = c.secondItem as? UIView, mineSet.contains(ObjectIdentifier(b)) { return true }
            return false
        })
        stack?.isHidden = true

        // Видео собеседника — на весь экран, своё — маленькое окно справа сверху.
        remoteView.backgroundColor = .clear
        remoteView.isHidden = isAudioOnlyCall
        localView.layer.cornerRadius = 16
        localView.layer.cornerCurve = .continuous
        localView.clipsToBounds = true
        localView.backgroundColor = L2.hex(0x161D2E)
        // Узкие экраны (SE): окно поменьше, чтобы не касаться аватара по центру.
        let narrow = UIScreen.main.bounds.width < 390
        localViewWidthConstraint.constant = narrow ? 92 : 108
        localViewHeightConstraint.constant = narrow ? 132 : 156
        peerNameRemoteVideoLabel.isHidden = true

        // Затемнение под кнопками (читаемость поверх видео).
        let scrim = L2GradientView(colors: [Self.background.withAlphaComponent(0), Self.background.withAlphaComponent(0.85)])
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isUserInteractionEnabled = false
        view.insertSubview(scrim, aboveSubview: remoteView)
        let topScrim = L2GradientView(colors: [Self.background.withAlphaComponent(0.7), Self.background.withAlphaComponent(0)])
        topScrim.translatesAutoresizingMaskIntoConstraints = false
        topScrim.isUserInteractionEnabled = false
        view.insertSubview(topScrim, aboveSubview: remoteView)

        peerNameLabel.backgroundColor = .clear
        peerNameLabel.textColor = .white
        peerNameLabel.font = L2.font(30, .semibold)
        peerNameLabel.textAlignment = .center
        peerNameLabel.numberOfLines = 1
        peerNameLabel.adjustsFontSizeToFitWidth = true
        peerNameLabel.minimumScaleFactor = 0.6
        peerNameLabel.accessibilityIdentifier = "l2.call.name"
        peerNameLabel.layer.shadowColor = UIColor.black.cgColor
        peerNameLabel.layer.shadowOpacity = 0.4
        peerNameLabel.layer.shadowRadius = 4
        peerNameLabel.layer.shadowOffset = .zero

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = L2.font(17, .regular)
        stateLabel.textColor = L2.hex(0xC9D1DE)
        stateLabel.textAlignment = .center
        stateLabel.accessibilityIdentifier = "l2.call.state"
        stateLabel.text = "Соединение…"
        view.addSubview(stateLabel)

        // Кнопки: ряд 1 — Микрофон · Камера · Динамик; ряд 2 — Повернуть · Завершить · Чат.
        flipButton.setImage(L2.symbol("arrow.triangle.2.circlepath.camera.fill", 24, .regular), for: .normal)
        flipButton.accessibilityIdentifier = "l2.call.flip"
        flipButton.accessibilityLabel = "Повернуть камеру"
        flipButton.addTarget(self, action: #selector(didTapFlip), for: .touchUpInside)
        backButton.setImage(L2.symbol("bubble.left.fill", 24, .regular), for: .normal)
        backButton.accessibilityIdentifier = "l2.call.back"
        backButton.accessibilityLabel = "Вернуться в чат"
        backButton.addTarget(self, action: #selector(didTapBack), for: .touchUpInside)

        let row1 = UIStackView(arrangedSubviews: [
            linia2Item(micToggleButton, "Микрофон"),
            linia2Item(videoToggleButton, "Камера"),
            linia2Item(speakerToggleButton, "Динамик"),
        ])
        let row2 = UIStackView(arrangedSubviews: [
            linia2Item(flipButton, "Повернуть"),
            linia2Item(hangUpButton, "Завершить"),
            linia2Item(backButton, "Чат"),
        ])
        for r in [row1, row2] {
            r.axis = .horizontal
            r.distribution = .equalSpacing
            r.alignment = .top
        }
        let grid = UIStackView(arrangedSubviews: [row1, row2])
        grid.axis = .vertical
        grid.spacing = 22
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)

        // Маршрут звука (AirPods / Bluetooth / наушники): системный выбор поверх кнопки «Динамик».
        let picker = AVRoutePickerView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        picker.accessibilityIdentifier = "l2.call.route"
        picker.accessibilityLabel = "Аудиовыход"
        picker.isHidden = true
        speakerToggleButton.superview?.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: speakerToggleButton.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: speakerToggleButton.trailingAnchor),
            picker.topAnchor.constraint(equalTo: speakerToggleButton.topAnchor),
            picker.bottomAnchor.constraint(equalTo: speakerToggleButton.bottomAnchor),
        ])
        routePicker = picker

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            remoteView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteView.topAnchor.constraint(equalTo: view.topAnchor),
            remoteView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topScrim.topAnchor.constraint(equalTo: view.topAnchor),
            topScrim.bottomAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 30),

            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrim.topAnchor.constraint(equalTo: grid.topAnchor, constant: -60),

            peerAvatarImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            peerAvatarImageView.topAnchor.constraint(equalTo: safe.topAnchor, constant: 56),
            dialingAnimationContainer.centerXAnchor.constraint(equalTo: peerAvatarImageView.centerXAnchor),
            dialingAnimationContainer.centerYAnchor.constraint(equalTo: peerAvatarImageView.centerYAnchor),

            peerNameLabel.topAnchor.constraint(equalTo: peerAvatarImageView.bottomAnchor, constant: 20),
            peerNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            peerNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            peerNameLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            stateLabel.topAnchor.constraint(equalTo: peerNameLabel.bottomAnchor, constant: 6),
            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),

            localView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            // Вёрстка: своё видео — справа сверху (как FaceTime/Telegram); внизу оно перекрывало имя собеседника на SE.
            localView.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),

            grid.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 36),
            grid.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -36),
            grid.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -20),
        ])
        // Порядок слоёв: видео собеседника → затемнение → имя/состояние → своё видео → кнопки.
        for v in [topScrim, scrim, peerNameLabel, stateLabel, localView, grid] as [UIView] { view.bringSubviewToFront(v) }
        hangUpButton.accessibilityIdentifier = "l2.call.hangup"
        hangUpButton.accessibilityLabel = "Завершить"
        micToggleButton.accessibilityIdentifier = "l2.call.mic"
        videoToggleButton.accessibilityIdentifier = "l2.call.video"
        speakerToggleButton.accessibilityIdentifier = "l2.call.speaker"
        // «Динамик» доступен сразу (и во время дозвона): переключение выхода не зависит от соединения.
        speakerToggleButton.isEnabled = true
        linia2AddEncryptedBadge()   // L2_CALLENC
        linia2AddUITestHooks()
    }

    /// Круглая кнопка 72 pt с подписью.
    private func linia2Item(_ button: UIButton, _ caption: String) -> UIView {
        button.removeFromSuperview()
        NSLayoutConstraint.deactivate(button.constraints.filter { ($0.firstItem as? UIView) === button && $0.secondItem == nil })
        for sub in button.subviews where sub is UIVisualEffectView { sub.removeFromSuperview() }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 36
        button.layer.masksToBounds = true
        button.imageEdgeInsets = .zero
        button.contentEdgeInsets = .zero
        let label = UILabel()
        label.text = caption
        label.font = L2.font(13, .regular)
        label.textColor = L2.hex(0xE6EAF2)
        label.textAlignment = .center
        label.isAccessibilityElement = false
        captions[button] = label
        if button.accessibilityLabel == nil { button.accessibilityLabel = caption }
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(button)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 72),
            button.heightAnchor.constraint(equalToConstant: 72),
            button.topAnchor.constraint(equalTo: box.topAnchor),
            button.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: 84),
        ])
        return box
    }

    private func linia2Style(_ b: UIButton, symbol: String, on: Bool, enabled: Bool = true) {
        // Как на iPhone: обычная кнопка — полупрозрачный круг, включённая (без звука, динамик) — белая.
        b.setImage(L2.symbol(symbol, 26, .regular)?.withRenderingMode(.alwaysTemplate), for: .normal)
        b.backgroundColor = on ? .white : UIColor.white.withAlphaComponent(0.16)
        b.tintColor = on ? Self.background : .white
        b.alpha = enabled ? 1 : 0.45
    }

    func linia2UpdateButtons() {
        guard isViewLoaded else { return }
        linia2Style(micToggleButton, symbol: isMuted ? "mic.slash.fill" : "mic.fill", on: isMuted, enabled: micToggleButton.isEnabled)
        micToggleButton.accessibilityLabel = isMuted ? "Включить микрофон" : "Выключить микрофон"
        micToggleButton.accessibilityValue = isMuted ? "выключен" : "включён"
        let camOn = cameraManager.isCapturing
        linia2Style(videoToggleButton, symbol: camOn ? "video.fill" : "video.slash.fill", on: !camOn, enabled: videoToggleButton.isEnabled)
        videoToggleButton.accessibilityLabel = camOn ? "Выключить камеру" : "Включить камеру"
        linia2Style(flipButton, symbol: "arrow.triangle.2.circlepath.camera.fill", on: false, enabled: camOn)
        flipButton.isEnabled = camOn
        linia2Style(backButton, symbol: "bubble.left.fill", on: false)
        hangUpButton.setImage(L2.symbol("phone.down.fill", 30, .regular)?.withRenderingMode(.alwaysTemplate), for: .normal)
        hangUpButton.backgroundColor = Self.red
        hangUpButton.tintColor = .white
        linia2UpdateRoute()
    }

    /// Громкий динамик? В симуляторе маршрут всегда «Speaker» — там верим выбранному выходу.
    private func linia2BuiltInSpeakerOn(_ outputs: [AVAudioSession.Port]) -> Bool {
        #if targetEnvironment(simulator)
        return audioOutput == .speaker
        #else
        return outputs.contains(.builtInSpeaker) || (outputs.isEmpty && audioOutput == .speaker)
        #endif
    }

    /// Кнопка «Динамик»: при подключённых AirPods / Bluetooth / наушниках — системный выбор выхода.
    func linia2UpdateRoute() {
        guard isViewLoaded else { return }
        let external = Linia2CallCenter.hasExternalOutput()
        routePicker?.isHidden = !external
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType }
        let symbol: String
        let caption: String
        var on = false
        let bluetooth: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        if outputs.contains(where: { bluetooth.contains($0) }) {
            symbol = "airpodspro"; caption = "Аудио"
        } else if outputs.contains(.headphones) || outputs.contains(.usbAudio) {
            symbol = "headphones"; caption = "Аудио"
        } else if outputs.contains(.carAudio) {
            symbol = "car.fill"; caption = "Аудио"
        } else if linia2BuiltInSpeakerOn(outputs) {
            symbol = "speaker.wave.3.fill"; caption = external ? "Аудио" : "Динамик"; on = !external
        } else {
            symbol = "speaker.wave.1.fill"; caption = external ? "Аудио" : "Динамик"
        }
        linia2Style(speakerToggleButton, symbol: UIImage(systemName: symbol) != nil ? symbol : "speaker.wave.2.fill", on: on, enabled: speakerToggleButton.isEnabled)
        speakerToggleButton.accessibilityValue = (on ? "включён" : "выключен") + (linia2ProximityWanted ? " · датчик приближения" : "")
        captions[speakerToggleButton]?.text = caption
    }

    func linia2SetAvatarVisible(_ visible: Bool) {
        peerAvatarImageView.alpha = visible ? 1 : 0
        dialingAnimationContainer.alpha = visible ? 1 : 0
    }

    func linia2SetupCallStatus() {
        stateLabel.text = linia2StatusText
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .linia2CallConnected, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.closed else { return }
            self.unstableUntil = nil
            if self.connectedAt == nil {
                self.connectedAt = Date()
                Cache.callManager.reportConnected()
                // Если CallKit не включил звук (сбой) — включаем сами.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { CallManager.ensureAudioEnabled() }
            }
            self.linia2Tick()
        })
        observers.append(nc.addObserver(forName: .linia2CallUnstable, object: nil, queue: .main) { [weak self] _ in
            self?.unstableUntil = Date().addingTimeInterval(4)
            self?.linia2Tick()
        })
        observers.append(nc.addObserver(forName: .linia2CallEnded, object: nil, queue: .main) { [weak self] n in
            guard let self = self, self.ownsCall else { return }
            // Звонок завершён системой (экран блокировки, CallKit, другой звонок) — закрыть экран.
            if let topic = n.userInfo?["topic"] as? String, topic != self.topic?.name { return }
            // Завершение прошлого звонка в том же чате (другой seq) не должно гасить текущий (ошибка веба №1).
            if let seq = n.userInfo?["seq"] as? Int, seq > 0, seq != self.callSeqId { return }
            self.handleCallClose(remoteEnded: (n.userInfo?["remote"] as? Bool) ?? false)
        })
        observers.append(nc.addObserver(forName: .linia2CallHeld, object: nil, queue: .main) { [weak self] n in
            self?.setHeld((n.userInfo?["held"] as? Bool) ?? false)
        })
        observers.append(nc.addObserver(forName: .linia2CallMuted, object: nil, queue: .main) { [weak self] n in
            self?.setMuted((n.userInfo?["muted"] as? Bool) ?? false)
        })
        observers.append(nc.addObserver(forName: .linia2CallAudioActivated, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            CallManager.setOutputPort(self.audioOutput)
            // Вариант Б: CallKit включил звук — странице: play() звука собеседника, проверить/перезапросить микрофон.
            self.webRTCClient.web?.linia2AudioActivated()
            self.linia2UpdateRoute()
        })
        // Свернули приложение: своё видео на паузе (камера в фоне недоступна), вернулись — продолжить.
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.cameraManager.isCapturing else { return }
            self.webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventMuted)
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.cameraManager.isCapturing, !self.isHeld else { return }
            self.webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventUnmuted)
        })
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.linia2Tick() }
    }

    private func linia2Tick() {
        if let u = unstableUntil, u < Date() { unstableUntil = nil }
        isPoorConnection = unstableUntil != nil || (connectedAt != nil && lastStatsPoor)
        stateLabel.text = linia2StatusText
        stateLabel.textColor = linia2StatusColor
        if let c = connectedAt, Date().timeIntervalSince(c) < 10 || Int(Date().timeIntervalSince1970) % 2 == 0 { linia2CheckQuality() }
    }

    /// «Плохая связь»: потери входящих пакетов > 10% или RTT > 800 мс (статистика WebRTC, каждые 2 с).
    private func linia2CheckQuality() {
        if let w = webRTCClient.web {
            // Движок WKWebView: байты аудио — из статистики страницы (для автотестов, как у нативного).
            let s = w.lastStats
            stateLabel.accessibilityValue = "arx=\((s["aIn"] as? NSNumber)?.intValue ?? 0) atx=\((s["aOut"] as? NSNumber)?.intValue ?? 0)"
            return
        }
        webRTCClient.statistics { [weak self] report in
            var rtt: Double = 0
            var lost: Double = 0, received: Double = 0
            var fraction: Double = 0
            var audioRx: Double = 0, audioTx: Double = 0
            for (_, st) in report.statistics {
                let v = st.values
                let kind = (v["kind"] as? String) ?? (v["mediaType"] as? String) ?? ""
                if st.type == "inbound-rtp", kind == "audio" { audioRx += (v["bytesReceived"] as? NSNumber)?.doubleValue ?? 0 }
                if st.type == "outbound-rtp", kind == "audio" { audioTx += (v["bytesSent"] as? NSNumber)?.doubleValue ?? 0 }
                switch st.type {
                case "candidate-pair":
                    if (v["state"] as? String) == "succeeded", (v["nominated"] as? NSNumber)?.boolValue ?? true,
                       let r = (v["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                        rtt = max(rtt, r)
                    }
                case "inbound-rtp":
                    lost += (v["packetsLost"] as? NSNumber)?.doubleValue ?? 0
                    received += (v["packetsReceived"] as? NSNumber)?.doubleValue ?? 0
                case "remote-inbound-rtp":
                    fraction = max(fraction, (v["fractionLost"] as? NSNumber)?.doubleValue ?? 0)
                    if let r = (v["roundTripTime"] as? NSNumber)?.doubleValue { rtt = max(rtt, r) }
                default:
                    break
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                var loss = fraction
                if let prev = self.lastStats {
                    let dl = lost - prev.lost, dr = received - prev.received
                    if dl + dr > 0 { loss = max(loss, dl / (dl + dr)) }
                }
                self.lastStats = (lost, received)
                // Автотесты: байты аудио в обе стороны (звук идёт и к нам, и от нас).
                self.stateLabel.accessibilityValue = "arx=\(Int(audioRx)) atx=\(Int(audioTx))"
                let poor = loss > 0.10 || rtt > 0.8
                self.lastStatsPoor = poor
                self.isPoorConnection = poor || self.unstableUntil != nil
                self.stateLabel.text = self.linia2StatusText
                self.stateLabel.textColor = self.linia2StatusColor
            }
        }
    }

    /// Удержание (входящий GSM-звонок, «Удержать» в системном экране): не отправляем звук и видео.
    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        if held {
            heldRestore = (audio: !isMuted, video: webRTCClient.isVideoTrackEnabled)
            webRTCClient.setAudioEnabled(false)
            webRTCClient.setVideoEnabled(false)
            if cameraManager.isCapturing { webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventMuted) }
        } else {
            let r = heldRestore ?? (audio: !isMuted, video: true)
            webRTCClient.setAudioEnabled(r.audio && !isMuted)
            webRTCClient.setVideoEnabled(r.video)
            if cameraManager.isCapturing { webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventUnmuted) }
            heldRestore = nil
        }
        linia2Tick()
    }

    /// Картинка-в-картинке для видеозвонка (iOS 15+): при сворачивании приложения видео собеседника — в окне PiP.
    func linia2SetupPiP() {
        guard pip == nil else { return }
        if #available(iOS 15.0, *), AVPictureInPictureController.isPictureInPictureSupported() {
            let p = Linia2CallPiP(sourceView: remoteView)
            webRTCClient.addRemoteRenderer(p.renderer)
            pip = p
        }
    }
}

/// Вертикальный градиент (затемнение под кнопками звонка).
final class L2GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    init(colors: [UIColor]) {
        super.init(frame: .zero)
        (layer as? CAGradientLayer)?.colors = colors.map { $0.cgColor }
    }
    required init?(coder: NSCoder) { return nil }
}


// MARK: - LINIA2 (вариант Б): выбор движка звонка
//
// WKWebView в фоне (звонок принят из CallKit на заблокированном экране, приложение не активно) не даёт
// getUserMedia: звонок 27.11 16:09 (id 596) — ни одного события JS; 27.11 18:51 (id 760) — ждали didBecomeActive,
// accept не ушёл, гость слышал гудки и сбросил. Поэтому:
//  • приложение не активно — СРАЗУ нативный движок (engine=native-bg), accept/offer без ожидания;
//    приложение потом стало активным, а нативный за kWebSwitchAfter с так и не соединился (ICE) — бесшовный
//    переход на WKWebView (switch-to-web): hang-up не шлём, в JS новое соединение, offer/answer заново по той же
//    сигнализации (тот же seq, новые ufrag/pwd и DTLS — как ICE restart), удалённые кандидаты — в новое соединение;
//    выключается флагом features.webCallSwitch=false (без сборки);
//  • приложение активно — страница запускается, ждём от неё «ready» до kWebWaitReady с; нет — нативный движок.
private var linia2EngineChosenKey: UInt8 = 0
private var linia2SwitchKey: UInt8 = 0

/// Состояние перехода «нативный → WKWebView» (на экран звонка).
private final class L2WebSwitchState {
    var nativeBgAt: Date?
    var activeAt: Date?
    var timer: Timer?
    var switching = false
    var startedAt: Date?
    var why = ""
}

extension CallViewController {
    static let kWebWaitReady: TimeInterval = 6
    /// Нативный движок (ответ из фона) не соединился за столько секунд — переход на WKWebView, когда приложение активно.
    static let kWebSwitchAfter: TimeInterval = 8
    /// Дольше этого после ответа переход не делаем (звонок уже идёт или завершится сам).
    static let kWebSwitchWindow: TimeInterval = 60
    /// После перехода ICE нового соединения не connected за столько секунд — ICE restart (если звонок соединялся).
    static let kWebSwitchConnectTimeout: TimeInterval = 15

    var linia2EngineChosen: Bool {
        get { (objc_getAssociatedObject(self, &linia2EngineChosenKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &linia2EngineChosenKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var l2Switch: L2WebSwitchState {
        if let s = objc_getAssociatedObject(self, &linia2SwitchKey) as? L2WebSwitchState { return s }
        let s = L2WebSwitchState()
        objc_setAssociatedObject(self, &linia2SwitchKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .background: return "background"
        default: return "inactive"
        }
    }

    /// Автотест (-l2-uitest, L2_FORCE_WEB_SWITCH=1): переход на WKWebView через 2 с после выхода на экран, даже если
    /// нативный движок соединился — проверка самого перехода против настоящего собеседника.
    private static var forceWebSwitch: Bool {
        ProcessInfo.processInfo.arguments.contains("-l2-uitest") && ProcessInfo.processInfo.environment["L2_FORCE_WEB_SWITCH"] == "1"
    }

    func linia2ChooseEngine(then proceed: @escaping () -> Void) {
        var done = false
        let finish: (Bool, String) -> Void = { [weak self] useWeb, reason in
            guard let self = self, !done else { return }
            done = true
            self.linia2EngineChosen = true
            if !useWeb { self.webRTCClient.linia2DisableWebEngine(reason: reason) }
            guard !self.closed else { return }
            proceed()
        }
        guard UIApplication.shared.applicationState == .active else {
            // Не ждём выхода на экран: accept уходит сразу, разговор — на нативном движке.
            done = true
            linia2EngineChosen = true
            diag?.add(["type": "engine", "name": "native-bg", "app": Self.appStateName()])
            Linia2TestProbe.nativeBg += 1
            guard !closed else { return }
            proceed()
            linia2ArmWebSwitch()
            return
        }
        diag?.add(["type": "web-load-start", "app": Self.appStateName()])
        webRTCClient.linia2EnableWebEngine(audioOnly: isAudioOnlyCall, caller: callDirection == .outgoing,
                                           video: !isAudioOnlyCall && !cameraDenied)
        guard let w = webRTCClient.web else { finish(false, "no-engine"); return }
        if w.isReady { finish(true, ""); return }
        w.onReady = { finish(true, "") }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.kWebWaitReady) {
            finish(false, "not-ready app=" + Self.appStateName())
        }
    }

    // MARK: Переход «нативный → WKWebView» (ответ из фона)

    func linia2ArmWebSwitch() {
        guard Linia2WebCallEngine.enabled else { return }
        guard Linia2Config.shared.feature("webCallSwitch", default: true) else {
            diag?.add(["type": "switch-to-web", "state": "off"])
            return
        }
        let st = l2Switch
        st.nativeBgAt = Date()
        st.timer?.invalidate()
        st.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.linia2CheckWebSwitch(t)
        }
    }

    private func linia2CheckWebSwitch(_ t: Timer) {
        let st = l2Switch
        guard let since = st.nativeBgAt, !closed, !connectionLost, !webRTCClient.isWebEngine else { t.invalidate(); return }
        let forced = Self.forceWebSwitch
        let elapsed = Date().timeIntervalSince(since)
        if elapsed > Self.kWebSwitchWindow {
            diag?.add(["type": "switch-to-web", "state": "skip", "why": "window", "ms": Int(elapsed * 1000)])
            t.invalidate()
            return
        }
        if webRTCClient.linia2Established && !forced {
            diag?.add(["type": "switch-to-web", "state": "skip", "why": "native-connected", "ms": Int(elapsed * 1000)])
            t.invalidate()
            return
        }
        guard UIApplication.shared.applicationState == .active else { st.activeAt = nil; return }
        if st.activeAt == nil {
            st.activeAt = Date()
            diag?.add(["type": "switch-to-web", "state": "app-active", "ms": Int(elapsed * 1000), "ice": webRTCClient.iceStateName])
        }
        // Первый обмен offer/answer нативного движка завершён, сигнализация на связи.
        guard !st.switching, callInitialSetupComplete, !wsDown, callSeqId > 0, let activeAt = st.activeAt else { return }
        if forced {
            guard Date().timeIntervalSince(activeAt) >= 2 else { return }
        } else {
            guard Date().timeIntervalSince(activeAt) >= 0.5, elapsed >= Self.kWebSwitchAfter else { return }
        }
        t.invalidate()
        linia2SwitchToWeb(why: forced ? "forced-test" : "native-not-connected")
    }

    /// Переход посреди звонка: страница движка грузится, пока работает нативный; готова — нативное соединение
    /// закрывается (без hang-up), в JS — новое соединение и offer по той же сигнализации.
    func linia2SwitchToWeb(why: String) {
        let st = l2Switch
        guard !st.switching, !closed, !webRTCClient.isWebEngine else { return }
        st.switching = true
        let t0 = Date()
        let sinceBg = st.nativeBgAt.map { Int(t0.timeIntervalSince($0) * 1000) } ?? -1
        diag?.add(["type": "switch-to-web", "state": "start", "why": why, "ms": sinceBg, "ice": webRTCClient.iceStateName])
        guard let w = webRTCClient.linia2PrepareWebSwitch() else {
            diag?.add(["type": "switch-to-web", "state": "fail", "why": "no-engine"])
            st.switching = false
            return
        }
        var done = false
        let commit: () -> Void = { [weak self] in
            guard let self = self, !done else { return }
            done = true
            self.linia2CommitWebSwitch(why: why, t0: t0)
        }
        if w.isReady { commit(); return }
        w.onReady = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.kWebWaitReady) { [weak self] in
            guard let self = self, !done else { return }
            done = true
            self.webRTCClient.linia2CancelWebSwitch()
            self.l2Switch.switching = false
            self.diag?.add(["type": "switch-to-web", "state": "fail", "why": "not-ready", "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        }
    }

    private func linia2CommitWebSwitch(why: String, t0: Date) {
        let st = l2Switch
        guard !closed else { webRTCClient.linia2CancelWebSwitch(); return }
        let wasVideo = !isAudioOnlyCall && !cameraDenied && cameraManager.isCapturing
        // Нативные камера, картинка-в-картинке и окна видео — выключить: дальше всё рисует и снимает страница.
        if cameraManager.isCapturing { cameraManager.stopCapture() }
        if #available(iOS 15.0, *), let p = self.pip as? Linia2CallPiP {
            webRTCClient.removeRemoteRenderer(p.renderer)
            p.stop()
        }
        pip = nil
        guard webRTCClient.linia2CommitWebSwitch(audioOnly: isAudioOnlyCall, caller: callDirection == .outgoing, video: wasVideo) else {
            st.switching = false
            diag?.add(["type": "switch-to-web", "state": "fail", "why": "commit"])
            return
        }
        cameraManager.web = webRTCClient.web
        cameraManager.isCapturing = wasVideo
        for container in [localView, remoteView] {
            guard let c = container else { continue }
            for sv in c.subviews where sv is RTCVideoRenderer { sv.removeFromSuperview() }
        }
        remoteRenderer = nil
        localView.backgroundColor = .clear
        if let nw = webRTCClient.web {
            nw.attach(to: view, below: remoteView)
            linia2UpdateWebLayout()
            if remoteVideoLive {
                nw.call("setRemoteVisible", true)
                remoteView.isHidden = true
            }
        }
        webRTCClient.setAudioEnabled(!isMuted && !isHeld)
        guard webRTCClient.createPeerConnection(withDataChannel: true) else {
            diag?.add(["type": "switch-to-web", "state": "fail", "why": "createPC"])
            return
        }
        // Тот же порядок m= (audio, video, application), что у собеседника; новые ufrag/pwd и DTLS — как ICE restart.
        webRTCClient.makeInitialOffer()
        st.startedAt = t0
        st.why = why
        Linia2TestProbe.callEngine = 2
        Linia2TestProbe.webSwitches += 1
        diag?.add(["type": "switch-to-web", "state": "offer", "why": why, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.kWebSwitchConnectTimeout) { [weak self] in
            guard let self = self, !self.closed, let s = self.l2Switch.startedAt, s == t0 else { return }
            self.diag?.add(["type": "switch-to-web", "state": "timeout", "why": why, "ice": self.webRTCClient.iceStateName])
            if self.webRTCClient.linia2Established {
                self.needIceRestart = true
                self.linia2SetLinkState(ice: true, reason: "switch-timeout")
                self.linia2MaybeRestartIce()
            }
        }
    }

    /// ICE соединения WKWebView после перехода — connected: в диагностику (сколько заняло).
    func linia2NoteWebSwitchConnected() {
        let st = l2Switch
        guard let t0 = st.startedAt, webRTCClient.isWebEngine else { return }
        st.startedAt = nil
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Linia2TestProbe.webSwitchIceMs = ms
        diag?.add(["type": "switch-to-web", "state": "connected", "why": st.why, "ms": ms])
    }
}
