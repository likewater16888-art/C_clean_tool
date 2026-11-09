param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Err = '',
    [string]$ScriptArgs = '',
    [string]$StartedFile = '',
    [string]$WorkDir = ''
)

if ([string]::IsNullOrWhiteSpace($Err)) { $Err = $Out + '.err' }

$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    $lines = @('PARSE ERRORS in ' + $Script + ': ' + $errs.Count)
    foreach ($e in $errs) { $lines += ('  L' + $e.Extent.StartLineNumber + ': ' + $e.Message) }
    $lines | Out-File $Out -Encoding UTF8
    $lines | ForEach-Object { Write-Output $_ }
    return
}

# cmd.exe writes the redirects, Win32_Process.Create detaches from this terminal's job
# object so closing the terminal cannot kill the run.
$cd = ''
if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $cd = 'cd /d "' + $WorkDir + '" && ' }
$inner = 'cmd.exe /c ' + $cd + 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + $ScriptArgs + ' > "' + $Out + '" 2> "' + $Err + '"'
$res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $inner }

$msg = 'started pid ' + $res.ProcessId + ' at ' + (Get-Date -Format 'HH:mm:ss')
if (-not [string]::IsNullOrWhiteSpace($StartedFile)) {
    $msg | Out-File $StartedFile -Encoding UTF8
}
Write-Output $msg
Write-Output ('cmd: ' + $inner)
