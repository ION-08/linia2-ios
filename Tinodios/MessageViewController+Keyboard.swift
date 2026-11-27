//
//  MessageViewController+Keyboard.swift
//  Tinodios
//
//  Copyright © 2019-2022 Tinode LLC. All rights reserved.
//

import UIKit

// LINIA2_KBD_GUIDE: панель ввода привязана к view.keyboardLayoutGuide (MessageViewController.loadView),
// лента заканчивается над панелью. Уведомлений клавиатуры и ручного расчёта больше нет: при подъёме клавиатуры
// (любой высоты — буквы, эмодзи, панель предложений, аппаратная клавиатура iPad) лента становится ниже,
// а здесь низ переписки удерживается на месте.
extension MessageViewController {

    /// Вызывается из viewDidLayoutSubviews: высота ленты изменилась (клавиатура, рост поля ввода, цитата,
    /// поворот) — сдвинуть содержимое так, чтобы нижние сообщения остались видны. Внутри анимации клавиатуры
    /// сдвиг анимируется вместе с ней.
    func linia2KeepBottomOnResize() {
        guard let cv = collectionView else { return }
        let height = cv.bounds.height
        let old = linia2LastCollectionHeightValue
        linia2LastCollectionHeightValue = height
        // Палец на ленте (интерактивное скрытие клавиатуры) — не дёргаем содержимое под пальцем.
        guard old > 0, abs(old - height) > 0.5, !cv.isTracking else { return }
        let insets = cv.adjustedContentInset
        let minY = -insets.top
        let maxY = max(minY, cv.contentSize.height + insets.bottom - height)
        let y = min(max(cv.contentOffset.y + (old - height), minY), maxY)
        if abs(y - cv.contentOffset.y) > 0.5 {
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: y), animated: false)
        }
    }
}
