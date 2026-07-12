# AI CLI Updater

PowerShell installer and updater for T3Code and local AI coding tools on Windows and WSL.

Created entirely using GPT 5.5 and GPT 5.6-Sol.

## Usage

Update Windows components:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]"
```

Update Windows components and CLIs inside a WSL distribution:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]" -WslDistro "[WSL DISTRO NAME]"
```

Include supported Windows desktop apps:

```powershell
powershell -ExecutionPolicy Bypass -File "[PATH\TO\SCRIPT]" -WslDistro "[WSL DISTRO NAME]" -IncludeDesktopApps
```

Available options:

- `-WslDistro <name>` updates native CLI installations inside the named WSL distribution.
- `-IncludeDesktopApps` includes supported Windows desktop applications.
- `-DryRun` shows what the script would do without installing or updating anything.

## Notes

- Windows x64 and Windows ARM64 are supported. x86, 32-bit ARM, and macOS are not supported.
- Missing components prompt for confirmation before installation. Pressing Enter or answering `N` skips that component.
- Windows and WSL installations are managed independently.
- The Windows T3Code app and CLI are skipped on Windows ARM64 because they are not natively supported. T3Code CLI can still be installed inside an ARM64 WSL distribution.
- Desktop applications are included only when `-IncludeDesktopApps` is specified.
- Close running CLI and desktop sessions if the script reports that an executable is locked.
- The script exits with code `1` when one or more requested updates fail.
