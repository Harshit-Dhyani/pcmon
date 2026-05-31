# Changelog

All notable changes to pcmon will be documented in this file.

## [Unreleased]

### Fixed
- Replaced the broken `/api/export` cache path so live export reads the current cache or last known payload without referencing undefined variables.
- Kept `/health` independent from heavy collector warmup so the listener can answer quickly while data is still warming.
- Added the protected-process guard to resume actions, matching kill and suspend behavior.
- Validated HTTP methods and snapshot IDs across snapshot, export, report, config, refresh-rate, stream, and data paths.
- Escaped printable report values before HTML interpolation.
- Removed wildcard CORS from SSE and kept localhost-only origin behavior.
- Replaced silent empty catches with bounded logging paths.
- Fixed fast stream handling so `_fast` packets update only summary cards, timestamps, trends, and sparklines.
- Kept section skeletons visible until the owning subsystem has settled, so partial or warming data no longer unloads the whole app.
- Replaced inline snapshot action string construction with data attributes and event listeners.

### Changed
- Live data payloads now include non-breaking collector metadata: `collection_state`, `cache_age_ms`, `subsystems`, and optional `errors_recent`.
- Collectors preserve last known good static/heavy entities during transient misses: drives, groups, services, startup items, pagefile, PowerShell profiles, network adapters, and GPU adapters.
- Process group matching uses exact normalized process-name sets instead of regex matching.
- Background cache writes use exclusive file writes with retry, and server reads use safe retry logic.
- `/data` prefers usable cache or in-memory last-good data before attempting synchronous collection.
- Refresh UI copy now distinguishes fast metric cadence from table/static refresh cadence.

## [1.0.0] - 2026-03-21

### Added
- **Dashboard** - 11 tabs (Overview, RAM, CPU, Disk, GPU, Groups, Suspicious, Services, System, All Processes, Settings)
- **Process Actions** - Kill, Suspend, Resume processes from UI
- **Protected Processes** - System processes cannot be terminated
- **Snapshots** - Save labeled system snapshots
- **Compare** - Compare snapshots to see changes
- **Export** - JSON and CSV export for snapshots
- **Clipboard** - Copy process tables to clipboard
- **Alert Thresholds** - Configurable via Settings tab
- **PDF Reports** - Generate printable HTML reports
- **System Tray** - Run in background with -Tray flag
- **Live Wallpaper** - Live system stats as desktop wallpaper
- **GPU Metrics** - Adapter info, utilization, memory
- **Process Groups** - Browser/Electron, Dev Tools, Security tools tracking
- **Sparklines** - Historical trending visualization
- **Delta Indicators** - Show metric changes (up/down)
- **Diagnostic Insights** - Actionable system health explanations
- **Real-Time Streaming** - WebSocket/SSE/polling fallback chain
- **Fast Metrics** - Sub-second updates for key metrics via real-time stream
- **Skeleton Loaders** - Loading states on every data fetch cycle
- **CLI Parameters** - -NoOpen, -ApiOnly, -Debug, -Tray, -Wallpaper, -Help

### Fixed
- **JSON truncation** - Changed serialization depth from 5 to 20
- **Client disconnect crashes** - Added try-catch around OutputStream.Write
- **File lock conflicts** - Background process uses retry with exclusive file mode
- **Counter path case sensitivity** - All counter paths uppercased for consistency
- **Empty array errors** - /api/snapshots now handles empty directories gracefully
- **Cache-first architecture** - Snapshot/compare/report endpoints read from cache file first
- **Background process crashes** - Fixed param handling, profile paths via temp file
- **Data display zeros** - Fixed Get-CachedStaticData with -NoProfile and WMI fallbacks
- **Get-CachedCommandLines logic** - Removed unreachable early return and unused parameter

### Security
- XSS protection in dashboard (uses `esc()` function)
- Input validation on all API endpoints
- Protected process list
- No shell-string execution
- Confirmation header required for process actions

### Architecture
- PowerShell-first modular backend source
- Plain HTML/CSS/JS frontend source
- Direct .ps1 mode as first-class path
- Background process for continuous data collection
- File-based cache for cross-process data sharing
- Debug mode with `-Debug` flag for verbose logging
- WebSocket broadcast timer for real-time push
- Fast metrics timer for sub-second updates

## [0.0.0] - 2026-01-01

### Added
- Initial release (placeholder)
