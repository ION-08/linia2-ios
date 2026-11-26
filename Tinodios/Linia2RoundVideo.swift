//
//  Linia2RoundVideo.swift
//  Линия 2.0: видео-кружочки (features.roundVideo).
//
//  Формат — CONTRACTS-next.md, раздел 1 (общий с вебом): обычное видео-вложение Drafty «VD» с data.round = true
//  (+ duration в мс, width/height 384), в head — "linia2-round": 1 и "linia2-ttl": roundVideo.ttlDays × 86400
//  (сервер удаляет у всех через N дней, по умолчанию 7). Признак кружка — любой из двух.
//  Запись: кнопка микрофона по нажатию переключается на камеру; удержание — запись (фронтальная камера,
//  384×384 H.264, до roundVideo.maxSeconds = 60 с), отпустить — отправить, смахнуть влево — отменить.
//  В чате кружок играет по кругу без звука; нажатие — со звуком с начала, ещё нажатие — снова без звука.
//

import AVFoundation
import UIKit
import TinodeSDK
import TinodiosDB

enum Linia2Round {
    static var featureOn: Bool { Linia2Config.shared.feature("roundVideo") }
    /// Срок хранения кружков, дней (roundVideo.ttlDays, 0 — без срока).
    static var ttlDays: Int { Int(min(365, max(0, Linia2Config.shared.number("roundVideo", "ttlDays") ?? 7))) }
    static var maxSeconds: Double { min(60, max(3, Linia2Config.shared.number("roundVideo", "maxSeconds") ?? 60)) }
    static var side: Int { Int(min(640, max(240, Linia2Config.shared.number("roundVideo", "size") ?? 384))) }
    static var videoBitrate: Int { Int(min(2000, max(150, Linia2Config.shared.number("roundVideo", "videoKbps") ?? 400))) * 1000 }
    static let kHeadRound = "linia2-round"
    private static let kFirstSent = "linia2.rv.hint"
    private static let kMode = "linia2.rv.mode"

    /// Выбор кнопки записи запоминается на устройстве: mic | video.
    static var cameraMode: Bool {
        get { featureOn && UserDefaults.standard.string(forKey: kMode) == "video" }
        set { UserDefaults.standard.set(newValue ? "video" : "mic", forKey: kMode) }
    }

    static var isUITest: Bool { ProcessInfo.processInfo.arguments.contains("-l2-uitest") }

    /// Сущность VD кружка: data.round = true или head linia2-round = 1.
    static func roundEntity(_ m: Message) -> (Int, Entity)? {
        guard let ents = m.content?.entities else { return nil }
        var headRound = false
        switch m.head?[kHeadRound] {
        case .int(1)?, .int64(1)?, .bool(true)?, .string("1")?: headRound = true
        default: break
        }
        for (i, e) in ents.enumerated() where e.tp == "VD" {
            if headRound { return (i, e) }
            switch e.data?["round"] {
            case .bool(true)?, .int(1)?, .string("true")?: return (i, e)
            default: continue
            }
        }
        return nil
    }

    static func isWebM(_ e: Entity) -> Bool { (e.data?["mime"]?.asString() ?? "").lowercased().contains("webm") }

    static func markRound(_ d: Drafty?) -> Drafty? {
        for e in d?.entities ?? [] where e.tp == "VD" {
            if e.data == nil { e.data = [:] }
            e.data?["round"] = .bool(true)
        }
        return d
    }

    /// Заголовок для кружка: признак и срок хранения.
    static var head: [String: JSONValue] {
        var h: [String: JSONValue] = [kHeadRound: .int(1)]
        if ttlDays > 0 { h[Linia2Disappearing.kHeader] = .int(ttlDays * 86400) }
        return h
    }

    /// Подсказка «Видео хранится 7 дней» — один раз на устройстве, при первой отправке.
    static func noteFirstSend() {
        guard !UserDefaults.standard.bool(forKey: kFirstSent) else { return }
        UserDefaults.standard.set(true, forKey: kFirstSent)
        let d = ttlDays
        guard d > 0 else { return }
        let text = L2T("l2.rv.keep", "Видео хранится {days}").replacingOccurrences(of: "{days}", with: ruDays(d))
        UiUtils.showToast(message: text, duration: 4, level: .info)
    }

    /// «1 день», «3 дня», «7 дней».
    static func ruDays(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let w = (m10 == 1 && m100 != 11) ? "день" : ((2...4).contains(m10) && !(12...14).contains(m100)) ? "дня" : "дней"
        return "\(n) \(w)"
    }

