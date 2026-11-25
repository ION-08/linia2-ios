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

    static let background = hex(0x0A0E1B)      // фон экранов
    static let surface = hex(0x222839)         // поиск, неактивные фильтры, поле ввода, карточки
    static let surface2 = hex(0x292F42)        // входящие пузыри, кнопки на поверхностях
    static let elevated = hex(0x161D2E)        // круглые кнопки в шапке
    static let tabBar = hex(0x121826)          // плавающее меню
    static let separator = hex(0xFFFFFF, 0.08)
    static let accent = hex(0xB3A0F6)          // активные элементы, бейджи, кнопка отправки
    static let accentStrong = hex(0x8373D3)    // свои пузыри
    static let onAccent = hex(0x14112B)        // текст/иконки на светлом фиолетовом
    static let textPrimary = UIColor.white
    static let textSecondary = hex(0x8A92A3)
    static let online = hex(0x2CE2A6)
    static let callOutgoing = hex(0x2FD1A2)
    static let danger = hex(0xFF6B7A)

    static let radius: CGFloat = 16
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
}

// MARK: - Глобальное оформление

enum Linia2Theme {
    static func apply(to window: UIWindow?) {
        window?.overrideUserInterfaceStyle = .dark
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
        UITextField.appearance().keyboardAppearance = .dark
        UITextView.appearance().keyboardAppearance = .dark
        UISearchBar.appearance().barTintColor = L2.background
        UIPageControl.appearance().currentPageIndicatorTintColor = L2.accent
        UISegmentedControl.appearance().selectedSegmentTintColor = L2.accentStrong
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
        layer.cornerRadius = 26
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
        keyboardAppearance = .dark
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
        icon.frame = CGRect(x: 0, y: 0, width: 46, height: 44)
        leftView = icon
        leftViewMode = .always
        clearButtonMode = .whileEditing
        returnKeyType = .search
        autocorrectionType = .no
        keyboardAppearance = .dark
        heightAnchor.constraint(equalToConstant: 46).isActive = true
    }

    required init?(coder: NSCoder) { return nil }
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
