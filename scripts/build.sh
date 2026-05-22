#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

WORKSPACE_STATE=".build/workspace-state.json"
if [[ -f "$WORKSPACE_STATE" ]] && ! grep -Fq "$ROOT_DIR" "$WORKSPACE_STATE"; then
  echo "Resetting stale SwiftPM workspace state for $ROOT_DIR..."
  swift package reset
fi

swift build
