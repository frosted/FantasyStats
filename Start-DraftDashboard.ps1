[CmdletBinding()]
param (
    [string] $DatabaseDirectory = (Join-Path $PSScriptRoot 'data'),
    [ValidateRange(1024, 65535)]
    [int] $Port = 8765
)

$ErrorActionPreference = 'Stop'

$liteDbAssemblyPath = Join-Path $PSScriptRoot 'packages\LiteDB.5.0.21\lib\netstandard2.0\LiteDB.dll'
if (-not (Test-Path -LiteralPath $liteDbAssemblyPath -PathType Leaf)) {
    throw "LiteDB 5.0.21 assembly not found at '$liteDbAssemblyPath'."
}
if (-not ('LiteDB.LiteDatabase' -as [type])) {
    Add-Type -Path $liteDbAssemblyPath
}

function Get-DashboardDatabasePath {
    param ([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or [System.IO.Path]::GetFileName($Name) -ne $Name -or [System.IO.Path]::GetExtension($Name) -ne '.db') {
        throw 'Choose a valid database file.'
    }

    $path = Join-Path $DatabaseDirectory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Database '$Name' was not found in '$DatabaseDirectory'."
    }

    $path
}

function Open-DashboardDatabase {
    param ([string] $Name)

    $connectionString = [LiteDB.ConnectionString]::new()
    $connectionString.Filename = Get-DashboardDatabasePath -Name $Name
    $connectionString.Connection = [LiteDB.ConnectionType]::Shared
    $connectionString.ReadOnly = $true
    [LiteDB.LiteDatabase]::new($connectionString)
}

function Get-DashboardText {
    param (
        [LiteDB.BsonDocument] $Document,
        [string] $Field
    )

    if (-not $Document.ContainsKey($Field) -or $Document[$Field].IsNull) {
        return ''
    }
    if ($Document[$Field].IsString) {
        return $Document[$Field].AsString
    }
    $Document[$Field].ToString()
}

