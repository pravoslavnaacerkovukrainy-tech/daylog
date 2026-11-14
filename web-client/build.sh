#!/bin/bash
# Сборка «Хаос Дня Веб» — оболочки WKWebView над https://day.osintradar.net/.
# Отдельный bundle ID local.chaosday.web; старый клиент и plan-client не затрагиваются.
# Подпись ad hoc, без Связки ключей. Сборка идёт во временной папке вне Documents
# (FileProvider может добавить атрибуты и сломать codesign), затем копируется в build/web/.
#
#   ./build.sh           release: только рабочий сайт, без debug-флагов
#   ./build.sh --debug   debug: + --debug-url <loopback> и --smoke, Web Inspector; в ZIP не идёт
set -euo pipefail
cd "$(dirname "$0")"
source ../plan-client/sdk.sh   # общий выбор SDK, только чтение
ROOT="$(cd .. && pwd)"
OUT="$ROOT/build/web"
mkdir -p "$OUT"

MODE=release
[[ "${1:-}" == "--debug" ]] && MODE=debug
NAME="Хаос Дня Веб"
FLAGS=(-O)
[[ $MODE == debug ]] && FLAGS=(-Onone -g -D CHAOS_WEB_DEBUG)
echo "→ SDK: $PLAN_SDK ($MODE)"

STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/web-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Компиляция…"
xcrun swiftc -module-cache-path "$OUT/ModuleCache" -swift-version 5 "${FLAGS[@]}" \
  -sdk "$PLAN_SDK" -target "$PLAN_TARGET" -module-name ChaosDayWeb \
  -o "$APP/Contents/MacOS/ChaosDayWeb" \
  Sources/Core/*.swift Sources/App/*.swift

cat Resources/Info.plist > "$APP/Contents/Info.plist"
cat "$ROOT/Resources/AppIcon.icns" > "$APP/Contents/Resources/AppIcon.icns"   # общая иконка, только чтение
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ $MODE == release ]] && strings "$APP/Contents/MacOS/ChaosDayWeb" | grep -Eq -- '--debug-url|--smoke'; then
  echo "ОШИБКА: debug-флаги попали в release" >&2; exit 1
fi

echo "→ Подпись ad hoc и проверка…"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" = "local.chaosday.web"

if [[ $MODE == debug ]]; then
  rm -rf "$OUT/debug/$NAME.app"; mkdir -p "$OUT/debug"
  ditto --norsrc --noextattr --noacl "$APP" "$OUT/debug/$NAME.app"
  echo; echo "Готово (debug): $OUT/debug/$NAME.app"
  exit 0
fi

ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$STAGE/Chaos-Day-Web.zip"
cat "$STAGE/Chaos-Day-Web.zip" > "$OUT/Chaos-Day-Web.zip"
rm -rf "$OUT/$NAME.app"
ditto --norsrc --noextattr --noacl "$APP" "$OUT/$NAME.app"

echo
echo "Готово: $OUT/$NAME.app (bundle ID local.chaosday.web)"
echo "ZIP:    $OUT/Chaos-Day-Web.zip"
