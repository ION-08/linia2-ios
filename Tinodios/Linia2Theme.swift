//
//  Linia2Theme.swift
//  Линия 2.0: дизайн-система (тёмная тема, фиолетовый акцент, закругления) и общие компоненты.
//

import UIKit

// MARK: - Цвета и шрифты

enum L2 {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// Цвет, который сам выбирает тёмный или светлый вариант по текущей теме.
    static func dyn(_ dark: UInt32, _ light: UInt32, _ da: CGFloat = 1, _ la: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .light ? hex(light, la) : hex(dark, da) }
    }

    // Наборы акцентного цвета: (светлый акцент в тёмной теме, пузырь, текст на акценте, акцент в светлой теме).
    struct AccentSet { let name: String; let accentDark: UInt32; let strong: UInt32; let onAccent: UInt32; let accentLight: UInt32 }
    static let accents: [AccentSet] = [
        AccentSet(name: "Мятный", accentDark: 0x7EE0C3, strong: 0x2FA987, onAccent: 0x0B2A22, accentLight: 0x1F9D7A),
        AccentSet(name: "Фиолетовый", accentDark: 0xB3A0F6, strong: 0x8373D3, onAccent: 0x14112B, accentLight: 0x6E5EC4),
        AccentSet(name: "Синий", accentDark: 0x8FB8FF, strong: 0x4F7FE0, onAccent: 0x0B1730, accentLight: 0x3D6BD0),
        AccentSet(name: "Розовый", accentDark: 0xF6A0C8, strong: 0xD3618F, onAccent: 0x2B1120, accentLight: 0xC24E80),
        AccentSet(name: "Оранжевый", accentDark: 0xFFC08A, strong: 0xE08A3C, onAccent: 0x2B1806, accentLight: 0xC9711F),
    ]
    static var accentSet: AccentSet {
        let i = Linia2Appearance.accentIndex
        return accents.indices.contains(i) ? accents[i] : accents[0]
    }

    /// Цвет из удалённых настроек (тёмная тема) или встроенный.
    private static func rc(_ key: String, _ builtin: UInt32) -> UInt32 { Linia2Config.shared.color(key) ?? builtin }
    /// Цвет светлой темы из удалённых настроек (colorsLight) или встроенный.
    private static func rcl(_ key: String, _ builtin: UInt32) -> UInt32 { Linia2Config.shared.colorLight(key) ?? builtin }
    /// Радиус из удалённых настроек (radii) или встроенный.
    static func r(_ key: String, _ builtin: CGFloat) -> CGFloat { Linia2Config.shared.radius(key, builtin) }
    /// Пользователь оставил цвет по умолчанию — тогда действует цвет с сервера.
    private static var usesServerAccent: Bool { Linia2Appearance.accentIndex == 0 }

    static var background: UIColor { dyn(rc("background", 0x0A0E1B), rcl("background", 0xF4F3FA)) }      // фон экранов
    static var surface: UIColor { dyn(rc("surface", 0x222839), rcl("surface", 0xFFFFFF)) }         // поиск, фильтры, поле ввода, карточки
    static var surface2: UIColor { dyn(rc("surface2", 0x292F42), rcl("surface2", 0xE9E7F3)) }        // входящие пузыри, кнопки на поверхностях
    static var bubbleIn: UIColor { dyn(rc("bubbleIn", 0x292F42), rcl("bubbleIn", 0xE9E7F3)) }
    static var elevated: UIColor { dyn(0x161D2E, 0xFFFFFF) }        // круглые кнопки в шапке
    static var tabBar: UIColor { dyn(0x121826, 0xFFFFFF) }          // плавающее меню
    static var separator: UIColor { dyn(0xFFFFFF, 0x12111C, 0.08, 0.08) }
    static var accent: UIColor {   // активные элементы
        let a = accentSet
        return usesServerAccent ? dyn(rc("accent", a.accentDark), Linia2Config.shared.colorLight("accent") ?? rc("accentLight", a.accentLight)) : dyn(a.accentDark, a.accentLight)
    }
    static var accentStrong: UIColor {   // свои пузыри
        usesServerAccent ? hex(Linia2Config.shared.color("bubbleOut") ?? rc("accentStrong", accentSet.strong)) : hex(accentSet.strong)
    }
    static var onAccent: UIColor { let a = accentSet; return dyn(usesServerAccent ? rc("onAccent", a.onAccent) : a.onAccent, 0xFFFFFF) }
    static var textPrimary: UIColor { dyn(rc("textPrimary", 0xFFFFFF), rcl("textPrimary", 0x12111C)) }
    static var textSecondary: UIColor { dyn(rc("textSecondary", 0x8A92A3), rcl("textSecondary", 0x6B6F80)) }
    static let online = hex(0x2CE2A6)
    static let callOutgoing = hex(0x2FD1A2)
    static var danger: UIColor { hex(Linia2Config.shared.color("danger") ?? 0xFF6B7A) }

    static var radius: CGFloat { r("card", 16) }
    static let fieldHeight: CGFloat = 52

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }

    static func rounded(_ size: CGFloat, _ weight: UIFont.Weight = .bold) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded) { return UIFont(descriptor: d, size: size) }
        return base
    }

    static func symbol(_ name: String, _ size: CGFloat = 20, _ weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    static func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    /// Круг с SF-символом строго по центру (для «+», микрофона, отправки).
    static func circleIcon(_ symbol: String, diameter: CGFloat, fill: UIColor, tint: UIColor, symbolSize: CGFloat? = nil) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            fill.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let sym = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolSize ?? diameter * 0.42, weight: .semibold))?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            if let sym = sym {
                let r = CGRect(x: (diameter - sym.size.width) / 2, y: (diameter - sym.size.height) / 2, width: sym.size.width, height: sym.size.height)
                sym.draw(in: r)
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Глобальное оформление

/// Настройки внешнего вида (сохраняются): тема и акцентный цвет.
enum Linia2Appearance {
    enum Theme: Int { case system = 0, dark = 1, light = 2 }
    private static let kTheme = "linia2.appearance.theme"
    private static let kAccent = "linia2.appearance.accent"

    static var theme: Theme {
        get {
            // Дизайн-контроль (UI-тест): тема из аргумента запуска «-l2-theme dark|light».
            switch UserDefaults.standard.string(forKey: "l2-theme") {
            case "dark"?: return .dark
            case "light"?: return .light
            default: break
            }
            if UserDefaults.standard.object(forKey: kTheme) == nil {
                // Пользователь не выбирал — тема по умолчанию из удалённых настроек.
                switch Linia2Config.shared.defaultTheme { case "light": return .light; case "system": return .system; default: return .dark }
            }
            return Theme(rawValue: UserDefaults.standard.integer(forKey: kTheme)) ?? .dark
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: kTheme) }
    }

    /// Цвет хранится по названию (а не номеру), чтобы изменения списка цветов не сбивали выбор.
    /// Старое значение по номеру (до сборки 10) не используется — у всех по умолчанию мятный.
    private static let kAccentName = "linia2.appearance.accentName"
    static var accentIndex: Int {
        get {
            guard let name = UserDefaults.standard.string(forKey: kAccentName) else { return 0 }
            return L2.accents.firstIndex { $0.name == name } ?? 0
        }
        set {
            UserDefaults.standard.removeObject(forKey: kAccent)
            if L2.accents.indices.contains(newValue) {
                UserDefaults.standard.set(L2.accents[newValue].name, forKey: kAccentName)
            }
        }
    }

    static var interfaceStyle: UIUserInterfaceStyle {
        switch theme { case .system: return .unspecified; case .dark: return .dark; case .light: return .light }
    }
}

