#!/bin/bash
# Самопроверка политики навигации (без сети и UI), затем — если не задан NO_SMOKE=1 —
# смоук-запуск debug-сборки против локальной страницы на 127.0.0.1 с непостоянным профилем.
# Рабочий сайт и профиль приложения не используются.
set -euo pipefail
cd "$(dirname "$0")"
source ../plan-client/sdk.sh
OUT="$(cd .. && pwd)/build/web"
mkdir -p "$OUT"
COMMON=(-module-cache-path "$OUT/ModuleCache" -swift-version 5 -sdk "$PLAN_SDK" -target "$PLAN_TARGET")

echo "→ Самопроверка WebPolicy (release-условия)…"
xcrun swiftc "${COMMON[@]}" -module-name WebSelfTest -o "$OUT/web-selftest" \
  Sources/Core/*.swift Tests/SelfTest/main.swift
"$OUT/web-selftest"

echo "→ Самопроверка WebPolicy (debug-условия)…"
xcrun swiftc "${COMMON[@]}" -D CHAOS_WEB_DEBUG -module-name WebSelfTest -o "$OUT/web-selftest-debug" \
  Sources/Core/*.swift Tests/SelfTest/main.swift
"$OUT/web-selftest-debug"

[[ "${NO_SMOKE:-}" == 1 ]] && exit 0

echo "→ Смоук-запуск debug-сборки на loopback…"
./build.sh --debug >/dev/null
SITE="$(mktemp -d "${TMPDIR:-/private/tmp}/web-smoke.XXXXXX")"
LOG="$SITE.log"
cat > "$SITE/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Смоук Хаос Дня</title>
<form method="post" action="/login"><input name="u"><button>Войти</button></form>
<a id="ext" href="https://example.com/">внешняя</a>
HTML
PORT=$(( 20000 + RANDOM % 20000 ))
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; rm -rf "$SITE" "$LOG"; }
trap cleanup EXIT
sleep 1

BIN="$OUT/debug/Хаос Дня Веб.app/Contents/MacOS/ChaosDayWeb"
"$BIN" --debug-url "http://127.0.0.1:$PORT/" --smoke >"$LOG" 2>/dev/null &
APPPID=$!
for _ in $(seq 1 30); do kill -0 "$APPPID" 2>/dev/null || break; sleep 0.5; done
kill "$APPPID" 2>/dev/null || true
cat "$LOG"
grep -q "SMOKE LOADED http://127.0.0.1:$PORT/ title=Смоук Хаос Дня" "$LOG" || { echo "Смоук не прошёл" >&2; exit 1; }

echo "→ Недоступный сервер показывает экран ошибки…"
kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true
"$BIN" --debug-url "http://127.0.0.1:$PORT/" --smoke >"$LOG" 2>/dev/null &
APPPID=$!
for _ in $(seq 1 30); do kill -0 "$APPPID" 2>/dev/null || break; sleep 0.5; done
kill "$APPPID" 2>/dev/null || true
cat "$LOG"
grep -q "SMOKE FAIL NSURLErrorDomain -1004 overlay=shown" "$LOG" || { echo "Экран ошибки не показан" >&2; exit 1; }

echo "→ debug-URL вне loopback отклоняется…"
set +e; "$BIN" --debug-url "https://example.com/" --smoke >/dev/null 2>&1; CODE=$?; set -e
test "$CODE" = 64 || { echo "ожидался код 64, получен $CODE" >&2; exit 1; }
echo "Смоук пройден"
