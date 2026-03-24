/* === MODULE: utils =============================================== */

/* ── DOM Helpers ──────────────────────────────────────────────────── */
const EL = id => document.getElementById(id);
const TXT = (el, v) => { if (el) el.textContent = v; };
const PCT = (el, v) => { if (el) el.style.width = Math.min(100, Math.max(0, v)) + '%'; };

/* ── Escape ──────────────────────────────────────────────────────── */
function esc(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

/* ── Status ──────────────────────────────────────────────────────── */
function statusClass(v) {
  if (v < 50) return 'ok';
  if (v < 80) return 'warn';
  return 'bad';
}

function COL(el, val) {
  if (!el) return;
  el.classList.remove('ok', 'warn', 'bad');
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
  el.classList.remove('ok', 'warn', 'bad');
  el.classList.add(statusClass(val));
}

function FILL(el, val) {
  if (!el) return;
  PCT(el, val);
  el.classList.remove('ok', 'warn', 'bad');
  el.classList.add(statusClass(val));
}

/* ── Formatting ─────────────────────────────────────────────────── */
function fmtNum(n, dec = 2) {
  if (n === null || n === undefined || isNaN(n) || !isFinite(n)) return '—';
  return n.toFixed(dec);
}

function fmtMem(mb) {
  if (mb === null || mb === undefined || isNaN(mb) || !isFinite(mb)) return '—';
  if (mb >= 1024) return (mb / 1024).toFixed(1) + ' GB';
  return mb.toFixed(0) + ' MB';
}

function getTrend(current, previous) {
  if (current == null || previous == null) return '';
  const diff = current - previous;
  if (diff > 0) return '↑' + diff.toFixed(1);
  if (diff < 0) return '↓' + Math.abs(diff).toFixed(1);
  return '→';
}

/* ── Skeleton ────────────────────────────────────────────────────── */
function showSkeleton(skId, tableId) {
  const sk = EL(skId);
  const tbl = EL(tableId);
  if (sk) sk.style.display = '';
  if (tbl) tbl.style.display = 'none';
}

function hideSkeleton(skId, tableId) {
  const sk = EL(skId);
  const tbl = EL(tableId);
  if (sk) sk.style.display = 'none';
  if (tbl) tbl.style.display = '';
}

function unloadCard(cardEl) {
  if (cardEl) cardEl.classList.remove('loading');
}

function showCardLoading(cardEl) {
  if (cardEl && !cardEl.classList.contains('loading')) cardEl.classList.add('loading');
}

function showAllSkeletons() {
  const cardIds = ['sc-ram', 'sc-cpu', 'sc-disk', 'sc-cm', 'r-sc-ram', 'r-sc-cm', 'r-sc-pg', 'c-sc-cpu', 'c-sc-pg'];
  cardIds.forEach(id => { const el = EL(id); if (el) el.classList.add('loading'); });
  const skPairs = [
    ['ov-tbl-sk', 'ov-tbl'], ['r-tbl-sk', 'r-tbl'], ['c-tbl-sk', 'c-tbl'],
    ['sus-tbl-sk', 'sus-tbl'], ['svc-tbl-sk', 'svc-tbl'],
    ['startup-tbl-sk', 'startup-tbl'], ['pagefile-tbl-sk', 'pagefile-tbl'],
    ['profiles-tbl-sk', 'profiles-tbl'], ['net-tbl-sk', 'net-tbl'], ['all-tbl-sk', 'all-tbl'],
    ['ov-disks-sk', 'ov-disks'], ['disk-drives-sk', 'disk-drives'],
    ['disk-io-sk', 'disk-io-strip'], ['ov-io-sk', 'ov-io'],
    ['gpu-adapters-sk', 'gpu-adapters'], ['group-insights-sk', 'group-insights'],
    ['sys-summary-sk', 'sys-summary'],
    ['dbg-mem-sk', 'dbg-mem'], ['dbg-timeline-sk', 'dbg-timeline'],
    ['dbg-sys-metrics-sk', 'dbg-sys-metrics'], ['dbg-cache-sk', 'dbg-cache']
  ];
  skPairs.forEach(([skId, tblId]) => showSkeleton(skId, tblId));
}

function hideAllSkeletons() {
  const cardIds = ['sc-ram', 'sc-cpu', 'sc-disk', 'sc-cm', 'r-sc-ram', 'r-sc-cm', 'r-sc-pg', 'c-sc-cpu', 'c-sc-pg'];
  cardIds.forEach(id => { const el = EL(id); if (el) el.classList.remove('loading'); });
}

/* ── Sparklines ───────────────────────────────────────────────────── */
function hexOrVarToAlpha(color, alpha) {
  if (color.startsWith('#')) {
    let hex = color.slice(1);
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    const r = parseInt(hex.slice(0, 2), 16);
    const g = parseInt(hex.slice(2, 4), 16);
    const b = parseInt(hex.slice(4, 6), 16);
    return `rgba(${r},${g},${b},${alpha})`;
  }
  if (color.startsWith('rgb(')) return color.replace(/\)$/, `,${alpha})`).replace('rgb(', 'rgba(');
  return `rgba(0,245,176,${alpha})`;
}

