//
//  Linia2WebCallEngine.swift
//  Линия 2.0: звонковый движок WebRTC в WKWebView (вариант Б, features.webCallEngine).
//
//  Медиа и RTCPeerConnection — в локальной странице из бандла (linia2-call.html, тот же порядок, что у веб-CallPanel
//  и гостевой страницы, которые работают в Safari на iPhone). Всё остальное — нативное и не меняется: сигнализация
//  Tinode (videoCall offer/answer/ice-candidate/hang-up), CallKit/PushKit, экран и кнопки звонка, переподключение,
//  TURN-данные (/invite/api/turn → Linia2Turn), диагностика (call-diag).
//
//  Встроено в WebRTCClient: если движок включён (`client.web != nil`), методы WebRTCClient передают команды в JS,
//  а события JS превращаются в те же вызовы WebRTCClientDelegate, что и у нативного движка — экран звонка
//  (CallViewController) не знает, какой движок работает. Выключить — features.webCallEngine=false в app-config
//  (без сборки, со следующего звонка).
//
//  App Store 2.5.2: страница и скрипт — только из бандла (loadHTMLString), сеть страницей не используется
//  (кроме WebRTC-медиа); baseURL https — чтобы страница была «безопасным контекстом» для getUserMedia.
//

import AVFoundation
import UIKit
import WebKit
import WebRTC

