# Changelog

## 1.4.2

- Commit heatmap: Top repos and Top people moved above the heatmap
- Sprint detail: By person spans the full width above the sprint's work
- Sprint map: Expand all / Collapse all

## 1.4.1

- Filter bar: people and tags are multiple choice, a persistent Exclude tags list, a saved default area path, every list narrowed by the other filters (pick an area path and the Epic list shrinks to it), and a search box on lists over 5
- Sprints: the sprint strip stays in view while scrolling; the sprint map has epic and feature links and a hover list of each cell's stories with links
- Technical Story is a story type everywhere, and its own kind in the spider web
- The report uses the full window width

## 1.1.1

- Fixed: a pinned commit heatmap tooltip on a square low in the grid was cut off by the bottom of the heatmap card. It now opens above the pointer when there's no room below, and the card makes room for very tall ones

## 1.1.0

- Every map (treemap, repo matrix, commit heatmap) can be narrowed to one sprint, with a banner showing the sprint, its dates and Previous / Next buttons, plus a Current sprint shortcut
- Commit heatmap: Everyone or By person (a row per person), day-by-day squares for a sprint, a tooltip on every square (date, commits, people, repos), click a square to pin it with links to those commits in Azure DevOps, and click a person to show only them. Over all sprints, By person gives each person their own day-by-day calendar
- One person's commits under different names or accounts (e.g. First Last and First.Last.CTR) are counted as one person. Commit rows now keep the part of the email before the @ for this; run a Full refresh to add it to older days

## 1.0.1

- Spider web takes label text into account: the layout keeps node and label boxes apart, overlapping labels are skipped (biggest items first), and labels stay at a readable size when a graph is zoomed out to fit a narrow panel
- Fixed: pasting the organization's address (https://dev.azure.com/<org>, optionally with /<project>, or https://<org>.visualstudio.com) into the Organization setting broke every request. The name and project are now read from the address.
- A note under Hide accomplished explains why commits linked to open work stay visible

## 1.0.0

First release.

- Launch pad in the sidebar: setup checklist, data summary, and one-click Pull changes, Full refresh, Rebuild report, Pull history, Clear archived data and Clear all data
- Report in a VS Code tab or the browser, with a demo report to try without Azure DevOps
- Settings in VS Code settings; the personal access token in VS Code secret storage
- Status bar item showing the last pull; optional pull on startup and automatic pulls
- Bundles ado_work_map.ps1: incremental pulls, bulk pull request metadata, commit heatmap, history from Analytics, and a fully offline report
