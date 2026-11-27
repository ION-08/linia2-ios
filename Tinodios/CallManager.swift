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
import TinodiosDB
import UIKit
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
        /// Звонок уже завершён (известен как завершённый или устарел) — не показывать.
        case ended
    }

    /// CallKit выключен в автотестах (симулятор): там входящий показывается алертом приложения.
    static var useCallKit: Bool { !ProcessInfo.processInfo.arguments.contains("-l2-uitest") }

    var callDelegate: CallProviderDelegate!
    var callController: CXCallController!
    var callInProgress: Call?
    // Dismisses call UI after timeout.
    var timer: Timer?
    /// Входящий в автотестах (без CallKit) — алертом; закрывается при завершении звонка.
    private weak var testIncomingAlert: UIAlertController?

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
                self.dismissIncomingCall(onTopic: call.topic, withSeqId: call.seq, reason: .unanswered)
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
        L2Log.event("l2_call_start", ["dir": "out", "kind": isAudioOnly ? "audio" : "video", "chat": L2Log.topicKind(topicName)])
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

    /// LINIA2: в этом топике идёт звонок (исходящий/входящий, в т.ч. ещё дозвон или свёрнутый экран звонка).
    /// Пока он идёт, из топика уходить нельзя: сервер Tinode завершает звонок, как только сессия участника
    /// отписывается от топика (topic.go unregisterSession → terminateCallInProgress) — собеседник получает «hang-up».
    func isCallActive(onTopic topicName: String?) -> Bool {
        guard let name = topicName, !name.isEmpty else { return false }
        if let call = callInProgress, call.topic == name { return true }
        if let vc = Linia2CallCenter.shared.active, !vc.closed, vc.topic?.name == name { return true }
        return false
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
        // LINIA2: звонок уже завершён (этим устройством, по «отбою» или проверкой) — не поднимать заново.
        if Linia2EndedCalls.contains(topicName, seq) {
            Cache.log.info("CallManager: call %@:%d already ended — not showing", topicName, seq)
            completion?(CallError.ended)
            return
        }

        self.callInProgress = Call(uuid: uuid, topic: topicName, from: fromUid, seq: seq, audioOnly: audioOnly)
        // LINIA2: TURN заранее — к моменту «Принять» данные уже в кэше, ответ на offer без ожидания.
        Linia2Turn.shared.prefetch()
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
                self.testIncomingAlert = alert
                Linia2TestProbe.incomingShown += 1
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
                L2Log.event("l2_call_start", ["dir": "in", "kind": audioOnly ? "audio" : "video", "chat": L2Log.topicKind(topicName)])
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
    /// LINIA2 (баг 1006 «фантомный повторный звонок»): ID звонка = topic+seq. Повторный push по тому же
    /// звонку — без нового показа; push по завершённому (известному как завершённый, устаревшему по `sentAt`
    /// или — после показа — по ответу сервера «звонка нет») — reportNewIncomingCall + сразу reportCall(ended).
    func handleVoipPush(event: String, topic: String, from: String?, seq: Int, audioOnly: Bool, callerName: String?,
                        sentAt: Date? = nil, completion: @escaping () -> Void) {
        let name = callerName ?? "Линия 2.0"
        Linia2TestProbe.voipPushes += 1
        if event == MsgServerData.WebRTC.kStarted.rawValue, let from = from, !Cache.tinode.isMe(uid: from), seq > 0 {
            if let cur = callInProgress {
                if cur.topic == topic && cur.seq == seq {
                    // Уже показан (пришёл по websocket или повторный push) — повторный отчёт с тем же UUID безвреден.
                    Linia2TestProbe.voipDuplicates += 1
                    reportToSystem(uuid: cur.uuid, topic: topic, handle: name, audioOnly: audioOnly) { _ in completion() }
                } else {
                    // Заняты другим звонком: показать и сразу снять, собеседнику — «занято».
                    Cache.tinode.videoCall(topic: topic, seq: seq, event: "hang-up")
                    endImmediately(topic: topic, handle: name, why: "busy", completion: completion)
                }
                return
            }
            if Linia2EndedCalls.contains(topic, seq) {
                endImmediately(topic: topic, handle: name, why: "ended", completion: completion)
                return
            }
            if CallManager.isStale(sentAt: sentAt) {
                Linia2EndedCalls.mark(topic, seq)
                endImmediately(topic: topic, handle: name, why: "stale", completion: completion)
                return
            }
            let uuid = UUID()
            displayIncomingCall(uuid: uuid, onTopic: topic, originatingFrom: from, withSeqId: seq, audioOnly: audioOnly, callerName: callerName) { err in
                if err != nil {
                    self.endImmediately(topic: topic, handle: name, why: "error", completion: completion)
                } else {
                    completion()
                    // Звонок мог закончиться, пока push шёл (или это повтор старого): спросить сервер.
                    self.verifyStillRinging(uuid: uuid, topic: topic, seq: seq, attempt: 0)
                }
            }
            return
        }
        // «Отбой» (hang-up / missed / declined …): снять звонок, если он ещё звонит.
        if let cur = callInProgress, cur.topic == topic, cur.seq == seq || seq <= 0 {
            Linia2EndedCalls.mark(topic, cur.seq)
            reportToSystem(uuid: cur.uuid, topic: topic, handle: name, audioOnly: cur.audioOnly) { _ in
                if !self.currentCallIsOutgoing {
                    self.dismissIncomingCall(onTopic: cur.topic, withSeqId: cur.seq)
                }
                completion()
            }
            return
        }
        if seq > 0 { Linia2EndedCalls.mark(topic, seq) }
        endImmediately(topic: topic, handle: name, why: "hang-up", completion: completion)
    }

    /// Push / сообщение отправлены сервером давно (дольше таймаута звонка) — звонок уже не идёт.
    /// Время — по часам сервера (timeAdjustment Tinode: разница часов телефона и сервера).
    static func isStale(sentAt: Date?) -> Bool {
        guard let t = sentAt else { return false }
        let tinode = Cache.tinode
        let timeout = TimeInterval(tinode.getServerParam(for: "callTimeout")?.asInt() ?? kCallTimeout)
        let serverNow = Date().addingTimeInterval(-tinode.timeAdjustment)
        return serverNow.timeIntervalSince(t) > timeout + 20
    }

    /// Обязательный отчёт CallKit и немедленное завершение (без экрана звонка). Без CallKit (автотесты) — только счётчик.
    private func endImmediately(topic: String, handle: String, why: String, completion: @escaping () -> Void) {
        Cache.log.info("CallManager: VoIP push for %@ (%@) — reported and ended immediately", topic, why)
        L2Log.event("l2_voip_ignored", ["why": why])
        Linia2TestProbe.voipIgnored += 1
        guard CallManager.useCallKit else { completion(); return }
        callDelegate.reportAndEndImmediately(topic: topic, handle: handle, completion: completion)
    }

    private func reportToSystem(uuid: UUID, topic: String, handle: String, audioOnly: Bool, completion: @escaping (Error?) -> Void) {
        guard CallManager.useCallKit else { completion(nil); return }
        callDelegate.reportIncomingCall(uuid: uuid, topic: topic, handle: handle, audioOnly: audioOnly, completion: completion)
    }

    /// Проверка у сервера, что показанный по VoIP push звонок ещё идёт (через 1,5 и 6 с после показа).
    /// «Звонка нет» (завершён / принят на другом устройстве) — снять как завершённый собеседником.
    private func verifyStillRinging(uuid: UUID, topic: String, seq: Int, attempt: Int) {
        let delays: [TimeInterval] = [1.5, 4.5]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            guard let cur = self.callInProgress, cur.uuid == uuid, !cur.accepted else { return }
            // Локально уже известно, что звонок закончился (сообщение звонка заменено).
            if let t = Cache.tinode.getTopic(topicName: topic),
               let msg = t.getMessage(byEffectiveSeq: seq) as? StoredMessage,
               let st = msg.webrtcCallState, st != .kStarted, st != .kAccepted {
                self.endRemotely(topic: topic, seq: seq, why: "local-" + st.rawValue)
                return
            }
            Linia2Voip.shared.checkCall(topic: topic, seq: seq) { state in
                guard let cur = self.callInProgress, cur.uuid == uuid, !cur.accepted else { return }
                if state == "ended" || state == "accepted" {
                    self.endRemotely(topic: topic, seq: seq, why: "server-" + (state ?? ""),
                                     reason: state == "accepted" ? .answeredElsewhere : .remoteEnded)
                } else {
                    self.verifyStillRinging(uuid: uuid, topic: topic, seq: seq, attempt: attempt + 1)
                }
            }
        }
    }

    /// Входящий (ещё не принятый) звонок завершён другой стороной / сервером: CallKit — reportCall(.remoteEnded).
    func endRemotely(topic: String, seq: Int, why: String, reason: CXCallEndedReason = .remoteEnded) {
        guard let call = callInProgress, call.topic == topic, call.seq == seq, !call.accepted else { return }
        Cache.log.info("CallManager: call %@:%d ended remotely (%@)", topic, seq, why)
        L2Log.event("l2_call_remote_end", ["why": why])
        callInProgress = nil
        timer?.invalidate()
        timer = nil
        Linia2EndedCalls.mark(call.topic, call.seq)
        CallManager.deactivateAudioSession()
        dismissTestAlert()
        if CallManager.useCallKit {
            callDelegate.reportEnded(uuid: call.uuid, reason: reason)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .linia2CallEnded, object: nil, userInfo: ["topic": call.topic, "seq": call.seq])
        }
    }

    private func remember(_ topic: String, _ seq: Int) {
        Linia2EndedCalls.mark(topic, seq)
    }

    private func dismissTestAlert() {
        DispatchQueue.main.async {
            guard let a = self.testIncomingAlert, a.presentingViewController != nil else { return }
            a.dismiss(animated: false)
        }
    }

    // Dismisses incoming call UI without displaying.
    func dismissIncomingCall(onTopic topic: String, withSeqId seq: Int, reason: CXCallEndedReason = .remoteEnded) {
        guard let call = self.callInProgress, call.topic == topic, call.seq == seq, !call.accepted else {
            return
        }
        // LINIA2: входящий снят другой стороной — для CallKit это «завершён собеседником», а не наш отбой.
        if !currentCallIsOutgoing {
            endRemotely(topic: topic, seq: seq, why: "dismiss", reason: reason)
            return
        }
        self.completeCallInProgress(reportToSystem: true, reportToPeer: false)
    }
}

