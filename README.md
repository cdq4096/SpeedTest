# p1bench —— 执行速度 / 内存占用一体化测试系统

一套用于练习和验证性能测量链路的完整小系统：

1. **被测程序**：C++ 程序 + 两个 `.so`（CPU 密集 / 内存密集），可自适应校准到指定运行时长；
2. **测量流水线**：`perf` 测总时长与各动态库时间占比，`heaptrack` 测峰值/泄漏内存并生成火焰图；
3. **结果查看器**：本地网页，左侧切换 `result1/result2/...`，右侧用卡片、饼图、交互火焰图展示结果。

> 给 AI 助手：根目录的 [`AGENTS.md`](AGENTS.md) 记录了文件地图、跨文件契约、
> 验证清单和已知坑，Pi 等工具在新会话中会自动加载。

```
p1bench
├── 被测程序 bench ──┬── libcpuwork.so   （整数混合 + sqrt）
│                    └── libmemwork.so   （256MB 堆上随机读改写）
│
├── perf_test/run.sh ──┬── perf record     → 总运行时间、各 DSO 占比
│                      └── heaptrack       → peak/leaked 火焰图、峰值内存
│
└── web/serve.py ────────── 读取 result.json → 浏览器展示
```

## 目录结构

```
.
├── CMakeLists.txt              # 两个 SHARED 库 + bench，RPATH=$ORIGIN/../lib
├── run.sh                      # 一键编译 + 运行被测程序（release/debug）
├── include/bench.h             # 两个 .so 的 extern "C" 接口
├── libcpuwork/cpu_work.cpp     # libcpuwork.so：CPU 密集负载
├── libmemwork/mem_work.cpp     # libmemwork.so：内存密集负载 + 可注入泄漏
├── src/main.cpp                # 调用两个库、自适应校准、计时、RSS 统计
│
├── perf_test/                  # 测量流水线（详见 perf_test/README.md）
│   ├── run.sh                  #   perf + heaptrack 两轮测量
│   ├── report_json.py          #   summary.txt → result.json
│   ├── tools/flamegraph.pl     #   内置火焰图渲染器（CDDL，保留版权头）
│   └── result1/                #   每次测量输出（result2… 手动指定）
│
└── web/                        # 结果查看器（详见 web/README.md）
    ├── start.sh                #   启动本地服务，默认 127.0.0.1:8000
    ├── serve.py                #   Python 标准库 HTTP 服务
    └── static/                 #   index.html / app.js / style.css / Chart.js
```

## 快速开始

```bash
# 1. 编译并跑一次被测程序（Release，约 20 秒）
./run.sh release

# 2. 跑测量流水线（perf 20s + heaptrack 20s，结果写入 perf_test/result1）
./perf_test/run.sh

# 3. 打开网页查看
./web/start.sh
# 浏览器访问 http://127.0.0.1:8000/
```

依赖安装（Ubuntu / WSL）：

```bash
sudo apt update
sudo apt install -y build-essential cmake \
    linux-tools-common linux-tools-generic heaptrack perl python3
```

网页查看只需要 `python3` 和已有的结果目录；`perf` / `heaptrack` 只在测量时需要。
Chart.js 与 `flamegraph.pl` 已内置，运行时不联网。

---

## 1. 被测程序

### 编译

```bash
./run.sh                 # Release（默认）
./run.sh debug           # Debug
./run.sh release -t 5    # 额外参数透传给 bench
```

| 模式 | 编译参数 |
| --- | --- |
| Release | `-O2 -g -DNDEBUG -fno-omit-frame-pointer` |
| Debug | `-O0 -g3 -fno-omit-frame-pointer` |

两种模式都保留 `-g` 和帧指针，便于 perf 符号化与 heaptrack 回溯。
产物：`build/<Release|Debug>/{bin/bench, lib/libcpuwork.so, lib/libmemwork.so}`。

### 负载设计

- `libcpuwork.so`：xorshift64 + 整数乘法混合 + `sqrt` 依赖链，单位工作量约几 ns；
- `libmemwork.so`：`posix_memalign` 申请 256 MB（可调）并逐页写满，
  在堆上做随机读-改-写，单位工作量约 100 ns；
- 两个库通过 `extern "C"` 导出，`main` 在编译期链接；
- **自适应校准**：先小样本探测两个库的单位耗时，再按 `--seconds` 和
  `--cpu-pct` 计算工作量，所以 Debug/Release 都能稳定跑到目标时长；
