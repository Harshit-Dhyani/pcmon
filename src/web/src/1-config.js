/* === MODULE: config ============================================= */
/* Shared state object — all modules write/read from here */
const PCM = {
  /* Config constants */
  HISTORY_SIZE: 40,
  TABLE_UPDATE_INTERVAL: 4000,
  DEFAULT_THRESHOLDS: { ram_pct: 85, cpu_pct: 90, commit_pct: 80, pages_sec: 1000, non_paged_mb: 1500, disk_pct: 90 },

  /* State */
  refreshInterval: 500,
  pollTimer: null,
  pollInFlight: false,
  firstLoad: true,
  lastTableUpdate: 0,
  thresholds: {},
  connectionMethod: 'unknown',
  eventSource: null,
  wsSocket: null,
  wsReconnectDelay: 1000,
  wsMaxReconnectDelay: 10000,
  resizeTimer: null,

  /* Data */
  cachedData: null,
  history: { ram: [], cpu: [], disk: [], net: [], commit: [] },
  prev: { ram: 0, cpu: 0, disk: 0, commit: 0 },

  /* Performance */
  perf: { fetchMs: 0, renderMs: 0, cycleMs: 0, fps: 0, fpsFrames: 0, fpsLast: 0 },
  perfTimer: 0,

  /* Errors */
  errors: []
};
PCM.thresholds = { ...PCM.DEFAULT_THRESHOLDS };
