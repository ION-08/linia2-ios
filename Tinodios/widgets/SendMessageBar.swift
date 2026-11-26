//
//  SendMessageBar.swift
//  Tinodios
//
//  Copyright © 2019-2022 Tinode LLC. All rights reserved.
//

import UIKit

enum AudioBarAction {
    case start
    case stopAndSend
    case stopAndDelete
    case lock
    case stopRecording
    case pauseRecording
    case playbackStart
    case playbackPause
    case playbackReset
}

public enum PendingPreviewAction {
    case none
    case reply
    case edit
}

protocol SendMessageBarDelegate: AnyObject {
    func sendMessageBar(sendText: String)
    func sendMessageBar(attachment: Bool)
    func sendMessageBar(textChangedTo text: String)
    func sendMessageBar(enablePeersMessaging: Bool)
    func sendMessageBar(recordAudio: AudioBarAction)
}

class SendMessageBar: UIView {
    enum AudioBarState {
        case longInitial // Initial locked state: recording audio.
        case longPlayback // Locked state: playing back the recording
        case longPaused // Locked state: playback paused
        case short // Not locked state: recording.
        case hidden
    }

    // MARK: - Constants

    private enum Constants {
        static let maxLines: CGFloat = 4
        static let inputFieldInsetLeading: CGFloat = 4
        static let inputFieldInsetTrailing: CGFloat = 40
        static let peerMessagingDisabledHeight: CGFloat = 30
        static let kPreviewCancelButtonMaxWidth: CGFloat = 36

        static let kSendButtonPointsNormal: CGFloat = 26
        static let kSendButtonPointsPressed: CGFloat = 44
        static let kButtonSizeNormal: CGFloat = 32
        // Size of the activated audio recording button.
        static let kSendButtonSizePressed: CGFloat = 54

        // Initial input text weight.
        static let kInitialInputFieldHeight: CGFloat = 40

