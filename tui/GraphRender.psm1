Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Theme.psm1') -Force

# Graph-specific glyphs (matches the visual design in Plan.RevisionGraph.md)
$GRAPH_NODE_GLYPH    = [char]0x25CF   # ●  revision node
$GRAPH_FOCUSED_GLYPH = [char]0x25C6   # ◆  focused revision node
$GRAPH_SPINE_GLYPH   = [char]0x2502   # │  vertical spine
$GRAPH_H_LINE_GLYPH  = [char]0x2500   # ─  horizontal line
$GRAPH_ARROW_RIGHT   = [char]0x25BA   # ►  integration outbound
$GRAPH_ARROW_LEFT    = [char]0x25C4   # ◄  integration inbound
$GRAPH_SEPARATOR     = [char]0x2550   # ═  section separator
$GRAPH_CURSOR        = [char]0x25B6   # ▶  cursor indicator

function Build-GraphFrameRow {
    <#
    .SYNOPSIS
        Constructs a single FrameRow for the graph screen.
    .DESCRIPTION
        Returns an object with Y, Segments (single full-width segment), and Signature.
        Text is padded or truncated to exactly Width columns.
    #>
    param(
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Color,
        [AllowEmptyString()][string]$BackgroundColor = '',
        [Parameter(Mandatory)][int]$Width,
        [AllowEmptyString()][string]$SigHint = ''
    )

    $padded = if ($Text.Length -gt $Width) {
        $Text.Substring(0, $Width)
    } elseif ($Text.Length -lt $Width) {
        $Text + (' ' * ($Width - $Text.Length))
    } else {
        $Text
    }

    $seg = @{ Text = $padded; Color = $Color; BackgroundColor = $BackgroundColor }
    $sig = if (-not [string]::IsNullOrEmpty($SigHint)) { $SigHint } else { "${Color}|${BackgroundColor}|${padded}" }
    return [pscustomobject]@{ Y = $Y; Segments = @($seg); Signature = $sig }
}

function Format-GraphNodeText {
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][bool]$IsFocused
    )

    $cursorGlyph = if ($IsFocused) { "$GRAPH_CURSOR" } else { ' ' }
    $nodeGlyph   = if ($IsFocused) { "$GRAPH_FOCUSED_GLYPH" } else { "$GRAPH_NODE_GLYPH" }
    $rev         = [int]$Node.Rev
    $action      = [string]$Node.Action
    $change      = [int]$Node.Change
    $actionPadded = if ($action.Length -ge 10) { $action.Substring(0, 10) } else { $action.PadRight(10) }
    return "${cursorGlyph}${nodeGlyph} #${rev}  ${actionPadded}  cl#${change}"
}

function Format-GraphIntegrationText {
    param(
        [Parameter(Mandatory)]$Integration,
        [Parameter(Mandatory)][bool]$IsFocused
    )

    $dir        = [string]$Integration.Direction
    $how        = [string]$Integration.How
    $file       = [string]$Integration.File
    $erev       = [int]$Integration.EndRev
    $cursorGlyph = if ($IsFocused) { "$GRAPH_CURSOR" } else { ' ' }

    if ($dir -eq 'inbound') {
        return "${cursorGlyph}   ${GRAPH_ARROW_LEFT}${GRAPH_H_LINE_GLYPH}${GRAPH_H_LINE_GLYPH} ${file}#${erev}  [${how}]"
    } else {
        return "${cursorGlyph}   ${GRAPH_H_LINE_GLYPH}${GRAPH_H_LINE_GLYPH}${GRAPH_ARROW_RIGHT} ${file}#${erev}  [${how}]"
    }
}

