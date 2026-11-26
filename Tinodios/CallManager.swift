//
//  CallManager.swift
//  Tinodios
//
//  Copyright © 2022 Tinode LLC. All rights reserved.
//
//  LINIA2: звонки через CallKit — входящие (в т.ч. по VoIP push при закрытом приложении и на
//  заблокированном экране) и исходящие (CXStartCallAction: зелёный индикатор, фоновое аудио,
//  удержание при звонке GSM). Аудиосессию активирует CallKit (RTCAudioSession.useManualAudio).
//  Под -l2-uitest (симулятор) CallKit не используется: входящий — алертом приложения.
//

import Foundation
import TinodeSDK
import CallKit
import WebRTC

class CallManager {
    private static let kCallTimeout = 30

    public struct Call {
        var uuid: UUID
        var topic: String
        var from: String
        var seq: Int
        var audioOnly: Bool
        /// Принят на этом устройстве (идёт разговор) — «принят на другом устройстве» его не снимает.
        var accepted = false
    }

    enum CallError: Error {
        case busy(String)
    }

    /// CallKit выключен в автотестах (симулятор): там входящий показывается алертом приложения.
    static var useCallKit: Bool { !ProcessInfo.processInfo.arguments.contains("-l2-uitest") }

    var callDelegate: CallProviderDelegate!
    var callController: CXCallController!
    var callInProgress: Call?
    // Dismisses call UI after timeout.
    var timer: Timer?
    /// Недавно завершённые звонки (topic:seq) — чтобы «отбой» по VoIP push не поднимал звонок заново.
    private var recentlyEnded: [String] = []

    // Returns true if the user originated the call.
    var currentCallIsOutgoing: Bool {
        guard let call = self.callInProgress else { return false }
        let tinode = Cache.tinode
        return tinode.isMe(uid: call.from)
    }

    init() {
        callDelegate = CallProviderDelegate(callManager: self)
        callController = CXCallController()
        if CallManager.useCallKit {
            // Звук включает CallKit (provider didActivate) — иначе на заблокированном экране нет звука.
            let rtc = RTCAudioSession.sharedInstance()
            rtc.useManualAudio = true
            rtc.isAudioEnabled = false
        }
    }

    private func makeCallTimeoutTimer(withDeadline deadline: TimeInterval) -> Timer {
        return Timer.scheduledTimer(withTimeInterval: deadline, repeats: false) { timer in
            timer.invalidate()
            self.timer = nil
            if let call = self.callInProgress {
                self.dismissIncomingCall(onTopic: call.topic, withSeqId: call.seq)
            }
        }
    }

    // Utility function to configure RTCAudioSession.
    public static func audioSessionChange(action: ((RTCAudioSession) throws -> Void)) {
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        do {
            try action(audioSession)
        } catch {
            Cache.log.error("WebRTCClient: error changing AVAudioSession: %@", error.localizedDescription)
        }
        audioSession.unlockForConfiguration()
    }

    public static func activateAudioSession(withSpeaker speaker: Bool) {
        self.audioSessionChange { audioSession in
            // Bluetooth (AirPods, гарнитуры, автомобиль) — разрешён; выбор выхода — AVRoutePickerView на экране звонка.
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            if !CallManager.useCallKit {
                try audioSession.setActive(true)
            }
            try? audioSession.overrideOutputAudioPort(speaker ? .speaker : .none)
        }
    }

    public static func deactivateAudioSession() {
        // С CallKit сессию выключает система (provider didDeactivate).
        guard !CallManager.useCallKit else { return }
        self.audioSessionChange { audioSession in
            try audioSession.setActive(false)
        }
    }

    /// Запасной путь: CallKit не активировал звук (сбой) — включаем сами.
    public static func ensureAudioEnabled() {
        let rtc = RTCAudioSession.sharedInstance()
        guard rtc.useManualAudio, !rtc.isAudioEnabled else { return }
        Cache.log.info("CallManager: CallKit did not activate audio, enabling manually")
        audioSessionChange { s in try s.setActive(true) }
        rtc.isAudioEnabled = true
    }

