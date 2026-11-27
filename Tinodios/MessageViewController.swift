//
//  MessageViewController.swift
//
//  Copyright © 2019-2025 Tinode LLC. All rights reserved.
//

import MobileVLCKit
import UIKit
import TinodeSDK
import TinodiosDB

protocol MessageDisplayLogic: AnyObject {
    func switchTopic(topic: String?)
    func updateTitleBar(pub: TheCard?, online: Bool?, deleted: Bool)
    func setOnline(online: Bool?)
    func runTypingAnimation()
    func displayChatMessages(messages: [StoredMessage], _ scrollToMostRecentMessage: Bool)
    func reloadAllMessages()
    func reloadMessages(fromSeqId loId: Int, toSeqId hiId: Int)
    func updateProgress(forMsgId msgId: Int64, progress: Float)
    func applyTopicPermissions(withError: Error?)
    func displayPinnedMessages(pins: [Int], selected: Int)
    func reloadPinned(forSeq: Int)
    func endRefresh()
    func dismissVC()
    // Display or dismiss preview (e.g. reply preview) in the send message bar.
    func togglePreviewBar(with preview: NSAttributedString?, onAction action: PendingPreviewAction)
}

// Pending message is the one the user is either  replying to or forwarding.
protocol PendingMessagePreviewDelegate: AnyObject {
    // Calculates size for preview attributed string.
    func pendingPreviewMessageSize(forMessage msg: NSAttributedString) -> CGSize
    // Cancels preview.
    func dismissPendingMessagePreview()
}

class MessageViewController: UIViewController {
    // Other controllers may send these notification to MessageViewController which will execute corresponding send message action.
    public static let kNotificationSendAttachment = "SendAttachment"

    // MARK: static parameters
    enum Constants {
        /// Size of the avatar in the nav bar in small state.
        static let kNavBarAvatarSmallState: CGFloat = 32

        /// Size of the avatar in group topics.
        static let kAvatarSize: CGFloat = 30

        static let kProgressViewHeight: CGFloat = 30
        static let kPinnedMessagesViewHeight: CGFloat = 64   // LINIA2: + строка «📌 Закреплённое K из N»

        // Size of delivery marker (checkmarks etc)
        static let kDeliveryMarkerSize: CGFloat = 16
        // Horizontal space between delivery marker and the edge of the message bubble
        static let kDeliveryMarkerPadding: CGFloat = 10
        // Horizontal space between delivery marker and timestamp
        static let kTimestampPadding: CGFloat = 0
        // Approximate width of the timestamp
        static let kTimestampWidth: CGFloat = 50
        // Approximate width of edited marker
        static let kEditedMarkerWidth: CGFloat = 70
        // Horizontal space between timestamp and edited marker
        static let kEditedMarkerPadding: CGFloat = 3
        // Progress bar paddings.
        static let kProgressBarLeftPadding: CGFloat = 10
        static let kProgressBarRightPadding: CGFloat = 25

        // Light/dark gray color: outgoing messages
        static var kOutgoingBubbleColorLight: UIColor { L2.accentStrong }
        static var kOutgoingBubbleColorDark: UIColor { L2.accentStrong }  // LINIA2_COLORS: свои — цвет акцента
        // And corresponding text color
        static let kOutgoingTextColorLight = UIColor.darkText
        static var kOutgoingTextColorDark: UIColor { UIColor.white }
        // Bright/dark green color
        static var kIncomingBubbleColorLight: UIColor { L2.bubbleIn }
        static var kIncomingBubbleColorDark: UIColor { L2.bubbleIn }
        // And corresponding font color
        static var kIncomingTextColorLight: UIColor { L2.textPrimary }
        static var kIncomingTextColorDark: UIColor { L2.textPrimary }
        // Meta-messages, such as "Content deleted".
        static var kDeletedMessageBubbleColorLight: UIColor { L2.surface }
        static var kDeletedMessageBubbleColorDark: UIColor { L2.surface }
        static let kDeletedMessageTextColor = UIColor.gray

        static let kContentFont = UIFont.preferredFont(forTextStyle: .body)

        static let kSenderNameFont = UIFont.l2Capped(.caption2)
        static let kTimestampFont = UIFont.l2Capped(.caption2)
        static let kSenderNameLabelHeight: CGFloat = 16
        static let kNewDateFont = UIFont.boldSystemFont(ofSize: 10)
        static let kNewDateLabelHeight: CGFloat = 24
        // Vertical spacing between messages from the same user (LINIA2: 4–6 pt, как в Telegram)
        static let kVerticalCellSpacing: CGFloat = 5
        // Additional vertical spacing between messages from different users (LINIA2: итого 10–12 pt).
        static let kAdditionalP2PVerticalCellSpacing: CGFloat = 6
        static let kMinimumCellWidth: CGFloat = 94
        static let kMinimumEditedCellWidth: CGFloat = 150
        // This is the space between the other side of the message and the edge of screen.
        // I.e. for incoming messages the space between the message and the *right* edge, for
        // outgoing between the message and the left edge.
        static let kFarSideHorizontalSpacing: CGFloat = 45

        // Insets around collection view, i.e. main view padding (LINIA2: пузырь в 11 pt от края экрана)
        static let kCollectionViewInset = UIEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        // LINIA2: максимальная ширина пузыря — доля ширины экрана.
        static let kMaxBubbleWidthFraction: CGFloat = 0.78
        // LINIA2: системные строки (исчезающие сообщения, снимок экрана) — компактная плашка по центру.
        static let kServiceContentInset = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        static var kServiceFont: UIFont { UIFont.preferredFont(forTextStyle: .caption1) }

        // Insets for the message bubble relative to collectionView: bubble should not touch the sides of the screen.
        static let kIncomingContainerPadding = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: Constants.kFarSideHorizontalSpacing)
        static let kOutgoingContainerPadding = UIEdgeInsets(top: 0, left: Constants.kFarSideHorizontalSpacing, bottom: 0, right: 0)

