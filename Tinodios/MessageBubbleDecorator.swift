//
//  MessageBubbleDecorator.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import UIKit

/// Draws message bubble as bezier path in iMessage style.
class MessageBubbleDecorator {

    public enum Style {
        case single, last, middle, first
    }

    private static func drawIncoming(path: UIBezierPath, size: CGSize, style: Style) {
        let width = size.width
        let height = size.height

        // Start at bottom-left corner.
        if style == .single || style == .last {
            // Leave space for the rounded corner.
            path.move(to: CGPoint(x: 22, y: height))
        } else {
            path.move(to: CGPoint(x: 4, y: height))
        }

        // Move to bottom right
        path.addLine(to: CGPoint(x: width - 17, y: height))
        // Add bottom-right rounded corner
        path.addCurve(to: CGPoint(x: width, y: height - 17), controlPoint1: CGPoint(x: width - 7.61, y: height), controlPoint2: CGPoint(x: width, y: height - 7.61))

        // Move to top right corner
        path.addLine(to: CGPoint(x: width, y: 17))
        // Add top-right round corner
        path.addCurve(to: CGPoint(x: width - 17, y: 0), controlPoint1: CGPoint(x: width, y: 7.61), controlPoint2: CGPoint(x: width - 7.61, y: 0))

        // Move to top left corner
        if style == .single || style == .first {
            // Leave space for the rounded corner.
            path.addLine(to: CGPoint(x: 21, y: 0))
            // Top left round corner
            path.addCurve(to: CGPoint(x: 4, y: 17), controlPoint1: CGPoint(x: 11.61, y: 0), controlPoint2: CGPoint(x: 4, y: 7.61))
        } else {
            path.addLine(to: CGPoint(x: 4, y: 0))
        }

        // Move to bottom-left.
        if style == .single || style == .last {
            // Leave space for pigtail.
            path.addLine(to: CGPoint(x: 4, y: height - 11))
            // Pigtail top
            path.addCurve(to: CGPoint(x: 0, y: height), controlPoint1: CGPoint(x: 4, y: height - 1), controlPoint2: CGPoint(x: 0, y: height))
            // Pigtail bottom
            path.addCurve(to: CGPoint(x: 11, y: height - 4), controlPoint1: CGPoint(x: 4, y: height + 0.43), controlPoint2: CGPoint(x: 8.16, y: height - 1.06))
            // Remainder of the bottom left round corner
            path.addCurve(to: CGPoint(x: 22, y: height), controlPoint1: CGPoint(x: 16, y: height), controlPoint2: CGPoint(x: 19, y: height))
        } else {
            // Move to bottom-left
            path.addLine(to: CGPoint(x: 4, y: height))
        }
    }

    private static func drawOutgoing(path: UIBezierPath, size: CGSize, style: Style) {
        let width = size.width
        let height = size.height

        // Start at bottom-right corner
        if style == .single || style == .last {
            path.move(to: CGPoint(x: width - 22, y: height))
        } else {
            path.move(to: CGPoint(x: width - 4, y: height))
        }

        // Move to bottom-left
        path.addLine(to: CGPoint(x: 17, y: height))
        // Bottom-left round corner
        path.addCurve(to: CGPoint(x: 0, y: height - 17), controlPoint1: CGPoint(x: 7.61, y: height), controlPoint2: CGPoint(x: 0, y: height - 7.61))
        // Move to top-left
        path.addLine(to: CGPoint(x: 0, y: 17))
        // Top-left round corner
        path.addCurve(to: CGPoint(x: 17, y: 0), controlPoint1: CGPoint(x: 0, y: 7.61), controlPoint2: CGPoint(x: 7.61, y: 0))

        // Move to top-right
        if style == .single || style == .first {
            path.addLine(to: CGPoint(x: width - 21, y: 0))
            path.addCurve(to: CGPoint(x: width - 4, y: 17), controlPoint1: CGPoint(x: width - 11.61, y: 0), controlPoint2: CGPoint(x: width - 4, y: 7.61))
        } else {
            path.addLine(to: CGPoint(x: width - 4, y: 0))
        }

        // Move to bottom-right
        if style == .single || style == .last {
            path.addLine(to: CGPoint(x: width - 4, y: height - 11))
            // Pigtail
            path.addCurve(to: CGPoint(x: width, y: height), controlPoint1: CGPoint(x: width - 4, y: height - 1), controlPoint2: CGPoint(x: width, y: height))
            path.addCurve(to: CGPoint(x: width - 11.04, y: height - 4.04), controlPoint1: CGPoint(x: width - 4.07, y: height + 0.43), controlPoint2: CGPoint(x: width - 8.16, y: height - 1.06))
            path.addCurve(to: CGPoint(x: width - 22, y: height), controlPoint1: CGPoint(x: width - 16, y: height), controlPoint2: CGPoint(x: width - 19, y: height))
        } else {
            path.addLine(to: CGPoint(x: width - 4, y: height))
        }
    }

    public static func drawDeleted(_ rect: CGRect) -> UIBezierPath {
        return UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: rect.size.width, height: rect.size.height), cornerRadius: 15.22)
    }

    /// Прямоугольник с разными радиусами углов.
    static func roundedPath(_ b: CGRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: b.minX + tl, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - tr, y: b.minY))
        p.addArc(withCenter: CGPoint(x: b.maxX - tr, y: b.minY + tr), radius: tr, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - br))
        p.addArc(withCenter: CGPoint(x: b.maxX - br, y: b.maxY - br), radius: br, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: b.minX + bl, y: b.maxY))
        p.addArc(withCenter: CGPoint(x: b.minX + bl, y: b.maxY - bl), radius: bl, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + tl))
        p.addArc(withCenter: CGPoint(x: b.minX + tl, y: b.minY + tl), radius: tl, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        p.close()
        return p
    }

    public static func draw(_ rect: CGRect, isIncoming: Bool, style: Style) -> UIBezierPath {
        // LINIA2: радиус пузыря с сервера (radii.bubble) — скруглённый прямоугольник, угол у края отправителя меньше.
        // Дизайн (как Telegram): все углы скруглены радиусом radii.bubble (по умолчанию 18), со стороны
        // отправителя у сообщений одной серии углы-«стыки» маленькие (6), у последнего в серии — нижний 6.
        // Раньше объединение двух путей давало прямой угол у края отправителя и разные углы у соседних пузырей.
        let r = Linia2Config.shared.radius("bubble", 18)
        if r >= 0 {
            let b = CGRect(origin: .zero, size: rect.size)
            let big = min(r, b.height / 2, b.width / 2)
            let small = min(6, big)
            let joinTop = style == .middle || style == .last
            let senderTop = joinTop ? small : big
            let senderBottom = small
            return roundedPath(b,
                               tl: isIncoming ? senderTop : big, tr: isIncoming ? big : senderTop,
                               br: isIncoming ? big : senderBottom, bl: isIncoming ? senderBottom : big)
        }
        let path = UIBezierPath()

        if isIncoming {
            drawIncoming(path: path, size: rect.size, style: style)
        } else {
            drawOutgoing(path: path, size: rect.size, style: style)
        }

        path.close()

        return path
    }
}
