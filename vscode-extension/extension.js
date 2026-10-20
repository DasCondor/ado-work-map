// ADO Work Map for VS Code: runs the bundled ado_work_map.ps1 (Windows PowerShell 5.1)
// and gives it a home in VS Code - a launch pad in the sidebar, commands, settings,
// a status bar item, and the report in a tab. The token lives in VS Code's secret
// storage and reaches the script through its environment, never its command line.
'use strict';
const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SECRET_KEY = 'adoWorkMap.pat';
let ctx, output, statusItem, homeView, reportPanel, autoTimer;
const job = { proc: null, action: '', label: '', started: null, exit: null, lastLine: '' };

const ACTIONS = {
  pull: { label: 'Pull changes', args: [], needsAdo: true },
  full: { label: 'Full refresh', args: ['-Full'], needsAdo: true },
  rebuild: { label: 'Rebuild report', args: ['-Offline'], needsAdo: false },
  history: { label: 'Pull history', args: ['-PullHistory'], needsAdo: true },
  clear: { label: 'Clear archived data', args: ['-ClearArchive'], needsAdo: false },
  clearAll: { label: 'Clear all data', args: ['-ClearArchive', '-IncludeHistory'], needsAdo: false },
  demo: { label: 'Demo report', args: ['-Demo'], needsAdo: false }
};

// ---------- settings and paths ----------
const cfg = () => vscode.workspace.getConfiguration('adoWorkMap');
// Organization and project, also accepting a pasted address such as
// https://dev.azure.com/<org>/<project> or https://<org>.visualstudio.com
function orgProject() {
  let org = String(cfg().get('organization') || '').trim(), project = String(cfg().get('project') || '').trim();
  if (/^https?:\/\//i.test(org)) {
    try {
      const u = new URL(org), segs = u.pathname.split('/').filter(Boolean).map(decodeURIComponent);
      if (u.hostname === 'dev.azure.com' && segs.length) org = segs.shift();
      else { const m = /^([^.]+)\.visualstudio\.com$/i.exec(u.hostname); if (m) org = m[1]; }
      if (!project && segs.length && !segs[0].startsWith('_')) project = segs[0];
    } catch (e) { }
  }
  return { org: org.replace(/\/+$/, ''), project: project.replace(/\/+$/, '') };
}
function dataDir() {
  const custom = (cfg().get('dataFolder') || '').trim();
  if (custom) return custom;
  const op = orgProject(), name = `${op.org || 'org'}_${op.project || 'project'}`.replace(/[^\w.-]+/g, '_');
  return path.join(ctx.globalStorageUri.fsPath, name);
}
const demoDir = () => path.join(ctx.globalStorageUri.fsPath, 'demo');
const reportPath = demo => path.join(demo ? demoDir() : dataDir(), 'ado_work_map.html');
const scriptPath = () => ctx.asAbsolutePath(path.join('resources', 'ado_work_map.ps1'));
const settingsMissing = () => { const op = orgProject(); return [['organization', op.org], ['project', op.project]].filter(x => !x[1]).map(x => x[0]); };

function buildArgs(action, extra) {
  const c = cfg(), out = action === 'demo' ? demoDir() : dataDir();
  const a = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath(), '-NoOpen',
    '-OutDir', out, '-ConfigPath', path.join(out, 'no-config.json')];
  if (action !== 'demo') {
    const s = (flag, v) => { v = String(v == null ? '' : v).trim(); if (v) a.push(flag, v); };
    const op = orgProject();
    s('-Org', op.org); s('-Project', op.project); s('-Team', c.get('team'));
    s('-Iteration', c.get('iteration')); s('-AreaPath', c.get('areaPath')); s('-EpicId', c.get('epicIds'));
    const server = (c.get('serverUrl') || '').trim();
    if (server && server !== 'https://dev.azure.com') a.push('-ServerUrl', server);
    const types = c.get('workItemTypes');
    if (Array.isArray(types) && types.length) a.push('-Types', types.join(','));
    for (const [flag, key] of [['-HistoryDays', 'historyDays'], ['-CommitDays', 'commitDays'], ['-ArchiveDays', 'archiveDays'], ['-MaxPrDetails', 'maxPrDetails']])
      if (!(extra || []).includes(flag)) a.push(flag, String(c.get(key)));
    if (c.get('closedWithinDays') >= 0) a.push('-ClosedWithinDays', String(c.get('closedWithinDays')));
    if (c.get('includeRemoved')) a.push('-IncludeRemoved');
  }
  return a.concat(ACTIONS[action].args, extra || []);
}

