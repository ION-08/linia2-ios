//
//  PinnedMessagesView.swift
//  Tinodios
//
//  Copyright © 2023-2025 Tinode LLC. All rights reserved.
//

import UIKit
import TinodeSDK

/// A protocol used to detect taps in the pinned messages carusel.
protocol PinnedMessagesDelegate: AnyObject {
    /// Tap on Cancel button.
    func didTapCancel(seq: Int)
    /// Tap on the message.
    func didTapMessage(seq: Int)
    /// LINIA2: список всех закреплённых («Открепить все»).
    func didTapPinnedList(pins: [Int])
}

class PinnedMessagesView: UICollectionReusableView {
    private static let kPinnedCollectionHeight = MessageViewController.Constants.kPinnedMessagesViewHeight - 4

    @IBOutlet weak var dotSelectorView: DotSelectorImageView!
    @IBOutlet weak var pagerView: PagerView!

    public var delegate: PinnedMessagesDelegate?

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        loadNib()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        loadNib()
    }

    private func loadNib() {
        let nib = UINib(nibName: "PinnedMessagesView", bundle: Bundle(for: type(of: self)))
        let nibView = nib.instantiate(withOwner: self, options: nil).first as! UIView
        nibView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nibView)

        NSLayoutConstraint.activate([
            nibView.topAnchor.constraint(equalTo: topAnchor),
            nibView.bottomAnchor.constraint(equalTo: bottomAnchor),
            nibView.rightAnchor.constraint(equalTo: rightAnchor),
            nibView.leftAnchor.constraint(equalTo: leftAnchor)
            ])

        dotSelectorView.dotCount = 3
        pagerView.delegate = self
        linia2Setup(nibView)
    }

    // MARK: LINIA2: плашка как в Telegram — «📌 Закреплённое K из N», нажатие переключает, список всех.
    private let l2Counter = UILabel()

    private func linia2Setup(_ nibView: UIView) {
        backgroundColor = L2.surface
        nibView.backgroundColor = L2.surface
        // Дизайн: в тёмной теме фон точек и ленты из xib (secondarySystemBackground) давал чёрный прямоугольник
        // с синей точкой; точки — только при нескольких закреплённых, цвет — акцент.
        dotSelectorView.backgroundColor = .clear
        dotSelectorView.selectedColor = L2.accent.cgColor
        dotSelectorView.normalColor = L2.textSecondary.withAlphaComponent(0.5).cgColor
        pagerView.backgroundColor = .clear
        for c in nibView.constraints where (c.firstItem as? UIView) === pagerView && c.firstAttribute == .top { c.constant = 18 }
        l2Counter.font = L2.font(12, .semibold)
        l2Counter.textColor = L2.accent
        l2Counter.translatesAutoresizingMaskIntoConstraints = false
        l2Counter.isUserInteractionEnabled = true
        l2Counter.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(linia2ShowList)))
        nibView.addSubview(l2Counter)
        NSLayoutConstraint.activate([
            l2Counter.leadingAnchor.constraint(equalTo: pagerView.leadingAnchor, constant: 6),
            l2Counter.topAnchor.constraint(equalTo: nibView.topAnchor, constant: 3)])
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(linia2ShowList)))
        accessibilityIdentifier = "l2.pinned"
        if Linia2Chrome.floatingHeader { linia2Float(nibView) }
        if let cancel = nibView.subviews.first(where: { ($0 as? UIButton)?.actions(forTarget: self, forControlEvent: .touchUpInside)?.isEmpty == false }) as? UIButton {
            cancel.accessibilityIdentifier = "l2.pinned.unpin"
            cancel.accessibilityLabel = "Открепить"
            cancel.tintColor = L2.textSecondary
        }
    }

    /// Плашка под плавающей шапкой: скруглённая полупрозрачная (blur), слева акцентная полоска — как в Telegram.
    private func linia2Float(_ nibView: UIView) {
        backgroundColor = .clear
        // Почти непрозрачная: сообщения под плашкой не просвечивают и не мешают читать.
        nibView.backgroundColor = L2.surface.withAlphaComponent(0.92)
        nibView.layer.cornerRadius = 14
        nibView.clipsToBounds = true
        let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        nibView.insertSubview(glass, at: 0)
        let bar = UIView()
        bar.backgroundColor = L2.accent
        bar.layer.cornerRadius = 1.5
        bar.isUserInteractionEnabled = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        nibView.addSubview(bar)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: nibView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: nibView.trailingAnchor),
            glass.topAnchor.constraint(equalTo: nibView.topAnchor),
            glass.bottomAnchor.constraint(equalTo: nibView.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: nibView.leadingAnchor, constant: 6),
            bar.topAnchor.constraint(equalTo: nibView.topAnchor, constant: 8),
            bar.bottomAnchor.constraint(equalTo: nibView.bottomAnchor, constant: -8),
            bar.widthAnchor.constraint(equalToConstant: 3),
        ])
    }

    private func linia2UpdateCounter() {
        let n = pins.count
        l2Counter.text = n > 1 ? String(format: L2T("l2.pin.counter", "📌 Закреплённое %d из %d"), selectedPage + 1, n) : L2T("l2.pin.single", "📌 Закреплённое")
        l2Counter.accessibilityIdentifier = "l2.pinned.counter"
    }

    @objc private func linia2ShowList(_ g: UIGestureRecognizer) {
        if let lp = g as? UILongPressGestureRecognizer, lp.state != .began { return }
        delegate?.didTapPinnedList(pins: pins)
    }

    @IBAction func unpinMessageClick(_ sender: Any) {
        delegate?.didTapCancel(seq: pins[selectedPage])
    }

    public var topicName: String?

    private func assignPinText(toView tv: UITextView, text: NSAttributedString) {
        // Дизайн: превью без своего цвета рисовалось тёмным по тёмному — нечитаемо. Основной цвет темы, 15 pt.
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.foregroundColor, in: full) { v, r, _ in
            if v == nil { m.addAttribute(.foregroundColor, value: L2.textPrimary, range: r) }
        }
        m.enumerateAttribute(.font, in: full) { v, r, _ in
            let f = (v as? UIFont) ?? L2.font(15)
            m.addAttribute(.font, value: f.withSize(min(f.pointSize, 15)), range: r)
        }
        tv.attributedText = m
        tv.textContainer.maximumNumberOfLines = 1
        tv.textContainer.lineBreakMode = .byTruncatingTail
        tv.sizeToFit()
        // Center text vertically.
        let topInset = max(0, (PinnedMessagesView.kPinnedCollectionHeight - tv.contentSize.height)/2)
        tv.contentInset = UIEdgeInsets(top: topInset, left: tv.contentInset.left, bottom: tv.contentInset.bottom, right: tv.contentInset.right)
    }

    public var pins: [Int] = [] {
        didSet {
            dotSelectorView.dotCount = pins.count
            dotSelectorView.alpha = pins.count > 1 ? 1 : 0
            if selectedPage >= pins.count { selectedPage = 0 }
            linia2UpdateCounter()
            var pages: [UIView] = []
            if !pins.isEmpty {
                guard let topicName = topicName, let topic = Cache.tinode.getTopic(topicName: topicName) else { return }
                let font = UITextView().font ?? UIFont.systemFont(ofSize: 15)
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: L2.textSecondary,
                    .font: UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitItalic)!, size: font.pointSize)
                ]
                pins.forEach { seq in
                    let tv = UITextView()
                    tv.delegate = self
                    tv.backgroundColor = .clear
                    tv.textColor = L2.textPrimary
                    tv.autocorrectionType = .no
                    tv.spellCheckingType = .no
                    pages.append(tv)
                    let msg = topic.getMessage(byEffectiveSeq: seq)
                    if let promise = self.preparePreview(msg) {
                        promise.thenApply { [weak self] content in
                            guard let pmv = self else { return nil }
                            let text = SendReplyFormatter(defaultAttributes: [:]).toAttributed(content!, fitIn: CGSize(width: pmv.pagerView.bounds.width, height: pmv.pagerView.bounds.height))
                            pmv.assignPinText(toView: tv, text: text)
                            return nil
                        }
                    } else {
                        var text = NSAttributedString(string: NSLocalizedString("message not found", comment: "Content of a pinned message when the message is missing"), attributes: attrs)
                        if let msg = msg, msg.isDeleted {
                            text = NSAttributedString(string: NSLocalizedString("message deleted", comment: "Content of a pinned message when the message is deleted"), attributes: attrs)
                        }
                        assignPinText(toView: tv, text: text)
                    }
                }
            }
            pagerView.pages = pages
        }
    }

    private var selectedPage: Int = 0
    public var selected: Int {
        get {
            return selectedPage
        }
        set(newValue)  {
            if newValue >= 0 && newValue < pins.count && newValue != selectedPage {
                selectedPage = newValue
                dotSelectorView.selected = selectedPage
            }
            linia2UpdateCounter()
        }
    }

    // Convert message into a quote ready for sending as a reply.
    func preparePreview(_ msg: Message?) -> PromisedReply<Drafty>? {
        guard let msg = msg else {
            return nil
        }
        guard let content = msg.content else {
            return nil
        }

        // Strip unneeded content and shorten.
        var reply = content.replyContent(length: UiUtils.kQuotedReplyLength, maxAttachments: 1)
        let createThumbnails = ThumbnailTransformer()
        reply = reply.transform(createThumbnails)
        let whenDone = PromisedReply<Drafty>()
        createThumbnails.completionPromise.thenApply {_ in
            try? whenDone.resolve(result: reply)
            return nil
        }
        return whenDone
    }
}

extension PinnedMessagesView: PagerViewDelegate {
    func didSelectPage(index: Int) {
        dotSelectorView.selected = index
        self.selectedPage = index
        linia2UpdateCounter()
    }
}

extension PinnedMessagesView: UITextViewDelegate {
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveLinear, animations: {
            textView.backgroundColor = L2.surface2
        }, completion: { _ in
            textView.backgroundColor = .clear
        })
        guard selectedPage < pins.count else { return false }
        delegate?.didTapMessage(seq: pins[selectedPage])
        // Как в Telegram: следующее нажатие — к следующему закреплённому.
        if pins.count > 1 {
            let next = (selectedPage + 1) % pins.count
            pagerView.moveToPage(at: next)
            didSelectPage(index: next)
        }
        return false
    }
}
