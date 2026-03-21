/* === MODULE: render ================================================ */

/* ── Drives ───────────────────────────────────────────────────────── */
function renderDrives(container, disks) {
  if (!container) return;
  container.innerHTML = '';
  (disks || []).forEach(d => {
    const pct = typeof d.pct === 'number' ? d.pct : 0;
    const cls = pct < 70 ? 'ok' : pct < 85 ? 'warn' : 'bad';
    const div = document.createElement('div');
    div.className = 'drive-card';
    div.innerHTML =
      '<div class="drive-head"><span class="drive-letter">' + esc(d.drive || '?') + '</span><span class="drive-pct ' + cls + '">' + fmtNum(pct) + '%</span></div>' +
      '<div class="drive-label">' + esc(d.label || '') + '</div>' +
      '<div class="drive-bar"><div class="drive-fill ' + cls + '" style="width:' + pct + '%"></div></div>' +
      '<div class="drive-meta">' + fmtMem(d.free_gb * 1024) + ' free&nbsp;/&nbsp;' + fmtMem(d.total_gb * 1024) + ' total</div>';
    container.appendChild(div);
  });
}

/* ── GPU ──────────────────────────────────────────────────────────── */
function renderGPUAdapters(container, gpu) {
  if (!container) return;
  container.innerHTML = '';
  if (!gpu || !gpu.available) { container.innerHTML = '<div class="note">No GPU data available</div>'; return; }
  (gpu.adapters || []).forEach(a => {
    const pct = a.pct || 0;
    const div = document.createElement('div');
    div.className = 'gpu-card';
    div.innerHTML =
      '<div class="gpu-name">' + esc(a.name || 'Unknown') + '</div>' +
      '<div class="gpu-stat">Status: <span style="color:var(--ok)">' + esc(a.status || 'OK') + '</span></div>' +
      '<div class="gpu-stat">Dedicated: ' + fmtMem((a.dedicated_gb || 0) * 1024) + '</div>' +
      '<div class="gpu-stat">Total: ' + fmtMem((a.total_gb || 0) * 1024) + '</div>' +
      '<div class="gpu-bar"><div class="gpu-fill" style="width:' + pct + '%"></div></div>';
    container.appendChild(div);
  });
}

/* ── I/O strip ──────────────────────────────────────────────────── */
function ioHtml(io) {
  return '<div class="io-card"><span class="io-lbl">' + esc(io.label) + '</span><span class="io-val">' + io.val + '</span></div>';
}

/* ── Table ────────────────────────────────────────────────────────── */
function renderTable(tbl, rows, cols, opts = {}) {
  if (!tbl) return;
  tbl.innerHTML = '';
  const thead = tbl.createTHead();
  const hdr = thead.insertRow();
  cols.forEach(c => { const th = document.createElement('th'); th.textContent = c; hdr.appendChild(th); });
  if (opts.actions) { const th = document.createElement('th'); th.textContent = 'Actions'; hdr.appendChild(th); }
  const tbody = tbl.createTBody();
  const maxRows = opts.maxRows || 30;
  rows.slice(0, maxRows).forEach((r, rowIdx) => {
    const tr = tbody.insertRow();
    cols.forEach((_, i) => { const td = tr.insertCell(); td.textContent = r[i] !== undefined ? r[i] : ''; });
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
          btn.dataset.name = p.name;
          btn.style.marginRight = '2px';
          btn.addEventListener('click', () => action.fn(p.pid, p.name));
          td.appendChild(btn);
        });
        const cpBtn = document.createElement('button');
        cpBtn.className = 'btn-sm';
        cpBtn.title = 'Copy to clipboard';
        cpBtn.textContent = 'C';
        cpBtn.addEventListener('click', () => {
          const pathEl = tbl.closest('.pg') || tbl;
          copyTableToClipboard(tbl.id);
        });
        td.appendChild(cpBtn);
      }
    }
  });
}

