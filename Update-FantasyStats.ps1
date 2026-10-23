#requires -Version 7.0
[CmdletBinding()]
param (
    # Season is the ending year, e.g. 2027 for 2026-27.
    [int] $Season = $(if ((Get-Date).Month -ge 10) { (Get-Date).Year + 1 } else { (Get-Date).Year }),
    [ValidateSet('NBA', 'WNBA')]
    [string] $League = 'NBA',
    [string] $DatabaseDirectory = (Join-Path $PSScriptRoot 'data'),
    [string] $DashboardPath = (Join-Path $PSScriptRoot "Dashboards\TeamDashboard_$Season.html"),
    [string] $SideBetsPath = (Join-Path (Join-Path $PSScriptRoot 'data') "side-bets-$Season.json"),
    [switch] $SkipDashboard
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Get-PlayerStats.ps1')
. (Join-Path $PSScriptRoot 'Get-FantasyTeamDashboard.ps1')

Write-Host "Fetching $League stats for $Season..."
$players = if ($League -eq 'NBA') {
    @(Get-AllPlayersStats -Season $Season)
}
else {
    @(Get-PlayerStats -League $League -Season $Season)
}

if ($players.Count -eq 0) {
    throw "No player stats were returned for $League $Season; database was not updated."
}

$saveResult = Save-PlayerStatsToLiteDb -Players $players -League $League -Season $Season -DatabaseDirectory $DatabaseDirectory
$saveResult | Format-List | Out-String | Write-Host

if ($SkipDashboard) { return }

$databasePath = Join-Path $DatabaseDirectory "$Season.db"
$dashboardDirectory = Split-Path -Parent $DashboardPath
if (-not (Test-Path -LiteralPath $dashboardDirectory)) {
    New-Item -ItemType Directory -Path $dashboardDirectory -Force | Out-Null
}

Get-FantasyTeamScoreFromDatabase -DatabasePath $databasePath -Collection $League |
    New-FantasyWebDashboard -Path $DashboardPath -Title "Chumpball $($Season - 1) - $Season" -SideBetsPath $SideBetsPath

Write-Host "Dashboard written to $DashboardPath"
