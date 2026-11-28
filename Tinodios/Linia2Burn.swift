//
//  Linia2Burn.swift
//  Линия 2.0: исчезающие сообщения после прочтения («самоуничтожение», features.burnMode). Только личные чаты.
//
//  Формат (общий с вебом):
//  - включение/выключение — служебное сообщение, head {"linia2-burnmode": "on"|"off", "linia2-burn-scope": "both"|"mine",
//    "linia2-burn-secs": 20} (строки/числа ≠ 0: SDK веба выбрасывает ложные значения). Состояние — по всем переключателям
//    по порядку seq, для каждого участника отдельно: on+both от X → у обоих; on+mine от X → только у X; off от X → у X выкл.
//    и у собеседника, если его режим пришёл из «для обоих». Кэш — linia2.burn2.<topic> (CONTRACTS-next.md, раздел 2).
//    Текст: «<Имя> включил(а) исчезающие сообщения: 20 с после прочтения» / «<Имя> выключил(а) исчезающие сообщения».
//  - сообщения в режиме — head {"linia2-burn": <секунды>}. Через N секунд ПОСЛЕ ПРОЧТЕНИЯ (своё — по read собеседника,
//    чужое — показано на экране) на сообщении обратный отсчёт 0:20 → 0:00, затем оно плавно исчезает и удаляется
//    у обоих (hard delete; удаляют и отправитель, и получатель — кто первый). Старые сообщения не трогаются.
//    Начало отсчёта хранится на устройстве (linia2.burnat.<topic>:<seq>, мс); своё уточняется по /invite/api/receipts.
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

    static var defaultSecs: Int {
        let d = Int(min(86400, max(1, Linia2Config.shared.number("burnMode", "defaultSecs") ?? 20)))
        let o = options
        return o.contains(d) ? d : (o.contains(20) ? 20 : o[0])
    }
    static var options: [Int] {
        let raw = Linia2Config.shared.numbers("burnMode", "options")?.map { Int($0) }.filter { $0 >= 1 && $0 <= 86400 } ?? []
        return raw.isEmpty ? [10, 20, 30, 60, 300] : Array(raw.prefix(8))
    }

    /// «20 с», «1 мин», «1 мин 30 с» (как на вебе).
    static func secsText(_ s: Int) -> String {
        if s < 60 { return "\(s) с" }
        return s % 60 == 0 ? "\(s / 60) мин" : "\(s / 60) мин \(s % 60) с"
    }

    /// Режим одного участника: срок и откуда пришёл («both» — включён «для обоих», «mine» — «только мои»).
    struct Side: Codable, Equatable {
        var secs: Int
        var src: String
    }
    /// Состояние чата: у меня и у собеседника отдельно (CONTRACTS-next.md, раздел 2).
    struct State: Codable, Equatable {
        var me: Side?
        var peer: Side?
    }
    private struct Cached: Codable {
        var seq: Int
        var st: State
    }

    /// Переключатель из служебного сообщения.
    struct Toggle {
        var on: Bool
        var both: Bool
        var secs: Int
    }

    private static func key(_ topic: String) -> String { "linia2.burn2." + topic }

    private static func loadCached(_ topic: String) -> Cached? {
        guard let s = UserDefaults.standard.string(forKey: key(topic)), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Cached.self, from: d)
    }

    private static func saveCached(_ topic: String, _ c: Cached?) {
        guard let c = c, let d = try? JSONEncoder().encode(c), let s = String(data: d, encoding: .utf8) else {
            UserDefaults.standard.removeObject(forKey: key(topic))
            return
        }
        UserDefaults.standard.set(s, forKey: key(topic))
    }

    /// Текущее состояние (из кэша на устройстве; пересчитывается по ленте в linia2ProcessBurn).
    static func state(_ topic: String) -> State { loadCached(topic)?.st ?? State(me: nil, peer: nil) }

    /// Мои новые сообщения исчезают: секунды или nil.
    static func mySecs(_ topic: String) -> Int? {
        guard featureOn, Tinode.topicTypeByName(name: topic) == .p2p, let me = state(topic).me, me.secs > 0 else { return nil }
        return me.secs
    }

    /// Для значка ⏱ и подписи: режим действует на мои сообщения.
    static func isOn(_ topic: String) -> Bool { mySecs(topic) != nil }

    /// Применить переключатель участника (mine — мой) к состоянию.
    static func apply(_ t: Toggle, mine: Bool, to st: inout State) {
        if t.on {
            let v = Side(secs: t.secs, src: t.both ? "both" : "mine")
            if mine { st.me = v } else { st.peer = v }
            if t.both { if mine { st.peer = v } else { st.me = v } }
        } else if mine {
            st.me = nil
            if st.peer?.src == "both" { st.peer = nil }   // «для обоих» выключает любой
        } else {
            st.peer = nil
            if st.me?.src == "both" { st.me = nil }
        }
    }

    /// Пересчитать состояние по служебным сообщениям ленты (по порядку seq). true — изменилось.
    @discardableResult
    static func recompute(topic: String, toggles: [(seq: Int, toggle: Toggle, mine: Bool)], minSeq: Int?) -> Bool {
        let cached = loadCached(topic)
        let old = cached?.st ?? State(me: nil, peer: nil)
        let list = toggles.sorted { $0.seq < $1.seq }
        var st = State(me: nil, peer: nil)
        // Переключатели старше загруженной истории — из кэша.
        if let c = cached, list.isEmpty || c.seq < list[0].seq { st = c.st }
        for t in list { apply(t.toggle, mine: t.mine, to: &st) }
        if let last = list.last {
            saveCached(topic, Cached(seq: max(last.seq, cached?.seq ?? 0), st: st))
        } else if let c = cached, let lo = minSeq, c.seq >= lo {
            // Переключатель был в загруженном диапазоне, а его нет — удалён.
            saveCached(topic, nil)
            st = State(me: nil, peer: nil)
        }
        return st != old
    }

    /// Свой переключатель сразу после отправки (не дожидаясь ленты).
    static func recordOwn(topic: String, seq: Int, toggle: Toggle) {
        let cached = loadCached(topic)
        guard seq > (cached?.seq ?? -1) else { return }
        var st = cached?.st ?? State(me: nil, peer: nil)
        apply(toggle, mine: true, to: &st)
        saveCached(topic, Cached(seq: seq, st: st))
    }

    static func number(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let i)?: return i
        case .int64(let i)?: return Int(i)
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }

    private static func isReplace(_ m: Message) -> Bool { m.head?["replace"] != nil }

    /// Служебное сообщение «включил/выключил» → переключатель.
    static func toggle(_ m: Message) -> Toggle? {
        guard let v = m.head?[kModeHeader], !isReplace(m) else { return nil }
        var on = false
        switch v {
        case .string(let s): on = s == "on" || s == "1" || s == "true"
        case .bool(let b): on = b
        default: on = (number(v) ?? 0) == 1
        }
        var both = true
        if case .string(let s)? = m.head?[kScopeHeader] { both = s != "mine" }
        let secs = number(m.head?[kSecsHeader]).flatMap { $0 > 0 ? min(86400, $0) : nil } ?? 20
        return Toggle(on: on, both: both, secs: secs)
    }

    /// Сообщение отправлено в режиме: через сколько секунд после прочтения исчезает. Звонки не исчезают.
    static func burnSecs(_ m: Message) -> Int? {
        guard let head = m.head, head[kModeHeader] == nil, head["webrtc"] == nil, let n = number(head[kHeader]), n > 0 else { return nil }
        return min(86400, n)
    }

    static func isBurnMessage(_ m: Message) -> Bool { burnSecs(m) != nil }

    /// Заголовок для новых сообщений чата в режиме.
    static func extraHead(topic: String) -> [String: JSONValue]? {
        guard let s = mySecs(topic) else { return nil }
        return [kHeader: .int(s)]
    }

    static var myName: String {
        let fn = Cache.tinode.getMeTopic()?.pub?.fn ?? ""
        return fn.isEmpty ? L2T("l2.burn.someone", "Собеседник") : fn
    }

    // MARK: отсчёт

    static func k(_ topic: String, _ seq: Int) -> String { topic + ":" + String(seq) }
    private static func startKey(_ k: String) -> String { "linia2.burnat." + k }

    /// Скрыты сразу (не дожидаясь сервера); удаление на сервере уже отправлено; время прочтения уточняется.
    static var gone = Set<String>()
    static var sent = Set<String>()
    private static var asked = Set<String>()

    /// Начало отсчёта (момент прочтения), хранится на устройстве — перезапуск не сбрасывает.
    static func startAt(_ k: String) -> Date? {
        let ms = UserDefaults.standard.double(forKey: startKey(k))
        return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
    }

    /// Запомнить начало (раньше — можно, позже — нет).
    static func markStart(_ k: String, at: Date) {
        if let old = startAt(k), old <= at { return }
        UserDefaults.standard.set((at.timeIntervalSince1970 * 1000).rounded(), forKey: startKey(k))
    }

    static func clearStart(_ k: String) { UserDefaults.standard.removeObject(forKey: startKey(k)) }

    static func deadline(topic: String, seq: Int, secs: Int) -> Date? {
        startAt(k(topic, seq)).map { $0.addingTimeInterval(TimeInterval(secs)) }
    }

    /// «⏱0:20» — до прочтения полный срок, после — сколько осталось.
    static func stamp(topic: String, message m: Message) -> String? {
        guard let secs = burnSecs(m) else { return nil }
        var left = secs
        if let dl = deadline(topic: topic, seq: m.seqId, secs: secs) { left = max(0, Int(ceil(dl.timeIntervalSinceNow))) }
        return String(format: "⏱%d:%02d", left / 60, left % 60)
    }

    /// Своё сообщение: уточнить время прочтения по журналу сервера (GET /invite/api/receipts) — берётся более раннее.
    static func refineReadTime(topic: String, seq: Int) {
        let key = k(topic, seq)
        guard !asked.contains(key) else { return }
        asked.insert(key)
        Linia2Receipt.fetch(topic: topic, seq: seq) { r, _ in
            let me = Cache.tinode.myUid
            let t = r?.members.filter { $0.uid != me }.compactMap { $0.read }.min()
            if let t = t { markStart(key, at: t) } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { _ = asked.remove(key) }   // журнал пишется не мгновенно
            }
        }
    }

    /// Удалить у всех (hard); шлют оба, кто первый. 404 — уже удалено; 403 — удалить у себя.
    /// Скрывается у себя (gone) только после ответа сервера: исчезло на экране — значит, у собеседника уже удалено
    /// (раньше пузырь гас до отправки {del}, и собеседник ещё видел сообщение на сервере).
    static func burn(topic: DefaultComTopic, seq: Int, done: @escaping () -> Void) {
        let key = k(topic.name, seq)
        guard !sent.contains(key) else { return }
        sent.insert(key)
        topic.delMessages(ids: [seq], hard: true).then(onSuccess: { _ in
            DispatchQueue.main.async { gone.insert(key); clearStart(key); done() }
            return nil
        }, onFailure: { err in
            var code = 0
            if case TinodeError.serverResponseError(let c, _, _)? = err as? TinodeError { code = c }
            Cache.log.error("Linia2Burn: не удалось удалить %d (%d): %@", seq, code, err.localizedDescription)
            if code == 403 { _ = topic.delMessages(ids: [seq], hard: false) }
            DispatchQueue.main.async {
                gone.insert(key)   // у себя скрыть в любом случае; при ошибке сети — повтор из таймера
                if code == 403 || code == 404 { clearStart(key) } else { sent.remove(key) }   // иначе — повтор позже
                if code == 403 { UiUtils.showToast(message: L2T("l2.del.noPeer", "Удалить у собеседника нельзя"), level: .info) }
                done()
            }
            return nil
        })
    }
}

