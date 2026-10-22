[CmdletBinding()]
param (
    [string] $DatabaseDirectory = (Join-Path $PSScriptRoot 'data'),
    [int] $MaximumRounds = 13
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$liteDbAssemblyPath = Join-Path $PSScriptRoot 'packages\LiteDB.5.0.21\lib\netstandard2.0\LiteDB.dll'
if (-not (Test-Path -LiteralPath $liteDbAssemblyPath -PathType Leaf)) {
    throw "LiteDB 5.0.21 assembly not found at '$liteDbAssemblyPath'."
}

if (-not ('LiteDB.LiteDatabase' -as [type])) {
    Add-Type -Path $liteDbAssemblyPath
}

$script:Database = $null
$script:Collection = $null
$script:PlayerDocuments = @()
$script:SelectedDocumentId = $null
$script:DraftDataPath = $null
$script:DraftAssignments = @{}
$script:LoadingDatabase = $false

function Get-BsonText {
    param (
        [LiteDB.BsonDocument] $Document,
        [string] $Field
    )

    if (-not $Document.ContainsKey($Field)) {
        return ''
    }

    $fieldValue = $Document[$Field]
    if ($null -eq $fieldValue -or $fieldValue.IsNull) {
        return ''
    }

    if ($fieldValue.IsString) {
        return $fieldValue.AsString
    }
    if ($fieldValue.IsInt32) {
        return $fieldValue.AsInt32.ToString([System.Globalization.CultureInfo]::CurrentCulture)
    }
    if ($fieldValue.IsInt64) {
        return $fieldValue.AsInt64.ToString([System.Globalization.CultureInfo]::CurrentCulture)
    }
    if ($fieldValue.IsDouble) {
        return $fieldValue.AsDouble.ToString([System.Globalization.CultureInfo]::CurrentCulture)
    }
    if ($fieldValue.IsDecimal) {
        return $fieldValue.AsDecimal.ToString([System.Globalization.CultureInfo]::CurrentCulture)
    }
    if ($fieldValue.IsBoolean) {
        return $fieldValue.AsBoolean.ToString()
    }

    $fieldValue.ToString()
}

function Get-DraftAssignment {
    param (
        [string] $CollectionName,
        [string] $PlayerId
    )

    $key = "$CollectionName`0$PlayerId"
    if ($script:DraftAssignments.ContainsKey($key)) {
        return $script:DraftAssignments[$key]
    }
    $null
}

function Get-PlayerEligibilityForDraft {
    param ([LiteDB.BsonDocument] $Document)

    $eligibility = Get-BsonText -Document $Document -Field 'elig_pos'
    if ([string]::IsNullOrWhiteSpace($eligibility)) {
        $position = Get-BsonText -Document $Document -Field 'pos'
        if (-not [string]::IsNullOrWhiteSpace($position)) {
            $trimmedPosition = $position.Trim()
            $eligibility = $trimmedPosition.Substring($trimmedPosition.Length - 1).ToUpperInvariant()
        }
    }
    $eligibility
}

function Get-DraftSidecarPath {
    param ([string] $DatabasePath)

    $seasonText = [System.IO.Path]::GetFileNameWithoutExtension($DatabasePath)
    $season = 0
    if ([int]::TryParse($seasonText, [ref] $season)) {
        return Join-Path ([System.IO.Path]::GetDirectoryName($DatabasePath)) "$($season + 1).json"
    }
    [System.IO.Path]::ChangeExtension($DatabasePath, '.json')
}

function Save-DraftData {
    if ([string]::IsNullOrWhiteSpace($script:DraftDataPath)) {
        throw 'No season draft sidecar is selected.'
    }

    $assignments = @($script:DraftAssignments.Values | Sort-Object collection, player_id)
    $data = [pscustomobject]@{
        version = 1
        owners = @($ownerOrderListBox.Items | ForEach-Object { [string] $_ })
        assignments = $assignments
    }
    $json = ConvertTo-Json -InputObject $data -Depth 8
    $temporaryPath = "$($script:DraftDataPath).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:DraftDataPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Remove-LegacyDraftFieldsFromDatabase {
    $updates = [System.Collections.Generic.List[object]]::new()
    foreach ($collectionName in $script:Database.GetCollectionNames()) {
        if ($collectionName -eq 'draft_owners') { continue }
        $collection = $script:Database.GetCollection[LiteDB.BsonDocument]($collectionName)
        foreach ($document in $collection.FindAll()) {
            if (-not ($document.ContainsKey('owner') -or $document.ContainsKey('draft_pos') -or $document.ContainsKey('drafted'))) { continue }
            $null = $document.Remove('owner')
            $null = $document.Remove('draft_pos')
            $null = $document.Remove('drafted')
            $updates.Add([pscustomobject]@{ Collection = $collection; Document = $document })
        }
    }

    if ($updates.Count -gt 0) {
        if (-not $script:Database.BeginTrans()) {
            throw 'Could not begin a transaction to remove legacy draft fields.'
        }
        try {
            foreach ($update in $updates) {
                if (-not $update.Collection.Update($update.Document)) {
                    throw "Could not remove legacy draft fields from '$($update.Document['_id'])'."
                }
            }
            if (-not $script:Database.Commit()) {
                throw 'Could not commit removal of legacy draft fields.'
            }
        }
        catch {
            try { $null = $script:Database.Rollback() } catch {}
            throw
        }
    }

    if ($script:Database.GetCollectionNames() -contains 'draft_owners') {
        $null = $script:Database.DropCollection('draft_owners')
    }
}

function Load-DraftData {
    if ([string]::IsNullOrWhiteSpace($script:DraftDataPath)) {
        throw 'No season draft sidecar is selected.'
    }

    $script:DraftAssignments = @{}
    $ownerOrderListBox.Items.Clear()
    if (Test-Path -LiteralPath $script:DraftDataPath -PathType Leaf) {
        $data = Get-Content -LiteralPath $script:DraftDataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($owner in @($data.owners)) {
            if (-not [string]::IsNullOrWhiteSpace([string] $owner)) {
                [void] $ownerOrderListBox.Items.Add([string] $owner)
            }
        }
        foreach ($assignment in @($data.assignments)) {
            $collectionName = [string] $assignment.collection
            $playerId = [string] $assignment.player_id
            if ([string]::IsNullOrWhiteSpace($collectionName) -or [string]::IsNullOrWhiteSpace($playerId)) {
                throw "Draft sidecar '$($script:DraftDataPath)' contains an assignment without collection or player_id."
            }
            $key = "$collectionName`0$playerId"
            if ($script:DraftAssignments.ContainsKey($key)) {
                throw "Draft sidecar '$($script:DraftDataPath)' contains duplicate player_id '$playerId' in '$collectionName'."
            }
            $script:DraftAssignments[$key] = [pscustomobject]@{
                collection = $collectionName
                player_id = $playerId
                owner = [string] $assignment.owner
                draft_position = $assignment.draft_position
                elig_pos = [string] $assignment.elig_pos
            }
        }
        $eligibilityChanged = $false
        foreach ($collectionName in $script:Database.GetCollectionNames()) {
            if ($collectionName -eq 'draft_owners') { continue }
            $collection = $script:Database.GetCollection[LiteDB.BsonDocument]($collectionName)
            foreach ($document in $collection.FindAll()) {
                $playerId = Get-BsonText -Document $document -Field '_id'
                $key = "$collectionName`0$playerId"
                if (-not $script:DraftAssignments.ContainsKey($key)) { continue }
                $assignment = $script:DraftAssignments[$key]
                if (-not [string]::IsNullOrWhiteSpace($assignment.elig_pos)) { continue }
                $assignment.elig_pos = Get-PlayerEligibilityForDraft -Document $document
                $eligibilityChanged = $true
            }
        }
        if ($eligibilityChanged) { Save-DraftData }
        Remove-LegacyDraftFieldsFromDatabase
        return
    }

    $legacyOwnerCollection = $script:Database.GetCollection[LiteDB.BsonDocument]('draft_owners')
    $legacyOrder = $legacyOwnerCollection.FindById('draft-order')
    if ($null -ne $legacyOrder -and $legacyOrder.ContainsKey('owners') -and -not $legacyOrder['owners'].IsNull) {
        foreach ($owner in $legacyOrder['owners'].AsArray) {
            if (-not $owner.IsNull -and -not [string]::IsNullOrWhiteSpace($owner.AsString)) {
                [void] $ownerOrderListBox.Items.Add($owner.AsString)
            }
        }
    }

    foreach ($collectionName in $script:Database.GetCollectionNames()) {
        if ($collectionName -eq 'draft_owners') { continue }
        $legacyCollection = $script:Database.GetCollection[LiteDB.BsonDocument]($collectionName)
        foreach ($document in $legacyCollection.FindAll()) {
            $owner = Get-BsonText -Document $document -Field 'owner'
            $draftPosition = Get-PlayerIntegerForDisplay -Document $document -Field 'draft_pos'
            if ([string]::IsNullOrWhiteSpace($owner) -and $null -eq $draftPosition) { continue }
            $playerId = Get-BsonText -Document $document -Field '_id'
            $key = "$collectionName`0$playerId"
            $script:DraftAssignments[$key] = [pscustomobject]@{
                collection = $collectionName
                player_id = $playerId
                owner = $owner
                draft_position = $draftPosition
                elig_pos = Get-PlayerEligibilityForDraft -Document $document
            }
        }
    }
    Save-DraftData
    Remove-LegacyDraftFieldsFromDatabase
}

function Set-DraftAssignment {
    param (
        [string] $CollectionName,
        [string] $PlayerId,
        [string] $Owner,
        [object] $DraftPosition,
        [string] $EligibilityPosition
    )

    $key = "$CollectionName`0$PlayerId"
    if ([string]::IsNullOrWhiteSpace($Owner) -and $null -eq $DraftPosition) {
        [void] $script:DraftAssignments.Remove($key)
    }
    else {
        $script:DraftAssignments[$key] = [pscustomobject]@{
            collection = $CollectionName
            player_id = $PlayerId
            owner = $Owner
            draft_position = $DraftPosition
            elig_pos = $EligibilityPosition
        }
    }
    Save-DraftData
}

function Get-PlayerValueForDisplay {
    param ([LiteDB.BsonDocument] $Document)

    $storedValue = Get-BsonText -Document $Document -Field 'value'
    if (-not [string]::IsNullOrWhiteSpace($storedValue)) {
        $numericStoredValue = [long] 0
        if ([long]::TryParse($storedValue, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $numericStoredValue)) {
            return $numericStoredValue
        }
    }

    $statValues = @{}
    foreach ($statName in 'pts', 'trb', 'ast', 'tov') {
        $statText = Get-BsonText -Document $Document -Field $statName
        $statValue = [long] 0
        [void] [long]::TryParse($statText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $statValue)
        $statValues[$statName] = $statValue
    }

    $calculatedValue = $statValues['pts'] + $statValues['trb'] + $statValues['ast'] - (2 * $statValues['tov'])
    $calculatedValue
}

function Get-PlayerIntegerForDisplay {
    param (
        [LiteDB.BsonDocument] $Document,
        [string] $Field
    )

    $text = Get-BsonText -Document $Document -Field $Field
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $value = [long] 0
    if ([long]::TryParse($text, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $value)) {
        return $value
    }

    $null
}

function Get-PlayerGamesForDisplay {
    param ([LiteDB.BsonDocument] $Document)

    $games = Get-PlayerIntegerForDisplay -Document $Document -Field 'games'
    if ($null -eq $games) {
        $games = Get-PlayerIntegerForDisplay -Document $Document -Field 'g'
    }
    $games
}

function Get-PlayerAverageForDisplay {
    param ([LiteDB.BsonDocument] $Document)

    $games = Get-PlayerGamesForDisplay -Document $Document
    if ($null -eq $games -or $games -le 0) {
        return $null
    }

    [Math]::Round([double] (Get-PlayerValueForDisplay -Document $Document) / [double] $games, 2)
}

function Set-PlayerRowAppearance {
    param (
        [System.Windows.Forms.DataGridViewRow] $Row,
        [LiteDB.BsonDocument] $Document
    )

    $assignment = Get-DraftAssignment -CollectionName ([string] $collectionComboBox.SelectedItem) -PlayerId (Get-BsonText -Document $Document -Field '_id')
    if ($null -ne $assignment -and (-not [string]::IsNullOrWhiteSpace($assignment.owner) -or $null -ne $assignment.draft_position)) {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(218, 222, 225)
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(91, 99, 103)
        $Row.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(184, 192, 197)
        $Row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(39, 48, 52)
        return
    }

    $eligiblePosition = Get-BsonText -Document $Document -Field 'elig_pos'
    if ([string]::IsNullOrWhiteSpace($eligiblePosition)) {
        $eligiblePosition = Get-BsonText -Document $Document -Field 'pos'
    }
    $eligiblePosition = $eligiblePosition.ToUpperInvariant()

    if ($eligiblePosition.Contains('G')) {
        $backColor = [System.Drawing.Color]::FromArgb(229, 242, 248)
        $selectionBackColor = [System.Drawing.Color]::FromArgb(197, 224, 238)
    }
    elseif ($eligiblePosition.Contains('F')) {
        $backColor = [System.Drawing.Color]::FromArgb(235, 244, 230)
        $selectionBackColor = [System.Drawing.Color]::FromArgb(205, 228, 192)
    }
    elseif ($eligiblePosition.Contains('C')) {
        $backColor = [System.Drawing.Color]::FromArgb(249, 241, 224)
        $selectionBackColor = [System.Drawing.Color]::FromArgb(237, 220, 183)
    }
    else {
        $backColor = [System.Drawing.Color]::White
        $selectionBackColor = [System.Drawing.Color]::FromArgb(220, 233, 232)
    }

    $Row.DefaultCellStyle.BackColor = $backColor
    $Row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(39, 48, 52)
    $Row.DefaultCellStyle.SelectionBackColor = $selectionBackColor
    $Row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(27, 48, 54)
}

function Set-TrackerStatus {
    param ([string] $Message)
    $statusLabel.Text = $Message
}

function Close-ActiveDatabase {
    $resetDraftButton.Enabled = $false
    $addPlayerButton.Enabled = $false
    if ($null -ne $script:Database) {
        $script:Database.Dispose()
        $script:Database = $null
    }
    $script:Collection = $null
    $script:PlayerDocuments = @()
    $script:SelectedDocumentId = $null
    $script:DraftDataPath = $null
    $script:DraftAssignments = @{}
}

function Show-PlayerSearchResults {
    $resultsGrid.Rows.Clear()
    $script:SelectedDocumentId = $null
    $selectedPlayerLabel.Text = 'Select a player from the results'
    $eligiblePosTextBox.Clear()
    $ownerTextBox.Clear()
    $teamTextBox.Clear()
    $eligiblePosTextBox.Enabled = $false
    $ownerTextBox.Enabled = $false
    $teamTextBox.Enabled = $false
    $saveButton.Enabled = $false
    $draftButton.Enabled = $false

    if ($null -eq $script:Collection) {
        return
    }

    $searchText = $searchTextBox.Text.Trim()
    foreach ($document in $script:PlayerDocuments) {
        $playerName = Get-BsonText -Document $document -Field 'player'
        if ($playerName.IndexOf($searchText, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        $position = Get-BsonText -Document $document -Field 'pos'
        $teamName = Get-BsonText -Document $document -Field 'team_name_abbr'
        if ([string]::IsNullOrWhiteSpace($teamName)) {
            $teamName = Get-BsonText -Document $document -Field 'team'
        }
        if ([string]::IsNullOrWhiteSpace($teamName)) {
            continue
        }

        $eligiblePosition = Get-BsonText -Document $document -Field 'elig_pos'
        if ([string]::IsNullOrWhiteSpace($eligiblePosition)) {
            if (-not [string]::IsNullOrWhiteSpace($position)) {
                $position = $position.Trim()
                $eligiblePosition = $position.Substring($position.Length - 1).ToUpperInvariant()
            }
        }
        $assignment = Get-DraftAssignment -CollectionName ([string] $collectionComboBox.SelectedItem) -PlayerId (Get-BsonText -Document $document -Field '_id')
        if ($null -ne $assignment -and -not [string]::IsNullOrWhiteSpace($assignment.elig_pos)) {
            $eligiblePosition = $assignment.elig_pos
        }
        $rowIndex = $resultsGrid.Rows.Add(
            $playerName,
            (Get-PlayerIntegerForDisplay -Document $document -Field 'age'),
            $eligiblePosition,
            $teamName,
            (Get-PlayerGamesForDisplay -Document $document),
            (Get-PlayerIntegerForDisplay -Document $document -Field 'pts'),
            (Get-PlayerIntegerForDisplay -Document $document -Field 'ast'),
            (Get-PlayerIntegerForDisplay -Document $document -Field 'trb'),
            (Get-PlayerIntegerForDisplay -Document $document -Field 'tov'),
            (Get-PlayerValueForDisplay -Document $document),
            (Get-PlayerAverageForDisplay -Document $document),
            $(if ($null -ne $assignment) { $assignment.owner } else { '' }),
            $(if ($null -ne $assignment) { $assignment.draft_position } else { $null })
        )
        $resultsGrid.Rows[$rowIndex].Tag = $document
        Set-PlayerRowAppearance -Row $resultsGrid.Rows[$rowIndex] -Document $document
    }

    if ($resultsGrid.Rows.Count -eq 0) {
        Set-TrackerStatus 'No players match this search.'
        return
    }

    $resultsGrid.CurrentCell = $resultsGrid.Rows[0].Cells['Player']
    $resultsGrid.Rows[0].Selected = $true
    Set-SelectedPlayerDetails
}

function Set-SelectedPlayerDetails {
    if ($resultsGrid.SelectedRows.Count -eq 0) {
        return
    }

    $document = $resultsGrid.SelectedRows[0].Tag
    if ($null -eq $document) {
        return
    }

    $script:SelectedDocumentId = Get-BsonText -Document $document -Field '_id'
    $selectedPlayerLabel.Text = Get-BsonText -Document $document -Field 'player'
    $eligiblePosition = Get-BsonText -Document $document -Field 'elig_pos'
    if ([string]::IsNullOrWhiteSpace($eligiblePosition)) {
        $position = Get-BsonText -Document $document -Field 'pos'
        if (-not [string]::IsNullOrWhiteSpace($position)) {
            $eligiblePosition = $position.Trim().Substring($position.Trim().Length - 1).ToUpperInvariant()
        }
    }
    $eligiblePosTextBox.Text = $eligiblePosition.ToUpperInvariant()
    $assignment = Get-DraftAssignment -CollectionName ([string] $collectionComboBox.SelectedItem) -PlayerId $script:SelectedDocumentId
    if ($null -ne $assignment -and -not [string]::IsNullOrWhiteSpace($assignment.elig_pos)) {
        $eligiblePosTextBox.Text = $assignment.elig_pos
    }
    $ownerTextBox.Text = if ($null -ne $assignment) { [string] $assignment.owner } else { '' }
    $draftPosTextBox.Text = if ($null -ne $assignment -and $null -ne $assignment.draft_position) { [string] $assignment.draft_position } else { '' }
    $teamName = Get-BsonText -Document $document -Field 'team_name_abbr'
    if ([string]::IsNullOrWhiteSpace($teamName)) {
        $teamName = Get-BsonText -Document $document -Field 'team'
    }
    $teamTextBox.Text = $teamName
    $draftPosition = $draftPosTextBox.Text
    $eligiblePosTextBox.Enabled = $true
    $ownerTextBox.Enabled = $true
    $draftPosTextBox.Enabled = $true
    $teamTextBox.Enabled = $true
    $saveButton.Enabled = $true
    $draftButton.Enabled = [string]::IsNullOrWhiteSpace($draftPosition) -and [string]::IsNullOrWhiteSpace($ownerTextBox.Text) -and $ownerOrderListBox.Items.Count -gt 0
}

function Invoke-DraftSelectedPlayer {
    if ($null -eq $script:Collection -or [string]::IsNullOrWhiteSpace($script:SelectedDocumentId)) {
        Set-TrackerStatus 'Select a player before drafting.'
        return
    }
    if ($ownerOrderListBox.Items.Count -eq 0) {
        Set-TrackerStatus 'Add owners to the draft order before drafting.'
        return
    }

    try {
        $document = $script:Collection.FindById($script:SelectedDocumentId)
        if ($null -eq $document) {
            throw 'The selected player no longer exists in this collection.'
        }

        $existingAssignment = Get-DraftAssignment -CollectionName ([string] $collectionComboBox.SelectedItem) -PlayerId $script:SelectedDocumentId
        if ($null -ne $existingAssignment -and (-not [string]::IsNullOrWhiteSpace($existingAssignment.owner) -or $null -ne $existingAssignment.draft_position)) {
            Set-TrackerStatus "$($document['player'].AsString) is already assigned to $($existingAssignment.owner)."
            return
        }

        $draftPickNumber = Get-NextDraftPickNumber
        $ownerIndex = Get-DraftOwnerIndex -PickNumber $draftPickNumber
        if ($ownerIndex -lt 0) {
            Set-TrackerStatus 'Add owners to the draft order before drafting.'
            return
        }
        $draftPosition = $ownerIndex + 1
        $draftOwner = [string] $ownerOrderListBox.Items[$ownerIndex]
        Set-DraftAssignment -CollectionName ([string] $collectionComboBox.SelectedItem) -PlayerId $script:SelectedDocumentId -Owner $draftOwner -DraftPosition ([long] $draftPickNumber) -EligibilityPosition (Get-PlayerEligibilityForDraft -Document $document)

        $draftedPlayerName = Get-BsonText -Document $document -Field 'player'
        for ($index = 0; $index -lt $script:PlayerDocuments.Count; $index++) {
            if ((Get-BsonText -Document $script:PlayerDocuments[$index] -Field '_id') -eq $script:SelectedDocumentId) {
                $script:PlayerDocuments[$index] = $document
                break
            }
        }

        foreach ($row in $resultsGrid.Rows) {
            if ((Get-BsonText -Document $row.Tag -Field '_id') -eq $script:SelectedDocumentId) {
                $row.Tag = $document
                $row.Cells['Owner'].Value = $draftOwner
                $row.Cells['DraftPos'].Value = [long] $draftPickNumber
                Set-PlayerRowAppearance -Row $row -Document $document
                break
            }
        }

        Update-CurrentDraftPosition
        Set-SelectedPlayerDetails
        Set-TrackerStatus "$draftedPlayerName drafted to $draftOwner at draft position $draftPosition (overall pick $draftPickNumber)."
    }
    catch {
        Set-TrackerStatus "Draft failed: $($_.Exception.Message)"
    }
}

function Add-PlayerToCollection {
    if ($null -eq $script:Collection) {
        Set-TrackerStatus 'Select a database collection before adding a player.'
        return
    }

    $playerName = $newPlayerNameTextBox.Text.Trim()
    $eligiblePosition = $newPlayerEligPosTextBox.Text.Trim().ToUpperInvariant()
    $teamName = $newPlayerTeamTextBox.Text.Trim().ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($playerName) -or [string]::IsNullOrWhiteSpace($eligiblePosition) -or [string]::IsNullOrWhiteSpace($teamName)) {
        Set-TrackerStatus 'Enter a player name, eligibility position, and team.'
        return
    }

    foreach ($existingPlayer in $script:PlayerDocuments) {
        if ([string]::Equals((Get-BsonText -Document $existingPlayer -Field 'player'), $playerName, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-TrackerStatus "Player '$playerName' already exists in this collection."
            return
        }
    }

    try {
        $document = [LiteDB.BsonDocument]::new()
        $document['_id'] = [LiteDB.BsonValue]::new($playerName)
        $document['player'] = [LiteDB.BsonValue]::new($playerName)
        $document['age'] = [LiteDB.BsonValue]::Null
        $document['pos'] = [LiteDB.BsonValue]::Null
        $document['elig_pos'] = [LiteDB.BsonValue]::new($eligiblePosition)
        $document['pts'] = [LiteDB.BsonValue]::Null
        $document['ast'] = [LiteDB.BsonValue]::Null
        $document['trb'] = [LiteDB.BsonValue]::Null
        $document['tov'] = [LiteDB.BsonValue]::Null
        $document['value'] = [LiteDB.BsonValue]::new([long] 0)
        $teamField = if ([string] $collectionComboBox.SelectedItem -eq 'WNBA') { 'team' } else { 'team_name_abbr' }
        $document[$teamField] = [LiteDB.BsonValue]::new($teamName)

        $script:Collection.Insert($document) | Out-Null
        $updatedPlayers = [System.Collections.Generic.List[LiteDB.BsonDocument]]::new()
        foreach ($existingPlayer in $script:PlayerDocuments) {
            $updatedPlayers.Add($existingPlayer)
        }
        $updatedPlayers.Add($document)
        $script:PlayerDocuments = $updatedPlayers.ToArray()

        $newPlayerNameTextBox.Clear()
        $newPlayerEligPosTextBox.Clear()
        $newPlayerTeamTextBox.Clear()
        $searchTextBox.Clear()
        Show-PlayerSearchResults

        foreach ($row in $resultsGrid.Rows) {
            if ((Get-BsonText -Document $row.Tag -Field '_id') -eq $playerName) {
                $resultsGrid.ClearSelection()
                $row.Selected = $true
                $resultsGrid.CurrentCell = $row.Cells['Player']
                Set-SelectedPlayerDetails
                break
            }
        }

        Set-TrackerStatus "$playerName added and ready to draft."
    }
    catch {
        Set-TrackerStatus "Could not add player: $($_.Exception.Message)"
    }
}

function Load-SelectedCollection {
    if ($null -eq $script:Database -or $null -eq $collectionComboBox.SelectedItem) {
        return
    }

    try {
        $script:Collection = $script:Database.GetCollection[LiteDB.BsonDocument]([string] $collectionComboBox.SelectedItem)
        $addPlayerButton.Enabled = $true
        $script:PlayerDocuments = @($script:Collection.FindAll())
        $legacyDraftDocuments = @($script:PlayerDocuments | Where-Object { $_.ContainsKey('drafted') -or $_.ContainsKey('owner') -or $_.ContainsKey('draft_pos') })
        if ($legacyDraftDocuments.Count -gt 0) {
            if (-not $script:Database.BeginTrans()) {
                throw 'Could not begin a transaction to remove legacy draft fields.'
            }
            try {
                foreach ($document in $legacyDraftDocuments) {
                    $null = $document.Remove('drafted')
                    $null = $document.Remove('owner')
                    $null = $document.Remove('draft_pos')
                    if (-not $script:Collection.Update($document)) {
                        throw "Could not remove legacy draft fields from '$($document['player'].AsString)'."
                    }
                }
                if (-not $script:Database.Commit()) {
                    throw 'Could not commit removal of legacy draft fields.'
                }
            }
            catch {
                try {
                    $null = $script:Database.Rollback()
                }
                catch {
                }
                throw
            }
            $script:PlayerDocuments = @($script:Collection.FindAll())
        }
        Update-CurrentDraftPosition
        Show-PlayerSearchResults
        if ($script:PlayerDocuments.Count -eq 0) {
            Set-TrackerStatus "No players found in '$($collectionComboBox.SelectedItem)' for this database."
        }
        else {
            Set-TrackerStatus "Loaded $($script:PlayerDocuments.Count) players from '$($collectionComboBox.SelectedItem)'."
        }
    }
    catch {
        $script:Collection = $null
        $script:PlayerDocuments = @()
        $addPlayerButton.Enabled = $false
        $resultsGrid.Rows.Clear()
        Set-TrackerStatus "Could not load collection: $($_.Exception.Message)"
    }
}

function Load-DraftOrder {
    $ownerOrderListBox.Items.Clear()
    Update-CurrentDraftPosition
    $draftOrderPanel.Enabled = $null -ne $script:Database
    if ($null -eq $script:Database) {
        return
    }

    try {
        Load-DraftData
        Update-CurrentDraftPosition
        Set-SelectedPlayerDetails
    }
    catch {
        Set-TrackerStatus "Could not load draft order: $($_.Exception.Message)"
    }
}

function Save-DraftOrder {
    if ($null -eq $script:Database) {
        return
    }

    try {
        Save-DraftData

        Update-CurrentDraftPosition
        Set-SelectedPlayerDetails
        Set-TrackerStatus 'Draft order saved.'
    }
    catch {
        Set-TrackerStatus "Could not save draft order: $($_.Exception.Message)"
    }
}

function Reset-DraftData {
    if ($null -eq $script:Database -or $null -eq $script:Collection) {
        throw 'Select a database and player collection before resetting the draft.'
    }

    $collectionName = [string] $collectionComboBox.SelectedItem
    foreach ($key in @($script:DraftAssignments.Keys)) {
        if ($key.StartsWith("$collectionName`0", [System.StringComparison]::OrdinalIgnoreCase)) {
            [void] $script:DraftAssignments.Remove($key)
        }
    }
    Save-DraftData
    Update-CurrentDraftPosition
    Show-PlayerSearchResults
    Set-TrackerStatus "Draft reset for '$collectionName'."
}

function Get-DraftedPlayerCount {
    $collectionPrefix = ([string] $collectionComboBox.SelectedItem) + [char] 0
    @($script:DraftAssignments.Keys | Where-Object { $_.StartsWith($collectionPrefix, [System.StringComparison]::OrdinalIgnoreCase) }).Count
}

function Get-NextDraftPickNumber {
    (Get-DraftedPlayerCount) + 1
}

function Get-DraftOwnerIndex {
    param ([int] $PickNumber)

    $ownerCount = $ownerOrderListBox.Items.Count
    if ($ownerCount -eq 0 -or $PickNumber -lt 1) {
        return -1
    }

    $roundIndex = [int] [Math]::Floor(($PickNumber - 1) / $ownerCount)
    $positionInRound = ($PickNumber - 1) % $ownerCount
    if (($roundIndex % 2) -eq 1) {
        return $ownerCount - 1 - $positionInRound
    }

    $positionInRound
}

function Update-CurrentDraftPosition {
    $pickNumber = Get-NextDraftPickNumber
    $currentDraftPositionLabel.Text = [string] $pickNumber

    if ($ownerOrderListBox.Items.Count -eq 0) {
        $currentDraftRoundLabel.Text = 'ROUND 1'
        $currentDraftOwnerLabel.Text = 'Add owners to draft order'
        return
    }

    $roundNumber = [int] [Math]::Floor(($pickNumber - 1) / $ownerOrderListBox.Items.Count) + 1
    if ($roundNumber -le $MaximumRounds) {
        $currentDraftRoundLabel.Text = "ROUND $roundNumber"
    } else {
        $currentDraftRoundLabel.Text = "Draft Complete!"
    }
    $ownerIndex = Get-DraftOwnerIndex -PickNumber $pickNumber
    if ($ownerIndex -lt 0) {
        $currentDraftOwnerLabel.Text = 'Add owners to draft order'
        return
    }

    $currentDraftOwnerLabel.Text = "$($ownerOrderListBox.Items[$ownerIndex]) up to pick!"
}

function Move-DraftOwner {
    param (
        [int] $Index,
        [int] $Offset
    )

    $newIndex = $Index + $Offset
    if ($Index -lt 0 -or $newIndex -lt 0 -or $newIndex -ge $ownerOrderListBox.Items.Count) {
        return
    }

    $ownerName = [string] $ownerOrderListBox.Items[$Index]
    $ownerOrderListBox.Items.RemoveAt($Index)
    $ownerOrderListBox.Items.Insert($newIndex, $ownerName)
    $ownerOrderListBox.SelectedIndex = $newIndex
    Save-DraftOrder
}

function Open-SelectedDatabase {
    if ($null -eq $databaseComboBox.SelectedItem) {
        return
    }

    $script:LoadingDatabase = $true
    try {
        Close-ActiveDatabase
        $selectedPath = [string] $databaseComboBox.SelectedItem
        $connectionString = [LiteDB.ConnectionString]::new()
        $connectionString.Filename = $selectedPath
        $connectionString.Connection = [LiteDB.ConnectionType]::Shared
        $script:Database = [LiteDB.LiteDatabase]::new($connectionString)
        $targetDraftDataPath = Get-DraftSidecarPath -DatabasePath $selectedPath
        $legacyDraftDataPath = [System.IO.Path]::ChangeExtension($selectedPath, '.json')
        $script:DraftDataPath = if (-not (Test-Path -LiteralPath $targetDraftDataPath -PathType Leaf) -and (Test-Path -LiteralPath $legacyDraftDataPath -PathType Leaf)) {
            $legacyDraftDataPath
        }
        else {
            $targetDraftDataPath
        }
        Load-DraftData
        if ($script:DraftDataPath -ne $targetDraftDataPath) {
            $script:DraftDataPath = $targetDraftDataPath
            Save-DraftData
        }
        $resetDraftButton.Enabled = $true
        $existingCollectionNames = @($script:Database.GetCollectionNames() | Where-Object { $_ -ne 'draft_owners' } | Sort-Object)
        $collectionNames = [System.Collections.Generic.List[string]]::new()

        if ($existingCollectionNames -contains 'players') {
            $collectionNames.Add('players')
        }
        foreach ($leagueCollection in 'NBA', 'WNBA') {
            $collectionNames.Add($leagueCollection)
        }
        foreach ($existingCollection in $existingCollectionNames) {
            if ($existingCollection -notin @('players', 'NBA', 'WNBA')) {
                $collectionNames.Add($existingCollection)
            }
        }

        $collectionComboBox.Items.Clear()
        foreach ($collectionName in $collectionNames) {
            [void] $collectionComboBox.Items.Add($collectionName)
        }

        $preferredCollection = if ($existingCollectionNames -contains 'players') {
            'players'
        }
        elseif ($existingCollectionNames -contains 'NBA') {
            'NBA'
        }
        elseif ($existingCollectionNames -contains 'WNBA') {
            'WNBA'
        }
        elseif ($existingCollectionNames.Count -gt 0) {
            $existingCollectionNames[0]
        }
        else {
            'NBA'
        }
        $collectionComboBox.SelectedItem = $preferredCollection
    }
    catch {
        Close-ActiveDatabase
        $collectionComboBox.Items.Clear()
        $resultsGrid.Rows.Clear()
        Set-TrackerStatus "Could not open database: $($_.Exception.Message)"
    }
    finally {
        $script:LoadingDatabase = $false
    }

    if ($null -ne $script:Database -and $null -ne $collectionComboBox.SelectedItem) {
        Load-SelectedCollection
    }
    Load-DraftOrder
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'Fantasy Basketball Draft Tracker'
$form.StartPosition = 'CenterScreen'
$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$minimumWidth = [Math]::Min(900, $workingArea.Width)
$minimumHeight = [Math]::Min(700, $workingArea.Height)
$form.MinimumSize = [System.Drawing.Size]::new($minimumWidth, $minimumHeight)
$form.Size = [System.Drawing.Size]::new(
    [Math]::Max($minimumWidth, [Math]::Min(1280, $workingArea.Width - 48)),
    [Math]::Max($minimumHeight, [Math]::Min(820, $workingArea.Height - 48))
)
$form.AutoScaleMode = 'None'
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 250)
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9.5)

$rootLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$rootLayout.Dock = 'Fill'
$rootLayout.Padding = [System.Windows.Forms.Padding]::new(18)
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 6
[void] $rootLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 60))
[void] $rootLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 48))
[void] $rootLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 44))
[void] $rootLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
[void] $rootLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 44))
[void] $rootLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 36))
$form.Controls.Add($rootLayout)

$titleLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$titleLayout.Dock = 'Fill'
$titleLayout.ColumnCount = 5
$titleLayout.RowCount = 1
[void] $titleLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 34))
[void] $titleLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 19))
[void] $titleLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 12))
[void] $titleLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 27))
[void] $titleLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 8))
$rootLayout.Controls.Add($titleLayout, 0, 0)

$titleLabel = [System.Windows.Forms.Label]::new()
$titleLabel.Text = 'FANTASY BASKETBALL  /  DRAFT TRACKER'
$titleLabel.Dock = 'Fill'
$titleLabel.AutoEllipsis = $true
$titleLabel.TextAlign = 'MiddleLeft'
$titleLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 16)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(27, 48, 54)
$titleLayout.Controls.Add($titleLabel, 0, 0)

$currentDraftOwnerLabel = [System.Windows.Forms.Label]::new()
$currentDraftOwnerLabel.Text = 'Add owners to draft order'
$currentDraftOwnerLabel.Dock = 'Fill'
$currentDraftOwnerLabel.TextAlign = 'MiddleRight'
$currentDraftOwnerLabel.AutoEllipsis = $true
$currentDraftOwnerLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
$currentDraftOwnerLabel.ForeColor = [System.Drawing.Color]::FromArgb(26, 104, 99)
$currentDraftOwnerLabel.Margin = [System.Windows.Forms.Padding]::new(0, 0, 12, 0)
$titleLayout.Controls.Add($currentDraftOwnerLabel, 1, 0)

