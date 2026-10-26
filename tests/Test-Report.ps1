<#
.SYNOPSIS
    Build the demo report with the script and check it in headless Edge: the page script runs, and the
    Needs attention checks find what the demo data was given to find.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\Test-Report.ps1 [-Script report\ado_work_map.ps1]
#>
param([string]$Script)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
if (-not $Script) { $Script = @((Join-Path $repo 'report\ado_work_map.ps1'), (Join-Path $repo 'ado_work_map.ps1')) | Where-Object { Test-Path $_ } | Select-Object -First 1 }
$out = Join-Path ([IO.Path]::GetTempPath()) ('adomap_reporttest_' + [guid]::NewGuid().ToString('N'))
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -Demo -NoOpen -OutDir $out | Out-Null
    $html = [IO.File]::ReadAllText((Join-Path $out 'ado_work_map.html'))
    # Run the checks after the report's own script, and write the results into the page
    $probe = @'
<pre id="probe"></pre><script>
(function () {
  const r = [], ok = (c, what) => r.push((c ? 'pass  ' : 'FAIL  ') + what);
  try {
    ok(typeof D === 'object' && D.items.length > 0, 'the report script runs and has data');
    ok(curIdx >= 0, 'there is a current sprint (or the next one, between sprints)');
    const res = Object.fromEntries(attnFindings().map(x => [x.c.id, x]));
    for (const id of ['unassigned', 'blocked', 'past', 'estimate', 'ac', 'orphan']) ok(res[id] && !res[id].skip && res[id].items.length > 0, 'Needs attention finds the demo case for: ' + id);
    ok(res.orphan.items.every(i => i.parent == null && i.kind !== 'Bug'), 'stories without a parent really have none');
    ok(res.unassigned.items.every(i => !i.assignee && i.sp === curIdx), 'unassigned items are unassigned and in the current sprint');
    const word = D.sprint.timeFrame === 'future' ? 'upcoming' : 'current';
    ok(document.querySelector('#meta').textContent.includes(word + ' sprint: ' + D.sprint.name), `the header calls ${D.sprint.name} the ${word} sprint`);
    ok(document.querySelector('#nav, nav') && ATTN[0].name.includes(word), 'the checks use the same word');
    const est = () => attnFindings().find(x => x.c.id === 'estimate');
    pointed = 0;   // as if no story in a sprint had points
    ok(attnCfg.estimate === 'auto' && /Skipped \(Auto\): 0 of \d+ stories/.test(est().skip || ''), 'Auto skips the estimate check, saying why');
    attnCfg.estimate = 'always'; ok(!est().skip && est().items.length > 0, 'Always runs it anyway');
    attnCfg.off.ac = true; ok(!attnFindings().some(x => x.c.id === 'ac'), 'a check can be turned off');
    // Experimental maps: each draws from the demo data, and one failing leaves the rest working
    const xb = () => document.getElementById('xbody');
    ok(typeof renderLab === 'function', 'the experimental maps script loads');
    for (const k of Object.keys(labMaps)) { store.set('labView', k); renderLab();
      ok(!xb().querySelector('.xfail') && /<(table|svg)/.test(xb().innerHTML), 'experimental map draws from the demo data: ' + k); }
    const keep = labMaps.deps.draw; labMaps.deps.draw = () => { throw new Error('test failure'); };
    store.set('labView', 'deps'); renderLab(); ok(/Dependencies couldn't be drawn/.test(xb().textContent), 'a failing map says so in its place');
    store.set('labView', 'aging'); renderLab(); ok(!xb().querySelector('.xfail'), 'the other maps still draw');
    labMaps.deps.draw = keep;
    const keepC = renderChanges; renderChanges = () => { throw new Error('test failure'); };
    document.getElementById('kpis').innerHTML = ''; renderAll(); renderChanges = keepC;
    ok(document.getElementById('kpis').innerHTML !== '' && document.getElementById('abody').innerHTML !== '', 'one view failing leaves the others drawn');
    showTab('lab'); delete window.renderLab; showTab('map'); showTab('lab'); ok(true, 'the report works without the experimental script'); showTab('attention');
    F.person = ['nobody at all']; ok(attnFindings().every(x => !x.items.length), 'filters apply to the checks');
  } catch (e) { r.push('FAIL  ' + e.message); }
  document.getElementById('probe').textContent = r.join('\n');
})();
</script></body>
'@
    $at = $html.LastIndexOf('</body>')
    [IO.File]::WriteAllText((Join-Path $out 'probe.html'), $html.Substring(0, $at) + $probe + $html.Substring($at + 7), (New-Object Text.UTF8Encoding $false))
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $ErrorActionPreference = 'Continue'   # Edge writes harmless noise to stderr
    $dom = & $edge --headless=new --disable-gpu --no-first-run "--user-data-dir=$(Join-Path $out 'edge')" --virtual-time-budget=10000 --dump-dom ('file:///' + ($out -replace '\\', '/') + '/probe.html') 2>$null | Out-String
    $text = [Net.WebUtility]::HtmlDecode([regex]::Match($dom, '<pre id="probe">([\s\S]*?)</pre>').Groups[1].Value)
    if (-not $text) { $text = 'FAIL  the checks did not run (the report script probably has a syntax error)' }
    Write-Host $text
    if ($text -cmatch '(?m)^FAIL') { exit 1 } else { Write-Host 'All passed' }
}
finally { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
