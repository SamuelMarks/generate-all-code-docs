#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"
zig fmt --check .
zig build
zig build test
python3 "$ROOT/scripts/coverage.py" --self-test
python3 "$ROOT/scripts/coverage.py" --require-100