$currentDraftRoundLabel = [System.Windows.Forms.Label]::new()
$currentDraftRoundLabel.Text = 'ROUND 1'
$currentDraftRoundLabel.Dock = 'Fill'
$currentDraftRoundLabel.TextAlign = 'MiddleCenter'
$currentDraftRoundLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
$currentDraftRoundLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$titleLayout.Controls.Add($currentDraftRoundLabel, 2, 0)

$currentDraftPositionCaption = [System.Windows.Forms.Label]::new()
$currentDraftPositionCaption.Text = 'CURRENT DRAFT POSITION'
$currentDraftPositionCaption.Dock = 'Fill'
$currentDraftPositionCaption.TextAlign = 'MiddleRight'
$currentDraftPositionCaption.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9.5)
$currentDraftPositionCaption.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$currentDraftPositionCaption.Margin = [System.Windows.Forms.Padding]::new(0, 0, 10, 0)
$titleLayout.Controls.Add($currentDraftPositionCaption, 3, 0)

$currentDraftPositionLabel = [System.Windows.Forms.Label]::new()
$currentDraftPositionLabel.Text = '1'
$currentDraftPositionLabel.Dock = 'Fill'
$currentDraftPositionLabel.TextAlign = 'MiddleCenter'
$currentDraftPositionLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 18)
$currentDraftPositionLabel.ForeColor = [System.Drawing.Color]::FromArgb(26, 104, 99)
$titleLayout.Controls.Add($currentDraftPositionLabel, 4, 0)

