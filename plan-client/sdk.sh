#!/bin/bash
# Общий выбор SDK для build.sh и test.sh. Некоторые Command Line Tools идут с SDK без
# плагина SwiftUIMacros; тогда берётся совместимый MacOSX26.5.sdk, если он установлен.
PLAN_SDK="${PLAN_SDK_PATH:-$(xcrun --show-sdk-path --sdk macosx)}"
_swift_bin="$(dirname "$(xcrun --find swiftc)")"
_iface="$PLAN_SDK/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
_compat="$(dirname "$PLAN_SDK")/MacOSX26.5.sdk"
if [[ -z "${PLAN_SDK_PATH:-}" && -d "$_compat" && ! -f "$_swift_bin/../lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] &&
   grep -q 'public macro State' "$_iface" 2>/dev/null; then
  PLAN_SDK="$_compat"
fi
PLAN_TARGET="$(uname -m)-apple-macos14.0"
export PLAN_SDK PLAN_TARGET