    /// Сколько дней осталось (по head linia2-ttl и времени сообщения).
    static func daysLeft(_ m: Message) -> Int? {
        guard let v = m.head?[Linia2Disappearing.kHeader], let ts = m.ts else { return nil }
        var secs: Double = 0
        switch v {
        case .int(let i): secs = Double(i)
        case .int64(let i): secs = Double(i)
        case .double(let d): secs = d
        case .string(let s): secs = Double(s) ?? 0
        default: return nil
        }
        guard secs > 0 else { return nil }
        let left = ts.addingTimeInterval(secs).timeIntervalSinceNow
        return max(0, Int(ceil(left / 86400)))
    }

    static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("l2round", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - Кружок в ленте

final class Linia2RoundVideoView: UIView {
    static let kDiameter: CGFloat = 220
    private static var cache: [String: Linia2RoundVideoView] = [:]
    private static var order: [String] = []

    /// Один вид на сообщение (чтобы перерисовка ячейки не обрывала звук).
    static func view(for key: String) -> Linia2RoundVideoView {
        if let v = cache[key] { return v }
        let v = Linia2RoundVideoView()
        cache[key] = v
        order.append(key)
        while order.count > 16 {
            let old = order.removeFirst()
            cache[old]?.stop()
            cache[old] = nil
        }
        return v
    }

    private let poster = UIImageView()
    private let playerLayer = AVPlayerLayer()
    private let badge = PaddedLabelL2()
    /// «исчезнет через N дн.» — под кругом (кладётся в ячейку рядом с кругом).
    let leftLabel = UILabel()
    /// WebM (веб без MP4) AVPlayer не играет — по нажатию открывается обычный просмотр видео (VLC).
    var onOpenFallback: (() -> Void)?
    private var isWebM = false
    private let soundIcon = UIImageView()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var statusObs: NSKeyValueObservation?
    private var loadedKey: String?
    private var loading = false
    private(set) var soundOn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = L2.surface2
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        addSubview(poster)
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        badge.font = L2.font(11, .semibold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        badge.layer.cornerRadius = 10
        badge.clipsToBounds = true
        badge.isHidden = true
        addSubview(badge)
        soundIcon.image = L2.symbol("speaker.slash.fill", 12, .bold)
        soundIcon.tintColor = .white
        soundIcon.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        soundIcon.contentMode = .center
        soundIcon.layer.cornerRadius = 11
        soundIcon.clipsToBounds = true
        addSubview(soundIcon)
        layer.borderColor = L2.accent.cgColor
        leftLabel.font = L2.font(11, .medium)
        leftLabel.textColor = L2.textSecondary
        leftLabel.textAlignment = .center
        isAccessibilityElement = true
        accessibilityLabel = "Видео-кружок"
        accessibilityValue = "загрузка"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        poster.frame = bounds
        playerLayer.frame = bounds
        let bs = badge.sizeThatFits(CGSize(width: bounds.width, height: 20))
        badge.frame = CGRect(x: (bounds.width - bs.width - 28) / 2, y: 10, width: bs.width + 28, height: 20)
        soundIcon.frame = CGRect(x: bounds.width * 0.15 - 11, y: bounds.height * 0.85 - 11, width: 22, height: 22)
    }

    func configure(message: Message, entity: Entity, key: String) {
        let ms = entity.data?["duration"]?.asInt() ?? 0
        badge.text = ms > 0 ? String(format: "%d:%02d", ms / 60000, (ms / 1000) % 60) : nil
        badge.isHidden = ms <= 0
        if let d = Linia2Round.daysLeft(message) {
            leftLabel.text = L2T("l2.round.left", "исчезнет через") + " " + String(max(1, d)) + " дн."
        } else {
            leftLabel.text = nil
        }
        accessibilityLabel = "Видео-кружок" + (leftLabel.text.map { ", " + $0 } ?? "")
        if poster.image == nil, let p = entity.data?["preview"]?.asData() { poster.image = UIImage(data: p) }
        isWebM = Linia2Round.isWebM(entity)
        if isWebM {
            accessibilityValue = "формат WebM"
            return
        }
        guard loadedKey != key, !loading else {
            if player != nil, player?.rate == 0 { player?.play() }
            return
        }
        let file = Linia2Round.cacheDir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".mp4")
        if FileManager.default.fileExists(atPath: file.path) {
            start(file, key: key)
            return
        }
        if let bits = entity.data?["val"]?.asData(), !bits.isEmpty {
            try? bits.write(to: file)
            start(file, key: key)
            return
        }
        guard let ref = entity.data?["ref"]?.asString(), !ref.hasPrefix("mid:"),
              let url = URL(string: ref, relativeTo: Cache.tinode.baseURL(useWebsocketProtocol: false)) else { return }
        loading = true
        URLSession.shared.downloadTask(with: Cache.tinode.addAuthQueryParams(url)) { [weak self] tmp, resp, _ in
            let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) == 200
            if ok, let tmp = tmp { try? FileManager.default.moveItem(at: tmp, to: file) }
            DispatchQueue.main.async {
                self?.loading = false
                if FileManager.default.fileExists(atPath: file.path) {
                    self?.start(file, key: key)
                } else {
                    self?.accessibilityValue = "не загрузилось"
                }
            }
        }.resume()
    }

