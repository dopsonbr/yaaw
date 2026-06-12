#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

WORKSPACE_STATE=".build/workspace-state.json"
if [[ -f "$WORKSPACE_STATE" ]] && ! grep -Fq "$ROOT_DIR" "$WORKSPACE_STATE"; then
  echo "Resetting stale SwiftPM workspace state for $ROOT_DIR..."
  swift package reset
fi

# Strict-concurrency (Swift 6 language mode) is always on per target. SWIFT_STRICT=1
# additionally treats warnings as errors — the CI/cutover gate (D-006). The whole
# package builds warnings-clean today, so this is enforceable.
if [[ "${SWIFT_STRICT:-0}" == "1" ]]; then
  swift build -Xswiftc -warnings-as-errors
else
  swift build
fi
