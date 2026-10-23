<#
.SYNOPSIS
    Pull Azure DevOps Epics, Features, User Stories and Tasks and build an
    interactive HTML work map across all sprints.

.DESCRIPTION
    Windows PowerShell 5.1, no extra modules. Produces one HTML report with:

      * Delivery map - Epic > Feature > Story > Task tree with accomplished vs
                       yet-to-be-accomplished roll-ups, plus a progress-over-time
                       chart from history.csv
      * Sprints      - every sprint on a timeline, velocity per sprint, a sprint
                       map (features x sprints) and the detail of any sprint
      * Changes      - what was created, completed, updated or moved in any time
                       frame, plus a change log recorded between runs
      * Maps         - treemap of epics/features by % done, a repo matrix, and a
                       commit heatmap (commits per day by repo and author)
      * Spider web   - graph of work items and their links (parent/child, related,
                       dependencies) plus the PRs, commits, branches, builds and
                       repos attached to them

    Each run only pulls what changed in Azure DevOps since the last run. Work
    items and pull request info are kept in <OutDir>\cache, so a run after the
    first one is usually a handful of API calls:
      * work items: one id query for the scope, one for "changed since last run",
        then full details only for new or changed items
      * pull requests: metadata only (title, status, branches, author - never
        code, diffs or commits), read from the project's PR list 1000 per call.
        Completed PRs never change, so later runs only re-check active ones.
      * commits (heatmap): dates, author names and the part of the email before
        the @ (to join one person's accounts) only, for -CommitDays days;
        later runs re-read just the last two days

    Auth (first one found wins):
      1. -Pat, or env ADO_PAT / AZURE_DEVOPS_EXT_PAT
         PAT scopes: Work Items (Read), Code (Read), Project and Team (Read),
         Build (Read), and Analytics (Read) for -PullHistory
      2. Azure CLI, if installed and signed in (az login)
      3. Secure prompt for a PAT

    Azure DevOps Server (on-premises): pass -ServerUrl https://tfs.contoso.com/tfs
    and use the collection name as -Org.

    Settings can be saved once with -SaveConfig (never the PAT) to
    ado_work_map.config.json next to this script; later runs need no parameters.

.EXAMPLE
    run_ado_work_map.cmd -Serve
    Open the launch pad: a local page for first-time setup and data maintenance
    (pull, full refresh, rebuild, history, clear) with a live log.
.EXAMPLE
    .\ado_work_map.ps1 -Setup
    First-time setup: create the report folders and run_ado_work_map.cmd from the example.
.EXAMPLE
    .\ado_work_map.ps1 -Org contoso -Project Phoenix -Team "Phoenix Team" -SaveConfig
.EXAMPLE
    .\ado_work_map.ps1
    Pull what changed since the last run and rebuild the report.
.EXAMPLE
    .\ado_work_map.ps1 -Full
    Ignore the cache and pull everything again.
.EXAMPLE
    .\ado_work_map.ps1 -Offline
    Rebuild the report from saved data without calling Azure DevOps.
.EXAMPLE
    .\ado_work_map.ps1 -PullHistory -HistoryDays 365
    Backfill history.csv from Azure DevOps Analytics, then run as usual.
.EXAMPLE
    .\ado_work_map.ps1 -ClearArchive
    Delete the cache and archived reports (add -IncludeHistory to also delete history.csv).
.EXAMPLE
    .\ado_work_map.ps1 -Demo
    Sample data, no Azure DevOps connection needed.

.NOTES
    Outputs (in -OutDir, default .\ado_report next to this script):
      ado_work_map.html   interactive report - one self-contained file, works offline
      ado_work_map.json   normalized data
      ado_work_items.csv  flat list of work items (opens in Excel)
      history.csv         one row per work item type per day
      cache\              work items, PR info and settings from the last pull
      archive\            one copy of the report per day, kept -ArchiveDays days
#>
[CmdletBinding()]
param(
    [string]$Org,
    [string]$ServerUrl = 'https://dev.azure.com',
    [string]$Project,
    [string]$Team,
    [string]$Iteration,
    [string[]]$EpicId,
    [string]$AreaPath,
    [string[]]$Types = @('Epic', 'Feature', 'User Story', 'Technical Story', 'Product Backlog Item', 'Requirement', 'Bug', 'Task'),
    [int]$ClosedWithinDays = -1,
    [switch]$IncludeRemoved,
    [string]$Pat,
    [int]$MaxPrDetails = 500,
    [string]$OutDir,
    [string]$ConfigPath,
    [switch]$SaveConfig,
    [switch]$NoOpen,
    [switch]$Full,
    [switch]$Offline,
    [switch]$PullHistory,
    [int]$HistoryDays = 180,
    [int]$ArchiveDays = 30,
    [int]$CommitDays = 365,
    [switch]$ClearArchive,
    [switch]$IncludeHistory,
    [switch]$Setup,
    [switch]$Serve,
    [int]$Port = 8765,
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$ApiVersion = '7.1'
$AdoResource = '499b84ac-1321-427f-aa17-267ca6975798'   # Azure DevOps AAD app id
$StoryTypes = @('User Story', 'Technical Story', 'Product Backlog Item', 'Requirement')
$Levels = @{ 'Epic' = 0; 'Feature' = 1; 'User Story' = 2; 'Technical Story' = 2; 'Product Backlog Item' = 2; 'Requirement' = 2; 'Bug' = 2; 'Task' = 3 }
$TypeColors = @{
    Epic = '#e06c00'; Feature = '#773b93'; Story = '#009ccc'; Tech = '#2a9d8f'; Bug = '#cc293d'; Task = '#c99a06'; Other = '#8a8a8a'
    Repo = '#475569'; PR = '#0d9488'; Commit = '#94a3b8'; Branch = '#2563eb'; Build = '#a16207'
}

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
$ConfigKeys = 'Org', 'ServerUrl', 'Project', 'Team', 'Iteration', 'EpicId', 'AreaPath', 'Types', 'ClosedWithinDays', 'IncludeRemoved', 'MaxPrDetails', 'OutDir', 'HistoryDays', 'ArchiveDays', 'CommitDays'
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'ado_work_map.config.json' }
if (-not $Demo -and (Test-Path $ConfigPath)) {
    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    foreach ($k in $ConfigKeys) {
        if (-not $PSBoundParameters.ContainsKey($k) -and $cfg.PSObject.Properties[$k] -and $null -ne $cfg.$k) {
            Set-Variable -Name $k -Value $cfg.$k
        }
    }
    Write-Host "Using settings from $ConfigPath"
}
# Accept a pasted address as the organization: https://dev.azure.com/<org>[/<project>] or
# https://<org>.visualstudio.com[/<project>] (a common mix-up that otherwise breaks every URL)
if ($Org -and $Org.Trim() -match '^https?://') {
    $u = [uri]$Org.Trim()
    $segs = @($u.AbsolutePath.Trim('/').Split('/') | Where-Object { $_ } | ForEach-Object { [uri]::UnescapeDataString($_) })
    if ($u.Host -eq 'dev.azure.com' -and $segs.Count) { $Org = $segs[0]; $segs = @($segs | Select-Object -Skip 1) }
    elseif ($u.Host -match '^([^.]+)\.visualstudio\.com$') { $Org = $Matches[1] }
    else { throw "Organization looks like a web address ($Org). Use just the organization name; for Azure DevOps Server also set -ServerUrl." }
    if (-not $Project -and $segs.Count -and $segs[0] -notmatch '^_') { $Project = $segs[0] }
    Write-Host "Using organization '$Org'$(if ($Project) { " and project '$Project'" }) from the address given."
}
$Org = "$Org".Trim().Trim('/'); $Project = "$Project".Trim().Trim('/')

# Lists arrive as one "a,b,c" string when launched with powershell.exe -File (e.g. from the .cmd starter)
$EpicId = @($EpicId | ForEach-Object { "$_" -split '[,; ]+' } | Where-Object { $_ } | ForEach-Object { [int]$_ })
$Types = @($Types | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($SaveConfig) {
    $save = [ordered]@{}
    foreach ($k in $ConfigKeys) {
        $v = (Get-Variable -Name $k).Value
        if ($v -is [switch]) { $v = [bool]$v }
        elseif ($v -is [array]) { $v = [object[]]($v | ForEach-Object { $_ }) }
        $save[$k] = $v
    }
    $save | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host "Saved settings to $ConfigPath (PAT is never saved)"
}
if (-not $OutDir) { $OutDir = Join-Path $ScriptDir $(if ($Demo) { 'ado_report_demo' } else { 'ado_report' }) }
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)

# --------------------------------------------------------------------------- #
# Azure DevOps REST
# --------------------------------------------------------------------------- #
function Get-AuthHeader {
    $p = $Pat
    if (-not $p) { $p = $env:ADO_PAT }
    if (-not $p) { $p = $env:AZURE_DEVOPS_EXT_PAT }
    if ($p) { return 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$p")) }
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $tok = & az account get-access-token --resource $AdoResource --query accessToken -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $tok) { return 'Bearer ' + ($tok | Select-Object -First 1).Trim() }
    }
    try { $sec = Read-Host -AsSecureString 'Azure DevOps PAT' }
    catch { throw 'No credentials: fill in ADO_PAT_VALUE in run_ado_work_map.cmd, set an ADO_PAT environment variable, or run az login.' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $p = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $p) { throw 'No credentials: set ADO_PAT, pass -Pat, or run az login.' }
    return 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$p"))
}

function Invoke-Ado {
    param([string]$Url, [string]$Method = 'GET', $Body, [hashtable]$Query, [switch]$NoApiVersion)
    $q = @{}
    if (-not $NoApiVersion) { $q['api-version'] = $ApiVersion }
    if ($Query) { foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] } }
    $uri = $Url
    if ($q.Count) {
        $qs = ($q.Keys | ForEach-Object { [uri]::EscapeDataString($_) + '=' + [uri]::EscapeDataString([string]$q[$_]) }) -join '&'
        $uri += $(if ($Url.Contains('?')) { '&' } else { '?' }) + $qs
    }
    $script:ApiCalls++
    $req = @{
        Uri             = $uri
        Method          = $Method
        Headers         = @{ Authorization = $script:AuthHeader; Accept = 'application/json' }
        ContentType     = 'application/json'
        UseBasicParsing = $true
    }
    if ($null -ne $Body) { $req.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10 -Compress)) }
    try { $r = Invoke-RestMethod @req }
    catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
        throw "$Method $Url failed: $detail"
    }
    # A bad or expired PAT gets a 203 with an HTML sign-in page
    if ($r -is [string] -and $r.TrimStart().StartsWith('<')) { throw 'Azure DevOps returned a sign-in page - check the PAT / az login.' }
    return $r
}

function Get-WiqlQuoted([string]$s) { $s.Replace("'", "''") }

function Get-ScopeIds {
    param([string]$ChangedSince)
    if ($EpicId) {
        $wiql = "SELECT [System.Id] FROM WorkItemLinks WHERE [Source].[System.Id] IN ($($EpicId -join ',')) " +
                "AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' MODE (Recursive)"
        $res = Invoke-Ado "$ProjUrl/_apis/wit/wiql" -Method POST -Body @{ query = $wiql }
        $ids = New-Object 'Collections.Generic.HashSet[int]'
        foreach ($e in $EpicId) { [void]$ids.Add($e) }
        foreach ($rel in $res.workItemRelations) {
            if ($rel.source) { [void]$ids.Add([int]$rel.source.id) }
            if ($rel.target) { [void]$ids.Add([int]$rel.target.id) }
        }
        return , @($ids | Sort-Object)
    }
    $typeList = ($Types | ForEach-Object { "'" + (Get-WiqlQuoted $_) + "'" }) -join ', '
    $where = @('[System.TeamProject] = @project', "[System.WorkItemType] IN ($typeList)")
    if (-not $IncludeRemoved) { $where += "[System.State] <> 'Removed'" }
    if ($AreaPath) { $where += "[System.AreaPath] UNDER '$(Get-WiqlQuoted $AreaPath)'" }
    if ($ClosedWithinDays -ge 0) {
        $since = (Get-Date).AddDays(-$ClosedWithinDays).ToString('yyyy-MM-dd')
        $where += "([Microsoft.VSTS.Common.ClosedDate] = '' OR [Microsoft.VSTS.Common.ClosedDate] >= '$since')"
    }
    if ($ChangedSince) { $where += "[System.ChangedDate] >= '$ChangedSince'" }
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE $($where -join ' AND ') ORDER BY [System.Id]"
    $res = Invoke-Ado "$ProjUrl/_apis/wit/wiql" -Method POST -Body @{ query = $wiql } -Query @{ timePrecision = 'true' }
    return , @($res.workItems | ForEach-Object { [int]$_.id })
}

function Get-WorkItems([int[]]$Ids) {
    $out = New-Object 'Collections.Generic.List[object]'
    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $chunk = $Ids[$i..([Math]::Min($i + 199, $Ids.Count - 1))]
        $res = Invoke-Ado "$ProjUrl/_apis/wit/workitemsbatch" -Method POST -Body @{ ids = @($chunk); '$expand' = 'Relations'; errorPolicy = 'Omit' }
        foreach ($w in $res.value) { if ($w) { $out.Add($w) } }
        Write-Host "  fetched $([Math]::Min($i + 200, $Ids.Count))/$($Ids.Count) work items"
    }
    return , $out
}

function Get-StateCategories([string[]]$TypeNames) {
    $cats = @{}
    foreach ($t in $TypeNames) {
        try { $res = Invoke-Ado "$ProjUrl/_apis/wit/workitemtypes/$([uri]::EscapeDataString($t))/states" }
        catch { Write-Warning "states for ${t}: $_"; continue }
        foreach ($s in $res.value) { $cats["$t|$($s.name)"] = $s.category }
    }
    return $cats
}

function Get-Iterations {
    # Every sprint the team has selected (past, current and future)
    $teamName = if ($Team) { $Team } else { "$Project Team" }
    $list = New-Object 'Collections.Generic.List[object]'
    try {
        $res = Invoke-Ado "$ProjUrl/$([uri]::EscapeDataString($teamName))/_apis/work/teamsettings/iterations"
        foreach ($it in $res.value) {
            $a = $it.attributes
            $list.Add(@{
                    name = [string]$it.name; path = [string]$it.path
                    start = if ($a) { [string]$a.startDate } else { '' }
                    finish = if ($a) { [string]$a.finishDate } else { '' }
                    timeFrame = if ($a) { [string]$a.timeFrame } else { '' }
                })
        }
    }
    catch { Write-Warning "sprints for team '$teamName': $_  (use -Team, or -Iteration for the current sprint)" }
    return , $list
}

function Get-Repos {
    try {
        return , @((Invoke-Ado "$ProjUrl/_apis/git/repositories").value | ForEach-Object {
                @{ id = [string]$_.id; name = [string]$_.name; defaultBranch = [string]$_.defaultBranch; webUrl = [string]$_.webUrl } })
    }
    catch { Write-Warning "repositories: $_"; return , @() }
}

# --------------------------------------------------------------------------- #
# Pull requests - metadata only (title, status, branches, author). No code,
# diffs or commits are ever downloaded.
# --------------------------------------------------------------------------- #
function ConvertTo-PrInfo($pr) {
    @{
        title   = [string]$pr.title
        status  = [string]$pr.status
        source  = ([string]$pr.sourceRefName).Replace('refs/heads/', '')
        target  = ([string]$pr.targetRefName).Replace('refs/heads/', '')
        author  = if ($pr.createdBy) { [string]$pr.createdBy.displayName } else { '' }
        repo    = if ($pr.repository) { [string]$pr.repository.id } else { '' }
        created = [string]$pr.creationDate
        closed  = [string]$pr.closedDate
    }
}

function Sync-PullRequests([hashtable]$PrCache, [string]$SinceUtc, [string[]]$LinkedIds) {
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $calls = $script:ApiCalls
    function Read-PrPages([hashtable]$Criteria) {
        # The project-wide PR list returns up to 1000 PRs per call
        $skip = 0; $n = 0
        while ($true) {
            $q = @{ '$top' = 1000; '$skip' = $skip }
            foreach ($k in $Criteria.Keys) { $q[$k] = $Criteria[$k] }
            $res = Invoke-Ado "$ProjUrl/_apis/git/pullrequests" -Query $q
            $page = @($res.value | Where-Object { $_ })
            if ($page.Count -eq 0) { break }
            foreach ($pr in $page) { $id = [string]$pr.pullRequestId; $PrCache[$id] = ConvertTo-PrInfo $pr; [void]$seen.Add($id) }
            $skip += $page.Count; $n += $page.Count
        }
        return $n
    }
    try {
        if ($PrCache.Count -eq 0 -or -not $SinceUtc) {
            Write-Host '  listing all pull requests in the project (metadata only)...'
            $n = Read-PrPages @{ 'searchCriteria.status' = 'all' }
        }
        else {
            # Completed and abandoned PRs don't change: only re-read active ones and those closed since the last run
            $n = Read-PrPages @{ 'searchCriteria.status' = 'active' }
            try { $n += Read-PrPages @{ 'searchCriteria.status' = 'all'; 'searchCriteria.queryTimeRangeType' = 'closed'; 'searchCriteria.minTime' = $SinceUtc } }
            catch { Write-Verbose "closed-since PR filter not available: $_" }
        }
        Write-Host "  $n pull requests read in $($script:ApiCalls - $calls) calls"
    }
    catch { Write-Warning "pull request list: $_" }

    # Linked PRs the lists didn't cover (other projects, or active last time and not seen now)
    $todo = @($LinkedIds | Where-Object { -not $seen.Contains($_) -and (-not $PrCache.ContainsKey($_) -or $PrCache[$_].status -eq 'active') } | Sort-Object { [int]$_ })
    if ($todo.Count) {
        Write-Host "  looking up $([Math]::Min($todo.Count, $MaxPrDetails)) linked pull requests one by one"
        $i = 0
        foreach ($id in $todo) {
            if ($i -ge $MaxPrDetails) { break }
            $i++
            try { $PrCache[$id] = ConvertTo-PrInfo (Invoke-Ado "$BaseUrl/_apis/git/pullrequests/$id") } catch { }
        }
        if ($todo.Count -gt $MaxPrDetails) { Write-Host "  $($todo.Count - $MaxPrDetails) left for the next run (raise -MaxPrDetails to get them now)" }
    }
}

# --------------------------------------------------------------------------- #
# Commit counts for the heatmap: per day, repo and author. Only commit dates and
# author names are read - never file contents or diffs.
# --------------------------------------------------------------------------- #
function Sync-Commits($Rows, [string]$SinceUtc, $Repos) {
    # $Rows: existing rows (d, r, a, n). Returns the updated list.
    $now = (Get-Date).ToUniversalTime()
    $cut = $now.Date.AddDays(-$CommitDays).ToString('yyyy-MM-dd')
    # Re-read the last couple of days every run so late pushes are counted; older days are kept as they are
    $from = if ($SinceUtc -and @($Rows).Count) { ([datetime]$SinceUtc).ToUniversalTime().Date.AddDays(-2) } else { $now.Date.AddDays(-$CommitDays) }
    $fromDay = $from.ToString('yyyy-MM-dd')
    $out = New-Object 'Collections.Generic.List[object]'
    foreach ($r in $Rows) { $d = [string]$r[0]; if ($d -lt $fromDay -and $d -ge $cut) { $out.Add(@($d, [string]$r[1], [string]$r[2], [int]$r[3])) } }
    $agg = @{}
    $calls = $script:ApiCalls; $n = 0
    foreach ($rp in $Repos) {
        $skip = 0
        while ($true) {
            try {
                $res = Invoke-Ado "$ProjUrl/_apis/git/repositories/$($rp.id)/commits" -Query @{
                    'searchCriteria.fromDate' = $from.ToString('yyyy-MM-ddTHH:mm:ssZ'); 'searchCriteria.$top' = 1000; 'searchCriteria.$skip' = $skip }
            }
            catch { break }   # empty or disabled repo
            $page = @($res.value | Where-Object { $_ })
            foreach ($c in $page) {
                $cd = $c.committer.date
                $d = if ($cd -is [datetime]) { $cd.ToUniversalTime().ToString('yyyy-MM-dd') } else { ([string]$cd).Substring(0, 10) }
                if ($d -lt $fromDay) { continue }
                # Name plus the part of the email before the @ (never the full address), so the report can
                # join one person's commits made under different names, e.g. First.Last.CTR
                $who = [string]$c.author.name
                $local = ([string]$c.author.email).Split('@')[0]
                if ($local) { $who += " <$local>" }
                $k = "$d|$($rp.id)|$who"
                $agg[$k] = 1 + [int]$agg[$k]
            }
            $n += $page.Count
            if ($page.Count -lt 100) { break }   # last page (pages are never smaller than 100 unless they're the last)
            $skip += $page.Count
        }
    }
    foreach ($k in $agg.Keys) { $p = $k.Split([char]'|', 3); $out.Add(@($p[0], $p[1], $p[2], $agg[$k])) }
    Write-Host "  $n commits read since $fromDay in $($script:ApiCalls - $calls) calls"
    return , $out
}

# --------------------------------------------------------------------------- #
# Local cache. Reading uses System.Web.Extensions (ships with .NET Framework),
# which is much faster than ConvertFrom-Json for multi-megabyte files.
# --------------------------------------------------------------------------- #
Add-Type -AssemblyName System.Web.Extensions
function New-Serializer {
    $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $s.MaxJsonLength = [int]::MaxValue
    $s.RecursionLimit = 64
    return $s
}
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    return (New-Serializer).DeserializeObject([IO.File]::ReadAllText($Path))
}
function Write-JsonFile([string]$Path, $Obj) {
    # ConvertTo-Json copes with PowerShell's wrapped objects; the serializer above is only used for reading
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Obj -Depth 10 -Compress), (New-Object Text.UTF8Encoding $false))
}
function ConvertTo-Hashtable($Dict) {
    $h = @{}
    if ($Dict) { foreach ($k in $Dict.Keys) { $h[$k] = $Dict[$k] } }
    return $h
}

$CacheFields = @('System.WorkItemType', 'System.State', 'System.IterationPath', 'System.Title', 'System.AssignedTo', 'System.AreaPath',
    'System.Tags', 'System.CreatedDate', 'System.ChangedDate', 'Microsoft.VSTS.Common.ClosedDate',
    'Microsoft.VSTS.Scheduling.StoryPoints', 'Microsoft.VSTS.Scheduling.Effort',
    'Microsoft.VSTS.Scheduling.RemainingWork', 'Microsoft.VSTS.Scheduling.CompletedWork')
$CacheRels = @('System.LinkTypes.Hierarchy-Reverse', 'System.LinkTypes.Related', 'System.LinkTypes.Dependency-Forward', 'ArtifactLink')

function ConvertTo-CacheItem($w) {
    # Keep only the fields and links the report uses
    $f = @{}
    foreach ($k in $CacheFields) {
        $v = $w.fields.$k
        if ($null -eq $v) { continue }
        if ($k -eq 'System.AssignedTo') { $v = @{ displayName = [string]$v.displayName } }
        elseif ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('o') }
        elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $v = [double]$v }
        else { $v = [string]$v }
        $f[$k] = $v
    }
    $rels = New-Object 'Collections.Generic.List[object]'
    foreach ($r in $w.relations) { if ($CacheRels -contains $r.rel) { $rels.Add(@{ rel = [string]$r.rel; url = [string]$r.url }) } }
    return @{ id = [int]$w.id; rev = [int]$w.rev; fields = $f; relations = $rels }
}

function Get-ParentId($Item) {
    foreach ($r in $Item.relations) { if ($r.rel -eq 'System.LinkTypes.Hierarchy-Reverse') { return Get-LinkTargetId $r.url } }
    return $null
}

function Compare-CacheItem($Old, $New, [string]$When, $Log) {
    # Record what changed between the previous pull and this one
    $o = $Old.fields; $n = $New.fields
    $base = @{ when = $When; id = [int]$New.id; type = [string]$n.'System.WorkItemType'; title = [string]$n.'System.Title' }
    $checks = @(
        @('State', 'System.State'), @('Sprint', 'System.IterationPath'), @('Title', 'System.Title'),
        @('Area', 'System.AreaPath'), @('Points', 'Microsoft.VSTS.Scheduling.StoryPoints'))
    foreach ($c in $checks) {
        $a = "$($o.($c[1]))"; $b = "$($n.($c[1]))"
        if ($a -ne $b) { $e = $base.Clone(); $e.change = $c[0]; $e.from = $a; $e.to = $b; $Log.Add($e) }
    }
    $a = if ($o.'System.AssignedTo') { [string]$o.'System.AssignedTo'.displayName } else { '' }
    $b = if ($n.'System.AssignedTo') { [string]$n.'System.AssignedTo'.displayName } else { '' }
    if ($a -ne $b) { $e = $base.Clone(); $e.change = 'Assigned'; $e.from = $a; $e.to = $b; $Log.Add($e) }
    $a = "$(Get-ParentId $Old)"; $b = "$(Get-ParentId $New)"
    if ($a -ne $b) { $e = $base.Clone(); $e.change = 'Parent'; $e.from = $(if ($a) { "#$a" } else { '' }); $e.to = $(if ($b) { "#$b" } else { '' }); $Log.Add($e) }
}

function Sync-WorkItems([hashtable]$Cache, [string]$SinceUtc, [string]$When, $Log, [switch]$FetchAll) {
    # $Cache: [int] id -> cache item, updated in place. Changes go to $Log.
    Write-Host 'Checking work items in scope...'
    $firstPull = $Cache.Count -eq 0
    $scopeIds = Get-ScopeIds
    $inScope = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($id in $scopeIds) { [void]$inScope.Add($id) }

    # Items that left the scope (closed long ago, moved area, removed, deleted...)
    $dropped = 0
    $extras = @{}
    foreach ($id in @($Cache.Keys)) {
        if ($inScope.Contains($id)) { continue }
        $old = $Cache[$id]
        if ($old.extra) { $extras[$id] = $old }
        else {
            $dropped++
            $Log.Add(@{ when = $When; id = $id; type = [string]$old.fields.'System.WorkItemType'; title = [string]$old.fields.'System.Title'; change = 'Left scope'; from = [string]$old.fields.'System.State'; to = '' })
        }
        $Cache.Remove($id)
    }

    $fetch = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($id in $scopeIds) { if (-not $Cache.ContainsKey($id)) { [void]$fetch.Add($id) } }
    $newCount = $fetch.Count
    if ($FetchAll) { foreach ($id in $scopeIds) { [void]$fetch.Add($id) } }
    elseif ($SinceUtc -and -not $firstPull) {
        if ($EpicId) {
            # Link queries can't filter on ChangedDate: compare revision numbers instead (cheap, 200 per call)
            $known = @($scopeIds | Where-Object { $Cache.ContainsKey($_) })
            for ($i = 0; $i -lt $known.Count; $i += 200) {
                $chunk = $known[$i..([Math]::Min($i + 199, $known.Count - 1))]
                $res = Invoke-Ado "$ProjUrl/_apis/wit/workitemsbatch" -Method POST -Body @{ ids = @($chunk); fields = @('System.Id', 'System.Rev'); errorPolicy = 'Omit' }
                foreach ($v in $res.value) { if ($v -and [int]$Cache[[int]$v.id].rev -ne [int]$v.rev) { [void]$fetch.Add([int]$v.id) } }
            }
        }
        else {
            foreach ($id in (Get-ScopeIds -ChangedSince $SinceUtc)) { if ($Cache.ContainsKey($id)) { [void]$fetch.Add($id) } }
        }
    }
    Write-Host "  $($scopeIds.Count) in scope: $newCount new, $($fetch.Count - $newCount) changed, $dropped left the scope"

    if ($fetch.Count) {
        foreach ($w in (Get-WorkItems @($fetch))) {
            $item = ConvertTo-CacheItem $w
            $id = $item.id
            if ($Cache.ContainsKey($id)) { Compare-CacheItem $Cache[$id] $item $When $Log }
            elseif (-not $firstPull) {
                $Log.Add(@{ when = $When; id = $id; type = [string]$item.fields.'System.WorkItemType'; title = [string]$item.fields.'System.Title'; change = 'Added'; from = ''; to = [string]$item.fields.'System.State' })
            }
            $Cache[$id] = $item
        }
    }

    # Parents outside the filter keep the tree connected. Cached ones are kept while still needed
    # and re-read only when their revision changed.
    $stale = New-Object 'Collections.Generic.List[int]'
    for ($round = 0; $round -lt 8; $round++) {
        $need = New-Object 'Collections.Generic.HashSet[int]'
        $restored = 0
        foreach ($ci in @($Cache.Values)) {
            $p = Get-ParentId $ci
            if ($null -eq $p -or $Cache.ContainsKey($p)) { continue }
            if ($extras.ContainsKey($p)) { $Cache[$p] = $extras[$p]; $stale.Add($p); $restored++ } else { [void]$need.Add($p) }
        }
        if ($need.Count) {
            Write-Host "  fetching $($need.Count) parent items outside the filter"
            foreach ($w in (Get-WorkItems @($need))) { $item = ConvertTo-CacheItem $w; $item.extra = $true; $Cache[$item.id] = $item }
        }
        elseif ($restored -eq 0) { break }
    }
    if ($stale.Count) {
        $changedExtras = New-Object 'Collections.Generic.List[int]'
        for ($i = 0; $i -lt $stale.Count; $i += 200) {
            $chunk = $stale.GetRange($i, [Math]::Min(200, $stale.Count - $i)).ToArray()
            $res = Invoke-Ado "$ProjUrl/_apis/wit/workitemsbatch" -Method POST -Body @{ ids = @($chunk); fields = @('System.Id', 'System.Rev'); errorPolicy = 'Omit' }
            foreach ($v in $res.value) { if ($v -and [int]$Cache[[int]$v.id].rev -ne [int]$v.rev) { $changedExtras.Add([int]$v.id) } }
        }
        if ($changedExtras.Count) {
            foreach ($w in (Get-WorkItems @($changedExtras))) { $item = ConvertTo-CacheItem $w; $item.extra = $true; $Cache[$item.id] = $item }
        }
    }
}

