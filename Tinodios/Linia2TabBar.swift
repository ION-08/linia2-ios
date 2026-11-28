//
//  Linia2TabBar.swift
//  Линия 2.0: корневой экран с плавающим закруглённым нижним меню (Чаты | Звонки | Контакты | Настройки).
//

import UIKit

final class Linia2TabBarController: UITabBarController, UINavigationControllerDelegate {
    enum Tab: Int, CaseIterable { case chats, calls, contacts, settings }

    private let bar = Linia2FloatingBar()
    /// Дизайн: подложка под строкой состояния на корневых экранах — прокрученный текст не налезает на часы/батарею.
    private let statusScrim = UIView()
    private var barBottom: NSLayoutConstraint!
    private(set) var chatsNavigator: UINavigationController!
    private var configObserver: NSObjectProtocol?

    /// Высота, которую экраны вкладок должны оставлять снизу под меню.
    static let reservedBottom: CGFloat = 96

    static var current: Linia2TabBarController? {
        (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController as? Linia2TabBarController
    }

    static func make() -> Linia2TabBarController {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let chats = (storyboard.instantiateViewController(withIdentifier: "ChatsNavigator") as? UINavigationController)
            ?? UINavigationController(rootViewController: UIViewController())
        let tc = Linia2TabBarController()
        tc.chatsNavigator = chats
        let calls = UINavigationController(rootViewController: Linia2CallsViewController())
        let contacts = UINavigationController(rootViewController: Linia2ContactsViewController())
        let settings = UINavigationController(rootViewController: Linia2SettingsViewController())
        tc.viewControllers = [chats, calls, contacts, settings]
        for case let nav as UINavigationController in tc.viewControllers ?? [] {
            nav.delegate = tc
            nav.view.backgroundColor = L2.background
        }
        return tc
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = L2.background
        tabBar.isHidden = true
        statusScrim.backgroundColor = L2.background.withAlphaComponent(0.94)
        statusScrim.isUserInteractionEnabled = false
        statusScrim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusScrim)
        NSLayoutConstraint.activate([
            statusScrim.topAnchor.constraint(equalTo: view.topAnchor),
            statusScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusScrim.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        barBottom = bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            barBottom,
            bar.heightAnchor.constraint(equalToConstant: 72),
        ])
        bar.onSelect = { [weak self] i in self?.selectTab(Tab(rawValue: i) ?? .chats) }
        bar.select(selectedIndex)
        // Вкладки (порядок, названия, видимость, иконки) — из удалённых настроек, применяются без перезапуска.
        configObserver = NotificationCenter.default.addObserver(forName: Linia2Config.changedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.bar.rebuild()
            if !self.bar.hasTab(self.selectedIndex) { self.selectTab(.chats) } else { self.bar.select(self.selectedIndex) }
        }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Закрылось модальное окно (экран звонка и т.п.) — меню снова видно. Раньше видимость пересчитывалась только
    /// при переходах в навигаторе и выборе вкладки: при холодном старте по входящему звонку чат открывался, пока
    /// экран звонка уже показывался, меню пряталось (alpha 0) и после звонка так и оставалось скрытым.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateBarVisibility(animated: false)
        Linia2Splash.ready("tabs")
    }

    /// LINIA2: безопасное переключение вкладок (быстрые нажатия, во время загрузки и анимаций):
    /// только с главного потока, только на существующий контроллер, «вернуться к началу» — не во время
    /// перехода в навигаторе (popToRoot посреди push/pop ломал стек и ронял приложение).
    func selectTab(_ tab: Tab) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.selectTab(tab) }
            return
        }
        guard let vcs = viewControllers, tab.rawValue < vcs.count else { return }
        if selectedIndex == tab.rawValue, let nav = selectedViewController as? UINavigationController {
            if nav.transitionCoordinator == nil, nav.presentedViewController == nil, nav.viewControllers.count > 1 {
                nav.popToRootViewController(animated: true)
            }
        } else if selectedIndex != tab.rawValue {
            // Клавиатура/поиск предыдущей вкладки не должны «переезжать» и держать первый отвечающий.
            selectedViewController?.view.endEditing(true)
            selectedIndex = tab.rawValue
        }
        bar.select(tab.rawValue)
        updateBarVisibility(animated: false)
    }

    /// Меню — только на главных экранах вкладок (как в Telegram, решение владельца 27.11): в чате и на вложенных
    /// экранах его нет (там «Назад»); под модальными окнами (звонок и т.п.) тоже скрыто.
    func updateBarVisibility(animated: Bool) {
        let nav = selectedViewController as? UINavigationController
        let onRoot = (nav?.viewControllers.count ?? 1) <= 1
        let visible = presentedViewController == nil && onRoot
        SendMessageBar.linia2TabBarReserve = 0   // в чате меню нет — панель ввода у нижнего края (плюс safe area)
        let apply = {
            self.bar.alpha = visible ? 1 : 0
            self.bar.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 30)
        }
        bar.isUserInteractionEnabled = visible
        statusScrim.isHidden = (nav?.viewControllers.count ?? 1) > 1
        if animated { UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: apply) } else { apply() }
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let isRoot = navigationController.viewControllers.first === viewController
        // На вложенных экранах меню нет — места под него не резервируем.
        _ = isRoot
        updateBarVisibility(animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        updateBarVisibility(animated: false)
    }
}

