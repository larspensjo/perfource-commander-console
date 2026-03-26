Set-StrictMode -Version Latest

# Maximum revisions fetched on the first load of a lane.
$script:InitialRevisionLimit = 30
# Revisions fetched per 'load more' page.
$script:RevisionPageSize = 30

function New-RevisionGraphState {
    param([Parameter(Mandatory)][string]$InitialDepotFile)
    [pscustomobject]@{
        Lanes            = @()
        PrimaryLaneIndex = 0
        InitialDepotFile = $InitialDepotFile
    }
}

function New-GraphLane {
    param(
        [Parameter(Mandatory)][int]$LaneIndex,
        [Parameter(Mandatory)][string]$DepotFile
    )
    [pscustomobject]@{
        LaneIndex  = $LaneIndex
        DepotFile  = $DepotFile
        Revisions  = @()
        IsLoading  = $true
        HasMore    = $false
        Generation = 0
    }
}

function New-GraphRow {
    param(
        [Parameter(Mandatory)][string]$RowType,
        [Parameter(Mandatory)][int]$LaneIndex,
        [AllowNull()]$RevisionNode  = $null,
        [AllowNull()]$Integration   = $null,
        [AllowNull()]$ParentNode    = $null,
        [bool]$IsNavigable          = $false,
        [int]$SortKey               = 0
    )
    [pscustomobject]@{
        RowType      = $RowType
        LaneIndex    = $LaneIndex
        RevisionNode = $RevisionNode
        Integration  = $Integration
        ParentNode   = $ParentNode
        IsNavigable  = $IsNavigable
        SortKey      = $SortKey
    }
}

function Get-GraphViewportSize {
    param([Parameter(Mandatory)]$State)
    $detailLines = 5
    $headerLines = 2
    $statusLines = 1
    $layoutProp = $State.Ui.PSObject.Properties['Layout']
    if ($null -ne $layoutProp -and $null -ne $layoutProp.Value -and
        [string]$layoutProp.Value.Mode -eq 'Normal') {
        return [Math]::Max(1, [int]$layoutProp.Value.Height - $detailLines - $headerLines - $statusLines)
    }
    return 10
}

function Update-GraphCursorState {
    param([Parameter(Mandatory)]$State)

    $rowsProp = $State.Derived.PSObject.Properties['GraphRows']
    $rows = @()
    if ($null -ne $rowsProp -and $null -ne $rowsProp.Value) { $rows = @($rowsProp.Value) }
    $rowCount = $rows.Count

    $idxProp = $State.Cursor.PSObject.Properties['GraphRowIndex']
    $topProp = $State.Cursor.PSObject.Properties['GraphScrollTop']
    if ($null -eq $idxProp -or $null -eq $topProp) { return $State }

    if ($rowCount -eq 0) {
        $State.Cursor.GraphRowIndex  = 0
        $State.Cursor.GraphScrollTop = 0
        return $State
    }

    # Clamp index
    if ($State.Cursor.GraphRowIndex -lt 0)             { $State.Cursor.GraphRowIndex = 0 }
    if ($State.Cursor.GraphRowIndex -ge $rowCount)     { $State.Cursor.GraphRowIndex = $rowCount - 1 }

    # Snap to nearest navigable row (search upward first, then downward)
    if (-not [bool]$rows[$State.Cursor.GraphRowIndex].IsNavigable) {
        $found = $false
        for ($j = $State.Cursor.GraphRowIndex; $j -ge 0; $j--) {
            if ([bool]$rows[$j].IsNavigable) { $State.Cursor.GraphRowIndex = $j; $found = $true; break }
        }
        if (-not $found) {
            for ($j = $State.Cursor.GraphRowIndex; $j -lt $rowCount; $j++) {
                if ([bool]$rows[$j].IsNavigable) { $State.Cursor.GraphRowIndex = $j; break }
            }
        }
    }

    # Clamp scroll
    $viewport  = Get-GraphViewportSize -State $State
    $maxScroll = [Math]::Max(0, $rowCount - $viewport)
    if ($State.Cursor.GraphScrollTop -lt 0)            { $State.Cursor.GraphScrollTop = 0 }
    if ($State.Cursor.GraphScrollTop -gt $maxScroll)   { $State.Cursor.GraphScrollTop = $maxScroll }

    # Ensure cursor is visible
    if ($State.Cursor.GraphRowIndex -lt $State.Cursor.GraphScrollTop) {
        $State.Cursor.GraphScrollTop = $State.Cursor.GraphRowIndex
    }
    if ($State.Cursor.GraphRowIndex -ge ($State.Cursor.GraphScrollTop + $viewport)) {
        $State.Cursor.GraphScrollTop = [Math]::Max(0, $State.Cursor.GraphRowIndex - $viewport + 1)
    }

    return $State
}

