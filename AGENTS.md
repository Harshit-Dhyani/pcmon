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

### Run Modes
- Direct: `.\pcmon.ps1`
- API-only: `-NoOpen` or `-ApiOnly`
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
- Require confirmation for process kill/suspend/resume
- XSS protection in dashboard

## 6. Code Quality Standards

- Keep changes small, checkable, reversible
- Preserve working behavior unless explicitly changing it
- Prefer one source of truth per concern
- Fix root causes, not symptoms
- Add short intent comments for non-trivial functions
- Keep README and runtime behavior aligned
- Verify changes before claiming completion

## 7. Architecture Rules

- PowerShell core for data collection
- Local HTTP server for dashboard
- Plain HTML/CSS/JS for UI
- Separate concerns: data collection, action handling, HTTP/API, dashboard UI
- Do not merge unrelated concerns into one file

## 8. Verification Before Done

- Local script still starts
- Dashboard loads correctly
- Data endpoint works
- Changed tabs/views render without breakage
- Action endpoints behave as expected
- Snapshot/compare/export flows work if touched

## 9. Non-Negotiables

- Never commit secrets, tokens, or debug credentials
- Never fake metrics or verification
- Never bypass failures by hiding errors
- Never mark work done without evidence
- Never leave stale product naming