        // Insets around content inside the message bubble.
        // Дизайн: пузырь без «хвостика» — поля по 12 pt с обеих сторон, как в Telegram (было 18/14 — текст «уезжал» вправо).
        static let kIncomingMessageContentInset = UIEdgeInsets(top: 4, left: 12, bottom: 13, right: 12)
        static let kOutgoingMessageContentInset = UIEdgeInsets(top: 4, left: 12, bottom: 13, right: 12)
        // LINIA2 (дизайн, как в вебе): время на одной строке с текстом — поля сверху и снизу равные,
        // текст по центру пузыря; время не влезло — оно под текстом справа (поля kOutgoing/kIncoming…).
        static let kInlineTimeContentInset = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        static let kDeletedMessageContentInset = UIEdgeInsets(top: 4, left: 14, bottom: 0, right: 14)
        // Дизайн: фото/видео без подписи — почти до края пузыря (как в Telegram), время — плашкой на снимке.
        static let kL2MediaInset = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)

        // Carve out for timestamp and delivery marker in the bottom-right corner.
        static let kIncomingMetadataCarveout = "     "
        static let kOutgoingMetadataCarveout = "       "

        // Thresholds for tracking update batch stats/UI refresh.
        // When too many messages (batch) come in a quick succession,
        // we refresh the UI in full in order to avoid UI glitches.
        static let kUpdateBatchFullRefreshThreshold = 5
        // Max time difference between successive messages to count them as one batch.
        static let kUpdateBatchTimeDeltaThresholdMs: Int64 = 300

        // Minimum and manimum duration of an audio recording in ms.
        static let kMinDuration = 3_000
        static let kMaxDuration = 600_000

        // Call type identifiers.
        static let kAudioOnlyCall = 1
        static let kVideoCall = 2

        // Maximum size of the video preview poster in bytes.
        static let kMaxPosterSize = 1024 * 8
    }

    /// The `sendMessageBar` is used as the `inputAccessoryView` in the view controller.
    lazy var sendMessageBar: SendMessageBar = {
        let view = SendMessageBar()
        view.autoresizingMask = .flexibleHeight
        return view
    }()

    /// The `forwardMessageBar` is used as the `inputAccessoryView` in the view controller
    /// (for forwarded messages only).
    lazy var forwardMessageBar: ForwardMessageBar = {
        let view = ForwardMessageBar()
        view.autoresizingMask = .flexibleHeight
        return view
    }()

    /// Avatar in the NavBar
    lazy var navBarAvatarView: AvatarWithOnlineIndicator = {
        let avatarIcon = AvatarWithOnlineIndicator()
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(navBarAvatarTapped(tapGestureRecognizer:)))
        avatarIcon.isUserInteractionEnabled = true
        avatarIcon.addGestureRecognizer(tapGestureRecognizer)
        return avatarIcon
    }()

    /// Call button in NavBar
    lazy var navBarCallBtn: UIBarButtonItem = {
        let b = UIBarButtonItem(image: UIImage(systemName: "phone", withConfiguration:UIImage.SymbolConfiguration(pointSize: 16, weight: .light)), style: .plain, target: self, action: #selector(navBarCallTapped(sender:)))
        b.accessibilityIdentifier = "l2.chat.call"   // LINIA2_UITEST_IDS
        b.accessibilityLabel = "Позвонить"
        return b
    }()

    /// LINIA2: отдельная кнопка видеозвонка в шапке.
    lazy var navBarVideoBtn: UIBarButtonItem = {
        let b = UIBarButtonItem(image: L2.symbol("video", 19, .regular), style: .plain, target: self, action: #selector(navBarVideoCallTapped(sender:)))
        b.accessibilityIdentifier = "l2.chat.video"
        b.accessibilityLabel = "Видеозвонок"
        return b
    }()

    /// Pointer to the view holding messages.
    weak var collectionView: MessageView!
    private var collectionViewBottomAnchor: NSLayoutConstraint!
    /// Button [GO to latest message].
    private weak var goToLatestButton: UIButton!
    private var goToLatestButtonBottomAnchor: NSLayoutConstraint!


    var interactor: (MessageBusinessLogic & MessageDataStore)?
    let refreshControl = UIRefreshControl()

    // MARK: properties

    var topicName: String? {
        didSet {
            topicType = Tinode.topicTypeByName(name: self.topicName)
            // Needed in order to get sender's avatar and display name
            let tinode = Cache.tinode
            topic = tinode.getTopic(topicName: topicName!) as? DefaultComTopic
            if topic == nil {
                topic = tinode.newTopic(for: topicName!) as? DefaultComTopic
            }
        }
    }
    var topicType: TopicType?
    var myUID: String?
    var topic: DefaultComTopic?
    // TODO: this is ugly. Move this to MVC+SendMessageBarDelegate.swift
    var imagePicker: ImagePicker?

    // Messages to be displayed
    var messages: [Message] = []
    // LINIA2: реакции — seq сообщения → эмодзи → uid; свои реакции → seq сообщения-реакции.
    var linia2Reactions: [Int: [String: [String]]] = [:]
    var linia2MyReactions: [Int: [String: Int]] = [:]
    // For updating individual messages, we need:
    // * Tinode sequence id -> messages offset.
    var messageSeqIdIndex: [Int: Int] = [:]
    // * Database message id -> message offset.
    var messageDbIdIndex: [Int64: Int] = [:]

    // Pinned messages.
    var pinnedMessageSeqs: [Int] = []
    var pinnedSelectionIndex: Int = 0

    var isInitialLayout = true

    // LINIA2: подпись «Исчезающие сообщения: 20 с после прочтения» над полем ввода (Linia2Burn.swift).
    var linia2BurnLabel: UILabel?
    var linia2BurnLabelBottom: NSLayoutConstraint?
    var linia2LastScreenshotNote: Date?
    var linia2BurnTimer: Timer?
    var linia2BurnFading = Set<String>()
    // LINIA2: поиск по чату и свайп назад при своей кнопке «Назад» (Linia2ChatChrome.swift).
    var linia2Search: Linia2ChatSearch?
    var linia2SavedPopDelegate: UIGestureRecognizerDelegate?

    // Highlight this cell when scroll finishes (after the user tapped on a quote or a pinned message).
    var highlightCellAtPathAfterScroll: IndexPath?

    // Size of the present update batch.
    var updateBatchSize = 0
    // Last message received timestamp - for tracking batches.
    var lastMessageReceived = Date.distantPast

    // The two below indicate whether to send typing notifications and read receipts.
    // Determined by the user specified account notifications settings.
    internal var sendTypingNotifications = false
    internal var sendReadReceipts = false

    internal var textSizeHelper = TextSizeHelper()

    // Currently playing or paused media player.
    internal var currentAudioPlayer: VLCMediaPlayer?

    // Max inband attachment/entity size.
    private var maxInbandSize: Int64 {
        // Attachment size less base64 expansion and overhead.
        return Cache.tinode.getServerLimit(for: Tinode.kMaxMessageSize, withDefault: MessageViewController.kMaxInbandAttachmentSize) * 3 / 4 - 1024
    }

    // MARK: initializers

    init() {
        super.init(nibName: nil, bundle: nil)
        self.setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setup()
    }

    private func addAppStateObservers() {
        // App state observers.
        NotificationCenter.default.addObserver(
            self, selector: #selector(self.appGoingInactive),
            name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(self.appBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(self.deviceRotated),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        // LINIA2: снимок экрана в режиме самоуничтожения.
        NotificationCenter.default.addObserver(
            self, selector: #selector(self.linia2DidTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(self.linia2PlaybackChanged),
            name: Linia2Playback.changed, object: nil)
    }
    private func removeAppStateObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.willResignActiveNotification,
            object: nil)
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.removeObserver(
            self,
            name: UIDevice.orientationDidChangeNotification,
            object: nil)
    }

    private func setup() {
        myUID = Cache.tinode.myUid
        self.imagePicker = ImagePicker(presentationController: self, delegate: self, editable: false, allowVideo: true)

        let interactor = MessageInteractor()
        let presenter = MessagePresenter()
        interactor.presenter = presenter
        presenter.viewController = self

        // Notifications settings.
        self.sendTypingNotifications = SharedUtils.kAppDefaults.bool(forKey: SharedUtils.kTinodePrefTypingNotifications)
        self.sendReadReceipts = SharedUtils.kAppDefaults.bool(forKey: SharedUtils.kTinodePrefReadReceipts)

        self.interactor = interactor
        addAppStateObservers()
    }

    @objc
    func appBecameActive() {
        self.interactor?.setup(topicName: topicName, sendReadReceipts: self.sendReadReceipts)
        self.interactor?.attachToTopic(interactively: true)
        self.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
    }
    @objc
    func appGoingInactive() {
        self.interactor?.cleanup()
        self.interactor?.leaveTopic()
    }
    @objc
    func deviceRotated() {
        // Invalidate cached content in the messages since it was
        // tailored for the old device orientation.
        self.messages.forEach { ($0 as? StoredMessage)?.cachedContent = nil }
        // Force a full redraw so the view can readjust the messages
        // in the view for the new screen dimensions.
        self.collectionView?.reloadDataAndKeepOffset()
    }

    // MARK: lifecycle

    deinit {
        // removeMenuControllerObservers()
        removeAppStateObservers()
        // Clean up.
        appGoingInactive()
    }

    // This makes messageInputBar visible.
    override var inputAccessoryView: UIView? {
        return !isForwardingMessage ? sendMessageBar : forwardMessageBar
    }

    // Indicates whether the user is about to forward a message to this topic
    // i.e. the forwarded message preview is shown in the preview bar.
    var isForwardingMessage: Bool = false

    override var canBecomeFirstResponder: Bool {
        return true
    }

    override func loadView() {
        super.loadView()

        let collectionView = MessageView()

        // Appearance and behavior.
        extendedLayoutIncludesOpaqueBars = true

        // Receive notifications from FilePreviewController with an attachment to upload or send.
        NotificationCenter.default.addObserver(self, selector: #selector(sendAttachment(notification:)), name: Notification.Name(MessageViewController.kNotificationSendAttachment), object: nil)

        // Collection View setup
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.layoutMargins = Constants.kCollectionViewInset
        collectionView.delegate = self
        view.addSubview(collectionView)
        self.collectionView = collectionView

        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(self.loadPreviousPage), for: .valueChanged)

        // Setup UICollectionView constraints: fill the screen
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        self.collectionViewBottomAnchor = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(inputAccessoryView?.frame.height ?? 0))
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            self.collectionViewBottomAnchor,
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor)
        ])

        // Дизайн: лента заканчивается над строкой ввода — пузыри не «срезаются» ровной линией, а мягко гаснут.
        let fade = Linia2FadeEdgeView()
        fade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fade)
        NSLayoutConstraint.activate([
            fade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            fade.heightAnchor.constraint(equalToConstant: 14),
        ])

        // Setup "Go to latest message" button.
        let buttonGoToLatest = UIButton(type: .custom)
        buttonGoToLatest.backgroundColor = L2.surface2
        buttonGoToLatest.imageView?.tintColor = .secondaryLabel
        buttonGoToLatest.setImage(UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)), for: .normal)
        buttonGoToLatest.sizeToFit()
        buttonGoToLatest.layer.cornerRadius = 22
        buttonGoToLatest.layer.shadowOpacity = 0.25
        buttonGoToLatest.layer.shadowOffset = CGSize()
        buttonGoToLatest.addTarget(self, action: #selector(self.goToLastMessage), for: .touchUpInside)

        view.addSubview(buttonGoToLatest)
        self.goToLatestButton = buttonGoToLatest
        buttonGoToLatest.isHidden = true

        // Button on the bottom-right.
        self.goToLatestButton.translatesAutoresizingMaskIntoConstraints = false
        self.goToLatestButtonBottomAnchor = self.goToLatestButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -(inputAccessoryView?.frame.height ?? 0) - 16)
        NSLayoutConstraint.activate([
            self.goToLatestButton.widthAnchor.constraint(equalToConstant: 44.0),
            self.goToLatestButton.heightAnchor.constraint(equalToConstant: 44.0),
            self.goToLatestButtonBottomAnchor,
            self.goToLatestButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        defer { linia2InstallReactionGestures() }
        // Дизайн: навигатор «Чатов» с крупными заголовками — без .never шапка чата резервировала пустую
        // полосу крупного заголовка (~52 pt) между пилюлями шапки и плашкой «Закреплённое»/лентой.
        navigationItem.largeTitleDisplayMode = .never

        if let layout = collectionView?.collectionViewLayout as? MessageViewLayout {
            layout.delegate = self
        }

        self.collectionView.dataSource = self
        sendMessageBar.delegate = self
        forwardMessageBar.delegate = self

        self.setInterfaceColors()
        linia2InstallChatBackground()

        if self.interactor?.setup(topicName: self.topicName, sendReadReceipts: self.sendReadReceipts) ?? false {
            self.interactor?.deleteFailedMessages()
            self.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Make sure we leave enough space for the input field & keyboard.
        if collectionView.contentInset.bottom < 8 {
            collectionView.contentInset.bottom = 8
        }

        self.collectionViewBottomAnchor.constant = -(inputAccessoryView?.frame.height ?? 0)
        self.goToLatestButtonBottomAnchor.constant = -(inputAccessoryView?.frame.height ?? 0) - 16
        self.linia2BurnLabelBottom?.constant = -(inputAccessoryView?.frame.height ?? 0) - 4

        // Otherwise setting contentInset after viewDidAppear will be animated.
        if isInitialLayout {
            defer { isInitialLayout = false }
            addKeyboardObservers()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        self.setInterfaceColors()
        linia2InstallChatBackground()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // LINIA2_CHAT_SAFETY: шапка с «назад», аватаром и именем видна всегда (другие экраны прячут панель).
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if Linia2Chrome.floatingHeader {
            linia2ApplyFloatingAppearance()   // своя «‹ Назад» в пилюле
        } else {
            navigationItem.hidesBackButton = false
            navigationItem.leftItemsSupplementBackButton = true
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        linia2RestorePopGesture()
        // LINIA2: уход с экрана чата — голосовое и кружок останавливаются.
        Linia2Playback.shared.stopAll()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        linia2EnablePopGesture()
        linia2ScheduleHistoryCheck()
        linia2UpdateBurnUI()
        // Панель ввода — inputAccessoryView, видна, только пока чат — первый отвечающий. Чат, открытый под
        // экраном звонка (входящий при холодном старте), им не становился — после звонка панели не было.
        if presentedViewController == nil, linia2Search == nil, !isFirstResponder,
           sendMessageBar.inputField?.isFirstResponder != true {
            becomeFirstResponder()
        }

        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: sendMessageBar.frame.height, right: 0)

        if case let .forwarded(_, _, fwdPreview) = self.interactor?.pendingMessage {
            self.isForwardingMessage = true
            self.showInPreviewBar(content: fwdPreview, forwarded: true)
        }
        self.interactor?.attachToTopic(interactively: true)
        self.interactor?.loadMessagesFromCache(scrollToMostRecentMessage: false)
        self.interactor?.sendReadNotification(explicitSeq: nil, when: .now() + .seconds(1))
        self.applyTopicPermissions()
    }

    @objc func loadPreviousPage() {
        self.interactor?.loadPreviousPage()
    }

    @objc func goToLastMessage() {
        collectionView.scrollToBottom(animated: true)
    }

    @objc func sendAttachment(notification: NSNotification) {
        // Attachment size less base64 expansion and overhead.
        let maxInbandSize = self.maxInbandSize
        switch notification.object {
        case let content as FilePreviewContent:
            if content.data.count > maxInbandSize {
                self.interactor?.uploadFile(UploadDef(filename: content.fileName, mimeType: content.contentType, data: content.data))
            } else {
                _ = interactor?.sendMessage(content: Drafty().attachFile(mime: content.contentType, bits: content.data, fname: content.fileName))
            }
        case let content as ImagePreviewContent:
            guard case let ImagePreviewContent.ImageContent.uiimage(image) = content.imgContent else { return }

            guard let data = image.pixelData(forMimeType: content.contentType) else { return }
            if data.count > maxInbandSize {
                self.interactor?.uploadImage(UploadDef(caption: content.caption, filename: content.fileName, mimeType: content.contentType, image: image, data: data, width: image.size.width * image.scale, height: image.size.height * image.scale))
            } else {
                let drafty = Drafty(plainText: " ").insertImage(at: 0, mime: content.contentType, bits: data, width: content.width!, height: content.height!, fname: content.fileName)
                if let caption = content.caption {
                    _ = drafty.appendLineBreak().append(Drafty(plainText: caption))
                }
                _ = interactor?.sendMessage(content: drafty)
            }
        case let content as VideoPreviewContent:
            sendVideoAttachment(withContent: content)
        default:
            break
        }
    }

    private func sendVideoAttachment(withContent content: VideoPreviewContent) {
        guard case let VideoPreviewContent.VideoSource.local(url, poster) = content.videoSrc else { return }
        let previewMime = "image/png"
        let preview = poster?.pixelData(forMimeType: previewMime)
        let maxInbandSize = self.maxInbandSize

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Cache.log.error("MessageVC - failed to read audio record: %@", error.localizedDescription)
            return
        }
        // LINIA2: незашифрованная запись голосового не остаётся на диске — данные уже в памяти (дальше —
        // в зашифрованной базе или в выгрузке).
        try? FileManager.default.removeItem(at: url)

        let previewSize = preview?.count ?? 0
        if data.count < previewSize {
            // Image poster is greater than video itself. This is not currently supported.
            Cache.log.error("MessageVC - preview size (%lld bytes) is greater than video (%lld bytes)", previewSize, data.count)
            return
        }

        let mime = content.contentType ?? Utils.mimeForUrl(url: url)
        if data.count + previewSize > maxInbandSize {
            self.interactor?.uploadVideo(UploadDef(caption: content.caption, filename: content.fileName,
                                                   mimeType: mime, data: data,
                                                   width: content.width != nil ? CGFloat(content.width!) : nil,
                                                   height: content.height != nil ? CGFloat(content.height!) : nil,
                                                   duration: content.duration, preview: preview, previewMime: previewMime,
                                                   previewOutOfBand: previewSize > Constants.kMaxPosterSize))
        } else {
            if let drafty = try? Drafty(plainText: " ").insertVideo(at: 0, mime: mime, bits: data, refurl: nil, duration: content.duration, width: content.width!, height: content.height!, fname: content.fileName, size: data.count, preMime: previewMime, preview: preview, previewRef: nil) {
                if let caption = content.caption {
                    _ = drafty.appendLineBreak().append(Drafty(plainText: caption))
                }
                _ = interactor?.sendMessage(content: drafty)
            }
        }
    }

    func sendAudioAttachment(url: URL, duration: Int, preview: Data) {

        if duration < Constants.kMinDuration {
            return
        }
        // Attachment size less base64 expansion and overhead.
        let maxInbandSize = self.maxInbandSize

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Cache.log.error("MessageVC - failed to read audio record: %@", error.localizedDescription)
            return
        }
        // LINIA2: незашифрованная запись голосового не остаётся на диске — данные уже в памяти (дальше —
        // в зашифрованной базе или в выгрузке).
        try? FileManager.default.removeItem(at: url)

        let mime = Utils.mimeForUrl(url: url, ifMissing: "audio/m4a")
        if data.count > maxInbandSize {
            self.interactor?.uploadAudio(UploadDef(mimeType: mime, data: data, duration: duration, preview: preview))
        } else {
            if let drafty = try? Drafty(plainText: " ").insertAudio(at: 0, mime: mime, bits: data, preview: preview, duration: duration, fname: nil, refurl: nil, size: data.count) {
                _ = interactor?.sendMessage(content: drafty)
            }
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        switch segue.identifier {
        case "Messages2TopicInfo":
            let destinationVC = segue.destination as! TopicInfoViewController
            destinationVC.topicName = self.topicName ?? ""
        case "ShowImagePreview":
            let destinationVC = segue.destination as! ImagePreviewController
            destinationVC.previewContent = (sender as! ImagePreviewContent)
            destinationVC.replyPreviewDelegate = self
        case "ShowFilePreview":
            let destinationVC = segue.destination as! FilePreviewController
            destinationVC.previewContent = (sender as! FilePreviewContent)
            destinationVC.replyPreviewDelegate = self
        case "ShowVideoPreview":
            let destinationVC = segue.destination as! VideoPreviewController
            destinationVC.previewContent = (sender as! VideoPreviewContent)
            destinationVC.replyPreviewDelegate = self
        case "Messages2Call":
            let destinationVC = segue.destination as! CallViewController
            if let call = sender as? CallManager.Call {
                destinationVC.callDirection = .incoming
                destinationVC.callSeqId = call.seq
                destinationVC.isAudioOnlyCall = call.audioOnly
            } else {
                destinationVC.callDirection = .outgoing
                destinationVC.isAudioOnlyCall = (sender as? Int) == Constants.kAudioOnlyCall
            }
            destinationVC.topic = self.topic
        default:
            break
        }
    }

    @objc func navBarAvatarTapped(tapGestureRecognizer: UITapGestureRecognizer) {
        if topic?.deleted ?? false {
            return
        }
        performSegue(withIdentifier: "Messages2TopicInfo", sender: nil)
    }

    private func setInterfaceColors() {
        if true {
            view.backgroundColor = L2.background
        } else {
            view.backgroundColor = .white
        }
    }

    /// LINIA2: 📞 — сразу аудиозвонок, 📹 — сразу видеозвонок (без промежуточного меню).
    @objc func navBarCallTapped(sender: UIMenuController) {
        guard self.topicType == .p2p else { return }
        self.performSegue(withIdentifier: "Messages2Call", sender: Constants.kAudioOnlyCall)
    }

    @objc func navBarVideoCallTapped(sender: UIBarButtonItem) {
        guard self.topicType == .p2p, Linia2Config.shared.feature("videoCalls") else { return }
        self.performSegue(withIdentifier: "Messages2Call", sender: Constants.kVideoCall)
    }
}

// Methods for filling message with content and layout out message subviews.
extension MessageViewController: UICollectionViewDataSource {

    func numberOfSections(in: UICollectionView) -> Int {
        return 1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        self.collectionView.toggleNoMessagesNote(on: messages.isEmpty)
        return messages.count
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        if kind == UICollectionView.elementKindSectionHeader {
            let sectionHeader = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: String(describing: PinnedMessagesView.self), for: indexPath) as! PinnedMessagesView

            // Configure header.
            if self.pinnedMessageSeqs.isEmpty {
                sectionHeader.isHidden = true
            } else {
                sectionHeader.delegate = self
                sectionHeader.topicName = self.topicName
                sectionHeader.pins = self.pinnedMessageSeqs
                sectionHeader.selected = 0
                sectionHeader.isHidden = false
            }
            sectionHeader.alpha = linia2Search == nil ? 1 : 0   // Дизайн: под строкой поиска плашку не показываем

            return sectionHeader
        }

        return UICollectionReusableView()
    }

    // Configure message cell for the given index: fill data and lay out subviews.
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {

        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: MessageCell.self), for: indexPath) as! MessageCell

        // To capture taps.
        cell.delegate = self

        // Cell content
        let message = messages[indexPath.item]

        // Get cell attributes from cache.
        let attributes = collectionView.layoutAttributesForItem(at: indexPath) as! MessageViewLayoutAttributes

        cell.progressView.frame = attributes.progressViewFrame

        // Set colors and fill out content except for the avatar. The maxumum size is needed for placing attached images.
        configureCell(cell: cell, with: message, at: indexPath)

        cell.avatarView.frame = attributes.avatarFrame
        if attributes.avatarFrame != .zero {
            // The avatar image should be assigned after setting the size. Otherwise it may be drawn twice.
            let sub = topic?.getSubscription(for: message.from)
            cell.avatarView.set(pub: sub?.pub, id: message.from, deleted: sub == nil)
        }

        // Sender name under the avatar.
        cell.senderNameLabel.frame = attributes.senderNameFrame

        cell.containerView.frame = attributes.containerFrame

        // Content: RichTextLabel.
        cell.content.frame = attributes.contentFrame

        cell.deliveryMarker.frame = attributes.deliveryMarkerFrame

        // LINIA2 (сборка 1011, «время в пузыре всё ещё не так»): время всегда прижато вправо. У входящих
        // было выравнивание влево в рамке 50 pt — при времени на одной строке с текстом оно наезжало на конец
        // текста на ~12 pt, а в переиспользованной ячейке (после исходящего, где .right) стояло иначе.
        cell.timestampLabel.textAlignment = .right
        cell.timestampLabel.sizeToFit()
        cell.timestampLabel.frame = attributes.timestampFrame

        cell.editedMarker.sizeToFit()
        cell.editedMarker.frame = attributes.editedMarkerFrame

        cell.newDateLabel.frame = attributes.newDateFrame

        // Draw the bubble
        bubbleDecorator(for: message, at: indexPath)(cell.containerView)
        linia2RenderReactions(cell: cell, message: message)
        linia2LayoutMetaPill(cell: cell, message: message)
        linia2RenderRound(cell: cell, message: message)
        // Дизайн: снимок со скруглением чуть меньше пузыря (поле 3 pt), без «квадратных» углов внутри.
        let pureMedia = linia2IsPureMedia(message)
        cell.content.layer.cornerRadius = pureMedia ? max(0, Linia2Config.shared.radius("bubble", 18) - 3) : 0
        cell.content.layer.masksToBounds = pureMedia
        linia2LayoutVoicePlay(cell: cell, message: message)
        linia2ScheduleTimeGapCheck(cell: cell, message: message)

        return cell
    }

    private func configureCell(cell: MessageCell, with message: Message, at indexPath: IndexPath) {

        cell.seqId = message.seqId
        cell.isDeleted = message.isDeleted
        cell.timeStamp = message.ts

        cell.content.backgroundColor = nil
        if message.isDeleted {
            if traitCollection.userInterfaceStyle == .dark {
                cell.containerView.backgroundColor = Constants.kDeletedMessageBubbleColorDark
            } else {
                cell.containerView.backgroundColor = Constants.kDeletedMessageBubbleColorLight
            }
            cell.content.textColor = Constants.kDeletedMessageTextColor
        } else if linia2IsServiceMessage(message) {
            // LINIA2: системная строка — плашка по центру, как «Сегодня/Вчера».
            cell.containerView.backgroundColor = L2.surface.withAlphaComponent(0.72)
            cell.content.textColor = L2.textSecondary
        } else if isFromCurrentSender(message: message) {
            if traitCollection.userInterfaceStyle == .dark {
                cell.containerView.backgroundColor = Constants.kOutgoingBubbleColorDark
                cell.content.textColor = Constants.kOutgoingTextColorDark
            } else {
                cell.containerView.backgroundColor = Constants.kOutgoingBubbleColorLight
                cell.content.textColor = Constants.kOutgoingTextColorDark
            }
        } else {
            if traitCollection.userInterfaceStyle == .dark {
                cell.containerView.backgroundColor = Constants.kIncomingBubbleColorDark
                cell.content.textColor = Constants.kIncomingTextColorDark
            } else {
                cell.containerView.backgroundColor = Constants.kIncomingBubbleColorLight
                cell.content.textColor = Constants.kIncomingTextColorLight
            }
        }

        cell.content.font = Constants.kContentFont

        let storedMessage = message as! StoredMessage
        if let t = linia2ServiceText(message) {
            // LINIA2: свой переключатель самоуничтожения — «Вы включили …».
            cell.content.attributedText = NSAttributedString(string: t, attributes: [.font: Constants.kServiceFont, .foregroundColor: L2.textSecondary])
            cell.content.textAlignment = .center
            cell.content.accessibilityIdentifier = "l2.service.\(message.seqId)"
        } else if let attributedText = storedMessage.cachedContent {
            let carveout = (isFromCurrentSender(message: message) ? Constants.kOutgoingMetadataCarveout : Constants.kIncomingMetadataCarveout)
            let text = NSMutableAttributedString(attributedString: attributedText)
            text.append(NSAttributedString(string: carveout, attributes: [.font: Constants.kContentFont]))
            cell.content.attributedText = text
        }

        if let (image, tint) = deliveryMarker(for: message) {
            cell.deliveryMarker.image = image
            cell.deliveryMarker.tintColor = tint
            // LINIA2: отметка доставки словами (VoiceOver и автотесты).
            if let t = topic {
                let st = t.msgReadCount(seq: message.seqId) > 0 ? "прочитано" : (t.msgRecvCount(seq: message.seqId) > 0 ? "доставлено" : "отправлено")
                cell.deliveryMarker.isAccessibilityElement = true
                cell.deliveryMarker.accessibilityLabel = "Статус"
                cell.deliveryMarker.accessibilityValue = st
                cell.deliveryMarker.accessibilityIdentifier = "l2.delivery.\(message.seqId)"
            }
        }
        // Дизайн: на фото без подписи время белое (на тёмной плашке поверх снимка), иначе — серое по серому.
        let markerTextColor = isFromCurrentSender(message: message) || linia2IsPureMedia(message) ? UIColor.white.withAlphaComponent(0.9) : L2.textSecondary
        if let ts = message.ts, !linia2IsServiceMessage(message) {
            // LINIA2: исчезающее сообщение — вместо времени таймер «⏱0:20» (после прочтения — обратный отсчёт).
            let burnStamp = topic.flatMap { Linia2Burn.stamp(topic: $0.name, message: message) }
            cell.timestampLabel.text = burnStamp ?? RelativeDateFormatter.shared.timeOnly(from: ts)
            cell.timestampLabel.isAccessibilityElement = burnStamp != nil
            cell.timestampLabel.accessibilityIdentifier = burnStamp != nil ? "l2.burn.timer.\(message.seqId)" : nil
            cell.timestampLabel.accessibilityLabel = nil
            cell.timestampLabel.accessibilityValue = nil
            cell.timestampLabel.textColor = markerTextColor
        }
        cell.editedMarker.text = editedMarkerText(forMessage: message)
        cell.editedMarker.textColor = markerTextColor
        cell.newDateLabel.attributedText = newDateLabel(for: message, at: indexPath)
        cell.senderNameLabel.attributedText = senderFullName(for: message, at: indexPath)

        if shouldShowProgressBar(for: message) {
            cell.showProgressBar()
        }
    }

    func editedMarkerText(forMessage msg: Message) -> String? {
        return msg.isEdited ? NSLocalizedString("edited", comment: "`Edited` message marker") : nil
    }

    func newDateLabel(for message: Message, at indexPath: IndexPath) -> NSAttributedString? {
        if isNewDateLabelVisible(at: indexPath) {
            return NSAttributedString(string: RelativeDateFormatter.shared.dateOnly(from: message.ts), attributes: [NSAttributedString.Key.font: Constants.kNewDateFont, NSAttributedString.Key.foregroundColor: L2.textSecondary])
        }
        return nil
    }

    // Get sender name
    func senderFullName(for message: Message, at indexPath: IndexPath) -> NSAttributedString? {
        guard shouldShowAvatar(for: message, at: indexPath) else { return nil }

        var senderName: String?
        if let sub = topic?.getSubscription(for: message.from), let pub = sub.pub {
            senderName = pub.fn
        }
        senderName = senderName ?? String(format: NSLocalizedString("Unknown %@", comment: "Sender with missing name"), message.from ?? "none")

        return NSAttributedString(string: senderName!, attributes: [
            NSAttributedString.Key.font: Constants.kSenderNameFont,
            NSAttributedString.Key.foregroundColor: L2.accent
            ])
    }

    func deliveryMarker(for message: Message) -> (UIImage, UIColor)? {
        guard isFromCurrentSender(message: message), !linia2IsServiceMessage(message), let topic = topic else { return nil }
        // LINIA2: флаг отметок «доставлено/прочитано» (features.readReceipts).
        guard Linia2Config.shared.feature("readReceipts") else { return nil }
        return UiUtils.deliveryMarkerIcon(for: message, in: topic)
    }

    // Returns closure which adds message bubble mask to the supplied UIView.
    func bubbleDecorator(for message: Message, at indexPath: IndexPath) -> (UIView) -> Void {
        let isIncoming = !isFromCurrentSender(message: message)
        let isDeleted = message.isDeleted || linia2IsServiceMessage(message)

        let breakBefore = !isPreviousMessageSameSender(at: indexPath) || !isPreviousMessageSameDate(at: indexPath)
        let breakAfter = !isNextMessageSameSender(at: indexPath) || !isNextMessageSameDate(at: indexPath)

        let style: MessageBubbleDecorator.Style
        switch true {
        case breakBefore && breakAfter:
            style = .single
        case breakBefore:
            style = .first
        case breakAfter:
            style = .last
        default:
            style = .middle
        }

        let isService = !message.isDeleted && linia2IsServiceMessage(message)
        return { view in
            if isService {   // LINIA2: плашка-капсула
                let mask = CAShapeLayer()
                mask.path = UIBezierPath(roundedRect: view.bounds, cornerRadius: min(11, view.bounds.height / 2)).cgPath
                view.layer.mask = mask
                return
            }
            let path = !isDeleted ?
                MessageBubbleDecorator.draw(view.bounds, isIncoming: isIncoming, style: style) :
                MessageBubbleDecorator.drawDeleted(view.bounds)
            let mask = CAShapeLayer()
            mask.path = path.cgPath
            view.layer.mask = mask
        }
    }
}

