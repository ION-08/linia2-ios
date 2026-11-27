//
//  ChatListInteractor.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import Foundation
import UIKit
import TinodeSDK

protocol ChatListBusinessLogic: AnyObject {
    func loadAndPresentTopics()
    func attachToMeTopic()
    func leaveMeTopic()
    func updateChat(_ name: String)
    func setup()
    func cleanup()
    func deleteTopic(_ name: String)
    func changeArchivedStatus(forTopic name: String, archived: Bool)
}

protocol ChatListDataStore: AnyObject {
    var topics: [DefaultComTopic]? { get set }
}

class ChatListInteractor: ChatListBusinessLogic, ChatListDataStore {
    private class MeListener: DefaultMeTopic.Listener {
        weak var interactor: ChatListBusinessLogic?

        override func onPres(pres: MsgServerPres) {
            if pres.what == "msg" {
                interactor?.loadAndPresentTopics()
            } else if pres.what == "off" || pres.what == "on" {
                if let name = pres.src {
                    interactor?.updateChat(name)
                }
            }
        }
        override func onMetaSub(sub: Subscription<TheCard, PrivateType>) {
            if Tinode.topicTypeByName(name: sub.topic) == .p2p {
                ContactsManager.default.processSubscription(sub: sub)
            }
        }
        override func onMetaDesc(desc: Description<TheCard, PrivateType>) {
            // Handle description for me topic:
            // add/update user info for ME.
            if let uid = Cache.tinode.myUid {
                ContactsManager.default.processDescription(uid: uid, desc: desc)
            }
        }
        override func onSubsUpdated() {
            interactor?.loadAndPresentTopics()
        }
        override func onContUpdate(sub: Subscription<TheCard, PrivateType>) {
            // Method makes no sense in context of MeTopic.
            // throw new UnsupportedOperationException();
        }
    }
    private class ChatEventListener: UiTinodeEventListener {
        private weak var interactor: ChatListBusinessLogic?
        init(interactor: ChatListBusinessLogic?, connected: Bool) {
            super.init(connected: connected)
            self.interactor = interactor
        }
        override func onLogin(code: Int, text: String) {
            super.onLogin(code: code, text: text)
            self.interactor?.attachToMeTopic()
        }
        override func onDisconnect(byServer: Bool, code: URLSessionWebSocketTask.CloseCode, reason: String) {
            super.onDisconnect(byServer: byServer, code: code, reason: reason)
            // Update presence indicators (all should be off).
            self.interactor?.loadAndPresentTopics()
        }
        override func onDataMessage(data: MsgServerData?) {
            super.onDataMessage(data: data)
            if let topic = data?.topic {
                interactor?.updateChat(topic)
            }
        }
        override func onInfoMessage(info: MsgServerInfo?) {
            super.onInfoMessage(info: info)
            if info?.what != "call", let topic = info?.src {
                interactor?.updateChat(topic)
            }
        }
    }

    var presenter: ChatListPresentationLogic?
    var router: ChatListRoutingLogic?
    var topics: [DefaultComTopic]?
    private var archivedTopics: [DefaultComTopic]?
    private var meListener: MeListener?
    private var meTopic: DefaultMeTopic?
    private var tinodeEventListener: ChatEventListener?
    /// LINIA2: подписка на me уже идёт — не запускать вторую (viewDidAppear при каждом переключении вкладок
    /// во время загрузки создавал по новому DefaultMeTopic и подписке).
    private var meAttachInProgress = false

    func attachToMeTopic() {
        // LINIA2: вызывается и с главного потока (viewDidAppear), и из потока сети (onLogin) — состояние
        // интерактора меняем только на главном.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.attachToMeTopic() }
            return
        }
        let tinode = Cache.tinode
        guard !meAttachInProgress, meTopic == nil || !meTopic!.attached else {
            return
        }
        if let me = tinode.getMeTopic(), me.attached {
            me.listener = self.meListener
            meTopic = me
            loadAndPresentTopics()
            return
        }
        meAttachInProgress = true
        // Страховка: если ответ так и не пришёл (обрыв связи), разрешить новую попытку.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.meAttachInProgress = false }

