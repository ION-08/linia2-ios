//
//  Linia2Burn.swift
//  Линия 2.0: режим самоуничтожения сообщений в чате (features.burnMode).
//
//  Формат — CONTRACTS-next.md, раздел 2 (общий с вебом):
//  включение/выключение — служебное сообщение с head {"linia2-burnmode": "on"|"off"} (строка: SDK веба выбрасывает 0/false) и текстом
//  «<Имя> включил(а) самоуничтожение: новые сообщения удаляются после прочтения» / «<Имя> выключил(а) самоуничтожение».
//  Действует ПОСЛЕДНЕЕ такое сообщение (по seq). Только личные чаты.
//  Сообщения, отправленные в режиме, несут head {"linia2-burn": 1}; после прочтения их удаляют у обоих (hard delete):
//  получатель — через burnMode.readSeconds (10 с) + длительность голосового/кружка, отправитель — то же + 2 с.
//  Скриншот в режиме → служебное сообщение head {"linia2-screenshot": 1}, «<имя> сделал(а) снимок экрана».
//  Удалённые настройки: features.burnMode (по умолчанию да), burnMode.readSeconds.
//

import UIKit
import TinodeSDK
import TinodiosDB

enum Linia2Burn {
    static let kHeader = "linia2-burn"
    static let kModeHeader = "linia2-burnmode"
    static let kScreenshotHeader = "linia2-screenshot"
    static let kAutoDeleteHeader = "linia2-autodelete"
    static let changed = Notification.Name("Linia2BurnChanged")

    static var featureOn: Bool { Linia2Config.shared.feature("burnMode") }

    /// Задержка удаления после прочтения (сек), 0…300 (burnMode.readSeconds).
    static var deleteDelay: TimeInterval {
        min(300, max(0, Linia2Config.shared.number("burnMode", "readSeconds") ?? 10))
    }

    /// Длительность голосового/кружка в сообщении (сек) — добавляется к задержке.
    static func mediaSeconds(_ m: Message) -> TimeInterval {
        let d = (m.content?.entities ?? []).compactMap { ($0.tp == "AU" || $0.tp == "VD") ? $0.data?["duration"]?.asInt() : nil }.max() ?? 0
        return min(600, TimeInterval(d) / 1000)
    }

    private static func key(_ topic: String) -> String { "linia2.burn." + topic }

    /// Включён ли режим в чате (по последнему служебному сообщению, сохранённому на устройстве).
    static func isOn(_ topic: String) -> Bool {
        guard featureOn else { return false }
        return (UserDefaults.standard.dictionary(forKey: key(topic))?["on"] as? Bool) ?? false
    }

    /// Запомнить состояние из служебного сообщения seq (более старые не перетирают более новые).
    @discardableResult
    static func record(topic: String, seq: Int, on: Bool) -> Bool {
        let d = UserDefaults.standard.dictionary(forKey: key(topic))
        let oldSeq = d?["seq"] as? Int ?? -1
        let oldOn = d?["on"] as? Bool ?? false
        guard seq >= oldSeq, seq != oldSeq || oldOn != on else { return false }
        UserDefaults.standard.set(["seq": seq, "on": on], forKey: key(topic))
        return oldOn != on
    }

    /// Служебное сообщение «включил/выключил»: head linia2-burnmode = "on" | "off" (а также true/1 для совместимости).
    static func toggleValue(_ m: Message) -> Bool? {
        guard let v = m.head?[kModeHeader] else { return nil }
        switch v {
        case .int(let i): return i != 0
        case .int64(let i): return i != 0
        case .double(let d): return d != 0
        case .bool(let b): return b
        case .string(let s): return s == "on" || s == "1" || s == "true"
        default: return nil
        }
    }

