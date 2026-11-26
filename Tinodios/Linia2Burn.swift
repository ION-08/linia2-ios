//
//  Linia2Burn.swift
//  Линия 2.0: исчезающие сообщения после прочтения («самоуничтожение», features.burnMode). Только личные чаты.
//
//  Формат (общий с вебом):
//  - включение/выключение — служебное сообщение, head {"linia2-burnmode": "on"|"off", "linia2-burn-scope": "both"|"mine",
//    "linia2-burn-secs": 20} (строки/числа ≠ 0: SDK веба выбрасывает ложные значения). Действует ПОСЛЕДНЕЕ по seq.
//    «Для обоих» — исчезают сообщения обоих; «Только мои» — только сообщения включившего.
//    Текст: «<Имя> включил(а) исчезающие сообщения: 20 с после прочтения» / «<Имя> выключил(а) исчезающие сообщения».
//  - сообщения в режиме — head {"linia2-burn": <секунды>}. Через N секунд ПОСЛЕ ПРОЧТЕНИЯ (своё — по read собеседника,
//    чужое — показано на экране) на сообщении обратный отсчёт 0:20 → 0:00, затем оно плавно исчезает и удаляется
//    у обоих (hard delete; удаляют и отправитель, и получатель — кто первый). Старые сообщения не трогаются.
//  - скриншот в режиме → служебное сообщение head {"linia2-screenshot": 1}, «<имя> сделал(а) снимок экрана».
//  Удалённые настройки: features.burnMode, burnMode.defaultSecs (20), burnMode.options ([10, 20, 30, 60, 300]).
//

import UIKit
import TinodeSDK
import TinodiosDB

enum Linia2Burn {
    static let kHeader = "linia2-burn"
    static let kModeHeader = "linia2-burnmode"
    static let kScopeHeader = "linia2-burn-scope"
    static let kSecsHeader = "linia2-burn-secs"
    static let kScreenshotHeader = "linia2-screenshot"
    static let kAutoDeleteHeader = "linia2-autodelete"

    static var featureOn: Bool { Linia2Config.shared.feature("burnMode") }

    static var defaultSecs: Int { Int(min(3600, max(3, Linia2Config.shared.number("burnMode", "defaultSecs") ?? 20))) }
    static var options: [Int] {
        let raw = Linia2Config.shared.numbers("burnMode", "options")?.map { Int($0) }.filter { $0 >= 3 && $0 <= 3600 } ?? []
        return raw.isEmpty ? [10, 20, 30, 60, 300] : Array(raw.prefix(8))
    }

    /// «20 с», «1 мин», «5 мин».
    static func secsText(_ s: Int) -> String {
        s < 60 || s % 60 != 0 ? "\(s) с" : "\(s / 60) мин"
    }

    struct Mode {
        var on: Bool
        var both: Bool
        var secs: Int
        var from: String
    }

    private static func key(_ topic: String) -> String { "linia2.burn." + topic }

    /// Текущий режим чата (по последнему служебному сообщению, сохранённому на устройстве).
    static func mode(_ topic: String) -> Mode? {
        guard featureOn, let d = UserDefaults.standard.dictionary(forKey: key(topic)), (d["on"] as? Bool) == true else { return nil }
        return Mode(on: true, both: (d["scope"] as? String ?? "both") != "mine", secs: d["secs"] as? Int ?? defaultSecs, from: d["from"] as? String ?? "")
    }

    /// Мои новые сообщения исчезают: секунды или nil.
    static func mySecs(_ topic: String) -> Int? {
        guard let m = mode(topic) else { return nil }
        return m.both || Cache.tinode.isMe(uid: m.from) ? m.secs : nil
    }

    /// Для значка ⏱: режим действует на меня (для обоих или я включил «только мои»).
    static func isOn(_ topic: String) -> Bool { mySecs(topic) != nil }

    /// Запомнить режим из служебного сообщения seq (старые не перетирают новые). true — изменилось.
    @discardableResult
    static func record(topic: String, seq: Int, mode m: Mode) -> Bool {
        let d = UserDefaults.standard.dictionary(forKey: key(topic))
        let oldSeq = d?["seq"] as? Int ?? -1
        guard seq > oldSeq else { return false }
        let new: [String: Any] = ["seq": seq, "on": m.on, "scope": m.both ? "both" : "mine", "secs": m.secs, "from": m.from]
        UserDefaults.standard.set(new, forKey: key(topic))
        return (d?["on"] as? Bool ?? false) != m.on || (d?["scope"] as? String) != (new["scope"] as? String)
            || (d?["secs"] as? Int) != m.secs || (d?["from"] as? String) != m.from
    }

