#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

zig build test
python3 "$ROOT/scripts/coverage.py" --require-100
