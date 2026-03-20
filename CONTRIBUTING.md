# Contributing to pcmon

Thank you for your interest in contributing to pcmon!

## Ways to Contribute

- **Report bugs** - Open an issue with reproduction steps
- **Suggest features** - Open an issue with your proposal
- **Improve docs** - Submit PRs for README or documentation
- **Submit code** - Fix bugs or add features

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/pcmon.git`
3. Create a branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Test locally: `.\pcmon.ps1`
6. Submit a pull request

## Development

### Running Locally

```powershell
.\pcmon.ps1
```

### Testing Changes

```powershell
# API-only mode (no browser)
.\pcmon.ps1 -NoOpen

# Custom port
.\pcmon.ps1 -Port 8080
```

### Code Style

- PowerShell: Follows standard conventions
- JavaScript: ES6+ syntax
- CSS: BEM naming convention

## Scripts

```bash
# Sync skills to .kilo
bun run sync:skills
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
