# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

## Reporting a Vulnerability

If you find a security vulnerability, please report it responsibly. Do not open public issues for security vulnerabilities.

## Security Practices

### Process Actions
- All process kill/suspend/resume actions require user confirmation
- Protected system processes (System, lsass, csrss, etc.) cannot be terminated
- Process IDs are validated as integers only
- No shell-string execution - uses native PowerShell cmdlets

### Input Validation
- All API inputs are validated
- Process IDs extracted via regex `(\d+)` only
- Config values validated for correct types
- Path traversal protection

### Data Handling
- All data stays local (local-first design)
- No cloud connectivity
- Snapshots stored locally in `snapshots/` directory
- Config stored locally in `config.json`

### XSS Protection
- Dashboard uses HTML escaping for user data
- Process names escaped before display
- No eval() or innerHTML with untrusted data

## Known Limitations

- Process actions require appropriate Windows permissions
- Some metrics may require admin privileges for full accuracy
- System tray mode requires Windows Forms support
