[CmdletBinding()]
param(
    [string]$WslDistro,
    [switch]$IncludeDesktopApps,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$script:IsWindowsOs = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$script:OsArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()

# RuntimeInformation can report X64 when x64 PowerShell is running under
# emulation on Windows ARM64. Prefer the machine-scoped Windows architecture,
# then use CIM as a secondary host-level signal before accepting the runtime
# view. This distinction controls which native WinGet binary is installed.
if ($script:IsWindowsOs) {
    $machineArchitecture = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", "Machine")
    if ($machineArchitecture -match "^(?i:ARM64)$") {
        $script:OsArchitecture = "Arm64"
    } elseif ($machineArchitecture -match "^(?i:AMD64|x86_64)$") {
        $script:OsArchitecture = "X64"
    } else {
        $cimOsArchitecture = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OSArchitecture -First 1
        if ($cimOsArchitecture -match "(?i:ARM).*(?:64)|64.*(?i:ARM)") {
            $script:OsArchitecture = "Arm64"
        } elseif ($cimOsArchitecture -match "(?i:64-bit|x64)") {
            $script:OsArchitecture = "X64"
        }
    }
}

$script:IsWindowsArm = $script:IsWindowsOs -and $script:OsArchitecture -eq "Arm64"
$script:WingetArchitecture = if ($script:IsWindowsArm) { "arm64" } else { "x64" }

if (-not $script:IsWindowsOs -or $script:OsArchitecture -notin @("X64", "Arm64")) {
    $platform = if ($script:IsWindowsOs) { "Windows $script:OsArchitecture" } else { "$([System.Environment]::OSVersion.Platform) $script:OsArchitecture" }
    Write-Error "Unsupported platform: $platform. This script supports Windows x64 and Windows ARM64. x86, 32-bit ARM, and macOS are not supported."
    exit 1
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Skip {
    param([string]$Message)
    Write-Host "SKIP: $Message" -ForegroundColor DarkYellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "INFO: $Message" -ForegroundColor Gray
}

function Test-CommandAvailable {
    param([string]$Command)
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Invoke-Update {
    param(
        [string]$Label,
        [string]$Executable,
        [string[]]$Arguments,
        [string[]]$BenignExitOutputPatterns = @()
    )

    $display = "$Executable $($Arguments -join ' ')".Trim()
    Write-Host "RUN:  $Label" -ForegroundColor Green
    Write-Host "      $display"

    if ($DryRun) {
        Write-Host "      dry-run: not executed" -ForegroundColor DarkGray
        return $true
    }

    $outputLines = New-Object System.Collections.Generic.List[string]
    & $Executable @Arguments 2>&1 | ForEach-Object {
        $line = $_.ToString()
        [void]$outputLines.Add($line)
        Write-Host $line
    }

    $exitCode = $LASTEXITCODE
    $outputText = $outputLines -join [Environment]::NewLine
    if ($exitCode -eq 0) {
        Write-Host "OK:   $Label completed." -ForegroundColor Green
        return $true
    }

    foreach ($pattern in $BenignExitOutputPatterns) {
        if ($outputText -match $pattern) {
            Write-Host "OK:   $Label is already up to date." -ForegroundColor Green
            return $true
        }
    }

    Write-Warning "$Label failed with exit code $exitCode."
    return $false
}

function Write-CommandVersion {
    param(
        [string]$Label,
        [string[]]$Commands
    )

    $command = Get-PreferredCommand $Commands
    if (-not $command) {
        return
    }

    $version = (& $command --version 2>$null | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($version)) {
        Write-Info "$Label version after update: $($version.Trim())"
    }
}

function Invoke-WingetUpgrade {
    param(
        [string]$Label,
        [string]$PackageId,
        [string]$Architecture
    )

    $arguments = @("upgrade", "--id", $PackageId, "--exact")
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        $arguments += @("--architecture", $Architecture)
    }
    $arguments += @("--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")

    $result = Invoke-Update `
        -Label $Label `
        -Executable "winget" `
        -Arguments $arguments `
        -BenignExitOutputPatterns @("No available upgrade found", "No newer package versions are available")

    return $result
}

function Invoke-WingetInstall {
    param(
        [string]$Label,
        [string]$PackageId,
        [string]$Architecture
    )

    $arguments = @("install", "--id", $PackageId, "--exact")
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        $arguments += @("--architecture", $Architecture)
    }
    $arguments += @("--silent", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")

    return Invoke-Update -Label $Label -Executable "winget" -Arguments $arguments
}

function Get-NpmGlobalRoot {
    if (-not (Test-CommandAvailable "npm.cmd")) {
        return $null
    }

    $root = (& npm.cmd root -g 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $null
    }

    return $root.Trim()
}

function Test-NpmGlobalPackage {
    param([string]$PackageName)

    $root = Get-NpmGlobalRoot
    if (-not $root) {
        return $false
    }

    $packagePath = Join-Path $root ($PackageName -replace "/", "\")
    return Test-Path $packagePath
}

function Test-PnpmGlobalPackage {
    param([string]$PackageName)

    if (-not (Test-CommandAvailable "pnpm")) {
        return $false
    }

    $root = (& pnpm root -g 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $false
    }

    $packagePath = Join-Path $root.Trim() ($PackageName -replace "/", "\")
    return Test-Path $packagePath
}

function Test-BunGlobalPackage {
    param([string]$PackageName)

    if (-not (Test-CommandAvailable "bun")) {
        return $false
    }

    $candidateRoots = @(
        (Join-Path $env:USERPROFILE ".bun\install\global\node_modules")
    )

    foreach ($root in $candidateRoots) {
        $packagePath = Join-Path $root ($PackageName -replace "/", "\")
        if (Test-Path $packagePath) {
            return $true
        }
    }

    return $false
}

function Test-ChocoPackage {
    param([string]$PackageName)

    if (-not (Test-CommandAvailable "choco")) {
        return $false
    }

    $pattern = "^$([regex]::Escape($PackageName))\|"
    $matches = & choco list --local-only -r 2>$null | Select-String -Pattern $pattern
    return $null -ne $matches
}

function Test-WingetPackage {
    param([string]$PackageId)

    if (-not (Test-CommandAvailable "winget")) {
        return $false
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    try {
        $output = & winget list --id $PackageId --exact 2>$null
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if (-not $output) {
        return $false
    }

    $text = ($output | Out-String)
    return $text -match [regex]::Escape($PackageId) -and $text -notmatch "No installed package found"
}

function Get-PreferredCommand {
    param([string[]]$Commands)

    foreach ($command in $Commands) {
        $found = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.Source
        }
    }

    return $null
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match "^([A-Za-z]):\\(.*)$") {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace "\\", "/"
        return "/mnt/$drive/$rest"
    }

    return $null
}

function Set-UnixTextFile {
    param(
        [string]$Path,
        [string]$Value
    )

    $unixValue = $Value -replace "`r`n?", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $unixValue, $utf8NoBom)
}

function Update-WindowsNpmLikePackage {
    param(
        [string]$Label,
        [string]$PackageName
    )

    $updated = $false

    if (Test-NpmGlobalPackage $PackageName) {
        if (Invoke-Update "$Label via npm global package '$PackageName'" "npm.cmd" @("install", "-g", "$PackageName@latest")) {
            $updated = $true
        }
    }

    if (Test-PnpmGlobalPackage $PackageName) {
        if (Invoke-Update "$Label via pnpm global package '$PackageName'" "pnpm" @("add", "-g", "$PackageName@latest")) {
            $updated = $true
        }
    }

    if (Test-BunGlobalPackage $PackageName) {
        if (Invoke-Update "$Label via bun global package '$PackageName'" "bun" @("add", "-g", "$PackageName@latest")) {
            $updated = $true
        }
    }

    return $updated
}

function Remove-WindowsClaudeJsPackages {
    $allSucceeded = $true

    if (Test-NpmGlobalPackage "@anthropic-ai/claude-code") {
        if (-not (Invoke-Update "Remove conflicting npm Claude Code installation" "npm.cmd" @("uninstall", "-g", "@anthropic-ai/claude-code"))) {
            $allSucceeded = $false
        }
    }

    if (Test-PnpmGlobalPackage "@anthropic-ai/claude-code") {
        if (-not (Invoke-Update "Remove conflicting pnpm Claude Code installation" "pnpm" @("remove", "-g", "@anthropic-ai/claude-code"))) {
            $allSucceeded = $false
        }
    }

    if (Test-BunGlobalPackage "@anthropic-ai/claude-code") {
        if (-not (Invoke-Update "Remove conflicting bun Claude Code installation" "bun" @("remove", "-g", "@anthropic-ai/claude-code"))) {
            $allSucceeded = $false
        }
    }

    return $allSucceeded
}

function Update-WindowsCodex {
    Write-Section "Windows Codex"
    $updated = Update-WindowsNpmLikePackage "Codex" "@openai/codex"

    # The standalone Codex desktop app merged into the ChatGPT desktop app (July 2026)
    # but kept the same Microsoft Store package ID.
    if ($IncludeDesktopApps -and (Test-WingetPackage "9PLM9XGG6VKS")) {
        if (Invoke-WingetUpgrade "ChatGPT desktop app (includes Codex) via Microsoft Store / winget package '9PLM9XGG6VKS'" "9PLM9XGG6VKS") {
            $updated = $true
        }
    } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage "9PLM9XGG6VKS")) {
        Write-Info "ChatGPT desktop app (includes Codex) is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $updated) {
        $codex = Get-PreferredCommand @("codex.cmd", "codex.exe", "codex")
        if ($codex) {
            if (Invoke-Update "Codex via native self-updater" $codex @("update")) {
                $updated = $true
            }
        }
    }

    if (-not $updated) {
        Write-Skip "Codex is not installed in a recognized Windows location."
    } elseif (-not $DryRun) {
        Write-CommandVersion "Codex CLI" @("codex.cmd", "codex.exe", "codex")
    }
}

function Update-WindowsClaude {
    Write-Section "Windows Claude"
    $cliUpdated = $false
    $wingetAvailable = Test-CommandAvailable "winget"
    $claudeCodePackageId = "Anthropic.ClaudeCode"

    # WinGet selects Anthropic's native binary directly. Supplying the OS
    # architecture is important on Windows ARM64, where an x64 Node/npm
    # installation can otherwise select the emulated win32-x64 build.
    if ($wingetAvailable) {
        if (Test-WingetPackage $claudeCodePackageId) {
            $cliUpdated = Invoke-WingetUpgrade `
                "Claude Code CLI via winget package '$claudeCodePackageId' ($script:WingetArchitecture)" `
                $claudeCodePackageId `
                $script:WingetArchitecture
        } else {
            $cliUpdated = Invoke-WingetInstall `
                "Claude Code CLI via winget package '$claudeCodePackageId' ($script:WingetArchitecture)" `
                $claudeCodePackageId `
                $script:WingetArchitecture
        }

        # Multiple claude shims make command resolution dependent on PATH
        # ordering. Only remove JS-package installs after WinGet succeeded.
        if ($cliUpdated -and -not (Remove-WindowsClaudeJsPackages)) {
            Write-Warning "Claude Code was installed through WinGet, but one or more conflicting JavaScript-package installations could not be removed."
        }
    } else {
        Write-Info "WinGet is unavailable; checking existing Claude Code installation methods."
        $cliUpdated = Update-WindowsNpmLikePackage "Claude Code" "@anthropic-ai/claude-code"

        if (-not $cliUpdated) {
            $claude = Get-PreferredCommand @("claude.exe", "claude.cmd", "claude")
            if ($claude) {
                if (Invoke-Update "Claude Code via native self-updater" $claude @("update")) {
                    $cliUpdated = $true
                }
            }
        }
    }

    if ($IncludeDesktopApps -and $wingetAvailable -and (Test-WingetPackage "Anthropic.Claude")) {
        [void](Invoke-WingetUpgrade `
            "Claude Desktop app via winget package 'Anthropic.Claude' ($script:WingetArchitecture)" `
            "Anthropic.Claude" `
            $script:WingetArchitecture)
    } elseif ($IncludeDesktopApps -and $wingetAvailable) {
        [void](Invoke-WingetInstall `
            "Claude Desktop app via winget package 'Anthropic.Claude' ($script:WingetArchitecture)" `
            "Anthropic.Claude" `
            $script:WingetArchitecture)
    } elseif ($IncludeDesktopApps) {
        Write-Skip "Claude Desktop app requires WinGet, but winget is unavailable."
    } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage "Anthropic.Claude")) {
        Write-Info "Claude Desktop app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    # The Claude Desktop app does not bundle the CLI, so a successful desktop
    # update must not hide a missing 'claude' command.
    if (-not $cliUpdated) {
        Write-Info "Claude Code CLI is not installed (the Claude Desktop app does not include it); installing it now."
        $cliUpdated = Invoke-Update "Claude Code CLI install via Anthropic native installer" "powershell.exe" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm https://claude.ai/install.ps1 | iex")
        if ($cliUpdated) {
            Write-Info "Restart your terminal if 'claude' is not yet found on PATH."
        } else {
            Write-Skip "Claude Code CLI could not be installed."
        }
    }

    if ($cliUpdated -and -not $DryRun) {
        Write-CommandVersion "Claude Code CLI" @("claude.exe", "claude.cmd", "claude")
    }
}

function Update-WindowsOpenCode {
    Write-Section "Windows OpenCode"
    $updated = $false

    if (Test-ChocoPackage "opencode") {
        if (Invoke-Update "OpenCode via Chocolatey package 'opencode'" "choco" @("upgrade", "opencode", "-y")) {
            $updated = $true
        }
    }

    if (Update-WindowsNpmLikePackage "OpenCode" "opencode-ai") {
        $updated = $true
    }

    if (-not $updated) {
        $opencode = Get-PreferredCommand @("opencode.cmd", "opencode.exe", "opencode")
        if ($opencode) {
            if (Invoke-Update "OpenCode via native self-updater" $opencode @("upgrade")) {
                $updated = $true
            }
        }
    }

    if (-not $updated) {
        Write-Skip "OpenCode is not installed in a recognized Windows location."
    }
}

function Update-WindowsCursor {
    Write-Section "Windows Cursor"
    $updated = $false

    $cursorAgent = Get-PreferredCommand @("cursor-agent.cmd", "cursor-agent.exe", "cursor-agent")
    if ($cursorAgent) {
        if (Invoke-Update "Cursor Agent via cursor-agent self-updater" $cursorAgent @("update")) {
            $updated = $true
        }
    }

    if (-not $cursorAgent) {
        $agent = Get-PreferredCommand @("agent.cmd", "agent.exe", "agent")
        if ($agent) {
            if (Invoke-Update "Cursor Agent via T3Code-style 'agent' self-updater" $agent @("update")) {
                $updated = $true
            }
        }
    }

    foreach ($id in @("Anysphere.Cursor", "Cursor.Cursor")) {
        if ($IncludeDesktopApps -and (Test-WingetPackage $id)) {
            if (Invoke-WingetUpgrade "Cursor app via winget package '$id'" $id) {
                $updated = $true
            }
        } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage $id)) {
            Write-Info "Cursor app package '$id' is installed; skipping because -IncludeDesktopApps was not specified."
        }
    }

    if (-not $updated) {
        Write-Skip "Cursor / Cursor Agent is not installed in a recognized Windows location."
    }
}