final class Linia2WebCallEngine: NSObject {
    /// Флаг удалённого конфига. По умолчанию — выключен (нативный движок); включить — features.webCallEngine=true в app-config.
    static var enabled: Bool {
        if #available(iOS 15.0, *) {
            return Linia2Config.shared.feature("webCallEngine", default: false)
        }
        return false   // до iOS 15 нет requestMediaCapturePermissionFor — только нативный движок
    }

    private(set) var webView: WKWebView!
    private weak var client: WebRTCClient?
    private var loaded = false
    /// Страница прислала «ready» (скрипт исполняется).
    var isReady: Bool { loaded }
    /// Вызывается один раз при «ready» (выбор движка на экране звонка).
    var onReady: (() -> Void)?
    private let loadStarted = Date()
    private var audioObservers: [NSObjectProtocol] = []
    private var pending: [String] = []
    private var closed = false
    /// LINIA2 (звук 1012): команды ждут, пока CallKit не активирует AVAudioSession (см. start).
    private var gated = false
    private var gateObserver: NSObjectProtocol?
    /// Последняя статистика JS (для call-diag и «Плохая связь»).
    private(set) var lastStats: [String: Any] = [:]
    private(set) var iceState: String = "none"
    private(set) var signalingState: String = "none"
    private(set) var hasAudio = false
    private(set) var hasVideo = false
    private(set) var audioEnabled = true
    private(set) var videoEnabled = false
    /// Контейнер на экране звонка (nil — экран ещё не показан: звонок принят на заблокированном экране).
    private weak var container: UIView?
    private weak var belowView: UIView?
    private var lastLocalRect: CGRect?

    init(client: WebRTCClient) {
        self.client = client
        super.init()
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = false
        cfg.websiteDataStore = WKWebsiteDataStore.nonPersistent()   // LINIA2: ничего от движка звонка на диск (кэш, хранилище страницы)
        cfg.userContentController.add(WeakHandler(self), name: "l2call")
        let wv = WKWebView(frame: UIScreen.main.bounds, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.isUserInteractionEnabled = false
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.accessibilityIdentifier = "l2.call.webEngine"
        webView = wv
        // WebKit не даёт микрофон/камеру странице вне окна — до показа экрана держим её в окне приложения (невидимо).
        parkInWindow()
        guard let url = Bundle.main.url(forResource: "linia2-call", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            Cache.log.error("Linia2WebCallEngine: linia2-call.html not found in bundle")
            client.onDiagEvent?(["type": "error", "where": "web-bundle"])
            return
        }
        client.onDiagEvent?(["type": "web-load", "app": Self.appState()])
        observeAudioSession()
        wv.loadHTMLString(html, baseURL: URL(string: "https://v2.chat-linia.site/linia2-call/"))
    }

    // MARK: Размещение

    /// Показать картинку движка на экране звонка (под видом `below`, т.е. под затемнением и кнопками).
    /// Пока экран не в окне (звонок принят на заблокированном экране, экран свёрнут) — страница остаётся в окне приложения.
    func attach(to view: UIView, below: UIView?) {
        container = view
        belowView = below
        guard view.window != nil else { parkInWindow(); return }
        if webView.superview === view { return }
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let b = below, b.superview === view { view.insertSubview(webView, belowSubview: b) } else { view.insertSubview(webView, at: 0) }
    }

    /// Экран звонка скрыт (свёрнут) — увести страницу в окно приложения, чтобы WebKit не остановил медиа.
    func park() {
        guard !closed else { return }
        container = nil
        parkInWindow()
    }

    /// Экран не показан — страница живёт в окне приложения за всеми видами (размер 2×2, почти прозрачная).
    private func parkInWindow() {
        guard container == nil || container?.window == nil else { return }
        lastLocalRect = nil
        var win: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            if let k = ws.windows.first(where: { w in w.isKeyWindow }) { win = k; break }
            if win == nil { win = ws.windows.first }
        }
        guard let w = win else { return }
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        webView.alpha = 0.01
        w.insertSubview(webView, at: 0)
    }

    /// Положение своего видео (окошко localView) — в координатах страницы.
    func setLocalRect(_ r: CGRect?) {
        guard r != lastLocalRect else { return }
        lastLocalRect = r
        guard let r = r, r.width > 0 else { call("setLocalRect", nil); return }
        call("setLocalRect", ["x": r.origin.x, "y": r.origin.y, "w": r.width, "h": r.height])
    }

    // MARK: Команды → JS

    func call(_ name: String, _ arg: Any?) {
        guard !closed || name == "close" || name == "muteAll" else { return }
        var argJs = "null"
        if let a = arg {
            if JSONSerialization.isValidJSONObject(a), let d = try? JSONSerialization.data(withJSONObject: a), let s = String(data: d, encoding: .utf8) {
                argJs = s
            } else if let b = a as? Bool {
                argJs = b ? "true" : "false"
            } else if let s = a as? String, let d = try? JSONSerialization.data(withJSONObject: [s]), let arr = String(data: d, encoding: .utf8) {
                argJs = String(arr.dropFirst().dropLast())
            }
        }
        let js = "window.L2Call&&L2Call.cmd(\(Self.jsString(name)),\(argJs))"
        if loaded && (!gated || name == "close" || name == "muteAll") {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending.append(js)
        }
    }

    static func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .background: return "background"
        default: return "inactive"
        }
    }

    private static func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }

    /// `established` — переход «нативный → WKWebView» посреди уже соединённого звонка (ошибки — ICE restart, не отбой).
    func start(audioOnly: Bool, caller: Bool, video: Bool, established: Bool = false) {
        videoEnabled = video
        // LINIA2 (звук 1012, call_diag 766/769): getUserMedia шёл ДО активации AVAudioSession CallKit-ом; активация
        // посреди захвата глушила трек (muted навсегда, 0 пакетов RTP). Теперь с CallKit — сначала «звук включён»
        // (didActivate → .linia2CallAudioActivated), потом getUserMedia; не дождались за kGateTimeout — как раньше.
        if CallManager.useCallKit && !CallManager.linia2AudioActive && gateObserver == nil {
            gated = true
            let t0 = Date()
            client?.onDiagEvent?(["type": "web-gate", "state": "wait-audio", "app": Self.appState()])
            gateObserver = NotificationCenter.default.addObserver(forName: .linia2CallAudioActivated, object: nil, queue: .main) { [weak self] _ in
                self?.openGate("activated", t0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.kGateTimeout) { [weak self] in self?.openGate("timeout", t0) }
        }
        var cfg: [String: Any] = ["audioOnly": audioOnly, "caller": caller, "video": video]
        if established { cfg["established"] = true }
        call("start", cfg)
    }

    static let kGateTimeout: TimeInterval = 2.5

    private func openGate(_ why: String, _ t0: Date) {
        if let o = gateObserver { NotificationCenter.default.removeObserver(o) }
        gateObserver = nil
        guard gated else { return }
        gated = false
        client?.onDiagEvent?(["type": "web-gate", "state": "open", "why": why, "ms": Int(Date().timeIntervalSince(t0) * 1000),
                              "pending": pending.count, "loaded": loaded])
        guard loaded, !closed else { return }
        let list = pending
        pending.removeAll()
        list.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
    }

    /// CallKit включил звук (didActivate): снять «mute» захвата WebKit и сказать странице «звук есть».
    func linia2AudioActivated() {
        reactivateCapture("activated")
        call("audioResume", ["reason": "activated"])
    }

    /// LINIA2 (звук 1012): WebKit глушит захват микрофона/камеры при прерывании AVAudioSession (активация CallKit,
    /// GSM-звонок) и сам не всегда снимает — включаем захват явно (iOS 15+), состояние до/после — в диагностику.
    func reactivateCapture(_ why: String) {
        guard !closed else { return }
        if #available(iOS 15.0, *) {
            let wv = webView!
            let mic0 = Self.captureName(wv.microphoneCaptureState), cam0 = Self.captureName(wv.cameraCaptureState)
            let wantCam = videoEnabled && wv.cameraCaptureState == .muted
            let wantMic = wv.microphoneCaptureState == .muted
            client?.onDiagEvent?(["type": "web-capture-state", "why": why, "mic": mic0, "cam": cam0,
                                  "action": wantMic || wantCam ? "activate" : "none", "app": Self.appState()])
            let report: () -> Void = { [weak self, weak wv] in
                guard let self = self, let wv = wv else { return }
                self.client?.onDiagEvent?(["type": "web-capture-state", "why": why + "-after",
                                           "mic": Self.captureName(wv.microphoneCaptureState),
                                           "cam": Self.captureName(wv.cameraCaptureState)])
            }
            if wantMic { wv.setMicrophoneCaptureState(.active) { report() } }
            if wantCam { wv.setCameraCaptureState(.active) { if !wantMic { report() } } }
        }
    }

    @available(iOS 15.0, *)
    private static func captureName(_ s: WKMediaCaptureState) -> String {
        switch s {
        case .none: return "none"
        case .active: return "active"
        case .muted: return "muted"
        @unknown default: return "?"
        }
    }

    func createPeerConnection(iceServers: [RTCIceServer], relayOnly: Bool, dataChannel: Bool) {
        call("createPC", ["ice": Self.iceJSON(iceServers), "policy": relayOnly ? "relay" : "all", "dc": dataChannel])
    }

    func restartIce(iceServers: [RTCIceServer], relayOnly: Bool) {
        call("restartIce", ["ice": Self.iceJSON(iceServers), "relay": relayOnly])
    }

    func setAudio(_ on: Bool) { audioEnabled = on; call("setAudio", on) }
    func setCamera(_ on: Bool) { videoEnabled = on; call("setCamera", on) }
    func setVideoEnabled(_ on: Bool) { videoEnabled = on; call("setVideoEnabled", on) }

    /// AVAudioSession: прерывания (GSM-звонок, Siri, другой звук) и смена выхода — в диагностику; после прерывания —
    /// странице «звук снова есть» (play звука собеседника, проверка/перезапрос микрофона).
    private func observeAudioSession() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        audioObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            guard let self = self else { return }
            let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let began = t == .began
            self.client?.onDiagEvent?(["type": "audio-interruption", "state": began ? "began" : "ended", "engine": "web", "app": Self.appState()])
            if !began {
                self.reactivateCapture("interruption-ended")
                self.call("audioResume", ["reason": "interruption-ended"])
            }
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            let r = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none"
            let inp = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none"
            self?.client?.onDiagEvent?(["type": "audio-route", "reason": Int(r), "out": out, "in": inp,
                                        "cat": AVAudioSession.sharedInstance().category.rawValue, "engine": "web"])
        })
    }

    func close() {
        guard !closed else { return }
        audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
        audioObservers.removeAll()
        if let o = gateObserver { NotificationCenter.default.removeObserver(o) }
        gateObserver = nil
        gated = false
        if !CallManager.linia2AudioActive { CallManager.linia2WebAudio = false }
        call("muteAll", nil)
        call("close", nil)
        closed = true
        let wv = webView
        // Дать JS закрыть соединение и отпустить микрофон/камеру, затем убрать страницу.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            wv?.configuration.userContentController.removeScriptMessageHandler(forName: "l2call")
            wv?.removeFromSuperview()
        }
    }

    static func iceJSON(_ list: [RTCIceServer]) -> [[String: Any]] {
        list.map { s in
            var d: [String: Any] = ["urls": s.urlStrings]
            if let u = s.username { d["username"] = u }
            if let c = s.credential { d["credential"] = c }
            return d
        }
    }

    // MARK: События JS → WebRTCClient

    fileprivate func handle(_ body: Any) {
        guard let m = body as? [String: Any], let t = m["t"] as? String, let client = client else { return }
        switch t {
        case "ready":
            loaded = true
            client.onDiagEvent?(["type": "web-ready", "engine": "web", "app": Self.appState(),
                                 "ms_load": Int(Date().timeIntervalSince(loadStarted) * 1000), "pending": pending.count])
            if !gated {
                let list = pending
                pending.removeAll()
                list.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
            }
            let r = onReady
            onReady = nil
            r?()
            // CallKit включил звук раньше, чем загрузилась страница, — сразу «звук есть».
            if CallManager.linia2AudioActive { call("audioResume", ["reason": "ready-active"]) }
        case "offer":
            if let d = m["sdp"] as? [String: Any], let sdp = d["sdp"] as? String {
                client.delegate?.sendOffer(withDescription: RTCSessionDescription(type: .offer, sdp: sdp))
            }
        case "answer":
            if let d = m["sdp"] as? [String: Any], let sdp = d["sdp"] as? String {
                client.delegate?.sendAnswer(withDescription: RTCSessionDescription(type: .answer, sdp: sdp))
            }
        case "ice":
            if let c = m["c"] as? [String: Any], let s = c["candidate"] as? String {
                let idx = (c["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
                client.delegate?.sendIceCandidate(RTCIceCandidate(sdp: s, sdpMLineIndex: idx, sdpMid: c["sdpMid"] as? String))
            }
        case "setupComplete":
            let remoteOffer = (m["remoteOffer"] as? Bool) ?? false
            client.linia2WebSetupComplete(remoteOffer: remoteOffer)
        case "iceState":
            let s = (m["state"] as? String) ?? ""
            iceState = s
            client.linia2WebIceState(s)
        case "signaling":
            let s = (m["state"] as? String) ?? ""
            signalingState = s
            if s == "stable" { client.delegate?.enableMediaControls() }
        case "dc":
            let ev = (m["ev"] as? String) ?? ""
            if ev == WebRTCClient.kVideoEventMuted {
                client.delegate?.toggleRemoteVideo(remoteLive: false)
            } else if ev == WebRTCClient.kVideoEventUnmuted {
                client.delegate?.toggleRemoteVideo(remoteLive: true)
            }
        case "negFailed":
            let stage = (m["stage"] as? String) ?? "web"
            client.delegate?.linia2NegotiationFailed(stage)
        case "close":
            client.onDiagEvent?(["type": "error", "where": (m["why"] as? String) ?? "web-close"])
            client.delegate?.closeCall()
        case "media":
            hasAudio = (m["audio"] as? Bool) ?? false
            hasVideo = (m["video"] as? Bool) ?? false
            client.onDiagEvent?(["type": "web-media", "audio": hasAudio, "video": hasVideo, "app": Self.appState(),
                                 "amuted": (m["amuted"] as? Bool) ?? false, "vmuted": (m["vmuted"] as? Bool) ?? false])
        case "capMuted":
            // Захват заглушён WebKit-ом (трек muted) — включить явно; страница через 1,2 с перезахватит сама.
            reactivateCapture("track-muted-" + ((m["kind"] as? String) ?? "?") + "-" + ((m["why"] as? String) ?? ""))
        case "cameraFailed":
            client.onDiagEvent?(["type": "error", "where": "web-camera"])
        case "stats":
            if let s = m["s"] as? [String: Any] { lastStats = s }
        case "diag":
            if var ev = m["ev"] as? [String: Any] {
                ev["engine"] = "web"
                ev["app"] = Self.appState()
                client.onDiagEvent?(ev)
            }
        default:
            break
        }
    }
}

// MARK: - WKWebView: разрешения и загрузка

extension Linia2WebCallEngine: WKUIDelegate, WKNavigationDelegate {
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Системное разрешение на микрофон/камеру спрашивает экран звонка; странице — без повторного запроса.
        decisionHandler(.grant)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Только наша страница: никаких переходов и загрузок.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        client?.onDiagEvent?(["type": "web-nav", "state": "finish", "app": Self.appState(),
                              "ms_load": Int(Date().timeIntervalSince(loadStarted) * 1000)])
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        client?.onDiagEvent?(["type": "error", "where": "web-nav-fail", "msg": String(error.localizedDescription.prefix(80)), "app": Self.appState()])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        client?.onDiagEvent?(["type": "error", "where": "web-nav-fail0", "msg": String(error.localizedDescription.prefix(80)), "app": Self.appState()])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Процесс WebKit упал (память/фон) — звонок продолжать нечем.
        Cache.log.error("Linia2WebCallEngine: web content process terminated")
        client?.onDiagEvent?(["type": "error", "where": "web-process-terminated"])
        if !closed { client?.delegate?.closeCall() }
    }
}

/// WKUserContentController держит обработчик сильно — разрываем цикл.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var engine: Linia2WebCallEngine?
    init(_ e: Linia2WebCallEngine) { engine = e }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        DispatchQueue.main.async { [weak self] in self?.engine?.handle(body) }
    }
}
