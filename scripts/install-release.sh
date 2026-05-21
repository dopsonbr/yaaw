#!/bin/sh
set -eu

REPO="dopsonbr/yaaw"
APP_NAME="YAAW"
VERSION="latest"
APP_DIR="/Applications"
BIN_DIR="/usr/local/bin"
SKIP_PATH=0
USE_SUDO=1

usage() {
  echo "usage: $0 [--version <vX.Y.Z|latest>] [--no-sudo] [--app-dir <directory>] [--bin-dir <directory>] [--skip-path]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --no-sudo)
      USE_SUDO=0
      shift
      ;;
    --app-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      APP_DIR="$2"
      shift 2
      ;;
    --bin-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BIN_DIR="$2"
      shift 2
      ;;
    --skip-path)
      SKIP_PATH=1
      shift
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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$(pwd)/$1" ;;
  esac
}

can_write_target() {
  target="$1"
  probe="$target"
  if [ ! -d "$probe" ]; then
    probe="$(dirname "$probe")"
  fi
  while [ ! -e "$probe" ]; do
    probe="$(dirname "$probe")"
  done
  [ -w "$probe" ]
}

run_for_target() {
  target="$1"
  shift
  if can_write_target "$target"; then
    "$@"
  elif [ "$USE_SUDO" -eq 1 ]; then
    sudo "$@"
  else
    echo "error: target is not writable without sudo: $target" >&2
    exit 1
  fi
}

if ! command_exists curl; then
  echo "error: curl is required" >&2
  exit 1
fi
if ! command_exists unzip; then
  echo "error: unzip is required" >&2
  exit 1
fi

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) ;;
  *)
    echo "error: YAAW release artifacts support macOS Apple Silicon only" >&2
    exit 1
    ;;
esac

ASSET_URL="${YAAW_RELEASE_ASSET_URL:-}"
if [ -z "$ASSET_URL" ]; then
  if [ "$VERSION" = "latest" ]; then
    RELEASE_API="https://api.github.com/repos/$REPO/releases/latest"
  else
    RELEASE_API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
  fi

  echo "Resolving YAAW release from $RELEASE_API..."
  RELEASE_JSON="$(curl -fsSL "$RELEASE_API")"
  ASSET_URL="$(
    printf '%s\n' "$RELEASE_JSON" \
      | sed -n 's/.*"browser_download_url": "\(.*YAAW-[^"]*-macos-arm64\.zip\)".*/\1/p' \
      | head -n 1
  )"
fi

if [ -z "$ASSET_URL" ]; then
  echo "error: no macOS Apple Silicon YAAW zip asset found on release" >&2
  exit 1
fi

APP_DIR="$(absolute_path "$APP_DIR")"
BIN_DIR="$(absolute_path "$BIN_DIR")"
INSTALL_APP="$APP_DIR/$APP_NAME.app"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yaaw-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

ZIP_PATH="$TMP_DIR/yaaw.zip"
echo "Downloading $ASSET_URL..."
curl -fL "$ASSET_URL" -o "$ZIP_PATH"

echo "Expanding release..."
unzip -q "$ZIP_PATH" -d "$TMP_DIR/release"
APP_BUNDLE="$(find "$TMP_DIR/release" -name "$APP_NAME.app" -type d | head -n 1)"
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
  echo "error: release zip did not contain $APP_NAME.app" >&2
  exit 1
fi

echo "Installing $APP_NAME.app to $INSTALL_APP..."
if [ "${YAAW_INSTALL_SKIP_KILL:-0}" != "1" ]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
run_for_target "$APP_DIR" mkdir -p "$APP_DIR"
run_for_target "$INSTALL_APP" rm -rf "$INSTALL_APP"
run_for_target "$APP_DIR" cp -R "$APP_BUNDLE" "$INSTALL_APP"

if command_exists codesign; then
  run_for_target "$INSTALL_APP" /usr/bin/codesign --force --deep --sign - "$INSTALL_APP"
  /usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
fi

if [ "$SKIP_PATH" -eq 0 ]; then
  LAUNCHER="$BIN_DIR/yaaw"
  LAUNCHER_TMP="$TMP_DIR/yaaw-launcher"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'open -na %s --args "$@"\n' "$(printf '%s\n' "$INSTALL_APP" | sed "s/'/'\\\\''/g; s/.*/'&'/")"
  } >"$LAUNCHER_TMP"
  chmod +x "$LAUNCHER_TMP"

  echo "Installing yaaw launcher to $LAUNCHER..."
  run_for_target "$BIN_DIR" mkdir -p "$BIN_DIR"
  run_for_target "$LAUNCHER" install -m 0755 "$LAUNCHER_TMP" "$LAUNCHER"
fi

echo "Installed $INSTALL_APP"
