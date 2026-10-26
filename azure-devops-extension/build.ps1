<#
.SYNOPSIS
    Build the ADO Work Map Azure DevOps extension (Boards > Work Map hub).

.DESCRIPTION
    Generates dist\ from the report template inside ado_work_map.ps1, so the hub always
    shows the same report as the script:
      dist\hub.html   the template's page, plus the hub bar, settings and loading panel
      dist\report.js  the template's report script, wrapped as runReport(D)
      dist\hub.js     pulls the data with the signed-in user's access (src\hub.js)
      dist\sdk\       the Azure DevOps extension SDK (MIT, bundled - no CDN)

    Then packages the .vsix with Microsoft's tfx-cli (npm install -g tfx-cli), unless
    -NoPackage is given.

.EXAMPLE
    .\azure-devops-extension\build.ps1
    Writes azure-devops-extension\DasCondor.ado-work-map-boards-<version>.vsix
.EXAMPLE
    .\azure-devops-extension\build.ps1 -Tfx C:\tools\node_modules\.bin\tfx.cmd
#>
param([string]$Tfx, [switch]$NoPackage)
$ErrorActionPreference = 'Stop'
$ext = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $ext
$utf8 = New-Object Text.UTF8Encoding $false

# --- the report template from the script
$src = [IO.File]::ReadAllText((Join-Path $repo 'ado_work_map.ps1')).Replace("`r`n", "`n")
$open = "`$HtmlTemplate = @'`n"
$a = $src.IndexOf($open)
if ($a -lt 0) { throw 'Report template not found in ado_work_map.ps1' }
$a += $open.Length
$b = $src.IndexOf("`n'@", $a)
$tpl = $src.Substring($a, $b - $a)

function Get-Between([string]$Text, [string]$From, [string]$To, [switch]$Last) {
    $i = if ($Last) { $Text.LastIndexOf($From) } else { $Text.IndexOf($From) }
    if ($i -lt 0) { throw "Template changed: '$From' not found" }
    $i += $From.Length
    $j = $Text.IndexOf($To, $i)
    if ($j -lt 0) { throw "Template changed: '$To' not found" }
    return $Text.Substring($i, $j - $i)
}
$head = Get-Between $tpl '<head>' '</head>'
$bodyAll = Get-Between $tpl '<body>' '</body>'
$cut = $bodyAll.LastIndexOf('<script>')
$markup = $bodyAll.Substring(0, $cut)
$script = Get-Between $bodyAll '<script>' '</script>' -Last
$dataLine = 'const D = __DATA__;'
if ($script.IndexOf($dataLine) -lt 0) { throw "Template changed: '$dataLine' not found" }
$script = $script.Replace($dataLine, '')
# The experimental maps: their own file, so a mistake in them can't stop the report
$lab = Get-Between $bodyAll '<script id="lab">' '</script>'

# In the hub the history comes from this browser, not history.csv
$markup = $markup.Replace('(whole scope, from history.csv)', '(whole scope, saved on each visit - Pull history adds the past)')

$hubCss = @'
<style>
#hub-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:6px 20px;background:var(--panel);border-bottom:1px solid var(--line);font-size:13px}
#hub-bar .grow{flex:1;min-width:120px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#hub-bar.busy #hub-status::before{content:"";display:inline-block;width:10px;height:10px;margin-right:6px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:hubspin .8s linear infinite;vertical-align:-1px}
#hub-bar.busy .hub-act{opacity:.5;pointer-events:none}
@keyframes hubspin{to{transform:rotate(360deg)}}
#hub-error{margin:10px 20px;padding:10px 14px;border:1px solid #cc293d;border-radius:8px;background:color-mix(in srgb,#cc293d 10%,var(--panel));font-size:13px}
#hub-settings{margin:10px 20px;padding:12px 16px;background:var(--panel);border:1px solid var(--line);border-radius:8px}
#hub-settings .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:10px 16px}
#hub-settings label{display:flex;flex-direction:column;gap:3px;font-size:12px;color:var(--muted)}
#hub-settings label.chk{flex-direction:row;align-items:center;gap:6px;color:var(--text)}
#hub-settings input[type=text],#hub-settings input[type=number],#hub-settings select{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:5px 9px;font:inherit;font-size:13px}
#hub-settings .acts{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
#hub-loading{display:flex;flex-direction:column;align-items:center;gap:12px;padding:60px 20px;text-align:center}
#hub-loading[hidden],#hub-settings[hidden],#hub-error[hidden],#report[hidden]{display:none}
#hub-loading .spin{width:28px;height:28px;border:3px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:hubspin .8s linear infinite}
#hub-log{max-width:760px;width:100%;max-height:260px;overflow:auto;text-align:left;font:12px/1.4 ui-monospace,Consolas,monospace;color:var(--muted);background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px 10px;margin:0;white-space:pre-wrap}
</style>
'@

