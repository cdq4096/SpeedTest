'use strict';

const PALETTE = [
  '#2563eb', '#0ea5e9', '#14b8a6', '#f59e0b', '#ef4444',
  '#8b5cf6', '#84cc16', '#f97316', '#06b6d4', '#ec4899',
];

const state = {
  results: [],
  current: null,
  chart: null,
};

let zoomOpened = false;

const $ = (id) => document.getElementById(id);

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[ch]));
}

function fmt(value, digits = 1) {
  if (value === null || value === undefined || value === '') {
    return '—';
  }
  const number = Number(value);
  return Number.isFinite(number) ? number.toFixed(digits) : '—';
}

/* ------------------------------------------------------------------ data */

async function fetchResults() {
  const response = await fetch('/api/results', { cache: 'no-store' });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  const payload = await response.json();
  state.results = Array.isArray(payload.results) ? payload.results : [];

  const names = state.results.map((item) => item.name);
  let target = state.current;
  if (!target || !names.includes(target)) {
    target = location.hash.slice(1) || names[0] || null;
  }

  if (target && names.includes(target)) {
    state.current = target;
    selectResult(target, false);
    openZoomFromQuery();
  } else {
    state.current = null;
    renderSidebar();
    showEmpty(
      '未发现结果目录',
      '先运行 ./perf_test/run.sh 生成 perf_test/result1，再点击左侧「刷新」。',
    );
  }

  $('scan-time').textContent = `更新于 ${new Date().toLocaleTimeString('zh-CN')}`;
}

/* --------------------------------------------------------------- sidebar */

function renderSidebar() {
  const nav = $('result-list');
  nav.innerHTML = '';

  if (!state.results.length) {
    nav.innerHTML = '<div class="side-empty">未发现 result* 目录</div>';
    return;
  }

  for (const result of state.results) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'result-item'
      + (result.name === state.current ? ' active' : '')
      + (result.error ? ' has-error' : '');
    button.innerHTML = `
      <span class="result-name">${esc(result.name)}</span>
      <span class="result-sub">${result.error ? '读取失败' : esc(result.generated || '')}</span>`;
    button.addEventListener('click', () => selectResult(result.name, true));
    nav.appendChild(button);
  }
}

function selectResult(name, updateHash) {
  state.current = name;
  if (updateHash) {
    history.replaceState(null, '', `#${name}`);
  }
  renderSidebar();

  const result = state.results.find((item) => item.name === name);
  if (!result) {
    showEmpty('结果不存在', `没有找到 ${name}`);
    return;
  }
  if (result.error) {
    showEmpty(`读取 ${name} 失败`, result.error);
    return;
  }
  renderDetail(result);
  document.title = `${name} - p1bench 结果`;
}

function openZoomFromQuery() {
  if (zoomOpened) return;
  const zoom = new URLSearchParams(location.search).get('zoom');
  if (!zoom) return;

  const result = state.results.find((item) => item.name === state.current);
  if (!result || !result.files) return;

  const key = zoom === 'leaked' ? 'leaked_svg' : 'peak_svg';
  if (!result.files[key]) return;

  zoomOpened = true;
  openModal(
    result.files[key],
    zoom === 'leaked' ? '泄漏内存火焰图' : '峰值内存火焰图',
  );
}

/* ------------------------------------------------------------ rendering */

function showEmpty(title, detail) {
  if (state.chart) {
    state.chart.destroy();
    state.chart = null;
  }
  $('detail').classList.add('hidden');
  const empty = $('empty');
  empty.classList.remove('hidden');
  empty.innerHTML = `<div class="big">${esc(title)}</div><div>${esc(detail)}</div>`;
}

function card(label, value, unit, sub) {
  const hasValue = value !== '—';
  return `<div class="card">
    <div class="card-label">${esc(label)}</div>
    <div class="card-value">${esc(value)}${hasValue && unit
      ? `<span class="unit">${esc(unit)}</span>` : ''}</div>
    <div class="card-sub">${esc(sub || '')}</div>
  </div>`;
}

