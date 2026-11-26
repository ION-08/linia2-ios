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
        old_end = s.find("\n        }\n", s.find("            }\n", old_start)) + len("\n        }\n")
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

# =====================================================================
# Дизайн «Линия 2.0» (тёмная тема, вкладки, онбординг) — ноябрь 2026
# =====================================================================
NEW_FILES2 = ["Linia2NewChat.swift", "Linia2Theme.swift", "Linia2TabBar.swift", "Linia2Calls.swift", "Linia2Contacts.swift",
              "Linia2Settings.swift", "Linia2ChatStyle.swift", "Linia2Reactions.swift",
              "Linia2RemoteConfig.swift", "Linia2Profile.swift", "Linia2Report.swift"]
NEW_FILES[:] = NEW_FILES + [f for f in NEW_FILES2 if (R / "Tinodios" / f).exists() and f not in NEW_FILES]
edit("Tinodios.xcodeproj/project.pbxproj", add_files)

ROOT_NAV = "(UIApplication.shared.delegate as! AppDelegate).window?.rootViewController as? UINavigationController"


def uiutils_tabs(s):
    if "Linia2TabBarController.make()" in s:
        return s
    # Экран входа -> «Добро пожаловать»
    s = must(s, '''            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            let destinationVC = storyboard.instantiateViewController(withIdentifier: "StartNavigator") as! UINavigationController

            if let window = (UIApplication.shared.delegate as! AppDelegate).window {
                window.rootViewController = destinationVC
            }
            completion?()''', '''            // LINIA2: первый экран — «Добро пожаловать в Линия 2.0».
            Linia2Root.setRoot(Linia2WelcomeViewController.makeRoot())
            completion?()''')
    # Чаты -> вкладки
    s = must(s, '''            let storyboard = UIStoryboard(name: "Main", bundle: nil)
            let initialViewController = storyboard.instantiateViewController(withIdentifier: "ChatsNavigator") as! UINavigationController
            if let serviceName = SharedUtils.serviceName {
                initialViewController.title = serviceName
            }
            if let window = (UIApplication.shared.delegate as! AppDelegate).window {
                window.rootViewController = initialViewController
            }
            UiUtils.setUpPushNotifications()''', '''            // LINIA2: корень — вкладки Чаты | Звонки | Контакты | Настройки.
            if !(Linia2Root.window?.rootViewController is Linia2TabBarController) {
                Linia2Root.setRoot(Linia2TabBarController.make())
            }
            UiUtils.setUpPushNotifications()''')
    s = s.replace("guard let rootVC = " + ROOT_NAV + " else {", "guard let rootVC = Linia2Root.chatsNavigator() else {")
    # Переход к чату: переключиться на вкладку «Чаты».
    s = must(s, '''            var shouldReplaceRootVC = true
            var rootVC: UINavigationController
            if isShowingChatListVC() {
                rootVC = keyWindow.rootViewController as! UINavigationController''', '''            var shouldReplaceRootVC = true
            var rootVC: UINavigationController
            var newRoot: UIViewController? = nil
            if isShowingChatListVC(), let chatsNav = Linia2Root.chatsNavigator() {
                rootVC = chatsNav
                Linia2TabBarController.current?.selectTab(.chats)''')
    s = must(s, '''                rootVC = storyboard.instantiateViewController(
                    withIdentifier: "ChatsNavigator") as! UINavigationController
                if let serviceName = SharedUtils.serviceName {
                    rootVC.title = serviceName
                }''', '''                let tabs = Linia2TabBarController.make()
                rootVC = tabs.chatsNavigator
                newRoot = tabs''')
    s = must(s, '''            if shouldReplaceRootVC {
                keyWindow.rootViewController = rootVC
            }''', '''            if shouldReplaceRootVC {
                keyWindow.rootViewController = newRoot ?? rootVC
            }''')
    return s


edit("Tinodios/UiUtils.swift", uiutils_tabs)
edit("Tinodios/MessageInteractor.swift", lambda s: s.replace(
    "guard let window = (UIApplication.shared.delegate as! AppDelegate).window, let navVC = window.rootViewController as? UINavigationController else {",
    "guard let navVC = Linia2Root.chatsNavigator() else {"))


