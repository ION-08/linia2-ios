//
//  Linia2CallCenter.swift
//  Линия 2.0: текущий звонок вне экрана звонка —
//   • Linia2CallCenter: открыть / свернуть / вернуть экран звонка, зелёная плашка «Идёт звонок 01:23»
//     над всеми экранами (id l2.call.banner), принятие входящего на заблокированном экране;
//   • Linia2CallPiP: картинка-в-картинке видеозвонка (AVPictureInPictureController + AVSampleBufferDisplayLayer);
//   • Linia2Voip: регистрация VoIP-токена PushKit на сервере (POST /invite/api/voip-token).
//

import AVFoundation
import AVKit
import TinodeSDK
import TinodiosDB
import UIKit
import WebRTC

// MARK: - Текущий звонок

final class Linia2CallCenter {
    static let shared = Linia2CallCenter()

    /// Экран текущего звонка (держим его, пока звонок идёт, даже если он свёрнут).
    private(set) var active: CallViewController?
    private let banner = Linia2CallBanner()
    private var tick: Timer?
    private var bannerShown = false
    /// Звонок принят, когда приложение было неактивно — показать экран при открытии.
    private var presentWhenActive = false
    /// LINIA2: экран звонка свёрнут пользователем («Чат») — PIN-блокировка больше не откладывается.
    private(set) var minimizedByUser = false

    private init() {
        banner.addTarget(self, action: #selector(bannerTapped), for: .touchUpInside)
    }

    /// Подключены AirPods / Bluetooth / проводные наушники / автомобиль.
    static func hasExternalOutput() -> Bool {
        let s = AVAudioSession.sharedInstance()
        let ext: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .headsetMic, .carAudio, .usbAudio, .airPlay]
        if s.currentRoute.outputs.contains(where: { ext.contains($0.portType) }) { return true }
        return (s.availableInputs ?? []).contains(where: { ext.contains($0.portType) })
    }

    func register(_ vc: CallViewController) {
        if let cur = active, cur !== vc, !cur.closed {
            // Новый экран, а старый звонок ещё идёт — новый сам закроется (CallManager занят).
            return
        }
        active = vc
        startTicking()
    }

    func callDidEnd(_ vc: CallViewController) {
        guard active === vc else { return }
        active = nil
        presentWhenActive = false
        minimizedByUser = false
        DispatchQueue.main.async { Linia2AppLock.shared.callDidEnd() }
        refreshBanner()
        tick?.invalidate()
        tick = nil
    }

    // MARK: Входящий (CallKit «Принять» или алерт в автотестах)

    func openIncoming(_ call: CallManager.Call) {
        DispatchQueue.main.async {
            self.waitForTopic(call.topic, attempts: 50) { topic in
                guard let topic = topic else {
                    Cache.log.error("Linia2CallCenter: topic %@ unavailable, ending call", call.topic)
                    Cache.callManager.completeCallInProgress(reportToSystem: true, reportToPeer: true)
                    UiUtils.showToast(message: "Не удалось подключиться к звонку")
                    return
                }
                let sb = UIStoryboard(name: "Main", bundle: nil)
                guard let vc = sb.instantiateViewController(withIdentifier: "CallViewController") as? CallViewController else { return }
                vc.topic = topic
                vc.callDirection = .incoming
                vc.callSeqId = call.seq
                vc.isAudioOnlyCall = call.audioOnly
                vc.loadViewIfNeeded()
                // Соединяемся сразу — разговор идёт и на заблокированном экране.
                vc.linia2StartIfNeeded()
                if UIApplication.shared.applicationState == .active {
                    // Под экраном звонка — чат с собеседником (как раньше).
                    UiUtils.routeToMessageVC(forTopic: call.topic) { _ in
                        self.present(vc)
                    }
                } else {
                    self.presentWhenActive = true
                }
            }
        }
    }

    private func waitForTopic(_ name: String, attempts: Int, completion: @escaping (DefaultComTopic?) -> Void) {
        let tinode = Cache.tinode
        if tinode.isConnectionAuthenticated, let t = tinode.getTopic(topicName: name) as? DefaultComTopic {
            completion(t)
            return
        }
        guard attempts > 0 else { completion(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.waitForTopic(name, attempts: attempts - 1, completion: completion)
        }
    }

    func applicationDidBecomeActive() {
        guard presentWhenActive, let vc = active, !vc.closed else { return }
        presentWhenActive = false
        if let topic = vc.topic?.name {
            UiUtils.routeToMessageVC(forTopic: topic) { _ in self.present(vc) }
        } else {
            present(vc)
        }
    }

    // MARK: Свернуть / вернуть

    private static func topController() -> UIViewController? {
        var top = Linia2Root.window?.rootViewController
        while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }

    private func present(_ vc: CallViewController) {
        guard !vc.closed, vc.presentingViewController == nil, vc.parent == nil else { return }
        guard let top = Self.topController() else { return }
        if top is UIAlertController {
            top.dismiss(animated: false) { self.present(vc) }
            return
        }
        vc.modalPresentationStyle = .fullScreen
        minimizedByUser = false
        Linia2AppLock.shared.suspendForCall()
        top.present(vc, animated: true)
        refreshBanner()
    }

    /// «Чат» на экране звонка: экран прячется, звонок продолжается, сверху — плашка.
    func minimize() {
        guard let vc = active else { return }
        minimizedByUser = true
        if vc.presentingViewController != nil {
            vc.dismiss(animated: true) { self.refreshBanner() }
        } else {
            vc.navigationController?.popViewController(animated: true)
        }
        refreshBanner()
        Linia2AppLock.shared.callScreenMinimized()
    }

    /// Нажатие на плашку — вернуться к звонку (с любого экрана).
    func showActiveCall() {
        guard let vc = active, !vc.closed else { return }
        present(vc)
    }

    @objc private func bannerTapped() {
        L2.haptic()
        showActiveCall()
    }

    // MARK: Плашка «Идёт звонок»

    private func startTicking() {
        guard tick == nil else { return }
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshBanner() }
    }

