//
//  CallViewController.swift
//  Tinodios
//
//  Copyright © 2022-2025 Tinode LLC. All rights reserved.
//


import AVFoundation
import AVKit
import Foundation
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

    func setupCamera() {
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

    func startCapture(completion: (() -> Void)? = nil) {
        Cache.log.info("CallVC - CameraManager: start capture")

        guard !isCapturing else { return }
        isCapturing = true

        #if arch(arm64)
        DispatchQueue.global(qos: .background).async {
            self.captureSession.startRunning()
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

        #if arch(arm64)
        DispatchQueue.global(qos: .background).async {
            self.captureSession.stopRunning()
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
}

class WebRTCClient: NSObject {
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

    private var remoteIceCandidatesCacheQueue = DispatchQueue(label: "co.tinode.webrtc.ice-candidates-queue")
    private var remoteIceCandidatesCache: [RTCIceCandidate] = []

    weak var delegate: WebRTCClientDelegate?

    func setup() {
        createMediaSenders()
    }

    func toggleAudio() -> Bool {
        guard let track = self.localAudioTrack else { return false }
        track.isEnabled = !track.isEnabled
        return track.isEnabled
    }

    // LINIA2: явные состояния (для CallKit «Выключить звук» и удержания).
    var isAudioEnabled: Bool { localAudioTrack?.isEnabled ?? false }
    func setAudioEnabled(_ on: Bool) { localAudioTrack?.isEnabled = on }
    func setVideoEnabled(_ on: Bool) { localVideoTrack?.isEnabled = on }
    var isVideoTrackEnabled: Bool { localVideoTrack?.isEnabled ?? false }

    /// Статистика WebRTC (потери, RTT) — для «Плохая связь».
    func statistics(_ completion: @escaping (RTCStatisticsReport) -> Void) {
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
        if !saveInCache {
            self.localPeer?.add(candidate) { err in
                if let err = err {
                    Cache.log.error("WebRTCClient: could not add ICE candidate: %@", err.localizedDescription)
                    self.delegate?.closeCall()
                }
            }
        } else {
            self.remoteIceCandidatesCacheQueue.sync {
                self.remoteIceCandidatesCache.append(candidate)
            }
        }
    }

    // Adds all locally cached remote ICE candidates to the peer connection.
    func drainIceCandidatesCache() {
        Cache.log.info("Draining iceCandidateCache: %d items", self.remoteIceCandidatesCache.count)
        var success = true
        self.remoteIceCandidatesCacheQueue.sync {
            self.remoteIceCandidatesCache.forEach { candidate in
                self.localPeer?.add(candidate) { err in
                    if let err = err {
                        Cache.log.error("WebRTCClient.drainIceCandidatesCache - could not add ICE candidate: %@", err.localizedDescription)
                        success = false
                    }
                }
            }
            self.remoteIceCandidatesCache.removeAll()
        }
        if !success {
            self.delegate?.closeCall()
        }
    }

    func createPeerConnection(withDataChannel dataChannel: Bool) -> Bool {
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

        if dataChannel {
            let chanConfig = RTCDataChannelConfiguration()
            chanConfig.isOrdered = true
            self.localDataChannel = localPeer!.dataChannel(forLabel: "events", configuration: chanConfig)
            self.localDataChannel?.delegate = self
        }

        let stream = WebRTCClient.factory.mediaStream(withStreamId: "ARDAMS")
        stream.addAudioTrack(self.localAudioTrack!)
        stream.addVideoTrack(self.localVideoTrack!)
        localPeer!.add(stream)
        return true
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
                    self?.delegate?.closeCall()
                    return
                }

                peerConnection.setLocalDescription(sdp, completionHandler: { [weak self](error) in
                    if let error = error {
                        Cache.log.error("WebRTCClient - failed to set local SDP (answer) %@", error.localizedDescription)
                        self?.delegate?.closeCall()
                        return
                    }
                    self?.delegate?.sendAnswer(withDescription: sdp)
                    self?.delegate?.markConnectionSetupComplete()
                })
            })
    }

    func sendOverDataChannel(event: String) {
        self.localDataChannel?.sendData(RTCDataBuffer(data: Data(event.utf8), isBinary: false))
    }

    func disconnect() {
        localPeer?.close()
        localPeer = nil

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
    private func generateRTCConfig() -> RTCConfiguration? {
        let tinode = Cache.tinode
        guard let iceConfig = tinode.getServerParam(for: "iceServers")?.asArray() else {
            Cache.log.error("WebRTCClient.generateRTCConfig: Missing/invalid iceServers server parameter")
            return nil
        }

        let config = RTCConfiguration()
        // TODO: planB for now. Need to migrate to unified in the future.
        config.sdpSemantics = .planB
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
                return nil
            }
            if let urls = vals["urls"]?.asArray() {
                let iceStrings = urls.compactMap { $0.asString() }
                var ice: RTCIceServer
                if let username = vals["username"]?.asString() {
                    let credential = vals["credential"]?.asString()
                    ice = RTCIceServer(urlStrings: iceStrings, username: username, credential: credential)
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
        guard let track = track else { return }
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
        guard let peerConnection = localPeer else { return }
        peerConnection.setRemoteDescription(desc, completionHandler: { [weak self](error) in
            guard let self = self else { return }
            if let error = error {
                Cache.log.error("WebRTCClient.handleRemoteOfferDescription failure: %@", error.localizedDescription)
                self.delegate?.closeCall()
                return
            }
            self.answer(peerConnection)
        })
    }

    // Processes remote answer SDP.
    func handleRemoteAnswerDescription(_ desc: RTCSessionDescription) {
        self.localPeer?.setRemoteDescription(desc, completionHandler: { (error) in
            if let e = error {
                Cache.log.error("WebRTCClient.handleRemoteAnswerDescription failure: %@", e.localizedDescription)
                self.delegate?.closeCall()
                return
            }
            self.delegate?.markConnectionSetupComplete()
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
        self.delegate?.handleRemoteStream(self, receivedStream: stream)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Cache.log.info("WebRTCClient: Removed media stream %@", stream)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        guard (self.delegate?.canSendOffer() ?? false) && !peerConnection.senders.isEmpty else {
            return
        }
        Cache.log.info("WebRTCClient: negotiating connection")
        self.offer(peerConnection)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .closed:
            fallthrough
        case .failed:
            self.delegate?.closeCall()
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

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Cache.log.info("WebRTCClient: ice rtc gathering state - %d", newState.rawValue)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Cache.log.info("WebRTCClient: new local ice candidate %@", candidate)
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
    private var cameraDenied = false
    let stateLabel = UILabel()
    let flipButton = UIButton(type: .system)
    let backButton = UIButton(type: .system)
    private var captions: [UIButton: UILabel] = [:]
    private var routePicker: UIView?
    private var pip: AnyObject?

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
        linia2UpdateRoute()
        Linia2CallCenter.shared.refreshBanner()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Свёрнут — показать плашку «Идёт звонок».
        Linia2CallCenter.shared.refreshBanner()
    }

    /// Запуск звонка — один раз (экран может быть свёрнут и открыт снова).
    /// Вызывается и без показа экрана: звонок, принятый на заблокированном экране.
    func linia2StartIfNeeded() {
        guard !started, !closed else { return }
        started = true
        loadViewIfNeeded()
        self.permissionsCheck { result in
            DispatchQueue.main.async {
                switch result {
                case .ok:
                    break
                case .micDenied:
                    // Звонок не обрываем: собеседник вас не слышит, пока не разрешите микрофон.
                    Cache.log.error("No permission to access microphone")
                    self.micDenied = true
                    self.linia2PermissionHint("Нет доступа к микрофону — собеседник вас не слышит. Разрешите доступ в Настройках iPhone.")
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
        CallManager.audioSessionChange { session in
            try session.overrideOutputAudioPort(newOutput)
            self.audioOutput = newOutput
        }
        linia2UpdateRoute()
    }

    @IBAction func didToggleMic(_ sender: Any) {
        setMuted(!isMuted)
        Cache.callManager.setMutedInSystem(isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if !isHeld { webRTCClient.setAudioEnabled(!muted) } else { heldRestore?.audio = !muted }
        linia2UpdateButtons()
    }

    @IBAction func didToggleCamera(_ sender: Any) {
        videoToggleButton.isEnabled = false
        if cameraManager.isCapturing {
            cameraManager.stopCapture {
                DispatchQueue.main.async {
                    self.localView.isHidden = true
                    self.webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventMuted)
                    self.videoToggleButton.isEnabled = true
                    self.linia2UpdateButtons()
                }
            }
        } else {
            cameraManager.startCapture {
                DispatchQueue.main.async {
                    self.localView.isHidden = false
                    self.webRTCClient.sendOverDataChannel(event: WebRTCClient.kVideoEventUnmuted)
                    self.videoToggleButton.isEnabled = true
                    self.linia2UpdateButtons()
                }
            }
        }
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
        cameraManager.setupCamera()
        if !self.isAudioOnlyCall && !cameraDenied {
            cameraManager.startCapture()
        }
        setupViews()

        routeChangeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: handleRouteChange)

        webRTCClient.delegate = self
        cameraManager.delegate = self
        Cache.tinode.addListener(self.listener)
        // Prevent screen from dimming/going to sleep.
        UIApplication.shared.isIdleTimerDisabled = true

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
        case micDenied
        case cameraDenied
    }

    private func permissionsCheck(completion: @escaping (PermissionsCheckResult) -> Void) {
        self.checkMicPermissions { success in
            guard success else {
                completion(.micDenied)
                return
            }
            if self.isAudioOnlyCall {
                completion(.ok)
                return
            }
            self.checkCameraPermissions { success in
                completion(success ? .ok : .cameraDenied)
            }
        }
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
                CallManager.audioSessionChange { session in
                    try session.overrideOutputAudioPort(self.audioOutput)
                }
            }
        case .newDeviceAvailable:
            // Подключили AirPods / гарнитуру — звук идёт в них (как на iPhone), динамик выключается.
            self.audioOutput = .none
        default:
            Cache.log.debug("CallVC - audio route change: other - %@, reason: %d", value.description, reason.rawValue)
        }
        DispatchQueue.main.async { self.linia2UpdateRoute() }
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
    func handleCallClose() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleCallClose() }
            return
        }
        guard !closed else { return }
        closed = true
        playSoundEffect(nil)
        uiTimer?.invalidate()
        uiTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        if ownsCall {
            Cache.callManager.completeCallInProgress(reportToSystem: true, reportToPeer: false)
            if self.callSeqId > 0 {
                self.topic?.videoCall(event: "hang-up", seq: self.callSeqId)
            }
        }
        self.callSeqId = -1
        Cache.tinode.removeListener(self.listener)
        stopMedia()
        Linia2CallCenter.shared.callDidEnd(self)
        if self.presentingViewController != nil {
            self.dismiss(animated: true)
        } else if let nav = self.navigationController {
            nav.popViewController(animated: true)
        }
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
            // The callee (we) has accepted the call. Notify the caller.
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
        self.topic?.videoCall(event: "offer", seq: self.callSeqId, payload: sdp.serialize())
    }

    func sendAnswer(withDescription sdp: RTCSessionDescription) {
        self.topic?.videoCall(event: "answer", seq: self.callSeqId, payload: sdp.serialize())
    }

    func sendIceCandidate(_ candidate: RTCIceCandidate) {
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

    func enableMediaControls() {
        DispatchQueue.main.async {
            self.micToggleButton.isEnabled = true
            self.videoToggleButton.isEnabled = true
            self.speakerToggleButton.isEnabled = true
            self.linia2UpdateButtons()
        }
    }

    func markConnectionSetupComplete() {
        self.callInitialSetupComplete = true
        self.webRTCClient.drainIceCandidatesCache()
    }

    func toggleRemoteVideo(remoteLive: Bool) {
        DispatchQueue.main.async {
            self.remoteVideoLive = remoteLive
            self.remoteView.isHidden = !remoteLive
            self.linia2SetAvatarVisible(!remoteLive)
        }
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
        // The callee has informed us (the caller) of the call acceptance.
        guard self.webRTCClient.createPeerConnection(withDataChannel: true) else {
            Cache.log.error("CallVC.handleAcceptedMsg - createPeerConnection failed")
            self.handleCallClose()
            return
        }
    }

    func handleOfferMsg(with payload: JSONValue?) {
        assert(Thread.isMainThread)
        guard case let .dict(offer) = payload, let desc = RTCSessionDescription.deserialize(from: offer) else {
            Cache.log.error("CallVC.handleOfferMsg - invalid offer payload")
            self.handleCallClose()
            return
        }
        // Data channel should be created by the peer. Not creating one.
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
        self.webRTCClient.handleRemoteAnswerDescription(desc)
    }

    func handleIceCandidateMsg(with payload: JSONValue?) {
        assert(Thread.isMainThread)
        guard case let .dict(iceDict) = payload, let candidate = RTCIceCandidate.deserialize(from: iceDict) else {
            Cache.log.error("CallVC.handleIceCandidateMsg - invalid ICE candidate payload")
            self.handleCallClose()
            return
        }
        self.webRTCClient.handleRemoteIceCandidate(candidate, saveInCache: !self.callInitialSetupComplete)
    }

    func handleRemoteHangup() {
        assert(Thread.isMainThread)
        self.playSoundEffect("call-end")
        self.handleCallClose()
    }

    func handleRinging() {
        assert(Thread.isMainThread)
        self.dialingAnimation(on: true)
        self.playSoundEffect("call-out", loop: true)
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
        localViewWidthConstraint.constant = 108
        localViewHeightConstraint.constant = 156
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
            localView.bottomAnchor.constraint(equalTo: grid.topAnchor, constant: -28),

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
        } else if outputs.contains(.builtInSpeaker) || (outputs.isEmpty && audioOutput == .speaker) {
            symbol = "speaker.wave.3.fill"; caption = external ? "Аудио" : "Динамик"; on = !external
        } else {
            symbol = "speaker.wave.1.fill"; caption = external ? "Аудио" : "Динамик"
        }
        linia2Style(speakerToggleButton, symbol: UIImage(systemName: symbol) != nil ? symbol : "speaker.wave.2.fill", on: on, enabled: speakerToggleButton.isEnabled)
        speakerToggleButton.accessibilityValue = on ? "включён" : "выключен"
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
            self.handleCallClose()
        })
        observers.append(nc.addObserver(forName: .linia2CallHeld, object: nil, queue: .main) { [weak self] n in
            self?.setHeld((n.userInfo?["held"] as? Bool) ?? false)
        })
        observers.append(nc.addObserver(forName: .linia2CallMuted, object: nil, queue: .main) { [weak self] n in
            self?.setMuted((n.userInfo?["muted"] as? Bool) ?? false)
        })
        observers.append(nc.addObserver(forName: .linia2CallAudioActivated, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            CallManager.audioSessionChange { s in try s.overrideOutputAudioPort(self.audioOutput) }
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
        stateLabel.textColor = isPoorConnection || isHeld ? L2.hex(0xFFB547) : L2.hex(0xC9D1DE)
        if connectedAt != nil, Int(Date().timeIntervalSince1970) % 2 == 0 { linia2CheckQuality() }
    }

    /// «Плохая связь»: потери входящих пакетов > 10% или RTT > 800 мс (статистика WebRTC, каждые 2 с).
    private func linia2CheckQuality() {
        webRTCClient.statistics { [weak self] report in
            var rtt: Double = 0
            var lost: Double = 0, received: Double = 0
            var fraction: Double = 0
            for (_, st) in report.statistics {
                let v = st.values
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
                let poor = loss > 0.10 || rtt > 0.8
                self.lastStatsPoor = poor
                self.isPoorConnection = poor || self.unstableUntil != nil
                self.stateLabel.text = self.linia2StatusText
                self.stateLabel.textColor = self.isPoorConnection || self.isHeld ? L2.hex(0xFFB547) : L2.hex(0xC9D1DE)
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