def app_delegate_theme(s):
    if "Linia2Theme.apply" in s:
        return s
    s = must(s, "        // LINIA2: блокировка приложения PIN-кодом / Face ID.\n        Linia2AppLock.shared.start()\n",
             "        // LINIA2: тёмная тема с фиолетовым акцентом.\n        Linia2Theme.apply(to: window)\n"
             "        // LINIA2: блокировка приложения PIN-кодом / Face ID.\n        Linia2AppLock.shared.start()\n")
    s = must(s, '''            } else {
                UiUtils.routeToChatListVC()
            }
        }
''', '''            } else {
                UiUtils.routeToChatListVC()
            }
        } else {
            // LINIA2: не вошли — «Добро пожаловать».
            window?.rootViewController = Linia2WelcomeViewController.makeRoot()
        }
''')
    return s


edit("Tinodios/AppDelegate.swift", app_delegate_theme)


def info_dark(s):
    # Тема выбирается в приложении («Внешний вид»), поэтому принудительную тёмную тему не ставим.
    return s.replace("\t<key>UIUserInterfaceStyle</key>\n\t<string>Dark</string>\n", "")


edit("Tinodios/Info.plist", info_dark)
print("done-3")


def chatlist_vc(s):
    if "linia2All" in s:
        return s
    s = must(s, "    var archivedChatsFooter: UIView?\n",
             "    var archivedChatsFooter: UIView?\n"
             "    // LINIA2: поиск и фильтры «Все / Непрочитанные».\n"
             "    var linia2All: [DefaultComTopic] = []\n    var linia2FilterIndex = 0\n    var linia2Query = \"\"\n"
             "    var linia2Header: L2TableHeader?\n    var linia2HeaderWidth: CGFloat = 0\n")
    s = must(s, "        setup()\n\n", "        setup()\n        linia2Setup()\n\n")
    s = must(s, "        self.topics = topics\n        self.archivedTopics = archivedTopics\n",
             "        self.linia2All = topics\n        self.topics = linia2Filtered(topics)\n        self.archivedTopics = archivedTopics\n")
    s = must(s, "        self.rowIndex = Dictionary(uniqueKeysWithValues: topics.enumerated().map { (index, topic) in (topic.name, index) })\n",
             "        self.rowIndex = Dictionary(uniqueKeysWithValues: self.topics.enumerated().map { (index, topic) in (topic.name, index) })\n")
    s = must(s, "    func deleteChat(_ name: String) {\n        assert(Thread.isMainThread)\n",
             "    func deleteChat(_ name: String) {\n        assert(Thread.isMainThread)\n        linia2All.removeAll { $0.name == name }\n")
    s = must(s, "    func displayLoginView() {",
             "    override func viewWillAppear(_ animated: Bool) {\n        super.viewWillAppear(animated)\n"
             "        navigationController?.setNavigationBarHidden(true, animated: animated)\n    }\n\n"
             "    override func viewWillDisappear(_ animated: Bool) {\n        super.viewWillDisappear(animated)\n"
             "        navigationController?.setNavigationBarHidden(false, animated: animated)\n    }\n\n"
             "    override func viewDidLayoutSubviews() {\n        super.viewDidLayoutSubviews()\n        linia2LayoutHeaderIfNeeded()\n    }\n\n"
             "    func displayLoginView() {")
    s = s.replace("button.setTitleColor(UIColor.darkGray, for: .normal)", "button.setTitleColor(L2.accent, for: .normal)")
    s = must(s, "        if show {\n            let rect = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height)",
             "        if show {\n            tableView.backgroundView = linia2EmptyNote()\n            return\n        }\n        if show {\n            let rect = CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height)")
    return s


edit("Tinodios/ChatListViewController.swift", chatlist_vc)
edit("Tinodios/widgets/ChatListViewCell.swift", lambda s: s if "linia2Style" in s else must(
    s, "        icon.set(pub: topic.pub, id: topic.name, online: (topic.isChannel || topic.isSlfType) ? nil : topic.online, deleted: topic.deleted)\n",
    "        icon.set(pub: topic.pub, id: topic.name, online: (topic.isChannel || topic.isSlfType) ? nil : topic.online, deleted: topic.deleted)\n"
    "        icon.linia2StyleIndicator()\n        linia2Style(topic)\n"))
edit("Tinodios/widgets/AvatarWithOnlineIndicator.swift", lambda s: s.replace(
    "static let kOnlineColor = UIColor.init(fromHexCode: 0xFF40C040)", "static let kOnlineColor = L2.online"))
