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
HELPER_PRODUCT="YAAWToolHost"
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
APP_VERSION="${YAAW_APP_VERSION:-0.0.1}"
BUILD_NUMBER="${YAAW_BUILD_NUMBER:-$APP_VERSION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stamp the packaged bundle with the exact commit it was built from so the
# About panel and Settings can prove which build is running.
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
HELPER_BINARY="$APP_HELPERS/$HELPER_PRODUCT"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON="$ROOT_DIR/resources/YAAW.icns"

running_bundled_app_pids() {
  { ps -axo pid=,comm= 2>/dev/null || true; } | awk -v app_binary="$APP_BINARY" '
    {
      pid = $1
      $1 = ""
      sub(/^ +/, "")
      if ($0 == app_binary) print pid
    }
  '
}

terminate_bundled_app() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done < <(running_bundled_app_pids)
}

terminate_bundled_app

cd "$ROOT_DIR"
if [[ "$BUILD_CONFIGURATION" != "debug" ]]; then
  swift build -c "$BUILD_CONFIGURATION"
  BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
  BUILD_BINARY="$BUILD_DIR/$BUILD_PRODUCT"
  BUILD_HELPER="$BUILD_DIR/$HELPER_PRODUCT"
else
  swift build
  BUILD_DIR="$(swift build --show-bin-path)"
  BUILD_BINARY="$BUILD_DIR/$BUILD_PRODUCT"
  BUILD_HELPER="$BUILD_DIR/$HELPER_PRODUCT"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_HELPER" "$HELPER_BINARY"
chmod +x "$APP_BINARY"
chmod +x "$HELPER_BINARY"

while IFS= read -r RESOURCE_BUNDLE; do
  [[ -n "$RESOURCE_BUNDLE" ]] || continue
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' -print)

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
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>YAAWBuildCommit</key>
  <string>$GIT_COMMIT</string>
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
  # `open -n` always starts a new instance. Quit any instance still running
  # from this bundle first: a stale instance keeps floating terminal panes
  # alive at their old frames, which then overlay the new instance's layout
  # (mixed/stale terminal content and window slivers after panel changes).
  # SIGTERM gives the old app a clean shutdown, which also tears down its
  # YAAWToolHost helpers.
  /usr/bin/pkill -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    /usr/bin/pgrep -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.2
  done
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
