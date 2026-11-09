<#
.SYNOPSIS
    Allowlisted, quarantine-first cleanup for the win11-storage-governance skill.

.DESCRIPTION
    Default mode is a DRY RUN: it only reports what would be removed and how much
    space would be freed. With -Execute, candidates are MOVED into a quarantine
    folder (restorable for KeepDays) instead of being deleted, and a JSON log is
    written.

    Blacklisted system locations are rejected before anything runs, so a bad path
    cannot be passed through the allowlist.

.PARAMETER OlderThanDays
    Only touch files whose LastWriteTime is older than this many days (default 7).

.PARAMETER QuarantineRoot
    Where -Execute moves files. Default: <SystemDrive>\Quarantine if the system drive
    has room, otherwise the drive with the most free space among C:..Z:.

.PARAMETER IncludeBrowserCache
    Also process browser Cache / Code Cache / GPUCache. Close browsers first.

.PARAMETER IncludeShaderCache
    Also process NVIDIA / DirectX shader caches. Games will recompile shaders.

.PARAMETER Execute
    Actually move the candidates to quarantine. Without it nothing is changed.

.PARAMETER LogDir
    Where the JSON log is written (default .\reports).

.PARAMETER MaxScanSecondsPerRoot
    Scan budget per allowlisted root (default 120, or 900 with -Execute). A root that
    exceeds it is reported as TRUNCATED and its numbers are a lower bound. %TEMP% on a
    busy dev machine can hold close to 100k directories, so a full PowerShell walk of it
    takes about two minutes.

.PARAMETER Scanner
    Auto (default) uses robocopy for the dry-run measurement (about 6x faster, roughly
    20s for an 11 GB %TEMP%) and the PowerShell walk when -Execute needs exact per-file
    paths. Robocopy | PowerShell force one implementation.

.PARAMETER OnlyRoots
    Restrict the run to these allowlist root labels, e.g. 'User TEMP','Windows TEMP'.
    Labels come from the per-root table. Unmatched labels fall back to every root.

.PARAMETER PlanJson
    Dry-run only: also write a machine-readable plan (summary JSON + full item CSV next
    to it) so a GUI can show what would be moved. Implies a PowerShell scan unless
    -Scanner is given, because only the walk knows exact file paths.

.PARAMETER ProgressFile
    -Execute only: append one JSON line every 25 items (done/total/moved/failed/bytes/
    current path) plus a final line, so a GUI can show live progress.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-SafeClean.ps1 -OlderThanDays 7

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-SafeClean.ps1 -OlderThanDays 7 -Execute
#>
[CmdletBinding()]
param(
    [int]$OlderThanDays = 7,
    [string]$QuarantineRoot = '',
    [switch]$IncludeBrowserCache,
    [switch]$IncludeShaderCache,
    [switch]$Execute,
    [string]$LogDir = (Join-Path (Get-Location).Path 'reports'),
    [int]$KeepDays = 14,
    [int]$MaxScanSecondsPerRoot = 120,
    [ValidateSet('Auto', 'Robocopy', 'PowerShell')]
    [string]$Scanner = 'Auto',
    [string[]]$OnlyRoots = @(),
    [string]$PlanJson = '',
    [string]$ProgressFile = ''
)

if ($Execute -and -not $PSBoundParameters.ContainsKey('MaxScanSecondsPerRoot')) {
    # Execution must be complete, so allow a much longer walk than the dry run.
    $MaxScanSecondsPerRoot = 900
}
if ($Scanner -eq 'Auto') {
    if ($Execute) { $Scanner = 'PowerShell' } else { $Scanner = 'Robocopy' }
}
if ($PlanJson -and -not $PSBoundParameters.ContainsKey('Scanner')) {
    # Only the PowerShell walk knows exact file paths, which a per-file plan needs.
    $Scanner = 'PowerShell'
}

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ----------------------------------------------------------------------------- safety