extension MessageViewController {
    /// Системная строка по центру (не пузырь): исчезающие сообщения, скриншот, автоудаление.
    func linia2IsServiceMessage(_ m: Message) -> Bool {
        guard let head = m.head, head["replace"] == nil else { return false }
        return head[Linia2Burn.kModeHeader] != nil || head[Linia2Burn.kScreenshotHeader] != nil || head[Linia2Burn.kAutoDeleteHeader] != nil
    }

    /// Текст системной строки — по head (как на вебе): «Вы включили …» / «<Имя> включил(а) …».
    func linia2ServiceText(_ m: Message) -> String? {
        let mine = isFromCurrentSender(message: m)
        let peerName: String = {
            let fn = self.topic?.pub?.fn ?? ""
            return fn.isEmpty ? L2T("l2.burn.someone", "Собеседник") : fn
        }()
        if let t = Linia2Burn.toggle(m) {
            let who: String = mine ? L2T("l2.burn.you", "Вы") : peerName
            let verb: String
            if t.on {
                verb = mine ? L2T("l2.burn.onMine", " включили") : L2T("l2.burn.onPeer", " включил(а)")
            } else {
                verb = mine ? L2T("l2.burn.offMine", " выключили") : L2T("l2.burn.offPeer", " выключил(а)")
            }
            var text: String = who + verb + L2T("l2.burn.what", " исчезающие сообщения")
            if t.on {
                if !t.both { text += L2T("l2.burn.mineSuffix", " (только свои)") }
                text += ": " + Linia2Burn.secsText(t.secs) + L2T("l2.burn.afterRead", " после прочтения")
            }
            return text
        }
        if let v = m.head?[Linia2Burn.kAutoDeleteHeader], m.head?["replace"] == nil {
            let secs = Linia2Burn.number(v) ?? 0   // "off", 0 и всё, что не число > 0, — выкл.
            let who: String = mine ? "Вы" : peerName
            if secs > 0 {
                let verb: String = mine ? " включили" : " включил(а)"
                return "⏱ " + who + verb + " автоудаление: " + Linia2Disappearing.label(secs)
            }
            let verb: String = mine ? " выключили" : " выключил(а)"
            return "⏱ " + who + verb + " автоудаление"
        }
        return nil
    }

