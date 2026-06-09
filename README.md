# AI CLI Updater

PowerShell updater for T3Code and local AI coding CLIs used by T3Code.

The script updates recognized Windows installs and can optionally update installs inside a named WSL distribution.

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

Also include supported desktop app updates:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]" -WslDistro "[WSL DISTRO NAME]" -IncludeDesktopApps
```

## Notes

- If `-WslDistro` is omitted, the script warns and only updates Windows installs.
- Missing CLIs are skipped.
- Use `-DryRun` to inspect detection and update commands without changing anything.
- Successful update commands print `OK`.
- Winget "no newer package" responses are treated as already up to date, not failures.
- Codex CLI updates print the detected `codex --version` output afterward when available.
- T3Code updates include globally installed `t3` npm/pnpm/bun packages. The Windows desktop app is updated through winget when `-IncludeDesktopApps` is specified.
- WSL npm/pnpm globals installed in system-owned locations may prompt for `sudo`.
