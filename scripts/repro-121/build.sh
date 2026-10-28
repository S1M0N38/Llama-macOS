#!/usr/bin/env bash
# Build the Debug app (the hover trace is DEBUG-only).
set -euo pipefail
cd "$(dirname "$0")/../.."
xcodebuild -project Llama.xcodeproj -scheme Llama -configuration Debug \
  -derivedDataPath build build
