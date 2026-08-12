#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Fankit"
BUNDLE_ID="io.github.pigeonmuyz.fankit"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.derivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HELPER_BINARY="$APP_BUNDLE/Contents/MacOS/FankitHelper"
DAEMON_PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/io.github.pigeonmuyz.fankit.helper.plist"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -p codesigning -v | awk '/valid identities found/{exit} /^[[:space:]]*[0-9]+\)/ {print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No code-signing identity found. Fankit requires a signed app to register its control helper." >&2
  exit 1
fi

SIGNING_SETTINGS=(
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGNING_REQUIRED=YES
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
)

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/Fankit.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  "${SIGNING_SETTINGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_curve() {
  local curve_test_binary
  curve_test_binary="$(mktemp -d)/fan-control-curve-verify"
  xcrun swiftc \
    "$ROOT_DIR/Fankit/Models/ThermalCurve.swift" \
    "$ROOT_DIR/script/curve_verify/main.swift" \
    -o "$curve_test_binary"
  "$curve_test_binary"
}

verify_ai_scheduling() {
  local ai_test_binary
  ai_test_binary="$(mktemp -d)/fan-control-ai-verify"
  xcrun swiftc \
    "$ROOT_DIR/Fankit/Models/FanControlModels.swift" \
    "$ROOT_DIR/Fankit/Models/ThermalCurve.swift" \
    "$ROOT_DIR/Fankit/Models/AISchedulingModels.swift" \
    "$ROOT_DIR/Fankit/Services/AIPromptBuilder.swift" \
    "$ROOT_DIR/Fankit/Services/AIScheduleParser.swift" \
    "$ROOT_DIR/script/ai_verify/main.swift" \
    -o "$ai_test_binary"
  "$ai_test_binary"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    verify_curve
    verify_ai_scheduling
    test -x "$HELPER_BINARY"
    test -f "$DAEMON_PLIST"
    test "$(lipo -archs "$APP_BINARY")" = "arm64"
    test "$(lipo -archs "$HELPER_BINARY")" = "arm64"
    plutil -lint "$DAEMON_PLIST" >/dev/null
    codesign --verify --deep --strict "$APP_BUNDLE"
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
