# AGENTS.md

Rules for the `pcmon` workspace. Optimize for correctness, security, production readiness, and real diagnostic value.

## 1. Product Identity

- Official product name: `pcmon`
- GitHub repository: `pcmon`
- CLI command: `pcmon`
- Version: v1.0

## 2. Core Principles

- **Local-first**: All data stays on the user's machine. No cloud, no telemetry.
- **PowerShell-first**: Native Windows access without external dependencies.
- **Diagnostic-focused**: Raw metrics with actionable interpretation, not pretty status displays.
- **Lightweight**: Plain HTML/CSS/JS dashboard. No heavy frameworks.
- **One core, multiple entry modes**: Direct `.ps1` execution, optional CLI package.
- **Truth-driven**: Prefer honest unsupported/stale/error states over fake zeros or pretty lies.
- **Trustworthy UX**: The dashboard must explain what is wrong now, not just dump counters.
- **Stable first**: Entity lists and critical sections must remain stable across transient collector misses.

## 2.1 Improvement Mission

When asked to improve `pcmon`, default to a combined pass across:
- bug fixes
- data quality
- observability and health clarity
- UX/status clarity
- high-value feature expansion

Do discovery first.
Treat file paths as hints, not certainties.
Use minimal safe diffs where possible.
Do not fake metrics.
Do not label unsupported metrics as working.
Do not silently hide broken collectors.
Do not claim something is "real-time" unless the refresh path actually behaves that way.

## 3. Current Features (v1.0)

### Dashboard Tabs
- **Overview** — RAM, commit, CPU, disk at a glance with sparklines
- **RAM** — paged/non-paged pool, private memory breakdown
- **CPU** — CPU utilization, queue, paging activity
- **Disk** — disk activity, drives with usage bars
- **GPU** — adapter info, utilization, memory (if available)
- **Groups** — Browser/Electron, Dev Tools, Security tools memory
- **Suspicious** — high-resource processes detection
- **Services** — heavy services and startup items
- **System** — drives, page file, PowerShell profiles
- **All Processes** — full process list with filtering
- **Settings** — configurable alert thresholds

### Process Actions
- Kill (with confirmation), Suspend, Resume
- Protected system processes blocked

### Snapshots & Reports
- Save/compare snapshots, export JSON/CSV
- Printable HTML reports

### Insights
- High RAM vs commit pressure, paging detection, non-paged pool (driver leaks), browser/Electron overhead, disk bottlenecks
- Current-bottleneck and issue surfacing should remain a first-class outcome of changes

### Run Modes
- Direct: `.\pcmon.ps1`
- API-only: `-NoOpen` or `-ApiOnly`
- Debug: `-Debug` (enables verbose logging)
- Custom port: `-Port 8080`
- Tray: `-Tray`
- Wallpaper: `-Wallpaper`

## 4. What NOT to Add

- **No React/Vue/Angular** — Plain HTML/CSS/JS only
- **No Tauri/Electron** — Local-first means local web view, not packaged desktop apps
- **No heavy dependencies** — Keep the core lightweight
- **No cloud/telemetry** — Local-first by design
- **No generic web app patterns** — This is a diagnostics tool, not a SaaS product

## 5. Security Requirements

- Validate all inputs at API boundaries
- Treat process IDs, file paths, query params as untrusted
- Never expose secrets, tokens, or machine-specific paths
- Never use `shell: true` or shell-string execution
- Prevent path traversal in snapshot/export/compare flows
- Block dangerous process actions on protected system processes
- Require confirmation header (`X-PCMON-Confirm: 1`) for process kill/suspend/resume
- Validate HTTP method (GET/POST) on all endpoints
- Escape all user data in innerHTML (use `esc()` function)
- Validate numeric types for threshold configs
- Use try-catch around all file operations
- Handle null/undefined values explicitly
- Do not weaken security to make a collector or UI path "work"

## 6. Code Quality Standards