// MARK: - Плавающее меню

final class Linia2FloatingBar: UIView {
    var onSelect: ((Int) -> Void)?
    private var items: [UIControl] = []
    private let pill = UIView()
    private var pillLeading: NSLayoutConstraint?
    private let stack = UIStackView()
    private var pillWidth: NSLayoutConstraint?
    private var shownSpecs: [Linia2Config.TabSpec] = []

    /// Встроенные вкладки: id → (индекс контроллера, название, иконка, иконка выбранной).
    private static let builtin: [String: (Int, String, String, String)] = [
        "chats": (0, "Чаты", "bubble.left", "bubble.left.fill"),
        "calls": (1, "Звонки", "phone", "phone.fill"),
        "contacts": (2, "Контакты", "person.2", "person.2.fill"),
        "settings": (3, "Настройки", "gearshape", "gearshape.fill"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        // «Стекло» в стиле iOS 26: размытие + тонкая обводка + тень.
        // Дизайн: размытие по теме (тёмное в светлой теме давало серую «плиту» под белыми экранами).
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 36
        blur.clipsToBounds = true
        addSubview(blur)
        backgroundColor = L2.tabBar.withAlphaComponent(0.82)
        layer.cornerRadius = 36
        layer.borderWidth = 1
        layer.borderColor = Self.borderColor.resolvedColor(with: traitCollection).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .light ? 0.12 : 0.45
        layer.shadowRadius = 24
        layer.shadowOffset = CGSize(width: 0, height: 10)

        pill.backgroundColor = L2.accent
        pill.layer.cornerRadius = 26
        pill.layer.cornerCurve = .continuous
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Одинаковые отступы выделения на всех вкладках и запас от скругления панели (радиус 36).
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pill.topAnchor.constraint(equalTo: stack.topAnchor), pill.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
        ])
        rebuild()
        accessibilityTraits = .tabBar
    }

    private static let borderColor = UIColor { $0.userInterfaceStyle == .light ? L2.hex(0x000000, 0.06) : L2.hex(0xFFFFFF, 0.10) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = Self.borderColor.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .light ? 0.12 : 0.45
    }

    func hasTab(_ index: Int) -> Bool { items.contains { $0.tag == index } }

    /// Пересобрать вкладки по удалённым настройкам (порядок, названия, видимость, иконки по URL).
    func rebuild() {
        let specs = Linia2Config.shared.tabs
        guard specs != shownSpecs || items.isEmpty else { return }
        shownSpecs = specs
        let selected = items.first { ($0 as? Linia2TabItem)?.isOn ?? false }?.tag ?? 0
        items.forEach { $0.removeFromSuperview() }
        items = []
        for spec in specs {
            guard let b = Self.builtin[spec.id] else { continue }
            let item = Linia2TabItem(title: spec.title ?? L2T("l2.tab." + spec.id, b.1), symbol: b.2, symbolSelected: b.3, iconURL: spec.iconURL)
            item.tag = b.0
            item.accessibilityIdentifier = "l2.tab." + spec.id
            item.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
            items.append(item)
            stack.addArrangedSubview(item)
        }
        pillWidth?.isActive = false
        pillWidth = pill.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 1.0 / CGFloat(max(1, items.count)), constant: -4)   // Дизайн: шире — подписи с полями внутри выделения
        pillWidth?.isActive = true
        // Сразу привязываем выделение — без этого до первого select() оно прижималось к левому краю.
        select(hasTab(selected) ? selected : (items.first?.tag ?? 0), animated: false)
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func tap(_ c: UIControl) {
        L2.haptic()
        onSelect?(c.tag)
    }

    func select(_ index: Int, animated: Bool = true) {
        for item in items { (item as? Linia2TabItem)?.setSelected(item.tag == index) }
        guard let target = items.first(where: { $0.tag == index }) else { return }
        pillLeading?.isActive = false
        pillLeading = pill.centerXAnchor.constraint(equalTo: target.centerXAnchor)
        pillLeading?.isActive = true
        if !animated { layoutIfNeeded(); return }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.4, options: [.beginFromCurrentState]) {
            self.layoutIfNeeded()
        }
    }
}