enum Linia2Theme {
    static func apply(to window: UIWindow?) {
        window?.overrideUserInterfaceStyle = Linia2Appearance.interfaceStyle
        window?.tintColor = L2.accent
        window?.backgroundColor = L2.background

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = L2.background
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: L2.textPrimary, .font: L2.font(17, .semibold)]
        nav.largeTitleTextAttributes = [.foregroundColor: L2.textPrimary, .font: L2.rounded(34, .bold)]
        let back = UIBarButtonItemAppearance()
        back.normal.titleTextAttributes = [.foregroundColor: L2.accent]
        nav.backButtonAppearance = back
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = L2.accent

        UITableView.appearance().backgroundColor = L2.background
        UITableView.appearance().separatorColor = L2.separator
        UITableViewCell.appearance().backgroundColor = L2.background
        UICollectionView.appearance().backgroundColor = L2.background
        UISwitch.appearance().onTintColor = L2.accentStrong
        UISearchBar.appearance().barTintColor = L2.background
        UIPageControl.appearance().currentPageIndicatorTintColor = L2.accent
        UISegmentedControl.appearance().selectedSegmentTintColor = L2.accentStrong
    }

    /// Применить изменённые тему/цвет ко всему приложению сразу: пересобираем экраны.
    static func reapplyEverywhere(reopen: (() -> UIViewController)? = nil) {
        guard let window = Linia2Root.window else { return }
        apply(to: window)
        for w in UIApplication.shared.windows {
            w.overrideUserInterfaceStyle = Linia2Appearance.interfaceStyle
            w.tintColor = L2.accent
        }
        if window.rootViewController is Linia2TabBarController {
            let tabs = Linia2TabBarController.make()
            window.rootViewController = tabs
            tabs.selectTab(.settings)
            if let vc = reopen?(), let nav = tabs.selectedViewController as? UINavigationController {
                nav.pushViewController(vc, animated: false)
                tabs.updateBarVisibility(animated: false)
            }
        }
    }
}

