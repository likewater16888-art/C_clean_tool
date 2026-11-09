<#
.SYNOPSIS
    Read-only Windows 11 system-drive audit for the win11-storage-governance skill.

.DESCRIPTION
    Measures known hot paths on the system drive, assigns a risk class to every path,
    and writes a Markdown + CSV report. This script NEVER deletes, moves, or modifies
    anything. It skips reparse points (junctions/symlinks) so it cannot wander into
    other trees.

.PARAMETER Top
    Number of rows printed in the console table (default 25).

.PARAMETER OutDir
    Report output directory (default .\reports).

.PARAMETER MaxSecondsPerPath
    Enumeration budget per path (default 45). A row that exceeds it is marked TRUNCATED.

.PARAMETER Deep
    Also measure the slow system trees (WinSxS, Windows Installer cache, WindowsApps,
    UWP Packages, whole LocalAppData/Roaming, browser profile roots, package stores).
    Adds several minutes. Off by default so a first audit stays fast.

.PARAMETER AppDataDetail
    Also measure every direct subdirectory of %LOCALAPPDATA% and %APPDATA%. Slow but
    usually the highest-value view on a bloated machine.

.PARAMETER FullTopLevel
    Also measure every top-level directory of the system drive. Slow.

.PARAMETER NoReport
    Print to console only, do not write files.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-CDriveAudit.ps1 -Top 25
#>
[CmdletBinding()]
param(
    [int]$Top = 25,
    [string]$OutDir = (Join-Path (Get-Location).Path 'reports'),
    [int]$MaxSecondsPerPath = 45,
    [switch]$Deep,
    [switch]$AppDataDetail,
    [switch]$FullTopLevel,
    [switch]$NoReport
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$scriptSw = [System.Diagnostics.Stopwatch]::StartNew()

# ----------------------------------------------------------------------------- helpers

function Get-PathSize {
    param([string]$Path, [int]$MaxSeconds = 90)

    $res = [pscustomobject]@{ Bytes = 0L; Files = 0; Truncated = $false; Exists = $false }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $res }
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $res }
    $res.Exists = $true

    if (-not $item.PSIsContainer) {
        $res.Bytes = [int64]$item.Length
        $res.Files = 1
        return $res
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $bytes = [int64]0
    $files = 0
    $truncated = $false
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($item.FullName)

    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { $truncated = $true; break }
        $cur = $stack.Pop()

        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                try {
                    $bytes += [System.IO.FileInfo]::new($f).Length
                    $files++
                } catch { }
                if (($files % 4000) -eq 0 -and $sw.Elapsed.TotalSeconds -gt $MaxSeconds) {
                    $truncated = $true
                    break
                }
            }
        } catch { }
        if ($truncated) { break }

        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                try {
                    $attr = [System.IO.File]::GetAttributes($d)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push($d)
                } catch { }
            }
        } catch { }
    }

    $res.Bytes = $bytes
    $res.Files = $files
    $res.Truncated = $truncated
    return $res
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0,8:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0,8:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0,8:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0,8:N0} B ' -f $Bytes)
}

function Add-Target {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Label,
        [string]$Path,
        [string]$Risk,
        [string]$Next = '',
        [switch]$Container,
        [switch]$Slow
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    $List.Add([pscustomobject]@{
        Label     = $Label
        Path      = $expanded
        Risk      = $Risk
        Next      = $Next
        Container = [bool]$Container
        Slow      = [bool]$Slow
    })
}

# ----------------------------------------------------------------------------- targets

$sysDrive = $env:SystemDrive
$localApp = $env:LOCALAPPDATA
$roamApp  = $env:APPDATA

$targets = New-Object 'System.Collections.Generic.List[object]'

