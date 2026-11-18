#!/usr/bin/env bash
# 启动 p1bench 结果查看器（默认 http://127.0.0.1:8000/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/serve.py" "$@"
