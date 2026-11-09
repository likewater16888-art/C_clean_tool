<#
.SYNOPSIS
    CDriveGuard - C 盘空间守护（极简图形界面版）

.DESCRIPTION
    给非技术用户使用的单页图形工具，底层复用 win11-storage-governance 的引擎脚本
    (engine\Invoke-SafeClean.ps1)。安全模型不变：

      * 只会「移动」到隔离文件夹，从不删除；保留期内可一键还原
      * 只处理白名单内的临时文件根目录（用户 TEMP / Windows TEMP / 错误报告 / 转储）
      * 系统目录、文档、桌面、下载、OneDrive、.git、.ssh 等一律不碰（引擎内黑名单硬拦截）
      * 不写注册表、不装服务、不建计划任务、不联网

    流程：① 扫描（只读） -> 勾掉不想清理的类别 -> ② 清理 -> 需要时「还原上次清理」

    打开时会先显示一页「使用说明」，10 秒后才允许关闭（防止没读就乱点）。

.PARAMETER SmokeTest
    Build the whole window, dump a control inventory and exit without showing it, so a
    broken UI cannot ship unnoticed.

.PARAMETER SmokeOut
    Where the SmokeTest inventory is written (default: work dir\smoke.txt).

.PARAMETER OlderThanDays
    Initial value of the "only clean files older than N days" spinner (default 7).

.PARAMETER IntroSeconds
    Countdown before the intro page can be dismissed (default 10). Test hook only - not
    documented for end users, and 0 disables the intro (automation).

.EXAMPLE
    powershell -STA -NoProfile -ExecutionPolicy Bypass -File CDriveGuard.ps1