edit("Tinodios/Base.lproj/Main.storyboard", lambda s: s.replace(
    '<segue destination="qBo-ye-avT" kind="show" id="PRK-dk-KAe"/>',
    '<segue destination="qBo-ye-avT" kind="show" identifier="Chats2NewChat" id="PRK-dk-KAe"/>'))
print("done-4")


def message_vc(s):
    if "LINIA2_COLORS" in s:
        return s
    s = must(s, "        static let kOutgoingBubbleColorDark = UIColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 1)",
             "        static let kOutgoingBubbleColorDark = L2.accentStrong  // LINIA2_COLORS: свои — фиолетовые")
    s = must(s, "        static let kOutgoingTextColorDark = UIColor.lightText", "        static let kOutgoingTextColorDark = UIColor.white")
    s = must(s, "        static let kIncomingBubbleColorDark = UIColor(red: 40/255, green: 120/255, blue: 60/255, alpha: 1)",
             "        static let kIncomingBubbleColorDark = L2.surface2")
    s = must(s, "        static let kIncomingTextColorDark = UIColor.lightText", "        static let kIncomingTextColorDark = UIColor.white")
    s = must(s, "        static let kDeletedMessageBubbleColorDark = UIColor(fromHexCode: 0xff263238)",
             "        static let kDeletedMessageBubbleColorDark = L2.surface")
    s = must(s, "        if traitCollection.userInterfaceStyle == .dark {\n            view.backgroundColor = .black\n",
             "        if true {\n            view.backgroundColor = L2.background\n")
    s = must(s, "        let markerTextColor = isFromCurrentSender(message: message) ? UIColor.gray : UIColor.lightText",
             "        let markerTextColor = isFromCurrentSender(message: message) ? UIColor.white.withAlphaComponent(0.75) : L2.textSecondary")
    s = s.replace("attributes: [NSAttributedString.Key.font: Constants.kNewDateFont, NSAttributedString.Key.foregroundColor: UIColor.darkGray])",
                  "attributes: [NSAttributedString.Key.font: Constants.kNewDateFont, NSAttributedString.Key.foregroundColor: L2.textSecondary])")
    s = s.replace("            NSAttributedString.Key.foregroundColor: UIColor.gray\n            ])",
                  "            NSAttributedString.Key.foregroundColor: L2.accent\n            ])")
    s = s.replace("buttonGoToLatest.backgroundColor = .secondarySystemBackground", "buttonGoToLatest.backgroundColor = L2.surface2")
    return s


edit("Tinodios/MessageViewController.swift", message_vc)


def message_display(s):
    if "linia2StyleTitleBar" in s:
        return s
    s = must(s, "        self.navigationItem.setRightBarButtonItems(items, animated: false)\n    }\n",
             "        self.navigationItem.setRightBarButtonItems(items, animated: false)\n"
             "        linia2StyleTitleBar(pub: pub, online: isSlf ? nil : online)\n    }\n")
    s = must(s, "        navBarAvatarView.online = online\n", "        navBarAvatarView.online = online\n        navBarAvatarView.linia2StyleIndicator()\n        linia2SetStatus(online)\n")
    s = must(s, "        navBarAvatarView.presentTypingAnimation(steps: 30)\n", "        navBarAvatarView.presentTypingAnimation(steps: 30)\n        linia2SetTyping()\n")
    return s


edit("Tinodios/MessageViewController+MessageDisplayLogic.swift", message_display)


def send_bar(s):
    if "linia2Style(container" in s:
        return s
    s = must(s, "        nibView.backgroundColor = UIColor.lightGray.withAlphaComponent(0.5)\n",
             "        nibView.backgroundColor = L2.background\n")
    s = must(s, "        showAudioBar(.hidden)\n    }\n", "        showAudioBar(.hidden)\n        linia2Style(container: self)\n    }\n")
    s = s.replace('static let kSendButtonImageWave = UIImage(systemName: "waveform.circle.fill"', 'static let kSendButtonImageWave = UIImage(systemName: "mic.circle.fill"')
    s = s.replace('static let kSendButtonImageWavePressed = UIImage(systemName: "waveform.circle.fill"', 'static let kSendButtonImageWavePressed = UIImage(systemName: "mic.circle.fill"')
    s = s.replace('static let kSendButtonImageArrow = UIImage(systemName: "arrow.up.circle.fill"', 'static let kSendButtonImageArrow = UIImage(systemName: "paperplane.circle.fill"')
    return s


