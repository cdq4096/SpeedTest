# AGENTS.md — p1bench 项目上下文

> 本文件供 AI 编码助手 / 新维护者快速上手。Pi 会在本目录及子目录自动加载它。
> 完整的人类文档见 `README.md`，测量细节见 `perf_test/README.md`，网页见 `web/README.md`。

## 1. 项目是什么

一套三层结构的性能测试系统：

1. **被测程序**：`bench` + 两个 `.so`
   - `libcpuwork.so`：xorshift64 + 整数混合 + `sqrt`（CPU 密集）
   - `libmemwork.so`：256 MB 堆上随机读改写（内存密集，可注入泄漏）
2. **测量流水线**：`perf_test/run.sh` 跑两轮
   - `perf record -e cpu-clock:u -F 999` → 总时长、各 DSO 时间占比
   - `heaptrack` → 峰值内存、泄漏量、peak/leaked 火焰图
3. **结果查看器**：`web/serve.py` 读 `result.json`，浏览器展示卡片、饼图、交互火焰图

## 2. 文件地图

| 路径 | 作用 |
| --- | --- |
| `CMakeLists.txt` | 两个 SHARED 库 + `bench`，`RPATH=$ORIGIN/../lib` |
| `run.sh` | 编译 + 运行被测程序，`release`（默认）/ `debug` |
| `include/bench.h` | 两个库的 `extern "C"` 接口（新增接口先改这里） |
| `libcpuwork/cpu_work.cpp` | CPU 负载实现 |
| `libmemwork/mem_work.cpp` | 内存负载 + `mem_work_leak()` 注入泄漏 |
| `src/main.cpp` | 参数解析、自适应校准、计时、RSS 统计、CSV |
| `perf_test/run.sh` | 两轮测量主脚本（**不负责编译**） |
| `perf_test/report_json.py` | `summary.txt` → `result.json` |
| `perf_test/tools/flamegraph.pl` | 内置渲染器（CDDL，勿随意改动） |
| `perf_test/result1/` | 已跑的基线结果（含 `result.json`），勿覆盖 |
| `web/serve.py` | 标准库 HTTP 服务 + `/api/results` + SVG 白名单 |
| `web/static/app.js` | 前端：切换结果、卡片、饼图、放大弹窗 |
| `web/static/vendor/chart.umd.min.js` | Chart.js 4.4.1（MIT，已内置，勿换 CDN） |

## 3. 常用命令

```bash
# 编译 + 跑被测程序
./run.sh release                 # ~20s
./run.sh debug
./run.sh release -t 3            # 快速验证用

# 完整测量（约 45s，需先编译）
./perf_test/run.sh               # → perf_test/result1
./perf_test/run.sh --out perf_test/result2 -t 20

# 网页
./web/start.sh                   # http://127.0.0.1:8000/
./web/start.sh --port 9000

# 手动补 result.json（旧结果）
python3 perf_test/report_json.py perf_test/result1
```

快速验证（不要动 result1）：

```bash
./perf_test/run.sh -t 3 --out perf_test/result_tmp
# 验证后删除
rm -rf perf_test/result_tmp
```

## 4. 必须遵守的契约

### 4.1 脚本行为

- `run.sh` 负责编译；`perf_test/run.sh` **只测量**，找不到
  `build/Release/bin/bench` 会提示先跑 `./run.sh release`。
- 结果目录新增迭代必须用 `--out perf_test/resultN`，不要覆盖 `result1`。
- `perf_test/run.sh` 会清理结果目录中自己生成的文件（含 `result.json`），重跑安全。
- 泄漏注入默认只在 heaptrack 轮发生（`--leak-mb 4`），perf 轮无泄漏。

### 4.2 summary.txt ↔ report_json.py

`report_json.py` 依赖 `summary.txt` 的段落标记和行格式：

```
---------------- [1] RUN TIME -----------------
---------------- [2] PERF: TIME SHARE BY DSO -----------------
---------------- [3] MEMORY -----------------
---------------- [4] OUTPUT FILES -----------------
```

- 阶段行：`cpuwork|memwork  units  seconds  rate_mops  rss  peak`
- `perf_dso_share.txt`：`  50.71%  10018  10028028018  libcpuwork.so`
  （百分比 / 样本数 / period / DSO）

改这些格式时必须同步更新 `perf_test/report_json.py`。

### 4.3 result.json ↔ 前端

`web/static/app.js` 读取的键：`name, generated, bench_args, perf_event,
runtime{perf_span_s, perf_wall_s, bench_self_s, heaptrack_s},
phases[], share[], memory.program_perf/program_heaptrack/heaptrack,
files.peak_svg/leaked_svg`。