    func refreshBanner() {
        guard let window = Linia2Root.window else { return }
        let vc = active
        let show = vc != nil && !(vc!.closed) && vc!.started && vc!.viewIfLoaded?.window == nil
        let root = window.rootViewController
        if show {
            if banner.superview !== window { window.addSubview(banner) }
            window.bringSubviewToFront(banner)
            let top = window.safeAreaInsets.top
            banner.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: top + Linia2CallBanner.height)
            banner.contentTop = top
            banner.text = vc!.linia2StatusText
            if !bannerShown {
                bannerShown = true
                banner.alpha = 0
                UIView.animate(withDuration: 0.25) { self.banner.alpha = 1 }
            }
            // Экран (вкладки, чат) сдвигается вниз — плашка ничего не закрывает.
            if let root = root, root.additionalSafeAreaInsets.top != Linia2CallBanner.height {
                root.additionalSafeAreaInsets.top = Linia2CallBanner.height
            }
        } else {
            if bannerShown {
                bannerShown = false
                banner.removeFromSuperview()
            }
            if let root = root, root.additionalSafeAreaInsets.top == Linia2CallBanner.height {
                root.additionalSafeAreaInsets.top = 0
            }
        }
    }
}

/// Зелёная плашка «Идёт звонок 01:23» — сверху, над вкладками; нажатие возвращает к звонку.
final class Linia2CallBanner: UIControl {
    static let height: CGFloat = 34
    private let label = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "phone.fill"))
    private var topConstraint: NSLayoutConstraint!

    var text: String = "" {
        didSet {
            label.text = text
            accessibilityLabel = text + ". Вернуться к звонку"
        }
    }
    var contentTop: CGFloat = 0 {
        didSet { topConstraint.constant = contentTop }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = L2.hex(0x1FA463)
        accessibilityIdentifier = "l2.call.banner"
        isAccessibilityElement = true
        accessibilityTraits = .button
        label.font = L2.font(15, .semibold)
        label.textColor = .white
        label.isUserInteractionEnabled = false
        icon.tintColor = .white
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 8
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        topConstraint = row.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            row.heightAnchor.constraint(equalToConstant: Linia2CallBanner.height),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.75 : 1 }
    }
}

// MARK: - Картинка-в-картинке (видеозвонок)

@available(iOS 15.0, *)
final class Linia2CallPiP: NSObject, AVPictureInPictureControllerDelegate {
    let renderer = Linia2SampleBufferRenderer()
    private var controller: AVPictureInPictureController?
    private let contentVC = AVPictureInPictureVideoCallViewController()

    init(sourceView: UIView) {
        super.init()
        contentVC.preferredContentSize = CGSize(width: 720, height: 1280)
        let v = renderer.view
        v.frame = contentVC.view.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentVC.view.addSubview(v)
        contentVC.view.backgroundColor = .black
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: sourceView, contentViewController: contentVC)
        let c = AVPictureInPictureController(contentSource: source)
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c
    }

    func stop() {
        controller?.stopPictureInPicture()
        controller = nil
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        renderer.isPiPActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        renderer.isPiPActive = false
    }

    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Linia2CallCenter.shared.showActiveCall()
        completionHandler(true)
    }
}

