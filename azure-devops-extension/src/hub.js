// ADO Work Map - Azure DevOps hub (Boards > Work Map).
//
// Pulls work items, sprints, repos, pull request info and commit counts with the signed-in
// user's own access (no PAT), keeps them in this browser (IndexedDB) so later visits only pull
// what changed, and renders the same report as ado_work_map.ps1 (report.js is generated from
// the script's report template by build.ps1).
//
// Like the script, it reads metadata only: no file contents, diffs or code are ever downloaded.
import * as SDK from './sdk/SDK.min.js';

const API = '7.1';
const DEFAULT_TYPES = ['Epic', 'Feature', 'User Story', 'Technical Story', 'Product Backlog Item', 'Requirement', 'Bug', 'Task'];
const STORY_TYPES = ['User Story', 'Technical Story', 'Product Backlog Item', 'Requirement'];
const LEVELS = {Epic: 0, Feature: 1, 'User Story': 2, 'Technical Story': 2, 'Product Backlog Item': 2, Requirement: 2, Bug: 2, Task: 3};
const TYPE_COLORS = {
  Epic: '#e06c00', Feature: '#773b93', Story: '#009ccc', Tech: '#2a9d8f', Bug: '#cc293d', Task: '#c99a06', Other: '#8a8a8a',
  Repo: '#475569', PR: '#0d9488', Commit: '#94a3b8', Branch: '#2563eb', Build: '#a16207'
};
const CACHE_FIELDS = ['System.WorkItemType', 'System.State', 'System.IterationPath', 'System.Title', 'System.AssignedTo', 'System.AreaPath',
  'System.Tags', 'System.CreatedDate', 'System.ChangedDate', 'Microsoft.VSTS.Common.ClosedDate',
  'Microsoft.VSTS.Scheduling.StoryPoints', 'Microsoft.VSTS.Scheduling.Effort',
  'Microsoft.VSTS.Scheduling.RemainingWork', 'Microsoft.VSTS.Scheduling.CompletedWork', 'Microsoft.VSTS.Common.AcceptanceCriteria',
  'Microsoft.VSTS.Common.ActivatedDate', 'System.BoardLane', 'System.BoardColumn'];
// Story date fields: the defaults, or the ones picked in the report's Settings (team settings below)
let dateFields = ['Microsoft.VSTS.Scheduling.StartDate', 'Microsoft.VSTS.Scheduling.TargetDate'];
const CACHE_RELS = ['System.LinkTypes.Hierarchy-Reverse', 'System.LinkTypes.Related', 'System.LinkTypes.Dependency-Forward', 'ArtifactLink'];
const MAX_CHANGES = 20000;

const $ = s => document.querySelector(s);
const nowIso = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const minusMinutes = (iso, m) => new Date(Date.parse(iso) - m * 6e4).toISOString().replace(/\.\d+Z$/, 'Z');
const ymd = d => d.toISOString().slice(0, 10);
const pad = n => String(n).padStart(2, '0');

let ctx = null;       // org, project, projectId, team, baseUrl, projUrl
let calls = 0;

// ---------------------------------------------------------------- status / log
function step(msg) {
  $('#hub-step').textContent = msg;
  $('#hub-status').textContent = msg;
  log(msg);
}
function log(msg) {
  const el = $('#hub-log');
  el.textContent += msg + '\n';
  el.scrollTop = el.scrollHeight;
}

// ---------------------------------------------------------------- settings (per project, this browser)
const settingsKey = () => `adomap.hub.${ctx.org}.${ctx.projectId}.settings`;
function readSettings() {
  let s = {};
  try { s = JSON.parse(localStorage.getItem(settingsKey()) || '{}'); } catch (e) {}
  return {
    team: s.team || '',
    areaPath: s.areaPath || '',
    types: Array.isArray(s.types) && s.types.length ? s.types : DEFAULT_TYPES,
    epicIds: Array.isArray(s.epicIds) ? s.epicIds : [],
    closedWithinDays: Number.isFinite(s.closedWithinDays) ? s.closedWithinDays : -1,
    includeRemoved: !!s.includeRemoved,
    commitDays: Number.isFinite(s.commitDays) ? s.commitDays : 365,
    maxPrDetails: Number.isFinite(s.maxPrDetails) ? s.maxPrDetails : 200
  };
}
function writeSettings(s) {
  try { localStorage.setItem(settingsKey(), JSON.stringify(s)); } catch (e) {}
}

// ---------------------------------------------------------------- team settings (one per project, shared by everyone)
// Status flows, swim lanes and story dates, set in the report's Settings tab. Sprint planning reads them too.
const TEAM_SETTINGS = 'report-settings';   // extension data collection; the document id is the project id
let teamSet = null;
async function dataManager() {
  const svc = await SDK.getService('ms.vss-features.extension-data-service');
  return svc.getExtensionDataManager(SDK.getExtensionContext().id, await SDK.getAccessToken());
}
async function loadTeamSettings() {
  try { const doc = await (await dataManager()).getDocument(TEAM_SETTINGS, ctx.projectId); teamSet = doc && doc.settings || null; }
  catch (e) { teamSet = null; }   // none saved yet: the report uses its defaults
  const d = teamSet && teamSet.dates || {};
  dateFields = [String(d.start || '').trim() || dateFields[0], String(d.end || '').trim() || dateFields[1]];
}
window.reportHost = {where: 'project', async saveSettings(s) {
  const m = await dataManager(); let cur = null;
  try { cur = await m.getDocument(TEAM_SETTINGS, ctx.projectId); } catch (e) {}
  const doc = {id: ctx.projectId, settings: s};
  if (cur) await m.setDocument(TEAM_SETTINGS, Object.assign(doc, {__etag: cur.__etag})); else await m.createDocument(TEAM_SETTINGS, doc);
  teamSet = s;
}};

