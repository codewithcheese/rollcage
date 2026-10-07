#!/bin/bash
# debug-tui.sh — Launch sandboxed claude in screen, capture TUI output, and check rendering.
# Streams sandbox denial logs in the background.
#
# Usage: ./scripts/debug-tui.sh [project_dir] [timeout]
#   project_dir defaults to $PWD
#   timeout     seconds to wait for TUI (default: 8)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(readlink -f "${1:-$PWD}")"
TMPDIR_RESOLVED="$(readlink -f "${TMPDIR:-/private/tmp}")"
CACHE_DIR="${TMPDIR_RESOLVED%/T*}/C"
CAPTURE_FILE="$(mktemp /tmp/rollcage-claude-debug.XXXXXX)"
DENIAL_LOG="/tmp/rollcage-claude-denials-$$.log"
SESSION_NAME="rollcage-claude-debug-$$"
TIMEOUT="${2:-8}"

cleanup() {
  # Kill the denial log stream
  if [[ -n "${LOG_PID:-}" ]]; then
    kill "$LOG_PID" 2>/dev/null || true
    wait "$LOG_PID" 2>/dev/null || true
  fi

  # Dump the screen buffer before quitting
  screen -S "$SESSION_NAME" -p 0 -X hardcopy "$CAPTURE_FILE" 2>/dev/null || true
  screen -S "$SESSION_NAME" -X quit 2>/dev/null || true

  echo ""
  echo "=== Captured TUI output ==="
  if [[ -s "$CAPTURE_FILE" ]]; then
    cat -v "$CAPTURE_FILE" | head -40
  else
    echo "(empty)"
  fi

  echo ""
  echo "=== TUI render check ==="
  if grep -qi 'claude' "$CAPTURE_FILE" 2>/dev/null; then
    echo "PASS: Found 'Claude' in TUI output — rendering works."
  else
    echo "FAIL: 'Claude' not found in TUI output — TUI may not have rendered."
  fi

  echo ""
  echo "=== Sandbox denials ==="
  if [[ -s "$DENIAL_LOG" ]]; then
    cat "$DENIAL_LOG"
  else
    echo "(none)"
  fi

  rm -f "$CAPTURE_FILE" "$DENIAL_LOG"
}
trap cleanup EXIT

if ! command -v screen &>/dev/null; then
  echo "Error: screen is required but not found. Install with: brew install screen" >&2
  exit 1
fi

echo "Project dir:  $PROJECT_DIR"
echo "TMPDIR:       $TMPDIR_RESOLVED"
echo "Cache dir:    $CACHE_DIR"
echo "Launcher:     ${SCRIPT_DIR}/rollcage claude"
echo "Timeout:      ${TIMEOUT}s"
echo ""

# Start sandbox denial log stream in background
/usr/bin/log stream \
  --predicate 'eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "deny"' \
  --style compact > "$DENIAL_LOG" 2>&1 &
LOG_PID=$!

# Launch sandboxed claude in a screen session.
# Screen provides the PTY that the TUI needs to render.
# No stdin redirect, no stdout pipe — let screen own the terminal.
screen -dmS "$SESSION_NAME" /bin/zsh -c \
  'cd "$1" && exec "$2" claude' screen "$PROJECT_DIR" "${SCRIPT_DIR}/rollcage"

echo "Started sandboxed claude in screen session '$SESSION_NAME'"
echo "Waiting ${TIMEOUT}s for TUI to render..."
sleep "$TIMEOUT"