// MARK: - Логотип «пульс-линия + Линия 2.0»

final class L2PulseView: UIView {
    var lineColor: UIColor = L2.accent { didSet { shape.strokeColor = lineColor.cgColor } }
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = lineColor.cgColor
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Та же линия, что в иконке: точки в системе 1024×1024 (по горизонтали 170…854).
        let pts: [(CGFloat, CGFloat)] = [(170, 560), (330, 560), (400, 380), (500, 700), (590, 300), (670, 560), (854, 560)]
        let w = bounds.width, h = bounds.height
        let sx = w / (854 - 170), sy = h / (700 - 300)
        let s = min(sx, sy)
        let ox = (w - (854 - 170) * s) / 2 - 170 * s, oy = (h - 400 * s) / 2 - 300 * s
        let p = UIBezierPath()
        for (i, pt) in pts.enumerated() {
            let q = CGPoint(x: ox + pt.0 * s, y: oy + pt.1 * s)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        shape.frame = bounds
        shape.path = p.cgPath
        shape.lineWidth = max(1.5, 64 * s)
    }
}

final class L2LogoView: UIStackView {
    init(size: CGFloat = 22) {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = size * 0.35
        let pulse = L2PulseView()
        pulse.widthAnchor.constraint(equalToConstant: size * 1.7).isActive = true
        pulse.heightAnchor.constraint(equalToConstant: size).isActive = true
        let label = UILabel()
        label.text = "Линия 2.0"
        label.font = L2.font(size, .medium)
        label.textColor = L2.textPrimary
        addArrangedSubview(pulse)
        addArrangedSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = "Линия 2.0"
    }

    required init(coder: NSCoder) { super.init(coder: coder) }
}

// MARK: - Кнопки

final class L2CircleButton: UIButton {
    init(symbol: String, size: CGFloat = 44, accessibility: String) {
        super.init(frame: .zero)
        setImage(L2.symbol(symbol, size * 0.42, .medium), for: .normal)
        tintColor = L2.textPrimary
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center
        contentEdgeInsets = .zero
        imageEdgeInsets = .zero
        imageView?.contentMode = .center
        backgroundColor = L2.elevated
        layer.cornerRadius = size / 2
        layer.borderWidth = 1
        layer.borderColor = L2.separator.cgColor
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        accessibilityLabel = accessibility
    }

    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}

final class L2Button: UIButton {
    enum Kind { case primary, secondary, outline, destructive }
    private let kind: Kind

    init(_ title: String, kind: Kind = .primary, symbol: String? = nil) {
        self.kind = kind
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        titleLabel?.font = L2.font(17, .semibold)
        layer.cornerRadius = L2.r("button", 26)
        heightAnchor.constraint(equalToConstant: 52).isActive = true
        if let symbol = symbol {
            setImage(L2.symbol(symbol, 17, .semibold), for: .normal)
            imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
            titleEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: -6)
        }
        switch kind {
        case .primary:
            backgroundColor = L2.accent
            setTitleColor(L2.onAccent, for: .normal)
            tintColor = L2.onAccent
        case .secondary:
            backgroundColor = L2.surface
            setTitleColor(L2.textPrimary, for: .normal)
            tintColor = L2.textPrimary
        case .outline:
            backgroundColor = .clear
            layer.borderWidth = 1.5
            layer.borderColor = L2.accent.cgColor
            setTitleColor(L2.accent, for: .normal)
            tintColor = L2.accent
        case .destructive:
            backgroundColor = L2.surface
            setTitleColor(L2.danger, for: .normal)
            tintColor = L2.danger
        }
        setTitleColor(titleColor(for: .normal)?.withAlphaComponent(0.5), for: .disabled)
    }

    required init?(coder: NSCoder) { return nil }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.75 : 1 } }
    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.6 } }
}