function sparkColorVar(cls) {
  if (cls === 'ok') return '--ok';
  if (cls === 'warn') return '--warn';
  if (cls === 'bad') return '--bad';
  return '--info';
}

function updateHistory(type, value) {
  if (typeof value !== 'number' || isNaN(value) || !isFinite(value)) return;
  PCM.history[type].push(value);
  if (PCM.history[type].length > PCM.HISTORY_SIZE) PCM.history[type].shift();
}

function drawSparkline(canvasId, values, colorVar, opts = {}) {
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
  const min = Math.min(...validValues);
  const range = max - min || 1;
  const step = validValues.length > 1 ? W / (validValues.length - 1) : W;
  const style = getComputedStyle(document.documentElement);
  const color = style.getPropertyValue(colorVar).trim() || '#00f5b0';

  // Grid lines
  ctx.strokeStyle = hexOrVarToAlpha('#ffffff', 0.08);
  ctx.lineWidth = 1;
  ctx.setLineDash([2, 4]);
  for (let g = 0; g <= 4; g++) {
    const y = Math.round((g / 4) * (H - 4)) + 2;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(W, y);
    ctx.stroke();
  }
  ctx.setLineDash([]);

  // Threshold line (if provided)
  if (opts.threshold) {
    const threshY = H - (opts.threshold / max) * (H - 4) - 2;
    ctx.strokeStyle = opts.threshColor || '#ff6b6b';
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.moveTo(0, threshY);
    ctx.lineTo(W, threshY);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // Points
  const pts = validValues.map((v, i) => ({
    x: i * step,
    y: H - (v / max) * (H - 4) - 2
  }));

  // Smooth bezier curve
  ctx.beginPath();
  if (pts.length > 2) {
    ctx.moveTo(pts[0].x, pts[0].y);
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = pts[Math.max(0, i - 1)];
      const p1 = pts[i];
      const p2 = pts[i + 1];
      const p3 = pts[Math.min(pts.length - 1, i + 2)];
      const cp1x = p1.x + (p2.x - p0.x) / 6;
      const cp1y = p1.y + (p2.y - p0.y) / 6;
      const cp2x = p2.x - (p3.x - p1.x) / 6;
      const cp2y = p2.y - (p3.y - p1.y) / 6;
      ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, p2.x, p2.y);
    }
  } else {
    ctx.moveTo(pts[0].x, pts[0].y);
    ctx.lineTo(pts[1].x, pts[1].y);
  }

  // Gradient fill
  const lastX = (validValues.length - 1) * step;
  const grad = ctx.createLinearGradient(0, 0, 0, H);
  grad.addColorStop(0, hexOrVarToAlpha(color, 0.5));
  grad.addColorStop(0.5, hexOrVarToAlpha(color, 0.15));
  grad.addColorStop(1, hexOrVarToAlpha(color, 0.02));
  ctx.lineTo(lastX, H);
  ctx.lineTo(pts[0].x, H);
  ctx.closePath();
  ctx.fillStyle = grad;
  ctx.fill();

  // Glow line
  ctx.shadowColor = color;
  ctx.shadowBlur = 12;
  ctx.strokeStyle = color;
  ctx.lineWidth = 2.5;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.stroke();
  ctx.shadowBlur = 0;

  // Animated pulse dot (current value)
  const lastPt = pts[pts.length - 1];
  const now = Date.now();
  const pulse = Math.sin(now / 300) * 0.3 + 0.7;
  
  // Outer glow
  ctx.beginPath();
  ctx.arc(lastPt.x, lastPt.y, 6, 0, Math.PI * 2);
  ctx.fillStyle = hexOrVarToAlpha(color, pulse * 0.3);
  ctx.fill();
  
  // Inner dot
  ctx.beginPath();
  ctx.arc(lastPt.x, lastPt.y, 4, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.shadowColor = color;
  ctx.shadowBlur = 15;
  ctx.fill();
  ctx.shadowBlur = 0;

  // Min/Max labels
  if (opts.showMinMax !== false) {
    ctx.font = '9px system-ui, sans-serif';
    ctx.fillStyle = hexOrVarToAlpha('#ffffff', 0.5);
    ctx.textAlign = 'right';
    ctx.fillText(max.toFixed(0), W - 3, 10);
    ctx.fillText(min.toFixed(0), W - 3, H - 2);
  }

  // Store for animation
  canvas._lastDraw = now;
}

