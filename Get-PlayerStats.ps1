function Invoke-BasketballReferenceRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Headers,
        [ValidateRange(1, 10)][int] $MaximumAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 30 -Headers $Headers -ErrorAction Stop
        }
        catch {
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $response = if ($null -ne $responseProperty) { $responseProperty.Value } else { $null }
            $statusCode = 0
            if ($null -ne $response) {
                $statusCodeProperty = $response.PSObject.Properties['StatusCode']
                if ($null -ne $statusCodeProperty) {
                    try { $statusCode = [int] $statusCodeProperty.Value } catch {}
                }
            }
            if ($statusCode -eq 429) {
                $retryAfter = ''
                if ($null -ne $response) {
                    try { $retryAfter = [string] $response.Headers['Retry-After'] } catch {}
                    if ([string]::IsNullOrWhiteSpace($retryAfter)) {
                        try { $retryAfter = [string] $response.Headers.RetryAfter.Delta.TotalSeconds } catch {}
                    }
                }
                $retryMessage = if ([string]::IsNullOrWhiteSpace($retryAfter)) { 'Wait a while before rerunning the collector.' } else { "Wait until Retry-After '$retryAfter' before rerunning the collector." }
                throw "Basketball Reference rate-limited '$Uri' (HTTP 429). No automatic retry was made. $retryMessage"
            }

            $retryable = $statusCode -in @(0, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $MaximumAttempts) { throw }

            $retryAfter = ''
            if ($null -ne $response) {
                try { $retryAfter = [string] $response.Headers['Retry-After'] } catch {}
                if ([string]::IsNullOrWhiteSpace($retryAfter)) {
                    try { $retryAfter = [string] $response.Headers.RetryAfter.Delta.TotalSeconds } catch {}
                }
            }
            $delaySeconds = 0.0
            if (-not [double]::TryParse($retryAfter, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $delaySeconds)) {
                $retryDate = [datetime]::MinValue
                if ([datetime]::TryParse($retryAfter, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $retryDate)) {
                    $delaySeconds = [Math]::Max(0, ($retryDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds)
                }
            }
            if ($delaySeconds -le 0) { $delaySeconds = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
            $delaySeconds = [Math]::Min(120, [Math]::Ceiling($delaySeconds))
            $statusText = if ($statusCode -gt 0) { "HTTP $statusCode" } else { 'a transient network error' }
            Write-Warning "Basketball Reference returned $statusText for '$Uri'. Retrying in $delaySeconds seconds (attempt $($attempt + 1) of $MaximumAttempts)."
            Start-Sleep -Seconds ([int] $delaySeconds)
        }
    }
}

