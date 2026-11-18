#!/usr/bin/env bash
#
# 用 perf + heaptrack 测量 p1bench：
#   [1] perf record 一轮：总运行时间、各 DSO(lib) 时间占比
#   [2] heaptrack 一轮：峰值内存、泄漏内存，并生成 peak / leaked 火焰图
#
# 注意：本脚本不负责编译。请先在项目根目录手动执行：
#   ./run.sh release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BENCH="$PROJECT_ROOT/build/Release/bin/bench"
FLAMEGRAPH_PL="$SCRIPT_DIR/tools/flamegraph.pl"

RESULT_DIR="$SCRIPT_DIR/result1"
SECONDS_TARGET=20
MEM_MB=256
LEAK_MB=4                  # 仅 heaptrack 轮注入，用于生成非空的泄漏火焰图
PASS_ARGS=()

usage() {
    cat <<'EOF'
Usage: ./perf_test/run.sh [options] [extra bench options...]

Options:
  -t, --seconds <sec>   每轮运行时长，默认 20
      --mem-mb <n>      libmemwork 工作集，默认 256
      --leak-mb <n>     heaptrack 轮故意泄漏的 MB 数，默认 4（0 表示不泄漏）
      --out <dir>       结果目录，默认 perf_test/result1
  -h, --help            显示帮助

Extra options are passed to build/Release/bin/bench, e.g. --cpu-pct 70 --seed 0x1234.

Prerequisite:
  ./run.sh release              # 先编译出 build/Release/bin/bench
  sudo apt install -y linux-tools-common linux-tools-generic heaptrack perl

Outputs (in result dir):
  summary.txt              人读汇总（运行时间、各库占比、内存）
  result.json              网页查看器使用的机器可读结果
  perf.data                perf 采样数据
  perf_dso_report.txt      perf report 原始输出
  perf_dso_share.txt       按 DSO 聚合的采样占比
  heaptrack.gz / .zst      heaptrack 数据
  heaptrack_summary.txt    heaptrack_print 输出
  peak.folded / peak.svg   峰值内存火焰图
  leaked.folded / leaked.svg  泄漏内存火焰图
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--seconds) SECONDS_TARGET="${2:?--seconds needs a value}"; shift 2 ;;
        --mem-mb)     MEM_MB="${2:?--mem-mb needs a value}"; shift 2 ;;
        --leak-mb)    LEAK_MB="${2:?--leak-mb needs a value}"; shift 2 ;;
        --out)        RESULT_DIR="${2:?--out needs a value}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; PASS_ARGS+=("$@"); break ;;
        *)            PASS_ARGS+=("$1"); shift ;;
    esac
done

mkdir -p "$RESULT_DIR"
RESULT_DIR="$(cd "$RESULT_DIR" && pwd)"

# ---------------------------------------------------------------- 前置检查 --
if [[ ! -x "$BENCH" ]]; then
    echo "error: 找不到可执行文件 $BENCH" >&2
    echo "       请先在项目根目录执行: ./run.sh release" >&2
    exit 1
fi

MISSING=()
if ! command -v heaptrack >/dev/null 2>&1 || ! command -v heaptrack_print >/dev/null 2>&1; then
    MISSING+=("heaptrack")
fi
command -v perl            >/dev/null 2>&1 || MISSING+=("perl")
command -v python3         >/dev/null 2>&1 || MISSING+=("python3")
[[ -x "$FLAMEGRAPH_PL" ]] || MISSING+=("perf_test/tools/flamegraph.pl")

PERF=""
if command -v perf >/dev/null 2>&1 && perf --version >/dev/null 2>&1; then
    PERF="$(command -v perf)"
