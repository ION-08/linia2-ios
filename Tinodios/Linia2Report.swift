//
//  Linia2Report.swift
//  Линия 2.0: жалобы (POST /invite/api/report, см. CONTRACTS.md) и блокировка собеседников.
//  Блокировка — как в Tinode (TopicSecurityViewController.blockContact): у своего режима доступа
//  снимаются права J и P («-JP»). Признак блокировки — !topic.isJoiner (так же фильтрует
//  список «Заблокированные» в Linia2Settings.swift). Писать и звонить при этом сервер Tinode не даёт.
//

import UIKit
import TinodeSDK

enum Linia2Moderation {
    enum Reason: String, CaseIterable {
        case spam, abuse, illegal, other

        var title: String {
            switch self {
            case .spam: return "Спам"
            case .abuse: return "Оскорбления"
            case .illegal: return "Незаконный контент"
            case .other: return "Другое"
            }
        }
    }

    static let kMaxText = 1000
    static let kMaxComment = 500

    // MARK: Жалоба

    /// Лист выбора причины → необязательный комментарий → отправка.
    /// - Parameters:
    ///   - topic: имя топика (usr… для личного чата, grp… для группы).
    ///   - reported: uid пользователя, на которого жалуются (если известен).
    ///   - seq/text: сообщение, на которое жалуются (для жалобы на профиль — nil).
    static func report(from vc: UIViewController, topic: String, reported: String?,
                       seq: Int? = nil, text: String? = nil,
                       sourceView: UIView? = nil, barItem: UIBarButtonItem? = nil) {
        let title = seq == nil ? "Пожаловаться" : "Пожаловаться на сообщение"
        let sheet = UIAlertController(title: title, message: "Выберите причину", preferredStyle: .actionSheet)
        for r in Reason.allCases {
            sheet.addAction(UIAlertAction(title: r.title, style: .default) { [weak vc] _ in
                guard let vc = vc else { return }
                askComment(from: vc, reason: r, topic: topic, reported: reported, seq: seq, text: text)
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        anchor(sheet, in: vc, sourceView: sourceView, barItem: barItem)
        vc.present(sheet, animated: true)
    }

    private static func askComment(from vc: UIViewController, reason: Reason, topic: String, reported: String?,
                                   seq: Int?, text: String?) {
        let alert = UIAlertController(title: reason.title,
                                      message: "Комментарий для администратора (необязательно)",
                                      preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "Комментарий"
            f.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Отправить", style: .default) { [weak alert] _ in
            let comment = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            send(topic: topic, reported: reported, seq: seq, text: text, reason: reason, comment: comment)
        })
        vc.present(alert, animated: true)
    }

    /// Отправить жалобу на сервер «Линия 2.0».
    static func send(topic: String, reported: String?, seq: Int?, text: String?, reason: Reason, comment: String) {
        guard let token = Cache.tinode.authToken, !token.isEmpty else {
            UiUtils.showToast(message: "Не удалось отправить жалобу: войдите в аккаунт заново.")
            return
        }
        var body: [String: Any] = ["topic": topic, "reason": reason.rawValue]
        if let reported = reported, !reported.isEmpty { body["reported"] = reported }
        if let seq = seq, seq > 0 { body["seq"] = seq }
        if let text = text, !text.isEmpty { body["text"] = String(text.prefix(kMaxText)) }
        if !comment.isEmpty { body["comment"] = String(comment.prefix(kMaxComment)) }
        Linia2API.post("report", body, token: token) { status, json in
            if json?["ok"] as? Bool == true {
                UiUtils.showToast(message: "Жалоба отправлена. Администратор проверит её.", level: .info)
                return
            }
            if status == 0 || json == nil {
                UiUtils.showToast(message: Linia2API.networkError)
                return
            }
            if status == 401 || status == 403 {
                UiUtils.showToast(message: "Не удалось отправить жалобу: войдите в аккаунт заново.")
                return
            }
            let err = (json?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            UiUtils.showToast(message: "Не удалось отправить жалобу" + (err.map { ": " + $0 } ?? ". Попробуйте ещё раз."))
        }
    }

    // MARK: Блокировка

    /// Заблокирован ли собеседник (тот же признак, что у списка «Заблокированные»).
    static func isBlocked(_ topic: DefaultComTopic) -> Bool {
        !topic.isJoiner
    }

    /// Подтверждение и блокировка/разблокировка. completion(успех) — на главном потоке.
    static func confirmToggleBlock(from vc: UIViewController, topic: DefaultComTopic,
                                   sourceView: UIView? = nil, barItem: UIBarButtonItem? = nil,
                                   completion: ((Bool) -> Void)? = nil) {
        let name = Linia2ContactInfo.name(of: topic)
        let blocked = isBlocked(topic)
        let alert: UIAlertController
        if blocked {
            alert = UIAlertController(title: "Разблокировать \(name)?",
                                      message: "Собеседник снова сможет писать и звонить вам.",
                                      preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Разблокировать", style: .default) { _ in
                setBlocked(false, topic: topic, completion: completion)
            })
        } else {
            alert = UIAlertController(title: "Заблокировать \(name)?",
                                      message: "Собеседник не сможет писать и звонить вам. Разблокировать можно в «Настройки → Конфиденциальность → Безопасность аккаунта → Заблокированные».",
                                      preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Заблокировать", style: .destructive) { _ in
                setBlocked(true, topic: topic, completion: completion)
            })
        }
        vc.present(alert, animated: true)
    }

    /// Блокировка: «-JP» к своему режиму (как TopicSecurityViewController.blockContact).
    /// Разблокировка: как BlockedContactsTableViewController — подписка восстанавливает доступ,
    /// затем топик отпускается; если топик уже открыт (attached) — возвращаем права «+JP».
    /// Изменение режима требует подписки на топик, поэтому неоткрытый топик временно подписываем.
    static func setBlocked(_ block: Bool, topic: DefaultComTopic, completion: ((Bool) -> Void)? = nil) {
        guard Cache.tinode.isConnected else {
            UiUtils.showToast(message: Linia2API.networkError)
            completion?(false)
            return
        }
        let wasAttached = topic.attached
        let promise: PromisedReply<ServerMessage>
        if block {
            if wasAttached {
                promise = topic.updateMode(uid: nil, update: "-JP")
            } else {
                promise = topic.subscribe().thenApply { _ in
                    return topic.updateMode(uid: nil, update: "-JP")
                }
            }
        } else {
            if wasAttached {
                promise = topic.updateMode(uid: nil, update: "+JP")
            } else {
                promise = topic.subscribe()
            }
        }
        promise.then(
            onSuccess: { _ in
                if !wasAttached && topic.attached {
                    topic.leave()
                }
                DispatchQueue.main.async {
                    UiUtils.showToast(message: block ? "Собеседник заблокирован" : "Собеседник разблокирован", level: .info)
                    completion?(true)
                }
                return nil
            },
            onFailure: { err in
                if !wasAttached && topic.attached {
                    topic.leave()
                }
                DispatchQueue.main.async {
                    let what = block ? "заблокировать" : "разблокировать"
                    if let e = err as? TinodeError, case .notConnected = e {
                        UiUtils.showToast(message: Linia2API.networkError)
                    } else {
                        UiUtils.showToast(message: "Не удалось \(what) собеседника. Попробуйте ещё раз.")
                    }
                    completion?(false)
                }
                return nil
            })
    }

    // MARK: Помощники

    static func anchor(_ sheet: UIAlertController, in vc: UIViewController, sourceView: UIView?, barItem: UIBarButtonItem?) {
        guard let pop = sheet.popoverPresentationController else { return }
        if let barItem = barItem {
            pop.barButtonItem = barItem
        } else {
            guard let v = sourceView ?? vc.viewIfLoaded else { return }
            pop.sourceView = v
            pop.sourceRect = sourceView?.bounds ?? CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1)
        }
    }
}

