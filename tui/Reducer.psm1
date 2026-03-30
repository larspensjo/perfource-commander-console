Set-StrictMode -Version Latest

$script:CommandHistoryMaxSize = 50
$script:CommandLogMaxSize     = 200
$script:BrowserGlobalActionTypes = @(
    'CommandStart', 'CommandFinish',
    'AsyncCommandStarted', 'AsyncCommandCancelling', 'AsyncCommandFailed', 'CommandCancelled',
    'PendingChangesLoaded', 'SubmittedChangesLoaded', 'FilesBaseLoaded', 'FilesEnrichmentDone', 'FilesEnrichmentFailed', 'DescribeLoaded', 'MutationCompleted',
    'ProcessStarted', 'ProcessFinished',
    'ToggleCommandModal', 'ShowCommandModal',
    'SwitchView',
    'Quit', 'Resize',
    'ToggleHelpOverlay', 'HideHelpOverlay',
    'OpenConfirmDialog', 'AcceptDialog', 'CancelDialog',
    'OpenMenu', 'MenuMoveUp', 'MenuMoveDown', 'MenuSwitchLeft', 'MenuSwitchRight', 'MenuSelect', 'MenuAccelerator',
    'WorkflowBegin', 'WorkflowItemComplete', 'WorkflowItemFailed', 'WorkflowEnd',
    'ReconcileMarks', 'UnmarkChanges',
    'LogCommandExecution',
    'OpenResolveSettings', 'SelectMergeTool'
)

# ── Request identity (M0.6) ───────────────────────────────────────────────────
# Monotonically increasing counter for PendingRequest identity.
$script:NextPendingRequestId = 1

# Scope assigned to each PendingRequest Kind.  Used by New-PendingRequest to
# derive Scope automatically so callsites don't hard-code a string.
$script:PendingRequestScopeByKind = @{
    'LoadFiles'           = 'Files'
    'LoadFilesEnrichment' = 'Files'
    'ReloadPending'       = 'Pending'
    'ReloadSubmitted'     = 'Submitted'
    'LoadMore'            = 'Submitted'
    'FetchDescribe'       = 'Describe'
    'DeleteChange'        = 'Mutation'
    'DeleteShelvedFiles'  = 'Mutation'
    'ShelveFiles'         = 'Mutation'
    'MoveFiles'           = 'Mutation'
    'SubmitChange'        = 'Mutation'
    'ExecuteWorkflow'     = 'Workflow'
    'SetMergeTool'        = 'Config'
    'ResolveFile'         = 'Mutation'
    'LoadFileLog'         = 'Graph'
}

function ConvertTo-NonEmptyStringValues {
    param([AllowNull()]$InputValues)

    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($InputValues)) {
        $text = [string]$value
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$values.Add($text)
        }
    }

    return @($values)
}

function New-PendingRequest {
    <#
    .SYNOPSIS
        Creates a PendingRequest envelope with stable identity and scope (M0.6).
    .DESCRIPTION
        Adds RequestId (monotonically increasing 'req-N'), Scope (derived from Kind via
        $script:PendingRequestScopeByKind), and Generation to any request properties
        hashtable.  Call sites pass a plain hashtable; this function returns the enriched
        [pscustomobject] ready for $State.Runtime.PendingRequest.
    .PARAMETER Properties
        Flat hashtable of request fields.  Must include 'Kind'.  Additional fields
        (e.g. ChangeId, CacheKey, WorkflowKind, ChangeIds) are passed through unchanged.
    .PARAMETER Generation
        Generation counter at the time of issue.  Callers read the appropriate
        State.Data.*Generation field and pass it here so completions can detect stale results.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Properties,
        [int]$Generation = 0
    )
    $kind  = [string]$Properties['Kind']
    $scope = if ($script:PendingRequestScopeByKind.ContainsKey($kind)) {
        $script:PendingRequestScopeByKind[$kind]
    } else {
        'Unknown'
    }

    $reqId = 'req-' + [string]$script:NextPendingRequestId
    $script:NextPendingRequestId++

    # Merge request-identity fields on top of any caller-supplied properties.
    # Caller-supplied Kind, Scope, Generation are overridden by the authoritative values.
    $enriched = $Properties + @{
        RequestId  = $reqId
        Scope      = $scope
        Generation = $Generation
    }

    return [pscustomobject]$enriched
}

# ── Menu definitions ─────────────────────────────────────────────────────────
# Each item: Id, Label, Accelerator, IsSeparator, IsEnabled (scriptblock: param($s))
# Separators have IsSeparator=$true and are skipped during navigation.

$script:MenuDefinitions = @{
    'File' = @(
        [pscustomobject]@{
            Id         = 'DeleteChange'
            Label      = 'Delete focused / marked changelists'
            Accelerator = 'X'
            IsSeparator = $false
            IsEnabled   = { param($s) Test-CanDeleteSelectedChanges -State $s }
        },
        [pscustomobject]@{
            Id          = 'DeleteShelvedFiles'
            Label       = 'Delete shelved files'
            Accelerator = 'U'
            IsSeparator = $false
            IsEnabled   = { param($s) Test-CanDeleteShelvedSelectedChanges -State $s }
        },
        [pscustomobject]@{
            Id          = 'MoveMarkedFiles'
            Label       = 'Move files from marked to focused'
            Accelerator = 'M'
            IsSeparator = $false
            IsEnabled   = { param($s)
                $mcProp  = $s.Query.PSObject.Properties['MarkedChangeIds']
                $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0
                $vcProp   = $s.Derived.PSObject.Properties['VisibleChangeIds']
                $hasFocus = $null -ne $vcProp -and $null -ne $vcProp.Value -and $vcProp.Value.Count -gt 0
                $viewMode = if ($s.Ui.PSObject.Properties['ViewMode']) { [string]$s.Ui.ViewMode } else { 'Pending' }
                $isPending = $viewMode -ne 'Submitted'
                $hasMarks -and $hasFocus -and $isPending
            }
        },
        [pscustomobject]@{
            Id          = 'ShelveFiles'
            Label       = 'Shelve files'
            Accelerator = 'S'
            IsSeparator = $false
            IsEnabled   = { param($s) Test-CanShelveSelectedChanges -State $s }
        },
        [pscustomobject]@{
            Id          = 'SubmitChange'
            Label       = 'Submit changelist'
            Accelerator = 'T'
            IsSeparator = $false
            IsEnabled   = { param($s) Test-CanSubmitSelectedChange -State $s }
        },
        [pscustomobject]@{
            Id          = 'ResolveFile'
            Label       = 'Resolve…'
            Accelerator = 'E'
            IsSeparator = $false
            IsEnabled   = { param($s)
                $screenProp = $s.Ui.PSObject.Properties['ScreenStack']
                if ($null -eq $screenProp -or $screenProp.Value.Count -eq 0) { return $false }
                if ([string]$screenProp.Value[-1] -ne 'Files') { return $false }
                $fileIndices = $s.Derived.VisibleFileIndices
                $fileIdx     = if (($s.Cursor.PSObject.Properties.Match('FileIndex')).Count -gt 0) { [int]$s.Cursor.FileIndex } else { 0 }
                if ($null -eq $fileIndices -or $fileIndices.Count -eq 0) { return $false }
                $cacheKey = "$($s.Data.FilesSourceChange)`:$($s.Data.FilesSourceKind)"
                $fileCache = $s.Data.PSObject.Properties['FileCache']?.Value
                if ($null -eq $fileCache -or -not $fileCache.ContainsKey($cacheKey)) { return $false }
                [object[]]$files = @($fileCache[$cacheKey])
                $rawIdx = if ($fileIdx -lt $fileIndices.Count) { [int]$fileIndices[$fileIdx] } else { -1 }
                if ($rawIdx -lt 0 -or $rawIdx -ge $files.Count) { return $false }
                [bool]$files[$rawIdx].IsUnresolved
            }
        },
        [pscustomobject]@{
            Id          = 'MergeTool'
            Label       = 'Merge tool settings…'
            Accelerator = 'G'
            IsSeparator = $false
            IsEnabled   = { $true }
        },
        [pscustomobject]@{ Id = '__FileSep1__'; Label = ''; Accelerator = ''; IsSeparator = $true;  IsEnabled = { $true } },
        [pscustomobject]@{
            Id         = 'MarkAllVisible'
            Label      = 'Mark all visible'
            Accelerator = 'V'
            IsSeparator = $false
            IsEnabled   = { param($s)
                $vcProp = $s.Derived.PSObject.Properties['VisibleChangeIds']
                $null -ne $vcProp -and $null -ne $vcProp.Value -and $vcProp.Value.Count -gt 0
            }
        },
        [pscustomobject]@{
            Id         = 'ClearMarks'
            Label      = 'Clear selection'
            Accelerator = 'C'
            IsSeparator = $false
            IsEnabled   = { param($s)
                $mcProp = $s.Query.PSObject.Properties['MarkedChangeIds']
                ($null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0)
            }
        },
        [pscustomobject]@{ Id = '__FileSep2__'; Label = ''; Accelerator = ''; IsSeparator = $true;  IsEnabled = { $true } },
        [pscustomobject]@{ Id = 'Refresh'; Label = 'Refresh';       Accelerator = 'R'; IsSeparator = $false; IsEnabled = { $true } },
        [pscustomobject]@{ Id = '__FileSep3__'; Label = ''; Accelerator = ''; IsSeparator = $true;  IsEnabled = { $true } },
        [pscustomobject]@{ Id = 'Quit';    Label = 'Quit';           Accelerator = 'Q'; IsSeparator = $false; IsEnabled = { $true } }
    )
    'View' = @(
        [pscustomobject]@{
            Id         = 'ViewPending'
            Label      = 'Pending changelists'
            Accelerator = 'P'
            IsSeparator = $false
            IsEnabled   = { param($s) $vm = if ($s.Ui.PSObject.Properties['ViewMode']) { [string]$s.Ui.ViewMode } else { 'Pending' }; $vm -ne 'Pending' }
        },
        [pscustomobject]@{
            Id         = 'ViewSubmitted'
            Label      = 'Submitted changelists'
            Accelerator = 'S'
            IsSeparator = $false
            IsEnabled   = { param($s) $vm = if ($s.Ui.PSObject.Properties['ViewMode']) { [string]$s.Ui.ViewMode } else { 'Pending' }; $vm -ne 'Submitted' }
        },
        [pscustomobject]@{ Id = 'ViewCommandLog'; Label = 'Command log';              Accelerator = 'L'; IsSeparator = $false; IsEnabled = { $true } },
        [pscustomobject]@{ Id = '__ViewSep0__'; Label = ''; Accelerator = ''; IsSeparator = $true;  IsEnabled = { $true } },
        [pscustomobject]@{
            Id          = 'ViewRevisionGraph'
            Label       = 'Revision graph'
            Accelerator = 'G'
            IsSeparator = $false
            IsEnabled   = { param($s)
                $screenProp = $s.Ui.PSObject.Properties['ScreenStack']
                if ($null -eq $screenProp -or $screenProp.Value.Count -eq 0) { return $false }
                if ([string]$screenProp.Value[-1] -ne 'Files') { return $false }
                $fileIndices = $s.Derived.VisibleFileIndices
                if ($null -eq $fileIndices -or $fileIndices.Count -eq 0) { return $false }
                $fileIdx  = if (($s.Cursor.PSObject.Properties.Match('FileIndex')).Count -gt 0) { [int]$s.Cursor.FileIndex } else { 0 }
                $cacheKey = "$($s.Data.FilesSourceChange)`:$($s.Data.FilesSourceKind)"
                $fileCache = $s.Data.PSObject.Properties['FileCache']?.Value
                if ($null -eq $fileCache -or -not $fileCache.ContainsKey($cacheKey)) { return $false }
                [object[]]$files = @($fileCache[$cacheKey])
                $rawIdx = if ($fileIdx -lt $fileIndices.Count) { [int]$fileIndices[$fileIdx] } else { -1 }
                $rawIdx -ge 0 -and $rawIdx -lt $files.Count
            }
        },
        [pscustomobject]@{ Id = '__ViewSep1__'; Label = ''; Accelerator = ''; IsSeparator = $true;  IsEnabled = { $true } },
        [pscustomobject]@{ Id = 'ToggleHideFilters'; Label = 'Hide unavailable filters';  Accelerator = 'H'; IsSeparator = $false; IsEnabled = { $true } },
        [pscustomobject]@{ Id = 'ExpandCollapse';    Label = 'Expand / collapse details'; Accelerator = 'E'; IsSeparator = $false; IsEnabled = { $true } },
        [pscustomobject]@{ Id = '__ViewSep2__'; Label = ''; Accelerator = ''; IsSeparator = $true;  IsEnabled = { $true } },
        [pscustomobject]@{ Id = 'Help';          Label = 'Help';                       Accelerator = '?'; IsSeparator = $false; IsEnabled = { $true } }
    )
}

