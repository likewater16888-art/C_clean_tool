<#
.SYNOPSIS
    Build the distributable CDriveGuard folder (and optional zip) from source.

.DESCRIPTION
    The engine scripts live in the win11-storage-governance skill, which is the single
    source of truth. This script copies a snapshot into ..\dist\CDriveGuard\engine,
    normalises encodings (PowerShell 5.1 needs a UTF-8 BOM to read non-ASCII literals
    correctly), writes a version stamp and a SHA256 manifest, and optionally zips the
    folder for handing to someone else.

    Never edit files inside dist\ by hand - re-run this script instead.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Dist.ps1 -Zip

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Dist.ps1 -Version 1.0.1
#>
[CmdletBinding()]
param(
    [string]$Version = '1.1.0',
    [string]$SkillScripts = '',
    [string]$OutDir = '',
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SkillScripts) { $SkillScripts = Join-Path $env:USERPROFILE '.cline\skills\win11-storage-governance\scripts' }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'dist\CDriveGuard' }

$engineDir = Join-Path $OutDir 'engine'
$engineFiles = @('Invoke-SafeClean.ps1', 'Invoke-CDriveAudit.ps1')

Write-Output ('Sources : {0}' -f $SkillScripts)
Write-Output ('Output  : {0}' -f $OutDir)

foreach ($f in $engineFiles) {
    $src = Join-Path $SkillScripts $f
    if (-not (Test-Path -LiteralPath $src)) { throw ('Missing engine script: {0}' -f $src) }
}

$guiPath = Join-Path $OutDir 'CDriveGuard.ps1'
if (-not (Test-Path -LiteralPath $guiPath)) { throw ('Missing GUI script: {0}' -f $guiPath) }

if (-not (Test-Path -LiteralPath $engineDir)) { New-Item -ItemType Directory -Force -Path $engineDir | Out-Null }
foreach ($f in $engineFiles) {
    Copy-Item -LiteralPath (Join-Path $SkillScripts $f) -Destination (Join-Path $engineDir $f) -Force
    Write-Output ('  copied engine\{0}' -f $f)
}

# PowerShell 5.1 reads .ps1 files without a BOM as ANSI, which turns Chinese strings into
# mojibake, so normalise every text file we ship. cmd.exe must NOT get a BOM.
function Set-Utf8Bom {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

$textFiles = Get-ChildItem -LiteralPath $OutDir -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.txt') -and $_.Name -ne 'SHA256.txt' }
foreach ($f in $textFiles) { Set-Utf8Bom -Path $f.FullName }
Write-Output ('  normalised encoding for {0} files' -f $textFiles.Count)

# cmd.exe wants CRLF and no BOM, and Start.cmd is deliberately ASCII-only (it runs before any
# codepage setup, so non-ASCII there would be mojibake on some machines).
$startCmd = Join-Path $OutDir 'Start.cmd'
if (Test-Path -LiteralPath $startCmd) {
    $cmdText = [System.IO.File]::ReadAllText($startCmd)
    if ($cmdText -match '[^\x00-\x7F]') {
        Write-Output '  WARNING: Start.cmd contains non-ASCII characters - keep it ASCII-only'
    }
    $cmdText = ($cmdText -split "`r?`n") -join "`r`n"
    [System.IO.File]::WriteAllText($startCmd, $cmdText, (New-Object System.Text.ASCIIEncoding))
    Write-Output '  normalised Start.cmd (CRLF, ASCII, no BOM)'
}

$versionText = @(
    ('CDriveGuard {0}' -f $Version),
    ('built {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)),
    ('engine from {0}' -f $SkillScripts),
    ('powershell required: 5.1 (Windows PowerShell, built in)')
) -join "`r`n"
Set-Content -LiteralPath (Join-Path $OutDir 'VERSION.txt') -Value $versionText -Encoding UTF8

$manifest = New-Object 'System.Collections.Generic.List[string]'
$manifest.Add(('# SHA256 manifest for CDriveGuard {0} (built {1:yyyy-MM-dd HH:mm})' -f $Version, (Get-Date)))
$manifest.Add('# verify: Get-FileHash <file> -Algorithm SHA256')
foreach ($f in (Get-ChildItem -LiteralPath $OutDir -Recurse -File | Where-Object { $_.Name -ne 'SHA256.txt' } | Sort-Object FullName)) {
    $rel = $f.FullName.Substring($OutDir.Length).TrimStart('\')
    $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    $manifest.Add(('{0}  {1}' -f $hash, $rel))
}
Set-Content -LiteralPath (Join-Path $OutDir 'SHA256.txt') -Value ($manifest -join "`r`n") -Encoding UTF8
Write-Output ('  manifest: {0} entries' -f ($manifest.Count - 2))

if ($Zip) {
    $zipPath = Join-Path (Split-Path -Parent $OutDir) ('CDriveGuard-v{0}.zip' -f $Version)
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path $OutDir -DestinationPath $zipPath -CompressionLevel Optimal
    $size = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    Write-Output ('ZIP     : {0} ({1} KB)' -f $zipPath, $size)
}

Write-Output ''
Write-Output 'Structure:'
Get-ChildItem -LiteralPath $OutDir -Recurse | ForEach-Object {
    $rel = $_.FullName.Substring($OutDir.Length).TrimStart('\')
    if ($_.PSIsContainer) { Write-Output ('  [dir] {0}' -f $rel) }
    else { Write-Output ('        {0}  ({1} KB)' -f $rel, [math]::Round($_.Length / 1KB, 1)) }
}
Write-Output ''
Write-Output 'Done. Ship the folder or the zip - do not edit dist\ by hand.'
