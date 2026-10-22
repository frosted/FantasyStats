#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-FantasyTeamScoreFromDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$DatabasePath,
        [ValidateSet('NBA', 'WNBA')][string]$Collection = 'NBA',
        [string[]]$Owner
    )

    begin {
        $dll = Join-Path $PSScriptRoot 'packages\LiteDB.5.0.21\lib\netstandard2.0\LiteDB.dll'
        if (-not ('LiteDB.LiteDatabase' -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
        $field = {
            param($doc, $name)
            if ($doc.ContainsKey($name) -and -not $doc[$name].IsNull) { $doc[$name].RawValue }
        }
    }
    process {
        $resolved = (Resolve-Path -LiteralPath $DatabasePath -ErrorAction Stop).ProviderPath
        $draftDataPath = [System.IO.Path]::ChangeExtension($resolved, '.json')
        if (-not (Test-Path -LiteralPath $draftDataPath -PathType Leaf)) {
            throw "Draft sidecar '$draftDataPath' was not found. Open the season database in FantasyDraftTracker to create or migrate it."
        }
        $draftData = Get-Content -LiteralPath $draftDataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $order = [System.Collections.Generic.List[string]]::new()
        foreach ($ownerName in @($draftData.owners)) {
            if (-not [string]::IsNullOrWhiteSpace([string] $ownerName)) { $order.Add([string] $ownerName) }
        }

        $assignmentsById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($assignment in @($draftData.assignments)) {
            if ([string] $assignment.collection -ne $Collection) { continue }
            $playerId = [string] $assignment.player_id
            if ([string]::IsNullOrWhiteSpace($playerId)) { continue }
            if ($assignmentsById.ContainsKey($playerId)) {
                throw "Draft sidecar '$draftDataPath' contains duplicate player_id '$playerId' for collection '$Collection'."
            }
            $assignmentsById.Add($playerId, $assignment)
        }

        $cs = [LiteDB.ConnectionString]::new()
        $cs.Filename = $resolved
        $cs.Connection = [LiteDB.ConnectionType]::Shared
        $cs.ReadOnly = $true
        $db = [LiteDB.LiteDatabase]::new($cs)
        try {
            $playersById = [System.Collections.Generic.Dictionary[string, LiteDB.BsonDocument]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($doc in $db.GetCollection[LiteDB.BsonDocument]($Collection).FindAll()) {
                $id = [string] (& $field $doc '_id')
                if (-not [string]::IsNullOrWhiteSpace($id)) { $playersById[$id] = $doc }
            }

            $players = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in $assignmentsById.GetEnumerator()) {
                $assignment = $entry.Value
                $drafter = [string] $assignment.owner
                if ([string]::IsNullOrWhiteSpace($drafter)) { continue }
                if (-not $playersById.ContainsKey($entry.Key)) {
                    $assignmentEligibility = $assignment.PSObject.Properties['elig_pos']
                    $players.Add([pscustomobject]@{
                        player_id      = $entry.Key
                        owner          = $drafter
                        player         = $entry.Key
                        team_name_abbr = ''
                        elig_os        = if ($null -ne $assignmentEligibility) { [string] $assignmentEligibility.Value } else { '' }
                        draft_pos      = $assignment.draft_position
                        games          = 0
                        pts            = 0
                        trb            = 0
                        ast            = 0
                        tov            = 0
                        value          = 0
                        injured        = $false
                        injury_note    = ''
                    })
                    continue
                }
                $doc = $playersById[$entry.Key]
                $assignmentEligibility = $assignment.PSObject.Properties['elig_pos']
                $position = if ($null -ne $assignmentEligibility) { [string] $assignmentEligibility.Value } else { '' }
                if ([string]::IsNullOrWhiteSpace($position)) {
                    $position = [string] (& $field $doc 'elig_pos')
                }
                if ([string]::IsNullOrWhiteSpace($position)) {
                    $rawPosition = [string] (& $field $doc 'pos')
                    if (-not [string]::IsNullOrWhiteSpace($rawPosition)) {
                        $position = $rawPosition.Trim().Substring($rawPosition.Trim().Length - 1).ToUpperInvariant()
                    }
                }
                [pscustomobject]@{
                    player_id      = $entry.Key
                    owner          = [string]$drafter
                    player         = [string](& $field $doc 'player')
                    team_name_abbr = [string]((& $field $doc 'team_name_abbr') ?? (& $field $doc 'team'))
                    elig_os        = $position
                    draft_pos      = $assignment.draft_position
                    games          = (& $field $doc 'games') ?? (& $field $doc 'g') ?? 0
                    pts            = (& $field $doc 'pts') ?? 0
                    trb            = (& $field $doc 'trb') ?? 0
                    ast            = (& $field $doc 'ast') ?? 0
                    tov            = (& $field $doc 'tov') ?? 0
                    value          = (& $field $doc 'value') ?? 0
                    injured        = [bool] ((& $field $doc 'injured') ?? $false)
                    injury_note    = [string] ((& $field $doc 'injury_note') ?? '')
                } | ForEach-Object { $players.Add($_) }
            }
        }
        finally { $db.Dispose() }

        foreach ($group in $players.ToArray() | Group-Object owner | Sort-Object Name) {
            if ($Owner -and $group.Name -notin $Owner) { continue }
            if ($group.Count -ne 13) {
                Write-Warning "Skipping '$($group.Name)': $($group.Count) players drafted (expected 13)."
                continue
            }
            Get-FantasyTeamScore -OwnerName $group.Name -Players $group.Group -DraftPosition ($order.IndexOf($group.Name) + 1)
        }
    }
}

function Get-FantasyTeamScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OwnerName,
        [Parameter(Mandatory)][ValidateCount(13, 13)][object[]]$Players,
        [int]$DraftPosition = 0
    )

    $pool = [System.Collections.Generic.List[object]]::new()
    $Players | Sort-Object { [double]$_.value } -Descending | ForEach-Object { $pool.Add($_) }

    # Removes and returns the top $Count players of a position from the pool.
    function Select-Slot([string]$Pos, [int]$Count) {
        $picked = @($pool | Where-Object elig_os -eq $Pos | Select-Object -First $Count)
        if ($picked.Count -lt $Count) {
            throw "Owner '$OwnerName': need $Count '$Pos' player(s) but only $($picked.Count) available."
        }
        foreach ($p in $picked) { [void]$pool.Remove($p) }
        $picked
    }

    function Get-Avg([double]$Value, [double]$Games) {
        if ($Games -eq 0) { return '0.00' }
        ($Value / $Games).ToString('F2', [cultureinfo]::InvariantCulture)
    }

    function ConvertTo-Row($p) {
        $injuredProperty = $p.PSObject.Properties['injured']
        $injuryNoteProperty = $p.PSObject.Properties['injury_note']
        [pscustomobject]@{
            Pos    = [string]$p.elig_os
            Player = [string]$p.player
            Team   = [string]$p.team_name_abbr
            Round  = [string]$p.draft_pos
            GP     = [double]$p.games
            PTS    = [double]$p.pts
            REB    = [double]$p.trb
            AST    = [double]$p.ast
            TOV    = [double]$p.tov
            Score  = [double]$p.value
            AVG    = Get-Avg ([double]$p.value) ([double]$p.games)
            Injured = ($null -ne $injuredProperty -and [bool] $injuredProperty.Value)
            InjuryNote = if ($null -ne $injuryNoteProperty) { [string] $injuryNoteProperty.Value } else { '' }
            IsTotal = $false
        }
    }

    function New-Group([string]$Label, [object[]]$Members) {
        $rows = @($Members | ForEach-Object { ConvertTo-Row $_ })
        $sum = { param($n) [double]($rows | Measure-Object -Property $n -Sum).Sum }
        $total = [pscustomobject]@{
            Pos    = ''
            Player = $Label
            Team   = ''
            Round  = ''
            GP     = & $sum 'GP'
            PTS    = & $sum 'PTS'
            REB    = & $sum 'REB'
            AST    = & $sum 'AST'
            TOV    = & $sum 'TOV'
            Score  = & $sum 'Score'
            AVG    = $null
            IsTotal = $true
        }
        $total.AVG = Get-Avg $total.Score $total.GP
        @($rows) + $total
    }

    $teamA = @(Select-Slot 'C' 1) + @(Select-Slot 'F' 2) + @(Select-Slot 'G' 2)
    $teamB = @(Select-Slot 'C' 1) + @(Select-Slot 'F' 2) + @(Select-Slot 'G' 2)
    $bench = @($pool)

    [pscustomobject]@{
        OwnerName     = $OwnerName
        DraftPosition = $DraftPosition
        TeamA     = New-Group 'Team A' $teamA
        TeamB     = New-Group 'Team B' $teamB
        Bench     = New-Group 'Bench' $bench
    }
}