// Helper methods for displaying message content
extension MessageViewController {

    // MARK: helper methods for displaying message content.

    func isPreviousMessageSameDate(at indexPath: IndexPath) -> Bool {
        guard indexPath.item > 0 else { return false }
        guard let this = messages[indexPath.item].ts, let prev = messages[indexPath.item - 1].ts else { return false }
        return Calendar.current.isDate(this, inSameDayAs: prev)
    }

    func isNextMessageSameDate(at indexPath: IndexPath) -> Bool {
        guard indexPath.item + 1 < messages.count else { return false }
        guard let this = messages[indexPath.item].ts, let next = messages[indexPath.item + 1].ts else { return false }
        return Calendar.current.isDate(this, inSameDayAs: next)
    }

    func isPreviousMessageSameSender(at indexPath: IndexPath) -> Bool {
        guard indexPath.item > 0 else { return false }
        return messages[indexPath.item].from == messages[indexPath.item - 1].from
    }

    func isNextMessageSameSender(at indexPath: IndexPath) -> Bool {
        guard indexPath.item + 1 < messages.count else { return false }
        return messages[indexPath.item].from == messages[indexPath.item + 1].from
    }

    func isFromCurrentSender(message: Message) -> Bool {
        return message.from == myUID
    }

    // Should avatars be shown at all for any message?
    func avatarsVisible(message: Message) -> Bool {
        return (topic?.isGrpType ?? false) && !(topic?.isChannel ?? false) && !isFromCurrentSender(message: message) && !linia2IsServiceMessage(message)
    }

