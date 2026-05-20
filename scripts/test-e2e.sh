#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${AGENT_IDE_E2E_ARTIFACTS:-$ROOT_DIR/.build/e2e-artifacts/latest}"
APP_NAME="AgentIDE"
ORIGINAL_ZDOTDIR="$(launchctl getenv ZDOTDIR || true)"

cd "$ROOT_DIR"

APP_BUNDLE="$(./script/build_and_run.sh --build-only | tail -1)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

SCREENSHOT_DIR="$ARTIFACT_DIR/screenshots"
SCREENSHOT_BLOCKER="$SCREENSHOT_DIR/SCREENSHOT_BLOCKER.md"
mkdir -p "$SCREENSHOT_DIR"
: >"$SCREENSHOT_BLOCKER"

RUNNER_STATUS=0
swift run AgentIDEE2E --artifacts "$ARTIFACT_DIR" || RUNNER_STATUS=$?

cleanup() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  launchctl unsetenv AGENT_IDE_DATABASE_PATH >/dev/null 2>&1 || true
  launchctl unsetenv AGENT_IDE_CONFIG_PATH >/dev/null 2>&1 || true
  launchctl unsetenv AGENT_IDE_CAPTURE_DIRECTORY >/dev/null 2>&1 || true
  launchctl unsetenv AGENT_IDE_PATH >/dev/null 2>&1 || true
  restore_zdotdir
}
trap cleanup EXIT

restore_zdotdir() {
  if [[ -n "$ORIGINAL_ZDOTDIR" ]]; then
    launchctl setenv ZDOTDIR "$ORIGINAL_ZDOTDIR"
  else
    launchctl unsetenv ZDOTDIR >/dev/null 2>&1 || true
  fi
}

set_launch_environment() {
  local database_path="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  local zdotdir="${3:-}"
  launchctl setenv AGENT_IDE_DATABASE_PATH "$database_path"
  launchctl setenv AGENT_IDE_CONFIG_PATH "$ARTIFACT_DIR/config/config.json"
  launchctl setenv AGENT_IDE_CAPTURE_DIRECTORY "$ARTIFACT_DIR/captures"
  launchctl setenv AGENT_IDE_PATH "$app_path"
  if [[ -n "$zdotdir" ]]; then
    launchctl setenv ZDOTDIR "$zdotdir"
  else
    restore_zdotdir
  fi
}

wait_for_window() {
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  repeat 50 times
    if exists process "$APP_NAME" then
      tell process "$APP_NAME"
        if (count of windows) > 0 then return
      end tell
    end if
    delay 0.1
  end repeat
  error "$APP_NAME did not expose a window"
end tell
APPLESCRIPT
}

capture_window() {
  local output_path="$1"
  local window_info
  window_info="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "$APP_NAME"
    set frontmost to true
    set windowPosition to position of window 1
    set windowSize to size of window 1
    set windowID to ""
    try
      set windowID to value of attribute "AXWindowNumber" of window 1
    end try
    return (windowID as string) & "|" & (item 1 of windowPosition as string) & "," & (item 2 of windowPosition as string) & "," & (item 1 of windowSize as string) & "," & (item 2 of windowSize as string)
  end tell
end tell
APPLESCRIPT
)"

  if [[ -z "$window_info" ]]; then
    {
      echo "- Could not read the $APP_NAME window bounds through System Events for $output_path."
      echo "  This usually means the shell lacks Accessibility permission on this Mac."
    } >>"$SCREENSHOT_BLOCKER"
    return 0
  fi

  local bounds="${window_info#*|}"
  if ! /usr/sbin/screencapture -x -R "$bounds" "$output_path" >/dev/null 2>&1; then
    {
      echo "- Could not capture $output_path with screencapture."
      echo "  This usually means the shell lacks Screen Recording permission on this Mac."
    } >>"$SCREENSHOT_BLOCKER"
  fi
}

