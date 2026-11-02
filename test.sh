#!/bin/bash
# Самопроверка ядра (DiaryStore) во временном каталоге. Обычные данные в Application Support не затрагиваются.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
mkdir -p build
SOURCES=(
  Sources/Core/DiaryCore.swift
  Sources/Core/XAIResponses.swift
  Sources/Core/DraftPolish.swift
  Sources/Core/NotePolish.swift
  Sources/Core/NotesChat.swift
  Tests/SelfTest/main.swift
)

if xcrun --show-sdk-path --sdk macosx >/dev/null 2>&1; then
  TARGET="${ARCH}-apple-macos14.0"
  SDK="$(xcrun --show-sdk-path --sdk macosx)"
  echo "→ Компиляция тестов…"
  xcrun swiftc \
    -swift-version 5 \
    -sdk "$SDK" \
    -target "$TARGET" \
    -module-name DaylogSelfTest \
    -o build/daylog-selftest \
    "${SOURCES[@]}"
else
  echo "→ Компиляция тестов (Swift на этой системе, без macOS SDK)…"
  swiftc \
    -swift-version 5 \
    -module-name DaylogSelfTest \
    -o build/daylog-selftest \
    "${SOURCES[@]}"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/daylog-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "→ Запуск (DAYLOG_DATA_DIR=$TMP)…"
DAYLOG_DATA_DIR="$TMP" ./build/daylog-selftest "$TMP"
