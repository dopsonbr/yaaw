#!/usr/bin/env bash
set -euo pipefail

VARIANT="production"
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --variant=*)
      VARIANT="${arg#--variant=}"
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

MODE="${1:-run}"
BUILD_PRODUCT="YAAW"
case "$VARIANT" in
  production)
    APP_NAME="YAAW"
    BUNDLE_ID="dev.dopsonbr.YAAW"
    ;;
  e2e)
    APP_NAME="YAAW-E2E"
    BUNDLE_ID="dev.dopsonbr.YAAW.E2E"
    ;;
  *)
    echo "unknown --variant=$VARIANT (expected production|e2e)" >&2
    exit 2
    ;;
esac
MIN_SYSTEM_VERSION="26.0"
BUILD_CONFIGURATION="${YAAW_BUILD_CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/resources/YAAW.icns"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
if [[ "$BUILD_CONFIGURATION" != "debug" ]]; then
  swift build -c "$BUILD_CONFIGURATION"
  BUILD_BINARY="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)/$BUILD_PRODUCT"
else
  swift build
  BUILD_BINARY="$(swift build --show-bin-path)/$BUILD_PRODUCT"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP_RESOURCES/YAAW.icns"
fi

VENDORED_GHOSTTY="$ROOT_DIR/Vendor/Ghostty"
if [[ -d "$VENDORED_GHOSTTY" ]]; then
  GHOSTTY_FRAMEWORK="$(find "$VENDORED_GHOSTTY" -path '*/Ghostty.framework' -type d | head -1 || true)"
  if [[ -n "$GHOSTTY_FRAMEWORK" ]]; then
    cp -R "$GHOSTTY_FRAMEWORK" "$APP_FRAMEWORKS/"
  fi

  GHOSTTY_DYLIB="$(find "$VENDORED_GHOSTTY" -name 'libghostty.dylib' -type f | head -1 || true)"
  if [[ -n "$GHOSTTY_DYLIB" ]]; then
    cp "$GHOSTTY_DYLIB" "$APP_FRAMEWORKS/"
  fi
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>YAAW</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
    if otool -L "$APP_BINARY" | grep -q '/Applications/Ghostty.app'; then
      echo "$APP_NAME links against /Applications/Ghostty.app; the app bundle must be self-contained" >&2
      exit 1
    fi
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --build-only|build-only)
    printf '%s\n' "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--build-only]" >&2
    echo "set YAAW_BUILD_CONFIGURATION=release for a release-staged app bundle" >&2
    exit 2
    ;;
esac
