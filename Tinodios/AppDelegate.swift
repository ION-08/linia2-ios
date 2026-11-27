//
//  AppDelegate.swift
//  ios
//
//  Copyright © 2019-2025 Tinode LLC. All rights reserved.
//

import Firebase
import Intents
import PushKit
import Network
import UIKit
import TinodeSDK
import TinodiosDB

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var backgroundSessionCompletionHandler: (() -> Void)?
    // Network reachability.
    var nwReachability: Any!
    var pushNotificationsConfigured = false
    var appIsStarting: Bool = false
    // Video call event listener.
    var callListener = CallEventListener()

    var voipRegistry: PKPushRegistry!

    // Video call event listener (responsible for displaying and dismissing Call UI).
    class CallEventListener: TinodeEventListener {
        func onInfoMessage(info: MsgServerInfo?) {
            guard let info = info, info.what == "call", let seq = info.seq, let topic = info.src else { return }
            switch info.event {
            case  "accept":
                // We have just accepted this call in another client.
                if !Cache.callManager.currentCallIsOutgoing {
                    Cache.callManager.dismissIncomingCall(onTopic: topic, withSeqId: seq, reason: .answeredElsewhere)
                } else if let cur = Cache.callManager.callInProgress, cur.topic == topic, cur.seq == seq {
                    // LINIA2: собеседник ответил на наш звонок — с этого момента 30 с на соединение.
                    Cache.callManager.startConnectWatchdog()
                }
            case "hang-up":
                // LINIA2: и идущий (принятый / исходящий) звонок — сразу, даже если экран звонка не получил «hang-up».
                DispatchQueue.main.async {
                    let cm = Cache.callManager
                    if let cur = cm.callInProgress, cur.topic == topic, cur.seq == seq, cur.accepted || cm.currentCallIsOutgoing {
                        cm.endCallInProgressRemotely(topic: topic, seq: seq, why: "info-hang-up")
                    } else {
                        cm.dismissIncomingCall(onTopic: topic, withSeqId: seq)
                    }
                }
            default:
                break
            }
        }
        func onDataMessage(data: MsgServerData?) {
            let tinode = Cache.tinode
            // The message is from a peer.
            guard let data = data, let seqId = data.replacesSeq ?? data.seq, let originator = data.from,
                // It is a video call message.
                let callState = data.webrtcCallState,
                let topicName = data.topic else { return }
            // LINIA2: финальное состояние звонка (finished / disconnected / missed / declined / busy) завершает его
            // всегда — даже если топик не загружен (чат не открыт, приложение в фоне) или сообщение ещё не в базе,
            // и от кого бы ни было сообщение (замену пишет сервер от имени звонившего — для исходящего это «я»).
            let isFinal = callState == .kBusy || callState == .kDeclined || callState == .kMissed
                || callState == .kDisconnected || callState == .kFinished
            if isFinal {
                Linia2EndedCalls.mark(topicName, seqId)
                DispatchQueue.main.async {
                    let cm = Cache.callManager
                    guard let cur = cm.callInProgress, cur.topic == topicName, cur.seq == seqId else { return }
                    Cache.log.info("Call (topic: %@, seq: %d): final state %@", topicName, seqId, callState.rawValue)
                    if cur.accepted || cm.currentCallIsOutgoing {
                        cm.endCallInProgressRemotely(topic: topicName, seq: seqId, why: "msg-" + callState.rawValue)
                    } else {
                        cm.dismissIncomingCall(onTopic: topicName, withSeqId: seqId)
                    }
                }
                return
            }
            // Остальное (started / accepted) — только от собеседника.
            guard !tinode.isMe(uid: originator), let topic = tinode.getTopic(topicName: topicName) else { return }

            // Check if we have a later version of the message (which means this call state is outdated).
            guard let msg = topic.getMessage(byEffectiveSeq: seqId) as? StoredMessage,
                  msg.webrtcCallState == callState else { return }

            let isAudioOnly = data.isAudioOnlyCall
            Cache.log.info("Call (topic: %@, seq: %d): processing event %@", topicName, seqId, String(reflecting: callState))
            switch callState {
            case .kStarted:
                // LINIA2 (баг 1006): старое «started» (история при подписке/выборке по push, повтор после отбоя)
                // не должно поднимать звонок заново: звонок уже завершён здесь или сообщению больше таймаута звонка.
                if Linia2EndedCalls.contains(topicName, seqId) {
                    Cache.log.info("Call (topic: %@, seq: %d): already ended — ignoring 'started'", topicName, seqId)
                    return
                }
                if let ts = data.ts, CallManager.isStale(sentAt: ts) {
                    Cache.log.info("Call (topic: %@, seq: %d): 'started' is too old — ignoring", topicName, seqId)
                    Linia2EndedCalls.mark(topicName, seqId)
                    return
                }
                // It is a legit incoming call. Start it.
                let backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                let show = {
                    let guest = data.head?["linia2-guest"] != nil ? Linia2GuestLinks.info(fromHead: data.head, seq: seqId) : nil
                    Cache.callManager.displayIncomingCall(uuid: UUID(), onTopic: topic.name, originatingFrom: originator, withSeqId: seqId, audioOnly: isAudioOnly, guest: guest) { err in
                        if let err = err {
                            Cache.log.error("Unable to take the call: %@", err.localizedDescription)
                        }
                        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
                    }
                }
                // LINIA2 (фантомный повторный входящий): «started» не «живой» (старше нескольких секунд — пришёл
                // историей при подписке, а финальное сообщение звонка ещё не загружено) — сначала спросить сервер.
                if let ts = data.ts, CallManager.isOlderThan(sentAt: ts, seconds: 6), topicName.hasPrefix("usr") {
                    DispatchQueue.main.async {
                        Linia2Voip.shared.checkCall(topic: topicName, seq: seqId) { state in
                            if state == "ended" || state == "accepted" || Linia2EndedCalls.contains(topicName, seqId) {
                                Cache.log.info("Call (topic: %@, seq: %d): late 'started', server says %@ — ignoring", topicName, seqId, state ?? "")
                                Linia2EndedCalls.mark(topicName, seqId)
                                UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
                                return
                            }
                            show()
                        }
                    }
                    return
                }
                DispatchQueue.main.async(execute: show)
            case .kAccepted:
                if !Cache.callManager.currentCallIsOutgoing {
                    Cache.log.info("Dismissing incoming call: topic=%@, seq=%d", topic.name, seqId)
                    Cache.callManager.dismissIncomingCall(onTopic: topic.name, withSeqId: seqId)
                }
            default:
                break
            }
        }
    }

    /// LINIA2: момент запуска процесса (для замеров «интерфейс готов» в автотестах).
    static let launchedAt = Date()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = AppDelegate.launchedAt
        Cache.log.info("App launched with options: %@", launchOptions ?? [:])
        Linia2ConnectionNotice.quietPeriod(10)   // LINIA2: при запуске — без «Связь потеряна» (только «Подключение…»)
        Linia2TestHook.applyLaunchOverrides()    // только под -l2-uitest: «сервер недоступен N с» и т.п.
        // LINIA2: Firebase (Crashlytics/Analytics/FCM) — первым делом, чтобы ловить и ранние вылеты.
        // Делегаты уведомлений — до конца didFinishLaunching (иначе теряется нажатие на push при холодном старте).
        Linia2Firebase.configureIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        if Linia2Firebase.configured { Messaging.messaging().delegate = self }
        L2Log.event("l2_app_start", ["push_launch": launchOptions?[.remoteNotification] != nil ? 1 : 0])
        if SharedUtils.isFirstLaunch {
            Cache.log.info("First time launch. Setting up...")
            SharedUtils.isFirstLaunch = false
            SharedUtils.identifyAndConfigureBranding()
        }
        SharedUtils.registerUserDefaults()
        // LINIA2: защита файлов, зашифрованный кэш картинок, HTTP-кэш только в памяти (до первого обращения к базе).
        Linia2Storage.start()
        // LINIA2: удалённые настройки (цвета, тексты, функции) — до применения темы.
        Linia2Config.shared.start()
        DispatchQueue.main.async { Linia2Failover.shared.start() }   // LINIA2_FAILOVER: резервные адреса + «Подключение…»
        // LINIA2: тема и акцент.
        Linia2Theme.apply(to: window)
        // LINIA2: блокировка приложения PIN-кодом (Face ID отключён).
        Linia2AppLock.shared.start()
        Linia2WipeExecutor.install()
        Linia2WipeSync.shared.start()
        Linia2TestHook.install()   // только под -l2-uitest

        let baseDb = BaseDb.sharedInstance
        if baseDb.isReady {
            // When the app launch after user tap on notification (originally was not running / not in background), except incoming calls which are handled separately.
            if let opts = launchOptions, let userInfo = opts[.remoteNotification] as? [String: Any],
                userInfo["webrtc"] == nil, let topicName = userInfo["topic"] as? String, !topicName.isEmpty {
                UiUtils.routeToMessageVC(forTopic: topicName)
            } else {
                UiUtils.routeToChatListVC()
            }
        } else {
            // LINIA2: не вошли — «Добро пожаловать».
            window?.rootViewController = Linia2WelcomeViewController.makeRoot()
        }

        registerForVoip()

        // Try to connect and login in the background.
        // LINIA2 (баг 1006): подключение не держит интерфейс (список чатов — из базы, сразу); не удалось —
        // повторы с нарастающей паузой (2, 4, 8, 16, 30 с), пока приложение на экране или идёт звонок.
        AppDelegate.connectInBackground(attempt: 0)
        Cache.tinode.addListener(self.callListener)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .seconds(10)) {
            let reachability = NWPathMonitor()
            reachability.start(queue: DispatchQueue.global(qos: .background))
            reachability.pathUpdateHandler = { path in
                let tinode = Cache.tinode
                if path.status == .satisfied { Linia2WipeExecutor.flush() }   // LINIA2: неотправленные отчёты
                if path.status == .satisfied, !tinode.isConnected {
                    Cache.log.info("NWPathMonitor: network available - reconnecting")
                    tinode.reconnectNow(interactively: false, reset: false)
                }
            }
            self.nwReachability = reachability
        }
        return true
    }

    // LINIA2: APNs-токен → FCM (явно, не полагаясь на подмену методов Firebase).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        L2Log.event("l2_push_token", ["kind": "apns", "bytes": deviceToken.count])
        guard Linia2Firebase.configured else { return }
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        L2Log.event("l2_push_token_error", ["kind": "apns", "code": (error as NSError).code])
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        backgroundSessionCompletionHandler = completionHandler
        // Instantiate large file helper.
        _ = Cache.getLargeFileHelper(withIdentifier: identifier)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        self.appIsStarting = false
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        self.appIsStarting = false
        Linia2Storage.didEnterBackground()   // LINIA2: отложенный VACUUM после миграции базы
        application.applicationIconBadgeNumber = Cache.totalUnreadCount()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        self.appIsStarting = true
        Linia2ConnectionNotice.quietPeriod(10)
        if Cache.tinode.myUid != nil, !Cache.tinode.isConnectionAuthenticated { AppDelegate.connectInBackground(attempt: 0) }
        SharedUtils.syncUserDefaults()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Linia2Storage.becameActive()   // LINIA2: ключи хранилища и шифрование старой базы
        Linia2WipeSync.shared.refresh()
        Linia2Turn.shared.prefetch()
        // LINIA2: звонок, принятый на заблокированном экране / в фоне, — показать его экран.
        Linia2CallCenter.shared.applicationDidBecomeActive()
        Linia2Voip.shared.register()
        Linia2GuestLinks.refreshGuestUid()
        self.appIsStarting = false
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // LINIA2: приложение закрыли (смахнули) во время звонка — завершить звонок в CallKit и у собеседника,
        // иначе на iPhone оставался «идущий звонок» с бегущими секундами.
        Cache.callManager.endForTermination()
        application.applicationIconBadgeNumber = Cache.totalUnreadCount()
    }

    // Notification received. Process it.
    // Application woken up in the background (e.g. for data fetch).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let state = application.applicationState
        L2Log.event("l2_push_received", ["what": (userInfo["what"] as? String) ?? (userInfo["l2cfg"] != nil ? "cfg" : "msg"),
                                         "state": state == .active ? "fg" : (state == .background ? "bg" : "inactive"),
                                         "call": userInfo["webrtc"] != nil ? 1 : 0])
        // LINIA2: настройка устройства с сервера (тот же тихий push linia2-config или {"l2wipe"}).
        if Linia2WipeSync.handlePush(userInfo) {
            completionHandler(.newData)
            return
        }
        // LINIA2: тихий push «конфиг обновлён» (тема FCM linia2-config) — перечитать удалённые настройки.
        if Linia2Config.handlePush(userInfo) {
            completionHandler(.newData)
            return
        }
        guard let topicName = userInfo["topic"] as? String, !topicName.isEmpty else {
            completionHandler(.failed)
            return
        }
        if state == .background || (state == .inactive && !self.appIsStarting) {
            // LINIA2: выборка — НЕ на главном потоке. Раньше fetchData (подключение, вход, подписка — синхронно,
            // без таймаута) выполнялся прямо здесь, на главном: несколько push подряд (бот «Безопасность»)
            // держали главный поток секундами, а при «повисшем» ответе — навсегда; открытие приложения
            // (нажатие на уведомление) в этот момент — и система убивала приложение по сторожевому таймеру.
            // Холодный старт по нажатию тоже попадал сюда (appIsStarting ещё false) — блокировал запуск.
            let what = userInfo["what"] as? String
            let seq = Int(userInfo["seq"] as? String ?? "") ?? 0
            let isCall = userInfo["webrtc"] != nil
            let done: (UIBackgroundFetchResult) -> Void = { r in DispatchQueue.main.async { completionHandler(r) } }
            let queuedAt = Date()
            AppDelegate.pushFetchQueue.async {
                // Система даёт ~30 с на push: долго ждали в очереди за другими — не начинать (сообщения придут при открытии).
                guard Date().timeIntervalSince(queuedAt) < 20 else { done(.noData); return }
                let tinode = Cache.tinode
                if what == nil || what == "msg" {
                    // New message.
                    guard seq > 0 else { done(.failed); return }
                    // Video call: keep connection to fetch related messages.
                    // Приложение открывается (inactive) — не покидать топик через 1 с: его может держать открытый чат.
                    done(SharedUtils.fetchData(using: tinode, for: topicName, seq: seq, keepConnection: isCall || state == .inactive))
                } else if what == "sub" {
                    // New subscription.
                    done(SharedUtils.fetchDesc(using: tinode, for: topicName))
                } else if what == "read" {
                    // Read notification.
                    done(seq > 0 ? SharedUtils.updateRead(using: tinode, for: topicName, seq: seq) : .failed)
                } else {
                    Cache.log.error("Invalid 'what' value ['%@'] in push notification for topic '%@'", what ?? "", topicName)
                    done(.failed)
                }
            }
        } else if state == .inactive && self.appIsStarting {
            // User tapped notification.
            completionHandler(.newData)
        } else {
            // App is active.
            completionHandler(.noData)
        }
    }

    private static let connectQueue = DispatchQueue(label: "info.codix.liniya2.startup-connect", qos: .userInitiated)
    private static var connectGeneration = 0

    /// LINIA2: вход в фоне с повторами. Каждый шаг ограничен по времени (SharedUtils.connectTimeout);
    /// «нет ответа» не выход из аккаунта — выход только при однозначном отказе сервера (connectAndLoginSync → false).
    static func connectInBackground(attempt: Int) {
        DispatchQueue.main.async {
            if attempt == 0 { connectGeneration += 1 }
            let gen = connectGeneration
            connectQueue.async {
                // LINIA2 (сборка 1007, первый запуск): не вошли (нет сохранённого токена) — подключаться и тем
                // более «выходить» нечего. Раньше «missing user name» → false → logoutAndRouteToLoginVC() с
                // фонового потока: Cache.invalidate() уничтожал Tinode, через который пользователь как раз входил
                // на экране «Добро пожаловать» («нет соединения с сервером»), экран входа сбрасывался, вылет.
                guard let token = SharedUtils.getAuthToken(), !token.isEmpty,
                      let user = SharedUtils.getSavedLoginUserName(), !user.isEmpty else { return }
                let tinode = Cache.tinode
                if tinode.isConnectionAuthenticated { return }
                let ok = SharedUtils.connectAndLoginSync(using: tinode, inBackground: false)
                if !ok {
                    // Выход — только если это всё ещё тот же вход (пользователь не вошёл заново за это время).
                    DispatchQueue.main.async {
                        guard SharedUtils.getAuthToken() == token, !Cache.tinode.isConnectionAuthenticated else { return }
                        UiUtils.logoutAndRouteToLoginVC()
                    }
                    return
                }
                guard !tinode.isConnectionAuthenticated, attempt < 8 else { return }
                let delays: [Double] = [2, 4, 8, 16, 30]
                let delay = delays[min(attempt, delays.count - 1)]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard gen == connectGeneration, !Cache.tinode.isConnectionAuthenticated,
                          UIApplication.shared.applicationState != .background || Cache.callManager.callInProgress != nil else { return }
                    Cache.log.info("Startup: not connected yet — retry #%d", attempt + 1)
                    connectInBackground(attempt: attempt + 1)
                }
            }
        }
    }

    /// LINIA2: фоновые выборки по push — по одной, вне главного потока.
    static let pushFetchQueue = DispatchQueue(label: "info.codix.liniya2.push-fetch", qos: .utility)

    // LINIA2: liniya2://call/<token> — ссылка на звонок (кнопка «Открыть в приложении» на странице гостя).
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if let token = Linia2GuestLinks.token(from: url) {
            Linia2GuestLinks.open(token: token)
            return true
        }
        return false
    }

    // Tapped on a web link. See if it's an app link.
    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // LINIA2: перезвон из «Недавних» iPhone (CallKit): handle звонка = имя топика.
        if let intent = userActivity.interaction?.intent as? INStartCallIntent,
           let topic = intent.contacts?.first?.personHandle?.value, !topic.isEmpty {
            let video = intent.callCapability == .videoCall
            Linia2Root.openChat(topic, call: video ? .video : .audio)
            return true
        }
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let url = userActivity.webpageURL,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return false
        }
        // TODO: support 3rd party urls.
        if let token = Linia2GuestLinks.token(from: url) {
            Linia2GuestLinks.open(token: token)
            return true
        }
        if components.host?.hasSuffix("chat-linia.site") ?? false {
            // Start the app.
            return true
        }
        return false
    }

    func registerForVoip() {
        self.voipRegistry = PKPushRegistry(queue: nil)
        self.voipRegistry.delegate = self
        self.voipRegistry.desiredPushTypes = [.voIP]
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Notification received. Process it.
    // Called when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let what = userInfo["what"] as? String
        L2Log.event("l2_push_received", ["what": what ?? "msg", "state": "fg", "call": userInfo["webrtc"] != nil ? 1 : 0])
        // Only handling "msg" notifications. New subscriptions ("sub" notifications) in the foreground
        // will be handled automatically by Tinode SDK.
        // LINIA2: completionHandler обязателен на любом пути (раньше для "sub" и т.п. не вызывался).
        guard let topicName = userInfo["topic"] as? String, !topicName.isEmpty,
            what == nil || what == "msg", let seq = Int(userInfo["seq"] as? String ?? "") else {
            completionHandler([])
            return
        }

        if let messageVC = UiUtils.topViewController(rootViewController: (UIApplication.shared.delegate as! AppDelegate).window?.rootViewController) as? MessageViewController, messageVC.topicName == topicName {
            // We are already in the correct topic. Do not present the notification.
            completionHandler([])
        } else {
            AppDelegate.pushFetchQueue.async {
                SharedUtils.fetchData(using: Cache.tinode, for: topicName, seq: seq, keepConnection: false)
            }
            // If the push notification is either silent or a video call related, do not present the alert.
            let suppressNotification = userInfo["silent"] as? String == "true" || userInfo["webrtc"] != nil
            completionHandler(suppressNotification ? [] : [.badge, .banner, .list, .sound])
        }
    }

    // User tapped on notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        Cache.log.info("User tapped on notification")
        L2Log.event("l2_push_opened", ["what": (userInfo["what"] as? String) ?? "msg"])
        defer { completionHandler() }
        guard let topicName = userInfo["topic"] as? String, !topicName.isEmpty else { return }
        let tinode = Cache.tinode
        if tinode.isConnectionAuthenticated {
            UiUtils.routeToMessageVC(forTopic: topicName)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if !SharedUtils.connectAndLoginSync(using: tinode, inBackground: false) {
                DispatchQueue.main.async { UiUtils.showToast(message: Linia2Texts.t("Failed to connect to server")) }
            } else {
                UiUtils.routeToMessageVC(forTopic: topicName)
            }
        }
    }
}

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        // Update token. Send to the app server.
        // LINIA2: сохраняем и отправляем сейчас (если есть соединение) и после каждого входа — см. Linia2Push.
        guard let token = fcmToken, !token.isEmpty else { return }
        Cache.log.info("FCM token received")
        Linia2Push.shared.didReceive(fcmToken: token)
    }
}