/* ── Main render ─────────────────────────────────────────────────── */
function renderAll(d) {
  if (!d) return;

  /* Throttle table updates */
  const now = Date.now();
  const doTables = (now - PCM.lastTableUpdate) > PCM.TABLE_UPDATE_INTERVAL;
  if (doTables) PCM.lastTableUpdate = now;

  hideAllSkeletons();

  /* Header */
  if (EL('hdr-host')) EL('hdr-host').textContent = d.hostname || '—';

  /* Overview metrics */
  TXT(EL('sv-ram'), fmtNum(d.ram_pct) + '%');
  TXT(EL('ss-ram'), fmtMem(d.ram_avail_mb) + ' avail');
  COL(EL('sf-ram'), d.ram_pct || 0);
  FILL(EL('sf-fill-ram'), d.ram_pct || 0);
  SBADGE(EL('sb-ram'), d.ram_pct || 0);
  const ramTrend = getTrend(d.ram_pct, PCM.prev.ram);
  if (EL('sdt-ram')) EL('sdt-ram').textContent = ramTrend;
  PCM.prev.ram = d.ram_pct || 0;

  TXT(EL('sv-cpu'), fmtNum(d.cpu_pct) + '%');
  COL(EL('sf-cpu'), d.cpu_pct || 0);
  FILL(EL('sf-fill-cpu'), d.cpu_pct || 0);
  SBADGE(EL('sb-cpu'), d.cpu_pct || 0);
  const cpuTrend = getTrend(d.cpu_pct, PCM.prev.cpu);
  if (EL('sdt-cpu')) EL('sdt-cpu').textContent = cpuTrend;
  PCM.prev.cpu = d.cpu_pct || 0;

  TXT(EL('sv-disk'), fmtNum(d.disk_pct) + '%');
  COL(EL('sf-disk'), d.disk_pct || 0);
  FILL(EL('sf-fill-disk'), d.disk_pct || 0);
  const diskTrend = getTrend(d.disk_pct, PCM.prev.disk);
  if (EL('sdt-disk')) EL('sdt-disk').textContent = diskTrend;
  PCM.prev.disk = d.disk_pct || 0;

  TXT(EL('sv-cm'), fmtNum(d.commit_pct) + '%');
  COL(EL('sf-cm'), d.commit_pct || 0);
  FILL(EL('sf-fill-cm'), d.commit_pct || 0);
  const cmTrend = getTrend(d.commit_pct, PCM.prev.commit);
  if (EL('sdt-cm')) EL('sdt-cm').textContent = cmTrend;
  PCM.prev.commit = d.commit_pct || 0;

  TXT(EL('ts'), d.ts || '—');

  /* Sparklines */
  updateHistory('ram', d.ram_pct);
  updateHistory('cpu', d.cpu_pct);
  updateHistory('disk', d.disk_pct);
  updateHistory('commit', d.commit_pct);
  refreshSparklines(d.cpu_pct || 0, d.ram_pct || 0, d.disk_pct || 0);

  /* RAM page */
  TXT(EL('r-sv-ram'), fmtNum(d.ram_pct) + '%');
  TXT(EL('r-avail'), fmtMem(d.ram_avail_mb) + ' / ' + fmtMem(d.ram_total_gb * 1024));
  COL(EL('r-sf-ram'), d.ram_pct || 0);
  FILL(EL('r-sf-fill-ram'), d.ram_pct || 0);
  TXT(EL('r-sv-priv'), fmtMem(d.private_mb || 0));
  TXT(EL('r-sv-pgpool'), fmtMem(d.paged_pool_mb || 0) + ' (' + fmtNum(d.paged_pool_pct || 0) + '%)');
  TXT(EL('r-sv-npgpool'), fmtMem(d.non_paged_mb || 0) + ' (' + fmtNum(d.non_paged_pct || 0) + '%)');
  TXT(EL('r-sv-pf'), fmtMem(d.page_file_mb || 0) + ' used');
  hideSkeleton('r-tbl-sk', 'r-tbl');

  /* CPU page */
  TXT(EL('c-sv-cpu'), fmtNum(d.cpu_pct) + '%');
  COL(EL('c-sf-cpu'), d.cpu_pct || 0);
  FILL(EL('c-sf-fill-cpu'), d.cpu_pct || 0);
  TXT(EL('c-sv-queue'), (d.cpu_queue || 0).toFixed(1));
  TXT(EL('c-sv-pages'), (d.pages_sec || 0).toFixed(1) + '/s');
  TXT(EL('c-sv-hard'), (d.pages_hard || 0).toFixed(1) + '/s');
  hideSkeleton('c-tbl-sk', 'c-tbl');

  /* Disks */
  renderDrives(EL('ov-disks'), d.disks);
  hideSkeleton('disk-drives-sk', 'disk-drives');
  hideSkeleton('ov-disks-sk', 'ov-disks');

  const diskIo = EL('disk-io-strip');
  if (diskIo) {
    diskIo.innerHTML = [
      { label: 'Disk Read', val: fmtNum(d.disk_read_mb) + ' MB/s' },
      { label: 'Disk Write', val: fmtNum(d.disk_write_mb) + ' MB/s' },
      { label: 'Net Sent', val: fmtNum(d.net_sent_kb) + ' KB/s' },
      { label: 'Net Recv', val: fmtNum(d.net_recv_kb) + ' KB/s' }
    ].map(ioHtml).join('');
    hideSkeleton('disk-io-sk', 'disk-io-strip');
  }

  const ovIo = EL('ov-io');
  if (ovIo) {
    ovIo.innerHTML = [
      { label: 'Disk R/W', val: fmtNum(d.disk_read_mb) + ' / ' + fmtNum(d.disk_write_mb) + ' MB/s' },
      { label: 'Net S/R', val: fmtNum(d.net_sent_kb) + ' / ' + fmtNum(d.net_recv_kb) + ' KB/s' }
    ].map(ioHtml).join('');
    hideSkeleton('ov-io-sk', 'ov-io');
  }

  /* GPU */
  const gpu = d.gpu || {};
  TXT(EL('g-avail'), gpu.available ? 'Yes' : 'No');
  const gpuSection = EL('pg-gpu');
  if (gpuSection) {
    if (gpu && gpu.available) {
      const eng = gpu.eng_type_totals || {};
      TXT(EL('g-3d'), eng['3d'] !== undefined ? fmtNum(eng['3d']) + '%' : 'N/A');
      TXT(EL('g-vdec'), eng['videodecode'] !== undefined ? fmtNum(eng['videodecode']) + '%' : 'N/A');
      TXT(EL('g-venc'), eng['videoencode'] !== undefined ? fmtNum(eng['videoencode']) + '%' : 'N/A');
      TXT(EL('g-copy'), eng['copy'] !== undefined ? fmtNum(eng['copy']) + '%' : 'N/A');
    }
  }
  renderGPUAdapters(EL('gpu-adapters'), gpu);
  hideSkeleton('gpu-adapters-sk', 'gpu-adapters');

  /* Groups */
  const groups = d.groups || {};
  const gi = EL('group-insights');
  if (gi) {
    const items = [];
    if (groups.browser) items.push('Browser: ' + fmtMem(groups.browser.ws_mb) + ' (' + groups.browser.count + ' tabs)');
    if (groups.devtools) items.push('Dev Tools: ' + fmtMem(groups.devtools.ws_mb) + ' (' + groups.devtools.count + ' tools)');
    if (groups.security) items.push('Security: ' + fmtMem(groups.security.ws_mb) + ' (' + groups.security.count + ' services)');
    gi.innerHTML = items.length ? items.map(t => '<div class="insight">' + esc(t) + '</div>').join('') : '<div class="note" style="padding:6px 0">No group activity detected.</div>';
    hideSkeleton('group-insights-sk', 'group-insights');
  }

  /* System */
  const sysSummary = EL('sys-summary');
  if (sysSummary) {
    sysSummary.innerHTML = [
      ['Hostname', esc(d.hostname) || '—'],
      ['OS', esc(d.os_caption) || '—'],
      ['Total Processes', d.total_procs || 0],
      ['RAM Total', fmtMem(d.ram_total_gb * 1024)],
      ['Commit Limit', fmtMem(d.limit_gb * 1024)]
    ].map(([k, v]) => '<div class="sys-row"><span>' + k + '</span><span>' + v + '</span></div>').join('');
    hideSkeleton('sys-summary-sk', 'sys-summary');
  }

  /* Throttled tables */
  if (doTables) {
    const topRamData = (d.top_ram || []).slice(0, 20);
    renderTable(EL('ov-tbl'), topRamData.map(p => [p.name || '?', p.pid || 0, fmtMem(p.ws_mb), fmtNum(p.cpu_s, 1) + 's']), ['Name', 'PID', 'WS', 'CPU'], { actions: true, processData: topRamData });
    hideSkeleton('ov-tbl-sk', 'ov-tbl');

    const topPrivData = (d.top_private || []).slice(0, 20);
    renderTable(EL('r-tbl'), topPrivData.map(p => [p.name || '?', p.pid || 0, fmtMem(p.ws_mb), fmtMem(p.private_mb)]), ['Name', 'PID', 'WS', 'Private'], { actions: true, processData: topPrivData });
    hideSkeleton('r-tbl-sk', 'r-tbl');

    const topCpuData = (d.top_cpu || []).slice(0, 20);
    renderTable(EL('c-tbl'), topCpuData.map(p => [p.name || '?', p.pid || 0, fmtNum(p.cpu_s, 1) + 's', fmtMem(p.ws_mb)]), ['Name', 'PID', 'CPU Time', 'WS'], { actions: true, processData: topCpuData });
    hideSkeleton('c-tbl-sk', 'c-tbl');

    const susData = (d.suspicious || []).slice(0, 30);
    renderTable(EL('sus-tbl'), susData.map(p => [p.name || '?', p.pid || 0, fmtMem(p.ws_mb), p.command_line ? 'Yes' : 'No']), ['Name', 'PID', 'WS', 'CLI?'], { actions: true, processData: susData });
    hideSkeleton('sus-tbl-sk', 'sus-tbl');

    const svcData = (d.heavy_services || []).slice(0, 25);
    renderTable(EL('svc-tbl'), svcData.map(s => [s.display_name || s.name || '?', s.name || '?', s.state || '?', s.start_mode || '?', s.pid || 0, fmtMem((d.top_ram || []).find(p => p.pid == s.pid)?.ws_mb || 0)]), ['Display Name', 'Name', 'State', 'Start', 'PID', 'WS'], {});
    hideSkeleton('svc-tbl-sk', 'svc-tbl');

    /* System page */
    renderDrives(EL('disk-drives'), d.disks);

    const startupData = (d.startup_items || []).slice(0, 20);
    renderTable(EL('startup-tbl'), startupData.map(s => [s.name || '?', s.command || '?', s.location || '?']), ['Name', 'Command', 'Location'], {});
    hideSkeleton('startup-tbl-sk', 'startup-tbl');

    const pfData = (d.pagefile || []).slice(0, 5);
    renderTable(EL('pagefile-tbl'), pfData.map(p => [p.name || '?', fmtMem(p.allocated_mb), fmtMem(p.current_usage_mb), fmtMem(p.peak_usage_mb)]), ['Name', 'Allocated MB', 'Current MB', 'Peak MB'], {});
    hideSkeleton('pagefile-tbl-sk', 'pagefile-tbl');

    const profiles = (d.powershell_profiles || []);
    renderTable(EL('profiles-tbl'), profiles.map(p => [p.path || '?', p.size_kb ? fmtMem(p.size_kb) : '?']), ['Profile Path', 'Size'], {});
    hideSkeleton('profiles-tbl-sk', 'profiles-tbl');

    /* All Processes */
    const allProcs = (d.all_processes || []).slice(0, 100);
    renderTable(EL('all-tbl'), allProcs.map(p => [p.name || '?', p.pid || 0, fmtMem(p.ws_mb), fmtNum(p.cpu_s, 1) + 's', p.threads || 0, p.handles || 0]), ['Name', 'PID', 'WS', 'CPU', 'Threads', 'Handles'], { actions: true, processData: allProcs });
    hideSkeleton('all-tbl-sk', 'all-tbl');

    /* Insights */
    const insEl = EL('insights-list');
    if (insEl) {
      insEl.innerHTML = (d.insights || []).map(t => '<div class="insight">' + esc(t) + '</div>').join('');
      if (!d.insights || d.insights.length === 0) insEl.innerHTML = '<div class="note" style="padding:6px 0">No insights yet.</div>';
    }
  }

  /* Insights (always) */
  const gi2 = EL('group-insights');
  if (gi2 && d.insights) {
    gi2.innerHTML = (d.insights || []).map(t => '<div class="insight">' + esc(t) + '</div>').join('');
  }

  /* Error banner */
  const psErrEl = EL('ps-errors');
  if (psErrEl) {
    const psErrBanner = EL('ps-errors');
    if (data.error_count > 0) psErrEl.innerHTML = '<div class="err-banner">PowerShell errors: ' + data.error_count + ' | <a href="/logs" target="_blank" rel="noopener">View logs</a> | <a href="/debug" target="_blank" rel="noopener">Debug</a></div>';
    else psErrEl.innerHTML = '';
  }
}

