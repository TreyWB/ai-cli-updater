# AI CLI Updater

PowerShell installer/updater for T3Code and local AI coding CLIs used by T3Code.

The script installs or updates supported Windows components and can optionally update installs inside a named WSL distribution.

Created entirely using GPT 5.5.

## Usage

Preview what would run:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]" -DryRun -WslDistro "[WSL DISTRO NAME]"
```

Update Windows only:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]"
```

Update Windows and WSL:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]" -WslDistro "[WSL DISTRO NAME]"
```

Also install or update supported desktop apps:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]" -WslDistro "[WSL DISTRO NAME]" -IncludeDesktopApps
```

## Notes

- The script supports Windows x64 and Windows ARM64. It errors on x86, 32-bit ARM, and macOS. On Windows ARM64 it currently skips the T3Code update step.
- If `-WslDistro` is omitted, the script warns and only updates Windows installs.
- Missing CLIs are skipped, except the Claude Code CLI, which is installed on Windows if not found.
- Use `-DryRun` to inspect detection and update commands without changing anything.
- Successful update commands print `OK`.
- Winget "no newer package" responses are treated as already up to date, not failures.
- Codex CLI updates print the detected `codex --version` output afterward when available.
- The standalone Codex desktop app is now the ChatGPT desktop app (same Microsoft Store package); it is updated through winget when `-IncludeDesktopApps` is specified.
- T3Code updates include globally installed `t3` npm/pnpm/bun packages. The Windows desktop app is updated through winget when `-IncludeDesktopApps` is specified.
- WSL npm/pnpm globals installed in system-owned locations may prompt for `sudo`.

## Claude installation behavior

- On Windows, Claude Code is installed or updated through the `Anthropic.ClaudeCode` WinGet package when WinGet is available.
- The WinGet architecture is always explicit: `x64` on Windows x64 and `arm64` on Windows ARM64. This prevents an x64 Node.js installation on Windows ARM64 from selecting an emulated x64 Claude binary through npm.
- After a successful WinGet install/update, conflicting global npm, pnpm, and bun installations of `@anthropic-ai/claude-code` are removed so `claude` command resolution does not depend on PATH ordering.
- If WinGet is unavailable, recognized existing package-manager installs are updated. If Claude Code is still missing, the script uses Anthropic's native PowerShell installer rather than creating a new npm installation.
- With `-IncludeDesktopApps`, the separate `Anthropic.Claude` desktop package is installed or updated through WinGet using the same explicit Windows architecture.
- WinGet-managed Claude packages update only when this script (or `winget upgrade`) is run; they do not use Claude's background native auto-updater by default.
- WSL is handled independently. Windows executables exposed under `/mnt/*` are not treated as native WSL installations.
