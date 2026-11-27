//
//  CallProviderDelegate.swift
//  Tinodios
//
//  Copyright © 2022-2025 Tinode LLC. All rights reserved.
//

import AVFoundation
import CallKit
import UIKit
import WebRTC

protocol CallManagerImpl: AnyObject {
    func acceptPendingCall() -> Bool
    func completeCallInProgress(reportToSystem: Bool, reportToPeer: Bool)
    func setHeld(_ held: Bool)
    func setMuted(_ muted: Bool)
}

class CallProviderDelegate: NSObject, CXProviderDelegate {
    /// LINIA2: «Показывать звонки в истории iPhone» (Настройки → Конфиденциальность), по умолчанию — вкл.
    static let kRecentsKey = "linia2.calls.inRecents"
    static var includesCallsInRecents: Bool {
        get { UserDefaults.standard.object(forKey: kRecentsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: kRecentsKey) }
    }

    static func makeConfiguration() -> CXProviderConfiguration {
        let providerConfiguration = CXProviderConfiguration()

        providerConfiguration.supportsVideo = true
        providerConfiguration.maximumCallsPerCallGroup = 1
        providerConfiguration.maximumCallGroups = 1
        providerConfiguration.supportedHandleTypes = [.generic]
        providerConfiguration.includesCallsInRecents = includesCallsInRecents
        if let icon = UIImage(systemName: "phone.fill")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 40)),
           let data = icon.withTintColor(.white, renderingMode: .alwaysOriginal).pngData() {
            providerConfiguration.iconTemplateImageData = data
        }
        return providerConfiguration
    }

    private weak var callManager: CallManagerImpl?
    private let provider: CXProvider

    init(callManager: CallManagerImpl?) {
        self.callManager = callManager
        self.provider = CXProvider(configuration: CallProviderDelegate.makeConfiguration())

        super.init()
        self.provider.setDelegate(self, queue: nil)
    }

    /// Применить изменённые настройки (история звонков iPhone) без перезапуска.
    func applySettings() {
        provider.configuration = CallProviderDelegate.makeConfiguration()
    }

    private func update(topic: String, name: String, audioOnly: Bool) -> CXCallUpdate {
        let update = CXCallUpdate()
        // handle = имя топика: по нему «Недавние» iPhone перезванивают через приложение (INStartCallIntent).
        update.remoteHandle = CXHandle(type: .generic, value: topic)
        update.localizedCallerName = name
        update.hasVideo = !audioOnly
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    func reportIncomingCall(uuid: UUID, topic: String, handle: String, audioOnly: Bool, completion: ((Error?) -> Void)?) {
        self.provider.reportNewIncomingCall(with: uuid, update: update(topic: topic, name: handle, audioOnly: audioOnly)) { error in
            if let error = error {
                Cache.log.error("Report incoming call error: %@", error.localizedDescription)
            }
            completion?(error)
        }
    }

    /// Для VoIP push без звонка (уже завершён / заняты): обязательный отчёт CallKit и немедленное завершение.
    func reportAndEndImmediately(topic: String, handle: String, completion: @escaping () -> Void) {
        let uuid = UUID()
        self.provider.reportNewIncomingCall(with: uuid, update: update(topic: topic, name: handle, audioOnly: true)) { _ in
            self.provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
            completion()
        }
    }

    func updateCall(uuid: UUID, name: String?, video: Bool) {
        let u = CXCallUpdate()
        if let name = name { u.localizedCallerName = name }
        u.hasVideo = video
        u.supportsHolding = true
        provider.reportCall(with: uuid, updated: u)
    }

    /// Звонок завершён не пользователем (например, связь потеряна) — сообщить системе с причиной.
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    func reportOutgoingConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func providerDidReset(_ provider: CXProvider) {
        callManager?.completeCallInProgress(reportToSystem: true, reportToPeer: true)
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // User tapped "Accept".
        // LINIA2: «accept» уходит только по вошедшему веб-сокету (иначе теряется, у звонящего — «Вызов…»).
        // Разбудили push-ем / сокет ещё входит — ждём вход до 10 с, затем принимаем и только потом fulfill.
        let started = Date()
        let tinode = Cache.tinode
        if !tinode.isConnectionAuthenticated {
            DispatchQueue.global(qos: .userInitiated).async { _ = tinode.reconnectNow(interactively: true, reset: false) }
        }
        func attempt() {
            guard let cur = Cache.callManager.callInProgress, cur.uuid == action.callUUID else { action.fail(); return }
            let waited = Date().timeIntervalSince(started)
            if !Cache.tinode.isConnectionAuthenticated && waited < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { attempt() }
                return
            }
            if waited > 0.1 {
                L2Log.event("l2_call_answer_wait", ["ms": Int(waited * 1000), "ok": Cache.tinode.isConnectionAuthenticated ? 1 : 0])
            }
            if let cm = self.callManager, cm.acceptPendingCall() {
                action.fulfill()
            } else {
                action.fail()
            }
        }
        if Thread.isMainThread { attempt() } else { DispatchQueue.main.async { attempt() } }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // User tapped "Decline/End call" in the incoming call view,
        // or end call action was requested programmatically.
        // LINIA2: fulfill — сразу (CallKit снимает звонок мгновенно); остальное — без ожидания сервера.
        action.fulfill()
        callManager?.completeCallInProgress(reportToSystem: false, reportToPeer: true)
    }

    /// Входящий GSM-звонок / «Удержать» на системном экране: пауза отправки аудио и видео.
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        callManager?.setHeld(action.isOnHold)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        callManager?.setMuted(action.isMuted)
        action.fulfill()
    }

    // Звук звонка: аудиосессию активирует CallKit — передаём её WebRTC.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // LINIA2: сессию настраиваем здесь (CallKit активировал её сам): .playAndRecord + .voiceChat, без .defaultToSpeaker —
        // аудиозвонок идёт в разговорный динамик (у уха), видеозвонок — в громкий. Кнопка «Динамик» меняет выход
        // (overrideOutputAudioPort) — экран звонка повторяет свой выбор по .linia2CallAudioActivated.
        let audioOnly = Cache.callManager.callInProgress?.audioOnly ?? true
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        } catch {
            Cache.log.error("CallProviderDelegate: setCategory failed: %@", error.localizedDescription)
        }
        if !Linia2CallCenter.hasExternalOutput() {
            try? audioSession.overrideOutputAudioPort(audioOnly ? .none : .speaker)
        }
        CallManager.linia2AudioActive = true
        if CallManager.linia2WebAudio {
            // Вариант Б: звук ведёт WebKit — RTCAudioSession не трогаем; странице — «звук включён» (play, проверка микрофона).
            Linia2CallCenter.shared.active?.diag?.add(["type": "audio", "state": "activated", "engine": "web",
                                                       "route": audioSession.currentRoute.outputs.first?.portType.rawValue ?? "none"])
            DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallAudioActivated, object: nil) }
            return
        }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(audioSession)
        rtc.isAudioEnabled = true
        Linia2CallCenter.shared.active?.diag?.add(["type": "audio", "state": "activated"])
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallAudioActivated, object: nil) }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        CallManager.linia2AudioActive = false
        if CallManager.linia2WebAudio {
            Linia2CallCenter.shared.active?.diag?.add(["type": "audio", "state": "deactivated", "engine": "web"])
            CallManager.linia2WebAudio = false   // звонок на WKWebView закончился
            return
        }
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidDeactivate(audioSession)
        rtc.isAudioEnabled = false
        Linia2CallCenter.shared.active?.diag?.add(["type": "audio", "state": "deactivated"])
    }
}

extension Notification.Name {
    static let linia2CallEnded = Notification.Name("Linia2CallEnded")
    static let linia2CallHeld = Notification.Name("Linia2CallHeld")
    static let linia2CallMuted = Notification.Name("Linia2CallMuted")
    static let linia2CallAudioActivated = Notification.Name("Linia2CallAudioActivated")
}