# Any candidate path matching one of these is refused outright.
$blockedPatterns = @(
    '\\Windows\\Installer(\\|$)',
    '\\Windows\\WinSxS(\\|$)',
    '\\Program Files\\WindowsApps(\\|$)',
    '\\Windows\\System32(\\|$)',
    '\\Windows\\SysWOW64(\\|$)',
    '\\Windows\\servicing(\\|$)',
    '\\System Volume Information(\\|$)',
    '(\\|^)ProgramData(\\|$)',
    '\\AppData\\Roaming$',
    '\\Documents(\\|$)',
    '\\Desktop(\\|$)',
    '\\Downloads(\\|$)',
    '\\OneDrive(\\|$)',
    '\.ssh(\\|$)',
    '\.git(\\|$)'
)

$blockedRegex = [regex]::new(
    ($blockedPatterns -join '|'),
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

function Test-BlockedPath {
    param([string]$Path)
    $m = $blockedRegex.Match($Path)
    if ($m.Success) { return $m.Value }
    return $null
}

# Directory names robocopy must never descend into (belt and braces on top of the regex).
$blockedDirNames = @(
    '.git', '.ssh', 'OneDrive', 'Documents', 'Desktop', 'Downloads',
    'System Volume Information', 'WinSxS', 'Installer', 'WindowsApps'
)

<#
    Robocopy-based measurement.
    /L list only, /S recurse, /XJ skip junctions, /MINAGE keeps only files older than n
    days, /BYTES raw sizes, /FP full paths, /TS timestamps.
    Only the leading size token of each data line is parsed, so the numbers stay correct
    even when the console code page mangles non-ASCII path characters.
    Returns @{ Files; Bytes } or $null when robocopy is unavailable.
#>
function Get-RobocopyMeasure {
    param([string]$Path, [int]$AgeDays)

    $rc = Get-Command 'robocopy.exe' -ErrorAction SilentlyContinue
    if (-not $rc) { return $null }

    $xd = @()
    foreach ($name in $blockedDirNames) { $xd += $name }

    $raw = & robocopy.exe $Path 'NULL' /L /S /XJ /MINAGE:$AgeDays /BYTES /FP /TS /NC /NDL /NJH /NJS /R:0 /W:0 /XD @xd 2>$null
    if ($LASTEXITCODE -ge 8) { return $null }

    $files = 0
    $bytes = [int64]0
    foreach ($line in $raw) {
        if (-not $line) { continue }
        $s = [string]$line
        if ($s.Length -lt 8 -or $s[0] -ne "`t") { continue }

        $tab = $s.LastIndexOf("`t")
        if ($tab -le 0) { continue }

        $head = $s.Substring(0, $tab).Trim()
        $sp = $head.IndexOf(' ')
        $token = if ($sp -gt 0) { $head.Substring(0, $sp) } else { $head }
        $size = [int64]0
        if (-not [int64]::TryParse($token, [ref]$size)) { continue }

        $files++
        $bytes += $size
    }

    return [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

function Get-DefaultQuarantineRoot {
    $best = $null
    foreach ($letter in 'C', 'D', 'E', 'F', 'G', 'H') {
        $root = $letter + ':\'
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $free = 0
        try { $free = (Get-PSDrive -Name $letter -ErrorAction Stop).Free } catch { continue }
        if ($free -lt 5GB) { continue }
        if ($null -eq $best -or $free -gt $best.Free) {
            $best = [pscustomobject]@{ Root = $root; Free = $free }
        }
    }
    if ($null -eq $best) { return (Join-Path $env:USERPROFILE 'Quarantine') }
    return (Join-Path $best.Root 'Quarantine')
}

# ----------------------------------------------------------------------------- targets

$localApp = $env:LOCALAPPDATA
$roots = New-Object 'System.Collections.Generic.List[object]'

function Add-Root {
    param($List, [string]$Label, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-Path -LiteralPath $expanded)) { return }
    $List.Add([pscustomobject]@{ Label = $Label; Path = $expanded })
}

Add-Root $roots 'User TEMP' "$env:TEMP"
Add-Root $roots 'Windows TEMP' "$env:SystemRoot\Temp"
Add-Root $roots 'Windows Error Reporting queue' "$localApp\Microsoft\Windows\WER\ReportQueue"
Add-Root $roots 'Windows Error Reporting archive' "$localApp\Microsoft\Windows\WER\ReportArchive"
Add-Root $roots 'Crashpad dumps' "$localApp\CrashDumps"

try {
    Get-ChildItem -LiteralPath $localApp -Directory -Filter '*-updater' -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            Add-Root $roots ('Electron updater pending ({0})' -f $_.Name) (Join-Path $_.FullName 'pending')
        }
} catch { }

if ($IncludeBrowserCache) {
    Add-Root $roots 'Chrome Cache' "$localApp\Google\Chrome\User Data\Default\Cache"
    Add-Root $roots 'Chrome Code Cache' "$localApp\Google\Chrome\User Data\Default\Code Cache"
    Add-Root $roots 'Chrome GPUCache' "$localApp\Google\Chrome\User Data\Default\GPUCache"
    Add-Root $roots 'Edge Cache' "$localApp\Microsoft\Edge\User Data\Default\Cache"
    Add-Root $roots 'Edge Code Cache' "$localApp\Microsoft\Edge\User Data\Default\Code Cache"
    Add-Root $roots 'Edge GPUCache' "$localApp\Microsoft\Edge\User Data\Default\GPUCache"
}

if ($IncludeShaderCache) {
    Add-Root $roots 'NVIDIA DXCache' "$localApp\NVIDIA\DXCache"
    Add-Root $roots 'NVIDIA GLCache' "$localApp\NVIDIA\GLCache"
    Add-Root $roots 'DirectX shader cache' "$localApp\D3DSCache"
}

if ($OnlyRoots.Count -gt 0) {
    # A GUI lets the user untick whole categories; an empty match must never look like
    # "nothing to clean", so fall back to every root and say so.
    $selectedRoots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $roots) {
        if ($OnlyRoots -contains $r.Label) { $selectedRoots.Add($r) }
    }
    if ($selectedRoots.Count -gt 0) {
        $roots = $selectedRoots
    } else {
        Write-Output ('WARNING: -OnlyRoots matched no allowlisted root ({0}); using all roots.' -f ($OnlyRoots -join ', '))
    }
}