edit("Tinodios/widgets/SendMessageBar.swift", send_bar)
print("done-5")


def message_vc_reactions(s):
    if "linia2Reactions" in s:
        return s
    s = must(s, "    var messages: [Message] = []\n",
             "    var messages: [Message] = []\n"
             "    // LINIA2: реакции — seq сообщения → эмодзи → uid; свои реакции → seq сообщения-реакции.\n"
             "    var linia2Reactions: [Int: [String: [String]]] = [:]\n    var linia2MyReactions: [Int: [String: Int]] = [:]\n")
    s = must(s, "        bubbleDecorator(for: message, at: indexPath)(cell.containerView)\n",
             "        bubbleDecorator(for: message, at: indexPath)(cell.containerView)\n        linia2RenderReactions(cell: cell, message: message)\n")
    s = must(s, "        attr.cellSpacing = Constants.kVerticalCellSpacing\n",
             "        attr.cellSpacing = Constants.kVerticalCellSpacing + linia2ReactionSpacing(for: message.seqId)\n")
    return s


edit("Tinodios/MessageViewController.swift", message_vc_reactions)
edit("Tinodios/MessageViewController+MessageDisplayLogic.swift", lambda s: s if "linia2ExtractReactions" in s else must(
    s, "        let newData: [StoredMessage] = messages\n", "        let newData: [StoredMessage] = linia2ExtractReactions(messages)\n"))
edit("Tinodios/MessageViewController+MessageCellDelegate.swift", lambda s: s if "linia2ReactMenu" in s else must(
    s, '            menuItems.append(MessageMenuItem(title: NSLocalizedString("Reply", comment: "Menu item"), action: #selector(showReplyPreview(sender:)), seqId: cell.seqId))\n',
    '            menuItems.append(MessageMenuItem(title: "Реакция", action: #selector(linia2ReactMenu(sender:)), seqId: cell.seqId))\n'
    '            menuItems.append(MessageMenuItem(title: NSLocalizedString("Reply", comment: "Menu item"), action: #selector(showReplyPreview(sender:)), seqId: cell.seqId))\n'))
print("done-6")
edit("Tinodios/MessageViewController.swift", lambda s: s if "linia2InstallReactionGestures()" in s else must(
    s, "    override func viewDidLoad() {\n        super.viewDidLoad()\n\n        if let layout = collectionView?.collectionViewLayout as? MessageViewLayout {",
    "    override func viewDidLoad() {\n        super.viewDidLoad()\n        defer { linia2InstallReactionGestures() }\n\n        if let layout = collectionView?.collectionViewLayout as? MessageViewLayout {"))


def message_vc_dynamic(s):
    for o, n in [('        static let kOutgoingBubbleColorDark = L2.accentStrong  // LINIA2_COLORS: свои — фиолетовые', '        static var kOutgoingBubbleColorDark: UIColor { L2.accentStrong }  // LINIA2_COLORS: свои — цвет акцента'), ('        static let kOutgoingTextColorDark = UIColor.white', '        static var kOutgoingTextColorDark: UIColor { UIColor.white }'), ('        static let kIncomingBubbleColorDark = L2.surface2', '        static var kIncomingBubbleColorDark: UIColor { L2.surface2 }'), ('        static let kIncomingTextColorDark = UIColor.white', '        static var kIncomingTextColorDark: UIColor { L2.textPrimary }'), ('        static let kDeletedMessageBubbleColorDark = L2.surface', '        static var kDeletedMessageBubbleColorDark: UIColor { L2.surface }'), ('        static let kOutgoingBubbleColorLight = UIColor(red: 244/255, green: 244/255, blue: 244/255, alpha: 1)', '        static var kOutgoingBubbleColorLight: UIColor { L2.accentStrong }'), ('        static let kIncomingBubbleColorLight = UIColor(red: 69/255, green: 193/255, blue: 89/255, alpha: 1)', '        static var kIncomingBubbleColorLight: UIColor { L2.surface2 }'), ('        static let kIncomingTextColorLight = UIColor.white', '        static var kIncomingTextColorLight: UIColor { L2.textPrimary }'), ('        static let kDeletedMessageBubbleColorLight = UIColor(fromHexCode: 0xffe3f2fd)', '        static var kDeletedMessageBubbleColorLight: UIColor { L2.surface }')]:
        s = s.replace(o, n, 1)
    return s