function Get-DashboardNumber {
    param (
        [LiteDB.BsonDocument] $Document,
        [string] $Field
    )

    if (-not $Document.ContainsKey($Field) -or $Document[$Field].IsNull) {
        return $null
    }

    $value = $Document[$Field]
    if ($value.IsInt32) { return [long] $value.AsInt32 }
    if ($value.IsInt64) { return [long] $value.AsInt64 }
    if ($value.IsDouble) { return [double] $value.AsDouble }
    if ($value.IsDecimal) { return [double] $value.AsDecimal }

    $parsed = [long] 0
    if ([long]::TryParse($value.ToString(), [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $parsed)) {
        return $parsed
    }
    $null
}

function ConvertTo-DashboardPlayer {
    param (
        [LiteDB.BsonDocument] $Document,
        [object] $Assignment
    )

    $position = Get-DashboardText -Document $Document -Field 'pos'
    $eligiblePosition = Get-DashboardText -Document $Document -Field 'elig_pos'
    if ($null -ne $Assignment) {
        $assignmentEligibility = $Assignment.PSObject.Properties['elig_pos']
        if ($null -ne $assignmentEligibility -and -not [string]::IsNullOrWhiteSpace([string] $assignmentEligibility.Value)) {
            $eligiblePosition = [string] $assignmentEligibility.Value
        }
    }
    if ([string]::IsNullOrWhiteSpace($eligiblePosition) -and -not [string]::IsNullOrWhiteSpace($position)) {
        $eligiblePosition = $position.Trim().Substring($position.Trim().Length - 1).ToUpperInvariant()
    }

    $team = Get-DashboardText -Document $Document -Field 'team_name_abbr'
    if ([string]::IsNullOrWhiteSpace($team)) {
        $team = Get-DashboardText -Document $Document -Field 'team'
    }

    $owner = if ($null -ne $Assignment) { [string] $Assignment.owner } else { '' }
    $draftPosition = if ($null -ne $Assignment -and $null -ne $Assignment.draft_position) { [long] $Assignment.draft_position } else { $null }
    $points = Get-DashboardNumber -Document $Document -Field 'pts'
    $assists = Get-DashboardNumber -Document $Document -Field 'ast'
    $rebounds = Get-DashboardNumber -Document $Document -Field 'trb'
    $turnovers = Get-DashboardNumber -Document $Document -Field 'tov'
    $games = Get-DashboardNumber -Document $Document -Field 'g'
    if ($null -eq $games) {
        $games = Get-DashboardNumber -Document $Document -Field 'games'
    }
    $value = Get-DashboardNumber -Document $Document -Field 'value'
    if ($null -eq $value) {
        $value = [long] 0
        if ($null -ne $points) { $value += $points }
        if ($null -ne $rebounds) { $value += $rebounds }
        if ($null -ne $assists) { $value += $assists }
        if ($null -ne $turnovers) { $value -= 2 * $turnovers }
    }
    $average = $null
    if ($null -ne $games -and $games -gt 0) {
        $average = [Math]::Round([double] $value / [double] $games, 2)
    }

    [pscustomobject]@{
        player   = Get-DashboardText -Document $Document -Field 'player'
        age      = Get-DashboardNumber -Document $Document -Field 'age'
        elig_pos = $eligiblePosition
        team     = $team
        owner    = $owner
        draft_pos = $draftPosition
        drafted  = (-not [string]::IsNullOrWhiteSpace($owner) -or $null -ne $draftPosition)
        value    = $value
        avg      = $average
        pts      = $points
        trb      = $rebounds
        ast      = $assists
        tov      = $turnovers
    }
}

function Get-DashboardState {
    param (
        [string] $DatabaseName,
        [string] $CollectionName
    )

    $databasePath = Get-DashboardDatabasePath -Name $DatabaseName
    $draftDataPath = [System.IO.Path]::ChangeExtension($databasePath, '.json')
    if (-not (Test-Path -LiteralPath $draftDataPath -PathType Leaf)) {
        throw "Draft sidecar '$draftDataPath' was not found. Open the season database in FantasyDraftTracker to create or migrate it."
    }
    $draftData = Get-Content -LiteralPath $draftDataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $assignmentsById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($assignment in @($draftData.assignments)) {
        if ([string] $assignment.collection -ne $CollectionName) { continue }
        $playerId = [string] $assignment.player_id
        if ([string]::IsNullOrWhiteSpace($playerId)) { continue }
        if ($assignmentsById.ContainsKey($playerId)) {
            throw "Draft sidecar '$draftDataPath' contains duplicate player_id '$playerId' for collection '$CollectionName'."
        }
        $assignmentsById.Add($playerId, $assignment)
    }

    $database = Open-DashboardDatabase -Name $DatabaseName
    try {
        $existingNames = @($database.GetCollectionNames() | Where-Object { $_ -ne 'draft_owners' } | Sort-Object)
        if ($CollectionName -notin @('NBA', 'WNBA', 'players') -and $CollectionName -notin $existingNames) {
            throw "Collection '$CollectionName' was not found in '$DatabaseName'."
        }

        $playerDocuments = @($database.GetCollection[LiteDB.BsonDocument]($CollectionName).FindAll())
        $allPlayers = @($playerDocuments | ForEach-Object {
            $playerId = Get-DashboardText -Document $_ -Field '_id'
            $assignment = if ($assignmentsById.ContainsKey($playerId)) { $assignmentsById[$playerId] } else { $null }
            ConvertTo-DashboardPlayer -Document $_ -Assignment $assignment
        })
        $players = @($allPlayers | Where-Object { $_.drafted -and -not [string]::IsNullOrWhiteSpace($_.owner) })
        $draftedCount = $players.Count

        $leaderboardDefinitions = @(
            @{ Key = 'value'; Title = 'SCORE' },
            @{ Key = 'avg'; Title = 'AVERAGE' },
            @{ Key = 'pts'; Title = 'POINTS' },
            @{ Key = 'trb'; Title = 'REBOUNDS' },
            @{ Key = 'ast'; Title = 'ASSISTS' },
            @{ Key = 'tov'; Title = 'TURNOVERS' }
        )
        $leaderboards = [System.Collections.Generic.List[object]]::new()
        foreach ($definition in $leaderboardDefinitions) {
            $rankedPlayers = @(
                $players |
                    Where-Object { $null -ne $_.PSObject.Properties[$definition.Key].Value } |
                    Sort-Object -Property @(
                        @{ Expression = { $_.PSObject.Properties[$definition.Key].Value }; Descending = $true },
                        @{ Expression = { $_.player }; Descending = $false }
                    ) |
                    Select-Object -First 5 |
                    ForEach-Object {
                        [pscustomobject]@{
                            player = $_.player
                            owner = $_.owner
                            score = $_.PSObject.Properties[$definition.Key].Value
                        }
                    }
            )
            $leaderboards.Add([pscustomobject]@{
                key = $definition.Key
                title = $definition.Title
                players = $rankedPlayers
            })
        }

        $owners = @($draftData.owners | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $pickNumber = $draftedCount + 1
        $roundNumber = 1
        $ownerUp = ''
        if ($owners.Count -gt 0) {
            $roundNumber = [int] [Math]::Floor(($pickNumber - 1) / $owners.Count) + 1
            $roundIndex = $roundNumber - 1
            $seatIndex = ($pickNumber - 1) % $owners.Count
            if (($roundIndex % 2) -eq 1) {
                $seatIndex = $owners.Count - 1 - $seatIndex
            }
            $ownerUp = $owners[$seatIndex]
        }

        [pscustomobject]@{
            database = $DatabaseName
            collection = $CollectionName
            updatedAt = [DateTime]::UtcNow.ToString('o')
            totalPlayers = $allPlayers.Count
            draftedPlayers = $draftedCount
            pickNumber = $pickNumber
            round = $roundNumber
            ownerUp = $ownerUp
            owners = @($owners)
            players = @($players)
            leaderboards = $leaderboards.ToArray()
        }
    }
    finally {
        $database.Dispose()
    }
}

function Write-DashboardResponse {
    param (
        [System.Net.HttpListenerContext] $Context,
        [int] $StatusCode,
        [string] $ContentType,
        [byte[]] $Body
    )

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.ContentLength64 = $Body.Length
    $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
    $Context.Response.Close()
}

function Write-DashboardJson {
    param (
        [System.Net.HttpListenerContext] $Context,
        [int] $StatusCode,
        [object] $Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    Write-DashboardResponse -Context $Context -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
}

$dashboardFile = Join-Path $PSScriptRoot 'DraftDashboard.html'
if (-not (Test-Path -LiteralPath $dashboardFile -PathType Leaf)) {
    throw "Dashboard page not found at '$dashboardFile'."
}

$baseUrl = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($baseUrl)
try {
    $listener.Start()
}
catch {
    $listener.Close()
    throw "Could not start the dashboard at $baseUrl. $_"
}

Write-Host "Chumpball live dashboard: $baseUrl"
Write-Host 'Press Ctrl+C to stop the dashboard server.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $requestPath = $context.Request.Url.AbsolutePath
            switch ($requestPath) {
                '/' {
                    $html = [System.IO.File]::ReadAllText($dashboardFile, [System.Text.Encoding]::UTF8)
                    Write-DashboardResponse -Context $context -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($html))
                }
                '/api/databases' {
                    $databases = @()
                    if (Test-Path -LiteralPath $DatabaseDirectory -PathType Container) {
                        $databases = @(Get-ChildItem -LiteralPath $DatabaseDirectory -Filter '*.db' -File |
                            Where-Object { $_.Name -notlike '*-log.db' } |
                            Sort-Object Name |
                            Select-Object -ExpandProperty Name)
                    }
                    Write-DashboardJson -Context $context -StatusCode 200 -Value @{ databases = $databases }
                }
                '/api/collections' {
                    $databaseName = $context.Request.QueryString['database']
                    $database = Open-DashboardDatabase -Name $databaseName
                    try {
                        $existing = @($database.GetCollectionNames() | Where-Object { $_ -ne 'draft_owners' } | Sort-Object)
                        $collections = [System.Collections.Generic.List[string]]::new()
                        foreach ($league in 'NBA', 'WNBA') { $collections.Add($league) }
                        if ($existing -contains 'players') { $collections.Add('players') }
                        foreach ($name in $existing) {
                            if ($name -notin @('NBA', 'WNBA', 'players')) { $collections.Add($name) }
                        }
                        Write-DashboardJson -Context $context -StatusCode 200 -Value @{ collections = $collections.ToArray() }
                    }
                    finally {
                        $database.Dispose()
                    }
                }
                '/api/state' {
                    $state = Get-DashboardState -DatabaseName $context.Request.QueryString['database'] -CollectionName $context.Request.QueryString['collection']
                    Write-DashboardJson -Context $context -StatusCode 200 -Value $state
                }
                default {
                    Write-DashboardJson -Context $context -StatusCode 404 -Value @{ error = 'Not found.' }
                }
            }
        }
        catch {
            try {
                Write-DashboardJson -Context $context -StatusCode 500 -Value @{ error = $_.Exception.Message }
            }
            catch {
                $context.Response.Abort()
            }
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
