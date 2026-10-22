# FantasyStats

## Get player stats and update the database

From the workspace root, dot-source the script, fetch a league and season from Basketball Reference, then save the results:

```powershell
. .\FantasyStats\Get-PlayerStats.ps1

$league = 'NBA' # Use 'WNBA' for women's stats.
$season = 2027
$stats = @(Get-PlayerStats -League $league -Season $season)
if ($stats.Count -eq 0) {
	throw "No player stats were returned for $league $season; database was not updated."
}

$saveResult = Save-PlayerStatsToLiteDb -Players $stats -League $league -Season $season
$saveResult | Format-List

@(2020..2027) | % { $stats = Get-PlayerStats -League NBA -Season $_; $saveResult = Save-PlayerStatsToLiteDb -Players $stats -League NBA -Season $_; $saveResult} 

@(2020..2027) | % { $stats = Get-PlayerStats -League WNBA -Season $_; $saveResult = Save-PlayerStatsToLiteDb -Players $stats -League WNBA -Season $_; $saveResult} 
```

To include every NBA player listed on a team roster, including players who have not appeared in a game, collect the season rosters and injury reports before saving:

```powershell
. .\FantasyStats\Get-PlayerStats.ps1

$season = 2027
$allPlayers = @(Get-AllPlayersStats -Season $season)
if ($allPlayers.Count -eq 0) {
	throw "No NBA roster players were returned for $season; database was not updated."
}

$saveResult = Save-PlayerStatsToLiteDb -Players $allPlayers -League NBA -Season $season
$saveResult | Format-List
```

`Get-AllPlayersStats` gathers teams from both conference standings, combines their roster pages with season totals, and marks roster players found in the injury report with `injured = $true` and an `injury_note`. Roster players without season totals are still included with zero-valued statistics. Saving replaces the entire NBA collection for that season, just like `Get-PlayerStats` data.

By default, stats are stored in `FantasyStats/data/<season>.db`, in a collection named for the league. NBA and WNBA data for the same season can share one database file. The result reports the database path, collection, and number of saved players. To use another directory, pass `-DatabaseDirectory` to `Save-PlayerStatsToLiteDb`.

Saving replaces the selected league's entire collection transactionally; it does not merge with existing records. Draft assignments are stored separately in `FantasyStats/data/<season>.json`, so refreshing stats does not clear them as long as the player's LiteDB `_id` remains the same. Saving one league does not replace the other league's collection in the same season database.

To refresh WNBA stats for several seasons, for example:

```powershell
@(2020..2026) | ForEach-Object {
	$season = $_
	$stats = @(Get-PlayerStats -League WNBA -Season $season)
	if ($stats.Count -eq 0) {
		Write-Warning "No WNBA stats returned for $season; skipping database update."
		return
	}

	Save-PlayerStatsToLiteDb -Players $stats -League WNBA -Season $season
}
```

`Get-PlayerStats` returns traded-player-cleaned rows with a numeric `value` field calculated as `pts + trb + ast - (tov * 2)` and an `elig_pos` field defaulted to the uppercase final character of `pos`. Blank stat values are treated as zero. `Save-PlayerStatsToLiteDb` repeats cleanup and calculation before BSON conversion, skips rows where both `team` and `pos` are blank, and leaves the database unchanged if no rows qualify. It excludes `owner`, `draft_pos`, and the legacy `drafted` field from player documents. LiteDB 5.0.21 is included under `packages/LiteDB.5.0.21`.

The draft tracker includes an editable draft-order list under Player Details. Owner order and player assignments are stored in a JSON sidecar next to each database. Opening a season database with the tracker creates the sidecar and migrates legacy `owner`, `draft_pos`, and `draft_owners` data the first time. Position availability counts C/F/G eligibility among the top `MaximumRounds × owner count` draft candidates by Value; drafted players reduce those counts without lower-ranked players replacing them.

When drafting the upcoming season from a database, the tracker names its sidecar for that next season: opening `2026.db` uses `2027.json`. If a same-stem legacy JSON file exists, the tracker carries its data forward. Dashboards instead always load the same-stem file as the selected database: `2027.db` uses `2027.json`. `player_id` is the LiteDB document `_id` (currently the player name); `draft_position` is the overall pick number. The collection identifies which league the assignment belongs to:

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

## Create a team dashboard

From the workspace root, dot-source the dashboard script, then read the season database and pipe its team scores to the HTML generator:

```powershell
. .\FantasyStats\Get-FantasyTeamDashboard.ps1

$season = 2027
$databasePath = ".\FantasyStats\data\$($season).db"
$dashboardPath = ".\FantasyStats\Dashboards\TeamDashboard_$($season).html"
Get-FantasyTeamScoreFromDatabase -DatabasePath $databasePath -Collection NBA |
	New-FantasyWebDashboard -Path $dashboardPath -Title "Chumpball $($season-1) - $($season)"
```

Keep the matching `2027.json` sidecar next to `2027.db`. The dashboard joins assignments from that file to player stats using `player_id`, groups by owner, and excludes unowned players. Change the database path and collection (`NBA` or `WNBA`) for the season and league you want. The script creates the HTML file at the specified path; open it in a browser to view the dashboard. Only owners with exactly 13 drafted players are included. Each included roster must also have enough C, F, and G eligibility to fill the two team lineups. Use the optional `-Owner 'Owner Name'` parameter on `Get-FantasyTeamScoreFromDatabase` to include only selected owners.

## Live draft dashboard

Start the local dashboard server from the workspace root:

```powershell
.\FantasyStats\Start-DraftDashboard.ps1
```

Then open `http://127.0.0.1:8765/` in a browser. The page refreshes every two seconds, groups drafted players by owner in draft order, and omits stat columns. It supports selecting a season database and league collection, and reads each season's assignments from its matching JSON sidecar.

## Querying a database

Open the season database and choose the league collection. Documents use the player name as `_id`:

```powershell
$liteDbAssembly = Resolve-Path '.\FantasyStats\packages\LiteDB.5.0.21\lib\netstandard2.0\LiteDB.dll'
Add-Type -Path $liteDbAssembly

$databasePath = Resolve-Path '.\FantasyStats\data\2027.db'
$database = [LiteDB.LiteDatabase]::new($databasePath)
try {
	$nba = $database.GetCollection[LiteDB.BsonDocument]('NBA')

	# Look up one player by document ID.
	$player = $nba.FindById('A.J. Green')
	if ($null -ne $player) {
		[pscustomobject]@{
			Player = $player['player'].AsString
			Team   = $player['team_name_abbr'].AsString
			Points = $player['pts'].AsInt64
		}
	}

	# Find NBA players with more than 2,000 points.
	$leaders = $nba.Find([LiteDB.Query]::GT('pts', [LiteDB.BsonValue]::new([long] 2000)))
	$leaders | ForEach-Object {
		[pscustomobject]@{
			Player = $_['player'].AsString
			Points = $_['pts'].AsInt64
		}
	} | Sort-Object Points -Descending

	# Use 'WNBA' instead to query the WNBA collection in the same file.
	$wnba = $database.GetCollection[LiteDB.BsonDocument]('WNBA')
}
finally {
	$database.Dispose()
}
```

The stat fields are BSON values. Use accessors such as `.AsString`, `.AsInt64`, or `.AsDouble` to read them as PowerShell values. The query above uses a numeric BSON value so `pts` is compared numerically.

Pass `-DatabaseDirectory` to `Save-PlayerStatsToLiteDb` to store the database files in a different directory.