# System drive / Windows managed
Add-Target $targets 'User TEMP' "$env:TEMP" 'safe-clean' 'files older than N days'
Add-Target $targets 'Windows TEMP' "$env:SystemRoot\Temp" 'safe-clean' 'files older than N days'
Add-Target $targets 'Windows Update download cache' "$env:SystemRoot\SoftwareDistribution\Download" 'official-tool' 'Settings > Windows Update or Disk Cleanup'
Add-Target $targets 'Delivery Optimization cache' "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization" 'official-tool' 'Disk Cleanup > Delivery Optimization Files'
Add-Target $targets 'Windows Error Reporting queue' "$localApp\Microsoft\Windows\WER" 'safe-clean' 'Settings > Temporary files'
Add-Target $targets 'Crash dumps (LiveKernelReports)' "$env:SystemRoot\LiveKernelReports" 'safe-clean' 'review before delete'
Add-Target $targets 'Minidump' "$env:SystemRoot\Minidump" 'safe-clean' 'review before delete'
Add-Target $targets 'MEMORY.DMP' "$env:SystemRoot\MEMORY.DMP" 'safe-clean' 'disable dump writing in System settings'
Add-Target $targets 'Prefetch' "$env:SystemRoot\Prefetch" 'safe-clean' 'system regenerates it'
Add-Target $targets 'Windows.old (previous install)' "$sysDrive\Windows.old" 'official-tool' 'Settings > System > Storage > Temporary files'
Add-Target $targets 'Recycle Bin' "$sysDrive\`$Recycle.Bin" 'safe-clean' 'empty only after user agrees'
Add-Target $targets 'Hibernation file' "$sysDrive\hiberfil.sys" 'official-tool' 'powercfg /a then powercfg /h off'
Add-Target $targets 'Page file' "$sysDrive\pagefile.sys" 'official-tool' 'System > Advanced > Performance > Virtual memory'
Add-Target $targets 'Swap file' "$sysDrive\swapfile.sys" 'official-tool' 'tied to page file settings'
Add-Target $targets 'Windows Installer cache' "$env:SystemRoot\Installer" 'do-not-touch' 'MSI repair/uninstall chains depend on it' -Slow
Add-Target $targets 'WinSxS component store' "$env:SystemRoot\WinSxS" 'official-tool' 'DISM /Online /Cleanup-Image /AnalyzeComponentStore' -Slow
Add-Target $targets 'WindowsApps (Store apps)' "$env:ProgramFiles\WindowsApps" 'do-not-touch' 'Settings > Apps > Move or Uninstall' -Slow

# User profile containers
Add-Target $targets 'LocalAppData (total)' "$localApp" 'investigate' 'break down with -AppDataDetail' -Container -Slow
Add-Target $targets 'Roaming AppData (total)' "$roamApp" 'investigate' 'break down with -AppDataDetail' -Container -Slow
Add-Target $targets 'UWP app data (Packages)' "$localApp\Packages" 'investigate' 'per-app; move via Settings' -Slow
Add-Target $targets 'Per-user programs' "$localApp\Programs" 'migrate-configure' 'reinstall to a non-system drive'
Add-Target $targets 'VS Code extensions' "$env:USERPROFILE\.vscode\extensions" 'investigate' 'extensions reinstall on demand'
Add-Target $targets 'Docker Desktop data' "$localApp\Docker" 'investigate' 'move disk image via Docker settings' -Slow
Add-Target $targets 'WSL distro disks' "$localApp\wsl" 'investigate' 'wsl --export then wsl --import on another drive' -Slow