    private static func number(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let i)?: return i
        case .int64(let i)?: return Int(i)
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }

    /// Служебное сообщение «включил/выключил» → режим.
    static func toggle(_ m: Message) -> Mode? {
        guard let v = m.head?[kModeHeader] else { return nil }
        var on = false
        switch v {
        case .string(let s): on = s == "on" || s == "1" || s == "true"
        case .bool(let b): on = b
        default: on = (number(v) ?? 0) != 0
        }
        var both = true
        if case .string(let s)? = m.head?[kScopeHeader] { both = s != "mine" }
        let secs = number(m.head?[kSecsHeader]).map { min(3600, max(3, $0)) } ?? defaultSecs
        return Mode(on: on, both: both, secs: secs, from: m.from ?? "")
    }

    /// Сообщение отправлено в режиме: через сколько секунд после прочтения исчезает.
    static func burnSecs(_ m: Message) -> Int? {
        guard let n = number(m.head?[kHeader]), n > 0 else { return nil }
        return n == 1 ? defaultSecs : min(3600, max(3, n))   // 1 — старый формат-флаг
    }

    static func isBurnMessage(_ m: Message) -> Bool { burnSecs(m) != nil }

    /// Заголовок для новых сообщений чата в режиме.
    static func extraHead(topic: String) -> [String: JSONValue]? {
        guard Tinode.topicTypeByName(name: topic) == .p2p, let s = mySecs(topic) else { return nil }
        return [kHeader: .int(s)]
    }

    static var myName: String {
        let fn = Cache.tinode.getMeTopic()?.pub?.fn ?? ""
        return fn.isEmpty ? L2T("l2.burn.someone", "Собеседник") : fn
    }

    /// Когда исчезает (topic:seq → время); уже исчезнувшие (скрыты сразу, не дожидаясь сервера).
    static var deadlines: [String: Date] = [:]
    static var gone = Set<String>()
    private static var scheduled = Set<String>()

    static func k(_ topic: String, _ seq: Int) -> String { topic + ":" + String(seq) }

    /// Начать отсчёт (один раз) и запланировать удаление у всех.
    static func startCountdown(topic: DefaultComTopic, seq: Int, secs: Int, extra: TimeInterval, done: @escaping () -> Void) {
        let key = k(topic.name, seq)
        if deadlines[key] == nil { deadlines[key] = Date().addingTimeInterval(TimeInterval(secs)) }
        guard seq > 0, !scheduled.contains(key), let dl = deadlines[key] else { return }
        scheduled.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dl.timeIntervalSinceNow) + extra) {
            gone.insert(key)
            topic.delMessages(ids: [seq], hard: true).then(onSuccess: { _ in
                DispatchQueue.main.async { done() }
                return nil
            }, onFailure: { err in
                Cache.log.error("Linia2Burn: не удалось удалить %d: %@", seq, err.localizedDescription)
                // Удалить у собеседника нельзя (нет права D) — хотя бы у себя; уже удалено (404) — молча.
                var code = 0
                if case TinodeError.serverResponseError(let c, _, _)? = err as? TinodeError { code = c }
                if code != 404 { _ = topic.delMessages(ids: [seq], hard: false) }
                DispatchQueue.main.async {
                    if code == 403 { UiUtils.showToast(message: L2T("l2.del.noPeer", "Удалить у собеседника нельзя"), level: .info) }
                    done()
                }
                return nil
            })
        }
    }
}

extension MessageViewController {
    /// Системная строка по центру (не пузырь): исчезающие сообщения, скриншот, автоудаление.
    func linia2IsServiceMessage(_ m: Message) -> Bool {
        guard let head = m.head else { return false }
        return head[Linia2Burn.kModeHeader] != nil || head[Linia2Burn.kScreenshotHeader] != nil || head[Linia2Burn.kAutoDeleteHeader] != nil
    }

