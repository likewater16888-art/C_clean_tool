# Summarises and sanity-checks the newest reports\clean-*.json produced by
# Invoke-SafeClean.ps1 -Execute: counts, failure reasons, quarantine bytes on disk,
# and whether the generated restore script still parses. Writes execute-verify.txt.
param([string]$Reports = (Join-Path (Get-Location).Path 'reports'))
$out = @()
$json = Get-ChildItem -LiteralPath $Reports -Filter 'clean-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $json) {
    'no clean-*.json found in ' + $Reports | Set-Content -LiteralPath (Join-Path $Reports 'execute-verify.txt') -Encoding UTF8
    return
}
$out += 'log: ' + $json.Name + '  size=' + [math]::Round($json.Length / 1MB, 2) + ' MB'
$s = Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json
$out += ('mode={0} older_than={1}d keep={2}d' -f $s.mode, $s.older_than_days, $s.keep_days)
$out += ('quarantine: ' + $s.quarantine_root)
$out += ('candidates={0} moved={1} failed={2} moved_gb={3} elevated={4}' -f $s.candidates, $s.moved, $s.failed, $s.moved_gb, $s.elevated)
$actions = $s.items | Group-Object Action | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
$out += 'actions: ' + ($actions -join ' ')
$errs = @($s.items | Where-Object { $_.Action -eq 'failed' } | Group-Object Error | Sort-Object Count -Descending | Select-Object -First 5)
foreach ($e in $errs) { $out += ('  err x{0}: {1}' -f $e.Count, $e.Name) }
$q = $s.quarantine_root
if (Test-Path -LiteralPath $q) {
    $files = @(Get-ChildItem -LiteralPath $q -Recurse -File -ErrorAction SilentlyContinue)
    $sum = ($files | Measure-Object Length -Sum).Sum
    $out += ('on-disk: {0} files, {1:N2} GB' -f $files.Count, ($sum / 1GB))
    $out += ('json bytes vs disk bytes: {0} vs {1}' -f $s.moved_bytes, $sum)
}
$restore = Get-ChildItem -LiteralPath $Reports -Filter 'restore-*.ps1' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($restore) {
    $out += ('restore script: {0} ({1} lines)' -f $restore.Name, (Get-Content -LiteralPath $restore.FullName).Count)
    $out += '--- restore script ---'
    $out += (Get-Content -LiteralPath $restore.FullName)
    $errs2 = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($restore.FullName, [ref]$null, [ref]$errs2)
    $out += ('restore parse errors: ' + $errs2.Count)
}
$out += ('C free GB now: ' + [math]::Round((Get-PSDrive C).Free / 1GB, 2))
$out | Set-Content -LiteralPath (Join-Path $Reports 'execute-verify.txt') -Encoding UTF8