// MARK: - Поле ввода и поиск

final class L2TextField: UITextField {
    init(placeholder: String) {
        super.init(frame: .zero)
        backgroundColor = L2.surface
        textColor = L2.textPrimary
        font = L2.font(17)
        layer.cornerRadius = L2.radius
        layer.borderWidth = 1
        layer.borderColor = UIColor.clear.cgColor
        attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: L2.textSecondary])
        keyboardAppearance = .default
        heightAnchor.constraint(equalToConstant: L2.fieldHeight).isActive = true
    }

    required init?(coder: NSCoder) { return nil }

    var isInvalid = false {
        didSet { layer.borderColor = (isInvalid ? L2.danger : UIColor.clear).cgColor }
    }

    // Без insetBy: при нулевой ширине (до раскладки) он даёт CGRect.null с бесконечными координатами,
    // а это вылет CALayerInvalidGeometry. Считаем прямоугольники вручную, ширина не меньше нуля.
    private func textArea(_ b: CGRect) -> CGRect {
        let right: CGFloat = rightView == nil ? 18 : 48
        return CGRect(x: b.minX + 18, y: b.minY, width: max(0, b.width - 18 - right), height: max(0, b.height))
    }
    override func textRect(forBounds b: CGRect) -> CGRect { textArea(b) }
    override func editingRect(forBounds b: CGRect) -> CGRect { textArea(b) }
    override func placeholderRect(forBounds b: CGRect) -> CGRect { textArea(b) }
    override func rightViewRect(forBounds b: CGRect) -> CGRect {
        CGRect(x: max(0, b.maxX - 44), y: max(0, (b.height - 44) / 2), width: 44, height: min(44, max(0, b.height)))
    }

    /// Кнопка «показать/скрыть пароль».
    func addSecureToggle() {
        isSecureTextEntry = true
        let b = UIButton(type: .system)
        b.setImage(L2.symbol("eye.slash", 16), for: .normal)
        b.tintColor = L2.textSecondary
        b.addTarget(self, action: #selector(toggleSecure(_:)), for: .touchUpInside)
        b.accessibilityLabel = "Показать пароль"
        rightView = b
        rightViewMode = .always
    }

    @objc private func toggleSecure(_ b: UIButton) {
        isSecureTextEntry.toggle()
        b.setImage(L2.symbol(isSecureTextEntry ? "eye.slash" : "eye", 16), for: .normal)
    }
}

final class L2SearchField: UITextField {
    private static let side: CGFloat = 16      // отступ текста слева
    private static let iconBox: CGFloat = 48   // место под лупу справа (иконка по центру, ~16pt от края)

    init(placeholder: String = "Поиск") {
        super.init(frame: .zero)
        backgroundColor = L2.surface
        textColor = L2.textPrimary
        font = L2.font(17)
        layer.cornerRadius = 22
        attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: L2.textSecondary])
        let icon = UIImageView(image: L2.symbol("magnifyingglass", 17, .medium))
        icon.tintColor = L2.textSecondary
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: Self.iconBox, height: 46)
        rightView = icon
        rightViewMode = .always
        clearButtonMode = .never
        returnKeyType = .search
        autocorrectionType = .no
        keyboardAppearance = .default
        accessibilityLabel = placeholder
        heightAnchor.constraint(equalToConstant: 46).isActive = true
    }

    required init?(coder: NSCoder) { return nil }

    private func textArea(_ b: CGRect) -> CGRect {
        CGRect(x: b.minX + Self.side, y: b.minY, width: max(0, b.width - Self.side - Self.iconBox), height: max(0, b.height))
    }
    override func textRect(forBounds b: CGRect) -> CGRect { textArea(b) }
    override func editingRect(forBounds b: CGRect) -> CGRect { textArea(b) }
    override func placeholderRect(forBounds b: CGRect) -> CGRect { textArea(b) }
    override func rightViewRect(forBounds b: CGRect) -> CGRect {
        CGRect(x: max(0, b.maxX - Self.iconBox), y: 0, width: min(Self.iconBox, b.width), height: max(0, b.height))
    }
}

// MARK: - Фильтры-«пилюли»

final class L2Chips: UIStackView {
    var onChange: ((Int) -> Void)?
    private(set) var selected = 0
    private var buttons: [UIButton] = []

