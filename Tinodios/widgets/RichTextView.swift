//
//  RichTextLabel.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import UIKit

/// UITextView with some layout issues fixed.
class RichTextView: UITextView {

    override func layoutSubviews() {
        super.layoutSubviews()
        setup()
    }

    // If true, will automatically adjust height based on the held content
    // upon size change (i.e. when layoutSubviews() gets called).
    @IBInspectable var autoAdjustHeight: Bool = true

    func setup() {
        // Apple is a steaming pile of buggy $#14
        // See https://stackoverflow.com/questions/746670/how-to-lose-margin-padding-in-uitextview
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInset = UIEdgeInsets.zero

        isScrollEnabled = false
        isUserInteractionEnabled = true
        isEditable = false
        isSelectable = true

        var b = bounds
        if !b.isEmpty && autoAdjustHeight {
            // Only change bounds for non-trivial (visible) RichTextViews.
            b.size.height = sizeThatFits(CGSize(width: bounds.size.width, height: CGFloat.greatestFiniteMagnitude)).height
            if b != bounds {
                bounds = b
            }
        }
    }

    // MARK: LINIA2: доступность
    // Текст сообщения и цитаты (ответ/пересылка) — нередактируемый: для VoiceOver и XCUITest это обычный
    // текст (StaticText) одним элементом с подписью = текст. Иначе UITextView в iOS 17/18 отдаётся как
    // TextView с вложенным TextView-фрагментом: подпись у вложенного, проверка «нажимаемости» по нему
    // не проходит (долгое нажатие по сообщению после закрытия меню не срабатывало), цитата над полем
    // ввода не читалась как текст. Без текста (только вложение) — поведение UITextView по умолчанию.
    /// Текст для доступности, если видимый текст нарисован картинкой (цитата ответа/пересылки — QuotedAttachment).
    var l2AccessibilityText: String?

    private var l2AccessibleText: String? {
        if let t = l2AccessibilityText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let t = (attributedText?.string ?? text ?? "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    override var isAccessibilityElement: Bool {
        get { l2AccessibleText != nil ? true : super.isAccessibilityElement }
        set { super.isAccessibilityElement = newValue }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get { l2AccessibleText != nil ? .staticText : super.accessibilityTraits }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityLabel: String? {
        get { l2AccessibleText ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityValue: String? {
        get { l2AccessibleText != nil ? nil : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(contentOffset, animated: false)
    }

    // MARK: public methods

    public func getURLForTap(_ location: CGPoint) -> URL? {
        // See discussion: https://stackoverflow.com/questions/19318092/how-to-detect-touch-on-nstextattachment/49153247#49153247

        let glyphIndex: Int = layoutManager.glyphIndex(for: location, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)

        guard glyphRect.contains(location) else { return nil }

        let characterIndex: Int = layoutManager.characterIndexForGlyph(at: glyphIndex)

        guard characterIndex < textStorage.length else { return nil }

        // Check if an URL was tapped
        if let link = textStorage.attribute(.link, at: characterIndex, effectiveRange: nil) as? NSURL {
            return link.absoluteURL
        }

        guard NSTextAttachment.character == (textStorage.string as NSString).character(at: characterIndex) else { return nil }
        guard let attachment = textStorage.attribute(.attachment, at: characterIndex, effectiveRange: nil) as? NSTextAttachment else { return nil }

        if let button = attachment as? ButtonAttachment {
            return button.payload
        }

        if attachment is QuotedAttachment {
            return URL(string: "tinode:///quote")
        }

        guard let att = attachment as? EntityTextAttachment else { return URL(string: "tinode:///attachment/generic") }

        var urlComps = URLComponents(string: "tinode://")!
        if att.type == "image" {
            urlComps.path = "/image/preview"
        } else if att.type == "video" {
            urlComps.path = "/video"
        } else if att.type?.starts(with: "audio") ?? false {
            urlComps.path = "/\(att.type!)"
            // Click position in glyphRect coordinates
            if att.type == "audio/seek" {
                let pos: CGFloat = (location.x - glyphRect.minX) / glyphRect.width
                urlComps.queryItems = [URLQueryItem(name: "pos", value: pos.description)]
            }
        }

        if let key = att.draftyEntityKey {
            var queryItems = urlComps.queryItems ?? []
            queryItems.append(URLQueryItem(name: "key", value: String(key)))
            urlComps.queryItems = queryItems
        }

        return urlComps.url
    }
}
