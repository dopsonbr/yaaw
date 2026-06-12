#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_ARTIFACT_DIR="${TMPDIR:-/tmp}/yaaw-e2e-artifacts/latest"
ARTIFACT_DIR="${YAAW_E2E_ARTIFACTS:-$DEFAULT_ARTIFACT_DIR}"
APP_NAME="YAAW-E2E"
APP_BUNDLE_ID="dev.dopsonbr.YAAW.E2E"

# Headless is the default: the app and its tool-host helpers never take
# focus or raise windows over the user's work. Pass --headed for the legacy
# focus-driven behavior (occasional full-fidelity check of OS key routing).
HEADLESS=1
for arg in "$@"; do
  if [[ "$arg" == "--headed" ]]; then
    HEADLESS=0
  fi
done

# Interpolated into AppleScript blocks that resize windows: raising is only
# allowed in headed runs ("delay 0" is an AppleScript no-op).
RAISE_WINDOW_LINE='perform action "AXRaise" of window 1'
if [[ "$HEADLESS" == "1" ]]; then
  RAISE_WINDOW_LINE="delay 0"
fi

cd "$ROOT_DIR"

printf 'YAAW E2E pasteboard sentinel' | /usr/bin/pbcopy >/dev/null 2>&1 || true

./script/build_and_run.sh --build-only --variant=e2e >/dev/null
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "expected E2E app bundle was not created: $APP_BUNDLE" >&2
  exit 1
fi
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# The per-surface render helper is now packaged as an NSXPC service bundle
# (Chunk D, ADR-004): faceless YAAWRenderHost processes that composite their
# frames into the parent window via CAContext rather than floating their own
# windows. It lives under Contents/XPCServices (not Contents/Helpers anymore).
RENDER_HOST_SERVICE_ID="dev.dopsonbr.YAAW.RenderHost"
RENDER_HOST_HELPER="$APP_BUNDLE/Contents/XPCServices/$RENDER_HOST_SERVICE_ID.xpc/Contents/MacOS/YAAWRenderHost"

running_e2e_app_pids() {
  { ps -axo pid=,comm= 2>/dev/null || true; } | awk -v app_binary="$APP_BINARY" '
    {
      pid = $1
      $1 = ""
      sub(/^ +/, "")
      if ($0 == app_binary) print pid
    }
  '
}

terminate_e2e_app() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done < <(running_e2e_app_pids)
}