    // Registers an outgoing call that's just been started.
    func registerOutgoingCall(onTopic topicName: String, isAudioOnly: Bool, peerName: String? = nil) -> Bool {
        guard self.callInProgress == nil else {
            // Another call is in progress. Quit.
            return false
        }
        let tinode = Cache.tinode
        let call = Call(uuid: UUID(), topic: topicName, from: tinode.myUid!, seq: -1, audioOnly: isAudioOnly)
        self.callInProgress = call
        CallManager.activateAudioSession(withSpeaker: !isAudioOnly)
        Cache.log.info("Starting outgoing call (uuid: %@) on topic: %@", call.uuid.uuidString, topicName)
        if CallManager.useCallKit {
            let action = CXStartCallAction(call: call.uuid, handle: CXHandle(type: .generic, value: topicName))
            action.isVideo = !isAudioOnly
            action.contactIdentifier = peerName
            callController.request(CXTransaction(action: action)) { error in
                if let error = error {
                    Cache.log.error("CallManager - StartCallAction failed: %@", error.localizedDescription)
                    DispatchQueue.main.async { CallManager.ensureAudioEnabled() }
                    return
                }
                self.callDelegate.updateCall(uuid: call.uuid, name: peerName, video: !isAudioOnly)
            }
        }
        return true
    }

    // Sets seq id on the current call.
    func updateOutgoingCall(withNewSeqId seq: Int) {
        self.callInProgress?.seq = seq
    }

    /// Соединение установлено — для CallKit (время в «Недавних», индикатор).
    func reportConnected() {
        guard let call = callInProgress, CallManager.useCallKit else { return }
        if currentCallIsOutgoing {
            callDelegate.reportOutgoingConnected(uuid: call.uuid)
        }
    }

    /// Синхронизировать «Выключить микрофон» с системным экраном звонка.
    func setMutedInSystem(_ muted: Bool) {
        guard let call = callInProgress, CallManager.useCallKit else { return }
        callController.request(CXTransaction(action: CXSetMutedCallAction(call: call.uuid, muted: muted))) { _ in }
    }

    private func key(_ topic: String, _ seq: Int) -> String { "\(topic):\(seq)" }