// ---------- running the script ----------
async function run(action, extra) {
  if (process.platform !== 'win32') { vscode.window.showErrorMessage('ADO Work Map needs Windows (it runs Windows PowerShell 5.1).'); return -1; }
  if (job.proc) { vscode.window.showWarningMessage(`ADO Work Map is busy: ${job.label}. Wait for it to finish, or cancel it.`); return -1; }
  const def = ACTIONS[action];
  const env = Object.assign({}, process.env);
  // VS Code may carry a PowerShell 7 module path; Windows PowerShell 5.1 must use its own
  for (const k of Object.keys(env)) if (k.toUpperCase() === 'PSMODULEPATH') delete env[k];
  if (def.needsAdo) {
    const missing = settingsMissing();
    if (missing.length) {
      const pick = await vscode.window.showWarningMessage(`Set your Azure DevOps ${missing.join(' and ')} first.`, 'Open Settings');
      if (pick) openSettings();
      return -1;
    }
    const pat = await ctx.secrets.get(SECRET_KEY);
    if (pat) env.ADO_PAT = pat;
    else if (!env.ADO_PAT && !env.AZURE_DEVOPS_EXT_PAT) {
      const pick = await vscode.window.showWarningMessage('Set your Azure DevOps personal access token first (it is stored securely by VS Code).', 'Set Token');
      if (pick) await setToken();
      const again = await ctx.secrets.get(SECRET_KEY);
      if (!again) return -1;
      env.ADO_PAT = again;
    }
  }
  const out = action === 'demo' ? demoDir() : dataDir();
  fs.mkdirSync(out, { recursive: true });
  output.appendLine(`\n=== ${def.label} - ${new Date().toLocaleString()} ===`);
  Object.assign(job, { action, label: def.label, started: new Date(), exit: null, lastLine: '' });

  return vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: `ADO Work Map: ${def.label}`, cancellable: true }, (progress, token) =>
    new Promise(resolve => {
      const proc = cp.spawn('powershell.exe', buildArgs(action, extra), { env, windowsHide: true });
      job.proc = proc;
      refreshViews();
      token.onCancellationRequested(() => { output.appendLine('Cancelled.'); killJob(); });
      // Keep this run's output next to the data too, for troubleshooting
      const logFile = path.join(out, 'last-run.log');
      try { fs.writeFileSync(logFile, `${def.label} - ${new Date().toISOString()}\n`); } catch (e) { }
      let buf = '';
      const onData = d => {
        const text = d.toString(); output.append(text); buf += text;
        try { fs.appendFileSync(logFile, text); } catch (e) { }
        const lines = buf.split(/\r?\n/); buf = lines.pop();
        const last = lines.map(l => l.trim()).filter(Boolean).pop();
        if (last) { job.lastLine = last; progress.report({ message: last.slice(0, 90) }); postState(); }
      };
      proc.stdout.on('data', onData); proc.stderr.on('data', onData);
      proc.on('error', err => { output.appendLine(`Couldn't start PowerShell: ${err.message}`); });
      proc.on('close', code => {
        job.proc = null; job.exit = code;
        refreshViews();
        if (code === 0) {
          if (['pull', 'full', 'rebuild', 'history'].includes(action)) {
            vscode.window.showInformationMessage(`ADO Work Map: ${def.label} finished.`, 'Open Report').then(p => { if (p) openReport(); });
            if (reportPanel && !reportPanel.demo) loadReportInto(reportPanel, false);
          } else if (action === 'demo') openReport(true);
          else vscode.window.showInformationMessage(`ADO Work Map: ${def.label} finished.`);
        } else if (code != null) {
          vscode.window.showErrorMessage(`ADO Work Map: ${def.label} failed${job.lastLine ? ' - ' + job.lastLine : ''}`, 'Show Log').then(p => { if (p) output.show(); });
        }
        resolve(code);
      });
    }));
}
function killJob() { if (job.proc) { try { cp.spawn('taskkill', ['/pid', String(job.proc.pid), '/T', '/F'], { windowsHide: true }); } catch (e) { job.proc.kill(); } } }

