/* === MODULE: stream ================================================ */

/* ── WebSocket ────────────────────────────────────────────────────── */
function tryWebSocket() {
  if (PCM.wsSocket) { PCM.wsSocket.close(); PCM.wsSocket = null; }
  try {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    PCM.wsSocket = new WebSocket(protocol + '//' + window.location.host + '/stream');
    PCM.wsSocket.onopen = () => {
      PCM.connectionMethod = 'websocket';
      PCM.wsReconnectDelay = 1000;
      if (PCM.eventSource) { PCM.eventSource.close(); PCM.eventSource = null; }
      if (PCM.pollTimer) { clearTimeout(PCM.pollTimer); PCM.pollTimer = null; }
      PCM.pollInFlight = false;
      updateSettingsConnInfo();
    };
    PCM.wsSocket.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data._fast) {
          handleFastUpdate(data);
        } else {
          const renderStart = performance.now();
          renderAll(data);
          PCM.perf.renderMs = performance.now() - renderStart;
          PCM.perf.cycleMs = PCM.perf.renderMs;
          PCM.perfTimer = Date.now();
          PCM.pollInFlight = false;
          PCM.cachedData = data;
          updateDebugPanel(data);
          updateSettingsConnInfo();
        }
      } catch (e) {}
    };
    PCM.wsSocket.onerror = () => { PCM.connectionMethod = 'sse'; trySSE(); };
    PCM.wsSocket.onclose = () => {
      if (PCM.connectionMethod === 'websocket') { PCM.connectionMethod = 'sse'; trySSE(); }
    };
  } catch (e) { PCM.connectionMethod = 'sse'; trySSE(); }
}

/* ── SSE ──────────────────────────────────────────────────────────── */
function trySSE() {
  if (PCM.eventSource) { PCM.eventSource.close(); PCM.eventSource = null; }
  if (PCM.wsSocket) { PCM.wsSocket.close(); PCM.wsSocket = null; }
  try {
    PCM.eventSource = new EventSource('/stream');
    PCM.eventSource.onopen = () => {
      PCM.connectionMethod = 'sse';
      PCM.wsReconnectDelay = 1000;
      if (PCM.pollTimer) { clearTimeout(PCM.pollTimer); PCM.pollTimer = null; }
      PCM.pollInFlight = false;
      updateSettingsConnInfo();
    };
    PCM.eventSource.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        if (data._fast) {
          handleFastUpdate(data);
        } else {
          const renderStart = performance.now();
          renderAll(data);
          PCM.perf.renderMs = performance.now() - renderStart;
          PCM.perf.cycleMs = PCM.perf.renderMs;
          PCM.perfTimer = Date.now();
          PCM.pollInFlight = false;
          PCM.cachedData = data;
          updateDebugPanel(data);
          updateSettingsConnInfo();
        }
      } catch (e) {}
    };
    PCM.eventSource.onerror = () => {
      PCM.connectionMethod = 'http';
      PCM.eventSource.close();
      PCM.eventSource = null;
      PCM.wsReconnectDelay = Math.min(PCM.wsReconnectDelay * 1.5, PCM.wsMaxReconnectDelay);
      startHTTPPolling();
    };
  } catch (e) { PCM.connectionMethod = 'http'; startHTTPPolling(); }
}

function initStream() { tryWebSocket(); }

function startHTTPPolling() {
  if (PCM.pollTimer) return;
  PCM.connectionMethod = 'http';
  fetchData();
}