function Get-PlayerStats {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('NBA', 'WNBA')]
        [string] $League,

        [Parameter(Mandatory)]
        [ValidateRange(1900, 2100)]
        [int] $Season
    )

    if ($League -eq 'NBA') {
        $uri = "https://www.basketball-reference.com/leagues/NBA_${Season}_totals.html"
        $tableId = 'totals_stats'
    }
    else {
        $uri = "https://www.basketball-reference.com/wnba/years/${Season}_totals.html"
        $tableId = 'totals'
    }

    try {
        $response = Invoke-BasketballReferenceRequest -Uri $uri -Headers @{
            'User-Agent' = 'Mozilla/5.0 (compatible; FantasyStats/1.0)'
        } -ErrorAction Stop
    }
    catch {
        Write-Host 'No records returned'
        return
    }

    $tablePattern = '(?is)<table\b(?=[^>]*\bid\s*=\s*["'']' + [regex]::Escape($tableId) + '["''])[^>]*>.*?</table>'
    $tableMatch = [regex]::Match($response.Content, $tablePattern)

    if (-not $tableMatch.Success) {
        foreach ($comment in [regex]::Matches($response.Content, '(?is)<!--(.*?)-->')) {
            $tableMatch = [regex]::Match($comment.Groups[1].Value, $tablePattern)
            if ($tableMatch.Success) {
                break
            }
        }
    }

    if (-not $tableMatch.Success) {
        Write-Host 'No records returned'
        return
    }

    $tableHtml = $tableMatch.Value
    $columnNames = @()
    foreach ($header in [regex]::Matches($tableHtml, '(?is)<thead\b[^>]*>(.*?)</thead>')) {
        foreach ($headerRow in [regex]::Matches($header.Groups[1].Value, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
            $candidateColumns = [System.Collections.Generic.List[string]]::new()
            foreach ($cell in [regex]::Matches($headerRow.Groups[1].Value, '(?is)<th\b([^>]*)>(.*?)</th>')) {
                $dataStat = [regex]::Match($cell.Groups[1].Value, '\bdata-stat\s*=\s*["'']([^"'']+)["'']')
                if ($dataStat.Success) {
                    $columnName = $dataStat.Groups[1].Value
                    if ($columnName -eq 'name_display') {
                        $columnName = 'player'
                    }
                    $candidateColumns.Add($columnName)
                }
            }
            if ($candidateColumns.Count -gt 0) {
                $columnNames = $candidateColumns.ToArray()
            }
        }
    }

    if ($columnNames.Count -eq 0) {
        Write-Host 'No records returned'
        return
    }

    $players = [System.Collections.Generic.List[object]]::new()
    foreach ($row in [regex]::Matches($tableHtml, '(?is)<tr\b([^>]*)>(.*?)</tr>')) {
        if ($row.Groups[1].Value -match '\bclass\s*=\s*["''][^"'']*\bthead\b') {
            continue
        }

        $rowData = [ordered]@{}
        foreach ($columnName in $columnNames) {
            $rowData[$columnName] = $null
        }

        foreach ($cell in [regex]::Matches($row.Groups[2].Value, '(?is)<(?:th|td)\b([^>]*)>(.*?)</(?:th|td)>')) {
            $dataStat = [regex]::Match($cell.Groups[1].Value, '\bdata-stat\s*=\s*["'']([^"'']+)["'']')
            if (-not $dataStat.Success) {
                continue
            }
            $columnName = $dataStat.Groups[1].Value
            if ($columnName -eq 'name_display') {
                $columnName = 'player'
            }
            if (-not $rowData.Contains($columnName)) {
                continue
            }

            $value = [regex]::Replace($cell.Groups[2].Value, '(?is)<[^>]+>', '')
            $value = [regex]::Replace($value, '(?is)</?[a-z][^>]*$', '')
            $value = [System.Net.WebUtility]::HtmlDecode($value).Replace([char] 0xA0, ' ').Trim()
            $rowData[$columnName] = $value
        }

        if ([string]::IsNullOrWhiteSpace([string] $rowData['player']) -or $rowData['player'] -eq 'Player') {
            continue
        }

        $players.Add([pscustomobject] $rowData)
    }

    if ($players.Count -eq 0) {
        Write-Host 'No records returned'
        return
    }

    $cleanPlayers = @(Remove-TradedPlayerRows -Players $players.ToArray())
    Add-PlayerValue -Players $cleanPlayers
}

function Get-BasketballReferenceTableHtml {
    param (
        [Parameter(Mandatory)][string] $Content,
        [Parameter(Mandatory)][string] $TableId,
        [switch] $Optional
    )

    $tablePattern = '(?is)<table\b(?=[^>]*\bid\s*=\s*["'']' + [regex]::Escape($TableId) + '["''])[^>]*>.*?</table>'
    $tableMatch = [regex]::Match($Content, $tablePattern)
    if (-not $tableMatch.Success) {
        foreach ($comment in [regex]::Matches($Content, '(?is)<!--(.*?)-->')) {
            $tableMatch = [regex]::Match($comment.Groups[1].Value, $tablePattern)
            if ($tableMatch.Success) { break }
        }
    }
    if (-not $tableMatch.Success) {
        if ($Optional) { return $null }
        throw "Basketball Reference table '$TableId' was not found."
    }
    $tableMatch.Value
}

