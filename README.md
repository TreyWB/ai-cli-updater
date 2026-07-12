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
- Missing components prompt for confirmation before they are installed. Answering no is treated as an ordinary skip, not a failure.
- Desktop apps are checked, updated, and offered for installation only when `-IncludeDesktopApps` is specified.
- Use `-DryRun` to inspect detection and update commands without changing anything. Missing components print the prompt that a live run would show, but dry-run mode never waits for input.
- Successful update commands print `OK`.
- Winget "no newer package" responses are treated as already up to date, not failures.
- Failed update commands are collected into a summary and the script exits with code `1`; a clean run exits with code `0`.
- Codex CLI updates print the detected `codex --version` output afterward when available. If a running Codex process would lock the npm-installed executable, the script identifies the process IDs and asks you to close Codex/T3Code/ChatGPT Codex sessions before retrying.
- The standalone Codex desktop app has been incorporated into the ChatGPT desktop app (same Microsoft Store package). It is updated through WinGet when `-IncludeDesktopApps` is specified; this does not replace the separate Codex CLI used by terminals and T3Code.
- T3Code updates include globally installed `t3` npm/pnpm/bun packages. The Windows desktop app is updated through winget when `-IncludeDesktopApps` is specified.
- WSL npm/pnpm globals installed in system-owned locations may prompt for `sudo`.
- When a named WSL distribution is included, missing native WSL CLIs are offered for installation independently of their Windows counterparts.

## Codex and OpenCode architecture behavior

- Codex's npm package selects its native executable from the architecture of the JavaScript runtime. On Windows ARM64, an x64 Node/npm/pnpm/bun runtime would therefore install or update the x64 Codex payload. The script detects this mismatch, skips the unsafe update, reports a failure, and recommends an ARM64 runtime or a native WSL Codex installation.
- If Codex CLI is missing and installation is accepted, the script uses a host-architecture Node/npm runtime. If necessary, it installs Node.js LTS through WinGet with an explicit Windows architecture before installing `@openai/codex`.
- Close running Codex sessions before updating an npm-managed Codex installation. This prevents Windows `EBUSY` errors caused by a locked `codex-code-mode-host.exe`.
- Windows OpenCode is standardized on the official `SST.opencode` WinGet package with an explicit `x64` or `arm64` architecture.
- After a successful WinGet OpenCode install/update, conflicting `opencode-ai` npm/pnpm/bun installations and the Chocolatey `opencode` package are removed. This prevents PATH ordering from selecting an old or wrong-architecture executable.
- If WinGet is unavailable, OpenCode can fall back to recognized package-manager installs on Windows x64. Windows ARM64 requires WinGet so the native ARM64 package is selected safely.

## Missing-component installation behavior

- ChatGPT, Claude Desktop, Cursor Desktop, and T3Code Desktop are offered only with `-IncludeDesktopApps` and are installed through WinGet.
- Codex CLI is installed from `@openai/codex` using a Node/npm runtime that matches the Windows host architecture.
- Claude Code CLI is installed through `Anthropic.ClaudeCode` when WinGet is available, with Anthropic's native installer as the fallback.
- Cursor Agent CLI is installed through Cursor's official native Windows installer.
- OpenCode CLI is installed through `SST.opencode` with an explicit architecture.
- On Windows x64, T3Code CLI can be installed from the `t3` npm package and its desktop app from `T3Tools.T3Code`.
- On Windows ARM64, all Windows T3Code installation and update paths are unconditionally skipped because T3Code does not provide native Windows ARM64 support.

## Claude installation behavior

- On Windows, Claude Code is installed or updated through the `Anthropic.ClaudeCode` WinGet package when WinGet is available.
- The WinGet architecture is always explicit: `x64` on Windows x64 and `arm64` on Windows ARM64. This prevents an x64 Node.js installation on Windows ARM64 from selecting an emulated x64 Claude binary through npm.
- After a successful WinGet install/update, conflicting global npm, pnpm, and bun installations of `@anthropic-ai/claude-code` are removed so `claude` command resolution does not depend on PATH ordering.
- If WinGet is unavailable, recognized existing package-manager installs are updated. If Claude Code is still missing, the script uses Anthropic's native PowerShell installer rather than creating a new npm installation.
- With `-IncludeDesktopApps`, the separate `Anthropic.Claude` desktop package is installed or updated through WinGet using the same explicit Windows architecture.
- WinGet-managed Claude packages update only when this script (or `winget upgrade`) is run; they do not use Claude's background native auto-updater by default.
- WSL is handled independently. Windows executables exposed under `/mnt/*` are not treated as native WSL installations.