Import-Module (Join-Path $PSScriptRoot 'Filtering.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Layout.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force

function Test-ChangeHasOpenedFiles {
    param($Change)

    if ($null -eq $Change) { return $false }

    $hasOpenedProp = $Change.PSObject.Properties['HasOpenedFiles']
    if ($null -ne $hasOpenedProp -and [bool]$hasOpenedProp.Value) {
        return $true
    }

    $openedCountProp = $Change.PSObject.Properties['OpenedFileCount']
    if ($null -ne $openedCountProp -and [int]$openedCountProp.Value -gt 0) {
        return $true
    }

    return $false
}

function Test-ChangeHasShelvedFiles {
    param($Change)

    if ($null -eq $Change) { return $false }

    $hasShelvedProp = $Change.PSObject.Properties['HasShelvedFiles']
    if ($null -ne $hasShelvedProp -and [bool]$hasShelvedProp.Value) {
        return $true
    }

    $shelvedCountProp = $Change.PSObject.Properties['ShelvedFileCount']
    if ($null -ne $shelvedCountProp -and [int]$shelvedCountProp.Value -gt 0) {
        return $true
    }

    return $false
}

function Get-DeleteActionableChangeIds {
    param($State)

    $viewMode = if ($State.Ui.PSObject.Properties['ViewMode']) { [string]$State.Ui.ViewMode } else { 'Pending' }
    if ($viewMode -ne 'Pending') { return @() }

    $mcProp = $State.Query.PSObject.Properties['MarkedChangeIds']
    $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0
    if ($hasMarks) {
        return @(ConvertTo-NonEmptyStringValues -InputValues $mcProp.Value | Sort-Object -Unique)
    }

    $visibleIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']
    if ($null -eq $visibleIdsProp -or $null -eq $visibleIdsProp.Value) { return @() }

    [object[]]$visibleIds = @($visibleIdsProp.Value)
    if ($visibleIds.Count -eq 0) { return @() }

    $focusedIndex = [Math]::Max(0, [Math]::Min([int]$State.Cursor.ChangeIndex, $visibleIds.Count - 1))
    return @([string]$visibleIds[$focusedIndex])
}

function Test-CanDeleteSelectedChanges {
    param($State)

    return @(Get-DeleteActionableChangeIds -State $State).Count -gt 0
}

function Get-DeleteShelvedActionableChanges {
    param($State)

    $viewMode = if ($State.Ui.PSObject.Properties['ViewMode']) { [string]$State.Ui.ViewMode } else { 'Pending' }
    if ($viewMode -ne 'Pending') { return @() }

    [object[]]$activeChanges = @($State.Data.AllChanges)
    $mcProp = $State.Query.PSObject.Properties['MarkedChangeIds']
    $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0

    if ($hasMarks) {
        $markedIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($markedId in @($mcProp.Value)) {
            [void]$markedIdSet.Add([string]$markedId)
        }

        return @(
            $activeChanges |
                Where-Object { $markedIdSet.Contains([string]$_.Id) } |
                Where-Object { Test-ChangeHasShelvedFiles -Change $_ }
        )
    }

    $visibleIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']
    if ($null -eq $visibleIdsProp -or $null -eq $visibleIdsProp.Value) { return @() }

    [object[]]$visibleIds = @($visibleIdsProp.Value)
    if ($visibleIds.Count -eq 0) { return @() }

    $focusedIndex = [Math]::Max(0, [Math]::Min([int]$State.Cursor.ChangeIndex, $visibleIds.Count - 1))
    $focusedId = [string]$visibleIds[$focusedIndex]

    return @(
        $activeChanges |
            Where-Object { [string]$_.Id -eq $focusedId } |
            Where-Object { Test-ChangeHasShelvedFiles -Change $_ } |
            Select-Object -First 1
    )
}

function Test-CanDeleteShelvedSelectedChanges {
    param($State)

    return @(Get-DeleteShelvedActionableChanges -State $State).Count -gt 0
}

function New-DeleteMarkedConfirmPayload {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string[]]$ChangeIds
    )

    $count = $ChangeIds.Count
    $summaryLines = @(
        "Selected: $count changelist$(if ($count -ne 1) { 's' } else { '' })"
        'Will attempt deletion in sequence'
    )

    $visibleIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']
    [object[]]$visibleIds = if ($null -ne $visibleIdsProp -and $null -ne $visibleIdsProp.Value) { @($visibleIdsProp.Value) } else { @() }
    if ($visibleIds.Count -gt 0) {
        $focusedIndex = [Math]::Max(0, [Math]::Min([int]$State.Cursor.ChangeIndex, $visibleIds.Count - 1))
        $focusedId = [string]$visibleIds[$focusedIndex]
        if (-not [string]::IsNullOrWhiteSpace($focusedId) -and $ChangeIds -notcontains $focusedId) {
            $summaryLines += "Focused: changelist $focusedId is not marked and will not be deleted"
        }
    }

    return [pscustomobject]@{
        Title            = "Delete $count marked changelist$(if ($count -ne 1) { 's' } else { '' })?"
        SummaryLines     = $summaryLines
        ConsequenceLines = @('Only empty changelists can be deleted')
        ConfirmLabel     = 'Y / Enter = confirm'
        CancelLabel      = 'N / Esc = cancel'
        OnAccept         = [pscustomobject]@{
            Kind         = 'ExecuteWorkflow'
            WorkflowKind = 'DeleteMarked'
            ChangeIds    = $ChangeIds
        }
    }
}

function New-DeleteShelvedConfirmPayload {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string[]]$ChangeIds
    )

    $count = $ChangeIds.Count
    $summaryLines = @(
        "Selected: $count changelist$(if ($count -ne 1) { 's' } else { '' })"
        'Shelved files will be deleted in sequence'
    )

    $visibleIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']
    [object[]]$visibleIds = if ($null -ne $visibleIdsProp -and $null -ne $visibleIdsProp.Value) { @($visibleIdsProp.Value) } else { @() }
    if ($visibleIds.Count -gt 0) {
        $focusedIndex = [Math]::Max(0, [Math]::Min([int]$State.Cursor.ChangeIndex, $visibleIds.Count - 1))
        $focusedId = [string]$visibleIds[$focusedIndex]
        if (-not [string]::IsNullOrWhiteSpace($focusedId) -and $ChangeIds -notcontains $focusedId) {
            $summaryLines += "Focused: changelist $focusedId is not marked and will not be changed"
        }
    }

    return [pscustomobject]@{
        Title            = "Delete shelved files from $count selected changelist$(if ($count -ne 1) { 's' } else { '' })?"
        SummaryLines     = $summaryLines
        ConsequenceLines = @('Opened files in these changelists will remain unchanged')
        ConfirmLabel     = 'Y / Enter = confirm'
        CancelLabel      = 'N / Esc = cancel'
        OnAccept         = [pscustomobject]@{
            Kind         = 'ExecuteWorkflow'
            WorkflowKind = 'DeleteShelvedFiles'
            ChangeIds    = $ChangeIds
        }
    }
}

function Get-ShelveActionableChanges {
    param($State)

    $viewMode = if ($State.Ui.PSObject.Properties['ViewMode']) { [string]$State.Ui.ViewMode } else { 'Pending' }
    if ($viewMode -ne 'Pending') { return @() }

    [object[]]$activeChanges = @($State.Data.AllChanges)
    $mcProp = $State.Query.PSObject.Properties['MarkedChangeIds']
    $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0

    if ($hasMarks) {
        $markedIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($markedId in @($mcProp.Value)) {
            [void]$markedIdSet.Add([string]$markedId)
        }

        return @(
            $activeChanges |
                Where-Object { $markedIdSet.Contains([string]$_.Id) } |
                Where-Object { Test-ChangeHasOpenedFiles -Change $_ }
        )
    }

    $visibleIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']
    if ($null -eq $visibleIdsProp -or $null -eq $visibleIdsProp.Value) { return @() }

    [object[]]$visibleIds = @($visibleIdsProp.Value)
    if ($visibleIds.Count -eq 0) { return @() }

    $focusedIndex = [Math]::Max(0, [Math]::Min([int]$State.Cursor.ChangeIndex, $visibleIds.Count - 1))
    $focusedId = [string]$visibleIds[$focusedIndex]

    return @(
        $activeChanges |
            Where-Object { [string]$_.Id -eq $focusedId } |
            Where-Object { Test-ChangeHasOpenedFiles -Change $_ } |
            Select-Object -First 1
    )
}

function Test-CanShelveSelectedChanges {
    param($State)

    return @(Get-ShelveActionableChanges -State $State).Count -gt 0
}

function Get-SubmitActionableChangeId {
    param($State)

    $viewMode = if ($State.Ui.PSObject.Properties['ViewMode']) { [string]$State.Ui.ViewMode } else { 'Pending' }
    if ($viewMode -ne 'Pending') { return $null }

    $visibleIdsProp = $State.Derived.PSObject.Properties['VisibleChangeIds']
    if ($null -eq $visibleIdsProp -or $null -eq $visibleIdsProp.Value) { return $null }

    [object[]]$visibleIds = @($visibleIdsProp.Value)
    if ($visibleIds.Count -eq 0) { return $null }

    $focusedIndex = [Math]::Max(0, [Math]::Min([int]$State.Cursor.ChangeIndex, $visibleIds.Count - 1))
    $focusedId = [string]$visibleIds[$focusedIndex]

    [object[]]$activeChanges = @($State.Data.AllChanges)
    $focusedChange = $activeChanges | Where-Object { [string]$_.Id -eq $focusedId } | Select-Object -First 1
    if ($null -eq $focusedChange) { return $null }
    if (-not (Test-ChangeHasOpenedFiles -Change $focusedChange)) { return $null }

    return $focusedId
}

function Test-CanSubmitSelectedChange {
    param($State)

    return $null -ne (Get-SubmitActionableChangeId -State $State)
}

# ── Changelist viewport geometry helpers ──────────────────────────────────────
# These must stay in sync with the render logic in Render.psm1 (which uses H-2).

function Get-ChangeInnerViewRows {
    param($State)
    if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        return [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
    }
    return 1
}

function Get-ChangeRowsPerItem {
    param($State)
    $expanded = $false
    if ($null -ne $State.Ui -and ($State.Ui.PSObject.Properties.Match('ExpandedChangelists')).Count -gt 0) {
        $expanded = [bool]$State.Ui.ExpandedChangelists
    }
    if ($expanded) {
        $innerRows = Get-ChangeInnerViewRows -State $State
        if ($innerRows -ge 2) { return 2 }
    }
    return 1
}

function Get-ChangeViewCapacity {
    param($State)
    $innerRows   = Get-ChangeInnerViewRows -State $State
    $rowsPerItem = Get-ChangeRowsPerItem   -State $State
    return [Math]::Max(1, [Math]::Floor($innerRows / $rowsPerItem))
}
# ──────────────────────────────────────────────────────────────────────────────

function Copy-StateObject {
    <#
    .SYNOPSIS
        Generic deep copy for PSCustomObject state trees.
    .DESCRIPTION
        Recursively copies PSCustomObject properties.
        HashSet<string> values are copied into a new set with the same comparer.
        IDictionary values (hashtables / dictionaries) are kept as shared
        references — append-only caches such as DescribeCache and FileCache are
        large and safe to share across reducer calls.
        Arrays are copied into new arrays with each element recursively copied.
        Primitives are returned by value.
    #>
    param([AllowNull()]$Obj)

    if ($null -eq $Obj) { return $null }

    # Primitive scalars — returned by value
    if ($Obj -is [string] -or $Obj -is [int] -or $Obj -is [bool] -or
        $Obj -is [long]   -or $Obj -is [double] -or $Obj -is [datetime] -or
        $Obj -is [System.Enum]) {
        return $Obj
    }

    # HashSet<string> — copy into a new set preserving the comparer.
    # Use Write-Output -NoEnumerate to prevent PowerShell from unrolling an empty set to $null.
    if ($Obj -is [System.Collections.Generic.HashSet[string]]) {
        $newSet = [System.Collections.Generic.HashSet[string]]::new($Obj.Comparer)
        foreach ($item in $Obj) { [void]$newSet.Add($item) }
        Write-Output -NoEnumerate $newSet
        return
    }

    # IDictionary (Hashtable / Dictionary) — keep as shared reference.
    # Caches such as DescribeCache and FileCache are append-only, so sharing is safe.
    if ($Obj -is [System.Collections.IDictionary]) {
        return $Obj
    }

    # Array — shallow-copy the array container.
    # State arrays hold immutable scalars or reference objects that are replaced
    # wholesale rather than mutated in-place, so cloning each element is wasted
    # work on the reducer hot path.
    # Use Write-Output -NoEnumerate to prevent an empty array from being unrolled to $null.
    if ($Obj -is [array]) {
        Write-Output -NoEnumerate ($Obj.Clone())
        return
    }

    # PSCustomObject — new object with all NoteProperty values recursively copied.
    # Build a single ordered hashtable and cast once; this is substantially
    # faster than creating an empty PSCustomObject and appending properties with
    # Add-Member on every reducer action.
    if ($Obj -is [pscustomobject]) {
        $copyMap = [ordered]@{}
        foreach ($prop in $Obj.PSObject.Properties) {
            if ($prop.MemberType -eq 'NoteProperty') {
                $propCopy = Copy-StateObject -Obj $prop.Value
                # PowerShell scalar-izes single-item pipeline output; re-wrap arrays that
                # were collapsed to a scalar so state arrays such as ScreenStack survive
                # the copy without losing their [array] type.
                if ($prop.Value -is [array] -and $propCopy -isnot [array]) {
                    $propCopy = [object[]] @($propCopy)
                }
                $copyMap[$prop.Name] = $propCopy
            }
        }
        return [pscustomobject]$copyMap
    }

    # Fallback — return as-is for unknown reference types
    return $Obj
}

function New-BrowserState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory = $false)][int]$InitialWidth = 120,
        [Parameter(Mandatory = $false)][int]$InitialHeight = 40
    )

    $state = [pscustomobject]@{
        Data = [pscustomobject]@{
            AllChanges        = @($Changes)
            AllFilters        = @(Get-AllFilterNames -ViewMode 'Pending')
            DescribeCache     = @{}
            # FileCache: keyed by "<Change>:<SourceKind>"; append-only, shared across copies.
            FileCache         = @{}
            FilesSourceChange = $null
            FilesSourceKind   = ''
            CurrentUser       = ''
            CurrentClient     = ''
            SubmittedChanges  = @()
            SubmittedHasMore  = $true
            SubmittedOldestId = $null
            # CommandOutputCache: keyed by CommandId (string); append-only, shared across copies.
            CommandOutputCache = @{}
            # FileCacheStatus: keyed by CacheKey; values are 'Loading' | 'Ready' | 'Error' (M0.4).
            FileCacheStatus    = @{}
            # Generation counters incremented whenever the corresponding collection is invalidated.
            # Main-loop completions read these to detect stale results (M0.6).
            FilesGeneration     = 0
            PendingGeneration   = 0
            SubmittedGeneration = 0
            GraphGeneration     = 0
            # Revision graph data; null until OpenRevisionGraph is dispatched.
            RevisionGraph       = $null
            # Set to $true by MutationCompleted(MutationKind='ResolveFile') so that
            # the first FilesEnrichmentDone (or FilesBaseLoaded for submitted) after
            # a resolve also chains a ReloadPending to refresh the changelist summary.
            ReloadPendingAfterEnrichment = $false
        }
        Ui = [pscustomobject]@{
            ActivePane             = 'Filters'
            # ScreenStack: active screen is always ScreenStack[-1].
            ScreenStack            = @('Changelists')
            IsMaximized            = $false
            HideUnavailableFilters = $false
            ExpandedChangelists    = $false
            ViewMode               = 'Pending'
            Layout                 = Get-BrowserLayout -Width $InitialWidth -Height $InitialHeight
            ExpandedCommands       = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            OverlayMode            = 'None'   # 'None' | 'Help' | 'Confirm' | 'Menu'
            OverlayPayload         = $null    # typed payload for the active overlay
        }
        Query = [pscustomobject]@{
            SelectedFilters  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            MarkedChangeIds  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            SearchText       = ''
            SearchMode       = 'None'
            SortMode         = 'Default'
            FileFilterTokens = @()   # parsed token list; see Step 4
            FileFilterText   = ''    # raw text for display
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds      = @()
            VisibleFilters        = @()
            VisibleFileIndices    = @()  # int[] indices into FileCache entry
            VisibleCommandIds     = @()  # CommandId strings for CommandLog view
            VisibleCommandFilters = @()  # filter items for CommandLog left pane
            GraphRows             = @()  # flat row list for RevisionGraph screen
        }
        Cursor = [pscustomobject]@{
            FilterIndex       = 0
            FilterScrollTop   = 0
            ChangeIndex       = 0
            ChangeScrollTop   = 0
            FileIndex         = 0
            FileScrollTop     = 0
            CommandIndex      = 0
            CommandScrollTop  = 0
            OutputIndex       = 0
            OutputScrollTop   = 0
            GraphRowIndex     = 0
            GraphScrollTop    = 0
            ViewSnapshots     = [pscustomobject]@{
                Pending    = [pscustomobject]@{ ChangeIndex = 0; ChangeScrollTop = 0 }
                Submitted  = [pscustomobject]@{ ChangeIndex = 0; ChangeScrollTop = 0 }
                CommandLog = [pscustomobject]@{ CommandIndex = 0; CommandScrollTop = 0 }
            }
        }
        Runtime = [pscustomobject]@{
            IsRunning        = $true
            LastError        = $null
            DetailChangeId   = $null
            PendingRequest   = $null
            CancelRequested  = $false   # set by Esc when busy; cleared by WorkflowEnd (M3.1)
            QuitRequested    = $false   # set by Q when busy; main loop dispatches Quit when safe (M3.1)
            ActiveWorkflow       = $null   # null | @{ Kind; TotalCount; DoneCount; FailedCount; FailedIds }
            LastWorkflowResult  = $null   # null | @{ Kind; DoneCount; FailedCount; FailedIds }
            ActiveCommand        = $null   # null | @{ RequestId; Kind; Scope; Generation; CommandLine; StartedAt; Status; CurrentProcessId; ProcessIds } (M4.5/M5.2)
            ConfiguredMax  = 200
            NextCommandId            = 1
            CommandLog               = @()
            CommandOutputCommandId   = $null
            ModalPrompt              = [pscustomobject]@{
                IsOpen            = $false
                IsBusy            = $false
                Purpose           = 'Command'
                CurrentCommand    = ''
                CurrentTimeoutMs  = 0
                History           = @()
            }
        }
    }

    return Update-BrowserDerivedState -State $state
}