# --------------------------------------------------------------------------- #
# Sprints
# --------------------------------------------------------------------------- #
function Get-SprintList($Iterations, $Raw) {
    # Team sprints plus any other iteration path work items sit in, oldest first
    $now = (Get-Date).ToUniversalTime()
    $list = New-Object 'Collections.Generic.List[object]'
    $known = @{}
    foreach ($it in $Iterations) {
        $s = @{ name = [string]$it.name; path = [string]$it.path; start = [string]$it.start; finish = [string]$it.finish; timeFrame = [string]$it.timeFrame }
        if ($s.start -and $s.finish) {
            $st = ([datetime]$s.start).ToUniversalTime(); $fi = ([datetime]$s.finish).ToUniversalTime().AddDays(1)
            $s.timeFrame = if ($now -lt $st) { 'future' } elseif ($now -ge $fi) { 'past' } else { 'current' }
        }
        if (-not $known.ContainsKey($s.path.ToLower())) { $list.Add($s); $known[$s.path.ToLower()] = 1 }
    }
    $root = "$Project".ToLower()
    foreach ($w in $Raw) {
        $p = [string]$w.fields.'System.IterationPath'
        if (-not $p -or $p.ToLower() -eq $root) { continue }
        $q = $p.ToLower(); $covered = $false
        while ($true) {
            if ($known.ContainsKey($q)) { $covered = $true; break }
            $i = $q.LastIndexOf('\'); if ($i -lt 0) { break }
            $q = $q.Substring(0, $i)
        }
        if (-not $covered) { $list.Add(@{ name = ($p -split '\\')[-1]; path = $p; start = ''; finish = ''; timeFrame = '' }); $known[$p.ToLower()] = 1 }
    }
    $current = $null
    if ($Iteration) {
        $current = $list | Where-Object { $_.path -eq $Iteration } | Select-Object -First 1
        if (-not $current) { $current = @{ name = ($Iteration -split '\\')[-1]; path = $Iteration; start = ''; finish = ''; timeFrame = 'current' }; $list.Add($current) }
    }
    else { $current = $list | Where-Object { $_.timeFrame -eq 'current' } | Select-Object -First 1 }
    $natural = { [regex]::Replace([string]$_.name, '\d+', { param($m) $m.Value.PadLeft(8, '0') }) }
    $sorted = @($list | Sort-Object @{ e = { if ($_.start) { $_.start } else { '9999' } } }, @{ e = $natural })
    return @{ list = $sorted; current = $current }
}

# --------------------------------------------------------------------------- #
# History backfill from Azure DevOps Analytics (daily counts per type and state)
# --------------------------------------------------------------------------- #
function Import-AdoHistory([int]$Days, [string]$Path) {
    $since = (Get-Date).ToUniversalTime().Date.AddDays(-$Days).ToString('yyyy-MM-dd') + 'T00:00:00Z'
    $typeList = ($Types | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $filter = "DateValue ge $since and WorkItemType in ($typeList)"
    if ($AreaPath) { $filter += " and startswith(Area/AreaPath,'$($AreaPath.Replace("'", "''"))')" }
    if ($EpicId) { Write-Warning 'History from Analytics covers the whole project (or -AreaPath), not just -EpicId.' }
    $apply = "filter($filter)/groupby((DateValue,WorkItemType,StateCategory),aggregate(`$count as Count))"
    # Azure DevOps Services serves Analytics from its own host; Azure DevOps Server from the collection URL
    $odata = if ($ServerUrl -match '^https://dev\.azure\.com') { "https://analytics.dev.azure.com/$([uri]::EscapeDataString($Org))/$([uri]::EscapeDataString($Project))" } else { $ProjUrl }
    $url = "$odata/_odata/v4.0-preview/WorkItemSnapshot?`$apply=$([uri]::EscapeDataString($apply))"
    Write-Host "Pulling $Days days of history from Azure DevOps Analytics..."
    $agg = @{}
    try {
        while ($url) {
            $res = Invoke-Ado $url -NoApiVersion
            foreach ($r in $res.value) {
                $key = ([string]$r.DateValue).Substring(0, 10) + '|' + [string]$r.WorkItemType
                if (-not $agg.ContainsKey($key)) { $agg[$key] = @{ done = 0; active = 0; new = 0; removed = 0 } }
                $agg[$key][(Get-Bucket ([string]$r.StateCategory) '')] += [int]$r.Count
            }
            $url = $res.'@odata.nextLink'
        }
    }
    catch { Write-Warning "History pull failed (is Analytics enabled, and does the PAT have Analytics (Read)?): $_"; return }

    $today = (Get-Date).ToString('yyyy-MM-dd')
    $dates = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($k in $agg.Keys) { $d = $k.Substring(0, 10); if ($d -ne $today) { [void]$dates.Add($d) } }
    $rows = New-Object 'Collections.Generic.List[object]'
    if (Test-Path $Path) { foreach ($r in (Import-Csv $Path)) { if (-not ($r.Project -eq $Project -and $dates.Contains($r.Date))) { $rows.Add($r) } } }
    foreach ($k in $agg.Keys) {
        $d = $k.Substring(0, 10); if ($d -eq $today) { continue }
        $a = $agg[$k]
        $rows.Add([pscustomobject]@{ Date = $d; Project = $Project; Type = $k.Substring(11); Done = $a.done; Active = $a.active
                New = $a.new; Removed = $a.removed; Total = $a.done + $a.active + $a.new })
    }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $Path))
    $rows | Sort-Object Date, Type | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Host "  $($dates.Count) days of history saved to $Path"
}

# --------------------------------------------------------------------------- #
# Change log (one row per detected change, appended each run)
# --------------------------------------------------------------------------- #
function Add-ChangeLog([string]$Path, $Log) {
    if (-not $Log.Count) { return }
    $Log | ForEach-Object { [pscustomobject]@{ When = $_.when; Project = $Project; Id = $_.id; Type = $_.type; Title = $_.title; Change = $_.change; From = $_.from; To = $_.to } } |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Append
}
function Read-ChangeLog([string]$Path, [int]$Max = 20000) {
    if (-not (Test-Path $Path)) { return , @() }
    $rows = @(Import-Csv $Path | Where-Object { $_.Project -eq $Project })
    if ($rows.Count -gt $Max) { $rows = $rows[($rows.Count - $Max)..($rows.Count - 1)] }
    return , @($rows | ForEach-Object { @{ when = $_.When; id = [int]$_.Id; type = $_.Type; title = $_.Title; change = $_.Change; from = $_.From; to = $_.To } })
}


