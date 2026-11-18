#!/usr/bin/env bash
#
# 一键编译并运行 p1bench。
#
#   ./run.sh                 # Release（默认）
#   ./run.sh debug           # Debug
#   ./run.sh release --seconds 5 --mem-mb 128
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: ./run.sh [release|debug] [program options...]

Modes:
  release   -O2 -g，默认
  debug     -O0 -g3

Program options (passed through to build/bin/bench):
  -t, --seconds <sec>   总测量时长，默认 20
      --cpu-pct <n>     libcpuwork 占比（0..100），默认 50
      --mem-mb <n>      libmemwork 堆工作集，默认 256
      --seed <n>        负载种子
  -h, --help            显示帮助

Examples:
  ./run.sh
  ./run.sh debug -t 5
  ./run.sh release --cpu-pct 80 --mem-mb 512
EOF
}

case "${1:-release}" in
    release|Release|RELEASE) MODE=Release ;;
    debug|Debug|DEBUG)       MODE=Debug ;;
    -h|--help)               usage; exit 0 ;;
    *)
        echo "error: unknown mode '$1' (expected release or debug)" >&2
        usage >&2
        exit 2
        ;;
esac
shift || true

BUILD_DIR="$ROOT/build/$MODE"
BIN="$BUILD_DIR/bin/bench"

if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake not found in PATH" >&2
    exit 1
fi

echo ">>> configure ($MODE)"
cmake -S "$ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$MODE" >/dev/null

echo ">>> build ($MODE, -j$(nproc))"
cmake --build "$BUILD_DIR" --parallel "$(nproc)"

echo ">>> run: $BIN $*"
exec "$BIN" "$@"
