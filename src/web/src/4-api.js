/* === MODULE: api ================================================== */

/* ── Auth ─────────────────────────────────────────────────────────── */
function authHeaders(extra = {}) {
  const h = { 'Content-Type': 'application/json' };
  if (PCM.csrfToken) h['X-PCMON-Token'] = PCM.csrfToken;
  Object.assign(h, extra);
  return h;
}

/* ── Schedule ─────────────────────────────────────────────────────── */
function scheduleNextFetch(delay = PCM.refreshInterval) {
  clearTimeout(PCM.pollTimer);
  PCM.pollTimer = setTimeout(fetchData, Math.max(500, delay));
}

/* ── Fetch ────────────────────────────────────────────────────────── */
async function fetchData() {
  if (PCM.pollInFlight && PCM.connectionMethod === 'http') return;
  if (PCM.connectionMethod === 'http') PCM.pollInFlight = true;
  const t0 = performance.now();
  try {
    // Live data must bypass browser caches or the refresh selector becomes dishonest.
    const res = await fetch('/data', { cache: 'no-store' });
    PCM.perf.fetchMs = performance.now() - t0;
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    if (PCM.connectionMethod !== 'websocket' && PCM.connectionMethod !== 'sse') {
      const renderStart = performance.now();
      renderAll(data);
      PCM.perf.renderMs = performance.now() - renderStart;
      PCM.perf.cycleMs = performance.now() - t0;
      PCM.perfTimer = Date.now();
      PCM.pollInFlight = false;
      PCM.cachedData = data;
      updateDebugPanel(data);
      updateSettingsConnInfo();
    }
    if (PCM.connectionMethod === 'http') scheduleNextFetch();
  } catch (e) {
    PCM.perf.fetchMs = performance.now() - t0;
    PCM.pollInFlight = false;
    if (PCM.connectionMethod === 'http') scheduleNextFetch();
  }
}

/* ── Bootstrap ────────────────────────────────────────────────────── */
async function loadBootstrap() {
  try {
    // Bootstrap pulls both the first live sample and thresholds together so the
    // first render already has real data plus alert configuration.
    const [dataRes, configRes] = await Promise.all([
      fetch('/data', { cache: 'no-store' }),
      fetch('/api/config', { cache: 'no-store' })
    ]);
    const data = await dataRes.json();
    const config = await configRes.json();
    PCM.thresholds = { ...PCM.DEFAULT_THRESHOLDS, ...(config.thresholds || {}) };
    PCM.cachedData = data;
    PCM.perfTimer = Date.now();
    PCM.firstLoad = false;
    renderAll(data);
    updateDebugPanel(data);
  } catch (e) {}
}

/* ── Process Actions ──────────────────────────────────────────────── */
async function killProcess(pid, name) {
  if (!confirm('Kill process "' + name + '" (PID: ' + pid + ')?')) return;
  try {
    const res = await fetch('/api/process/' + pid + '/kill', {
      method: 'POST',
      headers: authHeaders({ 'X-PCMON-Confirm': '1' })
    });
    const data = await res.json();
    if (data.success) { alert('Process terminated: ' + data.message); fetchData(); }
    else { alert('Failed: ' + data.error); }
  } catch (e) { alert('Error: ' + e.message); }
}

async function suspendProcess(pid, name) {
  if (!confirm('Suspend process "' + name + '" (PID: ' + pid + ')?')) return;
  try {
    const res = await fetch('/api/process/' + pid + '/suspend', {
      method: 'POST',
      headers: authHeaders({ 'X-PCMON-Confirm': '1' })
    });
    const data = await res.json();
    if (data.success) { alert('Process suspended: ' + data.message); }
    else { alert('Failed: ' + data.error); }
  } catch (e) { alert('Error: ' + e.message); }
}

async function resumeProcess(pid, name) {
  if (!confirm('Resume process "' + name + '" (PID: ' + pid + ')?')) return;
  try {
    const res = await fetch('/api/process/' + pid + '/resume', {
      method: 'POST',
      headers: authHeaders({ 'X-PCMON-Confirm': '1' })
    });
    const data = await res.json();
    if (data.success) { alert('Process resumed: ' + data.message); }
    else { alert('Failed: ' + data.error); }
  } catch (e) { alert('Error: ' + e.message); }
}

/* ── Config ───────────────────────────────────────────────────────── */
async function fetchConfig() {
  try {
    const res = await fetch('/api/config', { cache: 'no-store' });
    const data = await res.json();
    PCM.thresholds = { ...PCM.DEFAULT_THRESHOLDS, ...(data.thresholds || {}) };
  } catch (e) {}
}

async function saveConfig(cfg) {
  try {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify(cfg)
    });
    const data = await res.json();
    if (data.success) PCM.thresholds = { ...PCM.thresholds, ...cfg };
    return data.success;
  } catch (e) { return false; }
}

async function saveThresholds(thresholds) {
  try {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(thresholds)
    });
    const data = await res.json();
    if (data.success) PCM.thresholds = { ...PCM.thresholds, ...thresholds };
    return data.success;
  } catch (e) { return false; }
}

/* ── Snapshots ────────────────────────────────────────────────────── */
async function fetchSnapshots() {
  try {
    const res = await fetch('/api/snapshots', { cache: 'no-store' });
    return await res.json();
  } catch (e) { return []; }
}

async function deleteSnapshot(id) {
  try {
    await fetch('/api/snapshots/' + id + '/delete', { method: 'POST', headers: authHeaders() });
    renderSnapshots();
  } catch (e) {}
}

async function exportSnapshot(id, format) {
  window.open('/api/snapshots/' + id + '/export.' + format, '_blank');
}

async function compareSnapshots(id) {
  try {
    const res = await fetch('/api/snapshots/' + id + '/compare', {
      method: 'POST',
      headers: authHeaders()
    });
    return await res.json();
  } catch (e) { return { error: 'Network error' }; }
}

async function fetchReport() {
  try {
    const res = await fetch('/api/report', { cache: 'no-store' });
    return await res.text();
  } catch (e) { return '<p>Error loading report</p>'; }
}

async function fetchReportDownload() {
  try {
    const res = await fetch('/api/report/download');
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'pcmon-report.html';
    a.click();
    URL.revokeObjectURL(url);
  } catch (e) { alert('Download failed: ' + e.message); }
}

/* ── Errors ───────────────────────────────────────────────────────── */
async function fetchErrors() {
  try {
    const res = await fetch('/errors', { cache: 'no-store' });
    const data = await res.json();
    PCM.errors = data.errors || [];
    updateDebugPanel(PCM.cachedData);
  } catch (e) {}
}

/* ── Clipboard ───────────────────────────────────────────────────── */
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
  navigator.clipboard.writeText(text).then(() => alert('Copied to clipboard!')).catch(() => alert('Failed to copy'));
}