#>
[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [string]$SmokeOut = '',
    [int]$OlderThanDays = 7,
    [Parameter(DontShow = $true)][int]$IntroSeconds = 10
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppVersion = '1.1.0'
$script:AppRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Engine = Join-Path $script:AppRoot 'engine\Invoke-SafeClean.ps1'
$script:DataRoot = Join-Path $env:LOCALAPPDATA 'CDriveGuard'
$script:LogDir = Join-Path $script:DataRoot 'logs'
$script:WorkDir = Join-Path $script:DataRoot 'work'
foreach ($d in @($script:DataRoot, $script:LogDir, $script:WorkDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# ----------------------------------------------------------------------------- state

$script:State = 'idle'               # idle | scanning | planned | cleaning | restoring
$script:Busy = $false
$script:Proc = $null
$script:ProcKind = ''
$script:ProcOut = ''
$script:ProcErr = ''
$script:LogOffset = 0L
$script:LogPartial = ''
$script:Plan = $null
$script:RootStats = @{}              # label -> stat object from the plan
$script:QuarantineTarget = ''

$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)


# ----------------------------------------------------------------------------- helpers

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Quote-Arg {
    param([string]$Value)
    return ("'" + $Value.Replace("'", "''") + "'")
}

function Get-SystemDriveInfo {
    try {
        $di = New-Object System.IO.DriveInfo($env:SystemDrive)
        return [pscustomobject]@{ Root = $env:SystemDrive; Free = [int64]$di.AvailableFreeSpace; Total = [int64]$di.TotalSize }
    } catch {
        return [pscustomobject]@{ Root = $env:SystemDrive; Free = 0L; Total = 0L }
    }
}

function Get-BestQuarantineDrive {
    # Prefer the non-system fixed drive with the most free space; otherwise stay on C:.
    $sys = $env:SystemDrive.TrimEnd(':\')
    $best = $null
    try {
        foreach ($di in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $di.IsReady) { continue }
            if ($di.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
            if ($di.Name.TrimEnd(':\') -eq $sys) { continue }
            if (-not $best -or $di.AvailableFreeSpace -gt $best.AvailableFreeSpace) { $best = $di }
        }
    } catch { }
    if ($best) { return [pscustomobject]@{ Root = $best.Name; Free = [int64]$best.AvailableFreeSpace } }
    return $null
}

function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $txtLog.AppendText($Text)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
}

function Set-Status {
    param([string]$Text)
    $lblStatus.Text = $Text
    $lblStatus.Refresh()
}

function Update-DriveBar {
    $di = Get-SystemDriveInfo
    if ($di.Total -le 0) { $lblSpace.Text = 'C 盘：读取失败'; return }
    $usedPct = [int][math]::Round((($di.Total - $di.Free) / $di.Total) * 100)
    $pbSpace.Value = [Math]::Max(0, [Math]::Min(100, $usedPct))
    $lblSpace.Text = ('C 盘可用 {0}   /   总共 {1}   （已用 {2}%）' -f (Format-Size $di.Free), (Format-Size $di.Total), $usedPct)
    if ($di.Free -lt 5GB) { $lblSpace.ForeColor = [System.Drawing.Color]::Firebrick } else { $lblSpace.ForeColor = [System.Drawing.Color]::Black }
}


function Set-Busy {
    param([bool]$Busy, [string]$Hint = '')
    $script:Busy = $Busy
    $btnScan.Enabled = -not $Busy
    $btnAdmin.Enabled = (-not $Busy) -and (-not $script:IsElevated)
    $dgvRoots.Enabled = -not $Busy
    $numDays.Enabled = -not $Busy
    $chkBrowser.Enabled = -not $Busy
    $btnClean.Enabled = $false
    $btnRestore.Enabled = $false
    $btnDetails.Enabled = (-not $Busy) -and ($null -ne $script:Plan)
    $btnOpenQuarantine.Enabled = -not $Busy
    if ($Busy) {
        $pbWork.Style = 'Marquee'
        $pbWork.MarqueeAnimationSpeed = 30
        if ($Hint) { Set-Status $Hint }
    } else {
        $pbWork.Style = 'Blocks'
        $pbWork.MarqueeAnimationSpeed = 0
        $btnRestore.Enabled = ($null -ne (Get-LatestRestoreScript))
        Update-SelectionSummary
    }
}

function Update-SelectionSummary {
    $bytes = [int64]0
    $files = 0
    $count = 0
    foreach ($row in $dgvRoots.Rows) {
        if (-not [bool]$row.Cells[0].Value) { continue }
        $label = [string]$row.Cells[1].Value
        $stat = $script:RootStats[$label]
        if ($null -eq $stat) { continue }
        $count++
        $files += [int]$stat.Files
        $bytes += [int64]$stat.Bytes
    }
    if ($script:State -ne 'planned') { return }
    if ($count -eq 0 -or $bytes -eq 0) {
        $lblTotal.Text = '没有勾选任何类别 —— 请至少勾选一行，或重新扫描。'
        $btnClean.Text = '② 开始清理'
        $btnClean.Enabled = $false
        return
    }
    $lblTotal.Text = ('将清理 {0}，共 {1:N0} 个文件（{2} 个类别）' -f (Format-Size $bytes), $files, $count)
    $btnClean.Text = ('② 开始清理  {0}' -f (Format-Size $bytes))
    if (-not $script:Busy) { $btnClean.Enabled = $true }
}

function Get-LatestRestoreScript {
    try {
        return Get-ChildItem -LiteralPath $script:LogDir -Filter 'restore-*.ps1' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    } catch { return $null }
}

function Get-LatestCleanLog {
    try {
        return Get-ChildItem -LiteralPath $script:LogDir -Filter 'clean-*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    } catch { return $null }
}

# ----------------------------------------------------------------------------- child process

function Read-NewProcessOutput {
    if ([string]::IsNullOrEmpty($script:ProcOut)) { return }
    if (-not (Test-Path -LiteralPath $script:ProcOut)) { return }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($script:ProcOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -le $script:LogOffset) { return }
        $stream.Position = $script:LogOffset
        $buffer = New-Object byte[] ($stream.Length - $script:LogOffset)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $script:LogOffset += $read
        $text = $script:LogPartial + [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $script:LogPartial = ''
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) {
            $idx = $text.LastIndexOf("`n")
            if ($idx -ge 0) {
                $script:LogPartial = $text.Substring($idx + 1)
                $text = $text.Substring(0, $idx + 1)
            } else {
                $script:LogPartial = $text
                $text = ''
            }
        }
        Append-Log $text
    } catch {
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Start-EngineRun {
    param([string]$Kind, [string]$CallLine)
    $script:ProcKind = $Kind
    $script:ProcOut = Join-Path $script:WorkDir ('out-{0}.txt' -f $Kind)
    $script:ProcErr = Join-Path $script:WorkDir ('err-{0}.txt' -f $Kind)
    $script:LogOffset = 0L
    $script:LogPartial = ''
    foreach ($p in @($script:ProcOut, $script:ProcErr)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
    $wrapper = Join-Path $script:WorkDir ('run-{0}.ps1' -f $Kind)
    $body = @(
        '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
        '$ErrorActionPreference = ''Continue''',
        '$ProgressPreference = ''SilentlyContinue''',
        $CallLine,
        'exit 0'
    ) -join "`r`n"
    Set-Content -LiteralPath $wrapper -Value $body -Encoding UTF8
    $script:Proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-STA -NoProfile -ExecutionPolicy Bypass -File "' + $wrapper + '"') `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $script:ProcOut -RedirectStandardError $script:ProcErr
    $script:Timer.Start()
    Set-Busy $true
}

function Get-SelectionLabels {
    $labels = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in $dgvRoots.Rows) {
        if (-not [bool]$row.Cells[0].Value) { continue }
        $labels.Add([string]$row.Cells[1].Value)
    }
    return $labels
}

function New-EngineCall {
    param([string[]]$Arguments)
    return ('& ' + (Quote-Arg $script:Engine) + ' ' + ($Arguments -join ' '))
}

function Start-Scan {
    if ($script:Busy) { return }
    $planPath = Join-Path $script:WorkDir 'plan.json'
    if (Test-Path -LiteralPath $planPath) { Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue }
    $csvPath = [System.IO.Path]::ChangeExtension($planPath, '.csv')
    if (Test-Path -LiteralPath $csvPath) { Remove-Item -LiteralPath $csvPath -Force -ErrorAction SilentlyContinue }

    $dgvRoots.Rows.Clear()
    $script:RootStats = @{}
    $script:Plan = $null
    $script:State = 'scanning'
    $lblTotal.Text = '正在扫描…（不改动任何文件）'
    Append-Log ("`r`n===== 开始扫描 {0:HH:mm:ss} =====" -f (Get-Date))
    Append-Log "`r`n只读扫描：统计哪些临时文件已经很久没动过，不会修改任何文件。`r`n"

    $args = @(
        '-OlderThanDays', [string]$numDays.Value,
        '-KeepDays', '30',
        '-LogDir', (Quote-Arg $script:LogDir),
        '-PlanJson', (Quote-Arg $planPath)
    )
    if ($chkBrowser.Checked) { $args += '-IncludeBrowserCache' }
    $script:PendingPlanPath = $planPath

    Start-EngineRun -Kind 'scan' -CallLine (New-EngineCall -Arguments $args)
    Set-Status '正在扫描…（第一次大约 1-3 分钟，请稍等）'
}

function Start-Clean {
    if ($script:Busy) { return }
    if ($script:State -ne 'planned') { return }
    $labels = Get-SelectionLabels
    if ($labels.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请至少勾选一个类别。', 'CDriveGuard', 'OK', 'Information')
        return
    }

    $bytes = [int64]0
    $files = 0
    foreach ($label in $labels) {
        $stat = $script:RootStats[$label]
        if ($null -eq $stat) { continue }
        $bytes += [int64]$stat.Bytes
        $files += [int]$stat.Files
    }

    $di = Get-SystemDriveInfo
    $freeAfter = $di.Free + $bytes
    $q = Get-BestQuarantineDrive
    if ($null -eq $q) {
        $qText = ('{0}\Quarantine' -f $env:SystemDrive)
        $qFree = $di.Free
    } else {
        $qText = ('{0}CDriveGuard-Quarantine' -f $q.Root)
        $qFree = $q.Free
    }
    if ($qFree -lt ($bytes * 1.1 + 512MB)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("隔离盘空间不足：需要大约 {0}，但 {1} 只剩 {2}。`r`n`r`n请先腾出空间，或勾选更少的类别。" -f (Format-Size $bytes), $qText, (Format-Size $qFree)),
            'CDriveGuard', 'OK', 'Warning')
        return
    }

    $msg = @(
        ('将把 {0}（{1:N0} 个文件）移动到：' -f (Format-Size $bytes), $files),
        ('    {0}\<时间戳>' -f $qText),
        '',
        '文件不会被删除，30 天内随时可以点「还原上次清理」搬回原位。',
        ('清理后 C 盘可用空间大约变成 {0}。' -f (Format-Size $freeAfter)),
        '',
        '建议先关闭正在运行的大程序。现在开始吗？'
    ) -join "`r`n"
    $answer = [System.Windows.Forms.MessageBox]::Show($msg, '确认清理', 'YesNo', 'Question', 'Button2')
    if ($answer -ne 'Yes') {
        Append-Log "`r`n已取消清理。`r`n"
        return
    }

    $script:QuarantineTarget = $qText
    $progressPath = Join-Path $script:WorkDir 'progress.jsonl'
    if (Test-Path -LiteralPath $progressPath) { Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue }
    $script:PendingProgressPath = $progressPath

    $args = @(
        '-Execute',
        '-OlderThanDays', [string]$numDays.Value,
        '-KeepDays', '30',
        '-MaxScanSecondsPerRoot', '1800',
        '-Scanner', 'PowerShell',
        '-LogDir', (Quote-Arg $script:LogDir),
        '-ProgressFile', (Quote-Arg $progressPath),
        '-QuarantineRoot', (Quote-Arg $script:QuarantineTarget)
    )
    if ($chkBrowser.Checked) { $args += '-IncludeBrowserCache' }
    $args += '-OnlyRoots'
    $args += ('@(' + (($labels | ForEach-Object { Quote-Arg $_ }) -join ',') + ')')

    $script:State = 'cleaning'
    $pbWork.Style = 'Blocks'
    $pbWork.Value = 0
    Append-Log ("`r`n===== 开始清理 {0:HH:mm:ss} =====" -f (Get-Date))
    Append-Log ("`r`n目标隔离区：{0}\<时间戳>`r`n" -f $script:QuarantineTarget)
    Start-EngineRun -Kind 'clean' -CallLine (New-EngineCall -Arguments $args)
    Set-Status '正在清理…（把文件搬到隔离区，请勿关闭窗口）'
}

function Start-Restore {
    if ($script:Busy) { return }
    $restore = Get-LatestRestoreScript
    if ($null -eq $restore) {
        [void][System.Windows.Forms.MessageBox]::Show('还没有可还原的清理记录。', 'CDriveGuard', 'OK', 'Information')
        return
    }
    $msg = @(
        '要把上一次清理的文件全部搬回原来的位置吗？',
        '',
        ('还原脚本：{0}' -f $restore.Name),
        ('生成时间：{0:yyyy-MM-dd HH:mm}' -f $restore.LastWriteTime),
        '',
        '适用于：某个软件运行不正常，需要把它的临时文件恢复。',
        '还原完成后，隔离区里的对应文件会被清空。'
    ) -join "`r`n"
    $answer = [System.Windows.Forms.MessageBox]::Show($msg, '确认还原', 'YesNo', 'Question', 'Button2')
    if ($answer -ne 'Yes') { return }

    $script:State = 'restoring'
    $pbWork.Style = 'Blocks'
    $pbWork.Value = 0
    Append-Log ("`r`n===== 开始还原 {0:HH:mm:ss} =====" -f (Get-Date))
    Start-EngineRun -Kind 'restore' -CallLine ('& ' + (Quote-Arg $restore.FullName))
    Set-Status '正在还原…'
}

# ----------------------------------------------------------------------------- completion

function Complete-Scan {
    param([int]$ExitCode)
    $planPath = $script:PendingPlanPath
    $script:State = 'idle'
    Set-Busy $false

    if (-not (Test-Path -LiteralPath $planPath)) {
        Set-Status '扫描失败'
        $errTail = ''
        if (Test-Path -LiteralPath $script:ProcErr) {
            $errTail = (Get-Content -LiteralPath $script:ProcErr -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 12) -join "`r`n"
        }
        Append-Log ("`r`n扫描没有生成结果（退出码 {0}）。`r`n{1}`r`n" -f $ExitCode, $errTail)
        [void][System.Windows.Forms.MessageBox]::Show("扫描失败，请把下面的信息发给开发者：`r`n`r`n$errTail", 'CDriveGuard', 'OK', 'Error')
        return
    }

    try {
        $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Set-Status '扫描结果读取失败'
        Append-Log ("`r`n扫描结果无法解析：{0}`r`n" -f $_.Exception.Message)
        return
    }
    $script:Plan = $plan
    $script:RootStats = @{}
    $dgvRoots.Rows.Clear()
    foreach ($r in @($plan.roots)) {
        if ([int64]$r.Bytes -le 0) { continue }
        $script:RootStats[[string]$r.Label] = $r
        $idx = $dgvRoots.Rows.Add()
        $row = $dgvRoots.Rows[$idx]
        $row.Cells[0].Value = $true
        $row.Cells[1].Value = [string]$r.Label
        $row.Cells[2].Value = ('{0:N0}' -f [int]$r.Files)
        $row.Cells[3].Value = (Format-Size ([int64]$r.Bytes))
    }
    $script:State = 'planned'
    Set-Busy $false
    $gb = [double]$plan.total_gb
    Set-Status ('扫描完成：可清理 {0}（{1:N0} 个文件）' -f (Format-Size ([int64]$plan.total_bytes)), [int]$plan.candidates)
    Append-Log ("`r`n扫描完成：{0} 个文件 / {1}，分布在 {2} 个类别。`r`n" -f [int]$plan.candidates, (Format-Size ([int64]$plan.total_bytes)), $dgvRoots.Rows.Count)
    Append-Log '提示：在表格里取消勾选某个类别，就不会动它。确认后点「② 开始清理」。'
    if ($dgvRoots.Rows.Count -eq 0) {
        $lblTotal.Text = '没有找到可以安全清理的旧临时文件 —— 这是好事，不需要清理。'
        $btnClean.Text = '② 开始清理'
        $btnClean.Enabled = $false
    }
    if ([bool]$plan.elevated -eq $false) {
        Append-Log "`r`n当前是普通权限：被系统占用的少数文件会被自动跳过（不影响其他文件）。"
    }
}

function Complete-Clean {
    param([int]$ExitCode)
    $script:State = 'idle'
    $script:Plan = $null
    $script:RootStats = @{}
    $dgvRoots.Rows.Clear()
    Set-Busy $false
    Update-DriveBar

    $moved = 0
    $failed = 0
    $gbText = ''
    $quarantine = ''
    $log = Get-LatestCleanLog
    if ($null -ne $log) {
        try {
            $s = Get-Content -LiteralPath $log.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $moved = [int]$s.moved
            $failed = [int]$s.failed
            $gbText = Format-Size ([int64]$s.moved_bytes)
            $quarantine = [string]$s.quarantine_root
        } catch { }
    }

    $lblTotal.Text = ('上次清理：{0}，共 {1:N0} 个文件（{2} 个未能搬动）' -f $gbText, $moved, $failed)
    $btnClean.Text = '② 开始清理'
    Set-Status ('清理完成：释放 {0}' -f $gbText)
    $btnRestore.Enabled = ($null -ne (Get-LatestRestoreScript))

    $msg = @(
        ('清理完成，C 盘多了 {0} 空间。' -f $gbText),
        ('搬走了 {0:N0} 个文件；{1:N0} 个被程序占用，已自动跳过（不影响使用）。' -f $moved, $failed),
        ''
    )
    if ($quarantine) { $msg += ('文件没有删除，都在：' + $quarantine) }
    $msg += '30 天内点「还原上次清理」就能全部搬回原位。'
    [void][System.Windows.Forms.MessageBox]::Show(($msg -join "`r`n"), '完成', 'OK', 'Information')
}

function Complete-Restore {
    param([int]$ExitCode)
    $script:State = 'idle'
    Set-Busy $false
    Update-DriveBar
    Set-Status '还原完成'
    $txt = "还原完成。`r`n`r`n如果软件还是不正常，可以重新扫描一次再清理，或者直接联系开发者。"
    [void][System.Windows.Forms.MessageBox]::Show($txt, '完成', 'OK', 'Information')
}

function Update-LiveProgress {
    $p = $script:PendingProgressPath
    if ([string]::IsNullOrEmpty($p)) { return }
    if (-not (Test-Path -LiteralPath $p)) { return }
    $lines = Get-Content -LiteralPath $p -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $lines -or $lines.Count -eq 0) { return }
    $tick = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        try { $tick = $lines[$i] | ConvertFrom-Json } catch { $tick = $null }
        if ($null -ne $tick) { break }
    }
    if ($null -eq $tick) { return }
    if ([int]$tick.total -gt 0) {
        $pct = [int][math]::Floor((100.0 * [int]$tick.done) / [int]$tick.total)
        if ($pct -lt 0) { $pct = 0 }
        if ($pct -gt 100) { $pct = 100 }
        $pbWork.Value = $pct
        Set-Status ('正在搬移：{0:N0} / {1:N0} 个文件（{2}%），已释放 {3}' -f [int]$tick.moved, [int]$tick.total, $pct, (Format-Size ([int64]$tick.moved_bytes)))
    }
}

function OnTimerTick {
    try { Read-NewProcessOutput } catch { }
    if ($script:ProcKind -eq 'clean') {
        try { Update-LiveProgress } catch { }
    }
    if ($null -eq $script:Proc) { return }
    $exited = $false
    try { $exited = $script:Proc.HasExited } catch { $exited = $true }
    if (-not $exited) { return }

    $script:Timer.Stop()
    try { Read-NewProcessOutput } catch { }
    $kind = $script:ProcKind
    $code = 0
    try { $code = $script:Proc.ExitCode } catch { }
    $script:Proc = $null

    switch ($kind) {
        'scan' { Complete-Scan -ExitCode $code }
        'clean' { Complete-Clean -ExitCode $code }
        'restore' { Complete-Restore -ExitCode $code }
        default { Set-Busy $false }
    }
}

# ----------------------------------------------------------------------------- window

$fontFamilies = @()
try {
    $fontFamilies = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
} catch { }
if ($fontFamilies -contains 'Microsoft YaHei UI') {
    $fontUi = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
} elseif ($fontFamilies -contains 'Microsoft YaHei') {
    $fontUi = New-Object System.Drawing.Font('Microsoft YaHei', 9.5)
} else {
    $fontUi = New-Object System.Drawing.Font('Tahoma', 9.5)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = ('CDriveGuard  C 盘空间守护  v{0}' -f $script:AppVersion)
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(924, 640)
$form.MinimumSize = New-Object System.Drawing.Size(840, 620)
$form.Font = $fontUi
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Text = "这个工具不会删除你的文件。它只会把「很久没动过的临时文件」搬到另一个文件夹；`r`n如果之后有软件不正常，点「还原上次清理」就能全部搬回来。"
$lblBanner.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
$lblBanner.Bounds = New-Object System.Drawing.Rectangle(12, 10, 900, 40)
$lblBanner.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblBanner)

$lblSpace = New-Object System.Windows.Forms.Label
$lblSpace.Text = 'C 盘：读取中…'
$lblSpace.Bounds = New-Object System.Drawing.Rectangle(12, 56, 600, 22)
$lblSpace.Anchor = 'Top,Left,Right'
$lblSpace.Font = New-Object System.Drawing.Font($fontUi.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblSpace)

$pbSpace = New-Object System.Windows.Forms.ProgressBar
$pbSpace.Bounds = New-Object System.Drawing.Rectangle(12, 80, 600, 14)
$pbSpace.Anchor = 'Top,Left,Right'
$pbSpace.Minimum = 0
$pbSpace.Maximum = 100
$form.Controls.Add($pbSpace)

$lblPerm = New-Object System.Windows.Forms.Label
$lblPerm.Bounds = New-Object System.Drawing.Rectangle(12, 100, 600, 22)
$lblPerm.Anchor = 'Top,Left,Right'
if ($script:IsElevated) {
    $lblPerm.Text = '权限：管理员（可以处理全部临时文件）'
    $lblPerm.ForeColor = [System.Drawing.Color]::SeaGreen
} else {
    $lblPerm.Text = '权限：普通用户（极少数被系统占用的文件会自动跳过，不影响使用）'
    $lblPerm.ForeColor = [System.Drawing.Color]::DimGray
}
$form.Controls.Add($lblPerm)

$btnAdmin = New-Object System.Windows.Forms.Button
$btnAdmin.Text = '以管理员身份重新打开'
$btnAdmin.Bounds = New-Object System.Drawing.Rectangle(730, 98, 182, 26)
$btnAdmin.Anchor = 'Top,Right'
$btnAdmin.Enabled = -not $script:IsElevated
$form.Controls.Add($btnAdmin)

$lblPick = New-Object System.Windows.Forms.Label
$lblPick.Text = '① 扫描后，在这里勾选要清理的类别（不勾的绝对不会动）：'
$lblPick.Bounds = New-Object System.Drawing.Rectangle(12, 132, 900, 20)
$lblPick.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblPick)

$lblDaysA = New-Object System.Windows.Forms.Label
$lblDaysA.Text = '只清理'
$lblDaysA.Bounds = New-Object System.Drawing.Rectangle(424, 134, 50, 20)
$lblDaysA.Anchor = 'Top,Right'
$form.Controls.Add($lblDaysA)

$numDays = New-Object System.Windows.Forms.NumericUpDown
$numDays.Bounds = New-Object System.Drawing.Rectangle(476, 130, 54, 24)
$numDays.Minimum = 3
$numDays.Maximum = 90
$numDays.Value = [Math]::Max(3, [Math]::Min(90, $OlderThanDays))
$numDays.Anchor = 'Top,Right'
$form.Controls.Add($numDays)

$lblDaysB = New-Object System.Windows.Forms.Label
$lblDaysB.Text = '天以前的文件'
$lblDaysB.Bounds = New-Object System.Drawing.Rectangle(534, 134, 96, 20)
$lblDaysB.Anchor = 'Top,Right'
$form.Controls.Add($lblDaysB)

$chkBrowser = New-Object System.Windows.Forms.CheckBox
$chkBrowser.Text = '同时清理浏览器缓存（需先关闭浏览器）'
$chkBrowser.Bounds = New-Object System.Drawing.Rectangle(646, 130, 266, 24)
$chkBrowser.Anchor = 'Top,Right'
$form.Controls.Add($chkBrowser)

$dgvRoots = New-Object System.Windows.Forms.DataGridView
$dgvRoots.Bounds = New-Object System.Drawing.Rectangle(12, 156, 900, 172)
$dgvRoots.Anchor = 'Top,Left,Right'
$dgvRoots.AllowUserToAddRows = $false
$dgvRoots.AllowUserToDeleteRows = $false
$dgvRoots.AllowUserToResizeRows = $false
$dgvRoots.AllowUserToOrderColumns = $false
$dgvRoots.RowHeadersVisible = $false
$dgvRoots.SelectionMode = 'FullRowSelect'
$dgvRoots.MultiSelect = $false
$dgvRoots.BackgroundColor = [System.Drawing.Color]::White
$dgvRoots.BorderStyle = 'FixedSingle'
$dgvRoots.GridColor = [System.Drawing.Color]::Gainsboro
$dgvRoots.ColumnHeadersHeightSizeMode = 'AutoSize'

$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.HeaderText = '清理'
$colCheck.Width = 56
$colCheck.SortMode = 'NotSortable'
$colLabel = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colLabel.HeaderText = '类别'
$colLabel.Width = 520
$colLabel.ReadOnly = $true
$colLabel.SortMode = 'NotSortable'
$colFiles = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFiles.HeaderText = '文件数'
$colFiles.Width = 110
$colFiles.ReadOnly = $true
$colFiles.SortMode = 'NotSortable'
$colFiles.DefaultCellStyle.Alignment = 'MiddleRight'
$colBytes = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colBytes.HeaderText = '可释放'
$colBytes.Width = 140
$colBytes.ReadOnly = $true
$colBytes.SortMode = 'NotSortable'
$colBytes.DefaultCellStyle.Alignment = 'MiddleRight'
$dgvCols = New-Object 'System.Windows.Forms.DataGridViewColumn[]' 4
$dgvCols[0] = $colCheck
$dgvCols[1] = $colLabel
$dgvCols[2] = $colFiles
$dgvCols[3] = $colBytes
$dgvRoots.Columns.AddRange($dgvCols)
$form.Controls.Add($dgvRoots)

$lblTotal = New-Object System.Windows.Forms.Label
$lblTotal.Text = '还没有扫描。点下面的「① 扫描」开始（只读，不会动任何文件）。'
$lblTotal.Bounds = New-Object System.Drawing.Rectangle(12, 334, 900, 24)
$lblTotal.Anchor = 'Top,Left,Right'
$lblTotal.Font = New-Object System.Drawing.Font($fontUi.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTotal)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = '① 扫描（不改动文件）'
$btnScan.Bounds = New-Object System.Drawing.Rectangle(12, 364, 250, 46)
$btnScan.Anchor = 'Top,Left'
$form.Controls.Add($btnScan)

$btnClean = New-Object System.Windows.Forms.Button
$btnClean.Text = '② 开始清理'
$btnClean.Bounds = New-Object System.Drawing.Rectangle(272, 364, 250, 46)
$btnClean.Anchor = 'Top,Left'
$btnClean.Enabled = $false
$form.Controls.Add($btnClean)

$btnDetails = New-Object System.Windows.Forms.Button
$btnDetails.Text = '看清理明细'
$btnDetails.Bounds = New-Object System.Drawing.Rectangle(534, 374, 110, 28)
$btnDetails.Anchor = 'Top,Left'
$btnDetails.Enabled = $false
$form.Controls.Add($btnDetails)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = '还原上次清理'
$btnRestore.Bounds = New-Object System.Drawing.Rectangle(652, 374, 120, 28)
$btnRestore.Anchor = 'Top,Left'
$form.Controls.Add($btnRestore)

$btnOpenQuarantine = New-Object System.Windows.Forms.Button
$btnOpenQuarantine.Text = '打开隔离文件夹'
$btnOpenQuarantine.Bounds = New-Object System.Drawing.Rectangle(780, 374, 132, 28)
$btnOpenQuarantine.Anchor = 'Top,Left'
$form.Controls.Add($btnOpenQuarantine)

$pbWork = New-Object System.Windows.Forms.ProgressBar
$pbWork.Bounds = New-Object System.Drawing.Rectangle(12, 420, 900, 16)
$pbWork.Anchor = 'Top,Left,Right'
$pbWork.Minimum = 0
$pbWork.Maximum = 100
$form.Controls.Add($pbWork)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '准备就绪。'
$lblStatus.Bounds = New-Object System.Drawing.Rectangle(12, 440, 900, 22)
$lblStatus.Anchor = 'Top,Left,Right'
$form.Controls.Add($lblStatus)

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = '运行记录（出问题时把这部分发给我）：'
$lblLogTitle.Bounds = New-Object System.Drawing.Rectangle(12, 466, 900, 20)
$lblLogTitle.Anchor = 'Top,Left,Right'
$lblLogTitle.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblLogTitle)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Bounds = New-Object System.Drawing.Rectangle(12, 488, 900, 140)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$txtLog.WordWrap = $false
if ($fontFamilies -contains 'Consolas') {
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
}
$form.Controls.Add($txtLog)

# ----------------------------------------------------------------------------- details dialog

function Show-PlanDetails {
    if ($null -eq $script:Plan) {
        [void][System.Windows.Forms.MessageBox]::Show('请先点「① 扫描」。', 'CDriveGuard', 'OK', 'Information')
        return
    }
    $csv = [string]$script:Plan.items_csv
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('注意：这里只是「看一眼」，不决定清理范围。真正清理哪些类别，由表格里的勾选决定。')
    $lines.Add('')
    if ([string]::IsNullOrEmpty($csv) -or -not (Test-Path -LiteralPath $csv)) {
        $lines.Add('（本次扫描没有生成逐文件明细。）')
    } else {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $all = @(Import-Csv -LiteralPath $csv -Encoding UTF8)
            $take = [Math]::Min(300, $all.Count)
            $lines.Add(('共 {0:N0} 个文件，下面按大小显示前 {1} 个：' -f $all.Count, $take))
            $lines.Add('')
            $lines.Add(('{0,10}  {1,5}  {2}' -f '大小', '天数', '位置'))
            $lines.Add(('{0,10}  {1,5}  {2}' -f '----------', '-----', '----'))
            $top = $all | Sort-Object -Property @{ Expression = { [int64]$_.Bytes } } -Descending | Select-Object -First $take
            foreach ($it in $top) {
                $lines.Add(('{0,10}  {1,5}  {2}' -f (Format-Size ([int64]$it.Bytes)), [int]$it.AgeDays, [string]$it.Path))
            }
        } catch {
            $lines.Add('读取明细失败：' + $_.Exception.Message)
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '清理明细（按大小显示前 300 个）'
    $dlg.ClientSize = New-Object System.Drawing.Size(1000, 560)
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Both'
    $box.WordWrap = $false
    $box.Dock = 'Fill'
    if ($fontFamilies -contains 'Consolas') { $box.Font = New-Object System.Drawing.Font('Consolas', 9) }
    $box.Text = ($lines -join "`r`n")
    $dlg.Controls.Add($box)
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}

# ----------------------------------------------------------------------------- intro page
# Shown once per launch, before the main window is usable: the "x" and the button are both
# refused until the countdown reaches zero. The countdown is deliberately not skippable by
# keyboard (Esc/Alt+F4 go through the same FormClosing guard).

$script:IntroSeconds = [Math]::Max(0, $IntroSeconds)
$script:IntroLeft = 0
$script:IntroDlg = $null
$script:IntroOk = $null
$script:IntroHint = $null
$script:IntroTimer = $null

function Get-IntroGateText {
    param([int]$SecondsLeft)
    if ($SecondsLeft -gt 0) { return ('请先把上面的说明看完：还需等待 {0} 秒' -f $SecondsLeft) }
    return '看完了。点「我知道了，开始使用」进入主界面。'
}

function Get-IntroBodyText {
    $lines = @(
        '这个工具只做两件事：'
        '  1) 扫描：只读地算出 C 盘里可以安全搬走的“很久没动过的临时文件”；'
        '  2) 清理：把它们搬到另一个文件夹（隔离区），不是删除。'
        ''
        '三步用法：'
        '  ① 点【① 扫描（不改动文件）】，等 1~3 分钟（文件特别多时更久）；'
        '  ② 看表格里的类别和大小，不想清理的，把「清理」列的勾去掉；'
        '  ③ 点【② 开始清理 …】，确认后开始搬移；进度条走完就结束了。'
        ''
        '如果之后某个软件变得不正常：'
        '  点【还原上次清理】，文件会全部搬回原来的位置（30 天内有效）。'
        ''
        '它绝不碰：'
        '  系统目录、程序目录、文档、桌面、下载、OneDrive、.git、.ssh、聊天记录。'
        ''
        '它绝不做的：'
        '  删除文件、联网上传、写注册表、装后台服务、建计划任务。'
        ''
        '请记住一件事：'
        '  光是打开或关闭这个窗口，不会清理任何东西；'
        '  只有点了【② 开始清理】并确认，才会动文件。'
        ''
        ('本页面打开 {0} 秒后才允许关闭（不会自动关闭），慢慢读完再关就行。' -f $script:IntroSeconds)
    )
    return ($lines -join "`r`n")
}

function New-IntroForm {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '使用说明（请先读一遍）'
    $dlg.StartPosition = 'CenterParent'
    $dlg.ClientSize = New-Object System.Drawing.Size(700, 600)
    $dlg.MinimumSize = New-Object System.Drawing.Size(660, 520)
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.Font = $fontUi
    $dlg.BackColor = [System.Drawing.Color]::White

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = '使用说明（读完才能开始）'
    $lblTitle.Bounds = New-Object System.Drawing.Rectangle(16, 12, 668, 30)
    $lblTitle.Anchor = 'Top,Left,Right'
    $lblTitle.Font = New-Object System.Drawing.Font($fontUi.FontFamily, 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $dlg.Controls.Add($lblTitle)

    $txtIntro = New-Object System.Windows.Forms.TextBox
    $txtIntro.Bounds = New-Object System.Drawing.Rectangle(16, 48, 668, 486)
    $txtIntro.Anchor = 'Top,Bottom,Left,Right'
    $txtIntro.Multiline = $true
    $txtIntro.ReadOnly = $true
    $txtIntro.ScrollBars = 'Vertical'
    $txtIntro.WordWrap = $true
    $txtIntro.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 252)
    $txtIntro.Text = (Get-IntroBodyText)
    $dlg.Controls.Add($txtIntro)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = ''
    $lblHint.Bounds = New-Object System.Drawing.Rectangle(16, 554, 470, 24)
    $lblHint.Anchor = 'Bottom,Left,Right'
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblHint)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '开始使用'
    $btnOk.Bounds = New-Object System.Drawing.Rectangle(500, 546, 184, 40)
    $btnOk.Anchor = 'Bottom,Right'
    $btnOk.Enabled = $false
    $dlg.Controls.Add($btnOk)

    $script:IntroOk = $btnOk
    $script:IntroHint = $lblHint
    return $dlg
}

function Set-IntroGate {
    param([int]$SecondsLeft)
    $script:IntroLeft = $SecondsLeft
    if ($null -eq $script:IntroHint -or $null -eq $script:IntroOk) { return }
    $script:IntroHint.Text = Get-IntroGateText $SecondsLeft
    if ($SecondsLeft -gt 0) {
        $script:IntroOk.Enabled = $false
        $script:IntroOk.Text = '开始使用'
    } else {
        $script:IntroOk.Enabled = $true
        $script:IntroOk.Text = '我知道了，开始使用'
    }
}

function Show-IntroPage {
    if ($script:IntroSeconds -le 0) { return }
    $dlg = New-IntroForm
    $script:IntroDlg = $dlg

    $script:IntroOk.add_Click({
            if ($script:IntroLeft -le 0 -and $null -ne $script:IntroDlg) { $script:IntroDlg.Close() }
        })

    $dlg.add_FormClosing({
            param($sender, $e)
            if ($script:IntroLeft -gt 0) {
                $e.Cancel = $true
                if ($null -ne $script:IntroHint) {
                    $script:IntroHint.Text = ('还没到时间：还需等待 {0} 秒（故意不让关，读完再关）' -f $script:IntroLeft)
                }
            }
        })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.add_Tick({
            $left = $script:IntroLeft - 1
            if ($left -lt 0) { $left = 0 }
            Set-IntroGate $left
            if ($left -le 0) {
                try { $script:IntroTimer.Stop() } catch { }
            }
        })
    $script:IntroTimer = $timer

    Set-IntroGate $script:IntroSeconds
    $timer.Start()
    $script:IntroDlg.Focus()
    [void]$dlg.ShowDialog($form)

    try { $timer.Stop() } catch { }
    try { $timer.Dispose() } catch { }
    try { $dlg.Dispose() } catch { }
    $script:IntroDlg = $null
    $script:IntroOk = $null
    $script:IntroHint = $null
    $script:IntroTimer = $null
    $script:IntroLeft = 0
    Append-Log "`r`n已阅读使用说明，可以开始使用了。`r`n"
}

# ----------------------------------------------------------------------------- wiring

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 400
$script:Timer.add_Tick({ OnTimerTick })

function Invoke-UiAction {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Append-Log ("`r`n[错误] {0}`r`n" -f $_.Exception.Message)
        Set-Status ('出错：' + $_.Exception.Message)
        if ($script:Busy) { $script:Timer.Stop(); Set-Busy $false }
    }
}