function New-FantasyWebDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][pscustomobject]$TeamScore,
        [Parameter(Mandatory)][string]$Path,
        [string]$Title = 'Chumpball Fantasy Basketball'
    )

    begin {
        $teams = [System.Collections.Generic.List[object]]::new()
        $inv = [cultureinfo]::InvariantCulture
        $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
        $f0 = { param($v) ([double]$v).ToString('F0', $inv) }
        $avg = { param($s, $g) if ([double]$g -eq 0) { '0.00' } else { ([double]$s / [double]$g).ToString('F2', $inv) } }
    }
    process { $teams.Add($TeamScore) }
    end {
        $css = @'
body{font-family:Arial,"Segoe UI",sans-serif;font-size:13px;color:#000;margin:0;padding:16px;background:#fff;max-width:100vw}
.banner{position:sticky;top:0;z-index:100;background:#000;color:#fff;text-align:right;text-transform:uppercase;font-size:16px;padding:6px 8px;margin-bottom:20px}
.wrap{display:grid;grid-template-columns:minmax(0,1fr) minmax(300px,340px);gap:24px;align-items:start}
.wrap>div{min-width:0}
.table-scroll,.team-scroll{max-width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch;margin-bottom:18px}
.table-scroll table,.team-scroll table{margin-bottom:0}
.team-scroll table{min-width:760px}
@media(max-width:1000px){.wrap{grid-template-columns:minmax(0,1fr)}}
@media(max-width:600px){body{padding:8px}.banner{text-align:left;font-size:14px;margin-bottom:12px}.wrap{gap:14px}.table-scroll table{min-width:420px}.team-scroll table{min-width:760px}.injury-legend{padding:0 4px}}
table{border-collapse:collapse;width:100%;border:1px solid #000;margin-bottom:18px}
th,td{padding:3px 8px;white-space:nowrap}
th{text-align:left;font-weight:700}
.r{text-align:right;font-variant-numeric:tabular-nums}.c{text-align:center}
.injury-marker{color:#c00}
.injury-legend{font-size:12px;color:#333;margin:-4px 0 18px;padding:0 8px}
tr.own td{background:#000;color:#fff;font-weight:700}
tr.cols th{border-top:1px solid #000;border-bottom:1px solid #000}
tr.cols th:first-child{border-left:1px solid #000}
tr.cols th:last-child{border-right:1px solid #000}
tr.tot td{padding-top:4px;border:0;font-weight:700}
tr.tot.sep td{border-bottom:1px dotted #000}
tr.bench td{padding-bottom:6px}
.side .hdr{background:#000;color:#fff;text-align:center;font-weight:700;padding:6px;margin:0 0 18px}
.side table th.c{border-bottom:0}
'@

        $box = {
            param([string]$Heading, [string[]]$Headers, [string[]]$Aligns, [object[]]$Rows)
            $th = for ($i = 0; $i -lt $Headers.Count; $i++) { "<th class=`"$($Aligns[$i])`">$(& $enc $Headers[$i])</th>" }
            $values = @($Rows | ForEach-Object { foreach ($cell in $_) { $cell } })
            $tr = for ($rowStart = 0; $rowStart -lt $values.Count; $rowStart += $Headers.Count) {
                $td = for ($i = 0; $i -lt $Headers.Count; $i++) { "<td class=`"$($Aligns[$i])`">$(& $enc $values[$rowStart + $i])</td>" }
                "<tr>$($td -join '')</tr>"
            }
            "<div class=`"table-scroll`"><table><thead><tr><th class=`"c`" colspan=`"$($Headers.Count)`">$(& $enc $Heading)</th></tr><tr>$($th -join '')</tr></thead><tbody>$($tr -join '')</tbody></table></div>"
        }

        $standing = {
            param([string]$Heading, [string]$First, [object[]]$Entries)
            $i = 0
            $rows = foreach ($e in $Entries | Sort-Object Score -Descending) {
                $i++
                , @("$i. $($e.Name)", (& $f0 $e.Score), (& $f0 $e.GP), (& $avg $e.Score $e.GP))
            }
            & $box $Heading @($First, 'Score', 'GP', 'Avg') @('l', 'r', 'r', 'r') $rows
        }

        $standingOf = { param($prop) $teams | ForEach-Object { $tot = $_.$prop[-1]; [pscustomobject]@{ Name = $_.OwnerName; Score = $tot.Score; GP = $tot.GP } } }
        $both = $teams | ForEach-Object {
            $a = $_.TeamA[-1]; $b = $_.TeamB[-1]
            [pscustomobject]@{ Name = $_.OwnerName; Score = $a.Score + $b.Score; GP = $a.GP + $b.GP }
        }

        $everyone = foreach ($t in $teams) {
            foreach ($row in @($t.TeamA) + @($t.TeamB) + @($t.Bench)) {
                if ($row.IsTotal) { continue }
                $row | Select-Object Player, Team, GP, PTS, REB, AST, TOV, Score,
                    @{ n = 'AVG'; e = { if ($_.GP -gt 0) { $_.Score / $_.GP } else { 0 } } }
            }
        }
        $leader = {
            param([string]$Metric)
            $rows = $everyone | Sort-Object $Metric -Descending | Select-Object -First 5 | ForEach-Object {
                , @($_.Player, $_.Team, (& $f0 $_.GP), (& $f0 $_.$Metric))
            }
            & $box $Metric @('Player', 'Team', 'GP', $Metric) @('l', 'l', 'r', 'r') $rows
        }

        $hdr = 'Player', 'Team', 'Pos', 'Pick', 'GP', 'PTS', 'REB', 'AST', 'TOV', 'Score', 'AVG'
        $al = 'l', 'l', 'l', 'r', 'r', 'r', 'r', 'r', 'r', 'r', 'r'
        $th = (0..10 | ForEach-Object { "<th class=`"$($al[$_])`">$($hdr[$_])</th>" }) -join ''
        $nums = 'GP', 'PTS', 'REB', 'AST', 'TOV', 'Score'

        $owners = foreach ($t in $teams | Sort-Object { if ($_.DraftPosition -gt 0) { $_.DraftPosition } else { [int]::MaxValue } }) {
            $rows = foreach ($row in @($t.TeamA) + @($t.TeamB) + @($t.Bench)) {
                $cells = ($nums | ForEach-Object { "<td class=`"r`">$(& $f0 $row.$_)</td>" }) -join ''
                if ($row.IsTotal) {
                    $cls = if ($row.Player -eq 'Bench') { 'tot bench' } else { 'tot sep' }
                    "<tr class=`"$cls`"><td class=`"r`" colspan=`"4`">$(& $enc $row.Player):</td>$cells<td class=`"r`">$($row.AVG)</td></tr>"
                }
                else {
                    $playerNameHtml = $(& $enc $row.Player)
                    $rowTitle = ''
                    if ($row.Injured) {
                        $playerNameHtml += ' <span class="injury-marker">*</span>'
                        if (-not [string]::IsNullOrWhiteSpace($row.InjuryNote)) {
                            $rowTitle = " title=`"$(& $enc $row.InjuryNote)`""
                        }
                    }
                    "<tr$rowTitle><td>$playerNameHtml</td><td>$(& $enc $row.Team)</td><td>$(& $enc $row.Pos)</td>" +
                    "<td class=`"r`">$(& $enc $row.Round)</td>$cells<td class=`"r`">$($row.AVG)</td></tr>"
                }
            }
            "<div class=`"team-scroll`"><table><thead><tr class=`"own`"><td colspan=`"8`">$(& $enc $t.OwnerName)</td>" +
            "<td class=`"r`" colspan=`"3`">Draft Position: $($t.DraftPosition)</td></tr><tr class=`"cols`">$th</tr></thead>" +
            "<tbody>$($rows -join "`n")</tbody></table></div>"
        }

        $injuryCounts = foreach ($team in $teams) {
            $teamACount = @($team.TeamA | Where-Object { -not $_.IsTotal -and $_.Injured }).Count
            $teamBCount = @($team.TeamB | Where-Object { -not $_.IsTotal -and $_.Injured }).Count
            $benchCount = @($team.Bench | Where-Object { -not $_.IsTotal -and $_.Injured }).Count
            [pscustomobject]@{
                Owner = $team.OwnerName
                TeamA = $teamACount
                TeamB = $teamBCount
                Bench = $benchCount
                Total = $teamACount + $teamBCount + $benchCount
            }
        }
        $mostInjuriesRows = @(
            foreach ($entry in $injuryCounts | Sort-Object -Property @{ Expression = 'Total'; Descending = $true }, @{ Expression = 'Owner'; Descending = $false }) {
                , @($entry.Owner, $entry.TeamA, $entry.TeamB, $entry.Bench, $entry.Total)
            }
        )
        $injuredPlayerRows = @(
            foreach ($team in $teams) {
                foreach ($row in @($team.TeamA) + @($team.TeamB) + @($team.Bench)) {
                    if ($row.IsTotal -or -not $row.Injured) { continue }
                    [pscustomobject]@{
                        Owner = $team.OwnerName
                        Player = $row.Player
                        Team = $row.Team
                        GP = $row.GP
                        AVG = $row.AVG
                    }
                }
            }
        ) | Sort-Object Owner, Player
        $injuredPlayersRows = @(
            foreach ($player in $injuredPlayerRows) {
                , @($player.Owner, $player.Player, $player.Team, (& $f0 $player.GP), [string] $player.AVG)
            }
        )
        if ($injuredPlayersRows.Count -eq 0) {
            $injuredPlayersRows = @(, @('No injured players', '', '', '', ''))
        }

        $side = @(
            (& $standing 'Team A Standings' 'Team A Owner' (& $standingOf 'TeamA'))
            (& $standing 'Team B Standings' 'Team B Owner' (& $standingOf 'TeamB'))
            (& $standing 'Team A+B Standings' 'Owner' $both)
            '<div class="hdr">Leaderboards</div>'
            'Score', 'AVG', 'PTS', 'REB', 'AST', 'TOV' | ForEach-Object { & $leader $_ }
            '<div class="hdr">Injuries</div>'
            (& $box 'Most Injuries' @('Owner', 'Team A', 'Team B', 'Bench', 'Total') @('l', 'r', 'r', 'r', 'r') $mostInjuriesRows)
            (& $box 'Injured Players' @('Owner', 'Player', 'Team', 'GP', 'AVG') @('l', 'l', 'l', 'r', 'r') $injuredPlayersRows)
        )

        $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(& $enc $Title)</title><style>$css</style></head>
<body><div class="banner">$(& $enc $Title)</div>
<div class="wrap"><div>
$($owners -join "`n")
<div class="injury-legend"><span class="injury-marker">*</span> indicates an injured player. Hover over the asterisk for injury details.</div>
</div><div class="side">
$($side -join "`n")
</div></div>
</body></html>
"@
    $outputDirectory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    }
        Set-Content -LiteralPath $Path -Value $html -Encoding utf8
        Get-Item -LiteralPath $Path
    }
}
