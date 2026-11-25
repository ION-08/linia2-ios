# Линия 2.0 — iOS

Мессенджер «Линия 2.0» (Bundle ID `info.codix.liniya2`, Team `MXST7DT8VQ`) для сервера
https://v2.chat-linia.site. Основан на официальном клиенте Tinode iOS v1.24.4
(https://github.com/tinode/ios, лицензия Apache 2.0, см. `LICENSE` и `README.tinode.md`).

## Что изменено относительно Tinode
- название «Линия 2.0», новая иконка, Bundle ID / Team ID, app group `group.info.codix.liniya2.db`;
- сервер по умолчанию `v2.chat-linia.site` (HTTPS/WSS);
- интерфейс только на русском (в сборку попадают лишь ru-локализации);
- отключено обращение к hosts.tinode.co (брендинг Tinode мог подменить сервер);
- Firebase/FCM включается, только если задан секрет `GOOGLE_SERVICE_INFO_PLIST_BASE64`;
- регистрация в приложении ведёт на страницу приглашений (сервер принимает новых
  пользователей только по ссылке-приглашению);
- убраны iCloud и associated domains Tinode.
Все правки делает скрипт `ios-rebrand.py` (лежит на сервере в /opt/linia2) — его можно
повторно применить к новой версии Tinode.

## Сборка
Мака не нужно: GitHub Actions → workflow **TestFlight** (`.github/workflows/testflight.yml`)
собирает на macOS-раннере и загружает сборку в TestFlight. Запуск — при push в `main` или
вручную (Actions → TestFlight → Run workflow). Версия — файл `VERSION`, номер сборки —
номер запуска workflow.

Секреты репозитория: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`
(ключ App Store Connect API с ролью Admin), необязательно `GOOGLE_SERVICE_INFO_PLIST_BASE64`.