$hubTop = @'
<div id="hub-bar">
  <span class="grow" id="hub-status">Connecting to Azure DevOps...</span>
  <button class="btn hub-act" id="hub-refresh" title="Pull what changed since the last pull">Refresh</button>
  <button class="btn hub-act" id="hub-full" title="Re-read everything">Full refresh</button>
  <button class="btn hub-act" id="hub-history" title="Fill progress over time from Azure DevOps Analytics">Pull history</button>
  <button class="btn" id="hub-settings-btn">Settings</button>
</div>
<div id="hub-error" hidden></div>
<div id="hub-settings" hidden>
  <div class="grid">
    <label>Team (for sprints)<select id="s-team"></select></label>
    <label>Area path (blank = whole project)<input type="text" id="s-area" placeholder="Project\Team area"></label>
    <label>Work item types<input type="text" id="s-types"></label>
    <label>Only these epics and everything under them (ids)<input type="text" id="s-epics" placeholder="e.g. 101, 202"></label>
    <label>Skip items closed more than N days ago (-1 = keep all)<input type="number" id="s-closed" min="-1"></label>
    <label>Commit heatmap days (0 = off)<input type="number" id="s-commits" min="0"></label>
    <label>Linked PRs from other projects to look up per pull<input type="number" id="s-prs" min="0"></label>
    <label class="chk"><input type="checkbox" id="s-removed"> Include removed items</label>
  </div>
  <div class="acts">
    <button class="btn" id="s-save">Save and pull</button>
    <button class="btn" id="s-cancel">Cancel</button>
    <button class="btn" id="s-clear" style="margin-left:auto">Clear data saved in this browser</button>
  </div>
  <div class="sub" style="margin-top:8px">Settings and pulled data are kept in this browser, for this project only. Nothing is written to Azure DevOps.</div>
</div>
<div id="hub-loading">
  <div class="spin"></div>
  <b id="hub-step">Connecting to Azure DevOps...</b>
  <div class="sub">The first visit pulls everything; later visits only pull what changed.</div>
  <pre id="hub-log"></pre>
</div>
'@

$html = "<!doctype html>`n<html lang=`"en`">`n<head>$head$hubCss</head>`n<body>`n$hubTop<div id=`"report`" hidden>$markup</div>`n" +
        "<script src=`"report.js`"></script>`n<script src=`"lab.js`"></script>`n<script type=`"module`" src=`"hub.js`"></script>`n</body>`n</html>`n"
$report = "// Generated by build.ps1 from the report template in ado_work_map.ps1 - edit it there.`n" +
          "window.runReport = function (D) {`n$script`n};`n"

$dist = Join-Path $ext 'dist'
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
[void](New-Item -ItemType Directory -Force -Path (Join-Path $dist 'sdk'))
[IO.File]::WriteAllText((Join-Path $dist 'hub.html'), $html, $utf8)
[IO.File]::WriteAllText((Join-Path $dist 'report.js'), $report, $utf8)
[IO.File]::WriteAllText((Join-Path $dist 'lab.js'), $lab, $utf8)
Copy-Item (Join-Path $ext 'src\hub.js') (Join-Path $dist 'hub.js')
Copy-Item (Join-Path $ext 'sdk\SDK.min.js') (Join-Path $dist 'sdk\SDK.min.js')
Copy-Item (Join-Path $ext 'sdk\LICENSE.txt') (Join-Path $dist 'sdk\LICENSE.txt')
Copy-Item (Join-Path $repo 'LICENSE') (Join-Path $ext 'LICENSE.txt') -Force
Write-Host "Built $dist"

if ($NoPackage) { return }
if (-not $Tfx) {
    $cmd = Get-Command tfx -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'tfx not found. Install Node.js, then: npm install -g tfx-cli (or pass -Tfx <path to tfx.cmd>).' }
    $Tfx = $cmd.Source
}
Push-Location $ext
try {
    & $Tfx extension create --manifest-globs vss-extension.json --output-path $ext --no-prompt
    if ($LASTEXITCODE -ne 0) { throw "tfx failed ($LASTEXITCODE)" }
}
finally { Pop-Location }
