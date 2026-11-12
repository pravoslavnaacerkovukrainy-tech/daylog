#!/bin/bash
# Сборка «Хаос Дня» без Xcode: swiftc из Command Line Tools.
#
# Папка проекта лежит в ~/Documents, где FileProvider может в любой момент добавить
# com.apple.FinderInfo на бандл — из-за этого codesign отказывался подписывать.
# Поэтому бандл собирается, подписывается, проверяется и упаковывается в ZIP
# во временной папке ВНЕ Documents (системный TMPDIR), и только готовый ZIP
# копируется в build/. Атрибуты безопасности (quarantine/provenance) не трогаются.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$(pwd)"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
SDK="${DAYLOG_SDK_PATH:-$(xcrun --show-sdk-path --sdk macosx)}"

# Некоторые CLT поставляются с SDK 27.2 без плагина SwiftUIMacros.
# Если установлен совместимый SDK, используем его для обычных @State.
SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
SWIFTUI_INTERFACE="$SDK/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
COMPATIBLE_SDK="$(dirname "$SDK")/MacOSX26.5.sdk"
if [[ -z "${DAYLOG_SDK_PATH:-}" && -d "$COMPATIBLE_SDK" && ! -f "$SWIFT_BIN/../lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] &&
   grep -q 'public macro State' "$SWIFTUI_INTERFACE" 2>/dev/null; then
  SDK="$COMPATIBLE_SDK"
fi
echo "→ SDK: $SDK"

STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/daylog-build.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

APP="$STAGE/Хаос Дня.app"
ZIP="$STAGE/Chaos-Day-Mac.zip"
CHECK="$STAGE/check"

echo "→ Временная папка сборки: $STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CHECK"

echo "→ Компиляция ($TARGET)…"
xcrun swiftc \
  -module-cache-path "$PROJECT/build/ModuleCache" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -sdk "$SDK" \
  -target "$TARGET" \
  -module-name Daylog \
  -o "$APP/Contents/MacOS/Daylog" \
  Sources/Core/*.swift Sources/App/*.swift

# Только содержимое файлов, без расширенных атрибутов исходника.
cat Resources/Info.plist > "$APP/Contents/Info.plist"
cat Resources/AppIcon.icns > "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Подпись. Если на этой машине есть локальная code-signing идентичность
# (по умолчанию «Daylog Local Signing»), подписываем ею: её designated requirement
# стабилен между пересборками, поэтому сохраняется доступ к ключу Groq в Связке ключей.
# Идентификатор бандла остаётся local.daylog.app. Если идентичности нет (чистый клон, другой Mac,
# публичная сборка) — подпись ad hoc, как раньше. Сертификат в репозиторий не входит.
# DAYLOG_ADHOC_SIGN=1 проверяет сборку без обращения к Keychain.
SIGN_ID="${DAYLOG_SIGN_ID:-Daylog Local Signing}"
if [[ "${DAYLOG_ADHOC_SIGN:-0}" != "1" ]] && security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
  echo "→ Подпись локальной идентичностью и строгая проверка (вне Documents)…"
  codesign --force --sign "$SIGN_ID" "$APP"
else
  echo "→ Подпись ad hoc и строгая проверка (вне Documents)…"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "→ ZIP без ресурсных вилок и расширенных атрибутов…"
ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$ZIP"

echo "→ Проверка распакованной копии (вне Documents)…"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --strict --verbose=2 "$CHECK/Хаос Дня.app"
test -x "$CHECK/Хаос Дня.app/Contents/MacOS/Daylog"

echo "→ Копирование результатов в build/…"
mkdir -p "$PROJECT/build"
cat "$ZIP" > "$PROJECT/build/Chaos-Day-Mac.zip"
# Удобная запускаемая копия. FileProvider в Documents может снова добавить ей
# FinderInfo — проверенным результатом считается ZIP, а не эта копия.
rm -rf "$PROJECT/build/Хаос Дня.app"
ditto --norsrc --noextattr --noacl "$APP" "$PROJECT/build/Хаос Дня.app"

echo
echo "Готово."
echo "  Проверенный подписанный архив: $PROJECT/build/Chaos-Day-Mac.zip"
echo "  Запускаемая копия (для удобства): $PROJECT/build/Хаос Дня.app"
echo "  Запуск: open \"$PROJECT/build/Хаос Дня.app\""
echo "  Тестовые данные: DAYLOG_DATA_DIR=/tmp/daylog-demo \"$PROJECT/build/Хаос Дня.app/Contents/MacOS/Daylog\""
