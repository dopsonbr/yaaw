#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_ARTIFACT_DIR="${TMPDIR:-/tmp}/yaaw-e2e-artifacts/latest"
ARTIFACT_DIR="${YAAW_E2E_ARTIFACTS:-$DEFAULT_ARTIFACT_DIR}"
APP_NAME="YAAW-E2E"

cd "$ROOT_DIR"

printf 'YAAW E2E pasteboard sentinel' | /usr/bin/pbcopy >/dev/null 2>&1 || true

./script/build_and_run.sh --build-only --variant=e2e >/dev/null
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "expected E2E app bundle was not created: $APP_BUNDLE" >&2
  exit 1
fi
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

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

terminal_helper_pids() {
  { ps -axo pid=,args= 2>/dev/null || true; } | awk -v helper="$APP_BUNDLE/Contents/Helpers/YAAWToolHost" '
    index($0, helper) > 0 && index($0, "--tool-kind terminal") > 0 {
      print $1
    }
  '
}

assert_terminal_helper_running() {
  local context="$1"
  for _ in {1..80}; do
    if [[ -n "$(terminal_helper_pids)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "$APP_NAME expected a terminal YAAWToolHost helper during $context" >&2
  return 1
}

helper_window_count_with_prefix() {
  local prefix="$1"
  osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  set matchCount to 0
  repeat with candidateProcess in (processes whose name is "YAAWToolHost")
    tell candidateProcess
      repeat with candidateWindow in windows
        set windowTitle to ""
        try
          set windowTitle to value of attribute "AXTitle" of candidateWindow as text
        end try
        if windowTitle starts with "$prefix" then set matchCount to matchCount + 1
      end repeat
    end tell
  end repeat
  return matchCount
end tell
APPLESCRIPT
}

assert_helper_window_visible_with_prefix() {
  local prefix="$1"
  local context="$2"
  local count=""
  for _ in {1..80}; do
    count="$(helper_window_count_with_prefix "$prefix")"
    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "$APP_NAME expected visible helper window '$prefix*' during $context but saw '$count'" >&2
  return 1
}

assert_helper_window_hidden_with_prefix() {
  local prefix="$1"
  local context="$2"
  local count=""
  for _ in {1..80}; do
    count="$(helper_window_count_with_prefix "$prefix")"
    if [[ "$count" == "0" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "$APP_NAME expected hidden helper window '$prefix*' during $context but saw '$count'" >&2
  return 1
}

SCREENSHOT_DIR="$ARTIFACT_DIR/screenshots"
SCREENSHOT_BLOCKER="$SCREENSHOT_DIR/SCREENSHOT_BLOCKER.md"
mkdir -p "$SCREENSHOT_DIR"
: >"$SCREENSHOT_BLOCKER"

RUNNER_STATUS=0
swift run YAAWE2E --artifacts "$ARTIFACT_DIR" || RUNNER_STATUS=$?

cleanup() {
  terminate_e2e_app
  launchctl unsetenv YAAW_E2E_DATABASE_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_CONFIG_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_CAPTURE_DIRECTORY >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

set_launch_environment() {
  local database_path="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  launchctl setenv YAAW_E2E_DATABASE_PATH "$database_path"
  launchctl setenv YAAW_E2E_CONFIG_PATH "$ARTIFACT_DIR/config/settings.yaml"
  launchctl setenv YAAW_E2E_CAPTURE_DIRECTORY "$ARTIFACT_DIR/captures"
  launchctl setenv YAAW_E2E_PATH "$app_path"
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
    /usr/bin/open -n "$APP_BUNDLE"
    if wait_for_window; then
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
  local window_info
  window_info="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    try
      perform action "AXRaise" of window 1
    end try
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
    perform action "AXRaise" of window 1
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

focus_workspace_terminal() {
  local click_point
  click_point="$(osascript <<APPLESCRIPT
tell application "System Events"
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
    set position of window 1 to {0, 25}
    set size of window 1 to {1100, 732}
    delay 0.5
    set windowPosition to position of window 1
    set baseX to item 1 of windowPosition
    set baseY to item 2 of windowPosition
    return ((baseX + 470) as string) & "," & ((baseY + 360) as string)
  end tell
end tell
APPLESCRIPT
)"
  local click_x="${click_point%,*}"
  local click_y="${click_point#*,}"
  click_screen_point "$click_x" "$click_y"
}

send_command_shortcut() {
  local key="$1"
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  keystroke "$key" using command down
end tell
APPLESCRIPT
}

send_command_shift_shortcut() {
  local key="$1"
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
  assert_helper_window_visible_with_prefix "project:" "keyboard input probe"

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  set the clipboard to "$expected"
  keystroke "v" using command down
  delay 0.2
  key code 36
end tell
APPLESCRIPT

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
  assert_helper_window_visible_with_prefix "project:" "project terminal visibility"
  capture_window "$launch_screenshot_path" || true
  assert_terminal_region_not_near_white "$launch_screenshot_path" "project terminal launch" 22 78 12 78 || {
    terminate_e2e_app
    return 1
  }
  focus_workspace_terminal

  send_command_shortcut "j"
  wait_for_sql_value "$database_path" "$bottom_terminal_query" "1" "bottom terminal expansion" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }
  assert_helper_window_visible_with_prefix "bottom:" "bottom terminal expansion" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  send_command_shortcut "j"
  wait_for_sql_value "$database_path" "$bottom_terminal_query" "0" "bottom terminal collapse" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }
  assert_helper_window_hidden_with_prefix "bottom:" "bottom terminal collapse" || {
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
  assert_helper_window_visible_with_prefix "lazygit:" "git tab selection" || {
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
  assert_helper_window_hidden_with_prefix "lazygit:" "files tab selection" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    perform action "AXRaise" of window 1
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
  assert_helper_window_visible_with_prefix "project:" "window resize tracking" || {
    capture_window "$screenshot_path" || true
    terminate_e2e_app
    return 1
  }
  capture_window "$screenshot_path" || true
  terminate_e2e_app
}

run_settings_editor_probe() {
  local database_path="$ARTIFACT_DIR/states/settings-editor.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/settings-editor.png"

  launch_e2e_app "$database_path" "$ARTIFACT_DIR/bin:$PATH" "settings editor"
  assert_no_privacy_prompts "settings editor"

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
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
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

    set replacementText to "version: 1" & linefeed & "agent:" & linefeed & "  default: claude" & linefeed
    click editorArea
    set focused of editorArea to true
    delay 0.2
    keystroke "a" using command down
    delay 0.1
    set the clipboard to replacementText
    keystroke "v" using command down
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

if [[ "$RUNNER_STATUS" -ne 0 ]]; then
  launch_state "launch" || true
  exit "$RUNNER_STATUS"
fi

# Avoid coordinate-driven UI journeys in this harness. The Swift E2E runner
# verifies durable state transitions directly, while the launched app states
# below verify real rendering and terminal behavior through screenshots.
run_keyboard_input_probe
run_isolated_terminal_visibility_probe
run_workspace_shortcut_probe
run_settings_editor_probe

for state in launch project-creation files nvim git missing-directory bottom-terminal panel-resize panel-collapse; do
  launch_state "$state"
done

launch_state "missing-tool" "$ARTIFACT_DIR/bin-missing-lazygit:/usr/bin:/bin:/usr/sbin:/sbin"

if [[ -s "$SCREENSHOT_BLOCKER" ]]; then
  cat "$SCREENSHOT_BLOCKER" >&2
  exit 1
else
  rm -f "$SCREENSHOT_BLOCKER"
fi

echo "E2E artifacts: $ARTIFACT_DIR"
