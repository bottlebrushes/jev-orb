#!/usr/bin/env bash
# Runner for Jev Vision Pipeline
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
exec uv run python loop.py "$@"