    // Report incoming call to the operating system (which displays incoming call UI).
    func displayIncomingCall(uuid: UUID, onTopic topicName: String, originatingFrom fromUid: String, withSeqId seq: Int, audioOnly: Bool,
                             callerName: String? = nil, guest: (name: String, link: String)? = nil, completion: ((Error?) -> Void)?) {
        guard self.callInProgress == nil else {
            if seq == self.callInProgress!.seq && self.callInProgress!.topic == topicName {
                // Дубликат (VoIP push + сообщение по websocket): звонок уже показан.
                completion?(nil)
                return
            }
            Cache.log.info("Hanging up: another call in progress")
            let tinode = Cache.tinode
            tinode.videoCall(topic: topicName, seq: seq, event: "hang-up")
            completion?(CallError.busy("Busy. Another call in progress"))
            return
        }
        if recentlyEnded.contains(key(topicName, seq)) {
            completion?(nil)
            return
        }

        self.callInProgress = Call(uuid: uuid, topic: topicName, from: fromUid, seq: seq, audioOnly: audioOnly)
        let tinode = Cache.tinode
        let user: DefaultUser? = tinode.getUser(with: fromUid)
        var senderName = user?.pub?.fn ?? callerName ?? NSLocalizedString("Unknown", comment: "Placeholder for missing user name")
        // LINIA2: гостевой звонок по ссылке — «<имя> (по ссылке «<название>»)».
        let guestInfo = guest ?? Linia2GuestLinks.cachedInfo(seq: seq)
        let isGuestCall = guest != nil || Linia2GuestLinks.isGuest(fromUid) || Linia2GuestLinks.isGuest(topicName)
        if isGuestCall, let g = guestInfo { senderName = Linia2GuestLinks.callKitName(g) }
        let needGuestInfo = isGuestCall && guestInfo == nil
        // LINIA2_E2E: в автотестах (симулятор) входящий звонок — своим окном вместо CallKit.
        if !CallManager.useCallKit {
            tinode.videoCall(topic: topicName, seq: seq, event: "ringing")
            let timeout = (tinode.getServerParam(for: "callTimeout")?.asInt() ?? CallManager.kCallTimeout) + 5
            self.timer = self.makeCallTimeoutTimer(withDeadline: TimeInterval(timeout))
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "Входящий звонок",
                                              message: isGuestCall && guestInfo != nil ? Linia2GuestLinks.incomingText(guestInfo!) : senderName,
                                              preferredStyle: .alert)
                if needGuestInfo {
                    Linia2GuestLinks.callInfo(seq: seq) { [weak alert] i in
                        if let i = i { alert?.message = Linia2GuestLinks.incomingText(i) }
                    }
                }
                alert.view.accessibilityIdentifier = "l2.call.incoming"
                alert.addAction(UIAlertAction(title: "Отклонить", style: .destructive) { _ in
                    self.completeCallInProgress(reportToSystem: false, reportToPeer: true)
                })
                alert.addAction(UIAlertAction(title: "Принять", style: .default) { _ in
                    CallManager.activateAudioSession(withSpeaker: !audioOnly)
                    _ = self.acceptPendingCall()
                })
                var top = Linia2Root.window?.rootViewController
                while let p = top?.presentedViewController { top = p }
                top?.present(alert, animated: true)
            }
            completion?(nil)
            return
        }
        callDelegate.reportIncomingCall(uuid: uuid, topic: topicName, handle: senderName, audioOnly: audioOnly) { err in
            if err == nil {
                Cache.log.info("Reporting incoming call (uuid: %@) on topic: %@, seq: %d", self.callInProgress?.uuid.uuidString ?? "missing", topicName, seq)
                if needGuestInfo {
                    DispatchQueue.main.async {
                        Linia2GuestLinks.callInfo(seq: seq) { i in
                            guard let i = i, let cur = self.callInProgress, cur.uuid == uuid else { return }
                            self.callDelegate.updateCall(uuid: uuid, name: Linia2GuestLinks.callKitName(i), video: !audioOnly)
                        }
                    }
                }
                CallManager.activateAudioSession(withSpeaker: !audioOnly)
                tinode.videoCall(topic: topicName, seq: seq, event: "ringing")
                let timeout = (tinode.getServerParam(for: "callTimeout")?.asInt() ?? CallManager.kCallTimeout) + 5
                self.timer = self.makeCallTimeoutTimer(withDeadline: TimeInterval(timeout))
            } else {
                Cache.log.error("Incoming call (topic: %@, seq: %d) error: %@", topicName, seq, err!.localizedDescription)
                self.callInProgress = nil
            }
            completion?(err)
        }
    }

    /// VoIP push (PushKit). iOS требует СРАЗУ сообщить CallKit о звонке — иначе приложение будет закрыто
    /// и система перестанет доставлять VoIP push. Поэтому на каждый push есть reportNewIncomingCall.
    func handleVoipPush(event: String, topic: String, from: String?, seq: Int, audioOnly: Bool, callerName: String?, completion: @escaping () -> Void) {
        let name = callerName ?? "Линия 2.0"
        if event == MsgServerData.WebRTC.kStarted.rawValue, let from = from, !Cache.tinode.isMe(uid: from), seq > 0 {
            if let cur = callInProgress {
                if cur.topic == topic && cur.seq == seq {
                    // Уже показан (пришёл по websocket) — повторный отчёт с тем же UUID безвреден.
                    callDelegate.reportIncomingCall(uuid: cur.uuid, topic: topic, handle: name, audioOnly: audioOnly) { _ in completion() }
                } else {
                    // Заняты другим звонком: показать и сразу снять, собеседнику — «занято».
                    Cache.tinode.videoCall(topic: topic, seq: seq, event: "hang-up")
                    callDelegate.reportAndEndImmediately(topic: topic, handle: name, completion: completion)
                }
                return
            }
            if recentlyEnded.contains(key(topic, seq)) {
                callDelegate.reportAndEndImmediately(topic: topic, handle: name, completion: completion)
                return
            }
            displayIncomingCall(uuid: UUID(), onTopic: topic, originatingFrom: from, withSeqId: seq, audioOnly: audioOnly, callerName: callerName) { err in
                if err != nil {
                    self.callDelegate.reportAndEndImmediately(topic: topic, handle: name, completion: completion)
                } else {
                    completion()
                }
            }
            return
        }
        // «Отбой» (hang-up / missed / declined …): снять звонок, если он ещё звонит.
        if let cur = callInProgress, cur.topic == topic, cur.seq == seq || seq <= 0 {
            remember(topic, cur.seq)
            callDelegate.reportIncomingCall(uuid: cur.uuid, topic: topic, handle: name, audioOnly: cur.audioOnly) { _ in
                if !self.currentCallIsOutgoing {
                    self.dismissIncomingCall(onTopic: cur.topic, withSeqId: cur.seq)
                }
                completion()
            }
            return
        }
        if seq > 0 { remember(topic, seq) }
        callDelegate.reportAndEndImmediately(topic: topic, handle: name, completion: completion)
    }

    private func remember(_ topic: String, _ seq: Int) {
        recentlyEnded.append(key(topic, seq))
        if recentlyEnded.count > 20 { recentlyEnded.removeFirst(recentlyEnded.count - 20) }
    }

    // Dismisses incoming call UI without displaying.
    func dismissIncomingCall(onTopic topic: String, withSeqId seq: Int) {
        guard let call = self.callInProgress, call.topic == topic, call.seq == seq, !call.accepted else {
            return
        }
        self.completeCallInProgress(reportToSystem: true, reportToPeer: false)
    }
}