function Update-WindowsT3Code {
    Write-Section "Windows T3Code"

    if ($script:IsWindowsArm) {
        Write-Skip "T3Code updates are not supported on Windows ARM ($script:OsArchitecture); skipping."
        return
    }

    $updated = Update-WindowsNpmLikePackage "T3Code" "t3"

    if ($IncludeDesktopApps -and (Test-WingetPackage "T3Tools.T3Code")) {
        if (Invoke-WingetUpgrade "T3Code desktop app via winget package 'T3Tools.T3Code'" "T3Tools.T3Code") {
            $updated = $true
        }
    } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage "T3Tools.T3Code")) {
        Write-Info "T3Code desktop app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $updated) {
        Write-Skip "T3Code is not installed in a recognized Windows location."
    } elseif (-not $DryRun) {
        Write-CommandVersion "T3Code CLI" @("t3.cmd", "t3.exe", "t3")
    }
}

function Invoke-WslUpdates {
    param([string]$Distro)

    Write-Section "WSL: $Distro"

    if (-not (Test-CommandAvailable "wsl.exe")) {
        Write-Skip "wsl.exe is not available."
        return
    }

    $bashScript = @'
set -u

DRY_RUN="${T3_UPDATE_DRY_RUN:-0}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

section() {
  printf '\n== WSL %s ==\n' "$1"
}

skip() {
  printf 'SKIP: %s\n' "$1"
}

run_update() {
  label="$1"
  shift
  printf 'RUN:  %s\n' "$label"
  printf '      %s\n' "$*"
  if [ "$DRY_RUN" = "1" ]; then
    printf '      dry-run: not executed\n'
    return 0
  fi
  "$@"
  status=$?
  if [ "$status" -eq 0 ]; then
    printf 'OK:   %s completed.\n' "$label"
    return 0
  fi
  printf 'WARNING: %s failed with exit code %s.\n' "$label" "$status"
  return "$status"
}

SUDO_VALIDATED=0

ensure_sudo() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    printf 'WARNING: sudo is required but is not installed in this WSL distro.\n'
    return 1
  fi
  if [ "$SUDO_VALIDATED" -ne 1 ]; then
    printf 'INFO: sudo is required for one or more WSL global installs.\n'
    sudo -v
    status=$?
    if [ "$status" -ne 0 ]; then
      printf 'WARNING: sudo validation failed with exit code %s.\n' "$status"
      return "$status"
    fi
    SUDO_VALIDATED=1
  fi
  return 0
}