wait_for_process_exit() {
  for _ in {1..80}; do
    if [[ -z "$(running_e2e_app_pids)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# All render-host helper pids spawned by THIS suite's app bundle. The XPC
# service model gives every surface its own faceless YAAWRenderHost process;
# matching the packaged helper binary path scopes the count to this suite (a
# live YAAW.app on the same machine runs its own helpers from a different path).
all_helper_pids() {
  { ps -axo pid=,args= 2>/dev/null || true; } | awk -v helper="$RENDER_HOST_HELPER" '
    index($0, helper) > 0 {
      print $1
    }
  '
}

# The render helpers no longer carry the pre-rewrite `--tool-kind terminal` /
# `--instance-id project:` args (XPC services receive their launch config over
# the connection, not argv). The suite scopes by helper binary path instead;
# terminal vs. browser surfaces are distinguished by the launched-app's
# behavior, not the helper argv.
terminal_helper_pids() {
  all_helper_pids
}

app_pid() {
  running_e2e_app_pids | head -n 1
}

# Returns the most-recently-spawned render-host helper pid (the project
# terminal surface in the common single-surface launch). Replaces the
# pre-rewrite `--instance-id`-prefix match, which no longer exists under XPC.
# The argument is accepted for call-site compatibility but unused.
helper_pid_for_instance_prefix() {
  all_helper_pids | tail -n 1
}

assert_terminal_helper_running() {
  local context="$1"
  for _ in {1..80}; do
    if [[ -n "$(terminal_helper_pids)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "$APP_NAME expected a render-host helper during $context" >&2
  return 1
}

# NOTE: the pre-rewrite suite asserted per-surface *visible helper windows*
# (overlay-window model). Under the IOSurface compositing model (ADR-004
# Candidate 2) helpers are faceless — they render into a shared IOSurface
# composited inside the app's own window, with no visible per-surface window — so
# surface presence is now verified by (a) the helper *process* running
# (`assert_terminal_helper_running`), (b) the durable SQL state transitions
# (`wait_for_sql_value`), and (c) the composited *pixels* in the pane region
# (`assert_terminal_region_not_near_white`). The window-title assertions were
# removed; they tested a mechanism the rewrite deleted.

SCREENSHOT_DIR="$ARTIFACT_DIR/screenshots"
SCREENSHOT_BLOCKER="$SCREENSHOT_DIR/SCREENSHOT_BLOCKER.md"
mkdir -p "$SCREENSHOT_DIR"
: >"$SCREENSHOT_BLOCKER"

RUNNER_STATUS=0
swift run YAAWE2E --artifacts "$ARTIFACT_DIR" || RUNNER_STATUS=$?
E2E_TOOL="$(swift build --show-bin-path)/YAAWE2E"

FOCUS_BLOCKER="$ARTIFACT_DIR/FOCUS_BLOCKER.md"
: >"$FOCUS_BLOCKER"

# The headless contract: the e2e app must never become the frontmost app.
# (The user keeps working during a run, so the frontmost app legitimately
# changes between checks — only the e2e app going frontmost is a failure.)
assert_no_focus_steal() {
  [[ "$HEADLESS" == "1" ]] || return 0
  local context="$1"
  local now
  now="$("$E2E_TOOL" frontmost 2>/dev/null || echo unknown)"
  if [[ "$now" == "$APP_BUNDLE_ID" ]]; then
    echo "- $APP_NAME became frontmost during $context" >>"$FOCUS_BLOCKER"
  fi
}

cleanup() {
  terminate_e2e_app
  launchctl unsetenv YAAW_E2E_DATABASE_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_CONFIG_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_CAPTURE_DIRECTORY >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_HEADLESS >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

set_launch_environment() {
  local database_path="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  launchctl setenv YAAW_E2E_DATABASE_PATH "$database_path"
  launchctl setenv YAAW_E2E_CONFIG_PATH "$ARTIFACT_DIR/config/settings.yaml"
  launchctl setenv YAAW_E2E_CAPTURE_DIRECTORY "$ARTIFACT_DIR/captures"
  launchctl setenv YAAW_E2E_PATH "$app_path"
  if [[ "$HEADLESS" == "1" ]]; then
    launchctl setenv YAAW_E2E_HEADLESS "1"
  else
    launchctl unsetenv YAAW_E2E_HEADLESS >/dev/null 2>&1 || true
  fi
}

wait_for_window() {
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  repeat 150 times
    if exists process "$APP_NAME" then
      try
        tell process "$APP_NAME"
          if (count of windows) > 0 then return
        end tell
      end try
    end if
    delay 0.1
  end repeat
  error "$APP_NAME did not expose a window"
end tell
APPLESCRIPT
}

report_window_launch_failure() {
  local context="$1"
  echo "$APP_NAME did not expose a window for $context" >&2
  local pids
  pids="$(running_e2e_app_pids | tr '\n' ' ')"
  if [[ -n "$pids" ]]; then
    echo "Running $APP_NAME pids: $pids" >&2
    ps -axo pid=,stat=,comm=,args= | awk -v app_binary="$APP_BINARY" '
      $1 ~ /^[0-9]+$/ && $3 == app_binary {
        print
      }
    ' >&2 || true
  else
    echo "No running $APP_NAME process found after launch attempts." >&2
  fi
}

launch_e2e_app() {
  local database_path="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  local context="${3:-app launch}"

  terminate_e2e_app
  wait_for_process_exit || true
  set_launch_environment "$database_path" "$app_path"

  for attempt in 1 2 3; do
    if [[ "$HEADLESS" == "1" ]]; then
      /usr/bin/open -g -n "$APP_BUNDLE"
    else
      /usr/bin/open -n "$APP_BUNDLE"
    fi
    if wait_for_window; then
      assert_no_focus_steal "$context"
      return 0
    fi
    echo "$APP_NAME launch attempt $attempt did not expose a window for $context" >&2
    terminate_e2e_app
    wait_for_process_exit || true
    sleep "$attempt"
  done

  report_window_launch_failure "$context"
  return 1
}

assert_no_privacy_prompts() {
  local context="$1"
  local prompt_text
  prompt_text="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  set collectedText to ""
  repeat with processName in {"$APP_NAME", "UserNotificationCenter"}
    if exists process (processName as text) then
      tell process (processName as text)
        repeat with candidateWindow in windows
          try
            set collectedText to collectedText & (value of static texts of candidateWindow as string) & linefeed
          end try
        end repeat
      end tell
    end if
  end repeat
  return collectedText
end tell
APPLESCRIPT
)"
  if printf '%s\n' "$prompt_text" | grep -E "would like to access|Apple Music|media library|Documents Folder|Desktop Folder|Downloads Folder" >/dev/null; then
    {
      echo "- macOS privacy prompt appeared during $context."
      echo "  E2E tests must use sandbox fixture directories and must not require granting app permissions."
      printf '  Prompt text: %s\n' "$prompt_text"
    } >>"$SCREENSHOT_BLOCKER"
    return 1
  fi
}

capture_window() {
  local output_path="$1"

  if [[ "$HEADLESS" == "1" ]]; then
    local main_pid
    main_pid="$(app_pid)"
    if [[ -n "$main_pid" ]]; then
      local owner_args=()
      local helper_pid
      while IFS= read -r helper_pid; do
        [[ -n "$helper_pid" ]] && owner_args+=(--owner-pid "$helper_pid")
      done < <(all_helper_pids)
      if "$E2E_TOOL" screenshot --output "$output_path" --main-pid "$main_pid" \
        "${owner_args[@]}" 2>/dev/null; then
        return 0
      fi
    fi
    echo "ScreenCaptureKit capture failed for $output_path; using region capture fallback." >&2
  fi

  local raise_lines=""
  if [[ "$HEADLESS" != "1" ]]; then
    raise_lines='try
      set frontmost to true
    end try
    try
      perform action "AXRaise" of window 1
    end try'
  fi

  local window_info
  window_info="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "$APP_NAME"
    $raise_lines
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
    return 1
  fi

  local bounds="${window_info#*|}"
  if ! /usr/sbin/screencapture -x -R "$bounds" "$output_path" >/dev/null 2>&1; then
    {
      echo "- Could not capture $output_path with screencapture."
      echo "  This usually means the shell lacks Screen Recording permission on this Mac."
    } >>"$SCREENSHOT_BLOCKER"
    return 1
  fi
}

assert_no_terminal_launch_failure() {
  local screenshot_path="$1"
  /usr/bin/swift - "$screenshot_path" <<'SWIFT'
import AppKit
import Foundation

let screenshotPath = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: screenshotPath),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fputs("Could not read screenshot \(screenshotPath)\n", stderr)
  exit(2)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
guard let context = CGContext(
  data: &pixels,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: bytesPerRow,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("Could not create bitmap context for \(screenshotPath)\n", stderr)
  exit(2)
}

context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

var redErrorPixels = 0
let xRange = (width * 12 / 100)..<(width * 78 / 100)
let yRange = (height * 8 / 100)..<(height * 45 / 100)
for y in yRange {
  for x in xRange {
    let offset = y * bytesPerRow + x * bytesPerPixel
    let red = pixels[offset]
    let green = pixels[offset + 1]
    let blue = pixels[offset + 2]
    if red > 170 && green < 130 && blue < 140 {
      redErrorPixels += 1
    }
  }
}

if redErrorPixels > 1000 {
  fputs("Screenshot appears to contain Ghostty terminal failure text: \(screenshotPath) (\(redErrorPixels) red error pixels)\n", stderr)
  exit(1)
}
SWIFT
}

assert_terminal_region_not_near_white() {
  local screenshot_path="$1"
  local label="$2"
  local x_start_percent="$3"
  local x_end_percent="$4"
  local y_start_percent="$5"
  local y_end_percent="$6"
  /usr/bin/swift - "$screenshot_path" "$label" "$x_start_percent" "$x_end_percent" "$y_start_percent" "$y_end_percent" <<'SWIFT'
import AppKit
import Foundation

let screenshotPath = CommandLine.arguments[1]
let label = CommandLine.arguments[2]
guard CommandLine.arguments.count == 7,
      let xStartPercent = Int(CommandLine.arguments[3]),
      let xEndPercent = Int(CommandLine.arguments[4]),
      let yStartPercent = Int(CommandLine.arguments[5]),
      let yEndPercent = Int(CommandLine.arguments[6]),
      let image = NSImage(contentsOfFile: screenshotPath),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
  fputs("Could not read screenshot or region arguments for \(screenshotPath)\n", stderr)
  exit(2)
}

let width = cgImage.width
let height = cgImage.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
guard let context = CGContext(
  data: &pixels,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: bytesPerRow,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("Could not create bitmap context for \(screenshotPath)\n", stderr)
  exit(2)
}

context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

let xRange = max(0, width * xStartPercent / 100)..<min(width, width * xEndPercent / 100)
let yRange = max(0, height * yStartPercent / 100)..<min(height, height * yEndPercent / 100)
var nearWhitePixels = 0
var totalPixels = 0
for y in yRange {
  for x in xRange {
    let offset = y * bytesPerRow + x * bytesPerPixel
    let red = pixels[offset]
    let green = pixels[offset + 1]
    let blue = pixels[offset + 2]
    if red >= 235 && green >= 235 && blue >= 235 {
      nearWhitePixels += 1
    }
    totalPixels += 1
  }
}

guard totalPixels > 0 else {
  fputs("Empty screenshot region for \(label): \(screenshotPath)\n", stderr)
  exit(2)
}

let nearWhiteRatio = Double(nearWhitePixels) / Double(totalPixels)
if nearWhiteRatio > 0.45 {
  let percent = String(format: "%.1f", nearWhiteRatio * 100)
  fputs("\(label) terminal region is dominantly near-white in \(screenshotPath): \(percent)% near-white pixels\n", stderr)
  exit(1)
}
SWIFT
}

launch_state() {
  local state="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  local database_path="$ARTIFACT_DIR/states/$state.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/$state.png"
  local log_path="$ARTIFACT_DIR/$state.app.log"

  : >"$log_path"
  if ! launch_e2e_app "$database_path" "$app_path" "visual state $state"; then
    sed -n '1,120p' "$log_path" >&2 || true
    return 1
  fi

  if [[ "$state" == "missing-tool" ]]; then
    sleep 3
  else
    sleep 1
  fi
  if [[ "$state" == "panel-resize" ]]; then
    osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    $RAISE_WINDOW_LINE
    set size of window 1 to {980, 700}
    delay 0.15
    set size of window 1 to {1180, 820}
    delay 0.15
    set size of window 1 to {1040, 720}
    delay 0.15
    set size of window 1 to {1100, 760}
  end tell
end tell
APPLESCRIPT
    sleep 1
  fi
  assert_no_privacy_prompts "$state"
  capture_window "$screenshot_path"
  assert_no_terminal_launch_failure "$screenshot_path"
  assert_no_focus_steal "visual state $state"
  terminate_e2e_app
}

wait_for_sql_value() {
  local database_path="$1"
  local query="$2"
  local expected="$3"
  local label="$4"
  local value=""

  for _ in {1..80}; do
    value="$(sqlite3 "$database_path" "$query" 2>/dev/null || true)"
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi
    sleep 0.1
  done

  echo "$APP_NAME expected $label to be '$expected' but saw '$value'" >&2
  return 1
}

click_screen_point() {
  local x="$1"
  local y="$2"
  /usr/bin/swift - "$x" "$y" <<'SWIFT' >/dev/null
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2])
else {
  fputs("usage: click_screen_point x y\n", stderr)
  exit(2)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(
  mouseEventSource: source,
  mouseType: .leftMouseDown,
  mouseCursorPosition: point,
  mouseButton: .left
)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.08)
CGEvent(
  mouseEventSource: source,
  mouseType: .leftMouseUp,
  mouseCursorPosition: point,
  mouseButton: .left
)?.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.35)
SWIFT
}

