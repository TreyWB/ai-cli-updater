[CmdletBinding()]
param(
    [string]$WslDistro,
    [switch]$IncludeDesktopApps,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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
        [string[]]$Arguments
    )

    $display = "$Executable $($Arguments -join ' ')".Trim()
    Write-Host "RUN:  $Label" -ForegroundColor Green
    Write-Host "      $display"

    if ($DryRun) {
        Write-Host "      dry-run: not executed" -ForegroundColor DarkGray
        return
    }

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "$Label failed with exit code $LASTEXITCODE."
    }
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

    $output = & winget list --id $PackageId --exact 2>$null
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

function Update-WindowsNpmLikePackage {
    param(
        [string]$Label,
        [string]$PackageName
    )

    $updated = $false

    if (Test-NpmGlobalPackage $PackageName) {
        Invoke-Update "$Label via npm global package '$PackageName'" "npm.cmd" @("install", "-g", "$PackageName@latest")
        $updated = $true
    }

    if (Test-PnpmGlobalPackage $PackageName) {
        Invoke-Update "$Label via pnpm global package '$PackageName'" "pnpm" @("add", "-g", "$PackageName@latest")
        $updated = $true
    }

    if (Test-BunGlobalPackage $PackageName) {
        Invoke-Update "$Label via bun global package '$PackageName'" "bun" @("add", "-g", "$PackageName@latest")
        $updated = $true
    }

    return $updated
}

function Update-WindowsCodex {
    Write-Section "Windows Codex"
    $updated = Update-WindowsNpmLikePackage "Codex" "@openai/codex"

    if ($IncludeDesktopApps -and (Test-WingetPackage "9PLM9XGG6VKS")) {
        Invoke-Update "Codex via Microsoft Store / winget package '9PLM9XGG6VKS'" "winget" @("upgrade", "--id", "9PLM9XGG6VKS", "--exact", "--accept-package-agreements", "--accept-source-agreements")
        $updated = $true
    } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage "9PLM9XGG6VKS")) {
        Write-Info "Codex Microsoft Store app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $updated) {
        $codex = Get-PreferredCommand @("codex.cmd", "codex.exe")
        if ($codex) {
            Invoke-Update "Codex via native self-updater" $codex @("update")
            $updated = $true
        }
    }

    if (-not $updated) {
        Write-Skip "Codex is not installed in a recognized Windows location."
    }
}

function Update-WindowsClaude {
    Write-Section "Windows Claude"
    $updated = Update-WindowsNpmLikePackage "Claude Code" "@anthropic-ai/claude-code"

    if (-not $updated) {
        $claude = Get-PreferredCommand @("claude.cmd", "claude.exe", "claude")
        if ($claude) {
            Invoke-Update "Claude Code via native self-updater" $claude @("update")
            $updated = $true
        }
    }

    if ($IncludeDesktopApps -and (Test-WingetPackage "Anthropic.Claude")) {
        Invoke-Update "Claude Desktop app via winget package 'Anthropic.Claude'" "winget" @("upgrade", "--id", "Anthropic.Claude", "--exact", "--accept-package-agreements", "--accept-source-agreements")
        $updated = $true
    } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage "Anthropic.Claude")) {
        Write-Info "Claude Desktop app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $updated) {
        Write-Skip "Claude Code is not installed in a recognized Windows location."
    }
}

function Update-WindowsOpenCode {
    Write-Section "Windows OpenCode"
    $updated = $false

    if (Test-ChocoPackage "opencode") {
        Invoke-Update "OpenCode via Chocolatey package 'opencode'" "choco" @("upgrade", "opencode", "-y")
        $updated = $true
    }

    if (Update-WindowsNpmLikePackage "OpenCode" "opencode-ai") {
        $updated = $true
    }

    if (-not $updated) {
        $opencode = Get-PreferredCommand @("opencode.cmd", "opencode.exe", "opencode")
        if ($opencode) {
            Invoke-Update "OpenCode via native self-updater" $opencode @("upgrade")
            $updated = $true
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
        Invoke-Update "Cursor Agent via cursor-agent self-updater" $cursorAgent @("update")
        $updated = $true
    }

    if (-not $cursorAgent) {
        $agent = Get-PreferredCommand @("agent.cmd", "agent.exe", "agent")
        if ($agent) {
            Invoke-Update "Cursor Agent via T3Code-style 'agent' self-updater" $agent @("update")
            $updated = $true
        }
    }

    foreach ($id in @("Anysphere.Cursor", "Cursor.Cursor")) {
        if ($IncludeDesktopApps -and (Test-WingetPackage $id)) {
            Invoke-Update "Cursor app via winget package '$id'" "winget" @("upgrade", "--id", $id, "--exact", "--accept-package-agreements", "--accept-source-agreements")
            $updated = $true
        } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage $id)) {
            Write-Info "Cursor app package '$id' is installed; skipping because -IncludeDesktopApps was not specified."
        }
    }

    if (-not $updated) {
        Write-Skip "Cursor / Cursor Agent is not installed in a recognized Windows location."
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
  if have_npm_global_package "$package"; then
    run_update "$label via npm global package '$package'" npm install -g "$package@latest"
    return 0
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
  if have_pnpm_global_package "$package"; then
    run_update "$label via pnpm global package '$package'" pnpm add -g "$package@latest"
    return 0
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
    return 0
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
  run_update "Codex via native self-updater" "$codex_path" update
  codex_updated=0
fi
if [ "$codex_updated" -ne 0 ]; then
  path="$(cmd_path codex)"
  if [ -n "$path" ] && is_windows_path "$path"; then
    skip "Codex only resolves to a Windows PATH shim in WSL: $path"
  else
    skip "Codex is not installed in a recognized WSL location."
  fi
fi

section "Claude"
claude_updated=1
update_js_package_methods "Claude Code" "@anthropic-ai/claude-code" && claude_updated=0
if is_native_command claude; then
  claude_path="$(native_path_for claude)"
  run_update "Claude Code via native self-updater" "$claude_path" update
  claude_updated=0
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
  run_update "OpenCode via native ~/.opencode install" "$HOME/.opencode/bin/opencode" upgrade
  opencode_updated=0
elif is_native_command opencode; then
  opencode_path="$(native_path_for opencode)"
  run_update "OpenCode via native self-updater" "$opencode_path" upgrade
  opencode_updated=0
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
  run_update "Cursor Agent via cursor-agent self-updater" "$cursor_agent_path" update
  cursor_updated=0
elif is_native_command agent; then
  agent_path="$(native_path_for agent)"
  run_update "Cursor Agent via T3Code-style 'agent' self-updater" "$agent_path" update
  cursor_updated=0
fi
if [ "$cursor_updated" -ne 0 ]; then
  skip "Cursor Agent is not installed in a recognized WSL location."
fi
'@

    $tempScript = New-TemporaryFile
    Set-Content -LiteralPath $tempScript.FullName -Value $bashScript -NoNewline -Encoding ASCII

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

if ([string]::IsNullOrWhiteSpace($WslDistro)) {
    Write-Section "WSL"
    Write-Warning "No WSL distro was specified, so no WSL CLIs will be updated. Re-run with -WslDistro 'Ubuntu-24.04.3' to include WSL."
} else {
    Invoke-WslUpdates $WslDistro
}

Write-Host ""
Write-Host "AI CLI updater finished." -ForegroundColor Cyan