$dgvRoots.add_CurrentCellDirtyStateChanged({
        try {
            if ($dgvRoots.IsCurrentCellDirty) {
                [void]$dgvRoots.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
            }
        } catch { }
    })

$dgvRoots.add_CellValueChanged({
        param($sender, $e)
        try {
            if ($e.ColumnIndex -eq 0) { Update-SelectionSummary }
        } catch { }
    })

$btnScan.add_Click({ Invoke-UiAction { Start-Scan } })
$btnClean.add_Click({ Invoke-UiAction { Start-Clean } })
$btnRestore.add_Click({ Invoke-UiAction { Start-Restore } })
$btnDetails.add_Click({ Invoke-UiAction { Show-PlanDetails } })

$btnOpenQuarantine.add_Click({
        Invoke-UiAction {
            $target = ''
            $log = Get-LatestCleanLog
            if ($null -ne $log) {
                try {
                    $s = Get-Content -LiteralPath $log.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    $target = [string]$s.quarantine_root
                } catch { }
            }
            $openPath = $script:LogDir
            if ($target) {
                $parent = Split-Path -Parent $target
                if (Test-Path -LiteralPath $parent) { $openPath = $parent }
            }
            Start-Process -FilePath 'explorer.exe' -ArgumentList $openPath
        }
    })

