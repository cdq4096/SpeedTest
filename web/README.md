# web —— p1bench 结果查看器

只读展示 `perf_test/result*/` 的测量结果，纯 Python 标准库 + 原生 JS，
Chart.js 已内置，无 CDN / 无构建步骤。

## 启动

```bash
./web/start.sh                 # http://127.0.0.1:8000/
./web/start.sh --port 9000     # 换端口
```

浏览器打开 <http://127.0.0.1:8000/>。

WSL2 一般在 Windows 浏览器里访问 `http://localhost:8000/` 即可；若不通，
改用 `hostname -I` 看到的 WSL IP（如 `http://172.27.82.113:8000/`）。

## 页面

- 左侧：`perf_test/result*` 迭代结果列表（按名字自然排序），右侧显示选中结果。
- 运行时间 / 内存占用：卡片式，只保留核心指标。
- 模块时间占比：Chart.js 饼图 + 明细表；没有 perf 采样时自动回退为
  程序两阶段（cpuwork / memwork）耗时占比。
- 火焰图：峰值内存、泄漏内存一行两个；图内保留 heaptrack 自带的
  hover / 点击缩放 / Ctrl-F 搜索，也可「放大」或「新标签页」查看。
- 深链接：`http://127.0.0.1:8000/?zoom=peak#result1` 可直接打开峰值火焰图大图
  （`zoom=leaked` 为泄漏图）。

## 数据来源

页面的唯一数据源是每个结果目录下的 `result.json`：

- `./perf_test/run.sh` 结束时会自动调用 `perf_test/report_json.py` 生成。
- 旧结果（只有 `summary.txt`）可手动补：

```bash
python3 perf_test/report_json.py perf_test/result2
```

- 新增迭代结果：`./perf_test/run.sh --out perf_test/result2`，
  然后在网页左侧点「刷新」。

## 实现说明

- `serve.py`：`ThreadingHTTPServer`，绑定 127.0.0.1；提供
  `/api/results`、`/files/<result>/{peak,leaked}.svg` 及静态文件。
  SVG 文件名白名单 + 路径校验，防止目录穿越。
- `static/app.js`：原生 JS，切换结果、画饼图、放大弹窗。
- `static/vendor/chart.umd.min.js`：Chart.js 4.4.1（MIT）。