# ----------------------------------------------------------------------------- collect

$cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
$candidates = New-Object 'System.Collections.Generic.List[object]'
$refused = New-Object 'System.Collections.Generic.List[object]'
$stats = New-Object 'System.Collections.Generic.List[object]'
$blockedSkipped = 0

foreach ($root in $roots) {
    $hit = Test-BlockedPath -Path $root.Path
    if ($hit) {
        $refused.Add([pscustomobject]@{ Label = $root.Label; Path = $root.Path; Pattern = $hit })
        continue
    }

    $stat = [pscustomobject]@{
        Label     = $root.Label
        RootPath  = $root.Path
        Files     = 0
        Bytes     = [int64]0
        Truncated = $false
        Method    = $Scanner
    }
    $stats.Add($stat)

    if ($Scanner -eq 'Robocopy') {
        $measure = Get-RobocopyMeasure -Path $root.Path -AgeDays $OlderThanDays
        if ($null -ne $measure) {
            $stat.Files = $measure.Files
            $stat.Bytes = $measure.Bytes
            continue
        }
        $stat.Method = 'PowerShell (robocopy fallback)'
    }

    $rootSw = [System.Diagnostics.Stopwatch]::StartNew()
    $seen = 0

    try {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($root.Path)
        while ($stack.Count -gt 0) {
            if ($rootSw.Elapsed.TotalSeconds -gt $MaxScanSecondsPerRoot) {
                $stat.Truncated = $true
                break
            }

            $dir = $stack.Pop()

            try {
                foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                    $seen++
                    try {
                        if (-not $f.StartsWith($root.Path, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                        if ($blockedRegex.IsMatch($f)) { $blockedSkipped++; continue }

                        $info = [System.IO.FileInfo]::new($f)
                        if ($info.LastWriteTime -gt $cutoff) { continue }
                        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

                        $len = [int64]$info.Length
                        $stat.Files++
                        $stat.Bytes += $len

                        if ($Execute -or $PlanJson) {
                            $candidates.Add([pscustomobject]@{
                                Root      = $root.Label
                                RootPath  = $root.Path
                                FullName  = $f
                                Length    = $len
                                LastWrite = $info.LastWriteTime
                            })
                        }
                    } catch { }

                    if (($seen % 5000) -eq 0 -and $rootSw.Elapsed.TotalSeconds -gt $MaxScanSecondsPerRoot) {
                        $stat.Truncated = $true
                        break
                    }
                }
            } catch { }
            if ($stat.Truncated) { break }

            try {
                foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                    try {
                        $attr = [System.IO.File]::GetAttributes($d)
                        if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    } catch { continue }
                    $stack.Push($d)
                }
            } catch { }
        }
    } catch { }
}