# Package managers and dev caches
Add-Target $targets 'npm cache' "$localApp\npm-cache" 'migrate-configure' 'npm config set cache <dir>'
Add-Target $targets 'npm cache (roaming)' "$roamApp\npm-cache" 'migrate-configure' 'npm config set cache <dir>'
Add-Target $targets 'pnpm store' "$localApp\pnpm" 'migrate-configure' 'pnpm config set store-dir <dir>'
Add-Target $targets 'Yarn cache' "$localApp\Yarn\Cache" 'migrate-configure' 'yarn config set cacheFolder <dir>'
Add-Target $targets 'pip cache' "$localApp\pip\Cache" 'migrate-configure' 'set PIP_CACHE_DIR'
Add-Target $targets 'uv cache' "$localApp\uv\cache" 'migrate-configure' 'set UV_CACHE_DIR'
Add-Target $targets 'NuGet packages' "$env:USERPROFILE\.nuget\packages" 'migrate-configure' 'set NUGET_PACKAGES' -Slow
Add-Target $targets 'NuGet http cache' "$localApp\NuGet\v3-cache" 'migrate-configure' 'dotnet nuget locals http-cache --clear'
Add-Target $targets 'Cargo home' "$env:USERPROFILE\.cargo" 'migrate-configure' 'set CARGO_HOME' -Slow
Add-Target $targets 'Gradle cache' "$env:USERPROFILE\.gradle" 'migrate-configure' 'set GRADLE_USER_HOME' -Slow
Add-Target $targets 'Maven repository' "$env:USERPROFILE\.m2" 'migrate-configure' 'settings.xml localRepository' -Slow
Add-Target $targets 'Scoop root' "$env:USERPROFILE\scoop" 'migrate-configure' 'scoop config / SCOOP env var'
Add-Target $targets 'winget local data' "$localApp\Microsoft\WinGet" 'migrate-configure' 'winget settings portablePackageUserRoot'
Add-Target $targets 'Playwright browsers' "$localApp\ms-playwright" 'migrate-configure' 'set PLAYWRIGHT_BROWSERS_PATH'
Add-Target $targets 'Puppeteer browsers' "$localApp\puppeteer" 'migrate-configure' 'set PUPPETEER_CACHE_DIR'
Add-Target $targets 'Hugging Face cache' "$env:USERPROFILE\.cache\huggingface" 'migrate-configure' 'set HF_HOME'
Add-Target $targets 'Torch cache' "$env:USERPROFILE\.cache\torch" 'migrate-configure' 'set TORCH_HOME'
Add-Target $targets 'User .cache (other)' "$env:USERPROFILE\.cache" 'investigate' 'inspect before moving'
Add-Target $targets 'JetBrains caches' "$localApp\JetBrains" 'migrate-configure' 'IDE system/cache path settings'

# Browsers
Add-Target $targets 'Chrome profile root' "$localApp\Google\Chrome\User Data" 'investigate' 'never junction the profile root' -Container -Slow
Add-Target $targets 'Chrome Default cache' "$localApp\Google\Chrome\User Data\Default\Cache" 'safe-clean' 'close the browser first'
Add-Target $targets 'Chrome Default Code Cache' "$localApp\Google\Chrome\User Data\Default\Code Cache" 'safe-clean' 'close the browser first'
Add-Target $targets 'Chrome Default GPUCache' "$localApp\Google\Chrome\User Data\Default\GPUCache" 'safe-clean' 'close the browser first'
Add-Target $targets 'Edge profile root' "$localApp\Microsoft\Edge\User Data" 'investigate' 'never junction the profile root' -Container -Slow
Add-Target $targets 'Edge Default cache' "$localApp\Microsoft\Edge\User Data\Default\Cache" 'safe-clean' 'close the browser first'
Add-Target $targets 'Firefox profiles' "$localApp\Mozilla\Firefox\Profiles" 'investigate' 'cache only, never the profile root'

# GPU / shader caches
Add-Target $targets 'NVIDIA DXCache' "$localApp\NVIDIA\DXCache" 'safe-clean' 'games recompile shaders'
Add-Target $targets 'NVIDIA GLCache' "$localApp\NVIDIA\GLCache" 'safe-clean' 'games recompile shaders'
Add-Target $targets 'DirectX shader cache' "$localApp\D3DSCache" 'safe-clean' 'games recompile shaders'

# Chat apps (cache vs user data must be separated first)
Add-Target $targets 'Teams (classic) data' "$roamApp\Microsoft\Teams" 'investigate' 'separate cache from chat history'
Add-Target $targets 'Slack data' "$roamApp\Slack" 'investigate' 'separate cache from chat history'
Add-Target $targets 'WeChat Files' "$env:USERPROFILE\Documents\WeChat Files" 'investigate' 'user chat data, move via app settings'
Add-Target $targets 'Tencent Files (QQ)' "$env:USERPROFILE\Documents\Tencent Files" 'investigate' 'user chat data, move via app settings'