    /// Сообщение отправлено в режиме самоуничтожения (head linia2-burn: 1).
    static func isBurnMessage(_ m: Message) -> Bool {
        guard let v = m.head?[kHeader] else { return false }
        switch v {
        case .int(let i): return i != 0
        case .int64(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return s == "1"
        default: return false
        }
    }

    static func isScreenshotNote(_ m: Message) -> Bool { m.head?[kScreenshotHeader] != nil }

    /// Заголовок для новых сообщений чата в режиме.
    static func extraHead(topic: String) -> [String: JSONValue]? {
        isOn(topic) && Tinode.topicTypeByName(name: topic) == .p2p ? [kHeader: .int(1)] : nil
    }

    static var myName: String {
        let fn = Cache.tinode.getMeTopic()?.pub?.fn ?? ""
        return fn.isEmpty ? L2T("l2.burn.someone", "Собеседник") : fn
    }

    // Уже запланированные удаления (topic:seq).
    private static var scheduled = Set<String>()

    /// Удалить у всех через deleteDelay (один раз на сообщение).
    static func scheduleDelete(topic: DefaultComTopic, seq: Int, after: TimeInterval? = nil, done: (() -> Void)? = nil) {
        let k = topic.name + ":" + String(seq)
        guard seq > 0, !scheduled.contains(k) else { return }
        scheduled.insert(k)
        DispatchQueue.main.asyncAfter(deadline: .now() + (after ?? deleteDelay)) {
            topic.delMessages(ids: [seq], hard: true).then(onSuccess: { _ in
                DispatchQueue.main.async { done?() }
                return nil
            }, onFailure: { err in
                Cache.log.error("Linia2Burn: не удалось удалить %d: %@", seq, err.localizedDescription)
                // Удалить у собеседника нельзя (нет права D) — хотя бы у себя; уже удалено (404) — молча.
                var code = 0
                if case TinodeError.serverResponseError(let c, _, _)? = err as? TinodeError { code = c }
                if code != 404 {
                    _ = topic.delMessages(ids: [seq], hard: false)
                }
                DispatchQueue.main.async {
                    if code == 403 { UiUtils.showToast(message: L2T("l2.del.noPeer", "Удалить у собеседника нельзя"), level: .info) }
                    done?()
                }
                return nil
            })
        }
    }
}

extension MessageViewController {
    /// Системная строка по центру (не пузырь): самоуничтожение, скриншот, автоудаление.
    func linia2IsServiceMessage(_ m: Message) -> Bool {
        guard let head = m.head else { return false }
        return Linia2Burn.toggleValue(m) != nil || head[Linia2Burn.kScreenshotHeader] != nil || head[Linia2Burn.kAutoDeleteHeader] != nil
    }

    /// Текст системной строки: свои переключатели — «Вы включили …».
    func linia2ServiceText(_ m: Message) -> String? {
        guard let on = Linia2Burn.toggleValue(m), isFromCurrentSender(message: m) else { return nil }
        return on ? L2T("l2.burn.youOn", "Вы включили самоуничтожение: новые сообщения удаляются после прочтения")
                  : L2T("l2.burn.youOff", "Вы выключили самоуничтожение")
    }

    /// Обработка ленты: состояние режима, удаление прочитанных сообщений режима.
    func linia2ProcessBurn(_ all: [StoredMessage]) {
        guard let topic = topic else { return }
        var changed = false
        for m in all where m.seqId > 0 {
            if let on = Linia2Burn.toggleValue(m) {
                changed = Linia2Burn.record(topic: topic.name, seq: m.seqId, on: on) || changed
            }
        }
        if changed { linia2UpdateBurnUI() }
        guard Linia2Burn.featureOn else { return }
        for m in all where m.seqId > 0 && !m.isDeleted && Linia2Burn.isBurnMessage(m) {
            let mine = isFromCurrentSender(message: m)
            // Своё — когда собеседник прочитал; чужое — его показали на экране (мы отправили «прочитано»).
            let read = mine ? topic.msgReadCount(seq: m.seqId) > 0 : (view.window != nil && UIApplication.shared.applicationState == .active)
            if read {
                let after = Linia2Burn.deleteDelay + Linia2Burn.mediaSeconds(m) + (mine ? 2 : 0)
                Linia2Burn.scheduleDelete(topic: topic, seq: m.seqId, after: after) { [weak self] in
                    self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
                }
            }
        }
    }