function ConvertFrom-BasketballReferenceTable {
    param ([Parameter(Mandatory)][string] $TableHtml)

    $columnNames = @()
    foreach ($header in [regex]::Matches($TableHtml, '(?is)<thead\b[^>]*>(.*?)</thead>')) {
        foreach ($headerRow in [regex]::Matches($header.Groups[1].Value, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
            $candidateColumns = [System.Collections.Generic.List[string]]::new()
            foreach ($cell in [regex]::Matches($headerRow.Groups[1].Value, '(?is)<th\b([^>]*)>(.*?)</th>')) {
                $dataStat = [regex]::Match($cell.Groups[1].Value, '\bdata-stat\s*=\s*["'']([^"'']+)["'']')
                if ($dataStat.Success) { $candidateColumns.Add($dataStat.Groups[1].Value) }
            }
            if ($candidateColumns.Count -gt 0) { $columnNames = $candidateColumns.ToArray() }
        }
    }
    if ($columnNames.Count -eq 0) { throw 'Basketball Reference table did not contain data-stat headers.' }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($row in [regex]::Matches($TableHtml, '(?is)<tr\b([^>]*)>(.*?)</tr>')) {
        if ($row.Groups[1].Value -match '\bclass\s*=\s*["''][^"'']*\bthead\b') { continue }
        $rowData = [ordered]@{}
        foreach ($columnName in $columnNames) { $rowData[$columnName] = $null }
        $playerRef = ''
        $teamRef = ''
        foreach ($cell in [regex]::Matches($row.Groups[2].Value, '(?is)<(?:th|td)\b([^>]*)>(.*?)</(?:th|td)>')) {
            $dataStat = [regex]::Match($cell.Groups[1].Value, '\bdata-stat\s*=\s*["'']([^"'']+)["'']')
            if (-not $dataStat.Success) { continue }
            $columnName = $dataStat.Groups[1].Value
            if (-not $rowData.Contains($columnName)) { continue }
            $value = [regex]::Replace($cell.Groups[2].Value, '(?is)<[^>]+>', '')
            $value = [System.Net.WebUtility]::HtmlDecode($value).Replace([char] 0xA0, ' ').Trim()
            $rowData[$columnName] = $value
            $href = [regex]::Match($cell.Groups[2].Value, '\bhref\s*=\s*["'']([^"'']+)["'']')
            if ($href.Success -and $columnName -eq 'player') { $playerRef = $href.Groups[1].Value }
            if ($href.Success -and $columnName -eq 'team_name') { $teamRef = $href.Groups[1].Value }
        }
        $rowData['player_ref'] = $playerRef
        $rowData['team_ref'] = $teamRef
        if ($rowData.Contains('player') -and [string] $rowData['player'] -eq 'Player') { continue }
        $records.Add([pscustomobject] $rowData)
    }
    $records.ToArray()
}

function Get-AllPlayersStats {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateRange(1900, 2100)]
        [int] $Season
    )

    $headers = @{ 'User-Agent' = 'Mozilla/5.0 (compatible; FantasyStats/1.0)' }
    $standingsUri = "https://www.basketball-reference.com/leagues/NBA_${Season}.html"
    try {
        $standingsContent = (Invoke-BasketballReferenceRequest -Uri $standingsUri -Headers $headers).Content
    }
    catch {
        throw "Could not download NBA $Season standings from Basketball Reference. $($_.Exception.Message)"
    }

    $teamsByUrl = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tableId in 'confs_standings_E', 'confs_standings_W') {
        $tableHtml = Get-BasketballReferenceTableHtml -Content $standingsContent -TableId $tableId
        foreach ($teamRow in ConvertFrom-BasketballReferenceTable -TableHtml $tableHtml) {
            $teamRef = [string] $teamRow.team_ref
            $teamMatch = [regex]::Match($teamRef, '/teams/(?<abbr>[A-Z]{3})/')
            if (-not $teamMatch.Success) { continue }
            $teamUrl = "https://www.basketball-reference.com$($teamRef.Split('#')[0])"
            if (-not $teamsByUrl.ContainsKey($teamUrl)) { $teamsByUrl.Add($teamUrl, $teamMatch.Groups['abbr'].Value) }
        }
    }
    if ($teamsByUrl.Count -eq 0) { throw "No team links were found in the NBA $Season standings." }

    $seasonStats = @(Get-PlayerStats -League NBA -Season $Season)
    $statsByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($stat in $seasonStats) {
        $playerName = [string] $stat.player
        if (-not [string]::IsNullOrWhiteSpace($playerName)) { $statsByName[$playerName] = $stat }
    }

    $players = [System.Collections.Generic.List[object]]::new()
    $seenPlayerNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $teamIndex = 0
    foreach ($teamEntry in $teamsByUrl.GetEnumerator()) {
        if ($teamIndex -gt 0) { Start-Sleep -Seconds 3 }
        $teamIndex++
        try {
            $teamContent = (Invoke-BasketballReferenceRequest -Uri $teamEntry.Key -Headers $headers).Content
        }
        catch {
            throw "Could not download roster for '$($teamEntry.Value)' in NBA $Season. $($_.Exception.Message)"
        }

        $rosterHtml = Get-BasketballReferenceTableHtml -Content $teamContent -TableId 'roster'
        $rosterRows = @(ConvertFrom-BasketballReferenceTable -TableHtml $rosterHtml)
        $injuryHtml = Get-BasketballReferenceTableHtml -Content $teamContent -TableId 'injuries' -Optional
        $injuryRows = if ($null -ne $injuryHtml) { @(ConvertFrom-BasketballReferenceTable -TableHtml $injuryHtml) } else { @() }
        $injuriesByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $injuriesByRef = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($injury in $injuryRows) {
            $injuredName = [string] $injury.player
            if ([string]::IsNullOrWhiteSpace($injuredName)) { continue }
            $injuriesByName[$injuredName] = [string] $injury.note
            if (-not [string]::IsNullOrWhiteSpace([string] $injury.player_ref)) { [void] $injuriesByRef.Add([string] $injury.player_ref) }
        }

        foreach ($rosterPlayer in $rosterRows) {
            $playerName = [string] $rosterPlayer.player
            if ([string]::IsNullOrWhiteSpace($playerName) -or -not $seenPlayerNames.Add($playerName)) { continue }
            $playerData = [ordered]@{
                age = $null
                games = 0
                games_started = 0
                mp = 0
                fg = 0
                fga = 0
                fg_pct = 0
                fg3 = 0
                fg3a = 0
                fg3_pct = 0
                fg2 = 0
                fg2a = 0
                fg2_pct = 0
                efg_pct = 0
                ft = 0
                fta = 0
                ft_pct = 0
                orb = 0
                drb = 0
                trb = 0
                ast = 0
                stl = 0
                blk = 0
                tov = 0
                pf = 0
                pts = 0
                tpl_dbl = 0
                value = 0
            }
            if ($statsByName.ContainsKey($playerName)) {
                foreach ($property in $statsByName[$playerName].PSObject.Properties) {
                    $playerData[$property.Name] = $property.Value
                }
            }
            $playerData['player'] = $playerName
            if ($null -eq $playerData['age'] -or [string]::IsNullOrWhiteSpace([string] $playerData['age'])) {
                $birthDate = [datetime]::MinValue
                $birthDateText = [string] $rosterPlayer.birth_date
                if ([datetime]::TryParse($birthDateText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref] $birthDate)) {
                    $seasonReferenceDate = [datetime]::new($Season, 2, 1)
                    $playerAge = $seasonReferenceDate.Year - $birthDate.Year
                    if ($birthDate.Month -gt $seasonReferenceDate.Month -or ($birthDate.Month -eq $seasonReferenceDate.Month -and $birthDate.Day -gt $seasonReferenceDate.Day)) {
                        $playerAge--
                    }
                    $playerData['age'] = $playerAge
                }
            }
            $playerData['team_name_abbr'] = $teamEntry.Value
            $playerData['pos'] = [string] $rosterPlayer.pos
            $playerData['player_ref'] = [string] $rosterPlayer.player_ref
            $injured = $injuriesByName.ContainsKey($playerName) -or $injuriesByRef.Contains([string] $rosterPlayer.player_ref)
            $playerData['injured'] = $injured
            $playerData['injury_note'] = if ($injuriesByName.ContainsKey($playerName)) { $injuriesByName[$playerName] } else { '' }
            $players.Add([pscustomobject] $playerData)
        }
    }

    if ($players.Count -eq 0) { throw "No NBA player roster rows were found for $Season." }
    Add-PlayerValue -Players $players.ToArray()
}

