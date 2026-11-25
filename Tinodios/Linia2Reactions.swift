//
//  Linia2Reactions.swift
//  Линия 2.0: реакции на сообщения (в Tinode их нет — делаем своим протоколом).
//
//  Реакция = обычное сообщение с текстом-эмодзи и заголовками:
//    "reply": "<seq сообщения>", "linia2-react": "<эмодзи>".
//  Приложение «Линия 2.0» скрывает такие сообщения из ленты и показывает «пилюлю» (❤️ 2) под пузырём.
//  Снять свою реакцию — удалить своё сообщение-реакцию. Другие клиенты Tinode увидят реакцию как ответ-эмодзи.
//

import UIKit
import TinodeSDK
import TinodiosDB

extension MessageViewController {
    static let kL2ReactHeader = "linia2-react"
    static let kL2QuickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    private static let kL2ChipTag = 0x4C52

    /// Убирает сообщения-реакции из ленты и пересчитывает таблицу реакций.
    func linia2ExtractReactions(_ all: [StoredMessage]) -> [StoredMessage] {
        var map: [Int: [String: [String]]] = [:]
        var mine: [Int: [String: Int]] = [:]
        var visible: [StoredMessage] = []
        visible.reserveCapacity(all.count)
        for m in all {
            if let head = m.head, case .string(let emoji)? = head[Self.kL2ReactHeader],
               case .string(let target)? = head["reply"], let seq = Int(target) {
                if m.isDeleted || emoji.isEmpty { continue }
                let from = m.from ?? ""
                if !(map[seq]?[emoji]?.contains(from) ?? false) {
                    map[seq, default: [:]][emoji, default: []].append(from)
                }
                if Cache.tinode.isMe(uid: from) && m.seqId > 0 {
                    mine[seq, default: [:]][emoji] = m.seqId
                }
                continue
            }
            visible.append(m)
        }
        let changed = map != linia2Reactions
        linia2Reactions = map
        linia2MyReactions = mine
        if changed {
            DispatchQueue.main.async { [weak self] in
                self?.collectionView?.collectionViewLayout.invalidateLayout()
                self?.collectionView?.reloadData()
            }
        }
        return visible
    }

    /// Дополнительный отступ под сообщением с реакциями.
    func linia2ReactionSpacing(for seq: Int) -> CGFloat {
        (linia2Reactions[seq]?.isEmpty ?? true) ? 0 : 24
    }

    /// Рисует «пилюлю» с реакциями у нижнего края пузыря.
    func linia2RenderReactions(cell: MessageCell, message: Message) {
        cell.contentView.viewWithTag(Self.kL2ChipTag)?.removeFromSuperview()
        guard !message.isDeleted, let r = linia2Reactions[message.seqId], !r.isEmpty else { return }
        cell.clipsToBounds = false
        cell.contentView.clipsToBounds = false

        let mineSet = Set(linia2MyReactions[message.seqId]?.keys.map { $0 } ?? [])
        let parts = r.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .prefix(4)
            .map { $0.value.count > 1 ? "\($0.key) \($0.value.count)" : $0.key }
        let label = UILabel()
        label.text = parts.joined(separator: "  ")
        label.font = L2.font(14, .semibold)
        label.textColor = L2.textPrimary
        label.sizeToFit()

        let chip = UIControl()
        chip.tag = Self.kL2ChipTag
        chip.backgroundColor = L2.surface2
        chip.layer.borderWidth = 2
        chip.layer.borderColor = (mineSet.isEmpty ? L2.background : L2.accent).cgColor
        let w = label.bounds.width + 20, h: CGFloat = 26
        chip.layer.cornerRadius = h / 2
        let c = cell.containerView.frame
        let x = isFromCurrentSender(message: message) ? max(4, c.maxX - w - 8) : c.minX + 8
        chip.frame = CGRect(x: x, y: c.maxY - 6, width: w, height: h)
        label.frame = CGRect(x: 10, y: (h - label.bounds.height) / 2, width: label.bounds.width, height: label.bounds.height)
        label.isUserInteractionEnabled = false
        chip.addSubview(label)
        chip.isAccessibilityElement = true
        chip.accessibilityLabel = "Реакции: " + parts.joined(separator: ", ")
        chip.tag = Self.kL2ChipTag
        chip.addTarget(self, action: #selector(linia2ChipTapped(_:)), for: .touchUpInside)
        chip.accessibilityValue = String(message.seqId)
        cell.contentView.addSubview(chip)
    }

    @objc private func linia2ChipTapped(_ chip: UIControl) {
        guard let seq = Int(chip.accessibilityValue ?? "") else { return }
        linia2ShowReactionPicker(for: seq, from: chip)
    }

    /// Двойное касание по сообщению — ❤️.
    func linia2InstallReactionGestures() {
        let dbl = UITapGestureRecognizer(target: self, action: #selector(linia2DoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        dbl.cancelsTouchesInView = false
        dbl.delaysTouchesBegan = false
        collectionView?.addGestureRecognizer(dbl)
    }

    @objc private func linia2DoubleTap(_ g: UITapGestureRecognizer) {
        guard Linia2Config.shared.feature("reactions") else { return }
        guard let cv = collectionView, let ip = cv.indexPathForItem(at: g.location(in: cv)), ip.item < messages.count else { return }
        let msg = messages[ip.item]
        guard !msg.isDeleted, msg.seqId > 0 else { return }
        linia2ToggleReaction("❤️", on: msg.seqId)
    }

    /// Пункт «Реакция» в меню сообщения.
    @objc func linia2ReactMenu(sender: UIMenuController) {
        guard let item = sender.menuItems?.first as? MessageMenuItem, item.seqId > 0 else { return }
        linia2ShowReactionPicker(for: item.seqId, from: nil)
    }

    func linia2ShowReactionPicker(for seq: Int, from source: UIView?) {
        guard Linia2Config.shared.feature("reactions") else { return }
        let mine = linia2MyReactions[seq] ?? [:]
        let sheet = UIAlertController(title: "Реакция", message: nil, preferredStyle: .actionSheet)
        for e in Self.kL2QuickReactions {
            let title = mine[e] != nil ? "\(e)  — убрать" : e
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.linia2ToggleReaction(e, on: seq) })
        }
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        if let p = sheet.popoverPresentationController {
            p.sourceView = source ?? view
            p.sourceRect = source?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    /// Поставить реакцию или снять свою.
    func linia2ToggleReaction(_ emoji: String, on seq: Int) {
        guard let topic = topic else { return }
        L2.haptic()
        if let mySeq = linia2MyReactions[seq]?[emoji] {
            topic.delMessages(ids: [mySeq], hard: true).thenCatch { err in
                Cache.log.error("Linia2: не удалось снять реакцию: %@", err.localizedDescription)
                return nil
            }
            return
        }
        let head: [String: JSONValue] = ["reply": .string(String(seq)), Self.kL2ReactHeader: .string(emoji)]
        topic.publish(content: Drafty(content: emoji), withExtraHeaders: head).thenCatch { err in
            Cache.log.error("Linia2: не удалось отправить реакцию: %@", err.localizedDescription)
            DispatchQueue.main.async { UiUtils.showToast(message: "Не удалось отправить реакцию") }
            return nil
        }
    }
}