- **校验和**：每阶段返回 checksum 并打印，防止负载被编译器优化掉。

### 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-t, --seconds <s>` | 20 | 总测量时长（不含初始化与校准） |
| `--cpu-pct <n>` | 50 | libcpuwork 时间占比（0–100） |
| `--mem-mb <n>` | 256 | libmemwork 堆工作集大小（MiB） |
| `--leak-mb <n>` | 0 | 退出时故意泄漏 n MiB，供泄漏火焰图使用 |
| `--seed <n>` | 0x5EED2024 | 负载种子（十进制或 0x 前缀） |

### 输出

程序打印每个阶段的耗时、吞吐、当前 RSS、峰值 RSS（`VmRSS` / `VmHWM`），
末尾附两行 CSV。示例（Release，20 秒）：

```
workload    : 20.00 s (cpu 50% / mem 50%), working set 256 MB, seed 0x000000005EED2024
calibration : cpu 1.73 ns/unit, mem 9.55 ns/unit (probe 63 ms / 80 ms)

phase              work units   time [s]     rate [M/s]   RSS [MB]  peak [MB]
cpuwork            5734543858      9.964         575.55      259.1      259.1
memwork            1070703125      9.624         111.26      259.1      259.1

total measured time : 19.587 s
```

---

## 2. 测量流水线（perf_test/run.sh）

`perf_test/run.sh` **不负责编译**，运行前需先执行过 `./run.sh release`。

```bash
./perf_test/run.sh                                  # 两轮各 20s → result1
./perf_test/run.sh -t 5 --mem-mb 128                # 调整时长/工作集
./perf_test/run.sh --out perf_test/result2          # 新增一次迭代结果
./perf_test/run.sh --leak-mb 0                      # 关闭注入泄漏
```

### 两轮测量

**第 1 轮：perf**

```bash
perf record -e cpu-clock:u -F 999 -- ./bench -t 20
```

- WSL 没有硬件 PMU 时用软件事件 `cpu-clock:u`（脚本按
  `cpu-clock:u → task-clock:u → cpu-clock` 自动探测）；
- `perf report --sort dso -n --show-total-period` 得到各 DSO 的
  百分比 / 样本数 / period；
- 总运行时间给出三个口径：perf 采样时间跨度、shell 墙钟、程序自计时，
  可交叉验证。

**第 2 轮：heaptrack**

```bash
heaptrack -- ./bench -t 20 --leak-mb 4
```

- 自动注入 `--leak-mb 4`，保证泄漏火焰图非空；
- `heaptrack_print -l` 输出峰值内存、泄漏量、分配点；
- `--flamegraph-cost-type=peak|leaked -F` 生成折叠栈，
  再用内置 `flamegraph.pl` 渲染为 800px 宽的 SVG（两列并排时可读）。

### 产物（每个 result 目录）

| 文件 | 内容 |
| --- | --- |
| `summary.txt` | 人读汇总：时间、占比、内存、文件清单 |
| `result.json` | 网页查看器使用的机器可读结果（脚本结束时自动生成） |
| `perf.data` | perf 原始采样（可用 `perf report -i` 重分析） |
| `perf_dso_share.txt` | 各 DSO 的占比 / 样本数 / period |
| `perf_dso_report.txt` | `perf report` 原始输出 |
| `bench_perf.log` | perf 轮程序输出（阶段耗时、VmRSS/VmHWM） |
| `heaptrack.gz` / `.zst` | heaptrack 原始数据（GUI 可用 `heaptrack_gui`） |
| `heaptrack_summary.txt` | `heaptrack_print -l` 输出 |
| `peak.svg` / `leaked.svg` | 峰值 / 泄漏内存火焰图（含 `.folded` 中间文件） |

### 实测示例（result1，20 秒）

```
运行时间   perf 采样跨度 19.897 s · 墙钟 19.960 s · 程序自计时 19.587 s
占比       libcpuwork.so 50.71% (10.09 s) · libmemwork.so 49.29% (9.81 s)
内存       程序峰值 RSS 259.2 MiB（perf 轮）/ 264.0 MiB（heaptrack 轮，含泄漏）
           heaptrack 峰值堆 272.71 MiB · 峰值 RSS 275.95 MiB · 泄漏 4.20 MiB
```

---

## 3. 结果查看器（web）