function refreshSparklines(cpuPct, ramPct, diskPct) {
  drawSparkline('spk-ram', PCM.history.ram, sparkColorVar(statusClass(ramPct)));
  drawSparkline('spk-cpu', PCM.history.cpu, sparkColorVar(statusClass(cpuPct)));
  drawSparkline('spk-cpu2', PCM.history.cpu, sparkColorVar(statusClass(cpuPct)));
  drawSparkline('spk-disk', PCM.history.disk, sparkColorVar(statusClass(diskPct)));
  drawSparkline('disk-spk', PCM.history.disk, '--info');
  drawSparkline('net-spk', PCM.history.net, '--ok');
  drawSparkline('spk-cm', PCM.history.commit, sparkColorVar(statusClass(PCM.history.commit.slice(-1)[0] || 0)));
}

/* ── Fast update handler ─────────────────────────────────────────── */
function handleFastUpdate(data) {
  if (!data._fast) return;

  if (PCM.cachedData) {
    PCM.cachedData.ram_pct = data.ram_pct;
    PCM.cachedData.ram_avail_mb = data.ram_avail_mb;
    PCM.cachedData.commit_pct = data.commit_pct;
    PCM.cachedData.cpu_pct = data.cpu_pct;
    PCM.cachedData.disk_pct = data.disk_pct;
  }

  const ramPct = data.ram_pct || 0;
  const cpuPct = data.cpu_pct || 0;
  const diskPct = data.disk_pct || 0;
  const ramStatus = ramPct > PCM.thresholds.ram_pct ? 'bad' : ramPct > PCM.thresholds.ram_pct * 0.8 ? 'warn' : 'ok';
  const cpuStatus = cpuPct > PCM.thresholds.cpu_pct ? 'bad' : cpuPct > PCM.thresholds.cpu_pct * 0.8 ? 'warn' : 'ok';

  TXT(EL('sv-ram'), ramPct.toFixed(1) + '%');
  TXT(EL('ss-ram'), data.ram_avail_mb + ' MB avail');
  COL(EL('sf-ram'), ramPct);
  if (EL('sb-ram')) EL('sb-ram').textContent = ramPct > PCM.thresholds.ram_pct ? 'HIGH' : '';

  TXT(EL('sv-cpu'), cpuPct.toFixed(1) + '%');
  COL(EL('sf-cpu'), cpuPct);
  if (EL('sb-cpu')) EL('sb-cpu').textContent = cpuPct > PCM.thresholds.cpu_pct ? 'HIGH' : '';

  if (EL('sv-disk')) { TXT(EL('sv-disk'), diskPct.toFixed(1) + '%'); COL(EL('sf-disk'), diskPct); }

  if (EL('r-sv-ram')) { TXT(EL('r-sv-ram'), ramPct.toFixed(1) + '%'); TXT(EL('r-avail'), data.ram_avail_mb + ' MB'); COL(EL('r-sf-ram'), ramPct); }
  if (EL('c-sv-cpu')) { TXT(EL('c-sv-cpu'), cpuPct.toFixed(1) + '%'); COL(EL('c-sf-cpu'), cpuPct); }

  PCM.history.ram.push(ramPct);
  PCM.history.cpu.push(cpuPct);
  PCM.history.disk.push(diskPct);
  if (PCM.history.ram.length > PCM.HISTORY_SIZE) PCM.history.ram.shift();
  if (PCM.history.cpu.length > PCM.HISTORY_SIZE) PCM.history.cpu.shift();
  if (PCM.history.disk.length > PCM.HISTORY_SIZE) PCM.history.disk.shift();

  const now = Date.now();
  if (!handleFastUpdate._lastSparkline || now - handleFastUpdate._lastSparkline > 1000) {
    handleFastUpdate._lastSparkline = now;
    refreshSparklines(cpuPct, ramPct, diskPct);
  }

  if (EL('ts')) EL('ts').textContent = data.ts || '--:--:--';
  PCM.perfTimer = now;
  PCM.cachedData = PCM.cachedData || {};
  PCM.cachedData.ts = data.ts;
}