/// Слой AVSampleBufferDisplayLayer внутри обычного UIView.
final class Linia2SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// RTCVideoRenderer → CMSampleBuffer → AVSampleBufferDisplayLayer (для окна PiP).
final class Linia2SampleBufferRenderer: NSObject, RTCVideoRenderer {
    let view: Linia2SampleBufferView = {
        let v = Linia2SampleBufferView()
        v.displayLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = .black
        return v
    }()
    var isPiPActive = false
    private var frameCount = 0
    private var rotation: RTCVideoRotation = ._0

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame = frame else { return }
        frameCount += 1
        // Пока окно PiP не открыто — обновляем слой редко (чтобы в нём была картинка для старта PiP).
        let appActive = Thread.isMainThread ? UIApplication.shared.applicationState == .active : true
        if !isPiPActive && appActive && frameCount % 15 != 0 { return }
        let pixelBuffer: CVPixelBuffer?
        if let b = frame.buffer as? RTCCVPixelBuffer {
            pixelBuffer = b.pixelBuffer
        } else {
            pixelBuffer = Self.nv12(from: frame.buffer.toI420())
        }
        guard let pb = pixelBuffer, let sample = Self.sampleBuffer(pb) else { return }
        let rot = frame.rotation
        DispatchQueue.main.async {
            if rot != self.rotation {
                self.rotation = rot
                let angle: CGFloat
                switch rot {
                case ._90: angle = .pi / 2
                case ._180: angle = .pi
                case ._270: angle = -.pi / 2
                default: angle = 0
                }
                self.view.displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            }
            let layer = self.view.displayLayer
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
    }

    private static func sampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let fmt = format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let s = sample else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return s
    }

    /// I420 (VP8/VP9) → NV12 CVPixelBuffer.
    private static func nv12(from i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let w = Int(i420.width), h = Int(i420.height)
        guard w > 0, h > 0 else { return nil }
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &out) == kCVReturnSuccess,
              let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let yDst = yBase.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let srcY = i420.dataY, srcU = i420.dataU, srcV = i420.dataV
        let sY = Int(i420.strideY), sU = Int(i420.strideU), sV = Int(i420.strideV)
        for row in 0..<h {
            memcpy(yDst + row * yStride, srcY + row * sY, w)
        }
        let uvDst = uvBase.assumingMemoryBound(to: UInt8.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        for row in 0..<ch {
            let d = uvDst + row * uvStride
            let u = srcU + row * sU
            let v = srcV + row * sV
            for col in 0..<cw {
                d[2 * col] = u[col]
                d[2 * col + 1] = v[col]
            }
        }
        return pb
    }
}

// MARK: - VoIP-токен (PushKit) → сервер

/// Сервер (linia2-auth) хранит VoIP-токены устройств пользователя и при приглашении в звонок шлёт
/// VoIP push напрямую в APNs (FCM VoIP не доставляет). Авторизация — токеном Tinode пользователя.
final class Linia2Voip {
    static let shared = Linia2Voip()
    private let kToken = "linia2.voip.token"
    private let kSent = "linia2.voip.sent"   // "uid|token|время"
    private var retries = 0

    private var token: String? {
        get { UserDefaults.standard.string(forKey: kToken) }
        set { UserDefaults.standard.set(newValue, forKey: kToken) }
    }

    private static var env: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func update(token data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        if hex != token {
            token = hex
            UserDefaults.standard.removeObject(forKey: kSent)
        }
        register()
    }

    /// Отправить токен на сервер (раз в сутки или при смене токена / пользователя).
    func register() {
        DispatchQueue.main.async { self.registerNow() }
    }

    private func registerNow() {
        guard let token = token else { return }
        let tinode = Cache.tinode
        guard let auth = tinode.authToken, !auth.isEmpty, let uid = tinode.myUid else {
            // Ещё не вошли — повторить позже.
            if retries < 8 {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.registerNow() }
            }
            return
        }
        retries = 0
        let now = Int(Date().timeIntervalSince1970)
        if let sent = UserDefaults.standard.string(forKey: kSent) {
            let p = sent.split(separator: "|")
            if p.count == 3, p[0] == uid, p[1] == token, let t = Int(p[2]), now - t < 86400 { return }
        }
        Linia2API.post("voip-token", ["token": token, "env": Self.env], token: auth) { status, json in
            if status == 200, (json?["ok"] as? Bool) == true {
                UserDefaults.standard.set("\(uid)|\(token)|\(now)", forKey: self.kSent)
                Cache.log.info("Linia2Voip: VoIP token registered")
            } else {
                Cache.log.error("Linia2Voip: register failed, status %d", status)
            }
        }
    }

    /// Выход из аккаунта: сервер больше не шлёт звонки на это устройство.
    func unregister() {
        UserDefaults.standard.removeObject(forKey: kSent)
        guard let token = token, let auth = Cache.tinode.authToken, !auth.isEmpty else { return }
        Linia2API.post("voip-token", ["token": token, "env": Self.env, "remove": true], token: auth) { _, _ in }
    }

    func invalidate() {
        unregister()
        token = nil
    }

    /// LINIA2: идёт ли ещё звонок `seq` в личном чате `topic` (usr…) — по базе сервера.
    /// completion (главный поток): "ringing" | "accepted" | "ended" | "unknown"; nil — нет ответа / не вошли.
    func checkCall(topic: String, seq: Int, completion: @escaping (String?) -> Void) {
        let auth = Cache.tinode.authToken ?? SharedUtils.getAuthToken()
        guard topic.hasPrefix("usr"), seq > 0, let token = auth, !token.isEmpty else { completion(nil); return }
        Linia2API.post("voip-token", ["check_call": ["topic": topic, "seq": seq]], token: token) { status, json in
            completion(status == 200 ? json?["state"] as? String : nil)
        }
    }
}
