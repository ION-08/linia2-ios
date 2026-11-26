//
//  Linia2Diagnostics.swift
//  Линия 2.0: Firebase (Crashlytics + Analytics) и доставка push-токенов на сервер.
//
//  Firebase включается, только если в сборке настоящий GoogleService-Info.plist (в CI-тестах — заглушка
//  ci/GoogleService-Info.stub.plist, тогда всё здесь молча ничего не делает).
//  В журнал событий НЕ пишутся персональные данные: ни тексты сообщений, ни логины, ни имена, ни топики.
//

import Foundation
import FirebaseCore
import FirebaseCrashlytics
import FirebaseAnalytics
import FirebaseMessaging
import TinodeSDK

enum Linia2Firebase {
    /// Firebase настроен (FirebaseApp.configure вызван ровно один раз).
    private(set) static var configured = false

    /// Вызывать как можно раньше в didFinishLaunching (Crashlytics должен успеть поймать ранние вылеты).
    /// Только с главного потока.
    static func configureIfNeeded() {
        guard !configured, UiUtils.firebaseAvailable else { return }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        configured = true
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        let info = Bundle.main.infoDictionary
        Crashlytics.crashlytics().setCustomValue(info?["CFBundleShortVersionString"] as? String ?? "?", forKey: "l2_version")
        Crashlytics.crashlytics().setCustomValue(info?["CFBundleVersion"] as? String ?? "?", forKey: "l2_build")
    }
}

/// Журнал ключевых событий: Crashlytics.log (виден рядом с отчётом о вылете) + Analytics.logEvent.
/// Параметры — только технические (тип чата, вид звонка, состояние приложения), без персональных данных.
enum L2Log {
    static func event(_ name: String, _ params: [String: Any] = [:]) {
        let line = params.isEmpty ? name : name + " " + params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        Cache.log.info("L2: %@", line)
        guard Linia2Firebase.configured else { return }
        Crashlytics.crashlytics().log(line)
        Analytics.logEvent(name, parameters: params.isEmpty ? nil : params)
    }

    /// Тип чата по имени топика (без самого имени).
    static func topicKind(_ name: String?) -> String {
        guard let n = name else { return "none" }
        if n.hasPrefix("usr") || n.hasPrefix("p2p") { return "p2p" }
        if n.hasPrefix("grp") || n.hasPrefix("new") { return "grp" }
        if n.hasPrefix("chn") || n.hasPrefix("nch") { return "chn" }
        if n == "slf" { return "slf" }
        return "other"
    }
}

// MARK: - Push: FCM-токен → сервер Tinode, VoIP-токен → linia2-auth

/// Отвечает за то, чтобы сервер Tinode ВСЕГДА знал FCM-токен этого устройства:
/// при каждом запуске, при обновлении токена (MessagingDelegate) и после каждого входа (если токен пришёл
/// раньше, чем установилось соединение, — Tinode отбрасывает его, поэтому повторяем после onLogin).
final class Linia2Push: TinodeEventListener {
    static let shared = Linia2Push()
    private let kFcm = "linia2.fcm.token"

    private(set) var fcmToken: String? {
        get { UserDefaults.standard.string(forKey: kFcm) }
        set { UserDefaults.standard.set(newValue, forKey: kFcm) }
    }

    /// Новый (или тот же) FCM-токен от Firebase.
    func didReceive(fcmToken token: String) {
        guard !token.isEmpty else { return }
        let changed = token != fcmToken
        fcmToken = token
        L2Log.event("l2_push_token", ["kind": "fcm", "changed": changed ? 1 : 0])
        send()
    }

    /// Выход из аккаунта: токен удаляется в Firebase (Cache.invalidate), забываем и мы.
    func forget() { fcmToken = nil }

    /// Отправить токен на сервер Tinode ({hi dev}). Без соединения Tinode токен теряет — тогда ждём onLogin.
    func send() {
        DispatchQueue.main.async {
            guard let token = self.fcmToken, !token.isEmpty else { return }
            let tinode = Cache.tinode
            guard tinode.isConnected else {
                Cache.log.info("Linia2Push: нет соединения, FCM-токен уйдёт после входа")
                return
            }
            tinode.setDeviceToken(token: token).thenApply { _ in
                L2Log.event("l2_push_token_sent", ["kind": "fcm"])
                return nil
            }
        }
    }

    // Успешный вход (в т.ч. автоматический по токену при запуске/переподключении).
    func onLogin(code: Int, text: String) {
        guard code < 300 else {
            L2Log.event("l2_login_failed", ["code": code])
            return
        }
        L2Log.event("l2_login", ["code": code])
        send()
        Linia2Voip.shared.register()
    }
}
