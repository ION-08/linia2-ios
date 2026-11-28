//
//  Linia2Splash.swift
//  Линия 2.0: анимация загрузки — «бегущий импульс» по кардиограмме логотипа.
//
//  1) Linia2Splash — сразу после запуска поверх всего тот же кадр, что LaunchScreen (фон LaunchBackground,
//     logo-ios 256×256 по центру), и по линии логотипа бежит импульс (~1,2 с цикл). Убирается, как только
//     показан первый экран (PIN / вкладки / «Добро пожаловать») — ready(); запасной таймер 4 с.
//     Окно не принимает касаний и ничего не ждёт: запуск не задерживается.
//  2) Linia2PulseLine — та же линия в маленьком виде (плашка «Подключение…»).
//  Reduce Motion — без анимации (статичная линия / логотип). VoiceOver — «Загрузка».
//

import UIKit

/// Кардиограмма логотипа (branding/icon-mint.svg, координаты 1024×1024).
enum Linia2LogoPath {
    static let points: [CGPoint] = [CGPoint(x: 170, y: 540), CGPoint(x: 330, y: 540), CGPoint(x: 400, y: 360),
                                    CGPoint(x: 500, y: 680), CGPoint(x: 590, y: 280), CGPoint(x: 670, y: 540),
                                    CGPoint(x: 854, y: 540)]

    /// Путь в прямоугольнике `rect`, куда вписан квадрат 1024×1024 (scale = rect.width / 1024).
    static func path(in rect: CGRect) -> UIBezierPath {
        let s = rect.width / 1024
        let p = UIBezierPath()
        for (i, pt) in points.enumerated() {
            let q = CGPoint(x: rect.minX + pt.x * s, y: rect.minY + pt.y * s)
            i == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        return p
    }

    /// Только линия (без пустых полей квадрата): x 170…854, y 280…680 → вписать в rect с сохранением пропорций.
    static func tightPath(in rect: CGRect) -> UIBezierPath {
        let src = CGRect(x: 170, y: 280, width: 684, height: 400)
        let s = min(rect.width / src.width, rect.height / src.height)
        let ox = rect.midX - src.width * s / 2, oy = rect.midY - src.height * s / 2
        let p = UIBezierPath()
        for (i, pt) in points.enumerated() {
            let q = CGPoint(x: ox + (pt.x - src.minX) * s, y: oy + (pt.y - src.minY) * s)
            i == 0 ? p.move(to: q) : p.addLine(to: q)
        }
        return p
    }

    /// «Бегущий импульс»: голова (strokeEnd) и хвост (strokeStart) идут вдоль линии со сдвигом.
    static func pulseAnimation(duration: CFTimeInterval = 1.2) -> CAAnimationGroup {
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = [0, 1, 1]
        end.keyTimes = [0, 0.75, 1]
        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = [0, 0, 1]
        start.keyTimes = [0, 0.25, 1]
        let g = CAAnimationGroup()
        g.animations = [end, start]
        g.duration = duration
        g.repeatCount = .infinity
        g.timingFunction = CAMediaTimingFunction(name: .linear)
        g.isRemovedOnCompletion = false
        return g
    }

    static let pulseColor = L2.hex(0x2BE07F)
    static let coreColor = L2.hex(0xE6FFF2)
}

// MARK: - Маленькая пульсирующая линия

final class Linia2PulseLine: UIView {
    private let base = CAShapeLayer()
    private let glow = CAShapeLayer()

    var lineColor: UIColor = Linia2LogoPath.pulseColor { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for l in [base, glow] {
            l.fillColor = UIColor.clear.cgColor
            l.lineCap = .round
            l.lineJoin = .round
            layer.addSublayer(l)
        }
        glow.strokeStart = 0
        glow.strokeEnd = 0
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: 22, height: 13) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = Linia2LogoPath.tightPath(in: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
        let w = max(1.5, bounds.height / 8)
        base.path = path
        base.lineWidth = w
        glow.path = path
        glow.lineWidth = w
        glow.strokeColor = lineColor.cgColor
        updateAnimation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    @objc private func motionChanged() { updateAnimation() }

    private func updateAnimation() {
        let reduce = UIAccessibility.isReduceMotionEnabled
        // Reduce Motion — статичная линия полной яркости; иначе тусклая линия + бегущий импульс.
        base.strokeColor = lineColor.withAlphaComponent(reduce ? 1 : 0.35).cgColor
        glow.isHidden = reduce
        if window != nil && !reduce {
            if glow.animation(forKey: "pulse") == nil { glow.add(Linia2LogoPath.pulseAnimation(), forKey: "pulse") }
        } else {
            glow.removeAnimation(forKey: "pulse")
        }
    }
}

// MARK: - Заставка запуска

enum Linia2Splash {
    private static var window: UIWindow?
    private static var shownAt: Date?
    private static var holdUntil: Date?
    private static var preparedLogo: UIImage?
    /// Первый экран уже показан до show() — заставка не нужна.
    private static var screenReady = false
    private static let prepQueue = DispatchQueue(label: "linia2.splash.prep", qos: .userInitiated)

    /// UI-тест (дизайн-снимок): «-l2-splash-hold» — держать заставку 6 с, анимация остановлена в середине цикла.
    private static var testHold: Bool {
        Linia2TestHook.enabled && ProcessInfo.processInfo.arguments.contains("-l2-splash-hold")
    }

