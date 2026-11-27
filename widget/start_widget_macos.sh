#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/../sidecars/quota_floating/launch.mjs"

if command -v node >/dev/null 2>&1; then
  exec node "$LAUNCHER" --detached
fi

AGY_HELPER="/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper"
if [[ -x "$AGY_HELPER" ]]; then
  ELECTRON_RUN_AS_NODE=1 exec "$AGY_HELPER" "$LAUNCHER" --detached
fi

echo "Node.js not found in PATH and Antigravity Helper was not found at $AGY_HELPER" >&2
exit 1