/* ── Debug panel ─────────────────────────────────────────────────── */
function updateDebugPanel(data) {
  const dbgFetch = EL('dbg-fetch');
  const dbgRender = EL('dbg-render');
  const dbgCycle = EL('dbg-cycle');
  const dbgFps = EL('dbg-fps');
  const dbgMem = EL('dbg-mem');

  if (dbgFetch) {
    const fc = PCM.perf.fetchMs < 500 ? 'ok' : PCM.perf.fetchMs < 2000 ? 'warn' : 'bad';
    dbgFetch.textContent = data && data._loading ? 'waiting...' : PCM.perf.fetchMs.toFixed(1) + ' ms';
    dbgFetch.className = 'sval ' + (data && data._loading ? 'warn' : fc);
    COL(EL('dbg-sc-fetch'), data && data._loading ? 50 : PCM.perf.fetchMs > 2000 ? 90 : PCM.perf.fetchMs > 500 ? 50 : 10);
  }
  if (dbgRender) {
    const rc = PCM.perf.renderMs < 50 ? 'ok' : PCM.perf.renderMs < 200 ? 'warn' : 'bad';
    dbgRender.textContent = PCM.perf.renderMs.toFixed(1) + ' ms';
    dbgRender.className = 'sval ' + rc;
    COL(EL('dbg-sc-render'), PCM.perf.renderMs > 200 ? 90 : PCM.perf.renderMs > 50 ? 50 : 10);
  }
  if (dbgCycle) {
    const cc = PCM.perf.cycleMs < 2000 ? 'ok' : PCM.perf.cycleMs < 5000 ? 'warn' : 'bad';
    dbgCycle.textContent = PCM.perf.cycleMs.toFixed(1) + ' ms';
    dbgCycle.className = 'sval ' + cc;
    COL(EL('dbg-sc-cycle'), PCM.perf.cycleMs > 5000 ? 90 : PCM.perf.cycleMs > 2000 ? 50 : 10);
  }
  if (dbgFps) {
    const fps = PCM.perf.fps;
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
      ? '<div class="sys-row"><span>JS Heap Used</span><span>' + mem.used + ' MB</span></div><div class="sys-row"><span>JS Heap Total</span><span>' + mem.total + ' MB</span></div><div class="sys-row"><span>JS Heap Limit</span><span>' + mem.limit + ' MB</span></div><div class="sys-row"><span>Utilization</span><span>' + Math.round(mem.used / mem.limit * 100) + '%</span></div>'
      : '<div class="note">Memory API not available (Chrome only)</div>';
    hideSkeleton('dbg-mem-sk', 'dbg-mem');
  }

  const isLoading = data && data._loading;
  const dbgTl = EL('dbg-timeline');
  if (dbgTl) {
    const connIcons = { websocket: '⚡', sse: '🔌', http: '🔄' };
    dbgTl.innerHTML = '' +
      '<div class="sys-row"><span>Status</span><span style="color:' + (isLoading ? 'var(--warn)' : 'var(--ok)') + '">' + (isLoading ? 'Collecting data...' : 'Live') + '</span></div>' +
      '<div class="sys-row"><span>Connection</span><span>' + (connIcons[PCM.connectionMethod] || '?') + ' ' + PCM.connectionMethod + '</span></div>' +
      '<div class="sys-row"><span>Refresh</span><span>' + PCM.refreshInterval + 'ms</span></div>' +
      '<div class="sys-row"><span>Table Update</span><span>' + PCM.TABLE_UPDATE_INTERVAL + 'ms</span></div>' +
      '<div class="sys-row"><span>Data Age</span><span>' + (PCM.cachedData && !isLoading ? ((Date.now() - PCM.perfTimer) / 1000).toFixed(1) + 's ago' : '—') + '</span></div>' +
      '<div class="sys-row"><span>Processes</span><span>' + (data ? data.total_procs : '—') + '</span></div>' +
      '<div class="sys-row"><span>DOM Nodes</span><span>' + document.querySelectorAll('*').length + '</span></div>';
    hideSkeleton('dbg-timeline-sk', 'dbg-timeline');
  }

  const dbgSys = EL('dbg-sys-metrics');
  if (dbgSys && data) {
    dbgSys.innerHTML = isLoading
      ? '<div class="note">Waiting for data collection...</div>'
      : '<div class="sys-row"><span>RAM Usage</span><span>' + fmtNum(data.ram_pct) + '% (' + data.ram_used_gb + ' GB / ' + data.ram_total_gb + ' GB)</span></div>' +
        '<div class="sys-row"><span>CPU</span><span>' + fmtNum(data.cpu_pct) + '%</span></div>' +
        '<div class="sys-row"><span>Commit</span><span>' + fmtNum(data.commit_pct) + '% (' + data.commit_gb + ' GB)</span></div>' +
        '<div class="sys-row"><span>GPU 3D</span><span>' + (data.gpu && data.gpu.available ? fmtNum(data.gpu.eng_type_totals['3d']) + '%' : 'N/A') + '</span></div>' +
        '<div class="sys-row"><span>Pages/sec</span><span>' + data.pages_sec + '</span></div>' +
        '<div class="sys-row"><span>Non-Paged Pool</span><span>' + data.non_paged_mb + ' MB</span></div>' +
        '<div class="sys-row"><span>Perf (BE)</span><span>' + (data._perf_ms ? data._perf_ms + ' ms' : '—') + '</span></div>';
    hideSkeleton('dbg-sys-metrics-sk', 'dbg-sys-metrics');
  }

  const dbgCache = EL('dbg-cache');
  if (dbgCache) {
    const connIcons = { websocket: '⚡', sse: '🔌', http: '🔄' };
    const connLabels = { websocket: 'WS Connected', sse: 'SSE Connected', http: 'HTTP Polling' };
    const connColor = PCM.connectionMethod === 'websocket' || PCM.connectionMethod === 'sse' ? 'var(--ok)' : 'var(--warn)';
    dbgCache.innerHTML = '' +
      '<div class="sys-row"><span>Status</span><span style="color:' + (isLoading || PCM.pollInFlight ? 'var(--warn)' : 'var(--ok)') + '">' + (isLoading || PCM.pollInFlight ? 'Collecting...' : 'Ready') + '</span></div>' +
      '<div class="sys-row"><span>Connection</span><span style="color:' + connColor + '">' + (connIcons[PCM.connectionMethod] || '?') + ' ' + (connLabels[PCM.connectionMethod] || PCM.connectionMethod) + '</span></div>' +
      '<div class="sys-row"><span>Refresh</span><span>' + PCM.refreshInterval + 'ms</span></div>';
    hideSkeleton('dbg-cache-sk', 'dbg-cache');
  }

  const dbgErrCount = EL('js-err-count');
  const dbgErrList = EL('js-errors');
  const dbgPsErrs = EL('dbg-ps-errs');
  if (dbgErrCount) dbgErrCount.textContent = PCM.errors.length;
  if (dbgErrList) {
    if (PCM.errors.length === 0) dbgErrList.innerHTML = '<div class="note">No errors detected</div>';
    else dbgErrList.innerHTML = PCM.errors.slice(-20).reverse().map(e => {
      const d = new Date(e.ts);
      const time = d.toLocaleTimeString();
      const info = e.line ? ' at ' + (e.src || '') + ':' + e.line : '';
      return '<div class="err-entry ' + (e.type || 'error') + '"><span class="err-time">' + time + '</span><span class="err-type">' + (e.type || 'ERROR').toUpperCase() + '</span><span class="err-msg">' + esc(e.msg) + info + '</span></div>';
    }).join('');
  }
  if (dbgPsErrs) {
    const psErrBanner = EL('ps-errors');
    if (psErrBanner && psErrBanner.textContent) dbgPsErrs.innerHTML = psErrBanner.textContent;
  }
}

