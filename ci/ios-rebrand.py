#!/usr/bin/env python3
"""Ребрендинг Tinode iOS (v1.24.x) в «Линия 2.0». Запуск: python3 ios-rebrand.py /opt/linia2/ios
Скрипт идемпотентен: повторный запуск ничего не ломает."""
import re
import sys
from pathlib import Path

R = Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/linia2/ios")
TEAM = "MXST7DT8VQ"
BUNDLE = "info.codix.liniya2"
GROUP = "group.info.codix.liniya2.db"
HOST = "v2.chat-linia.site"
NAME = "Линия 2.0"
KEEP_LANGS = {"ru", "Base"}


def edit(path, fn):
    p = R / path
    s = p.read_text(encoding="utf-8")
    n = fn(s)
    if n != s:
        p.write_text(n, encoding="utf-8")
        print("edited", path)


def must(s, old, new, count=1):
    if new in s and old not in s:
        return s
    assert s.count(old) >= 1, "not found: %r" % old[:80]
    return s.replace(old, new) if count == 0 else s.replace(old, new, count)


# ---- xcconfig: сервер, название, версия ----
for cfg in ("prod.xcconfig", "devel.xcconfig"):
    def f(s):
        s = re.sub(r"(?m)^HOST_NAME = .*$", "HOST_NAME = " + HOST, s)
        s = re.sub(r"(?m)^USE_TLS = .*$", "USE_TLS = YES", s)
        s = re.sub(r"(?m)^APP_NAME = .*$", "APP_NAME = " + NAME, s)
        return s
    edit(cfg, f)
edit("prod.xcconfig", lambda s: re.sub(r"(?m)^GIT_TAG = .*$", "GIT_TAG = 1.0.0", re.sub(r"(?m)^GIT_COMMIT_COUNT = .*$", "GIT_COMMIT_COUNT = 1", s)))

# Скрипт номера сборки берёт версию из git-тегов Tinode — в CI версию задаёт workflow.
edit("Scripts/set_build_number.sh", lambda s: s if "LINIA2" in s else s.replace(
    'cd "$SRCROOT"', '# LINIA2: версию и номер сборки задаёт GitHub Actions (см. .github/workflows/testflight.yml).\nexit 0\n\ncd "$SRCROOT"', 1))

# ---- project.pbxproj: Bundle ID, Team, язык ----
BUNDLE_MAP = [
    ("co.tinode.tinodios.TinodiosNSExtension", BUNDLE + ".NSExtension"),
    ("co.tinode.ios.TinodiosUITests", BUNDLE + ".UITests"),
    ("co.tinode.ios.TinodeSDKTests", BUNDLE + ".TinodeSDKTests"),
    ("co.tinode.ios.TinodeSDK", BUNDLE + ".TinodeSDK"),
    ("co.tinode.tinodios.db", BUNDLE + ".db"),
    ("co.tinode.tinodios", BUNDLE),
]


def pbx(s):
    def bid(m):
        v = m.group(2)
        for old, new in BUNDLE_MAP:
            if v == old:
                v = new
                break
        return m.group(1) + v + ";"
    s = re.sub(r"(PRODUCT_BUNDLE_IDENTIFIER = )([^;]+);", bid, s)
    s = re.sub(r'DEVELOPMENT_TEAM = [^;]*;', "DEVELOPMENT_TEAM = %s;" % TEAM, s)
    s = s.replace("developmentRegion = en;", "developmentRegion = ru;")
    return s


for proj in ("Tinodios", "TinodeSDK", "TinodiosDB"):
    edit(proj + ".xcodeproj/project.pbxproj", pbx)


def only_ru(s):
    """Убираем из variant-групп все локализации, кроме ru и Base: приложение всегда на русском."""
    out, in_variant = [], False
    for line in s.splitlines(keepends=True):
        if "isa = PBXVariantGroup;" in line:
            in_variant = True
        elif in_variant and line.strip().startswith("};"):
            in_variant = False
        m = re.match(r"\s*[0-9A-F]{24} /\* (.+?) \*/,\s*$", line)
        if in_variant and m and m.group(1) not in KEEP_LANGS:
            continue
        out.append(line)
    s = "".join(out)
    s = re.sub(r"knownRegions = \((.*?)\);", "knownRegions = (\n\t\t\t\tru,\n\t\t\t\tBase,\n\t\t\t);", s, flags=re.S)
    return s