else
    # WSL 等环境下 /usr/bin/perf 包装脚本可能因内核版本不匹配而拒绝启动，
    # 直接找真正的 perf 二进制。
    for candidate in /usr/lib/linux-tools/*/perf; do
        if [[ -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
            PERF="$candidate"
            break
        fi
    done
fi
[[ -n "$PERF" ]] || MISSING+=("perf")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "error: 缺少依赖: ${MISSING[*]}" >&2
    echo "请执行:" >&2
    echo "  sudo apt update && sudo apt install -y linux-tools-common linux-tools-generic heaptrack perl python3" >&2
    exit 3
fi

# 清理上次结果中由本脚本生成的文件
for f in perf.data perf.data.old perf_record.log perf_times.txt \
         perf_time_values.txt perf_span_seconds.txt perf_wall_seconds.txt \
         perf_dso_report.txt perf_dso_samples.txt perf_dso_share.txt \
         bench_perf.log bench_heaptrack.log heaptrack_summary.txt \
         peak.folded peak.svg leaked.folded leaked.svg summary.txt \
         result.json; do
    rm -f "$RESULT_DIR/$f"
done
rm -f "$RESULT_DIR"/heaptrack.* 2>/dev/null || true

# ------------------------------------------------------------ perf 事件探测 --
EVENT=""
probe_event() {
    "$PERF" record -q -e "$1" -F 100 -o "$RESULT_DIR/.probe.data" -- \
        sleep 0.05 >/dev/null 2>&1
}
for ev in cpu-clock:u task-clock:u cpu-clock; do
    if probe_event "$ev"; then
        EVENT="$ev"
        break
    fi
done
rm -f "$RESULT_DIR/.probe.data"*

if [[ -z "$EVENT" ]]; then
    echo "warning: perf 无法建立采样（WSL/权限限制?），将跳过 perf 轮" >&2
fi

# ------------------------------------------------- [1/2] perf 轮：时间占比 --
PERF_OK=0
WALL_SECONDS=""

if [[ -n "$EVENT" ]]; then
    echo ">>> [1/2] perf record: ${SECONDS_TARGET}s, event=$EVENT"

    t0="$(date +%s.%N)"
    if "$PERF" record -q -e "$EVENT" -F 999 -o "$RESULT_DIR/perf.data" -- \
            "$BENCH" -t "$SECONDS_TARGET" --mem-mb "$MEM_MB" "${PASS_ARGS[@]}" \
            >"$RESULT_DIR/bench_perf.log" 2>"$RESULT_DIR/perf_record.log"; then
        PERF_OK=1
    else
        echo "warning: perf record 失败，详见 $RESULT_DIR/perf_record.log" >&2
    fi
    t1="$(date +%s.%N)"
    WALL_SECONDS="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
    echo "$WALL_SECONDS" > "$RESULT_DIR/perf_wall_seconds.txt"
fi

PERF_SPAN=""
if [[ "$PERF_OK" -eq 1 ]]; then
    # 注意：perf 5.15 的 `perf script -F dso` 会输出空行，因此改用 report 解析
    "$PERF" report --stdio --sort dso -n --show-total-period \
        --percent-limit 0 -i "$RESULT_DIR/perf.data" \
        > "$RESULT_DIR/perf_dso_report.txt" 2>/dev/null || true
    "$PERF" script -i "$RESULT_DIR/perf.data" -F time \
        > "$RESULT_DIR/perf_times.txt" 2>/dev/null || true

    # 采样时间戳 -> 采样跨度（近似等于总运行时间）
    sed -n 's/^[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        "$RESULT_DIR/perf_times.txt" > "$RESULT_DIR/perf_time_values.txt"
    PERF_SPAN="$(awk 'NR == 1 { first = $1 } { last = $1; n++ }
                      END { if (n > 0) printf "%.3f", last - first }' \
                      "$RESULT_DIR/perf_time_values.txt")"

    # 按 DSO 聚合：百分比、样本数、周期数(period)
    awk '
        /^[[:space:]]*[0-9]+(\.[0-9]+)?%/ {
            pct = $1; sub(/%$/, "", pct)
            dso = $4
            for (i = 5; i <= NF; ++i) dso = dso " " $i
            printf "%6.2f%% %8d %14s  %s\n", pct, $2, $3, dso
        }' "$RESULT_DIR/perf_dso_report.txt" \
        > "$RESULT_DIR/perf_dso_share.txt"
fi

# --------------------------------------- [2/2] heaptrack 轮：内存与火焰图 --
echo ">>> [2/2] heaptrack: ${SECONDS_TARGET}s, leak=${LEAK_MB}MB"

HT_BASE="$RESULT_DIR/heaptrack"
if ! heaptrack -o "$HT_BASE" -- \
        "$BENCH" -t "$SECONDS_TARGET" --mem-mb "$MEM_MB" --leak-mb "$LEAK_MB" \
        "${PASS_ARGS[@]}" \
        >"$RESULT_DIR/bench_heaptrack.log" 2>&1; then
    echo "warning: heaptrack 运行返回非 0，详见 bench_heaptrack.log" >&2
fi

HT_FILE="$(find "$RESULT_DIR" -maxdepth 1 -type f -name 'heaptrack.*' \
               -printf '%T@ %p\n' 2>/dev/null \
           | sort -nr | head -n 1 | cut -d' ' -f2-)"

HT_OK=0
if [[ -n "$HT_FILE" ]]; then
    if heaptrack_print "$HT_FILE" -l > "$RESULT_DIR/heaptrack_summary.txt" 2>&1; then
        HT_OK=1
    else
        echo "warning: heaptrack_print 分析失败" >&2
    fi

    if [[ "$HT_OK" -eq 1 ]]; then
        heaptrack_print "$HT_FILE" --flamegraph-cost-type=peak \
            -F "$RESULT_DIR/peak.folded" >/dev/null 2>&1 || true
        heaptrack_print "$HT_FILE" --flamegraph-cost-type=leaked \
            -F "$RESULT_DIR/leaked.folded" >/dev/null 2>&1 || true

        # 去掉“峰值时已释放/未泄漏”的 0 字节条目，避免火焰图里出现零宽帧
        for f in "$RESULT_DIR/peak.folded" "$RESULT_DIR/leaked.folded"; do
            if [[ -f "$f" ]]; then
                awk '$NF > 0' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
            fi
        done
    fi
else
    echo "warning: 未找到 heaptrack 输出文件" >&2
fi

render_flamegraph() {
    local folded="$1" svg="$2" title="$3"

    if [[ -s "$folded" ]] && awk 'NF { found = 1 } END { exit !found }' "$folded"; then
        perl "$FLAMEGRAPH_PL" --title "$title" --colors mem --countname bytes \
            --width 800 < "$folded" > "$svg"
        echo "    -> $(basename "$svg")"
    else
        cat > "$svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="900" height="120">
  <rect width="100%" height="100%" fill="#f7f7f7"/>
  <text x="24" y="64" font-family="monospace" font-size="16" fill="#555">
    no data: $(basename "$folded") is empty
  </text>
</svg>
EOF
        echo "    -> $(basename "$svg") (空数据占位)"
    fi
}

if [[ "$HT_OK" -eq 1 ]]; then
    echo ">>> 渲染火焰图"
    render_flamegraph "$RESULT_DIR/peak.folded" "$RESULT_DIR/peak.svg" \
        "heaptrack: peak memory"
    render_flamegraph "$RESULT_DIR/leaked.folded" "$RESULT_DIR/leaked.svg" \
        "heaptrack: leaked memory"
fi

# ---------------------------------------------------------------- 汇总 txt --
PROG_SECONDS=""
if [[ -f "$RESULT_DIR/bench_perf.log" ]]; then
    PROG_SECONDS="$(awk -F': *' '/total measured time/ { print $2 + 0; exit }' \
                       "$RESULT_DIR/bench_perf.log" 2>/dev/null || true)"
fi

HT_RUNTIME=""
if [[ -f "$RESULT_DIR/heaptrack_summary.txt" ]]; then
    HT_RUNTIME="$(awk -F': ' '/total runtime:/ { print $2; exit }' \
                     "$RESULT_DIR/heaptrack_summary.txt" 2>/dev/null || true)"
    HT_RUNTIME="${HT_RUNTIME%.}"
fi

SUMMARY="$RESULT_DIR/summary.txt"

{
    echo "=================================================================="
    echo " p1bench performance report (perf + heaptrack)"
    echo "=================================================================="
    echo "generated          : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "bench              : $BENCH"
    echo "bench args         : -t $SECONDS_TARGET --mem-mb $MEM_MB ${PASS_ARGS[*]:-}"
    echo "heaptrack args     : -t $SECONDS_TARGET --mem-mb $MEM_MB --leak-mb $LEAK_MB ${PASS_ARGS[*]:-}"
    echo "perf event         : ${EVENT:-<unavailable>}"
    echo
    echo "---------------- [1] RUN TIME -----------------"
    printf 'perf sample span   : %s s\n' "${PERF_SPAN:-n/a}"
    printf 'perf round wall    : %s s\n' "${WALL_SECONDS:-n/a}"
    printf 'bench self-timed   : %s s\n' "${PROG_SECONDS:-n/a}"
    printf 'heaptrack runtime  : %s\n' "${HT_RUNTIME:-n/a}"
    echo "program phases (perf round):"
    grep -E '^(cpuwork|memwork)[[:space:]]' \
        "$RESULT_DIR/bench_perf.log" 2>/dev/null | sed 's/^/  /' || true
    echo
    echo "---------------- [2] PERF: TIME SHARE BY DSO -----------------"
    if [[ -s "$RESULT_DIR/perf_dso_share.txt" ]]; then
        echo "  overhead   est.time  samples          period  dso"
        awk -v span="${PERF_SPAN:-0}" '{
            pct = $1; sub(/%$/, "", pct)
            printf "  %6.2f%%  %7.3f s  %8d  %14s  %s\n", \
                pct, pct * span / 100, $2, $3, $4
        }' "$RESULT_DIR/perf_dso_share.txt"
        awk '{ pct = $1; sub(/%$/, "", pct); total += pct }
             END { printf "  total: %.2f%%\n", total }' \
            "$RESULT_DIR/perf_dso_share.txt"
    else
        echo "  (no perf samples available)"
    fi
    echo
    echo "---------------- [3] MEMORY -----------------"
    echo "program (perf round, no injected leak):"
    grep -E 'rss after init|peak rss' \
        "$RESULT_DIR/bench_perf.log" 2>/dev/null | sed 's/^/  /' || true
    echo "program (heaptrack round, --leak-mb $LEAK_MB):"
    grep -E 'rss after init|peak rss|intentional leak' \
        "$RESULT_DIR/bench_heaptrack.log" 2>/dev/null | sed 's/^/  /' || true
    echo "heaptrack (单位 M = MiB):"
    grep -E 'total runtime:|calls to allocation functions:|temporary memory allocations:|peak heap memory consumption:|peak RSS|total memory leaked:' \
        "$RESULT_DIR/heaptrack_summary.txt" 2>/dev/null | sed 's/^/  /' || true
} > "$SUMMARY"

# 生成 web 使用的 result.json（summary 写完后解析）
if ! python3 "$SCRIPT_DIR/report_json.py" "$RESULT_DIR" >/dev/null 2>&1; then
    echo "warning: 生成 result.json 失败" >&2
fi

{
    echo
    echo "---------------- [4] OUTPUT FILES -----------------"
    ( cd "$RESULT_DIR" && ls -1 ) | sed 's/^/  /'
} >> "$SUMMARY"

echo
cat "$SUMMARY"

if [[ "$PERF_OK" -eq 0 || "$HT_OK" -eq 0 ]]; then
    echo
    echo "warning: 部分测量失败，请检查上面输出及 $RESULT_DIR 中的日志" >&2
    exit 1
fi

echo
echo "done: $SUMMARY"