$totalFiles = 0
$totalBytes = [int64]0
$truncatedRoots = New-Object 'System.Collections.Generic.List[string]'
foreach ($s in $stats) {
    $totalFiles += $s.Files
    $totalBytes += $s.Bytes
    if ($s.Truncated) { $truncatedRoots.Add($s.Label) }
}

# ----------------------------------------------------------------------------- report plan

Write-Output ''
Write-Output ('=== Invoke-SafeClean ({0}) ===' -f $(if ($Execute) { 'EXECUTE' } else { 'DRY RUN - nothing will change' }))
Write-Output ('Age threshold : older than {0} days (before {1:yyyy-MM-dd HH:mm})' -f $OlderThanDays, $cutoff)
Write-Output ('Scanner       : {0}' -f $Scanner)
Write-Output ('Allowlist roots found : {0}' -f $roots.Count)
Write-Output ('Candidates    : {0} files, {1:N2} GB' -f $totalFiles, ($totalBytes / 1GB))
if ($blockedSkipped -gt 0) {
    Write-Output ('Refused by blacklist (skipped) : {0} files' -f $blockedSkipped)
}
if ($truncatedRoots.Count -gt 0) {
    Write-Output ('TRUNCATED at {0}s per root (numbers are a lower bound): {1}' -f $MaxScanSecondsPerRoot, ($truncatedRoots -join ', '))
}
Write-Output ''

if ($PlanJson) {
    # Machine-readable plan for a GUI: summary JSON plus the full item list as CSV.
    $planDir = Split-Path -Parent $PlanJson
    if ($planDir -and -not (Test-Path -LiteralPath $planDir)) {
        New-Item -ItemType Directory -Force -Path $planDir | Out-Null
    }
    $planCsv = [System.IO.Path]::ChangeExtension($PlanJson, '.csv')
    $now = Get-Date
    $planItems = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in $candidates) {
        $planItems.Add([pscustomobject]@{
                Root      = $c.Root
                Path      = $c.FullName
                Bytes     = [int64]$c.Length
                AgeDays   = [int][math]::Floor(($now - $c.LastWrite).TotalDays)
                LastWrite = $c.LastWrite.ToString('yyyy-MM-dd HH:mm')
            })
    }
    $planItems | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding UTF8

    $plan = [pscustomobject]@{
        timestamp       = $now.ToString('o')
        mode            = 'plan'
        older_than_days = $OlderThanDays
        keep_days       = $KeepDays
        scanner         = $Scanner
        elevated        = $isElevated
        candidates      = $totalFiles
        item_count      = $planItems.Count
        total_bytes     = $totalBytes
        total_gb        = [math]::Round($totalBytes / 1GB, 3)
        blocked_skipped = $blockedSkipped
        truncated_roots = @($truncatedRoots)
        items_csv       = $planCsv
        roots           = @($stats | ForEach-Object {
                [pscustomobject]@{
                    Label     = $_.Label
                    Path      = $_.RootPath
                    Files     = $_.Files
                    Bytes     = $_.Bytes
                    Truncated = $_.Truncated
                }
            })
    }
    $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $PlanJson -Encoding UTF8
    Write-Output ('Plan JSON           : {0}' -f $PlanJson)
    Write-Output ('Plan items CSV      : {0}' -f $planCsv)
    Write-Output ''
}