$btnAdmin.add_Click({
        Invoke-UiAction {
            $self = Join-Path $script:AppRoot 'CDriveGuard.ps1'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = ('-STA -NoProfile -ExecutionPolicy Bypass -File "' + $self + '"')
            $psi.Verb = 'runas'
            try {
                [System.Diagnostics.Process]::Start($psi) | Out-Null
                $form.Close()
            } catch {
                Append-Log "`r`n已取消管理员授权，继续用普通权限运行。`r`n"
            }
        }
    })

$form.add_Shown({
        Invoke-UiAction {
            Update-DriveBar
            $di = Get-SystemDriveInfo
            Append-Log ('CDriveGuard v{0}   引擎：{1}' -f $script:AppVersion, (Split-Path -Leaf $script:Engine))
            Append-Log ("`r`nC 盘可用：{0}" -f (Format-Size $di.Free))
            Append-Log "`r`n安全说明：只移动、不删除；系统目录 / 文档 / 桌面 / 下载 / OneDrive / .git / .ssh 一律不动。`r`n"
            $last = Get-LatestCleanLog
            if ($null -ne $last) {
                Append-Log ("上次清理：{0:yyyy-MM-dd HH:mm}（需要时可点「还原上次清理」撤销）`r`n" -f $last.LastWriteTime)
            } else {
                Append-Log "这是第一次运行。点「① 扫描」看看能腾出多少空间。`r`n"
            }
            Set-Busy $false
            Set-Status '准备就绪：点「① 扫描」开始。'
            if (-not $SmokeTest -and $script:IntroSeconds -gt 0) { Show-IntroPage }
        }
    })