    private func start(_ file: URL, key: String) {
        loadedKey = key
        let item = AVPlayerItem(url: file)
        let p = AVQueuePlayer()
        p.isMuted = !soundOn
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: item)
        player = p
        playerLayer.player = p
        statusObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if p.timeControlStatus == .playing {
                    self.accessibilityValue = self.soundOn ? "играет со звуком" : "играет без звука"
                }
            }
        }
        accessibilityValue = "без звука"
        p.play()
    }

    /// Нажатие: со звуком с начала / снова без звука.
    func toggleSound() {
        if isWebM { onOpenFallback?(); return }
        guard let p = player else { return }
        soundOn.toggle()
        if soundOn {
            let s = AVAudioSession.sharedInstance()
            if s.category != .playAndRecord {   // во время звонка сессию не трогаем
                try? s.setCategory(.playback, mode: .default, options: [])
                try? s.setActive(true)
            }
            p.seek(to: .zero)
        }
        p.isMuted = !soundOn
        p.play()
        layer.borderWidth = soundOn ? 3 : 0
        soundIcon.isHidden = soundOn
        accessibilityValue = soundOn ? "играет со звуком" : "играет без звука"
        L2.haptic()
    }

    /// Ячейка ушла с экрана: без звука, пауза.
    func stop() {
        if soundOn {
            soundOn = false
            player?.isMuted = true
            layer.borderWidth = 0
            soundIcon.isHidden = false
        }
        player?.pause()
    }
}

extension MessageViewController {
    func linia2IsRound(_ m: Message) -> Bool {
        Linia2Round.roundEntity(m) != nil
    }

    /// Кружок поверх содержимого ячейки.
    func linia2RenderRound(cell: MessageCell, message: Message) {
        guard !message.isDeleted, let (idx, entity) = Linia2Round.roundEntity(message) else { return }
        let key = (topicName ?? "t") + "-" + String(message.seqId > 0 ? message.seqId : Int(message.msgId) + 1_000_000_000)
        let v = Linia2RoundVideoView.view(for: key)
        v.removeFromSuperview()
        let c = cell.containerView.bounds
        let d = min(c.width, c.height - Self.kRoundCaption)
        v.frame = CGRect(x: (c.width - d) / 2, y: 0, width: d, height: d)
        v.accessibilityIdentifier = "l2.round.\(message.seqId)"
        cell.containerView.backgroundColor = .clear
        cell.containerView.layer.mask = nil
        cell.content.isHidden = true
        cell.containerView.insertSubview(v, belowSubview: cell.linia2MetaPill)
        cell.linia2Round = v
        v.onOpenFallback = { [weak self, weak cell] in
            guard let self = self, let cell = cell else { return }
            self.didTapContent(in: cell, url: URL(string: "tinode:///video?key=\(idx)"))
        }
        if message.seqId > 0 { v.configure(message: message, entity: entity, key: key) }
        // Время и галочки — на круге справа внизу; «исчезнет через N дн.» — под кругом.
        let dy = c.height - d - (shouldShowProgressBar(for: message) ? Constants.kProgressViewHeight : 0)
        if dy > 0 {
            cell.timestampLabel.frame.origin.y -= dy
            cell.deliveryMarker.frame.origin.y -= dy
        }
        cell.timestampLabel.textColor = .white
        v.leftLabel.frame = CGRect(x: 0, y: d + 2, width: c.width, height: Self.kRoundCaption - 2)
        cell.containerView.addSubview(v.leftLabel)
        linia2LayoutMetaPill(cell: cell, message: message)
    }