$databaseBar = [System.Windows.Forms.TableLayoutPanel]::new()
$databaseBar.Dock = 'Fill'
$databaseBar.ColumnCount = 5
$databaseBar.RowCount = 1
$databaseBar.Padding = [System.Windows.Forms.Padding]::new(0, 5, 0, 0)
[void] $databaseBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 190))
[void] $databaseBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
[void] $databaseBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 140))
[void] $databaseBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 220))
[void] $databaseBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 220))
$rootLayout.Controls.Add($databaseBar, 0, 1)

$databaseLabel = [System.Windows.Forms.Label]::new()
$databaseLabel.Text = 'DATABASE'
$databaseLabel.Dock = 'Fill'
$databaseLabel.TextAlign = 'MiddleLeft'
$databaseLabel.Margin = [System.Windows.Forms.Padding]::new(0, 0, 20, 0)
$databaseLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9.5)
$databaseLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$databaseBar.Controls.Add($databaseLabel, 0, 0)

$databaseComboBox = [System.Windows.Forms.ComboBox]::new()
$databaseComboBox.DropDownStyle = 'DropDownList'
$databaseComboBox.Dock = 'Fill'
$databaseComboBox.Margin = [System.Windows.Forms.Padding]::new(0, 2, 8, 0)
$databaseBar.Controls.Add($databaseComboBox, 1, 0)

