#!/usr/bin/env bash
set -euo pipefail

APP_NAME="YAAW"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="/Applications"
BIN_DIR="/usr/local/bin"
SKIP_PATH=0
USE_SUDO=1

usage() {
  echo "usage: $0 [--test-install] [--no-sudo] [--app-dir <directory>] [--bin-dir <directory>] [--skip-path]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-install)
      APP_DIR=".build/install-test/Applications"
      BIN_DIR=".build/install-test/bin"
      USE_SUDO=0
      shift
      ;;
    --no-sudo)
      USE_SUDO=0
      shift
      ;;
    --app-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      APP_DIR="$2"
      shift 2
      ;;
    --bin-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
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

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$ROOT_DIR/$1" ;;
  esac
}

APP_DIR="$(absolute_path "$APP_DIR")"
INSTALL_APP="$APP_DIR/$APP_NAME.app"

can_write_target() {
  local target="$1"
  local probe="$target"

  if [[ ! -d "$probe" ]]; then
    probe="$(dirname "$probe")"
  fi
  while [[ ! -e "$probe" ]]; do
    probe="$(dirname "$probe")"
  done

  [[ -w "$probe" ]]
}

run_for_target() {
  local target="$1"
  shift

  if can_write_target "$target"; then
    "$@"
  elif [[ "$USE_SUDO" -eq 1 ]]; then
    sudo "$@"
  else
    echo "error: target is not writable without sudo: $target" >&2
    echo "use --app-dir/--bin-dir with writable directories or omit --no-sudo" >&2
    exit 1
  fi
}

echo "Building release $APP_NAME.app..."
cd "$ROOT_DIR"
APP_BUNDLE="$(YAAW_BUILD_CONFIGURATION=release ./script/build_and_run.sh --build-only | tail -1)"

echo "Installing $APP_NAME.app to $INSTALL_APP..."
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
run_for_target "$APP_DIR" mkdir -p "$APP_DIR"
run_for_target "$INSTALL_APP" rm -rf "$INSTALL_APP"
run_for_target "$APP_DIR" cp -R "$APP_BUNDLE" "$INSTALL_APP"

if command -v codesign >/dev/null 2>&1; then
  run_for_target "$INSTALL_APP" /usr/bin/codesign --force --deep --sign - "$INSTALL_APP"
  /usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
fi

if [[ "$SKIP_PATH" -eq 0 ]]; then
  BIN_DIR="$(absolute_path "$BIN_DIR")"
  LAUNCHER="$BIN_DIR/yaaw"
  LAUNCHER_TMP="$(mktemp)"
  trap 'rm -f "$LAUNCHER_TMP"' EXIT

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'open -na %q --args "$@"\n' "$INSTALL_APP"
  } >"$LAUNCHER_TMP"
  chmod +x "$LAUNCHER_TMP"

  echo "Installing yaaw launcher to $LAUNCHER..."
  run_for_target "$BIN_DIR" mkdir -p "$BIN_DIR"
  run_for_target "$LAUNCHER" install -m 0755 "$LAUNCHER_TMP" "$LAUNCHER"
fi

echo "Installed $INSTALL_APP"