function Remove-TradedPlayerRows {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Players
    )

    $playersByName = @{}
    $playerOrder = [System.Collections.Generic.List[string]]::new()

    foreach ($player in $Players) {
        $playerProperty = $player.PSObject.Properties['player']
        if ($null -eq $playerProperty -or [string]::IsNullOrWhiteSpace([string] $playerProperty.Value)) {
            throw 'Every player row must have a non-empty player property.'
        }

        $playerName = [string] $playerProperty.Value
        if (-not $playersByName.ContainsKey($playerName)) {
            $playersByName[$playerName] = [System.Collections.Generic.List[object]]::new()
            $playerOrder.Add($playerName)
        }
        $playersByName[$playerName].Add($player)
    }

    $cleanedPlayers = [System.Collections.Generic.List[object]]::new()
    foreach ($playerName in $playerOrder) {
        $playerRows = $playersByName[$playerName]
        if ($playerRows.Count -eq 1) {
            $cleanedPlayers.Add($playerRows[0])
            continue
        }

        $totalRow = $null
        $totalTeamPropertyName = $null
        foreach ($row in $playerRows) {
            foreach ($propertyName in @('team_name_abbr', 'team')) {
                $teamProperty = $row.PSObject.Properties[$propertyName]
                if ($null -ne $teamProperty -and [string] $teamProperty.Value -match '^(?:\d+TM|TOT)$') {
                    if ($null -ne $totalRow) {
                        throw "Multiple season-total rows found for player '$playerName'."
                    }
                    $totalRow = $row
                    $totalTeamPropertyName = $propertyName
                    break
                }
            }
        }

        if ($null -eq $totalRow) {
            throw "No multi-team season-total row found for player '$playerName'."
        }

        $latestRow = $playerRows[$playerRows.Count - 1]
        $latestTeamProperty = $latestRow.PSObject.Properties[$totalTeamPropertyName]
        if ($null -eq $latestTeamProperty) {
            foreach ($propertyName in @('team_name_abbr', 'team')) {
                $latestTeamProperty = $latestRow.PSObject.Properties[$propertyName]
                if ($null -ne $latestTeamProperty) {
                    break
                }
            }
        }

        if ($null -eq $latestTeamProperty -or [string]::IsNullOrWhiteSpace([string] $latestTeamProperty.Value)) {
            throw "Could not determine the latest team for player '$playerName'."
        }

        $totalRow.PSObject.Properties[$totalTeamPropertyName].Value = $latestTeamProperty.Value
        $cleanedPlayers.Add($totalRow)
    }

    $cleanedPlayers.ToArray()
}

