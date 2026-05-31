# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

## Reporting a Vulnerability

If you find a security vulnerability, please report it responsibly. Do not open public issues for security vulnerabilities.

## Security Practices

### Process Actions
- All process kill/suspend/resume actions require confirmation header (`X-PCMON-Confirm: 1`)
- Protected system processes (System, lsass, csrss, etc.) cannot be killed, suspended, or resumed
- Process IDs are validated as integers only
- No shell-string execution - uses native PowerShell cmdlets

### Input Validation
- API inputs and HTTP methods are validated before route handling
- Process IDs extracted via regex `(\d+)` only
- Config values validated for correct types
- Snapshot IDs are constrained to safe file-name tokens before compare, export, lookup, or delete
- Path traversal protection is applied to snapshot/export flows
- Invalid requests return structured JSON errors where practical

### Data Handling
- All data stays local (local-first design)
- No cloud connectivity
- Snapshots stored locally in `snapshots/` directory
- Config stored locally in `config.json`
- Runtime cache, refresh-rate, and log files are port-scoped under the user temp directory, for example `pcmon_live_cache_9876.json`, `pcmon_refresh_rate_9876.txt`, and `pcmon_errors_9876.log`

### XSS Protection
- Dashboard uses HTML escaping for user data
- Process names escaped before display
- Printable HTML reports escape interpolated process, user, and system values
- Snapshot action controls use data attributes and event listeners instead of constructing inline JavaScript with snapshot IDs
- No eval()

### Local API Boundary
- CORS is restricted to localhost origins; wildcard `*` is not used for diagnostics endpoints
- `/stream` applies the same localhost-only origin rule for SSE fallback
- `/health` is intentionally cheap and does not trigger heavy collectors

## Known Limitations

- Process actions require appropriate Windows permissions
- Some metrics may require admin privileges for full accuracy
- Some hardware counters are unsupported on some Windows systems; pcmon should surface unsupported, missing, stale, warming, or transiently unavailable states rather than fake zero values
- System tray mode requires Windows Forms support