    static let kRoundCaption: CGFloat = 18

    /// Размер ячейки для кружка.
    func linia2RoundContainerSize(maxWidth: CGFloat, progressVisible: Bool) -> CGSize {
        let d = min(Linia2RoundVideoView.kDiameter, maxWidth + 28)
        return CGSize(width: d, height: d + Self.kRoundCaption + (progressVisible ? Constants.kProgressViewHeight : 0))
    }

    // MARK: запись

    /// Удержание кнопки в режиме камеры (SendMessageBar).
    func linia2RoundGesture(_ state: UIGestureRecognizer.State, cancel: Bool) {
        switch state {
        case .began:
            linia2BeginRoundRecording()
        case .ended:
            Linia2RoundRecorder.current?.finish(send: !cancel)
        case .cancelled, .failed:
            Linia2RoundRecorder.current?.finish(send: false)
        default:
            if cancel { Linia2RoundRecorder.current?.finish(send: false) }
        }
    }

    private func linia2BeginRoundRecording() {
        guard Linia2Round.featureOn else { return }
        currentAudioPlayer?.stop()
        let start: () -> Void = { [weak self] in
            guard let self = self else { return }
            let rec = Linia2RoundRecorder()
            rec.onFinish = { [weak self] url, duration, poster in
                self?.linia2SendRound(url: url, durationMs: duration, poster: poster)
            }
            rec.start(in: self.view.window)
        }
        let hasCamera = (AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(for: .video)) != nil
        if !hasCamera && Linia2Round.isUITest {
            start()   // симулятор: синтетическое видео, разрешения не нужны
            return
        }
        Linia2Permissions.ensure(video: true, from: self) { result in
            // Разрешение спросили только что — палец уже отпущен; запись начнётся со следующего удержания.
            if result == .alreadyGranted { start() }
        }
    }

    func linia2SendRound(url: URL, durationMs: Int, poster: UIImage?) {
        guard durationMs >= 1000, let data = try? Data(contentsOf: url) else {
            UiUtils.showToast(message: L2T("l2.round.short", "Слишком короткое видео — удерживайте кнопку дольше"), level: .info)
            return
        }
        let preview = poster?.jpegData(compressionQuality: 0.7)
        let previewSize = preview?.count ?? 0
        let fname = "round-\(Int(Date().timeIntervalSince1970)).mp4"
        let maxInband = Cache.tinode.getServerLimit(for: Tinode.kMaxMessageSize, withDefault: MessageViewController.kMaxInbandAttachmentSize) * 3 / 4 - 1024
        if Int64(data.count + previewSize) > maxInband {
            var def = UploadDef(caption: nil, filename: fname, mimeType: "video/mp4", data: data,
                                width: CGFloat(Linia2Round.side), height: CGFloat(Linia2Round.side),
                                duration: durationMs, preview: preview, previewMime: "image/jpeg",
                                previewOutOfBand: previewSize > Constants.kMaxPosterSize)
            def.round = true
            def.extraHead = Linia2Round.head
            interactor?.uploadVideo(def)
        } else if let d = try? Drafty(plainText: " ").insertVideo(at: 0, mime: "video/mp4", bits: data, refurl: nil, duration: durationMs,
                                                                 width: Linia2Round.side, height: Linia2Round.side, fname: fname, size: data.count,
                                                                 preMime: "image/jpeg", preview: preview, previewRef: nil) {
            (interactor as? MessageInteractor)?.linia2NextHead = Linia2Round.head
            interactor?.sendMessage(content: Linia2Round.markRound(d) ?? d)
        }
        Linia2Round.noteFirstSend()
    }
}

// MARK: - Запись кружка: фронтальная камера → AVAssetWriter 384×384 H.264 + AAC

