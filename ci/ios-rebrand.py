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
