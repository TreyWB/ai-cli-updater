# AI CLI Updater

PowerShell updater for local AI coding CLIs used by T3Code.

The script updates recognized Windows installs and can optionally update CLIs inside a named WSL distribution.

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