if ($totalFiles -gt 0) {
    $stats |
        Where-Object { $_.Files -gt 0 } |
        ForEach-Object {
            [pscustomobject]@{
                Root      = $_.Label
                Files     = $_.Files
                GB        = [math]::Round($_.Bytes / 1GB, 2)
                Truncated = $_.Truncated
                Path      = $_.RootPath
            }
        } |
        Sort-Object GB -Descending |
        Format-Table -AutoSize | Out-String -Width 250 | Write-Output
}

if ($refused.Count -gt 0) {
    Write-Output 'Refused paths (blacklist hit, never touched):'
    $refused | Format-Table -AutoSize | Out-String -Width 250 | Write-Output
}

if (-not $Execute) {
    Write-Output 'Official-tool cleanup for areas this script intentionally ignores:'
    Write-Output '  Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore      (WinSxS, needs elevation)'
    Write-Output '  Dism.exe /Online /Cleanup-Image /StartComponentCleanup      (WinSxS, needs elevation)'
    Write-Output '  Settings > System > Storage > Temporary files               (Update/DO/Windows.old)'
    Write-Output '  powercfg /a  then  powercfg /h off                          (hibernation, needs elevation)'
    Write-Output '  npm cache verify   |  pip cache purge  |  dotnet nuget locals all --clear'
    Write-Output ''
    Write-Output 'Package-manager caches and browser profiles are NOT touched by this script on purpose.'
    Write-Output 'Re-run with -Execute once the user approves this plan.'
    return
}

# ----------------------------------------------------------------------------- execute (quarantine, never delete)

if ([string]::IsNullOrWhiteSpace($QuarantineRoot)) { $QuarantineRoot = Get-DefaultQuarantineRoot }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$destRoot = Join-Path $QuarantineRoot $stamp

Write-Output ('Quarantine root : {0}' -f $destRoot)
Write-Output ('Keep for        : {0} days before manual deletion' -f $KeepDays)
Write-Output ''

$log = New-Object 'System.Collections.Generic.List[object]'
$moved = 0
$failed = 0
$movedBytes = [int64]0
$restoreLines = New-Object 'System.Collections.Generic.List[string]'
$restoreLines.Add('# Restore everything quarantined by this run. Run only if an app broke.')
$restoreLines.Add('# robocopy /MOVE puts the files back where they came from and empties the')
$restoreLines.Add('# quarantine copies as it goes, so this file stays small even for 60k+ files.')
$restoreLines.Add(('[string]$Dest = ''{0}''' -f $destRoot))
$restoreLines.Add('')
$restoreLines.Add('$map = [ordered]@{ ''C'' = ''C:\''; ''D'' = ''D:\''; ''E'' = ''E:\''; ''F'' = ''F:\'' }')
$restoreLines.Add('foreach ($tag in @($map.Keys)) {')
$restoreLines.Add('    $src = Join-Path $Dest $tag')
$restoreLines.Add('    if (-not (Test-Path -LiteralPath $src)) { continue }')
$restoreLines.Add('    robocopy $src $map[$tag] /E /MOVE /IS /R:0 /W:0 /NFL /NDL /NJH /NJS')
$restoreLines.Add('}')
$restoreLines.Add(('Write-Output ''Restore finished. Delete {0} once nothing is broken.''' -f $destRoot))

$lastParent = ''

if ($ProgressFile) {
    # Live progress for a GUI: one JSON line every 25 items, plus a final line.
    $progressDir = Split-Path -Parent $ProgressFile
    if ($progressDir -and -not (Test-Path -LiteralPath $progressDir)) {
        New-Item -ItemType Directory -Force -Path $progressDir | Out-Null
    }
    Set-Content -LiteralPath $ProgressFile -Value '' -Encoding UTF8
}