final class Linia2RoundRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    static weak var current: Linia2RoundRecorder?
    private static var retained: Linia2RoundRecorder?

    var onFinish: ((URL, Int, UIImage?) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "info.codix.liniya2.round")
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var startPTS: CMTime?
    private var lastPTS: CMTime = .zero
    private var finished = false
    private var synthetic = false
    private var startedAt = Date()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("l2round-\(UUID().uuidString).mp4")

    private var overlay: Linia2RoundOverlay?
    private var timer: Timer?

    func start(in window: UIWindow?) {
        Self.current = self
        Self.retained = self
        let ov = Linia2RoundOverlay(frame: window?.bounds ?? UIScreen.main.bounds)
        window?.addSubview(ov)
        overlay = ov
        startedAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let camIn = try? AVCaptureDeviceInput(device: cam) else {
            if Linia2Round.isUITest {
                synthetic = true   // симулятор без камеры: автотест получает синтетическое видео
                ov.setSynthetic()
                startTimer()
                return
            }
            ov.removeFromSuperview()
            Self.retained = nil
            UiUtils.showToast(message: L2T("l2.round.noCamera", "Камера недоступна"))
            return
        }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        if session.canAddInput(camIn) { session.addInput(camIn) }
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        let vout = AVCaptureVideoDataOutput()
        vout.alwaysDiscardsLateVideoFrames = true
        vout.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(vout) { session.addOutput(vout) }
        if let c = vout.connection(with: .video) {
            if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
            if c.isVideoMirroringSupported { c.isVideoMirrored = cam.position == .front }
        }
        let aout = AVCaptureAudioDataOutput()
        aout.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(aout) { session.addOutput(aout) }
        session.commitConfiguration()
        ov.attach(session: session)

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            w.shouldOptimizeForNetworkUse = true
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings)
            v.expectsMediaDataInRealTime = true
            if w.canAdd(v) { w.add(v) }
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 48000])
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a) }
            writer = w; videoIn = v; audioIn = a
        } catch {
            Cache.log.error("Linia2Round: writer: %@", error.localizedDescription)
        }
        queue.async { self.session.startRunning() }
        startTimer()
    }

    static var videoSettings: [String: Any] { [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Linia2Round.side,
        AVVideoHeightKey: Linia2Round.side,
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Linia2Round.videoBitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 30,
        ],
    ] }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = Date().timeIntervalSince(self.startedAt)
            self.overlay?.update(elapsed: t, max: Linia2Round.maxSeconds)
            if t >= Linia2Round.maxSeconds { self.finish(send: true) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let w = writer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if output is AVCaptureVideoDataOutput {
            if startPTS == nil {
                guard w.startWriting() else { return }
                w.startSession(atSourceTime: pts)
                startPTS = pts
            }
            if videoIn?.isReadyForMoreMediaData == true { _ = videoIn?.append(sb); lastPTS = pts }
        } else if startPTS != nil, audioIn?.isReadyForMoreMediaData == true {
            _ = audioIn?.append(sb)
        }
    }

    /// Отпустили палец (send) или смахнули (отмена).
    func finish(send: Bool) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        let elapsed = Date().timeIntervalSince(startedAt)
        overlay?.dismiss()
        overlay = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let done: (URL?, Int) -> Void = { [weak self] file, ms in
            DispatchQueue.main.async {
                defer { Self.retained = nil }
                guard send, let file = file, let self = self else {
                    if let f = file { try? FileManager.default.removeItem(at: f) }
                    return
                }
                self.onFinish?(file, ms, Self.poster(file))
            }
        }
        if synthetic {
            let secs = min(Linia2Round.maxSeconds, max(1.5, elapsed))
            queue.async { Self.synthesize(to: self.url, seconds: secs) { ok in done(ok ? self.url : nil, Int(secs * 1000)) } }
            return
        }
        queue.async {
            self.session.stopRunning()
            guard let w = self.writer, let start = self.startPTS, w.status == .writing else { done(nil, 0); return }
            self.videoIn?.markAsFinished()
            self.audioIn?.markAsFinished()
            w.endSession(atSourceTime: self.lastPTS)
            let ms = Int(CMTimeGetSeconds(CMTimeSubtract(self.lastPTS, start)) * 1000)
            w.finishWriting { done(w.status == .completed ? self.url : nil, ms) }
        }
    }

    /// Кадр для превью (96×96 PNG).
    static func poster(_ file: URL) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVAsset(url: file))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 96, height: 96)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600), actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Автотесты в симуляторе: синтетическое видео 384×384 (цветные кадры), без звука.
    static func synthesize(to url: URL, seconds: Double, completion: @escaping (Bool) -> Void) {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { completion(false); return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: Linia2Round.side, kCVPixelBufferHeightKey as String: Linia2Round.side]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard w.canAdd(input) else { completion(false); return }
        w.add(input)
        guard w.startWriting() else { completion(false); return }
        w.startSession(atSourceTime: .zero)
        let fps: Int32 = 15
        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf),
               let ctx = CGContext(data: base, width: Linia2Round.side, height: Linia2Round.side, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let h = CGFloat(i % 60) / 60
                ctx.setFillColor(UIColor(hue: h, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: Linia2Round.side, height: Linia2Round.side))
                ctx.setFillColor(UIColor.white.cgColor)
                let x = CGFloat(i * 6 % Linia2Round.side)
                ctx.fillEllipse(in: CGRect(x: x, y: 160, width: 64, height: 64))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            _ = adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        w.finishWriting { completion(w.status == .completed) }
    }
}