function Copy-BrowserState {
    <#
    .SYNOPSIS
        Deep-copies the browser state.
    .DESCRIPTION
        Delegates to Copy-StateObject for a generic recursive copy.
        IDictionary values (DescribeCache, FileCache, etc.) are kept as shared
        references because they are append-only and potentially large.
    #>
    param([Parameter(Mandatory = $true)]$State)
    return Copy-StateObject -Obj $State
}

# ── Menu helpers ──────────────────────────────────────────────────────────────

function Get-ComputedMenuItems {
    <#
    .SYNOPSIS
        Returns the menu items for a named top-level menu with IsEnabled resolved
        against the supplied state.  Used by OpenMenu and navigation actions.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$MenuName,
        [Parameter(Mandatory = $true)]$State
    )
    $rawItems = $script:MenuDefinitions[$MenuName]
    if ($null -eq $rawItems) { return @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $rawItems) {
        if ([bool]$item.IsSeparator) {
            $result.Add($item)
        } else {
            $enabled = try { [bool](& $item.IsEnabled $State) } catch { $false }
            $result.Add([pscustomobject]@{
                Id          = [string]$item.Id
                Label       = [string]$item.Label
                Accelerator = [string]$item.Accelerator
                IsSeparator = $false
                IsEnabled   = $enabled
            })
        }
    }
    return $result.ToArray()
}

function Get-MenuFocusedItem {
    <#
    .SYNOPSIS
        Returns the menu item at the given navigable index (0-based, separators excluded).
        Returns $null if the index is out of range.
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$ComputedItems,
        [Parameter(Mandatory = $true)][int]$FocusIndex
    )
    $navIdx = 0
    foreach ($item in $ComputedItems) {
        if (-not [bool]$item.IsSeparator) {
            if ($navIdx -eq $FocusIndex) { return $item }
            $navIdx++
        }
    }
    return $null
}

function Get-MenuNavigableCount {
    <#
    .SYNOPSIS
        Returns the number of non-separator items in a computed menu item array.
    #>
    param([Parameter(Mandatory = $true)][object[]]$ComputedItems)
    $count = 0
    foreach ($item in $ComputedItems) {
        if (-not [bool]$item.IsSeparator) { $count++ }
    }
    return $count
}

# ─────────────────────────────────────────────────────────────────────────────

function Get-CommandOutputCount {
    <#
    .SYNOPSIS
        Returns the number of formatted output lines for the currently viewed command.
    #>
    param($State)
    $cmdId = ''
    $cidProp = $State.Runtime.PSObject.Properties['CommandOutputCommandId']
    if ($null -ne $cidProp -and $null -ne $cidProp.Value) { $cmdId = [string]$cidProp.Value }
    if ([string]::IsNullOrEmpty($cmdId)) { return 0 }
    $cache = $State.Data.PSObject.Properties['CommandOutputCache']?.Value
    if ($null -eq $cache -or -not $cache.ContainsKey($cmdId)) { return 0 }
    return @($cache[$cmdId]).Count
}

function Get-OutputViewportSize {
    param($State)
    if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        return [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
    }
    return 10
}

function Update-OutputDerivedState {
    param($State)
    $outputCount = Get-CommandOutputCount -State $State
    $viewport    = Get-OutputViewportSize  -State $State

    if ($outputCount -eq 0) {
        $State.Cursor.OutputIndex     = 0
        $State.Cursor.OutputScrollTop = 0
        return $State
    }

    if ($State.Cursor.OutputIndex -lt 0)             { $State.Cursor.OutputIndex = 0 }
    if ($State.Cursor.OutputIndex -ge $outputCount)  { $State.Cursor.OutputIndex = $outputCount - 1 }
    $maxScroll = [Math]::Max(0, $outputCount - $viewport)
    if ($State.Cursor.OutputScrollTop -lt 0)         { $State.Cursor.OutputScrollTop = 0 }
    if ($State.Cursor.OutputScrollTop -gt $maxScroll){ $State.Cursor.OutputScrollTop = $maxScroll }
    if ($State.Cursor.OutputIndex -lt $State.Cursor.OutputScrollTop) {
        $State.Cursor.OutputScrollTop = $State.Cursor.OutputIndex
    }
    if ($State.Cursor.OutputIndex -ge ($State.Cursor.OutputScrollTop + $viewport)) {
        $State.Cursor.OutputScrollTop = [Math]::Max(0, $State.Cursor.OutputIndex - $viewport + 1)
    }
    return $State
}

function Update-CommandLogDerivedState {
    <#
    .SYNOPSIS
        Computes derived state for the CommandLog view mode.
    .DESCRIPTION
        Called by Update-BrowserDerivedState when ViewMode -eq 'CommandLog'.
        Computes VisibleCommandIds, VisibleCommandFilters, and VisibleFilters.
        Clamps CommandIndex/CommandScrollTop and FilterIndex/FilterScrollTop.
    #>
    param([Parameter(Mandatory = $true)]$State)

    # Get CommandLog (newest first in storage)
    $commandLog = @()
    $clProp = $State.Runtime.PSObject.Properties['CommandLog']
    if ($null -ne $clProp -and $null -ne $clProp.Value) {
        $commandLog = @($clProp.Value)
    }

    # Get predicates keyed by filter name
    $predicates     = Get-CommandLogFilterPredicates -CommandLog $commandLog
    $allFilterNames = @($predicates.Keys)
    $State.Data.AllFilters = $allFilterNames

    # Compute VisibleCommandIds — oldest first (reverse of storage)
    $selectedFilters = $State.Query.SelectedFilters
    $visibleIds = [System.Collections.Generic.List[string]]::new()
    for ($i = $commandLog.Count - 1; $i -ge 0; $i--) {
        $entry   = $commandLog[$i]
        $passes  = $true
        foreach ($filter in $selectedFilters) {
            $pred = $predicates[$filter]
            if ($null -ne $pred -and -not ([bool](& $pred $entry))) {
                $passes = $false
                break
            }
        }
        if ($passes) { [void]$visibleIds.Add([string]$entry.CommandId) }
    }
    [object[]]$visibleCommandIds = @($visibleIds.ToArray())
    $State.Derived.VisibleCommandIds = $visibleCommandIds

    # Compute filter items (same shape as VisibleFilters so filter pane reuse works)
    $filterItems = [System.Collections.Generic.List[object]]::new()
    foreach ($filterName in $allFilterNames) {
        $matchCount = 0
        foreach ($entry in $commandLog) {
            $pred = $predicates[$filterName]
            if ($null -ne $pred -and [bool](& $pred $entry)) { $matchCount++ }
        }
        $isSelected   = $selectedFilters.Contains($filterName)
        $filterItems.Add([pscustomobject]@{
            Name        = $filterName
            MatchCount  = $matchCount
            IsSelected  = $isSelected
            IsSelectable = ($isSelected -or ($matchCount -gt 0))
        }) | Out-Null
    }
    $allCommandFilters = @($filterItems.ToArray())
    $State.Derived.VisibleFilters        = $allCommandFilters
    $State.Derived.VisibleCommandFilters = $allCommandFilters

    # Clamp FilterIndex / FilterScrollTop
    $filterViewport = 1
    if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        $filterViewport = [Math]::Max(1, $State.Ui.Layout.FilterPane.H - 2)
    }
    $filterCount = $allCommandFilters.Count
    if ($filterCount -eq 0) {
        $State.Cursor.FilterIndex     = 0
        $State.Cursor.FilterScrollTop = 0
    } else {
        if ($State.Cursor.FilterIndex -lt 0)              { $State.Cursor.FilterIndex = 0 }
        if ($State.Cursor.FilterIndex -ge $filterCount)   { $State.Cursor.FilterIndex = $filterCount - 1 }
        $maxFilterScroll = [Math]::Max(0, $filterCount - $filterViewport)
        if ($State.Cursor.FilterScrollTop -lt 0)          { $State.Cursor.FilterScrollTop = 0 }
        if ($State.Cursor.FilterScrollTop -gt $maxFilterScroll) { $State.Cursor.FilterScrollTop = $maxFilterScroll }
        if ($State.Cursor.FilterIndex -lt $State.Cursor.FilterScrollTop) {
            $State.Cursor.FilterScrollTop = $State.Cursor.FilterIndex
        }
        if ($State.Cursor.FilterIndex -ge ($State.Cursor.FilterScrollTop + $filterViewport)) {
            $State.Cursor.FilterScrollTop = [Math]::Max(0, $State.Cursor.FilterIndex - $filterViewport + 1)
        }
    }

    # Clamp CommandIndex / CommandScrollTop
    $commandCount = $visibleCommandIds.Count
    if ($commandCount -eq 0) {
        $State.Cursor.CommandIndex     = 0
        $State.Cursor.CommandScrollTop = 0
    } else {
        if ($State.Cursor.CommandIndex -lt 0)              { $State.Cursor.CommandIndex = 0 }
        if ($State.Cursor.CommandIndex -ge $commandCount)  { $State.Cursor.CommandIndex = $commandCount - 1 }
        $commandViewport = if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
            [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
        } else { 1 }
        $maxCommandScroll = [Math]::Max(0, $commandCount - $commandViewport)
        if ($State.Cursor.CommandScrollTop -lt 0)          { $State.Cursor.CommandScrollTop = 0 }
        if ($State.Cursor.CommandScrollTop -gt $maxCommandScroll) { $State.Cursor.CommandScrollTop = $maxCommandScroll }
        if ($State.Cursor.CommandIndex -lt $State.Cursor.CommandScrollTop) {
            $State.Cursor.CommandScrollTop = $State.Cursor.CommandIndex
        }
        if ($State.Cursor.CommandIndex -ge ($State.Cursor.CommandScrollTop + $commandViewport)) {
            $State.Cursor.CommandScrollTop = [Math]::Max(0, $State.Cursor.CommandIndex - $commandViewport + 1)
        }
    }

    # Safety: CommandLog mode does not display changelists
    $State.Derived.VisibleChangeIds   = @()
    $State.Derived.VisibleFileIndices = @()

    return $State
}

