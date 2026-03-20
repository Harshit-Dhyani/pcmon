# pcmon

[![CI](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/ci.yml/badge.svg)](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/ci.yml)
[![CodeQL](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/codeql.yml/badge.svg)](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/codeql.yml)
[![Release](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/release.yml/badge.svg)](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/release.yml)
[![Semantic Release](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/semantic-release.yml/badge.svg)](https://github.com/Harshit-Dhyani/pcmon/actions/workflows/semantic-release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![npm](https://img.shields.io/npm/dt/pcmon?label=npm)](https://www.npmjs.com/package/pcmon)
[![npm version](https://img.shields.io/npm/v/pcmon?label=npm)](https://www.npmjs.com/package/pcmon)
[![npm](https://img.shields.io/badge/bun-v1.0.0-brown.svg)](https://bun.sh)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://conventionalcommits.org)
[![GitHub Stars](https://img.shields.io/github/stars/Harshit-Dhyani/pcmon?style=flat)](https://github.com/Harshit-Dhyani/pcmon/stargazers)
[![GitHub Forks](https://img.shields.io/github/forks/Harshit-Dhyani/pcmon?style=flat)](https://github.com/Harshit-Dhyani/pcmon/network/members)

Local-first Windows system monitoring and diagnostics tool.

## Quick start

```powershell
.\pcmon.ps1
```

Or with PowerShell Core:

```powershell
pwsh -File .\pcmon.ps1
```

## Usage

```powershell
.\pcmon.ps1             # defaults: opens browser, 2s refresh
.\pcmon.ps1 -NoOpen      # API-only mode, no browser auto-open
.\pcmon.ps1 -ApiOnly     # same as -NoOpen
.\pcmon.ps1 -Port 8080   # custom port
.\pcmon.ps1 -Help        # show all options
```

## Requirements

- Windows with PowerShell 5.1+ or PowerShell Core (pwsh)
- Performance counters require admin privileges for full accuracy
- Web browser for the dashboard

## File layout

```
pcmon/           -- root
  pcmon.ps1      -- main entry point; HTTP server + data collection
  web/
    index.html   -- dashboard HTML (served from disk)
    dashboard.js -- dashboard UI logic (served from disk)
  bin/
    pcmon.ps1    -- CLI wrapper shim for future package-manager install
```

## Modes

### Direct PowerShell

Run the script directly. This is the primary supported mode.

```powershell
.\pcmon.ps1
```

### API-only (no browser)

```powershell
.\pcmon.ps1 -NoOpen
```

Starts the HTTP server on port 9876 without auto-opening the browser. Data is available at `http://localhost:9876/data`.

## Dashboard tabs

- **Overview** — RAM, commit, CPU, disk at a glance
- **RAM** — paged/non-paged pool, private memory breakdown, command lines
- **Processes** — all processes sorted by working set
- **Suspicious** — browser, dev tooling, AI helpers, security tools, drivers
- **Services & Startup** — heavy services and startup items
- **System** — drives, page file, PowerShell profiles

## Metrics collected

- Physical RAM (used/available)
- Commit charge (committed bytes / commit limit)
- Paged pool and non-paged pool (kernel memory)
- Paging rate (pages/sec, reads/sec, writes/sec)
- CPU utilization and processor queue length
- Disk utilization and queue length
- Network throughput (sent/received KB/s)
- Per-process: WS, private memory, paged, virtual, CPU, threads, handles
- Drive capacity and free space
- Service state and startup items
- Page file configuration
- PowerShell profile paths

## Future phases

### Phase 2 — CLI packaging
`bunx pcmon` (preferred) / `npm install -g pcmon` / `pnpm add -g pcmon` wrapping the same core behavior.

### Phase 3 — GPU diagnostics
- Overall GPU utilization
- GPU adapter name
- GPU memory usage

### Phase 4 — Optional desktop shell
Tauri (not Electron) as the future desktop container for users who prefer an installed app over a script.

## Design principles

- Local-first: all data stays on your machine
- Lightweight: plain HTML/CSS/JS, no React until complexity justifies it
- Diagnostic-focused: raw metrics with actionable interpretation
- One core, multiple entry modes: direct PS1, CLI package, optional desktop shell