function renderDetail(result) {
  $('empty').classList.add('hidden');
  $('detail').classList.remove('hidden');

  $('r-title').textContent = result.name;

  const meta = [];
  if (result.generated) meta.push(`生成时间 ${result.generated}`);
  if (result.perf_event) meta.push(`perf 事件 ${result.perf_event}`);
  if (result.bench_args) meta.push(`参数 ${result.bench_args}`);
  $('r-meta').innerHTML = meta.map(esc).join('<span class="dot">·</span>');

  const hasShare = Array.isArray(result.share) && result.share.length > 0;
  $('r-badge').textContent = hasShare ? 'perf 采样' : '程序阶段数据';

  renderTimeCards(result);
  renderMemoryCards(result);
  renderShare(result);
  renderFlames(result);
}

function renderTimeCards(result) {
  const runtime = result.runtime || {};
  const cards = [
    card('总运行时间', fmt(runtime.perf_span_s, 2), 's', 'perf 采样跨度'),
    card('墙钟时间', fmt(runtime.perf_wall_s, 2), 's', '含 perf 工具开销'),
    card('程序自计时', fmt(runtime.bench_self_s, 2), 's', '两个库阶段合计'),
    card('heaptrack 运行', fmt(runtime.heaptrack_s, 2), 's', '含 heaptrack 开销'),
  ];
  $('time-cards').innerHTML = cards.join('');
}

function renderMemoryCards(result) {
  const memory = result.memory || {};
  const perfRun = memory.program_perf || {};
  const heaptrackRun = memory.program_heaptrack || {};
  const program = heaptrackRun.peak_rss_mib != null ? heaptrackRun : perfRun;
  const heaptrack = memory.heaptrack || {};

  const programSub = heaptrackRun.intentional_leak_mib
    ? `含注入泄漏 ${fmt(heaptrackRun.intentional_leak_mib, 0)} MiB`
    : '程序 VmHWM';
  const leakSub = heaptrack.allocations != null
    ? `共 ${heaptrack.allocations} 次分配`
    : '结束时未释放';

  $('mem-cards').innerHTML = [
    card('程序峰值 RSS', fmt(program.peak_rss_mib, 1), 'MiB', programSub),
    card('heaptrack 峰值堆', fmt(heaptrack.peak_heap_mib, 1), 'MiB', '堆分配峰值'),
    card('heaptrack 峰值 RSS', fmt(heaptrack.peak_rss_mib, 1), 'MiB', '含工具开销'),
    card('泄漏内存', fmt(heaptrack.leaked_mib, 2), 'MiB', leakSub),
  ].join('');
}

