<#
.SYNOPSIS
    Build the sprint planning live demo hub (docs\planning.html).

.DESCRIPTION
    A preview of a sprint planning hub for the ADO Work Map extension: capacity with partial
    days off, carry over, planning poker, people lanes and swimlanes, a sprint calendar and a
    confidence vote. It runs entirely in the browser on the -Demo sample data and never
    connects to Azure DevOps.

    The page is sprint_planning.template.html with the demo data put in place of __DATA__.
    The demo sprints are dated relative to the day the data is made; the example sprint
    (4 weeks from Oct 26, 2026, with time off filled in) is used when the dates line up,
    otherwise the first future sprint is shown as it is.

.EXAMPLE
    .\sprint-planning\build.ps1
#>
param([string]$OutFile)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
if (-not $OutFile) { $OutFile = Join-Path $repo 'docs\planning.html' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('adomap_planning_' + [guid]::NewGuid().ToString('N'))
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ado_work_map.ps1') -Demo -NoOpen -OutDir $tmp | Out-Null
    $json = [IO.File]::ReadAllText((Join-Path $tmp 'ado_work_map.json'))
}
finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force } }

$template = [IO.File]::ReadAllText((Join-Path $here 'sprint_planning.template.html'))
if ($template.IndexOf('__DATA__') -lt 0) { throw 'Template has no __DATA__ placeholder' }
# '</' is escaped so the data can never close the script tag it sits in
[IO.File]::WriteAllText($OutFile, $template.Replace('__DATA__', $json.Replace('</', '<\/')), (New-Object Text.UTF8Encoding $false))
Write-Host "Built $OutFile"
