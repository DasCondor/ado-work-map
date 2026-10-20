# ADO Work Map

A single PowerShell script that pulls Epics, Features, User Stories, Bugs and Tasks from Azure DevOps and builds an interactive HTML report of what's done, what's left, every sprint, what changed, and how the work connects to your repos.

- **Windows PowerShell 5.1 only.** No modules to install; everything it uses ships with Windows 11.
- **Incremental.** The first run pulls everything; later runs only pull work items that changed since the last run.
- **Light on the API.** Pull request info (title, status, branches, author; never code) comes from the project's PR list, 1,000 per call. Completed PRs are cached for good.

## The report

| Tab | What it shows |
|---|---|
| **Delivery map** | Searchable epic list next to the selected epic's Feature > Story > Task tree with done / in progress / not started roll-ups. *Collapse to* Epic, Feature, Story or Task. Progress-over-time chart from `history.csv`. |
| **Sprints** | Every sprint on a timeline. Per sprint: KPIs, work by person (click to filter), and the sprint's work as a collapsible tree. Also a velocity chart and a sprint map (epics/features x sprints). |
| **Changes** | What changed in a time frame (latest pull, 7/14/30/90 days, custom): created, completed, updated, plus a change log of state changes, sprint moves, reassignments, retitles and scope changes recorded on each run. |
| **Maps** | Treemap (size = work, colour = % done, click to zoom) and a repo matrix (epics or features x repos). Both scale to thousands of items. |
| **Spider web** | Graph of work items, links, PRs, commits, branches, builds and repos. Opens on the current sprint; also overview, focus on one item, or everything. |

A filter bar (search, epic, person, area, tag) applies to every tab. Light / dark theme picker in the header.

## Setup

1. Copy `run_ado_work_map.example.cmd` to `run_ado_work_map.cmd` (that name is git-ignored).
2. Open it in Notepad and fill in `ADO_ORG`, `ADO_PROJECT` and `ADO_PAT_VALUE`, plus any optional settings.
   PAT scopes (all **Read**): Work Items, Code, Project and Team, Build, and Analytics (for history).
3. Double-click `run_ado_work_map.cmd`. The report opens from `ado_report\ado_work_map.html`.

Try it without Azure DevOps first:

```bat
run_ado_work_map.cmd -Demo
```

Prefer not to keep a PAT in a file? Leave `ADO_PAT_VALUE` empty and the script uses an `ADO_PAT` environment variable, `az login`, or asks for it.

## Commands

Extra arguments go straight to the script, so these work with the starter or with `ado_work_map.ps1` directly:

| Command | Does |
|---|---|
| *(none)* | Pull changes since the last run and rebuild the report |
| `-Full` | Re-pull everything, ignoring the cache |
| `-Offline` | Rebuild the report from saved data, no Azure DevOps calls |
| `-PullHistory [-HistoryDays 180]` | Backfill `history.csv` from Azure DevOps Analytics, then run |
| `-ClearArchive` | Delete the cache and archived reports |
| `-ClearArchive -IncludeHistory` | ...and `history.csv` and `changelog.csv` |
| `-NoOpen` | Don't open the browser |
| `-Demo` | Sample data |

Scope options: `-Team`, `-Iteration`, `-EpicId 1234,5678`, `-AreaPath`, `-Types`, `-ClosedWithinDays`, `-IncludeRemoved`. Azure DevOps Server (on-prem): `-ServerUrl https://tfs.contoso.com/tfs` with the collection name as `-Org`. Run `Get-Help .\ado_work_map.ps1 -Full` for everything.

### VS Code

Open the folder and use **Terminal > Run Task...**: Run, Update data, Full refresh, Rebuild from saved data, Pull history, Clear archived data, Clear ALL data, Demo. The tasks call `run_ado_work_map.cmd`, so your settings live in one place.

## Output

Everything goes to `ado_report\` next to the script:

| File | |
|---|---|
| `ado_work_map.html` | The report (the spider web loads vis-network from unpkg.com; the other tabs work offline) |
| `ado_work_map.json` | Normalized data |
| `ado_work_items.csv` | Flat list for Excel |
| `history.csv` | Daily counts per work item type |
| `changelog.csv` | Changes detected between runs |
| `cache\` | Work items, PR info and settings from the last pull |
| `archive\` | One copy of the report per day, kept 30 days (`-ArchiveDays`) |

## Running it blocked?

If Windows blocks the script, the starter already uses `-ExecutionPolicy Bypass`. To run the `.ps1` directly:

```bat
powershell -ExecutionPolicy Bypass -File .\ado_work_map.ps1
```
