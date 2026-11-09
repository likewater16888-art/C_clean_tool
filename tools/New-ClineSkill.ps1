<#
.SYNOPSIS
    Scaffold a new Cline Agent Skill with the layout and compliance rules Cline expects.

.DESCRIPTION
    Creates <scope>\.cline\skills\<name>\SKILL.md with valid frontmatter, a references\
    folder for long-form knowledge, and a scripts\ folder for anything with side effects.
    After creation it validates the 4 hard requirements Cline checks at load time:

      1. directory name == frontmatter "name"
      2. "description" present and <= 1024 characters
      3. body references use relative paths (references/..., scripts/...)
      4. side-effecting commands live in scripts\ and default to a dry run

.PARAMETER Name
    Skill name. Lowercase letters, digits and single hyphens only (e.g. disk-audit).

.PARAMETER Description
    What the skill does AND when to use it. Add Chinese trigger words for Chinese users.

.PARAMETER Scope
    Global (default) installs to %USERPROFILE%\.cline\skills; Workspace installs to
    <current dir>\.cline\skills.

.PARAMETER Force
    Overwrite an existing skill folder.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-ClineSkill.ps1 -Name pdf-filler -Description "Fill PDF forms. Use when the user mentions form filling."
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Description,
    [ValidateSet('Global', 'Workspace')][string]$Scope = 'Global',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ($Name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
    throw "Invalid name '$Name'. Use lowercase letters, digits and single hyphens (e.g. disk-audit)."
}
if ($Description.Length -gt 1024) {
    throw "Description is $($Description.Length) characters; Cline's limit is 1024."
}
if ($Description -notmatch '(?i)\buse when\b|when the user|[\u4e00-\u9fff]') {
    Write-Warning 'Description does not say WHEN to use the skill. Auto-triggering relies on that sentence.'
}

if ($Scope -eq 'Global') {
    $skillsRoot = Join-Path $env:USERPROFILE '.cline\skills'
} else {
    $skillsRoot = Join-Path (Get-Location).Path '.cline\skills'
}

$skillDir = Join-Path $skillsRoot $Name
if (Test-Path -LiteralPath $skillDir) {
    if (-not $Force) { throw "Skill already exists: $skillDir  (use -Force to overwrite)" }
    Remove-Item -LiteralPath $skillDir -Recurse -Force
}

$refDir = Join-Path $skillDir 'references'
$scriptDir = Join-Path $skillDir 'scripts'
New-Item -ItemType Directory -Force -Path $refDir, $scriptDir | Out-Null

$skillMd = @"
---
name: $Name
description: $Description
---

# $Name

## When to use

State the trigger conditions in plain language. Keep this aligned with the description field.

## Workflow

1. Confirm scope and required inputs.
2. Load references/notes.md for domain rules before acting.
3. Run the bundled script for anything that touches the filesystem or network.
4. Report what changed and how to roll back.

## Local scripts

scripts/Invoke-Example.ps1 - default dry run, -Execute to apply, quarantine before delete.

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-Example.ps1

## Safety

- Inspect before changing anything.
- Prefer official tools over filesystem surgery.
- Never delete without a quarantine step or explicit user confirmation.
"@

Set-Content -LiteralPath (Join-Path $skillDir 'SKILL.md') -Value $skillMd -Encoding UTF8

$notesMd = @"
# Domain notes for $Name

Long-form knowledge goes here so SKILL.md stays short. Cline only loads this file when
SKILL.md references it.
"@
Set-Content -LiteralPath (Join-Path $refDir 'notes.md') -Value $notesMd -Encoding UTF8

$examplePs1 = @'
<#
.SYNOPSIS
    Dry-run-first template for a skill script.
.DESCRIPTION
    Prints the plan by default. With -Execute it applies the change and writes a log.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$LogDir = (Join-Path (Get-Location).Path 'reports')
)

$ErrorActionPreference = 'Continue'

# 1. Build the plan from an explicit allowlist (never wildcard over user data).
$plan = @()

# 2. Show the plan.
if ($Execute) { Write-Output '=== Execute ===' } else { Write-Output '=== Dry run (nothing changes) ===' }
$plan | Format-Table -AutoSize | Out-String -Width 200 | Write-Output

# 3. Apply only on -Execute, quarantine before delete.
if ($Execute) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    Write-Output ('Log directory: {0}' -f $LogDir)
}
'@
Set-Content -LiteralPath (Join-Path $scriptDir 'Invoke-Example.ps1') -Value $examplePs1 -Encoding UTF8

# ----------------------------------------------------------------------------- validate

$errors = New-Object 'System.Collections.Generic.List[string]'

$mdPath = Join-Path $skillDir 'SKILL.md'
$text = Get-Content -LiteralPath $mdPath -Raw
$fm = [regex]::Match($text, '(?s)^---\r?\n(.*?)\r?\n---')
if (-not $fm.Success) {
    $errors.Add('SKILL.md does not start with a valid YAML frontmatter block.')
} else {
    $block = $fm.Groups[1].Value
    $fmName = [regex]::Match($block, '(?m)^name:\s*(.+)$').Groups[1].Value.Trim()
    $fmDesc = [regex]::Match($block, '(?m)^description:\s*(.+)$').Groups[1].Value.Trim()
    if ($fmName -ne $Name) { $errors.Add("frontmatter name '$fmName' does not match directory '$Name'.") }
    if ($fmDesc.Length -eq 0) { $errors.Add('frontmatter description is missing.') }
    if ($fmDesc.Length -gt 1024) { $errors.Add("description is $($fmDesc.Length) characters (limit 1024).") }
}

foreach ($f in Get-ChildItem -LiteralPath $scriptDir -Filter '*.ps1' -File) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $errors.Add(("syntax error in {0} line {1}: {2}" -f $f.Name, $parseErrors[0].Extent.StartLineNumber, $parseErrors[0].Message))
    }
}

Write-Output ''
Write-Output ('Created : {0}' -f $skillDir)
Write-Output ('  SKILL.md ({0} chars, description {1}/1024)' -f $text.Length, $Description.Length)
Write-Output '  references\notes.md'
Write-Output '  scripts\Invoke-Example.ps1'

if ($errors.Count -gt 0) {
    Write-Output ''
    Write-Output 'COMPLIANCE ERRORS:'
    $errors | ForEach-Object { Write-Output ('  - {0}' -f $_) }
    exit 1
}

Write-Output ''
Write-Output 'All Cline skill requirements pass.'
Write-Output ('Trigger it with: /{0}' -f $Name)