/* ── FPS tracking ───────────────────────────────────────────────── */
function trackFPS(ts) {
  PCM.perf.fpsFrames++;
  if (ts - PCM.perf.fpsLast >= 1000) {
    PCM.perf.fps = PCM.perf.fpsFrames;
    PCM.perf.fpsFrames = 0;
    PCM.perf.fpsLast = ts;
  }
  requestAnimationFrame(trackFPS);
}
requestAnimationFrame(trackFPS);

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
      if (tab.dataset.page === 'debug' && PCM.cachedData) updateDebugPanel(PCM.cachedData);
      setTimeout(() => refreshSparklines(PCM.history.cpu.slice(-1)[0] || 0, PCM.history.ram.slice(-1)[0] || 0, PCM.history.disk.slice(-1)[0] || 0), 50);
    });
  });
}

/* ── Refresh selector ────────────────────────────────────────────── */
function updateSettingsConnInfo() {
  const statusEl = EL('set-conn-status');
  const methodEl = EL('set-conn-method');
  const refreshEl = EL('set-refresh-val');
  const latencyEl = EL('set-latency');
  const connLabels = { websocket: '⚡ WebSocket (Fastest)', sse: '🔌 SSE (Fast)', http: '🔄 HTTP Polling' };
  const isConnected = (PCM.eventSource && PCM.eventSource.readyState === EventSource.OPEN) || (PCM.wsSocket && PCM.wsSocket.readyState === WebSocket.OPEN);
  if (statusEl) statusEl.textContent = isConnected ? 'Connected' : 'Disconnected';
  if (methodEl) methodEl.textContent = connLabels[PCM.connectionMethod] || PCM.connectionMethod;
  if (refreshEl) refreshEl.textContent = PCM.refreshInterval + ' ms';
  if (latencyEl) latencyEl.textContent = PCM.perf.fetchMs > 0 ? PCM.perf.fetchMs.toFixed(1) + ' ms' : '—';
  const methodDisplayEl = EL('method-display');
  if (methodDisplayEl) methodDisplayEl.textContent = (connLabels[PCM.connectionMethod] || PCM.connectionMethod);
}

