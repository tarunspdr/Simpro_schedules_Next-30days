#!/usr/bin/env bash
# Manual one-shot runner. Useful for testing on the server before enabling the timer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_DIR"
exec "$REPO_DIR/venv/bin/python" "$REPO_DIR/main.py"