# Electron updater leftovers
try {
    Get-ChildItem -LiteralPath $localApp -Directory -Filter '*-updater' -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Add-Target $targets ("Electron updater leftovers ({0})" -f $_.Name) (Join-Path $_.FullName 'pending') 'safe-clean' 'stale installer payload'
        }
} catch { }

# Optional: per-subdirectory AppData breakdown
if ($AppDataDetail) {
    foreach ($root in @($localApp, $roamApp)) {
        if ($root -eq $localApp) { $rootLabel = 'LocalAppData' } else { $rootLabel = 'Roaming' }
        try {
            Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $name = $_.Name.ToLowerInvariant()
                $risk = 'investigate'
                if ($name -match 'cache|temp|caches|shadercache|crashpad|gpucache|logs') { $risk = 'safe-clean' }
                Add-Target $targets ("{0} subdir: {1}" -f $rootLabel, $_.Name) $_.FullName $risk 'confirm before acting' -Container
            }
        } catch { }
    }
}

# Optional: every top-level directory of the system drive
if ($FullTopLevel) {
    Get-ChildItem -LiteralPath ($sysDrive + '\') -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $risk = 'investigate'
        if ($_.Name -match '^(Windows|Program Files|Program Files \(x86\)|ProgramData)$') { $risk = 'do-not-touch' }
        Add-Target $targets ("Top-level: {0}" -f $_.Name) $_.FullName $risk 'drill down before acting' -Container
    }
}

# ----------------------------------------------------------------------------- measure

$seen = @{}
$skippedSlow = 0
$skippedLabels = New-Object 'System.Collections.Generic.List[string]'
$rows = New-Object 'System.Collections.Generic.List[object]'

foreach ($t in $targets) {
    $key = $t.Path.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    if ($t.Slow -and -not $Deep) {
        $skippedSlow++
        $skippedLabels.Add($t.Label)
        continue
    }

    $size = Get-PathSize -Path $t.Path -MaxSeconds $MaxSecondsPerPath
    if (-not $size.Exists) { continue }

    $rows.Add([pscustomobject]@{
        Label     = $t.Label
        Path      = $t.Path
        Risk      = $t.Risk
        Next      = $t.Next
        Container = $t.Container
        SizeBytes = $size.Bytes
        Size      = (Format-Size $size.Bytes)
        Files     = $size.Files
        Truncated = $size.Truncated
    })
}

$rows = @($rows | Sort-Object SizeBytes -Descending)

# ----------------------------------------------------------------------------- volumes

$volumes = @()
try {
    $volumes = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Used -ne $null } |
        ForEach-Object {
            [pscustomobject]@{
                Drive  = $_.Name
                UsedGB = [math]::Round($_.Used / 1GB, 1)
                FreeGB = [math]::Round($_.Free / 1GB, 1)
            }
        })
} catch { }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ----------------------------------------------------------------------------- console output

Write-Output ''
Write-Output '=== Volumes ==='
$volumes | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Write-Output ('Elevated: {0}   (DISM / component cleanup needs elevation)' -f $isAdmin)
Write-Output ''

Write-Output ('=== Top {0} by size (read-only) ===' -f $Top)
$rows |
    Select-Object -First $Top @{n = 'Size'; e = { $_.Size }}, Risk, Label, Path, Files, Truncated |
    Format-Table -AutoSize | Out-String -Width 320 | Write-Output

Write-Output '=== Totals by risk class (containers excluded to avoid double counting) ==='
$rows |
    Where-Object { -not $_.Container } |
    Group-Object Risk |
    ForEach-Object {
        [pscustomobject]@{
            Risk  = $_.Name
            Size  = (Format-Size ([int64](($_.Group | Measure-Object SizeBytes -Sum).Sum))).Trim()
            Paths = $_.Count
        }
    } |
    Sort-Object Risk |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Output