- Keep changes small, checkable, reversible
- Preserve working behavior unless explicitly changing it
- Prefer one source of truth per concern
- Fix root causes, not symptoms
- Add short intent comments for non-trivial functions
- Keep README and runtime behavior aligned
- Verify changes before claiming completion
- **Never use undefined variables** - declare before use
- **Never duplicate variable declarations** - results in overwrites
- **Never use non-existent helper functions** - will cause runtime errors
- **Always add error handling** around file I/O, external processes, HTTP listeners
- **Always validate endpoint matches** before processing requests
- **Never assume JSON serialization depth is sufficient** - use `-Depth 20` for complex objects
- **Never publish partial data as full payload** - keep last known heavy/static data until a fresh replacement exists
- **Never clear arrays/objects just because an expensive cycle was skipped** - skipped collection must preserve prior good values
- **Never block server startup on heavy collection** - listener and `/health` must come up before slow cache warmup
- **Never treat fast-stream packets as full dashboard payloads** - `_fast` updates may only touch fields they actually contain
- **Never edit generated build output as the source of truth** - fix `src/backend/*` and `src/web/*`, then rebuild
- **Always distinguish valid zero vs missing vs unsupported vs stale** - they are not interchangeable
- **Always preserve last known good entity data when a collector transiently misses** - do not wipe drives, groups, services, startup items, or adapters
- **Always prefer boring correctness over flashy additions** - diagnostics first, cosmetics second

## 6.1 Metric Truthfulness Rules

For every suspicious metric, classify it as one of:
- valid
- broken
- missing
- unsupported
- stale
- transiently unavailable

Rules:
- A true zero is acceptable only when the collector is known-good for that metric on that cycle.
- Unsupported metrics must be labeled clearly in the UI.
- Missing or transient values must not be silently rendered as `0`.
- Stale data must be surfaced as stale.
- If a collector is flaky, fix the collector or the merge logic. Do not hide the problem with formatting alone.

## 7. Architecture Rules

### Source File Structure
- **Backend**: `src/backend/*.ps1` — source modules, committed to git
  - `00-config.ps1` — params, setup, constants, protected processes, thresholds, config loading
  - `01-logging.ps1` — Write-Log, Write-Err
  - `02-http-helpers.ps1` — Send-Response (JSON/binary response helper)
  - `03-actions.ps1` — Stop-ProcessById, Suspend-ProcessById, Resume-ProcessById
  - `04-snapshots.ps1` — Get-SnapshotFiles, Save-Snapshot, Compare-Snapshots
  - `05-collectors.ps1` — Get-CachedStaticData, Get-CachedCommandLines, Get-LiveData
  - `06-background.ps1` — background collection script content (here-string, used by server)
  - `07-server.ps1` — HTTP server, routes, report HTML, background startup, tray, wallpaper
  - `main.ps1` — thin entry point (dot-sources all modules)
- **Frontend**: `src/web/src/*.js` — modular JS split by responsibility (number prefix controls load order)
  - `1-config.js` — global state (PCM)
  - `2-utils.js` — utilities, sparklines, formatting
  - `3-stream.js` — WS/SSE/HTTP streaming
  - `4-api.js` — REST API client
  - `5-render.js` — main render engine
- **Build output** (generated, committed to root):
  - `pcmon.ps1` — built from `src/backend/` (concatenated modules, region markers stripped)
  - `dist/index.html` — built from `src/web/` (CSS+JS inlined)

### Build System
- `src/build.ps1` handles both frontend and backend builds
- `.\src\build.ps1` — full build (frontend + backend)
- `.\src\build.ps1 -FrontendOnly` — frontend only
- `.\src\build.ps1 -BackendOnly` — backend only
- `.\src\build.ps1 -Watch` — watch mode for frontend JS
- Region markers (`#region ... #endregion`) are stripped during build
- BOM is removed from each source file
- Build validates no duplicate function definitions