// MARK: - Меню сообщения: «Пожаловаться»

extension MessageViewController {
    @objc func linia2ReportMessage(sender: UIMenuController) {
        guard let item = sender.menuItems?.first as? MessageMenuItem, item.seqId > 0,
              let idx = messageSeqIdIndex[item.seqId], idx >= 0, idx < messages.count,
              let name = topicName else { return }
        let msg = messages[idx]
        guard !isFromCurrentSender(message: msg) else { return }
        // Для личного чата нарушитель — собеседник (имя топика = его uid).
        let reported = msg.from ?? ((topic?.isP2PType ?? false) ? name : nil)
        Linia2Moderation.report(from: self, topic: name, reported: reported,
                                seq: msg.seqId, text: msg.content?.string)
    }
}

// MARK: - Инфо о чате: кнопка «⋯» с жалобой и блокировкой (без правки storyboard)

extension TopicInfoViewController {
    private static let kL2MoreId = "l2.topicinfo.more"

    func linia2InstallModerationMenu() {
        guard let topic = Cache.tinode.getTopic(topicName: topicName) as? DefaultComTopic,
              !topic.isSlfType else { return }
        var items = navigationItem.rightBarButtonItems ?? []
        guard !items.contains(where: { $0.accessibilityIdentifier == Self.kL2MoreId }) else { return }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain,
                                   target: self, action: #selector(linia2MoreTapped(_:)))
        more.accessibilityIdentifier = Self.kL2MoreId
        more.accessibilityLabel = "Ещё"
        items.append(more)
        navigationItem.rightBarButtonItems = items
    }

    @objc func linia2MoreTapped(_ sender: UIBarButtonItem) {
        guard let topic = Cache.tinode.getTopic(topicName: topicName) as? DefaultComTopic else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let name = topicName
        sheet.addAction(UIAlertAction(title: "Пожаловаться", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            Linia2Moderation.report(from: self, topic: name, reported: topic.isP2PType ? name : nil, barItem: sender)
        })
        if topic.isP2PType {
            let title = Linia2Moderation.isBlocked(topic) ? "Разблокировать" : "Заблокировать"
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                Linia2Moderation.confirmToggleBlock(from: self, topic: topic)
            })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        Linia2Moderation.anchor(sheet, in: self, sourceView: nil, barItem: sender)
        present(sheet, animated: true)
    }
}