    // Show avatar in the given message
    func shouldShowAvatar(for message: Message, at indexPath: IndexPath) -> Bool {
        return avatarsVisible(message: message) && (!isNextMessageSameSender(at: indexPath) || !isNextMessageSameDate(at: indexPath))
    }

    // Should we show upload progress bar for reference attachment messages?
    func shouldShowProgressBar(for message: Message) -> Bool {
        return message.isPending && (message.content?.hasRefEntity ?? false)
    }

    func isNewDateLabelVisible(at indexPath: IndexPath) -> Bool {
        return !isPreviousMessageSameDate(at: indexPath)
    }
}

// Message size calculation
extension MessageViewController: MessageViewLayoutDelegate {

    // MARK: MessageViewLayoutDelegate method

    // Claculate positions and sizes of all subviews in a cell.
    func collectionView(_ collectionView: UICollectionView, fillAttributes attr: MessageViewLayoutAttributes) {
        if attr.representedElementCategory == .supplementaryView {
            // Request for pinned area attributes (section header).
            let height: CGFloat = self.pinnedMessageSeqs.isEmpty ? 0 : Constants.kPinnedMessagesViewHeight
            // Дизайн: плашка с равными полями слева и справа (раньше прижималась к левому краю экрана).
            attr.frame = CGRect(origin: CGPoint(x: collectionView.layoutMargins.left, y: 0), size: CGSize(width: collectionView.frame.width - collectionView.layoutMargins.left - collectionView.layoutMargins.right, height: height))
            attr.zIndex = 1
            // Дизайн: под строкой поиска плашку не показываем (alpha вида перетирается атрибутами раскладки).
            attr.alpha = linia2Search == nil ? 1 : 0
            return
        } else if attr.representedElementCategory == .decorationView {
            // This should not happen.
            return
        }

        // Fill out attributes for a regular message bubble.

        let indexPath = attr.indexPath

        // Cell content
        let message = messages[indexPath.item]

        // Is this an outgoing message?
        let isOutgoing = isFromCurrentSender(message: message)
        // The message set has avatars.
        let hasAvatars = avatarsVisible(message: message)
        let isDeleted = message.isDeleted
        // LINIA2: служебные строки (самоуничтожение, скриншот) — по центру, как «удалено».
        let isService = linia2IsServiceMessage(message)
        let isCentered = isDeleted || isService
        // This message has an avatar.
        let isAvatarVisible = !isCentered && shouldShowAvatar(for: message, at: indexPath)
        // This message has been edited.
        let isEdited = message.isEdited

        // Insets for the message bubble relative to collectionView: bubble should not touch the sides of the screen.
        let containerPadding = linia2ContainerPadding(outgoing: isOutgoing)

        // Size of the message bubble.
        let showUploadProgress = shouldShowProgressBar(for: message)
        let containerSize = calcContainerSize(for: message, avatarsVisible: hasAvatars, progressVisible: showUploadProgress)
        let timeInline = textSizeHelper.lastTimeInline && !isCentered
        // Get cell size.
        let cellSize = !isDeleted ? calcCellSize(forItemAt: indexPath) : containerSize
        attr.cellSpacing = Constants.kVerticalCellSpacing
        // LINIA2: место под пилюли реакций — внутри ячейки (а не в отступе между ячейками): иначе пилюля
        // лежала за границами ячейки, касание и доступность (XCUITest «scroll to visible») до неё не доходили.
        let reactionsHeight = linia2ReactionSpacing(for: message.seqId)

        // Height of the field with the current date above the first message of the day.
        let newDateLabelHeight = !isDeleted ? calcNewDateLabelHeight(at: indexPath) : 0

        // This is the height of the field with the sender's name.
        let senderNameLabelHeight = isAvatarVisible ? Constants.kSenderNameLabelHeight : 0

        if isAvatarVisible {
            attr.avatarFrame = CGRect(x: 0, y: cellSize.height - Constants.kAvatarSize - senderNameLabelHeight, width: Constants.kAvatarSize, height: Constants.kAvatarSize)

            // Sender name under the avatar.
            attr.senderNameFrame = CGRect(origin: CGPoint(x: 0, y: cellSize.height - senderNameLabelHeight), size: CGSize(width: cellSize.width, height: senderNameLabelHeight))
        } else {
            attr.avatarFrame = .zero
            attr.senderNameFrame = .zero
        }

        // Additional left padding in group topics with avatar
        let avatarPadding = hasAvatars ? Constants.kAvatarSize : 0

        // isDeleted ? center container : else
        // isFromCurrent Sender ? Flush container right : flush left.
        let originX =
            isCentered ? ((isDeleted ? collectionView.bounds.width : cellSize.width) - containerSize.width) / 2 :
            isOutgoing ? cellSize.width - avatarPadding - containerSize.width - containerPadding.right : avatarPadding + containerPadding.left
        attr.containerFrame = CGRect(origin: CGPoint(x: originX, y: newDateLabelHeight + containerPadding.top), size: containerSize)

        // Content: RichTextLabel.
        let contentInset =
            isService && !isDeleted ? Constants.kServiceContentInset :
            isCentered ? Constants.kDeletedMessageContentInset :
            linia2IsPureMedia(message) ? Constants.kL2MediaInset :
            timeInline ? Constants.kInlineTimeContentInset :
            isOutgoing ? Constants.kOutgoingMessageContentInset : Constants.kIncomingMessageContentInset
        attr.contentFrame = CGRect(x: contentInset.left, y: contentInset.top, width: attr.containerFrame.width - contentInset.left - contentInset.right, height: attr.containerFrame.height - contentInset.top - contentInset.bottom - (showUploadProgress ? Constants.kProgressViewHeight : 0))

        var rightEdge = CGPoint(x: attr.containerFrame.width - Constants.kDeliveryMarkerPadding, y: attr.containerFrame.height - Constants.kDeliveryMarkerSize)
        if timeInline && !showUploadProgress {
            // Время — на последней строке текста (по её нижнему краю), а не ниже текста.
            rightEdge.y = attr.containerFrame.height - contentInset.bottom - Constants.kDeliveryMarkerSize - 1
        }
        if linia2IsPureMedia(message) {
            // Дизайн: время на снимке — плашкой внутри, а не на срезе края пузыря.
            rightEdge.x -= 6
            rightEdge.y -= 10
        }
        if isOutgoing && !isCentered {
            rightEdge.x -= Constants.kDeliveryMarkerSize
            attr.deliveryMarkerFrame = CGRect(x: rightEdge.x, y: rightEdge.y, width: Constants.kDeliveryMarkerSize, height: Constants.kDeliveryMarkerSize)
        } else {
            attr.deliveryMarkerFrame = .zero
        }

        attr.timestampFrame = !isCentered ? CGRect(x: rightEdge.x - Constants.kTimestampWidth - Constants.kTimestampPadding, y: rightEdge.y, width: Constants.kTimestampWidth, height: Constants.kDeliveryMarkerSize) : .zero

        if isEdited {
            let x = attr.timestampFrame.origin != .zero ? attr.timestampFrame.origin.x - Constants.kEditedMarkerWidth - Constants.kEditedMarkerPadding : rightEdge.x
            attr.editedMarkerFrame = CGRect(x: x, y: rightEdge.y, width: Constants.kEditedMarkerWidth, height: Constants.kDeliveryMarkerSize)
        } else {
            attr.editedMarkerFrame = .zero
        }

        // New date label
        if newDateLabelHeight > 0 {
            attr.newDateFrame = CGRect(origin: CGPoint(x: 0, y: attr.containerFrame.minY - containerPadding.top - newDateLabelHeight), size: CGSize(width: cellSize.width, height: newDateLabelHeight))
        } else {
            attr.newDateFrame = .zero
        }

        if showUploadProgress {
            let origin = CGPoint(x: attr.contentFrame.origin.x, y: attr.contentFrame.origin.y + attr.contentFrame.size.height)
            attr.progressViewFrame =
                CGRect(origin: origin, size: CGSize(width: attr.contentFrame.width, height: Constants.kProgressViewHeight))
        } else {
            attr.progressViewFrame = .zero
        }

        attr.frame = CGRect(origin: CGPoint(), size: CGSize(width: cellSize.width, height: cellSize.height + reactionsHeight))
    }

