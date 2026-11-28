//
//  ImagePicker.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import MobileCoreServices
import UIKit

public enum ImagePickerMediaType {
    case image(UIImage?, String?, String?)
    case video(URL?, String?, String?)
}

public protocol ImagePickerDelegate: AnyObject {
    func didSelect(media: ImagePickerMediaType?)
}

open class ImagePicker: NSObject {

    private let pickerController: UIImagePickerController
    private weak var presentationController: UIViewController?
    private weak var delegate: ImagePickerDelegate?

    public init(presentationController: UIViewController, delegate: ImagePickerDelegate, editable: Bool,
                allowVideo: Bool = false) {
        self.pickerController = UIImagePickerController()

        super.init()

        self.presentationController = presentationController
        self.delegate = delegate

        self.pickerController.delegate = self
        self.pickerController.allowsEditing = editable
        self.pickerController.mediaTypes = [kUTTypeImage as String]
        if allowVideo {
            self.pickerController.mediaTypes.append(kUTTypeMovie as String)
        }
    }

    private func action(for type: UIImagePickerController.SourceType, title: String) -> UIAlertAction? {
        guard UIImagePickerController.isSourceTypeAvailable(type) else {
            return nil
        }

        return UIAlertAction(title: title, style: .default) { [unowned self] _ in
            self.pickerController.sourceType = type
            self.presentationController?.present(self.pickerController, animated: true)
        }
    }

    public func present(from sourceView: UIView) {

        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        if let action = self.action(for: .camera, title: Linia2Texts.t("Take photo")) {
            alertController.addAction(action)
        } else if Linia2TestHook.enabled && ProcessInfo.processInfo.arguments.contains("-l2-fake-camera") {
            // Автотесты: в симуляторе камеры нет — «снимок» как с камеры iPhone (повёрнутый, HDR / 16 бит на канал).
            alertController.addAction(UIAlertAction(title: Linia2Texts.t("Take photo"), style: .default) { [weak self] _ in
                guard let self = self else { return }
                let info: [UIImagePickerController.InfoKey: Any] = [.mediaType: kUTTypeImage as String,
                                                                     .originalImage: ImagePicker.linia2FakeCameraImage()]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.didPickImage(nil, didFinishPickingMediaWithInfo: info, camera: true)
                }
            })
        }
        if let action = self.action(for: .savedPhotosAlbum, title: Linia2Texts.t("Camera roll")) {
            alertController.addAction(action)
        }
        if let action = self.action(for: .photoLibrary, title: Linia2Texts.t("Photo library")) {
            alertController.addAction(action)
        }

        alertController.addAction(UIAlertAction(title: Linia2Texts.t("Cancel"), style: .cancel, handler: nil))

        if UIDevice.current.userInterfaceIdiom == .pad {
            alertController.popoverPresentationController?.sourceView = sourceView
            alertController.popoverPresentationController?.sourceRect = sourceView.bounds
            alertController.popoverPresentationController?.permittedArrowDirections = [.down, .up]
        }