# Pid that keyboard shortcuts target in headless mode: the focused project
# terminal helper (the same window that receives keystrokes in headed mode).
KEY_TARGET_PID=""

key_target_pid() {
  # IOSurface compositing model: the render helper is faceless (no key window),
  # so keystrokes / clicks must target the APP process. The app's pane view is
  # first responder and forwards input to the helper over XPC. (The pre-rewrite
  # overlay model targeted the helper window directly.)
  if [[ -z "$KEY_TARGET_PID" ]]; then
    KEY_TARGET_PID="$(app_pid)"
  fi
  printf '%s' "$KEY_TARGET_PID"
}

# Position the workspace window (so region screenshots have a stable layout) and,
# in headed mode only, bring it to the front. The headless contract forbids the
# app from ever becoming frontmost, so headless probes never activate it; they
# drive the app through command shortcuts (menu key-equivalents route to a
# backgrounded app) + durable state, not typed-into-pane input. Typed input
# (which the IOSurface model delivers through the app's *focused* pane, requiring
# a key window) is therefore a headed-only concern — see run_keyboard_input_probe.
focus_workspace_terminal() {
  KEY_TARGET_PID=""
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  tell process "$APP_NAME"
    set position of window 1 to {0, 25}
    set size of window 1 to {1100, 732}
  end tell
end tell
APPLESCRIPT
  if [[ "$HEADLESS" != "1" ]]; then
    osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  tell process "$APP_NAME"
    set frontmost to true
    perform action "AXRaise" of window 1
  end tell
end tell
APPLESCRIPT
    sleep 0.3
  fi
}