$browseButton = [System.Windows.Forms.Button]::new()
$browseButton.Text = 'Browse...'
$browseButton.AutoSize = $true
$browseButton.Anchor = 'None'
$browseButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$browseButton.FlatStyle = 'Flat'
$browseButton.Margin = [System.Windows.Forms.Padding]::new(0, 1, 12, 0)
$databaseBar.Controls.Add($browseButton, 2, 0)

#$collectionLabel = [System.Windows.Forms.Label]::new()
#$collectionLabel.Text = 'COLLECTION'
#$collectionLabel.Dock = 'Fill'
#$collectionLabel.TextAlign = 'MiddleLeft'
#$collectionLabel.Margin = [System.Windows.Forms.Padding]::new(0, 0, 20, 0)
#$collectionLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9.5)
#$collectionLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
#$databaseBar.Controls.Add($collectionLabel, 3, 0)

$collectionComboBox = [System.Windows.Forms.ComboBox]::new()
$collectionComboBox.DropDownStyle = 'DropDownList'
$collectionComboBox.Dock = 'Fill'
$collectionComboBox.Margin = [System.Windows.Forms.Padding]::new(0, 2, 0, 0)
$databaseBar.Controls.Add($collectionComboBox, 4, 0)

$searchBar = [System.Windows.Forms.TableLayoutPanel]::new()
$searchBar.Dock = 'Fill'
$searchBar.ColumnCount = 6
$searchBar.RowCount = 1
$searchBar.Padding = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
[void] $searchBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 160))
[void] $searchBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
[void] $searchBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 105))
[void] $searchBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 135))
[void] $searchBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 135))
[void] $searchBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 52))
$rootLayout.Controls.Add($searchBar, 0, 2)

$searchLabel = [System.Windows.Forms.Label]::new()
$searchLabel.Text = 'FILTER'
$searchLabel.Dock = 'Fill'
$searchLabel.TextAlign = 'MiddleLeft'
$searchLabel.Margin = [System.Windows.Forms.Padding]::new(0, 0, 12, 0)
$searchLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9.5)
$searchLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$searchBar.Controls.Add($searchLabel, 0, 0)

$searchTextBox = [System.Windows.Forms.TextBox]::new()
$searchTextBox.Dock = 'Fill'
$searchTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 2, 8, 0)
$searchBar.Controls.Add($searchTextBox, 1, 0)

$searchButton = [System.Windows.Forms.Button]::new()
$searchButton.Text = 'Search'
$searchButton.AutoSize = $true
$searchButton.Anchor = 'None'
$searchButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$searchButton.FlatStyle = 'Flat'
#$searchButton.BackColor = [System.Drawing.Color]::FromArgb(26, 104, 99)
#$searchButton.ForeColor = [System.Drawing.Color]::White
$searchButton.Margin = [System.Windows.Forms.Padding]::new(0, 0, 8, 0)
$searchBar.Controls.Add($searchButton, 2, 0)

$draftButton = [System.Windows.Forms.Button]::new()
$draftButton.Text = 'DRAFT'
$draftButton.AutoSize = $true
$draftButton.Anchor = 'None'
$draftButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$draftButton.FlatStyle = 'Flat'
$draftButton.BackColor = [System.Drawing.Color]::FromArgb(26, 104, 99)
$draftButton.ForeColor = [System.Drawing.Color]::White
$draftButton.Margin = [System.Windows.Forms.Padding]::new(24, 0, 24, 0)
$draftButton.Enabled = $false
$searchBar.Controls.Add($draftButton, 3, 0)

$addPlayerBar = [System.Windows.Forms.TableLayoutPanel]::new()
$addPlayerBar.Dock = 'Fill'
$addPlayerBar.ColumnCount = 7
$addPlayerBar.RowCount = 1
$addPlayerBar.Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 4)
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 150))
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 80))
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 115))
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 90))
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 140))
[void] $addPlayerBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 56))
$rootLayout.Controls.Add($addPlayerBar, 0, 4)

$newPlayerNameLabel = [System.Windows.Forms.Label]::new()
$newPlayerNameLabel.Text = 'New Player'
$newPlayerNameLabel.Dock = 'Fill'
$newPlayerNameLabel.TextAlign = 'MiddleLeft'
$newPlayerNameLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$newPlayerNameLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$addPlayerBar.Controls.Add($newPlayerNameLabel, 0, 0)

$newPlayerNameTextBox = [System.Windows.Forms.TextBox]::new()
$newPlayerNameTextBox.Dock = 'Fill'
$newPlayerNameTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)
$addPlayerBar.Controls.Add($newPlayerNameTextBox, 1, 0)

$newPlayerEligPosLabel = [System.Windows.Forms.Label]::new()
$newPlayerEligPosLabel.Text = 'POS'
$newPlayerEligPosLabel.Dock = 'Fill'
$newPlayerEligPosLabel.TextAlign = 'MiddleLeft'
$newPlayerEligPosLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$newPlayerEligPosLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$addPlayerBar.Controls.Add($newPlayerEligPosLabel, 2, 0)

