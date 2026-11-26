//
//  Linia2Receipts.swift
//  Линия 2.0: галочки доставки (пилюля под временем) и «Информация о доставке».
//
//  Данные — GET https://<host>/invite/api/receipts?topic=<имя топика клиента>&seq=<seq>
//  с заголовком Authorization: Bearer <токен Tinode> (CONTRACTS.md, «Информация о доставке»).
//  Флаги: features.readReceipts / features.readInfo; пункт меню — id `info` в menus.message.
//

import UIKit
import TinodeSDK
import TinodiosDB

// MARK: - Галочки: линия ~2.4 pt, шаблонные картинки (цвет задаёт tint)

enum L2Checks {
    private static let size = CGSize(width: 19, height: 16)

    private static func draw(double: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIColor.black.setStroke()
            func check(_ dx: CGFloat, short: Bool) {
                let p = UIBezierPath()
                if !short {
                    p.move(to: CGPoint(x: 1.6 + dx, y: 8.6))
                    p.addLine(to: CGPoint(x: 5.2 + dx, y: 12.2))
                } else {
                    p.move(to: CGPoint(x: 5.6 + dx, y: 12.2))
                }
                p.addLine(to: CGPoint(x: 12.4 + dx, y: 4.0))
                p.lineWidth = 2.4
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.stroke()
            }
            if double {
                check(0, short: false)
                check(5, short: true)
            } else {
                check(2.5, short: false)
            }
        }.withRenderingMode(.alwaysTemplate)
    }

    static let single = draw(double: false)
    static let double = draw(double: true)
    static let pending: UIImage = (UIImage(systemName: "clock", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
                                   ?? draw(double: false)).withRenderingMode(.alwaysTemplate)
}

// MARK: - Ответ сервера

struct Linia2Receipt {
    struct Member {
        let uid: String
        let name: String
        let recv: Date?
        let read: Date?
        let recvNow: Bool
        let readNow: Bool
        var isRead: Bool { read != nil || readNow }
        var isDelivered: Bool { !isRead && (recv != nil || recvNow) }
    }
    let sent: Date?
    let members: [Member]

    private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func parse(_ json: [String: Any]) -> Linia2Receipt? {
        guard (json["ok"] as? Bool) ?? true else { return nil }
        let members = (json["members"] as? [[String: Any]] ?? []).compactMap { m -> Member? in
            guard let uid = m["uid"] as? String else { return nil }
            return Member(uid: uid, name: m["name"] as? String ?? "", recv: date(m["recv"]), read: date(m["read"]),
                          recvNow: m["recvNow"] as? Bool ?? false, readNow: m["readNow"] as? Bool ?? false)
        }
        return Linia2Receipt(sent: date(json["sent"]), members: members)
    }