function initRefreshSelector() {
  const sel = EL('rf-sel');
  const settingsSel = EL('rf-sel-settings');
  if (!sel) return;

  const updateRefresh = (rate) => {
    PCM.refreshInterval = rate;
    try {
      fetch('/api/refresh-rate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refreshRate: rate })
      }).catch(() => {});
    } catch (e) {}
    updateSettingsConnInfo();
  };

  sel.addEventListener('change', () => {
    const rate = Math.min(10000, Math.max(500, parseInt(sel.value, 10) || 500));
    updateRefresh(rate);
  });

  if (settingsSel) {
    settingsSel.addEventListener('change', () => {
      if (sel) sel.value = settingsSel.value;
      const rate = Math.min(10000, Math.max(500, parseInt(settingsSel.value, 10) || 500));
      updateRefresh(rate);
    });
  }
}

/* ── Search filters ──────────────────────────────────────────────── */
function initSearchFilters() {
  const procsSearch = EL('procs-search');
  if (procsSearch) {
    procsSearch.addEventListener('input', () => {
      const q = procsSearch.value.toLowerCase();
      const rows = EL('all-tbl')?.querySelectorAll('tbody tr') || [];
      rows.forEach(tr => {
        const name = (tr.cells[0]?.textContent || '').toLowerCase();
        tr.style.display = name.includes(q) ? '' : 'none';
      });
    });
  }
}