path_requires_sudo() {
  path="$1"
  [ "$(id -u)" -ne 0 ] && [ -n "$path" ] && [ ! -w "$path" ]
}

run_update_maybe_sudo() {
  label="$1"
  needs_sudo="$2"
  shift 2
  if [ "$needs_sudo" = "1" ]; then
    if ensure_sudo; then
      run_update "$label" sudo -H "$@"
      return $?
    fi
    return 1
  fi
  run_update "$label" "$@"
}

cmd_path() {
  command -v "$1" 2>/dev/null || true
}

is_windows_path() {
  case "$1" in
    /mnt/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_native_command() {
  path="$(cmd_path "$1")"
  [ -n "$path" ] && ! is_windows_path "$path"
}

native_path_for() {
  name="$1"
  path="$(cmd_path "$name")"
  if [ -n "$path" ] && ! is_windows_path "$path"; then
    printf '%s\n' "$path"
  fi
}

print_version() {
  label="$1"
  command_name="$2"
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if is_native_command "$command_name"; then
    version="$("$command_name" --version 2>/dev/null | head -n 1)"
    if [ -n "$version" ]; then
      printf 'INFO: %s version after update: %s\n' "$label" "$version"
    fi
  fi
}

have_native_npm() {
  path="$(cmd_path npm)"
  [ -n "$path" ] && ! is_windows_path "$path"
}

npm_global_root() {
  if have_native_npm; then
    npm root -g 2>/dev/null | head -n 1
  fi
}

have_npm_global_package() {
  package="$1"
  root="$(npm_global_root)"
  [ -n "$root" ] && [ -d "$root/$package" ]
}

update_npm_global_package() {
  label="$1"
  package="$2"
  root="$(npm_global_root)"
  if [ -n "$root" ] && [ -d "$root/$package" ]; then
    needs_sudo=0
    if path_requires_sudo "$root"; then
      needs_sudo=1
    fi
    run_update_maybe_sudo "$label via npm global package '$package'" "$needs_sudo" npm install -g "$package@latest"
    return $?
  fi
  return 1
}

have_native_pnpm() {
  path="$(cmd_path pnpm)"
  [ -n "$path" ] && ! is_windows_path "$path"
}

pnpm_global_root() {
  if have_native_pnpm; then
    pnpm root -g 2>/dev/null | head -n 1
  fi
}

have_pnpm_global_package() {
  package="$1"
  root="$(pnpm_global_root)"
  [ -n "$root" ] && [ -d "$root/$package" ]
}

update_pnpm_global_package() {
  label="$1"
  package="$2"
  root="$(pnpm_global_root)"
  if [ -n "$root" ] && [ -d "$root/$package" ]; then
    needs_sudo=0
    if path_requires_sudo "$root"; then
      needs_sudo=1
    fi
    run_update_maybe_sudo "$label via pnpm global package '$package'" "$needs_sudo" pnpm add -g "$package@latest"
    return $?
  fi
  return 1
}

have_native_bun() {
  path="$(cmd_path bun)"
  [ -n "$path" ] && ! is_windows_path "$path"
}

have_bun_global_package() {
  package="$1"
  [ -d "$HOME/.bun/install/global/node_modules/$package" ]
}

update_bun_global_package() {
  label="$1"
  package="$2"
  if have_native_bun && have_bun_global_package "$package"; then
    run_update "$label via bun global package '$package'" bun add -g "$package@latest"
    return $?
  fi
  return 1
}

update_js_package_methods() {
  label="$1"
  package="$2"
  updated=1
  update_npm_global_package "$label" "$package" && updated=0
  update_pnpm_global_package "$label" "$package" && updated=0
  update_bun_global_package "$label" "$package" && updated=0
  return "$updated"
}

section "Codex"
codex_updated=1
update_js_package_methods "Codex" "@openai/codex" && codex_updated=0
if [ "$codex_updated" -ne 0 ] && is_native_command codex; then
  codex_path="$(native_path_for codex)"
  if run_update "Codex via native self-updater" "$codex_path" update; then
    codex_updated=0
  fi
fi
if [ "$codex_updated" -ne 0 ]; then
  path="$(cmd_path codex)"
  if [ -n "$path" ] && is_windows_path "$path"; then
    skip "Codex only resolves to a Windows PATH shim in WSL: $path"
  else
    skip "Codex is not installed in a recognized WSL location."
  fi
else
  print_version "Codex CLI" codex
fi

section "Claude"
claude_updated=1
update_js_package_methods "Claude Code" "@anthropic-ai/claude-code" && claude_updated=0
if is_native_command claude; then
  claude_path="$(native_path_for claude)"
  if run_update "Claude Code via native self-updater" "$claude_path" update; then
    claude_updated=0
  fi
fi
if [ "$claude_updated" -ne 0 ]; then
  path="$(cmd_path claude)"
  if [ -n "$path" ] && is_windows_path "$path"; then
    skip "Claude only resolves to a Windows PATH shim in WSL: $path"
  else
    skip "Claude Code is not installed in a recognized WSL location."
  fi
fi

section "OpenCode"
opencode_updated=1
if [ -x "$HOME/.opencode/bin/opencode" ]; then
  if run_update "OpenCode via native ~/.opencode install" "$HOME/.opencode/bin/opencode" upgrade; then
    opencode_updated=0
  fi
elif is_native_command opencode; then
  opencode_path="$(native_path_for opencode)"
  if run_update "OpenCode via native self-updater" "$opencode_path" upgrade; then
    opencode_updated=0
  fi
fi
update_js_package_methods "OpenCode" "opencode-ai" && opencode_updated=0
if [ "$opencode_updated" -ne 0 ]; then
  path="$(cmd_path opencode)"
  if [ -n "$path" ] && is_windows_path "$path"; then
    skip "OpenCode only resolves to a Windows PATH shim in WSL: $path"
  else
    skip "OpenCode is not installed in a recognized WSL location."
  fi
fi

section "Cursor"
cursor_updated=1
if is_native_command cursor-agent; then
  cursor_agent_path="$(native_path_for cursor-agent)"
  if run_update "Cursor Agent via cursor-agent self-updater" "$cursor_agent_path" update; then
    cursor_updated=0
  fi
elif is_native_command agent; then
  agent_path="$(native_path_for agent)"
  if run_update "Cursor Agent via T3Code-style 'agent' self-updater" "$agent_path" update; then
    cursor_updated=0
  fi
fi
if [ "$cursor_updated" -ne 0 ]; then
  skip "Cursor Agent is not installed in a recognized WSL location."
fi

section "T3Code"
t3code_updated=1
update_js_package_methods "T3Code" "t3" && t3code_updated=0
if [ "$t3code_updated" -ne 0 ]; then
  path="$(cmd_path t3)"
  if [ -n "$path" ] && is_windows_path "$path"; then
    skip "T3Code only resolves to a Windows PATH shim in WSL: $path"
  else
    skip "T3Code is not installed in a recognized WSL location."
  fi
else
  print_version "T3Code CLI" t3
fi
'@

    $tempScript = New-TemporaryFile
    Set-UnixTextFile -Path $tempScript.FullName -Value $bashScript

    try {
        $wslScriptPath = ConvertTo-WslPath $tempScript.FullName
        if ([string]::IsNullOrWhiteSpace($wslScriptPath)) {
            Write-Warning "Could not translate temporary script path for WSL distro '$Distro'."
            return
        }

        $dryRunValue = if ($DryRun) { "1" } else { "0" }
        wsl.exe -d $Distro -- env "T3_UPDATE_DRY_RUN=$dryRunValue" bash $wslScriptPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "WSL update block failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Remove-Item -LiteralPath $tempScript.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "AI CLI updater starting." -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "Dry-run mode: commands will be printed but not executed." -ForegroundColor DarkGray
}
if ($IncludeDesktopApps) {
    Write-Host "Desktop app updates are enabled." -ForegroundColor DarkGray
}

Update-WindowsCodex
Update-WindowsClaude
Update-WindowsOpenCode
Update-WindowsCursor
Update-WindowsT3Code

if ([string]::IsNullOrWhiteSpace($WslDistro)) {
    Write-Section "WSL"
    Write-Warning "No WSL distro was specified, so no WSL CLIs will be updated. Re-run with -WslDistro 'Ubuntu-24.04.3' to include WSL."
} else {
    Invoke-WslUpdates $WslDistro
}

Write-Host ""
Write-Host "AI CLI updater finished." -ForegroundColor Cyan
