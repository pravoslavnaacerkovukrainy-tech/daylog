#!/bin/bash
# Сборка экспериментального клиента «Хаос Дня План» (отдельный бандл local.chaosday.plan.pilot).
# Старое приложение и его файлы не затрагиваются. Подпись ad hoc, без Связки ключей.
# Бандл собирается и проверяется во временной папке вне Documents (FileProvider может
# добавить атрибуты и сломать codesign), затем копируется в build/plan/.
set -euo pipefail
cd "$(dirname "$0")"
source ./sdk.sh
ROOT="$(cd .. && pwd)"
OUT="$ROOT/build/plan"
mkdir -p "$OUT"
echo "→ SDK: $PLAN_SDK"

STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/plan-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
NAME="Хаос Дня План"
APP="$STAGE/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Компиляция…"
xcrun swiftc -module-cache-path "$OUT/ModuleCache" -swift-version 5 -parse-as-library -O \
  -sdk "$PLAN_SDK" -target "$PLAN_TARGET" -module-name ChaosDayPlan \
  -o "$APP/Contents/MacOS/ChaosDayPlan" \
  Sources/SyncCore/*.swift Sources/PlanApp/*.swift

cat Resources/Info.plist > "$APP/Contents/Info.plist"
cat "$ROOT/Resources/AppIcon.icns" > "$APP/Contents/Resources/AppIcon.icns"   # общая иконка, только чтение
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ Подпись ad hoc и проверка…"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" = "local.chaosday.plan.pilot"

ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$STAGE/Chaos-Day-Plan-Pilot.zip"
cat "$STAGE/Chaos-Day-Plan-Pilot.zip" > "$OUT/Chaos-Day-Plan-Pilot.zip"
rm -rf "$OUT/$NAME.app"
ditto --norsrc --noextattr --noacl "$APP" "$OUT/$NAME.app"

echo
echo "Готово: $OUT/$NAME.app (bundle ID local.chaosday.plan.pilot)"
echo "Запуск с изолированными данными:"
echo "  CHAOS_PLAN_DATA_DIR=/tmp/plan-demo \"$OUT/$NAME.app/Contents/MacOS/ChaosDayPlan\""
echo "  или: open -n \"$OUT/$NAME.app\" --args --data /tmp/plan-demo"