// ---------------------------------------------------------------- saved data (IndexedDB)
const store = (() => {
  let opened;
  const open = () => opened || (opened = new Promise((resolve, reject) => {
    const r = indexedDB.open('adomap', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('kv');
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  }));
  const run = (mode, fn) => open().then(db => new Promise((resolve, reject) => {
    const t = db.transaction('kv', mode), req = fn(t.objectStore('kv'));
    t.oncomplete = () => resolve(req && req.result);
    t.onerror = t.onabort = () => reject(t.error);
  }));
  // Saving is a convenience: if the browser blocks storage, everything still works for this visit
  const safe = p => p.catch(e => { log('(browser storage unavailable: ' + (e && e.message || e) + ')'); return undefined; });
  return {
    get: k => safe(run('readonly', s => s.get(k))),
    set: (k, v) => safe(run('readwrite', s => s.put(v, k))),
    del: k => safe(run('readwrite', s => s.delete(k)))
  };
})();
const key = name => `${ctx.org}|${ctx.projectId}|${name}`;
const SAVED = ['wi', 'meta', 'prs', 'commits', 'changes', 'history'];

// ---------------------------------------------------------------- REST
async function api(url, {method = 'GET', body, query, noVersion} = {}) {
  const q = [];
  if (!noVersion) q.push('api-version=' + API);
  if (query) for (const [k, v] of Object.entries(query)) q.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
  const full = q.length ? url + (url.includes('?') ? '&' : '?') + q.join('&') : url;
  for (let attempt = 0; ; attempt++) {
    const token = await SDK.getAccessToken();
    calls++;
    const headers = {Authorization: 'Bearer ' + token, Accept: 'application/json'};
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    let r;
    try { r = await fetch(full, {method, headers, body: body !== undefined ? JSON.stringify(body) : undefined}); }
    catch (e) { if (attempt < 2) continue; throw new Error(`${method} ${url.split('?')[0]}: ${e.message}`); }
    if ((r.status === 429 || r.status === 503) && attempt < 4) {
      const wait = Math.min(30, Number(r.headers.get('Retry-After')) || 2 * (attempt + 1));
      log(`  Azure DevOps asked to slow down - waiting ${wait}s`);
      await new Promise(res => setTimeout(res, wait * 1000));
      continue;
    }
    if (!r.ok) {
      let detail = '';
      try { const t = await r.text(); try { detail = JSON.parse(t).message || t; } catch (e) { detail = t; } } catch (e) {}
      const err = new Error(`${method} ${url.split('?')[0]} failed (${r.status}): ${String(detail).slice(0, 300)}`);
      err.status = r.status;
      throw err;
    }
    return r.status === 204 ? null : r.json();
  }
}

// Runs fn over items, n at a time
async function pool(items, n, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(Array.from({length: Math.min(n, items.length)}, async () => {
    while (i < items.length) { const k = i++; out[k] = await fn(items[k], k); }
  }));
  return out;
}
const chunks = (list, size) => { const out = []; for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size)); return out; };