function Write-ProgressTick {
    param([string]$Current = '')
    if (-not $ProgressFile) { return }
    $done = $moved + $failed
    if (($done % 25) -ne 0) { return }
    $tick = [pscustomobject]@{
        done        = $done
        total       = $candidates.Count
        moved       = $moved
        failed      = $failed
        moved_bytes = $movedBytes
        moved_gb    = [math]::Round($movedBytes / 1GB, 3)
        current     = $Current
    }
    try {
        Add-Content -LiteralPath $ProgressFile -Value ($tick | ConvertTo-Json -Compress) -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

foreach ($c in $candidates) {
    if (Test-BlockedPath -Path $c.FullName) {
        $log.Add([pscustomobject]@{ Action = 'refused'; Path = $c.FullName; Bytes = $c.Length; Error = 'blacklist' })
        $failed++
        Write-ProgressTick -Current $c.FullName
        continue
    }

    $driveRoot = [System.IO.Path]::GetPathRoot($c.FullName)
    $driveTag = ($driveRoot -replace '[:\\]', '')
    $relative = $c.FullName.Substring($driveRoot.Length)
    # Keep the folder structure inside the quarantine: the generated restore script
    # robocopy's each <Quarantine>\<drive> tree back onto <drive>\, so a preserved
    # structure lands every file exactly where it came from. Only characters that are
    # illegal *inside* a single name may be sanitised - the separators must survive.
    $segments = $relative.Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $safeSegments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($seg in $segments) {
        $clean = $seg
        foreach ($bad in [System.IO.Path]::GetInvalidFileNameChars()) {
            if ($bad -eq '\' -or $bad -eq '/' -or $bad -eq ':') { continue }
            $clean = $clean.Replace($bad, '_')
        }
        $safeSegments.Add($clean)
    }
    $relative = ($safeSegments -join '\')
    $destination = Join-Path (Join-Path $destRoot $driveTag) $relative

    try {
        $parent = Split-Path -Parent $destination
        if ($parent -ne $lastParent) {
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $lastParent = $parent
        }
        Move-Item -LiteralPath $c.FullName -Destination $destination -Force -ErrorAction Stop
        $moved++
        $movedBytes += $c.Length
        $log.Add([pscustomobject]@{ Action = 'quarantined'; Path = $c.FullName; Quarantine = $destination; Bytes = $c.Length; Error = '' })
    } catch {
        $failed++
        $lastParent = ''
        $log.Add([pscustomobject]@{ Action = 'failed'; Path = $c.FullName; Quarantine = $destination; Bytes = $c.Length; Error = $_.Exception.Message })
    }

    Write-ProgressTick -Current $c.FullName
}

if ($ProgressFile) {
    $final = [pscustomobject]@{
        done        = ($moved + $failed)
        total       = $candidates.Count
        moved       = $moved
        failed      = $failed
        moved_bytes = $movedBytes
        moved_gb    = [math]::Round($movedBytes / 1GB, 3)
        current     = ''
        status      = 'finished'
    }
    try {
        Add-Content -LiteralPath $ProgressFile -Value ($final | ConvertTo-Json -Compress) -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ----------------------------------------------------------------------------- log

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$logPath = Join-Path $LogDir ('clean-{0}.json' -f $stamp)
$restorePath = Join-Path $LogDir ('restore-{0}.ps1' -f $stamp)

$summary = [pscustomobject]@{
    timestamp         = (Get-Date -Format 'o')
    mode              = 'execute-quarantine'
    older_than_days   = $OlderThanDays
    keep_days         = $KeepDays
    quarantine_root   = $destRoot
    candidates        = $candidates.Count
    moved             = $moved
    failed            = $failed
    moved_bytes       = $movedBytes
    moved_gb          = [math]::Round($movedBytes / 1GB, 3)
    elevated          = $isElevated
    items             = $log
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $logPath -Encoding UTF8
$restoreLines | Set-Content -LiteralPath $restorePath -Encoding UTF8

Write-Output ('Moved to quarantine : {0} files, {1:N2} GB' -f $moved, ($movedBytes / 1GB))
Write-Output ('Failed / refused    : {0}' -f $failed)
Write-Output ('Log                 : {0}' -f $logPath)
Write-Output ('Restore script      : {0}' -f $restorePath)
Write-Output ''
Write-Output ('Next: verify the affected apps, then delete {0} after {1} days.' -f $destRoot, $KeepDays)
