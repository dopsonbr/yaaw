#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${YAAW_E2E_ARTIFACTS:-$ROOT_DIR/.build/e2e-artifacts/latest}"
APP_NAME="YAAW"
ORIGINAL_ZDOTDIR="$(launchctl getenv ZDOTDIR || true)"

cd "$ROOT_DIR"

APP_BUNDLE="$(./script/build_and_run.sh --build-only | tail -1)"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

SCREENSHOT_DIR="$ARTIFACT_DIR/screenshots"
SCREENSHOT_BLOCKER="$SCREENSHOT_DIR/SCREENSHOT_BLOCKER.md"
mkdir -p "$SCREENSHOT_DIR"
: >"$SCREENSHOT_BLOCKER"

RUNNER_STATUS=0
swift run YAAWE2E --artifacts "$ARTIFACT_DIR" || RUNNER_STATUS=$?

cleanup() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_DATABASE_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_CONFIG_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_CAPTURE_DIRECTORY >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_PATH >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
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
  launchctl setenv YAAW_DATABASE_PATH "$database_path"
  launchctl setenv YAAW_CONFIG_PATH "$ARTIFACT_DIR/config/config.json"
  launchctl setenv YAAW_CAPTURE_DIRECTORY "$ARTIFACT_DIR/captures"
  launchctl setenv YAAW_PATH "$app_path"
  if [[ -n "$zdotdir" ]]; then
    launchctl setenv ZDOTDIR "$zdotdir"
  else
    restore_zdotdir
  fi
}

wait_for_window() {
  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  repeat 150 times
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

dismiss_privacy_prompts() {
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  if exists process "$APP_NAME" then
    tell process "$APP_NAME"
      repeat with candidateWindow in windows
        try
          set windowText to value of static texts of candidateWindow as string
          if windowText contains "would like to access" then
            click button 1 of candidateWindow
          end if
        end try
      end repeat
    end tell
  end if
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

  dismiss_privacy_prompts
  if [[ "$state" == "missing-tool" ]]; then
    sleep 3
  else
    sleep 1
  fi
  capture_window "$screenshot_path"
  assert_no_terminal_launch_failure "$screenshot_path"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

run_keyboard_input_probe() {
  local database_path="$ARTIFACT_DIR/states/keyboard-input.sqlite"
  local expected="keyboardprobeenter"
  local screenshot_path="$SCREENSHOT_DIR/keyboard-input.png"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  set_launch_environment "$database_path"
  launchctl setenv YAAW_E2E_KEYBOARD_PROBE "1"
  rm -f "$ARTIFACT_DIR/captures"/*.log
  /usr/bin/open -n "$APP_BUNDLE"
  wait_for_window
  dismiss_privacy_prompts
  for _ in {1..80}; do
    if grep -R "YAAW_KEYBOARD_PROBE_READY" "$ARTIFACT_DIR/captures" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    perform action "AXRaise" of window 1
    set position of window 1 to {0, 25}
    set size of window 1 to {1100, 732}
    delay 1
    set windowPosition to position of window 1
    set baseX to item 1 of windowPosition
    set baseY to item 2 of windowPosition
    click at {baseX + 470, baseY + 360}
    delay 0.2
    key code 40
    delay 0.05
    key code 14
    delay 0.05
    key code 16
    delay 0.05
    key code 11
    delay 0.05
    key code 31
    delay 0.05
    key code 0
    delay 0.05
    key code 15
    delay 0.05
    key code 2
    delay 0.05
    key code 35
    delay 0.05
    key code 15
    delay 0.05
    key code 31
    delay 0.05
    key code 11
    delay 0.05
    key code 14
    delay 0.05
    key code 14
    delay 0.05
    key code 45
    delay 0.05
    key code 17
    delay 0.05
    key code 14
    delay 0.05
    key code 15
    delay 0.05
    key code 36
  end tell
end tell
APPLESCRIPT

  for _ in {1..80}; do
    if grep -R "YAAW_ENTER_RECEIVED=$expected" "$ARTIFACT_DIR/captures" >/dev/null 2>&1; then
      pkill -x "$APP_NAME" >/dev/null 2>&1 || true
      launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
      return 0
    fi
    sleep 0.1
  done

  echo "$APP_NAME did not deliver typed text plus Enter to the focused terminal" >&2
  capture_window "$screenshot_path" || true
  find "$ARTIFACT_DIR/captures" -maxdepth 1 -type f -print -exec sed -n '1,80p' {} \; >&2 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  launchctl unsetenv YAAW_E2E_KEYBOARD_PROBE >/dev/null 2>&1 || true
  return 1
}

if [[ "$RUNNER_STATUS" -ne 0 ]]; then
  launch_state "launch" || true
  exit "$RUNNER_STATUS"
fi

# Avoid coordinate-driven UI journeys in this harness. The Swift E2E runner
# verifies durable state transitions directly, while the launched app states
# below verify real rendering and terminal behavior through screenshots.
run_keyboard_input_probe

MISSING_TOOL_ZDOTDIR="$ARTIFACT_DIR/zsh-missing-tools"
mkdir -p "$MISSING_TOOL_ZDOTDIR"
printf 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n' >"$MISSING_TOOL_ZDOTDIR/.zshenv"

for state in launch project-creation files nvim git missing-directory bottom-terminal panel-collapse; do
  launch_state "$state"
done

launch_state "missing-tool" "$ARTIFACT_DIR/bin-missing-lazygit:/usr/bin:/bin:/usr/sbin:/sbin" "$MISSING_TOOL_ZDOTDIR"

if [[ -s "$SCREENSHOT_BLOCKER" ]]; then
  cat "$SCREENSHOT_BLOCKER" >&2
  exit 1
else
  rm -f "$SCREENSHOT_BLOCKER"
fi

echo "E2E artifacts: $ARTIFACT_DIR"