extension CallManager: CallManagerImpl {
    func acceptPendingCall() -> Bool {
        guard let call = self.callInProgress else { return false }

        Cache.log.info("Accepting call: topic=%@, seq=%d", call.topic, call.seq)
        self.timer?.invalidate()
        self.timer = nil
        self.callInProgress?.accepted = true
        // LINIA2: экран звонка создаётся сразу (даже на заблокированном экране / в фоне) — звонок
        // соединяется без открытия приложения; экран виден, когда пользователь его откроет.
        Linia2CallCenter.shared.openIncoming(call)
        return true
    }

    func completeCallInProgress(reportToSystem: Bool, reportToPeer: Bool) {
        guard let call = self.callInProgress else { return }
        Cache.log.info("Completing call: topic=%@, seq=%d", call.topic, call.seq)
        self.callInProgress = nil
        self.timer?.invalidate()
        self.timer = nil
        if call.seq > 0 { remember(call.topic, call.seq) }
        CallManager.deactivateAudioSession()

        if reportToPeer {
            // Tell the peer the call is over/declined.
            Cache.tinode.videoCall(topic: call.topic, seq: call.seq, event: "hang-up")
        }
        if reportToSystem && CallManager.useCallKit {
            // Tell the OS that the call is over/declined.
            let endCallAction = CXEndCallAction(call: call.uuid)
            let transaction = CXTransaction(action: endCallAction)

            Cache.log.info("Ending call (uuid: %@) on topic: %@, seq: %d", call.uuid.uuidString, call.topic, call.seq)
            self.callController.request(transaction) { error in
                if let error = error {
                    Cache.log.error("CallManager - EndCallAction transaction request failed: %@", error.localizedDescription)
                    return
                }
            }
        }
        // Экран звонка (если открыт или свёрнут) закрывается.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .linia2CallEnded, object: nil, userInfo: ["topic": call.topic, "seq": call.seq])
        }
    }

    func setHeld(_ held: Bool) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallHeld, object: nil, userInfo: ["held": held]) }
    }

    func setMuted(_ muted: Bool) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallMuted, object: nil, userInfo: ["muted": muted]) }
    }
}
