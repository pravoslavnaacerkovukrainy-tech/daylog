#!/bin/bash
# Самопроверка SyncCore против сервера в памяти и сборка CLI chaos-sync.
# Только временный каталог и синтетические данные; Application Support не затрагивается.
set -euo pipefail
cd "$(dirname "$0")"
source ./sdk.sh
OUT="$(cd .. && pwd)/build/plan"
mkdir -p "$OUT"
COMMON=(-module-cache-path "$OUT/ModuleCache" -swift-version 5 -parse-as-library -sdk "$PLAN_SDK" -target "$PLAN_TARGET")

echo "→ Самопроверка SyncCore…"
xcrun swiftc "${COMMON[@]}" -module-name SyncSelfTest -o "$OUT/sync-selftest" \
  Sources/SyncCore/*.swift Tests/SyncSelfTest/*.swift
"$OUT/sync-selftest"

echo "→ Сборка CLI chaos-sync…"
xcrun swiftc "${COMMON[@]}" -O -module-name ChaosSync -o "$OUT/chaos-sync" \
  Sources/SyncCore/*.swift Tools/chaos-sync/main.swift
echo "Готово: $OUT/chaos-sync"