    /// Текст системной строки: свои переключатели — «Вы включили …».
    func linia2ServiceText(_ m: Message) -> String? {
        guard let mode = Linia2Burn.toggle(m), isFromCurrentSender(message: m) else { return nil }
        if !mode.on { return L2T("l2.burn.youOff", "Вы выключили исчезающие сообщения") }
        return L2T("l2.burn.youOn", "Вы включили исчезающие сообщения") + (mode.both ? "" : L2T("l2.burn.mineSuffix", " (только ваши)"))
            + ": " + Linia2Burn.secsText(mode.secs) + " после прочтения"
    }

    /// Обработка ленты: режим чата, отсчёт и удаление прочитанных. Возвращает ленту без исчезнувших.
    @discardableResult
    func linia2ProcessBurn(_ all: [StoredMessage]) -> [StoredMessage] {
        guard let topic = topic else { return all }
        var changed = false
        for m in all where m.seqId > 0 {
            if let mode = Linia2Burn.toggle(m) {
                changed = Linia2Burn.record(topic: topic.name, seq: m.seqId, mode: mode) || changed
            }
        }
        if changed { linia2UpdateBurnUI() }
        let visibleNow = view.window != nil && UIApplication.shared.applicationState == .active
        var started = false
        for m in all where m.seqId > 0 && !m.isDeleted {
            guard let secs = Linia2Burn.burnSecs(m) else { continue }
            let mine = isFromCurrentSender(message: m)
            // Своё — когда собеседник прочитал; чужое — его показали на экране (мы отправили «прочитано»).
            let read = mine ? topic.msgReadCount(seq: m.seqId) > 0 : visibleNow
            if read {
                started = true
                Linia2Burn.startCountdown(topic: topic, seq: m.seqId, secs: secs, extra: mine ? 2 : 0) { [weak self] in
                    self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
                }
            }
        }
        if started && linia2BurnTimer == nil {
            linia2BurnTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                self.linia2BurnTick()
            }
        }
        return all.filter { !Linia2Burn.gone.contains(Linia2Burn.k(topic.name, $0.seqId)) }
    }

    /// Отсчёт «0:20 → 0:00» на видимых сообщениях; на нуле — плавно исчезает.
    private func linia2BurnTick() {
        guard let topic = topic, let cv = collectionView else { return }
        var pending = false
        for cell in cv.visibleCells.compactMap({ $0 as? MessageCell }) where cell.seqId > 0 {
            let key = Linia2Burn.k(topic.name, cell.seqId)
            guard let dl = Linia2Burn.deadlines[key] else { continue }
            let left = Int(ceil(dl.timeIntervalSinceNow))
            if left > 0 {
                pending = true
                cell.timestampLabel.text = String(format: "⏱%d:%02d", left / 60, left % 60)
                cell.timestampLabel.accessibilityLabel = "исчезнет через \(left) с"
                if let i = messageSeqIdIndex[cell.seqId] { linia2LayoutMetaPill(cell: cell, message: messages[i]) }
            } else if cell.contentView.alpha > 0.99 {
                Linia2Burn.gone.insert(key)
                UIView.animate(withDuration: 0.6, animations: { cell.contentView.alpha = 0 }) { [weak self] _ in
                    cell.contentView.alpha = 1
                    self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
                }
            }
        }
        let now = Date()
        if !pending && !Linia2Burn.deadlines.contains(where: { $0.key.hasPrefix(topic.name + ":") && $0.value > now }) {
            linia2BurnTimer?.invalidate()
            linia2BurnTimer = nil
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
        b.accessibilityLabel = on ? "Исчезающие сообщения включены" : "Исчезающие сообщения выключены"
        b.accessibilityValue = on ? "включено" : "выключено"
        return b
    }

    @objc func linia2BurnTapped(_ sender: UIBarButtonItem) {
        guard let t = topic else { return }
        if Linia2Burn.mode(t.name) != nil {
            let alert = UIAlertController(title: L2T("l2.burn.offTitle", "Выключить исчезающие сообщения?"),
                                          message: L2T("l2.burn.offText", "Новые сообщения будут сохраняться."),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
            alert.addAction(UIAlertAction(title: L2T("l2.burn.off", "Выключить"), style: .destructive) { [weak self] _ in
                self?.linia2SetBurn(Linia2Burn.Mode(on: false, both: true, secs: Linia2Burn.defaultSecs, from: ""))
            })
            present(alert, animated: true)
            return
        }
        // Включение: для кого, затем срок после прочтения.
        let alert = UIAlertController(title: L2T("l2.burn.title", "Исчезающие сообщения"),
                                      message: L2T("l2.burn.text", "Новые сообщения будут исчезать у обоих через выбранное время после прочтения. Старые останутся. Собеседник может сделать скриншот."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L2T("l2.burn.both", "Для обоих"), style: .default) { [weak self] _ in self?.linia2ChooseBurnSecs(both: true) })
        alert.addAction(UIAlertAction(title: L2T("l2.burn.mine", "Только мои сообщения"), style: .default) { [weak self] _ in self?.linia2ChooseBurnSecs(both: false) })
        alert.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
        alert.preferredAction = alert.actions.first
        present(alert, animated: true)
    }

    private func linia2ChooseBurnSecs(both: Bool) {
        let sheet = UIAlertController(title: L2T("l2.burn.secsTitle", "Исчезать после прочтения через"), message: nil, preferredStyle: .actionSheet)
        let def = Linia2Burn.defaultSecs
        for s in Linia2Burn.options {
            sheet.addAction(UIAlertAction(title: Linia2Burn.secsText(s) + (s == def ? " ✓" : ""), style: .default) { [weak self] _ in
                self?.linia2SetBurn(Linia2Burn.Mode(on: true, both: both, secs: s, from: Cache.tinode.myUid ?? ""))
            })
        }
        sheet.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
        if let p = sheet.popoverPresentationController { p.sourceView = view; p.sourceRect = CGRect(x: view.bounds.midX, y: 80, width: 1, height: 1) }
        present(sheet, animated: true)
    }

    func linia2SetBurn(_ mode: Linia2Burn.Mode) {
        guard let t = topic else { return }
        var head: [String: JSONValue] = [Linia2Burn.kModeHeader: .string(mode.on ? "on" : "off")]
        let text: String
        if mode.on {
            head[Linia2Burn.kScopeHeader] = .string(mode.both ? "both" : "mine")
            head[Linia2Burn.kSecsHeader] = .int(mode.secs)
            text = Linia2Burn.myName + L2T("l2.burn.enabledBy", " включил(а) исчезающие сообщения")
                + (mode.both ? "" : L2T("l2.burn.enabledMine", " для своих сообщений")) + ": " + Linia2Burn.secsText(mode.secs) + " после прочтения"
        } else {
            text = Linia2Burn.myName + L2T("l2.burn.disabledBy", " выключил(а) исчезающие сообщения")
        }
        t.publish(content: Drafty(content: text), withExtraHeaders: head).then(onSuccess: { [weak self] msg in
            DispatchQueue.main.async {
                if let seq = msg?.ctrl?.getIntParam(for: "seq") {
                    var m = mode
                    m.from = Cache.tinode.myUid ?? ""
                    Linia2Burn.record(topic: t.name, seq: seq, mode: m)
                }
                self?.linia2UpdateBurnUI()
                self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: true)
            }
            return nil
        }, onFailure: { _ in
            DispatchQueue.main.async { UiUtils.showToast(message: L2T("l2.burn.failed", "Не удалось изменить режим исчезающих сообщений")) }
            return nil
        })
    }

    /// Значок в шапке и красная подпись у поля ввода.
    func linia2UpdateBurnUI() {
        if let t = topic {
            updateTitleBar(pub: t.pub, online: t.online, deleted: t.deleted)
        }
        let secs = topic.flatMap { Linia2Burn.mySecs($0.name) }
        if secs != nil && linia2BurnLabel == nil {
            let l = PaddedLabelL2()
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
        if let s = secs {
            linia2BurnLabel?.text = "⏱ " + L2T("l2.burn.label", "Исчезающие сообщения") + ": " + Linia2Burn.secsText(s) + " после прочтения"
        }
        linia2BurnLabel?.isHidden = secs == nil
    }

    /// Скриншот в режиме — служебное сообщение собеседнику.
    @objc func linia2DidTakeScreenshot() {
        guard view.window != nil, let t = topic, Linia2Burn.mode(t.name) != nil else { return }
        if let last = linia2LastScreenshotNote, Date().timeIntervalSince(last) < 3 { return }
        linia2LastScreenshotNote = Date()
        let text = Linia2Burn.myName + L2T("l2.burn.screenshot", " сделал(а) снимок экрана")
        _ = t.publish(content: Drafty(content: text), withExtraHeaders: [Linia2Burn.kScreenshotHeader: .int(1)]).thenFinally { [weak self] in
            self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: true)
        }
    }
}