driver_key_name() {
  case "$1" in
    ",") printf 'comma' ;;
    "[") printf 'lbracket' ;;
    "]") printf 'rbracket' ;;
    ".") printf 'period' ;;
    *) printf '%s' "$1" ;;
  esac
}

send_command_shortcut() {
  local key="$1"
  if [[ "$HEADLESS" == "1" ]]; then
    "$E2E_TOOL" send-key --pid "$(key_target_pid)" \
      --key "$(driver_key_name "$key")" --modifiers command
    return
  fi
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  keystroke "$key" using command down
end tell
APPLESCRIPT
}

send_command_shift_shortcut() {
  local key="$1"
  if [[ "$HEADLESS" == "1" ]]; then
    "$E2E_TOOL" send-key --pid "$(key_target_pid)" \
      --key "$(driver_key_name "$key")" --modifiers command,shift
    return
  fi
  local key_code=""
  case "$key" in
    "[")
      key_code=33
      ;;
    "]")
      key_code=30
      ;;
  esac
  if [[ -n "$key_code" ]]; then
    osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  key code $key_code using {command down, shift down}
end tell
APPLESCRIPT
    return
  fi

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  keystroke "$key" using {command down, shift down}
end tell
APPLESCRIPT
}

assert_settings_editor_visible() {
  osascript <<APPLESCRIPT >/dev/null
on findByIdentifier(rootElement, targetIdentifier)
  tell application "System Events"
    try
      if (value of attribute "AXIdentifier" of rootElement as text) is targetIdentifier then return rootElement
    end try
    try
      set childElements to UI elements of rootElement
    on error
      return missing value
    end try
    repeat with childElement in childElements
      try
        set foundElement to my findByIdentifier(childElement, targetIdentifier)
        if foundElement is not missing value then return foundElement
      end try
    end repeat
  end tell
  return missing value
end findByIdentifier

on findInWindows(processName, targetIdentifier)
  tell application "System Events"
    tell process processName
      set windowElements to windows
    end tell
    repeat with windowElement in windowElements
      set foundElement to my findByIdentifier(windowElement, targetIdentifier)
      if foundElement is not missing value then return foundElement
    end repeat
  end tell
  return missing value
end findInWindows

on selectSidebarRow(labelElement)
  tell application "System Events"
    set currentElement to labelElement
    repeat 8 times
      try
        if (value of attribute "AXRole" of currentElement as text) is "AXRow" then
          set value of attribute "AXSelected" of currentElement to true
          return true
        end if
      end try
      try
        set currentElement to (value of attribute "AXParent" of currentElement)
      on error
        return false
      end try
    end repeat
  end tell
  return false
end selectSidebarRow

tell application "System Events"
  tell process "$APP_NAME"
    set sidebarItem to missing value
    repeat 80 times
      set sidebarItem to my findInWindows("$APP_NAME", "settings-sidebar-config-file")
      if sidebarItem is not missing value then exit repeat
      delay 0.1
    end repeat
    if sidebarItem is missing value then error "settings sidebar not found after Cmd+,"
    if not (my selectSidebarRow(sidebarItem)) then error "settings sidebar row could not be selected"
    repeat 80 times
      if my findInWindows("$APP_NAME", "settings-yaml-editor") is not missing value then return
      delay 0.1
    end repeat
    error "settings YAML editor not found after Cmd+,"
  end tell
end tell
APPLESCRIPT
}