        static var kSendButtonImageWave: UIImage { SendMessageBar.linia2CameraMode ? kSendButtonImageCamera : L2.circleIcon("mic.fill", diameter: 32, fill: L2.accent, tint: L2.onAccent) }
        static var kSendButtonImageCamera: UIImage { L2.circleIcon("video.fill", diameter: 32, fill: L2.accent, tint: L2.onAccent, symbolSize: 13) }
        static var kSendButtonImageWavePressed: UIImage { L2.circleIcon("mic.fill", diameter: 54, fill: L2.accent, tint: L2.onAccent) }
        static var kSendButtonImageArrow: UIImage { L2.circleIcon("paperplane.fill", diameter: 32, fill: L2.accent, tint: L2.onAccent, symbolSize: 14) }
        static var kSendButtonImageEditCheck: UIImage? { L2.circleIcon("checkmark", diameter: 32, fill: L2.accent, tint: L2.onAccent) }
        static let kWaveInsetsShort = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 88)
        static let kWaveInsetsLong = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 52)
    }

    // MARK: Action delegate

    weak var delegate: (SendMessageBarDelegate & PendingMessagePreviewDelegate)?

    // MARK: IBOutlets

    @IBOutlet weak var attachButton: UIButton!
    @IBOutlet weak var sendButton: UIButton!
    @IBOutlet weak var sendButtonSize: NSLayoutConstraint!
    @IBOutlet weak var sendButtonHorizontal: NSLayoutConstraint!
    @IBOutlet weak var sendButtonVertical: NSLayoutConstraint!

    // Sliders for locking and deleting audio recording.
    @IBOutlet weak var verticalSliderView: UIView!
    @IBOutlet weak var horizontalSliderView: UIView!

    // Constraints.
    private var sendButtonConstrains: CGPoint!
    // Position in SendMessageBar coordinates.
    private var sendButtonLocation: CGPoint!

    @IBOutlet weak var inputField: PlaceholderTextView!
    @IBOutlet weak var inputFieldHeight: NSLayoutConstraint!

    // Overlay for writing disabled. Hidden by default.
    @IBOutlet weak var allDisabledView: UIView!
    // Message "Peer's messaging is disabled. Enable". Not installed by default.
    @IBOutlet weak var peerMessagingDisabledView: UIStackView!
    @IBOutlet weak var peerMessagingDisabledHeight: NSLayoutConstraint!
    @IBOutlet weak var previewView: RichTextView!
    @IBOutlet weak var previewViewHeight: NSLayoutConstraint!

    @IBOutlet weak var audioView: UIView!
    @IBOutlet weak var deleteAudioButton: UIButton!
    @IBOutlet weak var deleteAudioButtonWidth: NSLayoutConstraint!
    @IBOutlet weak var stopAudioRecordingButton: UIButton!
    @IBOutlet weak var playAudioButton: UIButton!
    @IBOutlet weak var pauseAudioButton: UIButton!

    @IBOutlet weak var audioDurationLabel: UILabel!
    @IBOutlet weak var audioDurationLabelHeight: NSLayoutConstraint!
    @IBOutlet weak var audioViewHeight: NSLayoutConstraint!
    @IBOutlet weak var wavePreviewImageView: WaveImageView!
    @IBOutlet weak var wavePreviewLeading: NSLayoutConstraint! // 40 <-> 8

    // MARK: Properties
    private var audioLocked: Bool = false
    /// LINIA2: кнопка записи — камера (видео-кружок) вместо микрофона; переключается нажатием.
    static var linia2CameraMode: Bool {
        get { Linia2Round.cameraMode }
        set { Linia2Round.cameraMode = newValue }
    }
    private var linia2RoundCancelled = false

    private var pendingPreviewAction: PendingPreviewAction = .none
    public var pendingPreviewText: NSAttributedString? {
        get { return previewView.attributedText.length != .zero ? previewView.attributedText : nil }
        set { previewView.attributedText = newValue }
    }

    private var sendButtonTextImage: UIImage? {
        switch pendingPreviewAction {
        case .edit:
            return Constants.kSendButtonImageEditCheck
        default:
            return Constants.kSendButtonImageArrow
        }
    }

    var previewMaxWidth: CGFloat {
        return inputField.frame.width - Constants.kPreviewCancelButtonMaxWidth
    }

    // MARK: IBActions

    @IBAction func attach(_ sender: UIButton) {
        inputField.resignFirstResponder()

        let alert = UIAlertController(title: Linia2Texts.t("Attachment"), message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: Linia2Texts.t("Image / Video"), style: .default, handler: { _ in
            self.delegate?.sendMessageBar(attachment: false)
        }))
        alert.addAction(UIAlertAction(title: Linia2Texts.t("File"), style: .default, handler: { _ in
            self.delegate?.sendMessageBar(attachment: true)
        }))
        alert.addAction(UIAlertAction(title: Linia2Texts.t("Cancel"), style: .cancel, handler: nil))
        self.window?.rootViewController?.present(alert, animated: true, completion: nil)
    }

    @IBAction func send(_ sender: UIButton) {
        let msg = inputField.actualText.trimmingCharacters(in: .whitespacesAndNewlines)

        if audioLocked {
            self.delegate?.sendMessageBar(recordAudio: .stopAndSend)
            audioLocked = false
            showAudioBar(.hidden)
        } else if !msg.isEmpty {
            delegate?.sendMessageBar(sendText: msg)
            inputField.text = nil
            textViewDidChange(inputField)
        } else if Linia2Round.featureOn && pendingPreviewAction != .edit {
            // LINIA2: нажатие без текста — микрофон ⇄ камера (кружок).
            SendMessageBar.linia2CameraMode.toggle()
            linia2UpdateRecordButton()
            L2.haptic()
        }
    }

    func linia2UpdateRecordButton() {
        let cam = SendMessageBar.linia2CameraMode
        sendButton.accessibilityValue = cam ? "камера" : "микрофон"
        if inputField.actualText.isEmpty && !audioLocked {
            sendButton.setImage(Constants.kSendButtonImageWave, for: .normal)
            sendButton.accessibilityLabel = cam ? "Записать кружок" : "Записать голосовое"
        } else {
            sendButton.accessibilityLabel = "Отправить"
        }
    }

    @IBAction func deleteRecording(_ sender: Any) {
        wavePreviewImageView.reset()
        showAudioBar(.hidden)
        audioLocked = false
        self.delegate?.sendMessageBar(recordAudio: .stopAndDelete)
    }

    @IBAction func stopRecording(_ sender: Any) {
        showAudioBar(.longPaused)
        self.delegate?.sendMessageBar(recordAudio: .stopRecording)
    }

    @IBAction func playRecording(_ sender: Any) {
        showAudioBar(.longPlayback)
        self.delegate?.sendMessageBar(recordAudio: .playbackStart)
    }

    @IBAction func pausePlayback(_ sender: Any) {
        showAudioBar(.longPaused)
        self.delegate?.sendMessageBar(recordAudio: .playbackPause)
    }

    // Handle audio recorder button swipes and presses.
    @IBAction func longPressed(sender: UILongPressGestureRecognizer) {
        if !inputField.actualText.isEmpty || audioLocked {
            // Cancel long press.
            sender.isEnabled = false
            sender.isEnabled = true
            return
        }

        // LINIA2: режим камеры — удержание записывает видео-кружок, смахивание влево — отмена.
        if SendMessageBar.linia2CameraMode && Linia2Round.featureOn {
            let vc = delegate as? MessageViewController
            switch sender.state {
            case .began:
                linia2RoundCancelled = false
                self.sendButtonLocation = sender.location(in: self)
                vc?.linia2RoundGesture(.began, cancel: false)
            case .changed:
                if !linia2RoundCancelled, sender.location(in: self).x - sendButtonLocation.x < -90 {
                    linia2RoundCancelled = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    vc?.linia2RoundGesture(.changed, cancel: true)
                }
            case .ended:
                vc?.linia2RoundGesture(.ended, cancel: linia2RoundCancelled)
            case .cancelled, .failed:
                vc?.linia2RoundGesture(.cancelled, cancel: true)
            default:
                break
            }
            return
        }

        switch sender.state {
        case .began:
            let loc = sender.location(in: self)
            self.sendButtonConstrains = CGPoint(x: self.sendButtonHorizontal.constant, y: self.sendButtonVertical.constant)
            self.sendButtonLocation = CGPoint(x: loc.x, y: loc.y)
            UIView.animate(withDuration: 0.2, delay: 0, options: UIView.AnimationOptions.curveEaseIn, animations: {
                self.showAudioBar(.short)
                self.sendButtonSize.constant = Constants.kSendButtonSizePressed
                self.sendButton.setImage(Constants.kSendButtonImageWavePressed, for: .normal)
                self.verticalSliderView.isHidden = false
                self.horizontalSliderView.isHidden = false
                self.layoutIfNeeded()
            }, completion: nil)
            self.delegate?.sendMessageBar(recordAudio: .start)
        case .ended:
            if inputField.actualText.isEmpty && !audioLocked {
                audioBarState(.stopAndDelete)
                self.delegate?.sendMessageBar(recordAudio: .stopAndSend)
            }
        case .cancelled:
            break
        case .changed:
            // Constrain movements to either strictly horizontal or strictly vertical.
            let loc = sender.location(in: self)
            // dX and dY are negative: the movement is up and to the left.
            var dX = min(0, loc.x - sendButtonLocation.x)
            var dY = min(0, loc.y - sendButtonLocation.y)

            if abs(dX) > abs(dY) {
                // Horizontal move.
                dY = 0
            } else {
                // Vertical move.
                dX = 0
            }
            if dX < -60 {
                // User swiped to "Trash".
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                audioLocked = false
                sender.isEnabled = false
                audioBarState(.stopAndDelete)
                self.delegate?.sendMessageBar(recordAudio: .stopAndDelete)
                sender.isEnabled = true
            } else if dY < -60 {
                // User swiped to "Lock".
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                audioLocked = true
                sender.isEnabled = false
                audioBarState(.lock)
                sender.isEnabled = true
                self.layoutIfNeeded()
            } else {
                self.sendButtonHorizontal.constant = sendButtonConstrains.x + dX
                self.sendButtonVertical.constant = sendButtonConstrains.y + dY
            }
        default:
            break
        }
    }

    @IBAction func enablePeerMessagingClicked(_ sender: Any) {
        self.delegate?.sendMessageBar(enablePeersMessaging: true)
    }

    @IBAction func cancelPreviewClicked(_ sender: Any) {
        self.delegate?.dismissPendingMessagePreview()
    }

    // MARK: - Private properties

    private var inputFieldMaxHeight: CGFloat = 120

    // MARK: - Initializers

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        loadNib()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        loadNib()
    }

    // This is needed for proper calculation of size from constraints.
    override var intrinsicContentSize: CGSize {
        return CGSize.zero
    }

    // LINIA2_ABOVE_TABBAR: пока клавиатура скрыта, под полем ввода — прозрачный отступ высотой с нижнее меню;
    // меню (в окне приложения) видно сквозь него, нажатия в отступе проходят к меню.
    private var linia2BottomConstraint: NSLayoutConstraint?
    private var linia2Reserve: CGFloat = 0
    static var linia2TabBarReserve: CGFloat = 0   // задаёт Linia2TabBarController (0 — меню не показываем)

    override func didMoveToWindow() {
        super.didMoveToWindow()
        linia2ApplyReserve(keyboardShown: false)
    }

    func linia2ApplyReserve(keyboardShown: Bool) {
        let base = SendMessageBar.linia2TabBarReserve
        let want = (keyboardShown || base <= 0) ? 0 : base + (window?.safeAreaInsets.bottom ?? 0)
        backgroundColor = want > 0 ? .clear : L2.background
        guard want != linia2Reserve else { return }
        linia2Reserve = want
        linia2BottomConstraint?.constant = -want
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    @objc private func linia2KeyboardFrame(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let screenH = window?.bounds.height ?? UIScreen.main.bounds.height
        // Настоящая клавиатура заметно выше самой панели ввода.
        let shown = n.name != UIResponder.keyboardWillHideNotification && end.minY < screenH - 1 && end.height > bounds.height - linia2Reserve + 120
        linia2ApplyReserve(keyboardShown: shown)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if linia2Reserve > 0 && point.y > bounds.height - linia2Reserve { return nil }   // отступ — сквозь к меню
        return super.hitTest(point, with: event)
    }

    // MARK: - Configuration

    private func loadNib() {
        let nib = UINib(nibName: "SendMessageBar", bundle: Bundle(for: type(of: self)))
        let nibView = nib.instantiate(withOwner: self, options: nil).first as! UIView
        nibView.backgroundColor = L2.background
        nibView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nibView)
        NSLayoutConstraint.activate([
            nibView.topAnchor.constraint(equalTo: topAnchor),
            nibView.rightAnchor.constraint(equalTo: rightAnchor),
            nibView.leftAnchor.constraint(equalTo: leftAnchor)
            ])
        let bottom = nibView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.isActive = true
        linia2BottomConstraint = bottom
        NotificationCenter.default.addObserver(self, selector: #selector(linia2KeyboardFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(linia2KeyboardFrame(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        configure()
    }

    private func configure() {
        // LINIA2_UITEST_IDS: идентификаторы для автотестов.
        attachButton.accessibilityIdentifier = "l2.chat.attach"
        attachButton.accessibilityLabel = "Вложение"
        sendButton.accessibilityIdentifier = "l2.chat.send"
        sendButton.accessibilityLabel = "Отправить"
        inputField.accessibilityIdentifier = "l2.chat.input"
        attachButton.isHidden = !Linia2Config.shared.feature("attachments")   // LINIA2: флаг вложений
        horizontalSliderView.alpha = 0.9
        verticalSliderView.alpha = 0.9

        inputField.layer.borderWidth = 0
        inputField.layer.cornerRadius = L2.r("input", 18)
        inputField.autoresizingMask = [.flexibleHeight]
        inputField.delegate = self
        inputField.textContainerInset = UIEdgeInsets(
            top: inputField.textContainerInset.top,
            left: Constants.inputFieldInsetLeading,
            bottom: inputField.textContainerInset.bottom,
            right: Constants.inputFieldInsetTrailing)

        if let font = inputField.font {
            inputFieldMaxHeight = font.lineHeight * Constants.maxLines
        }

        sendButton.isEnabled = true
        toggleNotAvailableOverlay(visible: false)
        togglePeerMessagingDisabled(visible: false)
        togglePendingPreviewBar(withMessage: nil)

        showAudioBar(.hidden)
        linia2Style(container: self)
        linia2UpdateRecordButton()
    }

    // MARK: - Subviews handling

    public func toggleNotAvailableOverlay(visible: Bool) {
        allDisabledView.isHidden = !visible
        isUserInteractionEnabled = !visible
    }

    public func togglePeerMessagingDisabled(visible: Bool) {
        peerMessagingDisabledView.isHidden = !visible
        peerMessagingDisabledView.isUserInteractionEnabled = visible
        peerMessagingDisabledHeight.constant = visible ? Constants.peerMessagingDisabledHeight : 0
    }

    public func togglePendingPreviewBar(withMessage message: NSAttributedString?, onAction action: PendingPreviewAction = .none) {
        if let message = message, let delegate = self.delegate {
            let textbounds = delegate.pendingPreviewMessageSize(forMessage: message)
            previewViewHeight.constant = textbounds.height
            pendingPreviewText = message
            previewView.isHidden = false
            pendingPreviewAction = action
        } else {
            previewViewHeight.constant = .zero
            pendingPreviewText = nil
            previewView.l2AccessibilityText = nil
            previewView.isHidden = true
            pendingPreviewAction = .none
        }
        textViewDidChange(inputField)
    }

    // MARK: - Audio playback and recording

    // Un-locked audio recording, show duration label & wave.
    func showAudioBar(_ state: AudioBarState) {
        if state == .hidden || state == .short {
            deleteAudioButton.show(false)
            playAudioButton.show(false)
            pauseAudioButton.show(false)
            stopAudioRecordingButton.show(false)
        } else {
            // Long bar
            deleteAudioButton.show(true, dimension: Constants.kButtonSizeNormal)
            switch state {
            case .longInitial:
                playAudioButton.show(false)
                pauseAudioButton.show(false)
                stopAudioRecordingButton.show(true, dimension: Constants.kButtonSizeNormal)
            case .longPlayback:
                playAudioButton.show(false)
                pauseAudioButton.show(true, dimension: Constants.kButtonSizeNormal)
                stopAudioRecordingButton.show(false)
            case .longPaused:
                playAudioButton.show(true, dimension: Constants.kButtonSizeNormal)
                pauseAudioButton.show(false)
                stopAudioRecordingButton.show(false)
            default:
                break
            }
        }

        if state == .hidden {
            // Bar hidden.
            inputField.show(true, height: Constants.kInitialInputFieldHeight)
            attachButton.isHidden = !Linia2Config.shared.feature("attachments")   // LINIA2: флаг вложений
            // audioDurationLabel.show(false)
            audioDurationLabel.isHidden = true
            wavePreviewImageView.isHidden = true
            wavePreviewImageView.reset()
            audioViewHeight.constant = CGFloat.leastNonzeroMagnitude
            audioView.isHidden = true
            sendButton.setImage(Constants.kSendButtonImageWave, for: .normal)
        } else {
            // Long or short bar visible.
            inputField.resignFirstResponder() // Otherwise it does not hide
            inputField.show(false)
            attachButton.isHidden = true
            audioDurationLabel.isHidden = false
            audioDurationLabel.show(true, height: 40)
            audioDurationLabel.sizeToFit()
            audioView.isHidden = false
            audioViewHeight.constant = 40
            wavePreviewImageView.isHidden = false
            if state == .short {
                wavePreviewLeading.constant = 8
                wavePreviewImageView.waveInsets = Constants.kWaveInsetsShort
            } else {
                wavePreviewLeading.constant = 40
                wavePreviewImageView.waveInsets = Constants.kWaveInsetsLong
            }
        }

        audioView.setNeedsLayout()
    }

    func audioBarState(_ state: AudioBarAction) {
        UIView.animate(withDuration: 0.15, delay: 0, options: UIView.AnimationOptions.curveEaseIn, animations: {
            self.sendButtonHorizontal.constant = self.sendButtonConstrains.x
            self.sendButtonVertical.constant = self.sendButtonConstrains.y
            self.verticalSliderView.isHidden = true
            self.horizontalSliderView.isHidden = true
            self.sendButtonSize.constant = Constants.kButtonSizeNormal
            if state == .lock {
                self.sendButton.setImage(self.sendButtonTextImage, for: .normal)
                self.showAudioBar(.longInitial)
            } else {
                self.sendButton.setImage(Constants.kSendButtonImageWave, for: .normal)
                self.showAudioBar(.hidden)
            }
            self.layoutIfNeeded()
        }, completion: nil)
    }

    func audioPlaybackPreview(_ data: Data, duration: TimeInterval) {
        wavePreviewImageView?.playbackPreview(data, duration: duration)
    }

    func audioUpdateAmplitude(amplitude: Float, atTime: TimeInterval) {
        wavePreviewImageView?.put(amplitude: amplitude, atTime: atTime)
    }

    func audioPlaybackAction(_ state: AudioBarAction) {
        switch state {
        case .playbackStart:
            playAudioButton.show(false)
            pauseAudioButton.show(true, dimension: Constants.kButtonSizeNormal)
            wavePreviewImageView.play()
        case .playbackReset:
            wavePreviewImageView.reset()
            playAudioButton.show(true, dimension: Constants.kButtonSizeNormal)
            pauseAudioButton.show(false)
        case .playbackPause:
            wavePreviewImageView.pause(rewind: false)
            playAudioButton.show(true, dimension: Constants.kButtonSizeNormal)
            pauseAudioButton.show(false)
        default:
            break
        }
    }
}

extension SendMessageBar: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        delegate?.sendMessageBar(textChangedTo: textView.text)

        if inputField.actualText.isEmpty {
            inputFieldHeight.constant = Constants.kInitialInputFieldHeight

            self.sendButton.setImage(Constants.kSendButtonImageWave, for: .normal)
            linia2UpdateRecordButton()
        } else {
            let size = CGSize(width: frame.width - Constants.inputFieldInsetLeading - Constants.inputFieldInsetTrailing, height: .greatestFiniteMagnitude)
            let fittingSize = inputField.sizeThatFits(size)
            if fittingSize.height <= inputFieldMaxHeight {
                inputFieldHeight.constant = fittingSize.height + 2 // Not sure why but it seems to be off by 2
            }

            self.sendButton.setImage(self.sendButtonTextImage, for: .normal)
            linia2UpdateRecordButton()
        }
    }
}
