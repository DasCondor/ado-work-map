<#
.SYNOPSIS
    Test the -Check setup step against a fake Azure DevOps on localhost (no real connection).

.DESCRIPTION
    The fake project has teams "Alpha" and "Beta" (no "<project> Team"), refuses repositories
    with 403, and has no Analytics. Expected: project and work items ok, a FIX that lists the
    teams, a FIX for Code with the missing permission, exit code 2. Then again with -Team Alpha:
    sprints ok with the current one named.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\Test-Check.ps1 [-Script report\ado_work_map.ps1]
#>
param([string]$Script)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Script) { $Script = @((Join-Path (Split-Path -Parent $here) 'report\ado_work_map.ps1'), (Join-Path (Split-Path -Parent $here) 'ado_work_map.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1 }
$port = 8797
$server = Start-Job -ArgumentList $port -ScriptBlock {
    param($port)
    $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$port/"); $l.Start()
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $ctx = $l.GetContext(); $p = [uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
        $code = 200
        $body = switch -Regex ($p) {
            '/_apis/projects/P$' { '{"name":"P","id":"1"}' }
            '/_apis/projects/P/teams$' { '{"value":[{"name":"Beta"},{"name":"Alpha"}]}' }
            '/P/_apis/wit/wiql$' { '{"workItems":[{"id":1}]}' }
            '/P/Alpha/_apis/work/teamsettings/iterations$' { '{"value":[{"name":"S1","attributes":{"timeFrame":"past"}},{"name":"S2","attributes":{"timeFrame":"current"}}]}' }
            '/P/_apis/git/repositories$' { $code = 403; '{"message":"TF401027: You need the Git Read permission."}' }
            default { $code = 404; '{"message":"not here"}' }
        }
        $b = [Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.StatusCode = $code; $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
    }
}
Start-Sleep -Milliseconds 800
$fail = 0
function Assert($cond, $what) { if ($cond) { Write-Host "  pass  $what" } else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:fail++ } }
$common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-ServerUrl', "http://localhost:$port", '-Org', 'O', '-Project', 'P', '-Pat', 'test', '-OutDir', (Join-Path $env:TEMP 'adomap_checktest'), '-Check')
try {
    $out = (& powershell.exe @common 2>&1 | Out-String); $exit = $LASTEXITCODE
    Assert ($out -match 'ok\s+Project: P') 'project read'
    Assert ($out -match 'ok\s+Work items') 'work items read'
    Assert ($out -match "FIX\s+Team 'P Team'.*one of: Alpha; Beta") 'missing default team lists the real teams'
    Assert ($out -match 'FIX\s+Code.*\(403\).*missing a permission') 'repository 403 explained'
    Assert ($out -match 'note\s+Analytics') 'analytics only a note'
    Assert ($exit -eq 2) "exit code 2 when something needs fixing (got $exit)"
    $out2 = (& powershell.exe @($common + @('-Team', 'Alpha')) 2>&1 | Out-String)
    Assert ($out2 -match "ok\s+Sprints for 'Alpha': 2, current: S2") 'sprints for the chosen team'
}
finally { Stop-Job $server -ErrorAction SilentlyContinue; Remove-Job $server -Force -ErrorAction SilentlyContinue }
if ($fail) { Write-Host "$fail failed"; exit 1 } else { Write-Host 'All passed' }