// ---------------------------------------------------------------- work items
const wq = s => String(s).replace(/'/g, "''");

async function scopeIds(S, changedSince) {
  if (S.epicIds.length) {
    const wiql = `SELECT [System.Id] FROM WorkItemLinks WHERE [Source].[System.Id] IN (${S.epicIds.join(',')}) ` +
      `AND [System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward' MODE (Recursive)`;
    const res = await api(`${ctx.projUrl}/_apis/wit/wiql`, {method: 'POST', body: {query: wiql}});
    const ids = new Set(S.epicIds);
    for (const rel of res.workItemRelations || []) {
      if (rel.source) ids.add(rel.source.id);
      if (rel.target) ids.add(rel.target.id);
    }
    return [...ids].sort((a, b) => a - b);
  }
  const where = ['[System.TeamProject] = @project', `[System.WorkItemType] IN (${S.types.map(t => `'${wq(t)}'`).join(', ')})`];
  if (!S.includeRemoved) where.push("[System.State] <> 'Removed'");
  if (S.areaPath) where.push(`[System.AreaPath] UNDER '${wq(S.areaPath)}'`);
  if (S.closedWithinDays >= 0) {
    const since = ymd(new Date(Date.now() - S.closedWithinDays * 864e5));
    where.push(`([Microsoft.VSTS.Common.ClosedDate] = '' OR [Microsoft.VSTS.Common.ClosedDate] >= '${since}')`);
  }
  if (changedSince) where.push(`[System.ChangedDate] >= '${changedSince}'`);
  const wiql = `SELECT [System.Id] FROM WorkItems WHERE ${where.join(' AND ')} ORDER BY [System.Id]`;
  const res = await api(`${ctx.projUrl}/_apis/wit/wiql`, {method: 'POST', body: {query: wiql}, query: {timePrecision: 'true'}});
  return (res.workItems || []).map(w => w.id);
}

async function getWorkItems(ids, label) {
  const out = [];
  let done = 0;
  await pool(chunks(ids, 200), 4, async chunk => {
    const res = await api(`${ctx.projUrl}/_apis/wit/workitemsbatch`, {method: 'POST', body: {ids: chunk, $expand: 'Relations', errorPolicy: 'Omit'}});
    for (const w of res.value || []) if (w) out.push(w);
    done += chunk.length;
    step(`${label || 'Fetching work items'}: ${done.toLocaleString()} / ${ids.length.toLocaleString()}`);
  });
  return out;
}

async function getRevisions(ids) {
  const revs = new Map();
  await pool(chunks(ids, 200), 4, async chunk => {
    const res = await api(`${ctx.projUrl}/_apis/wit/workitemsbatch`, {method: 'POST', body: {ids: chunk, fields: ['System.Id', 'System.Rev'], errorPolicy: 'Omit'}});
    for (const v of res.value || []) if (v) revs.set(v.id, v.rev);
  });
  return revs;
}

// Keep only the fields and links the report uses
function toCacheItem(w) {
  const f = {};
  for (const k of [...new Set(CACHE_FIELDS.concat(dateFields))]) {
    let v = (w.fields || {})[k];
    if (v == null) continue;
    if (k === 'System.AssignedTo') v = {displayName: String(v.displayName || '')};
    else if (k === 'Microsoft.VSTS.Common.AcceptanceCriteria') { if (!String(v).replace(/<[^>]*>|&nbsp;/g, '').trim()) continue; v = 1; }   // only whether there is any
    else if (typeof v !== 'number') v = String(v);
    f[k] = v;
  }
  const relations = (w.relations || []).filter(r => CACHE_RELS.includes(r.rel)).map(r => ({rel: r.rel, url: String(r.url)}));
  return {id: w.id, rev: w.rev, fields: f, relations};
}

function linkTargetId(url) {
  const last = String(url).replace(/\/+$/, '').split('/').pop();
  return /^\d+$/.test(last) ? Number(last) : null;
}
function parentId(item) {
  for (const r of item.relations || []) if (r.rel === 'System.LinkTypes.Hierarchy-Reverse') return linkTargetId(r.url);
  return null;
}

// Record what changed between the previous pull and this one
function compareItems(o, n, when, changes) {
  const base = {when, id: n.id, type: String(n.fields['System.WorkItemType'] || ''), title: String(n.fields['System.Title'] || '')};
  const add = (change, from, to) => changes.push(Object.assign({}, base, {change, from, to}));
  const checks = [['State', 'System.State'], ['Sprint', 'System.IterationPath'], ['Title', 'System.Title'],
    ['Area', 'System.AreaPath'], ['Points', 'Microsoft.VSTS.Scheduling.StoryPoints'], ['Column', 'System.BoardColumn'], ['Lane', 'System.BoardLane']];
  for (const [name, f] of checks) {
    const a = o.fields[f] == null ? '' : String(o.fields[f]), b = n.fields[f] == null ? '' : String(n.fields[f]);
    if (a !== b) add(name, a, b);
  }
  const who = x => x.fields['System.AssignedTo'] ? String(x.fields['System.AssignedTo'].displayName || '') : '';
  if (who(o) !== who(n)) add('Assigned', who(o), who(n));
  const pa = parentId(o), pb = parentId(n);
  if (String(pa == null ? '' : pa) !== String(pb == null ? '' : pb)) add('Parent', pa != null ? '#' + pa : '', pb != null ? '#' + pb : '');
}

async function syncWorkItems(cache, since, when, changes, fetchAll, S) {
  step('Checking work items in scope...');
  const firstPull = cache.size === 0;
  const ids = await scopeIds(S);
  const inScope = new Set(ids);

  // Items that left the scope (closed long ago, moved area, removed, deleted...)
  let dropped = 0;
  const extras = new Map();
  for (const [id, old] of [...cache]) {
    if (inScope.has(id)) continue;
    if (old.extra) extras.set(id, old);
    else {
      dropped++;
      changes.push({when, id, type: String(old.fields['System.WorkItemType'] || ''), title: String(old.fields['System.Title'] || ''), change: 'Left scope', from: String(old.fields['System.State'] || ''), to: ''});
    }
    cache.delete(id);
  }

  const toFetch = new Set(ids.filter(id => !cache.has(id)));
  const newCount = toFetch.size;
  if (fetchAll) ids.forEach(id => toFetch.add(id));
  else if (since && !firstPull) {
    if (S.epicIds.length) {
      // Link queries can't filter on ChangedDate: compare revision numbers instead
      const revs = await getRevisions(ids.filter(id => cache.has(id)));
      for (const [id, rev] of revs) if (cache.get(id).rev !== rev) toFetch.add(id);
    }
    else for (const id of await scopeIds(S, since)) if (cache.has(id)) toFetch.add(id);
  }
  log(`  ${ids.length.toLocaleString()} in scope: ${newCount} new, ${toFetch.size - newCount} changed, ${dropped} left the scope`);

  if (toFetch.size) {
    for (const w of await getWorkItems([...toFetch])) {
      const item = toCacheItem(w);
      if (cache.has(item.id)) compareItems(cache.get(item.id), item, when, changes);
      else if (!firstPull) changes.push({when, id: item.id, type: String(item.fields['System.WorkItemType'] || ''), title: String(item.fields['System.Title'] || ''), change: 'Added', from: '', to: String(item.fields['System.State'] || '')});
      cache.set(item.id, item);
    }
  }

  // Parents outside the filter keep the tree connected; cached ones are re-read only when their revision changed
  const stale = [];
  for (let round = 0; round < 8; round++) {
    const need = new Set();
    let restored = 0;
    for (const ci of [...cache.values()]) {
      const p = parentId(ci);
      if (p == null || cache.has(p)) continue;
      if (extras.has(p)) { cache.set(p, extras.get(p)); stale.push(p); restored++; } else need.add(p);
    }
    if (need.size) {
      log(`  fetching ${need.size} parent items outside the filter`);
      for (const w of await getWorkItems([...need], 'Fetching parents')) { const item = toCacheItem(w); item.extra = true; cache.set(item.id, item); }
    }
    else if (!restored) break;
  }
  if (stale.length) {
    const revs = await getRevisions(stale);
    const changed = [...revs].filter(([id, rev]) => cache.get(id).rev !== rev).map(([id]) => id);
    if (changed.length) for (const w of await getWorkItems(changed, 'Fetching parents')) { const item = toCacheItem(w); item.extra = true; cache.set(item.id, item); }
  }
}

// ---------------------------------------------------------------- states, sprints, repos
async function stateCategories(typeNames) {
  const cats = {};
  await pool(typeNames, 4, async t => {
    try {
      const res = await api(`${ctx.projUrl}/_apis/wit/workitemtypes/${encodeURIComponent(t)}/states`);
      for (const s of res.value || []) cats[`${t}|${s.name}`] = s.category;
    }
    catch (e) { log(`  states for ${t}: ${e.message}`); }
  });
  return cats;
}

async function getIterations(S) {
  const team = S.team || ctx.team || `${ctx.project} Team`;
  try {
    const res = await api(`${ctx.projUrl}/${encodeURIComponent(team)}/_apis/work/teamsettings/iterations`);
    return (res.value || []).map(it => {
      const a = it.attributes || {};
      return {name: String(it.name), path: String(it.path), start: a.startDate ? String(a.startDate) : '', finish: a.finishDate ? String(a.finishDate) : '', timeFrame: a.timeFrame ? String(a.timeFrame) : ''};
    });
  }
  catch (e) { log(`  sprints for team '${team}': ${e.message} (pick the team in Settings)`); return []; }
}

async function getRepos() {
  try {
    return ((await api(`${ctx.projUrl}/_apis/git/repositories`)).value || [])
      .map(r => ({id: String(r.id), name: String(r.name), defaultBranch: String(r.defaultBranch || ''), webUrl: String(r.webUrl || '')}));
  }
  catch (e) { log(`  repositories: ${e.message}`); return []; }
}

// ---------------------------------------------------------------- pull requests (metadata only)
const prInfo = pr => ({
  title: String(pr.title || ''), status: String(pr.status || ''),
  source: String(pr.sourceRefName || '').replace('refs/heads/', ''), target: String(pr.targetRefName || '').replace('refs/heads/', ''),
  author: pr.createdBy ? String(pr.createdBy.displayName || '') : '', repo: pr.repository ? String(pr.repository.id) : '',
  created: String(pr.creationDate || ''), closed: String(pr.closedDate || '')
});

async function syncPullRequests(prs, since, linkedIds, S) {
  const seen = new Set();
  const readPages = async criteria => {
    let skip = 0, n = 0;
    for (;;) {
      const res = await api(`${ctx.projUrl}/_apis/git/pullrequests`, {query: Object.assign({$top: 1000, $skip: skip}, criteria)});
      const page = (res.value || []).filter(Boolean);
      if (!page.length) break;
      for (const pr of page) { const id = String(pr.pullRequestId); prs[id] = prInfo(pr); seen.add(id); }
      skip += page.length; n += page.length;
      step(`Reading pull request info: ${n.toLocaleString()}`);
    }
    return n;
  };
  try {
    let n;
    if (!Object.keys(prs).length || !since) n = await readPages({'searchCriteria.status': 'all'});
    else {
      // Completed and abandoned PRs don't change: only re-read active ones and those closed since the last pull
      n = await readPages({'searchCriteria.status': 'active'});
      try { n += await readPages({'searchCriteria.status': 'all', 'searchCriteria.queryTimeRangeType': 'closed', 'searchCriteria.minTime': since}); }
      catch (e) { /* closed-since filter not available */ }
    }
    log(`  ${n.toLocaleString()} pull requests read`);
  }
  catch (e) { log(`  pull request list: ${e.message}`); }

  // Linked PRs the lists didn't cover (other projects, or active last time and not seen now)
  const todo = linkedIds.filter(id => !seen.has(id) && (!prs[id] || prs[id].status === 'active')).sort((a, b) => a - b);
  if (todo.length) {
    const now = todo.slice(0, S.maxPrDetails);
    log(`  looking up ${now.length} linked pull requests one by one`);
    await pool(now, 6, async id => { try { prs[id] = prInfo(await api(`${ctx.baseUrl}/_apis/git/pullrequests/${id}`)); } catch (e) {} });
    if (todo.length > now.length) log(`  ${todo.length - now.length} left for the next refresh (raise the limit in Settings)`);
  }
}

// ---------------------------------------------------------------- commit counts for the heatmap (dates and authors only)
async function syncCommits(rows, since, repos, days) {
  const now = new Date();
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const cut = ymd(new Date(today - days * 864e5));
  // Re-read the last couple of days every time so late pushes are counted; older days are kept as they are
  const from = since && rows.length ? new Date(Date.parse(ymd(new Date(since)) + 'T00:00:00Z') - 2 * 864e5) : new Date(today - days * 864e5);
  const fromDay = ymd(from);
  const out = rows.filter(r => r[0] < fromDay && r[0] >= cut).map(r => [String(r[0]), String(r[1]), String(r[2]), Number(r[3])]);
  const agg = new Map();
  let n = 0;
  await pool(repos, 4, async rp => {
    let skip = 0;
    for (;;) {
      let res;
      try {
        res = await api(`${ctx.projUrl}/_apis/git/repositories/${rp.id}/commits`, {query: {
          'searchCriteria.fromDate': from.toISOString().replace(/\.\d+Z$/, 'Z'), 'searchCriteria.$top': 1000, 'searchCriteria.$skip': skip}});
      }
      catch (e) { break; }   // empty or disabled repo
      const page = (res.value || []).filter(Boolean);
      for (const c of page) {
        const d = String((c.committer && c.committer.date) || '').slice(0, 10);
        if (!d || d < fromDay) continue;
        // Name plus the part of the email before the @ (never the full address), so the report can
        // join one person's commits made under different names, e.g. First.Last.CTR
        const local = String((c.author && c.author.email) || '').split('@')[0];
        const who = String((c.author && c.author.name) || '') + (local ? ` <${local}>` : '');
        const k = `${d}|${rp.id}|${who}`;
        agg.set(k, (agg.get(k) || 0) + 1);
      }
      n += page.length;
      step(`Counting commits: ${n.toLocaleString()}`);
      if (page.length < 100) break;
      skip += page.length;
    }
  });
  for (const [k, v] of agg) { const p = k.split('|'); out.push([p[0], p[1], p.slice(2).join('|'), v]); }
  log(`  ${n.toLocaleString()} commits read since ${fromDay}`);
  return out;
}

// ---------------------------------------------------------------- history from Analytics (daily counts per type and state)
async function importHistory(days, S, history) {
  const since = ymd(new Date(Date.now() - days * 864e5)) + 'T00:00:00Z';
  let filter = `DateValue ge ${since} and WorkItemType in (${S.types.map(t => `'${wq(t)}'`).join(',')})`;
  if (S.areaPath) filter += ` and startswith(Area/AreaPath,'${wq(S.areaPath)}')`;
  const apply = `filter(${filter})/groupby((DateValue,WorkItemType,StateCategory),aggregate($count as Count))`;
  let url = `https://analytics.dev.azure.com/${encodeURIComponent(ctx.org)}/${encodeURIComponent(ctx.project)}/_odata/v4.0-preview/WorkItemSnapshot?$apply=${encodeURIComponent(apply)}`;
  const agg = new Map();
  while (url) {
    const res = await api(url, {noVersion: true});
    for (const r of res.value || []) {
      const k = String(r.DateValue).slice(0, 10) + '|' + r.WorkItemType;
      if (!agg.has(k)) agg.set(k, {done: 0, active: 0, new: 0, removed: 0});
      agg.get(k)[bucket(String(r.StateCategory), '')] += Number(r.Count) || 0;
    }
    url = res['@odata.nextLink'];
    step(`Pulling history: ${agg.size.toLocaleString()} day/type rows`);
  }
  const today = ymd(new Date());
  const dates = new Set([...agg.keys()].map(k => k.slice(0, 10)).filter(d => d !== today));
  const rows = history.filter(r => !dates.has(r.date));
  for (const [k, a] of agg) {
    const d = k.slice(0, 10);
    if (d === today) continue;
    rows.push({date: d, type: k.slice(11), done: a.done, active: a.active, new: a.new, total: a.done + a.active + a.new});
  }
  rows.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : a.type < b.type ? -1 : 1);
  log(`  ${dates.size} days of history saved`);
  return rows;
}