$newPlayerEligPosTextBox = [System.Windows.Forms.TextBox]::new()
$newPlayerEligPosTextBox.Dock = 'Fill'
$newPlayerEligPosTextBox.CharacterCasing = 'Upper'
$newPlayerEligPosTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)
$addPlayerBar.Controls.Add($newPlayerEligPosTextBox, 3, 0)

$newPlayerTeamLabel = [System.Windows.Forms.Label]::new()
$newPlayerTeamLabel.Text = 'TEAM'
$newPlayerTeamLabel.Dock = 'Fill'
$newPlayerEligPosTextBox.CharacterCasing = 'Upper'
$newPlayerTeamLabel.TextAlign = 'MiddleLeft'
$newPlayerTeamLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$newPlayerTeamLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$addPlayerBar.Controls.Add($newPlayerTeamLabel, 4, 0)

$newPlayerTeamTextBox = [System.Windows.Forms.TextBox]::new()
$newPlayerTeamTextBox.Dock = 'Fill'
$newPlayerTeamTextBox.CharacterCasing = 'Upper'
$newPlayerTeamTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 5, 10, 5)
$addPlayerBar.Controls.Add($newPlayerTeamTextBox, 5, 0)

$addPlayerButton = [System.Windows.Forms.Button]::new()
$addPlayerButton.Text = '+'
$addPlayerButton.AccessibleName = 'Add player'
$addPlayerButton.AccessibleDescription = 'Add player to the selected database collection'
$addPlayerButton.AutoSize = $true
$addPlayerButton.Anchor = 'None'
$addPlayerButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$addPlayerButton.FlatStyle = 'Flat'
$addPlayerButton.BackColor = [System.Drawing.Color]::FromArgb(26, 104, 99)
$addPlayerButton.ForeColor = [System.Drawing.Color]::White
$addPlayerButton.Enabled = $false
$addPlayerBar.Controls.Add($addPlayerButton, 6, 0)

$resetDraftButton = [System.Windows.Forms.Button]::new()
$resetDraftButton.Text = 'RESET'
$resetDraftButton.AutoSize = $true
$resetDraftButton.Anchor = 'None'
$resetDraftButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$resetDraftButton.FlatStyle = 'Flat'
$resetDraftButton.BackColor = [System.Drawing.Color]::FromArgb(153, 67, 67)
$resetDraftButton.ForeColor = [System.Drawing.Color]::White
$resetDraftButton.Margin = [System.Windows.Forms.Padding]::new(24, 0, 24, 0)
$resetDraftButton.Enabled = $false
$searchBar.Controls.Add($resetDraftButton, 4, 0)

$dashboardButton = [System.Windows.Forms.Button]::new()
$dashboardButton.Text = '🌐'
$dashboardButton.AccessibleName = 'Open Chumpball live dashboard'
$dashboardButton.AccessibleDescription = 'Launch the live draft dashboard in your browser'
$dashboardButton.AutoSize = $true
$dashboardButton.Anchor = 'None'
$dashboardButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$dashboardButton.Font = [System.Drawing.Font]::new('Segoe UI Symbol', 12)
$dashboardButton.FlatStyle = 'Flat'
$dashboardButton.Margin = [System.Windows.Forms.Padding]::new(4, 4, 0, 4)
$searchBar.Controls.Add($dashboardButton, 5, 0)
$dashboardToolTip = [System.Windows.Forms.ToolTip]::new()
$dashboardToolTip.SetToolTip($dashboardButton, 'Open Chumpball live dashboard')

$splitContainer = [System.Windows.Forms.SplitContainer]::new()
$splitContainer.Dock = 'Fill'
$splitContainer.FixedPanel = 'Panel2'
$splitContainer.Size = [System.Drawing.Size]::new(848, 300)
$splitContainer.Panel1MinSize = 420
$splitContainer.Panel2MinSize = 420
$splitContainer.SplitterDistance = 420
$rootLayout.Controls.Add($splitContainer, 0, 3)

$resultsGrid = [System.Windows.Forms.DataGridView]::new()
$resultsGrid.Dock = 'Fill'
$resultsGrid.BackgroundColor = [System.Drawing.Color]::White
$resultsGrid.BorderStyle = 'FixedSingle'
$resultsGrid.AllowUserToAddRows = $false
$resultsGrid.AllowUserToDeleteRows = $false
$resultsGrid.AllowUserToResizeRows = $false
$resultsGrid.ReadOnly = $true
$resultsGrid.MultiSelect = $false
$resultsGrid.SelectionMode = 'FullRowSelect'
$resultsGrid.RowHeadersVisible = $false
$resultsGrid.AutoGenerateColumns = $false
$resultsGrid.AutoSizeColumnsMode = 'Fill'
$resultsGrid.ColumnHeadersHeight = 38
$resultsGrid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(232, 238, 237)
$resultsGrid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(42, 61, 64)
$resultsGrid.EnableHeadersVisualStyles = $false
$resultsGrid.Columns.Add('Player', 'PLAYER') | Out-Null
$resultsGrid.Columns.Add('Age', 'AGE') | Out-Null
$resultsGrid.Columns.Add('EligPos', 'POS') | Out-Null
$resultsGrid.Columns.Add('Team', 'TEAM') | Out-Null
$resultsGrid.Columns.Add('Games', 'GAMES') | Out-Null
$resultsGrid.Columns.Add('Pts', 'PTS') | Out-Null
$resultsGrid.Columns.Add('Ast', 'AST') | Out-Null
$resultsGrid.Columns.Add('Trb', 'TRB') | Out-Null
$resultsGrid.Columns.Add('Tov', 'TOV') | Out-Null
$resultsGrid.Columns.Add('Value', 'VALUE') | Out-Null
$resultsGrid.Columns.Add('Avg', 'AVG') | Out-Null
$resultsGrid.Columns.Add('Owner', 'OWNER') | Out-Null
$resultsGrid.Columns.Add('DraftPos', 'DRAFT') | Out-Null
foreach ($numericColumn in 'Age', 'Games', 'Pts', 'Ast', 'Trb', 'Tov', 'Value', 'DraftPos') {
    $resultsGrid.Columns[$numericColumn].ValueType = [long]
    $resultsGrid.Columns[$numericColumn].SortMode = 'Automatic'
}
$resultsGrid.Columns['Avg'].ValueType = [double]
$resultsGrid.Columns['Avg'].SortMode = 'Automatic'
$resultsGrid.Columns['Player'].FillWeight = 170
$resultsGrid.Columns['Age'].FillWeight = 45
$resultsGrid.Columns['EligPos'].FillWeight = 70
$resultsGrid.Columns['Team'].FillWeight = 60
$resultsGrid.Columns['Games'].FillWeight = 55
$resultsGrid.Columns['Pts'].FillWeight = 50
$resultsGrid.Columns['Ast'].FillWeight = 50
$resultsGrid.Columns['Trb'].FillWeight = 50
$resultsGrid.Columns['Tov'].FillWeight = 50
$resultsGrid.Columns['Value'].FillWeight = 60
$resultsGrid.Columns['Avg'].FillWeight = 60
$resultsGrid.Columns['Owner'].FillWeight = 100
$resultsGrid.Columns['DraftPos'].FillWeight = 70
$splitContainer.Panel1.Controls.Add($resultsGrid)

$editorLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$editorLayout.Dock = 'Fill'
$editorLayout.Padding = [System.Windows.Forms.Padding]::new(24, 18, 18, 14)
$editorLayout.ColumnCount = 1
$editorLayout.RowCount = 6
[void] $editorLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 30))
[void] $editorLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 26))
[void] $editorLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 36))
[void] $editorLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 36))
[void] $editorLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 36))
[void] $editorLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
$splitContainer.Panel2.Controls.Add($editorLayout)

$editorTitle = [System.Windows.Forms.Label]::new()
$editorTitle.Text = 'PLAYER DETAILS'
$editorTitle.Dock = 'Fill'
$editorTitle.TextAlign = 'MiddleLeft'
$editorTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 12)
$editorTitle.ForeColor = [System.Drawing.Color]::FromArgb(27, 48, 54)
$editorLayout.Controls.Add($editorTitle, 0, 0)

$selectedPlayerLabel = [System.Windows.Forms.Label]::new()
$selectedPlayerLabel.Text = 'Select a player from the results'
$selectedPlayerLabel.Dock = 'Fill'
$selectedPlayerLabel.TextAlign = 'MiddleLeft'
$selectedPlayerLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$editorLayout.Controls.Add($selectedPlayerLabel, 0, 1)

$ownerDraftPositionLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$ownerDraftPositionLayout.Dock = 'Fill'
$ownerDraftPositionLayout.ColumnCount = 4
$ownerDraftPositionLayout.RowCount = 1
[void] $ownerDraftPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 60))
[void] $ownerDraftPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 50))
[void] $ownerDraftPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 90))
[void] $ownerDraftPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 60))
$editorLayout.Controls.Add($ownerDraftPositionLayout, 0, 2)

