#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY_REF="${GHOSTTY_REF:-46d54ed673a004df09078bee56e809421a82370e}"
SOURCE_DIR="$ROOT_DIR/.build/ghostty-src"
VENDOR_DIR="$ROOT_DIR/Vendor/Ghostty"

if ! command -v zig >/dev/null 2>&1; then
  cat >&2 <<'EOF'
zig is required to build the vendored Ghostty framework.

Install Zig, then re-run:
  scripts/bootstrap-libghostty.sh
EOF
  exit 1
fi

mkdir -p "$ROOT_DIR/.build" "$VENDOR_DIR"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone https://github.com/ghostty-org/ghostty.git "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" fetch --tags origin
git -C "$SOURCE_DIR" checkout "$GHOSTTY_REF"

(
  cd "$SOURCE_DIR"
  zig build -Demit-xcframework
)

framework_path=""
while IFS= read -r candidate; do
  framework_path="$candidate"
  break
done < <(find "$SOURCE_DIR/zig-out" -maxdepth 4 -name '*.xcframework' -print)

if [[ -z "$framework_path" ]]; then
  echo "No Ghostty xcframework was produced under $SOURCE_DIR/zig-out" >&2
  exit 1
fi

rm -rf "$VENDOR_DIR"/*.xcframework
cp -R "$framework_path" "$VENDOR_DIR/"

echo "Vendored $(basename "$framework_path") at $VENDOR_DIR"