/* ── Snapshots ──────────────────────────────────────────────────── */
function initSnapshots() {
  renderSnapshots();
  const saveBtn = EL('btn-save-snap');
  if (saveBtn) saveBtn.addEventListener('click', async () => {
    const label = prompt('Snapshot label (optional):', '');
    if (label === null) return;
    try {
      await fetch('/api/snapshots', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ label })
      });
      renderSnapshots();
    } catch (e) { alert('Failed to save snapshot'); }
  });
}

async function renderSnapshots() {
  const container = EL('snapshots-list');
  if (!container) return;
  const snapshots = await fetchSnapshots();
  if (!snapshots || snapshots.length === 0) { container.innerHTML = '<div class="note">No snapshots yet. Click Save Snapshot to create one.</div>'; return; }
  container.innerHTML = snapshots.map(s =>
    '<div class="snap-item">' +
    '<span class="snap-ts">' + esc(s.ts) + '</span>' +
    '<span class="snap-lbl">' + esc(s.label || '') + '</span>' +
    '<button class="btn-sm" onclick="compareSnapshot(\'' + s.id + '\')">Compare</button>' +
    '<button class="btn-sm" onclick="exportSnapshot(\'' + s.id + '\',\'json\')">JSON</button>' +
    '<button class="btn-sm" onclick="exportSnapshot(\'' + s.id + '\',\'csv\')">CSV</button>' +
    '<button class="btn-sm btn-danger" onclick="deleteSnapshot(\'' + s.id + '\')">X</button>' +
    '</div>'
  ).join('');
}

