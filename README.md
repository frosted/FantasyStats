# FantasyStats

FantasyStats is a PowerShell toolkit for managing NBA and WNBA fantasy drafts, refreshing player statistics, calculating pool standings, and publishing HTML dashboards. Draft data is kept separately from scraped statistics so a stats refresh does not normally erase a season's picks.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Draft tracking](#draft-tracking)
- [Refreshing player statistics](#refreshing-player-statistics)
- [Generating a team dashboard](#generating-a-team-dashboard)
- [Live draft dashboard](#live-draft-dashboard)
- [Landing page](#landing-page)
- [Data files](#data-files)
- [GitHub Actions and GitHub Pages](#github-actions-and-github-pages)
- [Troubleshooting](#troubleshooting)

## How it works

The usual season workflow is:

1. Prepare or refresh a season database, then use the draft tracker to set the owner order and assign players.
2. During the season, refresh stats from Basketball Reference. The update script writes the new stats into the selected league collection and builds a team dashboard.
3. Build the root landing page so it links to the HTML dashboards in the dashboards directory.
4. Optionally let GitHub Actions run the refresh and commit generated files on its configured schedule.

| Script | Purpose |
| --- | --- |
| `FantasyDraftTracker.ps1` | Windows desktop UI for choosing a database, maintaining the owner order, reviewing/editing player details, and recording draft picks. |
| `Get-PlayerStats.ps1` | Scraping, cleanup, fantasy-value calculation, and LiteDB persistence functions. |
| `Update-FantasyStats.ps1` | Fetches stats for one league/season, updates the database, and generates the team dashboard. |
| `Get-FantasyTeamDashboard.ps1` | Reads draft assignments and player stats, calculates team scores and standings, and renders dashboard HTML. |
| `Start-DraftDashboard.ps1` | Starts a local browser-based live draft view. |
| `Update-Index.ps1` | Scans the configured dashboards directory for HTML files and generates the root `index.html`. |

## Requirements

- PowerShell 7.0 or later (`pwsh`).
- Internet access for the Basketball Reference scraper.
- The LiteDB 5.0.21 assembly included in `packages/LiteDB.5.0.21`.
- Windows for `FantasyDraftTracker.ps1`, which uses Windows Forms. The scraping and HTML-generation scripts are PowerShell Core scripts and are also used on the Ubuntu GitHub Actions runner.
- A browser to view generated HTML or the live draft dashboard.

Run repository commands from the `FantasyStats` directory unless an example says otherwise:

```powershell
Set-Location .\FantasyStats
$PSVersionTable.PSVersion
```

## Quick start

Refresh the default NBA season and generate its team dashboard:

```powershell
pwsh -File .\Update-FantasyStats.ps1
```

Choose a specific season and league:

```powershell
pwsh -File .\Update-FantasyStats.ps1 -Season 2027 -League NBA
pwsh -File .\Update-FantasyStats.ps1 -Season 2027 -League WNBA
```

The default season is the ending year of the season: from October onward, the default is the current year plus one; otherwise it is the current year. The default league is NBA. The NBA update gathers roster players, while the WNBA update uses the standard league stats fetch.

## Draft tracking

Launch the desktop tracker on Windows:

```powershell
pwsh -File .\FantasyDraftTracker.ps1
```

The tracker can use another database directory or a different maximum draft length:

```powershell
pwsh -File .\FantasyDraftTracker.ps1 -DatabaseDirectory .\data -MaximumRounds 13
```

Use the database selector to choose the season and league collection. Add participants to the draft order, move them into the desired order, and use the Draft action to assign the selected player to the owner on the clock. Player details can be corrected in the tracker when needed, such as team or position changes. NBA and WNBA collections are supported.

The draft follows a snake order. The default maximum is 13 rounds. The available position counts are based on eligible C/F/G players among the top `MaximumRounds x owner count` candidates by value. Picks remove players from the available pool; lower-ranked players do not automatically replace them in those counts.

Assignments and the owner order are saved as a JSON sidecar. The tracker can create a sidecar for a new draft and migrate older embedded draft fields when opening a legacy database. Back up databases and sidecars before making bulk edits or running migration-sensitive workflows.

## Refreshing player statistics

`Update-FantasyStats.ps1` calls the functions in `Get-PlayerStats.ps1`, saves the selected league collection, then creates a dashboard unless `-SkipDashboard` is specified.

Examples:

```powershell
# Refresh NBA 2027 and write the default dashboard.
./Update-FantasyStats.ps1 -Season 2027 -League NBA

# Refresh WNBA 2027.
./Update-FantasyStats.ps1 -Season 2027 -League WNBA

# Refresh stats but do not generate HTML.
./Update-FantasyStats.ps1 -Season 2027 -League NBA -SkipDashboard

# Choose explicit output locations.
./Update-FantasyStats.ps1 `
	-Season 2027 `
	-League NBA `
	-DatabaseDirectory .\data `
	-DashboardPath .\Dashboards\TeamDashboard_2027.html
```

The default database path is `data/<season>.db`. NBA and WNBA are separate collections in that file, so updating one league does not replace the other. Each save transaction replaces the selected league's collection; it is a refresh, not a merge. If no valid players are returned, the update script stops instead of replacing the collection with an empty result.

To call the lower-level functions directly, dot-source the scraper module:

```powershell
. .\Get-PlayerStats.ps1

$season = 2027
$league = 'NBA'
$players = @(Get-PlayerStats -League $league -Season $season)
if ($players.Count -eq 0) {
	throw "No player stats were returned for $league $season; database was not updated."
}

$saveResult = Save-PlayerStatsToLiteDb `
	-Players $players `
	-League $league `
	-Season $season
$saveResult | Format-List
```

For NBA, `Get-AllPlayersStats` includes roster players who have not appeared in a game and adds injury details when available:

```powershell
. .\Get-PlayerStats.ps1

$season = 2027
$players = @(Get-AllPlayersStats -Season $season)
if ($players.Count -eq 0) {
	throw "No NBA roster players were returned for $season; database was not updated."
}

Save-PlayerStatsToLiteDb -Players $players -League NBA -Season $season
```

Refresh several seasons, skipping any season for which the source returns no rows:

```powershell
. .\Get-PlayerStats.ps1

foreach ($season in 2020..2027) {
	$players = @(Get-PlayerStats -League WNBA -Season $season)
	if ($players.Count -eq 0) {
		Write-Warning "No WNBA stats returned for $season; skipping."
		continue
	}

	Save-PlayerStatsToLiteDb -Players $players -League WNBA -Season $season
}
```

Player value is calculated as `PTS + REB + AST - (2 x TOV)`. The `elig_pos` value is derived from the final position character when no explicit eligibility is present. Traded-player rows are cleaned before saving, blank numeric stats are treated as zero, and rows without both a team and position are skipped. Player names are currently used as LiteDB document IDs, so changing a player's name can prevent an existing draft assignment from matching that player after a refresh.

## Generating a team dashboard

The update script generates the default dashboard automatically. To generate it directly, dot-source `Get-FantasyTeamDashboard.ps1` and pipe the scores to the HTML writer:

```powershell
. .\Get-FantasyTeamDashboard.ps1

$season = 2027
$databasePath = ".\data\$season.db"
$dashboardPath = ".\Dashboards\TeamDashboard_$season.html"

Get-FantasyTeamScoreFromDatabase -DatabasePath $databasePath -Collection NBA |
	New-FantasyWebDashboard `
		-Path $dashboardPath `
		-Title "Chumpball $($season - 1) - $season"
```

Choose a league and optionally restrict the dashboard to selected owners:

```powershell
Get-FantasyTeamScoreFromDatabase `
	-DatabasePath .\data\2027.db `
	-Collection WNBA `
	-Owner 'Owner One', 'Owner Two' |
	New-FantasyWebDashboard `
		-Path .\Dashboards\WNBA_TeamDashboard_2027.html `
		-Title 'WNBA Chumpball 2026 - 2027'
```

The dashboard reads assignments from the matching JSON sidecar and joins them to player stats by `player_id`. Unassigned players are not included in owner scores. An owner must have exactly 13 drafted players and enough position eligibility to fill two lineups, each with one C, two F, and two G slots; the remaining three players are the bench. Owners who do not meet these rules are skipped or produce a clear position-availability error.

The dashboard includes standings, team and bench breakdowns, per-game averages, and injury details when available. The scoring value is the sum of points, rebounds, and assists minus twice turnovers.

### Side bets

The dashboard reads side bets from `data/side-bets-<season>.json`. Edit the JSON file for the season before running `Update-FantasyStats.ps1`; the generated dashboard displays bettors, the bet description, and the wager. If the season file is missing or has no bets, the table displays an empty-state row. Bettors are stored as an array and displayed joined with `vs`.

```json
{
	"season": 2027,
	"bets": [
		{
			"bettors": ["Jay", "Ed"],
			"bet": "Team A+B (Centers only)",
			"wager": "Not specified"
		},
		{
			"bettors": ["Jayden", "Ed"],
			"bet": "Team A+B",
			"wager": "Shooting machine rental"
		}
	]
}
```

## Live draft dashboard

Start the local browser dashboard:

```powershell
pwsh -File .\Start-DraftDashboard.ps1
```

Open `http://127.0.0.1:8765/`. To use a different port:

```powershell
pwsh -File .\Start-DraftDashboard.ps1 -Port 9000
```

The page refreshes every two seconds, lets you select a season database and NBA/WNBA collection, and displays the current owner assignments in draft order. This is a local server; screen-sharing the browser is a simple way to show picks to remote participants. Stop the server with `Ctrl+C` in its PowerShell window.

## Landing page

Run the index generator from the repository root:

```powershell
pwsh -File .\Update-Index.ps1
```

It scans the `Dashboards` directory for `.html` files, creates a card for each dashboard, and writes `index.html` in the repository root. Add a generated dashboard to that directory and rerun the script to include it in the landing page.

**Linux path capitalization:** the update scripts and workflow refer to `Dashboards/`, while the checked-in directory in this repository is currently named `dashboards/`. Windows treats those names as equivalent, but Ubuntu does not. Before relying on the GitHub Actions workflow, rename the tracked directory to `Dashboards/` or change every script and workflow reference to use `dashboards/` consistently.

## Data files

### Season databases

Each `data/<season>.db` file is a LiteDB database. It can contain an `NBA` and a `WNBA` collection for the same season. Player documents contain the stats used by the dashboard; draft ownership is stored separately.

### Draft sidecars

Each draft JSON file stores the ordered owners and player assignments. A representative sidecar looks like this:

```json
{
  "version": 1,
  "owners": ["Owner One", "Owner Two"],
  "assignments": [
	{
	  "collection": "NBA",
	  "player_id": "A.J. Green",
	  "owner": "Owner One",
	  "draft_position": 1,
	  "elig_pos": "G"
	},
	{
	  "collection": "WNBA",
	  "player_id": "A'ja Wilson",
	  "owner": "Owner Two",
	  "draft_position": 1,
	  "elig_pos": "F"
	}
  ]
}
```

`player_id` matches the LiteDB document `_id` (currently the player name). `draft_position` is the overall pick number, and `collection` distinguishes leagues. In the tracker, drafting the upcoming season from `2026.db` uses `2027.json`; dashboard generation for `2027.db` uses the same-stem `2027.json`. Keep the correct sidecar alongside the corresponding season database when copying or restoring data.

The tracker migrates older `owner`, `draft_pos`, `drafted`, and `draft_owners` data into the sidecar when it opens a legacy database. The scraper excludes those legacy fields from refreshed player records.

### Query a database

This example loads LiteDB, reads one player, and returns NBA point leaders. Replace the collection with `WNBA` to query that league:

```powershell
$liteDbAssembly = Resolve-Path '.\packages\LiteDB.5.0.21\lib\netstandard2.0\LiteDB.dll'
Add-Type -Path $liteDbAssembly

$databasePath = Resolve-Path '.\data\2027.db'
$database = [LiteDB.LiteDatabase]::new($databasePath)
try {
	$players = $database.GetCollection[LiteDB.BsonDocument]('NBA')

	$player = $players.FindById('A.J. Green')
	if ($null -ne $player) {
		[pscustomobject]@{
			Player = $player['player'].AsString
			Team   = $player['team_name_abbr'].AsString
			Points = $player['pts'].AsInt64
		}
	}

	$leaders = $players.Find(
		[LiteDB.Query]::GT('pts', [LiteDB.BsonValue]::new([long] 2000))
	)
	$leaders | ForEach-Object {
		[pscustomobject]@{
			Player = $_['player'].AsString
			Points = $_['pts'].AsInt64
		}
	} | Sort-Object Points -Descending
}
finally {
	$database.Dispose()
}
```

LiteDB values are BSON values; use typed accessors such as `.AsString`, `.AsInt64`, or `.AsDouble` when reading them.

## GitHub Actions and GitHub Pages

The workflow is defined in `.github/workflows/update-stats.yml`. It supports scheduled runs and manual `workflow_dispatch`. The current cron expression runs every six hours (`0 */6 * * *`); change the cron expression if a once-daily run is preferred.

The job runs on `ubuntu-latest` with PowerShell Core, refreshes stats and the team dashboard, runs `Update-Index.ps1`, and stages `index.html`, `Dashboards/`, and `data/`. It has `contents: write` permission and commits generated changes as `github-actions[bot]` only when there is a diff to commit.

The workflow pushes generated files to the repository; it does not contain a separate GitHub Pages deployment action. Configure Pages in the repository settings to publish from the branch and folder where these generated files are committed. The first publish can take a few minutes. Keep scrape requests and the configured schedule within the source site's acceptable usage.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No players returned or a scrape fails | Confirm internet access and that Basketball Reference is reachable; rerun later if the source is unavailable. The database is not replaced when the update returns no valid players. |
| Dashboard reports a missing sidecar | Open the database in `FantasyDraftTracker.ps1` to create or migrate its draft JSON, and check that the sidecar season matches the database/dashboard. |
| Owner is omitted from standings | Confirm the owner has exactly 13 assignments and the roster can fill the two C/F/G lineups. |
| Dashboard or index folder is not found on Ubuntu | Check the exact capitalization of `Dashboards` versus `dashboards`; Linux paths are case-sensitive. |
| LiteDB assembly cannot be loaded | Confirm `packages/LiteDB.5.0.21/lib/netstandard2.0/LiteDB.dll` is present and PowerShell 7 or later is running. |
| The generated site does not update | Check the Actions run and commit permissions, then verify GitHub Pages is configured to publish from the branch/folder receiving the generated files. |