        // Unnecessary empty view is added and animation is disabled because of
        // https://stackoverflow.com/questions/55653187/swift-default-alertviewcontroller-breaking-constraints
        // https://stackoverflow.com/questions/55372093/uialertcontrollers-actionsheet-gives-constraint-error-on-ios-12-2
        // FIXME: Remove the following line and make `animation: true` when Apple fixes the bug.
        alertController.view.addSubview(UIView())
        self.presentationController?.present(alertController, animated: false)
    }

    private func pickerController(_ controller: UIImagePickerController?, didSelect media: ImagePickerMediaType?) {
        // LINIA2_CAMERA (1020): результат — после закрытия пикера (переход на предпросмотр во время анимации
        // закрытия камеры мог не выполниться).
        guard let controller = controller, controller.presentingViewController != nil else {
            self.delegate?.didSelect(media: media)
            return
        }
        controller.dismiss(animated: true) { [weak self] in
            self?.delegate?.didSelect(media: media)
        }
    }

    /// LINIA2_CAMERA (1020): снимок в обычный 8-битный sRGB «как на экране», ориентация вверх, длинная сторона ≤ maxSide.
    /// Снимки камеры iPhone — повёрнутые (orientation .right) и с iOS 17+ HDR / 10–16 бит на канал: прежний
    /// fixedOrientation рисовал их через CGContext с форматом исходника (8-битный premultipliedLast) — CGContext
    /// не создавался, картинка становилась nil и выбор молча отбрасывался: «фото сделано, но не отправилось».
    /// Из галереи фото обычно уже «вверх» — fixedOrientation возвращал их без перерисовки, поэтому там работало.
    static func linia2Normalized(_ img: UIImage, maxSide: CGFloat = 2048) -> UIImage? {
        let w = img.size.width * img.scale, h = img.size.height * img.scale
        guard w >= 1, h >= 1 else { return nil }
        let k = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, (w * k).rounded(.down)), height: max(1, (h * k).rounded(.down)))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        fmt.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Автотесты: картинка как с камеры — 16 бит на канал (extended range) и orientation .right.
    static func linia2FakeCameraImage() -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        fmt.preferredRange = .extended
        let size = CGSize(width: 1600, height: 1200)
        let base = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            for i in 0..<16 {
                UIColor(hue: CGFloat(i) / 16, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(i) * size.width / 16, y: 0, width: size.width / 16 + 1, height: size.height))
            }
        }
        guard let cg = base.cgImage else { return base }
        return UIImage(cgImage: cg, scale: 1, orientation: .right)
    }

    private static func extractFileNameAndMimeType(fromURL url: NSURL?) -> (NSString?, String?) {
        guard let url = url else { return (nil, nil) }
        // Get mime type and file name
        let urlResourceValues = try? url.resourceValues(forKeys: [.typeIdentifierKey, .nameKey])
        let uti = urlResourceValues?[.typeIdentifierKey] as? NSString
        let fname = urlResourceValues?[.nameKey] as? NSString
        var mimeType: String?
        if let uti = uti {
            // Convert UTI string like 'public.jpeg' to MIME type like 'image/jpeg'
            let unmanaged = UTTypeCopyPreferredTagWithClass(uti as CFString, kUTTagClassMIMEType)
            mimeType = unmanaged?.takeRetainedValue() as String?
        } else {
            mimeType = nil
        }
        return (fname, mimeType)
    }

    private func didPickImage(_ picker: UIImagePickerController?,
                              didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any], camera: Bool? = nil) {
        let isCamera = camera ?? (self.pickerController.sourceType == .camera)
        let picked = (info[self.pickerController.allowsEditing ? .editedImage : .originalImage] as? UIImage)
            ?? (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage)
        // LINIA2_CAMERA: снимок камеры — всегда перерисовка в 8-битный sRGB (см. linia2Normalized); прочие — как раньше,
        // а если fixedOrientation не справился (HDR / 16 бит) — тоже перерисовка, а не молчаливый отказ.
        let fixed: UIImage? = isCamera ? nil : picked?.fixedOrientation()
        guard let src = picked, let image = fixed ?? ImagePicker.linia2Normalized(src) else {
            Linia2LaunchLog.shared.step("photo-pick-fail", ["camera": isCamera ? 1 : 0, "img": picked == nil ? 0 : 1])
            if picked != nil { DispatchQueue.main.async { UiUtils.showToast(message: "Не удалось обработать фото.") } }
            return self.pickerController(picker, didSelect: nil)
        }

        var mimeType: String? = nil
        var fname: NSString? = nil
        if isCamera {
            // Images taken by camera won't have .imageURL or .referenceURL.
            // LINIA2_CAMERA: JPEG (PNG снимка камеры — в 10 раз больше) и имя файла всегда (без EXIF имя было пустым —
            // сервер не принимает выгрузку без имени файла).
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            fname = "IMG-\(f.string(from: Date())).jpg" as NSString
            mimeType = "image/jpeg"
            Linia2LaunchLog.shared.step("photo-camera", ["w": Int(image.size.width * image.scale), "h": Int(image.size.height * image.scale)])
        } else {
            let imageUrl = info[.imageURL] as? NSURL

            let result = ImagePicker.extractFileNameAndMimeType(fromURL: imageUrl)
            fname = result.0
            mimeType = result.1
        }

        self.pickerController(picker, didSelect: .image(image, mimeType, fname as String?))
    }

    private func didPickVideo(_ picker: UIImagePickerController,
                              didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        // Currently UIImagePickerController compresses and converts the original video into quicktime
        // which makes the original video file name, size, format and dimensions unavailable.
        // Sometimes it may break some of these params, e.g. dimensions.
        // To be able to access the original video file, we need to use PHPickerViewController.
        // TODO: switch to PHPickerViewController.
        let videoUrl = info[.mediaURL] as? NSURL
        let result = ImagePicker.extractFileNameAndMimeType(fromURL: videoUrl)
        let fname = result.0
        let mimeType = result.1

        self.pickerController(picker, didSelect: .video(videoUrl as URL?, mimeType, fname as String?))
    }
}

extension ImagePicker: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.pickerController(picker, didSelect: nil/*, mimeType: nil, fileName: nil*/)
        picker.dismiss(animated: true, completion: nil)
    }

    public func imagePickerController(_ picker: UIImagePickerController,
                                      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        guard !picker.isBeingDismissed else {
            // Prevent ImagePicker from showing the image multiple times.
            return
        }
        guard let mediaType = info[.mediaType] as? String else {
            return self.pickerController(picker, didSelect: nil)
        }
        switch mediaType as CFString {
        case kUTTypeImage:
            didPickImage(picker, didFinishPickingMediaWithInfo: info)
            break
        case kUTTypeMovie:
            didPickVideo(picker, didFinishPickingMediaWithInfo: info)
            break
        default:
            return self.pickerController(picker, didSelect: nil/*, mimeType: nil, fileName: nil*/)
        }
    }
}