/* ── Thresholds ──────────────────────────────────────────────────── */
const THRESHOLD_DEFS = [
  { key: 'ram_pct', label: 'RAM Usage %', min: 0, max: 100 },
  { key: 'cpu_pct', label: 'CPU Usage %', min: 0, max: 100 },
  { key: 'commit_pct', label: 'Commit Charge %', min: 0, max: 100 },
  { key: 'pages_sec', label: 'Pages/sec', min: 0, max: 10000 },
  { key: 'non_paged_mb', label: 'Non-Paged Pool MB', min: 0, max: 10000 },
  { key: 'disk_pct', label: 'Disk Usage %', min: 0, max: 100 }
];

function renderThresholds() {
  const container = EL('thresholds-form');
  if (!container) return;
  container.innerHTML = THRESHOLD_DEFS.map(t =>
    '<div class="th-row"><label>' + esc(t.label) + '</label><input type="number" data-key="' + t.key + '" value="' + (PCM.thresholds[t.key] || 0) + '" min="' + t.min + '" max="' + t.max + '"></div>'
  ).join('');
}

async function saveThresholdsFromForm() {
  const container = EL('thresholds-form');
  const msgEl = EL('thresholds-msg');
  const saveBtn = EL('btn-save-thresholds');
  if (!container) return;
  if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Saving...'; }
  const thresholds = {};
  container.querySelectorAll('input[data-key]').forEach(input => { thresholds[input.dataset.key] = parseFloat(input.value) || 0; });
  const ok = await saveThresholds(thresholds);
  if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save Thresholds'; }
  if (msgEl) {
    msgEl.textContent = ok ? 'Saved!' : 'Error saving';
    msgEl.style.color = ok ? 'var(--ok)' : 'var(--bad)';
    setTimeout(() => { if (msgEl) msgEl.textContent = ''; }, 2000);
  }
}