function Build-GraphFrame {
    <#
    .SYNOPSIS
        Builds the full terminal frame for the RevisionGraph screen.
    .DESCRIPTION
        Returns a frame object { Width; Height; Rows[] } where each row is
        { Y; Segments; Signature } — exactly the same structure as Build-FilesScreenFrame.
        Layout (top to bottom):
          2 rows   Lane header + separator
          N rows   Scrollable graph area
          5 rows   Detail separator + 4 detail lines
          1 row    Status bar
    #>
    param([Parameter(Mandatory)]$State)

    $layout = $State.Ui.Layout
    $width  = [int]$layout.Width
    $height = [int]$layout.Height

    $headerLines = 2    # depot path + ═════ separator
    $detailLines = 5    # ═════ separator + 4 content lines
    $statusLines = 1
    $graphAreaH  = [Math]::Max(1, $height - $headerLines - $detailLines - $statusLines)

    $graphProp  = $State.Data.PSObject.Properties['RevisionGraph']
    $graphState = if ($null -ne $graphProp) { $graphProp.Value } else { $null }
    $lanes      = if ($null -ne $graphState) { @($graphState.Lanes) } else { @() }

    $graphRowsProp = $State.Derived.PSObject.Properties['GraphRows']
    $graphRows = @()
    if ($null -ne $graphRowsProp -and $null -ne $graphRowsProp.Value) {
        $graphRows = @($graphRowsProp.Value)
    }

    $curIdxProp = $State.Cursor.PSObject.Properties['GraphRowIndex']
    $cursorIdx  = if ($null -ne $curIdxProp) { [int]$curIdxProp.Value } else { 0 }

    $topProp    = $State.Cursor.PSObject.Properties['GraphScrollTop']
    $scrollTop  = if ($null -ne $topProp) { [int]$topProp.Value } else { 0 }

    $isLoading  = ($lanes.Count -gt 0 -and [bool]$lanes[0].IsLoading)

    $rows = [System.Collections.Generic.List[object]]::new($height)
    $y    = 0

    # ── Lane header: depot path ────────────────────────────────────────────────
    $depotPath  = if ($null -ne $graphState) { [string]$graphState.InitialDepotFile } else { '' }
    $loadSuffix = if ($isLoading) { '  ... loading' } else { '' }
    $headerText = " ${depotPath}${loadSuffix}"
    $rows.Add((Build-GraphFrameRow -Y $y -Text $headerText -Color 'Cyan' -Width $width `
        -SigHint "graphhdr:${depotPath}:${isLoading}"))
    $y++

    # ── Header separator ══════════════════════════════════════════════════════
    $sepText = [string]::new($GRAPH_SEPARATOR, $width)
    $rows.Add((Build-GraphFrameRow -Y $y -Text $sepText -Color 'DarkGray' -Width $width `
        -SigHint "graphsep:${width}"))
    $y++

    # ── Graph area ─────────────────────────────────────────────────────────────
    for ($i = 0; $i -lt $graphAreaH; $i++) {
        $rowIdx    = $scrollTop + $i
        $isFocused = ($rowIdx -eq $cursorIdx)

        if ($graphRows.Count -eq 0 -and $isLoading) {
            # Show a loading placeholder centred in the graph area
            $midRow = [Math]::Floor($graphAreaH / 2)
            $text   = if ($i -eq $midRow) { '  Loading revision history...' } else { '' }
            $rows.Add((Build-GraphFrameRow -Y $y -Text $text -Color 'DarkGray' -Width $width `
                -SigHint "graphloading:${i}"))
        } elseif ($rowIdx -lt $graphRows.Count) {
            $gr  = $graphRows[$rowIdx]
            $bg  = if ($isFocused) { 'DarkCyan' } else { '' }

            $text = switch ([string]$gr.RowType) {
                'Node' {
                    Format-GraphNodeText -Node $gr.RevisionNode -IsFocused $isFocused
                }
                'Integration' {
                    Format-GraphIntegrationText -Integration $gr.Integration -IsFocused $isFocused
                }
                'Spine' {
                    " $GRAPH_SPINE_GLYPH"
                }
                default { '' }
            }

            $color = switch ([string]$gr.RowType) {
                'Node'        { if ($isFocused) { 'White'    } else { 'White'    } }
                'Integration' { if ($isFocused) { 'White'    } else { 'DarkCyan' } }
                'Spine'       { 'DarkGray' }
                default       { 'Gray' }
            }

            $revStr = if ($null -ne $gr.PSObject.Properties['RevisionNode']?.Value) {
                [string]$gr.RevisionNode.Change
            } else { '0' }
            $rows.Add((Build-GraphFrameRow -Y $y -Text $text -Color $color -BackgroundColor $bg `
                -Width $width -SigHint "graphrow:${rowIdx}:${isFocused}:${revStr}"))
        } else {
            $rows.Add((Build-GraphFrameRow -Y $y -Text '' -Color 'Gray' -Width $width `
                -SigHint "graphempty:${rowIdx}"))
        }
        $y++
    }

    # ── Detail area separator ══════════════════════════════════════════════════
    $rows.Add((Build-GraphFrameRow -Y $y -Text $sepText -Color 'DarkGray' -Width $width `
        -SigHint "graphdetailsep:${width}"))
    $y++

    # ── Detail content ─────────────────────────────────────────────────────────
    # Get-FocusedGraphNode is exported from GraphReducer.psm1 (loaded by root module)
    $focusedNode = Get-FocusedGraphNode -State $State

    if ($null -ne $focusedNode) {
        $timeInt = [int]$focusedNode.Time
        $dateStr = if ($timeInt -gt 0) {
            try { [datetime]::UnixEpoch.AddSeconds($timeInt).ToLocalTime().ToString('yyyy-MM-dd') } catch { '' }
        } else { '' }

        $rev    = [int]$focusedNode.Rev
        $action = [string]$focusedNode.Action
        $change = [int]$focusedNode.Change
        $user   = [string]$focusedNode.User
        $client = [string]$focusedNode.Client
        $desc   = [string]$focusedNode.Description
        $descFirst = ($desc -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($descFirst)) { $descFirst = '(no description)' }

        $line1 = " #${rev}  ${action}  cl#${change}  ${dateStr}  ${user}@${client}"
        $line2 = " '${descFirst}'"
        $detailContent = @($line1, $line2, '', '')

        for ($d = 0; $d -lt 4; $d++) {
            $dt = if ($d -lt $detailContent.Count) { $detailContent[$d] } else { '' }
            $rows.Add((Build-GraphFrameRow -Y $y -Text $dt -Color 'Gray' -Width $width `
                -SigHint "graphdetail:${d}:${change}"))
            $y++
        }
    } else {
        for ($d = 0; $d -lt 4; $d++) {
            $rows.Add((Build-GraphFrameRow -Y $y -Text '' -Color 'DarkGray' -Width $width `
                -SigHint "graphdetail:${d}:none"))
            $y++
        }
    }

    # ── Status bar ─────────────────────────────────────────────────────────────
    $totalRevs = 0
    $laneCount = $lanes.Count
    foreach ($lane in $lanes) { $totalRevs += [int](@($lane.Revisions).Count) }

    $lastErrorProp = $State.Runtime.PSObject.Properties['LastError']
    $lastError     = if ($null -ne $lastErrorProp -and $null -ne $lastErrorProp.Value) { [string]$lastErrorProp.Value } else { '' }
    $errorPart     = if (-not [string]::IsNullOrWhiteSpace($lastError)) { "  ! $lastError" } else { '' }
    $statusText    = " Revisions: $totalRevs  |  Lanes: $laneCount  |  Up/Down: Navigate  Esc: Back  Q: Quit${errorPart}"

    $rows.Add((Build-GraphFrameRow -Y $y -Text $statusText -Color 'DarkGray' -Width $width `
        -SigHint "graphstatus:${totalRevs}:${laneCount}"))

    return [pscustomobject]@{
        Width  = $width
        Height = $height
        Rows   = $rows.ToArray()
    }
}

Export-ModuleMember -Function Build-GraphFrame, Build-GraphFrameRow