extension AppDelegate: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        Cache.log.info("PK token received")
        L2Log.event("l2_push_token", ["kind": "voip", "bytes": credentials.token.count])
        // LINIA2: VoIP-токен — на наш сервер (linia2-auth), он шлёт VoIP push напрямую в APNs.
        Linia2Voip.shared.update(token: credentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Cache.log.info("PK must invalidate token")
        L2Log.event("l2_push_token_invalidated", ["kind": "voip"])
        Linia2Voip.shared.invalidate()
    }

    // VoIP push notification recived.
    // Формат (linia2-auth → APNs): {"aps":{}, "data":{"topic","seq","webrtc":"started"|"hang-up","xfrom","aonly","name"}}.
    // ВАЖНО: на каждый VoIP push — reportNewIncomingCall (см. CallManager.handleVoipPush), иначе iOS закроет приложение.
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        Cache.log.info("PK push received")

        guard type == .voIP else {
            completion()
            return
        }
        let data = (payload.dictionaryPayload["data"] as? [String: Any]) ?? [:]
        let topicName = data["topic"] as? String ?? ""
        let callState = data["webrtc"] as? String ?? ""
        let seq = Int(data["seq"] as? String ?? "") ?? (data["seq"] as? Int) ?? Int(data["replace"] as? String ?? "") ?? 0
        let audioOnly = (data["aonly"] as? Bool) ?? ((data["aonly"] as? String) == "true")
        let name = data["name"] as? String
        // LINIA2: время отправки сервером (unix-секунды) — устаревший push (звонок уже кончился) не показывается.
        let ts = Double(data["ts"] as? String ?? "") ?? (data["ts"] as? Double)
        let sentAt = ts.map { Date(timeIntervalSince1970: $0) }
        L2Log.event("l2_voip_push", ["event": callState.isEmpty ? "none" : callState, "has_seq": seq > 0 ? 1 : 0])
        Cache.callManager.handleVoipPush(event: callState, topic: topicName, from: data["xfrom"] as? String, seq: seq,
                                         audioOnly: audioOnly, callerName: (name?.isEmpty ?? true) ? nil : name,
                                         sentAt: sentAt, completion: completion)
        // Подключиться к серверу (если приложение было закрыто) — дальше звонок идёт как обычно.
        if callState == MsgServerData.WebRTC.kStarted.rawValue {
            // При холодном старте подключение уже запускает didFinishLaunching; здесь — если приложение было в фоне.
            Linia2Turn.shared.prefetch()   // LINIA2: TURN заранее, до «Принять»
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let tinode = Cache.tinode
                if !tinode.isConnected {
                    tinode.reconnectNow(interactively: true, reset: false)
                }
            }
        }
    }
}
