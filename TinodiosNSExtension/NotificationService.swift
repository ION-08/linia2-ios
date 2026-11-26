//
//  NotificationService.swift
//  TinodiosNSExtension
//
//  Copyright © 2019-2022 Tinode. All rights reserved.
//

import UserNotifications
import TinodeSDK
import TinodiosDB

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    let log = TinodeSDK.Log(subsystem: BaseDb.kBundleId)

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        // New message notification (msg):
        // - P2P
        //   Title: <sender name> || 'Unknown'
        //   Body: <message content> || 'New message'
        // - GRP
        //   Title: <topic name> || 'Unknown'
        //   Body: <sender name>: <message content> || 'New message'
        //
        // Subscription notification (sub):
        // - P2P
        //   Title: 'New chat'
        //   Body: <sender name> || 'Unknown'
        // - GRP
        //   Title: 'New chat'
        //   Body: <group name> || 'Unknown'
        // Deleted subscription:
        //   Always invisible.
        //

        if let bestAttemptContent = bestAttemptContent {
            let payload = bestAttemptContent.userInfo
            // LINIA2: обработчик вызывается на любом пути (раньше «return» без него — уведомление ждало 30 с).
            guard let topicName = payload["topic"] as? String, !topicName.isEmpty, let from = payload["xfrom"] as? String, !from.isEmpty else {
                contentHandler(bestAttemptContent)
                return
            }

            let action = payload["what"] as? String ?? "msg"

            guard ["msg", "sub"].contains(action) else {
                // Not handling it here.
                contentHandler(bestAttemptContent)
                return
            }

            defer { contentHandler(bestAttemptContent) }

            guard let store = BaseDb.sharedInstance.sqlStore else { return }
            let topicType = Tinode.topicTypeByName(name: topicName)
            let senderName: String
            switch topicType {
            case .p2p:
                var user = store.userGet(uid: from) as? DefaultUser
                if user == nil {
                    // If we don't have the user info, fetch it from the server.
                    let tinode = SharedUtils.createTinode()
                    self.log.info("Fetching desc from server for user %@.", from)
                    if SharedUtils.fetchDesc(using: tinode, for: from) == .newData {
                        // The above call blocks until the servers replies, but it takes time to sync data to local store. Give the thread 1 second to persist the data.
                        Thread.sleep(forTimeInterval: 1)
                        user = store.userGet(uid: from) as? DefaultUser
                    } else {
                        self.log.info("No new desc data fetched for %@.", from)
                    }
                    tinode.disconnect()
                }
                senderName = user?.pub?.fn ?? "собеседника"
                break
            case .grp:
                let topic = store.topicGet(from: nil, withName: topicName) as? DefaultComTopic
                senderName = topic?.pub?.fn ?? NSLocalizedString("Unknown", comment: "Placeholder for missing topic name")
                break
            default:
                return
            }

            // LINIA2: текст сообщения в уведомлении НЕ показываем (и сервер его не передаёт) —
            // только «Новое сообщение от <имя>».
            bestAttemptContent.subtitle = ""
            if action == "msg" {
                if payload["webrtc"] as? String == "started" {
                    bestAttemptContent.title = "Входящий звонок"
                    bestAttemptContent.body = "Звонок от " + senderName
                } else if topicType == .grp {
                    let author = (store.userGet(uid: from) as? DefaultUser)?.pub?.fn
                    bestAttemptContent.title = senderName
                    bestAttemptContent.body = author != nil ? "Новое сообщение от " + author! : "Новое сообщение"
                } else {
                    bestAttemptContent.title = "Линия 2.0"
                    bestAttemptContent.body = "Новое сообщение от " + senderName
                }
            } else if action == "sub" {
                bestAttemptContent.title = "Новый чат"
                bestAttemptContent.body = senderName
            }
        } else {
            contentHandler(request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // 30 seconds.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

}