    // MARK: supporting methods

    // Calculate and cache message cell size
    func calcCellSize(forItemAt indexPath: IndexPath) -> CGSize {
        // if let size = cellSizeCache[indexPath.item] {
        //    return size
        // }

        let message = messages[indexPath.item]
        let hasAvatars = avatarsVisible(message: message)
        let showProgress = shouldShowProgressBar(for: message)
        let containerHeight = calcContainerSize(for: message, avatarsVisible: hasAvatars, progressVisible: showProgress).height
        let size = CGSize(width: calcCellWidth(), height: calcCellHeightFromContent(for: message, at: indexPath, containerHeight: containerHeight, avatarsVisible: hasAvatars, progressVisible: showProgress))
        return size
    }

    /// LINIA2: отступ «дальней» стороны — пузырь не шире kMaxBubbleWidthFraction экрана.
    func linia2ContainerPadding(outgoing: Bool) -> UIEdgeInsets {
        let screen = collectionView?.bounds.width ?? UIScreen.main.bounds.width
        let far = max(Constants.kFarSideHorizontalSpacing, calcCellWidth() - (screen * Constants.kMaxBubbleWidthFraction).rounded(.down))
        return outgoing ? UIEdgeInsets(top: 0, left: far, bottom: 0, right: 0) : UIEdgeInsets(top: 0, left: 0, bottom: 0, right: far)
    }

