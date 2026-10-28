#!/usr/bin/env bash
# Launch the Debug app with hover tracing enabled.
#
#   ./launch.sh                 # deterministic fixture: 22 simulated models
#   ./launch.sh --real-models   # scan the real Hugging Face cache instead
#   ./launch.sh --verbose       # log every tracking-area / raw event (slow)
#
# Env knobs understood by the app:
#   LB_HOVER_TRACE=1            enable the trace (DEBUG builds only)
#   LB_HOVER_TRACE_LEAN=1       log highlight transitions + violations only
#   LB_HOVER_TRACE_VERBOSE=1    log every raw mouse event
#   LB_HOVER_SNAPSHOTS=1        write a PNG of the menu on a violation
set -euo pipefail
cd "$(dirname "$0")/../.."

APP="build/Build/Products/Debug/Llama.app"
LOG="${LB_HOVER_TRACE_PATH:-/tmp/llama-hover.log}"
LEAN=1
SIMULATE=1
for arg in "$@"; do
  case "$arg" in
    --real-models) SIMULATE=0 ;;
    --verbose) LEAN=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$APP/Contents/MacOS/Llama" ]]; then
  echo "app not built; run ./build.sh first" >&2
  exit 1
fi

./scripts/repro-121/stop.sh

# The Debug bundle id is app.llama.Llama.dev (see UserSettings.swift), so the
# simulateModels flag lives in that domain.
if [[ $SIMULATE == 1 ]]; then
  defaults write app.llama.Llama.dev simulateModels -bool YES
else
  defaults write app.llama.Llama.dev simulateModels -bool NO
fi

rm -f "$LOG"
rm -rf /tmp/llama-hover-snapshots
mkdir -p /tmp/llama-hover-snapshots

ENV=(LB_HOVER_TRACE=1 "LB_HOVER_TRACE_PATH=$LOG" LB_HOVER_SNAPSHOTS=1)
if [[ $LEAN == 1 ]]; then ENV+=(LB_HOVER_TRACE_LEAN=1); else ENV+=(LB_HOVER_TRACE_VERBOSE=1); fi

env "${ENV[@]}" nohup "$APP/Contents/MacOS/Llama" > /tmp/llama-stdout.log 2>&1 &
PID=$!

# Wait for the app's first trace line.
for _ in $(seq 1 100); do
  grep -q '"ev":"sessionStart"' "$LOG" 2>/dev/null && break
  sleep 0.1
done
if ! grep -q '"ev":"sessionStart"' "$LOG" 2>/dev/null; then
  echo "app did not start; see /tmp/llama-stdout.log" >&2
  exit 1
fi

echo "pid=$PID"
echo "trace=$LOG"
echo "simulateModels=$SIMULATE lean=$LEAN"
echo "snapshots=/tmp/llama-hover-snapshots"
