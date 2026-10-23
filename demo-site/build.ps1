<#
.SYNOPSIS
    Build the GitHub Pages live demo in docs\.

.DESCRIPTION
    docs\work-map.html        the report made with -Demo sample data, with a strict
                              content security policy added (nothing loads or leaves)
    docs\planning.html        the sprint planning preview (sprint-planning\build.ps1)
    docs\index.html           an Azure DevOps-style frame (ADO Work Map branding, a
    docs\sprint-planning.html collapsible side panel) hosting both hubs, the way Azure
                              DevOps extension hubs run; index.html opens on the Work Map,
                              sprint-planning.html on Sprint planning, and switching
                              between them happens in place

.EXAMPLE
    .\demo-site\build.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$docs = Join-Path $repo 'docs'
$utf8 = New-Object Text.UTF8Encoding $false

# The report, from the sample data
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('adomap_demo_' + [guid]::NewGuid().ToString('N'))
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ado_work_map.ps1') -Demo -NoOpen -OutDir $tmp | Out-Null
    $report = [IO.File]::ReadAllText((Join-Path $tmp 'ado_work_map.html'))
}
finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force } }
$csp = '<meta http-equiv="Content-Security-Policy" content="default-src ''none''; script-src ''unsafe-inline''; style-src ''unsafe-inline''; img-src data:; base-uri ''none''; form-action ''none''">' +
       "`n" + '<meta name="referrer" content="no-referrer">'
$at = $report.IndexOf('<meta charset="utf-8">')
if ($at -lt 0) { throw 'Report has no charset meta tag' }
$at += '<meta charset="utf-8">'.Length
$report = $report.Substring(0, $at) + "`n" + $csp + $report.Substring($at)
# In the demo the report wears Azure DevOps' own palette (Fluent neutrals, #0078d4 blue, Segoe UI),
# to match the frame around it. The script's own report is unchanged.
$palette = @'
<style>
:root{--bg:#f8f8f8;--panel:#fff;--text:#201f1e;--muted:#605e5c;--line:#e1dfdd;--hover:#f3f2f1;--sel:#deecf9;
  --done:#107c10;--active:#0078d4;--new:#a19f9d;--removed:#c8c6c4;--accent:#0078d4}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#1b1a19;--panel:#252423;--text:#f3f2f1;--muted:#c8c6c4;
  --line:#3b3a39;--hover:#323130;--sel:#0f3a5e;--done:#54b054;--active:#479ef5;--new:#797775;--removed:#484644;--accent:#479ef5}}
:root[data-theme=dark]{--bg:#1b1a19;--panel:#252423;--text:#f3f2f1;--muted:#c8c6c4;--line:#3b3a39;--hover:#323130;--sel:#0f3a5e;
  --done:#54b054;--active:#479ef5;--new:#797775;--removed:#484644;--accent:#479ef5}
body{font-family:"Segoe UI","Segoe UI Web (West European)",-apple-system,BlinkMacSystemFont,Roboto,"Helvetica Neue",sans-serif}
.kpi,.card,table,#graph,#g-overlay,.sp,.seg,.btn,input[type=search],input[type=date],select{border-radius:4px}
.seg button.on{background:var(--accent)}
</style>
'@
$at = $report.IndexOf('</head>')
if ($at -lt 0) { throw 'Report has no </head>' }
$report = $report.Substring(0, $at) + $palette + $report.Substring($at)
[IO.File]::WriteAllText((Join-Path $docs 'work-map.html'), $report, $utf8)
Write-Host "Built $(Join-Path $docs 'work-map.html')"

# The sprint planning preview
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'sprint-planning\build.ps1')

# The frame, once per starting hub
$shell = [IO.File]::ReadAllText((Join-Path $here 'shell.template.html'))
foreach ($p in @(@('index.html', 'map'), @('sprint-planning.html', 'plan'))) {
    [IO.File]::WriteAllText((Join-Path $docs $p[0]), $shell.Replace('__HUB__', $p[1]), $utf8)
    Write-Host "Built $(Join-Path $docs $p[0])"
}