    func calcCellWidth() -> CGFloat {
        return collectionView.frame.width - collectionView.layoutMargins.left - collectionView.layoutMargins.right
    }

    func calcCellHeightFromContent(
        for message: Message, at indexPath: IndexPath, containerHeight: CGFloat,
        avatarsVisible hasAvatars: Bool, progressVisible: Bool) -> CGFloat {

        let senderNameLabelHeight: CGFloat = shouldShowAvatar(for: message, at: indexPath) ? Constants.kSenderNameLabelHeight : 0
        let newDateLabelHeight: CGFloat = calcNewDateLabelHeight(at: indexPath)
        let avatarHeight = hasAvatars ? Constants.kAvatarSize : 0

        let totalLabelHeight: CGFloat = newDateLabelHeight + containerHeight + senderNameLabelHeight + (progressVisible ? Constants.kProgressViewHeight : 0)
        return max(avatarHeight, totalLabelHeight)
    }

    func calcNewDateLabelHeight(at indexPath: IndexPath) -> CGFloat {
        let height: CGFloat
        if isNewDateLabelVisible(at: indexPath) {
            height = Constants.kNewDateLabelHeight
        } else if !isPreviousMessageSameSender(at: indexPath) {
            height = Constants.kAdditionalP2PVerticalCellSpacing
        } else {
            height = 0
        }
        return height
    }