// ---------- token ----------
async function setToken(value) {
  if (typeof value !== 'string') {
    value = await vscode.window.showInputBox({
      title: 'Azure DevOps personal access token', password: true, ignoreFocusOut: true,
      prompt: 'Read-only scopes are enough: Work Items, Code, Project and Team, Build, and Analytics (for history). Stored in VS Code secret storage.'
    });
  }
  if (!value) return;
  await ctx.secrets.store(SECRET_KEY, value.trim());
  vscode.window.showInformationMessage('ADO Work Map: token saved to VS Code secret storage.');
  postState();
}
async function clearToken() { await ctx.secrets.delete(SECRET_KEY); vscode.window.showInformationMessage('ADO Work Map: token removed.'); postState(); }
const openSettings = () => vscode.commands.executeCommand('workbench.action.openSettings', '@ext:DasCondor.ado-work-map');

// ---------- report ----------
async function openReport(demo, where) {
  const file = reportPath(!!demo);
  if (!fs.existsSync(file)) {
    const pick = await vscode.window.showInformationMessage('No report yet. Pull your data first, or open the demo report.', 'Pull Changes', 'Open Demo');
    if (pick === 'Pull Changes') run('pull'); else if (pick === 'Open Demo') run('demo');
    return;
  }
  if ((where || cfg().get('openReportIn')) === 'browser') { vscode.env.openExternal(vscode.Uri.file(file)); return; }
  if (reportPanel) { reportPanel.reveal(); }
  else {
    reportPanel = vscode.window.createWebviewPanel('adoWorkMap.report', 'ADO Work Map', vscode.ViewColumn.Active, { enableScripts: true, retainContextWhenHidden: true });
    reportPanel.iconPath = vscode.Uri.file(ctx.asAbsolutePath('media/icon.png'));
    reportPanel.onDidDispose(() => { reportPanel = null; });
    reportPanel.webview.onDidReceiveMessage(m => { if (m && m.type === 'open' && /^https:\/\//.test(m.url)) vscode.env.openExternal(vscode.Uri.parse(m.url)); });
  }
  loadReportInto(reportPanel, !!demo);
}
function loadReportInto(panel, demo) {
  panel.demo = demo;
  panel.title = demo ? 'ADO Work Map (demo)' : `ADO Work Map - ${orgProject().project}`;
  const html = fs.readFileSync(reportPath(demo), 'utf8');
  // The report is self-contained: allow only its own inline code, and send external links to the browser
  const csp = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline';">`;
  const bridge = `<script>(function(){const api=acquireVsCodeApi();const go=u=>api.postMessage({type:'open',url:u});
document.addEventListener('click',e=>{const a=e.target.closest&&e.target.closest('a[href^="https://"]');if(a&&!e.defaultPrevented){e.preventDefault();go(a.href);}});
if(!(typeof D!=='undefined'&&D.demo))window.open=u=>{if(u&&/^https:/.test(u))go(u);return null;};})();</script>`;
  panel.webview.html = html.replace('<head>', '<head>' + csp).replace('</body>', bridge + '</body>');
}

// ---------- status ----------
function readStatus() {
  const dir = dataDir(), st = path.join(dir, 'cache', 'status.json'), rep = reportPath(false);
  let data = null, report = null;
  try { data = JSON.parse(fs.readFileSync(st, 'utf8').replace(/^\uFEFF/, '')); } catch (e) { }
  try { const s = fs.statSync(rep); report = { updated: s.mtime.toISOString(), kb: Math.round(s.size / 1024) }; } catch (e) { }
  return { data, report, dir };
}
function ago(iso) {
  if (!iso) return 'never';
  const s = (Date.now() - Date.parse(iso)) / 1000;
  return s < 90 ? 'just now' : s < 5400 ? Math.round(s / 60) + ' min ago' : s < 129600 ? Math.round(s / 3600) + ' h ago' : Math.round(s / 86400) + ' days ago';
}
async function state() {
  const st = readStatus(), c = cfg();
  return {
    org: orgProject().org, project: orgProject().project, missing: settingsMissing(),
    token: !!(await ctx.secrets.get(SECRET_KEY)) || !!process.env.ADO_PAT,
    data: st.data, report: st.report, dir: st.dir, historyDays: c.get('historyDays'),
    job: { running: !!job.proc, label: job.label, exit: job.exit, started: job.started && job.started.toISOString(), lastLine: job.lastLine }
  };
}
function refreshViews() { updateStatusBar(); postState(); }
async function postState() { if (homeView) homeView.webview.postMessage({ type: 'state', state: await state() }); }
function updateStatusBar() {
  const st = readStatus();
  if (job.proc) { statusItem.text = `$(sync~spin) ADO: ${job.label}...`; statusItem.tooltip = 'ADO Work Map is working - click to show the log'; statusItem.command = 'adoWorkMap.showLog'; }
  else if (st.data) { statusItem.text = `$(graph) ADO: ${ago(st.data.lastRunUtc)}`; statusItem.tooltip = `ADO Work Map - last pull ${new Date(st.data.lastRunUtc).toLocaleString()}\nClick to pull changes`; statusItem.command = 'adoWorkMap.pull'; }
  else { statusItem.text = '$(graph) ADO Work Map'; statusItem.tooltip = 'Set up ADO Work Map'; statusItem.command = 'workbench.view.extension.adoWorkMap'; }
  statusItem.show();
}
function scheduleAutoPull() {
  if (autoTimer) clearInterval(autoTimer);
  const m = cfg().get('autoPullMinutes');
  if (m > 0) autoTimer = setInterval(() => { if (!job.proc && !settingsMissing().length) run('pull'); }, m * 60000);
}

// ---------- sidebar launch pad ----------
class HomeProvider {
  resolveWebviewView(view) {
    homeView = view;
    view.webview.options = { enableScripts: true };
    view.webview.html = homeHtml(view.webview);
    view.webview.onDidReceiveMessage(async m => {
      switch (m.cmd) {
        case 'ready': postState(); break;
        case 'run':
          if ((m.action === 'clear' || m.action === 'clearAll') &&
              (await vscode.window.showWarningMessage(m.action === 'clear' ? 'Delete the cache and archived reports? The next pull starts from scratch.' : 'Delete ALL saved data, including history and the change log? This cannot be undone.', { modal: true }, 'Delete')) !== 'Delete') return;
          run(m.action, m.action === 'history' ? ['-HistoryDays', String(Math.max(1, +m.days || 180))] : undefined); break;
        case 'openReport': openReport(false); break;
        case 'openReportBrowser': openReport(false, 'browser'); break;
        case 'demo': run('demo'); break;
        case 'setToken': setToken(); break;
        case 'settings': openSettings(); break;
        case 'log': output.show(); break;
        case 'cancel': killJob(); break;
        case 'folder': vscode.env.openExternal(vscode.Uri.file(dataDir())); break;
      }
    });
    view.onDidChangeVisibility(() => { if (view.visible) postState(); });
  }
}
function homeHtml(webview) {
  const nonce = crypto.randomBytes(16).toString('base64');
  return `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
body{font:13px var(--vscode-font-family);color:var(--vscode-foreground);padding:4px 8px 12px}
h3{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:var(--vscode-descriptionForeground);margin:14px 0 6px}
.step{display:grid;grid-template-columns:18px 1fr;gap:6px;margin:6px 0}
.dot{width:14px;height:14px;border-radius:50%;border:1.5px solid var(--vscode-descriptionForeground);margin-top:2px;font-size:10px;line-height:14px;text-align:center}
.dot.ok{background:var(--vscode-testing-iconPassed,#3fb950);border-color:transparent;color:#fff}
.sub{color:var(--vscode-descriptionForeground);font-size:12px}
button{display:block;width:100%;margin:5px 0;padding:5px 8px;border:1px solid var(--vscode-button-border,transparent);border-radius:2px;cursor:pointer;font:inherit;text-align:center;
  background:var(--vscode-button-secondaryBackground);color:var(--vscode-button-secondaryForeground)}
button:hover{background:var(--vscode-button-secondaryHoverBackground)}
button.primary{background:var(--vscode-button-background);color:var(--vscode-button-foreground)}
button.primary:hover{background:var(--vscode-button-hoverBackground)}
button.danger{color:var(--vscode-errorForeground)}
button[disabled]{opacity:.5;cursor:default}
.link{background:none;border:0;padding:0;margin:2px 0 0;width:auto;display:inline;color:var(--vscode-textLink-foreground);text-align:left}
.link:hover{background:none;text-decoration:underline}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.stat{border:1px solid var(--vscode-panel-border,rgba(128,128,128,.3));border-radius:3px;padding:4px 7px}
.stat b{display:block;font-size:15px}
.row{display:flex;gap:6px;align-items:center}
input{width:56px;background:var(--vscode-input-background);color:var(--vscode-input-foreground);border:1px solid var(--vscode-input-border,transparent);padding:2px 4px}
.job{border-left:3px solid var(--vscode-progressBar-background);padding:4px 8px;margin-top:6px;word-break:break-word}
.job.bad{border-color:var(--vscode-errorForeground)} .job.ok{border-color:var(--vscode-testing-iconPassed,#3fb950)}
</style></head><body>
<div id="root"></div>
<script nonce="${nonce}">
const vscode = acquireVsCodeApi();
const send = (cmd, extra) => vscode.postMessage(Object.assign({cmd}, extra || {}));
const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const ago = iso => { if (!iso) return 'never'; const s = (Date.now() - Date.parse(iso)) / 1000;
  return s < 90 ? 'just now' : s < 5400 ? Math.round(s / 60) + ' min ago' : s < 129600 ? Math.round(s / 3600) + ' h ago' : Math.round(s / 86400) + ' days ago'; };
let days = 180;
function render(S) {
  const run = S.job.running, ready = !S.missing.length && S.token, d = S.data;
  const step = (ok, title, detail, btn) => '<div class="step"><span class="dot' + (ok ? ' ok' : '') + '">' + (ok ? '&#10003;' : '') + '</span><div><b>' + title + '</b><div class="sub">' + detail + '</div>' + (btn || '') + '</div></div>';
  const b = (cmd, label, cls, extra) => '<button class="' + (cls || '') + '" data-cmd="' + cmd + '"' + (extra || '') + (run && cmd === 'run' ? ' disabled' : '') + '>' + label + '</button>';
  let h = '<h3>Getting started</h3>' +
    step(!S.missing.length, 'Organization and project', S.missing.length ? 'Not set yet.' : esc(S.org) + ' / ' + esc(S.project), S.missing.length ? '<button class="link" data-cmd="settings">Open settings</button>' : '') +
    step(S.token, 'Personal access token', S.token ? 'Stored securely by VS Code.' : 'Read-only access is enough.', '<button class="link" data-cmd="setToken">' + (S.token ? 'Replace token' : 'Set token') + '</button>') +
    step(!!d, 'First pull', d ? 'Done ' + ago(d.lastRunUtc) + '.' : 'Pulls everything once; later pulls only fetch changes.') +
    step(!!S.report, 'Open the report', S.report ? 'Updated ' + ago(S.report.updated) + '.' : 'Appears after the first pull.');
  if (d) h += '<h3>Your data</h3><div class="stats">' +
    [['Last pull', ago(d.lastRunUtc)], ['Work items', (d.items || 0).toLocaleString()], ['Sprints', d.sprints || 0], ['Pull requests', (d.prs || 0).toLocaleString()], ['Changes', d.changes || 0], ['API calls', d.apiCalls || 0]]
      .map(([k, v]) => '<div class="stat"><span class="sub">' + k + '</span><b>' + v + '</b></div>').join('') + '</div>';
  h += '<h3>Report</h3>' + b('openReport', 'Open report', S.report ? 'primary' : '', S.report ? '' : ' disabled') +
    b('openReportBrowser', 'Open in browser', '', S.report ? '' : ' disabled') +
    (S.report ? '' : b('demo', 'Open demo report'));
  h += '<h3>Data</h3>' +
    b('run', 'Pull changes', 'primary', ' data-action="pull"' + (ready ? '' : ' disabled')) +
    b('run', 'Full refresh', '', ' data-action="full"' + (ready ? '' : ' disabled')) +
    b('run', 'Rebuild report', '', ' data-action="rebuild"' + (d ? '' : ' disabled')) +
    '<div class="row">' + b('run', 'Pull history', '', ' data-action="history"' + (ready ? '' : ' disabled')) + '<input id="days" type="number" min="1" value="' + days + '"><span class="sub">days</span></div>' +
    b('run', 'Clear archived data', 'danger', ' data-action="clear"') +
    b('run', 'Clear all data', 'danger', ' data-action="clearAll"');
  const j = S.job;
  if (j.label) h += '<h3>Activity</h3><div class="job ' + (j.running ? '' : j.exit === 0 ? 'ok' : 'bad') + '"><b>' + esc(j.label) + '</b> - ' +
    (j.running ? 'running...' : j.exit === 0 ? 'finished' : 'failed') + '<div class="sub">' + esc(j.lastLine) + '</div></div>' +
    (j.running ? b('cancel', 'Cancel') : '') + '<button class="link" data-cmd="log">Show log</button>';
  h += '<h3>More</h3><button class="link" data-cmd="settings">Settings</button> &middot; <button class="link" data-cmd="folder">Data folder</button>';
  document.getElementById('root').innerHTML = h;
  const di = document.getElementById('days'); if (di) di.oninput = e => days = +e.target.value || 180;
}
document.addEventListener('click', e => { const el = e.target.closest('[data-cmd]'); if (!el || el.disabled) return;
  send(el.dataset.cmd, el.dataset.action ? {action: el.dataset.action, days} : {}); });
window.addEventListener('message', e => { if (e.data.type === 'state') { days = e.data.state.historyDays || days; render(e.data.state); } });
send('ready');
</script></body></html>`;
}

// ---------- activation ----------
function activate(context) {
  ctx = context;
  output = vscode.window.createOutputChannel('ADO Work Map');
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  context.subscriptions.push(output, statusItem,
    vscode.window.registerWebviewViewProvider('adoWorkMap.home', new HomeProvider(), { webviewOptions: { retainContextWhenHidden: true } }),
    vscode.commands.registerCommand('adoWorkMap.pull', () => run('pull')),
    vscode.commands.registerCommand('adoWorkMap.fullRefresh', () => run('full')),
    vscode.commands.registerCommand('adoWorkMap.rebuild', () => run('rebuild')),
    vscode.commands.registerCommand('adoWorkMap.pullHistory', async days => {
      if (days == null) {
        const v = await vscode.window.showInputBox({ title: 'Pull history', prompt: 'How many days of history to pull from Azure DevOps Analytics', value: String(cfg().get('historyDays')), validateInput: x => /^\d+$/.test(x) && +x > 0 ? null : 'Enter a number of days' });
        if (!v) return;
        days = +v;
      }
      return run('history', ['-HistoryDays', String(days)]);
    }),
    vscode.commands.registerCommand('adoWorkMap.clearArchive', async force => {
      if (force !== true && (await vscode.window.showWarningMessage('Delete the cache and archived reports? The next pull starts from scratch.', { modal: true }, 'Delete')) !== 'Delete') return;
      return run('clear');
    }),
    vscode.commands.registerCommand('adoWorkMap.clearAll', async force => {
      if (force !== true && (await vscode.window.showWarningMessage('Delete ALL saved data, including history and the change log? This cannot be undone.', { modal: true }, 'Delete')) !== 'Delete') return;
      return run('clearAll');
    }),
    vscode.commands.registerCommand('adoWorkMap.openReport', () => openReport(false)),
    vscode.commands.registerCommand('adoWorkMap.openReportInBrowser', () => openReport(false, 'browser')),
    vscode.commands.registerCommand('adoWorkMap.demo', () => run('demo')),
    vscode.commands.registerCommand('adoWorkMap.setToken', v => setToken(v)),
    vscode.commands.registerCommand('adoWorkMap.clearToken', clearToken),
    vscode.commands.registerCommand('adoWorkMap.openSettings', openSettings),
    vscode.commands.registerCommand('adoWorkMap.showLog', () => output.show()),
    vscode.commands.registerCommand('adoWorkMap.openDataFolder', () => { fs.mkdirSync(dataDir(), { recursive: true }); vscode.env.openExternal(vscode.Uri.file(dataDir())); }),
    vscode.commands.registerCommand('adoWorkMap.cancel', killJob),
    // for scripts and tests: where things are, and what the last run did
    vscode.commands.registerCommand('adoWorkMap._info', async () => ({ dataDir: dataDir(), demoDir: demoDir(), report: reportPath(false), state: await state() })),
    vscode.workspace.onDidChangeConfiguration(e => { if (e.affectsConfiguration('adoWorkMap')) { scheduleAutoPull(); refreshViews(); } }),
    { dispose: () => { if (autoTimer) clearInterval(autoTimer); killJob(); } }
  );
  updateStatusBar();
  const tick = setInterval(updateStatusBar, 60000);   // keeps "x min ago" current
  context.subscriptions.push({ dispose: () => clearInterval(tick) });
  scheduleAutoPull();
  if (cfg().get('pullOnStartup') && !settingsMissing().length) setTimeout(() => run('pull'), 5000);
}
function deactivate() { killJob(); }
module.exports = { activate, deactivate };
