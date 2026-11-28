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
        linia2LiftInputBarIfNeeded(keyboardFrame: end, didShow: notification.name == UIResponder.keyboardDidShowNotification)
        linia2ScheduleFeedCheck("kbd")
    }

    /// didShow — клавиатура только что появилась (LINIA2_KBD_REVEAL — только в этот момент, см. linia2RevealLastMessages).
    func linia2LiftInputBarIfNeeded(keyboardFrame end: CGRect?, didShow: Bool = false) {
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
        // LINIA2_KBD_FEED (1020): «клавиатура появилась» — по keyboardDidShow или резкому подъёму верха клавиатуры
        // (> 120 pt). Изменения высоты строки ввода, подсказок QuickType при наборе — не «появление».
        let appeared = docked && (didShow || Linia2KbdLift.lastTop - kb.minY > 120)
        Linia2KbdLift.lastTop = docked ? kb.minY : H
        // Кадр панели и клавиатуры — в координатах экрана (панель живёт в окне клавиатуры, лента — в окне приложения).
        let screen = win.screen.coordinateSpace
        let kbTopScreen = end.minY
        guard docked, barTop > kb.minY + 1 else {
            apply(target, 0)
            // Панель подняла система: последние сообщения не должны остаться под клавиатурой — только при появлении.
            if appeared { linia2RevealLastMessages(panelTopScreen: min(win.convert(CGPoint(x: 0, y: barTop), to: screen).y, kbTopScreen)) }
            return
        }
        // LINIA2_KBD_FEED: уже поднятая нами панель, а клавиатура теперь сообщает кадр вместе с ней (верх клавиатуры =
        // верх сдвинутой панели) — положение верное; без этой проверки каждый такой кадр поднимал панель ещё на её высоту.
        if cur != 0, abs(r.minY - kb.minY) <= 1 { return }
        // Верх панели под клавиатурой — система её не подняла: низ панели — к верху клавиатуры.
        let lift = max(-(barBottom - kb.minY), -kb.height)
        Cache.log.info("LINIA2_KBD_LIFT: panel not lifted by system (top %f, keyboard %f), lift %f", Double(barTop), Double(kb.minY), Double(lift))
        if abs(cur - lift) > 0.5 {
            Linia2LaunchLog.shared.step("kbd-lift", ["lift": Int(lift), "kbTop": Int(kb.minY), "barTop": Int(barTop), "H": Int(H)])
        }
        apply(target, lift)
        if let cv = collectionView {
            // Сколько ленты закрывают клавиатура и поднятая панель (в координатах экрана), не больше высоты ленты.
            let cvBottom = cv.convert(CGPoint(x: 0, y: cv.bounds.maxY), to: screen).y
            let need = min(max(0, cvBottom - (kbTopScreen - bar.bounds.height)) + 8, max(0, cv.bounds.height - 60))
            if cv.contentInset.bottom < need {
                cv.contentInset.bottom = need
                cv.verticalScrollIndicatorInsets.bottom = need
            }
        }
        if appeared { linia2RevealLastMessages(panelTopScreen: kbTopScreen - bar.bounds.height) }
    }

    /// LINIA2_KBD_REVEAL: после появления клавиатуры низ ленты должен быть над панелью ввода. Если пользователь
    /// был у конца переписки, а последние сообщения остались под клавиатурой — поднимаем ленту ровно на это расстояние.
    /// Если листал историю выше — не трогаем.
    /// LINIA2_KBD_FEED (1020): в 1019 вызывалось на каждом keyboardDidChangeFrame (а он приходит при каждом изменении
    /// высоты строки ввода/подсказок при наборе) и сравнивало верх панели в координатах окна клавиатуры с низом ленты
    /// в координатах окна приложения; отступ снизу ставился «высота окна − верх панели» и только рос. Теперь: только
    /// при появлении клавиатуры, всё в координатах экрана, сдвиг не больше перекрытия и не дальше конца ленты.
    func linia2RevealLastMessages(panelTopScreen panelTop: CGFloat) {
        guard Linia2Config.shared.feature("kbdLift"), let cv = collectionView, let win = cv.window,
              cv.numberOfSections > 0, cv.numberOfItems(inSection: 0) > 0, !cv.isDragging else { return }
        let screen = win.screen.coordinateSpace
        let contentBottom = cv.convert(CGPoint(x: 0, y: cv.contentSize.height), to: screen).y
        let cvBottom = cv.convert(CGPoint(x: 0, y: cv.bounds.maxY), to: screen).y
        let overlap = contentBottom - panelTop
        // Конец ленты под панелью/клавиатурой, но не дальше 80 pt ниже края ленты (пользователь у конца переписки).
        guard overlap > 1, contentBottom <= cvBottom + 80, overlap < cv.bounds.height else { return }
        let need = min(max(0, cvBottom - panelTop) + 8, max(0, cv.bounds.height - 60))
        if cv.contentInset.bottom < need {
            cv.contentInset.bottom = need
            cv.verticalScrollIndicatorInsets.bottom = need
        }
        let y = min(cv.contentOffset.y + overlap, linia2MaxOffsetY(cv))
        guard y > cv.contentOffset.y + 0.5 else { return }
        Cache.log.info("LINIA2_KBD_REVEAL: last messages under keyboard, scroll %f", Double(y - cv.contentOffset.y))
        cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: y), animated: true)
    }

    /// Наибольший допустимый contentOffset.y (низ ленты у нижнего отступа).
    func linia2MaxOffsetY(_ cv: UICollectionView) -> CGFloat {
        max(-cv.adjustedContentInset.top, cv.contentSize.height + cv.adjustedContentInset.bottom - cv.bounds.height)
    }

    /// contentOffset.y в допустимых пределах ленты (setContentOffset сам не ограничивает — лента «уезжает» за конец
    /// переписки, на экране пусто, пока пользователь не потянет ленту или не придёт новое сообщение).
    func linia2ClampedOffsetY(_ cv: UICollectionView, _ y: CGFloat) -> CGFloat {
        min(max(y, -cv.adjustedContentInset.top), linia2MaxOffsetY(cv))
    }

    /// LINIA2_KBD_FEED: через 0,4 с после изменения клавиатуры/строки ввода — лента не пустая. Если есть сообщения, а в
    /// видимой области ленты нет ни одного (лента ушла за конец переписки или сжалась), — вернуть к последним
    /// сообщениям и записать кадры в журнал запуска (call-diag, step kbd-heal) для разбора.
    func linia2ScheduleFeedCheck(_ why: String) {
        Linia2KbdLift.checkGen &+= 1
        let gen = Linia2KbdLift.checkGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard gen == Linia2KbdLift.checkGen else { return }
            self?.linia2CheckFeedVisible(why)
        }
    }

    func linia2CheckFeedVisible(_ why: String) {
        guard let cv = collectionView, cv.window != nil, cv.numberOfSections > 0, !cv.isDragging, !cv.isDecelerating,
              linia2Search == nil else { return }
        let n = cv.numberOfItems(inSection: 0)
        guard n > 0 else { return }
        let inset = cv.adjustedContentInset
        let visible = CGRect(x: cv.bounds.minX, y: cv.bounds.minY + inset.top, width: cv.bounds.width,
                             height: max(0, cv.bounds.height - inset.top - inset.bottom))
        let cells = (cv.collectionViewLayout.layoutAttributesForElements(in: visible) ?? [])
            .filter { $0.representedElementCategory == .cell && $0.frame.intersects(visible) }
        let maxY = linia2MaxOffsetY(cv)
        let beyond = cv.contentOffset.y > maxY + 2 || cv.contentOffset.y < -inset.top - 2
        guard cells.isEmpty || beyond else { return }
        if !cells.isEmpty {
            // Сообщения видны, но лента за пределами (после скрытия клавиатуры) — тихо вернуть в пределы.
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: linia2ClampedOffsetY(cv, cv.contentOffset.y)), animated: true)
            return
        }
        let bar = inputAccessoryView
        Linia2LaunchLog.shared.step("kbd-heal", [
            "why": why, "n": n, "cells": cells.count, "off": Int(cv.contentOffset.y), "maxY": Int(maxY),
            "cs": Int(cv.contentSize.height), "h": Int(cv.bounds.height), "inB": Int(cv.contentInset.bottom),
            "inT": Int(inset.top), "bar": Int(bar?.bounds.height ?? -1), "lift": Int(Linia2KbdLift.target?.transform.ty ?? 0),
            "kbTop": Int(Linia2KbdLift.lastTop), "H": Int(cv.window?.bounds.height ?? 0)])
        Linia2LaunchLog.shared.uploadSoon()
        Cache.log.error("LINIA2_KBD_FEED: feed empty on screen (offset %f, max %f, cells %d) — scroll to last messages",
                        Double(cv.contentOffset.y), Double(maxY), cells.count)
        if cv.contentInset.bottom > cv.bounds.height - 60 {
            cv.contentInset.bottom = max(8, bar?.bounds.height ?? 8)
            cv.verticalScrollIndicatorInsets.bottom = cv.contentInset.bottom
        }
        cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: linia2MaxOffsetY(cv)), animated: false)
    }

    @objc func adjustForKeyboard(_ notification: Notification) {
        // Apparently there is a bug in iOS 11 on iPad which sends useless notifications. This is a workaround.
        guard let keyboardInfo = KeyboardInfo(notification: notification), !keyboardInfo.frameBegin.isEmpty else { return }

        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: keyboardInfo.frameEnd.height, right: 0)
        let inputAccessoryViewHeight = inputAccessoryView?.frame.height ?? 0

        let overlap: CGFloat
        // Try to use frameBegin and frameEnd, when all available content is taller
        // than viewport less send bar. This can be done only on newer iOS versions.
        if collectionView.contentSize.height > collectionView.bounds.height - inputAccessoryViewHeight {
            overlap = keyboardInfo.frameEnd.height - keyboardInfo.frameBegin.height
        } else {
            // LINIA2: переписка короче экрана — сдвигаем ровно настолько, насколько низ последнего сообщения
            // заходит под клавиатуру/строку ввода (в координатах окна). Прежняя формула Tinode считала, что лента
            // начинается с верха экрана; под плавающей шапкой она сдвигала короткую переписку вверх при каждом
            // изменении строки ввода (например, при появлении цитаты ответа) — верхние сообщения уезжали
            // под шапку, а снизу оставалась пустота.
            let contentBottom = collectionView.convert(CGPoint(x: 0, y: collectionView.contentSize.height), to: nil).y
            overlap = contentBottom - keyboardInfo.frameEnd.origin.y
        }

        if overlap > 0 && keyboardInfo.frameEnd.size.height != inputAccessoryViewHeight {
            // LINIA2_KBD_FEED: в пределах ленты (Tinode прибавлял разницу кадров без ограничения).
            let contentOffset = CGPoint(
                x: collectionView.contentOffset.x,
                y: linia2ClampedOffsetY(collectionView, collectionView.contentOffset.y + overlap))
            collectionView.setContentOffset(contentOffset, animated: false)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        linia2LiftInputBarIfNeeded(keyboardFrame: nil)
        Linia2KbdLift.lastTop = .greatestFiniteMagnitude
        collectionView.contentInset.bottom = inputAccessoryView?.frame.height ?? 0
        collectionView.verticalScrollIndicatorInsets.bottom = collectionView.contentInset.bottom
        linia2ScheduleFeedCheck("hide")
    }
}

/// LINIA2_KBD_LIFT: вид, сдвинутый вверх вручную (чтобы вернуть его на место).
enum Linia2KbdLift {
    static weak var target: UIView?
    /// Верх пристыкованной клавиатуры при прошлом кадре (окно клавиатуры); нет клавиатуры — очень большое.
    static var lastTop: CGFloat = .greatestFiniteMagnitude
    /// Поколение отложенной проверки ленты (LINIA2_KBD_FEED).
    static var checkGen = 0
}