/// LINIA2: завершённые звонки (topic:seq) — на диске, чтобы и после перезапуска приложения (холодный старт по
/// VoIP push) повторный push по тому же звонку не поднимал его заново. Хранятся сутки, не больше 200.
enum Linia2EndedCalls {
    private static let kKey = "linia2.calls.ended"
    private static let lock = NSLock()
    private static var cache: [String: Double]?

    private static func key(_ topic: String, _ seq: Int) -> String { "\(topic):\(seq)" }

    private static func load() -> [String: Double] {
        if let c = cache { return c }
        let c = (UserDefaults.standard.dictionary(forKey: kKey) as? [String: Double]) ?? [:]
        cache = c
        return c
    }

    static func mark(_ topic: String, _ seq: Int) {
        guard !topic.isEmpty, seq > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var d = load()
        let now = Date().timeIntervalSince1970
        d[key(topic, seq)] = now
        d = d.filter { now - $0.value < 86400 }
        if d.count > 200 {
            for (k, _) in d.sorted(by: { $0.value < $1.value }).prefix(d.count - 200) { d.removeValue(forKey: k) }
        }
        cache = d
        UserDefaults.standard.set(d, forKey: kKey)
    }

    static func contains(_ topic: String, _ seq: Int) -> Bool {
        guard seq > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return load()[key(topic, seq)] != nil
    }