    /// Самое начало запуска: декодировать логотип вне главного потока (к моменту show() он готов).
    static func prepare() {
        prepQueue.async {
            let img = UIImage(named: "logo-ios")?.preparingForDisplay()
            DispatchQueue.main.async { if preparedLogo == nil { preparedLogo = img } }
        }
    }

    /// Конец didFinishLaunching: показать кадр LaunchScreen + бегущий импульс. Окно рисуется вместе
    /// с первым кадром приложения — запуск не ждёт заставку.
    static func show() {
        guard window == nil, !screenReady || testHold, UIApplication.shared.applicationState != .background else {
            preparedLogo = nil
            return
        }
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.windowLevel = .alert + 3
        w.isUserInteractionEnabled = false
        // Как LaunchScreen — по системной теме (тема приложения — плавный переход фона ниже).
        w.overrideUserInterfaceStyle = .unspecified
        let vc = Linia2SplashViewController(logo: preparedLogo ?? UIImage(named: "logo-ios"), frozen: testHold)
        w.rootViewController = vc
        w.isHidden = false
        window = w
        shownAt = Date()
        if testHold { holdUntil = Date().addingTimeInterval(6) }
        // Запасной выход: что бы ни случилось — не дольше 4 с (в тесте — после удержания).
        DispatchQueue.main.asyncAfter(deadline: .now() + (testHold ? 6.2 : 4)) { hide(reason: "timeout") }
    }

    /// Первый экран готов (PIN / вкладки / «Добро пожаловать»).
    static func ready(_ reason: String) {
        guard window != nil else { screenReady = true; return }
        if let h = holdUntil, Date() < h { return }
        hide(reason: reason)
    }

    private static func hide(reason: String) {
        guard let w = window else { return }
        window = nil
        preparedLogo = nil
        let ms = Int(Date().timeIntervalSince(shownAt ?? Date()) * 1000)
        Linia2LaunchLog.shared.step("splash-hide", ["ms": ms, "why": reason == "timeout" ? 1 : 0])
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            w.alpha = 0
        }, completion: { _ in
            w.isHidden = true
            w.rootViewController = nil
        })
    }
}

private final class Linia2SplashViewController: UIViewController {
    private let logo: UIImage?
    private let frozen: Bool
    private let logoView = UIImageView()
    private let glow = CAShapeLayer()
    private let core = CAShapeLayer()
    private var laidOut = CGRect.null

    init(logo: UIImage?, frozen: Bool) {
        self.logo = logo
        self.frozen = frozen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let v = UIView(frame: UIScreen.main.bounds)
        v.backgroundColor = UIColor(named: "LaunchBackground") ?? L2.hex(0x0A0E1B)
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Точно как LaunchScreen.storyboard: 256×256, по центру, scaleAspectFit.
        logoView.image = logo
        logoView.contentMode = .scaleAspectFit
        logoView.clipsToBounds = true
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.isAccessibilityElement = true
        logoView.accessibilityLabel = "Загрузка"
        logoView.accessibilityTraits = [.image, .updatesFrequently]
        logoView.accessibilityIdentifier = "l2.splash"
        view.addSubview(logoView)
        NSLayoutConstraint.activate([logoView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     logoView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                     logoView.widthAnchor.constraint(equalToConstant: 256),
                                     logoView.heightAnchor.constraint(equalToConstant: 256)])

        // Импульс поверх линии логотипа: широкое свечение + яркая сердцевина.
        let s: CGFloat = 256.0 / 1024.0
        glow.lineWidth = 64 * s
        glow.strokeColor = Linia2LogoPath.pulseColor.cgColor
        glow.shadowColor = Linia2LogoPath.pulseColor.cgColor
        glow.shadowRadius = 8
        glow.shadowOpacity = 0.9
        glow.shadowOffset = .zero
        core.lineWidth = 30 * s
        core.strokeColor = Linia2LogoPath.coreColor.withAlphaComponent(0.95).cgColor
        for l in [glow, core] {
            l.fillColor = UIColor.clear.cgColor
            l.lineCap = .round
            l.lineJoin = .round
            l.strokeStart = 0
            l.strokeEnd = 0
            logoView.layer.addSublayer(l)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard logoView.bounds != laidOut, !logoView.bounds.isEmpty else { return }
        laidOut = logoView.bounds
        let path = Linia2LogoPath.path(in: logoView.bounds).cgPath
        glow.path = path
        core.path = path
        startPulse()
        fadeToAppBackground()
    }

    private func startPulse() {
        // Reduce Motion — статичный логотип (как LaunchScreen), без импульса.
        guard !UIAccessibility.isReduceMotionEnabled, glow.animation(forKey: "pulse") == nil else { return }
        for l in [glow, core] {
            let a = Linia2LogoPath.pulseAnimation()
            if frozen {
                // Дизайн-снимок: кадр из середины цикла (импульс на пиках кардиограммы).
                a.speed = 0
                a.timeOffset = 0.6
            }
            l.add(a, forKey: "pulse")
        }
    }

    /// Фон — из цвета LaunchScreen (системная тема) к фону приложения (выбранная тема): без вспышки при уходе.
    private func fadeToAppBackground() {
        guard view.tag == 0 else { return }
        view.tag = 1
        var style = Linia2Appearance.interfaceStyle
        if style == .unspecified { style = traitCollection.userInterfaceStyle }
        let target = L2.background.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        let options: UIView.AnimationOptions = UIAccessibility.isReduceMotionEnabled ? [] : [.curveEaseInOut]
        UIView.animate(withDuration: 0.35, delay: 0.1, options: options, animations: {
            self.view.backgroundColor = target
        })
    }
}