    init(_ titles: [String]) {
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 10
        alignment = .leading
        for (i, t) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = L2.font(16, .medium)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
            b.layer.cornerRadius = 20
            b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            b.tag = i
            b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
            buttons.append(b)
            addArrangedSubview(b)
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(spacer)
        render()
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    func select(_ i: Int) { selected = i; render() }

    @objc private func tap(_ b: UIButton) {
        guard b.tag != selected else { return }
        L2.haptic()
        selected = b.tag
        render()
        onChange?(selected)
    }

    private func render() {
        for b in buttons {
            let on = b.tag == selected
            b.backgroundColor = on ? L2.accent : L2.surface
            b.setTitleColor(on ? L2.onAccent : L2.textPrimary, for: .normal)
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}

// MARK: - Шапка экрана вкладки: логотип, крупный заголовок, кнопки справа

final class L2Header: UIView {
    let titleLabel = UILabel()
    let trailing = UIStackView()

    init(title: String, buttons: [UIButton] = [], showLogo: Bool = true) {
        super.init(frame: .zero)
        let logo = L2LogoView(size: 22)
        let logoRow = UIStackView(arrangedSubviews: [logo])
        logoRow.axis = .vertical
        logoRow.alignment = .center
        logoRow.isHidden = !showLogo

        titleLabel.text = title
        titleLabel.font = L2.rounded(34, .heavy)
        titleLabel.textColor = L2.textPrimary
        titleLabel.accessibilityTraits = .header
        trailing.axis = .horizontal
        trailing.spacing = 12
        buttons.forEach { trailing.addArrangedSubview($0) }
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), trailing])
        titleRow.axis = .horizontal
        titleRow.alignment = .center

        let v = UIStackView(arrangedSubviews: [logoRow, titleRow])
        v.axis = .vertical
        v.spacing = 14
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                                     v.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     v.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     v.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }

    required init?(coder: NSCoder) { return nil }
}

// MARK: - Табличная шапка (для UITableView.tableHeaderView): корректный расчёт высоты

final class L2TableHeader: UIView {
    let stack = UIStackView()

    init(_ views: [UIView], spacing: CGFloat = 16) {
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.spacing = spacing
        views.forEach { stack.addArrangedSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                                     stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)])
    }

    required init?(coder: NSCoder) { return nil }

    /// Установить как tableHeaderView с правильной высотой.
    func install(in table: UITableView) {
        let w = table.bounds.width > 0 ? table.bounds.width : UIScreen.main.bounds.width
        frame = CGRect(x: 0, y: 0, width: w, height: 10)
        setNeedsLayout()
        layoutIfNeeded()
        let h = systemLayoutSizeFitting(CGSize(width: w, height: UIView.layoutFittingCompressedSize.height),
                                        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        frame.size.height = h
        table.tableHeaderView = self
    }
}

// MARK: - Аватар-заглушка (буквы) для списков без картинки

enum L2Avatar {
    static let palette: [UInt32] = [0x8373D3, 0x5B8DEF, 0x2FB39A, 0xE07A9B, 0xE0A14A, 0x7C8CF8, 0xB06AE0]

    static func letters(for name: String?) -> String {
        let parts = (name ?? "").split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    static func color(for id: String) -> UIColor {
        var h: UInt32 = 5381
        for c in id.unicodeScalars { h = (h &* 33) &+ c.value }
        return L2.hex(palette[Int(h % UInt32(palette.count))])
    }
}

// MARK: - Пустое состояние

func l2EmptyState(_ title: String, _ subtitle: String, symbol: String) -> UIView {
    let icon = UIImageView(image: L2.symbol(symbol, 40, .regular))
    icon.tintColor = L2.accent
    let t = UILabel()
    t.text = title
    t.font = L2.font(20, .semibold)
    t.textColor = L2.textPrimary
    t.textAlignment = .center
    let s = UILabel()
    s.text = subtitle
    s.font = L2.font(15)
    s.textColor = L2.textSecondary
    s.textAlignment = .center
    s.numberOfLines = 0
    let v = UIStackView(arrangedSubviews: [icon, t, s])
    v.axis = .vertical
    v.alignment = .center
    v.spacing = 10
    let wrap = UIView()
    v.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(v)
    NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                                 v.centerYAnchor.constraint(equalTo: wrap.centerYAnchor, constant: -40),
                                 v.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 32)])
    return wrap
}