launch_state() {
  local state="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  local zdotdir="${3:-}"
  local database_path="$ARTIFACT_DIR/states/$state.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/$state.png"
  local log_path="$ARTIFACT_DIR/$state.app.log"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  : >"$log_path"
  set_launch_environment "$database_path" "$app_path" "$zdotdir"
  /usr/bin/open -n "$APP_BUNDLE"

  if ! wait_for_window; then
    echo "$APP_NAME did not stay running for visual state $state" >&2
    sed -n '1,120p' "$log_path" >&2 || true
    return 1
  fi

  if [[ "$state" == "missing-tool" ]]; then
    sleep 3
  else
    sleep 1
  fi
  capture_window "$screenshot_path"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

run_ui_journey() {
  local database_path="$ARTIFACT_DIR/states/ui-journey.sqlite"
  local project_path="$ARTIFACT_DIR/fixture-project"
  cp "$ARTIFACT_DIR/states/launch.sqlite" "$database_path"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  set_launch_environment "$database_path"
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    perform action "AXRaise" of window 1
    set position of window 1 to {0, 25}
    set size of window 1 to {1100, 732}
    delay 0.2
    set windowPosition to position of window 1
    set baseX to item 1 of windowPosition
    set baseY to item 2 of windowPosition

    delay 1
    click at {baseX + 226, baseY + 94}
    repeat 20 times
      if exists sheet 1 of window 1 then exit repeat
      delay 0.1
    end repeat
    set value of text field 1 of group 1 of sheet 1 of window 1 to "UI Smoke Project"
    set value of text field 2 of group 1 of sheet 1 of window 1 to "$project_path"
    click button 2 of group 1 of sheet 1 of window 1

    delay 1
    click at {baseX + 226, baseY + 226}
    repeat 20 times
      if exists sheet 1 of window 1 then exit repeat
      delay 0.1
    end repeat
    click button 1 of group 1 of sheet 1 of window 1

    delay 1
    click at {baseX + 790, baseY + 67}
    click at {baseX + 910, baseY + 170}
    keystroke "readme"
    click at {baseX + 840, baseY + 67}
    delay 0.2
    click at {baseX + 886, baseY + 67}
    delay 0.2
    click at {baseX + 550, baseY + 718}
    delay 0.2
    click at {baseX + 83, baseY + 286}
  end tell
end tell
APPLESCRIPT

  capture_window "$SCREENSHOT_DIR/ui-journey.png"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true

  local project_count thread_count archived_count git_mode_count global_expanded_count
  project_count="$(/usr/bin/sqlite3 "$database_path" "SELECT COUNT(*) FROM projects WHERE display_name = 'UI Smoke Project';")"
  thread_count="$(/usr/bin/sqlite3 "$database_path" "SELECT COUNT(*) FROM threads WHERE agent_cli = 'codex';")"
  archived_count="$(/usr/bin/sqlite3 "$database_path" "SELECT COUNT(*) FROM threads WHERE is_archived = 1;")"
  git_mode_count="$(/usr/bin/sqlite3 "$database_path" "SELECT COUNT(*) FROM right_panel_modes WHERE mode = 'git';")"
  global_expanded_count="$(/usr/bin/sqlite3 "$database_path" "SELECT COUNT(*) FROM layout_state WHERE key = 'global_terminal_expanded' AND value = 'true';")"
  if [[ "$project_count" != "1" || "$thread_count" -lt "1" || "$archived_count" -lt "1" || "$git_mode_count" -lt "1" || "$global_expanded_count" != "1" ]]; then
    echo "UI journey did not persist the expected project/thread/archive/layout/tool state" >&2
    return 1
  fi
}

if [[ "$RUNNER_STATUS" -ne 0 ]]; then
  launch_state "launch" || true
  exit "$RUNNER_STATUS"
fi

# This is the app-process journey: it uses System Events to click and type
# against the launched SwiftUI app, then asserts the resulting durable state.
run_ui_journey

MISSING_TOOL_ZDOTDIR="$ARTIFACT_DIR/zsh-missing-tools"
mkdir -p "$MISSING_TOOL_ZDOTDIR"
printf 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n' >"$MISSING_TOOL_ZDOTDIR/.zshenv"

for state in launch project-creation files nvim git missing-directory global-terminal panel-collapse; do
  launch_state "$state"
done

launch_state "missing-tool" "$ARTIFACT_DIR/bin-missing-lazygit:/usr/bin:/bin:/usr/sbin:/sbin" "$MISSING_TOOL_ZDOTDIR"

if [[ ! -s "$SCREENSHOT_BLOCKER" ]]; then
  rm -f "$SCREENSHOT_BLOCKER"
fi

echo "E2E artifacts: $ARTIFACT_DIR"
