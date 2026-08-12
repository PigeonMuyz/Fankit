#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Fankit.xcodeproj"
SCHEME="Fankit"
CONFIGURATION="Release"
VERSION="${1:-1.0.2}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/.derivedData/release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fankit-dmg.XXXXXX")"
RW_IMAGE="$STAGING_DIR/Fankit-rw.dmg"
MOUNT_DIR=""
DMG_PATH="$DIST_DIR/Fankit-$VERSION.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

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

cleanup() {
  if [[ -n "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must use semantic versioning, for example 1.0.0." >&2
  exit 2
fi

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$CHECKSUM_PATH"

echo "Building $SCHEME $CONFIGURATION $VERSION..."
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  "${SIGNING_SETTINGS[@]}" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/Fankit.app"
test -d "$BUILT_APP"

APP_SIZE_KB="$(du -sk "$BUILT_APP" | awk '{print $1}')"
IMAGE_SIZE_MB=$((APP_SIZE_KB / 1024 + 32))
if (( IMAGE_SIZE_MB < 64 )); then
  IMAGE_SIZE_MB=64
fi

echo "Creating Finder-style installer image..."
hdiutil create \
  -size "${IMAGE_SIZE_MB}m" \
  -fs HFS+ \
  -volname "Fankit" \
  -ov "$RW_IMAGE" >/dev/null

MOUNT_OUTPUT="$(hdiutil attach -nobrowse -noautoopen "$RW_IMAGE")"
MOUNT_DIR="$(printf '%s\n' "$MOUNT_OUTPUT" | awk '$NF ~ /^\/Volumes\// { print $NF; exit }')"
if [[ -z "$MOUNT_DIR" ]]; then
  echo "Unable to locate the mounted Fankit volume." >&2
  exit 1
fi

ditto "$BUILT_APP" "$MOUNT_DIR/Fankit.app"
ln -s /Applications "$MOUNT_DIR/Applications"

if ! osascript >/dev/null <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Fankit"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 860, 620}
        set iconOptions to icon view options of container window
        set arrangement of iconOptions to not arranged
        set icon size of iconOptions to 128
        set text size of iconOptions to 14
        try
            set background color of iconOptions to {11000, 10000, 10000}
        end try
        set position of item "Fankit.app" of container window to {210, 280}
        set position of item "Applications" of container window to {600, 280}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
  echo "Finder layout could not be saved; keeping the standard DMG layout." >&2
fi

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""
hdiutil convert "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

echo "Created: $DMG_PATH"
echo "Checksum: $CHECKSUM_PATH"