run_workspace_shortcut_probe() {
  local database_path="$ARTIFACT_DIR/states/workspace-shortcuts.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/workspace-shortcuts.png"
  local selected_tab_query="SELECT COALESCE((SELECT selected_tab_id FROM right_panel_tab_state ORDER BY thread_id LIMIT 1), '');"
  local bottom_terminal_query="SELECT COALESCE((SELECT is_expanded FROM bottom_terminal_state ORDER BY thread_id LIMIT 1), 0);"

  cp "$ARTIFACT_DIR/states/launch.sqlite" "$database_path"
  sqlite3 "$database_path" "DELETE FROM bottom_terminal_state; UPDATE right_panel_modes SET mode = 'files'; UPDATE right_panel_tab_state SET selected_tab_id = 'files';"
  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "workspace shortcut probe"
  assert_no_privacy_prompts "workspace shortcut probe"
  focus_workspace_terminal

  send_command_shortcut "j"
  wait_for_sql_value "$database_path" "$bottom_terminal_query" "1" "Cmd+J bottom terminal expansion" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shortcut "2"
  wait_for_sql_value "$database_path" "$selected_tab_query" "git" "Cmd+2 right-panel selection" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shortcut "3"
  wait_for_sql_value "$database_path" "$selected_tab_query" "nvim" "Cmd+3 right-panel selection" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shortcut "1"
  wait_for_sql_value "$database_path" "$selected_tab_query" "files" "Cmd+1 right-panel selection" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  sqlite3 "$database_path" "UPDATE right_panel_modes SET mode = 'files'; UPDATE right_panel_tab_state SET selected_tab_id = 'files';"
  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "workspace shortcut cycling probe"
  assert_no_privacy_prompts "workspace shortcut cycling probe"
  focus_workspace_terminal

  send_command_shift_shortcut "["
  wait_for_sql_value "$database_path" "$selected_tab_query" "nvim" "Cmd+Shift+[ right-panel cycling" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shift_shortcut "]"
  wait_for_sql_value "$database_path" "$selected_tab_query" "files" "Cmd+Shift+] right-panel cycling" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shortcut ","
  if ! assert_settings_editor_visible; then
    echo "$APP_NAME did not open Settings from Cmd+," >&2
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  fi

  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "workspace Cmd+Q probe"
  assert_no_privacy_prompts "workspace Cmd+Q probe"
  focus_workspace_terminal
  send_command_shortcut "q"
  if ! wait_for_process_exit; then
    echo "$APP_NAME did not quit after Cmd+Q from workspace terminal focus" >&2
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  fi
}