    /// Обработка ленты: режим чата, автоудаление, отсчёт и удаление прочитанных. Возвращает ленту без исчезнувших.
    @discardableResult
    func linia2ProcessBurn(_ all: [StoredMessage]) -> [StoredMessage] {
        guard let topic = topic, topic.isP2PType || topic.isGrpType else { return all }
        let loaded = all.filter { $0.seqId > 0 }
        // 1. Состояние исчезающих сообщений — по всем переключателям, для каждого участника отдельно.
        if topic.isP2PType {
            let toggles = loaded.compactMap { m -> (seq: Int, toggle: Linia2Burn.Toggle, mine: Bool)? in
                guard let t = Linia2Burn.toggle(m) else { return nil }
                return (seq: m.seqId, toggle: t, mine: isFromCurrentSender(message: m))
            }
            if Linia2Burn.recompute(topic: topic.name, toggles: toggles, minSeq: loaded.map { $0.seqId }.min()) {
                linia2UpdateBurnUI()
            }
        }
        // 2. Автоудаление чата (служебное сообщение linia2-autodelete от веба или iOS): действует последнее по seq.
        if let last = loaded.filter({ $0.head?[Linia2Burn.kAutoDeleteHeader] != nil && $0.head?["replace"] == nil }).max(by: { $0.seqId < $1.seqId }) {
            Linia2Disappearing.record(topic: topic.name, seq: last.seqId, secs: Linia2Burn.number(last.head?[Linia2Burn.kAutoDeleteHeader]) ?? 0)
        }
        guard topic.isP2PType else { return all }
        // 3. Отсчёт с момента прочтения.
        let visibleNow = view.window != nil && UIApplication.shared.applicationState == .active
        var pending = false
        for m in loaded where !m.isDeleted {
            guard Linia2Burn.burnSecs(m) != nil else { continue }
            let key = Linia2Burn.k(topic.name, m.seqId)
            if Linia2Burn.sent.contains(key) { continue }
            pending = true
            if Linia2Burn.gone.contains(key) { continue }
            let mine = isFromCurrentSender(message: m)
            // Своё — когда собеседник прочитал; чужое — его показали на экране (мы отправили «прочитано»).
            let read = mine ? topic.msgReadCount(seq: m.seqId) > 0 : (visibleNow || Linia2Burn.startAt(key) != nil)
            guard read else { continue }
            Linia2Burn.markStart(key, at: Date())
            if mine { Linia2Burn.refineReadTime(topic: topic.name, seq: m.seqId) }
        }
        if pending && linia2BurnTimer == nil {
            linia2BurnTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                self.linia2BurnTick()
            }
        }
        return all.filter { !Linia2Burn.gone.contains(Linia2Burn.k(topic.name, $0.seqId)) }
    }

    /// Раз в 0,5 с: отсчёт «⏱0:20 → 0:00» на видимых сообщениях; на нуле — плавно скрыть (≈0,45 с) и удалить у всех.
    private func linia2BurnTick() {
        guard let topic = topic, let cv = collectionView else { return }
        var pending = false
        for m in messages where m.seqId > 0 && !m.isDeleted {
            guard let secs = Linia2Burn.burnSecs(m) else { continue }
            let key = Linia2Burn.k(topic.name, m.seqId)
            if Linia2Burn.sent.contains(key) { continue }
            pending = true
            let seq = m.seqId
            let finish = { [weak self] in
                Linia2Burn.burn(topic: topic, seq: seq) { self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false) }
            }
            if Linia2Burn.gone.contains(key) {   // уже скрыто (идёт исчезновение или повтор после ошибки сети)
                if !linia2BurnFading.contains(key) { finish() }
                continue
            }
            let cell = messageSeqIdIndex[m.seqId].flatMap { cv.cellForItem(at: IndexPath(item: $0, section: 0)) as? MessageCell }
            if Linia2Burn.startAt(key) == nil, isFromCurrentSender(message: m), topic.msgReadCount(seq: m.seqId) > 0 {
                Linia2Burn.markStart(key, at: Date())   // «прочитано» пришло без перерисовки ленты
                Linia2Burn.refineReadTime(topic: topic.name, seq: m.seqId)
            }
            guard let dl = Linia2Burn.deadline(topic: topic.name, seq: m.seqId, secs: secs) else { continue }
            let left = Int(ceil(dl.timeIntervalSinceNow))
            if left > 0 {
                if let cell = cell, let text = Linia2Burn.stamp(topic: topic.name, message: m), cell.timestampLabel.text != text {
                    cell.timestampLabel.text = text
                    cell.timestampLabel.isAccessibilityElement = true
                    cell.timestampLabel.accessibilityIdentifier = "l2.burn.timer.\(m.seqId)"
                    cell.timestampLabel.accessibilityLabel = text
                    cell.timestampLabel.accessibilityValue = "исчезнет через \(left) с"
                    linia2LayoutMetaPill(cell: cell, message: m)
                }
                continue
            }
            if let cell = cell {
                // Сначала {del hard} на сервер, гасить — по ответу: пока пузырь виден, у собеседника он ещё может быть.
                linia2BurnFading.insert(key)
                cell.isUserInteractionEnabled = false
                Linia2Burn.burn(topic: topic, seq: seq) { [weak self] in
                    guard let self = self else { return }
                    let reload = { [weak self] in
                        self?.linia2BurnFading.remove(key)
                        self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
                    }
                    // Ячейка могла переиспользоваться под другое сообщение — гасим только свою.
                    guard let i = self.messageSeqIdIndex[seq],
                          let c = self.collectionView?.cellForItem(at: IndexPath(item: i, section: 0)) as? MessageCell,
                          c === cell, c.seqId == seq else {
                        cell.isUserInteractionEnabled = true
                        reload()
                        return
                    }
                    UIView.animate(withDuration: 0.45, animations: {
                        c.contentView.alpha = 0
                        c.contentView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
                    }, completion: { _ in
                        c.contentView.alpha = 1
                        c.contentView.transform = .identity
                        c.isUserInteractionEnabled = true
                        reload()
                    })
                }
            } else {
                finish()
            }
        }
        if !pending {
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

    @objc func linia2BurnTapped(_ sender: Any?) {
        guard let t = topic else { return }
        if let me = Linia2Burn.state(t.name).me, Linia2Burn.isOn(t.name) {
            let alert = UIAlertController(title: L2T("l2.burn.offTitle", "Выключить исчезающие сообщения?"),
                                          message: me.src == "both"
                                            ? L2T("l2.burn.offTextBoth", "Новые сообщения обоих больше не будут исчезать после прочтения. Уже отправленные исчезнут, как было задано.")
                                            : L2T("l2.burn.offTextMine", "Ваши новые сообщения больше не будут исчезать после прочтения."),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
            alert.addAction(UIAlertAction(title: L2T("l2.burn.off", "Выключить"), style: .destructive) { [weak self] _ in
                self?.linia2SetBurn(Linia2Burn.Toggle(on: false, both: true, secs: Linia2Burn.defaultSecs))
            })
            alert.view.accessibilityIdentifier = "l2.burn.offAlert"
            present(alert, animated: true)
            return
        }
        // Включение: для кого («Для обоих» — по умолчанию), затем срок после прочтения.
        let alert = UIAlertController(title: L2T("l2.burn.title", "Исчезающие сообщения"),
                                      message: L2T("l2.burn.text", "Новые сообщения будут исчезать у обоих через выбранное время после прочтения. Старые останутся. Собеседник может сделать скриншот."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L2T("l2.burn.both", "Для обоих"), style: .default) { [weak self] _ in self?.linia2ChooseBurnSecs(both: true) })
        alert.addAction(UIAlertAction(title: L2T("l2.burn.mine", "Только мои сообщения"), style: .default) { [weak self] _ in self?.linia2ChooseBurnSecs(both: false) })
        alert.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
        alert.preferredAction = alert.actions.first
        alert.view.accessibilityIdentifier = "l2.burn.alert"
        present(alert, animated: true)
    }

    private func linia2ChooseBurnSecs(both: Bool) {
        let sheet = UIAlertController(title: L2T("l2.burn.secsTitle", "Исчезать после прочтения через"), message: nil, preferredStyle: .actionSheet)
        let def = Linia2Burn.defaultSecs
        for s in Linia2Burn.options {
            let a = UIAlertAction(title: Linia2Burn.secsText(s) + (s == def ? " ✓" : ""), style: .default) { [weak self] _ in
                self?.linia2SetBurn(Linia2Burn.Toggle(on: true, both: both, secs: s))
            }
            sheet.addAction(a)
            if s == def { sheet.preferredAction = a }
        }
        sheet.addAction(UIAlertAction(title: L2T("l2.cancel", "Отмена"), style: .cancel))
        if let p = sheet.popoverPresentationController { p.sourceView = view; p.sourceRect = CGRect(x: view.bounds.midX, y: 80, width: 1, height: 1) }
        present(sheet, animated: true)
    }

    /// Переключатель — служебное сообщение (без linia2-burn и linia2-ttl): {"linia2-burnmode": "on"|"off", scope, secs}.
    func linia2SetBurn(_ toggle: Linia2Burn.Toggle) {
        guard let t = topic else { return }
        var head: [String: JSONValue] = [Linia2Burn.kModeHeader: .string(toggle.on ? "on" : "off")]
        var text: String = Linia2Burn.myName
        if toggle.on {
            head[Linia2Burn.kScopeHeader] = .string(toggle.both ? "both" : "mine")
            head[Linia2Burn.kSecsHeader] = .int(toggle.secs)
            text += L2T("l2.burn.onPeer", " включил(а)") + L2T("l2.burn.what", " исчезающие сообщения")
            if !toggle.both { text += L2T("l2.burn.mineSuffix", " (только свои)") }
            text += ": " + Linia2Burn.secsText(toggle.secs) + L2T("l2.burn.afterRead", " после прочтения")
        } else {
            text += L2T("l2.burn.offPeer", " выключил(а)") + L2T("l2.burn.what", " исчезающие сообщения")
        }
        t.publish(content: Drafty(content: text), withExtraHeaders: head).then(onSuccess: { [weak self] msg in
            DispatchQueue.main.async {
                if let seq = msg?.ctrl?.getIntParam(for: "seq") {
                    Linia2Burn.recordOwn(topic: t.name, seq: seq, toggle: toggle)
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
            let bottom = l.bottomAnchor.constraint(equalTo: linia2InputDock.topAnchor, constant: -4)
            NSLayoutConstraint.activate([bottom, l.centerXAnchor.constraint(equalTo: view.centerXAnchor), l.heightAnchor.constraint(equalToConstant: 22)])
            linia2BurnLabel = l
            linia2BurnLabelBottom = bottom
        }
        if let s = secs {
            linia2BurnLabel?.text = "⏱ " + L2T("l2.burn.on", "Исчезающие сообщения: {secs} после прочтения")
                .replacingOccurrences(of: "{secs}", with: Linia2Burn.secsText(s))
        }
        linia2BurnLabel?.isHidden = secs == nil
    }

    /// Скриншот в режиме — служебное сообщение собеседнику.
    @objc func linia2DidTakeScreenshot() {
        guard view.window != nil, let t = topic, t.isP2PType else { return }
        let st = Linia2Burn.state(t.name)
        guard Linia2Burn.featureOn, st.me != nil || st.peer != nil else { return }
        if let last = linia2LastScreenshotNote, Date().timeIntervalSince(last) < 3 { return }
        linia2LastScreenshotNote = Date()
        let text = Linia2Burn.myName + L2T("l2.burn.screenshot", " сделал(а) снимок экрана")
        _ = t.publish(content: Drafty(content: text), withExtraHeaders: [Linia2Burn.kScreenshotHeader: .int(1)]).thenFinally { [weak self] in
            self?.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: true)
        }
    }
}