private final class Linia2TabItem: UIControl {
    private let icon = UIImageView()
    private let label = UILabel()
    private let symbol: String
    private let symbolSelected: String
    private var remoteIcon: UIImage?
    private(set) var isOn = false
    private static var iconCache: [URL: UIImage] = [:]

    init(title: String, symbol: String, symbolSelected: String, iconURL: URL? = nil) {
        self.symbol = symbol
        self.symbolSelected = symbolSelected
        super.init(frame: .zero)
        if let u = iconURL {
            if let img = Self.iconCache[u] { remoteIcon = img } else {
                URLSession.shared.dataTask(with: u) { [weak self] d, r, _ in
                    guard let d = d, d.count < 500_000, (r as? HTTPURLResponse)?.statusCode == 200,
                          let img = UIImage(data: d, scale: 3)?.withRenderingMode(.alwaysTemplate) else { return }
                    DispatchQueue.main.async {
                        Self.iconCache[u] = img
                        guard let self = self else { return }
                        self.remoteIcon = img
                        self.setSelected(self.isOn)
                    }
                }.resume()
            }
        }
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = L2.font(11, .medium)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            // Дизайн: подпись внутри зелёного выделения (оно уже вкладки на 6 pt с каждой стороны) —
            // «Настройки» на SE больше не вылезает за край выделения.
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        setSelected(false)
    }

    required init?(coder: NSCoder) { return nil }

    func setSelected(_ on: Bool) {
        isOn = on
        icon.image = remoteIcon ?? L2.symbol(on ? symbolSelected : symbol, 20, .medium)
        let color = on ? L2.onAccent : L2.textPrimary
        icon.tintColor = color
        label.textColor = color
        accessibilityTraits = on ? [.button, .selected] : .button
    }
}

// MARK: - Поиск навигатора чатов (вместо «rootViewController as? UINavigationController» из Tinode)

enum Linia2Root {
    static var window: UIWindow? { (UIApplication.shared.delegate as? AppDelegate)?.window }

    /// Навигатор вкладки «Чаты» (или корневой навигатор, если вкладок ещё нет — экран входа).
    static func chatsNavigator() -> UINavigationController? {
        if let tc = window?.rootViewController as? Linia2TabBarController { return tc.chatsNavigator }
        return window?.rootViewController as? UINavigationController
    }

    /// Навигатор, который сейчас на экране (выбранная вкладка).
    static func visibleNavigator() -> UINavigationController? {
        if let tc = window?.rootViewController as? Linia2TabBarController { return tc.selectedViewController as? UINavigationController }
        return window?.rootViewController as? UINavigationController
    }

    /// Плавная смена корневого экрана.
    static func setRoot(_ vc: UIViewController) {
        guard let window = window else { return }
        if vc is Linia2TabBarController, Linia2TestProbe.uiReadyMs < 0 {
            Linia2TestProbe.uiReadyMs = Int(Date().timeIntervalSince(AppDelegate.launchedAt) * 1000)
        }
        if window.rootViewController == nil {
            window.rootViewController = vc
            return
        }
        UIView.transition(with: window, duration: 0.35, options: [.transitionCrossDissolve, .allowAnimatedContent], animations: {
            let old = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            window.rootViewController = vc
            UIView.setAnimationsEnabled(old)
        })
    }
}

// MARK: - Общие переходы для экранов Линии 2.0

extension Linia2Root {
    enum CallKind: Int { case audio = 1, video = 2 }   // = MessageViewController.Constants.kAudioOnlyCall / kVideoCall

    /// Открыть чат (вкладка «Чаты» → экран переписки). Если задан `call` — сразу начать звонок.
    static func openChat(_ topicName: String, call: CallKind? = nil) {
        UiUtils.routeToMessageVC(forTopic: topicName) { mvc in
            guard let mvc = mvc, let call = call else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                mvc.loadViewIfNeeded()
                guard mvc.topic != nil else { return }
                mvc.performSegue(withIdentifier: "Messages2Call", sender: call.rawValue)
            }
        }
    }
}