### Module Conventions
- Each backend source module uses `#region --- Name --- ... #endregion`
- `03-actions.ps1` and `06-background.ps1` have no region markers (plain content)
- Modules with `#region` must have matching `#endregion` at end of file
- Variable declarations (e.g., `$script:refreshRateFile`) must appear before use across modules
- Build uses `-replace '(?m)^\s*#\s*endregion\s*(\r?\n)', '$1'` to strip region markers

### Real-Time Streaming (`/stream`)
- WebSocket via `AcceptWebSocketAsync` (try first)
- SSE as fallback with text/event-stream
- HTTP polling as last resort
- Fast metrics timer (50ms) broadcasts lightweight data (RAM, CPU, commit, disk)
- WebSocket broadcast timer sends full data every ~50ms
- Fast packets are summary-only and must never overwrite tables, groups, startup items, services, or process inventories
- Full payloads must include stable `top_ram`, `top_private`, `top_cpu`, `all_processes`, `startup`, `heavy_services`, `groups`, `disks`, and `pagefile` fields
- Frontend renderers must preserve prior full-data sections when processing `_fast` packets
- Refresh controls must map honestly to actual update cadence
- "Watch" behavior, live mode, and polling/stream state must be verified end-to-end, not assumed from UI labels

## 8. Data Flow Architecture

### Background Collection Process
- Separate pwsh/powershell process for continuous data collection
- Writes to temp JSON file every cycle
- Falls back to main process if background fails
- Respects configurable refresh rate from file
- Keeps last known heavy/static collections in memory between cycles
- First successful cycle must populate process/group/startup/static tables before publishing them
- Heavy/static intervals must scale from configured refresh rate rather than being hard-coded assumptions
- Counter lookup must tolerate host-qualified and case-variant Windows counter paths
- Drive, GPU, service, startup, and profile identity must be stable across cycles
- Transient collector misses must not cause flicker/disappearance for stable entities

### Main Server Process
- HttpListener for HTTP server
- Reads cached data from file for `/data` endpoint
- Falls back to synchronous collection if cache unavailable
- Handles all API endpoints (snapshots, process actions, config)
- `/health` must stay cheap and independent from heavy collectors
- `/data` should return last good cache instead of blocking on a full recollect when possible
- Temp/cache/log/refresh files must be isolated per port so multiple instances do not corrupt each other
- Overview/API responses must surface stale or degraded collection state when relevant

### Refresh Rate System
- UI sends refresh rate to `/api/refresh-rate` (min 1000ms)
- Backend saves to temp file
- Background process reads rate file each cycle
- Sync fallback respects same minimum

## 9. Common Bugs to Avoid

### Variable Issues
- Never reference variables before declaration
- Never declare same variable twice (last wins)
- Remove unused variable declarations

### Null/Undefined Handling
- Always check `$null` before accessing properties
- Use `[DateTime]::MinValue` for cache expiry sentinel values
- Handle empty collections explicitly (use `@()` to ensure array)

### Background Process
- Pass file paths as arguments, not inline
- Use proper quoting for paths with spaces
- Add error handling for Start-Process failures
- Graceful degradation if background process unavailable
- **Use -File parameter with separate array arguments** - not -Command with string
- **Handle file lock conflicts** - use retry loop with `[System.IO.File]::Open()` exclusive mode
- **Do not emit zero/empty process tables on non-heavy cycles** - reuse previous heavy snapshot
- **Do not refresh startup/pagefile/profile data every fast cycle** - cache them on static intervals
- **Do not assume `Get-Counter` paths match exact casing or hostname-free formats** - use pattern-based matching
- **Do not let first-run partial data overwrite valid cached data** - first publish must be internally consistent

### HTTP Server
- Wrap `GetContext()` in try-catch
- Validate HTTP method before processing
- **Always wrap OutputStream.Write in try-catch** - client disconnects cause "network name no longer available"
- Handle malformed requests gracefully
- Keep startup work outside the request loop, but do not block listener start on expensive precomputation
- Distinguish fast summary responses from full data responses explicitly
- Do not let a slow `/data` path starve `/health`