服务端在 `/api/results` 中会把 `files.*_svg` 替换成 `/files/<name>/...` URL。
改 schema 时同步改 `report_json.py`、`app.js`、两份 README。

### 4.4 C++ 侧

- 接口是 `extern "C"`，声明在 `include/bench.h`；新增功能先改头文件再改实现。
- 校准假设单位耗时线性可扩展：`*_run(n)` 的成本必须与 `n` 成正比。
- 必须保留 checksum 返回值/打印，防止负载被优化掉。
- `mem_work_leak()` 故意不释放内存，属测试特性，勿“修复”。
- 保持 C++17、`-Wall -Wextra` 无警告；不引入第三方 C++ 依赖。

### 4.5 前端/资源

- 界面中文、浅色、原生 HTML/CSS/JS；Chart.js 使用本地 `vendor/` 文件，禁止 CDN。
- 火焰图用 `<object>` 保留交互；宽度 800px 是两列可读性的折中。
  需要重新渲染现有图时：
  ```bash
  cd perf_test/result1
  perl ../tools/flamegraph.pl --title "heaptrack: peak memory" \
      --colors mem --countname bytes --width 800 < peak.folded > peak.svg
  ```
- `web/serve.py` 只允许 `peak.svg` / `leaked.svg`，且只监听 `127.0.0.1`，不要放宽。

## 5. 本机环境要点

- WSL2（内核 `6.18.x-microsoft`），Ubuntu 22.04，Python 3.10，Node v26。
- `/usr/bin/perf` 是会报 “perf not found for kernel …” 的包装脚本；
  真正的二进制在 `/usr/lib/linux-tools/*/perf`。`perf_test/run.sh` 已自动检测。
- `perf_event_paranoid=2`：只能做用户态采样；脚本用软件事件 `cpu-clock:u`。
- heaptrack 1.3.0 未启用 zstd，输出为 `heaptrack.gz`；脚本用 `heaptrack.*` 匹配。
- 本机已安装：perf、heaptrack、perl、python3、Node；Windows Edge 可用于截图验证。
- 项目**不是 git 仓库**；如需版本管理，`git init` 后建议忽略
  `build/`、`perf_test/result*/perf.data*`、`__pycache__/`。

## 6. 改动后的验证清单

```bash
# 1. C++ 构建
./run.sh release -t 1

# 2. 测量链路（约 45s；也可用 -t 3 --out perf_test/result_tmp）
./perf_test/run.sh -t 3 --out perf_test/result_tmp
python3 -c "import json; json.load(open('perf_test/result_tmp/result.json'))"
rm -rf perf_test/result_tmp

# 3. Python / JS 语法
python3 -m py_compile web/serve.py perf_test/report_json.py
node --check web/static/app.js
bash -n run.sh perf_test/run.sh web/start.sh

# 4. HTTP 接口
./web/start.sh & sleep 1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/results
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/files/result1/peak.svg
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/files/result1/summary.txt  # 期望 404
kill %1
```

页面视觉验证（本机可用 Windows Edge 无头截图）：

```bash
"/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
  --headless=new --disable-gpu --no-first-run \
  --user-data-dir='C:\Users\Public\edge-p1bench' \
  --window-size=1600,1200 --virtual-time-budget=6000 \
  --screenshot='C:\Users\Public\p1bench.png' http://127.0.0.1:8000/
```

## 7. 已知坑

- `perf script -F dso` 在 perf 5.15 输出空行；不要用它算占比，
  用 `perf report --sort dso -n --show-total-period`（当前实现）。
- heaptrack 的 `M` 是 MiB；`total leaked` 可能比注入值大几 KB（libc 缓冲）。
- `perf sample span` 是采样时间戳跨度，不等于墙钟；summary 里并列了三个口径。
- 火焰图 folded 中 count=0 的条目要在渲染前过滤（已在脚本里做）。
- 前端没有构建步骤；改 `app.js` 后浏览器强刷即可，服务端设置 `no-cache`。
- 不要提交/删除 `perf_test/result1`，它是当前基线。

## 8. 当前状态（2026-11-18）

- 三部分均已完成并跑通：被测程序、perf/heaptrack 流水线、网页查看器。
- `perf_test/result1`（Release，20s）为基线：
  - 占比 `libcpuwork.so 50.71%` / `libmemwork.so 49.29%`
  - heaptrack 峰值堆 272.71 MiB、峰值 RSS 275.95 MiB、泄漏 4.20 MiB
  - 火焰图 `peak.svg` / `leaked.svg`（800px）已生成
- 未实现：跨 result 对比视图（明确不做）、自动递增 result 编号、CI。
- 变更历史：修复过 perf DSO 占比为空、泄漏火焰图为空、火焰图 1600px 过小、
  README 代码块缺 fence 等问题。
