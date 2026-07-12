[CmdletBinding()]
param(
    [string]$WslDistro,
    [switch]$IncludeDesktopApps,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
$script:Failures = New-Object System.Collections.Generic.List[string]

$script:IsWindowsOs = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:OsArchitecture = "Unknown"

# RuntimeInformation.OSArchitecture is unavailable in some Windows PowerShell
# 5.1/.NET Framework combinations, and can report X64 when x64 PowerShell is
# running under emulation on Windows ARM64. Prefer host-level Windows signals;
# only use RuntimeInformation through reflection as a cross-platform fallback.
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
} else {
    $runtimeInformationType = [System.Runtime.InteropServices.RuntimeInformation]
    $osArchitectureProperty = $runtimeInformationType.GetProperty("OSArchitecture")
    if ($null -ne $osArchitectureProperty) {
        $script:OsArchitecture = $osArchitectureProperty.GetValue($null, $null).ToString()
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

function Confirm-ComponentInstall {
    param([string]$Label)

    if ($DryRun) {
        Write-Host "PROMPT: $Label is not installed; a live run would ask whether to install it." -ForegroundColor Magenta
        return $false
    }

    while ($true) {
        $response = Read-Host "$Label is not installed. Install it? [y/N]"
        if ([string]::IsNullOrWhiteSpace($response) -or $response -match "^(?i:n|no)$") {
            Write-Skip "$Label installation was declined."
            return $false
        }
        if ($response -match "^(?i:y|yes)$") {
            return $true
        }
        Write-Info "Enter Y to install or N to skip."
    }
}

function Register-UpdateFailure {
    param([string]$Message)

    if (-not $script:Failures.Contains($Message)) {
        [void]$script:Failures.Add($Message)
    }
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
    Register-UpdateFailure "$Label failed with exit code $exitCode."
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
        [string]$PackageName,
        [switch]$RequireHostArchitecture
    )

    $updated = $false

    if (Test-NpmGlobalPackage $PackageName) {
        if ($RequireHostArchitecture -and -not (Test-WindowsJsRuntimeArchitecture "npm" $Label)) {
            # Native optional dependencies are selected from Node's architecture.
        } elseif (Invoke-Update "$Label via npm global package '$PackageName'" "npm.cmd" @("install", "-g", "$PackageName@latest")) {
            $updated = $true
        }
    }

    if (Test-PnpmGlobalPackage $PackageName) {
        if ($RequireHostArchitecture -and -not (Test-WindowsJsRuntimeArchitecture "pnpm" $Label)) {
            # pnpm uses the same Node runtime architecture check as npm.
        } elseif (Invoke-Update "$Label via pnpm global package '$PackageName'" "pnpm" @("add", "-g", "$PackageName@latest")) {
            $updated = $true
        }
    }

    if (Test-BunGlobalPackage $PackageName) {
        if ($RequireHostArchitecture -and -not (Test-WindowsJsRuntimeArchitecture "bun" $Label)) {
            # Bun also chooses native dependencies from its own architecture.
        } elseif (Invoke-Update "$Label via bun global package '$PackageName'" "bun" @("add", "-g", "$PackageName@latest")) {
            $updated = $true
        }
    }

    return $updated
}

function Get-WindowsJsRuntimeArchitecture {
    param([ValidateSet("npm", "pnpm", "bun")][string]$PackageManager)

    $runtimeArchitecture = $null
    if ($PackageManager -in @("npm", "pnpm") -and (Test-CommandAvailable "node.exe")) {
        $runtimeArchitecture = (& node.exe -p "process.arch" 2>$null | Select-Object -First 1)
    } elseif ($PackageManager -eq "bun" -and (Test-CommandAvailable "bun")) {
        $runtimeArchitecture = (& bun -p "process.arch" 2>$null | Select-Object -First 1)
    }

    switch -Regex ($runtimeArchitecture) {
        "^(?i:arm64)$" { return "Arm64" }
        "^(?i:x64|amd64|x86_64)$" { return "X64" }
        default { return "Unknown" }
    }
}

function Get-HostArchitectureNpmCommand {
    if ((Test-CommandAvailable "npm.cmd") -and (Get-WindowsJsRuntimeArchitecture "npm") -eq $script:OsArchitecture) {
        return (Get-PreferredCommand @("npm.cmd"))
    }

    $programFilesNpm = Join-Path $env:ProgramFiles "nodejs\npm.cmd"
    $programFilesNode = Join-Path $env:ProgramFiles "nodejs\node.exe"
    if ((Test-Path $programFilesNpm) -and (Test-Path $programFilesNode)) {
        $architecture = (& $programFilesNode -p "process.arch" 2>$null | Select-Object -First 1)
        if (($architecture -eq "arm64" -and $script:OsArchitecture -eq "Arm64") -or
            ($architecture -eq "x64" -and $script:OsArchitecture -eq "X64")) {
            return $programFilesNpm
        }
    }

    return $null
}

function Install-HostArchitectureNode {
    $nodePackageId = "OpenJS.NodeJS.LTS"
    if (-not (Test-CommandAvailable "winget")) {
        $message = "A $script:OsArchitecture Node.js runtime is required, but WinGet is unavailable."
        Write-Warning $message
        Register-UpdateFailure $message
        return $null
    }

    $arguments = @(
        "install", "--id", $nodePackageId, "--exact",
        "--architecture", $script:WingetArchitecture,
        "--force", "--silent",
        "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"
    )
    if (-not (Invoke-Update "Node.js LTS dependency ($script:WingetArchitecture)" "winget" $arguments)) {
        return $null
    }

    $npmCommand = Get-HostArchitectureNpmCommand
    if (-not $npmCommand) {
        $message = "Node.js was installed, but a $script:OsArchitecture npm runtime could not be resolved. Restart the terminal and rerun the updater."
        Write-Warning $message
        Register-UpdateFailure $message
        return $null
    }

    return $npmCommand
}

function Install-WindowsNpmPackage {
    param(
        [string]$Label,
        [string]$PackageName,
        [switch]$RequireHostArchitecture
    )

    $npmCommand = if ($RequireHostArchitecture) {
        Get-HostArchitectureNpmCommand
    } else {
        Get-PreferredCommand @("npm.cmd")
    }

    if (-not $npmCommand) {
        $npmCommand = Install-HostArchitectureNode
    }
    if (-not $npmCommand) {
        return $false
    }

    return Invoke-Update "$Label install via npm global package '$PackageName'" $npmCommand @("install", "-g", "$PackageName@latest")
}

function Test-WindowsJsRuntimeArchitecture {
    param(
        [ValidateSet("npm", "pnpm", "bun")][string]$PackageManager,
        [string]$Label
    )

    $runtimeArchitecture = Get-WindowsJsRuntimeArchitecture $PackageManager
    if ($runtimeArchitecture -eq $script:OsArchitecture) {
        return $true
    }

    $message = "$Label via $PackageManager was skipped: its runtime is $runtimeArchitecture but the Windows host is $script:OsArchitecture. Install a matching $script:OsArchitecture runtime or update this CLI inside WSL."
    Write-Skip $message
    if (-not $DryRun) {
        Register-UpdateFailure $message
    }
    return $false
}

function Test-WindowsNpmLikePackage {
    param([string]$PackageName)

    return (Test-NpmGlobalPackage $PackageName) -or
        (Test-PnpmGlobalPackage $PackageName) -or
        (Test-BunGlobalPackage $PackageName)
}

function Remove-WindowsNpmLikePackage {
    param(
        [string]$Label,
        [string]$PackageName
    )

    $allSucceeded = $true

    if (Test-NpmGlobalPackage $PackageName) {
        if (-not (Invoke-Update "Remove conflicting npm $Label installation" "npm.cmd" @("uninstall", "-g", $PackageName))) {
            $allSucceeded = $false
        }
    }

    if (Test-PnpmGlobalPackage $PackageName) {
        if (-not (Invoke-Update "Remove conflicting pnpm $Label installation" "pnpm" @("remove", "-g", $PackageName))) {
            $allSucceeded = $false
        }
    }

    if (Test-BunGlobalPackage $PackageName) {
        if (-not (Invoke-Update "Remove conflicting bun $Label installation" "bun" @("remove", "-g", $PackageName))) {
            $allSucceeded = $false
        }
    }

    return $allSucceeded
}

function Remove-WindowsClaudeJsPackages {
    return Remove-WindowsNpmLikePackage "Claude Code" "@anthropic-ai/claude-code"
}

function Get-RunningCodexProcesses {
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match "^(?i:codex)(?:$|-|\.)"
    })
}

