(function () {
  'use strict';

  /* ── Config ──────────────────────────────────────────────────────── */
  const HISTORY_SIZE = 40;
  const TABLE_UPDATE_INTERVAL = 10000;
  const DEFAULT_THRESHOLDS = { ram_pct: 85, cpu_pct: 90, commit_pct: 80, pages_sec: 1000, non_paged_mb: 1500, disk_pct: 90 };
  let refreshInterval = 1000;
  let pollTimer = null;
  let pollInFlight = false;
  let firstLoad = true;
  let lastTableUpdate = 0;
  let thresholds = { ...DEFAULT_THRESHOLDS };
  let csrfToken = '';
  let connectionMethod = 'unknown';
  let eventSource = null;
  let wsReconnectDelay = 1000;
  let wsMaxReconnectDelay = 10000;

  const history = { ram: [], cpu: [], disk: [], net: [], commit: [] };
  const prev = { ram: 0, cpu: 0, disk: 0, commit: 0 };
  let cachedData = null;

  /* ── Performance Monitoring ─────────────────────────────────────── */
  let perf = { fetchMs: 0, renderMs: 0, cycleMs: 0, fps: 0, fpsFrames: 0, fpsLast: 0 };
  let perfTimer = 0;
  function trackFPS(ts) {
    perf.fpsFrames++;
    if (ts - perf.fpsLast >= 1000) {
      perf.fps = perf.fpsFrames;
      perf.fpsFrames = 0;
      perf.fpsLast = ts;
    }
    requestAnimationFrame(trackFPS);
  }
  requestAnimationFrame(trackFPS);

  function updateDebugPanel(data) {
    const dbgFetch = EL('dbg-fetch');
    const dbgRender = EL('dbg-render');
    const dbgCycle = EL('dbg-cycle');
    const dbgFps = EL('dbg-fps');
    const dbgMem = EL('dbg-mem');
    const dbgTl = EL('dbg-timeline');
    const dbgSys = EL('dbg-sys-metrics');
    const dbgCache = EL('dbg-cache');
    const dbgErrCount = EL('js-err-count');
    const dbgErrList = EL('js-errors');
    const dbgPsErrs = EL('dbg-ps-errs');

    if (dbgFetch) {
      const fc = perf.fetchMs < 500 ? 'ok' : perf.fetchMs < 2000 ? 'warn' : 'bad';
      dbgFetch.textContent = data && data._loading ? 'waiting...' : perf.fetchMs.toFixed(1) + ' ms';
      dbgFetch.className = 'sval ' + (data && data._loading ? 'warn' : fc);
      COL(EL('dbg-sc-fetch'), data && data._loading ? 50 : perf.fetchMs > 2000 ? 90 : perf.fetchMs > 500 ? 50 : 10);
    }
    if (dbgRender) {
      const rc = perf.renderMs < 50 ? 'ok' : perf.renderMs < 200 ? 'warn' : 'bad';
      dbgRender.textContent = perf.renderMs.toFixed(1) + ' ms';
      dbgRender.className = 'sval ' + rc;
      COL(EL('dbg-sc-render'), perf.renderMs > 200 ? 90 : perf.renderMs > 50 ? 50 : 10);
    }
    if (dbgCycle) {
      const cc = perf.cycleMs < 2000 ? 'ok' : perf.cycleMs < 5000 ? 'warn' : 'bad';
      dbgCycle.textContent = perf.cycleMs.toFixed(1) + ' ms';
      dbgCycle.className = 'sval ' + cc;
      COL(EL('dbg-sc-cycle'), perf.cycleMs > 5000 ? 90 : perf.cycleMs > 2000 ? 50 : 10);
    }
    if (dbgFps) {
      const fps = perf.fps;
      const fc = fps >= 55 ? 'ok' : fps >= 30 ? 'warn' : 'bad';
      dbgFps.textContent = fps + ' fps';
      dbgFps.className = 'sval ' + fc;
      COL(EL('dbg-sc-fps'), fps < 30 ? 90 : fps < 55 ? 50 : 10);
    }

    if (dbgMem) {
      const mem = performance.memory ? {
        used: (performance.memory.usedJSHeapSize / 1048576).toFixed(0),
        total: (performance.memory.totalJSHeapSize / 1048576).toFixed(0),
        limit: (performance.memory.jsHeapSizeLimit / 1048576).toFixed(0)
      } : null;
      dbgMem.innerHTML = mem
        ? `<div class="sys-row"><span>JS Heap Used</span><span>${mem.used} MB</span></div><div class="sys-row"><span>JS Heap Total</span><span>${mem.total} MB</span></div><div class="sys-row"><span>JS Heap Limit</span><span>${mem.limit} MB</span></div><div class="sys-row"><span>Utilization</span><span>${Math.round(mem.used/mem.limit*100)}%</span></div>`
        : '<div class="note">Memory API not available (Chrome only)</div>';
      hideSkeleton('dbg-mem-sk', 'dbg-mem');
    }

    const isLoading = data && data._loading;
    if (dbgTl) {
      const connIcons = { websocket: '⚡', sse: '🔌', http: '🔄' };
      dbgTl.innerHTML = `<div class="sys-row"><span>Status</span><span style="color:${isLoading ? 'var(--warn)' : 'var(--ok)'}">${isLoading ? 'Collecting data...' : 'Live'}</span></div><div class="sys-row"><span>Connection</span><span>${connIcons[connectionMethod] || '?'} ${connectionMethod}</span></div><div class="sys-row"><span>Refresh</span><span>${refreshInterval}ms</span></div><div class="sys-row"><span>Table Update</span><span>${TABLE_UPDATE_INTERVAL}ms</span></div><div class="sys-row"><span>Data Age</span><span>${cachedData && !isLoading ? ((Date.now() - perfTimer) / 1000).toFixed(1) + 's ago' : '—'}</span></div><div class="sys-row"><span>Processes</span><span>${data ? data.total_procs : '—'}</span></div><div class="sys-row"><span>DOM Nodes</span><span>${document.querySelectorAll('*').length}</span></div>`;
      hideSkeleton('dbg-timeline-sk', 'dbg-timeline');
    }

    if (dbgSys && data) {
      dbgSys.innerHTML = isLoading
        ? '<div class="note">Waiting for data collection...</div>'
        : `<div class="sys-row"><span>RAM Usage</span><span>${data.ram_pct}% (${data.ram_used_gb} GB / ${data.ram_total_gb} GB)</span></div><div class="sys-row"><span>CPU</span><span>${data.cpu_pct}%</span></div><div class="sys-row"><span>Commit</span><span>${data.commit_pct}% (${data.commit_gb} GB)</span></div><div class="sys-row"><span>GPU 3D</span><span>${data.gpu && data.gpu.available ? data.gpu.eng_type_totals['3d'].toFixed(1) + '%' : 'N/A'}</span></div><div class="sys-row"><span>Pages/sec</span><span>${data.pages_sec}</span></div><div class="sys-row"><span>Non-Paged Pool</span><span>${data.non_paged_mb} MB</span></div><div class="sys-row"><span>Perf (BE)</span><span>${data._perf_ms ? data._perf_ms + ' ms' : '—'}</span></div>`;
      hideSkeleton('dbg-sys-metrics-sk', 'dbg-sys-metrics');
    }

    if (dbgCache) {
      const connIcons = { websocket: '⚡', sse: '🔌', http: '🔄' };
      const connLabels = { websocket: 'WS Connected', sse: 'SSE Connected', http: 'HTTP Polling' };
      const connColor = connectionMethod === 'websocket' || connectionMethod === 'sse' ? 'var(--ok)' : 'var(--warn)';
      dbgCache.innerHTML = `<div class="sys-row"><span>Status</span><span style="color:${isLoading || pollInFlight ? 'var(--warn)' : 'var(--ok)'}">${isLoading || pollInFlight ? 'Collecting...' : 'Ready'}</span></div><div class="sys-row"><span>Connection</span><span style="color:${connColor}">${connIcons[connectionMethod] || '?'} ${connLabels[connectionMethod] || connectionMethod}</span></div><div class="sys-row"><span>Refresh</span><span>${refreshInterval}ms</span></div>`;
      hideSkeleton('dbg-cache-sk', 'dbg-cache');
    }

    if (dbgErrCount) dbgErrCount.textContent = ERRORS.length;
    if (dbgErrList) {
      if (ERRORS.length === 0) {
        dbgErrList.innerHTML = '<div class="note">No errors detected</div>';
      } else {
        dbgErrList.innerHTML = ERRORS.slice(-20).reverse().map(e => {
          const d = new Date(e.ts);
          const time = d.toLocaleTimeString();
          const info = e.line ? ` at ${e.src}:${e.line}` : '';
          return `<div class="err-entry ${e.type}"><span class="err-time">${time}</span><span class="err-type">${e.type.toUpperCase()}</span><span class="err-msg">${esc(e.msg)}${info}</span></div>`;
        }).join('');
      }
    }

    if (dbgPsErrs) {
      const psErrBanner = EL('ps-errors');
      if (psErrBanner && psErrBanner.textContent) {
        dbgPsErrs.innerHTML = psErrBanner.textContent;
      }
    }
  }

  /* ── Helpers ─────────────────────────────────────────────────────── */
  function getTrend(current, previous) {
    if (current == null || previous == null) return '';
    const diff = current - previous;
    if (diff > 0) return '↑' + diff.toFixed(1);
    if (diff < 0) return '↓' + Math.abs(diff).toFixed(1);
    return '→';
  }
  const EL  = id => document.getElementById(id);
  const TXT = (el, v) => { if (el) el.textContent = v; };
  const PCT = (el, v) => { if (el) el.style.width = Math.min(100, Math.max(0, v)) + '%'; };

  function esc(str) {
    if (str == null) return '';
    return String(str)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;')
      .replace(/>/g,'&gt;').replace(/"/g,'&quot;')
      .replace(/'/g,'&#039;');
  }

  function statusClass(v) {
    if (v < 50) return 'ok';
    if (v < 80) return 'warn';
    return 'bad';
  }

  function COL(el, val) {
    if (!el) return;
    el.classList.remove('ok','warn','bad');
    el.classList.add(statusClass(val));
  }

  function SBADGE(el, val) {
    if (!el) return;
    const cls = statusClass(val);
    el.textContent = val < 50 ? 'OK' : val < 80 ? 'WARN' : 'HIGH';
    el.className = 'sbadge show ' + cls;
  }

  function SCARD(el, val) {
    if (!el) return;
    el.classList.remove('ok','warn','bad');
    el.classList.add(statusClass(val));
  }

  function FILL(el, val) {
    if (!el) return;
    PCT(el, val);
    el.classList.remove('ok','warn','bad');
    el.classList.add(statusClass(val));
  }

  function fmtNum(n, dec = 2) { if (n === null || n === undefined || isNaN(n) || !isFinite(n)) return '—'; return n.toFixed(dec); }

  function fmtMem(mb) {
    if (mb === null || mb === undefined || isNaN(mb) || !isFinite(mb)) return '—';
    if (mb >= 1024) return (mb / 1024).toFixed(1) + ' GB';
    return mb.toFixed(0) + ' MB';
  }

  /* ── Skeleton teardown ───────────────────────────────────────────── */
  function showSkeleton(skId, tableId) {
    const sk = EL(skId);
    const tbl = EL(tableId);
    if (sk)  sk.style.display = '';
    if (tbl) tbl.style.display = 'none';
  }

  function hideSkeleton(skId, tableId) {
    const sk = EL(skId);
    const tbl = EL(tableId);
    if (sk)  sk.style.display = 'none';
    if (tbl) tbl.style.display = '';
  }

  function unloadCard(cardEl) {
    if (cardEl) cardEl.classList.remove('loading');
  }

  function showCardLoading(cardEl) {
    if (cardEl && !cardEl.classList.contains('loading')) cardEl.classList.add('loading');
  }

  /* Show all data-section skeletons (called at fetch start) */
  function showAllSkeletons() {
    const cardIds = ['sc-ram','sc-cpu','sc-disk','sc-cm','r-sc-ram','r-sc-cm','r-sc-pg','c-sc-cpu','c-sc-pg'];
    cardIds.forEach(id => { const el = EL(id); if (el) el.classList.add('loading'); });
    showSkeleton('ov-tbl-sk',       'ov-tbl');
    showSkeleton('r-tbl-sk',        'r-tbl');
    showSkeleton('c-tbl-sk',        'c-tbl');
    showSkeleton('sus-tbl-sk',      'sus-tbl');
    showSkeleton('svc-tbl-sk',      'svc-tbl');
    showSkeleton('startup-tbl-sk',  'startup-tbl');
    showSkeleton('pagefile-tbl-sk', 'pagefile-tbl');
    showSkeleton('profiles-tbl-sk', 'profiles-tbl');
    showSkeleton('all-tbl-sk',      'all-tbl');
    showSkeleton('ov-disks-sk',     'ov-disks');
    showSkeleton('disk-drives-sk',  'disk-drives');
    showSkeleton('disk-io-sk',      'disk-io-strip');
    showSkeleton('ov-io-sk',        'ov-io');
    showSkeleton('gpu-adapters-sk', 'gpu-adapters');
    showSkeleton('group-insights-sk','group-insights');
    showSkeleton('sys-summary-sk',  'sys-summary');
    showSkeleton('dbg-mem-sk',      'dbg-mem');
    showSkeleton('dbg-timeline-sk', 'dbg-timeline');
    showSkeleton('dbg-sys-metrics-sk','dbg-sys-metrics');
    showSkeleton('dbg-cache-sk',   'dbg-cache');
  }

  /* Hide all data-section skeletons (called on first data arrival) */
  function hideAllSkeletons() {
    const cardIds = ['sc-ram','sc-cpu','sc-disk','sc-cm','r-sc-ram','r-sc-cm','r-sc-pg','c-sc-cpu','c-sc-pg'];
    cardIds.forEach(id => { const el = EL(id); if (el) el.classList.remove('loading'); });
  }

  /* ── Canvas Sparklines ───────────────────────────────────────────── */
  function drawSparkline(canvasId, values, colorVar) {
    const canvas = EL(canvasId);
    if (!canvas || !Array.isArray(values)) return;

    const validValues = values.filter(v => typeof v === 'number' && Number.isFinite(v));
    if (validValues.length < 2) return;

    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.parentElement ? canvas.parentElement.getBoundingClientRect() : { width: 200, height: 32 };
    const W = Math.max(Math.round(rect.width || 200), 100);
    const H = parseInt(canvas.style.height, 10) || canvas.clientHeight || 32;

    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);

    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);

    const max = Math.max(...validValues, 1);
    const step = validValues.length > 1 ? W / (validValues.length - 1) : W;

    const style = getComputedStyle(document.documentElement);
    const color = style.getPropertyValue(colorVar).trim() || '#00f5b0';

    ctx.beginPath();
    validValues.forEach((v, i) => {
      const x = i * step;
      const y = H - (v / max) * (H - 4) - 2;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });

    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.shadowColor = color;
    ctx.shadowBlur = 6;
    ctx.stroke();
    ctx.shadowBlur = 0;

    const lastX = (validValues.length - 1) * step;
    ctx.lineTo(lastX, H);
    ctx.lineTo(0, H);
    ctx.closePath();
    ctx.fillStyle = hexOrVarToAlpha(color, 0.12);
    ctx.fill();
  }

  function hexOrVarToAlpha(color, alpha) {
    if (color.startsWith('#')) {
      let hex = color.slice(1);
      if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
      const r = parseInt(hex.slice(0,2),16);
      const g = parseInt(hex.slice(2,4),16);
      const b = parseInt(hex.slice(4,6),16);
      return `rgba(${r},${g},${b},${alpha})`;
    }
    if (color.startsWith('rgb(')) {
      return color.replace(/\)$/,`,${alpha})`).replace('rgb(','rgba(');
    }
    return `rgba(0,245,176,${alpha})`;
  }

  function sparkColorVar(cls) {
    if (cls === 'ok')   return '--ok';
    if (cls === 'warn') return '--warn';
    if (cls === 'bad')  return '--bad';
    return '--info';
  }

  function updateHistory(type, value) {
    // Skip invalid values
    if (typeof value !== 'number' || isNaN(value) || !isFinite(value)) return;
    history[type].push(value);
    if (history[type].length > HISTORY_SIZE) history[type].shift();
  }

  function refreshSparklines(cpuPct, ramPct, diskPct) {
    drawSparkline('spk-ram',  history.ram,  sparkColorVar(statusClass(ramPct)));
    drawSparkline('spk-cpu',  history.cpu,  sparkColorVar(statusClass(cpuPct)));
    drawSparkline('spk-cpu2', history.cpu,  sparkColorVar(statusClass(cpuPct)));
    drawSparkline('spk-disk', history.disk, sparkColorVar(statusClass(diskPct)));
    drawSparkline('disk-spk', history.disk, '--info');
    drawSparkline('net-spk',  history.net,  '--ok');
    drawSparkline('spk-cm', history.commit, sparkColorVar(statusClass(history.commit.slice(-1)[0] || 0)));
  }

  function authHeaders(extra = {}) {
    return csrfToken ? { ...extra, 'X-PCMON-CSRF': csrfToken } : { ...extra };
  }

  function scheduleNextFetch(delay = refreshInterval) {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(fetchData, Math.max(250, delay));
  }

  async function loadBootstrap() {
    try {
      const res = await fetch('/api/bootstrap', { cache: 'no-store' });
      if (!res.ok) return;
      const data = await res.json();
      csrfToken = data.csrf_token || '';
      thresholds = { ...DEFAULT_THRESHOLDS, ...(data.thresholds || {}) };
    } catch {}
  }

  let wsSocket = null;

  function tryWebSocket() {
    if (wsSocket) {
      wsSocket.close();
      wsSocket = null;
    }
    try {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      wsSocket = new WebSocket(protocol + '//' + window.location.host + '/stream');
      wsSocket.onopen = () => {
        connectionMethod = 'websocket';
        wsReconnectDelay = 1000;
        if (eventSource) { eventSource.close(); eventSource = null; }
        if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
        pollInFlight = false;
        updateSettingsConnInfo();
      };
      wsSocket.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          const renderStart = performance.now();
          renderAll(data);
          perf.renderMs = performance.now() - renderStart;
          perf.cycleMs = perf.renderMs;
          perfTimer = Date.now();
          pollInFlight = false;
          cachedData = data;
          updateDebugPanel(data);
          updateSettingsConnInfo();
        } catch (e) {}
      };
      wsSocket.onerror = () => {
        connectionMethod = 'sse';
        trySSE();
      };
      wsSocket.onclose = () => {
        if (connectionMethod === 'websocket') {
          connectionMethod = 'sse';
          trySSE();
        }
      };
    } catch (e) {
      connectionMethod = 'sse';
      trySSE();
    }
  }

  function trySSE() {
    if (eventSource) {
      eventSource.close();
      eventSource = null;
    }
    if (wsSocket) {
      wsSocket.close();
      wsSocket = null;
    }
    try {
      eventSource = new EventSource('/stream');
      eventSource.onopen = () => {
        connectionMethod = 'sse';
        wsReconnectDelay = 1000;
        if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
        pollInFlight = false;
        updateSettingsConnInfo();
      };
      eventSource.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          const renderStart = performance.now();
          renderAll(data);
          perf.renderMs = performance.now() - renderStart;
          perf.cycleMs = perf.renderMs;
          perfTimer = Date.now();
          pollInFlight = false;
          cachedData = data;
          updateDebugPanel(data);
          updateSettingsConnInfo();
        } catch (e) {}
      };
      eventSource.onerror = () => {
        connectionMethod = 'http';
        eventSource.close();
        eventSource = null;
        wsReconnectDelay = Math.min(wsReconnectDelay * 1.5, wsMaxReconnectDelay);
        startHTTPPolling();
      };
    } catch (e) {
      connectionMethod = 'http';
      startHTTPPolling();
    }
  }

  function initStream() {
    tryWebSocket();
  }

  function startHTTPPolling() {
    if (pollTimer) return;
    connectionMethod = 'http';
    fetchData();
  }

  /* ── Process actions ─────────────────────────────────────────────── */
  async function killProcess(pid, name) {
    if (!confirm(`Kill process "${name}" (PID: ${pid})?`)) return;
    try {
      const res = await fetch(`/api/process/${pid}/kill`, {
        method: 'POST',
        headers: authHeaders({ 'X-PCMON-Confirm': '1' })
      });
      const data = await res.json();
      if (data.success) {
        alert('Process terminated: ' + data.message);
        fetchData();
      } else {
        alert('Failed: ' + data.error);
      }
    } catch (e) {
      alert('Error: ' + e.message);
    }
  }

  async function suspendProcess(pid, name) {
    if (!confirm(`Suspend process "${name}" (PID: ${pid})?`)) return;
    try {
      const res = await fetch(`/api/process/${pid}/suspend`, {
        method: 'POST',
        headers: authHeaders({ 'X-PCMON-Confirm': '1' })
      });
      const data = await res.json();
      if (data.success) {
        alert('Process suspended: ' + data.message);
      } else {
        alert('Failed: ' + data.error);
      }
    } catch (e) {
      alert('Error: ' + e.message);
    }
  }

  async function resumeProcess(pid, name) {
    if (!confirm(`Resume process "${name}" (PID: ${pid})?`)) return;
    try {
      const res = await fetch(`/api/process/${pid}/resume`, {
        method: 'POST',
        headers: authHeaders({ 'X-PCMON-Confirm': '1' })
      });
      const data = await res.json();
      if (data.success) {
        alert('Process resumed: ' + data.message);
      } else {
        alert('Failed: ' + data.error);
      }
    } catch (e) {
      alert('Error: ' + e.message);
    }
  }

  /* ── Table rendering ─────────────────────────────────────────────── */
  function renderTable(tbl, rows, cols, opts = {}) {
    if (!tbl) return;
    tbl.innerHTML = '';
    const thead = tbl.createTHead();
    const hdr = thead.insertRow();
    cols.forEach(c => {
      const th = document.createElement('th');
      th.textContent = c;
      hdr.appendChild(th);
    });
    if (opts.actions) {
      const th = document.createElement('th');
      th.textContent = 'Actions';
      hdr.appendChild(th);
    }
    const tbody = tbl.createTBody();
    const maxRows = opts.maxRows || 30;
    rows.slice(0, maxRows).forEach((r, rowIdx) => {
      const tr = tbody.insertRow();
      cols.forEach((_, i) => {
        const td = tr.insertCell();
        td.textContent = r[i] !== undefined ? r[i] : '';
      });
      if (opts.actions && opts.processData && opts.processData[rowIdx]) {
        const p = opts.processData[rowIdx];
        if (p && p.pid) {
          const td = tr.insertCell();
          const actions = [
            { label: 'K', title: 'Kill process', fn: killProcess },
            { label: 'S', title: 'Suspend process', fn: suspendProcess },
            { label: 'R', title: 'Resume process', fn: resumeProcess }
          ];
          actions.forEach((action, idx) => {
            const btn = document.createElement('button');
            btn.className = 'btn-sm';
            btn.title = action.title;
            btn.textContent = action.label;
            btn.dataset.pid = p.pid;
            btn.dataset.name = p.name || '';
            btn.addEventListener('click', () => action.fn(p.pid, p.name || ''));
            if (idx > 0) btn.style.marginLeft = '4px';
            td.appendChild(btn);
          });
        }
      }
    });
  }

  /* ── Drive cards ─────────────────────────────────────────────────── */
  function renderDrives(container, disks) {
    if (!container) return;
    container.innerHTML = '';
    (disks || []).forEach(d => {
      const pct = typeof d.pct === 'number' ? d.pct : 0;
      const cls = pct < 70 ? 'ok' : pct < 85 ? 'warn' : 'bad';
      const div = document.createElement('div');
      div.className = 'drive-card';
      div.innerHTML = `
        <div class="drive-head">
          <span class="drive-letter">${esc(d.drive) || '?'}</span>
          <span class="drive-pct ${cls}">${fmtNum(pct)}%</span>
        </div>
        <div class="drive-label">${esc(d.label) || ''}</div>
        <div class="drive-bar"><div class="drive-fill ${cls}" style="width:${pct}%"></div></div>
        <div class="drive-meta">${fmtMem(d.free_gb * 1024)} free&nbsp;/&nbsp;${fmtMem(d.total_gb * 1024)} total</div>
      `;
      container.appendChild(div);
    });
  }

  /* ── GPU adapters ────────────────────────────────────────────────── */
  function renderGPUAdapters(container, gpu) {
    if (!container) return;
    container.innerHTML = '';
    if (!gpu || !gpu.available) {
      container.innerHTML = '<div class="note">No GPU data available</div>';
      return;
    }
    (gpu.adapters || []).forEach(a => {
      const pct = a.pct || 0;
      const div = document.createElement('div');
      div.className = 'gpu-card';
      div.innerHTML = `
        <div class="gpu-name">${esc(a.name) || 'Unknown'}</div>
        <div class="gpu-stat">Status: <span style="color:var(--ok)">${esc(a.status) || 'OK'}</span></div>
        <div class="gpu-stat">Dedicated: ${fmtMem((a.dedicated_gb || 0) * 1024)}</div>
        <div class="gpu-stat">Total: ${fmtMem((a.total_gb || 0) * 1024)}</div>
        <div class="gpu-bar"><div class="gpu-fill" style="width:${pct}%"></div></div>
      `;
      container.appendChild(div);
    });
  }

  /* ── Alerts ──────────────────────────────────────────────────────── */
  function setAlert(id, threshold, value, msgElId) {
    const el = EL(id);
    if (!el) return;
    if (typeof value === 'number' && value > threshold) {
      el.style.display = 'flex';
      TXT(EL(msgElId), value.toFixed(1));
    } else {
      el.style.display = 'none';
    }
  }

  function applyAlerts(d) {
    const liveThresholds = d && d.thresholds ? { ...thresholds, ...d.thresholds } : thresholds;
    setAlert('al-pg', liveThresholds.pages_sec, d.pages_sec, 'al-pg-t');
    setAlert('al-cm', liveThresholds.commit_pct, d.commit_pct, 'al-cm-t');
    setAlert('al-np', liveThresholds.non_paged_mb, d.non_paged_mb, 'al-np-t');
    setAlert('al-gpu', 90, d.gpu && d.gpu.eng_type_totals ? d.gpu.eng_type_totals['3d'] : 0, 'al-gpu-t');
  }

  /* ── Master render ───────────────────────────────────────────────── */
  function renderAll(d) {
    if (!d) return;
    
    if (history.ram.length > 30) history.ram = history.ram.slice(-30);
    if (history.cpu.length > 30) history.cpu = history.cpu.slice(-30);
    if (history.disk.length > 30) history.disk = history.disk.slice(-30);
    if (history.net.length > 30) history.net = history.net.slice(-30);
    
    cachedData = d;
    if (d.thresholds) thresholds = { ...thresholds, ...d.thresholds };

    TXT(EL('ts'),       d.ts);
    TXT(EL('hdr-host'), d.hostname || '—');

    /* ── RAM ── */
    const ramPct = d.ram_pct || 0;
    const ramCls = statusClass(ramPct);
    TXT(EL('sv-ram'), fmtNum(ramPct) + '%');
    TXT(EL('ss-ram'), fmtMem(d.ram_used_gb * 1024) + ' / ' + fmtMem(d.ram_total_gb * 1024));
    COL(EL('sv-ram'), ramPct); FILL(EL('sf-ram'), ramPct);
    SBADGE(EL('sb-ram'), ramPct); SCARD(EL('sc-ram'), ramPct);
    unloadCard(EL('sc-ram'));
    TXT(EL('sv-ram-trend'), getTrend(ramPct, prev.ram));
    prev.ram = ramPct;

    /* RAM page */
    TXT(EL('r-sv-ram'), fmtMem(d.ram_used_gb * 1024));
    TXT(EL('r-ss-ram'), fmtMem(d.ram_used_gb * 1024) + ' / ' + fmtMem(d.ram_total_gb * 1024));
    TXT(EL('r-avail'),  fmtMem(d.ram_avail_mb));
    COL(EL('r-sv-ram'), ramPct); FILL(EL('r-sf-ram'), ramPct);
    SBADGE(EL('r-sb-ram'), ramPct); SCARD(EL('r-sc-ram'), ramPct);
    unloadCard(EL('r-sc-ram'));

    /* ── CPU ── */
    const cpuPct = d.cpu_pct || 0;
    TXT(EL('sv-cpu'), fmtNum(cpuPct) + '%');
    COL(EL('sv-cpu'), cpuPct); FILL(EL('sf-cpu'), cpuPct);
    SBADGE(EL('sb-cpu'), cpuPct); SCARD(EL('sc-cpu'), cpuPct);
    unloadCard(EL('sc-cpu'));
    TXT(EL('sv-cpu-trend'), getTrend(cpuPct, prev.cpu));
    prev.cpu = cpuPct;

    TXT(EL('c-sv-cpu'), fmtNum(cpuPct) + '%');
    COL(EL('c-sv-cpu'), cpuPct); FILL(EL('c-sf-cpu'), cpuPct);
    SBADGE(EL('c-sb-cpu'), cpuPct); SCARD(EL('c-sc-cpu'), cpuPct);
    unloadCard(EL('c-sc-cpu'));
    TXT(EL('c-sv-pg'),  fmtNum(d.pages_sec));
    TXT(EL('c-queue'),  fmtNum(d.cpu_queue, 2));
    unloadCard(EL('c-sc-pg'));

    /* ── Disk ── */
    const diskPct = d.disk_pct || 0;
    TXT(EL('sv-disk'), fmtNum(diskPct) + '%');
    TXT(EL('ss-disk'), 'Queue: ' + fmtNum(d.disk_queue || 0, 2));
    COL(EL('sv-disk'), diskPct); FILL(EL('sf-disk'), diskPct);
    SBADGE(EL('sb-disk'), diskPct); SCARD(EL('sc-disk'), diskPct);
    unloadCard(EL('sc-disk'));
    TXT(EL('sv-disk-trend'), getTrend(diskPct, prev.disk));
    prev.disk = diskPct;

    /* ── Commit ── */
    const cmPct = d.commit_pct || 0;
    TXT(EL('sv-cm'), fmtNum(cmPct) + '%');
    TXT(EL('ss-cm'), fmtMem(d.commit_gb * 1024) + ' / ' + fmtMem(d.limit_gb * 1024));
    COL(EL('sv-cm'), cmPct); FILL(EL('sf-cm'), cmPct);
    SBADGE(EL('sb-cm'), cmPct); SCARD(EL('sc-cm'), cmPct);
    unloadCard(EL('sc-cm'));
    TXT(EL('sv-cm-trend'), getTrend(cmPct, prev.commit));
    prev.commit = cmPct;

    const cmPct2 = d.commit_pct || 0;
    TXT(EL('r-sv-cm'), fmtNum(cmPct2) + '%');
    TXT(EL('r-ss-cm'), fmtMem(d.commit_gb * 1024) + ' / ' + fmtMem(d.limit_gb * 1024));
    FILL(EL('r-sf-cm'), cmPct2);
    SBADGE(EL('r-sb-cm'), cmPct2); SCARD(EL('r-sc-cm'), cmPct2);
    unloadCard(EL('r-sc-cm'));

    /* RAM detail */
    TXT(EL('r-sv-pg'),   fmtNum(d.pages_sec));
    TXT(EL('r-ss-pg'),   'Page reads: ' + fmtNum(d.page_reads_sec) + '/s');
    TXT(EL('r-paged'),   fmtMem(d.paged_pool_mb));
    TXT(EL('r-nonpaged'),fmtMem(d.non_paged_mb));
    unloadCard(EL('r-sc-pg'));

    /* ── History ── */
    updateHistory('ram',  ramPct);
    updateHistory('cpu',  cpuPct);
    updateHistory('disk', diskPct);
    updateHistory('commit', d.commit_pct || 0);
    updateHistory('net',  (d.net_sent_kb || 0) + (d.net_recv_kb || 0));

    /* ── Sparklines ── */
    refreshSparklines(cpuPct, ramPct, diskPct);

    /* Tables (throttled every 10s for re-render, but always hide skeletons) */
    const now = Date.now();
    const doTables = firstLoad || (now - lastTableUpdate > TABLE_UPDATE_INTERVAL);
    if (doTables) lastTableUpdate = now;

    TXT(EL('ov-pc'), (d.total_procs || 0) + ' processes');

    hideSkeleton('ov-tbl-sk',       'ov-tbl');
    hideSkeleton('r-tbl-sk',        'r-tbl');
    hideSkeleton('c-tbl-sk',        'c-tbl');
    hideSkeleton('sus-tbl-sk',      'sus-tbl');
    hideSkeleton('svc-tbl-sk',      'svc-tbl');
    hideSkeleton('startup-tbl-sk',  'startup-tbl');
    hideSkeleton('pagefile-tbl-sk', 'pagefile-tbl');
    hideSkeleton('profiles-tbl-sk', 'profiles-tbl');
    hideSkeleton('all-tbl-sk',      'all-tbl');

    if (firstLoad) {
      hideAllSkeletons();
      firstLoad = false;
    }

    /* Always update dynamic content — hide skeletons on every refresh */
    const ioHtml = io => `
      <div class="io-card">
        <span class="io-lbl">${io.label}</span>
        <span class="io-val">${io.val}</span>
      </div>`;

    renderDrives(EL('disk-drives'), d.disks);
    renderDrives(EL('ov-disks'), d.disks);
    hideSkeleton('disk-drives-sk', 'disk-drives');
    hideSkeleton('ov-disks-sk', 'ov-disks');

    const diskIo = EL('disk-io-strip');
    if (diskIo) {
      diskIo.innerHTML = [
        { label: 'Disk Read',  val: fmtNum(d.disk_read_mb)  + ' MB/s' },
        { label: 'Disk Write', val: fmtNum(d.disk_write_mb) + ' MB/s' },
        { label: 'Net Sent',   val: fmtNum(d.net_sent_kb)   + ' KB/s' },
        { label: 'Net Recv',   val: fmtNum(d.net_recv_kb)   + ' KB/s' },
      ].map(ioHtml).join('');
      hideSkeleton('disk-io-sk', 'disk-io-strip');
    }

    const ovIo = EL('ov-io');
    if (ovIo) {
      ovIo.innerHTML = [
        { label: 'Disk R/W',      val: fmtNum(d.disk_read_mb) + ' / ' + fmtNum(d.disk_write_mb) + ' MB/s' },
        { label: 'Net Sent/Recv', val: fmtNum(d.net_sent_kb) + ' / ' + fmtNum(d.net_recv_kb) + ' KB/s'   },
      ].map(ioHtml).join('');
      hideSkeleton('ov-io-sk', 'ov-io');
    }

    /* GPU */
    const gpu = d.gpu || {};
    TXT(EL('g-avail'),  gpu.available ? 'Yes' : 'No');
    const gpuSection = EL('pg-gpu');
    if (gpuSection) {
      if (gpu && gpu.available) {
        gpuSection.classList.remove('gpu-unavailable');
      } else {
        gpuSection.classList.add('gpu-unavailable');
      }
    }
    TXT(EL('g-status'), gpu.available ? (gpu.adapters?.[0]?.status || 'Active') : 'N/A');
    const eng = gpu.eng_type_totals || {};
    TXT(EL('g-3d'),   (eng['3d']         !== undefined ? eng['3d'].toFixed(1)         + '%' : 'N/A'));
    TXT(EL('g-vdec'), eng['videodecode'] !== undefined ? eng['videodecode'].toFixed(1)  + '%' : 'N/A');
    TXT(EL('g-venc'), eng['videoencode'] !== undefined ? eng['videoencode'].toFixed(1)  + '%' : 'N/A');
    renderGPUAdapters(EL('gpu-adapters'), gpu);
    hideSkeleton('gpu-adapters-sk', 'gpu-adapters');
    setAlert('al-gpu', 90, eng['3d'], 'al-gpu-t');

    /* Groups */
    const grp = d.groups || {};
    if (grp.browser) {
      TXT(EL('grp-browser-val'),   fmtMem(grp.browser.ws_mb));
      TXT(EL('grp-browser-count'), (grp.browser.count || 0) + ' processes');
    }
    if (grp.dev_tools) {
      TXT(EL('grp-dev-val'),   fmtMem(grp.dev_tools.ws_mb));
      TXT(EL('grp-dev-count'), (grp.dev_tools.count || 0) + ' processes');
    }
    if (grp.security) {
      TXT(EL('grp-sec-val'),   fmtMem(grp.security.ws_mb));
      TXT(EL('grp-sec-count'), (grp.security.count || 0) + ' processes');
    }
    const gi = EL('group-insights');
    if (gi) {
      gi.innerHTML = (d.insights || []).map(t => `<div class="insight">${esc(t)}</div>`).join('');
      if (!d.insights || d.insights.length === 0) gi.innerHTML = '<div class="note" style="padding:6px 0">No insights yet.</div>';
      hideSkeleton('group-insights-sk', 'group-insights');
    }

    /* System */
    const sysSummary = EL('sys-summary');
    if (sysSummary) {
      sysSummary.innerHTML = [
        ['Hostname',        esc(d.hostname) || '—'],
        ['OS',              esc(d.os_caption) || '—'],
        ['Total Processes', d.total_procs || 0],
        ['RAM Total',       fmtMem(d.ram_total_gb * 1024)],
        ['Commit Limit',    fmtMem(d.limit_gb * 1024)],
      ].map(([k,v]) => `<div class="sys-row"><span>${k}</span><span>${v}</span></div>`).join('');
      hideSkeleton('sys-summary-sk', 'sys-summary');
    }

    /* Throttled tables — only re-render every TABLE_UPDATE_INTERVAL */
    if (doTables) {
    const topRamData = (d.top_ram || []).slice(0, 20);
    const topRamRows = topRamData.map(p => [
      p.name || '?', p.pid || 0, fmtMem(p.ws_mb), fmtNum(p.cpu_s, 1) + 's'
    ]);
    renderTable(EL('ov-tbl'), topRamRows, ['Name','PID','WS','CPU'], { actions: true, processData: topRamData });

    /* RAM table */
    const topPrivateData = (d.top_private || []).slice(0,30);
    const topPrivateRows = topPrivateData.map(p => [
      p.name||'?', p.pid||0, fmtMem(p.ws_mb), fmtMem(p.private_mb),
      fmtNum(p.cpu_s,1)+'s', p.threads||0, p.handles||0
    ]);
    renderTable(EL('r-tbl'), topPrivateRows, ['Name','PID','WS','Private','CPU','Threads','Handles'], { actions: true, processData: topPrivateData });

    /* CPU table */
    const topCpuData = (d.top_cpu || []).slice(0,20);
    const topCpuRows = topCpuData.map(p => [
      p.name||'?', p.pid||0, fmtNum(p.cpu_s,1)+'s', fmtMem(p.ws_mb), p.threads||0
    ]);
    renderTable(EL('c-tbl'), topCpuRows, ['Name','PID','CPU Time','WS','Threads'], { actions: true, processData: topCpuData });

    /* Suspicious */
    const susRows = (d.suspicious || []).map(p => [
      p.name||'?', p.pid||0, fmtMem(p.ws_mb), p.reason||''
    ]);
    renderTable(EL('sus-tbl'), susRows, ['Name','PID','WS','Reason']);
    TXT(EL('sus-count'), (d.suspicious || []).length);

    /* Services */
    const svcRows = (d.heavy_services || []).map(s => [
      s.Name||'?', s.DisplayName||'', s.State||'', s.StartMode||'', s.ProcessId||0
    ]);
    renderTable(EL('svc-tbl'), svcRows, ['Name','Display Name','State','Start Mode','PID']);

    const startupRows = (d.startup || []).map(s => [
      s.Name||'?', s.Command||'', s.Location||'', s.User||''
    ]);
    renderTable(EL('startup-tbl'), startupRows, ['Name','Command','Location','User']);

    const pfRows = (d.pagefile || []).map(p => [
      p.Name||'?',
      p.AllocatedBaseSize ? fmtMem(p.AllocatedBaseSize) : 'Auto',
      p.CurrentUsage ? fmtMem(p.CurrentUsage) : '0',
      p.PeakUsage    ? fmtMem(p.PeakUsage)    : '0'
    ]);
    renderTable(EL('pagefile-tbl'), pfRows, ['Name','Size','Initial','Maximum']);

    const profRows = (d.ps_profiles || []).map(p => [
      p.path||'?', p.exists ? 'Yes':'No', p.size_kb ? p.size_kb+' KB':'—'
    ]);
    renderTable(EL('profiles-tbl'), profRows, ['Path','Exists','Size']);

    /* All processes */
    const allProcessData = d.all_processes || d.top_ram || [];
    const allRows = allProcessData.map(p => [
      p.name||'?', p.pid||0, fmtMem(p.ws_mb), fmtMem(p.private_mb),
      fmtNum(p.cpu_s,1)+'s', p.threads||0, p.handles||0, p.path||''
    ]);
    renderTable(EL('all-tbl'), allRows, ['Name','PID','WS','Private','CPU','Threads','Handles','Path'], { actions: true, processData: allProcessData });
    TXT(EL('all-pc'), (d.total_procs || 0) + ' processes');
    }

    /* Alerts */
    applyAlerts(d);
  }

  /* ── Error tracking ─────────────────────────────────────────────── */
  const ERRORS = [];
  const MAX_ERRORS = 100;

  window.onerror = (msg, src, line, col, err) => {
    ERRORS.push({ ts: Date.now(), type: 'js', msg: String(msg), src, line, col });
    if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
    updateErrorDisplay();
    return true;
  };

  window.onunhandledrejection = (e) => {
    ERRORS.push({ ts: Date.now(), type: 'promise', msg: String(e.reason) });
    if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
    updateErrorDisplay();
  };

  function updateErrorDisplay() {
    if (cachedData) updateDebugPanel(cachedData);
  }

  async function fetchErrors() {
    try {
      const res = await fetch('/errors', { cache: 'no-store' });
      if (!res.ok) return;
      const data = await res.json();
      const psErrEl = EL('ps-errors');
      if (psErrEl) {
        if (data.error_count > 0) {
          psErrEl.innerHTML = `<div class="err-banner">PowerShell errors: ${data.error_count} | <a href="/logs" target="_blank" rel="noopener">View logs</a> | <a href="/debug" target="_blank" rel="noopener">Debug</a></div>`;
        } else {
          psErrEl.innerHTML = '';
        }
      }
      if (cachedData) {
        cachedData._psErrorCount = data.error_count || 0;
      }
      updateErrorDisplay();
    } catch {}
  }

  /* ── Fetch ───────────────────────────────────────────────────────── */
  async function fetchData() {
    if (pollInFlight) return;
    pollInFlight = true;
    const cycleStart = performance.now();
    let data = null;
    let fetchError = null;

    if (!cachedData) showAllSkeletons();

    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        const fetchStart = performance.now();
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), Math.max(5000, refreshInterval + 2000));
        const res = await fetch('/data', { cache: 'no-store', signal: controller.signal });
        clearTimeout(timeoutId);
        perf.fetchMs = performance.now() - fetchStart;
        if (!res.ok) throw new Error('HTTP ' + res.status);
        data = await res.json();
        break;
      } catch (e) {
        fetchError = e;
        if (attempt === 1) {
          const msg = e && e.name === 'AbortError' ? 'Timeout, retrying...' : 'Error: ' + (e.message || e);
          ERRORS.push({ ts: Date.now(), type: 'fetch', msg });
          if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
          await new Promise(r => setTimeout(r, 500));
        }
      }
    }

    try {
      if (data) {
        const renderStart = performance.now();
        renderAll(data);
        perf.renderMs = performance.now() - renderStart;
        perf.cycleMs = performance.now() - cycleStart;
        perfTimer = Date.now();
        updateDebugPanel(data);
        fetchErrors();
      } else {
        perf.cycleMs = performance.now() - cycleStart;
        if (fetchError && fetchError.name !== 'AbortError') {
          ERRORS.push({ ts: Date.now(), type: 'fetch', msg: fetchError.message || String(fetchError) });
          if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
        }
        if (cachedData) updateDebugPanel({ ...cachedData, _loading: true });
        updateErrorDisplay();
      }
    } finally {
      pollInFlight = false;
      scheduleNextFetch(refreshInterval);
    }
  }

  window.pcmonDebug = {
    errors: ERRORS,
    fetch: fetchData,
    fetchErrors,
    config: { refreshRate: refreshInterval, url: '', get thresholds() { return thresholds; } }
  };

  function copyTableToClipboard(tableId) {
    const tbl = document.getElementById(tableId);
    if (!tbl) return;
    let text = '';
    const headers = tbl.querySelectorAll('thead th');
    headers.forEach((th, i) => { text += th.textContent + (i < headers.length - 1 ? '\t' : ''); });
    text += '\n';
    const rows = tbl.querySelectorAll('tbody tr');
    rows.forEach(tr => {
      const cells = tr.querySelectorAll('td');
      cells.forEach((td, i) => { text += td.textContent + (i < cells.length - 1 ? '\t' : ''); });
      text += '\n';
    });
    navigator.clipboard.writeText(text).then(() => {
      alert('Copied to clipboard!');
    }).catch(() => {
      alert('Failed to copy');
    });
  }

  window.killProcess = killProcess;
  window.suspendProcess = suspendProcess;
  window.resumeProcess = resumeProcess;
  window.copyTableToClipboard = copyTableToClipboard;

  /* ── Tabs ────────────────────────────────────────────────────────── */
  function initTabs() {
    const tabs = document.querySelectorAll('.ntab');
    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('on'));
        tab.classList.add('on');
        document.querySelectorAll('.pg').forEach(p => p.classList.remove('on'));
        const target = document.getElementById('pg-' + tab.dataset.page);
        if (target) target.classList.add('on');
        if (tab.dataset.page === 'debug' && cachedData) updateDebugPanel(cachedData);
        setTimeout(() => {
          refreshSparklines(history.cpu.slice(-1)[0] || 0, history.ram.slice(-1)[0] || 0, history.disk.slice(-1)[0] || 0);
        }, 50);
      });
    });
  }

  /* ── Refresh selector ────────────────────────────────────────────── */
  function updateSettingsConnInfo() {
    const statusEl = EL('set-conn-status');
    const methodEl = EL('set-conn-method');
    const refreshEl = EL('set-refresh-val');
    const latencyEl = EL('set-latency');
    const settingsSel = EL('rf-sel-settings');
    const connLabels = { websocket: '⚡ WebSocket (Fastest)', sse: '🔌 SSE (Fast)', http: '🔄 HTTP Polling' };
    const isConnected = (eventSource && eventSource.readyState === EventSource.OPEN) || (wsSocket && wsSocket.readyState === WebSocket.OPEN);
    
    if (statusEl) statusEl.textContent = isConnected ? 'Connected' : 'Disconnected';
    if (methodEl) methodEl.textContent = connLabels[connectionMethod] || connectionMethod;
    if (refreshEl) refreshEl.textContent = refreshInterval + ' ms';
    if (latencyEl) latencyEl.textContent = perf.fetchMs > 0 ? perf.fetchMs.toFixed(1) + ' ms' : '~50 ms';
    if (settingsSel) settingsSel.value = refreshInterval;
  }

  function initRefreshSelector() {
    const sel = EL('rf-sel');
    const settingsSel = EL('rf-sel-settings');
    if (!sel) return;
    refreshInterval = parseInt(sel.value, 10) || 1000;
    
    const updateRefresh = (rate) => {
      refreshInterval = rate;
      if (sel) sel.value = rate;
      if (settingsSel) settingsSel.value = rate;
      fetch('/api/refresh-rate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders() },
        body: JSON.stringify({ rate })
      }).catch(() => {});
      if (connectionMethod === 'http') {
        scheduleNextFetch(0);
      }
      updateSettingsConnInfo();
    };

    sel.addEventListener('change', () => {
      const rate = Math.min(30000, Math.max(1, parseInt(sel.value, 10) || 1000));
      updateRefresh(rate);
    });

    if (settingsSel) {
      settingsSel.addEventListener('change', () => {
        if (sel) sel.value = settingsSel.value;
        const rate = Math.min(30000, Math.max(1, parseInt(settingsSel.value, 10) || 1000));
        updateRefresh(rate);
      });
    }
  }

  /* ── Search filters ──────────────────────────────────────────────── */
  function initSearchFilters() {
    function filterTable(inputId, tableId) {
      const input = EL(inputId);
      if (!input) return;
      input.addEventListener('input', () => {
        const term = input.value.toLowerCase();
        const tbl  = EL(tableId);
        if (!tbl) return;
        tbl.querySelectorAll('tbody tr').forEach(row => {
          row.style.display = row.textContent.toLowerCase().includes(term) ? '' : 'none';
        });
      });
    }
    filterTable('s-ram', 'r-tbl');
    filterTable('s-all', 'all-tbl');
  }

  /* ── Snapshots ───────────────────────────────────────────────────── */
  let selectedSnapshotId = null;

  async function loadSnapshots() {
    showSkeleton('snapshots-tbl-sk', 'snapshots-tbl');
    try {
      const res = await fetch('/api/snapshots');
      if (!res.ok) { hideSkeleton('snapshots-tbl-sk', 'snapshots-tbl'); return; }
      const list = await res.json();
      const tbl = EL('snapshots-tbl');
      if (!tbl) return;
      tbl.innerHTML = '';
      const thead = tbl.createTHead();
      const hdr = thead.insertRow();
      ['Time', 'Label', 'Actions'].forEach(c => {
        const th = document.createElement('th');
        th.textContent = c;
        hdr.appendChild(th);
      });
      const tbody = tbl.createTBody();
      (list || []).forEach(s => {
        const tr = tbody.insertRow();
        tr.innerHTML = `<td>${esc(s.ts)}</td><td>${esc(s.label || '—')}</td>`;
        const td = tr.insertCell();
        const btnCompare = document.createElement('button');
        btnCompare.className = 'btn btn-sm';
        btnCompare.textContent = 'Compare';
        btnCompare.onclick = () => compareSnapshot(s.id);
        td.appendChild(btnCompare);
        const btnJson = document.createElement('button');
        btnJson.className = 'btn btn-sm';
        btnJson.textContent = 'JSON';
        btnJson.onclick = () => exportSnapshot(s.id, s.label, 'json');
        btnJson.style.marginLeft = '4px';
        td.appendChild(btnJson);
        const btnCsv = document.createElement('button');
        btnCsv.className = 'btn btn-sm';
        btnCsv.textContent = 'CSV';
        btnCsv.onclick = () => exportSnapshot(s.id, s.label, 'csv');
        btnCsv.style.marginLeft = '4px';
        td.appendChild(btnCsv);
        if (s.id === selectedSnapshotId) tr.classList.add('selected');
      });
      hideSkeleton('snapshots-tbl-sk', 'snapshots-tbl');
    } catch {
      hideSkeleton('snapshots-tbl-sk', 'snapshots-tbl');
    }
  }

  async function saveSnapshot() {
    const labelInput = EL('snap-label');
    const msgEl = EL('snap-msg');
    const saveBtn = EL('btn-save-snap');
    const label = labelInput ? labelInput.value.trim() : '';
    if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Saving...'; }
    try {
      const res = await fetch('/api/snapshots', {
        method: 'POST',
        headers: authHeaders({ 'Content-Type': 'application/json' }),
        body: JSON.stringify({ label })
      });
      if (res.ok) {
        const result = await res.json();
        selectedSnapshotId = result.id;
        if (labelInput) labelInput.value = '';
        if (msgEl) { msgEl.textContent = 'Snapshot saved!'; setTimeout(() => { if (msgEl) msgEl.textContent = ''; }, 2000); }
        loadSnapshots();
      } else {
        if (msgEl) msgEl.textContent = 'Error: ' + res.status;
      }
    } catch (e) {
      if (msgEl) msgEl.textContent = 'Error saving snapshot';
    } finally {
      if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save Snapshot'; }
    }
  }

  async function compareSnapshot(id) {
    selectedSnapshotId = id;
    loadSnapshots();
    const resultEl = EL('compare-result');
    if (!resultEl) return;
    showSkeleton('compare-result-sk', 'compare-result');
    resultEl.innerHTML = '<div class="note">Comparing...</div>';
    try {
      const res = await fetch(`/api/snapshots/${id}/compare`, { method: 'POST', headers: authHeaders() });
      if (!res.ok) throw new Error('Failed');
      const data = await res.json();
      if (data.error) {
        resultEl.innerHTML = `<div class="note" style="color:var(--bad)">${esc(data.error)}</div>`;
        hideSkeleton('compare-result-sk', 'compare-result');
        return;
      }
      const changes = data.changes || [];
      if (changes.length === 0) {
        resultEl.innerHTML = '<div class="note">No changes detected.</div>';
        hideSkeleton('compare-result-sk', 'compare-result');
        return;
      }
      let html = '<div class="compare-summary"><strong>Snapshot:</strong> ' + esc(data.snapshot_ts) + ' → <strong>Now:</strong> ' + esc(data.current_ts) + '</div>';
      changes.forEach(c => {
        const diff = c.diff > 0 ? '+' + c.diff : c.diff;
        const color = c.direction === 'increased' || c.direction === 'new' ? 'var(--bad)' : c.direction === 'decreased' || c.direction === 'gone' ? 'var(--ok)' : 'var(--accent)';
        let extra = '';
        if (c.processes) {
          extra = '<div class="compare-procs">' + c.processes.slice(0,5).map(p => `<span>${esc(p.name)} (${fmtMem(p.ws_mb)})</span>`).join('') + (c.count > 5 ? `<span>+${c.count-5} more</span>` : '') + '</div>';
        }
        html += `<div class="compare-item"><span class="compare-name">${esc(c.name)}</span><span class="compare-diff" style="color:${color}">${diff}${c.old !== undefined ? ' (' + c.old + '→' + c.new + '%)' : ''}</span>${extra}</div>`;
      });
      resultEl.innerHTML = html;
      hideSkeleton('compare-result-sk', 'compare-result');
    } catch (e) {
      resultEl.innerHTML = '<div class="note" style="color:var(--bad)">Error comparing snapshot</div>';
      hideSkeleton('compare-result-sk', 'compare-result');
    }
  }

  function exportSnapshot(id, label, format) {
    const safeLabel = (label || 'no_label').replace(/[^\w\-_]/g, '_');
    const filename = `pcmon_snapshot_${id}_${safeLabel}.${format}`;
    const url = `/api/snapshots/${id}/export${format === 'csv' ? '.csv' : ''}`;
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }

  function initSnapshots() {
    const saveBtn = EL('btn-save-snap');
    if (saveBtn) saveBtn.addEventListener('click', saveSnapshot);
    loadSnapshots();
  }

  /* ── Report Generation ───────────────────────────────────────────── */
  function generateReport() {
    window.open('/api/report', '_blank');
  }

  function downloadReport() {
    const a = document.createElement('a');
    a.href = '/api/report/download';
    a.download = '';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }

  function initReportButtons() {
    const genBtn = EL('btn-gen-report');
    if (genBtn) genBtn.addEventListener('click', generateReport);
    const dlBtn = EL('btn-dl-report');
    if (dlBtn) dlBtn.addEventListener('click', downloadReport);
  }

  /* ── Threshold settings ───────────────────────────────────────────── */
  const THRESHOLD_DEFS = [
    { key: 'ram_pct', label: 'RAM Usage %', unit: '%', default: 85 },
    { key: 'cpu_pct', label: 'CPU Usage %', unit: '%', default: 90 },
    { key: 'commit_pct', label: 'Commit Charge %', unit: '%', default: 80 },
    { key: 'pages_sec', label: 'Pages / sec', unit: '/s', default: 1000 },
    { key: 'non_paged_mb', label: 'Non-Paged Pool', unit: 'MB', default: 1500 },
    { key: 'disk_pct', label: 'Disk Usage %', unit: '%', default: 90 },
  ];

  async function loadThresholds() {
    try {
      const res = await fetch('/api/config');
      if (!res.ok) return thresholds || {};
      return await res.json();
    } catch { return thresholds || {}; }
  }

  async function saveThresholds(thresholds) {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: authHeaders({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(thresholds)
    });
    return res.ok;
  }

  async function renderThresholds() {
    const container = EL('thresholds-form');
    if (!container) return;
    showSkeleton('thresholds-form-sk', 'thresholds-form');
    const data = await loadThresholds();
    container.innerHTML = THRESHOLD_DEFS.map(t => {
      const val = data[t.key] !== undefined ? data[t.key] : t.default;
      return `<div class="threshold-row">
        <label>${esc(t.label)}</label>
        <input type="number" class="sbar" data-key="${t.key}" value="${val}" style="width:100px">
        <span class="threshold-unit">${t.unit}</span>
      </div>`;
    }).join('');
    hideSkeleton('thresholds-form-sk', 'thresholds-form');
  }

  async function saveThresholdsFromForm() {
    const container = EL('thresholds-form');
    const msgEl = EL('thresholds-msg');
    const saveBtn = EL('btn-save-thresholds');
    if (!container) return;
    if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Saving...'; }
    const thresholds = {};
    container.querySelectorAll('input[data-key]').forEach(input => {
      thresholds[input.dataset.key] = parseFloat(input.value) || 0;
    });
    const ok = await saveThresholds(thresholds);
    if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save Thresholds'; }
    if (msgEl) {
      msgEl.textContent = ok ? 'Saved!' : 'Error saving';
      msgEl.style.color = ok ? 'var(--ok)' : 'var(--bad)';
      setTimeout(() => { if (msgEl) msgEl.textContent = ''; }, 2000);
    }
  }

  function initThresholds() {
    renderThresholds();
    const saveBtn = EL('btn-save-thresholds');
    if (saveBtn) saveBtn.addEventListener('click', saveThresholdsFromForm);
  }

  /* ── Resize handler ──────────────────────────────────────────────── */
  let resizeTimer;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      refreshSparklines(
        history.cpu.slice(-1)[0]  || 0,
        history.ram.slice(-1)[0]  || 0,
        history.disk.slice(-1)[0] || 0
      );
    }, 100);
  });

  /* ── Boot ────────────────────────────────────────────────────────── */
  async function start() {
    await loadBootstrap();
    initTabs();
    initRefreshSelector();
    initSearchFilters();
    initSnapshots();
    initThresholds();
    initReportButtons();
    initStream();
  }

  document.readyState === 'loading'
    ? document.addEventListener('DOMContentLoaded', start)
    : start();

})();
