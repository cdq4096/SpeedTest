# perf_test —— perf + heaptrack 测量

在 `build/Release/bin/bench` 上跑两轮测量，结果统一写到 `perf_test/result1/`。

## 1. 安装工具（一次性，手动执行）

```bash
sudo apt update
sudo apt install -y linux-tools-common linux-tools-generic heaptrack perl
```

说明：

- WSL 的 `/usr/bin/perf` 是版本检查包装脚本，内核 `6.18.x-microsoft` 与 Jammy 的
  5.15 工具链不匹配时可能报 “perf not found for kernel ...”。`run.sh` 会自动
  改用 `/usr/lib/linux-tools/*/perf` 真正的二进制。
- WSL 通常没有硬件 PMU，脚本按 `cpu-clock:u` → `task-clock:u` → `cpu-clock`
  顺序探测可用的 perf 事件；都不可用时跳过 perf 轮并在结果中注明，heaptrack 照常执行。
- 火焰图渲染器 `tools/flamegraph.pl` 已内置（上游 CDDL 许可，保留原始版权头），
  不需要联网。

## 2. 使用

```bash
# 在项目根目录，先手动编译 Release（本脚本不负责编译）
./run.sh release

# 两轮各 20 秒：perf 一轮 + heaptrack 一轮
./perf_test/run.sh

# 自定义时长/工作集，额外参数会透传给 bench
./perf_test/run.sh -t 5 --mem-mb 128 --cpu-pct 70
```

`--leak-mb` 默认 4：只在 heaptrack 轮注入，故意泄漏 4 MB，保证泄漏火焰图非空；
设为 0 可关闭（此时 leaked 图会是空数据占位）。

## 3. 做了什么

| 轮次 | 命令（等价） | 得到 |
| --- | --- | --- |
| perf | `perf record -e cpu-clock:u -F 999 -- bench -t 20` | 总运行时间、各 DSO 采样占比 |
| heaptrack | `heaptrack -- bench -t 20 --leak-mb 4` | 峰值堆内存、峰值 RSS、泄漏量、火焰图 |

之后用 `heaptrack_print` 生成折叠栈（本机 heaptrack 未启用 zstd，数据文件实际为 `.gz`；
若支持 zstd 则为 `.zst`，下面用 `heaptrack.gz` 代指）：

```bash
heaptrack_print heaptrack.gz --flamegraph-cost-type=peak   -F peak.folded
heaptrack_print heaptrack.gz --flamegraph-cost-type=leaked -F leaked.folded
perl tools/flamegraph.pl --colors mem --countname bytes < peak.folded > peak.svg
```

`perf_dso_share.txt` 的列为：overhead 百分比、样本数、period（cpu-clock 事件
计数值，约等于 ns）、DSO 名；`summary.txt` 里会再换算成估算耗时。

## 4. 产物（perf_test/result1/）

| 文件 | 内容 |
| --- | --- |
| `summary.txt` | 汇总：运行时间、各 DSO 占比、程序与 heaptrack 的内存数据 |
| `result.json` | 给网页查看器使用的机器可读结果（由 `report_json.py` 生成） |
| `perf.data` | perf 采样数据（可用 `perf report -i` 重新分析） |
| `perf_dso_share.txt` | 各 DSO 采样占比（百分比/样本数/period，合计 100%） |
| `perf_dso_report.txt` | `perf report --sort dso` 原始输出 |
| `bench_perf.log` | perf 轮的程序输出（阶段耗时、VmRSS/VmHWM） |
| `heaptrack.gz` | heaptrack 原始数据（GUI: `heaptrack_gui`；支持 zstd 时为 `.zst`） |
| `heaptrack_summary.txt` | `heaptrack_print -l` 输出（峰值/泄漏/分配点） |
| `peak.folded` / `peak.svg` | 峰值内存火焰图 |
| `leaked.folded` / `leaked.svg` | 泄漏内存火焰图 |

`summary.txt` 中的 “perf sample span” 是采样时间戳跨度（≈ 总运行时间），
“perf round wall” 是 shell 侧墙钟（含 perf 自身开销），可与
“bench self-timed” 交叉验证。

注意：heaptrack 输出的 `M` 为 MiB；`total memory leaked` 可能比 `--leak-mb`
略大（包含 printf 等 libc 内部未释放的几 KB 缓冲），属于正常现象。

## 5. 网页查看

```bash
./web/start.sh          # http://127.0.0.1:8000/
```

左侧切换 result1 / result2…，右侧显示运行时间、内存卡片、模块占比饼图和
峰值/泄漏火焰图。新增迭代用 `--out perf_test/result2`，页面点「刷新」即可。
详见 [web/README.md](../web/README.md)。