function initThresholds() { renderThresholds(); const saveBtn = EL('btn-save-thresholds'); if (saveBtn) saveBtn.addEventListener('click', saveThresholdsFromForm); }

/* ── Report ──────────────────────────────────────────────────────── */
function initReportButtons() {
  const openBtn = EL('btn-open-report');
  if (openBtn) openBtn.addEventListener('click', async () => {
    const report = await fetchReport();
    const win = window.open('', '_blank');
    if (win) { win.document.write(report); win.document.close(); }
  });
  const dlBtn = EL('btn-dl-report');
  if (dlBtn) dlBtn.addEventListener('click', fetchReportDownload);
  const compareBtn = EL('btn-compare-snap');
  if (compareBtn) compareBtn.addEventListener('click', () => { const id = prompt('Enter snapshot ID to compare:'); if (id) compareSnapshot(id); });
}

async function compareSnapshot(id) {
  const resultEl = EL('compare-result');
  if (resultEl) resultEl.innerHTML = '<div class="note">Comparing...</div>';
  try {
    const data = await compareSnapshots(id);
    if (resultEl) {
      if (data.error) { resultEl.innerHTML = '<div class="note" style="color:var(--bad)">' + esc(data.error) + '</div>'; return; }
      if (!data.changes || data.changes.length === 0) { resultEl.innerHTML = '<div class="note">No changes detected.</div>'; return; }
      let html = '<div class="compare-summary"><strong>Snapshot:</strong> ' + esc(data.snapshot_ts) + ' → <strong>Now:</strong> ' + esc(data.current_ts) + '</div>';
      data.changes.forEach(c => {
        const color = c.new > c.old ? 'var(--bad)' : c.new < c.old ? 'var(--ok)' : 'var(--dim)';
        const diff = c.old !== undefined && c.new !== undefined ? (c.new - c.old).toFixed(1) : '';
        let extra = '';
        if (c.name === 'Top RAM Process' && c.processes) extra = '<div class="compare-procs">' + c.processes.slice(0, 5).map(p => '<span>' + esc(p.name) + ' (' + fmtMem(p.ws_mb) + ')</span>').join('') + (c.count > 5 ? '<span>+' + (c.count - 5) + ' more</span>' : '') + '</div>';
        html += '<div class="compare-item"><span class="compare-name">' + esc(c.name) + '</span><span class="compare-diff" style="color:' + color + '">' + diff + (c.old !== undefined ? ' (' + c.old + '→' + c.new + '%)' : '') + '</span>' + extra + '</div>';
      });
      resultEl.innerHTML = html;
    }
  } catch (e) { if (resultEl) resultEl.innerHTML = '<div class="note" style="color:var(--bad)">Error comparing snapshot</div>'; }
}

/* ── Resize ──────────────────────────────────────────────────────── */
window.addEventListener('resize', () => {
  clearTimeout(PCM.resizeTimer);
  PCM.resizeTimer = setTimeout(() => {
    refreshSparklines(PCM.history.cpu.slice(-1)[0] || 0, PCM.history.ram.slice(-1)[0] || 0, PCM.history.disk.slice(-1)[0] || 0);
  }, 100);
});

/* ── Expose globals ─────────────────────────────────────────────── */
window.killProcess = killProcess;
window.suspendProcess = suspendProcess;
window.resumeProcess = resumeProcess;
window.copyTableToClipboard = copyTableToClipboard;
window.compareSnapshot = compareSnapshot;
window.exportSnapshot = exportSnapshot;
window.deleteSnapshot = deleteSnapshot;

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
