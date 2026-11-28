//
//  MessageViewController+Keyboard.swift
//  Tinodios
//
//  Copyright © 2019-2022 Tinode LLC. All rights reserved.
//

import UIKit

extension MessageViewController {

    func addKeyboardObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(adjustForKeyboard(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        notificationCenter.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil)
        // LINIA2_KBD_LIFT: проверка после анимации клавиатуры — поднята ли панель ввода (inputAccessoryView).
        notificationCenter.addObserver(
            self,
            selector: #selector(linia2KeyboardDidChange(_:)),
            name: UIResponder.keyboardDidShowNotification,
            object: nil)
        notificationCenter.addObserver(
            self,
            selector: #selector(linia2KeyboardDidChange(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
    }

    /// LINIA2_KBD_LIFT: на iPhone 17 / iOS 27.3 система иногда не поднимает inputAccessoryView над клавиатурой —
    /// панель остаётся у нижнего края под клавиатурой. Панель по-прежнему inputAccessoryView (раскладку экрана
    /// не трогаем — без циклов Auto Layout); после анимации клавиатуры сверяем положение панели с кадром
    /// клавиатуры и, если верх панели оказался ниже верха клавиатуры, сдвигаем её вверх (transform: раскладку
    /// не вызывает). Обычный случай (панель — часть кадра клавиатуры, верх совпадает) — ничего не делаем.
    /// Сервер: features.kbdLift = false — выключить.
    @objc func linia2KeyboardDidChange(_ notification: Notification) {
        guard let end = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        linia2LiftInputBarIfNeeded(keyboardFrame: end)
    }

    func linia2LiftInputBarIfNeeded(keyboardFrame end: CGRect?) {
        let active = inputAccessoryView
        // Трогаем только вид, который сдвинули сами (у системных обёрток может быть своя анимация).
        func apply(_ target: UIView?, _ ty: CGFloat) {
            if let old = Linia2KbdLift.target, old !== target || ty == 0 {
                Linia2KbdLift.target = nil
                UIView.animate(withDuration: 0.2) { old.transform = .identity }
            }
            guard let t = target, ty != 0 else { return }
            Linia2KbdLift.target = t
            if abs(t.transform.ty - ty) > 0.5 {
                UIView.animate(withDuration: 0.2) { t.transform = CGAffineTransform(translationX: 0, y: ty) }
            }
        }
        guard Linia2Config.shared.feature("kbdLift"), let end = end, !end.isEmpty,
              let bar = active, let win = bar.window, !bar.isHidden else { apply(Linia2KbdLift.target, 0); return }
        // Сдвигаем самого верхнего предка панели той же высоты (системная обёртка ровно по панели): иначе
        // сдвинутая за пределы обёртки панель не получала бы нажатий.
        var target: UIView = bar
        while let sv = target.superview, sv !== win, sv.superview != nil, sv.bounds.height <= bar.bounds.height + 1 { target = sv }
        let kb = win.convert(end, from: win.screen.coordinateSpace)
        let H = win.bounds.height
        let cur = (Linia2KbdLift.target === target) ? target.transform.ty : 0
        let r = bar.convert(bar.bounds, to: win)
        let barTop = r.minY - cur, barBottom = r.maxY - cur
        // Клавиатура пристыкована снизу и заметно выше самой панели (не только панель без клавиатуры).
        let docked = kb.minY < H - 1 && kb.maxY >= H - 1 && kb.height > bar.bounds.height + 100
        guard docked, barTop > kb.minY + 1 else { apply(target, 0); return }
        // Верх панели под клавиатурой — система её не подняла: низ панели — к верху клавиатуры.
        let lift = -(barBottom - kb.minY)
        Cache.log.info("LINIA2_KBD_LIFT: panel not lifted by system (top %f, keyboard %f), lift %f", Double(barTop), Double(kb.minY), Double(lift))
        apply(target, lift)
        if let cv = collectionView {
            let need = H - kb.minY + bar.bounds.height
            if cv.contentInset.bottom < need { cv.contentInset.bottom = need }
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        linia2LiftInputBarIfNeeded(keyboardFrame: nil)
        collectionView.contentInset.bottom = inputAccessoryView?.frame.height ?? 0
    }
}

/// LINIA2_KBD_LIFT: вид, сдвинутый вверх вручную (чтобы вернуть его на место).
enum Linia2KbdLift {
    static weak var target: UIView?
}
