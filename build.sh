#!/bin/bash
# Сборка «Ход дня» без Xcode: swiftc из Command Line Tools.
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
SDK="$(xcrun --show-sdk-path --sdk macosx)"

STAGE="$(mktemp -d "${TMPDIR:-/private/tmp}/daylog-build.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

APP="$STAGE/Daylog.app"
ZIP="$STAGE/Daylog-Mac.zip"
CHECK="$STAGE/check"

echo "→ Временная папка сборки: $STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CHECK"

echo "→ Компиляция ($TARGET)…"
xcrun swiftc \
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
# стабилен между пересборками, поэтому доступ к ключу xAI в Связке ключей не слетает
# и его не нужно вводить заново. Если идентичности нет (чистый клон, другой Mac,
# публичная сборка) — подпись ad hoc, как раньше. Сертификат в репозиторий не входит.
SIGN_ID="${DAYLOG_SIGN_ID:-Daylog Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
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
codesign --verify --strict --verbose=2 "$CHECK/Daylog.app"
test -x "$CHECK/Daylog.app/Contents/MacOS/Daylog"

echo "→ Копирование результатов в build/…"
mkdir -p "$PROJECT/build"
cat "$ZIP" > "$PROJECT/build/Daylog-Mac.zip"
# Удобная запускаемая копия. FileProvider в Documents может снова добавить ей
# FinderInfo — проверенным результатом считается ZIP, а не эта копия.
rm -rf "$PROJECT/build/Daylog.app"
ditto --norsrc --noextattr --noacl "$APP" "$PROJECT/build/Daylog.app"

echo
echo "Готово."
echo "  Проверенный подписанный архив: $PROJECT/build/Daylog-Mac.zip"
echo "  Запускаемая копия (для удобства): $PROJECT/build/Daylog.app"
echo "  Запуск: open \"$PROJECT/build/Daylog.app\""
echo "  Тестовые данные: DAYLOG_DATA_DIR=/tmp/daylog-demo \"$PROJECT/build/Daylog.app/Contents/MacOS/Daylog\""
