#!/bin/bash
# Линия 2.0: загрузка dSYM в Firebase Crashlytics (сборочная фаза приложения).
# Работает только для Release и только с настоящим GoogleService-Info.plist (в CI-тестах — заглушка с LINIA2_STUB).
# Ошибка загрузки НЕ ломает сборку (dSYM дополнительно загружается из testflight.yml через upload-symbols).
GSP="${SRCROOT}/GoogleService-Info.plist"
if [ "${CONFIGURATION}" != "Release" ]; then
  echo "Crashlytics: ${CONFIGURATION} — пропуск"; exit 0
fi
if [ ! -f "$GSP" ] || grep -q "LINIA2_STUB" "$GSP" || ! grep -q "GOOGLE_APP_ID" "$GSP"; then
  echo "Crashlytics: нет настоящего GoogleService-Info.plist — пропуск"; exit 0
fi
RUN="${PODS_ROOT}/FirebaseCrashlytics/run"
if [ ! -x "$RUN" ]; then
  echo "warning: Crashlytics: не найден ${RUN}"; exit 0
fi
"$RUN" || echo "warning: Crashlytics: загрузка dSYM из сборки не удалась (будет повторена в CI)"
exit 0
