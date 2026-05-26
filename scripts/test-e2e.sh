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

launch_state() {
  local state="$1"
  local app_path="${2:-$ARTIFACT_DIR/bin:$PATH}"
  local database_path="$ARTIFACT_DIR/states/$state.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/$state.png"
  local log_path="$ARTIFACT_DIR/$state.app.log"

  terminate_e2e_app
  : >"$log_path"
  set_launch_environment "$database_path" "$app_path"
  /usr/bin/open -n "$APP_BUNDLE"

  if ! wait_for_window; then
    terminate_e2e_app
    sleep 1
    /usr/bin/open -n "$APP_BUNDLE"
    if ! wait_for_window; then
      echo "$APP_NAME did not stay running for visual state $state" >&2
      sed -n '1,120p' "$log_path" >&2 || true
      return 1
    fi
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

wait_for_process_exit() {
  for _ in {1..80}; do
    if [[ -z "$(running_e2e_app_pids)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

focus_workspace_terminal() {
  osascript <<APPLESCRIPT >/dev/null
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
    click at {baseX + 470, baseY + 360}
    delay 0.4
  end tell
end tell
APPLESCRIPT
}

send_command_shortcut() {
  local key="$1"
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
  end tell
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
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
  end tell
  key code $key_code using {command down, shift down}
end tell
APPLESCRIPT
    return
  fi

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
  end tell
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

tell application "System Events"
  tell process "$APP_NAME"
    repeat 80 times
      set editorContainer to my findByIdentifier(window 1, "settings-yaml-editor")
      if editorContainer is not missing value then return
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

  terminate_e2e_app
  cp "$ARTIFACT_DIR/states/launch.sqlite" "$database_path"
  sqlite3 "$database_path" "DELETE FROM bottom_terminal_state; UPDATE right_panel_modes SET mode = 'files'; UPDATE right_panel_tab_state SET selected_tab_id = 'files';"
  set_launch_environment "$database_path"
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window
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

  terminate_e2e_app
  sqlite3 "$database_path" "UPDATE right_panel_modes SET mode = 'files'; UPDATE right_panel_tab_state SET selected_tab_id = 'files';"
  set_launch_environment "$database_path"
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window
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

  terminate_e2e_app
  set_launch_environment "$database_path"
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window
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

  terminate_e2e_app
  set_launch_environment "$database_path"
  launchctl setenv YAAW_E2E_KEYBOARD_PROBE "1"
  rm -f "$ARTIFACT_DIR/captures"/*.log
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window
  assert_no_privacy_prompts "keyboard input probe"
  for _ in {1..80}; do
    if grep -R "YAAW_KEYBOARD_PROBE_READY" "$ARTIFACT_DIR/captures" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
    set position of window 1 to {0, 25}
    set size of window 1 to {1100, 732}
    delay 1
    set windowPosition to position of window 1
    set baseX to item 1 of windowPosition
    set baseY to item 2 of windowPosition
    click at {baseX + 470, baseY + 360}
    delay 1
    set the clipboard to "$expected"
    keystroke "v" using command down
    delay 0.2
    key code 36
  end tell
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

run_settings_editor_probe() {
  local database_path="$ARTIFACT_DIR/states/settings-editor.sqlite"
  local screenshot_path="$SCREENSHOT_DIR/settings-editor.png"

  terminate_e2e_app
  set_launch_environment "$database_path"
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window
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

tell application "System Events"
  tell process "$APP_NAME"
    try
      set frontmost to true
    end try
    perform action "AXRaise" of window 1
    set openButton to my findByIdentifier(window 1, "open-settings-button")
    if openButton is missing value then error "settings button not found"
    click openButton

    set editorContainer to missing value
    repeat 80 times
      set editorContainer to my findByIdentifier(window 1, "settings-yaml-editor")
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

    set saveButton to my findByIdentifier(window 1, "settings-save-button")
    if saveButton is missing value then error "settings save button not found"
    click saveButton
    delay 0.5

    set backButton to my findByIdentifier(window 1, "settings-back-button")
    if backButton is missing value then error "settings back button not found"
    click backButton

    repeat 50 times
      set returnedButton to my findByIdentifier(window 1, "open-settings-button")
      if returnedButton is not missing value then return
      delay 0.1
    end repeat
    error "settings back button did not return to workspace"
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
