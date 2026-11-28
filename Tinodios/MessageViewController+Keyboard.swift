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
            let contentOffset = CGPoint(
                x: collectionView.contentOffset.x,
                y: collectionView.contentOffset.y + overlap)
            collectionView.setContentOffset(contentOffset, animated: false)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        collectionView.contentInset.bottom = inputAccessoryView?.frame.height ?? 0
    }
}