$ownerLabel = [System.Windows.Forms.Label]::new()
$ownerLabel.Text = 'OWN'
$ownerLabel.Dock = 'Fill'
$ownerLabel.TextAlign = 'MiddleLeft'
$ownerLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$ownerLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$ownerDraftPositionLayout.Controls.Add($ownerLabel, 0, 0)

$ownerTextBox = [System.Windows.Forms.TextBox]::new()
$ownerTextBox.Dock = 'Fill'
$ownerTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 4, 12, 4)
$ownerTextBox.Enabled = $false
$ownerDraftPositionLayout.Controls.Add($ownerTextBox, 1, 0)

$draftPosLabel = [System.Windows.Forms.Label]::new()
$draftPosLabel.Text = '#'
$draftPosLabel.Dock = 'Fill'
$draftPosLabel.TextAlign = 'MiddleLeft'
$draftPosLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$draftPosLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$ownerDraftPositionLayout.Controls.Add($draftPosLabel, 2, 0)

$draftPosTextBox = [System.Windows.Forms.TextBox]::new()
$draftPosTextBox.Dock = 'Fill'
$draftPosTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 4, 0, 4)
$draftPosTextBox.Enabled = $false
$ownerDraftPositionLayout.Controls.Add($draftPosTextBox, 3, 0)

$teamPositionLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$teamPositionLayout.Dock = 'Fill'
$teamPositionLayout.ColumnCount = 4
$teamPositionLayout.RowCount = 1
[void] $teamPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 60))
[void] $teamPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 50))
[void] $teamPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 90))
[void] $teamPositionLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 60))
$editorLayout.Controls.Add($teamPositionLayout, 0, 3)

$teamLabel = [System.Windows.Forms.Label]::new()
$teamLabel.Text = 'TM'
$teamLabel.Dock = 'Fill'
$teamLabel.TextAlign = 'MiddleLeft'
$teamLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$teamLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$teamPositionLayout.Controls.Add($teamLabel, 0, 0)

$teamTextBox = [System.Windows.Forms.TextBox]::new()
$teamTextBox.Dock = 'Fill'
$teamTextBox.CharacterCasing = 'Upper'
$teamTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 3, 12, 3)
$teamTextBox.Enabled = $false
$teamPositionLayout.Controls.Add($teamTextBox, 1, 0)

$eligiblePosLabel = [System.Windows.Forms.Label]::new()
$eligiblePosLabel.Text = 'POS'
$eligiblePosLabel.Dock = 'Fill'
$eligiblePosLabel.TextAlign = 'MiddleLeft'
$eligiblePosLabel.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 9)
$eligiblePosLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 105, 109)
$teamPositionLayout.Controls.Add($eligiblePosLabel, 2, 0)

$eligiblePosTextBox = [System.Windows.Forms.TextBox]::new()
$eligiblePosTextBox.Dock = 'Fill'
$eligiblePosTextBox.CharacterCasing = 'Upper'
$eligiblePosTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 3, 0, 3)
$eligiblePosTextBox.Enabled = $false
$teamPositionLayout.Controls.Add($eligiblePosTextBox, 3, 0)

$saveButton = [System.Windows.Forms.Button]::new()
$saveButton.Text = 'Save / Update'
$saveButton.AutoSize = $true
$saveButton.Anchor = 'None'
$saveButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$saveButton.FlatStyle = 'Flat'
$saveButton.BackColor = [System.Drawing.Color]::FromArgb(26, 104, 99)
$saveButton.ForeColor = [System.Drawing.Color]::White
$saveButton.Enabled = $false
$saveButton.Margin = [System.Windows.Forms.Padding]::new(0, 12, 0, 0)
$editorLayout.Controls.Add($saveButton, 0, 4)

$draftOrderPanel = [System.Windows.Forms.TableLayoutPanel]::new()
$draftOrderPanel.Dock = 'Fill'
$draftOrderPanel.ColumnCount = 1
$draftOrderPanel.RowCount = 5
$draftOrderPanel.Padding = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
[void] $draftOrderPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 34))
[void] $draftOrderPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100))
[void] $draftOrderPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 44))
[void] $draftOrderPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 6))
[void] $draftOrderPanel.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Absolute', 44))
$draftOrderPanel.Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 0)
$editorLayout.Controls.Add($draftOrderPanel, 0, 5)

$draftOrderTitle = [System.Windows.Forms.Label]::new()
$draftOrderTitle.Text = 'DRAFT ORDER'
$draftOrderTitle.Dock = 'Fill'
$draftOrderTitle.TextAlign = 'MiddleLeft'
$draftOrderTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
$draftOrderTitle.ForeColor = [System.Drawing.Color]::FromArgb(27, 48, 54)
$draftOrderPanel.Controls.Add($draftOrderTitle, 0, 0)

$ownerOrderListBox = [System.Windows.Forms.ListBox]::new()
$ownerOrderListBox.Dock = 'Fill'
$ownerOrderListBox.IntegralHeight = $false
$ownerOrderListBox.SelectionMode = 'One'
$draftOrderPanel.Controls.Add($ownerOrderListBox, 0, 1)

$ownerEntryLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$ownerEntryLayout.Dock = 'Fill'
$ownerEntryLayout.ColumnCount = 2
$ownerEntryLayout.RowCount = 1
[void] $ownerEntryLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100))
[void] $ownerEntryLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Absolute', 78))
$draftOrderPanel.Controls.Add($ownerEntryLayout, 0, 2)

$ownerNameTextBox = [System.Windows.Forms.TextBox]::new()
$ownerNameTextBox.Dock = 'Fill'
$ownerNameTextBox.AutoSize = $false
$ownerNameTextBox.MinimumSize = [System.Drawing.Size]::new(0, 24)
$ownerNameTextBox.Margin = [System.Windows.Forms.Padding]::new(0, 6, 8, 6)
$ownerEntryLayout.Controls.Add($ownerNameTextBox, 0, 0)

$addOwnerButton = [System.Windows.Forms.Button]::new()
$addOwnerButton.Text = 'Add'
$addOwnerButton.AutoSize = $true
$addOwnerButton.Anchor = 'None'
$addOwnerButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$addOwnerButton.FlatStyle = 'Flat'
$addOwnerButton.Margin = [System.Windows.Forms.Padding]::new(0, 5, 0, 5)
$ownerEntryLayout.Controls.Add($addOwnerButton, 1, 0)

$ownerActionsLayout = [System.Windows.Forms.TableLayoutPanel]::new()
$ownerActionsLayout.Dock = 'Fill'
$ownerActionsLayout.ColumnCount = 3
$ownerActionsLayout.RowCount = 1
foreach ($columnIndex in 0..2) {
    [void] $ownerActionsLayout.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 33.33))
}
$draftOrderPanel.Controls.Add($ownerActionsLayout, 0, 4)

$moveOwnerUpButton = [System.Windows.Forms.Button]::new()
$moveOwnerUpButton.Text = 'Up'
$moveOwnerUpButton.AutoSize = $true
$moveOwnerUpButton.Anchor = 'None'
$moveOwnerUpButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$moveOwnerUpButton.FlatStyle = 'Flat'
$moveOwnerUpButton.Margin = [System.Windows.Forms.Padding]::new(0, 5, 4, 5)
$ownerActionsLayout.Controls.Add($moveOwnerUpButton, 0, 0)

$moveOwnerDownButton = [System.Windows.Forms.Button]::new()
$moveOwnerDownButton.Text = 'Down'
$moveOwnerDownButton.AutoSize = $true
$moveOwnerDownButton.Anchor = 'None'
$moveOwnerDownButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$moveOwnerDownButton.FlatStyle = 'Flat'
$moveOwnerDownButton.Margin = [System.Windows.Forms.Padding]::new(2, 5, 2, 5)
$ownerActionsLayout.Controls.Add($moveOwnerDownButton, 1, 0)

$removeOwnerButton = [System.Windows.Forms.Button]::new()
$removeOwnerButton.Text = 'Remove'
$removeOwnerButton.AutoSize = $true
$removeOwnerButton.Anchor = 'None'
$removeOwnerButton.MaximumSize = [System.Drawing.Size]::new(0, 24)
$removeOwnerButton.FlatStyle = 'Flat'
$removeOwnerButton.Margin = [System.Windows.Forms.Padding]::new(4, 5, 0, 5)
$ownerActionsLayout.Controls.Add($removeOwnerButton, 2, 0)

$statusLabel = [System.Windows.Forms.Label]::new()
$statusLabel.Text = 'Select a database to begin.'
$statusLabel.Dock = 'Fill'
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(73, 91, 95)
$rootLayout.Controls.Add($statusLabel, 0, 5)

$databaseComboBox.Add_SelectedIndexChanged({
    if (-not $script:LoadingDatabase) {
        Open-SelectedDatabase
    }
})

$collectionComboBox.Add_SelectedIndexChanged({
    if (-not $script:LoadingDatabase) {
        Load-SelectedCollection
    }
})

$searchTextBox.Add_TextChanged({ Show-PlayerSearchResults })

$searchButton.Add_Click({
    Show-PlayerSearchResults
})