edit("Tinodios/MessageViewController.swift", message_vc_dynamic)


def send_bar_circles(s):
    if "L2.circleIcon" in s:
        return s
    s = re.sub(r'static let kSendButtonImageWave = UIImage\(systemName: "[^"]+".*\n',
               'static var kSendButtonImageWave: UIImage { L2.circleIcon("mic.fill", diameter: 32, fill: L2.accent, tint: L2.onAccent) }\n', s, count=1)
    s = re.sub(r'static let kSendButtonImageWavePressed = UIImage\(systemName: "[^"]+".*\n',
               'static var kSendButtonImageWavePressed: UIImage { L2.circleIcon("mic.fill", diameter: 54, fill: L2.accent, tint: L2.onAccent) }\n', s, count=1)
    s = re.sub(r'static let kSendButtonImageArrow = UIImage\(systemName: "[^"]+".*\n',
               'static var kSendButtonImageArrow: UIImage { L2.circleIcon("paperplane.fill", diameter: 32, fill: L2.accent, tint: L2.onAccent, symbolSize: 14) }\n', s, count=1)
    s = re.sub(r'static let kSendButtonImageEditCheck = UIImage\(systemName: "[^"]+".*\n',
               'static var kSendButtonImageEditCheck: UIImage? { L2.circleIcon("checkmark", diameter: 32, fill: L2.accent, tint: L2.onAccent) }\n', s, count=1)
    return s


edit("Tinodios/widgets/SendMessageBar.swift", send_bar_circles)


def chat_style_attach(s):
    return s.replace('''        attachButton.setImage(L2.symbol("plus", 20, .medium), for: .normal)
        attachButton.tintColor = L2.textPrimary
        attachButton.backgroundColor = L2.surface
        attachButton.layer.cornerRadius = 18
        sendButton.tintColor = L2.accent''', '''        // «+» — круг с плюсом строго по центру (картинка размером с кнопку).
        attachButton.setImage(L2.circleIcon("plus", diameter: 32, fill: L2.surface2, tint: L2.textPrimary), for: .normal)
        attachButton.backgroundColor = .clear
        attachButton.contentHorizontalAlignment = .center
        attachButton.contentVerticalAlignment = .center
        attachButton.imageView?.contentMode = .center
        sendButton.contentHorizontalAlignment = .center
        sendButton.contentVerticalAlignment = .center
        sendButton.imageView?.contentMode = .center''')


edit("Tinodios/Linia2ChatStyle.swift", chat_style_attach)


# ---- Финальные правки: подложка под полем ввода, iOS 15 ----
def send_bar_host_bg(s):
    # LINIA2_HOST_BG v2 (25.11, авария): красим только себя и узкую подложку прямо под полем ввода.
    # Полноэкранные системные слои клавиатуры НЕ трогаем — в сборке 9 они закрывали весь экран чата.
    a = s.find("    // LINIA2_HOST_BG:")
    if a >= 0:
        b = s.index("    // MARK: - Configuration\n", a)
        s = s[:a] + s[b:]
    if "LINIA2_HOST_BG_V2" in s:
        return s
    return must(s, "    // MARK: - Configuration\n",
                "    // LINIA2_HOST_BG_V2: фон панели ввода и полосы под ней — как у приложения; только узкие подложки (не во весь экран).\n"
                "    override func didMoveToWindow() {\n"
                "        super.didMoveToWindow()\n"
                "        backgroundColor = L2.background\n"
                "        guard let host = superview, window != nil else { return }\n"
                "        let screenH = window?.bounds.height ?? UIScreen.main.bounds.height\n"
                "        if host.bounds.height > 0 && host.bounds.height < screenH * 0.4 {\n"
                "            host.backgroundColor = L2.background\n"
                "        }\n"
                "    }\n\n"
                "    // MARK: - Configuration\n")