edit("Tinodios.xcodeproj/project.pbxproj", only_ru)

# ---- Info.plist ----
def info(s):
    s = s.replace("<key>CFBundleDisplayName</key>\n\t<string>Tinode</string>",
                  "<key>CFBundleDisplayName</key>\n\t<string>%s</string>" % NAME)
    s = s.replace("<string>$(DEVELOPMENT_LANGUAGE)</string>", "<string>ru</string>")
    s = s.replace("<string>armv7</string>", "<string>arm64</string>")
    if "ITSAppUsesNonExemptEncryption" not in s:
        s = s.replace("\t<key>LSApplicationCategoryType</key>",
                      "\t<key>ITSAppUsesNonExemptEncryption</key>\n\t<false/>\n\t<key>LSApplicationCategoryType</key>", 1)
    if "CFBundleLocalizations" not in s:
        s = s.replace("\t<key>CFBundleDisplayName</key>",
                      "\t<key>CFBundleLocalizations</key>\n\t<array>\n\t\t<string>ru</string>\n\t</array>\n\t<key>CFBundleDisplayName</key>", 1)
    s = s.replace("Tinode", NAME)  # тексты разрешений (английский фолбэк)
    return s


edit("Tinodios/Info.plist", info)
edit("TinodiosNSExtension/Info.plist", lambda s: s.replace("<string>$(DEVELOPMENT_LANGUAGE)</string>", "<string>ru</string>"))

# ---- entitlements: своя app group, без iCloud и чужих доменов ----
APP_ENT = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>aps-environment</key>
	<string>production</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>%s</string>
	</array>