    /// Загрузка (колбэк на главном потоке): nil — «Нет сведений».
    static func fetch(topic: String, seq: Int, completion: @escaping (Linia2Receipt?, Int) -> Void) {
        var comps = URLComponents(string: Linia2API.base + "receipts")
        comps?.queryItems = [URLQueryItem(name: "topic", value: topic), URLQueryItem(name: "seq", value: String(seq))]
        guard let url = comps?.url, let token = Cache.tinode.authToken, !token.isEmpty else {
            completion(nil, 401)
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var r: Linia2Receipt?
            if code == 200, let d = data, let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                r = parse(json)
            }
            DispatchQueue.main.async { completion(r, code) }
        }.resume()
    }

    /// «12:05», не сегодня — «24.11 12:05».
    static func timeText(_ d: Date?, known: Bool) -> String {
        guard let d = d else { return known ? L2T("l2.receipt.unknownTime", "время неизвестно") : "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd.MM.yy HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Лист «Информация о сообщении»

final class Linia2ReceiptViewController: UIViewController {
    private let topic: DefaultComTopic
    private let seq: Int
    private let localSent: Date?
    private let stack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(topic: DefaultComTopic, seq: Int, sent: Date?) {
        self.topic = topic
        self.seq = seq
        self.localSent = sent
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        view.accessibilityIdentifier = "l2.receipt.sheet"
        let title = UILabel()
        title.text = L2T("l2.msg.infoTitle", "Информация о сообщении")
        title.font = L2.font(18, .bold)
        title.textColor = L2.textPrimary
        title.accessibilityIdentifier = "l2.receipt.title"
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)
        view.addSubview(scroll)
        scroll.addSubview(stack)
        spinner.startAnimating()
        stack.addArrangedSubview(spinner)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        Linia2Receipt.fetch(topic: topic.name, seq: seq) { [weak self] r, _ in self?.show(r) }
    }

    private func label(_ text: String, _ size: CGFloat = 16, _ weight: UIFont.Weight = .regular, secondary: Bool = false) -> UILabel {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = L2.font(size, weight)
        l.textColor = secondary ? L2.textSecondary : L2.textPrimary
        return l
    }

    private func show(_ r: Linia2Receipt?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let r = r else {
            let l = label(L2T("l2.receipt.none", "Нет сведений"), 16, .regular, secondary: true)
            l.accessibilityIdentifier = "l2.receipt.none"
            stack.addArrangedSubview(l)
            return
        }
        let sent = "Отправлено " + Linia2Receipt.timeText(r.sent ?? localSent, known: true)
        if topic.isP2PType, let m = r.members.first {
            // Личный чат: одна строка «Отправлено · Доставлено · Прочитано».
            var parts = [sent]
            if m.isRead || m.isDelivered || m.recv != nil {
                parts.append("Доставлено " + Linia2Receipt.timeText(m.recv ?? m.read, known: true))
            } else {
                parts.append(L2T("l2.receipt.notDelivered", "Ещё не доставлено"))
            }
            if m.isRead {
                parts.append("Прочитано " + Linia2Receipt.timeText(m.read, known: true))
            } else if m.isDelivered {
                parts.append(L2T("l2.receipt.notRead", "Не прочитано"))
            }
            let l = label(parts.joined(separator: " · "))
            l.accessibilityIdentifier = "l2.receipt.p2p"
            stack.addArrangedSubview(l)
            return
        }
        let s = label(sent, 15, .regular, secondary: true)
        s.accessibilityIdentifier = "l2.receipt.sent"
        stack.addArrangedSubview(s)
        let read = r.members.filter { $0.isRead }
        let delivered = r.members.filter { $0.isDelivered }
        let pending = r.members.filter { !$0.isRead && !$0.isDelivered }
        section("Прочитали", read, id: "read") { Linia2Receipt.timeText($0.read, known: true) }
        section("Доставлено, но не прочитано", delivered, id: "delivered") { Linia2Receipt.timeText($0.recv, known: true) }
        section("Ещё не доставлено", pending, id: "pending") { _ in "" }
    }

    private func section(_ title: String, _ list: [Linia2Receipt.Member], id: String, time: (Linia2Receipt.Member) -> String) {
        guard !list.isEmpty else { return }
        let h = label("\(title) (\(list.count))", 15, .semibold)
        h.accessibilityIdentifier = "l2.receipt." + id
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last ?? h)
        stack.addArrangedSubview(h)
        for m in list {
            let sub = topic.getSubscription(for: m.uid)
            let avatar = RoundImageView()
            avatar.translatesAutoresizingMaskIntoConstraints = false
            avatar.widthAnchor.constraint(equalToConstant: 32).isActive = true
            avatar.heightAnchor.constraint(equalToConstant: 32).isActive = true
            avatar.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            avatar.set(pub: sub?.pub, id: m.uid, deleted: false)
            let name = label(sub?.pub?.fn ?? (m.name.isEmpty ? m.uid : m.name))
            let t = label(time(m), 14, .regular, secondary: true)
            t.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [avatar, name, t])
            row.spacing = 10
            row.alignment = .center
            stack.addArrangedSubview(row)
        }
    }
}

// MARK: - Экран чата: пилюля, меню «Информация», нажатие на галочки

extension MessageViewController {
    var linia2ReceiptInfoEnabled: Bool {
        Linia2Config.shared.feature("readReceipts") && Linia2Config.shared.feature("readInfo")
    }

    /// Пилюля под временем и галочками своих сообщений (#00000040).
    func linia2LayoutMetaPill(cell: MessageCell, message: Message) {
        let pill = cell.linia2MetaPill
        guard isFromCurrentSender(message: message) || linia2IsRound(message), !message.isDeleted, !linia2IsServiceMessage(message),
              let text = cell.timestampLabel.text, !text.isEmpty else {
            pill.isHidden = true
            return
        }
        cell.timestampLabel.textAlignment = .right
        let tw = min(cell.timestampLabel.frame.width, ceil(cell.timestampLabel.sizeThatFits(CGSize(width: 200, height: 30)).width))
        var r = cell.timestampLabel.frame
        r.origin.x = r.maxX - tw
        r.size.width = tw
        if cell.deliveryMarker.image != nil, cell.deliveryMarker.frame != .zero { r = r.union(cell.deliveryMarker.frame) }
        r = r.insetBy(dx: -5, dy: -1.5)
        pill.frame = r
        pill.layer.cornerRadius = r.height / 2
        pill.isHidden = false
        cell.containerView.insertSubview(pill, belowSubview: cell.timestampLabel)
    }

    func linia2DidTapDelivery(in cell: MessageCell) {
        guard linia2ReceiptInfoEnabled, cell.seqId > 0, let i = messageSeqIdIndex[cell.seqId], isFromCurrentSender(message: messages[i]) else { return }
        linia2PresentReceipt(seq: cell.seqId, sent: cell.timeStamp)
    }

    @objc func linia2ShowReceiptInfo(sender: UIMenuController) {
        guard let item = sender.menuItems?.first as? MessageMenuItem, item.seqId > 0 else { return }
        let ts = messageSeqIdIndex[item.seqId].map { messages[$0].ts } ?? nil
        linia2PresentReceipt(seq: item.seqId, sent: ts)
    }

    func linia2PresentReceipt(seq: Int, sent: Date?) {
        guard let topic = topic else { return }
        present(Linia2ReceiptViewController(topic: topic, seq: seq, sent: sent), animated: true)
    }
}