function Add-PlayerValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Players
    )

    foreach ($player in $Players) {
        $eligibilityProperty = $player.PSObject.Properties['elig_pos']
        if ($null -eq $eligibilityProperty -or [string]::IsNullOrWhiteSpace([string] $eligibilityProperty.Value)) {
            $positionProperty = $player.PSObject.Properties['pos']
            $eligiblePosition = $null
            if ($null -ne $positionProperty -and -not [string]::IsNullOrWhiteSpace([string] $positionProperty.Value)) {
                $position = ([string] $positionProperty.Value).Trim()
                $eligiblePosition = $position.Substring($position.Length - 1).ToUpperInvariant()
            }
            $player | Add-Member -MemberType NoteProperty -Name elig_pos -Value $eligiblePosition -Force
        }
        else {
            $eligibilityProperty.Value = ([string] $eligibilityProperty.Value).Trim().ToUpperInvariant()
        }

        $statValues = @{}
        foreach ($statName in 'pts', 'trb', 'ast', 'tov') {
            $statProperty = $player.PSObject.Properties[$statName]
            $statValue = [long] 0
            if ($null -ne $statProperty -and -not [string]::IsNullOrWhiteSpace([string] $statProperty.Value)) {
                if (-not [long]::TryParse([string] $statProperty.Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $statValue)) {
                    throw "Player '$($player.player)' has a non-integer '$statName' value."
                }
            }
            $statValues[$statName] = $statValue
        }

        $calculatedValue = $statValues['pts'] + $statValues['trb'] + $statValues['ast'] - (2 * $statValues['tov'])
        $player | Add-Member -MemberType NoteProperty -Name value -Value $calculatedValue -Force
    }

    $Players
}