$dashboardButton.Add_Click({
    $dashboardUrl = 'http://127.0.0.1:8765/'
    try {
        $null = Invoke-WebRequest -Uri $dashboardUrl -TimeoutSec 2 -ErrorAction Stop
    }
    catch {
        $dashboardScript = Join-Path $PSScriptRoot 'Start-DraftDashboard.ps1'
        if (-not (Test-Path -LiteralPath $dashboardScript -PathType Leaf)) {
            Set-TrackerStatus "Dashboard server not found at '$dashboardScript'."
            return
        }

        try {
            $powerShellPath = (Get-Process -Id $PID).Path
            $arguments = @('-NoProfile', '-WindowStyle', 'Hidden', '-File', "`"$dashboardScript`"")
            Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop
        }
        catch {
            Set-TrackerStatus "Could not start the dashboard server: $($_.Exception.Message)"
            return
        }
    }

    try {
        Start-Process -FilePath $dashboardUrl -ErrorAction Stop
        Set-TrackerStatus 'Opened the Chumpball live dashboard in your browser.'
    }
    catch {
        Set-TrackerStatus "Could not open the dashboard: $($_.Exception.Message)"
    }
})

$addPlayerButton.Add_Click({
    Add-PlayerToCollection
})

$newPlayerTeamTextBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $addPlayerButton.PerformClick()
        $_.SuppressKeyPress = $true
    }
})

$draftButton.Add_Click({
    Invoke-DraftSelectedPlayer
})

$resultsGrid.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        $draftButton.PerformClick()
    }
})

$resetDraftButton.Add_Click({
    $confirmation = [System.Windows.Forms.MessageBox]::Show(
        $form,
        'Reset drafted players for this league? Player owners and draft positions will be cleared. The owner draft order will be preserved.',
        'Confirm Draft Reset',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Reset-DraftData
    }
    catch {
        Set-TrackerStatus "Draft reset failed: $($_.Exception.Message)"
    }
})

$resultsGrid.Add_SelectionChanged({ Set-SelectedPlayerDetails })
$resultsGrid.Add_CellClick({ Set-SelectedPlayerDetails })

$saveButton.Add_Click({
    if ($null -eq $script:Collection -or [string]::IsNullOrWhiteSpace($script:SelectedDocumentId)) {
        return
    }

    try {
        $document = $script:Collection.FindById($script:SelectedDocumentId)
        if ($null -eq $document) {
            throw 'The selected player no longer exists in this collection.'
        }
        $updatedPlayerName = Get-BsonText -Document $document -Field 'player'
        $draftPositionText = $draftPosTextBox.Text.Trim()
        $draftPositionValue = $null
        if (-not [string]::IsNullOrWhiteSpace($draftPositionText)) {
            $parsedDraftPosition = [long] 0
            if (-not [long]::TryParse($draftPositionText, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $parsedDraftPosition) -or $parsedDraftPosition -lt 1) {
                throw 'Draft Pos must be a positive whole number or blank.'
            }
            $draftPositionValue = $parsedDraftPosition
        }

        $document['elig_pos'] = if ([string]::IsNullOrWhiteSpace($eligiblePosTextBox.Text)) {
            [LiteDB.BsonValue]::Null
        }
        else {
            [LiteDB.BsonValue]::new($eligiblePosTextBox.Text.Trim().ToUpperInvariant())
        }
        $teamField = if ($document.ContainsKey('team_name_abbr') -or [string] $collectionComboBox.SelectedItem -ne 'WNBA') {
            'team_name_abbr'
        }
        else {
            'team'
        }
        $document[$teamField] = if ([string]::IsNullOrWhiteSpace($teamTextBox.Text)) {
            [LiteDB.BsonValue]::Null
        }
        else {
            [LiteDB.BsonValue]::new($teamTextBox.Text.Trim().ToUpperInvariant())
        }

        if (-not $script:Collection.Update($document)) {
            throw 'LiteDB did not update the selected player.'
        }
        Set-DraftAssignment -CollectionName ([string] $collectionComboBox.SelectedItem) -PlayerId $script:SelectedDocumentId -Owner $ownerTextBox.Text.Trim() -DraftPosition $draftPositionValue -EligibilityPosition (Get-PlayerEligibilityForDraft -Document $document)

        $eligiblePosition = Get-BsonText -Document $document -Field 'elig_pos'
        for ($index = 0; $index -lt $script:PlayerDocuments.Count; $index++) {
            if ((Get-BsonText -Document $script:PlayerDocuments[$index] -Field '_id') -eq $script:SelectedDocumentId) {
                $script:PlayerDocuments[$index] = $document
                break
            }
        }

        foreach ($row in $resultsGrid.Rows) {
            if ((Get-BsonText -Document $row.Tag -Field '_id') -eq $script:SelectedDocumentId) {
                $row.Tag = $document
                $row.Cells['EligPos'].Value = $eligiblePosition
                $row.Cells['Owner'].Value = $ownerTextBox.Text.Trim()
                $row.Cells['DraftPos'].Value = $draftPositionValue
                $updatedTeam = Get-BsonText -Document $document -Field 'team_name_abbr'
                if ([string]::IsNullOrWhiteSpace($updatedTeam)) {
                    $updatedTeam = Get-BsonText -Document $document -Field 'team'
                }
                $row.Cells['Team'].Value = $updatedTeam
                Set-PlayerRowAppearance -Row $row -Document $document
                break
            }
        }

        Update-CurrentDraftPosition
        Set-SelectedPlayerDetails
        Set-TrackerStatus "$updatedPlayerName updated successfully."
    }
    catch {
        Set-TrackerStatus "Save failed: $($_.Exception.Message)"
    }
})

$browseButton.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = 'Select a FantasyStats LiteDB database'
    $dialog.Filter = 'LiteDB databases (*.db)|*.db|All files (*.*)|*.*'
    $dialog.InitialDirectory = if (Test-Path -LiteralPath $DatabaseDirectory -PathType Container) {
        (Resolve-Path -LiteralPath $DatabaseDirectory).Path
    }
    else {
        $PSScriptRoot
    }

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedPath = [System.IO.Path]::GetFullPath($dialog.FileName)
        if (-not $databaseComboBox.Items.Contains($selectedPath)) {
            [void] $databaseComboBox.Items.Add($selectedPath)
        }
        $databaseComboBox.SelectedItem = $selectedPath
    }
    $dialog.Dispose()
})

$form.Add_FormClosed({
    Close-ActiveDatabase
})

$addOwnerButton.Add_Click({
    $ownerName = $ownerNameTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($ownerName)) {
        return
    }

    foreach ($existingOwner in $ownerOrderListBox.Items) {
        if ([string]::Equals([string] $existingOwner, $ownerName, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-TrackerStatus "Owner '$ownerName' is already in the draft order."
            return
        }
    }

    [void] $ownerOrderListBox.Items.Add($ownerName)
    $ownerOrderListBox.SelectedIndex = $ownerOrderListBox.Items.Count - 1
    $ownerNameTextBox.Clear()
    Save-DraftOrder
})

$ownerNameTextBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $addOwnerButton.PerformClick()
        $_.SuppressKeyPress = $true
    }
})

$moveOwnerUpButton.Add_Click({
    Move-DraftOwner -Index $ownerOrderListBox.SelectedIndex -Offset -1
})

$moveOwnerDownButton.Add_Click({
    Move-DraftOwner -Index $ownerOrderListBox.SelectedIndex -Offset 1
})

$removeOwnerButton.Add_Click({
    $selectedIndex = $ownerOrderListBox.SelectedIndex
    if ($selectedIndex -lt 0) {
        return
    }

    $ownerOrderListBox.Items.RemoveAt($selectedIndex)
    if ($ownerOrderListBox.Items.Count -gt 0) {
        $ownerOrderListBox.SelectedIndex = [Math]::Min($selectedIndex, $ownerOrderListBox.Items.Count - 1)
    }
    Save-DraftOrder
})

$databaseFiles = @()
if (Test-Path -LiteralPath $PSScriptRoot -PathType Container) {
    $databaseFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.db' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
}
if (Test-Path -LiteralPath $DatabaseDirectory -PathType Container) {
    $databaseFiles += @(Get-ChildItem -LiteralPath $DatabaseDirectory -Filter '*.db' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
}
$databaseFiles = @($databaseFiles | Sort-Object -Unique)
foreach ($databaseFile in $databaseFiles) {
    [void] $databaseComboBox.Items.Add($databaseFile)
}

if ($databaseComboBox.Items.Count -gt 0) {
    $preferredDatabase = $databaseFiles | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -eq (Get-Date).Year.ToString() } | Select-Object -First 1
    if ($preferredDatabase) {
        $databaseComboBox.SelectedItem = $preferredDatabase
    }
    else {
        $databaseComboBox.SelectedIndex = 0
    }
}
else {
    Set-TrackerStatus "No .db files found under '$PSScriptRoot'. Use Browse to select a database."
}

[System.Windows.Forms.Application]::EnableVisualStyles()
[void] $form.ShowDialog()
$form.Dispose()