$form.add_FormClosing({
        param($sender, $e)
        if ($script:Busy) {
            $a = [System.Windows.Forms.MessageBox]::Show('正在处理文件，现在关闭会中途停止。确定关闭吗？', 'CDriveGuard', 'YesNo', 'Warning', 'Button2')
            if ($a -ne 'Yes') { $e.Cancel = $true; return }
            try {
                if ($script:Proc -and -not $script:Proc.HasExited) { $script:Proc.Kill() }
            } catch { }
        }
        try { $script:Timer.Stop() } catch { }
    })

# ----------------------------------------------------------------------------- smoke test / main

if ($SmokeTest) {
    $outPath = if ($SmokeOut) { $SmokeOut } else { Join-Path $script:WorkDir 'smoke.txt' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('CDriveGuard smoke test')
    $lines.Add('version   ' + $script:AppVersion)
    $lines.Add('elevated  ' + $script:IsElevated)
    $lines.Add('ui font   ' + $fontUi.Name)
    $lines.Add('engine    ' + $script:Engine + '   exists=' + (Test-Path -LiteralPath $script:Engine))
    $lines.Add('logdir    ' + $script:LogDir)
    $lines.Add('')
    $form.CreateControl()
    foreach ($c in $form.Controls) {
        $text = [string]$c.Text
        $text = $text -replace "`r", ' / ' -replace "`n", ' / '
        if ($text.Length -gt 56) { $text = $text.Substring(0, 56) + '...' }
        $lines.Add(('{0,-24} bounds={1,-30} enabled={2,-5} text="{3}"' -f $c.GetType().Name, $c.Bounds.ToString(), $c.Enabled, $text))
    }
    $lines.Add('')
    $lines.Add('grid columns  ' + $dgvRoots.Columns.Count)
    $lines.Add('grid rows     ' + $dgvRoots.Rows.Count)
    $lines.Add('col0 type     ' + $dgvRoots.Columns[0].GetType().Name)
    $lines.Add('timer interval ' + $script:Timer.Interval)
    $lines.Add('numDays value  ' + $numDays.Value)
    $lines.Add('')

    # Actually show the window for a moment so the Shown handler, drive bar refresh and
    # Set-Busy path are exercised too - smoke must fail loudly if any of them throws.
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.Application]::DoEvents()
    $lines.Add('shown status   ' + $lblStatus.Text)
    $lines.Add('space label    ' + $lblSpace.Text)
    $lines.Add('space bar used ' + $pbSpace.Value + '%')
    $lines.Add('clean enabled  ' + $btnClean.Enabled)
    $lines.Add('restore enabled ' + $btnRestore.Enabled)
    $lines.Add('grid enabled   ' + $dgvRoots.Enabled)
    $logOneLine = ($txtLog.Text -replace "`r", ' / ' -replace "`n", ' / ')
    if ($logOneLine.Length -gt 400) { $logOneLine = $logOneLine.Substring(0, 400) + '...' }
    $lines.Add('log text       ' + $logOneLine)

    # The intro page must exist, must start gated, and must open up at zero.
    $lines.Add('')
    $lines.Add('intro seconds  ' + $script:IntroSeconds)
    $intro = New-IntroForm
    $intro.CreateControl()
    $lines.Add('intro controls ' + $intro.Controls.Count)
    Set-IntroGate $script:IntroSeconds
    $lines.Add('gate@N         left=' + $script:IntroLeft + ' okEnabled=' + $script:IntroOk.Enabled + ' okText="' + $script:IntroOk.Text + '"')
    $lines.Add('hint@N         ' + $script:IntroHint.Text)
    Set-IntroGate 0
    $lines.Add('gate@0         left=' + $script:IntroLeft + ' okEnabled=' + $script:IntroOk.Enabled + ' okText="' + $script:IntroOk.Text + '"')
    $lines.Add('hint@0         ' + $script:IntroHint.Text)
    $body = $intro.Controls | Where-Object { $_.GetType().Name -eq 'TextBox' } | Select-Object -First 1
    $lines.Add('intro body len ' + $body.Text.Length)
    $lines.Add('body checks    只做两件事=' + [bool]($body.Text -like '*只做两件事*') + ' 还原=' + [bool]($body.Text -like '*还原上次清理*') + ' 不删除=' + [bool]($body.Text -like '*不是删除*') + ' 秒数=' + [bool]($body.Text -like ('*' + $script:IntroSeconds + ' 秒*')))
    $intro.Dispose()
    $script:IntroOk = $null
    $script:IntroHint = $null
    $script:IntroLeft = 0
    $form.Close()

    Set-Content -LiteralPath $outPath -Value ($lines -join "`r`n") -Encoding UTF8
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
$form.Dispose()