### JSON Serialization
- **Use -Depth 20** for objects with nested structures (processes, GPU, disks)
- **Never use Depth 5** - it truncates nested data and causes "JSON truncated" warnings

### Frontend State
- Treat `PCM.cachedData` as the last known full payload, not as a mirror of every incoming packet
- `_fast` handlers may update only summary cards, trends, timestamps, and sparkline history
- Table renderers must not replace populated tables with empty placeholders unless the backend explicitly reports an empty full payload
- SSE/WS fast updates must not zero out group counts or process counts just because those fields are absent
- Empty-state UI must distinguish: loading, empty, unsupported, error, stale
- Drive cards, adapter cards, and key tables must use stable identity and sane retention to avoid flicker
- Overview must surface "what is wrong right now?" clearly and honestly

### Feature Direction
High-value expansions are encouraged when they are trustworthy and local-only:
- deeper CPU insight: model, sockets/cores/logical processors, base clock, live MHz, session max MHz, temperature if accessible, max observed temperature, package power if accessible, peak observed power, bottleneck interpretation
- better RAM insight: total/used/available, commit, pages/sec, hard-fault-adjacent signals if trustworthy, paged/non-paged pool, compressed memory if accessible, pressure state
- better disk insight: stable drives, read/write throughput, queue, active time, busiest drive, bottleneck interpretation
- better GPU insight: adapter identity, utilization, engine breakdown, VRAM, unsupported-state honesty
- better network insight: throughput, busiest adapter, adapter identity, Wi-Fi/Ethernet distinction if available, bottleneck interpretation

Do not invent hardware-only metrics that Windows/PowerShell cannot reliably provide.
If a ThrottleStop-like metric is only partially feasible, expose it with clear limits.

### Build Discipline
- If you change backend behavior, update `src/backend/*` and rebuild `pcmon.ps1`
- If you change frontend behavior, update `src/web/*` and rebuild `dist/index.html`
- Do not leave source and generated output out of sync
- Do not claim a fix landed until the generated artifacts used by runtime were rebuilt

### Caching
- Define cache file path before functions that use it
- Use single source of truth for shared paths
- Check file exists before read operations

## 10. Debug Mode

- Use `-Debug` flag to enable verbose logging
- Debug mode shows background collection timing
- Debug mode shows client disconnect errors gracefully

## 11. Verification Checklist

Before claiming completion:
- [ ] Script starts without errors
- [ ] `/health` responds quickly before heavy collection finishes
- [ ] Dashboard loads in browser
- [ ] Data endpoint returns valid JSON
- [ ] `total_procs`, `all_processes`, `top_ram`, `startup`, and `groups` stay populated across multiple refresh cycles
- [ ] Fast SSE/WS updates do not clear tables or group cards
- [ ] Drive list does not flicker or disappear across multiple cycles
- [ ] Refresh selector matches real data freshness for supported intervals
- [ ] Watch/live behavior works correctly and matches UI state
- [ ] Paged/non-paged pool do not falsely flicker to zero
- [ ] Pages/sec is handled honestly
- [ ] GPU/network values are either correct or clearly marked unsupported/unavailable
- [ ] Empty sections show the correct empty/unsupported/error/stale state
- [ ] Overview surfaces likely bottlenecks and current system issues clearly
- [ ] New CPU/system metrics are verified or clearly labeled with limitations
- [ ] All tabs render without errors
- [ ] Process actions work (kill/suspend/resume)
- [ ] Snapshot save/compare/export works
- [ ] Settings (thresholds) persist
- [ ] No 404 errors in browser console
- [ ] No unhandled exceptions in PowerShell
- [ ] Memory stable over extended use

## 12. Non-Negotiables

- Never commit secrets, tokens, or debug credentials
- Never fake metrics or verification
- Never bypass failures by hiding errors
- Never mark work done without evidence
- Never leave stale product naming