    // Calculate maximum width of content inside message bubble
    func calcMaxContentWidth(for message: Message, avatarsVisible: Bool) -> CGFloat {

        let insets = linia2IsPureMedia(message) ? Constants.kL2MediaInset :
            isFromCurrentSender(message: message) ? Constants.kOutgoingMessageContentInset : Constants.kIncomingMessageContentInset

        let avatarWidth = avatarsVisible ? Constants.kAvatarSize : 0

        let padding = linia2ContainerPadding(outgoing: isFromCurrentSender(message: message))

        return calcCellWidth() - avatarWidth - padding.left - padding.right - insets.left - insets.right
    }

    /// Calculate size of the view which holds message content.
    func calcContainerSize(for message: Message, avatarsVisible: Bool, progressVisible: Bool) -> CGSize {
        let maxWidth = calcMaxContentWidth(for: message, avatarsVisible: avatarsVisible)
        textSizeHelper.lastTimeInline = false
        if !message.isDeleted && linia2IsRound(message) {   // LINIA2: видео-кружок
            return linia2RoundContainerSize(maxWidth: maxWidth, progressVisible: progressVisible)
        }
        let isService = !message.isDeleted && linia2IsServiceMessage(message)
        let baseInsets =
            isService ? Constants.kServiceContentInset :
            message.isDeleted ? Constants.kDeletedMessageContentInset :
            linia2IsPureMedia(message) ? Constants.kL2MediaInset :
            isFromCurrentSender(message: message) ? Constants.kOutgoingMessageContentInset : Constants.kIncomingMessageContentInset

        var size = calcContentSize(for: message, maxWidth: maxWidth)
        let insets = textSizeHelper.lastTimeInline ? Constants.kInlineTimeContentInset : baseInsets

        size.width += insets.left + insets.right
        if !isService {
            size.width = max(size.width,
                             message.isEdited ? Constants.kMinimumEditedCellWidth : Constants.kMinimumCellWidth)
        }
        size.height += insets.top + insets.bottom
        if progressVisible {
            size.height += Constants.kProgressViewHeight
        }

        return size
    }

