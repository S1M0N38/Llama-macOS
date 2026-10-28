#!/usr/bin/env bash
# Attach LLDB to the running Debug app with hover breakpoints installed.
#
#   ./lldb.sh                 # interactive: stop on enter/exit/highlight changes
#   ./lldb.sh --auto-continue # print the row + highlight state and keep going
#
# The interesting expressions once stopped:
#   frame variable self
#   expr -l Swift -- self.traceLabel
#   expr -l Swift -- self.isHighlighted
#   expr -l Swift -- self.enclosingMenuItem?.menu?.highlightedItem as Any
#
# Drive a repro from another terminal while stopped/continued:
#   swift scripts/repro-121/repro.swift --runs 1
set -euo pipefail
cd "$(dirname "$0")/../.."

APP="build/Build/Products/Debug/Llama.app"
PID="$(pgrep -f "$APP/Contents/MacOS/Llama" | head -1 || true)"
if [[ -z "${PID:-}" ]]; then
  echo "Llama (Debug) is not running; start it with ./launch.sh" >&2
  exit 1
fi

AUTO=0
if [[ "${1:-}" == "--auto-continue" ]]; then AUTO=1; fi

ARGS=(
  -p "$PID"
  -o 'breakpoint set --name "-[Llama.ItemView mouseEnteredWithEvent:]"'
)

# Swift methods: match by regex so this survives symbol mangling changes.
ARGS+=(
  -o 'breakpoint set --func-regex "^Llama\.ItemView\.mouseExited"'
  -o 'breakpoint set --func-regex "^Llama\.ItemView\.mouseEntered"'
  -o 'breakpoint set --func-regex "^Llama\.ItemView\.setHighlight"'
  -o 'breakpoint list'
)

if [[ $AUTO == 1 ]]; then
  ARGS+=(
    -o 'breakpoint command add -s command -o "frame variable self" -o "expr -l Swift -- self.traceLabel" -o "continue" 1 2 3'
  )
fi

echo "attaching to pid $PID"
exec lldb "${ARGS[@]}"
