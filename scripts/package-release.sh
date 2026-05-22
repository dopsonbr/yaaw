#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT_DIR/dist"

usage() {
  echo "usage: $0 --version <major.minor.patch> [--output-dir <directory>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  if [[ -f "$ROOT_DIR/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
  else
    usage
    exit 2
  fi
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be MAJOR.MINOR.PATCH, got: $VERSION" >&2
  exit 2
fi

case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR" ;;
esac

mkdir -p "$OUTPUT_DIR"

echo "Building YAAW $VERSION..."
APP_BUNDLE="$(
  cd "$ROOT_DIR"
  YAAW_BUILD_CONFIGURATION=release \
    YAAW_APP_VERSION="$VERSION" \
    YAAW_BUILD_NUMBER="$VERSION" \
    ./script/build_and_run.sh --build-only | tail -n 1
)"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: expected app bundle was not created: $APP_BUNDLE" >&2
  exit 1
fi

PLIST="$APP_BUNDLE/Contents/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "error: app bundle version is $PLIST_VERSION, expected $VERSION" >&2
  exit 1
fi
if [[ "$PLIST_BUILD" != "$VERSION" ]]; then
  echo "error: app bundle build is $PLIST_BUILD, expected $VERSION" >&2
  exit 1
fi

if [[ ! -d "$APP_BUNDLE/Contents/Resources/YAAW_YAAW.bundle" ]]; then
  echo "error: app bundle is missing SwiftPM resources: $APP_BUNDLE/Contents/Resources/YAAW_YAAW.bundle" >&2
  exit 1
fi

ZIP_PATH="$OUTPUT_DIR/YAAW-$VERSION-macos-arm64.zip"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "$ZIP_PATH"