    /// Calculate size of message content.
    func calcContentSize(for message: Message, maxWidth: CGFloat) -> CGSize {
        textSizeHelper.lastTimeInline = false
        let attributedText = NSMutableAttributedString()

        let carveout = isFromCurrentSender(message: message) ? Constants.kOutgoingMetadataCarveout : Constants.kIncomingMetadataCarveout

        let textColor: UIColor
        if message.isDeleted {
            textColor = Constants.kDeletedMessageTextColor
        } else if traitCollection.userInterfaceStyle == .dark {
            textColor = isFromCurrentSender(message: message) ? Constants.kOutgoingTextColorDark : Constants.kIncomingTextColorDark
        } else {
            textColor = isFromCurrentSender(message: message) ? Constants.kOutgoingTextColorLight : Constants.kIncomingTextColorLight
        }

        let storedMessage = message as! StoredMessage
        if let t = linia2ServiceText(message) {
            // LINIA2: компактная плашка — мелкий шрифт, без места под время.
            let a = NSAttributedString(string: t, attributes: [.font: Constants.kServiceFont, .foregroundColor: textColor])
            return textSizeHelper.computeSize(for: a, within: maxWidth)
        } else if let content = storedMessage.attributedContent(fitIn: CGSize(width: maxWidth, height: collectionView.frame.height * 0.66), withDefaultAttributes: [.font: Constants.kContentFont, .foregroundColor: textColor]) {
            attributedText.append(content)
        } else {
            attributedText.append(NSAttributedString(string: "none", attributes: [.font: Constants.kContentFont]))
        }
        attributedText.append(NSAttributedString(string: carveout, attributes: [.font: Constants.kContentFont]))

        // FIXME: storedMessage may contain an image surrounded by text. In such cases,
        // size calculations may be wrong. Handle it.
        if storedMessage.isVisualMedia {
            // Дизайн: фото без подписи — размер ровно по снимку (строка текста добавляла полосу снизу).
            if linia2IsPureMedia(message) {
                var imageSize: CGSize?
                attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length)) { v, _, stop in
                    if let a = v as? NSTextAttachment, a.bounds.width > 0 { imageSize = a.bounds.size; stop.pointee = true }
                }
                if let sz = imageSize { return CGSize(width: ceil(sz.width), height: ceil(sz.height)) }
            }
            return attributedText.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                               context: nil).integral.size
        }
        // Дизайн: время (и галочки) — справа внизу без наложения на текст. Пробелы-«вырез» в конце строки
        // не переносятся, поэтому место считаем по последней строке: влезает — время на ней, иначе — своя строка.
        if message.isDeleted { return textSizeHelper.computeSize(for: attributedText, within: maxWidth) }
        let timeW = ("00:00" as NSString).size(withAttributes: [.font: Constants.kTimestampFont]).width
        // LINIA2: проверка после раскладки нашла наложение и пересчёт не помог — время на своей строке.
        if Linia2TimeGap.forcedBelow(topic: topicName, seq: message.seqId) {
            return textSizeHelper.computeSize(for: attributedText, within: maxWidth, trailingReserve: .greatestFiniteMagnitude, extraLine: 8)
        }
        var reserve = isFromCurrentSender(message: message) ? timeW + 30 : timeW + 8
        if message.isEdited {
            // Метка «изменено» стоит левее рамки времени (50 pt) — её место тоже в последней строке.
            reserve += max(0, Constants.kTimestampWidth - timeW) + Constants.kEditedMarkerWidth + Constants.kEditedMarkerPadding
        }
        return textSizeHelper.computeSize(for: attributedText, within: maxWidth, trailingReserve: reserve, extraLine: 8)
    }
}

extension MessageViewController: PendingMessagePreviewDelegate {
    func pendingPreviewMessageSize(forMessage msg: NSAttributedString) -> CGSize {
        return self.textSizeHelper.computeSize(for: msg, within: CGFloat.infinity)
    }
    func dismissPendingMessagePreview() {
        // Make sure MessageVC is the first responder so we can successfully reload
        // the input accessory view.
        self.becomeFirstResponder()
        self.interactor?.dismissPendingMessage()
        self.togglePreviewBar(with: nil)
        self.view.setNeedsLayout()
    }
}

extension MessageViewController: ForwardToDelegate {
    func forwardMessage(_ message: Drafty, preview: Drafty, from originTopic: String, to topicId: String) {
        self.presentChatReplacingCurrentVC(with: topicId, initializationCallback: {
            ($0 as! MessageViewController).attachForwardedMessage(message, preview, from: originTopic)
        })
    }

    func attachForwardedMessage(_ message: Drafty, _ preview: Drafty, from origin: String) {
        if self.topic?.isWriter ?? false {
            self.interactor?.prepareToForward(message: message, forwardedFrom: origin, preview: preview)
        }
    }
}

extension MessageViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let isHidden = scrollView.contentOffset.y + scrollView.frame.size.height + 40 >= scrollView.contentSize.height
        if self.goToLatestButton.isHidden != isHidden {
            UIView.transition(with: self.goToLatestButton, duration: 0.4, options: .transitionCrossDissolve, animations: {
                self.goToLatestButton.isHidden = isHidden
            }, completion: nil)
        }
    }

    /// LINIA2: кружок ушёл за экран — стоп (если он не переехал в новую ячейку того же сообщения).
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let r = (cell as? MessageCell)?.linia2Round else { return }
        DispatchQueue.main.async { [weak collectionView, weak r] in
            guard let r = r, let cv = collectionView else { return }
            let shown = cv.visibleCells.contains { ($0 as? MessageCell)?.linia2Round === r && r.window != nil }
            if !shown { r.pause() }
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let path = self.highlightCellAtPathAfterScroll else { return }
        self.highlightCellAtPathAfterScroll = nil
        guard let cell = collectionView.cellForItem(at: path) as? MessageCell else { return }
        cell.highlightAnimated(withDuration: 4.0)
    }
}

/// Градиент «прозрачный → фон» у нижнего края ленты (над строкой ввода).
final class Linia2FadeEdgeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        updateColors()
    }

    required init?(coder: NSCoder) { return nil }

    private func updateColors() {
        let bg = L2.background.resolvedColor(with: traitCollection)
        (layer as? CAGradientLayer)?.colors = [bg.withAlphaComponent(0).cgColor, bg.withAlphaComponent(0.95).cgColor]
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }
}

extension MessageViewController {
    /// Фото/видео без подписи (не кружок): выводится почти до края пузыря.
    func linia2IsPureMedia(_ message: Message) -> Bool {
        guard !message.isDeleted, let m = message as? StoredMessage, m.isVisualMedia, !linia2IsRound(message) else { return false }
        return (message.content?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
