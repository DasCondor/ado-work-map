@echo off
rem ===========================================================================
rem  run_ado_work_map.cmd - double-click starter for ado_work_map.ps1
rem
rem  THIS IS THE TEMPLATE: copy it to run_ado_work_map.cmd (git ignores that
rem  name, so your PAT never gets committed) and fill in your settings there.
rem
rem  Fill in the settings below once, then double-click this file (or run it
rem  from a CMD prompt, or use the VS Code tasks) whenever you want a fresh
rem  report. Each run only pulls what changed in Azure DevOps since the last one.
rem
rem  SECURITY: this file holds your PAT in plain text.
rem    - Keep it out of git / GitHub (it is listed in .gitignore).
rem    - Don't email or share it. Give the PAT read-only scopes:
rem      Work Items, Code, Project and Team, Build, Analytics (all Read)
rem    - Leave ADO_PAT_VALUE empty to use an ADO_PAT environment variable,
rem      "az login", or be prompted instead.
rem
rem  Extra arguments are passed through to the script, e.g.
rem    run_ado_work_map.cmd -Full                re-pull everything (ignore the cache)
rem    run_ado_work_map.cmd -Offline             rebuild the report from saved data, no ADO calls
rem    run_ado_work_map.cmd -PullHistory         backfill history.csv from ADO Analytics, then run
rem    run_ado_work_map.cmd -ClearArchive        delete the cache and archived reports
rem    run_ado_work_map.cmd -ClearArchive -IncludeHistory   ...and history.csv + changelog.csv
rem    run_ado_work_map.cmd -Demo                sample data, no ADO connection
rem ===========================================================================
setlocal

rem ---- Required --------------------------------------------------------------
rem  Organization = the part after https://dev.azure.com/
set "ADO_ORG=your-org"
set "ADO_PROJECT=Your Project"
set "ADO_PAT_VALUE="

rem ---- Optional (leave empty to skip) ----------------------------------------
rem  Team whose sprints are shown (default: "<project> Team")
set "ADO_TEAM="
rem  Force a sprint as "current" instead of the team's, e.g. Your Project\Sprint 14
set "ADO_ITERATION="
rem  Only these epics and everything under them, comma separated, e.g. 1234,5678
set "ADO_EPIC_IDS="
rem  Only this area path and its children, e.g. Your Project\Payments
set "ADO_AREA_PATH="
rem  Work item types, comma separated (default: Epic,Feature,User Story,Product Backlog Item,Requirement,Bug,Task)
set "ADO_TYPES="
rem  Skip items closed more than N days ago (open items are always kept)
set "ADO_CLOSED_WITHIN_DAYS="
rem  PR info comes from the project's PR list (1000 per call, metadata only - no code).
rem  This caps the extra one-by-one lookups for linked PRs the list doesn't cover
rem  (other projects, or PRs that just closed). Default 500.
set "ADO_MAX_PR_DETAILS="
rem  Days of history to pull with -PullHistory (default 180)
set "ADO_HISTORY_DAYS="
rem  Days to keep the daily copies in archive\ (default 30, 0 = don't archive)
set "ADO_ARCHIVE_DAYS="
rem  Azure DevOps Server (on-premises) only: collection server URL, e.g. https://tfs.contoso.com/tfs
rem  (then put the collection name in ADO_ORG). Leave empty for dev.azure.com.
set "ADO_SERVER_URL="
rem  Report folder (default: ado_report next to the script). No trailing backslash.
set "ADO_OUT_DIR="
rem  1 = include items in the Removed state
set "ADO_INCLUDE_REMOVED=0"
rem  1 = don't open the report in the browser when done
set "ADO_NO_OPEN=0"
rem  1 = keep this window open at the end even when it succeeds
set "PAUSE_AT_END=0"

rem ---- Run (no need to edit below) -------------------------------------------
set "SCRIPT=%~dp0ado_work_map.ps1"
if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%". Keep this file in the same folder as ado_work_map.ps1.
    pause
    exit /b 1
)

set "ARGS="
if /i not "%ADO_ORG%"=="your-org" if not "%ADO_ORG%"=="" set ARGS=%ARGS% -Org "%ADO_ORG%"
if /i not "%ADO_PROJECT%"=="Your Project" if not "%ADO_PROJECT%"=="" set ARGS=%ARGS% -Project "%ADO_PROJECT%"
if not "%ADO_TEAM%"=="" set ARGS=%ARGS% -Team "%ADO_TEAM%"
if not "%ADO_ITERATION%"=="" set ARGS=%ARGS% -Iteration "%ADO_ITERATION%"
if not "%ADO_EPIC_IDS%"=="" set ARGS=%ARGS% -EpicId "%ADO_EPIC_IDS%"
if not "%ADO_AREA_PATH%"=="" set ARGS=%ARGS% -AreaPath "%ADO_AREA_PATH%"
if not "%ADO_TYPES%"=="" set ARGS=%ARGS% -Types "%ADO_TYPES%"
if not "%ADO_CLOSED_WITHIN_DAYS%"=="" set ARGS=%ARGS% -ClosedWithinDays %ADO_CLOSED_WITHIN_DAYS%
if not "%ADO_MAX_PR_DETAILS%"=="" set ARGS=%ARGS% -MaxPrDetails %ADO_MAX_PR_DETAILS%
if not "%ADO_HISTORY_DAYS%"=="" set ARGS=%ARGS% -HistoryDays %ADO_HISTORY_DAYS%
if not "%ADO_ARCHIVE_DAYS%"=="" set ARGS=%ARGS% -ArchiveDays %ADO_ARCHIVE_DAYS%
if not "%ADO_SERVER_URL%"=="" set ARGS=%ARGS% -ServerUrl "%ADO_SERVER_URL%"
if not "%ADO_OUT_DIR%"=="" set ARGS=%ARGS% -OutDir "%ADO_OUT_DIR%"
if "%ADO_INCLUDE_REMOVED%"=="1" set ARGS=%ARGS% -IncludeRemoved
if "%ADO_NO_OPEN%"=="1" set ARGS=%ARGS% -NoOpen

rem The PAT goes to the script through the environment (not the command line),
rem so it does not show up in the process list. setlocal keeps it out of this
rem CMD session once the script ends.
if not "%ADO_PAT_VALUE%"=="" set "ADO_PAT=%ADO_PAT_VALUE%"
set "ADO_PAT_VALUE="

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %ARGS% %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo ado_work_map.ps1 failed with exit code %RC%.
    pause
) else if "%PAUSE_AT_END%"=="1" (
    pause
)
endlocal & exit /b %RC%
