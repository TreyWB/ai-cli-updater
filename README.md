# AI CLI Updater

PowerShell updater for local AI coding CLIs used by T3Code.

The script updates recognized Windows installs and can optionally update CLIs inside a named WSL distribution.

## Usage

Preview what would run:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Documents\projects\ai-cli-updater\update-ai-clis.ps1" -DryRun -WslDistro "Ubuntu-24.04.3"
```

Update Windows only:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Documents\projects\ai-cli-updater\update-ai-clis.ps1"
```

Update Windows and WSL:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Documents\projects\ai-cli-updater\update-ai-clis.ps1" -WslDistro "Ubuntu-24.04.3"
```

Also include supported desktop app updates:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\Documents\projects\ai-cli-updater\update-ai-clis.ps1" -WslDistro "Ubuntu-24.04.3" -IncludeDesktopApps
```

## Notes

- If `-WslDistro` is omitted, the script warns and only updates Windows installs.
- Missing CLIs are skipped.
- Use `-DryRun` to inspect detection and update commands without changing anything.