    /// ⏱ в шапке: серый — выкл., красный — вкл.
    func linia2BurnBarButton() -> UIBarButtonItem? {
        guard Linia2Burn.featureOn, let t = topic, t.isP2PType, t.isWriter else { return nil }
        let on = Linia2Burn.isOn(t.name)
        let b = UIBarButtonItem(image: L2.symbol(on ? "timer.circle.fill" : "timer", 19, .regular), style: .plain,
                                target: self, action: #selector(linia2BurnTapped(_:)))
        b.tintColor = on ? L2.hex(0xFF5A5F) : nil
        b.accessibilityIdentifier = "l2.chat.burn"
        b.accessibilityLabel = on ? "Самоуничтожение включено" : "Самоуничтожение выключено"
        b.accessibilityValue = on ? "включено" : "выключено"
        return b
    }

    @objc func linia2BurnTapped(_ sender: UIBarButtonItem) {
        guard let t = topic else { return }
        let on = Linia2Burn.isOn(t.name)
        let alert: UIAlertController
        if on {
            alert = UIAlertController(title: L2T("l2.burn.offTitle", "Выключить самоуничтожение?"),
                                      message: L2T("l2.burn.offText", "Новые сообщения больше не будут удаляться после прочтения."),
                                      preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L2T("l2.burn.off", "Выключить"), style: .destructive) { [weak self] _ in self?.linia2SetBurn(false) })
        } else {
            alert = UIAlertController(title: L2T("l2.burn.title", "Самоуничтожение сообщений"),
                                      message: L2T("l2.burn.text", "Новые сообщения будут удаляться у обоих сразу после прочтения. Старые останутся. Собеседник может сделать скриншот."),
                                      preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L2T("l2.burn.enable", "Включить"), style: .destructive) { [weak self] _ in self?.linia2SetBurn(true) })
        }
        alert.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
        present(alert, animated: true)
    }

    func linia2SetBurn(_ on: Bool) {
        guard let t = topic else { return }
        let text = Linia2Burn.myName + (on ? L2T("l2.burn.enabledBy", " включил(а) самоуничтожение: новые сообщения удаляются после прочтения")
                                           : L2T("l2.burn.disabledBy", " выключил(а) самоуничтожение"))
        t.publish(content: Drafty(content: text), withExtraHeaders: [Linia2Burn.kModeHeader: .string(on ? "on" : "off")]).then(onSuccess: { [weak self] msg in
            DispatchQueue.main.async {
                if let seq = msg?.ctrl?.getIntParam(for: "seq") {
                    Linia2Burn.record(topic: t.name, seq: seq, on: on)
                }
                self?.linia2UpdateBurnUI()
                self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: true)
            }
            return nil
        }, onFailure: { err in
            DispatchQueue.main.async { UiUtils.showToast(message: L2T("l2.burn.failed", "Не удалось изменить режим самоуничтожения")) }
            return nil
        })
    }

    /// Значок в шапке и красная подпись у поля ввода.
    func linia2UpdateBurnUI() {
        if let t = topic {
            updateTitleBar(pub: t.pub, online: t.online, deleted: t.deleted)
        }
        let on = topic.map { Linia2Burn.isOn($0.name) } ?? false
        if on && linia2BurnLabel == nil {
            let l = PaddedLabelL2()
            l.text = "⏱ " + L2T("l2.burn.on", "Самоуничтожение включено")
            l.font = L2.font(13, .semibold)
            l.textColor = L2.hex(0xFF5A5F)
            l.backgroundColor = L2.background.withAlphaComponent(0.9)
            l.layer.cornerRadius = 11
            l.clipsToBounds = true
            l.textAlignment = .center
            l.accessibilityIdentifier = "l2.chat.burnLabel"
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
            let bottom = l.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(inputAccessoryView?.frame.height ?? 0) - 4)
            NSLayoutConstraint.activate([bottom, l.centerXAnchor.constraint(equalTo: view.centerXAnchor), l.heightAnchor.constraint(equalToConstant: 22)])
            linia2BurnLabel = l
            linia2BurnLabelBottom = bottom
        }
        linia2BurnLabel?.isHidden = !on
    }

    /// Скриншот в режиме — служебное сообщение собеседнику.
    @objc func linia2DidTakeScreenshot() {
        guard view.window != nil, let t = topic, Linia2Burn.isOn(t.name) else { return }
        if let last = linia2LastScreenshotNote, Date().timeIntervalSince(last) < 3 { return }
        linia2LastScreenshotNote = Date()
        let text = Linia2Burn.myName + L2T("l2.burn.screenshot", " сделал(а) снимок экрана")
        _ = t.publish(content: Drafty(content: text), withExtraHeaders: [Linia2Burn.kScreenshotHeader: .int(1)]).thenFinally { [weak self] in
            self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: true)
        }
    }
}