function Save-PlayerStatsToLiteDb {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Players,

        [Parameter(Mandatory)]
        [ValidateSet('NBA', 'WNBA')]
        [string] $League,

        [Parameter(Mandatory)]
        [ValidateRange(1900, 2100)]
        [int] $Season,

        [string] $DatabaseDirectory
    )

    if ($null -eq $Players -or $Players.Count -eq 0) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($DatabaseDirectory)) {
        $DatabaseDirectory = Join-Path $PSScriptRoot 'data'
    }

    $assemblyPath = Join-Path $PSScriptRoot 'packages\LiteDB.5.0.21\lib\netstandard2.0\LiteDB.dll'
    if (-not (Test-Path -LiteralPath $assemblyPath -PathType Leaf)) {
        throw "LiteDB 5.0.21 assembly not found at '$assemblyPath'. Restore the project package before saving stats."
    }

    if ($null -eq ([type]::GetType('LiteDB.LiteDatabase', $false))) {
        Add-Type -Path $assemblyPath -ErrorAction Stop
    }

    $databasePlayers = [System.Collections.Generic.List[object]]::new()
    foreach ($player in $Players) {
        $position = [string] $player.pos
        $teamNameProperty = $player.PSObject.Properties['team_name_abbr']
        $team = if ($null -ne $teamNameProperty) { [string] $teamNameProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($team)) {
            $teamProperty = $player.PSObject.Properties['team']
            if ($null -ne $teamProperty) {
                $team = [string] $teamProperty.Value
            }
        }
        if ([string]::IsNullOrWhiteSpace($team) -and [string]::IsNullOrWhiteSpace($position)) {
            continue
        }
        $databasePlayers.Add($player)
    }
    if ($databasePlayers.Count -eq 0) {
        return
    }

    $cleanPlayers = @(Remove-TradedPlayerRows -Players $databasePlayers.ToArray())
    if ($cleanPlayers.Count -eq 0) {
        return
    }

    $cleanPlayers = @(Add-PlayerValue -Players $cleanPlayers)

    $documents = [System.Collections.Generic.List[LiteDB.BsonDocument]]::new()
    $playerIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($player in $cleanPlayers) {
        $playerName = [string] $player.player
        if (-not $playerIds.Add($playerName)) {
            throw "Player name '$playerName' is duplicated after preprocessing and cannot be used as a document ID."
        }

        $document = [LiteDB.BsonDocument]::new()
        foreach ($property in $player.PSObject.Properties) {
            if ($property.Name -in @('_id', 'owner', 'draft_pos', 'drafted')) {
                continue
            }

            $value = $property.Value
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                $document[$property.Name] = [LiteDB.BsonValue]::Null
                continue
            }

            if ($value -is [string]) {
                $parsedInteger = [long] 0
                $parsedDouble = [double] 0
                if ([long]::TryParse($value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $parsedInteger)) {
                    $value = $parsedInteger
                }
                elseif ([double]::TryParse($value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $parsedDouble)) {
                    $value = $parsedDouble
                }
            }

            $document[$property.Name] = [LiteDB.BsonValue]::new($value)
        }
        $document['_id'] = [LiteDB.BsonValue]::new($playerName)
        $documents.Add($document)
    }

    $null = New-Item -Path $DatabaseDirectory -ItemType Directory -Force
    $databasePath = Join-Path $DatabaseDirectory "$Season.db"
    $connectionString = [LiteDB.ConnectionString]::new()
    $connectionString.Filename = $databasePath
    $connectionString.Connection = [LiteDB.ConnectionType]::Shared
    $database = [LiteDB.LiteDatabase]::new($connectionString)
    try {
        $collection = $database.GetCollection[LiteDB.BsonDocument]($League)
        if (-not $database.BeginTrans()) {
            throw "Could not begin a LiteDB transaction for '$databasePath'."
        }

        try {
            $null = $collection.DeleteAll()
            $insertedCount = $collection.InsertBulk($documents)
            if (-not $database.Commit()) {
                throw "Could not commit player stats to '$databasePath'."
            }
        }
        catch {
            try {
                $null = $database.Rollback()
            }
            catch {
            }
            throw
        }
    }
    finally {
        $database.Dispose()
    }

    [pscustomobject]@{
        DatabasePath = $databasePath
        Collection   = $League
        Count        = $insertedCount
    }
}