for proj in ("Tinodios", "TinodeSDK", "TinodiosDB"):
    edit(proj + ".xcodeproj/project.pbxproj", lambda s: re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = 1[0-4]\.\d+;", "IPHONEOS_DEPLOYMENT_TARGET = 15.0;", s))
edit("Podfile", lambda s: s.replace("platform :ios, '14.0'", "platform :ios, '15.0'"))
print("done-final-A")


# (быстрое переподключение при возврате в приложение — ОТКАЧЕНО 25.11: вызывало обрывы соединения)


# ---- Блок B: keepalive WebSocket — мёртвое соединение обнаруживается за секунды, а не минуты ----
# (keepalive WebSocket — ОТКАЧЕН 25.11: вызывал обрывы соединения)


# ---- Сборка 10: зашитые английские строки → Linia2Texts.t(...) (русский) ----
HARDCODED = ["Attachment", "Image / Video", "File", "Cancel", "Take photo", "Camera roll", "Photo library", "Scan QR code",
             "Avatar successfully updated", "Server error", "Failed to connect to server", "Video playback error", "Invalid input",
             "Removed non-existent user.", "Added non-existent user", "Invalid member selection. Try again.",
             "Confirmation code sent", "Credentials confirmed", "Password successfully updated", "Invalid or incorrect code", "Invalid params"]


def ru_hardcoded(s):
    for h in HARDCODED:
        for pre in ("title: ", "message: "):
            s = s.replace('%s"%s"' % (pre, h), '%sLinia2Texts.t("%s")' % (pre, h))
    return s


for f in ["Tinodios/widgets/SendMessageBar.swift", "Tinodios/widgets/ImagePicker.swift", "Tinodios/FindViewController.swift",
          "Tinodios/TopicSecurityViewController.swift", "Tinodios/TopicInfoViewController.swift", "Tinodios/AccountGeneralSettingsViewController.swift",
          "Tinodios/NewGroupViewController.swift", "Tinodios/SettingsSecurityViewController.swift", "Tinodios/CredentialsChangeViewController.swift",
          "Tinodios/AppDelegate.swift", "Tinodios/ResetPasswordViewController.swift", "Tinodios/VideoPreviewController.swift"]:
    edit(f, ru_hardcoded)


def info_plist_ru(s):
    rep = {
        "Линия 2.0 takes photos with the camera to use as avatar or to send them to your contacts": "Камера нужна, чтобы сделать фото профиля или отправить снимок собеседнику",
        "Face ID is used to unlock Линия 2.0": "Face ID используется для разблокировки «Линия 2.0»",
        "Линия 2.0 uses microphone to record audio messages you send to your contacts": "Микрофон нужен для звонков и голосовых сообщений",
        "Линия 2.0 sends only emails and phone numbers to the Линия 2.0 server to help you connect with other users": "«Линия 2.0» использует контакты только для поиска знакомых в приложении",
        "Images and pictures from Линия 2.0 can be saved in the photo library": "Фото и картинки из «Линия 2.0» можно сохранять в медиатеку",
        "Линия 2.0 needs access to your photos to let you you send them to your contacts": "Доступ к фото нужен, чтобы отправлять их собеседникам",
    }
    for a, b in rep.items():
        s = s.replace(a, b)
    return s


edit("Tinodios/Info.plist", info_plist_ru)


# ---- Сборка 10: экран чата одного цвета (область сообщений, панель ввода и полоса под ней) ----
def message_view_bg(s):
    return s.replace('''        if traitCollection.userInterfaceStyle == .dark {
            backgroundColor = .black
        } else {
            backgroundColor = .white
        }''', '''        backgroundColor = L2.background   // LINIA2: как остальное приложение''')


edit("Tinodios/MessageView.swift", message_view_bg)


edit("Tinodios/widgets/SendMessageBar.swift", send_bar_host_bg)


# ---- Сборка 10: история не загружалась («пустой чат», хотя на сервере сообщения есть) ----
# Если локальный кэш пуст, а на сервере в чате есть сообщения — явно запрашиваем последнюю страницу с сервера.
def history_fallback(s):
    if "LINIA2_HISTORY_FALLBACK" in s:
        return s
    s = must(s, '''            if let messagePage = BaseDb.sharedInstance.sqlStore?.getMessagePage(topic: t, from: Int.max, limit: numToLoad, forward: false) {
                // Replace messages with the new page.
                self.messages = messagePage.map { $0 as! StoredMessage }.reversed()
                self.presenter?.presentMessages(messages: self.messages, scrollToMostRecentMessage)
            }''', '''            if let messagePage = BaseDb.sharedInstance.sqlStore?.getMessagePage(topic: t, from: Int.max, limit: numToLoad, forward: false) {
                // Replace messages with the new page.
                self.messages = messagePage.compactMap { $0 as? StoredMessage }.reversed()
                self.presenter?.presentMessages(messages: self.messages, scrollToMostRecentMessage)
            }
            // LINIA2_HISTORY_FALLBACK: кэш пуст, а на сервере есть сообщения — запросить последнюю страницу с сервера (один раз).
            if self.messages.isEmpty, (t.seq ?? 0) > 0, t.attached, !self.linia2HistoryRequested {
                self.linia2HistoryRequested = true
                let q = t.metaGetBuilder().withData(since: nil, before: nil, limit: MessageInteractor.kMessagesPerPage).build()
                t.getMeta(query: q).thenApply { [weak self] _ in
                    self?.loadMessagesFromCache(scrollToMostRecentMessage: true)
                    return nil
                }
            }''')
    s = must(s, "    private static let kMessagesPerPage = 24\n",
             "    private static let kMessagesPerPage = 24\n    private var linia2HistoryRequested = false\n")
    return s


edit("Tinodios/MessageInteractor.swift", history_fallback)


# ---- Авария 25.11: экран чата всегда с шапкой и «назад», свайп назад; «Повторить», если история не загрузилась ----
def chat_safety(s):
    if "LINIA2_CHAT_SAFETY" in s:
        return s
    return must(s, '''    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
''', '''    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // LINIA2_CHAT_SAFETY: шапка с «назад», аватаром и именем видна всегда (другие экраны прячут панель).
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationItem.hidesBackButton = false
        navigationItem.leftItemsSupplementBackButton = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        linia2ScheduleHistoryCheck()
''')


edit("Tinodios/MessageViewController.swift", chat_safety)


# ---- 25.11: нижнее меню видно и внутри чата — поле ввода над меню (пока клавиатура скрыта) ----
def send_bar_above_tabbar(s):
    if "LINIA2_ABOVE_TABBAR" in s:
        return s
    s = s.replace('''    // LINIA2_HOST_BG_V2: фон панели ввода и полосы под ней — как у приложения; только узкие подложки (не во весь экран).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        backgroundColor = L2.background
        guard let host = superview, window != nil else { return }
        let screenH = window?.bounds.height ?? UIScreen.main.bounds.height
        if host.bounds.height > 0 && host.bounds.height < screenH * 0.4 {
            host.backgroundColor = L2.background
        }
    }
''', '''    // LINIA2_ABOVE_TABBAR: пока клавиатура скрыта, под полем ввода — прозрачный отступ высотой с нижнее меню;
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
''')
    s = must(s, '''            nibView.bottomAnchor.constraint(equalTo: bottomAnchor),
            nibView.rightAnchor.constraint(equalTo: rightAnchor),
            nibView.leftAnchor.constraint(equalTo: leftAnchor)
            ])''', '''            nibView.rightAnchor.constraint(equalTo: rightAnchor),
            nibView.leftAnchor.constraint(equalTo: leftAnchor)
            ])
        let bottom = nibView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.isActive = true
        linia2BottomConstraint = bottom
        NotificationCenter.default.addObserver(self, selector: #selector(linia2KeyboardFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(linia2KeyboardFrame(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)''')
    return s


edit("Tinodios/widgets/SendMessageBar.swift", send_bar_above_tabbar)


# Идентификаторы для автотестов в панели ввода чата.
def send_bar_uitest_ids(s):
    if "LINIA2_UITEST_IDS" in s:
        return s
    return must(s, "    private func configure() {\n        horizontalSliderView.alpha = 0.9\n",
                "    private func configure() {\n        // LINIA2_UITEST_IDS: идентификаторы для автотестов.\n"
                "        attachButton.accessibilityIdentifier = \"l2.chat.attach\"\n        attachButton.accessibilityLabel = \"Вложение\"\n"
                "        sendButton.accessibilityIdentifier = \"l2.chat.send\"\n        sendButton.accessibilityLabel = \"Отправить\"\n"
                "        inputField.accessibilityIdentifier = \"l2.chat.input\"\n        horizontalSliderView.alpha = 0.9\n")


edit("Tinodios/widgets/SendMessageBar.swift", send_bar_uitest_ids)