    /// Стирание данных (код паники) — забыть.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        cache = [:]
        UserDefaults.standard.removeObject(forKey: kKey)
    }
}

extension CallManager: CallManagerImpl {
    func acceptPendingCall() -> Bool {
        guard let call = self.callInProgress else { return false }

        Cache.log.info("Accepting call: topic=%@, seq=%d", call.topic, call.seq)
        L2Log.event("l2_call_answer", ["kind": call.audioOnly ? "audio" : "video"])
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
        L2Log.event("l2_call_end", ["kind": call.audioOnly ? "audio" : "video", "accepted": call.accepted ? 1 : 0,
                                    "dir": call.from == Cache.tinode.myUid ? "out" : "in", "by_me": reportToPeer ? 1 : 0])
        self.callInProgress = nil
        self.timer?.invalidate()
        self.timer = nil
        if call.seq > 0 { remember(call.topic, call.seq) }
        CallManager.deactivateAudioSession()
        dismissTestAlert()

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

    /// LINIA2: связь потеряна (переподключение не удалось за 30 с) — звонок завершается как «не удался»:
    /// CallKit reportCall(endedAt:reason: .failed). Экран звонка закрывается сам (показав «Связь потеряна»),
    /// поэтому .linia2CallEnded здесь не отправляем.
    func failCallInProgress() {
        guard let call = self.callInProgress else { return }
        Cache.log.info("Call failed (connection lost): topic=%@, seq=%d", call.topic, call.seq)
        L2Log.event("l2_call_lost", ["kind": call.audioOnly ? "audio" : "video",
                                     "dir": call.from == Cache.tinode.myUid ? "out" : "in"])
        self.callInProgress = nil
        self.timer?.invalidate()
        self.timer = nil
        if call.seq > 0 { remember(call.topic, call.seq) }
        CallManager.deactivateAudioSession()
        if CallManager.useCallKit {
            callDelegate.reportEnded(uuid: call.uuid, reason: .failed)
        }
    }

    func setHeld(_ held: Bool) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallHeld, object: nil, userInfo: ["held": held]) }
    }

    func setMuted(_ muted: Bool) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .linia2CallMuted, object: nil, userInfo: ["muted": muted]) }
    }
}