if ($skippedSlow -gt 0) {
    Write-Output ('Skipped {0} slow paths (large system trees). Re-run with -Deep to measure them.' -f $skippedSlow)
    Write-Output ('  ' + ($skippedLabels -join ', '))
}
Write-Output 'Reminder: this audit only measured sizes. Nothing was deleted, moved, or modified.'

# ----------------------------------------------------------------------------- report files

if (-not $NoReport) {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $mdPath = Join-Path $OutDir ('audit-{0}.md' -f $stamp)
    $csvPath = Join-Path $OutDir ('audit-{0}.csv' -f $stamp)

    $md = New-Object 'System.Collections.Generic.List[string]'
    $md.Add('# Windows 11 C-drive audit (read-only)')
    $md.Add('')
    $md.Add(('- Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $md.Add(('- User: `{0}`   Elevated: {1}' -f $env:USERNAME, $isAdmin))
    $md.Add(('- System drive: `{0}`   Enumeration budget per path: {1}s' -f $sysDrive, $MaxSecondsPerPath))
    if ($skippedSlow -gt 0) {
        $md.Add(('- Not measured (slow trees, use -Deep): {0}' -f ($skippedLabels -join ', ')))
    }
    $md.Add('')
    $md.Add('## Volumes')
    $md.Add('')
    $md.Add('| Drive | Used GB | Free GB |')
    $md.Add('|---|---|---|')
    foreach ($v in $volumes) { $md.Add(('| {0}: | {1} | {2} |' -f $v.Drive, $v.UsedGB, $v.FreeGB)) }
    $md.Add('')
    $md.Add('## Hot paths by size')
    $md.Add('')
    $md.Add('| Size | Risk | Label | Path | Files | Note / next step |')
    $md.Add('|---|---|---|---|---|---|')
    foreach ($r in $rows) {
        if ($r.Truncated) { $flag = ' (TRUNCATED)' } else { $flag = '' }
        $md.Add(('| {0}{1} | {2} | {3} | `{4}` | {5} | {6} |' -f $r.Size.Trim(), $flag, $r.Risk, $r.Label, $r.Path, $r.Files, $r.Next))
    }
    $md.Add('')
    $md.Add('## Totals by risk class (containers excluded)')
    $md.Add('')
    $md.Add('| Risk | Size | Paths |')
    $md.Add('|---|---|---|')
    foreach ($g in ($rows | Where-Object { -not $_.Container } | Group-Object Risk | Sort-Object Name)) {
        $sum = (Format-Size ([int64](($g.Group | Measure-Object SizeBytes -Sum).Sum))).Trim()
        $md.Add(('| {0} | {1} | {2} |' -f $g.Name, $sum, $g.Count))
    }
    $md.Add('')
    $md.Add('## How to read this report')
    $md.Add('')
    $md.Add('- `safe-clean`: regenerable temp/cache. Cleanup candidate after the owning app is closed.')
    $md.Add('- `official-tool`: handled by DISM, Windows Settings, Disk Cleanup, or a vendor tool. Never by hand.')
    $md.Add('- `migrate-configure`: move it by configuration (package-manager setting or environment variable), not by junction.')
    $md.Add('- `investigate`: may contain user data. Classify before touching.')
    $md.Add('- `do-not-touch`: system servicing store or installer cache. Report only.')
    $md.Add('- Rows flagged as containers overlap other rows and are excluded from the risk totals.')
    $md.Add('')
    $md.Add('> This report is read-only. Nothing was deleted or moved.')
    $md.Add('')

    Set-Content -LiteralPath $mdPath -Value $md -Encoding UTF8
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    Write-Output ''
    Write-Output ('Report: {0}' -f $mdPath)
    Write-Output ('CSV   : {0}' -f $csvPath)
}

Write-Output ('Elapsed: {0:N1}s' -f $scriptSw.Elapsed.TotalSeconds)