function Update-WindowsCodex {
    Write-Section "Windows Codex"
    $cliUpdated = $false
    $jsPackageInstalled = Test-WindowsNpmLikePackage "@openai/codex"
    $codexCommand = Get-PreferredCommand @("codex.cmd", "codex.exe", "codex")

    if ($jsPackageInstalled) {
        $compatibleRuntimeInstalled = $false
        if ((Test-NpmGlobalPackage "@openai/codex") -and (Test-WindowsJsRuntimeArchitecture "npm" "Codex")) {
            $compatibleRuntimeInstalled = $true
        }
        if ((Test-PnpmGlobalPackage "@openai/codex") -and (Test-WindowsJsRuntimeArchitecture "pnpm" "Codex")) {
            $compatibleRuntimeInstalled = $true
        }
        if ((Test-BunGlobalPackage "@openai/codex") -and (Test-WindowsJsRuntimeArchitecture "bun" "Codex")) {
            $compatibleRuntimeInstalled = $true
        }

        if ($compatibleRuntimeInstalled) {
            $runningCodex = Get-RunningCodexProcesses
            if ($runningCodex.Count -gt 0 -and -not $DryRun) {
                $processList = ($runningCodex | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }) -join ", "
                $message = "Codex CLI update is blocked by running Codex processes: $processList. Close Codex sessions (including T3Code/ChatGPT Codex sessions) and rerun the updater."
                Write-Warning $message
                Register-UpdateFailure $message
            } else {
                $cliUpdated = Update-WindowsNpmLikePackage "Codex" "@openai/codex" -RequireHostArchitecture
            }
        }
    } else {
        if ($codexCommand) {
            $cliUpdated = Invoke-Update "Codex via native self-updater" $codexCommand @("update")
        } elseif (Confirm-ComponentInstall "Codex CLI") {
            $cliUpdated = Install-WindowsNpmPackage "Codex CLI" "@openai/codex" -RequireHostArchitecture
            if ($cliUpdated) {
                Write-Info "Restart your terminal if 'codex' is not yet found on PATH."
            }
        }
    }

    # The standalone Codex desktop app merged into the ChatGPT desktop app (July 2026)
    # but kept the same Microsoft Store package ID.
    if ($IncludeDesktopApps -and (Test-WingetPackage "9PLM9XGG6VKS")) {
        [void](Invoke-WingetUpgrade "ChatGPT desktop app (includes Codex) via Microsoft Store / winget package '9PLM9XGG6VKS'" "9PLM9XGG6VKS")
    } elseif ($IncludeDesktopApps -and (Confirm-ComponentInstall "ChatGPT desktop app")) {
        if (Test-CommandAvailable "winget") {
            [void](Invoke-WingetInstall "ChatGPT desktop app via Microsoft Store / winget package '9PLM9XGG6VKS'" "9PLM9XGG6VKS")
        } else {
            $message = "ChatGPT desktop app installation requires WinGet, but winget is unavailable."
            Write-Warning $message
            Register-UpdateFailure $message
        }
    } elseif (-not $IncludeDesktopApps -and (Test-WingetPackage "9PLM9XGG6VKS")) {
        Write-Info "ChatGPT desktop app (includes Codex) is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $cliUpdated -and -not $jsPackageInstalled -and -not $codexCommand) {
        Write-Skip "Codex CLI was not installed."
    } elseif (-not $DryRun) {
        Write-CommandVersion "Codex CLI current" @("codex.cmd", "codex.exe", "codex")
    }
}