```bash
./web/start.sh                 # http://127.0.0.1:8000/
./web/start.sh --port 9000     # 换端口
```

WSL2 下 Windows 浏览器直接访问 `http://localhost:8000/`；若不通，用
`hostname -I` 的 IP 访问。

### 页面

- **左侧栏**：`perf_test/result*` 按自然顺序排列（result1、result2、result10…），
  显示生成时间，读取失败的条目标红；
- **运行时间 / 内存卡片**：只保留核心指标；
- **模块时间占比**：Chart.js 饼图 + 明细表；没有 perf 采样时自动回退为
  `cpuwork` / `memwork` 两阶段耗时占比，并在图下注明；
- **火焰图**：峰值 / 泄漏一行两个，`<object>` 保留 hover、点击缩放、
  Ctrl-F 搜索；右上角可「放大」或「新标签页」打开；
- **深链接**：`?zoom=peak#result1`、`?zoom=leaked#result2` 直接打开大图。

### 数据契约

网页只读每个结果目录下的 `result.json`（由 `perf_test/report_json.py` 生成），
不再解析人类可读的 `summary.txt`。旧结果可手动补：

```bash
python3 perf_test/report_json.py perf_test/result1
```

### 服务实现

- `web/serve.py`：Python 标准库 `ThreadingHTTPServer`，绑定 `127.0.0.1`；
  `GET /api/results` 返回全部结果，`GET /files/<name>/{peak,leaked}.svg` 提供火焰图；
- SVG 文件名白名单 + 路径校验，防目录穿越；
- `web/static/`：原生 HTML/CSS/JS，Chart.js 4.4.1 已内置（MIT），无 CDN、无构建步骤。

---

## 4. 数据流

```
                ┌───────────────────────────────┐
                │  bench（main + 2 个 .so）      │
                └───────┬───────────────┬───────┘
        perf record     │               │  heaptrack
        (cpu-clock:u)   ▼               ▼
                  perf.data        heaptrack.gz
                        │               │
       perf report/script│              │ heaptrack_print
                        ▼               ▼
              perf_dso_share.txt   heaptrack_summary.txt + peak/leaked.folded
                        │               │
                        │        flamegraph.pl
                        │               ▼
                        │        peak.svg / leaked.svg
                        └───────┬───────┘
                                ▼
                     summary.txt + result.json
                                │
                     web/serve.py (HTTP)
                                ▼
                          浏览器页面
```

---

## 5. 迭代与对比

每次测量写入一个独立目录：

```bash
./perf_test/run.sh --out perf_test/result1   # 基线
./perf_test/run.sh --out perf_test/result2   # 修改后
```

刷新网页即可在左侧切换查看；两个目录互不覆盖。对比 Release / Debug 时，
保持 `--seconds`、`--mem-mb`、`--seed` 一致，程序会按实测速率自动缩放工作量。

---

## 6. 已知限制与注意事项

- **WSL 通常没有硬件 PMU**：脚本使用软件事件 `cpu-clock:u`，得到的是采样占比；
  在物理机上可改用 `cycles:u` 获得更精确的周期数据。
- **perf 总时间**：`perf sample span` 是采样时间戳跨度（≈ 运行时间），
  与 `perf round wall`、程序自计时并列展示，便于发现异常。
- **heaptrack 的单位 `M` 是 MiB**；`total memory leaked` 可能比 `--leak-mb`
  略大（含 printf 等 libc 未释放的几 KB 缓冲），属正常现象。
- **泄漏火焰图依赖注入泄漏**：默认在 heaptrack 轮注入 4 MiB；`--leak-mb 0`
  时泄漏图会是空数据。
- **火焰图宽度 800px**：为两列并排阅读做了取舍；单图细节可点「放大」或
  「新标签页」查看交互大图。
- **网页只监听本机**；结果目录必须包含 `result.json`，旧结果用
  `report_json.py` 补齐。

---

## 7. 常用命令速查

```bash
./run.sh                       # Release 编译 + 跑 20s
./run.sh debug                 # Debug 编译 + 跑
./perf_test/run.sh             # perf + heaptrack 两轮测量（需先编译）
./perf_test/run.sh --out perf_test/result2 -t 10
./web/start.sh                 # 结果网页
python3 perf_test/report_json.py perf_test/result2   # 手动补 result.json
```

更多细节：

- 测量流水线：[`perf_test/README.md`](perf_test/README.md)
- 网页查看器：[`web/README.md`](web/README.md)