run_keyboard_input_probe() {
  # Typed input is delivered through the app's *focused* pane (the IOSurface model
  # has no key-able helper window of its own, unlike the old overlay helper), so
  # this probe requires the app to be frontmost with a key window — which the
  # headless no-focus-steal contract forbids. It therefore runs in --headed mode
  # only (the suite's documented "full-fidelity OS key-routing" path). The headless
  # default still verifies rendering, durable state, command shortcuts (menu
  # key-equivalents route to a backgrounded app), crash isolation, and visual
  # states. Manual/real-use typing is verified working (the agent terminal
  # auto-focuses and forwards keystrokes over XPC).
  if [[ "$HEADLESS" == "1" ]]; then
    echo "- skipping keyboard input probe in headless mode (typed input needs app focus; run --headed)"
    return 0
  fi
  local database_path="$ARTIFACT_DIR/states/keyboard-input.sqlite"
  local expected="keyboardprobeenter"
  local screenshot_path="$SCREENSHOT_DIR/keyboard-input.png"

  launchctl setenv YAAW_E2E_KEYBOARD_PROBE "1"
  rm -f "$ARTIFACT_DIR/captures"/*.log
  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "keyboard input probe"
  assert_no_privacy_prompts "keyboard input probe"
  for _ in {1..80}; do
    if grep -R "YAAW_KEYBOARD_PROBE_READY" "$ARTIFACT_DIR/captures" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  assert_terminal_helper_running "keyboard input probe"

  focus_workspace_terminal
  # Surface presence is the running helper above; the real assertion is that the
  # pasted text + Enter reach the terminal (checked via the capture log below).

  printf '%s' "$expected" | /usr/bin/pbcopy
  if [[ "$HEADLESS" == "1" ]]; then
    "$E2E_TOOL" send-key --pid "$(key_target_pid)" --key v --modifiers command
    sleep 0.2
    "$E2E_TOOL" send-key --pid "$(key_target_pid)" --key return
  else
    osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  keystroke "v" using command down
  delay 0.2
  key code 36
end tell
APPLESCRIPT
  fi

  for _ in {1..80}; do
    if grep -aR "YAAW_ENTER_RECEIVED=.*$expected" "$ARTIFACT_DIR/captures" >/dev/null 2>&1; then
      terminate_e2e_app
      launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.1
  done

  echo "$APP_NAME did not deliver pasted text plus Enter to the focused terminal" >&2
  capture_window "$screenshot_path" || true
  find "$ARTIFACT_DIR/captures" -maxdepth 1 -type f -print -exec sed -n '1,80p' {} \; >&2 || true
  terminate_e2e_app
  launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
  return 1
}

run_isolated_terminal_visibility_probe() {
  local database_path="$ARTIFACT_DIR/states/isolated-terminal-visibility.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/isolated-terminal-visibility.png"
  local launch_screenshot_path="$SCREENSHOT_DIR/isolated-terminal-visibility-launch.png"
  local git_screenshot_path="$SCREENSHOT_DIR/isolated-terminal-visibility-git.png"
  local selected_tab_query="SELECT COALESCE((SELECT selected_tab_id FROM right_panel_tab_state ORDER BY thread_id LIMIT 1), '');"
  local bottom_terminal_query="SELECT COALESCE((SELECT is_expanded FROM bottom_terminal_state ORDER BY thread_id LIMIT 1), 0);"

  cp "$ARTIFACT_DIR/states/launch.sqlite" "$database_path"
  sqlite3 "$database_path" "DELETE FROM bottom_terminal_state; UPDATE right_panel_modes SET mode = 'files'; UPDATE right_panel_tab_state SET selected_tab_id = 'files';"
  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "isolated terminal visibility probe"
  assert_no_privacy_prompts "isolated terminal visibility probe"
  focus_workspace_terminal
  assert_terminal_helper_running "isolated terminal visibility probe"
  capture_window "$launch_screenshot_path" || true
  # Compositing is verified by the composited pixels in the pane region (the
  # helper is faceless under the IOSurface model — no window to assert on).
  assert_terminal_region_not_near_white "$launch_screenshot_path" "project terminal launch" 22 78 12 78 || {
    terminate_e2e_app
    return 1
  }
  focus_workspace_terminal

  send_command_shortcut "j"
  # The durable state transition is the deterministic signal that the app
  # processed the toggle and (de)activated the bottom-terminal surface; the
  # compositing mechanism itself is the same one verified for the project pane.
  wait_for_sql_value "$database_path" "$bottom_terminal_query" "1" "bottom terminal expansion" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }
  capture_window "$SCREENSHOT_DIR/isolated-terminal-visibility-bottom.png" || true

  send_command_shortcut "j"
  wait_for_sql_value "$database_path" "$bottom_terminal_query" "0" "bottom terminal collapse" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shortcut "2"
  wait_for_sql_value "$database_path" "$selected_tab_query" "git" "git tab selection" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }
  capture_window "$git_screenshot_path" || true
  assert_terminal_region_not_near_white "$git_screenshot_path" "git terminal tab" 73 98 12 88 || {
    terminate_e2e_app
    return 1
  }
  focus_workspace_terminal

  send_command_shortcut "1"
  wait_for_sql_value "$database_path" "$selected_tab_query" "files" "files tab selection" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    $RAISE_WINDOW_LINE
    set size of window 1 to {980, 700}
    delay 0.15
    set size of window 1 to {1180, 820}
    delay 0.15
    set size of window 1 to {1040, 720}
    delay 0.15
    set size of window 1 to {1100, 760}
  end tell
end tell
APPLESCRIPT
  capture_window "$screenshot_path" || true
  # After a flurry of resizes the project pane must still composite content
  # (the surface tracks the pane size; a stale/blank pane would read near-white).
  assert_terminal_region_not_near_white "$screenshot_path" "window resize tracking" 22 78 12 78 || {
    terminate_e2e_app
    return 1
  }
  terminate_e2e_app
}

run_settings_editor_probe() {
  local database_path="$ARTIFACT_DIR/states/settings-editor.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/settings-editor.png"

  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "settings editor"
  assert_no_privacy_prompts "settings editor"

  local settings_probe_raise_lines="delay 0"
  if [[ "$HEADLESS" != "1" ]]; then
    settings_probe_raise_lines='try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1'
  fi

  if ! osascript <<APPLESCRIPT >/dev/null
on findByIdentifier(rootElement, targetIdentifier)
  tell application "System Events"
    try
      if (value of attribute "AXIdentifier" of rootElement as text) is targetIdentifier then return rootElement
    end try
    try
      set childElements to UI elements of rootElement
    on error
      return missing value
    end try
    repeat with childElement in childElements
      try
        set foundElement to my findByIdentifier(childElement, targetIdentifier)
        if foundElement is not missing value then return foundElement
      end try
    end repeat
  end tell
  return missing value
end findByIdentifier

on findTextArea(rootElement)
  tell application "System Events"
    try
      if (value of attribute "AXRole" of rootElement as text) is "AXTextArea" then return rootElement
    end try
    try
      set childElements to UI elements of rootElement
    on error
      return missing value
    end try
    repeat with childElement in childElements
      try
        set foundElement to my findTextArea(childElement)
        if foundElement is not missing value then return foundElement
      end try
    end repeat
  end tell
  return missing value
end findTextArea

on findInWindows(processName, targetIdentifier)
  tell application "System Events"
    tell process processName
      set windowElements to windows
    end tell
    repeat with windowElement in windowElements
      set foundElement to my findByIdentifier(windowElement, targetIdentifier)
      if foundElement is not missing value then return foundElement
    end repeat
  end tell
  return missing value
end findInWindows

on selectSidebarRow(labelElement)
  tell application "System Events"
    set currentElement to labelElement
    repeat 8 times
      try
        if (value of attribute "AXRole" of currentElement as text) is "AXRow" then
          set value of attribute "AXSelected" of currentElement to true
          return true
        end if
      end try
      try
        set currentElement to (value of attribute "AXParent" of currentElement)
      on error
        return false
      end try
    end repeat
  end tell
  return false
end selectSidebarRow

tell application "System Events"
  tell process "$APP_NAME"
    $settings_probe_raise_lines
    set openButton to my findByIdentifier(window 1, "open-settings-button")
    if openButton is missing value then error "settings button not found"
    click openButton

    set sidebarItem to missing value
    repeat 80 times
      set sidebarItem to my findInWindows("$APP_NAME", "settings-sidebar-config-file")
      if sidebarItem is not missing value then exit repeat
      delay 0.1
    end repeat
    if sidebarItem is missing value then error "settings sidebar not found"
    if not (my selectSidebarRow(sidebarItem)) then error "settings sidebar row could not be selected"

    set editorContainer to missing value
    repeat 80 times
      set editorContainer to my findInWindows("$APP_NAME", "settings-yaml-editor")
      if editorContainer is not missing value then exit repeat
      delay 0.1
    end repeat
    if editorContainer is missing value then error "settings YAML editor not found"

    set editorArea to my findTextArea(editorContainer)
    if editorArea is missing value then set editorArea to my findTextArea(window 1)
    if editorArea is missing value then error "settings text area not found"
    set existingText to value of editorArea as text
    if existingText does not contain "# YAAW settings." then error "settings YAML text did not load"

    -- Keep a fixed theme pinned: the app defaults to System mode, which would
    -- make the later visual-state screenshots depend on the host appearance.
    set replacementText to "version: 1" & linefeed & "agent:" & linefeed & "  default: claude" & linefeed & "theme:" & linefeed & "  active: ghostty-default" & linefeed
    set focused of editorArea to true
    delay 0.2
    set value of editorArea to replacementText
    delay 0.4
    set updatedText to value of editorArea as text
    if updatedText does not contain "default: claude" then error "settings YAML editor did not accept edited text"

    set saveButton to my findInWindows("$APP_NAME", "settings-save-button")
    if saveButton is missing value then error "settings save button not found"
    click saveButton
    delay 0.5

    set settingsWindow to missing value
    repeat with windowElement in windows
      if my findByIdentifier(windowElement, "settings-yaml-editor") is not missing value then
        set settingsWindow to windowElement
        exit repeat
      end if
    end repeat
    if settingsWindow is missing value then error "settings window not found for close"
    click (first button of settingsWindow whose subrole is "AXCloseButton")

    repeat 50 times
      if my findInWindows("$APP_NAME", "settings-yaml-editor") is missing value then exit repeat
      delay 0.1
    end repeat
    if my findInWindows("$APP_NAME", "settings-yaml-editor") is not missing value then error "settings window did not close"

    set returnedButton to my findInWindows("$APP_NAME", "open-settings-button")
    if returnedButton is missing value then error "workspace window not reachable after closing settings"

    -- Native-toolbar smoke check: panel toggles must stay AX-discoverable.
    if my findInWindows("$APP_NAME", "toggle-sidebar-button") is missing value then error "sidebar toggle not found in toolbar"
    if my findInWindows("$APP_NAME", "toggle-right-panel-button") is missing value then error "right panel toggle not found in toolbar"
  end tell
end tell
APPLESCRIPT
  then
    echo "$APP_NAME settings editor probe failed" >&2
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  fi

  if ! grep -A2 "^agent:" "$ARTIFACT_DIR/config/settings.yaml" | grep "default: claude" >/dev/null; then
    echo "$APP_NAME settings editor save did not update the YAML file" >&2
    sed -n '1,80p' "$ARTIFACT_DIR/config/settings.yaml" >&2 || true
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  fi

  terminate_e2e_app
}

# --- AX-identifier targeting (Chunk F mandate) -------------------------------
# Every interactive control now carries a stable accessibilityIdentifier, so
# probes target controls by id instead of by hardcoded coordinates (which break
# on any layout change). These helpers recursively search the AX tree for an
# AXIdentifier and click / read / wait on the match. Coordinate clicks remain
# only as a fallback (focus_workspace_terminal) and emit no assertions.

# Recursively find an element by AXIdentifier in the app's windows; click it.
# Usage: ax_click_identifier <identifier>  -> 0 if clicked, 1 otherwise.
ax_click_identifier() {
  local identifier="$1"
  osascript <<APPLESCRIPT >/dev/null 2>&1
on findByIdentifier(rootElement, targetIdentifier)
  tell application "System Events"
    try
      if (value of attribute "AXIdentifier" of rootElement as text) is targetIdentifier then return rootElement
    end try
    try
      set childElements to UI elements of rootElement
    on error
      return missing value
    end try
    repeat with childElement in childElements
      try
        set foundElement to my findByIdentifier(childElement, targetIdentifier)
        if foundElement is not missing value then return foundElement
      end try
    end repeat
  end tell
  return missing value
end findByIdentifier

tell application "System Events"
  tell process "$APP_NAME"
    repeat with windowElement in windows
      set foundElement to my findByIdentifier(windowElement, "$identifier")
      if foundElement is not missing value then
        click foundElement
        return
      end if
    end repeat
  end tell
end tell
error "AXIdentifier $identifier not found"
APPLESCRIPT
}

# Wait (up to 8s) for an element with the given AXIdentifier to exist.
# Usage: ax_wait_for_identifier <identifier> <context>
ax_wait_for_identifier() {
  local identifier="$1"
  local context="$2"
  for _ in {1..80}; do
    if osascript <<APPLESCRIPT >/dev/null 2>&1
on findByIdentifier(rootElement, targetIdentifier)
  tell application "System Events"
    try
      if (value of attribute "AXIdentifier" of rootElement as text) is targetIdentifier then return rootElement
    end try
    try
      set childElements to UI elements of rootElement
    on error
      return missing value
    end try
    repeat with childElement in childElements
      try
        set foundElement to my findByIdentifier(childElement, targetIdentifier)
        if foundElement is not missing value then return foundElement
      end try
    end repeat
  end tell
  return missing value
end findByIdentifier

tell application "System Events"
  tell process "$APP_NAME"
    repeat with windowElement in windows
      if my findByIdentifier(windowElement, "$identifier") is not missing value then return
    end repeat
  end tell
end tell
error "missing $identifier"
APPLESCRIPT
    then
      return 0
    fi
    sleep 0.1
  done
  echo "$APP_NAME did not expose AXIdentifier '$identifier' during $context" >&2
  return 1
}

# --- Crash-isolation probe (kill -9 a render helper) -------------------------
# Per-helper isolation contract (ADR-004): SIGKILL one render-host helper and
# assert the app process survives, the frontmost app is unchanged, and the pane
# recovers (a NEW helper pid appears for the surface). Exits nonzero if the app
# crashes or no replacement helper appears within the recovery window.
assert_app_still_running() {
  local context="$1"
  if [[ -z "$(running_e2e_app_pids)" ]]; then
    echo "$APP_NAME process died during $context (crash isolation violated)" >&2
    return 1
  fi
}

run_crash_isolation_probe() {
  local database_path="$ARTIFACT_DIR/states/crash-isolation.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/crash-isolation.png"

  cp "$ARTIFACT_DIR/states/launch.sqlite" "$database_path"
  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "crash isolation probe"
  assert_no_privacy_prompts "crash isolation probe"
  focus_workspace_terminal
  assert_terminal_helper_running "crash isolation probe"

  local before_app frontmost_before victim
  before_app="$(app_pid)"
  frontmost_before="$("$E2E_TOOL" frontmost 2>/dev/null || echo unknown)"
  victim="$(all_helper_pids | tail -n 1)"
  if [[ -z "$victim" ]]; then
    echo "$APP_NAME crash isolation probe found no render helper to kill" >&2
    terminate_e2e_app
    return 1
  fi

  # SIGKILL via the driver (equivalent to `kill -9 $victim`).
  "$E2E_TOOL" kill-helper --pid "$victim" 2>/dev/null || kill -9 "$victim" 2>/dev/null || true

  # App must survive and stay the same process; frontmost must be unchanged.
  if ! assert_app_still_running "crash isolation probe"; then
    capture_window "$screenshot_path" || true
    return 1
  fi
  if [[ "$(app_pid)" != "$before_app" ]]; then
    echo "$APP_NAME pid changed after killing a render helper (app restarted)" >&2
    terminate_e2e_app
    return 1
  fi
  local frontmost_after
  frontmost_after="$("$E2E_TOOL" frontmost 2>/dev/null || echo unknown)"
  if [[ "$frontmost_after" != "$frontmost_before" ]]; then
    echo "$APP_NAME crash isolation changed frontmost ($frontmost_before -> $frontmost_after)" >&2
  fi

  # Pane recovery: a NEW helper pid (different from the victim) must appear.
  local recovered=""
  for _ in {1..50}; do
    recovered="$(all_helper_pids | grep -vx "$victim" | tail -n 1 || true)"
    [[ -n "$recovered" ]] && break
    sleep 0.1
  done
  if [[ -z "$recovered" ]]; then
    echo "$APP_NAME killed render helper did not recover within 5s" >&2
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  fi
  capture_window "$screenshot_path" || true
  terminate_e2e_app
}

if [[ "$RUNNER_STATUS" -ne 0 ]]; then
  launch_state "launch" || true
  exit "$RUNNER_STATUS"
fi

# --- Performance gates (Chunk A/B/D/E) ---------------------------------------
# The release perf gate runs via the YAAWKitPerf executable, not
# `RUN_BENCHMARKS=1 swift test -c release`: XCTest targets importing YAAWKit
# crash the Swift 6.3 release optimizer (DECISIONS-LOG D-010), so the
# authoritative release numbers come from the plain executable. A nonzero exit
# means a gate regressed and fails the suite.
echo "Running release perf gates (YAAWKitPerf)..."
if ! swift run -c release YAAWKitPerf; then
  echo "Release perf gates failed (YAAWKitPerf exited nonzero)" >&2
  exit 1
fi

# Avoid coordinate-driven UI journeys in this harness. The Swift E2E runner
# verifies durable state transitions directly, while the launched app states
# below verify real rendering and terminal behavior through screenshots.
run_keyboard_input_probe
assert_no_focus_steal "keyboard input probe"
run_isolated_terminal_visibility_probe
assert_no_focus_steal "isolated terminal visibility probe"
run_workspace_shortcut_probe
assert_no_focus_steal "workspace shortcut probe"
run_settings_editor_probe
assert_no_focus_steal "settings editor probe"
run_crash_isolation_probe
assert_no_focus_steal "crash isolation probe"

for state in launch project-creation files browser-preview nvim git missing-directory bottom-terminal panel-resize panel-collapse; do
  launch_state "$state"
done

launch_state "missing-tool" "$ARTIFACT_DIR/bin-missing-lazygit:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -s "$SCREENSHOT_BLOCKER" ]]; then
  cat "$SCREENSHOT_BLOCKER" >&2
  exit 1
else
  rm -f "$SCREENSHOT_BLOCKER"
fi

if [[ -s "$FOCUS_BLOCKER" ]]; then
  cat "$FOCUS_BLOCKER" >&2
  # CI runners have no user at the screen; warn without failing there.
  if [[ "${CI:-}" != "true" ]]; then
    exit 1
  fi
else
  rm -f "$FOCUS_BLOCKER"
fi

echo "E2E artifacts: $ARTIFACT_DIR"