function Update-WindowsClaude {
    Write-Section "Windows Claude"
    $cliUpdated = $false
    $wingetAvailable = Test-CommandAvailable "winget"
    $claudeCodePackageId = "Anthropic.ClaudeCode"
    $wingetCliInstalled = Test-WingetPackage $claudeCodePackageId
    $otherCliInstalled = (Test-WindowsNpmLikePackage "@anthropic-ai/claude-code") -or
        $null -ne (Get-PreferredCommand @("claude.exe", "claude.cmd", "claude"))
    $cliInstalled = $wingetCliInstalled -or $otherCliInstalled

    # WinGet selects Anthropic's native binary directly. Supplying the OS
    # architecture is important on Windows ARM64, where an x64 Node/npm
    # installation can otherwise select the emulated win32-x64 build.
    if ($wingetAvailable) {
        if ($wingetCliInstalled) {
            $cliUpdated = Invoke-WingetUpgrade `
                "Claude Code CLI via winget package '$claudeCodePackageId' ($script:WingetArchitecture)" `
                $claudeCodePackageId `
                $script:WingetArchitecture
        } elseif ($cliInstalled -or (Confirm-ComponentInstall "Claude Code CLI")) {
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

        if (-not $cliInstalled -and (Confirm-ComponentInstall "Claude Code CLI")) {
            $cliUpdated = Invoke-Update "Claude Code CLI install via Anthropic native installer" "powershell.exe" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm https://claude.ai/install.ps1 | iex")
            if ($cliUpdated) {
                Write-Info "Restart your terminal if 'claude' is not yet found on PATH."
            }
        }
    }

    $claudeDesktopInstalled = Test-WingetPackage "Anthropic.Claude"
    if ($IncludeDesktopApps -and $wingetAvailable -and $claudeDesktopInstalled) {
        [void](Invoke-WingetUpgrade `
            "Claude Desktop app via winget package 'Anthropic.Claude' ($script:WingetArchitecture)" `
            "Anthropic.Claude" `
            $script:WingetArchitecture)
    } elseif ($IncludeDesktopApps -and $wingetAvailable -and (Confirm-ComponentInstall "Claude Desktop app")) {
        [void](Invoke-WingetInstall `
            "Claude Desktop app via winget package 'Anthropic.Claude' ($script:WingetArchitecture)" `
            "Anthropic.Claude" `
            $script:WingetArchitecture)
    } elseif ($IncludeDesktopApps -and -not $wingetAvailable -and (Confirm-ComponentInstall "Claude Desktop app")) {
        Write-Skip "Claude Desktop app requires WinGet, but winget is unavailable."
        Register-UpdateFailure "Claude Desktop app installation requires WinGet, but winget is unavailable."
    } elseif (-not $IncludeDesktopApps -and $claudeDesktopInstalled) {
        Write-Info "Claude Desktop app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $cliUpdated -and -not $cliInstalled) {
        Write-Skip "Claude Code CLI was not installed."
    }

    if ($cliUpdated -and -not $DryRun) {
        Write-CommandVersion "Claude Code CLI" @("claude.exe", "claude.cmd", "claude")
    }
}

function Update-WindowsOpenCode {
    Write-Section "Windows OpenCode"
    $updated = $false
    $wingetPackageId = "SST.opencode"
    $wingetInstalled = Test-WingetPackage $wingetPackageId
    $otherInstallPresent = (Test-ChocoPackage "opencode") -or
        (Test-WindowsNpmLikePackage "opencode-ai") -or
        $null -ne (Get-PreferredCommand @("opencode.exe", "opencode.cmd", "opencode"))
    $installed = $wingetInstalled -or $otherInstallPresent

    if (Test-CommandAvailable "winget") {
        if ($wingetInstalled) {
            $updated = Invoke-WingetUpgrade `
                "OpenCode via winget package '$wingetPackageId' ($script:WingetArchitecture)" `
                $wingetPackageId `
                $script:WingetArchitecture
        } elseif ($installed -or (Confirm-ComponentInstall "OpenCode CLI")) {
            $updated = Invoke-WingetInstall `
                "OpenCode via winget package '$wingetPackageId' ($script:WingetArchitecture)" `
                $wingetPackageId `
                $script:WingetArchitecture
        }

        if ($updated) {
            if (-not (Remove-WindowsNpmLikePackage "OpenCode" "opencode-ai")) {
                Write-Warning "OpenCode was installed through WinGet, but a conflicting JavaScript-package installation could not be removed."
            }

            if (Test-ChocoPackage "opencode") {
                [void](Invoke-Update "Remove conflicting Chocolatey OpenCode installation" "choco" @("uninstall", "opencode", "-y"))
            }
        }
    } elseif (-not $script:IsWindowsArm) {
        Write-Info "WinGet is unavailable; falling back to recognized x64 OpenCode installation methods."
        if (Test-ChocoPackage "opencode") {
            $updated = Invoke-Update "OpenCode via Chocolatey package 'opencode'" "choco" @("upgrade", "opencode", "-y")
        }
        if (Update-WindowsNpmLikePackage "OpenCode" "opencode-ai" -RequireHostArchitecture) {
            $updated = $true
        }
        if (-not $installed -and (Confirm-ComponentInstall "OpenCode CLI")) {
            $updated = Install-WindowsNpmPackage "OpenCode CLI" "opencode-ai" -RequireHostArchitecture
        }
    } else {
        if ($installed -or (Confirm-ComponentInstall "OpenCode CLI")) {
            $message = "OpenCode requires WinGet on Windows ARM64 so the native arm64 package can be selected safely."
            Write-Skip $message
            if (-not $DryRun) {
                Register-UpdateFailure $message
            }
        }
    }

    if (-not $updated -and -not $installed) {
        Write-Skip "OpenCode CLI was not installed."
    } elseif (-not $DryRun) {
        Write-CommandVersion "OpenCode CLI" @("opencode.exe", "opencode.cmd", "opencode")
    }
}

function Update-WindowsCursor {
    Write-Section "Windows Cursor"
    $cliUpdated = $false

    $cursorAgent = Get-PreferredCommand @("cursor-agent.cmd", "cursor-agent.exe", "cursor-agent")
    if ($cursorAgent) {
        if (Invoke-Update "Cursor Agent via cursor-agent self-updater" $cursorAgent @("update")) {
            $cliUpdated = $true
        }
    }

    if (-not $cursorAgent) {
        $agent = Get-PreferredCommand @("agent.cmd", "agent.exe", "agent")
        if ($agent) {
            if (Invoke-Update "Cursor Agent via T3Code-style 'agent' self-updater" $agent @("update")) {
                $cliUpdated = $true
            }
        } elseif (Confirm-ComponentInstall "Cursor Agent CLI") {
            $cliUpdated = Invoke-Update "Cursor Agent CLI via official Windows installer" "powershell.exe" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "irm 'https://cursor.com/install?win32=true' | iex")
            if ($cliUpdated) {
                Write-Info "Restart your terminal if 'cursor-agent' is not yet found on PATH."
            }
        }
    }

    $cursorDesktopId = "Anysphere.Cursor"
    $cursorDesktopInstalled = Test-WingetPackage $cursorDesktopId
    if ($IncludeDesktopApps -and $cursorDesktopInstalled) {
        [void](Invoke-WingetUpgrade "Cursor desktop app via winget package '$cursorDesktopId' ($script:WingetArchitecture)" $cursorDesktopId $script:WingetArchitecture)
    } elseif ($IncludeDesktopApps -and (Confirm-ComponentInstall "Cursor desktop app")) {
        if (Test-CommandAvailable "winget") {
            [void](Invoke-WingetInstall "Cursor desktop app via winget package '$cursorDesktopId' ($script:WingetArchitecture)" $cursorDesktopId $script:WingetArchitecture)
        } else {
            $message = "Cursor desktop app installation requires WinGet, but winget is unavailable."
            Write-Warning $message
            Register-UpdateFailure $message
        }
    } elseif (-not $IncludeDesktopApps -and $cursorDesktopInstalled) {
        Write-Info "Cursor desktop app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $cliUpdated -and -not $cursorAgent -and -not (Get-PreferredCommand @("agent.cmd", "agent.exe", "agent"))) {
        Write-Skip "Cursor Agent CLI was not installed."
    }
}

function Update-WindowsT3Code {
    Write-Section "Windows T3Code"

    if ($script:IsWindowsArm) {
        Write-Skip "T3Code is not natively supported on Windows ARM64. Its CLI and desktop app will not be installed or updated."
        return
    }

    $cliInstalled = (Test-WindowsNpmLikePackage "t3") -or
        $null -ne (Get-PreferredCommand @("t3.cmd", "t3.exe", "t3"))
    $cliUpdated = Update-WindowsNpmLikePackage "T3Code" "t3"
    if (-not $cliInstalled -and (Confirm-ComponentInstall "T3Code CLI")) {
        $cliUpdated = Install-WindowsNpmPackage "T3Code CLI" "t3" -RequireHostArchitecture
    }

    $desktopPackageId = "T3Tools.T3Code"
    $desktopInstalled = Test-WingetPackage $desktopPackageId
    if ($IncludeDesktopApps -and $desktopInstalled) {
        [void](Invoke-WingetUpgrade "T3Code desktop app via winget package '$desktopPackageId' (x64)" $desktopPackageId "x64")
    } elseif ($IncludeDesktopApps -and (Confirm-ComponentInstall "T3Code desktop app")) {
        if (Test-CommandAvailable "winget") {
            [void](Invoke-WingetInstall "T3Code desktop app via winget package '$desktopPackageId' (x64)" $desktopPackageId "x64")
        } else {
            $message = "T3Code desktop app installation requires WinGet, but winget is unavailable."
            Write-Warning $message
            Register-UpdateFailure $message
        }
    } elseif (-not $IncludeDesktopApps -and $desktopInstalled) {
        Write-Info "T3Code desktop app is installed; skipping because -IncludeDesktopApps was not specified."
    }

    if (-not $cliUpdated -and -not $cliInstalled) {
        Write-Skip "T3Code CLI was not installed."
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
FAILURES=0
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.cursor/bin:$PATH"

section() {
  printf '\n== WSL %s ==\n' "$1"
}

skip() {
  printf 'SKIP: %s\n' "$1"
}

confirm_install() {
  label="$1"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'PROMPT: %s is not installed; a live run would ask whether to install it.\n' "$label"
    return 1
  fi
  while true; do
    printf '%s is not installed. Install it? [y/N] ' "$label"
    IFS= read -r response || response=""
    case "$response" in
      y|Y|yes|YES|Yes) return 0 ;;
      ""|n|N|no|NO|No)
        skip "$label installation was declined."
        return 1
        ;;
      *) printf 'INFO: Enter Y to install or N to skip.\n' ;;
    esac
  done
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
  FAILURES=$((FAILURES + 1))
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

install_npm_global_package() {
  label="$1"
  package="$2"
  if ! have_native_npm; then
    printf 'WARNING: %s requires a native WSL Node.js/npm installation.\n' "$label"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  root="$(npm_global_root)"
  needs_sudo=0
  if path_requires_sudo "$root"; then
    needs_sudo=1
  fi
  run_update_maybe_sudo "$label install via npm global package '$package'" "$needs_sudo" npm install -g "$package@latest"
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
  if confirm_install "Codex CLI in WSL"; then
    if run_update "Codex CLI via official standalone installer" bash -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'; then
      codex_updated=0
    fi
  elif [ -n "$path" ] && is_windows_path "$path"; then
    skip "Codex only resolves to a Windows PATH shim in WSL: $path"
  fi
fi
if [ "$codex_updated" -eq 0 ]; then
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
  if confirm_install "Claude Code CLI in WSL"; then
    if run_update "Claude Code CLI via Anthropic native installer" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
      claude_updated=0
    fi
  elif [ -n "$path" ] && is_windows_path "$path"; then
    skip "Claude only resolves to a Windows PATH shim in WSL: $path"
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
  if confirm_install "OpenCode CLI in WSL"; then
    if run_update "OpenCode CLI via official installer" bash -c 'curl -fsSL https://opencode.ai/install | bash'; then
      opencode_updated=0
    fi
  elif [ -n "$path" ] && is_windows_path "$path"; then
    skip "OpenCode only resolves to a Windows PATH shim in WSL: $path"
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
  if confirm_install "Cursor Agent CLI in WSL"; then
    if run_update "Cursor Agent CLI via official installer" bash -c 'curl -fsSL https://cursor.com/install | bash'; then
      cursor_updated=0
    fi
  fi
fi

section "T3Code"
t3code_updated=1
update_js_package_methods "T3Code" "t3" && t3code_updated=0
if [ "$t3code_updated" -ne 0 ]; then
  path="$(cmd_path t3)"
  if confirm_install "T3Code CLI in WSL"; then
    if install_npm_global_package "T3Code CLI" "t3"; then
      t3code_updated=0
    fi
  elif [ -n "$path" ] && is_windows_path "$path"; then
    skip "T3Code only resolves to a Windows PATH shim in WSL: $path"
  fi
fi
if [ "$t3code_updated" -eq 0 ]; then
  print_version "T3Code CLI" t3
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\nWARNING: WSL updates finished with %s failed command(s).\n' "$FAILURES"
  exit 1
fi
'@

    $tempScript = New-TemporaryFile
    Set-UnixTextFile -Path $tempScript.FullName -Value $bashScript

    try {
        $wslScriptPath = ConvertTo-WslPath $tempScript.FullName
        if ([string]::IsNullOrWhiteSpace($wslScriptPath)) {
            $message = "Could not translate temporary script path for WSL distro '$Distro'."
            Write-Warning $message
            Register-UpdateFailure $message
            return
        }

        $dryRunValue = if ($DryRun) { "1" } else { "0" }
        wsl.exe -d $Distro -- env "T3_UPDATE_DRY_RUN=$dryRunValue" bash $wslScriptPath
        if ($LASTEXITCODE -ne 0) {
            $message = "WSL update block failed with exit code $LASTEXITCODE."
            Write-Warning $message
            Register-UpdateFailure $message
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
if ($script:Failures.Count -gt 0) {
    Write-Host "AI CLI updater finished with $($script:Failures.Count) failure(s):" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "AI CLI updater finished successfully." -ForegroundColor Cyan
exit 0