// ---------------------------------------------------------------- normalization (same as Build-Model in ado_work_map.ps1)
function bucket(cat, state) {
  switch (cat) {
    case 'Completed': return 'done';
    case 'Removed': return 'removed';
    case 'InProgress': case 'Resolved': return 'active';
    case 'Proposed': return 'new';
  }
  const s = String(state || '').toLowerCase();
  if (['done', 'closed', 'completed'].includes(s)) return 'done';
  if (s === 'removed') return 'removed';
  if (['new', 'proposed', 'to do', 'approved'].includes(s)) return 'new';
  return 'active';
}
const wiKind = t => t === 'Technical Story' ? 'Tech' : STORY_TYPES.includes(t) ? 'Story' : ['Epic', 'Feature', 'Bug', 'Task'].includes(t) ? t : 'Other';
const short = (s, max) => s.length > max ? s.slice(0, max) + '\u2026' : s;

// vstfs:///Git/Commit/{proj}%2F{repo}%2F{sha}
function parseArtifact(url) {
  if (!url || !/^vstfs:\/\/\//i.test(url)) return null;
  const rest0 = url.slice(9);
  const i1 = rest0.indexOf('/'), i2 = i1 < 0 ? -1 : rest0.indexOf('/', i1 + 1);
  if (i2 < 0) return null;
  const tool = rest0.slice(0, i1), kind = rest0.slice(i1 + 1, i2);
  let rest;
  try { rest = decodeURIComponent(rest0.slice(i2 + 1)); } catch (e) { return null; }
  if (tool === 'Git') {
    const j1 = rest.indexOf('/'), j2 = j1 < 0 ? -1 : rest.indexOf('/', j1 + 1);
    if (j2 < 0) return null;
    const a = {proj: rest.slice(0, j1), repo: rest.slice(j1 + 1, j2), ident: rest.slice(j2 + 1)};
    if (kind === 'Commit') return Object.assign(a, {kind: 'Commit'});
    if (kind === 'PullRequestId') return Object.assign(a, {kind: 'PR'});
    if (kind === 'Ref') { if (a.ident.startsWith('GB')) a.ident = a.ident.slice(2); return Object.assign(a, {kind: 'Branch'}); }
    return null;
  }
  if (tool === 'Build' && kind === 'Build') return {kind: 'Build', proj: null, repo: null, ident: rest};
  return null;
}
function artifacts(raw) {
  const out = [];
  for (const w of raw) for (const r of w.relations || []) if (r.rel === 'ArtifactLink') { const a = parseArtifact(r.url); if (a) out.push({wid: w.id, a}); }
  return out;
}

// Team sprints plus any other iteration path work items sit in, oldest first
function sprintList(iterations, raw) {
  const now = Date.now();
  const list = [], known = new Set();
  for (const it of iterations) {
    const s = {name: it.name, path: it.path, start: it.start, finish: it.finish, timeFrame: it.timeFrame};
    if (s.start && s.finish) {
      const st = Date.parse(s.start), fi = Date.parse(s.finish) + 864e5;
      s.timeFrame = now < st ? 'future' : now >= fi ? 'past' : 'current';
    }
    if (!known.has(s.path.toLowerCase())) { list.push(s); known.add(s.path.toLowerCase()); }
  }
  const root = ctx.project.toLowerCase();
  for (const w of raw) {
    const p = String(w.fields['System.IterationPath'] || '');
    if (!p || p.toLowerCase() === root) continue;
    let q = p.toLowerCase(), covered = false;
    for (;;) {
      if (known.has(q)) { covered = true; break; }
      const i = q.lastIndexOf('\\');
      if (i < 0) break;
      q = q.slice(0, i);
    }
    if (!covered) { list.push({name: p.split('\\').pop(), path: p, start: '', finish: '', timeFrame: ''}); known.add(p.toLowerCase()); }
  }
  // Between sprints (e.g. the weekend before the next one starts): the next sprint, if it starts within a week
  const current = list.find(s => s.timeFrame === 'current') ||
    list.filter(s => s.timeFrame === 'future' && s.start && Date.parse(s.start) < Date.now() + 7 * 864e5).sort((a, b) => a.start < b.start ? -1 : 1)[0] || null;
  const natural = s => String(s.name).replace(/\d+/g, m => m.padStart(8, '0'));
  const cmp = (a, b) => a < b ? -1 : a > b ? 1 : 0;
  list.sort((a, b) => cmp(a.start || '9999', b.start || '9999') || cmp(natural(a), natural(b)));
  return {list, current};
}

function buildModel(raw, cats, sprintInfo, repos, prs) {
  const sprint = sprintInfo.current;
  const sprintPath = sprint ? sprint.path : '';
  const items = new Map();
  for (const w of raw) {
    const f = w.fields;
    const t = String(f['System.WorkItemType'] || ''), state = String(f['System.State'] || ''), itPath = String(f['System.IterationPath'] || '');
    let points = f['Microsoft.VSTS.Scheduling.StoryPoints'];
    if (points == null) points = f['Microsoft.VSTS.Scheduling.Effort'];
    items.set(w.id, {
      id: w.id, type: t, kind: wiKind(t), level: LEVELS[t] == null ? 0 : LEVELS[t],
      title: String(f['System.Title'] || ''), state, bucket: bucket(cats[`${t}|${state}`], state),
      assignee: f['System.AssignedTo'] ? String(f['System.AssignedTo'].displayName || '') : '',
      iteration: itPath, area: String(f['System.AreaPath'] || ''), tags: String(f['System.Tags'] || ''),
      points: points == null ? null : points,
      remaining: f['Microsoft.VSTS.Scheduling.RemainingWork'] == null ? null : f['Microsoft.VSTS.Scheduling.RemainingWork'],
      completed: f['Microsoft.VSTS.Scheduling.CompletedWork'] == null ? null : f['Microsoft.VSTS.Scheduling.CompletedWork'],
      created: String(f['System.CreatedDate'] || ''), changed: String(f['System.ChangedDate'] || ''), closed: String(f['Microsoft.VSTS.Common.ClosedDate'] || ''), activated: String(f['Microsoft.VSTS.Common.ActivatedDate'] || ''),
      lane: String(f['System.BoardLane'] || ''), column: String(f['System.BoardColumn'] || ''), start: String(f[dateFields[0]] || ''), end: String(f[dateFields[1]] || ''), ac: !!f['Microsoft.VSTS.Common.AcceptanceCriteria'],
      inSprint: !!(sprintPath && (itPath.toLowerCase() === sprintPath.toLowerCase() || itPath.toLowerCase().startsWith(sprintPath.toLowerCase() + '\\'))),
      url: `${ctx.projUrl}/_workitems/edit/${w.id}`, parent: null, children: []
    });
  }

  // Work item <-> work item links
  const wiLinks = [], seen = new Set();
  for (const w of raw) {
    const src = w.id;
    for (const r of w.relations || []) {
      if (!/\/workItems\//i.test(r.url)) continue;
      const dst = linkTargetId(r.url);
      if (dst == null || !items.has(dst)) continue;
      if (r.rel === 'System.LinkTypes.Hierarchy-Reverse') items.get(src).parent = dst;
      else if (r.rel === 'System.LinkTypes.Related') {
        const k = `${Math.min(src, dst)}|${Math.max(src, dst)}|related`;
        if (!seen.has(k)) { seen.add(k); wiLinks.push({from: src, to: dst, kind: 'related'}); }
      }
      else if (r.rel === 'System.LinkTypes.Dependency-Forward') {
        const k = `${src}|${dst}|depends`;
        if (!seen.has(k)) { seen.add(k); wiLinks.push({from: src, to: dst, kind: 'depends'}); }
      }
    }
  }
  for (const it of items.values()) if (it.parent != null) items.get(it.parent).children.push(it.id);
  for (const it of items.values()) it.children.sort((a, b) => items.get(a).level - items.get(b).level || a - b);

  // Roll-ups over leaf descendants
  const leafMemo = new Map();
  const leaves = id => {
    if (leafMemo.has(id)) return leafMemo.get(id);
    leafMemo.set(id, []);   // guards against parent loops
    const it = items.get(id);
    const res = it.children.length ? it.children.flatMap(leaves) : [id];
    leafMemo.set(id, res);
    return res;
  };
  for (const it of items.values()) {
    const r = {done: 0, active: 0, new: 0};
    for (const l of leaves(it.id)) { const b = items.get(l).bucket; if (b in r) r[b]++; }
    r.total = r.done + r.active + r.new;
    r.pct = r.total ? Math.round(100 * r.done / r.total) : it.bucket === 'done' ? 100 : 0;
    it.roll = r;
  }
  const lvl = t => LEVELS[t] == null ? 9 : LEVELS[t];
  const roots = [...items.values()].filter(it => it.parent == null).sort((a, b) => a.level - b.level || a.id - b.id).map(it => it.id);

  // Summary per type
  const sum = new Map();
  for (const it of items.values()) {
    if (!sum.has(it.type)) sum.set(it.type, {type: it.type, total: 0, done: 0, active: 0, new: 0, removed: 0});
    const s = sum.get(it.type);
    s.total++; s[it.bucket]++;
  }
  const summary = [...sum.values()].sort((a, b) => lvl(a.type) - lvl(b.type) || (a.type < b.type ? -1 : a.type > b.type ? 1 : 0));

  // Spider web graph
  const repoById = new Map(repos.map(r => [r.id, r]));
  const nodes = new Map(), edges = [];
  for (const it of items.values()) {
    const tip = [`${it.type} #${it.id}`, it.title, `State: ${it.state}`];
    if (it.assignee) tip.push(`Assigned: ${it.assignee}`);
    if (it.iteration) tip.push(`Iteration: ${it.iteration}`);
    nodes.set('w' + it.id, {
      id: 'w' + it.id, kind: it.kind, wi: true,
      label: (it.bucket === 'done' ? '\u2713 ' : '') + `#${it.id} ` + short(it.title, 38),
      title: tip.join('\n'), url: it.url, bucket: it.bucket, inSprint: it.inSprint, level: it.level
    });
    if (it.parent != null) edges.push({from: 'w' + it.parent, to: 'w' + it.id, kind: 'child'});
  }
  for (const l of wiLinks) edges.push({from: 'w' + l.from, to: 'w' + l.to, kind: l.kind});

  const addRepoNode = (projId, repoId) => {
    const nid = 'r' + repoId;
    if (!nodes.has(nid)) {
      const rp = repoById.get(repoId);
      const name = rp ? rp.name : `repo ${repoId.slice(0, 8)}`;
      let tip = `Repository: ${name}`;
      if (rp && rp.defaultBranch) tip += '\ndefault: ' + rp.defaultBranch.replace('refs/heads/', '');
      nodes.set(nid, {id: nid, kind: 'Repo', label: name, title: tip, url: rp && rp.webUrl ? rp.webUrl : `${ctx.baseUrl}/${projId}/_git/${repoId}`, wis: []});
    }
    return nid;
  };
  for (const rp of repos) addRepoNode(ctx.project, rp.id);

  const wiRepo = new Map();
  for (const {wid, a} of artifacts(raw)) {
    if (!items.has(wid)) continue;
    const nid = `${a.kind}:${a.repo}:${a.ident}`;
    if (!nodes.has(nid)) {
      const repoName = a.repo && repoById.get(a.repo) ? repoById.get(a.repo).name : a.repo;
      const n = {id: nid, kind: a.kind, art: true, wis: []};
      if (a.kind === 'Commit') {
        n.label = a.ident.slice(0, 7);
        n.title = `Commit ${a.ident}\nRepo: ${repoName}`;
        n.url = `${ctx.baseUrl}/${a.proj}/_git/${a.repo}/commit/${a.ident}`;
      }
      else if (a.kind === 'PR') {
        const d = prs[String(a.ident)];
        n.label = `PR !${a.ident}`;
        const tip = [`Pull request !${a.ident}`];
        if (d) {
          if (d.title) { n.label += ' ' + short(d.title, 30); tip.push(d.title); }
          if (d.status) tip.push(`Status: ${d.status}`);
          if (d.source) tip.push(`${d.source} \u2192 ${d.target}`);
          if (d.author) tip.push(`By: ${d.author}`);
          n.status = d.status; n.source = d.source; n.created = d.created; n.closed = d.closed;
        }
        tip.push(`Repo: ${repoName}`);
        n.title = tip.join('\n');
        n.url = `${ctx.baseUrl}/${a.proj}/_git/${a.repo}/pullrequest/${a.ident}`;
      }
      else if (a.kind === 'Branch') {
        n.label = a.ident;
        n.title = `Branch ${a.ident}\nRepo: ${repoName}`;
        n.url = `${ctx.baseUrl}/${a.proj}/_git/${a.repo}?version=GB${encodeURIComponent(a.ident)}`;
      }
      else {
        n.label = `Build ${a.ident}`; n.title = `Build ${a.ident}`;
        n.url = `${ctx.projUrl}/_build/results?buildId=${a.ident}`;
      }
      nodes.set(nid, n);
      if (a.repo) {
        const rid = addRepoNode(a.proj, a.repo);
        n.repo = rid;
        edges.push({from: nid, to: rid, kind: 'in-repo'});
      }
    }
    const n = nodes.get(nid);
    if (!n.wis.includes(wid)) { n.wis.push(wid); edges.push({from: 'w' + wid, to: nid, kind: 'artifact'}); }
    if (n.repo) {
      const rn = nodes.get(n.repo);
      if (!rn.wis.includes(wid)) rn.wis.push(wid);
      const k = `${wid}|${n.repo}`;
      if (!wiRepo.has(k)) wiRepo.set(k, {wid, rid: n.repo, via: []});
      if (!wiRepo.get(k).via.includes(nid)) wiRepo.get(k).via.push(nid);
    }
  }
  // PR -> source branch, when that branch is also linked
  for (const n of [...nodes.values()]) {
    if (n.kind === 'PR' && n.source && n.repo) {
      const bid = `Branch:${n.repo.slice(1)}:${n.source}`;
      if (nodes.has(bid)) edges.push({from: n.id, to: bid, kind: 'pr-branch'});
    }
  }
  // Direct work item -> repo edges, drawn only when the artifacts between them are hidden
  for (const x of wiRepo.values()) edges.push({from: 'w' + x.wid, to: x.rid, kind: 'wi-repo', via: x.via});
  edges.forEach((e, i) => { e.id = 'e' + i; });

  const d = new Date();
  return {
    org: ctx.org, project: ctx.project, projectUrl: ctx.projUrl,
    generated: `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`,
    sprint, sprints: sprintInfo.list, changes: [], runUtc: '', summary,
    items: [...items.values()].sort((a, b) => a.id - b.id), roots,
    graph: {nodes: [...nodes.values()], edges}, typeColors: TYPE_COLORS, history: [], acRead: true
  };
}

// ---------------------------------------------------------------- pull + save
async function loadSaved() {
  const out = {};
  for (const k of SAVED) out[k] = await store.get(key(k));
  return out;
}

async function pull(full) {
  const S = readSettings();
  calls = 0;
  const runUtc = nowIso();
  const saved = await loadSaved();
  const changes = [];

  // Work items: reuse saved data when it was made with the same scope settings
  const signature = [ctx.org, ctx.projectId, S.types.join(','), S.areaPath, S.epicIds.join(','), S.includeRemoved, S.closedWithinDays, ...dateFields].join('|');
  const cache = new Map();
  let since = null, prevRunUtc = '';
  const wc = saved.wi;
  if (wc && wc.version === 5 && wc.signature === signature) {   // v3 added acceptance criteria, v4 the activated date, v5 board lane and column
    for (const ci of wc.items) cache.set(ci.id, ci);
    prevRunUtc = wc.lastRunUtc;
    since = minusMinutes(wc.lastRunUtc, 10);
    log(full ? 'Full refresh - re-reading every work item' : `Pulling changes since ${new Date(wc.lastRunUtc).toLocaleString()} (${cache.size.toLocaleString()} items saved)`);
  }
  else log(wc ? 'Scope settings changed - pulling everything' : 'First visit - pulling everything (later visits only pull changes)');

  await syncWorkItems(cache, since, runUtc, changes, full, S);
  const raw = [...cache.values()];
  await store.set(key('wi'), {version: 5, signature, lastRunUtc: runUtc, prevRunUtc, items: raw});

  step('Reading state categories, sprints and repos...');
  const typeNames = [...new Set(raw.map(w => w.fields['System.WorkItemType']).filter(Boolean))].sort();
  const [cats, iterations, repos] = await Promise.all([stateCategories(typeNames), getIterations(S), getRepos()]);
  const meta = {cats, iterations, repos, team: S.team || ctx.team};
  await store.set(key('meta'), meta);

  step('Reading pull request info (metadata only)...');
  const pc = full ? null : saved.prs;
  const prs = pc && pc.prs ? pc.prs : {};
  const prSince = pc && Object.keys(prs).length ? minusMinutes(pc.lastRunUtc, 10) : null;
  const linked = [...new Set(artifacts(raw).filter(x => x.a.kind === 'PR').map(x => String(x.a.ident)))];
  await syncPullRequests(prs, prSince, linked, S);
  await store.set(key('prs'), {lastRunUtc: runUtc, prs});

  let commitRows = [];
  if (S.commitDays > 0) {
    step('Counting commits for the heatmap (dates and authors only)...');
    const cc = full ? null : saved.commits;
    const rowsIn = cc && cc.days === S.commitDays ? cc.rows : [];
    commitRows = await syncCommits(rowsIn, rowsIn.length ? cc.lastRunUtc : null, repos, S.commitDays);
    await store.set(key('commits'), {days: S.commitDays, lastRunUtc: runUtc, rows: commitRows});
  }

  const allChanges = (saved.changes || []).concat(changes).slice(-MAX_CHANGES);
  await store.set(key('changes'), allChanges);
  log(`  ${calls} Azure DevOps calls, ${changes.length} changes since the last pull`);
  return {raw, meta, prs, commitRows, commitDays: S.commitDays, changes: allChanges, history: saved.history || [], runUtc, prevRunUtc, S, fresh: true};
}

async function savedData() {
  const s = await loadSaved();
  if (!s.wi || !s.meta) return null;
  const S = readSettings();
  return {
    raw: s.wi.items, meta: s.meta, prs: s.prs ? s.prs.prs : {}, commitRows: s.commits ? s.commits.rows : [], commitDays: s.commits ? s.commits.days : S.commitDays,
    changes: s.changes || [], history: s.history || [], runUtc: s.wi.lastRunUtc, prevRunUtc: s.wi.prevRunUtc, S, fresh: false
  };
}

async function makeModel(data) {
  const raw = data.S.epicIds.length ? data.raw.filter(w => data.S.types.includes(w.fields['System.WorkItemType']) || w.extra) : data.raw;
  const model = buildModel(raw, data.meta.cats || {}, sprintList(data.meta.iterations || [], raw), data.meta.repos || [], data.prs || {});
  // History: one row per type per day, today's replaced on every fresh pull
  let history = data.history;
  if (data.fresh) {
    const today = ymd(new Date());
    history = history.filter(r => r.date !== today).concat(model.summary.map(s => ({date: today, type: s.type, done: s.done, active: s.active, new: s.new, total: s.total - s.removed})));
    await store.set(key('history'), history);
  }
  model.history = history.slice().sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : 0);
  model.changes = data.changes;
  model.runUtc = data.runUtc;
  model.prevRunUtc = data.prevRunUtc;
  model.commits = {days: data.commitDays, rows: data.commitRows};
  model.demo = false;
  model.settings = teamSet;
  return model;
}

// ---------------------------------------------------------------- render
let reportHtml = null;
function render(model) {
  const host = $('#report');
  if (reportHtml == null) reportHtml = host.innerHTML;
  else host.innerHTML = reportHtml;   // fresh markup, so the report script can run again
  $('#hub-loading').hidden = true;
  host.hidden = false;
  window.runReport(model);
}

let busy = false;
async function refresh(full) {
  if (busy) return;
  busy = true;
  $('#hub-bar').classList.add('busy');
  $('#hub-log').textContent = '';
  $('#hub-error').hidden = true;
  const first = $('#report').hidden;
  if (first) $('#hub-loading').hidden = false;
  try {
    const data = await pull(full);
    step('Building the map...');
    const model = await makeModel(data);
    render(model);
    $('#hub-status').textContent = `Up to date \u00b7 ${model.items.length.toLocaleString()} work items \u00b7 ${calls} calls`;
  }
  catch (e) {
    console.error(e);
    const saved = first ? await savedData().catch(() => null) : null;
    if (saved) { render(await makeModel(saved)); }
    showError(e, !!saved || !first);
  }
  finally {
    busy = false;
    $('#hub-bar').classList.remove('busy');
  }
}

function showError(e, hasData) {
  const msg = e && e.message || String(e);
  let hint = '';
  if (e && e.status === 401) hint = 'Azure DevOps refused the request. Reload the page; if it keeps happening, ask an admin to re-approve the extension (its permissions may have changed).';
  else if (e && e.status === 403) hint = 'Your account doesn\'t have permission to read this. Ask a project admin for access to the project or team, or pick another team in Settings.';
  else if (e && e.status === 404) hint = 'Not found: the team or area path in Settings may have been renamed or removed.';
  else if (/TF51011|TF401019|area path/i.test(msg)) hint = 'Check the area path in Settings.';
  $('#hub-error').innerHTML = '<b>Couldn\'t pull from Azure DevOps.</b> ' + escapeHtml(msg) + (hint ? '<br>' + escapeHtml(hint) : '') +
    (hasData ? '<br>Showing the data saved from the last pull.' : '');
  $('#hub-error').hidden = false;
  $('#hub-status').textContent = 'Pull failed';
  if (!hasData) $('#hub-step').textContent = 'Pull failed - see the message above.';
}
const escapeHtml = s => String(s).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));