# --------------------------------------------------------------------------- #
# Normalization
# --------------------------------------------------------------------------- #
function ConvertFrom-ArtifactUrl([string]$Url) {
    # vstfs:///Git/Commit/{proj}%2F{repo}%2F{sha}
    if (-not $Url -or -not $Url.StartsWith('vstfs:///', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $parts = $Url.Substring(9).Split([char[]]'/', 3)
    if ($parts.Count -lt 3) { return $null }
    $tool = $parts[0]; $kind = $parts[1]; $rest = [uri]::UnescapeDataString($parts[2])
    if ($tool -eq 'Git') {
        $segs = $rest.Split([char[]]'/', 3)
        if ($segs.Count -lt 3) { return $null }
        $a = @{ proj = $segs[0]; repo = $segs[1]; ident = $segs[2] }
        if ($kind -eq 'Commit') { $a.kind = 'Commit'; return $a }
        if ($kind -eq 'PullRequestId') { $a.kind = 'PR'; return $a }
        if ($kind -eq 'Ref') { $a.kind = 'Branch'; if ($a.ident.StartsWith('GB')) { $a.ident = $a.ident.Substring(2) }; return $a }
        return $null
    }
    if ($tool -eq 'Build' -and $kind -eq 'Build') { return @{ kind = 'Build'; proj = $null; repo = $null; ident = $rest } }
    return $null
}

function Get-Artifacts($Raw) {
    $out = New-Object 'Collections.Generic.List[object]'
    foreach ($w in $Raw) {
        foreach ($r in $w.relations) {
            if ($r.rel -eq 'ArtifactLink') {
                $a = ConvertFrom-ArtifactUrl $r.url
                if ($a) { $out.Add(@{ wid = [int]$w.id; a = $a }) }
            }
        }
    }
    return , $out
}

function Get-Bucket([string]$Category, [string]$State) {
    switch ($Category) {
        'Completed' { return 'done' }
        'Removed' { return 'removed' }
        'InProgress' { return 'active' }
        'Resolved' { return 'active' }
        'Proposed' { return 'new' }
    }
    $s = "$State".ToLower()
    if (@('done', 'closed', 'completed') -contains $s) { return 'done' }
    if ($s -eq 'removed') { return 'removed' }
    if (@('new', 'proposed', 'to do', 'approved') -contains $s) { return 'new' }
    return 'active'
}

function Get-WiKind([string]$Type) {
    if ($Type -eq 'Technical Story') { return 'Tech' }
    if ($StoryTypes -contains $Type) { return 'Story' }
    if (@('Epic', 'Feature', 'Bug', 'Task') -contains $Type) { return $Type }
    return 'Other'
}

function Get-LinkTargetId([string]$Url) {
    $last = $Url.TrimEnd('/').Split('/')[-1]
    $n = 0
    if ([int]::TryParse($last, [ref]$n)) { return $n }
    return $null
}

function Get-Short([string]$s, [int]$Max) {
    if ($s.Length -gt $Max) { return $s.Substring(0, $Max) + [char]0x2026 }
    return $s
}

function Build-Model($Raw, $Cats, $SprintInfo, $Repos, $PrDetails) {
    $Sprint = $SprintInfo.current
    $sprintPath = if ($Sprint) { [string]$Sprint.path } else { '' }
    $items = @{}

    foreach ($w in $Raw) {
        $f = $w.fields
        $t = [string]$f.'System.WorkItemType'
        $state = [string]$f.'System.State'
        $itPath = [string]$f.'System.IterationPath'
        $lvl = $Levels[$t]; if ($null -eq $lvl) { $lvl = 0 }
        $points = $f.'Microsoft.VSTS.Scheduling.StoryPoints'
        if ($null -eq $points) { $points = $f.'Microsoft.VSTS.Scheduling.Effort' }
        $id = [int]$w.id
        $items[$id] = @{
            id        = $id
            type      = $t
            kind      = Get-WiKind $t
            level     = $lvl
            title     = [string]$f.'System.Title'
            state     = $state
            bucket    = Get-Bucket $Cats["$t|$state"] $state
            assignee  = if ($f.'System.AssignedTo') { [string]$f.'System.AssignedTo'.displayName } else { '' }
            iteration = $itPath
            area      = [string]$f.'System.AreaPath'
            tags      = [string]$f.'System.Tags'
            points    = $points
            remaining = $f.'Microsoft.VSTS.Scheduling.RemainingWork'
            completed = $f.'Microsoft.VSTS.Scheduling.CompletedWork'
            created   = [string]$f.'System.CreatedDate'
            changed   = [string]$f.'System.ChangedDate'
            closed    = [string]$f.'Microsoft.VSTS.Common.ClosedDate'
            inSprint  = [bool]($sprintPath -and ($itPath -eq $sprintPath -or $itPath.StartsWith("$sprintPath\", [StringComparison]::OrdinalIgnoreCase)))
            url       = "$ProjUrl/_workitems/edit/$id"
            parent    = $null
            children  = New-Object 'Collections.Generic.List[int]'
        }
    }

    # Work item <-> work item links
    $wiLinks = New-Object 'Collections.Generic.List[object]'
    $seen = @{}
    foreach ($w in $Raw) {
        $src = [int]$w.id
        foreach ($r in $w.relations) {
            if ("$($r.url)" -notmatch '/workItems/') { continue }
            $dst = Get-LinkTargetId $r.url
            if ($null -eq $dst -or -not $items.ContainsKey($dst)) { continue }
            switch ($r.rel) {
                'System.LinkTypes.Hierarchy-Reverse' { $items[$src].parent = $dst }
                'System.LinkTypes.Related' {
                    $key = "$([Math]::Min($src, $dst))|$([Math]::Max($src, $dst))|related"
                    if (-not $seen[$key]) { $seen[$key] = 1; $wiLinks.Add(@{ from = $src; to = $dst; kind = 'related' }) }
                }
                'System.LinkTypes.Dependency-Forward' {
                    $key = "$src|$dst|depends"
                    if (-not $seen[$key]) { $seen[$key] = 1; $wiLinks.Add(@{ from = $src; to = $dst; kind = 'depends' }) }
                }
            }
        }
    }
    foreach ($it in $items.Values) { if ($null -ne $it.parent) { $items[$it.parent].children.Add($it.id) } }
    foreach ($it in @($items.Values)) {
        $it.children = @($it.children | Sort-Object @{ e = { $items[$_].level } }, @{ e = { $_ } })
    }

    # Roll-ups over leaf descendants
    $leafMemo = @{}
    function Get-Leaves([int]$Id) {
        if ($leafMemo.ContainsKey($Id)) { return , $leafMemo[$Id] }
        $res = New-Object 'Collections.Generic.List[int]'
        if ($items[$Id].children.Count -eq 0) { $res.Add($Id) }
        else { foreach ($c in $items[$Id].children) { foreach ($l in (Get-Leaves $c)) { $res.Add($l) } } }
        $leafMemo[$Id] = $res
        return , $res
    }
    foreach ($it in $items.Values) {
        $r = @{ done = 0; active = 0; new = 0 }
        foreach ($leaf in (Get-Leaves $it.id)) {
            $b = $items[$leaf].bucket
            if ($r.ContainsKey($b)) { $r[$b]++ }
        }
        $r.total = $r.done + $r.active + $r.new
        $r.pct = if ($r.total) { [int][Math]::Round(100 * $r.done / $r.total) } elseif ($it.bucket -eq 'done') { 100 } else { 0 }
        $it.roll = $r
    }

    $roots = @($items.Values | Where-Object { $null -eq $_.parent } | Sort-Object @{ e = { $_.level } }, @{ e = { $_.id } } | ForEach-Object { $_.id })

    # Summary per type
    $sum = @{}
    foreach ($it in $items.Values) {
        if (-not $sum.ContainsKey($it.type)) { $sum[$it.type] = @{ type = $it.type; total = 0; done = 0; active = 0; new = 0; removed = 0 } }
        $sum[$it.type].total++
        $sum[$it.type][$it.bucket]++
    }
    $summary = @($sum.Values | Sort-Object @{ e = { $l = $Levels[$_.type]; if ($null -eq $l) { 9 } else { $l } } }, @{ e = { $_.type } })

    # Spider web graph
    $repoById = @{}
    foreach ($rp in $Repos) { $repoById[[string]$rp.id] = $rp }
    $nodes = @{}
    $edges = New-Object 'Collections.Generic.List[object]'
    $check = [string][char]0x2713

    foreach ($it in $items.Values) {
        $tip = @("$($it.type) #$($it.id)", $it.title, "State: $($it.state)")
        if ($it.assignee) { $tip += "Assigned: $($it.assignee)" }
        if ($it.iteration) { $tip += "Iteration: $($it.iteration)" }
        $nodes["w$($it.id)"] = @{
            id = "w$($it.id)"; kind = $it.kind; wi = $true
            label = $(if ($it.bucket -eq 'done') { "$check " } else { '' }) + "#$($it.id) " + (Get-Short $it.title 38)
            title = $tip -join "`n"; url = $it.url; bucket = $it.bucket; inSprint = $it.inSprint; level = $it.level
        }
        if ($null -ne $it.parent) { $edges.Add(@{ from = "w$($it.parent)"; to = "w$($it.id)"; kind = 'child' }) }
    }
    foreach ($l in $wiLinks) { $edges.Add(@{ from = "w$($l.from)"; to = "w$($l.to)"; kind = $l.kind }) }

    function Add-RepoNode([string]$ProjId, [string]$RepoId) {
        $nid = "r$RepoId"
        if (-not $nodes.ContainsKey($nid)) {
            $rp = $repoById[$RepoId]
            $name = if ($rp) { [string]$rp.name } else { "repo $($RepoId.Substring(0, [Math]::Min(8, $RepoId.Length)))" }
            $tip = "Repository: $name"
            if ($rp -and $rp.defaultBranch) { $tip += "`ndefault: " + ([string]$rp.defaultBranch).Replace('refs/heads/', '') }
            $url = if ($rp -and $rp.webUrl) { [string]$rp.webUrl } else { "$BaseUrl/$ProjId/_git/$RepoId" }
            $nodes[$nid] = @{ id = $nid; kind = 'Repo'; label = $name; title = $tip; url = $url; wis = (New-Object 'Collections.Generic.List[int]') }
        }
        return $nid
    }
    foreach ($rp in $Repos) { [void](Add-RepoNode $Project ([string]$rp.id)) }

    $wiRepo = @{}
    $arrow = [string][char]0x2192
    foreach ($entry in (Get-Artifacts $Raw)) {
        $wid = $entry.wid; $a = $entry.a
        if (-not $items.ContainsKey($wid)) { continue }
        $nid = "$($a.kind):$($a.repo):$($a.ident)"
        if (-not $nodes.ContainsKey($nid)) {
            $repoName = if ($a.repo -and $repoById[$a.repo]) { $repoById[$a.repo].name } else { $a.repo }
            $n = @{ id = $nid; kind = $a.kind; art = $true; wis = (New-Object 'Collections.Generic.List[int]') }
            switch ($a.kind) {
                'Commit' {
                    $n.label = $a.ident.Substring(0, [Math]::Min(7, $a.ident.Length))
                    $n.title = "Commit $($a.ident)`nRepo: $repoName"
                    $n.url = "$BaseUrl/$($a.proj)/_git/$($a.repo)/commit/$($a.ident)"
                }
                'PR' {
                    $d = $PrDetails["$($a.ident)"]
                    $n.label = "PR !$($a.ident)"
                    $tip = @("Pull request !$($a.ident)")
                    if ($d) {
                        if ($d.title) { $n.label += ' ' + (Get-Short $d.title 30); $tip += $d.title }
                        if ($d.status) { $tip += "Status: $($d.status)" }
                        if ($d.source) { $tip += "$($d.source) $arrow $($d.target)" }
                        if ($d.author) { $tip += "By: $($d.author)" }
                        $n.status = $d.status; $n.source = $d.source
                    }
                    $tip += "Repo: $repoName"
                    $n.title = $tip -join "`n"
                    $n.url = "$BaseUrl/$($a.proj)/_git/$($a.repo)/pullrequest/$($a.ident)"
                }
                'Branch' {
                    $n.label = $a.ident
                    $n.title = "Branch $($a.ident)`nRepo: $repoName"
                    $n.url = "$BaseUrl/$($a.proj)/_git/$($a.repo)?version=GB$([uri]::EscapeDataString($a.ident))"
                }
                default {
                    $n.label = "Build $($a.ident)"; $n.title = "Build $($a.ident)"
                    $n.url = "$ProjUrl/_build/results?buildId=$($a.ident)"
                }
            }
            $nodes[$nid] = $n
            if ($a.repo) {
                $rid = Add-RepoNode $a.proj $a.repo
                $n.repo = $rid
                $edges.Add(@{ from = $nid; to = $rid; kind = 'in-repo' })
            }
        }
        $n = $nodes[$nid]
        if (-not $n.wis.Contains($wid)) {
            $n.wis.Add($wid)
            $edges.Add(@{ from = "w$wid"; to = $nid; kind = 'artifact' })
        }
        if ($n.repo) {
            $rn = $nodes[$n.repo]
            if (-not $rn.wis.Contains($wid)) { $rn.wis.Add($wid) }
            $key = "$wid|$($n.repo)"
            if (-not $wiRepo.ContainsKey($key)) { $wiRepo[$key] = @{ wid = $wid; rid = $n.repo; via = (New-Object 'Collections.Generic.List[string]') } }
            if (-not $wiRepo[$key].via.Contains($nid)) { $wiRepo[$key].via.Add($nid) }
        }
    }

    # PR -> source branch, when that branch is also linked
    foreach ($n in @($nodes.Values)) {
        if ($n.kind -eq 'PR' -and $n.source -and $n.repo) {
            $bid = "Branch:$($n.repo.Substring(1)):$($n.source)"
            if ($nodes.ContainsKey($bid)) { $edges.Add(@{ from = $n.id; to = $bid; kind = 'pr-branch' }) }
        }
    }
    # Direct work item -> repo edges, drawn only when the artifacts between them are hidden
    foreach ($x in $wiRepo.Values) { $edges.Add(@{ from = "w$($x.wid)"; to = $x.rid; kind = 'wi-repo'; via = $x.via }) }
    for ($i = 0; $i -lt $edges.Count; $i++) { $edges[$i].id = "e$i" }

    return @{
        org = $Org; project = $Project; projectUrl = $ProjUrl
        generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        sprint = $Sprint
        sprints = $SprintInfo.list
        changes = @()
        runUtc = ''
        summary = $summary
        items = @($items.Values | Sort-Object { $_.id })
        roots = $roots
        graph = @{ nodes = @($nodes.Values); edges = $edges }
        typeColors = $TypeColors
        history = @()
    }
}

# --------------------------------------------------------------------------- #
# History (one row per type per day, so reruns build a progress trend)
# --------------------------------------------------------------------------- #
function Update-History($Model, [string]$Path, [switch]$SeedDemo, [switch]$NoWrite) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $rows = New-Object 'Collections.Generic.List[object]'
    if (Test-Path $Path) {
        foreach ($r in (Import-Csv $Path)) { if (-not ($r.Date -eq $today -and $r.Project -eq $Project)) { $rows.Add($r) } }
    }
    elseif ($SeedDemo) {
        # Fake ten weeks of history so the demo chart has something to show
        for ($wk = 10; $wk -ge 1; $wk--) {
            $f = (10 - $wk) / 10
            foreach ($s in $Model.summary) {
                $total = [int][Math]::Round($s.total * (0.7 + 0.3 * $f))
                $done = [int][Math]::Round($s.done * $f * 0.95)
                $active = [int][Math]::Min($total - $done, [Math]::Round($s.active * (0.5 + 0.5 * $f)))
                $rows.Add([pscustomobject]@{ Date = (Get-Date).AddDays(-7 * $wk).ToString('yyyy-MM-dd'); Project = $Project; Type = $s.type
                        Done = $done; Active = $active; New = $total - $done - $active; Removed = 0; Total = $total })
            }
        }
    }
    if ($NoWrite) {
        # Offline rebuild: keep today's saved snapshot instead of replacing it
        if (Test-Path $Path) { foreach ($r in (Import-Csv $Path)) { if ($r.Date -eq $today -and $r.Project -eq $Project) { $rows.Add($r) } } }
    }
    else {
        foreach ($s in $Model.summary) {
            $rows.Add([pscustomobject]@{ Date = $today; Project = $Project; Type = $s.type; Done = $s.done; Active = $s.active
                    New = $s.new; Removed = $s.removed; Total = $s.total - $s.removed })
        }
        $rows | Sort-Object Date, Type | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
    $Model.history = @($rows | Where-Object { $_.Project -eq $Project } | Sort-Object Date | ForEach-Object {
            @{ date = $_.Date; type = $_.Type; done = [int]$_.Done; active = [int]$_.Active; new = [int]$_.New; total = [int]$_.Total } })
}

# --------------------------------------------------------------------------- #
# Demo data (same shapes the REST API returns)
# --------------------------------------------------------------------------- #
function New-DemoData {
    $rnd = New-Object System.Random 14
    function Pick($a) { $a[$rnd.Next($a.Count)] }
    $projId = '11111111-0000-0000-0000-000000000000'
    $repos = @()
    $i = 0
    foreach ($n in 'web-portal', 'payments-api', 'infra-terraform', 'mobile-app', 'shared-libs') {
        $repos += @{ id = ('{0:d8}-aaaa-bbbb-cccc-000000000000' -f $i); name = $n; defaultBranch = 'refs/heads/main'; webUrl = "https://dev.azure.com/demo/$Project/_git/$n" }
        $i++
    }
    $sprints = @(11..16 | ForEach-Object { "$Project\Sprint $_" })
    $current = $sprints[3]
    # Four-week sprints (Monday to the fourth Friday), Sprint 14 running today and Sprint 15 starting next Monday
    $today = (Get-Date).Date
    $s15 = $today.AddDays(7 - ((([int]$today.DayOfWeek) + 6) % 7))
    $sprintStart = @{}
    $iterations = New-Object 'Collections.Generic.List[object]'
    foreach ($k in 11..16) {
        $start = $s15.AddDays(($k - 15) * 28)
        $sprintStart["$Project\Sprint $k"] = $start
        $iterations.Add(@{ name = "Sprint $k"; path = "$Project\Sprint $k"; start = $start.ToString('yyyy-MM-ddT00:00:00Z')
                finish = $start.AddDays(25).ToString('yyyy-MM-ddT00:00:00Z'); timeFrame = '' })
    }
    function Iso($d) { $d.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $people = @('Avery Chen', 'Jordan Patel', 'Sam Rivera', 'Taylor Brooks', 'Riley Okafor')
    $cats = @{}
    foreach ($t in 'Epic', 'Feature', 'User Story', 'Technical Story', 'Bug', 'Task') {
        $cats["$t|New"] = 'Proposed'; $cats["$t|Active"] = 'InProgress'; $cats["$t|Resolved"] = 'Resolved'
        $cats["$t|Closed"] = 'Completed'; $cats["$t|Removed"] = 'Removed'
    }
    $raw = New-Object 'Collections.Generic.List[object]'
    $st = @{ nextId = 1000; pr = 400 }
    $prDetails = @{}

    function WiUrl($id) { "https://dev.azure.com/demo/_apis/wit/workItems/$id" }
    function New-Item2($type, $title, $parent, $state, $iter, $extra) {
        $id = $st.nextId; $st.nextId = $st.nextId + 1
        $fields = @{ 'System.WorkItemType' = $type; 'System.Title' = $title; 'System.State' = $state
            'System.IterationPath' = $iter; 'System.AreaPath' = "$Project\$(Pick @('Web', 'Web', 'Web\Portal', 'Mobile', 'Platform'))"
            'System.Tags' = ((@('customer-facing', 'tech-debt', 'security', 'needs-review', 'blocked', 'quick-win') | Where-Object { $rnd.NextDouble() -lt 0.2 }) -join '; ')
            'System.AssignedTo' = @{ displayName = (Pick $people) } }
        if ($extra) { foreach ($k in $extra.Keys) { $fields[$k] = $extra[$k] } }
        $base = if ($sprintStart.ContainsKey($iter)) { $sprintStart[$iter] } else { $today.AddDays(-$rnd.Next(5, 60)) }
        $created = $base.AddDays(-$rnd.Next(1, 25)).AddHours($rnd.Next(8, 18))
        if ($created -gt $today) { $created = $today.AddDays(-$rnd.Next(1, 10)) }
        $fields['System.CreatedDate'] = Iso $created
        if ($state -eq 'Closed') {
            $closed = $base.AddDays($rnd.Next(1, 12)).AddHours($rnd.Next(8, 18))
            if ($closed -gt (Get-Date)) { $closed = (Get-Date).AddHours(-$rnd.Next(1, 48)) }
            $fields['Microsoft.VSTS.Common.ClosedDate'] = Iso $closed
            $fields['System.ChangedDate'] = Iso $closed
        }
        else { $fields['System.ChangedDate'] = Iso ((Get-Date).AddHours(-$rnd.Next(1, 24 * 20))) }
        $rels = New-Object 'Collections.Generic.List[object]'
        if ($parent) {
            $rels.Add(@{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = (WiUrl $parent.id) })
            $parent.relations.Add(@{ rel = 'System.LinkTypes.Hierarchy-Forward'; url = (WiUrl $id) })
        }
        $w = @{ id = $id; fields = $fields; relations = $rels }
        $raw.Add($w)
        return $w
    }
    function Add-Art($w, $kind, $repo, $ident) {
        $enc = [uri]::EscapeDataString("$projId/$($repo.id)/$ident")
        $w.relations.Add(@{ rel = 'ArtifactLink'; url = "vstfs:///Git/$kind/$enc"; attributes = @{ name = $kind } })
    }

    $plan = [ordered]@{
        'Customer self-service portal' = @('Account dashboard', 'Profile & preferences', 'Support ticket center')
        'Payments modernization'       = @('Card tokenization', 'Refund workflow', 'Ledger reconciliation')
        'Cloud migration'              = @('Landing zone', 'Database cutover')
        'Mobile app v2'                = @('Offline mode', 'Push notifications')
    }
    $progress = @(0.85, 0.55, 0.3, 0.05)
    $verbs = @('Build', 'Design', 'Wire up', 'Validate', 'Instrument', 'Harden')
    $taskKinds = @('API endpoint', 'UI component', 'Unit tests', 'Pipeline step', 'Docs', 'Migration')
    $e = 0
    foreach ($epicTitle in $plan.Keys) {
        $p = $progress[$e]; $e++
        $epic = New-Item2 'Epic' $epicTitle $null $(if ($p -gt 0.1) { 'Active' } else { 'New' }) $Project $null
        foreach ($fTitle in $plan[$epicTitle]) {
            $featDone = $rnd.NextDouble() -lt ($p * 0.6)
            $feat = New-Item2 'Feature' $fTitle $epic $(if ($featDone) { 'Closed' } else { 'Active' }) $Project $null
            $repo = Pick $repos
            $storyCount = $rnd.Next(2, 5)
            for ($s = 0; $s -lt $storyCount; $s++) {
                $r = $rnd.NextDouble()
                if ($featDone -or $r -lt ($p - 0.15)) { $state = 'Closed'; $iter = Pick $sprints[0..2] }
                elseif ($r -lt ($p + 0.2)) { $state = Pick @('Active', 'Active', 'Resolved', 'New'); $iter = $current }
                else { $state = 'New'; $iter = Pick (@($sprints[4..5]) + $Project) }
                $r2 = $rnd.NextDouble(); $stype = if ($r2 -lt 0.15) { 'Bug' } elseif ($r2 -lt 0.3) { 'Technical Story' } else { 'User Story' }
                $story = New-Item2 $stype "$(Pick $verbs) $($fTitle.ToLower()) part $($s + 1)" $feat $state $iter @{ 'Microsoft.VSTS.Scheduling.StoryPoints' = (Pick @(1, 2, 3, 5, 8)) }
                $branch = "feature/$($story.id)-" + $fTitle.ToLower().Replace('&', 'and').Replace(' ', '-')
                if ($state -ne 'New') {
                    Add-Art $story 'Ref' $repo "GB$branch"
                    $st.pr = $st.pr + 1
                    $prId = [string]$st.pr
                    Add-Art $story 'PullRequestId' $repo $prId
                    $prDetails[$prId] = @{ title = $story.fields.'System.Title'; status = $(if ($state -eq 'Closed') { 'completed' } else { 'active' })
                        source = $branch; target = 'main'; author = $story.fields.'System.AssignedTo'.displayName }
                }
                $taskCount = $rnd.Next(2, 6)
                for ($k = 0; $k -lt $taskCount; $k++) {
                    $tst = if ($state -eq 'Closed') { 'Closed' } elseif ($state -eq 'New') { 'New' } else { Pick @('Closed', 'Active', 'New') }
                    $rem = if ($tst -eq 'Closed') { 0 } else { Pick @(2, 4, 6, 8) }
                    $task = New-Item2 'Task' "$(Pick $taskKinds) for #$($story.id)" $story $tst $iter @{
                        'Microsoft.VSTS.Scheduling.RemainingWork' = $rem; 'Microsoft.VSTS.Scheduling.CompletedWork' = (Pick @(0, 2, 4, 6)) }
                    if ($tst -ne 'New' -and $rnd.NextDouble() -lt 0.6) {
                        Add-Art $task 'Commit' $repo (-join (1..40 | ForEach-Object { '{0:x}' -f $rnd.Next(16) }))
                    }
                }
            }
        }
    }
    $stories = @($raw | Where-Object { @('User Story', 'Technical Story', 'Bug') -contains $_.fields.'System.WorkItemType' })
    for ($x = 0; $x -lt 6; $x++) {
        $a = Pick $stories; $b = Pick $stories
        if ($a.id -eq $b.id) { continue }
        $a.relations.Add(@{ rel = 'System.LinkTypes.Related'; url = (WiUrl $b.id) })
        $b.relations.Add(@{ rel = 'System.LinkTypes.Related'; url = (WiUrl $a.id) })
    }
    for ($x = 0; $x -lt 4; $x++) {
        $a = Pick $stories; $b = Pick $stories
        if ($a.id -ne $b.id) { $a.relations.Add(@{ rel = 'System.LinkTypes.Dependency-Forward'; url = (WiUrl $b.id) }) }
    }
    # A month of change-log entries, as if the script had run every few days
    $changes = New-Object 'Collections.Generic.List[object]'
    foreach ($w in $raw) {
        $f = $w.fields
        if ($rnd.NextDouble() -gt 0.35) { continue }
        $when = Iso ((Get-Date).AddDays(-$rnd.Next(0, 30)).Date.AddHours(9))
        $e = @{ when = $when; id = $w.id; type = $f.'System.WorkItemType'; title = $f.'System.Title' }
        switch ($rnd.Next(5)) {
            0 { $e.change = 'State'; $e.from = 'New'; $e.to = $f.'System.State' }
            1 { $e.change = 'Sprint'; $e.from = Pick $sprints; $e.to = $f.'System.IterationPath' }
            2 { $e.change = 'Assigned'; $e.from = Pick $people; $e.to = $f.'System.AssignedTo'.displayName }
            3 { $e.change = 'Added'; $e.from = ''; $e.to = $f.'System.State' }
            default { $e.change = 'State'; $e.from = 'Active'; $e.to = $f.'System.State' }
        }
        if ($e.from -ne $e.to) { $changes.Add($e) }
    }
    # A year of commit counts: busier mid-week, quieter on weekends and around holidays
    $commits = New-Object 'Collections.Generic.List[object]'
    for ($back = 364; $back -ge 0; $back--) {
        $day = $today.AddDays(-$back)
        $weekend = $day.DayOfWeek -eq 'Saturday' -or $day.DayOfWeek -eq 'Sunday'
        $holiday = ($day.Month -eq 12 -and $day.Day -ge 22) -or ($day.Month -eq 1 -and $day.Day -le 2)
        $ramp = 0.5 + 0.5 * (364 - $back) / 364
        foreach ($rp in $repos) {
            foreach ($who in $people) {
                $chance = if ($weekend) { 0.04 } elseif ($holiday) { 0.08 } else { 0.32 * $ramp }
                # Authors as "Name <email before the @>"; the first person also commits from a contractor
                # account (First.Last.CTR), which the report joins back into one person
                $local = ($who -replace ' ', '.').ToLower()
                $author = if ($who -eq $people[0] -and $rnd.NextDouble() -lt 0.3) { "$($who -replace ' ', '.').CTR <$local.ctr>" } else { "$who <$local>" }
                if ($rnd.NextDouble() -lt $chance) { $commits.Add(@($day.ToString('yyyy-MM-dd'), $rp.id, $author, $rnd.Next(1, 6))) }
            }
        }
    }
    return @{ raw = $raw; cats = $cats; iterations = $iterations; repos = $repos; prs = $prDetails; changes = @($changes | Sort-Object { $_.when }); commits = $commits }
}

# --------------------------------------------------------------------------- #
# HTML report template (__DATA__ is replaced with the model JSON)
# --------------------------------------------------------------------------- #
$HtmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ADO Work Map</title>
<script>
// Theme before first paint: a link like report.html#/sprints:dark wins over the saved choice
(function () {
  let t = 'auto';
  try { t = JSON.parse(localStorage.getItem('adomap.theme') || '"auto"'); } catch (e) {}
  const h = location.hash.replace(/^#\/?/, '').split(':')[1];
  if (h === 'dark' || h === 'light') t = h;
  if (t !== 'auto') document.documentElement.dataset.theme = t;
})();
</script>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--text:#1a202c;--muted:#64748b;--line:#e2e8f0;--hover:#f1f5f9;--sel:#e8f0fe;
  --done:#16a34a;--active:#2563eb;--new:#a3aec0;--removed:#cbd5e1;--accent:#0f62fe}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#0f1115;--panel:#171a21;--text:#e5e7eb;--muted:#94a3b8;
  --line:#2a2f3a;--hover:#1f2430;--sel:#1c2a44;--done:#22c55e;--active:#60a5fa;--new:#5b6577;--removed:#374151;--accent:#60a5fa;color-scheme:dark}}
:root[data-theme=dark]{--bg:#0f1115;--panel:#171a21;--text:#e5e7eb;--muted:#94a3b8;
  --line:#2a2f3a;--hover:#1f2430;--sel:#1c2a44;--done:#22c55e;--active:#60a5fa;--new:#5b6577;--removed:#374151;--accent:#60a5fa;color-scheme:dark}
:root[data-theme=light]{color-scheme:light}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,"Segoe UI",sans-serif}
a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
a.wid{font-weight:600;white-space:nowrap;text-decoration:underline;text-decoration-color:color-mix(in srgb,var(--accent) 40%,transparent);text-underline-offset:2px}
a.wid span{font-size:.8em;margin-left:1px;opacity:.7}
header{padding:12px 20px;background:var(--panel);border-bottom:1px solid var(--line);display:flex;gap:12px;align-items:flex-start;justify-content:space-between}
.tml{fill:#fff;font-size:12px;font-weight:600;paint-order:stroke;stroke:rgba(0,0,0,.5);stroke-width:3px;pointer-events:none}
.tml.s{font-size:11px;font-weight:400}
h1{font-size:18px;margin:0} h2{font-size:15px;margin:18px 0 8px} h3{font-size:14px;margin:0 0 8px}
.sub{color:var(--muted);font-size:12px}
nav{display:flex;gap:2px;padding:0 16px;background:var(--panel);overflow-x:auto}
nav button{background:none;border:0;border-bottom:2px solid transparent;padding:10px 14px;color:var(--muted);cursor:pointer;font:inherit;white-space:nowrap}
nav button.on{color:var(--text);border-color:var(--accent)}
.fbar{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 20px;background:var(--panel);border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
.fbar select{max-width:220px}
.pick{position:relative}
.pick summary{list-style:none;cursor:pointer;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:5px 24px 5px 9px;font-size:13px;max-width:220px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pick summary::-webkit-details-marker{display:none}
.pick summary::after{content:"\25BE";position:absolute;right:8px;top:5px;color:var(--muted)}
.pick.on summary{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.pick .menu{position:absolute;top:calc(100% + 4px);left:0;z-index:30;min-width:260px;max-width:440px;max-height:340px;overflow:auto;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:6px;box-shadow:0 6px 20px rgba(0,0,0,.2)}
.pick .menu input[type=search]{width:100%;min-width:0;margin-bottom:6px}
.pick .menu label{display:flex;gap:6px;align-items:center;padding:3px 4px;border-radius:4px;cursor:pointer;white-space:nowrap;font-size:13px}
.pick .menu label:hover{background:var(--hover)}
.pick .menu .def{border-top:1px solid var(--line);margin-top:4px;padding-top:6px}
.fbar .on{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
main{padding:14px 20px}
main>section{display:none} main>section.on{display:block}
.kpis{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
.kpi{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:9px 12px;display:flex;flex-direction:column;gap:4px}
.kpi b{font-size:20px}
.bar{display:flex;height:8px;border-radius:4px;overflow:hidden;background:var(--line);min-width:50px}
.bar i{display:block;height:100%}
.b-done{background:var(--done)}.b-active{background:var(--active)}.b-new{background:var(--new)}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin:8px 0}
.legend span::before{content:"";display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px;background:var(--c)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px}
.badge{font-size:10.5px;font-weight:600;padding:1px 6px;border-radius:3px;color:#fff;background:var(--c);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;justify-self:start;max-width:100%}
.pill{font-size:11px;padding:1px 7px;border-radius:9px;border:1px solid;white-space:nowrap;justify-self:start}
.p-done{color:var(--done)}.p-active{color:var(--active)}.p-new{color:var(--muted)}.p-removed{color:var(--muted);text-decoration:line-through}
.pct{font-size:12px;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.t{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.toolbar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:0 0 10px}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:6px;overflow:hidden}
.seg button{background:var(--panel);color:var(--text);border:0;padding:5px 11px;cursor:pointer;font:inherit;font-size:13px}
.seg button+button{border-left:1px solid var(--line)}
.seg button.on{background:var(--accent);color:#fff}
input[type=search],input[type=date],select{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:5px 9px;font:inherit;font-size:13px}
input[type=search]{min-width:200px}
.btn{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit;font-size:13px}
.btn:hover{background:var(--hover)}
details.fold>summary{cursor:pointer;font-weight:600;margin:14px 0 8px}
/* two-pane delivery map */
.panes{display:grid;grid-template-columns:330px 1fr;gap:12px;align-items:start}
.elist{position:sticky;top:56px;max-height:calc(100vh - 80px);display:flex;flex-direction:column}
.elist .items{overflow:auto;margin-top:6px}
.ep{display:grid;grid-template-columns:1fr auto;gap:2px 8px;width:100%;text-align:left;background:none;border:0;border-radius:6px;padding:6px 8px;color:var(--text);cursor:pointer;font:inherit}
.ep:hover{background:var(--hover)} .ep.on{background:var(--sel)}
.ep .bar{grid-column:1/-1}
.rhead{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px}
/* tree */
.tree details>summary{list-style:none;cursor:pointer}
.tree details>summary::-webkit-details-marker{display:none}
.tree .row{display:grid;grid-template-columns:14px 76px 72px minmax(120px,1fr) auto 120px 92px 52px minmax(60px,130px);gap:8px;align-items:center;padding:3px 6px;border-radius:4px}
.tree.sprint .row{grid-template-columns:14px 76px 72px minmax(120px,1fr) auto 120px 44px 52px 80px minmax(60px,110px)}
.tree .row:hover{background:var(--hover)}
.tree .row::before{content:"";grid-column:1}
.tree details>summary>.row::before{content:"\25B8";color:var(--muted)}
.tree details[open]>summary>.row::before{content:"\25BE"}
.tree .kids{margin-left:18px;border-left:1px dashed var(--line)}
.tree .ctx{opacity:.55}
.who{font-size:12px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.more{margin:8px 6px}
/* tables */
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}
th,td{padding:5px 9px;border-bottom:1px solid var(--line);text-align:left;vertical-align:middle}
th{font-size:12px;color:var(--muted);font-weight:600}
td.n{text-align:right;font-variant-numeric:tabular-nums}
.tablewrap{overflow-x:auto}
tr.click{cursor:pointer} tr.click:hover td{background:var(--hover)} tr.on td{background:var(--sel)}
/* sprints */
.strip{position:sticky;top:56px;z-index:4;background:var(--bg);display:flex;gap:8px;overflow-x:auto;padding:2px 2px 8px}
.sp{flex:0 0 170px;display:flex;flex-direction:column;gap:3px;text-align:left;background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px 10px;color:var(--text);cursor:pointer;font:inherit}
.sp:hover{background:var(--hover)} .sp.on{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.sp.tf-current b::after{content:" \2022 now";color:var(--accent);font-size:11px}
.sp.tf-past{opacity:.85}
.sp-people,.sp-work{margin-top:12px}
@media (min-width:901px){
  #sprints.det.on{display:grid;grid-template-columns:minmax(0,1fr) clamp(340px,32%,560px);column-gap:12px;align-items:start}
  #sprints.det #sbody{display:contents}
  #sprints.det>#strip{grid-area:1/1} #sprints.det>.toolbar{grid-area:2/1} #sprints.det .kpis{grid-area:3/1}
  /* contain:size keeps a long list from stretching the rows beside it; it scrolls instead */
  #sprints.det .sp-people{grid-area:1/2/4/3;align-self:stretch;contain:size;overflow:auto;margin:0}
  #sprints.det .sp-work{grid-area:4/1/5/3}
}
.hmwrap{display:grid;grid-template-columns:minmax(0,max-content) minmax(280px,1fr);gap:12px;align-items:start;margin-top:12px}
.hmwrap #hm{min-width:0;overflow-x:auto}
.hmside{display:flex;flex-direction:column;gap:12px;min-width:0}
@media (max-width:1100px){.hmwrap{grid-template-columns:minmax(0,1fr)}}
.smap{position:relative;overflow:auto;max-height:calc(100vh - 220px)}
#smtip{pointer-events:auto;line-height:1.7;white-space:normal;max-width:460px;max-height:320px;overflow:auto;z-index:4}
#smtip .badge{margin-right:4px}
.smap table{border-radius:0}
.smap th,.smap td{white-space:nowrap;padding:4px 6px}
.smap th:first-child,.smap td:first-child{position:sticky;left:0;background:var(--panel);z-index:1;max-width:320px;overflow:hidden;text-overflow:ellipsis}
.smap thead th{position:sticky;top:0;background:var(--panel);z-index:2;cursor:pointer}
.smap thead th:first-child{z-index:3}
.smap th.cur{color:var(--accent)}
.smap .cell{display:flex;flex-direction:column;gap:2px;min-width:56px;font-size:11px;color:var(--muted)}
.smap tr.ep-row td:first-child{font-weight:600;cursor:pointer}
.smap tr.ft-row td:first-child{padding-left:24px}
#trend svg,#velo svg{width:100%;height:auto;display:block}
#trend text,#velo text,#hm text{fill:var(--muted);font-size:11px}
/* maps narrowed to one sprint */
.scopebar{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;margin:0 0 12px;padding:8px 12px;border:1px solid var(--accent);border-left-width:5px;border-radius:8px;background:color-mix(in srgb,var(--accent) 12%,var(--panel))}
.scopebar b.sn{font-size:16px}
.scopebar .grow{flex:1}
#msprint.on{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
#hm{position:relative}
#hm rect[data-f]{cursor:pointer}
#hmtip.pin{pointer-events:auto;line-height:1.7;padding-right:26px}
#hmtip .x{position:absolute;top:2px;right:4px;background:none;border:0;color:var(--muted);font-size:16px;cursor:pointer;line-height:1}
#hm rect[data-f]:hover{stroke:var(--text);stroke-width:1.5}
#hm text.hl{fill:var(--text);font-size:12px}
#hm text.wk{font-size:10px}
#hm rect.wkend{fill:var(--hover)}
tr[data-who]{cursor:pointer} tr[data-who]:hover td{background:var(--hover)} tr[data-who].on td{background:var(--sel)}
.two{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:var(--text);color:var(--bg);padding:8px 14px;border-radius:8px;font-size:13px;z-index:20;box-shadow:0 4px 14px rgba(0,0,0,.25)}
.toast[hidden]{display:none}
.demo-pill{font-size:11px;font-weight:600;padding:1px 8px;border-radius:9px;background:var(--accent);color:#fff;vertical-align:2px}
/* spider web */
.web{display:grid;grid-template-columns:1fr 280px;gap:12px}
.gwrap{position:relative}
#graph{height:calc(100vh - 250px);min-height:480px;background:var(--panel);border:1px solid var(--line);border-radius:8px}
#g-overlay{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;padding:24px;text-align:center;background:var(--panel);border:1px solid var(--line);border-radius:8px}
#g-busy{position:absolute;top:10px;left:10px;display:flex;gap:8px;align-items:center;background:var(--hover);border:1px solid var(--line);border-radius:6px;padding:4px 8px;font-size:12px}
#g-overlay[hidden],#g-busy[hidden]{display:none}
.gtip{position:absolute;z-index:4;pointer-events:none;max-width:340px;white-space:pre-line;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:6px 9px;font-size:12px;box-shadow:0 4px 14px rgba(0,0,0,.18)}
.gtip[hidden]{display:none}
#graph{position:relative;overflow:hidden}
#side{display:flex;flex-direction:column;gap:12px}
#side label{display:flex;align-items:center;gap:6px;font-size:13px;cursor:pointer}
#side .sw{width:11px;height:11px;border-radius:2px;background:var(--c)}
#side .cnt{margin-left:auto;color:var(--muted);font-size:12px}
#detail pre{white-space:pre-wrap;font:12px/1.4 inherit;margin:6px 0}
@media (max-width:1200px){
  .panes{grid-template-columns:1fr}
  .elist{position:static;max-height:340px}
}
@media (max-width:900px){
  main{padding:12px 16px} .fbar{padding:8px 16px}
  .web,.two{grid-template-columns:1fr}
  .tree .row,.tree.sprint .row{grid-template-columns:14px 64px 66px 1fr auto}
  .tree .row>:nth-child(n+6){display:none}
}
</style>
</head>
<body>
<header>
  <div><h1 id="title">ADO Work Map</h1><div class="sub" id="meta"></div></div>
  <label class="sub">Theme <select id="theme"><option value="auto">Auto</option><option value="light">Light</option><option value="dark">Dark</option></select></label>
</header>
<nav>
  <button class="on" data-tab="map">Delivery map</button>
  <button data-tab="sprints">Sprints</button>
  <button data-tab="changes">Changes</button>
  <button data-tab="maps">Maps</button>
  <button data-tab="web">Spider web</button>
</nav>
<div class="fbar">
  <input type="search" id="f-q" placeholder="Search title, #id, person, tag">
  <details class="pick" id="f-epic"></details>
  <details class="pick" id="f-person"></details>
  <details class="pick" id="f-area"></details>
  <details class="pick" id="f-tag"></details>
  <details class="pick" id="f-notag"></details>
  <button class="btn" id="f-clear">Clear filters</button>
  <span class="sub" id="f-count"></span>
</div>
<main>
<section id="map" class="on">
  <div class="kpis" id="kpis"></div>
  <div class="legend"><span style="--c:var(--done)">Accomplished</span><span style="--c:var(--active)">In progress</span><span style="--c:var(--new)">Not started</span></div>
  <details class="fold" id="trendFold"><summary>Progress over time <select id="trendType" style="margin-left:8px;font-size:12px;padding:2px 6px"></select> <span class="sub">(whole scope, from history.csv)</span></summary>
    <div class="card" id="trend"></div></details>
  <div class="panes">
    <div class="card elist">
      <div class="toolbar" style="margin:0">
        <input type="search" id="eq" placeholder="Find epic" style="min-width:0;flex:1">
        <select id="esort" title="Sort epics">
          <option value="id">Sort: id</option><option value="name">Name</option><option value="low">Least done</option>
          <option value="high">Most done</option><option value="rem">Most remaining</option>
        </select>
      </div>
      <div class="items" id="elist"></div>
    </div>
    <div>
      <div class="rhead" id="rhead"></div>
      <div class="toolbar">
        <div class="seg" id="mode"><button class="on" data-m="all">All</button><button data-m="done">Accomplished</button><button data-m="todo">Yet to do</button><button data-m="sprint">Current sprint</button></div>
        <span class="sub">Collapse to</span>
        <div class="seg" id="mapDepth"><button data-l="0">Epic</button><button data-l="1">Feature</button><button data-l="2">Story</button><button data-l="9">Task</button></div>
      </div>
      <div class="card tree" id="tree"></div>
    </div>
  </div>
</section>

<section id="sprints">
  <div class="strip" id="strip"></div>
  <div class="toolbar">
    <div class="seg" id="sview"><button class="on" data-v="detail">Sprint detail</button><button data-v="velocity">Velocity</button><button data-v="map">Sprint map</button></div>
    <span class="sub" id="sinfo"></span>
  </div>
  <div id="sbody"></div>
</section>

<section id="changes">
  <div class="toolbar">
    <div class="seg" id="crange"><button data-r="latest">Latest pull</button><button data-r="7">7 days</button><button data-r="14">14 days</button><button data-r="30">30 days</button><button data-r="90">90 days</button><button data-r="custom">Custom</button></div>
    <span id="ccustom" hidden><input type="date" id="cfrom"> to <input type="date" id="cto"></span>
    <span class="sub" id="cinfo"></span>
  </div>
  <div class="kpis" id="ckpis"></div>
  <div class="toolbar" style="margin-top:12px">
    <div class="seg" id="cview"><button class="on" data-v="log">Change log</button><button data-v="created">Created</button><button data-v="completed">Completed</button><button data-v="updated">Updated</button></div>
    <select id="ctype" title="Kind of change"></select>
  </div>
  <div id="cbody"></div>
</section>

<section id="maps">
  <div class="toolbar">
    <div class="seg" id="mview"><button data-v="treemap">Treemap</button><button data-v="matrix">Repo matrix</button><button data-v="heatmap">Commit heatmap</button></div>
    <select id="msprint" title="Show one sprint in every map"></select>
    <button class="btn" id="mcur" hidden>Current sprint</button>
    <span class="sub" id="minfo"></span>
  </div>
  <div id="mscope"></div>
  <div id="mbody"></div>
</section>

<section id="web">
  <div class="web">
    <div class="gwrap"><div id="graph"></div><div id="g-overlay" hidden></div><div id="g-busy" hidden></div></div>
    <div id="side">
      <div class="card"><input type="search" id="gq" placeholder="Find #id or text, then Enter" style="min-width:0;width:100%"></div>
      <div class="card">
        <div class="sub" style="margin-bottom:4px">Show</div>
        <select id="g-scope" style="width:100%">
          <option value="sprint">Sprint</option>
          <option value="overview">Overview: epics, features, repos</option>
          <option value="focus">Focus: double-click an item</option>
          <option value="all">Everything (slow on big projects)</option>
        </select>
        <select id="g-sprintsel" style="width:100%;margin-top:6px"></select>
        <div class="sub" id="g-count" style="margin-top:6px"></div>
      </div>
      <div class="card" id="kinds"></div>
      <div class="card">
        <label><input type="checkbox" id="g-hidedone"> Hide accomplished</label>
        <div class="sub" style="margin:2px 0 0 22px">Hides work items that are done, and the links that only lead to them. Commits, branches and PRs linked to work that's still open stay visible: commits have no done state of their own, and they show where open work has already touched the code. Untick <b>Commit</b> above to hide them.</div>
        <div style="margin-top:8px"><button class="btn" id="relayout">Re-layout</button></div>
        <div class="sub" style="margin-top:8px">The filter bar applies here too. Green ring = done. Dashed = related, red arrow = dependency. In the overview, thick grey lines are repo links rolled up from everything under a feature. Double-click a work item to focus on its tree.</div>
      </div>
      <div class="card" id="detail"><span class="sub">Click a node for details.</span></div>
    </div>
  </div>
</section>
</main>
<script>
const D = __DATA__;
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const store = {
  get(k, d) { try { const v = localStorage.getItem('adomap.' + D.project + '.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem('adomap.' + D.project + '.' + k, JSON.stringify(v)); } catch (e) {} }
};
const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
const byId = new Map(D.items.map(i => [i.id, i]));
const C = D.typeColors;
const SPR = D.sprints || [];
const fmtDate = d => d ? new Date(d).toLocaleDateString(undefined, {month: 'short', day: 'numeric', timeZone: 'UTC'}) : '';
const fmtWhen = d => d ? new Date(d).toLocaleString(undefined, {month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'}) : '';
const num = v => Number(v) || 0;

// ---------- derived data ----------
const sprintIndex = new Map(SPR.map((s, i) => [s.path.toLowerCase(), i]));
const curIdx = D.sprint && sprintIndex.has(D.sprint.path.toLowerCase()) ? sprintIndex.get(D.sprint.path.toLowerCase()) : -1;
D.items.forEach(it => {
  let p = (it.iteration || '').toLowerCase(), idx = -1;
  while (p) { if (sprintIndex.has(p)) { idx = sprintIndex.get(p); break; } const k = p.lastIndexOf('\\'); if (k < 0) break; p = p.slice(0, k); }
  it.sp = idx;
  let a = it; it.epic = null;
  while (a) { if (a.type === 'Epic') { it.epic = a.id; break; } a = byId.get(a.parent); }
  let f = it; it.feature = null;
  while (f) { if (f.level === 1) { it.feature = f.id; break; } f = byId.get(f.parent); }
});
const leafMemo = new Map();
const leaves = id => { let r = leafMemo.get(id); if (r) return r; const it = byId.get(id);
  r = it.children.length ? it.children.flatMap(leaves) : [id]; leafMemo.set(id, r); return r; };
const sprintName = it => it.sp >= 0 ? SPR[it.sp].name : '';

// ---------- global filters ----------
// People, tags and excluded tags are lists. The area path can have a saved default; excluded tags survive Clear filters.
let defArea = store.get('defaultArea', '');
const blankF = () => ({q: '', epic: '', person: [], area: defArea, tag: [], notag: []});
const F = Object.assign(blankF(), store.get('filters', {}));
['person', 'tag', 'notag'].forEach(k => { if (!Array.isArray(F[k])) F[k] = F[k] ? [F[k]] : []; });
const KEYS = ['q', 'epic', 'person', 'area', 'tag', 'notag'];
const tagsOf = it => (it.tags || '').split(/;\s*/).filter(Boolean);
function passK(it, k) {   // one filter at a time, so each list in the bar can be narrowed by the others
  switch (k) {
    case 'epic': return !F.epic || (F.epic === 'none' ? it.epic == null : String(it.epic) === F.epic);
    case 'person': return !F.person.length || F.person.includes(it.assignee || '-');
    case 'area': return !F.area || it.area === F.area || it.area.startsWith(F.area + '\\');
    case 'tag': return !F.tag.length || tagsOf(it).some(t => F.tag.includes(t));
    case 'notag': return !F.notag.length || !tagsOf(it).some(t => F.notag.includes(t));
    case 'q': return !F.q || `#${it.id} ${it.title} ${it.assignee} ${it.tags} ${it.state}`.toLowerCase().includes(F.q);
  }
  return true;
}
const passExcept = (it, skip) => KEYS.every(k => k === skip || passK(it, k));
const passNoEpic = it => passExcept(it, 'epic');
const pass = it => passExcept(it, '');
const isOn = k => Array.isArray(F[k]) ? F[k].length > 0 : !!F[k];
const filtersOn = () => KEYS.some(isOn);
const nonEpicFiltersOn = () => KEYS.some(k => k !== 'epic' && isOn(k));
let rollMemo = new Map();
function roll(it) {   // leaf roll-up honouring every filter except the epic one
  let r = rollMemo.get(it.id); if (r) return r;
  r = {done: 0, active: 0, new: 0};
  for (const l of leaves(it.id)) { const x = byId.get(l); if (x.bucket in r && passNoEpic(x)) r[x.bucket]++; }
  r.total = r.done + r.active + r.new;
  r.pct = r.total ? Math.round(100 * r.done / r.total) : (it.bucket === 'done' ? 100 : 0);
  rollMemo.set(it.id, r); return r;
}

const uniq = a => [...new Set(a.filter(Boolean))].sort((x, y) => x.localeCompare(y));
const opt = (v, label, sel) => `<option value="${esc(v)}"${sel ? ' selected' : ''}>${esc(label)}</option>`;
// A dropdown checklist (single or multiple choice) with a search box once it has more than 5 entries
function pick(id, o) {
  const el = $('#' + id), chosen = Array.isArray(F[o.key]) ? F[o.key] : (F[o.key] ? [F[o.key]] : []);
  const items = o.items.slice();
  chosen.forEach(v => { if (!items.some(x => x[0] === v)) items.push([v, v]); });   // keep a choice visible even when nothing matches it now
  const labelOf = v => (items.find(x => x[0] === v) || [v, v])[1];
  const text = !chosen.length ? o.all : chosen.length > 1 ? `${o.label}: ${chosen.length}` : (o.multi ? o.label + ': ' : '') + labelOf(chosen[0]);
  el.className = 'pick' + (chosen.length ? ' on' : '');
  el.P = {o, items, chosen};
  const q = el.querySelector('input[type=search]');
  el.innerHTML = `<summary title="${esc(o.label)}">${esc(text)}</summary><div class="menu">` +
    (items.length > 5 ? `<input type="search" placeholder="Find ${esc(o.label.toLowerCase())}" value="${esc(q ? q.value : '')}">` : '') +
    `<div class="rows"></div>${o.extra || ''}</div>`;
  pickRows(el);
}
function pickRows(el) {
  const {o, items, chosen} = el.P, q = (el.querySelector('input[type=search]') || {value: ''}).value.trim().toLowerCase();
  const rows = (q ? items.filter(x => x[1].toLowerCase().includes(q)) : items);
  const row = (v, l, on) => `<label><input type="${o.multi ? 'checkbox' : 'radio'}" value="${esc(v)}"${on ? ' checked' : ''}> ${esc(l)}</label>`;
  el.querySelector('.rows').innerHTML = (o.multi || q ? '' : row('', o.all, !chosen.length)) +
    rows.slice(0, 300).map(([v, l]) => row(v, l, chosen.includes(v))).join('') +
    (rows.length > 300 ? `<p class="sub" style="margin:4px">${rows.length - 300} more - type to narrow</p>` : '') +
    (!rows.length ? '<p class="sub" style="margin:4px">Nothing matches.</p>' : '');
}
function buildFilterBar() {
  const cand = k => D.items.filter(i => passExcept(i, k));
  const ce = cand('epic'), ids = new Set(ce.map(i => i.epic));
  const epics = D.items.filter(i => i.type === 'Epic' && ids.has(i.id)).sort((a, b) => a.title.localeCompare(b.title));
  pick('f-epic', {key: 'epic', label: 'Epic', all: 'All epics', items: (ids.has(null) ? [['none', 'Not under an epic']] : []).concat(epics.map(e => [String(e.id), `#${e.id} ${e.title.slice(0, 50)}`]))});
  const cp = cand('person');
  pick('f-person', {key: 'person', multi: true, label: 'People', all: 'Anyone', items: (cp.some(i => !i.assignee) ? [['-', 'Unassigned']] : []).concat(uniq(cp.map(i => i.assignee)).map(p => [p, p]))});
  pick('f-area', {key: 'area', label: 'Area path', all: 'All areas', items: uniq(cand('area').map(i => i.area)).map(a => [a, a]),
    extra: F.area ? `<label class="def"><input type="checkbox" id="f-areadef"${defArea === F.area ? ' checked' : ''}> Open with this area path</label>`
      : defArea ? `<p class="sub def">Default: ${esc(defArea)}</p>` : ''});
  pick('f-tag', {key: 'tag', multi: true, label: 'Tags', all: 'Any tag', items: uniq(cand('tag').flatMap(tagsOf)).map(t => [t, t])});
  pick('f-notag', {key: 'notag', multi: true, label: 'Excluded tags', all: 'Exclude tags', items: uniq(D.items.flatMap(tagsOf)).map(t => [t, t])});
  $('#f-q').value = F.q;
}
function syncFilterBar() {
  $('#f-q').classList.toggle('on', !!F.q);
  $('#f-count').textContent = filtersOn() ? `${D.items.filter(pass).length.toLocaleString()} of ${D.items.length.toLocaleString()} items match` : `${D.items.length.toLocaleString()} items`;
}
function setFilter(k, v) { F[k] = v; store.set('filters', F); rollMemo = new Map(); buildFilterBar(); syncFilterBar(); renderAll(); }
$('.fbar').addEventListener('change', e => {
  const p = e.target.closest('.pick'); if (!p || e.target.type === 'search') return;
  if (e.target.id === 'f-areadef') { defArea = e.target.checked ? F.area : ''; store.set('defaultArea', defArea); buildFilterBar(); return; }
  const k = p.id.slice(2), v = e.target.value;
  if (Array.isArray(F[k])) setFilter(k, e.target.checked ? F[k].concat(v) : F[k].filter(x => x !== v));
  else { p.open = false; setFilter(k, v); }
});
$('.fbar').addEventListener('input', e => { if (e.target.type === 'search' && e.target.closest('.pick')) pickRows(e.target.closest('.pick')); });
document.addEventListener('click', e => $$('.pick[open]').forEach(p => { if (!p.contains(e.target)) p.open = false; }));
$('#f-q').oninput = debounce(e => setFilter('q', e.target.value.trim().toLowerCase()), 250);
$('#f-clear').onclick = () => { Object.assign(F, blankF(), {notag: F.notag}); $('#f-q').value = ''; setFilter('q', ''); };

// ---------- shared bits ----------
const bar = r => { const t = (r.done + r.active + r.new) || 1;
  return `<div class="bar" title="${r.done} done, ${r.active} in progress, ${r.new} not started"><i class="b-done" style="width:${r.done/t*100}%"></i><i class="b-active" style="width:${r.active/t*100}%"></i><i class="b-new" style="width:${r.new/t*100}%"></i></div>`; };
const badge = it => `<span class="badge" style="--c:${C[it.kind] || '#888'}" title="${esc(it.type)}">${esc(it.type)}</span>`;
const pill = it => `<span class="pill p-${it.bucket}">${esc(it.state)}</span>`;
const link = it => `<a class="wid" href="${esc(it.url)}" target="_blank" rel="noopener" title="Open #${it.id} in Azure DevOps">#${it.id}<span aria-hidden="true">&#8599;</span></a>`;
const segSet = (sel, attr, val) => $$(sel + ' button').forEach(b => b.classList.toggle('on', b.dataset[attr] === String(val)));

// Collapsible, lazily rendered tree used by the delivery map and the sprint view.
// Only the open branches are in the page, so big projects stay quick.
function makeTree(el, o) {
  const T = {memo: new Map(), shown: 100, openLevel: o.openLevel || 0};
  const keep = id => { if (T.memo.has(id)) return T.memo.get(id); T.memo.set(id, false); const it = byId.get(id);
    const v = !!it && (o.match(it) || it.children.some(keep)); T.memo.set(id, v); return v; };
  const node = id => { const it = byId.get(id); const kids = it.children.filter(keep);
    if (!kids.length) return `<div class="leaf">${o.row(it, o.match(it))}</div>`;
    const open = it.level < T.openLevel;
    return `<details data-id="${id}"${open ? ' open' : ''}><summary>${o.row(it, o.match(it))}</summary><div class="kids">${open ? kids.map(node).join('') : ''}</div></details>`; };
  el.addEventListener('toggle', e => { const d = e.target; if (d.tagName !== 'DETAILS' || !d.open) return;
    const k = d.querySelector(':scope > .kids'); if (k && !k.childElementCount) k.innerHTML = byId.get(+d.dataset.id).children.filter(keep).map(node).join(''); }, true);
  el.addEventListener('click', e => { if (e.target.closest('.more')) { T.shown += 100; T.render(); } });
  T.render = (resetPaging) => {
    T.memo = new Map(); if (resetPaging) T.shown = 100;
    const tops = o.tops().filter(keep);
    // Don't open more than ~3000 rows at once; open fewer levels instead
    const want = T.openLevel; let lvl = want;
    const countTo = L => { let n = 0; const walk = id => { n++; const it = byId.get(id); if (it.level < L && n < 4000) it.children.filter(keep).forEach(walk); }; tops.slice(0, T.shown).forEach(walk); return n; };
    while (lvl > 0 && countTo(lvl) > 3000) lvl--;
    T.openLevel = lvl;
    el.innerHTML = tops.slice(0, T.shown).map(node).join('') +
      (tops.length > T.shown ? `<button class="btn more">Show ${Math.min(100, tops.length - T.shown)} more (${T.shown} of ${tops.length.toLocaleString()} shown)</button>` : '') +
      (!tops.length ? `<p class="sub" style="padding:8px">${o.empty || 'Nothing matches.'}</p>` : '') +
      (lvl < want ? '<p class="sub" style="padding:4px 8px">Too many rows to open every level at once - opened fewer levels. Filter, or expand branches one by one.</p>' : '');
    T.openLevel = want;
  };
  return T;
}

// ---------- header ----------
$('#title').textContent = D.project + ' - Work Map';
$('#meta').innerHTML = `${esc(D.org)} / <a href="${esc(D.projectUrl)}" target="_blank" rel="noopener">${esc(D.project)}</a> &middot; ${D.items.length.toLocaleString()} work items &middot; ${SPR.length} sprints &middot; data pulled ${esc(fmtWhen(D.runUtc) || D.generated)}` +
  (D.sprint ? ` &middot; current sprint: <b>${esc(D.sprint.name)}</b>` : '');
// Demo data: links can't open real work items, so say so instead of going to a dead page
if (D.demo) {
  $('#title').innerHTML = esc(D.project) + ' - Work Map <span class="demo-pill">DEMO DATA</span>';
  $('#meta').insertAdjacentHTML('beforeend', ' &middot; <a href="https://github.com/DasCondor/ado-work-map" target="_blank" rel="noopener">Get the script on GitHub</a>');
  const note = msg => { let t = $('#demoNote'); if (!t) { t = document.createElement('div'); t.id = 'demoNote'; t.className = 'toast'; t.setAttribute('role', 'status'); document.body.appendChild(t); }
    t.textContent = msg; t.hidden = false; clearTimeout(note.h); note.h = setTimeout(() => { t.hidden = true; }, 3500); };
  const msg = 'Demo data - in your own report this opens the item in Azure DevOps.';
  document.addEventListener('click', e => { const a = e.target.closest('a[href^="https://dev.azure.com/demo"]'); if (a) { e.preventDefault(); note(msg); } }, true);
  window.open = () => { note(msg); return null; };
}
// Links can open a tab directly: ado_work_map.html#/sprints (or #/maps:dark)
let activeTab = location.hash.replace(/^#\/?/, '').split(':')[0] || store.get('tab', 'map');
function showTab(t) {
  if (!$('#' + t)) t = 'map';
  activeTab = t; store.set('tab', t);
  try { history.replaceState(null, '', '#/' + t); } catch (e) {}
  $$('nav button').forEach(x => x.classList.toggle('on', x.dataset.tab === t));
  $$('main>section').forEach(s => s.classList.toggle('on', s.id === t));
  if (t === 'web') initGraph();
  if (t === 'maps') renderMaps();
  if (t === 'sprints' && !renderSprints.scrolled) renderSprints();
}
$$('nav button').forEach(b => b.onclick = () => showTab(b.dataset.tab));

// ---------- Delivery map ----------
function renderKpis() {
  const by = new Map();
  D.items.forEach(it => { if (!pass(it)) return; let s = by.get(it.type);
    if (!s) by.set(it.type, s = {type: it.type, level: it.level, done: 0, active: 0, new: 0, removed: 0}); s[it.bucket]++; });
  $('#kpis').innerHTML = [...by.values()].sort((a, b) => a.level - b.level || a.type.localeCompare(b.type)).map(s =>
    `<div class="kpi"><span class="sub">${esc(s.type)}</span><b>${s.done} <span class="sub">/ ${s.done + s.active + s.new} done</span></b>${bar(s)}<span class="sub">${s.active} in progress &middot; ${s.new} not started</span></div>`).join('')
    || '<p class="sub">No items match the filters.</p>';
}

(function trend() {
  const H = D.history || [], sel = $('#trendType');
  const types = [...new Set(H.map(h => h.type))];
  sel.innerHTML = types.map(t => `<option>${esc(t)}</option>`).join('');
  sel.value = types.includes('Task') ? 'Task' : (types.includes('User Story') ? 'User Story' : types[0]);
  sel.onclick = e => e.stopPropagation();
  $('#trendFold').open = store.get('trendOpen', false);
  $('#trendFold').ontoggle = () => store.set('trendOpen', $('#trendFold').open);
  const draw = () => {
    const pts = H.filter(h => h.type === sel.value);
    if (pts.length < 2) { $('#trend').innerHTML = '<p class="sub" style="padding:8px">The trend fills in as the script runs on different days, or right away with -PullHistory.</p>'; return; }
    const css = getComputedStyle(document.documentElement), col = v => css.getPropertyValue(v).trim();
    const W = 900, Hh = 220, L = 40, R = 90, T = 12, B = 26;
    const t0 = Date.parse(pts[0].date), t1 = Date.parse(pts[pts.length - 1].date);
    const max = Math.max(1, ...pts.map(p => p.total));
    const x = d => L + (W - L - R) * (t1 === t0 ? 1 : (Date.parse(d) - t0) / (t1 - t0));
    const y = v => T + (Hh - T - B) * (1 - v / max);
    const line = (f, c, dash) => `<polyline fill="none" stroke="${c}" stroke-width="2" ${dash ? 'stroke-dasharray="5 4"' : ''} points="${pts.map(p => x(p.date) + ',' + y(f(p))).join(' ')}"/>`;
    const last = pts[pts.length - 1];
    const lab = (v, c, txt) => `<text x="${W - R + 6}" y="${y(v) + 4}" style="fill:${c}">${txt} ${v}</text>`;
    const grid = [0, .25, .5, .75, 1].map(f => { const v = Math.round(max * f);
      return `<line x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}" stroke="${col('--line')}"/><text x="${L - 6}" y="${y(v) + 4}" text-anchor="end">${v}</text>`; }).join('');
    const dots = pts.length <= 120 ? pts.map(p => `<circle cx="${x(p.date)}" cy="${y(p.done)}" r="3" fill="${col('--done')}"><title>${p.date}: ${p.done} done / ${p.total}</title></circle>`).join('') : '';
    $('#trend').innerHTML = `<svg viewBox="0 0 ${W} ${Hh}" role="img" aria-label="Burn-up for ${esc(sel.value)}">${grid}
      ${line(p => p.total, col('--muted'))}${line(p => p.done + p.active, col('--active'), true)}${line(p => p.done, col('--done'))}${dots}
      ${lab(last.total, col('--muted'), 'scope')}${lab(last.done, col('--done'), 'done')}
      <text x="${L}" y="${Hh - 6}">${fmtDate(pts[0].date + 'T00:00:00Z')}</text><text x="${W - R}" y="${Hh - 6}" text-anchor="end">${fmtDate(last.date + 'T00:00:00Z')}</text></svg>
      <div class="legend" style="padding:0 6px"><span style="--c:var(--muted)">Scope (total)</span><span style="--c:var(--active)">Done + in progress</span><span style="--c:var(--done)">Done</span></div>`;
  };
  sel.onchange = draw; draw();
})();

let mapMode = 'all';
let epicSort = store.get('epicSort', 'id');
$('#esort').value = epicSort;
const topLevel = D.roots.map(id => byId.get(id));
function renderEpicList() {
  const q = $('#eq').value.trim().toLowerCase();
  let rows = D.items.filter(i => i.type === 'Epic' && i.bucket !== 'removed').map(e => ({e, r: roll(e)}));
  if (nonEpicFiltersOn()) rows = rows.filter(x => x.r.total || passNoEpic(x.e));
  if (q) rows = rows.filter(x => `#${x.e.id} ${x.e.title}`.toLowerCase().includes(q));
  const sorters = {id: (a, b) => a.e.id - b.e.id, name: (a, b) => a.e.title.localeCompare(b.e.title), low: (a, b) => a.r.pct - b.r.pct,
    high: (a, b) => b.r.pct - a.r.pct, rem: (a, b) => (b.r.total - b.r.done) - (a.r.total - a.r.done)};
  rows.sort(sorters[epicSort] || sorters.id);
  const orphan = topLevel.filter(i => i.type !== 'Epic' && (!nonEpicFiltersOn() || roll(i).total || passNoEpic(i)));
  const btn = (val, title, sub, r) => `<button class="ep${F.epic === val ? ' on' : ''}" data-e="${esc(val)}"><span class="t" title="${esc(title)}">${esc(title)}</span><span class="pct">${r ? r.pct + '%' : ''}</span><span class="sub">${sub}</span><span></span>${r ? bar(r) : ''}</button>`;
  $('#elist').innerHTML = btn('', `All epics (${rows.length})`, 'Pick an epic to see its features', null) +
    rows.map(x => btn(String(x.e.id), x.e.title, `#${x.e.id} &middot; ${x.r.done}/${x.r.total} done &middot; ${esc(x.e.state)}`, x.r)).join('') +
    (orphan.length ? btn('none', `Not under an epic (${orphan.length})`, 'Features, stories and tasks with no epic', null) : '');
}
$('#elist').onclick = e => { const b = e.target.closest('.ep'); if (b) setFilter('epic', b.dataset.e); };
$('#eq').oninput = debounce(renderEpicList, 200);
$('#esort').onchange = e => { epicSort = e.target.value; store.set('epicSort', epicSort); renderEpicList(); };

const mapRow = (it, matched) => `<div class="row${matched ? '' : ' ctx'}">${badge(it)}${link(it)}<span class="t" title="${esc(it.title)}">${esc(it.title)}</span>${pill(it)}<span class="who">${esc(it.assignee)}</span><span class="who">${esc(sprintName(it))}</span>` +
  (it.children.length ? (r => `<span class="pct">${r.done}/${r.total}</span>${bar(r)}`)(roll(it)) : '<span></span><span></span>') + '</div>';
function mapMatch(it) {
  if (!pass(it)) return false;
  if (mapMode === 'done') return it.bucket === 'done';
  if (mapMode === 'todo') return it.bucket === 'new' || it.bucket === 'active';
  if (mapMode === 'sprint') return it.inSprint;
  return true;
}
const mapTree = makeTree($('#tree'), {
  match: mapMatch, row: mapRow, openLevel: store.get('mapDepth', 1),
  tops: () => {
    if (F.epic === 'none') return topLevel.filter(i => i.type !== 'Epic').map(i => i.id);
    if (F.epic) { const e = byId.get(+F.epic); return e ? e.children : []; }
    return D.roots;
  },
  empty: 'Nothing matches. Try clearing filters or picking another epic.'
});
segSet('#mapDepth', 'l', mapTree.openLevel);
function renderRight() {
  const e = F.epic && F.epic !== 'none' ? byId.get(+F.epic) : null;
  $('#rhead').innerHTML = e
    ? `${badge(e)} ${link(e)} <b>${esc(e.title)}</b> ${pill(e)} <span class="pct">${roll(e).done}/${roll(e).total} done (${roll(e).pct}%)</span><span style="width:160px">${bar(roll(e))}</span>
       <button class="btn" id="toWeb">Show in spider web</button>`
    : `<b>${F.epic === 'none' ? 'Work not under an epic' : 'All epics'}</b><span class="sub">${F.epic ? '' : 'Pick an epic on the left to narrow the view'}</span>`;
  if (e) $('#toWeb').onclick = () => { showTab('web'); if (window.graphApi) graphApi.focus(e.id); };
  mapTree.render(true);
}
$$('#mode button').forEach(b => b.onclick = () => { mapMode = b.dataset.m; segSet('#mode', 'm', mapMode); mapTree.render(true); });
$$('#mapDepth button').forEach(b => b.onclick = () => { mapTree.openLevel = +b.dataset.l; store.set('mapDepth', mapTree.openLevel); segSet('#mapDepth', 'l', b.dataset.l); mapTree.render(); });

// ---------- Sprints ----------
let selSprint = curIdx >= 0 ? curIdx : SPR.length - 1;
let sprintView = store.get('sprintView', 'detail');
let sprintTree = null;
const smapOpen = new Set();
let smapAll = false;
function sprintStats() {
  const st = SPR.map(() => ({tasks: {done: 0, active: 0, new: 0}, work: {done: 0, active: 0, new: 0}, pts: 0, ptsDone: 0, rem: 0}));
  D.items.forEach(it => { if (it.sp < 0 || it.bucket === 'removed' || !pass(it)) return; const s = st[it.sp];
    if (it.type === 'Task') { s.tasks[it.bucket]++; s.rem += num(it.remaining); }
    else if (it.level >= 2) { s.work[it.bucket]++; s.pts += num(it.points); if (it.bucket === 'done') s.ptsDone += num(it.points); } });
  return st;
}
function renderSprints() {
  if (!SPR.length) { $('#strip').innerHTML = ''; $('#sbody').innerHTML = '<p class="sub">No sprints found. Check -Team (the team must have sprints selected) or -Iteration.</p>'; return; }
  const st = sprintStats();
  $('#strip').innerHTML = SPR.map((s, i) => { const x = st[i], w = x.tasks.done + x.tasks.active + x.tasks.new ? x.tasks : x.work;
    return `<button class="sp tf-${esc(s.timeFrame || 'none')}${i === selSprint ? ' on' : ''}" data-i="${i}"><b class="t">${esc(s.name)}</b><span class="sub">${s.start ? fmtDate(s.start) + ' &ndash; ' + fmtDate(s.finish) : 'no dates'}</span>${bar(w)}<span class="sub">${w.done}/${w.done + w.active + w.new} done${x.pts ? ' &middot; ' + x.ptsDone + '/' + x.pts + ' pts' : ''}</span></button>`; }).join('');
  // Centre the selected sprint in the strip (scroll the strip only, never the page)
  const strip = $('#strip'), on = $('#strip .sp.on');
  if (on && !renderSprints.scrolled && strip.clientWidth) { strip.scrollLeft = on.offsetLeft - strip.offsetLeft - (strip.clientWidth - on.offsetWidth) / 2; renderSprints.scrolled = true; }
  segSet('#sview', 'v', sprintView);
  $('#sprints').classList.toggle('det', sprintView === 'detail');
  if (sprintView === 'velocity') renderVelocity(st);
  else if (sprintView === 'map') renderSprintMap();
  else renderSprintDetail(st);
}
$('#strip').onclick = e => { const b = e.target.closest('.sp'); if (!b) return; selSprint = +b.dataset.i; sprintView = 'detail'; store.set('sprintView', sprintView); renderSprints(); };
$$('#sview button').forEach(b => b.onclick = () => { sprintView = b.dataset.v; store.set('sprintView', sprintView); renderSprints(); });

function renderSprintDetail(st) {
  const s = SPR[selSprint], x = st[selSprint];
  const items = D.items.filter(i => i.sp === selSprint && i.bucket !== 'removed' && pass(i));
  const tasks = items.filter(i => i.type === 'Task'), work = items.filter(i => i.type !== 'Task' && i.level >= 2);
  let days = '';
  if (s.finish) { const d = Math.ceil((Date.parse(s.finish) + 864e5 - Date.now()) / 864e5); days = s.timeFrame === 'future' ? 'not started' : d > 0 ? `${d} days left` : 'ended'; }
  $('#sinfo').innerHTML = `${esc(s.path)}${s.start ? ' &middot; ' + fmtDate(s.start) + ' &ndash; ' + fmtDate(s.finish) : ''}${days ? ' &middot; ' + days : ''}`;
  const people = new Map();
  tasks.forEach(t => { const k = t.assignee || 'Unassigned'; const p = people.get(k) || {done: 0, active: 0, new: 0, rem: 0}; p[t.bucket]++; p.rem += num(t.remaining); people.set(k, p); });
  if (!tasks.length) work.forEach(t => { const k = t.assignee || 'Unassigned'; const p = people.get(k) || {done: 0, active: 0, new: 0, rem: 0}; p[t.bucket]++; people.set(k, p); });
  const prow = [...people.entries()].sort((a, b) => b[1].rem - a[1].rem || (b[1].active + b[1].new) - (a[1].active + a[1].new)).map(([k, p]) => {
    const val = k === 'Unassigned' ? '-' : k;
    return `<tr class="click${F.person.includes(val) ? ' on' : ''}" data-p="${esc(val)}"><td class="t" style="max-width:150px">${esc(k)}</td><td class="n">${p.done}</td><td class="n">${p.active}</td><td class="n">${p.new}</td><td class="n">${p.rem}</td><td style="width:70px">${bar(p)}</td></tr>`; }).join('');
  $('#sbody').innerHTML = `
    <div class="kpis">
      <div class="kpi"><span class="sub">Tasks done</span><b>${x.tasks.done} <span class="sub">/ ${x.tasks.done + x.tasks.active + x.tasks.new}</span></b>${bar(x.tasks)}</div>
      <div class="kpi"><span class="sub">Stories / bugs done</span><b>${x.work.done} <span class="sub">/ ${x.work.done + x.work.active + x.work.new}</span></b>${bar(x.work)}</div>
      <div class="kpi"><span class="sub">Points done</span><b>${x.ptsDone} <span class="sub">/ ${x.pts}</span></b></div>
      <div class="kpi"><span class="sub">Remaining work (h)</span><b>${x.rem}</b></div>
      <div class="kpi"><span class="sub">In progress / not started</span><b>${x.tasks.active + x.work.active} <span class="sub">/ ${x.tasks.new + x.work.new}</span></b></div>
    </div>
    <div class="card sp-people"><h3>By person <span class="sub">(click to filter everything)</span></h3>
      <div class="tablewrap"><table id="ptab"><thead><tr><th>Person</th><th>Done</th><th>Active</th><th>New</th><th>Rem. h</th><th></th></tr></thead><tbody>${prow || '<tr><td colspan="6" class="sub">Nobody in this sprint.</td></tr>'}</tbody></table></div></div>
    <div class="sp-work">
      <div class="toolbar"><b>Work in ${esc(s.name)}</b><span class="sub">Collapse to</span>
        <div class="seg" id="sDepth"><button data-l="0">Epic</button><button data-l="1">Feature</button><button data-l="2">Story</button><button data-l="9">Task</button></div></div>
      <div class="card tree sprint" id="stree"></div>
    </div>`;
  $('#ptab').onclick = e => { const r = e.target.closest('tr.click'); if (r) setFilter('person', F.person.includes(r.dataset.p) ? F.person.filter(p => p !== r.dataset.p) : [r.dataset.p]); };
  // Sprint tree: items in the sprint plus their parents for context, with counts and remaining hours rolled up
  const inSp = new Set(items.map(i => i.id));
  const agg = new Map();
  items.forEach(i => { let a = byId.get(i.parent); while (a) { const g = agg.get(a.id) || {done: 0, active: 0, new: 0, rem: 0}; g[i.bucket]++; if (i.type === 'Task') g.rem += num(i.remaining); agg.set(a.id, g); a = byId.get(a.parent); } });
  const tops = []; const seen = new Set();
  items.forEach(i => { let a = i; while (byId.get(a.parent)) a = byId.get(a.parent); if (!seen.has(a.id)) { seen.add(a.id); tops.push(a.id); } });
  const srow = (it, matched) => { const g = agg.get(it.id);
    return `<div class="row${matched ? '' : ' ctx'}">${badge(it)}${link(it)}<span class="t" title="${esc(it.title)}">${esc(it.title)}</span>${pill(it)}<span class="who">${esc(it.assignee)}</span>` +
      `<span class="pct">${it.points != null && it.level >= 2 ? esc(it.points) + ' pt' : ''}</span>` +
      (g ? `<span class="pct">${g.done}/${g.done + g.active + g.new}</span><span class="pct">${g.rem ? g.rem + ' h left' : ''}</span>${bar(g)}` : `<span></span><span class="pct">${it.type === 'Task' && it.remaining != null ? esc(it.remaining) + ' h left' : ''}</span><span></span>`) + '</div>'; };
  const depth = store.get('sprintDepth', items.length > 400 ? 2 : 9);
  sprintTree = makeTree($('#stree'), {match: it => inSp.has(it.id), row: srow, openLevel: depth, tops: () => tops.sort((a, b) => a - b), empty: 'No work in this sprint matches the filters.'});
  segSet('#sDepth', 'l', depth);
  $$('#sDepth button').forEach(b => b.onclick = () => { sprintTree.openLevel = +b.dataset.l; store.set('sprintDepth', sprintTree.openLevel); segSet('#sDepth', 'l', b.dataset.l); sprintTree.render(); });
  sprintTree.render(true);
}

function renderVelocity(st) {
  $('#sinfo').textContent = 'Done vs planned per sprint (story points, or stories and bugs when points are not used)';
  const usePts = st.some(x => x.pts > 0);
  const vals = SPR.map((s, i) => ({s, i, done: usePts ? st[i].ptsDone : st[i].work.done, all: usePts ? st[i].pts : st[i].work.done + st[i].work.active + st[i].work.new}))
    .filter(v => v.all > 0 || v.s.timeFrame === 'current');
  if (!vals.length) { $('#sbody').innerHTML = '<p class="sub">No stories or bugs in any sprint yet.</p>'; return; }
  const css = getComputedStyle(document.documentElement), col = v => css.getPropertyValue(v).trim();
  const W = Math.max(700, vals.length * 56), H = 280, L = 40, B = 60, T = 14;
  const max = Math.max(1, ...vals.map(v => v.all)), bw = (W - L - 10) / vals.length;
  const y = v => T + (H - T - B) * (1 - v / max);
  const past = vals.filter(v => v.s.timeFrame === 'past');
  const avg = past.length ? Math.round(past.slice(-6).reduce((a, v) => a + v.done, 0) / Math.min(6, past.length)) : 0;
  const bars = vals.map((v, k) => { const x0 = L + k * bw + bw * .15, w = bw * .7;
    return `<g class="click" data-i="${v.i}" style="cursor:pointer"><title>${esc(v.s.name)}: ${v.done} of ${v.all} ${usePts ? 'points' : 'items'} done</title>
      <rect x="${x0}" y="${y(v.all)}" width="${w}" height="${y(0) - y(v.all)}" fill="${col('--line')}"/>
      <rect x="${x0}" y="${y(v.done)}" width="${w}" height="${y(0) - y(v.done)}" fill="${v.i === curIdx ? col('--active') : col('--done')}"/>
      <text x="${x0 + w / 2}" y="${H - B + 14}" text-anchor="end" transform="rotate(-35 ${x0 + w / 2} ${H - B + 14})">${esc(v.s.name.slice(0, 18))}</text></g>`; }).join('');
  const grid = [0, .5, 1].map(f => { const v = Math.round(max * f); return `<line x1="${L}" x2="${W - 10}" y1="${y(v)}" y2="${y(v)}" stroke="${col('--line')}"/><text x="${L - 6}" y="${y(v) + 4}" text-anchor="end">${v}</text>`; }).join('');
  $('#sbody').innerHTML = `<div class="card" id="velo" style="overflow-x:auto"><svg viewBox="0 0 ${W} ${H}" style="width:100%;max-width:${W}px;min-width:${Math.min(W, 900)}px">${grid}${bars}
    ${avg ? `<line x1="${L}" x2="${W - 10}" y1="${y(avg)}" y2="${y(avg)}" stroke="${col('--accent')}" stroke-dasharray="5 4"/><text x="${W - 12}" y="${y(avg) - 4}" text-anchor="end" style="fill:${col('--accent')}">avg of last ${Math.min(6, past.length)}: ${avg}</text>` : ''}</svg>
    <div class="legend" style="padding:0 6px"><span style="--c:var(--done)">Done</span><span style="--c:var(--line)">Planned</span><span style="--c:var(--active)">Current sprint</span></div></div>
    <p class="sub">Click a bar to open that sprint.</p>`;
  $('#velo svg').onclick = e => { const g = e.target.closest('g.click'); if (g) { selSprint = +g.dataset.i; sprintView = 'detail'; renderSprints(); } };
}

function renderSprintMap() {
  // Rows: epics (click to open their features). Columns: sprints. Cells: stories and bugs done / total.
  const c = curIdx >= 0 ? curIdx : SPR.length - 1;
  const lo = smapAll ? 0 : Math.max(0, c - 6), hi = smapAll ? SPR.length - 1 : Math.min(SPR.length - 1, c + 6);
  const cols = []; for (let i = lo; i <= hi; i++) cols.push(i); cols.push(-1);
  $('#sinfo').innerHTML = `Stories and bugs per sprint, done / total &middot; <a href="#" id="smapAll">${smapAll ? 'Show 6 sprints either side of now' : 'Show all ' + SPR.length + ' sprints'}</a> &middot; <a href="#" id="smapOpen">Expand all</a> &middot; <a href="#" id="smapShut">Collapse all</a>`;
  const ea = new Map(), fa = new Map(), feats = new Map();
  D.items.forEach(it => { if (it.level < 2 || it.type === 'Task' || it.bucket === 'removed' || !pass(it)) return;
    const ek = it.epic == null ? 'none' : it.epic, fk = it.feature == null ? 'none:' + ek : it.feature, col = it.sp;
    for (const [m, k] of [[ea, ek], [fa, fk]]) { let r = m.get(k); if (!r) m.set(k, r = new Map()); let x = r.get(col); if (!x) r.set(col, x = {done: 0, active: 0, new: 0, items: []}); x[it.bucket]++; x.items.push(it); }
    if (!feats.has(ek)) feats.set(ek, new Set()); feats.get(ek).add(fk); });
  const cells = new Map();   // "key|sprint" -> the stories in that cell, for the hover list
  const cell = (m, key) => cols.map(i => { const x = m && m.get(i); if (!x) return '<td></td>';
    cells.set(key + '|' + i, x); const n = x.done + x.active + x.new; return `<td><div class="cell" data-k="${esc(key + '|' + i)}">${x.done}/${n}${bar(x)}</div></td>`; }).join('');
  const inWin = m => m && cols.some(i => m.has(i));
  const epicKeys = [...ea.keys()].filter(k => inWin(ea.get(k))).sort((a, b) => (a === 'none') - (b === 'none') || a - b);
  const rows = epicKeys.map(ek => { const e = byId.get(ek), open = smapOpen.has(String(ek));
    const head = `<tr class="ep-row" data-e="${ek}"><td title="${esc(e ? e.title : '')}">${open ? '&#9662;' : '&#9656;'} ${e ? `${link(e)} ${esc(e.title)}` : 'Not under an epic'}</td>${cell(ea.get(ek), 'e' + ek)}</tr>`;
    if (!open) return head;
    return head + [...feats.get(ek)].filter(fk => inWin(fa.get(fk))).sort().map(fk => { const f = byId.get(fk);
      return `<tr class="ft-row"><td title="${esc(f ? f.title : '')}">${f ? `${link(f)} ${esc(f.title)}` : '<span class="sub">No feature</span>'}</td>${cell(fa.get(fk), 'f' + fk)}</tr>`; }).join(''); }).join('');
  $('#sbody').innerHTML = `<div class="card smap"><table><thead><tr><th>Epic / feature</th>${cols.map(i => i < 0 ? '<th>Backlog</th>' :
    `<th data-i="${i}" class="${i === curIdx ? 'cur' : ''}" title="${esc(SPR[i].path)}">${esc(SPR[i].name)}<div class="sub">${fmtDate(SPR[i].start)}</div></th>`).join('')}</tr></thead>
    <tbody>${rows || `<tr><td colspan="${cols.length + 1}" class="sub">Nothing in these sprints matches the filters.</td></tr>`}</tbody></table><div class="gtip" id="smtip" hidden></div></div>
    <p class="sub">Click an epic to open its features; click a sprint heading to open that sprint. Hover a cell to see its stories.</p>`;
  $('#smapAll').onclick = e => { e.preventDefault(); smapAll = !smapAll; renderSprintMap(); };
  $('#smapOpen').onclick = e => { e.preventDefault(); epicKeys.forEach(k => smapOpen.add(String(k))); renderSprintMap(); };
  $('#smapShut').onclick = e => { e.preventDefault(); smapOpen.clear(); renderSprintMap(); };
  const card = $('#sbody .smap');
  card.onclick = e => { if (e.target.closest('a')) return;
    const th = e.target.closest('th[data-i]'); if (th) { selSprint = +th.dataset.i; sprintView = 'detail'; renderSprints(); return; }
    const r = e.target.closest('tr.ep-row'); if (r) { const k = r.dataset.e; smapOpen.has(k) ? smapOpen.delete(k) : smapOpen.add(k); renderSprintMap(); } };
  // Hover list of a cell's stories, with links; it stays while the pointer is on it
  const tip = $('#smtip'); let cur = null;
  card.onmousemove = e => {
    if (e.target.closest('#smtip')) return;
    const c = e.target.closest('.cell[data-k]');
    if (!c) { tip.hidden = true; cur = null; return; }
    if (c === cur) return;
    cur = c; const x = cells.get(c.dataset.k), i = +c.dataset.k.split('|')[1];
    const items = x.items.slice().sort((a, b) => a.id - b.id);
    tip.innerHTML = `<b>${esc(i < 0 ? 'Backlog' : SPR[i].name)}</b> &middot; ${x.done} done, ${x.active} in progress, ${x.new} not started<br>` +
      items.slice(0, 15).map(it => `${badge(it)}${link(it)} ${esc(it.title)} ${pill(it)}`).join('<br>') + (items.length > 15 ? `<br><span class="sub">+${items.length - 15} more</span>` : '');
    tip.hidden = false;
    const box = card.getBoundingClientRect();
    let px = e.clientX - box.left + card.scrollLeft + 14, py = e.clientY - box.top + card.scrollTop + 14;
    if (px + tip.offsetWidth > card.scrollLeft + box.width - 4) px = Math.max(card.scrollLeft + 4, e.clientX - box.left + card.scrollLeft - tip.offsetWidth - 10);
    if (py + tip.offsetHeight > card.scrollTop + card.clientHeight - 4) py = Math.max(card.scrollTop + 4, e.clientY - box.top + card.scrollTop - tip.offsetHeight - 10);
    tip.style.left = px + 'px'; tip.style.top = py + 'px';
  };
  card.onmouseleave = () => { tip.hidden = true; cur = null; };
}

// ---------- Changes ----------
let cRange = store.get('cRange', 'latest'), cView = 'log', cType = '', cShown = 300;
const changes = (D.changes || []).map(c => Object.assign({t: Date.parse(c.when)}, c));
const prevRun = D.prevRunUtc ? Date.parse(D.prevRunUtc) : null;
function rangeBounds() {
  const now = Date.now(), run = Date.parse(D.runUtc) || now;
  if (cRange === 'latest') { const from = prevRun || (changes.length ? Math.max(...changes.filter(c => c.t < run - 6e4).map(c => c.t), run - 864e5) : run - 864e5); return [from, run + 6e4, prevRun ? 'since the previous pull (' + fmtWhen(D.prevRunUtc) + ')' : 'in the latest pull']; }
  if (cRange === 'custom') { const f = $('#cfrom').value, t = $('#cto').value;
    return [f ? Date.parse(f + 'T00:00:00') : 0, t ? Date.parse(t + 'T23:59:59') : now, `${f || 'start'} to ${t || 'today'}`]; }
  return [now - +cRange * 864e5, now + 6e4, `in the last ${cRange} days`];
}
function passChange(c) {
  const it = byId.get(c.id);
  if (it) return pass(it);
  if (KEYS.some(k => k !== 'q' && isOn(k))) return false;   // item left the scope: only text search applies
  return !F.q || `#${c.id} ${c.title}`.toLowerCase().includes(F.q);
}
function renderChanges() {
  segSet('#crange', 'r', cRange); segSet('#cview', 'v', cView);
  $('#ccustom').hidden = cRange !== 'custom';
  const [from, to, label] = rangeBounds();
  const inR = d => { const t = Date.parse(d); return t > from && t <= to; };
  const log = changes.filter(c => c.t > from && c.t <= to && passChange(c));
  const created = D.items.filter(i => i.created && inR(i.created) && pass(i));
  const completed = D.items.filter(i => i.bucket === 'done' && i.closed && inR(i.closed) && pass(i));
  const updated = D.items.filter(i => i.changed && inR(i.changed) && pass(i));
  const cnt = k => log.filter(c => c.change === k).length;
  $('#cinfo').textContent = `Showing changes ${label}`;
  $('#ckpis').innerHTML = [['Created', created.length], ['Completed', completed.length], ['Updated', updated.length], ['State changes', cnt('State')],
    ['Moved sprint', cnt('Sprint')], ['Reassigned', cnt('Assigned')], ['Added to scope', cnt('Added')], ['Left scope', cnt('Left scope')]]
    .map(([k, v]) => `<div class="kpi"><span class="sub">${k}</span><b>${v.toLocaleString()}</b></div>`).join('');
  const kinds = uniq(changes.map(c => c.change));
  $('#ctype').innerHTML = opt('', 'All kinds of change') + kinds.map(k => opt(k, k, k === cType)).join('');
  $('#ctype').hidden = cView !== 'log';
  const more = n => n > cShown ? `<button class="btn more" style="margin-top:8px">Show more (${cShown} of ${n.toLocaleString()} shown)</button>` : '';
  const idCell = c => { const it = byId.get(c.id); return it ? link(it) : `#${c.id}`; };
  let html;
  if (cView === 'log') {
    const rows = log.filter(c => !cType || c.change === cType).sort((a, b) => b.t - a.t);
    html = !changes.length ? '<p class="sub">The change log starts with the next run: each run records what changed since the one before. The Created / Completed / Updated views already work from the work item dates.</p>'
      : `<div class="tablewrap"><table><thead><tr><th>When</th><th>Item</th><th>Type</th><th>Title</th><th>Change</th><th>From</th><th>To</th></tr></thead><tbody>${
      rows.slice(0, cShown).map(c => `<tr><td class="sub" style="white-space:nowrap">${esc(fmtWhen(c.when))}</td><td>${idCell(c)}</td><td>${esc(c.type)}</td><td class="t" style="max-width:360px">${esc(c.title)}</td><td><b>${esc(c.change)}</b></td><td class="sub">${esc(c.from)}</td><td>${esc(c.to)}</td></tr>`).join('')
      || '<tr><td colspan="7" class="sub">No changes recorded in this time frame.</td></tr>'}</tbody></table></div>${more(rows.length)}`;
  } else {
    const list = cView === 'created' ? created : cView === 'completed' ? completed : updated;
    const key = cView === 'created' ? 'created' : cView === 'completed' ? 'closed' : 'changed';
    const rows = list.slice().sort((a, b) => Date.parse(b[key]) - Date.parse(a[key]));
    html = `<div class="tablewrap"><table><thead><tr><th>${cView === 'created' ? 'Created' : cView === 'completed' ? 'Completed' : 'Last changed'}</th><th>Item</th><th>Type</th><th>Title</th><th>State</th><th>Assigned</th><th>Sprint</th></tr></thead><tbody>${
      rows.slice(0, cShown).map(i => `<tr><td class="sub" style="white-space:nowrap">${esc(fmtWhen(i[key]))}</td><td>${link(i)}</td><td>${esc(i.type)}</td><td class="t" style="max-width:360px">${esc(i.title)}</td><td>${pill(i)}</td><td>${esc(i.assignee)}</td><td class="sub">${esc(sprintName(i))}</td></tr>`).join('')
      || '<tr><td colspan="7" class="sub">Nothing in this time frame.</td></tr>'}</tbody></table></div>${more(rows.length)}`;
  }
  $('#cbody').innerHTML = html;
}
$$('#crange button').forEach(b => b.onclick = () => { cRange = b.dataset.r; store.set('cRange', cRange); cShown = 300; renderChanges(); });
$$('#cview button').forEach(b => b.onclick = () => { cView = b.dataset.v; cShown = 300; renderChanges(); });
$('#ctype').onchange = e => { cType = e.target.value; renderChanges(); };
$('#cfrom').onchange = $('#cto').onchange = renderChanges;
$('#cbody').onclick = e => { if (e.target.closest('.more')) { cShown += 300; renderChanges(); } };

// ---------- Maps: treemap and repo matrix (scale to thousands of items) ----------
let mapsView = store.get('mapsView', 'treemap'), tmRoot = null;
function squarify(items, x, y, w, h) {
  // Squarified treemap layout: items [{v}] sorted largest first -> rectangles
  const out = [], total = items.reduce((a, b) => a + b.v, 0);
  if (!total || w <= 0 || h <= 0) return out;
  let rest = items.map(it => Object.assign({a: it.v * w * h / total}, it));
  while (rest.length) {
    const short = Math.min(w, h); let row = [], worst = Infinity;
    while (rest.length) {
      const cand = row.concat([rest[0]]), s = cand.reduce((a, b) => a + b.a, 0);
      const mx = Math.max(...cand.map(c => c.a)), mn = Math.min(...cand.map(c => c.a));
      const wv = Math.max(short * short * mx / (s * s), (s * s) / (short * short * mn));
      if (wv > worst) break;
      worst = wv; row = cand; rest.shift();
    }
    const s = row.reduce((a, b) => a + b.a, 0), thick = s / short; let off = 0;
    row.forEach(r => { const len = r.a / thick;
      out.push(w >= h ? Object.assign(r, {x: x, y: y + off, w: thick, h: len}) : Object.assign(r, {x: x + off, y: y, w: len, h: thick})); off += len; });
    if (w >= h) { x += thick; w -= thick; } else { y += thick; h -= thick; }
  }
  return out;
}
const hexRgb = h => { h = h.replace('#', ''); if (h.length === 3) h = h.split('').map(c => c + c).join(''); const n = parseInt(h, 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; };
// Every map can be narrowed to one sprint: -1 = all sprints (the heatmap then shows the last 52 weeks)
let mapsSprint = store.get('mapsSprint', -1);
if (!(mapsSprint >= -1 && mapsSprint < SPR.length)) mapsSprint = -1;
const spPass = it => mapsSprint < 0 || it.sp === mapsSprint;
let mrollMemo = new Map();
function mroll(it) {   // roll() limited to the chosen sprint
  if (mapsSprint < 0) return roll(it);
  let r = mrollMemo.get(it.id); if (r) return r;
  r = {done: 0, active: 0, new: 0};
  for (const l of leaves(it.id)) { const x = byId.get(l); if (x.bucket in r && passNoEpic(x) && spPass(x)) r[x.bucket]++; }
  r.total = r.done + r.active + r.new;
  r.pct = r.total ? Math.round(100 * r.done / r.total) : 0;
  mrollMemo.set(it.id, r); return r;
}
function setMapsSprint(i) { mapsSprint = i; store.set('mapsSprint', i); renderMaps(); }
function renderMapScope() {
  const sel = $('#msprint');
  sel.innerHTML = opt('-1', 'All sprints') + SPR.map((s, i) => opt(i, `${s.name}${i === curIdx ? ' (current)' : ''}${s.start ? ' - ' + fmtDate(s.start) : ''}`)).join('');
  sel.value = String(mapsSprint);
  sel.hidden = !SPR.length;
  sel.classList.toggle('on', mapsSprint >= 0);
  $('#mcur').hidden = curIdx < 0 || mapsSprint === curIdx;
  const s = SPR[mapsSprint];
  if (!s) { $('#mscope').innerHTML = ''; return; }
  const n = D.items.filter(it => it.sp === mapsSprint && pass(it)).length;
  const when = s.start ? `${fmtDate(s.start)} &ndash; ${fmtDate(s.finish)}` : 'no dates set';
  const tf = mapsSprint === curIdx ? '<b>current sprint</b>' : s.timeFrame === 'past' ? 'finished' : s.timeFrame === 'future' ? 'upcoming' : '';
  $('#mscope').innerHTML = `<div class="scopebar"><span class="sub">Every map shows one sprint:</span><b class="sn">${esc(s.name)}</b>
    <span>${when}${tf ? ' &middot; ' + tf : ''} &middot; ${n.toLocaleString()} work item${n === 1 ? '' : 's'}</span><span class="grow"></span>
    <button class="btn" data-step="-1"${mapsSprint === 0 ? ' disabled' : ''}>&lsaquo; Previous</button>
    <button class="btn" data-step="1"${mapsSprint === SPR.length - 1 ? ' disabled' : ''}>Next &rsaquo;</button>
    <button class="btn" data-step="all">Show all sprints</button></div>`;
}
$('#msprint').onchange = e => setMapsSprint(+e.target.value);
$('#mcur').onclick = () => setMapsSprint(curIdx);
$('#mscope').onclick = e => { const b = e.target.closest('button[data-step]'); if (!b) return;
  setMapsSprint(b.dataset.step === 'all' ? -1 : Math.max(0, Math.min(SPR.length - 1, mapsSprint + +b.dataset.step))); };
function renderMaps() {
  segSet('#mview', 'v', mapsView);
  mrollMemo = new Map();
  renderMapScope();
  if (mapsView === 'matrix') renderRepoMatrix(); else if (mapsView === 'heatmap') renderHeatmap(); else renderTreemap();
}
$$('#mview button').forEach(b => b.onclick = () => { mapsView = b.dataset.v; store.set('mapsView', mapsView); renderMaps(); });

function renderTreemap() {
  const css = getComputedStyle(document.documentElement), col = v => css.getPropertyValue(v).trim();
  const c0 = hexRgb(col('--new')), c1 = hexRgb(col('--done'));
  const shade = p => `rgb(${c0.map((v, i) => Math.round(v + (c1[i] - v) * p / 100)).join(',')})`;
  if (tmRoot != null && !byId.has(tmRoot)) tmRoot = null;
  let ids;
  if (tmRoot != null) ids = byId.get(tmRoot).children;
  else if (F.epic === 'none') ids = topLevel.filter(i => i.type !== 'Epic').map(i => i.id);
  else if (F.epic) ids = byId.has(+F.epic) ? byId.get(+F.epic).children : [];
  else ids = D.roots;
  let tiles = ids.map(id => byId.get(id)).filter(it => it && it.bucket !== 'removed').map(it => {
    const r = mroll(it); return {it, r, v: it.children.length ? r.total : (passNoEpic(it) && spPass(it) ? 1 : 0)}; }).filter(t => t.v > 0).sort((a, b) => b.v - a.v);  const hidden = Math.max(0, tiles.length - 400); tiles = tiles.slice(0, 400);
  const trail = []; for (let a = tmRoot != null ? byId.get(tmRoot) : null; a; a = byId.get(a.parent)) trail.unshift(a);
  const rootLabel = F.epic === 'none' ? 'Not under an epic' : F.epic ? 'Selected epic' : 'All epics';
  $('#minfo').innerHTML = `<a href="#" data-up="">${rootLabel}</a>` + trail.map(a => ` &rsaquo; <a href="#" data-up="${a.id}">#${a.id} ${esc(a.title.slice(0, 40))}</a>`).join('') +
    ` &middot; size = work items under each tile, colour = % done${hidden ? ` &middot; ${hidden} smallest tiles not drawn` : ''}`;
  const el = $('#mbody'), W = Math.max(600, el.clientWidth || 1000), H = Math.max(420, Math.min(720, window.innerHeight - 300));
  const tileOf = it => { const r = mroll(it); return {it, r, v: it.children.length ? r.total : (passNoEpic(it) && spPass(it) ? 1 : 0)}; };
  const tip = t => `<title>${esc(t.it.type)} #${t.it.id} ${esc(t.it.title)}\n${t.r.done}/${t.r.total} done (${t.r.pct}%)${t.it.assignee ? '\n' + esc(t.it.assignee) : ''}${t.it.children.length ? '\nClick to zoom in' : '\nDouble-click to open in Azure DevOps'}</title>`;
  // Two levels: big tiles show their children inside, under a header strip
  const draw = (t, depth) => {
    const it = t.it, big = t.w > 70 && t.h > 30, tall = t.h > 46;
    const kids = depth === 0 && it.children.length && t.w > 150 && t.h > 100
      ? it.children.map(id => byId.get(id)).filter(k => k && k.bucket !== 'removed').map(tileOf).filter(k => k.v > 0).sort((a, b) => b.v - a.v).slice(0, 150) : [];
    const box = `<rect x="${t.x + 1}" y="${t.y + 1}" width="${Math.max(0, t.w - 2)}" height="${Math.max(0, t.h - 2)}" rx="3" fill="${shade(t.r.pct)}" stroke="${C[it.kind] || '#888'}" stroke-width="${depth ? 1 : 2}"/>`;
    if (kids.length) {
      const inner = squarify(kids, t.x + 4, t.y + 24, t.w - 8, t.h - 28);
      return `<g data-id="${it.id}" style="cursor:zoom-in">${tip(t)}${box}<text x="${t.x + 8}" y="${t.y + 17}" class="tml">${esc(it.title.slice(0, Math.floor(t.w / 7.5)))} &middot; ${t.r.pct}%</text></g>` + inner.map(k => draw(k, 1)).join('');
    }
    return `<g data-id="${it.id}" style="cursor:${it.children.length ? 'zoom-in' : 'pointer'}">${tip(t)}${box}
      ${big ? `<text x="${t.x + 7}" y="${t.y + 18}" class="tml${depth ? ' s' : ''}">${esc(it.title.slice(0, Math.floor(t.w / 7)))}</text>` : ''}
      ${big && tall ? `<text x="${t.x + 7}" y="${t.y + 34}" class="tml s">#${it.id} &middot; ${t.r.pct}% &middot; ${t.r.total} items</text>` : ''}</g>`;
  };
  const rects = squarify(tiles, 0, 0, W, H);
  el.innerHTML = rects.length ? `<div class="card" style="padding:0;overflow:hidden"><svg id="tm" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" style="display:block;max-width:100%;height:auto">${rects.map(t => draw(t, 0)).join('')}</svg></div>
    <div class="legend"><span style="--c:${shade(0)}">0% done</span><span style="--c:${shade(50)}">50%</span><span style="--c:${shade(100)}">100% done</span><span class="sub">Tile border = work item type. Click to zoom in, double-click to open in Azure DevOps.</span></div>`
    : `<p class="sub">Nothing to draw - this level has no work items that match the filters${mapsSprint >= 0 ? ' in this sprint' : ''}.</p>`;
}
$('#minfo').onclick = e => { const a = e.target.closest('a[data-up]'); if (!a) return; e.preventDefault(); tmRoot = a.dataset.up ? +a.dataset.up : null; renderMaps(); };
$('#mbody').onclick = e => { const g = e.target.closest('#tm g[data-id]');
  if (!g) { const td = e.target.closest('td[data-f]'); if (td && td.dataset.f) { showTab('web'); if (window.graphApi) graphApi.focus(+td.dataset.f); } return; }
  const it = byId.get(+g.dataset.id); if (it && it.children.length) { tmRoot = it.id; renderMaps(); } };
$('#mbody').ondblclick = e => { const g = e.target.closest('#tm g[data-id]'); if (g) { const it = byId.get(+g.dataset.id); if (it) window.open(it.url, '_blank', 'noopener'); } };

function renderRepoMatrix() {
  // Rows: epics (or the selected epic's features). Columns: repos. Cell: work items linked to that repo
  // through PRs, commits or branches.
  const byEpic = F.epic && F.epic !== 'none';
  const rowOf = it => byEpic ? it.feature : it.epic;
  const repoName = new Map(D.graph.nodes.filter(n => n.kind === 'Repo').map(n => [n.id, n.label]));
  const m = new Map(), colTot = new Map(), rowTot = new Map();
  D.graph.edges.forEach(e => { if (e.kind !== 'wi-repo') return; const it = byId.get(+e.from.slice(1)); if (!it || !pass(it) || !spPass(it)) return;
    const k = rowOf(it) == null ? 'none' : rowOf(it); let r = m.get(k); if (!r) m.set(k, r = new Map());
    r.set(e.to, (r.get(e.to) || 0) + 1); colTot.set(e.to, (colTot.get(e.to) || 0) + 1); rowTot.set(k, (rowTot.get(k) || 0) + 1); });
  const cols = [...colTot.keys()].sort((a, b) => colTot.get(b) - colTot.get(a));
  const shownCols = cols.slice(0, 60);
  const rows = [...m.keys()].sort((a, b) => rowTot.get(b) - rowTot.get(a));
  const max = Math.max(1, ...[...m.values()].flatMap(r => [...r.values()]));
  $('#minfo').innerHTML = `${byEpic ? 'Features of the selected epic' : 'Epics'} &times; repos &middot; number = work items linked to the repo by PRs, commits or branches` +
    (cols.length > 60 ? ` &middot; busiest 60 of ${cols.length} repos shown` : '');
  if (!rows.length) { $('#mbody').innerHTML = `<p class="sub">No work items in view${mapsSprint >= 0 ? ' in this sprint' : ''} are linked to code (PRs, commits or branches).</p>`; return; }
  const label = k => { const it = byId.get(k); return it ? `${link(it)} ${esc(it.title)}` : `<span class="sub">${byEpic ? 'No feature' : 'Not under an epic'}</span>`; };
  $('#mbody').innerHTML = `<div class="card smap"><table><thead><tr><th>${byEpic ? 'Feature' : 'Epic'}</th><th>Total</th>${shownCols.map(c => `<th title="${esc(repoName.get(c) || c)}">${esc((repoName.get(c) || c).slice(0, 22))}</th>`).join('')}</tr></thead><tbody>${
    rows.map(k => { const r = m.get(k);
      return `<tr><td title="${esc((byId.get(k) || {}).title || '')}">${label(k)}</td><td class="n"><b>${rowTot.get(k)}</b></td>${shownCols.map(c => { const v = r.get(c);
        return v ? `<td class="n" data-f="${byId.has(k) ? k : ''}" title="${v} work item${v > 1 ? 's' : ''} to ${esc(repoName.get(c) || c)}${byId.has(k) ? ' (click for spider web)' : ''}" style="background:color-mix(in srgb, var(--accent) ${Math.round(12 + 70 * v / max)}%, transparent);cursor:${byId.has(k) ? 'pointer' : 'default'}">${v}</td>` : '<td></td>'; }).join('')}</tr>`; }).join('')}</tbody></table></div>
    <p class="sub">Click a cell to open that ${byEpic ? 'feature' : 'epic'} in the spider web. Pick an epic in the filter bar to break it down by feature.</p>`;
}

// Commit heatmap: commits per day by repo and person (counts only, no code). Covers the last 52 weeks,
// or the days of the sprint picked for the maps. Everyone in one grid, or one row per person.
let hmRepo = '', hmAuthor = store.get('hmAuthor', ''), hmView = store.get('hmView', 'everyone');

// One person often commits under more than one name or email, e.g. "First Last" and First.Last.CTR.
// Names and the part of the email before the @ are normalised (case, dots, contractor markers,
// "Last, First") and any that match are joined into one person, shown under their most-used full name.
function authorIndex(weight) {
  const MARK = /\b(ctr|contractor|cntr|ext|external|vendor)\b/g;
  const norm = s => String(s).toLowerCase().replace(/[._\-+()\[\]]+/g, ' ').replace(MARK, ' ').replace(/\s+/g, ' ').trim();
  const parse = raw => { const m = /^(.*?)\s*<([^<>]*)>\s*$/.exec(raw); return m ? [m[1].trim(), m[2].trim()] : [raw.trim(), ''];
  };
  const nameKey = n => { n = n.replace(/@.*$/, ''); const c = /^([^,]+),\s*(.+)$/.exec(n); return norm(c ? c[2] + ' ' + c[1] : n); };
  const mailKey = e => e ? norm(e.split('@')[0]) : '';
  const title = s => s.replace(/\b\w/g, c => c.toUpperCase());
  const up = new Map();
  const find = k => { while (up.get(k) !== k) k = up.get(k); return k; };
  const join = (a, b) => { if (!up.has(a)) up.set(a, a); if (!up.has(b)) up.set(b, b); const x = find(a), y = find(b); if (x !== y) up.set(x, y); };
  const info = [...weight.keys()].map(raw => {
    const [n, e] = parse(raw), keys = [nameKey(n), mailKey(e)].filter(Boolean);
    if (!keys.length) keys.push(raw);
    keys.forEach(k => join(keys[0], k));
    // Display: a real "First Last" name as typed (contractor marker dropped), else built from the key
    const shown = /\s/.test(n.trim()) && !/@/.test(n) ? n.replace(/[\s,]*\(?\b(ctr|contractor|cntr)\b\)?\.?/gi, '').trim() : '';
    return {raw, keys, shown};
  });
  const best = new Map();
  info.forEach(x => { if (!x.shown) return; const g = find(x.keys[0]), w = weight.get(x.raw) || 0;
    if (!best.has(g) || w > best.get(g).w) best.set(g, {name: x.shown, w}); });
  const out = new Map();
  info.forEach(x => { const g = find(x.keys[0]); out.set(x.raw, best.has(g) ? best.get(g).name : title(g)); });
  return out;
}

function renderHeatmap() {
  const CM = D.commits || {rows: []}, rows = CM.rows || [];
  const repoName = new Map(D.graph.nodes.filter(n => n.kind === 'Repo').map(n => [n.id.slice(1), n.label]));
  const rname = id => repoName.get(id) || ('repo ' + String(id).slice(0, 8));
  if (!rows.length) {
    $('#minfo').textContent = '';
    $('#mbody').innerHTML = `<p class="sub">No commit data yet. Each pull reads commit dates and authors (never code) for the last ${CM.days || 365} days; set -CommitDays 0 to turn this off.</p>`;
    return;
  }
  const weight = new Map();
  rows.forEach(r => weight.set(r[2], (weight.get(r[2]) || 0) + Number(r[3])));
  const who = authorIndex(weight);
  const people = uniq([...who.values()]);
  const repos = uniq(rows.map(r => r[1])).sort((a, b) => rname(a).localeCompare(rname(b)));
  if (hmRepo && !repos.includes(hmRepo)) hmRepo = '';
  if (hmAuthor && !people.includes(hmAuthor)) hmAuthor = '';

  // Range: the picked sprint's days, or the last 52 weeks ending this week
  const day = 864e5, today = new Date(); today.setUTCHours(0, 0, 0, 0);
  const iso = d => d.toISOString().slice(0, 10), at = k => new Date(k + 'T00:00:00Z');
  const sp = SPR[mapsSprint], spDays = !!(sp && sp.start && sp.finish);
  const from = spDays ? at(String(sp.start).slice(0, 10)) : new Date(today.getTime() - (52 * 7 + today.getUTCDay()) * day);
  const to = spDays ? at(String(sp.finish).slice(0, 10)) : today;
  const fromK = iso(from), toK = iso(to);
  const sel = rows.filter(r => r[0] >= fromK && r[0] <= toK && (!hmRepo || r[1] === hmRepo) && (!hmAuthor || who.get(r[2]) === hmAuthor));

  const byDay = new Map(), byRepo = new Map(), byWho = new Map(), byWhoDay = new Map();
  sel.forEach(([d, r, a, n]) => { n = Number(n); const p = who.get(a);
    byDay.set(d, (byDay.get(d) || 0) + n); byRepo.set(r, (byRepo.get(r) || 0) + n); byWho.set(p, (byWho.get(p) || 0) + n);
    byWhoDay.set(p + '|' + d, (byWhoDay.get(p + '|' + d) || 0) + n); });
  let total = 0, active = 0, best = ['', 0];
  byDay.forEach((n, d) => { total += n; active++; if (n > best[1]) best = [d, n]; });

  const fill = l => l ? `color-mix(in srgb, var(--done) ${[0, 30, 55, 78, 100][l]}%, var(--panel))` : 'var(--line)';
  const levelOf = max => n => !n ? 0 : n <= max * .25 ? 1 : n <= max * .5 ? 2 : n <= max * .75 ? 3 : 4;
  const fmtLong = k => at(k).toLocaleDateString(undefined, {weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC'});
  const cell = (x, y, s, n, lvl, f, t, p, extra) =>
    `<rect x="${x}" y="${y}" width="${s}" height="${s}" rx="${s > 16 ? 4 : 2}" style="fill:${fill(lvl)}" data-f="${f}" data-t="${t}" data-p="${esc(p || '')}"${extra || ''}></rect>`;
  const byPerson = hmView === 'person';
  const shownPeople = byPerson ? [...byWho.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0]).slice(0, spDays ? 40 : 15) : [];
  const nameCol = byPerson ? 150 : 0, short = s => s.length > 22 ? s.slice(0, 21) + '\u2026' : s;
  let svg = '', W = 0, H = 0;

  if (spDays) {
    // Sprint: one big cell per day, weekends shaded; one row for everyone, or one per person
    const n = Math.round((to - from) / day) + 1, cs = 26, gap = 4, L = byPerson ? nameCol : 70, T = 36;
    const lines = byPerson ? shownPeople : [''];
    const max = Math.max(1, ...(byPerson ? lines.flatMap(p => [...Array(n)].map((_, i) => byWhoDay.get(p + '|' + iso(new Date(from.getTime() + i * day))) || 0)) : [...byDay.values()]));
    const lvl = levelOf(max);
    W = L + n * (cs + gap); H = T + Math.max(1, lines.length) * (cs + gap);
    for (let i = 0; i < n; i++) {
      const dt = new Date(from.getTime() + i * day), k = iso(dt), x = L + i * (cs + gap), wkend = dt.getUTCDay() === 0 || dt.getUTCDay() === 6;
      if (wkend) svg += `<rect class="wkend" x="${x - 2}" y="${T - 34}" width="${cs + 4}" height="${H - T + 34}" rx="4"></rect>`;
      svg += `<text class="wk" x="${x + cs / 2}" y="${T - 22}" text-anchor="middle">${dt.toLocaleDateString(undefined, {weekday: 'narrow', timeZone: 'UTC'})}</text>` +
             `<text x="${x + cs / 2}" y="${T - 8}" text-anchor="middle"${k === iso(today) ? ' class="hl"' : ''}>${dt.getUTCDate()}</text>`;
      lines.forEach((p, r) => {
        const v = p ? byWhoDay.get(p + '|' + k) || 0 : byDay.get(k) || 0, future = dt > today;
        svg += cell(x, T + r * (cs + gap), cs, v, lvl(v), k, k, p, future ? ' stroke="var(--muted)" stroke-dasharray="3 3" fill-opacity=".4"' : '');
      });
    }
    lines.forEach((p, r) => { svg += `<text class="hl" x="0" y="${T + r * (cs + gap) + cs / 2 + 4}">${esc(p ? short(p) : 'Everyone')}</text>`; });
  }
  else if (byPerson) {
    // Last 52 weeks, one day-by-day calendar per person (same scale for everyone, so they compare)
    const cs = 11, gap = 3, L = 30, weeks = 53, block = 7 * (cs + gap) + 40;
    const lvl = levelOf(Math.max(1, ...byWhoDay.values()));
    W = L + weeks * (cs + gap); H = Math.max(1, shownPeople.length) * block;
    shownPeople.forEach((p, r) => {
      const T = r * block + 38;
      svg += `<text class="hl" x="0" y="${T - 22}">${esc(p)} &middot; ${(byWho.get(p) || 0).toLocaleString()} commits</text>`;
      for (let w = 0; w < weeks; w++) for (let k = 0; k < 7; k++) {
        const dt = new Date(from.getTime() + (w * 7 + k) * day); if (dt > today) continue;
        const key = iso(dt), n = byWhoDay.get(p + '|' + key) || 0;
        if (k === 0 && dt.getUTCDate() <= 7) svg += `<text class="wk" x="${L + w * (cs + gap)}" y="${T - 5}">${dt.toLocaleDateString(undefined, {month: 'short', timeZone: 'UTC'})}</text>`;
        svg += cell(L + w * (cs + gap), T + k * (cs + gap), cs, n, lvl(n), key, key, p);
      }
      svg += [[1, 'Mon'], [3, 'Wed'], [5, 'Fri']].map(([k, t]) => `<text class="wk" x="0" y="${T + k * (cs + gap) + 9}">${t}</text>`).join('');
    });
  }
  else {
    // Last 52 weeks for everyone: 53 week columns ending this week, Sunday at the top
    const cs = 13, gap = 3, L = 30, T = 20, weeks = 53, lvl = levelOf(Math.max(1, ...byDay.values()));
    W = L + weeks * (cs + gap); H = T + 7 * (cs + gap);
    let lastMonth = -1;
    for (let w = 0; w < weeks; w++) for (let k = 0; k < 7; k++) {
      const dt = new Date(from.getTime() + (w * 7 + k) * day); if (dt > today) continue;
      const key = iso(dt), n = byDay.get(key) || 0;
      if (k === 0 && dt.getUTCMonth() !== lastMonth) { lastMonth = dt.getUTCMonth();
        svg += `<text x="${L + w * (cs + gap)}" y="12">${dt.toLocaleDateString(undefined, {month: 'short', timeZone: 'UTC'})}</text>`; }
      svg += cell(L + w * (cs + gap), T + k * (cs + gap), cs, n, lvl(n), key, key, '');
    }
    svg += [[1, 'Mon'], [3, 'Wed'], [5, 'Fri']].map(([k, t]) => `<text x="0" y="${T + k * (cs + gap) + 10}">${t}</text>`).join('');
  }

  const legend = [0, 1, 2, 3, 4].map(l => `<span style="display:inline-block;width:11px;height:11px;border-radius:2px;background:${fill(l)};vertical-align:-1px"></span>`).join(' ');
  const top = (m, label, attr) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10).map(([k, v]) =>
    `<tr${attr ? ` data-who="${esc(k)}"${k === hmAuthor ? ' class="on"' : ''} title="Show only ${esc(k)}"` : ''}><td class="t" style="max-width:240px">${esc(label(k))}</td><td class="n">${v.toLocaleString()}</td><td style="width:40%"><div class="bar"><i class="b-done" style="width:${100 * v / Math.max(...m.values())}%"></i></div></td></tr>`).join('');
  const range = spDays ? `${fmtDate(sp.start)} &ndash; ${fmtDate(sp.finish)}` : 'last 52 weeks';
  const older = spDays && fromK < iso(new Date(today.getTime() - (CM.days || 365) * day));
  $('#minfo').innerHTML = `Commits per day, ${range}${byPerson ? ', by person' : ''} &middot; counts only (dates and authors), no code` +
    (sp && !spDays ? ` &middot; ${esc(sp.name)} has no dates, so the last 52 weeks are shown` : '') +
    (older ? ` &middot; commit data only goes back ${CM.days || 365} days` : '');
  $('#mbody').innerHTML = `
    <div class="toolbar">
      <div class="seg" id="hmView"><button data-v="everyone">Everyone</button><button data-v="person">By person</button></div>
      <select id="hmRepo">${opt('', 'All repos (' + repos.length + ')')}${repos.map(r => opt(r, rname(r), r === hmRepo)).join('')}</select>
      <select id="hmAuthor"${hmAuthor ? ' class="on"' : ''}>${opt('', 'Everyone (' + people.length + ' people)')}${people.map(a => opt(a, a, a === hmAuthor)).join('')}</select>
      ${byPerson && byWho.size > shownPeople.length ? `<span class="sub">${shownPeople.length} busiest of ${byWho.size} people shown</span>` : ''}
    </div>
    <div class="kpis">
      <div class="kpi"><span class="sub">Commits</span><b>${total.toLocaleString()}</b></div>
      <div class="kpi"><span class="sub">Active days</span><b>${active}</b></div>
      <div class="kpi"><span class="sub">Busiest day</span><b>${best[1] || 0}</b><span class="sub">${best[0] ? fmtLong(best[0]) : ''}</span></div>
      <div class="kpi"><span class="sub">Per active day</span><b>${active ? (total / active).toFixed(1) : 0}</b></div>
      <div class="kpi"><span class="sub">People</span><b>${byWho.size}</b></div>
    </div>
    <div class="hmwrap">
    <div class="card" id="hm">${(byPerson && !shownPeople.length) ? '<p class="sub">No commits in this range.</p>' :
      `<svg viewBox="0 0 ${W} ${H}" style="width:${spDays ? W * 1.6 : W * 1.25}px;max-width:100%;min-width:${Math.min(W, 1400)}px">${svg}</svg>`}
      <div class="legend" style="justify-content:flex-end;padding:0 6px">Less ${legend} More &middot; hover a square for details</div>
      <div class="gtip" id="hmtip" hidden></div></div>
    <div class="hmside">
      <div class="card"><h3>Top repos</h3><table><tbody>${top(byRepo, rname)}</tbody></table></div>
      <div class="card"><h3>Top people</h3><table><tbody>${top(byWho, a => a, true)}</tbody></table><div class="sub" style="margin-top:6px">Click a person to show only them. Names and email accounts that belong to one person (e.g. First.Last.CTR) are counted together.</div></div>
    </div></div>`;
  segSet('#hmView', 'v', hmView);
  $$('#hmView button').forEach(b => b.onclick = () => { hmView = b.dataset.v; store.set('hmView', hmView); renderHeatmap(); });
  $('#hmRepo').onchange = e => { hmRepo = e.target.value; renderHeatmap(); };
  $('#hmAuthor').onchange = e => { hmAuthor = e.target.value; store.set('hmAuthor', hmAuthor); renderHeatmap(); };
  $$('#mbody tr[data-who]').forEach(tr => tr.onclick = () => { hmAuthor = hmAuthor === tr.dataset.who ? '' : tr.dataset.who; store.set('hmAuthor', hmAuthor); renderHeatmap(); });

  // Hover a square: the day, its commits, and who and which repos they came from.
  // Click it to pin the details, with links to those commits in Azure DevOps (the repo's Commits
  // page filtered to that day, and to the person for a person's square).
  const hm = $('#hm'), tip = $('#hmtip');
  const repoUrl = new Map(D.graph.nodes.filter(n => n.kind === 'Repo').map(n => [n.id.slice(1), n.url]));
  const plainName = raw => raw.replace(/\s*<[^<>]*>\s*$/, '');
  const commitsLink = (repo, f, t, rs) => {
    const u = repoUrl.get(repo); if (!u) return '';
    const q = [`fromDate=${f}`, `toDate=${t}`];
    if (rs) {   // the name this person used most in that repo that day
      const names = new Map(); rs.forEach(x => { if (x[1] === repo) names.set(x[2], (names.get(x[2]) || 0) + Number(x[3])); });
      const top = [...names.entries()].sort((a, b) => b[1] - a[1])[0];
      if (top) q.push('user=' + encodeURIComponent(plainName(top[0])));
    }
    return `${u}/commits?${q.join('&')}`;
  };
  let pinned = false;
  const show = (e, r, pin) => {
    const f = r.dataset.f, t = r.dataset.t, p = r.dataset.p;
    const rs = sel.filter(x => x[0] >= f && x[0] <= t && (!p || who.get(x[2]) === p));
    const sum = m => [...m.entries()].sort((a, b) => b[1] - a[1]);
    const pm = new Map(), rm = new Map(); let n = 0;
    rs.forEach(([, rp, a, c]) => { c = Number(c); n += c; pm.set(who.get(a), (pm.get(who.get(a)) || 0) + c); rm.set(rp, (rm.get(rp) || 0) + c); });
    const list = (m, label) => { const e2 = sum(m); return e2.slice(0, 5).map(([k, v]) => `${esc(label(k))} ${v}`).join(', ') + (e2.length > 5 ? `, +${e2.length - 5} more` : ''); };
    let html = `<b>${fmtLong(f)}</b>${p ? '\n' + esc(p) : ''}\n${n ? `<b>${n.toLocaleString()}</b> commit${n === 1 ? '' : 's'}` : at(f) > today ? 'Still to come' : 'No commits'}` +
      (n && !p ? '\nPeople: ' + list(pm, a => a) : '');
    if (n && pin) {
      html = `<button class="x" title="Close">&times;</button>` + html + '\nOpen in Azure DevOps:' + sum(rm).map(([rp, v]) => {
        const u = commitsLink(rp, f, t, p ? rs : null);
        return u ? `\n<a href="${esc(u)}" target="_blank" rel="noopener">${esc(rname(rp))} &middot; ${v} commit${v === 1 ? '' : 's'} &#8599;</a>` : `\n${esc(rname(rp))} ${v}`;
      }).join('');
    }
    else if (n) html += '\nRepos: ' + list(rm, rname) + '\n<span class="sub">Click to open these commits in Azure DevOps</span>';
    tip.innerHTML = html;
    tip.classList.toggle('pin', !!pin);
    tip.hidden = false;
    // Keep the box inside the card (which scrolls sideways, so anything outside it is cut off):
    // flip it left or above the pointer when there's no room, and give the card extra room
    // underneath when the box is taller than the card itself
    hm.style.paddingBottom = '';
    const room = hm.clientHeight - 8, h = tip.offsetHeight;
    if (h > room) hm.style.paddingBottom = (h - room + 16) + 'px';
    const box = hm.getBoundingClientRect();
    let x = e.clientX - box.left + hm.scrollLeft + 14, y = e.clientY - box.top + 14;
    if (x + tip.offsetWidth > hm.scrollLeft + box.width - 4) x = e.clientX - box.left + hm.scrollLeft - tip.offsetWidth - 10;
    if (y + h > hm.clientHeight - 4) y = e.clientY - box.top - h - 10;
    y = Math.max(4, Math.min(y, hm.clientHeight - h - 4));
    tip.style.left = Math.max(hm.scrollLeft + 4, x) + 'px'; tip.style.top = y + 'px';
  };
  const hide = () => { tip.hidden = true; hm.style.paddingBottom = ''; };
  hm.onmousemove = e => {
    if (pinned) return;
    const r = e.target.closest('rect[data-f]');
    if (r) show(e, r, false); else hide();
  };
  hm.onclick = e => {
    if (e.target.closest('#hmtip .x')) { pinned = false; hide(); return; }
    if (e.target.closest('#hmtip')) return;   // a link in the pinned details
    const r = e.target.closest('rect[data-f]');
    if (!r) { pinned = false; hide(); return; }
    pinned = true; show(e, r, true);
  };
  hm.onmouseleave = () => { if (!pinned) hide(); };
}

function renderAll() {
  renderKpis(); renderEpicList(); renderRight(); renderSprints(); renderChanges();
  if (activeTab === 'maps') renderMaps();
  if (window.graphApi) graphApi.redraw();
}

// Theme: Auto follows Windows, or pick Light / Dark. Charts, maps and the graph redraw in the new colours.
$('#theme').value = document.documentElement.dataset.theme || 'auto';
$('#theme').onchange = e => {
  const t = e.target.value;
  try { localStorage.setItem('adomap.theme', JSON.stringify(t)); } catch (err) {}
  if (t === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = t;
  $('#trendType').onchange(); renderSprints(); if (activeTab === 'maps') renderMaps();
  if (window.graphApi) { graphApi.reset(); if (activeTab === 'web') initGraph(); }
};

// ---------- Graph renderer ----------
// A small canvas graph built into the report, so the spider web works offline
// with no outside libraries: shapes, labels, dashed / arrowed links, hover
// tooltips, drag, pan, wheel zoom, and a force layout run in small chunks.
function MiniGraph(host, NS, ES, fg) {
  const cv = document.createElement('canvas');
  cv.style.cssText = 'width:100%;height:100%;display:block;cursor:grab;touch-action:none;border-radius:8px';
  host.innerHTML = ''; host.appendChild(cv);
  const tip = document.createElement('div'); tip.className = 'gtip'; tip.hidden = true; host.appendChild(tip);
  const ctx = cv.getContext('2d');
  const P = new Map();                       // node id -> {x, y}
  let ids = [], eids = [], sel = null, raf = 0, running = false, userMoved = false, dpr = 1, W = 0, H = 0, drag = null, tipTimer = 0;
  let animTok = 0;   // bumping it cancels a running focus animation
  const view = {x: 0, y: 0, k: 1}, handlers = {}, doneQueue = [];
  const size = id => NS.get(id).size || 10;
  const dbBox = id => { const s = NS.get(id); ctx.font = '600 14px system-ui,Segoe UI,sans-serif'; return {w: ctx.measureText(s.label).width + 22, h: 38}; };
  // Space each node takes with its label, in graph units: w x h, centred oy below the node's centre.
  // The layout keeps these boxes apart, so text size is part of the layout, not just the dots.
  const boxes = new Map();
  function box(id) {
    let b = boxes.get(id); if (b) return b;
    const s = NS.get(id), r = size(id);
    if (s.shape === 'database') { const d = dbBox(id); b = {w: d.w + 8, h: d.h + 8, oy: 0}; }
    else {
      ctx.font = `${s.font.bold ? '600 ' : ''}${s.font.size}px system-ui,Segoe UI,sans-serif`;
      const tw = s.label ? ctx.measureText(s.label).width : 0, top = -r * 1.25, bottom = r * 1.25 + 3 + (s.label ? s.font.size * 1.3 : 0);
      b = {w: Math.max(r * 2.5, tw) + 10, h: bottom - top + 6, oy: (top + bottom) / 2};
    }
    boxes.set(id, b); return b;
  }

  function resize() {
    dpr = window.devicePixelRatio || 1; W = host.clientWidth; H = host.clientHeight;
    cv.width = Math.max(1, W * dpr); cv.height = Math.max(1, H * dpr);
    if (!userMoved) fit();   // the first real size can arrive after a small layout has already finished
    paint();
  }
  const ro = new ResizeObserver(resize); ro.observe(host);

  function shapePath(id, p) {
    const s = NS.get(id), r = size(id), x = p.x, y = p.y;
    ctx.beginPath();
    switch (s.shape) {
      case 'square': ctx.rect(x - r, y - r, 2 * r, 2 * r); break;
      case 'triangle': ctx.moveTo(x, y - r * 1.15); ctx.lineTo(x + r, y + r * .75); ctx.lineTo(x - r, y + r * .75); ctx.closePath(); break;
      case 'triangleDown': ctx.moveTo(x, y + r * 1.15); ctx.lineTo(x + r, y - r * .75); ctx.lineTo(x - r, y - r * .75); ctx.closePath(); break;
      case 'diamond': ctx.moveTo(x, y - r * 1.2); ctx.lineTo(x + r * 1.2, y); ctx.lineTo(x, y + r * 1.2); ctx.lineTo(x - r * 1.2, y); ctx.closePath(); break;
      case 'hexagon': for (let i = 0; i < 6; i++) { const a = Math.PI / 3 * i; ctx[i ? 'lineTo' : 'moveTo'](x + r * Math.cos(a), y + r * Math.sin(a)); } ctx.closePath(); break;
      case 'database': { const b = dbBox(id), w = b.w, h = b.h, e = 6;
        ctx.moveTo(x - w / 2, y - h / 2 + e); ctx.ellipse(x, y - h / 2 + e, w / 2, e, 0, Math.PI, 0);
        ctx.lineTo(x + w / 2, y + h / 2 - e); ctx.ellipse(x, y + h / 2 - e, w / 2, e, 0, 0, Math.PI); ctx.closePath(); break; }
      default: ctx.arc(x, y, r, 0, Math.PI * 2);
    }
  }
  function paint() {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
    ctx.setTransform(dpr * view.k, 0, 0, dpr * view.k, dpr * view.x, dpr * view.y);
    const panning = drag && drag.kind === 'pan' && eids.length > 2500;
    if (!panning) for (const e of eids) {
      const s = ES.get(e), a = P.get(s.from), b = P.get(s.to); if (!a || !b) continue;
      const hi = sel && (s.from === sel || s.to === sel);
      ctx.globalAlpha = hi ? .95 : .5; ctx.strokeStyle = s.color; ctx.lineWidth = (s.width || 1) * (hi ? 1.8 : 1);
      ctx.setLineDash(s.dashes ? (Array.isArray(s.dashes) ? s.dashes : [5, 5]) : []);
      ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
      if (s.arrow) {
        const ang = Math.atan2(b.y - a.y, b.x - a.x), r = size(s.to) + 3, tx = b.x - Math.cos(ang) * r, ty = b.y - Math.sin(ang) * r;
        ctx.setLineDash([]); ctx.beginPath(); ctx.moveTo(tx, ty);
        ctx.lineTo(tx - 10 * Math.cos(ang - .4), ty - 10 * Math.sin(ang - .4)); ctx.lineTo(tx - 10 * Math.cos(ang + .4), ty - 10 * Math.sin(ang + .4));
        ctx.closePath(); ctx.fillStyle = s.color; ctx.fill();
      }
    }
    ctx.globalAlpha = 1; ctx.setLineDash([]);
    for (const id of ids) {
      const p = P.get(id), s = NS.get(id); if (!p) continue;
      shapePath(id, p); ctx.fillStyle = s.bg; ctx.fill();
      ctx.lineWidth = id === sel ? 3 : s.bw; ctx.strokeStyle = id === sel ? fg : s.border; ctx.stroke();
    }
    // Labels: biggest items first (repos, epics, features), and skip any that would overlap one
    // already drawn, so text stays readable at any zoom. Zoom in to see the rest.
    const order = ids.filter(id => NS.get(id).label).sort((a, b) =>
      (b === sel) - (a === sel) || (NS.get(b).shape === 'database') - (NS.get(a).shape === 'database') || size(b) - size(a));
    const taken = new Map(), cellPx = 80, k = view.k;
    const hits = (x0, y0, x1, y1, add) => {
      for (let gx = Math.floor(x0 / cellPx); gx <= Math.floor(x1 / cellPx); gx++) for (let gy = Math.floor(y0 / cellPx); gy <= Math.floor(y1 / cellPx); gy++) {
        const key = gx * 100003 + gy, l = taken.get(key);
        if (add) { if (l) l.push([x0, y0, x1, y1]); else taken.set(key, [[x0, y0, x1, y1]]); }
        else if (l && l.some(r => r[0] < x1 && r[2] > x0 && r[1] < y1 && r[3] > y0)) return true;
      }
      return false;
    };
    // Labels are drawn in screen pixels: never smaller than MIN_LABEL_PX, so they stay readable
    // when a big graph is zoomed out to fit (e.g. a narrow VS Code panel)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const MIN_LABEL_PX = 9.5;
    for (const id of order) {
      const p = P.get(id), s = NS.get(id); if (!p) continue;
      if (s.font.size * k < 3 && id !== sel) continue;   // very far out: dots only, zoom in for names
      const db = s.shape === 'database', fs = db ? Math.max(9, s.font.size * k) : Math.max(MIN_LABEL_PX, s.font.size * k);
      ctx.font = `${s.font.bold ? '600 ' : ''}${fs}px system-ui,Segoe UI,sans-serif`;
      const tw = ctx.measureText(s.label).width, cx = view.x + p.x * k;
      const top = db ? view.y + p.y * k - fs * .62 : view.y + (p.y + size(id) * 1.25) * k + 3;
      const sx0 = cx - tw / 2 - 2, sx1 = cx + tw / 2 + 2, sy0 = top - 1, sy1 = top + fs * 1.2 + 1;
      if (sx1 < 0 || sy1 < 0 || sx0 > W || sy0 > H) continue;
      if (!db && id !== sel && hits(sx0, sy0, sx1, sy1, false)) continue;
      if (db && tw > dbBox(id).w * k) continue;   // repo name doesn't fit its shape at this zoom
      hits(sx0, sy0, sx1, sy1, true);
      ctx.textAlign = 'center'; ctx.textBaseline = 'top'; ctx.fillStyle = s.font.color;
      ctx.fillText(s.label, cx, top);
    }
  }
  const schedulePaint = () => { if (!running) requestAnimationFrame(paint); };

  function setVisible(nodeIds, edgeIds) {
    ids = [...nodeIds]; eids = edgeIds; userMoved = false; animTok++;
    const nb = new Map(), add = (a, b) => { let l = nb.get(a); if (!l) nb.set(a, l = []); l.push(b); };
    eids.forEach(e => { const s = ES.get(e); add(s.from, s.to); add(s.to, s.from); });
    const R = 45 * Math.sqrt(ids.length + 1);
    ids.forEach(id => {   // new nodes start next to a neighbour that's already placed, else somewhere in a disc
      if (P.has(id)) return;
      const n = (nb.get(id) || []).find(x => P.has(x)), a = Math.random() * 6.2832, r = n ? 25 + Math.random() * 35 : R * Math.sqrt(Math.random());
      const o = n ? P.get(n) : {x: 0, y: 0}, q = n ? 1 : aspect(); P.set(id, {x: o.x + Math.cos(a) * r * q, y: o.y + Math.sin(a) * r / q});
    });
    if (!ids.includes(sel)) sel = null;
    fit(); paint();
  }
  // Spread the layout to the canvas shape (a wide canvas gets a wide graph) instead of a circle in the middle
  const aspect = () => W && H ? Math.min(2.5, Math.max(.6, W / H)) : 1;
  function fit() {
    if (!ids.length || !W) return;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    ids.forEach(id => { const p = P.get(id), b = box(id);   // include the labels, so none are cut off at the edges
      x0 = Math.min(x0, p.x - b.w / 2); x1 = Math.max(x1, p.x + b.w / 2); y0 = Math.min(y0, p.y + b.oy - b.h / 2); y1 = Math.max(y1, p.y + b.oy + b.h / 2); });
    view.k = Math.min(1.6, Math.max(.04, Math.min(W / (x1 - x0 + 40), H / (y1 - y0 + 40))));
    view.x = W / 2 - view.k * (x0 + x1) / 2; view.y = H / 2 - view.k * (y0 + y1) / 2;
  }
  function layout(iters, onProgress) {
    stop();
    const n = ids.length; if (!n) return;
    const idx = new Map(ids.map((id, i) => [id, i]));
    const X = new Float64Array(n), Y = new Float64Array(n), VX = new Float64Array(n), VY = new Float64Array(n), M = new Float64Array(n);
    ids.forEach((id, i) => { const p = P.get(id); X[i] = p.x; Y[i] = p.y; M[i] = NS.get(id).mass || 1; });
    const E = []; eids.forEach(e => { const s = ES.get(e), a = idx.get(s.from), b = idx.get(s.to); if (a != null && b != null) E.push(a, b); });
    const rest = 95, kSpring = .035, kRep = 3600, cell = 170, grav = .005, damp = .8, gX = grav / aspect(), gY = grav * aspect();
    const BW = new Float64Array(n), BH = new Float64Array(n), BO = new Float64Array(n);
    ids.forEach((id, i) => { const b = box(id); BW[i] = b.w; BH[i] = b.h; BO[i] = b.oy; });
    let cc = cell; for (let i = 0; i < n; i++) cc = Math.max(cc, BW[i], BH[i]); cc = Math.min(cc, 420);
    let it = 0; running = true;
    const step = () => {
      // Work in ~14 ms slices, so the page stays responsive (and it keeps going where animation frames are throttled)
      const t0 = performance.now();
      for (; it < iters && performance.now() - t0 < 14; it++) {
        const cool = 1 - .85 * it / iters, grid = new Map(), FX = new Float64Array(n), FY = new Float64Array(n);
        for (let i = 0; i < n; i++) { const k = Math.floor(X[i] / cell) * 100003 + Math.floor(Y[i] / cell); let c = grid.get(k); if (!c) grid.set(k, c = []); c.push(i); }
        for (let i = 0; i < n; i++) {   // repulsion between nearby nodes only (grid), so big graphs stay fast
          const cx = Math.floor(X[i] / cell), cy = Math.floor(Y[i] / cell);
          for (let gx = cx - 1; gx <= cx + 1; gx++) for (let gy = cy - 1; gy <= cy + 1; gy++) {
            const c = grid.get(gx * 100003 + gy); if (!c) continue;
            for (const j of c) {
              if (j <= i) continue;
              let dx = X[i] - X[j], dy = Y[i] - Y[j], d2 = dx * dx + dy * dy;
              if (d2 > cell * cell) continue;
              if (d2 < .01) { dx = Math.random() - .5; dy = Math.random() - .5; d2 = .25; }
              const d = Math.sqrt(d2), fr = kRep * M[i] * M[j] / d2;
              FX[i] += dx / d * fr; FY[i] += dy / d * fr; FX[j] -= dx / d * fr; FY[j] -= dy / d * fr;
            }
          }
        }
        for (let e = 0; e < E.length; e += 2) {
          const a = E[e], b = E[e + 1], dx = X[b] - X[a], dy = Y[b] - Y[a], d = Math.sqrt(dx * dx + dy * dy) || .1, fs = kSpring * (d - rest);
          FX[a] += dx / d * fs; FY[a] += dy / d * fs; FX[b] -= dx / d * fs; FY[b] -= dy / d * fs;
        }
        const maxV = 35 * cool;
        for (let i = 0; i < n; i++) {
          if (drag && drag.kind === 'node' && drag.id === ids[i]) { const p = P.get(ids[i]); X[i] = p.x; Y[i] = p.y; VX[i] = VY[i] = 0; continue; }
          VX[i] = (VX[i] + (FX[i] - X[i] * gX) / M[i]) * damp; VY[i] = (VY[i] + (FY[i] - Y[i] * gY) / M[i]) * damp;
          const v = Math.hypot(VX[i], VY[i]); if (v > maxV) { VX[i] *= maxV / v; VY[i] *= maxV / v; }
          X[i] += VX[i]; Y[i] += VY[i];
        }
        // Once the rough shape has formed, push apart any node + label boxes that overlap
        if (it > iters * .2) {
          const g2 = new Map();
          for (let i = 0; i < n; i++) { const k = Math.floor(X[i] / cc) * 100003 + Math.floor((Y[i] + BO[i]) / cc); let c = g2.get(k); if (!c) g2.set(k, c = []); c.push(i); }
          for (let i = 0; i < n; i++) {
            const cx = Math.floor(X[i] / cc), cy = Math.floor((Y[i] + BO[i]) / cc);
            for (let gx = cx - 1; gx <= cx + 1; gx++) for (let gy = cy - 1; gy <= cy + 1; gy++) {
              const c = g2.get(gx * 100003 + gy); if (!c) continue;
              for (const j of c) {
                if (j <= i) continue;
                const dx = X[j] - X[i], dy = (Y[j] + BO[j]) - (Y[i] + BO[i]);
                const ox = (BW[i] + BW[j]) / 2 - Math.abs(dx), oy = (BH[i] + BH[j]) / 2 - Math.abs(dy);
                if (ox <= 0 || oy <= 0) continue;
                const wi = M[j] / (M[i] + M[j]), wj = 1 - wi;   // heavier nodes (repos) move less
                if (ox < oy) { const s = (ox * .55 + .3) * (dx ? Math.sign(dx) : (Math.random() < .5 ? -1 : 1)); X[i] -= s * wi; X[j] += s * wj; }
                else { const s = (oy * .55 + .3) * (dy ? Math.sign(dy) : (Math.random() < .5 ? -1 : 1)); Y[i] -= s * wi; Y[j] += s * wj; }
              }
            }
          }
        }
      }
      ids.forEach((id, i) => { const p = P.get(id); p.x = X[i]; p.y = Y[i]; });
      if (!userMoved) fit();
      paint();
      if (onProgress) onProgress(it, iters);
      if (it < iters && running) raf = setTimeout(step, 0);
      else { running = false; if (!userMoved) { widen(); fit(); paint(); } const q = doneQueue.splice(0); q.forEach(f => f()); }
    };
    raf = setTimeout(step, 0);
  }
  function stop() { clearTimeout(raf); running = false; }
  // Small graphs keep a round shape whatever the canvas: stretch them sideways (up to 1.8x) to use a wide canvas
  function widen() {
    let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    ids.forEach(id => { const p = P.get(id); x0 = Math.min(x0, p.x); x1 = Math.max(x1, p.x); y0 = Math.min(y0, p.y); y1 = Math.max(y1, p.y); });
    const w = x1 - x0, h = y1 - y0, want = W && H ? W / H : 1;
    if (!(w > 0 && h > 0) || w / h >= want) return;
    const f = Math.min(1.8, want * h / w), cx = (x0 + x1) / 2;
    ids.forEach(id => { const p = P.get(id); p.x = cx + (p.x - cx) * f; });
  }

  // ---- interaction ----
  const toWorld = (sx, sy) => ({x: (sx - view.x) / view.k, y: (sy - view.y) / view.k});
  function hit(sx, sy) {
    const w = toWorld(sx, sy);
    for (let i = ids.length - 1; i >= 0; i--) {
      const id = ids[i], p = P.get(id), s = NS.get(id);
      if (s.shape === 'database') { const b = dbBox(id); if (Math.abs(w.x - p.x) <= b.w / 2 && Math.abs(w.y - p.y) <= b.h / 2) return id; }
      else { const r = size(id) * 1.25 + 3 / view.k; if ((w.x - p.x) ** 2 + (w.y - p.y) ** 2 <= r * r) return id; }
    }
    return null;
  }
  const local = e => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  cv.addEventListener('pointerdown', e => {
    const [sx, sy] = local(e), id = hit(sx, sy);
    drag = {kind: id ? 'node' : 'pan', id, sx, sy, moved: false, vx: view.x, vy: view.y}; animTok++;
    cv.setPointerCapture(e.pointerId); cv.style.cursor = 'grabbing'; tip.hidden = true;
  });
  cv.addEventListener('pointermove', e => {
    const [sx, sy] = local(e);
    if (drag) {
      if (Math.abs(sx - drag.sx) + Math.abs(sy - drag.sy) > 3) drag.moved = true;
      if (!drag.moved) return;
      userMoved = true;
      if (drag.kind === 'pan') { view.x = drag.vx + sx - drag.sx; view.y = drag.vy + sy - drag.sy; }
      else { const w = toWorld(sx, sy), p = P.get(drag.id); p.x = w.x; p.y = w.y; }
      schedulePaint(); return;
    }
    const id = hit(sx, sy);
    cv.style.cursor = id ? 'pointer' : 'grab';
    clearTimeout(tipTimer);
    if (!id || !NS.get(id).title) { tip.hidden = true; return; }
    tipTimer = setTimeout(() => {
      tip.textContent = NS.get(id).title; tip.hidden = false;
      tip.style.left = Math.min(sx + 14, W - tip.offsetWidth - 8) + 'px'; tip.style.top = Math.min(sy + 14, H - tip.offsetHeight - 8) + 'px';
    }, 150);
  });
  cv.addEventListener('pointerup', e => {
    if (!drag) return;
    const d = drag; drag = null; cv.style.cursor = 'grab';
    if (!d.moved) { sel = d.id; paint(); if (handlers.click) handlers.click(d.id); }
    else schedulePaint();
  });
  cv.addEventListener('pointerleave', () => { clearTimeout(tipTimer); tip.hidden = true; });
  cv.addEventListener('dblclick', e => { const [sx, sy] = local(e), id = hit(sx, sy); if (id && handlers.doubleClick) handlers.doubleClick(id); });
  cv.addEventListener('wheel', e => {
    e.preventDefault(); userMoved = true; animTok++;
    const [sx, sy] = local(e), w = toWorld(sx, sy), k = Math.min(6, Math.max(.03, view.k * Math.exp(-e.deltaY * .0015)));
    view.k = k; view.x = sx - w.x * k; view.y = sy - w.y * k; schedulePaint();
  }, {passive: false});

  return {
    setVisible, layout, stop, fit: () => { fit(); paint(); }, paint,
    get running() { return running; },
    on(ev, fn) { handlers[ev] = fn; },
    whenDone(fn) { if (running) doneQueue.push(fn); else fn(); },
    select(id) { sel = id; paint(); },
    screenPos(id) { const p = P.get(id); return p ? [view.x + p.x * view.k, view.y + p.y * view.k] : null; },
    focus(id, k) {
      const p = P.get(id); if (!p) return; userMoved = true;
      const k0 = view.k, x0 = view.x, y0 = view.y, k1 = k || 1, x1 = W / 2 - p.x * k1, y1 = H / 2 - p.y * k1, t0 = performance.now(), tok = ++animTok;
      const anim = t => { if (tok !== animTok) return; const f = Math.min(1, (t - t0) / 350), s = f * (2 - f);
        view.k = k0 + (k1 - k0) * s; view.x = x0 + (x1 - x0) * s; view.y = y0 + (y1 - y0) * s; paint(); if (f < 1) requestAnimationFrame(anim); };
      requestAnimationFrame(anim);
    },
    destroy() { stop(); ro.disconnect(); host.innerHTML = ''; }
  };
}

// ---------- Spider web ----------
// Big projects reach tens of thousands of nodes, more than a browser can lay out.
// The graph only draws one scope at a time (overview, sprint, one item's tree) and
// asks before drawing more than NODE_LIMIT nodes. Layout runs in small batches.
const NODE_LIMIT = 2000;
let net;
function initGraph() {
  if (net) return;
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue('--text').trim(), done = css.getPropertyValue('--done').trim(),
        muted = css.getPropertyValue('--muted').trim();
  const G = D.graph, nodeById = new Map(G.nodes.map(n => [n.id, n]));
  const SHAPE = {Epic: ['hexagon', 24], Feature: ['dot', 18], Story: ['dot', 12], Tech: ['dot', 12], Bug: ['triangle', 11], Task: ['dot', 7], Other: ['dot', 10],
                 Repo: ['database', 0], PR: ['diamond', 10], Commit: ['dot', 4], Branch: ['triangleDown', 8], Build: ['square', 7]};
  const ORDER = ['Epic', 'Feature', 'Story', 'Tech', 'Bug', 'Task', 'Other', 'Repo', 'PR', 'Branch', 'Commit', 'Build'];
  const counts = {}; G.nodes.forEach(n => counts[n.kind] = (counts[n.kind] || 0) + 1);
  const on = new Set(ORDER.filter(k => counts[k] && !(k === 'Commit' && counts[k] > 400)));
  $('#kinds').innerHTML = ORDER.filter(k => counts[k]).map(k =>
    `<label><input type="checkbox" data-k="${k}"${on.has(k) ? ' checked' : ''}><span class="sw" style="--c:${C[k]}"></span>${k === 'PR' ? 'Pull requests' : k === 'Tech' ? 'Technical Story' : k}<span class="cnt">${counts[k]}</span></label>`).join('');
  if (!SPR.length) $('#g-scope option[value=sprint]').disabled = true;
  let gSprint = curIdx >= 0 ? curIdx : SPR.length - 1;
  $('#g-sprintsel').innerHTML = SPR.map((s, i) => `<option value="${i}">${esc(s.name)}${i === curIdx ? ' (current)' : ''}${s.start ? ' - ' + fmtDate(s.start) : ''}</option>`).join('');
  $('#g-sprintsel').value = gSprint;

  // Repo links rolled up to the nearest feature (or epic) for the overview
  const rollTarget = id => { let it = byId.get(id); while (it && it.level > 1 && byId.has(it.parent)) it = byId.get(it.parent); return it; };
  const roll = new Map();
  G.edges.forEach(e => { if (e.kind !== 'wi-repo') return; const t = rollTarget(+e.from.slice(1)); if (!t) return;
    const k = 'w' + t.id + '|' + e.to; roll.set(k, (roll.get(k) || 0) + 1); });
  const rollEdges = [...roll].map(([k, c], i) => { const [from, to] = k.split('|'); return {id: 'roll' + i, from, to, kind: 'rollup', count: c}; });
  const allEdges = G.edges.concat(rollEdges);
  const adj = new Map();   // related / dependency neighbours
  G.edges.forEach(e => { if (e.kind !== 'related' && e.kind !== 'depends') return; const a = +e.from.slice(1), b = +e.to.slice(1);
    (adj.get(a) || adj.set(a, []).get(a)).push(b); (adj.get(b) || adj.set(b, []).get(b)).push(a); });

  const NS = new Map(G.nodes.map(n => {
    const sh = SHAPE[n.kind] || ['dot', 8], isDone = n.bucket === 'done' || n.status === 'completed';
    return [n.id, {label: n.label, title: n.title, shape: sh[0], size: sh[1] || 10, bg: C[n.kind] || '#888',
      border: isDone ? done : (C[n.kind] || '#888'), bw: isDone ? 3 : 1,
      font: n.kind === 'Repo' ? {color: '#fff', size: 14, bold: true} : {color: fg, size: n.kind === 'Commit' ? 9 : 11},
      mass: n.kind === 'Repo' ? 3 : 1}];
  }));
  const EDGE = {child: {color: muted, width: 1.2}, related: {color: muted, dashes: true}, depends: {color: '#dc2626', arrow: true},
                artifact: {color: '#0d9488', width: .8}, 'in-repo': {color: '#475569', width: .8}, 'pr-branch': {color: '#2563eb', dashes: [2, 3]},
                'wi-repo': {color: '#475569', dashes: [6, 4], width: .8}, rollup: {color: '#64748b'}};
  const ES = new Map(allEdges.map(e => [e.id, Object.assign({from: e.from, to: e.to}, EDGE[e.kind] || {color: muted},
    e.kind === 'rollup' ? {width: 1 + Math.min(6, Math.log2(e.count))} : {})]));
  const edgeMeta = new Map(allEdges.map(e => [e.id, e]));

  let scope = SPR.length ? 'sprint' : 'overview', focusId = null, force = false, visible = new Set();
  $('#g-scope').value = scope;
  $('#g-sprintsel').hidden = scope !== 'sprint';
  function scopeItems() {
    const s = new Set();
    if (scope === 'overview') D.items.forEach(i => { if (i.level <= 1) s.add(i.id); });
    else if (scope === 'sprint') D.items.forEach(i => { if (i.sp !== gSprint || !pass(i)) return; let it = i; while (it && !s.has(it.id)) { s.add(it.id); it = byId.get(it.parent); } });
    else if (scope === 'focus' && focusId != null) {
      for (let it = byId.get(focusId); it; it = byId.get(it.parent)) s.add(it.id);
      const walk = id => { s.add(id); byId.get(id).children.forEach(walk); }; walk(focusId);
      [...s].forEach(id => (adj.get(id) || []).forEach(n => s.add(n)));
    } else if (scope === 'all') D.items.forEach(i => s.add(i.id));
    return s;
  }
  function filtered(ids) {
    // Filter bar: keep matching items, plus their parents in the same view for context
    if (!filtersOn() || scope === 'sprint') return ids;
    const out = new Set();
    ids.forEach(id => { const it = byId.get(id); if (!pass(it)) return; let a = it; while (a && ids.has(a.id) && !out.has(a.id)) { out.add(a.id); a = byId.get(a.parent); } });
    return out;
  }
  function compute() {
    const hd = $('#g-hidedone').checked; visible = new Set();
    filtered(scopeItems()).forEach(id => { const n = nodeById.get('w' + id); if (n && on.has(n.kind) && (!hd || n.bucket !== 'done')) visible.add(n.id); });
    const wiOn = new Set(visible);
    if (scope !== 'overview') G.nodes.forEach(n => { if (n.art && on.has(n.kind) && n.wis.some(w => wiOn.has('w' + w))) visible.add(n.id); });
    if (on.has('Repo')) G.nodes.forEach(n => { if (n.kind !== 'Repo') return;
      if (((scope === 'overview' || scope === 'all') && !hd) || (scope !== 'overview' && n.wis.some(w => wiOn.has('w' + w)))) visible.add(n.id); });
    if (scope === 'overview' && on.has('Repo')) rollEdges.forEach(e => { if (wiOn.has(e.from)) visible.add(e.to); });
  }
  const edgeOk = m => {
    if (!visible.has(m.from) || !visible.has(m.to)) return false;
    if (m.kind === 'rollup') return scope === 'overview';
    if (m.kind === 'wi-repo') return scope !== 'overview' && !m.via.some(a => visible.has(a));
    return true; };
  net = MiniGraph($('#graph'), NS, ES, fg);

  const busy = $('#g-busy'), overlay = $('#g-overlay');
  const layout = () => {
    const n = visible.size, it = n > 1000 ? 150 : n > 300 ? 250 : 400;
    busy.innerHTML = `Laying out ${n.toLocaleString()} nodes&hellip; <span>0%</span> <button class="btn" style="padding:1px 8px">Stop</button>`;
    busy.querySelector('button').onclick = () => { net.stop(); busy.hidden = true; };
    busy.hidden = false;
    net.layout(it, (i, t) => { busy.querySelector('span').textContent = Math.round(100 * i / t) + '%'; if (i >= t) busy.hidden = true; });
  };

  function draw() {
    compute();
    const n = visible.size;
    $('#g-count').textContent = `${n.toLocaleString()} nodes in this view`;
    overlay.hidden = true;
    if (scope === 'focus' && focusId == null) {
      visible = new Set();
      overlay.innerHTML = '<b>Pick an item to focus on</b><span class="sub">Double-click a work item in another view, or type its #id in the search box.</span>';
      overlay.hidden = false;
    } else if (n > NODE_LIMIT && !force) {
      visible = new Set();
      overlay.innerHTML = `<b>${n.toLocaleString()} nodes is too many to draw smoothly</b>
        <span class="sub">Narrow it down: focus on one epic or feature (double-click it in the overview), switch to Current sprint, or untick Tasks / Commits / Branches.</span>
        <button class="btn" id="g-force">Draw anyway (may freeze the page for a while)</button>`;
      overlay.hidden = false;
      $('#g-force').onclick = () => { force = true; draw(); };
    }
    net.setVisible(visible, allEdges.filter(edgeOk).map(e => e.id));
    if (visible.size) layout(); else busy.hidden = true;
  }
  function setScope(s) { scope = s; force = false; $('#g-scope').value = s; $('#g-sprintsel').hidden = s !== 'sprint'; draw(); }
  $('#g-sprintsel').onchange = e => { gSprint = +e.target.value; force = false; draw(); };
  function focusOn(id) {
    focusId = id;
    $('#g-scope option[value=focus]').textContent = `Focus: #${id} ${(byId.get(id) || {}).title || ''}`.slice(0, 60);
    setScope('focus');
    net.whenDone(() => { if (visible.has('w' + id)) { net.select('w' + id); net.focus('w' + id, 1); } });
  }
  const showDetail = n => {
    $('#detail').innerHTML = `<b>${esc(n.label)}</b><div class="sub">${esc(n.kind)}</div><pre>${esc(n.title)}</pre>` +
      (n.url ? `<a href="${esc(n.url)}" target="_blank" rel="noopener">Open in Azure DevOps &#8599;</a>` : '') +
      (n.wi ? ' <button class="btn" id="g-focus" style="margin-top:6px">Focus on this item</button>' : '');
    if (n.wi) $('#g-focus').onclick = () => focusOn(+n.id.slice(1));
  };

  $('#g-scope').onchange = e => setScope(e.target.value);
  $('#kinds').onchange = e => { const k = e.target.dataset.k; e.target.checked ? on.add(k) : on.delete(k); draw(); };
  $('#g-hidedone').onchange = draw;
  $('#relayout').onclick = () => { if (visible.size) layout(); };
  net.on('click', id => { const n = nodeById.get(id); if (n) showDetail(n); });
  net.on('doubleClick', id => { const n = nodeById.get(id); if (n && n.wi) focusOn(+n.id.slice(1)); });
  $('#gq').onkeydown = e => { if (e.key !== 'Enter') return; const q = e.target.value.trim().toLowerCase().replace(/^#/, ''); if (!q) return;
    const hit = nodeById.get('w' + q) || G.nodes.find(n => n.label.toLowerCase().includes(q));
    if (!hit) { $('#detail').innerHTML = '<span class="sub">No match.</span>'; return; }
    showDetail(hit);
    if (visible.has(hit.id)) { net.select(hit.id); net.focus(hit.id, 1.2); }
    else if (hit.wi) focusOn(+hit.id.slice(1));
    else if (hit.wis && hit.wis.length) focusOn(hit.wis[0]); };
  window.graphApi = {redraw: () => { force = false; draw(); }, focus: id => focusOn(id),
    reset: () => { net.destroy(); net = null; window.graphApi = null; }};
  draw();
}

buildFilterBar(); syncFilterBar(); renderAll(); showTab(activeTab);
</script>
</body>
</html>
'@

# --------------------------------------------------------------------------- #
# Launch pad (-Serve): a small local web page for first-time setup and data
# maintenance. It only listens on this PC, needs a one-time key from the link it
# prints, and runs the same script in the background for each button.
# --------------------------------------------------------------------------- #
function Get-RunArguments([string[]]$Extra) {
    # The settings this launch pad was started with, passed on to each background run
    $a = New-Object 'Collections.Generic.List[string]'
    $a.AddRange([string[]]@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-NoOpen', '-ConfigPath', $ConfigPath, '-OutDir', $OutDir))
    foreach ($k in 'Org', 'Project', 'Team', 'Iteration', 'AreaPath') { $v = Get-Variable $k -ValueOnly; if ($v) { $a.Add("-$k"); $a.Add([string]$v) } }
    if ($ServerUrl -and $ServerUrl -ne 'https://dev.azure.com') { $a.Add('-ServerUrl'); $a.Add($ServerUrl) }
    if ($EpicId) { $a.Add('-EpicId'); $a.Add(($EpicId -join ',')) }
    if ($Types) { $a.Add('-Types'); $a.Add(($Types -join ',')) }
    foreach ($k in 'MaxPrDetails', 'HistoryDays', 'ArchiveDays', 'CommitDays') {
        if ($Extra -contains "-$k") { continue }   # the button's own value wins
        $a.Add("-$k"); $a.Add([string](Get-Variable $k -ValueOnly))
    }
    if ($ClosedWithinDays -ge 0) { $a.Add('-ClosedWithinDays'); $a.Add([string]$ClosedWithinDays) }
    if ($IncludeRemoved) { $a.Add('-IncludeRemoved') }
    foreach ($x in $Extra) { $a.Add($x) }
    # One command line, quoting anything with spaces
    return (($a | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' ')
}

function Read-SharedText([string]$Path, [int]$MaxLines = 400) {
    # Read a log another process is still writing to
    if (-not (Test-Path $Path)) { return '' }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    $lines = $text -split "`r?`n"
    if ($lines.Count -gt $MaxLines) { $lines = $lines[($lines.Count - $MaxLines)..($lines.Count - 1)] }
    return ($lines -join "`n")
}

function Start-LaunchPad {
    $listener = New-Object System.Net.HttpListener
    $prefix = "http://localhost:$Port/"
    $listener.Prefixes.Add($prefix)
    try { $listener.Start() }
    catch { throw "Couldn't start the launch pad on $prefix ($($_.Exception.Message)). Is it already open? Or pick another port with -Port." }
    $key = [guid]::NewGuid().ToString('N')
    # Background runs inherit the token through the environment, never on their command line
    if ($Pat) { $env:ADO_PAT = $Pat }
    $logDir = $OutDir   # not cache\: Clear deletes that folder while the run is writing its log
    $job = @{ proc = $null; action = ''; label = ''; started = $null; exit = $null; log = (Join-Path $logDir 'launchpad.log'); err = (Join-Path $logDir 'launchpad.err.log') }
    $actions = [ordered]@{
        setup    = @{ label = 'Set up folders'; args = @('-Setup') }
        pull     = @{ label = 'Pull changes'; args = @() }
        full     = @{ label = 'Full refresh'; args = @('-Full') }
        offline  = @{ label = 'Rebuild report'; args = @('-Offline') }
        history  = @{ label = 'Pull history'; args = @('-PullHistory') }
        clear    = @{ label = 'Clear archived data'; args = @('-ClearArchive') }
        clearall = @{ label = 'Clear all data'; args = @('-ClearArchive', '-IncludeHistory') }
    }
    $url = "$($prefix)?k=$key"
    Write-Host ''
    Write-Host "ADO Work Map launch pad: $url"
    Write-Host 'Only this PC can reach it. Keep this window open while you use it; close it (or press Ctrl+C) to stop.'
    if (-not $NoOpen) { Start-Process $url }

    function Send($ctx, [int]$code, [string]$type, [string]$body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = $type
        $ctx.Response.Headers.Add('Cache-Control', 'no-store')
        $ctx.Response.Headers.Add('X-Content-Type-Options', 'nosniff')
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.Close()
    }
    function SendJson($ctx, $obj) { Send $ctx 200 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $obj -Depth 6 -Compress) }

    function Get-PadStatus {
        $statusFile = Join-Path $OutDir 'cache\status.json'
        $report = Join-Path $OutDir 'ado_work_map.html'
        $todo = @()
        if (-not $Org) { $todo += 'Organization (ADO_ORG in run_ado_work_map.cmd)' }
        if (-not $Project) { $todo += 'Project (ADO_PROJECT in run_ado_work_map.cmd)' }
        if (-not $Pat -and -not $env:ADO_PAT -and -not $env:AZURE_DEVOPS_EXT_PAT -and -not (Get-Command az -ErrorAction SilentlyContinue)) {
            $todo += 'Personal access token (ADO_PAT_VALUE in run_ado_work_map.cmd, or start the launch pad from run_ado_work_map.cmd)' }
        $running = $job.proc -and -not $job.proc.HasExited
        if ($job.proc -and $job.proc.HasExited -and $null -eq $job.exit) { $job.exit = $job.proc.ExitCode }
        $log = ''
        if ($job.started) { $log = Read-SharedText $job.log; $e = Read-SharedText $job.err 80; if ($e.Trim()) { $log += "`n" + $e } }
        @{
            org = $Org; project = $Project; outDir = $OutDir
            folders = [bool]((Test-Path $OutDir) -and (Test-Path (Join-Path $OutDir 'cache')) -and (Test-Path (Join-Path $OutDir 'archive')))
            todo = $todo
            data = $(if (Test-Path $statusFile) { Get-Content $statusFile -Raw | ConvertFrom-Json } else { $null })
            report = $(if (Test-Path $report) { $f = Get-Item $report; @{ updated = $f.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); kb = [int]($f.Length / 1KB) } } else { $null })
            job = @{ running = [bool]$running; action = $job.action; label = $job.label; exit = $job.exit
                started = $(if ($job.started) { $job.started.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }); log = $log }
            actions = @($actions.Keys | ForEach-Object { @{ id = $_; label = $actions[$_].label } })
        }
    }

    function Start-PadJob([string]$id, [int]$days) {
        if ($job.proc -and -not $job.proc.HasExited) { return 'busy' }
        $a = @($actions[$id].args)
        if ($id -eq 'history') { $a += '-HistoryDays'; $a += [string][Math]::Max(1, $days) }
        [void](New-Item -ItemType Directory -Force -Path $logDir)
        foreach ($f in $job.log, $job.err) { if (Test-Path $f) { Remove-Item $f -Force } }
        $job.proc = Start-Process powershell.exe -ArgumentList (Get-RunArguments $a) -RedirectStandardOutput $job.log -RedirectStandardError $job.err -NoNewWindow -PassThru
        $null = $job.proc.Handle   # keeps ExitCode available after the process ends
        $job.action = $id; $job.label = $actions[$id].label; $job.started = (Get-Date).ToUniversalTime(); $job.exit = $null
        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  started: $($job.label)"
        return 'started'
    }

    try {
        while ($listener.IsListening) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.Wait(500)) { }   # short waits so Ctrl+C still works
            $ctx = $pending.Result
            $req = $ctx.Request
            try {
                # Only answer requests addressed to this PC by name (blocks DNS-rebinding tricks)
                if ($req.Url.Host -ne 'localhost') { Send $ctx 403 'text/plain' 'Forbidden'; continue }
                $cookie = $req.Cookies['adomap']
                if ($req.QueryString['k'] -eq $key) {
                    # Swap the one-time key in the link for a cookie, and drop it from the address bar
                    $ctx.Response.Headers.Add('Set-Cookie', "adomap=$key; Path=/; HttpOnly; SameSite=Strict")
                    $ctx.Response.Redirect('/'); $ctx.Response.Close(); continue
                }
                if (-not $cookie -or $cookie.Value -ne $key) {
                    Send $ctx 403 'text/html; charset=utf-8' '<p style="font-family:system-ui">Open the launch pad with the link shown in its window.</p>'; continue
                }
                if ($req.HttpMethod -eq 'POST' -and $req.Headers['X-AdoMap'] -ne '1') { Send $ctx 403 'text/plain' 'Forbidden'; continue }
                switch ($req.Url.AbsolutePath) {
                    '/' { Send $ctx 200 'text/html; charset=utf-8' $LaunchPadTemplate }
                    '/report' {
                        $report = Join-Path $OutDir 'ado_work_map.html'
                        if (Test-Path $report) { Send $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllText($report)) }
                        else { Send $ctx 404 'text/html; charset=utf-8' '<p style="font-family:system-ui">No report yet - run a pull from the launch pad first.</p>' }
                    }
                    '/api/status' { SendJson $ctx (Get-PadStatus) }
                    '/api/run' {
                        $body = (New-Object IO.StreamReader($req.InputStream)).ReadToEnd() | ConvertFrom-Json
                        if (-not $actions.Contains([string]$body.action)) { Send $ctx 400 'text/plain' 'Unknown action'; break }
                        SendJson $ctx @{ result = (Start-PadJob ([string]$body.action) ([int]$body.days)) }
                    }
                    '/api/stop' {
                        SendJson $ctx @{ result = 'stopping' }
                        $listener.Stop()
                    }
                    default { Send $ctx 404 'text/plain' 'Not found' }
                }
            }
            catch { try { Send $ctx 500 'text/plain' "Error: $($_.Exception.Message)" } catch { } }
        }
    }
    finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
        Write-Host 'Launch pad stopped.'
    }
}

$LaunchPadTemplate = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ADO Work Map - Launch pad</title>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--text:#1a202c;--muted:#64748b;--line:#e2e8f0;--hover:#f1f5f9;--accent:#0f62fe;--done:#16a34a;--warn:#b45309;--bad:#dc2626;--code:#0f172a;--codetext:#e2e8f0}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--panel:#171a21;--text:#e5e7eb;--muted:#94a3b8;--line:#2a2f3a;--hover:#1f2430;--accent:#60a5fa;--done:#22c55e;--warn:#f59e0b;--bad:#f87171;--code:#0b0d12;--codetext:#cbd5e1;color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 system-ui,"Segoe UI",sans-serif}
header{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:14px 20px;background:var(--panel);border-bottom:1px solid var(--line)}
h1{font-size:18px;margin:0} h2{font-size:15px;margin:0 0 10px}
.sub{color:var(--muted);font-size:12px}
main{max-width:1100px;margin:0 auto;padding:16px 20px;display:grid;grid-template-columns:1fr 1fr;gap:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.wide{grid-column:1/-1}
.btn{display:inline-flex;align-items:center;gap:6px;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:7px;padding:7px 12px;font:inherit;font-size:13px;cursor:pointer;text-decoration:none}
.btn:hover:not([disabled]){background:var(--hover)}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.btn.danger{color:var(--bad);border-color:color-mix(in srgb,var(--bad) 45%,var(--line))}
.btn[disabled]{opacity:.5;cursor:not-allowed}
.steps{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:10px}
.steps li{display:grid;grid-template-columns:26px 1fr auto;gap:10px;align-items:start}
.dot{width:24px;height:24px;border-radius:50%;display:grid;place-items:center;font-size:12px;font-weight:700;border:2px solid var(--line);color:var(--muted)}
.dot.ok{background:var(--done);border-color:var(--done);color:#fff}
.steps ul{margin:4px 0 0;padding-left:18px;color:var(--warn);font-size:13px}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:12px}
.stat{border:1px solid var(--line);border-radius:8px;padding:8px 10px}
.stat b{display:block;font-size:18px}
.acts{display:flex;flex-direction:column;gap:8px}
.act{display:grid;grid-template-columns:170px 1fr;gap:12px;align-items:center}
.act .btn{justify-content:center}
input[type=number]{width:72px;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:4px 6px;font:inherit}
.badge{font-size:12px;font-weight:600;padding:2px 9px;border-radius:10px;border:1px solid}
.b-run{color:var(--accent)} .b-ok{color:var(--done)} .b-bad{color:var(--bad)} .b-idle{color:var(--muted)}
pre{background:var(--code);color:var(--codetext);border-radius:8px;padding:10px 12px;margin:10px 0 0;height:300px;overflow:auto;font:12px/1.45 ui-monospace,Consolas,monospace;white-space:pre-wrap}
.err{color:var(--bad)}
@media (max-width:820px){main{grid-template-columns:1fr;padding:12px 16px} .act{grid-template-columns:1fr} .stats{grid-template-columns:repeat(2,1fr)} header{padding:12px 16px}}
</style>
</head>
<body>
<header>
  <div><h1>ADO Work Map &middot; Launch pad</h1><div class="sub" id="who">Loading...</div></div>
  <div style="display:flex;gap:8px"><a class="btn primary" id="open" href="/report" target="_blank" rel="noopener">Open report</a><button class="btn" id="stop" title="Stop the launch pad">Close launch pad</button></div>
</header>
<main>
  <section class="card">
    <h2>Getting started</h2>
    <ol class="steps" id="steps"></ol>
  </section>

  <section class="card">
    <h2>Your data</h2>
    <div class="stats" id="stats"></div>
    <div class="sub" id="dataInfo"></div>
  </section>

  <section class="card wide">
    <h2>Maintenance</h2>
    <div class="acts">
      <div class="act"><button class="btn primary" data-a="pull">Pull changes</button><span class="sub">Get what changed in Azure DevOps since the last pull and rebuild the report. The everyday button.</span></div>
      <div class="act"><button class="btn" data-a="full">Full refresh</button><span class="sub">Re-read everything from Azure DevOps. Use it if something looks out of date.</span></div>
      <div class="act"><button class="btn" data-a="offline">Rebuild report</button><span class="sub">Rebuild the report from the saved data. No Azure DevOps calls.</span></div>
      <div class="act"><button class="btn" data-a="history">Pull history</button><span class="sub">Fill in the progress-over-time chart from Azure DevOps Analytics for the last <input type="number" id="days" min="1" max="3650" value="180"> days.</span></div>
      <div class="act"><button class="btn danger" data-a="clear">Clear archived data</button><span class="sub">Delete the cache and the daily report copies. The next pull starts from scratch. History and the change log are kept.</span></div>
      <div class="act"><button class="btn danger" data-a="clearall">Clear all data</button><span class="sub">Also delete history.csv and changelog.csv. This can't be undone.</span></div>
    </div>
  </section>

  <section class="card wide">
    <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><h2 style="margin:0">Activity</h2><span id="state" class="badge b-idle">Idle</span><span class="sub" id="elapsed"></span></div>
    <pre id="log">Nothing has run yet. Pick a button above.</pre>
  </section>
</main>
<script>
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const ago = iso => { if (!iso) return 'never'; const s = (Date.now() - Date.parse(iso)) / 1000;
  return s < 90 ? 'just now' : s < 5400 ? Math.round(s / 60) + ' min ago' : s < 129600 ? Math.round(s / 3600) + ' h ago' : Math.round(s / 86400) + ' days ago'; };
const when = iso => iso ? new Date(iso).toLocaleString(undefined, {month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'}) : '';
let S = null, timer = null, lastLog = '', wasRunning = false;

async function api(path, body) {
  const r = await fetch(path, body ? {method: 'POST', headers: {'Content-Type': 'application/json', 'X-AdoMap': '1'}, body: JSON.stringify(body)} : {cache: 'no-store'});
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

function render() {
  const d = S.data, j = S.job, run = j.running;
  $('#who').textContent = (S.org && S.project ? `${S.org} / ${S.project}` : 'Settings not filled in yet') + ' - data folder: ' + S.outDir;
  // Getting started
  const step = (ok, title, detail, action) => `<li><span class="dot${ok ? ' ok' : ''}">${ok ? '&#10003;' : ''}</span><div><b>${title}</b><div class="sub">${detail}</div></div>${action || '<span></span>'}</li>`;
  const settingsOk = !S.todo.length;
  $('#steps').innerHTML =
    step(settingsOk, 'Fill in your settings', settingsOk ? 'Organization, project and token are set.'
      : 'Open <b>run_ado_work_map.cmd</b> in Notepad, fill these in, then start the launch pad again:<ul>' + S.todo.map(t => `<li>${esc(t)}</li>`).join('') + '</ul>') +
    step(S.folders, 'Set up the folders', S.folders ? 'Data folders are ready.' : 'Creates the report, cache and archive folders.',
      S.folders ? '' : `<button class="btn" data-a="setup"${run ? ' disabled' : ''}>Set up</button>`) +
    step(!!d, 'First pull', d ? 'Done ' + ago(d.lastRunUtc) + '.' : 'Pulls everything once. Later pulls only fetch changes.',
      d ? '' : `<button class="btn primary" data-a="pull"${run || !settingsOk ? ' disabled' : ''}>Pull everything</button>`) +
    step(!!S.report, 'Open the report', S.report ? 'Updated ' + ago(S.report.updated) + '.' : 'Appears after the first pull.',
      S.report ? '<a class="btn" href="/report" target="_blank" rel="noopener">Open</a>' : '');
  // Data
  const stat = (k, v) => `<div class="stat"><span class="sub">${k}</span><b>${v}</b></div>`;
  $('#stats').innerHTML = d ? stat('Last pull', ago(d.lastRunUtc)) + stat('Work items', (d.items || 0).toLocaleString()) + stat('Sprints', d.sprints || 0) +
      stat('Pull requests', (d.prs || 0).toLocaleString()) + stat('Changes last pull', (d.changes || 0).toLocaleString()) + stat('API calls last pull', d.apiCalls || 0)
    : '<div class="sub" style="grid-column:1/-1">No data yet. Run the first pull.</div>';
  $('#dataInfo').innerHTML = d ? `Last pull ${when(d.lastRunUtc)} (${esc(d.mode)})` + (S.report ? ` &middot; report ${S.report.kb.toLocaleString()} KB, updated ${when(S.report.updated)}` : '') : '';
  $('#open').style.visibility = S.report ? 'visible' : 'hidden';
  // Buttons
  $$('button[data-a]').forEach(b => { b.disabled = run || (b.dataset.a !== 'setup' && !settingsOk && ['pull', 'full', 'history'].includes(b.dataset.a)); });
  // Activity
  const st = $('#state');
  if (!j.started) { st.className = 'badge b-idle'; st.textContent = 'Idle'; }
  else if (run) { st.className = 'badge b-run'; st.textContent = j.label + ' - running...'; }
  else if (j.exit === 0) { st.className = 'badge b-ok'; st.textContent = j.label + ' - finished'; }
  else { st.className = 'badge b-bad'; st.textContent = j.label + ' - failed' + (j.exit != null ? ` (exit ${j.exit})` : ''); }
  $('#elapsed').textContent = j.started ? (run ? 'started ' : 'ran at ') + when(j.started) : '';
  if (j.started && j.log !== lastLog) {
    const pre = $('#log'), atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
    pre.textContent = j.log || '(no output yet)'; lastLog = j.log;
    if (atEnd || run || wasRunning) pre.scrollTop = pre.scrollHeight;
  }
  wasRunning = run;
}

async function refresh() {
  clearTimeout(timer);
  try { S = await api('/api/status'); render(); timer = setTimeout(refresh, S.job.running ? 1200 : 5000); }
  catch (e) { $('#state').className = 'badge b-bad'; $('#state').textContent = 'Launch pad not reachable'; $('#who').textContent = 'The launch pad window was closed. Start it again to continue.'; }
}

document.addEventListener('click', async e => {
  const b = e.target.closest('button[data-a]'); if (!b || b.disabled) return;
  const a = b.dataset.a;
  if (a === 'clear' && !confirm('Delete the cache and archived reports? The next pull will start from scratch.')) return;
  if (a === 'clearall' && !confirm('Delete ALL saved data, including history.csv and changelog.csv? This cannot be undone.')) return;
  try { const r = await api('/api/run', {action: a, days: +$('#days').value || 180}); if (r.result === 'busy') alert('Something is already running - wait for it to finish.'); }
  catch (err) { alert('Could not start: ' + err.message); }
  lastLog = ''; refresh();
});
$('#stop').onclick = async () => {
  if (S && S.job.running && !confirm('A run is still in progress. Close the launch pad anyway? The run keeps going in the background.')) return;
  try { await api('/api/stop', {}); } catch (e) {}
  document.body.innerHTML = '<p style="font-family:system-ui;padding:24px">The launch pad is closed. Start it again from VS Code or <b>run_ado_work_map.cmd -Serve</b>.</p>';
};
refresh();
</script>
</body>
</html>
'@

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
$CacheDir = Join-Path $OutDir 'cache'
$ArchiveDir = Join-Path $OutDir 'archive'
$HistoryPath = Join-Path $OutDir 'history.csv'
$ChangeLogPath = Join-Path $OutDir 'changelog.csv'
$WiCachePath = Join-Path $CacheDir 'workitems.json'
$PrCachePath = Join-Path $CacheDir 'pullrequests.json'
$MetaPath = Join-Path $CacheDir 'meta.json'
$CommitCachePath = Join-Path $CacheDir 'commits.json'
$script:ApiCalls = 0

if ($Setup) {
    # First-time setup: folders, the starter file, and a check of what still needs filling in
    Write-Host "Setting up ADO Work Map in $ScriptDir"
    foreach ($dir in @($OutDir, $CacheDir, $ArchiveDir)) {
        if (Test-Path $dir) { Write-Host "  ok       $dir" }
        else { [void](New-Item -ItemType Directory -Force -Path $dir); Write-Host "  created  $dir" }
    }
    $starter = Join-Path $ScriptDir 'run_ado_work_map.cmd'
    $example = Join-Path $ScriptDir 'run_ado_work_map.example.cmd'
    if (Test-Path $starter) { Write-Host "  ok       $starter (kept as it is)" }
    elseif (Test-Path $example) { Copy-Item $example $starter; Write-Host "  created  $starter (from run_ado_work_map.example.cmd)" }
    else { Write-Warning "run_ado_work_map.example.cmd is missing - download it again from the repo." }

    $todo = @()
    if (Test-Path $starter) {
        $vals = @{}
        foreach ($line in (Get-Content $starter)) { if ($line -match '^set "ADO_(\w+)=(.*)"\s*$') { $vals[$Matches[1]] = $Matches[2] } }
        if (-not $vals.ORG -or $vals.ORG -eq 'your-org') { $todo += 'ADO_ORG (your organization, the part after dev.azure.com/)' }
        if (-not $vals.PROJECT -or $vals.PROJECT -eq 'Your Project') { $todo += 'ADO_PROJECT' }
        if (-not $vals.PAT_VALUE -and -not $env:ADO_PAT) { $todo += 'ADO_PAT_VALUE (or set an ADO_PAT environment variable, or use az login)' }
    }
    # The starter holds the PAT: make sure git would never pick it up
    if (Test-Path (Join-Path $ScriptDir '.git')) {
        Push-Location $ScriptDir
        try {
            & git check-ignore -q run_ado_work_map.cmd 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host '  ok       run_ado_work_map.cmd is git-ignored' }
            else { Write-Warning 'run_ado_work_map.cmd is NOT git-ignored - add it to .gitignore before you put a PAT in it.' }
        }
        finally { Pop-Location }
    }
    Write-Host "  ok       Windows PowerShell $($PSVersionTable.PSVersion)"
    Write-Host ''
    if ($todo.Count) {
        Write-Host 'Next: open run_ado_work_map.cmd and fill in:'
        $todo | ForEach-Object { Write-Host "  - $_" }
        if ($env:TERM_PROGRAM -eq 'vscode' -and (Get-Command code -ErrorAction SilentlyContinue)) { & code $starter }
    }
    else { Write-Host 'Settings look complete. Run the "ADO Map: Run" task, or double-click run_ado_work_map.cmd.' }
    Write-Host 'Try it without Azure DevOps first: run_ado_work_map.cmd -Demo'
    return
}

if ($Serve) { Start-LaunchPad; return }

if ($ClearArchive) {
    $targets = @($CacheDir, $ArchiveDir)
    if ($IncludeHistory) { $targets += $HistoryPath, $ChangeLogPath }
    foreach ($t in $targets) {
        if (Test-Path $t) { Remove-Item $t -Recurse -Force; Write-Host "Removed $t" } else { Write-Host "Nothing to remove at $t" }
    }
    Write-Host 'Done. The next run pulls everything from Azure DevOps again.'
    return
}

$changeLog = New-Object 'Collections.Generic.List[object]'
$runUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$prevRunUtc = ''

if ($Demo) {
    $Org = 'demo'; $Project = 'Phoenix'
    $BaseUrl = 'https://dev.azure.com/demo'; $ProjUrl = "$BaseUrl/$Project"
    $d = New-DemoData
    $raw = $d.raw; $cats = $d.cats; $iterations = $d.iterations; $repos = $d.repos; $prs = $d.prs
    $demoChanges = $d.changes
    $commitRows = $d.commits
    $prevRunUtc = (Get-Date).ToUniversalTime().AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
}
elseif ($Offline) {
    $wc = Read-JsonFile $WiCachePath
    $meta = Read-JsonFile $MetaPath
    if (-not $wc -or -not $meta) { throw "No saved data in $CacheDir yet - run once without -Offline first." }
    if (-not $Org) { $Org = $meta.org }
    if (-not $Project) { $Project = $meta.project }
    if (-not $PSBoundParameters.ContainsKey('ServerUrl') -and $meta.serverUrl) { $ServerUrl = $meta.serverUrl }
    $BaseUrl = "$($ServerUrl.TrimEnd('/'))/$([uri]::EscapeDataString($Org))"
    $ProjUrl = "$BaseUrl/$([uri]::EscapeDataString($Project))"
    Write-Host "Rebuilding from data pulled $($wc.lastRunUtc) (no Azure DevOps calls)"
    $raw = @($wc.items)
    $cats = ConvertTo-Hashtable $meta.cats
    $iterations = @($meta.iterations); $repos = @($meta.repos)
    $pc = Read-JsonFile $PrCachePath
    $prs = if ($pc) { ConvertTo-Hashtable $pc.prs } else { @{} }
    $cc = Read-JsonFile $CommitCachePath
    $commitRows = if ($cc) { @($cc.rows) } else { @() }
    $runUtc = [string]$wc.lastRunUtc
    $prevRunUtc = [string]$wc.prevRunUtc
}
else {
    if (-not $Org -or -not $Project) { throw 'Pass -Org and -Project (or save them with -SaveConfig, or use -Demo).' }
    $BaseUrl = "$($ServerUrl.TrimEnd('/'))/$([uri]::EscapeDataString($Org))"
    $ProjUrl = "$BaseUrl/$([uri]::EscapeDataString($Project))"
    $script:AuthHeader = Get-AuthHeader
    [void](New-Item -ItemType Directory -Force -Path $CacheDir)

    # Work items: reuse the cache when it was made with the same scope settings
    $signature = "$Org|$Project|$($Types -join ',')|$AreaPath|$($EpicId -join ',')|$([bool]$IncludeRemoved)|$ClosedWithinDays"
    $cache = @{}; $since = $null
    $wc = Read-JsonFile $WiCachePath
    if ($wc -and $wc.version -eq 2 -and $wc.signature -eq $signature) {
        foreach ($ci in $wc.items) { $cache[[int]$ci.id] = $ci }
        $prevRunUtc = [string]$wc.lastRunUtc
        $since = ([datetime]$wc.lastRunUtc).ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
        if ($Full) { Write-Host 'Full refresh - re-reading every work item' }
        else { Write-Host "Pulling changes since $($wc.lastRunUtc) ($($cache.Count) items cached)" }
    }
    elseif ($wc) { Write-Host 'Scope settings changed since the last run - pulling everything' }
    else { Write-Host 'First run - pulling everything (later runs only pull changes)' }

    Sync-WorkItems $cache $since $runUtc $changeLog -FetchAll:$Full
    $raw = @($cache.Values)
    Write-JsonFile $WiCachePath @{ version = 2; signature = $signature; lastRunUtc = $runUtc; prevRunUtc = $prevRunUtc; items = $raw }

    $typeNames = @($raw | ForEach-Object { $_.fields.'System.WorkItemType' } | Where-Object { $_ } | Sort-Object -Unique)
    Write-Host 'Reading state categories, sprints, repos...'
    $cats = Get-StateCategories $typeNames
    $iterations = Get-Iterations
    $repos = Get-Repos

    Write-Host 'Syncing pull request info...'
    $pc = if ($Full) { $null } else { Read-JsonFile $PrCachePath }
    $prs = if ($pc -and $pc.project -eq $Project) { ConvertTo-Hashtable $pc.prs } else { @{} }
    $prSince = if ($pc -and $prs.Count) { ([datetime]$pc.lastRunUtc).ToUniversalTime().AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
    $linked = @((Get-Artifacts $raw) | Where-Object { $_.a.kind -eq 'PR' } | ForEach-Object { [string]$_.a.ident } | Sort-Object -Unique)
    Sync-PullRequests $prs $prSince $linked
    Write-JsonFile $PrCachePath @{ project = $Project; lastRunUtc = $runUtc; prs = $prs }
    Write-JsonFile $MetaPath @{ org = $Org; serverUrl = $ServerUrl; project = $Project; cats = $cats; iterations = $iterations; repos = $repos }

    $commitRows = @()
    if ($CommitDays -gt 0) {
        Write-Host 'Syncing commit counts for the heatmap (dates and authors only)...'
        $cc = if ($Full) { $null } else { Read-JsonFile $CommitCachePath }
        $rowsIn = if ($cc -and $cc.project -eq $Project -and [int]$cc.days -eq $CommitDays) { @($cc.rows) } else { @() }
        $ccSince = if ($rowsIn.Count) { [string]$cc.lastRunUtc } else { $null }
        $commitRows = Sync-Commits $rowsIn $ccSince $repos
        Write-JsonFile $CommitCachePath @{ project = $Project; days = $CommitDays; lastRunUtc = $runUtc; rows = $commitRows }
    }
    Write-Host "  $($script:ApiCalls) Azure DevOps calls this run"

    if ($PullHistory) { Import-AdoHistory $HistoryDays $HistoryPath }
}
if ($PullHistory -and ($Demo -or $Offline)) { Write-Warning '-PullHistory needs a live Azure DevOps connection; skipped.' }

if ($EpicId) { $raw = @($raw | Where-Object { $Types -contains $_.fields.'System.WorkItemType' -or $_.extra }) }

Write-Host 'Building report...'
$sprintInfo = Get-SprintList $iterations $raw
$model = Build-Model $raw $cats $sprintInfo $repos $prs
[void](New-Item -ItemType Directory -Force -Path $OutDir)
Update-History $model $HistoryPath -SeedDemo:$Demo -NoWrite:$Offline
if ($Demo) {
    $model.changes = $demoChanges
}
else {
    Add-ChangeLog $ChangeLogPath $changeLog
    $model.changes = Read-ChangeLog $ChangeLogPath
}
$model.runUtc = $runUtc
$model.prevRunUtc = $prevRunUtc
$model.commits = @{ days = $CommitDays; rows = $commitRows }
$model.demo = [bool]$Demo

$json = ConvertTo-Json -InputObject $model -Depth 12 -Compress
$utf8 = New-Object Text.UTF8Encoding $false
$htmlPath = Join-Path $OutDir 'ado_work_map.html'
[IO.File]::WriteAllText($htmlPath, $HtmlTemplate.Replace('__DATA__', $json.Replace('</', '<\/')), $utf8)
[IO.File]::WriteAllText((Join-Path $OutDir 'ado_work_map.json'), $json, $utf8)
$model.items | ForEach-Object {
    [pscustomobject]@{
        Id = $_.id; Type = $_.type; Title = $_.title; State = $_.state; Status = $_.bucket; AssignedTo = $_.assignee
        Iteration = $_.iteration; Area = $_.area; Parent = $_.parent; Points = $_.points; RemainingWork = $_.remaining
        CompletedWork = $_.completed; InCurrentSprint = $_.inSprint; Created = $_.created; Changed = $_.changed; Closed = $_.closed; Url = $_.url
    }
} | Export-Csv -Path (Join-Path $OutDir 'ado_work_items.csv') -NoTypeInformation -Encoding UTF8

# One archived copy of the report per day
if ($ArchiveDays -gt 0) {
    # The archive is a convenience: if it can't be written (e.g. a very long path), warn and carry on
    try {
        [void](New-Item -ItemType Directory -Force -Path $ArchiveDir)
        Copy-Item $htmlPath (Join-Path $ArchiveDir ('ado_work_map_{0}.html' -f (Get-Date -Format 'yyyy-MM-dd'))) -Force
        Get-ChildItem $ArchiveDir -Filter 'ado_work_map_*.html' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$ArchiveDays) } | Remove-Item -Force
    }
    catch { Write-Warning "Couldn't archive today's report: $($_.Exception.Message)" }
}

# Small summary of this run for the launch pad
if (-not $Demo) {
    [void](New-Item -ItemType Directory -Force -Path $CacheDir)
    Write-JsonFile (Join-Path $CacheDir 'status.json') @{
        lastRunUtc = $runUtc; finishedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode = $(if ($Offline) { 'rebuilt from saved data' } elseif ($Full) { 'full refresh' } else { 'pulled changes' })
        items = @($model.items).Count; sprints = @($model.sprints).Count; prs = $prs.Count
        changes = $changeLog.Count; apiCalls = $script:ApiCalls
    }
}

$inSprint = @($model.items | Where-Object { $_.inSprint }).Count
Write-Host ''
Write-Host "$($model.items.Count) work items, $(@($model.sprints).Count) sprints, $($model.graph.nodes.Count) graph nodes, $($model.graph.edges.Count) edges"
if ($model.sprint) { Write-Host "Current sprint: $($model.sprint.name) ($inSprint items)" }
if (-not $Demo -and -not $Offline) { Write-Host "Changes since last run: $($changeLog.Count)" }
Write-Host "Report: $htmlPath"
if (-not $NoOpen) { Start-Process $htmlPath }
