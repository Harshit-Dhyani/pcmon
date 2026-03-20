(function () {
  'use strict';

  /* ── Config ──────────────────────────────────────────────────────── */
  const HISTORY_SIZE = 40;
  let refreshInterval = 2000;
  let intervalId = null;
  let firstLoad = true;

  const history = { ram: [], cpu: [], disk: [], net: [], commit: [] };
  const prev = { ram: 0, cpu: 0, disk: 0, commit: 0 };

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

  function fmtNum(n, dec = 1) { if (n === null || n === undefined || isNaN(n) || !isFinite(n)) return '—'; return n.toFixed(dec); }

  function fmtMem(mb) {
    if (mb === null || mb === undefined || isNaN(mb) || !isFinite(mb)) return '—';
    if (mb >= 1024) return (mb / 1024).toFixed(1) + ' GB';
    return mb.toFixed(0) + ' MB';
  }

  /* ── Skeleton teardown ───────────────────────────────────────────── */
  function hideSkeleton(skId, tableId) {
    const sk = EL(skId);
    const tbl = EL(tableId);
    if (sk)  sk.style.display = 'none';
    if (tbl) tbl.style.display = '';
  }

  function unloadCard(cardEl) {
    if (cardEl) cardEl.classList.remove('loading');
  }

  /* ── Canvas Sparklines ───────────────────────────────────────────── */
  function drawSparkline(canvasId, values, colorVar) {
    const canvas = EL(canvasId);
    if (!canvas || !values || values.length < 2) return;

    // Filter out invalid values
    const validValues = values.filter(v => typeof v === 'number' && !isNaN(v) && isFinite(v));
    if (validValues.length < 2) return;

    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.parentElement.getBoundingClientRect();
    const W = Math.max(rect.width || 200, 100);
    const H = parseInt(canvas.style.height) || 32;

    canvas.style.width  = W + 'px';
    canvas.style.height = H + 'px';
    canvas.width  = W * dpr;
    canvas.height = H * dpr;

    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, W, H);

    const max  = Math.max(...validValues, 1);
    const step = W / (validValues.length - 1 || 1);

    // resolve css var color
    const style = getComputedStyle(document.documentElement);
    const color = style.getPropertyValue(colorVar).trim() || '#00f5b0';

    // Build path
    ctx.beginPath();
    validValues.forEach((v, i) => {
      const x = i * step;
      const y = H - (v / max) * (H - 4) - 2;
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    });

    // Stroke
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.lineJoin = 'round';
    ctx.lineCap  = 'round';

    // Glow
    ctx.shadowColor = color;
    ctx.shadowBlur  = 6;
    ctx.stroke();
    ctx.shadowBlur = 0;

    // Fill gradient
    const lastX = (validValues.length - 1) * step;
    const lastY = H - (validValues[validValues.length - 1] / max) * (H - 4) - 2;
    ctx.lineTo(lastX, H);
    ctx.lineTo(0, H);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, 0, 0, H);
    grad.addColorStop(0, color.replace(')', ', 0.18)').replace('rgb(','rgba(').replace('#', 'rgba(').replace(/^rgba\(#(..)(..)(..)/, (m,r,g,b) => `rgba(${parseInt(r,16)},${parseInt(g,16)},${parseInt(b,16)}`));
    // Simpler approach using opacity
    ctx.fillStyle = hexOrVarToAlpha(color, 0.12);
    ctx.fill();
  }

  function hexOrVarToAlpha(color, alpha) {
    // color may be hex like #00f5b0 or an rgb string
    if (color.startsWith('#')) {
      const r = parseInt(color.slice(1,3),16);
      const g = parseInt(color.slice(3,5),16);
      const b = parseInt(color.slice(5,7),16);
      return `rgba(${r},${g},${b},${alpha})`;
    }
    if (color.startsWith('rgb(')) {
      return color.replace('rgb(','rgba(').replace(')',`,${alpha})`);
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

  /* ── Table rendering ─────────────────────────────────────────────── */
  function renderTable(tbl, rows, cols) {
    if (!tbl) return;
    tbl.innerHTML = '';
    const thead = tbl.createTHead();
    const hdr = thead.insertRow();
    cols.forEach(c => {
      const th = document.createElement('th');
      th.textContent = c;
      hdr.appendChild(th);
    });
    const tbody = tbl.createTBody();
    rows.slice(0, 50).forEach(r => {
      const tr = tbody.insertRow();
      cols.forEach((_, i) => {
        const td = tr.insertCell();
        td.textContent = r[i] !== undefined ? r[i] : '';
      });
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

  /* ── Master render ───────────────────────────────────────────────── */
  function renderAll(d) {
    if (!d) return;

    TXT(EL('ts'),       d.ts);
    TXT(EL('hdr-host'), d.hostname || '—');

    /* ── RAM ── */
    const ramPct = d.ram_pct || 0;
    const ramCls = statusClass(ramPct);
    TXT(EL('sv-ram'), fmtNum(ramPct) + '%');
    TXT(EL('ss-ram'), fmtMem(d.ram_used_gb * 1024) + ' / ' + fmtMem(d.ram_total_gb * 1024));
    EL('sv-ram')?.classList.replace('ok','') || true;
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

    /* ── Tables ── */
    TXT(EL('ov-pc'), (d.total_procs || 0) + ' processes');

    if (firstLoad) {
      hideSkeleton('ov-tbl-sk',       'ov-tbl');
      hideSkeleton('r-tbl-sk',        'r-tbl');
      hideSkeleton('c-tbl-sk',        'c-tbl');
      hideSkeleton('sus-tbl-sk',      'sus-tbl');
      hideSkeleton('svc-tbl-sk',      'svc-tbl');
      hideSkeleton('startup-tbl-sk',  'startup-tbl');
      hideSkeleton('pagefile-tbl-sk', 'pagefile-tbl');
      hideSkeleton('profiles-tbl-sk', 'profiles-tbl');
      hideSkeleton('all-tbl-sk',      'all-tbl');
      firstLoad = false;
    }

    const topRamRows = (d.top_ram || []).slice(0, 20).map(p => [
      p.name || '?', p.pid || 0, fmtMem(p.ws_mb), fmtNum(p.cpu_s, 1) + 's'
    ]);
    renderTable(EL('ov-tbl'), topRamRows, ['Name','PID','WS','CPU']);

    renderDrives(EL('disk-drives'), d.disks);
    renderDrives(EL('ov-disks'), d.disks);

    /* I/O strip */
    const ioHtml = io => `
      <div class="io-card">
        <span class="io-lbl">${io.label}</span>
        <span class="io-val">${io.val}</span>
      </div>`;
    const diskIo = EL('disk-io-strip');
    if (diskIo) {
      diskIo.innerHTML = [
        { label: 'Disk Read',  val: fmtNum(d.disk_read_mb)  + ' MB/s' },
        { label: 'Disk Write', val: fmtNum(d.disk_write_mb) + ' MB/s' },
        { label: 'Net Sent',   val: fmtNum(d.net_sent_kb)   + ' KB/s' },
        { label: 'Net Recv',   val: fmtNum(d.net_recv_kb)   + ' KB/s' },
      ].map(ioHtml).join('');
    }

    const ovIo = EL('ov-io');
    if (ovIo) {
      ovIo.innerHTML = [
        { label: 'Disk R/W',      val: fmtNum(d.disk_read_mb) + ' / ' + fmtNum(d.disk_write_mb) + ' MB/s' },
        { label: 'Net Sent/Recv', val: fmtNum(d.net_sent_kb) + ' / ' + fmtNum(d.net_recv_kb) + ' KB/s'   },
      ].map(ioHtml).join('');
    }

    /* RAM table */
    const topPrivateRows = (d.top_private || []).slice(0,30).map(p => [
      p.name||'?', p.pid||0, fmtMem(p.ws_mb), fmtMem(p.private_mb),
      fmtNum(p.cpu_s,1)+'s', p.threads||0, p.handles||0
    ]);
    renderTable(EL('r-tbl'), topPrivateRows, ['Name','PID','WS','Private','CPU','Threads','Handles']);

    /* CPU table */
    const topCpuRows = (d.top_cpu || []).slice(0,20).map(p => [
      p.name||'?', p.pid||0, fmtNum(p.cpu_s,1)+'s', fmtMem(p.ws_mb), p.threads||0
    ]);
    renderTable(EL('c-tbl'), topCpuRows, ['Name','PID','CPU Time','WS','Threads']);

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
    TXT(EL('g-3d'),   eng['3d']          !== undefined ? eng['3d'].toFixed(1)          + '%' : 'N/A');
    TXT(EL('g-vdec'), eng['videodecode'] !== undefined ? eng['videodecode'].toFixed(1)  + '%' : 'N/A');
    TXT(EL('g-venc'), eng['videoencode'] !== undefined ? eng['videoencode'].toFixed(1)  + '%' : 'N/A');
    renderGPUAdapters(EL('gpu-adapters'), gpu);
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
    }

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
    }

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
    const allRows = (d.top_ram || []).map(p => [
      p.name||'?', p.pid||0, fmtMem(p.ws_mb), fmtMem(p.private_mb),
      fmtNum(p.cpu_s,1)+'s', p.threads||0, p.handles||0, p.path||''
    ]);
    renderTable(EL('all-tbl'), allRows, ['Name','PID','WS','Private','CPU','Threads','Handles','Path']);
    TXT(EL('all-pc'), (d.total_procs || 0) + ' processes');

    /* Alerts */
    setAlert('al-pg', 1000, d.pages_sec,    'al-pg-t');
    setAlert('al-cm', 80,   d.commit_pct,   'al-cm-t');
    setAlert('al-np', 500,  d.non_paged_mb, 'al-np-t');
  }

  /* ── Error tracking ─────────────────────────────────────────────── */
  const ERRORS = [];
  const MAX_ERRORS = 100;

  window.onerror = (msg, src, line, col, err) => {
    ERRORS.push({ ts: Date.now(), type: 'js', msg: String(msg), src, line, col });
    if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
    updateErrorDisplay();
    return false;
  };

  window.onunhandledrejection = (e) => {
    ERRORS.push({ ts: Date.now(), type: 'promise', msg: String(e.reason) });
    if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
    updateErrorDisplay();
  };

  function updateErrorDisplay() {
    const el = EL('js-errors');
    if (!el) return;
    if (ERRORS.length === 0) {
      el.innerHTML = '<div class="note">No errors detected</div>';
      return;
    }
    el.innerHTML = ERRORS.slice(-20).reverse().map(e => {
      const d = new Date(e.ts);
      const time = d.toLocaleTimeString();
      const info = e.line ? ` at ${e.src}:${e.line}` : '';
      return `<div class="err-entry ${e.type}"><span class="err-time">${time}</span><span class="err-type">${e.type.toUpperCase()}</span><span class="err-msg">${esc(e.msg)}${info}</span></div>`;
    }).join('');
  }

  async function fetchErrors() {
    try {
      const res = await fetch('/errors');
      if (!res.ok) return;
      const data = await res.json();
      const psErrEl = EL('ps-errors');
      if (psErrEl && data.error_count > 0) {
        psErrEl.innerHTML = `<div class="err-banner">PowerShell errors: ${data.error_count} | <a href="/logs" target="_blank">View logs</a> | <a href="/debug" target="_blank">Debug</a></div>`;
      }
      ERRORS.push({ ts: Date.now(), type: 'api', msg: `API Error Count: ${data.error_count}` });
      if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
      updateErrorDisplay();
    } catch {}
  }

  /* ── Fetch ───────────────────────────────────────────────────────── */
  async function fetchData() {
    try {
      const res = await fetch('/data');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const data = await res.json();
      renderAll(data);
      fetchErrors();
    } catch (e) {
      ERRORS.push({ ts: Date.now(), type: 'fetch', msg: e.message });
      if (ERRORS.length > MAX_ERRORS) ERRORS.shift();
      updateErrorDisplay();
    }
  }

  window.pcmonDebug = {
    errors: ERRORS,
    fetch: fetchData,
    fetchErrors,
    config: { refreshRate: refreshInterval, url: '' }
  };

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
        // Redraw sparklines on tab switch (canvas sizing)
        setTimeout(() => {
          refreshSparklines(history.cpu.slice(-1)[0] || 0, history.ram.slice(-1)[0] || 0, history.disk.slice(-1)[0] || 0);
        }, 50);
      });
    });
  }

  /* ── Refresh selector ────────────────────────────────────────────── */
  function initRefreshSelector() {
    const sel = EL('rf-sel');
    if (!sel) return;
    sel.addEventListener('change', () => {
      refreshInterval = parseInt(sel.value, 10) || 2000;
      clearInterval(intervalId);
      intervalId = setInterval(fetchData, refreshInterval);
    });
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
    try {
      const res = await fetch('/api/snapshots');
      if (!res.ok) return;
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
    } catch {}
  }

  async function saveSnapshot() {
    const labelInput = EL('snap-label');
    const msgEl = EL('snap-msg');
    const label = labelInput ? labelInput.value.trim() : '';
    try {
      const res = await fetch('/api/snapshots', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ label })
      });
      if (res.ok) {
        const result = await res.json();
        selectedSnapshotId = result.id;
        if (labelInput) labelInput.value = '';
        if (msgEl) { msgEl.textContent = 'Snapshot saved!'; setTimeout(() => { if (msgEl) msgEl.textContent = ''; }, 2000); }
        loadSnapshots();
      }
    } catch (e) {
      if (msgEl) msgEl.textContent = 'Error saving snapshot';
    }
  }

  async function compareSnapshot(id) {
    selectedSnapshotId = id;
    loadSnapshots();
    const resultEl = EL('compare-result');
    if (!resultEl) return;
    resultEl.innerHTML = '<div class="note">Comparing...</div>';
    try {
      const res = await fetch(`/api/snapshots/${id}/compare`, { method: 'POST' });
      if (!res.ok) throw new Error('Failed');
      const data = await res.json();
      if (data.error) {
        resultEl.innerHTML = `<div class="note" style="color:var(--bad)">${esc(data.error)}</div>`;
        return;
      }
      const changes = data.changes || [];
      if (changes.length === 0) {
        resultEl.innerHTML = '<div class="note">No changes detected.</div>';
        return;
      }
      let html = '<div class="compare-summary"><strong>Snapshot:</strong> ' + esc(data.snapshot_ts) + ' → <strong>Now:</strong> ' + esc(data.current_ts) + '</div>';
      changes.forEach(c => {
        const diff = c.diff > 0 ? '+' + c.diff : c.diff;
        const color = c.direction === 'increased' || c.direction === 'new' ? 'var(--bad)' : c.direction === 'decreased' || c.direction === 'gone' ? 'var(--ok)' : 'var(--accent)';
        let extra = '';
        if (c.processes) {
          extra = '<div class="compare-procs">' + c.processes.slice(0,5).map(p => `<span>${esc(p.name)} (${fmtMem(p.ws_mb * 1024)})</span>`).join('') + (c.count > 5 ? `<span>+${c.count-5} more</span>` : '') + '</div>';
        }
        html += `<div class="compare-item"><span class="compare-name">${esc(c.name)}</span><span class="compare-diff" style="color:${color}">${diff}${c.old !== undefined ? ' (' + c.old + '→' + c.new + '%)' : ''}</span>${extra}</div>`;
      });
      resultEl.innerHTML = html;
    } catch (e) {
      resultEl.innerHTML = '<div class="note" style="color:var(--bad)">Error comparing snapshot</div>';
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
  function start() {
    initTabs();
    initRefreshSelector();
    initSearchFilters();
    initSnapshots();
    fetchData();
    intervalId = setInterval(fetchData, refreshInterval);
  }

  document.readyState === 'loading'
    ? document.addEventListener('DOMContentLoaded', start)
    : start();

})();
