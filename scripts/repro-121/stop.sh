#!/usr/bin/env bash
# Stop the Debug app this lab launches (not the /Applications copy).
set -uo pipefail
pkill -f "build/Build/Products/Debug/Llama.app/Contents/MacOS/Llama" 2>/dev/null || true
sleep 0.5