        let meSentAt = Date()
        Linia2LaunchLog.shared.step("me-sub-sent")
        guard let promise = UiUtils.attachToMeTopic(meListener: self.meListener) else {
            meAttachInProgress = false
            return
        }
        promise.then(
            onSuccess: { [weak self] _ in
                Linia2LaunchLog.shared.step("me-sub-ok", ["ms": Int(Date().timeIntervalSince(meSentAt) * 1000)])
                DispatchQueue.main.async {
                    self?.meAttachInProgress = false
                    self?.meTopic = tinode.getMeTopic()
                    self?.loadAndPresentTopics()
                }
                return nil
            }, onFailure: { [weak self] err in
                Linia2LaunchLog.shared.step("me-sub-fail", ["ms": Int(Date().timeIntervalSince(meSentAt) * 1000),
                                                            "err": String(err.localizedDescription.prefix(120))])
                DispatchQueue.main.async { self?.meAttachInProgress = false }
                if let e = err as? TinodeError, case .serverResponseError(let code, _, _) = e {
                    if code == 401 || code==403 || code == 404 {
                        self?.router?.routeToLogin()
                    }
                }
                return nil
            })
    }
    func leaveMeTopic() {
        if self.meTopic?.attached ?? false {
            self.meTopic?.leave()
        }
    }
    func setup() {
        if self.meListener == nil {
            self.meListener = MeListener()
        }
        self.meListener?.interactor = self
        self.meTopic?.listener = meListener
        let tinode = Cache.tinode
        if self.tinodeEventListener == nil {
            self.tinodeEventListener = ChatEventListener(
                interactor: self,
                connected: tinode.isConnected)
        }
        tinode.addListener(self.tinodeEventListener!)
    }
    func cleanup() {
        if self.meTopic?.listener === self.meListener {
            self.meTopic?.listener = nil
        }
        let tinode = Cache.tinode
        if let listener = self.tinodeEventListener {
            tinode.removeListener(listener)
        }
    }
    private func getTopics(archived: Bool) -> [DefaultComTopic]? {
        return Utils.fetchTopics(archived: archived)
    }
    func loadAndPresentTopics() {
        // LINIA2: вызывается из потока сети (pres/sub от me) и с главного (viewDidAppear) одновременно —
        // запись в self.topics из двух потоков приводила к вылету при быстрой смене вкладок во время загрузки.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.loadAndPresentTopics() }
            return
        }
        // LINIA2 (большой аккаунт): при входе приходят сотни pres/meta — каждый вызывал полную перезагрузку
        // списка на главном потоке. Теперь не чаще раза в 0,5 с: первый — сразу, остальные — одним разом.
        let now = Date()
        if now.timeIntervalSince(lastReload) < 0.5 {
            guard !reloadScheduled else { return }
            reloadScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.reloadScheduled = false
                self.lastReload = .distantPast
                self.loadAndPresentTopics()
            }
            return
        }
        lastReload = now
        self.topics = self.getTopics(archived: false)
        self.archivedTopics = self.getTopics(archived: true)
        self.presenter?.presentTopics(
            self.topics ?? [], archivedTopics: self.archivedTopics)
    }
    private var lastReload = Date.distantPast
    private var reloadScheduled = false

    func updateChat(_ name: String) {
        self.presenter?.topicUpdated(name)
    }

    func deleteTopic(_ name: String) {
        guard let topic = Cache.tinode.getTopic(topicName: name) as? DefaultComTopic else { return }
        topic.delete(hard: true).then(
            onSuccess: { [weak self] _ in
                self?.loadAndPresentTopics()
                return nil
            },
            onFailure: UiUtils.ToastFailureHandler
        )
    }

    func changeArchivedStatus(forTopic name: String, archived: Bool) {
        guard let topic = Cache.tinode.getTopic(topicName: name) as? DefaultComTopic else { return }
        topic.updateArchived(archived: archived)?.then(
            onSuccess: { [weak self] _ in
                self?.loadAndPresentTopics()
                return nil
            },
            onFailure: UiUtils.ToastFailureHandler
        )
    }
}