function Update-GraphDerivedState {
    param([Parameter(Mandatory)]$State)

    $graphProp = $State.Data.PSObject.Properties['RevisionGraph']
    if ($null -eq $graphProp -or $null -eq $graphProp.Value) {
        $State.Derived.GraphRows = @()
        return Update-GraphCursorState -State $State
    }

    $graphState = $graphProp.Value
    $lanes = @($graphState.Lanes)

    if ($lanes.Count -eq 0) {
        $State.Derived.GraphRows = @()
        return Update-GraphCursorState -State $State
    }

    # Collect all revision nodes from all lanes tagged with LaneIndex
    $nodeList = [System.Collections.Generic.List[object]]::new()
    foreach ($lane in $lanes) {
        $laneRevs = @($lane.Revisions)
        $laneIdx  = [int]$lane.LaneIndex
        foreach ($rev in $laneRevs) {
            $nodeList.Add([pscustomobject]@{ Node = $rev; LaneIndex = $laneIdx }) | Out-Null
        }
    }

    # Sort ascending by Change (oldest first → top of display)
    $sorted = @($nodeList.ToArray() | Sort-Object { [int]$_.Node.Change })

    # Build flat rows: for each node emit Node row + Integration rows, then a Spine row
    $rows = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $item    = $sorted[$i]
        $node    = $item.Node
        $laneIdx = [int]$item.LaneIndex
        $change  = [int]$node.Change

        # Node row
        $rows.Add((New-GraphRow -RowType 'Node' -LaneIndex $laneIdx `
            -RevisionNode $node -IsNavigable $true -SortKey $change)) | Out-Null

        # Integration rows — one per integration record
        foreach ($integ in @($node.Integrations)) {
            $rows.Add((New-GraphRow -RowType 'Integration' -LaneIndex $laneIdx `
                -Integration $integ -ParentNode $node -IsNavigable $true -SortKey $change)) | Out-Null
        }

        # Spine row between this node and the next (not after the last one)
        if ($i -lt ($sorted.Count - 1)) {
            $rows.Add((New-GraphRow -RowType 'Spine' -LaneIndex $laneIdx `
                -IsNavigable $false -SortKey $change)) | Out-Null
        }
    }

    $State.Derived.GraphRows = @($rows.ToArray())
    return Update-GraphCursorState -State $State
}

function Get-FocusedGraphNode {
    <#
    .SYNOPSIS
        Returns the RevisionNode for the currently focused graph row.
        For Node rows, returns the revision directly.
        For Integration rows, returns the parent RevisionNode.
        Returns $null when no navigable row is focused.
    #>
    param([Parameter(Mandatory)]$State)

    $rowsProp = $State.Derived.PSObject.Properties['GraphRows']
    if ($null -eq $rowsProp -or $null -eq $rowsProp.Value) { return $null }
    $rows = @($rowsProp.Value)
    if ($rows.Count -eq 0) { return $null }

    $idxProp = $State.Cursor.PSObject.Properties['GraphRowIndex']
    $idx = if ($null -ne $idxProp) { [int]$idxProp.Value } else { 0 }
    if ($idx -lt 0 -or $idx -ge $rows.Count) { return $null }

    $row = $rows[$idx]
    switch ([string]$row.RowType) {
        'Node'        { return $row.RevisionNode }
        'Integration' { return $row.ParentNode   }
        default       { return $null }
    }
}

function Invoke-GraphReducer {
    <#
    .SYNOPSIS
        Reducer for the RevisionGraph screen and graph-scoped async completions.
    .DESCRIPTION
        Handles: OpenRevisionGraph, RevisionLogLoaded, RevisionLogFailed,
        GraphNavigate (including MoveUp/Down/PageUp/Down/MoveHome/End),
        and HideCommandModal (Escape) to pop the screen.
        Delegates global lifecycle actions to Invoke-ChangelistReducer.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Action
    )

    # Delegate global lifecycle actions (PendingChangesLoaded, CommandFinish, etc.)
    if (Test-IsBrowserGlobalAction -ActionType ([string]$Action.Type)) {
        return Invoke-ChangelistReducer -State $State -Action $Action
    }

    $next = Copy-BrowserState -State $State

    switch ($Action.Type) {

        'OpenRevisionGraph' {
            $depotFile = [string]$Action.DepotFile
            if ([string]::IsNullOrWhiteSpace($depotFile)) { return $next }

            # Increment generation to invalidate any in-flight load
            $genProp = $next.Data.PSObject.Properties['GraphGeneration']
            $nextGen = if ($null -ne $genProp) { [int]$genProp.Value + 1 } else { 1 }
            $next.Data.GraphGeneration = $nextGen

            # Create initial graph state with one loading lane
            $lane       = New-GraphLane -LaneIndex 0 -DepotFile $depotFile
            $graphState = New-RevisionGraphState -InitialDepotFile $depotFile
            $graphState.Lanes = @($lane)
            $next.Data.RevisionGraph = $graphState

            # Push RevisionGraph onto the screen stack
            $next.Ui.ScreenStack = @($next.Ui.ScreenStack) + @('RevisionGraph')

            # Reset graph cursor
            $next.Cursor.GraphRowIndex  = 0
            $next.Cursor.GraphScrollTop = 0
            $next.Derived.GraphRows     = @()

            # Trigger async filelog load
            $next.Runtime.PendingRequest = New-PendingRequest @{
                Kind      = 'LoadFileLog'
                DepotFile = $depotFile
                LaneIndex = 0
            } -Generation $nextGen

            return $next
        }

        'RevisionLogLoaded' {
            $generation = [int]$Action.Generation
            $genProp    = $next.Data.PSObject.Properties['GraphGeneration']
            $graphGen   = if ($null -ne $genProp) { [int]$genProp.Value } else { 0 }

            # Stale-guard: discard completions from superseded loads
            if ($generation -lt $graphGen) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }

            $graphProp = $next.Data.PSObject.Properties['RevisionGraph']
            if ($null -eq $graphProp -or $null -eq $graphProp.Value) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }

            $laneIndex = [int]$Action.LaneIndex
            $lanes     = @($graphProp.Value.Lanes)
            if ($laneIndex -ge $lanes.Count) {
                $next.Runtime.ActiveCommand = $null
                return $next
            }

            $lanes[$laneIndex].Revisions = @($Action.Revisions)
            $lanes[$laneIndex].IsLoading = $false
            $lanes[$laneIndex].HasMore   = [bool]$Action.HasMore

            $next.Runtime.ActiveCommand = $null
            $next.Runtime.LastError     = $null

            # Initialise cursor on the newest revision (last navigable row)
            $wasEmpty = ($next.Derived.PSObject.Properties['GraphRows']?.Value).Count -eq 0
            $next = Update-GraphDerivedState -State $next

            if ($wasEmpty) {
                # Place cursor on the newest (last) navigable row
                $rows = @($next.Derived.GraphRows)
                for ($j = $rows.Count - 1; $j -ge 0; $j--) {
                    if ([bool]$rows[$j].IsNavigable) {
                        $next.Cursor.GraphRowIndex = $j
                        break
                    }
                }
                $next = Update-GraphCursorState -State $next
            }

            return $next
        }

        'RevisionLogFailed' {
            $next.Runtime.ActiveCommand = $null
            $errorProp = $Action.PSObject.Properties['Error']
            if ($null -ne $errorProp) { $next.Runtime.LastError = [string]$errorProp.Value }

            # Mark lane as no longer loading
            $graphProp = $next.Data.PSObject.Properties['RevisionGraph']
            if ($null -ne $graphProp -and $null -ne $graphProp.Value) {
                $laneIdxProp = $Action.PSObject.Properties['LaneIndex']
                $laneIndex   = if ($null -ne $laneIdxProp) { [int]$laneIdxProp.Value } else { 0 }
                $lanes       = @($graphProp.Value.Lanes)
                if ($laneIndex -lt $lanes.Count) {
                    $lanes[$laneIndex].IsLoading = $false
                }
            }

            return $next
        }

        # ── Navigation ────────────────────────────────────────────────────────

        { $_ -in @('MoveUp', 'GraphNavigate') -and
          ($Action.Type -eq 'MoveUp' -or [string]$Action.Direction -eq 'Up') } {
            $rows = @($next.Derived.PSObject.Properties['GraphRows']?.Value)
            $cur  = [int]$next.Cursor.GraphRowIndex
            for ($j = $cur - 1; $j -ge 0; $j--) {
                if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; break }
            }
            return Update-GraphCursorState -State $next
        }

        { $_ -in @('MoveDown', 'GraphNavigate') -and
          ($Action.Type -eq 'MoveDown' -or [string]$Action.Direction -eq 'Down') } {
            $rows = @($next.Derived.PSObject.Properties['GraphRows']?.Value)
            $cur  = [int]$next.Cursor.GraphRowIndex
            for ($j = $cur + 1; $j -lt $rows.Count; $j++) {
                if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; break }
            }
            return Update-GraphCursorState -State $next
        }

        'PageUp' {
            $rows     = @($next.Derived.PSObject.Properties['GraphRows']?.Value)
            $cur      = [int]$next.Cursor.GraphRowIndex
            $viewport = Get-GraphViewportSize -State $next
            $target   = [Math]::Max(0, $cur - $viewport)
            $found    = $false
            for ($j = $target; $j -ge 0; $j--) {
                if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; $found = $true; break }
            }
            if (-not $found -and $rows.Count -gt 0) {
                for ($j = 0; $j -lt $rows.Count; $j++) {
                    if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; break }
                }
            }
            return Update-GraphCursorState -State $next
        }

        'PageDown' {
            $rows     = @($next.Derived.PSObject.Properties['GraphRows']?.Value)
            $cur      = [int]$next.Cursor.GraphRowIndex
            $viewport = Get-GraphViewportSize -State $next
            $target   = [Math]::Min($rows.Count - 1, $cur + $viewport)
            $found    = $false
            for ($j = $target; $j -lt $rows.Count; $j++) {
                if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; $found = $true; break }
            }
            if (-not $found -and $rows.Count -gt 0) {
                for ($j = $rows.Count - 1; $j -ge 0; $j--) {
                    if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; break }
                }
            }
            return Update-GraphCursorState -State $next
        }

        'MoveHome' {
            $rows = @($next.Derived.PSObject.Properties['GraphRows']?.Value)
            for ($j = 0; $j -lt $rows.Count; $j++) {
                if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; break }
            }
            return Update-GraphCursorState -State $next
        }

        'MoveEnd' {
            $rows = @($next.Derived.PSObject.Properties['GraphRows']?.Value)
            for ($j = $rows.Count - 1; $j -ge 0; $j--) {
                if ([bool]$rows[$j].IsNavigable) { $next.Cursor.GraphRowIndex = $j; break }
            }
            return Update-GraphCursorState -State $next
        }

        # ── Screen management ─────────────────────────────────────────────────

        'HideCommandModal' {
            # Priority: overlay → cancel busy command → close modal → pop screen
            $overlayMode = [string]($next.Ui.PSObject.Properties['OverlayMode']?.Value)
            if ($overlayMode -ne 'None' -and -not [string]::IsNullOrEmpty($overlayMode)) {
                $next.Ui.OverlayMode    = 'None'
                $next.Ui.OverlayPayload = $null
                return $next
            }
            if ([bool]$next.Runtime.ModalPrompt.IsBusy) {
                $next.Runtime.CancelRequested = $true
                return $next
            }
            if ([bool]$next.Runtime.ModalPrompt.IsOpen) {
                $next.Runtime.ModalPrompt.IsOpen = $false
                return $next
            }
            # Pop RevisionGraph screen
            $stack = [System.Collections.Generic.List[string]]::new()
            foreach ($item in @($next.Ui.ScreenStack)) { $stack.Add([string]$item) }
            if ($stack.Count -gt 1) { $stack.RemoveAt($stack.Count - 1) }
            $next.Ui.ScreenStack = $stack.ToArray()
            return $next
        }

        default {
            return Update-BrowserDerivedState -State $next
        }
    }
}

Export-ModuleMember -Function Invoke-GraphReducer, Update-GraphDerivedState, Update-GraphCursorState, `
    Get-GraphViewportSize, Get-FocusedGraphNode, New-RevisionGraphState, New-GraphLane, New-GraphRow