/// Полупрозрачный экран записи: круглое превью камеры, время, кольцо прогресса, «← отмена».
final class Linia2RoundOverlay: UIView {
    private let preview = UIView()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let ring = CAShapeLayer()
    private let time = UILabel()
    private let hint = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        isUserInteractionEnabled = false   // жест остаётся у кнопки
        accessibilityIdentifier = "l2.round.recording"
        isAccessibilityElement = true
        accessibilityLabel = "Запись кружка"
        let d = min(frame.width - 60, 280)
        preview.frame = CGRect(x: (frame.width - d) / 2, y: frame.height * 0.22, width: d, height: d)
        preview.layer.cornerRadius = d / 2
        preview.clipsToBounds = true
        preview.backgroundColor = L2.surface2
        addSubview(preview)
        ring.path = UIBezierPath(arcCenter: CGPoint(x: preview.frame.midX, y: preview.frame.midY), radius: d / 2 + 5,
                                 startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        ring.strokeColor = L2.accent.cgColor
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 4
        ring.lineCap = .round
        ring.strokeEnd = 0
        layer.addSublayer(ring)
        time.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        time.textColor = .white
        time.textAlignment = .center
        time.text = "🔴 0:00"
        time.frame = CGRect(x: 0, y: preview.frame.maxY + 24, width: frame.width, height: 24)
        addSubview(time)
        hint.font = L2.font(15)
        hint.textColor = UIColor.white.withAlphaComponent(0.8)
        hint.textAlignment = .center
        hint.text = L2T("l2.round.hint", "Отпустите — отправить · ← смахните — отмена")
        hint.frame = CGRect(x: 16, y: time.frame.maxY + 10, width: frame.width - 32, height: 22)
        addSubview(hint)
        alpha = 0
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
    }

    required init?(coder: NSCoder) { return nil }

    func attach(session: AVCaptureSession) {
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        l.frame = preview.bounds
        preview.layer.addSublayer(l)
        previewLayer = l
    }

    func setSynthetic() { preview.backgroundColor = L2.accent.withAlphaComponent(0.6) }

    func update(elapsed: TimeInterval, max: TimeInterval) {
        let s = Int(elapsed)
        time.text = String(format: "🔴 %d:%02d", s / 60, s % 60)
        ring.strokeEnd = CGFloat(min(1, elapsed / max))
    }

    func dismiss() {
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }) { _ in self.removeFromSuperview() }
    }
}

// MARK: - Доступ к камере и микрофону (кружки)

enum Linia2Permissions {
    enum Result { case alreadyGranted, granted, denied }

    /// Есть доступ — сразу .alreadyGranted (не спрашиваем); не спрашивали — системный запрос;
    /// запрещено — окно «Настройки → Линия 2.0 → Камера/Микрофон» с кнопкой «Открыть настройки».
    static func ensure(video: Bool, from vc: UIViewController, completion: @escaping (Result) -> Void) {
        let cam = video ? AVCaptureDevice.authorizationStatus(for: .video) : .authorized
        let mic = AVAudioSession.sharedInstance().recordPermission
        if cam == .authorized && mic == .granted {
            completion(.alreadyGranted)
            return
        }
        if cam == .denied || cam == .restricted || mic == .denied {
            let what = (cam == .denied || cam == .restricted) ? "Камера" : "Микрофон"
            let a = UIAlertController(title: L2T("l2.perm.title", "Нет доступа"),
                                      message: String(format: L2T("l2.perm.text", "Чтобы записать видео, откройте Настройки → Линия 2.0 → %@ и включите доступ."), what),
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L2T("l2.call.openSettings", "Открыть настройки"), style: .default) { _ in
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            })
            a.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
            vc.present(a, animated: true)
            completion(.denied)
            return
        }
        let askMic: () -> Void = {
            if mic == .granted {
                DispatchQueue.main.async { completion(.granted) }
                return
            }
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                DispatchQueue.main.async { completion(ok ? .granted : .denied) }
            }
        }
        if cam == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok { askMic() } else { DispatchQueue.main.async { completion(.denied) } }
            }
        } else {
            askMic()
        }
    }
}