function Update-BrowserCursorState {
    param([Parameter(Mandatory = $true)]$State)

    $viewMode = if (($State.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$State.Ui.ViewMode } else { 'Pending' }
    if ($viewMode -eq 'CommandLog') {
        return Update-CommandLogDerivedState -State $State
    }

    $visibleCount = if (($State.Derived.PSObject.Properties.Match('VisibleChangeIds')).Count -gt 0 -and $null -ne $State.Derived.VisibleChangeIds) {
        $State.Derived.VisibleChangeIds.Count
    } else { 0 }

    if ($visibleCount -eq 0) {
        $State.Cursor.ChangeIndex = 0
        $State.Cursor.ChangeScrollTop = 0
    } else {
        if ($State.Cursor.ChangeIndex -ge $visibleCount) {
            $State.Cursor.ChangeIndex = $visibleCount - 1
        }
        if ($State.Cursor.ChangeIndex -lt 0) {
            $State.Cursor.ChangeIndex = 0
        }
        if ($State.Cursor.ChangeScrollTop -lt 0) {
            $State.Cursor.ChangeScrollTop = 0
        }

        $changeViewport = Get-ChangeViewCapacity -State $State
        $maxChangeScroll = [Math]::Max(0, $visibleCount - $changeViewport)
        if ($State.Cursor.ChangeScrollTop -gt $maxChangeScroll) {
            $State.Cursor.ChangeScrollTop = $maxChangeScroll
        }
        if ($State.Cursor.ChangeIndex -lt $State.Cursor.ChangeScrollTop) {
            $State.Cursor.ChangeScrollTop = $State.Cursor.ChangeIndex
        }
        if ($State.Cursor.ChangeIndex -ge ($State.Cursor.ChangeScrollTop + $changeViewport)) {
            $State.Cursor.ChangeScrollTop = [Math]::Max(0, $State.Cursor.ChangeIndex - $changeViewport + 1)
        }
    }

    $filterViewport = 1
    if ($State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
        $filterViewport = [Math]::Max(1, $State.Ui.Layout.FilterPane.H - 2)
    }

    $filterCount = if (($State.Derived.PSObject.Properties.Match('VisibleFilters')).Count -gt 0 -and $null -ne $State.Derived.VisibleFilters) {
        $State.Derived.VisibleFilters.Count
    } else { 0 }

    if ($filterCount -eq 0) {
        $State.Cursor.FilterIndex = 0
        $State.Cursor.FilterScrollTop = 0
    } else {
        if ($State.Cursor.FilterIndex -lt 0) {
            $State.Cursor.FilterIndex = 0
        }
        if ($State.Cursor.FilterIndex -ge $filterCount) {
            $State.Cursor.FilterIndex = $filterCount - 1
        }

        $maxFilterScroll = [Math]::Max(0, $filterCount - $filterViewport)
        if ($State.Cursor.FilterScrollTop -gt $maxFilterScroll) {
            $State.Cursor.FilterScrollTop = $maxFilterScroll
        }
        if ($State.Cursor.FilterScrollTop -lt 0) {
            $State.Cursor.FilterScrollTop = 0
        }
        if ($State.Cursor.FilterIndex -lt $State.Cursor.FilterScrollTop) {
            $State.Cursor.FilterScrollTop = $State.Cursor.FilterIndex
        }
        if ($State.Cursor.FilterIndex -ge ($State.Cursor.FilterScrollTop + $filterViewport)) {
            $State.Cursor.FilterScrollTop = [Math]::Max(0, $State.Cursor.FilterIndex - $filterViewport + 1)
        }
    }

    if (($State.Cursor.PSObject.Properties.Match('FileIndex')).Count -gt 0) {
        $fileCount = if (($State.Derived.PSObject.Properties.Match('VisibleFileIndices')).Count -gt 0 -and $null -ne $State.Derived.VisibleFileIndices) {
            $State.Derived.VisibleFileIndices.Count
        } else { 0 }

        if ($fileCount -eq 0) {
            $State.Cursor.FileIndex     = 0
            $State.Cursor.FileScrollTop = 0
        } else {
            if ($State.Cursor.FileIndex -lt 0) { $State.Cursor.FileIndex = 0 }
            if ($State.Cursor.FileIndex -ge $fileCount) { $State.Cursor.FileIndex = $fileCount - 1 }

            $fileViewport  = if ($null -ne $State.Ui.Layout -and $State.Ui.Layout.Mode -eq 'Normal') {
                [Math]::Max(1, $State.Ui.Layout.ListPane.H - 2)
            } else { 1 }
            $maxFileScroll = [Math]::Max(0, $fileCount - $fileViewport)
            if ($State.Cursor.FileScrollTop -lt 0) { $State.Cursor.FileScrollTop = 0 }
            if ($State.Cursor.FileScrollTop -gt $maxFileScroll) { $State.Cursor.FileScrollTop = $maxFileScroll }
            if ($State.Cursor.FileIndex -lt $State.Cursor.FileScrollTop) {
                $State.Cursor.FileScrollTop = $State.Cursor.FileIndex
            }
            if ($State.Cursor.FileIndex -ge ($State.Cursor.FileScrollTop + $fileViewport)) {
                $State.Cursor.FileScrollTop = [Math]::Max(0, $State.Cursor.FileIndex - $fileViewport + 1)
            }
        }
    }

    return $State
}

function Update-BrowserDerivedState {
    param([Parameter(Mandatory = $true)]$State)

    # Determine active source list and view context
    $viewMode    = if (($State.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$State.Ui.ViewMode } else { 'Pending' }
    $currentUser = if (($State.Data.PSObject.Properties.Match('CurrentUser')).Count -gt 0) { [string]$State.Data.CurrentUser } else { '' }

    # CommandLog mode has entirely separate derived state — return early.
    if ($viewMode -eq 'CommandLog') {
        return Update-CommandLogDerivedState -State $State
    }

    # IMPORTANT: do NOT use if/else expression for @()-valued branches — PowerShell swallows
    # empty-array pipeline output and the variable becomes $null, failing [AllowEmptyCollection()].
    [object[]]$activeChanges = @()
    if ($viewMode -eq 'Submitted') {
        if (($State.Data.PSObject.Properties.Match('SubmittedChanges')).Count -gt 0 -and $null -ne $State.Data.SubmittedChanges) {
            $activeChanges = @($State.Data.SubmittedChanges)
        }
    } else {
        $activeChanges = @($State.Data.AllChanges)
    }

    # Regenerate AllFilters for the active view mode
    $State.Data.AllFilters = @(Get-AllFilterNames -ViewMode $viewMode -CurrentUser $currentUser)

    $visibleChangeIds = Get-VisibleChangeIds `
        -AllChanges $activeChanges `
        -SelectedFilters $State.Query.SelectedFilters `
        -SearchText $State.Query.SearchText `
        -SearchMode $State.Query.SearchMode `
        -SortMode $State.Query.SortMode `
        -ViewMode $viewMode `
        -CurrentUser $currentUser
    $State.Derived.VisibleChangeIds = @($visibleChangeIds)

    $visibleChangeIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $State.Derived.VisibleChangeIds) {
        [void]$visibleChangeIdSet.Add([string]$id)
    }

    $visibleChanges = @($activeChanges | Where-Object { $visibleChangeIdSet.Contains([string]$_.Id) })

    $filterItems = New-Object System.Collections.Generic.List[object]
    foreach ($filter in $State.Data.AllFilters) {
        $matchCount = 0
        foreach ($cl in $visibleChanges) {
            if (Test-EntryMatchesFilter -FilterName $filter -Entry $cl -ViewMode $viewMode -CurrentUser $currentUser) {
                $matchCount++
            }
        }

        $isSelected   = $State.Query.SelectedFilters.Contains($filter)
        $isSelectable = $isSelected -or ($matchCount -gt 0)

        $filterItems.Add([pscustomobject]@{
            Name        = $filter
            MatchCount  = $matchCount
            IsSelected  = $isSelected
            IsSelectable = $isSelectable
        }) | Out-Null
    }

    $VisibleFilters = @($filterItems.ToArray())
    if ($State.Ui.HideUnavailableFilters) {
        $VisibleFilters = @($VisibleFilters | Where-Object { $_.IsSelected -or $_.IsSelectable })
    }
    $State.Derived.VisibleFilters = @($VisibleFilters)

    # ── Files screen derived state ────────────────────────────────────────────
    # Compute VisibleFileIndices from the cached file list.
    # Filter token application is deferred to Step 4; for now all loaded entries
    # are visible.
    $fileCache      = $State.Data.PSObject.Properties['FileCache']?.Value
    $sourceChangeProp = $State.Data.PSObject.Properties['FilesSourceChange']
    $sourceKindProp   = $State.Data.PSObject.Properties['FilesSourceKind']
    if ($null -ne $fileCache -and $null -ne $sourceChangeProp -and $null -ne $sourceKindProp) {
        $cacheKey = "$($sourceChangeProp.Value)`:$($sourceKindProp.Value)"
        if ($null -ne $sourceChangeProp.Value -and
            -not [string]::IsNullOrEmpty([string]$sourceKindProp.Value) -and
            $fileCache.ContainsKey($cacheKey)) {
            $allFiles = @($fileCache[$cacheKey])
            if ($allFiles.Count -gt 0) {
                $State.Derived.VisibleFileIndices = @(0..($allFiles.Count - 1))
            } else {
                $State.Derived.VisibleFileIndices = @()
            }
        } else {
            $State.Derived.VisibleFileIndices = @()
        }
    } elseif (($State.Derived.PSObject.Properties.Match('VisibleFileIndices')).Count -gt 0) {
        $State.Derived.VisibleFileIndices = @()
    }

    return Update-BrowserCursorState -State $State
}

function Get-FilterViewportSize {
    param($CurrentState)
    if ($CurrentState.Ui.Layout -and $CurrentState.Ui.Layout.Mode -eq 'Normal') {
        return [Math]::Max(1, $CurrentState.Ui.Layout.FilterPane.H - 2)
    }
    return 1
}

function Test-IsBrowserGlobalAction {
    param([Parameter(Mandatory = $true)][string]$ActionType)
    return ($ActionType -in $script:BrowserGlobalActionTypes)
}

function Get-ChangeViewportSize {
    param($CurrentState)
    return Get-ChangeViewCapacity -State $CurrentState
}

function Invoke-ChangelistReducer {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    $next = Copy-BrowserState -State $State
    $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }

    switch ($Action.Type) {
        'CommandStart' {
            $next.Runtime.ModalPrompt.IsBusy         = $true
            $next.Runtime.ModalPrompt.IsOpen         = $true
            $next.Runtime.ModalPrompt.Purpose        = 'Command'
            $next.Runtime.ModalPrompt.CurrentCommand = [string]$Action.CommandLine
            $next.Runtime.ModalPrompt.CurrentTimeoutMs = if (($Action.PSObject.Properties.Match('TimeoutMs')).Count -gt 0) { [int]$Action.TimeoutMs } else { 0 }
            return $next
        }
        'CommandFinish' {
            $startedAt  = [datetime]$Action.StartedAt
            $endedAt    = [datetime]$Action.EndedAt
            $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)
            $succeeded  = [bool]$Action.Succeeded
            $historyItem = [pscustomobject]@{
                StartedAt     = $startedAt
                EndedAt       = $endedAt
                CommandLine   = [string]$Action.CommandLine
                ExitCode      = [int]$Action.ExitCode
                Succeeded     = $succeeded
                ErrorText     = [string]$Action.ErrorText
                DurationMs    = $durationMs
                DurationClass = if (($Action.PSObject.Properties.Match('DurationClass')).Count -gt 0) { [string]$Action.DurationClass } else { 'Normal' }
                Outcome       = if (($Action.PSObject.Properties.Match('Outcome')).Count -gt 0) { [string]$Action.Outcome } else { if ($succeeded) { 'Completed' } else { 'Failed' } }
            }
            $trimmed = @($historyItem) + @($next.Runtime.ModalPrompt.History |
                Select-Object -First ($script:CommandHistoryMaxSize - 1))
            $next.Runtime.ModalPrompt.History           = $trimmed
            $next.Runtime.ModalPrompt.IsBusy            = $false
            $next.Runtime.ModalPrompt.CurrentCommand    = ''
            $next.Runtime.ModalPrompt.CurrentTimeoutMs  = 0
            if ($succeeded) {
                $next.Runtime.ModalPrompt.IsOpen = $false
            }
            $next.Runtime.ActiveCommand   = $null   # clear async-command tracking (M4.5)
            $next.Runtime.CancelRequested = $false
            return $next
        }
        'AsyncCommandStarted' {
            # M4: background read-only command started — update modal and track active request
            $next.Runtime.ModalPrompt.IsBusy          = $true
            $next.Runtime.ModalPrompt.IsOpen          = $true
            $next.Runtime.ModalPrompt.Purpose         = 'Command'
            $next.Runtime.ModalPrompt.CurrentCommand  = [string]$Action.CommandLine
            $next.Runtime.ModalPrompt.CurrentTimeoutMs = if (($Action.PSObject.Properties.Match('TimeoutMs')).Count -gt 0) { [int]$Action.TimeoutMs } else { 0 }
            $next.Runtime.ActiveCommand = [pscustomobject]@{
                RequestId   = [string]$Action.RequestId
                Kind        = [string]$Action.Kind
                Scope       = [string]$Action.Scope
                Generation  = [int]$Action.Generation
                CommandLine = [string]$Action.CommandLine
                StartedAt   = [datetime]$Action.StartedAt
                Status      = 'Running'
                CurrentProcessId = $null
                ProcessIds       = @()
            }
            return $next
        }
        'AsyncCommandCancelling' {
            if ($null -ne $next.Runtime.ActiveCommand) {
                $reqId = if (($Action.PSObject.Properties.Match('RequestId')).Count -gt 0) { [string]$Action.RequestId } else { '' }
                if ([string]::IsNullOrWhiteSpace($reqId) -or [string]$next.Runtime.ActiveCommand.RequestId -eq $reqId) {
                    $next.Runtime.ActiveCommand.Status = 'Cancelling'
                }
            }
            return $next
        }
        'PendingChangesLoaded' {
            # M4.7: drop stale completions by generation
            $generation = [int]$Action.Generation
            if ($generation -lt $next.Data.PendingGeneration) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }
            # Reconcile marks: remove stale IDs no longer in the fresh set
            [string[]]$freshIds = foreach ($change in @($Action.AllChanges)) {
                if ($null -eq $change) { continue }
                $id = [string]$change.Id
                if (-not [string]::IsNullOrWhiteSpace($id)) { $id }
            }
            $validSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($id in $freshIds) { [void]$validSet.Add($id) }
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $staleIds = @($markedProp.Value | Where-Object { -not $validSet.Contains([string]$_) })
                foreach ($staleId in $staleIds) { [void]$markedProp.Value.Remove($staleId) }
            }
            $next.Data.AllChanges      = @($Action.AllChanges)
            $next.Runtime.LastError    = $null
            $next.Runtime.ActiveCommand = $null
            return Update-BrowserDerivedState -State $next
        }
        'SubmittedChangesLoaded' {
            # M4.7: drop stale completions
            $generation = [int]$Action.Generation
            if ($generation -lt $next.Data.SubmittedGeneration) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }
            $entries    = @($Action.Entries)
            $appendMode = if (($Action.PSObject.Properties.Match('AppendMode')).Count -gt 0) { [bool]$Action.AppendMode } else { $false }
            if ($appendMode) {
                $next.Data.SubmittedChanges = @($next.Data.SubmittedChanges) + $entries
            } else {
                # Replace: reconcile marks so stale IDs are removed
                [string[]]$freshIds = foreach ($entry in $entries) {
                    if ($null -eq $entry) { continue }
                    $id = [string]$entry.Id
                    if (-not [string]::IsNullOrWhiteSpace($id)) { $id }
                }
                $validSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($id in $freshIds) { [void]$validSet.Add($id) }
                $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
                if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                    $staleIds = @($markedProp.Value | Where-Object { -not $validSet.Contains([string]$_) })
                    foreach ($staleId in $staleIds) { [void]$markedProp.Value.Remove($staleId) }
                }
                $next.Data.SubmittedChanges = $entries
            }
            if (($Action.PSObject.Properties.Match('HasMore')).Count -gt 0) { $next.Data.SubmittedHasMore  = [bool]$Action.HasMore  }
            if (($Action.PSObject.Properties.Match('OldestId')).Count -gt 0) { $next.Data.SubmittedOldestId = $Action.OldestId }
            $next.Runtime.LastError     = $null
            $next.Runtime.ActiveCommand = $null
            return Update-BrowserDerivedState -State $next
        }
        'FilesBaseLoaded' {
            # M4.7: drop stale completions
            $cacheKey   = [string]$Action.CacheKey
            $generation = [int]$Action.Generation
            if ($generation -lt $next.Data.FilesGeneration) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }
            $next.Data.FileCache[$cacheKey]       = @($Action.FileEntries)
            $next.Runtime.LastError               = $null
            $next.Runtime.ActiveCommand           = $null
            $sourceKind = if (($Action.PSObject.Properties.Match('SourceKind')).Count -gt 0) { [string]$Action.SourceKind } else { '' }
            if ($sourceKind -eq 'Opened') {
                # Signal enrichment follow-up (M2.1)
                $next.Data.FileCacheStatus[$cacheKey] = 'BaseReady'
                $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'LoadFilesEnrichment'; CacheKey = $cacheKey } -Generation $next.Data.FilesGeneration
            } else {
                # Submitted source: no enrichment, mark ready immediately
                $next.Data.FileCacheStatus[$cacheKey] = 'Ready'
                # Chain ReloadPending if a resolve just completed (dual-refresh)
                if ([bool]$next.Data.ReloadPendingAfterEnrichment) {
                    $next.Data.ReloadPendingAfterEnrichment = $false
                    $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'ReloadPending' } -Generation $next.Data.PendingGeneration
                }
            }
            return Update-BrowserDerivedState -State $next
        }
        'FilesEnrichmentDone' {
            # M4.7: drop stale completions
            $cacheKey   = [string]$Action.CacheKey
            $generation = [int]$Action.Generation
            if ($generation -lt $next.Data.FilesGeneration) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }
            $next.Data.FileCache[$cacheKey]       = @($Action.FileEntries)
            $next.Data.FileCacheStatus[$cacheKey] = 'Ready'
            $next.Runtime.LastError               = $null
            $next.Runtime.ActiveCommand           = $null
            # Chain ReloadPending if a resolve just completed (dual-refresh)
            if ([bool]$next.Data.ReloadPendingAfterEnrichment) {
                $next.Data.ReloadPendingAfterEnrichment = $false
                $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'ReloadPending' } -Generation $next.Data.PendingGeneration
            }
            return Update-BrowserDerivedState -State $next
        }
        'FilesEnrichmentFailed' {
            $cacheKey = [string]$Action.CacheKey
            $next.Data.FileCacheStatus[$cacheKey] = 'EnrichmentFailed'
            $next.Runtime.ActiveCommand           = $null
            $next.Runtime.LastError               = if (($Action.PSObject.Properties.Match('ErrorText')).Count -gt 0) { [string]$Action.ErrorText } else { '' }
            return Update-BrowserDerivedState -State $next
        }
        'DescribeLoaded' {
            $change = [string]$Action.Change
            $next.Data.DescribeCache[$change] = $Action.Describe
            $next.Runtime.ActiveCommand       = $null
            return $next
        }
        'MutationCompleted' {
            $next.Runtime.ActiveCommand = $null
            $next.Runtime.LastError     = $null
            # After a resolve, flag that the next file-list enrichment (or base-load)
            # should also chain a ReloadPending to refresh changelist unresolved counts.
            $mutationKind = if (($Action.PSObject.Properties.Match('MutationKind')).Count -gt 0) { [string]$Action.MutationKind } else { '' }
            if ($mutationKind -eq 'ResolveFile') {
                $next.Data.ReloadPendingAfterEnrichment = $true
            }
            return $next
        }
        'AsyncCommandFailed' {
            $next.Runtime.ActiveCommand = $null
            $next.Runtime.LastError     = if (($Action.PSObject.Properties.Match('ErrorText')).Count -gt 0) { [string]$Action.ErrorText } else { '' }
            return $next
        }
        'CommandCancelled' {
            $next.Runtime.ActiveCommand = $null
            $next.Runtime.LastError     = $null
            return $next
        }
        'ProcessStarted' {
            if ($null -ne $next.Runtime.ActiveCommand) {
                $reqId = if (($Action.PSObject.Properties.Match('RequestId')).Count -gt 0) { [string]$Action.RequestId } else { '' }
                if ([string]$next.Runtime.ActiveCommand.RequestId -eq $reqId) {
                    $processId = if (($Action.PSObject.Properties.Match('ProcessId')).Count -gt 0) { [int]$Action.ProcessId } else { 0 }
                    $existing = if (($next.Runtime.ActiveCommand.PSObject.Properties.Match('ProcessIds')).Count -gt 0) {
                        @($next.Runtime.ActiveCommand.ProcessIds) | ForEach-Object { [int]$_ }
                    } else { @() }
                    if ($existing -notcontains $processId) {
                        $next.Runtime.ActiveCommand.ProcessIds = @($existing + @($processId))
                    }
                    $next.Runtime.ActiveCommand.CurrentProcessId = $processId
                }
            }
            return $next
        }
        'ProcessFinished' {
            if ($null -ne $next.Runtime.ActiveCommand) {
                $reqId = if (($Action.PSObject.Properties.Match('RequestId')).Count -gt 0) { [string]$Action.RequestId } else { '' }
                if ([string]$next.Runtime.ActiveCommand.RequestId -eq $reqId) {
                    $processId = if (($Action.PSObject.Properties.Match('ProcessId')).Count -gt 0) { [int]$Action.ProcessId } else { 0 }
                    $currentProcessIds = if (($next.Runtime.ActiveCommand.PSObject.Properties.Match('ProcessIds')).Count -gt 0) { @($next.Runtime.ActiveCommand.ProcessIds) } else { @() }
                    $remaining = @($currentProcessIds | Where-Object { [int]$_ -ne $processId })
                    $next.Runtime.ActiveCommand.ProcessIds = $remaining
                    $next.Runtime.ActiveCommand.CurrentProcessId = if ($remaining.Count -gt 0) { [int]$remaining[-1] } else { $null }
                }
            }
            return $next
        }
        'ShowCommandModal' {
            $next.Runtime.ModalPrompt.IsOpen = $true
            return $next
        }
        'ToggleCommandModal' {
            if (-not $next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.ModalPrompt.IsOpen = -not $next.Runtime.ModalPrompt.IsOpen
            }
            return $next
        }
        'HideCommandModal' {
            # Esc priority (M3.2): overlay → cancel-when-busy → close modal
            $overlayMode = if (($next.Ui.PSObject.Properties.Match('OverlayMode')).Count -gt 0) { [string]$next.Ui.OverlayMode } else { 'None' }
            if ($overlayMode -ne 'None') {
                $next.Ui.OverlayMode    = 'None'
                $next.Ui.OverlayPayload = $null
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.CancelRequested = $true
                return $next
            }
            $next.Runtime.ModalPrompt.IsOpen = $false
            return $next
        }
        'ToggleHelpOverlay' {
            $overlayMode = if (($next.Ui.PSObject.Properties.Match('OverlayMode')).Count -gt 0) { [string]$next.Ui.OverlayMode } else { 'None' }
            if ($overlayMode -eq 'Help') {
                $next.Ui.OverlayMode = 'None'
            } else {
                $next.Ui.OverlayMode    = 'Help'
                $next.Ui.OverlayPayload = $null
            }
            return $next
        }
        'HideHelpOverlay' {
            $next.Ui.OverlayMode    = 'None'
            $next.Ui.OverlayPayload = $null
            return $next
        }
        'OpenConfirmDialog' {
            $payloadProp = $Action.PSObject.Properties['Payload']
            $next.Ui.OverlayMode    = 'Confirm'
            $next.Ui.OverlayPayload = if ($null -ne $payloadProp) { $payloadProp.Value } else { $null }
            return $next
        }
        'AcceptDialog' {
            $acceptPayload = $next.Ui.OverlayPayload
            $next.Ui.OverlayMode    = 'None'
            $next.Ui.OverlayPayload = $null
            # If the overlay payload carries an OnAccept workflow continuation, queue it as PendingRequest
            if ($null -ne $acceptPayload) {
                $onAcceptProp = $acceptPayload.PSObject.Properties['OnAccept']
                if ($null -ne $onAcceptProp -and $null -ne $onAcceptProp.Value) {
                    # Convert the pscustomobject OnAccept payload into a hashtable so
                    # New-PendingRequest can merge identity fields cleanly (M0.6).
                    $props = @{}
                    foreach ($p in $onAcceptProp.Value.PSObject.Properties) { $props[$p.Name] = $p.Value }
                    $next.Runtime.PendingRequest = New-PendingRequest -Properties $props
                }
            }
            return $next
        }
        'CancelDialog' {
            $next.Ui.OverlayMode    = 'None'
            $next.Ui.OverlayPayload = $null
            return $next
        }
        'OpenResolveSettings' {
            # Guard: do not open over a non-menu overlay
            $currentOverlay = if (($next.Ui.PSObject.Properties.Match('OverlayMode')).Count -gt 0) { [string]$next.Ui.OverlayMode } else { 'None' }
            if ($currentOverlay -ne 'None' -and $currentOverlay -ne 'Menu') { return $next }

            $presets   = @(Get-P4MergeToolPresets)
            $menuItems = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $presets.Count; $i++) {
                $preset = $presets[$i]
                $menuItems.Add([pscustomobject]@{
                    Id          = "SelectMergeTool_$i"
                    Label       = [string]$preset.Name
                    Accelerator = [string]($i + 1)
                    IsSeparator = $false
                    IsEnabled   = $true
                })
            }
            $menuItems.Add([pscustomobject]@{ Id = '__ResolveSep1__'; Label = ''; Accelerator = ''; IsSeparator = $true; IsEnabled = $true })
            $menuItems.Add([pscustomobject]@{
                Id          = 'MergeToolManual'
                Label       = 'Enter path manually…'
                Accelerator = 'P'
                IsSeparator = $false
                IsEnabled   = $true
            })
            $next.Ui.OverlayMode    = 'Menu'
            $next.Ui.OverlayPayload = [pscustomobject]@{
                ActiveMenu = 'Select merge tool'
                FocusIndex = 0
                MenuItems  = $menuItems.ToArray()
            }
            return $next
        }
        'OpenMenu' {
            $menuNameProp = $Action.PSObject.Properties['Menu']
            $menuName     = if ($null -ne $menuNameProp) { [string]$menuNameProp.Value } else { '' }
            if ($menuName -ne 'File' -and $menuName -ne 'View') { return $next }
            # Do not open a menu if another overlay is already showing
            $currentOverlay = if (($next.Ui.PSObject.Properties.Match('OverlayMode')).Count -gt 0) { [string]$next.Ui.OverlayMode } else { 'None' }
            if ($currentOverlay -ne 'None' -and $currentOverlay -ne 'Menu') { return $next }
            $next.Ui.OverlayMode    = 'Menu'
            $next.Ui.OverlayPayload = [pscustomobject]@{
                ActiveMenu = $menuName
                FocusIndex = 0
                MenuItems  = @(Get-ComputedMenuItems -MenuName $menuName -State $next)
            }
            return $next
        }
        'MenuMoveUp' {
            if ([string]$next.Ui.OverlayMode -ne 'Menu') { return $next }
            $payload   = $next.Ui.OverlayPayload
            [object[]]$items    = @($payload.MenuItems)
            $navCount  = Get-MenuNavigableCount -ComputedItems $items
            $newFocus  = [Math]::Max(0, [int]$payload.FocusIndex - 1)
            $next.Ui.OverlayPayload = [pscustomobject]@{
                ActiveMenu = [string]$payload.ActiveMenu
                FocusIndex = $newFocus
                MenuItems  = $items
            }
            return $next
        }
        'MenuMoveDown' {
            if ([string]$next.Ui.OverlayMode -ne 'Menu') { return $next }
            $payload   = $next.Ui.OverlayPayload
            [object[]]$items    = @($payload.MenuItems)
            $navCount  = Get-MenuNavigableCount -ComputedItems $items
            $newFocus  = [Math]::Min([int]$payload.FocusIndex + 1, [Math]::Max(0, $navCount - 1))
            $next.Ui.OverlayPayload = [pscustomobject]@{
                ActiveMenu = [string]$payload.ActiveMenu
                FocusIndex = $newFocus
                MenuItems  = $items
            }
            return $next
        }
        'MenuSwitchLeft' {
            if ([string]$next.Ui.OverlayMode -ne 'Menu') { return $next }
            $current = [string]$next.Ui.OverlayPayload.ActiveMenu
            # Only switch between the two standard menus; custom overlays are not switchable.
            if ($current -ne 'File' -and $current -ne 'View') { return $next }
            $newMenu = if ($current -eq 'File') { 'View' } else { 'File' }
            $next.Ui.OverlayPayload = [pscustomobject]@{
                ActiveMenu = $newMenu
                FocusIndex = 0
                MenuItems  = @(Get-ComputedMenuItems -MenuName $newMenu -State $next)
            }
            return $next
        }
        'MenuSwitchRight' {
            # Only 2 menus; switch in either direction wraps the same way
            return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'MenuSwitchLeft' })
        }
        'MenuSelect' {
            if ([string]$next.Ui.OverlayMode -ne 'Menu') { return $next }
            $payload    = $next.Ui.OverlayPayload
            [object[]]$items     = @($payload.MenuItems)
            $item       = Get-MenuFocusedItem -ComputedItems $items -FocusIndex ([int]$payload.FocusIndex)
            # Close menu regardless
            $next.Ui.OverlayMode    = 'None'
            $next.Ui.OverlayPayload = $null
            if ($null -eq $item -or -not [bool]$item.IsEnabled) { return $next }
            # Dispatch the underlying action
            $itemId = [string]$item.Id
            switch ($itemId) {
                'DeleteChange'      { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'DeleteChange' }) }
                'DeleteShelvedFiles' { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'DeleteShelvedFiles' }) }
                'MarkAllVisible'    { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'MarkAllVisible' }) }
                'ClearMarks'        { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'ClearMarks' }) }
                'Refresh'           { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'Reload' }) }
                'Quit'              { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'Quit' }) }
                'ViewPending'       { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Pending' }) }
                'ViewSubmitted'     { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' }) }
                'ViewCommandLog'    { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' }) }
                'ToggleHideFilters' { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'ToggleHideUnavailableFilters' }) }
                'ExpandCollapse'    { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' }) }
                'Help'              { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'ToggleHelpOverlay' }) }
                'SubmitChange'      { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'SubmitChange' }) }
                'ResolveFile'       { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'ResolveFile' }) }
                'MergeTool'         { return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' }) }
                'ViewRevisionGraph' { return Invoke-FilesReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenRevisionGraph' }) }
                'MoveMarkedFiles'   {
                    [string[]]$changeIds   = @(ConvertTo-NonEmptyStringValues -InputValues $next.Query.MarkedChangeIds | Sort-Object)
                    [object[]]$visibleIds  = @($next.Derived.VisibleChangeIds)
                    $targetId = if ($visibleIds.Count -gt 0) { [string]$visibleIds[$next.Cursor.ChangeIndex] } else { '' }
                    $markedCount = $changeIds.Count
                    $payload = [pscustomobject]@{
                        Title            = "Move opened files from $markedCount marked changelist$(if ($markedCount -ne 1) { 's' }) to focused?"
                        SummaryLines     = @(
                            "Source: $markedCount changelist$(if ($markedCount -ne 1) { 's' } else { '' })"
                            "Target: changelist $targetId"
                        )
                        ConsequenceLines = @('Opened files in marked changelists will be reassigned to the focused changelist')
                        ConfirmLabel     = 'Y / Enter = confirm'
                        CancelLabel      = 'N / Esc = cancel'
                        OnAccept         = [pscustomobject]@{
                            Kind           = 'ExecuteWorkflow'
                            WorkflowKind   = 'MoveMarkedFiles'
                            ChangeIds      = $changeIds
                            TargetChangeId = $targetId
                        }
                    }
                    return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $payload })
                }
                'ShelveFiles'       {
                    [object[]]$targetChanges = @(Get-ShelveActionableChanges -State $next)
                    if ($targetChanges.Count -eq 0) {
                        return Update-BrowserDerivedState -State $next
                    }

                    [string[]]$changeIds = foreach ($change in $targetChanges) {
                        if ($null -eq $change) { continue }
                        $id = [string]$change.Id
                        if (-not [string]::IsNullOrWhiteSpace($id)) { $id }
                    }
                    $changeIds = @($changeIds | Sort-Object -Unique)
                    $mcProp = $next.Query.PSObject.Properties['MarkedChangeIds']
                    $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0
                    if ($hasMarks) {
                        $count = $changeIds.Count
                        $payload = [pscustomobject]@{
                            Title            = "Shelve files in $count selected changelist$(if ($count -ne 1) { 's' })?"
                            SummaryLines     = @(
                                "Selected: $count changelist$(if ($count -ne 1) { 's' } else { '' })"
                                ($changeIds | ForEach-Object { "  CL $_" })
                            )
                            ConsequenceLines = @('Existing shelved files in these changelists will be replaced')
                            ConfirmLabel     = 'Y / Enter = confirm'
                            CancelLabel      = 'N / Esc = cancel'
                            OnAccept         = [pscustomobject]@{
                                Kind         = 'ExecuteWorkflow'
                                WorkflowKind = 'ShelveFiles'
                                ChangeIds    = $changeIds
                            }
                        }
                    } else {
                        $currentId = [string]$changeIds[0]
                        $payload = [pscustomobject]@{
                            Title            = "Shelve files in changelist ${currentId}?"
                            SummaryLines     = @("Changelist: $currentId")
                            ConsequenceLines = @('Existing shelved files in this changelist will be replaced')
                            ConfirmLabel     = 'Y / Enter = confirm'
                            CancelLabel      = 'N / Esc = cancel'
                            OnAccept         = [pscustomobject]@{
                                Kind         = 'ExecuteWorkflow'
                                WorkflowKind = 'ShelveFiles'
                                ChangeIds    = $changeIds
                            }
                        }
                    }
                    return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $payload })
                }
                default             {
                    # Handle SelectMergeTool_N items from the ResolveSettings overlay
                    if ($itemId -match '^SelectMergeTool_(\d+)$') {
                        $presetIndex = [int]$Matches[1]
                        $presets = @(Get-P4MergeToolPresets)
                        if ($presetIndex -lt $presets.Count) {
                            $next.Runtime.PendingRequest = New-PendingRequest @{
                                Kind     = 'SetMergeTool'
                                ToolPath = [string]$presets[$presetIndex].Path
                            }
                        }
                    } elseif ($itemId -eq 'MergeToolManual') {
                        $manualPayload = [pscustomobject]@{
                            Title            = 'Configure merge tool manually'
                            SummaryLines     = @('To set a custom merge tool path, run this in a terminal:')
                            ConsequenceLines = @('  p4 set P4MERGE=<full path to merge tool executable>')
                            ConfirmLabel     = 'Enter = Close'
                            CancelLabel      = 'Esc = Close'
                            OnAccept         = $null
                        }
                        return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $manualPayload })
                    }
                }
            }
            return Update-BrowserDerivedState -State $next
        }
        'MenuAccelerator' {
            if ([string]$next.Ui.OverlayMode -ne 'Menu') { return $next }
            $keyChar = [string]$Action.Key  # already uppercase from input mapper
            $payload = $next.Ui.OverlayPayload
            [object[]]$items  = @($payload.MenuItems)
            $navIdx = 0
            $matchedNavIdx = -1
            $matchedItem   = $null
            foreach ($item in $items) {
                if (-not [bool]$item.IsSeparator) {
                    if ([string]::Equals([string]$item.Accelerator, $keyChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $matchedNavIdx = $navIdx
                        $matchedItem   = $item
                        break
                    }
                    $navIdx++
                }
            }
            if ($null -eq $matchedItem) { return $next }
            # Move focus to matched item
            $next.Ui.OverlayPayload = [pscustomobject]@{
                ActiveMenu = [string]$payload.ActiveMenu
                FocusIndex = $matchedNavIdx
                MenuItems  = $items
            }
            # If enabled, immediately select it
            if ([bool]$matchedItem.IsEnabled) {
                return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'MenuSelect' })
            }
            return $next
        }
        'WorkflowBegin' {
            $wfKind       = if (($Action.PSObject.Properties.Match('Kind')).Count -gt 0) { [string]$Action.Kind } else { '' }
            $wfTotalCount = if (($Action.PSObject.Properties.Match('TotalCount')).Count -gt 0) { [int]$Action.TotalCount } else { 0 }
            $next.Runtime.LastWorkflowResult = $null
            $next.Runtime.ActiveWorkflow = [pscustomobject]@{
                Kind        = $wfKind
                TotalCount  = $wfTotalCount
                DoneCount   = 0
                FailedCount = 0
                FailedIds   = @()
            }
            return $next
        }
        'WorkflowItemComplete' {
            if ($null -ne $next.Runtime.ActiveWorkflow) {
                $next.Runtime.ActiveWorkflow.DoneCount++
            }
            return $next
        }
        'WorkflowItemFailed' {
            if ($null -ne $next.Runtime.ActiveWorkflow) {
                $next.Runtime.ActiveWorkflow.FailedCount++
                $failedId = if (($Action.PSObject.Properties.Match('ChangeId')).Count -gt 0) { [string]$Action.ChangeId } else { '' }
                if (-not [string]::IsNullOrEmpty($failedId)) {
                    [object[]]$prevFailed = @($next.Runtime.ActiveWorkflow.FailedIds)
                    $next.Runtime.ActiveWorkflow.FailedIds = $prevFailed + @($failedId)
                }
            }
            return $next
        }
        'WorkflowEnd' {
            if ($null -ne $next.Runtime.ActiveWorkflow) {
                $wf = $next.Runtime.ActiveWorkflow
                $next.Runtime.LastWorkflowResult = [pscustomobject]@{
                    Kind        = $wf.Kind
                    DoneCount   = $wf.DoneCount
                    FailedCount = $wf.FailedCount
                    FailedIds   = $wf.FailedIds
                }
            }
            $next.Runtime.ActiveWorkflow  = $null
            $next.Runtime.CancelRequested = $false  # cancel was acted upon; reset for next workflow (M3.2)
            return $next
        }
        'ReconcileMarks' {
            if (($Action.PSObject.Properties.Match('AllChangeIds')).Count -gt 0) {
                [string[]]$allIds = @(ConvertTo-NonEmptyStringValues -InputValues $Action.AllChangeIds)
                $validSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($id in $allIds) { [void]$validSet.Add($id) }
                $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
                if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                    $staleIds = @($markedProp.Value | Where-Object { -not $validSet.Contains([string]$_) })
                    foreach ($staleId in $staleIds) { [void]$markedProp.Value.Remove($staleId) }
                }
            }
            return $next
        }
        'UnmarkChanges' {
            [string[]]$changeIds = if (($Action.PSObject.Properties.Match('ChangeIds')).Count -gt 0) {
                @(ConvertTo-NonEmptyStringValues -InputValues $Action.ChangeIds)
            } else { @() }
            foreach ($changeId in $changeIds) {
                if (-not [string]::IsNullOrWhiteSpace($changeId)) {
                    [void]$next.Query.MarkedChangeIds.Remove($changeId)
                }
            }
            return $next
        }
        'Quit' {
            # When busy: defer quit until after the active command completes (M3.2)
            if ($next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.QuitRequested = $true
            } else {
                $next.Runtime.IsRunning = $false
            }
            return $next
        }
        'SwitchPane' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Ui.ActivePane = 'Changelists'
            } else {
                $next.Ui.ActivePane = 'Filters'
            }
            return $next
        }
        'MoveUp' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                if ($next.Cursor.FilterIndex -gt 0) { $next.Cursor.FilterIndex-- }
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and $next.Cursor.CommandIndex -gt 0) {
                    $next.Cursor.CommandIndex--
                }
            } else {
                if ($next.Cursor.ChangeIndex -gt 0) { $next.Cursor.ChangeIndex-- }
            }
            return Update-BrowserCursorState -State $next
        }
        'MoveDown' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $maxFilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
                if ($next.Cursor.FilterIndex -lt $maxFilterIndex) { $next.Cursor.FilterIndex++ }
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) {
                    $maxIdx = [Math]::Max(0, $next.Derived.VisibleCommandIds.Count - 1)
                    if ($next.Cursor.CommandIndex -lt $maxIdx) { $next.Cursor.CommandIndex++ }
                }
            } else {
                $maxChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
                if ($next.Cursor.ChangeIndex -lt $maxChangeIndex) { $next.Cursor.ChangeIndex++ }
            }
            return Update-BrowserCursorState -State $next
        }
        'PageUp' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $step = Get-FilterViewportSize -CurrentState $next
                $next.Cursor.FilterIndex = [Math]::Max(0, $next.Cursor.FilterIndex - $step)
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                    $step = Get-ChangeViewportSize -CurrentState $next
                    $next.Cursor.CommandIndex = [Math]::Max(0, $next.Cursor.CommandIndex - $step)
                }
            } else {
                $step = Get-ChangeViewportSize -CurrentState $next
                $next.Cursor.ChangeIndex = [Math]::Max(0, $next.Cursor.ChangeIndex - $step)
            }
            return Update-BrowserCursorState -State $next
        }
        'PageDown' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $step = Get-FilterViewportSize -CurrentState $next
                $maxFilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
                $next.Cursor.FilterIndex = [Math]::Min($maxFilterIndex, $next.Cursor.FilterIndex + $step)
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) {
                    $step = Get-ChangeViewportSize -CurrentState $next
                    $maxIdx = [Math]::Max(0, $next.Derived.VisibleCommandIds.Count - 1)
                    $next.Cursor.CommandIndex = [Math]::Min($maxIdx, $next.Cursor.CommandIndex + $step)
                }
            } else {
                $step = Get-ChangeViewportSize -CurrentState $next
                $maxChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
                $next.Cursor.ChangeIndex = [Math]::Min($maxChangeIndex, $next.Cursor.ChangeIndex + $step)
            }
            return Update-BrowserCursorState -State $next
        }
        'MoveHome' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Cursor.FilterIndex = 0
                $next.Cursor.FilterScrollTop = 0
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                    $next.Cursor.CommandIndex     = 0
                    $next.Cursor.CommandScrollTop = 0
                }
            } else {
                $next.Cursor.ChangeIndex = 0
                $next.Cursor.ChangeScrollTop = 0
            }
            return Update-BrowserCursorState -State $next
        }
        'MoveEnd' {
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Cursor.FilterIndex = [Math]::Max(0, $next.Derived.VisibleFilters.Count - 1)
            } elseif ($currentViewMode -eq 'CommandLog') {
                if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0 -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) {
                    $next.Cursor.CommandIndex = [Math]::Max(0, $next.Derived.VisibleCommandIds.Count - 1)
                }
            } else {
                $next.Cursor.ChangeIndex = [Math]::Max(0, $next.Derived.VisibleChangeIds.Count - 1)
            }
            return Update-BrowserCursorState -State $next
        }
        'ToggleFilter' {
            $filter = $null
            $tagProp = $Action.PSObject.Properties['Filter']
            if ($null -ne $tagProp) {
                $filter = [string]$tagProp.Value
            }
            if ([string]::IsNullOrWhiteSpace($filter)) {
                if ($next.Derived.VisibleFilters.Count -eq 0) {
                    return $next
                }
                $filter = [string]$next.Derived.VisibleFilters[$next.Cursor.FilterIndex].Name
            }

            if ($next.Query.SelectedFilters.Contains($filter)) {
                [void]$next.Query.SelectedFilters.Remove($filter)
            } else {
                [void]$next.Query.SelectedFilters.Add($filter)
            }

            $next.Cursor.ChangeIndex = 0
            $next.Cursor.ChangeScrollTop = 0
            $next = Update-BrowserDerivedState -State $next

            $targetFilterIndex = -1
            for ($i = 0; $i -lt $next.Derived.VisibleFilters.Count; $i++) {
                if ($next.Derived.VisibleFilters[$i].Name -eq $filter) {
                    $targetFilterIndex = $i
                    break
                }
            }
            if ($targetFilterIndex -ge 0) {
                $next.Cursor.FilterIndex = $targetFilterIndex
            }

            return Update-BrowserDerivedState -State $next
        }
        'ToggleHideUnavailableFilters' {
            $currentFilterName = $null
            if ($next.Cursor.FilterIndex -ge 0 -and $next.Cursor.FilterIndex -lt $next.Derived.VisibleFilters.Count) {
                $currentFilterName = [string]$next.Derived.VisibleFilters[$next.Cursor.FilterIndex].Name
            }

            $next.Ui.HideUnavailableFilters = -not $next.Ui.HideUnavailableFilters
            $next.Cursor.FilterIndex = 0
            $next.Cursor.FilterScrollTop = 0
            $next = Update-BrowserDerivedState -State $next

            if (-not [string]::IsNullOrWhiteSpace($currentFilterName)) {
                for ($i = 0; $i -lt $next.Derived.VisibleFilters.Count; $i++) {
                    if ($next.Derived.VisibleFilters[$i].Name -eq $currentFilterName) {
                        $next.Cursor.FilterIndex = $i
                        break
                    }
                }
            }

            return Update-BrowserDerivedState -State $next
        }
        'ToggleChangelistView' {
            if ($currentViewMode -eq 'CommandLog') {
                # In CommandLog mode, toggle expand for the selected command
                $expandedProp = $next.Ui.PSObject.Properties['ExpandedCommands']
                if ($null -ne $expandedProp -and ($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0 -and $next.Derived.VisibleCommandIds.Count -gt 0) {
                    $idx    = [Math]::Max(0, [Math]::Min($next.Cursor.CommandIndex, $next.Derived.VisibleCommandIds.Count - 1))
                    $cmdId  = [string]$next.Derived.VisibleCommandIds[$idx]
                    $expSet = $next.Ui.ExpandedCommands
                    if ($expSet.Contains($cmdId)) {
                        [void]$expSet.Remove($cmdId)
                    } else {
                        [void]$expSet.Add($cmdId)
                    }
                }
            } else {
                $next.Ui.ExpandedChangelists = -not [bool]$next.Ui.ExpandedChangelists
            }
            return Update-BrowserDerivedState -State $next
        }
        'Describe' {
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex,
                                               $next.Derived.VisibleChangeIds.Count - 1))
            $changeId = $next.Derived.VisibleChangeIds[$idx]
            # The default CL cannot be described via p4 describe — skip the request.
            if ($changeId -eq 'default') { return $next }
            $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'FetchDescribe'; ChangeId = $changeId }
            $next.Runtime.DetailChangeId = $changeId  # persists for rendering
            return Update-BrowserDerivedState -State $next
        }
        'SubmitChange' {
            $changeId = Get-SubmitActionableChangeId -State $next
            if ($null -eq $changeId) { return $next }
            $payload = [pscustomobject]@{
                Title            = "Submit changelist ${changeId}?"
                SummaryLines     = @("Changelist: $changeId")
                ConsequenceLines = @('All opened files in this changelist will be committed to the depot')
                ConfirmLabel     = 'Y / Enter = confirm'
                CancelLabel      = 'N / Esc = cancel'
                OnAccept         = [pscustomobject]@{
                    Kind     = 'SubmitChange'
                    ChangeId = $changeId
                }
            }
            return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $payload })
        }
        'DeleteChange' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($currentViewMode -eq 'Submitted') { return $next }  # No-op in submitted view
            [string[]]$changeIds = @(Get-DeleteActionableChangeIds -State $next)
            if ($changeIds.Count -eq 0) { return $next }

            $mcProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0
            if ($hasMarks) {
                $payload = New-DeleteMarkedConfirmPayload -State $next -ChangeIds $changeIds
                return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $payload })
            }

            $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'DeleteChange'; ChangeId = $changeIds[0] }
            return Update-BrowserDerivedState -State $next
        }
        'DeleteShelvedFiles' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($currentViewMode -eq 'Submitted') { return $next }

            [object[]]$targetChanges = @(Get-DeleteShelvedActionableChanges -State $next)
            if ($targetChanges.Count -eq 0) { return Update-BrowserDerivedState -State $next }

            [string[]]$changeIds = foreach ($change in $targetChanges) {
                if ($null -eq $change) { continue }
                $id = [string]$change.Id
                if (-not [string]::IsNullOrWhiteSpace($id)) { $id }
            }
            $changeIds = @($changeIds | Sort-Object -Unique)
            $mcProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            $hasMarks = $null -ne $mcProp -and $null -ne $mcProp.Value -and $mcProp.Value.Count -gt 0
            if ($hasMarks) {
                $payload = New-DeleteShelvedConfirmPayload -State $next -ChangeIds $changeIds
                return Invoke-ChangelistReducer -State $next -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $payload })
            }

            $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'DeleteShelvedFiles'; ChangeId = $changeIds[0] }
            return Update-BrowserDerivedState -State $next
        }
        'ToggleMarkCurrent' {
            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx     = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex, $next.Derived.VisibleChangeIds.Count - 1))
            $changeId = [string]$next.Derived.VisibleChangeIds[$idx]
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $marked = $markedProp.Value
                if ($marked.Contains($changeId)) {
                    [void]$marked.Remove($changeId)
                } else {
                    [void]$marked.Add($changeId)
                }
            }
            return $next
        }
        'MarkAllVisible' {
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $marked = $markedProp.Value
                foreach ($id in $next.Derived.VisibleChangeIds) {
                    [void]$marked.Add([string]$id)
                }
            }
            return $next
        }
        'ClearMarks' {
            $markedProp = $next.Query.PSObject.Properties['MarkedChangeIds']
            if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                $next.Query.MarkedChangeIds.Clear()
            }
            return $next
        }
        'Reload' {
            $currentViewMode = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $next.Data.DescribeCache = @{}
            $next.Runtime.DetailChangeId = $null
            if ($currentViewMode -eq 'Submitted') {
                $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'ReloadSubmitted' } -Generation $next.Data.SubmittedGeneration
            } else {
                $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'ReloadPending' } -Generation $next.Data.PendingGeneration
            }
            return Update-BrowserDerivedState -State $next
        }
        'Resize' {
            $width = [int]$Action.Width
            $height = [int]$Action.Height
            if ($width -gt 10 -and $height -gt 5) {
                $next.Ui.Layout = Get-BrowserLayout -Width $width -Height $height
            }
            return Update-BrowserDerivedState -State $next
        }
        'SwitchView' {
            $targetView  = [string]$Action.View
            if ($targetView -ne 'Pending' -and $targetView -ne 'Submitted' -and $targetView -ne 'CommandLog') { return $next }

            $currentView = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            if ($targetView -eq $currentView) { return $next }

            # If on a pushed screen (Files/CommandOutput), pop back to Changelists first.
            [object[]]$currentStack = if (($next.Ui.PSObject.Properties.Match('ScreenStack')).Count -gt 0 -and $null -ne $next.Ui.ScreenStack) { @($next.Ui.ScreenStack) } else { @('Changelists') }
            if ($currentStack.Count -gt 1) {
                $next.Ui.ScreenStack = @('Changelists')
            }

            # Save current cursor snapshot
            if (($next.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $next.Cursor.ViewSnapshots) {
                if ($currentView -eq 'CommandLog') {
                    if (($next.Cursor.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                        $next.Cursor.ViewSnapshots.CommandLog = [pscustomobject]@{
                            CommandIndex     = $next.Cursor.CommandIndex
                            CommandScrollTop = $next.Cursor.CommandScrollTop
                        }
                    }
                } else {
                    $next.Cursor.ViewSnapshots.$currentView = [pscustomobject]@{
                        ChangeIndex     = $next.Cursor.ChangeIndex
                        ChangeScrollTop = $next.Cursor.ChangeScrollTop
                    }
                }
            }

            # Switch view mode
            $next.Ui.ViewMode = $targetView

            # Restore target view cursor snapshot
            if (($next.Cursor.PSObject.Properties.Match('ViewSnapshots')).Count -gt 0 -and $null -ne $next.Cursor.ViewSnapshots) {
                if ($targetView -eq 'CommandLog') {
                    $snap = $next.Cursor.ViewSnapshots.CommandLog
                    if ($null -ne $snap -and ($snap.PSObject.Properties.Match('CommandIndex')).Count -gt 0) {
                        $next.Cursor.CommandIndex     = [int]$snap.CommandIndex
                        $next.Cursor.CommandScrollTop = [int]$snap.CommandScrollTop
                    } else {
                        $next.Cursor.CommandIndex     = 0
                        $next.Cursor.CommandScrollTop = 0
                    }
                } elseif (($next.Cursor.ViewSnapshots.PSObject.Properties.Match($targetView)).Count -gt 0) {
                    $snap = $next.Cursor.ViewSnapshots.$targetView
                    $next.Cursor.ChangeIndex     = [int]$snap.ChangeIndex
                    $next.Cursor.ChangeScrollTop = [int]$snap.ChangeScrollTop
                } else {
                    $next.Cursor.ChangeIndex     = 0
                    $next.Cursor.ChangeScrollTop = 0
                }
            } else {
                $next.Cursor.ChangeIndex     = 0
                $next.Cursor.ChangeScrollTop = 0
            }

            # Reset filter cursor and selected filters (different filter sets per view)
            $next.Cursor.FilterIndex     = 0
            $next.Cursor.FilterScrollTop = 0
            $next.Query.SelectedFilters.Clear()

            # If switching to submitted for the first time (empty list), request initial load
            if ($targetView -eq 'Submitted') {
                [object[]]$submittedChanges = @()
                if (($next.Data.PSObject.Properties.Match('SubmittedChanges')).Count -gt 0 -and $null -ne $next.Data.SubmittedChanges) {
                    $submittedChanges = @($next.Data.SubmittedChanges)
                }
                $submittedHasMore = if (($next.Data.PSObject.Properties.Match('SubmittedHasMore')).Count -gt 0) { [bool]$next.Data.SubmittedHasMore } else { $true }
                if ($submittedChanges.Count -eq 0 -and $submittedHasMore) {
                    $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'LoadMore' } -Generation $next.Data.SubmittedGeneration
                }
            }

            return Update-BrowserDerivedState -State $next
        }
        'LoadMore' {
            $currentViewMode  = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $submittedHasMore = if (($next.Data.PSObject.Properties.Match('SubmittedHasMore')).Count -gt 0) { [bool]$next.Data.SubmittedHasMore } else { $false }
            if ($currentViewMode -eq 'Submitted' -and $submittedHasMore) {
                $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'LoadMore' } -Generation $next.Data.SubmittedGeneration
            }
            return $next
        }
        'LogCommandExecution' {
            # Assign next monotonic CommandId
            $cmdIdInt = if (($next.Runtime.PSObject.Properties.Match('NextCommandId')).Count -gt 0) { [int]$next.Runtime.NextCommandId } else { 1 }
            $cmdId    = [string]$cmdIdInt
            $next.Runtime.NextCommandId = $cmdIdInt + 1

            # Build metadata item (no FormattedLines — those go into CommandOutputCache)
            $startedAt  = [datetime]$Action.StartedAt
            $endedAt    = [datetime]$Action.EndedAt
            $durationMs = [int](($endedAt - $startedAt).TotalMilliseconds)
            $metaItem   = [pscustomobject]@{
                CommandId     = $cmdId
                StartedAt     = $startedAt
                EndedAt       = $endedAt
                CommandLine   = [string]$Action.CommandLine
                ExitCode      = [int]$Action.ExitCode
                Succeeded     = [bool]$Action.Succeeded
                ErrorText     = [string]$Action.ErrorText
                DurationMs    = $durationMs
                DurationClass = if (($Action.PSObject.Properties.Match('DurationClass')).Count -gt 0) { [string]$Action.DurationClass } else { 'Normal' }
                Outcome       = if (($Action.PSObject.Properties.Match('Outcome')).Count -gt 0) { [string]$Action.Outcome } else { if ([bool]$Action.Succeeded) { 'Completed' } else { 'Failed' } }
                OutputCount   = [int]$Action.OutputCount
                SummaryLine   = [string]$Action.SummaryLine
                OutputRef     = $cmdId
            }

            # Store formatted lines in CommandOutputCache (shared dictionary)
            $formattedLines = @()
            $flProp = $Action.PSObject.Properties['FormattedLines']
            if ($null -ne $flProp -and $null -ne $flProp.Value) { $formattedLines = @($flProp.Value) }
            $next.Data.CommandOutputCache[$cmdId] = $formattedLines

            # Prepend metadata to CommandLog (newest first) and trim if over limit
            $newLog = @($metaItem) + @($next.Runtime.CommandLog)
            if ($newLog.Count -gt $script:CommandLogMaxSize) {
                $evicted = $newLog[$script:CommandLogMaxSize..($newLog.Count - 1)]
                foreach ($e in $evicted) {
                    $evKey = [string]$e.OutputRef
                    if (-not [string]::IsNullOrEmpty($evKey) -and $next.Data.CommandOutputCache.ContainsKey($evKey)) {
                        $next.Data.CommandOutputCache.Remove($evKey) | Out-Null
                    }
                }
                $newLog = $newLog[0..($script:CommandLogMaxSize - 1)]
            }
            $next.Runtime.CommandLog = $newLog

            return Update-BrowserDerivedState -State $next
        }
        'OpenFilesScreen' {
            # In CommandLog mode, open the CommandOutput screen for the selected command.
            if ($currentViewMode -eq 'CommandLog') {
                if (($next.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0 -and $next.Derived.VisibleCommandIds.Count -gt 0) {
                    $idx   = [Math]::Max(0, [Math]::Min($next.Cursor.CommandIndex, $next.Derived.VisibleCommandIds.Count - 1))
                    $cmdId = [string]$next.Derived.VisibleCommandIds[$idx]
                    [object[]]$currentStack = if (($next.Ui.PSObject.Properties.Match('ScreenStack')).Count -gt 0 -and $null -ne $next.Ui.ScreenStack) { @($next.Ui.ScreenStack) } else { @('Changelists') }
                    $next.Ui.ScreenStack = $currentStack + @('CommandOutput')
                    $next.Runtime.CommandOutputCommandId = $cmdId
                    $next.Cursor.OutputIndex     = 0
                    $next.Cursor.OutputScrollTop = 0
                }
                return Update-BrowserDerivedState -State $next
            }

            if ($next.Derived.VisibleChangeIds.Count -eq 0) { return $next }
            $idx         = [Math]::Max(0, [Math]::Min($next.Cursor.ChangeIndex, $next.Derived.VisibleChangeIds.Count - 1))
            $changeIdStr = $next.Derived.VisibleChangeIds[$idx]
            $change      = ConvertTo-P4ChangelistId -Value ([string]$changeIdStr)
            $viewMode    = if (($next.Ui.PSObject.Properties.Match('ViewMode')).Count -gt 0) { [string]$next.Ui.ViewMode } else { 'Pending' }
            $sourceKind  = if ($viewMode -eq 'Submitted') { 'Submitted' } else { 'Opened' }

            # Push Files onto the screen stack.
            # Use [object[]] to prevent PowerShell from scalar-izing a 1-element if-expression result.
            [object[]]$currentStack = if (($next.Ui.PSObject.Properties.Match('ScreenStack')).Count -gt 0 -and $null -ne $next.Ui.ScreenStack) { @($next.Ui.ScreenStack) } else { @('Changelists') }
            $next.Ui.ScreenStack    = $currentStack + @('Files')

            # Record which CL and source kind to load (I/O side effect in Step 2).
            $next.Data.FilesSourceChange = $change
            $next.Data.FilesSourceKind   = $sourceKind

            # Clear stale file filter state and reset file cursor.
            $next.Query.FileFilterText   = ''
            $next.Query.FileFilterTokens = @()
            $next.Cursor.FileIndex       = 0
            $next.Cursor.FileScrollTop   = 0

            # Signal main loop to trigger the I/O side effect (implemented in Step 2).
            $cacheKey = "${change}:${sourceKind}"
            $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'LoadFiles'; CacheKey = $cacheKey } -Generation $next.Data.FilesGeneration

            return Update-BrowserDerivedState -State $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function Invoke-FilesReducer {
    <#
    .SYNOPSIS
        Reducer for the Files screen.  Handles files-screen-specific actions
        (navigation, CloseFilesScreen, SetFileFilter, Reload) and delegates
        cross-screen lifecycle actions (Quit, Resize, modal lifecycle) to
        Invoke-ChangelistReducer so the logic is not duplicated.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    # Delegate actions whose logic is identical on every screen.
    if (Test-IsBrowserGlobalAction -ActionType ([string]$Action.Type)) {
        return Invoke-ChangelistReducer -State $State -Action $Action
    }

    $next = Copy-BrowserState -State $State

    switch ($Action.Type) {
        'HideCommandModal' {
            # Esc priority (M3.2): overlay → cancel-when-busy → close modal → close files screen.
            $overlayMode = if (($next.Ui.PSObject.Properties.Match('OverlayMode')).Count -gt 0) { [string]$next.Ui.OverlayMode } else { 'None' }
            if ($overlayMode -ne 'None') {
                $next.Ui.OverlayMode    = 'None'
                $next.Ui.OverlayPayload = $null
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.CancelRequested = $true
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsOpen) {
                $next.Runtime.ModalPrompt.IsOpen = $false
                return $next
            }
            # Fall through: Esc with no overlay open → close the files screen.
            $stack = [System.Collections.Generic.List[string]]::new()
            foreach ($s in @($next.Ui.ScreenStack)) { $stack.Add([string]$s) }
            if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
            $next.Ui.ScreenStack = $stack.ToArray()
            return Update-BrowserDerivedState -State $next
        }
        'CloseFilesScreen' {
            $stack = [System.Collections.Generic.List[string]]::new()
            foreach ($s in @($next.Ui.ScreenStack)) { $stack.Add([string]$s) }
            if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
            $next.Ui.ScreenStack = $stack.ToArray()
            return Update-BrowserDerivedState -State $next
        }
        'SwitchPane' {
            # Cycle between left (filter) and right (list) panes on the files screen.
            # Re-use 'Filters'/'Changelists' as stand-in values until the render layer
            # assigns file-specific pane names in a later step.
            if ($next.Ui.ActivePane -eq 'Filters') {
                $next.Ui.ActivePane = 'Changelists'
            } else {
                $next.Ui.ActivePane = 'Filters'
            }
            return $next
        }
        'MoveUp' {
            if ($next.Cursor.FileIndex -gt 0) { $next.Cursor.FileIndex-- }
            return Update-BrowserCursorState -State $next
        }
        'MoveDown' {
            $maxIdx = [Math]::Max(0, $next.Derived.VisibleFileIndices.Count - 1)
            if ($next.Cursor.FileIndex -lt $maxIdx) { $next.Cursor.FileIndex++ }
            return Update-BrowserCursorState -State $next
        }
        'PageUp' {
            $step = if ($null -ne $next.Ui.Layout -and $next.Ui.Layout.Mode -eq 'Normal') {
                [Math]::Max(1, $next.Ui.Layout.ListPane.H - 2)
            } else { 10 }
            $next.Cursor.FileIndex = [Math]::Max(0, $next.Cursor.FileIndex - $step)
            return Update-BrowserCursorState -State $next
        }
        'PageDown' {
            $step   = if ($null -ne $next.Ui.Layout -and $next.Ui.Layout.Mode -eq 'Normal') {
                [Math]::Max(1, $next.Ui.Layout.ListPane.H - 2)
            } else { 10 }
            $maxIdx = [Math]::Max(0, $next.Derived.VisibleFileIndices.Count - 1)
            $next.Cursor.FileIndex = [Math]::Min($maxIdx, $next.Cursor.FileIndex + $step)
            return Update-BrowserCursorState -State $next
        }
        'MoveHome' {
            $next.Cursor.FileIndex     = 0
            $next.Cursor.FileScrollTop = 0
            return Update-BrowserCursorState -State $next
        }
        'MoveEnd' {
            $next.Cursor.FileIndex = [Math]::Max(0, $next.Derived.VisibleFileIndices.Count - 1)
            return Update-BrowserCursorState -State $next
        }
        'SetFileFilter' {
            # Stub — full parsing and filtering implemented in Step 4.
            $textProp = $Action.PSObject.Properties['FilterText']
            $text     = if ($null -ne $textProp) { [string]$textProp.Value } else { '' }
            $next.Query.FileFilterText   = $text
            $next.Query.FileFilterTokens = @()  # Step 4 will parse this
            $next.Cursor.FileIndex       = 0
            $next.Cursor.FileScrollTop   = 0
            return Update-BrowserDerivedState -State $next
        }
        'OpenFilterPrompt' {
            # Stub — full implementation in Step 4.
            return $next
        }
        'Reload' {
            # Evict the cache entry for the current file source so a fresh load is triggered.
            $cacheKey = "$($next.Data.FilesSourceChange)`:$($next.Data.FilesSourceKind)"
            $fileCache = $next.Data.PSObject.Properties['FileCache']?.Value
            if ($null -ne $fileCache -and $fileCache.ContainsKey($cacheKey)) {
                $fileCache.Remove($cacheKey) | Out-Null
            }
            # Also clear the enrichment-status so the reload starts fresh (M2.2).
            $fileCacheStatus = $next.Data.PSObject.Properties['FileCacheStatus']?.Value
            if ($null -ne $fileCacheStatus -and $fileCacheStatus.ContainsKey($cacheKey)) {
                $fileCacheStatus.Remove($cacheKey) | Out-Null
            }
            $reloadCacheKey = "$($next.Data.FilesSourceChange)`:$($next.Data.FilesSourceKind)"
            $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'LoadFiles'; CacheKey = $reloadCacheKey } -Generation $next.Data.FilesGeneration
            return Update-BrowserDerivedState -State $next
        }
        'ResolveFile' {
            # Validate: file must be focused, loaded, and unresolved.
            $cacheKey         = "$($next.Data.FilesSourceChange)`:$($next.Data.FilesSourceKind)"
            $fileCache        = $next.Data.PSObject.Properties['FileCache']?.Value
            $fileIndex        = if (($next.Cursor.PSObject.Properties.Match('FileIndex')).Count -gt 0) { [int]$next.Cursor.FileIndex } else { 0 }
            [object[]]$visIdx = @($next.Derived.VisibleFileIndices)

            if ($null -eq $fileCache -or -not $fileCache.ContainsKey($cacheKey) -or $visIdx.Count -eq 0) {
                $next.Runtime.LastError = 'No files loaded.'
                return $next
            }

            [object[]]$files = @($fileCache[$cacheKey])
            $rawIdx  = if ($fileIndex -lt $visIdx.Count) { [int]$visIdx[$fileIndex] } else { -1 }
            if ($rawIdx -lt 0 -or $rawIdx -ge $files.Count) {
                $next.Runtime.LastError = 'No file selected.'
                return $next
            }
            $fileEntry = $files[$rawIdx]

            if (-not [bool]$fileEntry.IsUnresolved) {
                $next.Runtime.LastError = 'File is not unresolved. Use Shift+R to configure the merge tool.'
                return $next
            }

            $depotPath = [string]$fileEntry.DepotPath
            $change    = [string]$next.Data.FilesSourceChange
            $next.Runtime.LastError    = $null
            $next.Runtime.PendingRequest = New-PendingRequest @{ Kind = 'ResolveFile'; DepotPath = $depotPath; Change = $change } -Generation 0
            return $next
        }
        'OpenRevisionGraph' {
            # Get the focused file's depot path and delegate to the graph reducer.
            $cacheKey = "$($next.Data.FilesSourceChange)`:$($next.Data.FilesSourceKind)"
            $fileCache = $next.Data.PSObject.Properties['FileCache']?.Value
            [object[]]$visIdx = @($next.Derived.VisibleFileIndices)
            $fileIndex = if (($next.Cursor.PSObject.Properties.Match('FileIndex')).Count -gt 0) { [int]$next.Cursor.FileIndex } else { 0 }

            if ($null -ne $fileCache -and $fileCache.ContainsKey($cacheKey) -and $visIdx.Count -gt 0) {
                [object[]]$files = @($fileCache[$cacheKey])
                $rawIdx = if ($fileIndex -lt $visIdx.Count) { [int]$visIdx[$fileIndex] } else { -1 }
                if ($rawIdx -ge 0 -and $rawIdx -lt $files.Count) {
                    $depotPath = [string]$files[$rawIdx].DepotPath
                    if (-not [string]::IsNullOrWhiteSpace($depotPath)) {
                        return Invoke-GraphReducer -State $next -Action ([pscustomobject]@{
                            Type      = 'OpenRevisionGraph'
                            DepotFile = $depotPath
                        })
                    }
                }
            }
            $next.Runtime.LastError = 'No file selected for revision graph.'
            return $next
        }
        'OpenFilesScreen' {
            # No-op: already on Files screen; cannot nest.
            return $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function Invoke-CommandOutputReducer {
    <#
    .SYNOPSIS
        Reducer for the CommandOutput screen. Handles scrolling through formatted
        p4 command output and Escape/left-arrow to pop the screen.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    # Delegate global lifecycle actions to ChangelistReducer
    if (Test-IsBrowserGlobalAction -ActionType ([string]$Action.Type)) {
        return Invoke-ChangelistReducer -State $State -Action $Action
    }

    $next = Copy-BrowserState -State $State

    $closeScreen = {
        param($s)
        $stack = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($s.Ui.ScreenStack)) { $stack.Add([string]$item) }
        if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
        $s.Ui.ScreenStack = $stack.ToArray()
        return Update-BrowserDerivedState -State $s
    }

    switch ($Action.Type) {
        'HideCommandModal' {
            # Esc priority (M3.2): overlay → cancel-when-busy → close modal → close screen.
            $overlayMode = if (($next.Ui.PSObject.Properties.Match('OverlayMode')).Count -gt 0) { [string]$next.Ui.OverlayMode } else { 'None' }
            if ($overlayMode -ne 'None') {
                $next.Ui.OverlayMode    = 'None'
                $next.Ui.OverlayPayload = $null
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.CancelRequested = $true
                return $next
            }
            if ($next.Runtime.ModalPrompt.IsOpen) {
                $next.Runtime.ModalPrompt.IsOpen = $false
                return $next
            }
            return & $closeScreen $next
        }
        'CloseFilesScreen' {
            return & $closeScreen $next
        }
        'MoveUp' {
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0 -and $next.Cursor.OutputIndex -gt 0) {
                $next.Cursor.OutputIndex--
            }
            return Update-OutputDerivedState -State $next
        }
        'MoveDown' {
            $outputCount = Get-CommandOutputCount -State $next
            $maxIdx = [Math]::Max(0, $outputCount - 1)
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0 -and $next.Cursor.OutputIndex -lt $maxIdx) {
                $next.Cursor.OutputIndex++
            }
            return Update-OutputDerivedState -State $next
        }
        'PageUp' {
            $step = Get-OutputViewportSize -State $next
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex = [Math]::Max(0, $next.Cursor.OutputIndex - $step)
            }
            return Update-OutputDerivedState -State $next
        }
        'PageDown' {
            $step        = Get-OutputViewportSize -State $next
            $outputCount = Get-CommandOutputCount -State $next
            $maxIdx      = [Math]::Max(0, $outputCount - 1)
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex = [Math]::Min($maxIdx, $next.Cursor.OutputIndex + $step)
            }
            return Update-OutputDerivedState -State $next
        }
        'MoveHome' {
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex     = 0
                $next.Cursor.OutputScrollTop = 0
            }
            return Update-OutputDerivedState -State $next
        }
        'MoveEnd' {
            $outputCount = Get-CommandOutputCount -State $next
            if (($next.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) {
                $next.Cursor.OutputIndex = [Math]::Max(0, $outputCount - 1)
            }
            return Update-OutputDerivedState -State $next
        }
        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

function Invoke-BrowserReducer {
    <#
    .SYNOPSIS
        Top-level reducer router.  Dispatches to Invoke-ChangelistReducer,
        Invoke-FilesReducer, or Invoke-CommandOutputReducer based on the
        active screen in Ui.ScreenStack.  When an overlay is active, all
        input is routed through Invoke-ChangelistReducer so overlay actions
        are handled regardless of the active screen.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Action
    )

    # Overlay-first routing: when an overlay is active route everything through
    # the changelist reducer (which handles all overlay actions as global actions).
    $overlayMode = $State.Ui.PSObject.Properties['OverlayMode']?.Value
    if ($null -ne $overlayMode -and [string]$overlayMode -ne 'None') {
        return Invoke-ChangelistReducer -State $State -Action $Action
    }

    # Use PSObject.Properties index accessor — returns $null when property absent (safe for legacy test states).
    $screenStack  = $State.Ui.PSObject.Properties['ScreenStack']?.Value
    $activeScreen = if ($null -ne $screenStack -and $screenStack.Count -gt 0) { $screenStack[-1] } else { 'Changelists' }

    # Graph completion actions always route to the graph reducer regardless of screen
    if ($Action.Type -in @('RevisionLogLoaded', 'RevisionLogFailed')) {
        return Invoke-GraphReducer -State $State -Action $Action
    }

    if ($activeScreen -eq 'Files') {
        return Invoke-FilesReducer -State $State -Action $Action
    }
    if ($activeScreen -eq 'RevisionGraph') {
        return Invoke-GraphReducer -State $State -Action $Action
    }
    if ($activeScreen -eq 'CommandOutput') {
        return Invoke-CommandOutputReducer -State $State -Action $Action
    }
    return Invoke-ChangelistReducer -State $State -Action $Action
}

function ConvertTo-ChangeNumberFromId {
    param([string]$Id)
    return ConvertTo-P4ChangelistId -Value $Id
}

Export-ModuleMember -Function New-BrowserState, Copy-BrowserState, Copy-StateObject, `
    Invoke-BrowserReducer, Invoke-ChangelistReducer, Invoke-FilesReducer, Invoke-CommandOutputReducer, Invoke-GraphReducer, `
    Update-BrowserDerivedState, Update-CommandLogDerivedState, Update-OutputDerivedState, `
    Test-IsBrowserGlobalAction, `
    New-PendingRequest, `
    ConvertTo-ChangeNumberFromId, `
    Get-ChangeInnerViewRows, Get-ChangeRowsPerItem, Get-ChangeViewCapacity, `
    Get-CommandOutputCount, Get-OutputViewportSize, `
    Get-ComputedMenuItems, Get-MenuFocusedItem, Get-MenuNavigableCount