// ---------------------------------------------------------------- settings panel
async function openSettings() {
  const S = readSettings();
  $('#s-area').value = S.areaPath;
  $('#s-types').value = S.types.join(', ');
  $('#s-epics').value = S.epicIds.join(', ');
  $('#s-closed').value = S.closedWithinDays;
  $('#s-removed').checked = S.includeRemoved;
  $('#s-commits').value = S.commitDays;
  $('#s-prs').value = S.maxPrDetails;
  const sel = $('#s-team');
  sel.innerHTML = `<option value="">Default team (${escapeHtml(ctx.team || ctx.project + ' Team')})</option>`;
  $('#hub-settings').hidden = false;
  try {
    const res = await api(`${ctx.baseUrl}/_apis/projects/${ctx.projectId}/teams`, {query: {$top: 500}});
    for (const t of (res.value || []).sort((a, b) => a.name.localeCompare(b.name))) sel.insertAdjacentHTML('beforeend', `<option>${escapeHtml(t.name)}</option>`);
  }
  catch (e) { if (S.team) sel.insertAdjacentHTML('beforeend', `<option>${escapeHtml(S.team)}</option>`); }
  sel.value = S.team;
}
function saveSettings() {
  const ints = s => s.split(/[,; ]+/).map(x => parseInt(x, 10)).filter(Number.isFinite);
  const num = (v, d) => { const n = parseInt(v, 10); return Number.isFinite(n) ? n : d; };
  writeSettings({
    team: $('#s-team').value,
    areaPath: $('#s-area').value.trim(),
    types: $('#s-types').value.split(',').map(s => s.trim()).filter(Boolean),
    epicIds: ints($('#s-epics').value),
    closedWithinDays: num($('#s-closed').value, -1),
    includeRemoved: $('#s-removed').checked,
    commitDays: Math.max(0, num($('#s-commits').value, 365)),
    maxPrDetails: Math.max(0, num($('#s-prs').value, 200))
  });
  $('#hub-settings').hidden = true;
  refresh(false);
}
async function clearSaved() {
  if (!confirm('Delete the data saved in this browser for this project? The next pull reads everything again.')) return;
  for (const k of SAVED) await store.del(key(k));
  $('#hub-settings').hidden = true;
  refresh(true);
}
async function pullHistory() {
  if (busy) return;
  const days = parseInt(prompt('Pull how many days of history from Azure DevOps Analytics?', '180'), 10);
  if (!Number.isFinite(days) || days <= 0) return;
  busy = true;
  $('#hub-bar').classList.add('busy');
  try {
    const rows = await importHistory(days, readSettings(), (await store.get(key('history'))) || []);
    await store.set(key('history'), rows);
    const saved = await savedData();
    if (saved) render(await makeModel(saved));
    $('#hub-status').textContent = `History pulled (${days} days)`;
  }
  catch (e) {
    showError(new Error('History pull failed - is Analytics enabled for this project? ' + (e.message || e)), true);
  }
  finally { busy = false; $('#hub-bar').classList.remove('busy'); }
}

