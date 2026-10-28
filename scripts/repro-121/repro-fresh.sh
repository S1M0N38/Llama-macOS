#!/usr/bin/env bash
# Reproduce #121 N times, restarting the app between attempts.
#
# Restarting matters: on this machine the bug is deterministic on the first
# hovered menu open of a process, while a second open in the same process often
# coalesces mouse moves and does not reproduce. Restarting makes the attempt
# repeatable instead of a coin flip.
#
#   ./repro-fresh.sh            # 3 attempts
#   ./repro-fresh.sh 5          # 5 attempts
#   ./repro-fresh.sh 3 --real-models   # use the real HF cache (needs weights)
set -euo pipefail
cd "$(dirname "$0")/../.."

RUNS=3
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then RUNS="$1"; shift; fi

PASS=0
for i in $(seq 1 "$RUNS"); do
  echo "=== attempt $i/$RUNS ==="
  ./scripts/repro-121/launch.sh "$@" > /dev/null
  sleep 2
  set +e
  OUT=$(swift scripts/repro-121/repro.swift --runs 1 2>&1)
  STATUS=$?
  set -e
  echo "$OUT" | grep -E '^run |REPRODUCED|menu frame' || true
  if echo "$OUT" | grep -q 'REPRODUCED 1/1'; then PASS=$((PASS + 1)); fi
  ./scripts/repro-121/stop.sh
done

echo ""
echo "REPRODUCED $PASS/$RUNS fresh-app attempts"
if [[ $PASS -gt 0 ]]; then exit 0; else exit 1; fi