</dict>
</plist>
""" % GROUP
(R / "Tinodios/Tinodios.entitlements").write_text(APP_ENT, encoding="utf-8")
edit("TinodiosNSExtension/TinodiosNSExtension.entitlements", lambda s: s.replace("group.co.tinode.tinodios.db", GROUP))
edit("Tinodios/Settings.bundle/Root.plist", lambda s: s.replace("group.co.tinode.tinodios.db", GROUP))
for p in R.rglob("*.swift"):
    rel = p.relative_to(R).as_posix()
    if rel.startswith(("Localizations/", "Pods/")):
        continue
    if "group.co.tinode.tinodios.db" in p.read_text(encoding="utf-8"):
        edit(rel, lambda s: s.replace("group.co.tinode.tinodios.db", GROUP))

# ---- русские строки: название и ссылки ----
def ru_strings(s):
    s = s.replace('"https://tinode.co"', '"https://%s"' % HOST)
    s = s.replace('= "Tinode";', '= "%s";' % NAME)
    s = s.replace('"Посмотри Tinode Messenger"', '"Присоединяйся к «%s»"' % NAME)
    s = s.replace('"Посмотри на Tinode Messenger: https://tinode.co/"',
                  '"Присоединяйся к мессенджеру «%s». Попроси у меня приглашение: https://%s/"' % (NAME, HOST))
    s = s.replace("Tinode-у нужно", "Приложению «%s» нужен" % NAME)
    s = s.replace("из Tinode", "из «%s»" % NAME)
    s = s.replace('"Tinode ', '"«%s» ' % NAME)
    return s


for f in ("Tinodios/ru.lproj/Main.strings", "Tinodios/ru.lproj/InfoPlist.strings", "ru.lproj/Localizable.strings"):
    edit(f, ru_strings)

# ---- Swift-код ----
# 1) Не обращаться к hosts.tinode.co (оттуда может прийти чужой адрес сервера).
def no_branding(s):
    if "kLinia2DisableBranding" in s:
        return s
    s = must(s, "    public static func identifyAndConfigureBranding() {\n",
             "    public static func identifyAndConfigureBranding() {\n        // LINIA2: брендинг Tinode отключён, сервер задан в сборке.\n        if SharedUtils.kLinia2DisableBranding { return }\n")
    s = must(s, "    public static func setUpBranding(withConfigurationCode configCode: String) {\n",
             "    public static func setUpBranding(withConfigurationCode configCode: String) {\n        if SharedUtils.kLinia2DisableBranding { return }\n")
    if "kLinia2DisableBranding =" not in s:
        s = must(s, "    // Identifies device with Tinode server and fetches branding configuration code.\n",
                 "    public static let kLinia2DisableBranding = true\n\n    // Identifies device with Tinode server and fetches branding configuration code.\n")
    return s


edit("TinodiosDB/SharedUtils.swift", no_branding)
edit("TinodiosDB/BaseDb.swift", lambda s: s.replace('kBundleId = "co.tinode.tinodios.db"', 'kBundleId = "%s.db"' % BUNDLE))

# 2) Firebase — только если в сборку положен настоящий GoogleService-Info.plist.
FB_CHECK = '''
    /// LINIA2: Firebase (push через FCM) включается, только если в сборке настоящий GoogleService-Info.plist.
    static var firebaseAvailable: Bool {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) else { return false }
        return dict["LINIA2_STUB"] == nil && dict["GOOGLE_APP_ID"] != nil
    }

    private static func setUpPushNotifications() {'''


def fb(s):
    if "firebaseAvailable" in s:
        return s
    s = must(s, "\n    private static func setUpPushNotifications() {", FB_CHECK)
    s = must(s, "        guard !appDelegate.pushNotificationsConfigured else {\n",
             "        guard UiUtils.firebaseAvailable else { return }\n        guard !appDelegate.pushNotificationsConfigured else {\n")
    return s


edit("Tinodios/UiUtils.swift", fb)
edit("Tinodios/Cache.swift", lambda s: s if "firebaseAvailable" in s else must(
    s, "            Messaging.messaging().deleteToken { error in",
    "            if UiUtils.firebaseAvailable { Messaging.messaging().deleteToken { error in"
).replace(
    '                Cache.log.debug("Failed to delete FCM token: %@", error.debugDescription)\n            }\n',
    '                Cache.log.debug("Failed to delete FCM token: %@", error.debugDescription)\n            } }\n', 1))

# 3) Ссылки и регистрация.
edit("Tinodios/AppDelegate.swift", lambda s: s.replace('hasSuffix("tinode.co")', 'hasSuffix("chat-linia.site")'))
edit("Tinodios/SettingsHelpViewController.swift", lambda s: s.replace(
    '"https://tinode.co/terms.html"', '"https://%s/invite/"' % HOST).replace(
    '"https://tinode.co/privacy.html"', '"https://%s/invite/"' % HOST))
edit("Tinodios/FindViewController.swift", lambda s: s.replace(
    '"Check out Tinode Messenger: https://tinode.co/"', '"Check out Tinode Messenger: https://tinode.co/"'))

# Регистрация только по приглашению: кнопка «Зарегистрироваться» открывает страницу приглашений.
def signup(s):
    if "LINIA2" in s:
        return s
    s = must(s, "    override func viewDidLoad() {\n        super.viewDidLoad()\n",
             "    override func viewDidLoad() {\n        super.viewDidLoad()\n"
             "        // LINIA2: регистрация только по приглашению — отправляем на страницу приглашений.\n"
             "        if let url = URL(string: \"https://%s/invite/\") {\n"
             "            DispatchQueue.main.async {\n"
             "                UIApplication.shared.open(url)\n"
             "                self.navigationController?.popViewController(animated: false)\n"
             "            }\n"
             "        }\n" % HOST)
    return s


edit("Tinodios/SignupViewController.swift", signup)
print("done")

# ---- Сервер зашит жёстко, никаких настроек подключения в приложении ----
def fixed_server(s):
    if "LINIA2_FIXED_SERVER" in s:
        return s
    s = must(s, "    static func getConnectionSettings() -> (hostName: String?, useTLS: Bool?) {\n        return (hostName: kAppDefaults.string(forKey: kPrefHostName), useTLS: kAppDefaults.bool(forKey: kPrefUseTLS))\n    }",
             "    // LINIA2_FIXED_SERVER: адрес сервера зашит в приложение и не меняется пользователем.\n    public static let kLinia2Host = \"%s\"\n    static func getConnectionSettings() -> (hostName: String?, useTLS: Bool?) {\n        return (hostName: kLinia2Host, useTLS: true)\n    }" % HOST)
    s = must(s, "    static func setConnectionSettings(_ hostName: String?, _ useTLS: String?) {\n",
             "    static func setConnectionSettings(_ hostName: String?, _ useTLS: String?) {\n        // LINIA2: подменить сервер нельзя — всегда сохраняем фиксированный адрес.\n        let hostName: String? = kLinia2Host, useTLS: String? = \"true\"\n")
    return s


edit("TinodiosDB/SharedUtils.swift", fixed_server)


def login_no_conn(s):
    if "LINIA2" in s:
        return s
    return must(s, "        if let logo = SharedUtils.smallIcon {",
                "        // LINIA2: никаких настроек подключения на экране входа.\n"
                "        self.configureConnectionButton.isHidden = true\n"
                "        self.poweredByStack.isHidden = true\n"
                "        if let logo = SharedUtils.smallIcon {")


edit("Tinodios/LoginViewController.swift", login_no_conn)


def help_no_server(s):
    if "LINIA2" in s:
        return s
    s = must(s, "        let (host, tls) = Tinode.getConnectionParams()\n        serverAddressLabel.text = (tls ? \"https://\" : \"http://\") + host\n",
             "        // LINIA2: адрес сервера пользователю не показываем.\n        serverAddressLabel.text = \"\"\n")
    s = must(s, "    override func viewDidLayoutSubviews() {",
             "    // LINIA2: скрываем строку с адресом сервера.\n"
             "    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {\n"
             "        let cell = super.tableView(tableView, cellForRowAt: indexPath)\n"
             "        if let label = serverAddressLabel, label.isDescendant(of: cell) { return 0.01 }\n"
             "        return super.tableView(tableView, heightForRowAt: indexPath)\n"
             "    }\n\n"
             "    override func viewDidLayoutSubviews() {")
    return s


edit("Tinodios/SettingsHelpViewController.swift", help_no_server)

# Настройки iOS (приложение «Настройки»): убираем раздел «Connection settings».
def root_plist(s):
    i = s.find("<string>ConnectionSettings</string>")
    if i < 0:
        return s
    start = s.rfind("\t\t<dict>", 0, i)
    end = s.find("</dict>", i) + len("</dict>\n")
    return s[:start] + s[end:]


edit("Tinodios/Settings.bundle/Root.plist", root_plist)
cs = R / "Tinodios/Settings.bundle/ConnectionSettings.plist"
if cs.exists():
    cs.unlink()
    print("removed ConnectionSettings.plist")
for l in (R / "Tinodios/Settings.bundle").glob("*.lproj/ConnectionSettings.strings"):
    l.unlink()

# =====================================================================
# Регистрация по коду, TURN по токену, блокировка PIN/Face ID (ноябрь 2026)
# =====================================================================
import hashlib as _hl

NEW_FILES = ["Linia2Registration.swift", "Linia2Turn.swift", "Linia2AppLock.swift"]


def _id(seed):
    return _hl.md5(seed.encode()).hexdigest()[:24].upper()


def add_files(s):
    for name in NEW_FILES:
        if "/* %s */" % name in s:
            continue
        fref, bfile = _id("fref-" + name), _id("bfile-" + name)
        s = s.replace("/* Begin PBXFileReference section */\n",
                      "/* Begin PBXFileReference section */\n\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = \"<group>\"; };\n" % (fref, name, name), 1)
        s = s.replace("/* Begin PBXBuildFile section */\n",
                      "/* Begin PBXBuildFile section */\n\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (bfile, name, fref, name), 1)
        # группа Tinodios
        s = re.sub(r"(0A0380D621B3CC8100A3FA0E /\* Tinodios \*/ = \{\s*isa = PBXGroup;\s*children = \(\n)",
                   lambda m: m.group(1) + "\t\t\t\t%s /* %s */,\n" % (fref, name), s, count=1)
        # фаза Sources цели Tinodios
        s = re.sub(r"(0A0380D021B3CC8100A3FA0E /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = \d+;\s*files = \(\n)",
                   lambda m: m.group(1) + "\t\t\t\t%s /* %s in Sources */,\n" % (bfile, name), s, count=1)
    return s


edit("Tinodios.xcodeproj/project.pbxproj", add_files)


def storyboard(s):
    # «Регистрация» -> экран кода приглашения (через shouldPerformSegue), без «Забыли пароль?».
    s = s.replace('<segue destination="YmQ-cB-rjH" kind="show" id="4U7-tt-Fa7"/>',
                  '<segue destination="YmQ-cB-rjH" kind="show" identifier="Login2Signup" id="4U7-tt-Fa7"/>')
    s = re.sub(r'(<button [^>]*?)( id="q6T-TC-n42")', lambda m: m.group(0) if 'hidden="YES"' in m.group(1) else m.group(1) + ' hidden="YES"' + m.group(2), s, count=1)
    return s


edit("Tinodios/Base.lproj/Main.storyboard", storyboard)
edit("Tinodios/ru.lproj/Main.strings", lambda s: s.replace('"1tv-os-KfJ.normalTitle" = "Регистрация";',
                                                          '"1tv-os-KfJ.normalTitle" = "У меня есть код приглашения";'))


def login_vc(s):
    if "Login2Signup" not in s:
        s = must(s, "    @IBAction func loginClicked(_ sender: Any) {",
                 "    // LINIA2: «У меня есть код приглашения» — свой экран регистрации по коду.\n"
                 "    override func shouldPerformSegue(withIdentifier identifier: String, sender: Any?) -> Bool {\n"
                 "        if identifier == \"Login2Signup\" {\n"
                 "            navigationController?.pushViewController(Linia2InviteCodeViewController(), animated: true)\n"
                 "            return false\n"
                 "        }\n"
                 "        return super.shouldPerformSegue(withIdentifier: identifier, sender: sender)\n"
                 "    }\n\n"
                 "    @IBAction func loginClicked(_ sender: Any) {")
    s = s.replace('                            toastMsg = "Tinode: \\(tinodeErr.description)"',
                  '                            // LINIA2: понятные сообщения на русском.\n'
                  '                            if case .serverResponseError(let code, _, _) = tinodeErr, code == 401 || code == 403 {\n'
                  '                                toastMsg = "Неверный логин или пароль. После 5 ошибок вход блокируется на 15 минут."\n'
                  '                            } else {\n'
                  '                                toastMsg = "Ошибка входа: \\(tinodeErr.description)"\n'
                  '                            }')
    if "Linia2Turn.shared.prefetch()" not in s:
      s = s.replace('                        UiUtils.routeToChatListVC()\n                        return nil\n                    }, onFailure: { err in\n                        Cache.log.error("LoginVC - login failed',
                  '                        Linia2Turn.shared.prefetch()\n                        UiUtils.routeToChatListVC()\n                        return nil\n                    }, onFailure: { err in\n                        Cache.log.error("LoginVC - login failed')
    return s


edit("Tinodios/LoginViewController.swift", login_vc)


def signup_vc(s):
    old_start = s.find("        // LINIA2: регистрация только по приглашению")
    if old_start >= 0 and "Linia2InviteCodeViewController" not in s:
        old_end = s.find("        }\n", s.find("            }\n", old_start)) + len("        }\n")
        s = s[:old_start] + (
            "        // LINIA2: регистрация только по коду приглашения — подменяем экран Tinode своим.\n"
            "        DispatchQueue.main.async {\n"
            "            guard let nav = self.navigationController else { return }\n"
            "            var stack = nav.viewControllers.filter { $0 !== self }\n"
            "            stack.append(Linia2InviteCodeViewController())\n"
            "            nav.setViewControllers(stack, animated: false)\n"
            "        }\n") + s[old_end:]
    return s


edit("Tinodios/SignupViewController.swift", signup_vc)


def call_vc(s):
    if "Linia2Turn" in s:
        return s
    return must(s, "        return config\n    }\n\n    private func createMediaSenders() {",
                "        // LINIA2: TURN с временным паролем, выданным нашим сервером после входа.\n"
                "        config.iceServers.append(contentsOf: Linia2Turn.shared.iceServers())\n"
                "        return config\n    }\n\n    private func createMediaSenders() {")


edit("Tinodios/CallViewController.swift", call_vc)


def app_delegate(s):
    if "Linia2AppLock" in s:
        return s
    s = must(s, "        SharedUtils.registerUserDefaults()\n",
             "        SharedUtils.registerUserDefaults()\n        // LINIA2: блокировка приложения PIN-кодом / Face ID.\n        Linia2AppLock.shared.start()\n")
    s = must(s, "    func applicationDidBecomeActive(_ application: UIApplication) {\n",
             "    func applicationDidBecomeActive(_ application: UIApplication) {\n        Linia2Turn.shared.prefetch()\n")
    return s


edit("Tinodios/AppDelegate.swift", app_delegate)
edit("Tinodios/UiUtils.swift", lambda s: s if "resetOnLogout" in s else must(
    s, "    public static func logoutAndRouteToLoginVC() {\n",
    "    public static func logoutAndRouteToLoginVC() {\n        Linia2AppLock.shared.resetOnLogout()\n"))


def security_vc(s):
    if "Linia2AppLockSettingsViewController" in s:
        return s
    s = must(s, "    override func viewDidLoad() {\n        super.viewDidLoad()\n",
             "    override func viewDidLoad() {\n        super.viewDidLoad()\n"
             "        // LINIA2: пункт «Блокировка приложения» (PIN-код / Face ID).\n"
             "        let footer = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 76))\n"
             "        let lockButton = UIButton(type: .system)\n"
             "        lockButton.setTitle(\"Блокировка приложения (PIN-код, Face ID)\", for: .normal)\n"
             "        lockButton.titleLabel?.font = .systemFont(ofSize: 17)\n"
             "        lockButton.setTitleColor(Linia2Style.green, for: .normal)\n"
             "        lockButton.translatesAutoresizingMaskIntoConstraints = false\n"
             "        lockButton.addTarget(self, action: #selector(linia2LockTapped), for: .touchUpInside)\n"
             "        footer.addSubview(lockButton)\n"
             "        NSLayoutConstraint.activate([lockButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),\n"
             "                                     lockButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])\n"
             "        tableView.tableFooterView = footer\n")
    s = s.rstrip()
    assert s.endswith("}")
    s = s[:-1].rstrip() + "\n\n    @objc func linia2LockTapped() {\n        navigationController?.pushViewController(Linia2AppLockSettingsViewController(), animated: true)\n    }\n}\n"
    return s


edit("Tinodios/SettingsSecurityViewController.swift", security_vc)


def faceid_plist(s):
    if "NSFaceIDUsageDescription" in s:
        return s
    return s.replace("\t<key>NSMicrophoneUsageDescription</key>",
                     "\t<key>NSFaceIDUsageDescription</key>\n\t<string>Face ID is used to unlock %s</string>\n\t<key>NSMicrophoneUsageDescription</key>" % NAME, 1)


edit("Tinodios/Info.plist", faceid_plist)
edit("Tinodios/ru.lproj/InfoPlist.strings", lambda s: s if "NSFaceIDUsageDescription" in s else
     s.rstrip("\n") + '\n/* Privacy - Face ID Usage Description */\n"NSFaceIDUsageDescription" = "Face ID используется, чтобы разблокировать «%s»";\n' % NAME)
print("done-2")