// ---------------------------------------------------------------- start
async function start() {
  SDK.init({loaded: false});
  await SDK.ready();
  const wc = SDK.getWebContext(), host = SDK.getHost();
  let base = '';
  try {
    const loc = await SDK.getService('ms.vss-features.location-service');
    base = await loc.getServiceLocation();
  } catch (e) {}
  if (!base) base = `https://dev.azure.com/${encodeURIComponent(host.name)}/`;
  const baseUrl = String(base).replace(/\/+$/, '');
  ctx = {
    org: host.name, project: wc.project.name, projectId: wc.project.id,
    team: wc.team && wc.team.name ? wc.team.name : '',
    baseUrl, projUrl: `${baseUrl}/${encodeURIComponent(wc.project.name)}`
  };
  SDK.notifyLoadSucceeded();

  $('#hub-refresh').onclick = () => refresh(false);
  $('#hub-full').onclick = () => { if (confirm('Re-read every work item, pull request and commit count? This takes longer than a normal refresh.')) refresh(true); };
  $('#hub-history').onclick = pullHistory;
  $('#hub-settings-btn').onclick = () => $('#hub-settings').hidden ? openSettings() : ($('#hub-settings').hidden = true);
  $('#s-save').onclick = saveSettings;
  $('#s-cancel').onclick = () => { $('#hub-settings').hidden = true; };
  $('#s-clear').onclick = clearSaved;

  await loadTeamSettings();
  // Show what's saved straight away, then pull what changed
  const saved = await savedData().catch(() => null);
  if (saved) {
    try { render(await makeModel(saved)); $('#hub-status').textContent = 'Showing saved data - pulling changes...'; }
    catch (e) { console.error(e); }
  }
  await refresh(false);
}

start().catch(e => { console.error(e); showError(e, false); });
