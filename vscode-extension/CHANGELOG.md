# Changelog

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
