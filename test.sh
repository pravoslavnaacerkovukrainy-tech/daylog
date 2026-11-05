#!/bin/bash
# Самопроверка ядра (DiaryStore) во временном каталоге. Обычные данные в Application Support не затрагиваются.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
SDK="${DAYLOG_SDK_PATH:-$(xcrun --show-sdk-path --sdk macosx)}"
mkdir -p build

echo "→ Компиляция тестов…"
xcrun swiftc \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "$TARGET" \
  -module-name DaylogSelfTest \
  -o build/daylog-selftest \
  Sources/Core/DiaryCore.swift Sources/Core/Organizer.swift Sources/Core/XAIResponses.swift Sources/Core/DraftPolish.swift Sources/Core/NotePolish.swift Sources/Core/NotesChat.swift Sources/Core/DaySummary.swift Sources/Core/NoteMarkdown.swift Sources/Core/MarkdownFolderExport.swift Tests/SelfTest/main.swift

TMP="$(mktemp -d "${TMPDIR:-/tmp}/daylog-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "→ Запуск (DAYLOG_DATA_DIR=$TMP)…"
DAYLOG_DATA_DIR="$TMP" ./build/daylog-selftest "$TMP"