function renderShare(result) {
  const runtime = result.runtime || {};
  let share = (result.share || []).filter((item) => Number(item.percent) > 0);
  let note = '';

  if (!share.length && Array.isArray(result.phases) && result.phases.length) {
    const total = result.phases.reduce(
      (sum, phase) => sum + (Number(phase.seconds) || 0), 0,
    );
    if (total > 0) {
      share = result.phases
        .map((phase) => ({
          dso: phase.name,
          percent: ((Number(phase.seconds) || 0) / total) * 100,
          samples: null,
          period: null,
          est_seconds: Number(phase.seconds),
        }))
        .filter((item) => item.percent > 0);
      note = '未采集到 perf DSO 采样，饼图按程序阶段耗时估算。';
    }
  }

  if (!share.length) {
    if (state.chart) {
      state.chart.destroy();
      state.chart = null;
    }
    $('share-table').innerHTML = '';
    $('share-note').textContent = '没有可用的占比数据。';
    return;
  }

  share.sort((a, b) => b.percent - a.percent);

  const span = Number(runtime.perf_span_s)
    || Number(runtime.bench_self_s)
    || 0;

  const rows = share.map((item, index) => {
    const est = item.est_seconds != null
      ? Number(item.est_seconds)
      : (span * Number(item.percent)) / 100;
    const color = PALETTE[index % PALETTE.length];
    return `<tr>
      <td><span class="swatch" style="background:${color}"></span>${esc(item.dso)}</td>
      <td class="num">${fmt(item.percent, 2)}%</td>
      <td class="num">${est > 0 ? `${fmt(est, 2)} s` : '—'}</td>
      <td class="num">${item.samples != null ? esc(item.samples) : '—'}</td>
    </tr>`;
  }).join('');

  $('share-table').innerHTML = `<thead><tr>
      <th>模块</th><th>占比</th><th>估算耗时</th><th>样本数</th>
    </tr></thead><tbody>${rows}</tbody>`;
  $('share-note').textContent = note;

  if (typeof Chart === 'undefined') {
    $('share-note').textContent = 'Chart.js 未加载，无法绘制饼图。';
    return;
  }

  if (state.chart) {
    state.chart.destroy();
  }

  state.chart = new Chart($('share-chart').getContext('2d'), {
    type: 'pie',
    data: {
      labels: share.map((item) => item.dso),
      datasets: [{
        data: share.map((item) => Number(item.percent)),
        backgroundColor: share.map((_, index) => PALETTE[index % PALETTE.length]),
        borderColor: '#ffffff',
        borderWidth: 2,
      }],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label: (context) => {
              const percent = Number(context.parsed);
              const est = span > 0
                ? `，约 ${((span * percent) / 100).toFixed(2)} s`
                : '';
              return ` ${context.label}: ${percent.toFixed(2)}%${est}`;
            },
          },
        },
      },
    },
  });
}

function renderFlames(result) {
  const grid = $('flame-grid');
  grid.innerHTML = '';

  const definitions = [
    { key: 'peak_svg', title: '峰值内存火焰图' },
    { key: 'leaked_svg', title: '泄漏内存火焰图' },
  ];

  for (const definition of definitions) {
    const url = result.files && result.files[definition.key];
    const figure = document.createElement('figure');
    figure.className = 'flame-card';

    if (!url) {
      figure.innerHTML = `<figcaption><span>${esc(definition.title)}</span></figcaption>
        <div class="flame-empty">未生成该火焰图</div>`;
    } else {
      figure.innerHTML = `<figcaption>
          <span>${esc(definition.title)}</span>
          <span class="flame-actions">
            <button type="button" class="zoom">放大</button>
            <a href="${esc(url)}" target="_blank" rel="noopener">新标签页</a>
          </span>
        </figcaption>
        <object class="flame" data="${esc(url)}" type="image/svg+xml"
                aria-label="${esc(definition.title)}"></object>`;
      figure.querySelector('.zoom').addEventListener('click', () => {
        openModal(url, definition.title);
      });
    }
    grid.appendChild(figure);
  }
}

/* ----------------------------------------------------------------- modal */

function openModal(url, title) {
  $('modal-title').textContent = title;
  $('modal-obj').data = url;
  $('modal-open').href = url;
  $('modal').classList.remove('hidden');
}

function closeModal() {
  $('modal').classList.add('hidden');
  $('modal-obj').data = 'about:blank';
}

/* ------------------------------------------------------------------- init */

function bindEvents() {
  $('refresh').addEventListener('click', () => {
    fetchResults().catch((error) => {
      showEmpty('加载失败', `${error.message}（检查 web 服务是否还在运行）`);
    });
  });

  $('modal-close').addEventListener('click', closeModal);
  $('modal').addEventListener('click', (event) => {
    if (event.target === $('modal')) {
      closeModal();
    }
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      closeModal();
    }
  });

  window.addEventListener('hashchange', () => {
    const name = location.hash.slice(1);
    if (name) {
      selectResult(name, false);
    }
  });
}

document.addEventListener('DOMContentLoaded', () => {
  bindEvents();
  fetchResults().catch((error) => {
    showEmpty(
      '加载失败',
      `${error.message}（请确认已运行 ./web/start.sh）`,
    );
  });
});
