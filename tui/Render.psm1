Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Theme.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force

$_theme                = Get-BrowserUiTheme
$SCROLLBAR_THUMB_GLYPH = [char]0x2591
$SCROLLBAR_TRACK_GLYPH = [char]0x2502
$CURSOR_GLYPH          = $_theme.Glyphs.Cursor      # ▶
$MARK_GLYPH            = $_theme.Glyphs.Mark        # ●
$UNRESOLVED_GLYPH      = $_theme.Glyphs.Unresolved  # ⚠
$OPENED_GLYPH          = $_theme.Glyphs.Opened      # 📁
$SHELVED_GLYPH         = $_theme.Glyphs.Shelved     # 📦
$MODIFIED_GLYPH        = $_theme.Glyphs.Modified    # ≠
$PENDING_GLYPH         = [char]0x2026               # … (horizontal ellipsis — enrichment pending)
$UNRESOLVED_BADGE_WIDTH = 2  # one glyph slot + one trailing space

# Set to $true via Enable-FrameIntegrityTest to activate the runtime border checker.
$script:IntegrityTestEnabled = $false

# Set to $true via Disable-RenderFlush (test seam) to suppress all [Console]::Write calls.
$script:SuppressFlush = $false

# Optional callback installed by the root module to record render sub-stage timings.
$script:RenderProfiler = $null

# Cache stable filter-pane rows across renders. Cursor movement in the changelist
# pane does not affect this content, so rebuilding it every frame is wasted work.
$script:FilterPaneRowsCache = $null

function Set-RenderProfiler {
    param([AllowNull()][scriptblock]$Profiler = $null)
    $script:RenderProfiler = $Profiler
}

function Invoke-RenderProfileEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][int]$DurationMs,
        [Parameter(Mandatory = $false)][hashtable]$Fields = @{}
    )

    if ($null -eq $script:RenderProfiler) { return }
    & $script:RenderProfiler $Stage $DurationMs $Fields
}

function Get-RenderProfileFields {
    param([Parameter(Mandatory = $true)]$State)

    $screenStackProp = $State.Ui.PSObject.Properties['ScreenStack']
    $activeScreen    = if ($null -ne $screenStackProp -and $screenStackProp.Value.Count -gt 0) { $screenStackProp.Value[-1] } else { 'Changelists' }
    $viewMode = Get-PropertyValueOrDefault -Object $State.Ui -Name 'ViewMode' -Default 'Pending'

    return @{
        Screen     = [string]$activeScreen
        ViewMode   = [string]$viewMode
        ActivePane = [string](Get-PropertyValueOrDefault -Object $State.Ui -Name 'ActivePane' -Default '')
    }
}

function Get-ReferenceIdentity {
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return 0 }
    return [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Object)
}

function Get-PropertyValueOrDefault {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $value = $Object[$Name]
            if ($null -eq $value) { return $Default }
            return $value
        }
        return $Default
    }

    $match = $Object.PSObject.Properties.Match($Name)
    if ($null -eq $match -or $match.Count -eq 0) { return $Default }
    $value = $match[0].Value
    if ($null -eq $value) { return $Default }
    return $value
}

function Get-BusyIndicatorGlyph {
    param(
        [datetime]$StartedAt = [datetime]::MinValue,
        [datetime]$CurrentTime = [datetime]::MinValue
    )

    $frames = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2)

    if ($StartedAt -eq [datetime]::MinValue) {
        return $frames[0]
    }

    $now = if ($CurrentTime -ne [datetime]::MinValue) { $CurrentTime } else { Get-Date }
    $elapsedSeconds = [Math]::Max(0, [int](($now - $StartedAt).TotalSeconds))

    return $frames[$elapsedSeconds % $frames.Count]
}

function Test-IsSegmentLike {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    return $Value.PSObject.Properties.Match('Text').Count -gt 0
}

# Returns an array-as-value via Write-Output -NoEnumerate.
# CALLER: do NOT wrap this call in @() — that re-wraps the returned array as a
# 1-element array, which silently breaks any downstream segment processing.
# Correct:  $segs = Merge-AdjacentSegments -Segments $input
# WRONG:    $segs = @(Merge-AdjacentSegments -Segments $input)  # nests array!
function Merge-AdjacentSegments {
    param([Parameter(Mandatory = $true)]$Segments)

    $flat = @()
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        if ($segment -is [System.Collections.IEnumerable] -and -not ($segment -is [string]) -and -not (Test-IsSegmentLike -Value $segment)) {
            $flat += @(Merge-AdjacentSegments -Segments $segment)
            continue
        }

        $text = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')
        $color = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Color' -Default 'Gray')
        $background = [string](Get-PropertyValueOrDefault -Object $segment -Name 'BackgroundColor' -Default '')
        $flat += @(@{ Text = $text; Color = $color; BackgroundColor = $background })
    }

    if ($flat.Count -eq 0) {
        Write-Output -NoEnumerate @()
        return
    }

    $merged = @()
    foreach ($segment in $flat) {
        if ($merged.Count -eq 0) {
            $merged += @($segment)
            continue
        }

        $last = $merged[$merged.Count - 1]
        if ($last.Color -eq $segment.Color -and $last.BackgroundColor -eq $segment.BackgroundColor) {
            $last.Text = [string]$last.Text + [string]$segment.Text
            $merged[$merged.Count - 1] = $last
        } else {
            $merged += @($segment)
        }
    }

    Write-Output -NoEnumerate @($merged)
}

# Returns an array-as-value via Write-Output -NoEnumerate.
# CALLER: do NOT wrap this call in @() — see Merge-AdjacentSegments note above.
function Write-ColorSegments {
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][int]$Width
    )

    if ($Width -le 0) {
        Write-Output -NoEnumerate @()
        return
    }

    $flat = @()
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        if ($segment -is [System.Collections.IEnumerable] -and -not ($segment -is [string]) -and -not (Test-IsSegmentLike -Value $segment)) {
            $flat += @(Write-ColorSegments -Segments $segment -Width 2147483647)
            continue
        }

        $flat += @(@{
            Text = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')
            Color = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Color' -Default 'Gray')
            BackgroundColor = [string](Get-PropertyValueOrDefault -Object $segment -Name 'BackgroundColor' -Default '')
        })
    }

    if ($flat.Count -eq 0) {
        $padText = if ($Width -lt [int]::MaxValue) { ' ' * $Width } else { '' }
        Write-Output -NoEnumerate @(@{ Text = $padText; Color = 'Gray'; BackgroundColor = '' })
        return
    }

    $text = (($flat | ForEach-Object { [string]$_.Text }) -join '')
    $baseColor = [string]$flat[0].Color
    $baseBackground = [string]$flat[0].BackgroundColor

    if ($text.Length -gt $Width) {
        if ($Width -le 1) {
            $text = $text.Substring(0, $Width)
        } else {
            $text = $text.Substring(0, $Width - 1) + [char]0x2026
        }
    } elseif ($text.Length -lt $Width -and $Width -lt [int]::MaxValue) {
        $text = $text + (' ' * ($Width - $text.Length))
    }

    Write-Output -NoEnumerate @(@{ Text = $text; Color = $baseColor; BackgroundColor = $baseBackground })
}

function Build-BoxTopSegments {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][string]$BorderColor,
        [Parameter(Mandatory = $true)][string]$TitleColor
    )

    if ($Width -le 0) {
        Write-Output -NoEnumerate @()
        return
    }
    if ($Width -eq 1) {
        Write-Output -NoEnumerate @(@{ Text = '╭'; Color = $BorderColor })
        return
    }

    $innerWidth = [Math]::Max(0, $Width - 2)
    $inner = '─' * $innerWidth
    if ($innerWidth -gt 0 -and -not [string]::IsNullOrEmpty($Title)) {
        $trimmedTitle = if ($Title.Length -gt $innerWidth) { $Title.Substring(0, $innerWidth) } else { $Title }
        $start = [Math]::Max(0, [Math]::Floor(($innerWidth - $trimmedTitle.Length) / 2))
        $innerChars = $inner.ToCharArray()
        for ($i = 0; $i -lt $trimmedTitle.Length; $i++) {
            $innerChars[$start + $i] = $trimmedTitle[$i]
        }
        $inner = -join $innerChars
    }

    Write-Output -NoEnumerate @(
        @{ Text = '╭'; Color = $BorderColor },
        @{ Text = $inner; Color = $TitleColor },
        @{ Text = '╮'; Color = $BorderColor }
    )
}

function Build-BoxBottomSegments {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][string]$BorderColor
    )

    if ($Width -le 0) {
        Write-Output -NoEnumerate @()
        return
    }
    if ($Width -eq 1) {
        Write-Output -NoEnumerate @(@{ Text = '╰'; Color = $BorderColor })
        return
    }

    Write-Output -NoEnumerate @(
        @{ Text = '╰'; Color = $BorderColor },
        @{ Text = ('─' * [Math]::Max(0, $Width - 2)); Color = $BorderColor },
        @{ Text = '╯'; Color = $BorderColor }
    )
}

function Build-BorderedRowSegments {
    param(
        [Parameter(Mandatory = $true)]$InnerSegments,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][string]$BorderColor
    )

    if ($Width -le 0) {
        Write-Output -NoEnumerate @()
        return
    }
    if ($Width -eq 1) {
        Write-Output -NoEnumerate @(@{ Text = '│'; Color = $BorderColor })
        return
    }

    $innerWidth = [Math]::Max(0, $Width - 2)
    $inner = @(Resize-SegmentRow -Segments $InnerSegments -Width $innerWidth)
    $segments = @(@{ Text = '│'; Color = $BorderColor }) + @($inner) + @(@{ Text = '│'; Color = $BorderColor })
    Write-Output -NoEnumerate $segments
}

function Resize-SegmentRow {
    # Truncate or pad a row of multi-colored segments to exactly $Width characters,
    # preserving each segment's Color and BackgroundColor.
    # Nested arrays of segments are flattened recursively (same as Write-ColorSegments).
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][int]$Width
    )

    if ($Width -le 0) { return @() }

    # Flatten nested arrays recursively in-order, preserving individual segment
    # colors. A previous breadth-first expansion reordered bordered rows like
    # [left-border, inner..., right-border] into [left-border, right-border,
    # inner...], which made pane borders disappear from the seam columns.
    $flat = [System.Collections.Generic.List[object]]::new()
    $appendSegmentsInOrder = {
        param($Items)

        foreach ($s in @($Items)) {
            if ($null -eq $s) { continue }
            if ($s -is [System.Collections.IEnumerable] -and -not ($s -is [string]) -and -not (Test-IsSegmentLike -Value $s)) {
                & $appendSegmentsInOrder $s
                continue
            }

            $h = @{
                Text            = [string](Get-PropertyValueOrDefault -Object $s -Name 'Text'            -Default '')
                Color           = [string](Get-PropertyValueOrDefault -Object $s -Name 'Color'           -Default 'Gray')
                BackgroundColor = [string](Get-PropertyValueOrDefault -Object $s -Name 'BackgroundColor' -Default '')
            }
            $flat.Add($h)
        }
    }
    & $appendSegmentsInOrder $Segments

    $result = [System.Collections.Generic.List[object]]::new()
    $remaining = $Width

    foreach ($seg in $flat) {
        if ($remaining -le 0) { break }
        $text  = [string](Get-PropertyValueOrDefault -Object $seg -Name 'Text'            -Default '')
        $color = [string](Get-PropertyValueOrDefault -Object $seg -Name 'Color'           -Default 'Gray')
        $bg    = [string](Get-PropertyValueOrDefault -Object $seg -Name 'BackgroundColor' -Default '')

        if ($text.Length -le $remaining) {
            $result.Add(@{ Text = $text; Color = $color; BackgroundColor = $bg })
            $remaining -= $text.Length
        } else {
            $result.Add(@{ Text = $text.Substring(0, $remaining); Color = $color; BackgroundColor = $bg })
            $remaining = 0
        }
    }

    if ($remaining -gt 0) {
        if ($result.Count -gt 0) {
            # Widen the trailing segment in-place to consume remaining space
            $last = $result[$result.Count - 1]
            $last.Text = [string]$last.Text + (' ' * $remaining)
            $result[$result.Count - 1] = $last
        } else {
            $result.Add(@{ Text = (' ' * $remaining); Color = 'Gray'; BackgroundColor = '' })
        }
    }

    return $result.ToArray()
}

function Get-SegmentRowWidth {
    param([AllowNull()]$Segments)

    $width = 0
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        if (-not (Test-IsSegmentLike -Value $segment)) {
            return -1
        }

        $width += ([string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')).Length
    }

    return $width
}

function New-FrameRowFromFlatSegments {
    param(
        [Parameter(Mandatory = $true)][int]$Y,
        [AllowNull()]$LeftSegments,
        [AllowNull()]$RightSegments,
        [AllowEmptyString()][string]$RightBackgroundColor = ''
    )

    $combined = [System.Collections.Generic.List[object]]::new()
    $signatureBuilder = [System.Text.StringBuilder]::new()

    $appendSegment = {
        param($Segment, [AllowEmptyString()][string]$BackgroundOverride = '')

        if ($null -eq $Segment) { return }

        $text = [string](Get-PropertyValueOrDefault -Object $Segment -Name 'Text' -Default '')
        $color = [string](Get-PropertyValueOrDefault -Object $Segment -Name 'Color' -Default 'Gray')
        $background = if ([string]::IsNullOrEmpty($BackgroundOverride)) {
            [string](Get-PropertyValueOrDefault -Object $Segment -Name 'BackgroundColor' -Default '')
        } else {
            $BackgroundOverride
        }

        $segmentValue = @{ Text = $text; Color = $color; BackgroundColor = $background }
        $combined.Add($segmentValue)
        if ($signatureBuilder.Length -gt 0) {
            [void]$signatureBuilder.Append(';')
        }
        [void]$signatureBuilder.Append($color)
        [void]$signatureBuilder.Append('|')
        [void]$signatureBuilder.Append($background)
        [void]$signatureBuilder.Append('|')
        [void]$signatureBuilder.Append($text)
    }

    foreach ($segment in @($LeftSegments)) {
        & $appendSegment $segment
    }

    & $appendSegment @{ Text = ' '; Color = 'DarkGray'; BackgroundColor = '' }

    foreach ($segment in @($RightSegments)) {
        & $appendSegment $segment $RightBackgroundColor
    }

    return [pscustomobject]@{
        Y = $Y
        Segments = $combined.ToArray()
        Signature = $signatureBuilder.ToString()
    }
}

function Compose-FrameRow {
    param(
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)]$LeftSegments,
        [Parameter(Mandatory = $true)][int]$LeftWidth,
        [Parameter(Mandatory = $true)]$RightSegments,
        [Parameter(Mandatory = $true)][int]$RightWidth,
        [AllowEmptyString()][string]$RightBackgroundColor = '',
        [Parameter(Mandatory = $true)][int]$TotalWidth,
        [Parameter(Mandatory = $true)][bool]$IsLastRow
    )

    $targetWidth = if ($IsLastRow) { [Math]::Max(0, $TotalWidth - 1) } else { [Math]::Max(0, $TotalWidth) }
    $leftActualWidth = Get-SegmentRowWidth -Segments $LeftSegments
    $rightActualWidth = Get-SegmentRowWidth -Segments $RightSegments
    if ($leftActualWidth -ge 0 -and $rightActualWidth -ge 0 -and ($leftActualWidth + 1 + $rightActualWidth) -eq $targetWidth) {
        return New-FrameRowFromFlatSegments -Y $Y -LeftSegments $LeftSegments -RightSegments $RightSegments -RightBackgroundColor $RightBackgroundColor
    }

    $left  = @(Resize-SegmentRow -Segments $LeftSegments  -Width ([Math]::Max(0, $LeftWidth)))
    $right = @(Resize-SegmentRow -Segments $RightSegments -Width ([Math]::Max(0, $RightWidth)))

    if (-not [string]::IsNullOrEmpty($RightBackgroundColor)) {
        $right = @($right | ForEach-Object {
            @{
                Text = [string](Get-PropertyValueOrDefault -Object $_ -Name 'Text' -Default '')
                Color = [string](Get-PropertyValueOrDefault -Object $_ -Name 'Color' -Default 'Gray')
                BackgroundColor = $RightBackgroundColor
            }
        })
    }

    $gap = @(@{ Text = ' '; Color = 'DarkGray'; BackgroundColor = '' })
    $combined = @($left + $gap + $right)
    $combined = Merge-AdjacentSegments -Segments $combined

    $combined = Resize-SegmentRow -Segments $combined -Width $targetWidth
    $combined = Merge-AdjacentSegments -Segments $combined

    return [pscustomobject]@{
        Y = $Y
        Segments = $combined
        Signature = Get-FrameRowSignature -Segments $combined
    }
}

function Get-FrameRowSignature {
    param([Parameter(Mandatory = $true)]$Segments)

    $builder = [System.Text.StringBuilder]::new()
    $isFirst = $true

    foreach ($segment in @($Segments)) {
        $color = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Color' -Default 'Gray')
        $background = [string](Get-PropertyValueOrDefault -Object $segment -Name 'BackgroundColor' -Default '')
        $text = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')

        if (-not $isFirst) {
            [void]$builder.Append(';')
        }
        [void]$builder.Append($color)
        [void]$builder.Append('|')
        [void]$builder.Append($background)
        [void]$builder.Append('|')
        [void]$builder.Append($text)
        $isFirst = $false
    }

    return $builder.ToString()
}

function Get-FrameDiff {
    param(
        [AllowNull()]$PreviousFrame,
        [Parameter(Mandatory = $true)]$NextFrame
    )

    if ($null -eq $PreviousFrame) {
        Write-Output -NoEnumerate @($NextFrame.Rows)
        return
    }
    if ($PreviousFrame.Width -ne $NextFrame.Width -or $PreviousFrame.Height -ne $NextFrame.Height) {
        Write-Output -NoEnumerate @($NextFrame.Rows)
        return
    }

    $changed = @()
    $maxRows = [Math]::Min($PreviousFrame.Rows.Count, $NextFrame.Rows.Count)
    for ($i = 0; $i -lt $maxRows; $i++) {
        if ($PreviousFrame.Rows[$i].Signature -ne $NextFrame.Rows[$i].Signature) {
            $changed += @($NextFrame.Rows[$i])
        }
    }

    if ($NextFrame.Rows.Count -gt $maxRows) {
        for ($i = $maxRows; $i -lt $NextFrame.Rows.Count; $i++) {
            $changed += @($NextFrame.Rows[$i])
        }
    }

    Write-Output -NoEnumerate @($changed)
}

function Flush-FrameDiff {
    param(
        [Parameter(Mandatory = $true)]$ChangedRows,
        [Parameter(Mandatory = $true)]$Frame
    )

    $null = $Frame  # reserved: passed for API symmetry; not yet used in body

    if ($script:SuppressFlush) { return $true }

    try {
        foreach ($row in @($ChangedRows)) {
            [Console]::SetCursorPosition(0, [int]$row.Y)
            foreach ($segment in @($row.Segments)) {
                $text = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')
                $fg = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Color' -Default 'Gray')
                $bg = [string](Get-PropertyValueOrDefault -Object $segment -Name 'BackgroundColor' -Default '')

                try { [Console]::ForegroundColor = [System.ConsoleColor]::$fg } catch { [Console]::ForegroundColor = [System.ConsoleColor]::Gray }
                if ([string]::IsNullOrEmpty($bg)) {
                    [Console]::BackgroundColor = [System.ConsoleColor]::Black
                } else {
                    try { [Console]::BackgroundColor = [System.ConsoleColor]::$bg } catch { [Console]::BackgroundColor = [System.ConsoleColor]::Black }
                }

                # Strip control characters (U+0000–U+001F, U+007F) before writing.
                # Any embedded newline, carriage-return, tab, etc. from raw p4 output
                # would move the terminal cursor and corrupt the layout.
                $text = $text -replace '[\x00-\x1F\x7F]', ' '
                [Console]::Write($text)
            }
        }

        [Console]::ResetColor()
        return $true
    }
    catch {
        try { [Console]::ResetColor() } catch { <# best-effort cleanup � swallow to avoid masking the original error #> }
        return $false
    }
}

function Get-ScrollThumb {
    param(
        [Parameter(Mandatory = $true)][int]$TotalItems,
        [Parameter(Mandatory = $true)][int]$ViewRows,
        [Parameter(Mandatory = $true)][int]$ScrollTop
    )

    if ($ViewRows -le 0) { return $null }
    if ($TotalItems -le $ViewRows) { return $null }

    $maxScroll = [Math]::Max(1, $TotalItems - $ViewRows)
    $clampedTop = [Math]::Min([Math]::Max(0, $ScrollTop), $maxScroll)

    $rawSize = [Math]::Round(($ViewRows * $ViewRows) / [double]$TotalItems)
    $size = [Math]::Max(1, [Math]::Min($ViewRows, [int]$rawSize))
    $travel = [Math]::Max(0, $ViewRows - $size)
    $start = if ($travel -eq 0) { 0 } else { [int][Math]::Round(($clampedTop / [double]$maxScroll) * $travel) }
    $end = [Math]::Min($ViewRows - 1, $start + $size - 1)

    return [pscustomobject]@{
        Size = $size
        Start = $start
        End = $end
    }
}

$script:PreviousFrame = $null

function Reset-RenderState {
    $script:PreviousFrame = $null
    $script:FilterPaneRowsCache = $null
}

function Get-ChangeById {
    param(
        [AllowNull()][object[]]$Changes,
        [Parameter(Mandatory = $true)][string]$Id
    )

    if ($null -eq $Changes) {
        return $null
    }

    return $Changes | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Get-ActiveChangesList {
    param([Parameter(Mandatory = $true)]$State)

    $viewMode = Get-PropertyValueOrDefault -Object $State.Ui -Name 'ViewMode' -Default 'Pending'
    if ($viewMode -eq 'Submitted') {
        $submitted = Get-PropertyValueOrDefault -Object $State.Data -Name 'SubmittedChanges' -Default $null
        if ($null -eq $submitted) { return @() }
        return @($submitted)
    }

    $data = Get-PropertyValueOrDefault -Object $State -Name 'Data' -Default $null
    $allChanges = Get-PropertyValueOrDefault -Object $data -Name 'AllChanges' -Default $null
    if ($null -eq $allChanges) {
        return @()
    }

    return @($allChanges)
}

function Get-ChangeLookupById {
    param([AllowNull()][object[]]$Changes)

    $lookup = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Changes) {
        return $lookup
    }

    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        $changeId = [string](Get-PropertyValueOrDefault -Object $change -Name 'Id' -Default '')
        if ([string]::IsNullOrWhiteSpace($changeId)) { continue }
        if (-not $lookup.ContainsKey($changeId)) {
            $lookup[$changeId] = $change
        }
    }

    return $lookup
}

function Get-VisibleFilterByIndex {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$FilterIndex
    )

    if ($FilterIndex -lt 0 -or $FilterIndex -ge $State.Derived.VisibleFilters.Count) {
        return $null
    }

    return $State.Derived.VisibleFilters[$FilterIndex]
}

function Get-MarkerColor {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Marker)

    switch ($Marker) {
        $CURSOR_GLYPH { return 'Cyan' }
        $SCROLLBAR_THUMB_GLYPH { return 'Gray' }
        $SCROLLBAR_TRACK_GLYPH { return 'DarkGray' }
        default { return 'DarkGray' }
    }
}

function Get-FilterRowModel {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$FilterIndex,
        [Parameter(Mandatory = $true)][int]$FilterRowOffset,
        [AllowNull()]$FilterThumb
    )

    $FilterText = ''
    $FilterColor = 'Gray'
    $FilterMarker = ' '
    $filterItem = Get-VisibleFilterByIndex -State $State -FilterIndex $FilterIndex

    if ($null -ne $filterItem) {
        if ($State.Cursor.FilterIndex -eq $FilterIndex) {
            $FilterMarker = $CURSOR_GLYPH
        } elseif ($null -ne $FilterThumb) {
            if ($FilterRowOffset -ge $FilterThumb.Start -and $FilterRowOffset -le $FilterThumb.End) {
                $FilterMarker = $SCROLLBAR_THUMB_GLYPH
            } else {
                $FilterMarker = $SCROLLBAR_TRACK_GLYPH
            }
        }

        $isSelected = [bool](Get-PropertyValueOrDefault -Object $filterItem -Name 'IsSelected' -Default $false)
        $isSelectable = [bool](Get-PropertyValueOrDefault -Object $filterItem -Name 'IsSelectable' -Default $true)
        $filterName = [string](Get-PropertyValueOrDefault -Object $filterItem -Name 'Name' -Default '')
        $filterMatchCount = [string](Get-PropertyValueOrDefault -Object $filterItem -Name 'MatchCount' -Default '')
        $mark = if ($isSelected) { '☑' } else { '☐' }
        $FilterText = "$FilterMarker $mark $filterName ($filterMatchCount)"

        if (-not $isSelectable -and -not $isSelected) {
            $FilterColor = 'DarkGray'
        } elseif ($isSelected) {
            $FilterColor = 'Green'
        }
    } elseif ($null -ne $FilterThumb) {
        if ($FilterRowOffset -ge $FilterThumb.Start -and $FilterRowOffset -le $FilterThumb.End) {
            $FilterMarker = $SCROLLBAR_THUMB_GLYPH
        } else {
            $FilterMarker = $SCROLLBAR_TRACK_GLYPH
        }
        $FilterText = $FilterMarker
        $FilterColor = 'DarkGray'
    }

    return [pscustomobject]@{
        Text = $FilterText
        Color = $FilterColor
        Marker = $FilterMarker
    }
}

function Get-FilterPaneRowsCacheKey {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$BorderColor,
        [Parameter(Mandatory = $true)][string]$TitleColor,
        [AllowNull()]$FilterThumb
    )

    $thumbStart = if ($null -eq $FilterThumb) { -1 } else { [int]$FilterThumb.Start }
    $thumbEnd = if ($null -eq $FilterThumb) { -1 } else { [int]$FilterThumb.End }
    $visibleFilters = Get-PropertyValueOrDefault -Object $State.Derived -Name 'VisibleFilters' -Default $null

    return @(
        [string]$Layout.FilterPane.W,
        [string]$Layout.FilterPane.H,
        [string](Get-ReferenceIdentity -Object $visibleFilters),
        [string]$State.Cursor.FilterIndex,
        [string]$State.Cursor.FilterScrollTop,
        [string](Get-PropertyValueOrDefault -Object $State.Ui -Name 'ActivePane' -Default ''),
        [string]$BorderColor,
        [string]$TitleColor,
        [string]$thumbStart,
        [string]$thumbEnd
    ) -join '|'
}

function Get-FilterPaneRowSegments {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$BorderColor,
        [Parameter(Mandatory = $true)][string]$TitleColor,
        [AllowNull()]$FilterThumb
    )

    $cacheKey = Get-FilterPaneRowsCacheKey -State $State -Layout $Layout -BorderColor $BorderColor -TitleColor $TitleColor -FilterThumb $FilterThumb
    if ($null -ne $script:FilterPaneRowsCache -and $script:FilterPaneRowsCache.Key -eq $cacheKey) {
        return $script:FilterPaneRowsCache.Rows
    }

    $rows = [object[]]::new($Layout.FilterPane.H)
    for ($globalRow = 0; $globalRow -lt $Layout.FilterPane.H; $globalRow++) {
        if ($globalRow -eq 0) {
            $rows[$globalRow] = Build-BoxTopSegments -Title '[Filters]' -Width $Layout.FilterPane.W -BorderColor $BorderColor -TitleColor $TitleColor
            continue
        }

        if ($globalRow -eq ($Layout.FilterPane.H - 1)) {
            $rows[$globalRow] = Build-BoxBottomSegments -Width $Layout.FilterPane.W -BorderColor $BorderColor
            continue
        }

        $filterInnerRow = $globalRow - 1
        $filterIndex = $State.Cursor.FilterScrollTop + $filterInnerRow
        $filterRow = Get-FilterRowModel -State $State -FilterIndex $filterIndex -FilterRowOffset $filterInnerRow -FilterThumb $FilterThumb
        $filterInnerSegments = Build-FilterSegments -FilterText $filterRow.Text -FilterMarker $filterRow.Marker -FilterColor $filterRow.Color
        $rows[$globalRow] = Build-BorderedRowSegments -InnerSegments $filterInnerSegments -Width $Layout.FilterPane.W -BorderColor $BorderColor
    }

    $script:FilterPaneRowsCache = @{
        Key = $cacheKey
        Rows = $rows
    }

    return $rows
}

function Build-FilterSegments {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FilterText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FilterMarker,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FilterColor
    )

    if ($FilterText.Length -eq 0) {
        Write-Output -NoEnumerate @()
        return
    }

    $markerLength = [Math]::Max(0, [Math]::Min($FilterText.Length, $FilterMarker.Length))
    if ($markerLength -le 0) {
        Write-Output -NoEnumerate @(
            @{ Text = $FilterText; Color = $FilterColor }
        )
        return
    }

    $restText = $FilterText.Substring($markerLength)
    $segments = @(
        @{ Text = $FilterText.Substring(0, $markerLength); Color = (Get-MarkerColor -Marker $FilterMarker) }
    )

    if ($restText.Length -gt 0) {
        $segments += @{ Text = $restText; Color = $FilterColor }
    }

    Write-Output -NoEnumerate $segments
}

function Build-ChangeSegments {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Marker,
        [AllowNull()]$Change,
        [Parameter(Mandatory = $true)][bool]$IsSelected,
        [bool]$IsMarked = $false
    )

    $markBadge      = if ($IsMarked) { $MARK_GLYPH } else { ' ' }
    $markBadgeColor = if ($IsMarked) { 'Yellow' } else { 'Gray' }

    if ($null -eq $Change) {
        if ([string]::IsNullOrEmpty($Marker) -or $Marker -eq ' ') {
            Write-Output -NoEnumerate @()
            return
        }
        Write-Output -NoEnumerate @(
            @{ Text = $Marker;    Color = (Get-MarkerColor -Marker $Marker) },
            @{ Text = $markBadge; Color = $markBadgeColor }
        )
        return
    }

    $changeId         = [string](Get-PropertyValueOrDefault -Object $Change -Name 'Id'                 -Default '')
    $changeTitle      = [string](Get-PropertyValueOrDefault -Object $Change -Name 'Title'              -Default '')
    $changeKind       = [string](Get-PropertyValueOrDefault -Object $Change -Name 'Kind'               -Default '')
    $changeUser       = [string](Get-PropertyValueOrDefault -Object $Change -Name 'User'               -Default '')
    $openedCount      = [int]   (Get-PropertyValueOrDefault -Object $Change -Name 'OpenedFileCount'    -Default 0)
    $shelvedCount     = [int]   (Get-PropertyValueOrDefault -Object $Change -Name 'ShelvedFileCount'   -Default 0)
    $hasUnresolved    = [bool]  (Get-PropertyValueOrDefault -Object $Change -Name 'HasUnresolvedFiles' -Default $false)
    $hasOpened        = [bool]  (Get-PropertyValueOrDefault -Object $Change -Name 'HasOpenedFiles'     -Default ($openedCount -gt 0))
    $hasShelved       = [bool]  (Get-PropertyValueOrDefault -Object $Change -Name 'HasShelvedFiles'    -Default ($shelvedCount -gt 0))

    $markerColor      = if ($IsSelected) { 'Cyan' } else { Get-MarkerColor -Marker $Marker }
    $titleColor       = if ($IsSelected) { 'White' } else { 'Gray' }
    $stateText        = if ($hasUnresolved) {
        $UNRESOLVED_GLYPH + ' '
    } elseif ($hasOpened) {
        $OPENED_GLYPH
    } else {
        '  '
    }
    $stateColor       = if ($hasUnresolved) {
        'Yellow'
    } elseif ($hasOpened) {
        'DarkYellow'
    } else {
        'DarkGray'
    }
    $shelvedText      = if ($hasShelved) { $SHELVED_GLYPH } else { '  ' }
    $shelvedColor     = if ($hasShelved) { 'DarkCyan' } else { 'DarkGray' }

    $segments = @(
        @{ Text = $Marker;          Color = $markerColor       },
        @{ Text = $markBadge;       Color = $markBadgeColor    },
        @{ Text = $stateText;       Color = $stateColor        },
        @{ Text = $shelvedText;     Color = $shelvedColor      },
        @{ Text = " $changeId";     Color = 'DarkGray'         }
    )

    # Show user column for submitted entries
    if ($changeKind -eq 'Submitted' -and $changeUser.Length -gt 0) {
        $segments += @{ Text = " $changeUser"; Color = 'DarkYellow' }
    }

    if ($changeTitle.Length -gt 0) {
        $segments += @{ Text = " $changeTitle"; Color = $titleColor }
    }

    Write-Output -NoEnumerate $segments
}

function Build-ChangeDetailSegments {
    param(
        [AllowNull()]$Change
    )

    if ($null -eq $Change) {
        Write-Output -NoEnumerate @()
        return
    }

    $openedCount     = [int]   (Get-PropertyValueOrDefault -Object $Change -Name 'OpenedFileCount'     -Default 0)
    $shelvedCount    = [int]   (Get-PropertyValueOrDefault -Object $Change -Name 'ShelvedFileCount'    -Default 0)
    $unresolvedCount = [int]   (Get-PropertyValueOrDefault -Object $Change -Name 'UnresolvedFileCount' -Default 0)
    $capturedRaw     =          Get-PropertyValueOrDefault  -Object $Change -Name 'Captured'            -Default $null
    $dateStr = ''
    if ($null -ne $capturedRaw) {
        try { $dateStr = ([datetime]$capturedRaw).ToString('yyyy-MM-dd') } catch { $dateStr = '' }
    }

    $segments = @(
        @{ Text = [char]::ConvertFromUtf32(0x1F4C1); Color = 'DarkCyan' },
        @{ Text = " $openedCount  ";                  Color = 'Gray'     },
        @{ Text = [char]::ConvertFromUtf32(0x1F4E6); Color = 'DarkCyan' },
        @{ Text = " $shelvedCount  ";                 Color = 'Gray'     }
    )

    if ($unresolvedCount -gt 0) {
        $segments += @{ Text = $UNRESOLVED_GLYPH; Color = 'Yellow'   }
        $segments += @{ Text = " $unresolvedCount  "; Color = 'Gray' }
    }

    $segments += @{ Text = $dateStr; Color = 'DarkGray' }

    Write-Output -NoEnumerate $segments
}

function Build-SubmittedChangeDetailSegments {
    param(
        [AllowNull()]$Change
    )

    if ($null -eq $Change) {
        Write-Output -NoEnumerate @()
        return
    }

    $user        = [string](Get-PropertyValueOrDefault -Object $Change -Name 'User'       -Default '')
    $capturedRaw =          Get-PropertyValueOrDefault -Object $Change -Name 'Captured'   -Default $null
    $dateStr = ''
    if ($null -ne $capturedRaw) {
        try { $dateStr = ([datetime]$capturedRaw).ToString('yyyy-MM-dd HH:mm') } catch { $dateStr = '' }
    }

    Write-Output -NoEnumerate @(
        @{ Text = $user;    Color = 'DarkYellow' },
        @{ Text = '  ';     Color = 'Gray'       },
        @{ Text = $dateStr; Color = 'DarkGray'   }
    )
}

function Build-ChangeSummarySegments {
    param([AllowNull()]$Change)

    if ($null -eq $Change) {
        Write-Output -NoEnumerate @(
            @(
                @{ Text = 'No matching changelists'; Color = 'DarkGray' }
            )
        )
        return
    }

    $changeId = [string](Get-PropertyValueOrDefault -Object $Change -Name 'Id'    -Default '')
    $title    = [string](Get-PropertyValueOrDefault -Object $Change -Name 'Title' -Default '')

    # Row 0: Id
    $row0 = @(
        @{ Text = 'Id: ';    Color = 'DarkYellow' },
        @{ Text = $changeId; Color = 'DarkGray'   }
    )

    # Row 1: Title
    $row1 = @(
        @{ Text = 'Title: '; Color = 'DarkYellow' },
        @{ Text = $title;    Color = 'Gray'        }
    )

    Write-Output -NoEnumerate $row0
    Write-Output -NoEnumerate $row1
}

function Build-DetailSegments {
    param(
        [Parameter(Mandatory = $true)]$State,
        [AllowNull()]$SelectedChange = $null
    )

    $rows = [System.Collections.Generic.List[object]]::new()

    # Show last error if present
    $lastError = Get-PropertyValueOrDefault -Object $State.Runtime -Name 'LastError' -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$lastError)) {
        # Normalize: extract the STDERR message if present, otherwise take the first non-empty line
        # (Invoke-P4 throws a multi-line string; embedding raw newlines breaks the terminal layout)
        $errorDisplay  = [string]$lastError
        $stderrLine    = ($errorDisplay -split '\r?\n' | Where-Object { $_ -match '^STDERR:' } | Select-Object -First 1)
        if ($stderrLine) {
            $errorDisplay = $stderrLine -replace '^STDERR:\s*', ''
        } else {
            $errorDisplay = ($errorDisplay -split '\r?\n' | Where-Object { $_ -ne '' } | Select-Object -First 1)
        }
        $rows.Add(@(@{ Text = "Error: $errorDisplay"; Color = 'Red' }))
    }

    $selectedChange = $SelectedChange
    if ($null -eq $selectedChange -and $State.Derived.VisibleChangeIds.Count -gt 0) {
        $selectedId    = $State.Derived.VisibleChangeIds[[Math]::Min($State.Cursor.ChangeIndex, $State.Derived.VisibleChangeIds.Count - 1)]
        $activeChanges = Get-ActiveChangesList -State $State
        $selectedChange = Get-ChangeById -Changes $activeChanges -Id $selectedId
    }

    # Look up describe from cache via DetailChangeId (persists after describe is fetched)
    $desc           = $null
    $detailChangeId = Get-PropertyValueOrDefault -Object $State.Runtime -Name 'DetailChangeId' -Default $null
    $describeCache  = Get-PropertyValueOrDefault -Object $State.Data    -Name 'DescribeCache'  -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$detailChangeId) -and $null -ne $describeCache) {
        $change = ConvertTo-P4ChangelistId -Value $detailChangeId
        if ($null -ne $change -and $describeCache.ContainsKey($change)) {
            $desc = $describeCache[$change]
        }
    }

    if ($null -ne $desc) {
        # Render describe output
        $timeStr = if ($desc.Time) { $desc.Time.ToString('yyyy-MM-dd HH:mm') } else { '' }
        $rows.Add(@(
            @{ Text = "CL $($desc.Change)"; Color = 'Cyan' },
            @{ Text = '  '; Color = 'Gray' },
            @{ Text = [string]$desc.Status; Color = 'DarkYellow' },
            @{ Text = '  '; Color = 'Gray' },
            @{ Text = [string]$desc.User; Color = 'Gray' },
            @{ Text = '  '; Color = 'Gray' },
            @{ Text = [string]$desc.Client; Color = 'DarkGray' }
        ))
        $rows.Add(@(@{ Text = $timeStr; Color = 'DarkGray' }))
        $rows.Add(@(@{ Text = ''; Color = 'Gray' }))
        foreach ($line in @($desc.Description)) {
            $rows.Add(@(@{ Text = [string]$line; Color = 'Gray' }))
        }
        $rows.Add(@(@{ Text = ''; Color = 'Gray' }))
        foreach ($file in @($desc.Files)) {
            $rows.Add(@(
                @{ Text = ('{0,-8}' -f [string]$file.Action); Color = 'DarkYellow' },
                @{ Text = [string]$file.DepotPath; Color = 'Gray' }
            ))
        }
    } else {
        # Fall back to changelist summary
        foreach ($summaryRow in @(Build-ChangeSummarySegments -Change $selectedChange)) {
            $rows.Add($summaryRow)
        }
    }

    Write-Output -NoEnumerate $rows.ToArray()
}

function Get-PaneBorderColor {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PaneName,
        [Parameter(Mandatory = $true)]$State
    )

    if ($PaneName -eq $State.Ui.ActivePane) {
        return 'Cyan'
    }

    return 'DarkGray'
}

function Build-StatusBarRow {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Layout
    )

    $viewMode = Get-PropertyValueOrDefault -Object $State.Ui -Name 'ViewMode' -Default 'Pending'
    $viewBadge = "[$viewMode]"

    $filteredCount = $State.Derived.VisibleChangeIds.Count
    $totalCount    = if ($viewMode -eq 'Submitted') {
        $sub = Get-PropertyValueOrDefault -Object $State.Data -Name 'SubmittedChanges' -Default @()
        if ($null -eq $sub) { 0 } else { @($sub).Count }
    } else {
        $allChanges = Get-PropertyValueOrDefault -Object $State.Data -Name 'AllChanges' -Default @()
        if ($null -eq $allChanges) { 0 } else { @($allChanges).Count }
    }

    $markedCount = 0
    $markedProp  = $State.Query.PSObject.Properties['MarkedChangeIds']
    if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
        $markedCount = $markedProp.Value.Count
    }
    $markBadge = if ($markedCount -gt 0) { " $([char]0x25CF) Marked: $markedCount |" } else { '' }

    $workflowBadge = ''
    $lastResult    = Get-PropertyValueOrDefault -Object $State.Runtime -Name 'LastWorkflowResult' -Default $null
    if ($null -ne $lastResult) {
        $wfDone   = [int](Get-PropertyValueOrDefault -Object $lastResult -Name 'DoneCount'   -Default 0)
        $wfFailed = [int](Get-PropertyValueOrDefault -Object $lastResult -Name 'FailedCount' -Default 0)
        if ($wfFailed -gt 0) {
            $workflowBadge = " $([char]0x2717) $wfDone ok, $wfFailed failed |"
        } else {
            $workflowBadge = " $([char]0x2713) $wfDone done |"
        }
    }

    $expandHint  = if ((Get-PropertyValueOrDefault -Object $State.Ui -Name 'ExpandedChangelists' -Default $false)) { '[E] Collapse' } else { '[E] Expand' }
    $statusText  = "$viewBadge Filtered: $filteredCount/$totalCount |$markBadge$workflowBadge [F1] Help [1/2/3] View [Tab] Pane [Space] Filter [Enter] Describe $expandHint [F5] Reload [Q] Quit"
    $statusWidth = [Math]::Max(0, $Layout.StatusPane.W - 1)

    $segments = Write-ColorSegments -Segments @(@{
        Text = $statusText
        Color = 'DarkGray'
        BackgroundColor = ''
    }) -Width $statusWidth

    $statusSegments = foreach ($segment in $segments) {
        @{
            Text = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')
            Color = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Color' -Default 'Gray')
            BackgroundColor = ''
        }
    }

    $mergedSegments = Merge-AdjacentSegments -Segments $statusSegments
    $signature = Get-FrameRowSignature -Segments $mergedSegments

    return [pscustomobject]@{
        Y = $Layout.StatusPane.Y
        Segments = $mergedSegments
        Signature = $signature
    }
}

function Build-CommandModalRows {
    param(
        [Parameter(Mandatory = $true)]$CommandModal,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$MaxRows,
        [object]$ActiveWorkflow    = $null,
        [bool]$CancelRequested     = $false,   # M3.4
        [bool]$QuitRequested       = $false,   # M3.4
        [datetime]$StartedAt       = [datetime]::MinValue,  # M4: elapsed time
        [datetime]$CurrentTime     = [datetime]::MinValue
    )

    $borderColor    = 'DarkCyan'
    $isBusy         = [bool](Get-PropertyValueOrDefault   -Object $CommandModal -Name 'IsBusy'            -Default $false)
    $currentCommand = [string](Get-PropertyValueOrDefault -Object $CommandModal -Name 'CurrentCommand'    -Default '')
    $history        = @(Get-PropertyValueOrDefault        -Object $CommandModal -Name 'History'           -Default @())
    $timeoutMs      = [int](Get-PropertyValueOrDefault    -Object $CommandModal -Name 'CurrentTimeoutMs'  -Default 0)
    $indicatorGlyph = Get-BusyIndicatorGlyph -StartedAt $StartedAt -CurrentTime $CurrentTime
    $now            = if ($CurrentTime -ne [datetime]::MinValue) { $CurrentTime } else { Get-Date }

    # Box height: top + inner content rows + bottom border; minimum 4
    $boxHeight = [Math]::Max(4, [Math]::Min($MaxRows, 12))
    $innerRows = $boxHeight - 2

    $contentRows = [System.Collections.Generic.List[object]]::new()

    if ($isBusy) {
        # Workflow step progress row (shown when a workflow is active)
        if ($null -ne $ActiveWorkflow) {
            $done  = [int]$ActiveWorkflow.DoneCount
            $total = [int]$ActiveWorkflow.TotalCount
            $stepDisplay = if ($total -gt 0) { "(step $($done + 1)/$total)" } else { '' }
            $contentRows.Add(@(
                @{ Text = $indicatorGlyph + ' Working… '; Color = 'Yellow' },
                @{ Text = $stepDisplay;                   Color = 'DarkGray' }
            ))
        }
        # Cancel / quit banner row (M3.4)
        if ($CancelRequested -and $contentRows.Count -lt ($innerRows - 1)) {
            $contentRows.Add(@(@{ Text = [char]0x26A0 + ' Cancel requested — finishing current step…'; Color = 'Yellow' }))
        } elseif ($QuitRequested -and $contentRows.Count -lt ($innerRows - 1)) {
            $contentRows.Add(@(@{ Text = [char]0x26A0 + ' Will quit after current command…'; Color = 'Yellow' }))
        }
        # Currently running command row
        if ($contentRows.Count -lt ($innerRows - 1)) {
            $elapsedSec   = if ($StartedAt -ne [datetime]::MinValue) { [int](($now - $StartedAt).TotalSeconds) } else { 0 }
            $elapsedLabel = if ($elapsedSec -gt 0) { "  ($($elapsedSec)s)" } else { '' }
            $contentRows.Add(@(
                @{ Text = $indicatorGlyph + ' Running: '; Color = 'DarkGray' },
                @{ Text = $currentCommand;                Color = 'Yellow' },
                @{ Text = $elapsedLabel;                  Color = 'DarkGray' }
            ))
        }
    }

    foreach ($entry in $history) {
        if ($contentRows.Count -ge ($innerRows - 1)) { break }  # reserve 1 row for footer
        $ts           = ([datetime]$entry.StartedAt).ToString('HH:mm:ss')
        $outcome      = if (($entry.PSObject.Properties.Match('Outcome')).Count -gt 0) { [string]$entry.Outcome } else { if ([bool]$entry.Succeeded) { 'Completed' } else { 'Failed' } }
        switch ($outcome) {
            'Completed' { $tag = '[OK] '; $tagColor = 'Green'  }
            'TimedOut'  { $tag = '[TMO]'; $tagColor = 'Yellow' }
            'Cancelled' { $tag = '[CXL]'; $tagColor = 'Yellow' }
            default     { $tag = '[ERR]'; $tagColor = 'Red'    }
        }
        $durationMs   = [int]$entry.DurationMs
        $durationClass = if (($entry.PSObject.Properties.Match('DurationClass')).Count -gt 0) { [string]$entry.DurationClass } else { 'Normal' }
        $durationColor = switch ($durationClass) {
            'Critical' { 'Red'    }
            'Warning'  { 'Yellow' }
            'Info'     { 'Cyan'   }
            default    { 'Gray'   }
        }
        $cmdLine      = [string]$entry.CommandLine
        $contentRows.Add(@(
            @{ Text = "$ts "; Color = 'DarkGray' },
            @{ Text = $tag;   Color = $tagColor },
            @{ Text = " ${durationMs}ms"; Color = $durationColor },
            @{ Text = "  $cmdLine"; Color = 'Gray' }
        ))
        # For failed entries, append a detail row with the extracted error reason
        if ($outcome -in @('Failed', 'TimedOut') -and $contentRows.Count -lt ($innerRows - 1)) {
            $errMsg     = [string]$entry.ErrorText
            $stderrLine = ($errMsg -split '\r?\n' | Where-Object { $_ -match '^STDERR:' } | Select-Object -First 1)
            if ($stderrLine) {
                $errMsg = $stderrLine -replace '^STDERR:\s*', ''
            } else {
                $errMsg = ($errMsg -split '\r?\n' | Where-Object { $_ -ne '' } | Select-Object -Last 1)
            }
            if (-not [string]::IsNullOrWhiteSpace($errMsg)) {
                $contentRows.Add(@(@{ Text = "  $errMsg"; Color = 'DarkRed' }))
            }
        }
    }

    # Pad remaining inner rows with blank lines
    while ($contentRows.Count -lt ($innerRows - 1)) {
        $contentRows.Add(@(@{ Text = ''; Color = 'Gray' }))
    }

    # Footer
    $footerText  = if ($isBusy) {
        if ($CancelRequested) {
            '[' + [char]0x26A0 + '] Cancel requested — finishing current step…'
        } elseif ($QuitRequested) {
            '[' + [char]0x26A0 + '] Will quit after current command…'
        } else {
            $timeoutSec = if ($timeoutMs -gt 0) { [Math]::Round($timeoutMs / 1000) } else { 0 }
            $timeoutLabel = if ($timeoutSec -gt 0) { "  Timeout: ${timeoutSec}s" } else { '' }
            "[Esc] Cancel step  [Q] Quit after step${timeoutLabel}"
        }
    } else {
        '[Esc] Dismiss  [F12] Toggle  [Q] Quit'
    }
    $footerColor = if ($isBusy) {
        if ($CancelRequested -or $QuitRequested) { 'Yellow' } else { 'DarkCyan' }
    } else { 'DarkGray' }
    $contentRows.Add(@(@{ Text = $footerText; Color = $footerColor }))

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add((Build-BoxTopSegments    -Title '[p4 Commands]' -Width $Width -BorderColor $borderColor -TitleColor 'Cyan'))
    foreach ($row in $contentRows) {
        $rows.Add((Build-BorderedRowSegments -InnerSegments $row -Width $Width -BorderColor $borderColor))
    }
    $rows.Add((Build-BoxBottomSegments -Width $Width -BorderColor $borderColor))

    # Emit each row as a single (array) object — `return $rows.ToArray()` would unroll
    # both the outer list and each inner segment array, collapsing rows into individual
    # segments.  Write-Output -NoEnumerate preserves every row-array as one pipeline item.
    foreach ($row in $rows) {
        Write-Output -NoEnumerate $row
    }
}

function Build-HelpOverlayRows {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$MaxRows
    )

    $borderColor = 'DarkMagenta'
    $keyColor    = 'Cyan'
    $descColor   = 'Gray'
    $columnGap   = 2

    $helpLines = @(
        @{ Key = 'Tab';        Desc = 'Switch pane' },
        @{ Key = '↑ ↓';        Desc = 'Navigate' },
        @{ Key = 'PgUp/PgDn';  Desc = 'Page scroll' },
        @{ Key = 'Home/End';   Desc = 'Jump top/bottom' },
        @{ Key = 'Space';      Desc = 'Toggle filter' },
        @{ Key = 'M / Ins';    Desc = 'Mark/unmark current changelist' },
        @{ Key = 'Shift+M';    Desc = 'Mark all visible changelists' },
        @{ Key = 'C';          Desc = 'Clear all changelist marks' },
        @{ Key = 'Enter';      Desc = 'Describe CL' },
        @{ Key = 'E';          Desc = 'Expand/collapse rows' },
        @{ Key = 'H';          Desc = 'Hide unavailable filters' },
        @{ Key = '1 / 2';      Desc = 'Switch view (Pending/Submitted)' },
        @{ Key = 'L';          Desc = 'Load more (submitted view)' },
        @{ Key = 'F5';         Desc = 'Reload active view' },
        @{ Key = 'X / Del';    Desc = 'Delete focused CL / marked CLs' },
        @{ Key = '3 / F12';    Desc = 'Command log view' },
        @{ Key = 'F1 / Esc';   Desc = 'Close help' },
        @{ Key = 'Q';          Desc = 'Quit' }
    )

    $innerRows    = [Math]::Max(3, [Math]::Min($MaxRows - 2, $helpLines.Count))
    $displayLines = $helpLines | Select-Object -First $innerRows
    $maxKeyWidth  = (($displayLines | ForEach-Object { ([string]$_.Key).Length } | Measure-Object -Maximum).Maximum)

    $contentRows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $displayLines) {
        $key         = [string]$line.Key
        $desc        = [string]$line.Desc
        $paddingSize = [Math]::Max($columnGap, ($maxKeyWidth - $key.Length) + $columnGap)
        $padding     = ' ' * $paddingSize

        $contentRows.Add(@(
            @{ Text = $key;     Color = $keyColor  },
            @{ Text = $padding; Color = $descColor },
            @{ Text = $desc;    Color = $descColor }
        ))
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add((Build-BoxTopSegments -Title '[Help]' -Width $Width -BorderColor $borderColor -TitleColor 'Magenta'))
    foreach ($row in $contentRows) {
        $rows.Add((Build-BorderedRowSegments -InnerSegments $row -Width $Width -BorderColor $borderColor))
    }
    $rows.Add((Build-BoxBottomSegments -Width $Width -BorderColor $borderColor))

    foreach ($row in $rows) {
        Write-Output -NoEnumerate $row
    }
}

function Apply-HelpOverlay {
    param(
        [Parameter(Mandatory = $true)]$Frame,
        [Parameter(Mandatory = $true)][bool]$IsOpen
    )

    if (-not $IsOpen) { return $Frame }

    $width      = $Frame.Width
    $height     = $Frame.Height
    $modalWidth = [Math]::Max(4, [Math]::Min(50, $width - 4))
    $leftPad    = [Math]::Max(0, [Math]::Floor(($width - $modalWidth) / 2))
    $rightPad   = $width - $leftPad - $modalWidth

    $maxRows  = [Math]::Max(4, $height - 4)
    $helpRows = Build-HelpOverlayRows -Width $modalWidth -MaxRows $maxRows

    # Center vertically
    $modalStart = [Math]::Max(0, [Math]::Floor(($height - 1 - $helpRows.Count) / 2))

    $newRows = [object[]]::new($Frame.Rows.Count)
    for ($i = 0; $i -lt $Frame.Rows.Count; $i++) {
        $newRows[$i] = $Frame.Rows[$i]
    }

    for ($i = 0; $i -lt $helpRows.Count; $i++) {
        $frameRowIndex = $modalStart + $i
        if ($frameRowIndex -ge 0 -and $frameRowIndex -lt ($height - 1)) {
            $leftSeg  = @{ Text = (' ' * $leftPad);  Color = 'Black'; BackgroundColor = '' }
            $rightSeg = @{ Text = (' ' * $rightPad); Color = 'Black'; BackgroundColor = '' }
            $segs     = @($leftSeg) + @($helpRows[$i]) + @($rightSeg)
            $segs     = Merge-AdjacentSegments -Segments $segs
            $segs     = Resize-SegmentRow -Segments $segs -Width $width
            $segs     = Merge-AdjacentSegments -Segments $segs
            $newRows[$frameRowIndex] = [pscustomobject]@{
                Y         = $frameRowIndex
                Segments  = $segs
                Signature = Get-FrameRowSignature -Segments $segs
            }
        }
    }

    return [pscustomobject]@{
        Width  = $Frame.Width
        Height = $Frame.Height
        Rows   = $newRows
    }
}

function Build-MenuOverlayRows {
    <#
    .SYNOPSIS
        Builds rows for a menu overlay dropdown.
        Payload must have ActiveMenu (string), FocusIndex (int), MenuItems (array of computed items).
        Width is the total column width including border characters.
    #>
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $BORDER   = 'DarkCyan'
    $TITLE    = 'Cyan'
    $ITEM     = 'White'
    $FOCUSED  = 'Cyan'
    $DISABLED = 'DarkGray'
    $SEP      = 'DarkGray'

    $menuName  = [string]$Payload.ActiveMenu
    $focusIdx  = [int]$Payload.FocusIndex
    [object[]]$allItems = @($Payload.MenuItems)

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add((Build-BoxTopSegments -Title " $menuName " -Width $Width -BorderColor $BORDER -TitleColor $TITLE))

    $innerWidth = [Math]::Max(0, $Width - 2)
    $navIdx = 0
    foreach ($item in $allItems) {
        if ([bool]$item.IsSeparator) {
            $rows.Add(@(
                @{ Text = '├'; Color = $BORDER },
                @{ Text = ('─' * $innerWidth); Color = $SEP },
                @{ Text = '┤'; Color = $BORDER }
            ))
        } else {
            $isFocused = ($navIdx -eq $focusIdx)
            $isEnabled = [bool]$item.IsEnabled
            $label     = [string]$item.Label
            $accel     = [string]$item.Accelerator
            $accelStr  = if ([string]::IsNullOrEmpty($accel)) { '  ' } else { $accel + ' ' }
            $prefix    = if ($isFocused) { '▶ ' } else { '  ' }
            # innerWidth = prefix(2) + labelArea + accelStr.Length
            $labelArea = [Math]::Max(1, $innerWidth - 2 - $accelStr.Length)
            if ($label.Length -gt $labelArea) { $label = $label.Substring(0, $labelArea) }
            $gap       = $labelArea - $label.Length
            $innerText = $prefix + $label + (' ' * $gap) + $accelStr
            $color     = if ($isFocused -and $isEnabled) { $FOCUSED }
                         elseif (-not $isEnabled)         { $DISABLED }
                         else                             { $ITEM }
            $rows.Add(@(
                @{ Text = '│'; Color = $BORDER },
                @{ Text = $innerText; Color = $color },
                @{ Text = '│'; Color = $BORDER }
            ))
            $navIdx++
        }
    }
    $rows.Add((Build-BoxBottomSegments -Width $Width -BorderColor $BORDER))

    foreach ($row in $rows) {
        Write-Output -NoEnumerate $row
    }
}

function Apply-MenuOverlay {
    <#
    .SYNOPSIS
        Stamps the menu dropdown overlay onto the frame, anchored at the top of the screen.
        File menu opens at column 0; View menu opens at column 8.
    #>
    param(
        [Parameter(Mandatory = $true)]$Frame,
        $Payload
    )

    if ($null -eq $Payload) { return $Frame }

    $width    = $Frame.Width
    $menuName = [string]$Payload.ActiveMenu
    [object[]]$allItems = @($Payload.MenuItems)

    # Compute dropdown width from longest label: 2(prefix) + label + 1(gap) + 1(accel) + 1(space) + 2(borders)
    $maxLabelLen = 0
    foreach ($item in $allItems) {
        if (-not [bool]$item.IsSeparator) {
            $len = ([string]$item.Label).Length
            if ($len -gt $maxLabelLen) { $maxLabelLen = $len }
        }
    }
    $menuWidth = [Math]::Min([Math]::Max(22, $maxLabelLen + 7), $width)

    # Column anchor: File at 0, View at 8 (approximates a menu bar)
    $leftCol = 0
    if ($menuName -eq 'View') { $leftCol = [Math]::Min(8, [Math]::Max(0, $width - $menuWidth)) }

    $menuRows = @(Build-MenuOverlayRows -Payload $Payload -Width $menuWidth)

    $newRows = [object[]]::new($Frame.Rows.Count)
    for ($i = 0; $i -lt $Frame.Rows.Count; $i++) { $newRows[$i] = $Frame.Rows[$i] }

    for ($i = 0; $i -lt $menuRows.Count; $i++) {
        $ri = $i  # anchor at top row 0
        if ($ri -ge $Frame.Rows.Count) { break }
        $rightStart = $leftCol + $menuWidth
        $leftFill   = @{ Text = (' ' * $leftCol); Color = 'Black'; BackgroundColor = '' }
        $rightFill  = @{ Text = (' ' * ([Math]::Max(0, $width - $rightStart))); Color = 'Black'; BackgroundColor = '' }
        $segs = @($leftFill) + @($menuRows[$i]) + @($rightFill)
        $segs = Merge-AdjacentSegments -Segments $segs
        $segs = Resize-SegmentRow -Segments $segs -Width $width
        $segs = Merge-AdjacentSegments -Segments $segs
        $newRows[$ri] = [pscustomobject]@{
            Y         = $ri
            Segments  = $segs
            Signature = Get-FrameRowSignature -Segments $segs
        }
    }

    return [pscustomobject]@{
        Width  = $Frame.Width
        Height = $Frame.Height
        Rows   = $newRows
    }
}

function Build-ConfirmDialogRows {
    <#
    .SYNOPSIS
        Builds the row+segment content for a Yes/No confirmation dialog.
        Returns rows as arrays of segment hashtables, using the same box-drawing
        helpers as other overlay builders.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        $Payload   # OverlayPayload from state; may be $null for an empty dialog
    )

    $BORDER  = 'Yellow'
    $TITLE   = 'Yellow'
    $TEXT    = 'White'
    $DIM     = 'Gray'
    $FOOTER  = 'Cyan'

    # Extract payload fields with safe defaults
    $titleText    = if ($null -ne $Payload -and ($Payload.PSObject.Properties.Match('Title')).Count -gt 0)        { [string]$Payload.Title }        else { 'Confirm?' }
    $confirmLabel = if ($null -ne $Payload -and ($Payload.PSObject.Properties.Match('ConfirmLabel')).Count -gt 0) { [string]$Payload.ConfirmLabel } else { 'Y = confirm' }
    $cancelLabel  = if ($null -ne $Payload -and ($Payload.PSObject.Properties.Match('CancelLabel')).Count -gt 0)  { [string]$Payload.CancelLabel }  else { 'N / Esc = cancel' }

    # Arrays: declare typed so strict mode can't collapse empty results to $null
    [object[]]$summaryLines     = @()
    [object[]]$consequenceLines = @()
    if ($null -ne $Payload -and ($Payload.PSObject.Properties.Match('SummaryLines')).Count -gt 0     -and $null -ne $Payload.SummaryLines)     { $summaryLines     = @($Payload.SummaryLines)     }
    if ($null -ne $Payload -and ($Payload.PSObject.Properties.Match('ConsequenceLines')).Count -gt 0 -and $null -ne $Payload.ConsequenceLines) { $consequenceLines = @($Payload.ConsequenceLines) }

    $innerWidth = [Math]::Max(2, $Width - 2)

    # Helpers that produce a single segment of exactly innerWidth chars
    $padLine = {
        param([string]$text, [string]$color)
        $padded = if ($text.Length -ge $innerWidth) { $text.Substring(0, $innerWidth) } else { $text + (' ' * ($innerWidth - $text.Length)) }
        return @{ Text = $padded; Color = $color }
    }
    $centerLine = {
        param([string]$text, [string]$color)
        if ($text.Length -ge $innerWidth) { return @{ Text = $text.Substring(0, $innerWidth); Color = $color } }
        $l = [Math]::Floor(($innerWidth - $text.Length) / 2)
        $r = $innerWidth - $text.Length - $l
        return @{ Text = (' ' * $l) + $text + (' ' * $r); Color = $color }
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    # Top border with title
    $rows.Add((Build-BoxTopSegments -Title "[$titleText]" -Width $Width -BorderColor $BORDER -TitleColor $TITLE))
    # Empty row
    $rows.Add((Build-BorderedRowSegments -InnerSegments @((& $padLine '' $TEXT)) -Width $Width -BorderColor $BORDER))

    # Summary lines
    foreach ($line in $summaryLines) {
        $rows.Add((Build-BorderedRowSegments -InnerSegments @((& $padLine "  $line" $TEXT)) -Width $Width -BorderColor $BORDER))
    }

    # Consequence lines
    if ($consequenceLines.Count -gt 0) {
        $rows.Add((Build-BorderedRowSegments -InnerSegments @((& $padLine '' $TEXT)) -Width $Width -BorderColor $BORDER))
        foreach ($line in $consequenceLines) {
            $rows.Add((Build-BorderedRowSegments -InnerSegments @((& $padLine "  $line" $DIM)) -Width $Width -BorderColor $BORDER))
        }
    }

    # Empty row before footer
    $rows.Add((Build-BorderedRowSegments -InnerSegments @((& $padLine '' $TEXT)) -Width $Width -BorderColor $BORDER))

    # Footer: centered confirm + cancel labels
    $footerText = "$confirmLabel   $cancelLabel"
    $rows.Add((Build-BorderedRowSegments -InnerSegments @((& $centerLine $footerText $FOOTER)) -Width $Width -BorderColor $BORDER))

    # Bottom border
    $rows.Add((Build-BoxBottomSegments -Width $Width -BorderColor $BORDER))

    foreach ($row in $rows) {
        Write-Output -NoEnumerate $row
    }
}

function Apply-ConfirmDialogOverlay {
    <#
    .SYNOPSIS
        Overlays the confirmation dialog onto the frame.  Centers it both
        horizontally and vertically (above the status bar row).
    #>
    param(
        [Parameter(Mandatory = $true)]$Frame,
        $Payload   # OverlayPayload; may be $null
    )

    $width      = $Frame.Width
    $height     = $Frame.Height
    $modalWidth = [Math]::Max(20, [Math]::Min(52, $width - 4))
    $leftPad    = [Math]::Max(0, [Math]::Floor(($width - $modalWidth) / 2))
    $rightPad   = $width - $leftPad - $modalWidth

    $dialogRows = @(Build-ConfirmDialogRows -Width $modalWidth -Payload $Payload)

    # Center vertically (status bar is the last row, don't overlap it)
    $modalStart = [Math]::Max(0, [Math]::Floor(($height - 1 - $dialogRows.Count) / 2))

    $newRows = [object[]]::new($Frame.Rows.Count)
    for ($i = 0; $i -lt $Frame.Rows.Count; $i++) { $newRows[$i] = $Frame.Rows[$i] }

    for ($i = 0; $i -lt $dialogRows.Count; $i++) {
        $frameRowIndex = $modalStart + $i
        if ($frameRowIndex -ge 0 -and $frameRowIndex -lt ($height - 1)) {
            $leftSeg  = @{ Text = (' ' * $leftPad);  Color = 'Black'; BackgroundColor = '' }
            $rightSeg = @{ Text = (' ' * $rightPad); Color = 'Black'; BackgroundColor = '' }
            $segs     = @($leftSeg) + @($dialogRows[$i]) + @($rightSeg)
            $segs     = Merge-AdjacentSegments -Segments $segs
            $segs     = Resize-SegmentRow -Segments $segs -Width $width
            $segs     = Merge-AdjacentSegments -Segments $segs
            $newRows[$frameRowIndex] = [pscustomobject]@{
                Y         = $frameRowIndex
                Segments  = $segs
                Signature = Get-FrameRowSignature -Segments $segs
            }
        }
    }

    return [pscustomobject]@{
        Width  = $Frame.Width
        Height = $Frame.Height
        Rows   = $newRows
    }
}

function Apply-ModalOverlay {
    param(
        [Parameter(Mandatory = $true)]$Frame,
        [Parameter(Mandatory = $true)]$ModalPrompt,
        [object]$ActiveWorkflow  = $null,
        [bool]$CancelRequested   = $false,   # M3.4
        [bool]$QuitRequested     = $false,   # M3.4
        [datetime]$StartedAt     = [datetime]::MinValue,  # M4: elapsed time
        [datetime]$CurrentTime   = [datetime]::MinValue
    )

    $width      = $Frame.Width
    $height     = $Frame.Height
    $leftPad    = 2
    $modalWidth = [Math]::Max(4, $width - 4)
    $rightPad   = $width - $leftPad - $modalWidth

    $maxRows   = [Math]::Max(4, [Math]::Min([int][Math]::Floor($height / 3), 12))
    $modalRows = Build-CommandModalRows -CommandModal $ModalPrompt -Width $modalWidth -MaxRows $maxRows -ActiveWorkflow $ActiveWorkflow -CancelRequested $CancelRequested -QuitRequested $QuitRequested -StartedAt $StartedAt -CurrentTime $CurrentTime

    # Anchor above the status bar (last row)
    $modalStart = $height - 1 - $modalRows.Count
    if ($modalStart -lt 0) { $modalStart = 0 }

    $newRows = [object[]]::new($Frame.Rows.Count)
    for ($i = 0; $i -lt $Frame.Rows.Count; $i++) {
        $newRows[$i] = $Frame.Rows[$i]
    }

    for ($i = 0; $i -lt $modalRows.Count; $i++) {
        $frameRowIndex = $modalStart + $i
        if ($frameRowIndex -ge 0 -and $frameRowIndex -lt ($height - 1)) {  # never overwrite status bar
            $leftSeg  = @{ Text = (' ' * $leftPad);  Color = 'Black'; BackgroundColor = '' }
            $rightSeg = @{ Text = (' ' * $rightPad); Color = 'Black'; BackgroundColor = '' }
            $segs     = @($leftSeg) + @($modalRows[$i]) + @($rightSeg)
            # Build-BorderedRowSegments embeds inner segments as a nested array; flatten
            # before Resize-SegmentRow (which, unlike Write-ColorSegments, does not recurse).
            # NOTE: do NOT wrap in @() here — Merge-AdjacentSegments uses Write-Output -NoEnumerate,
            # so @(call) would re-wrap the returned array as a single element, producing Count=1.
            $segs     = Merge-AdjacentSegments -Segments $segs
            $segs     = Resize-SegmentRow -Segments $segs -Width $width
            $segs     = Merge-AdjacentSegments -Segments $segs
            $newRows[$frameRowIndex] = [pscustomobject]@{
                Y         = $frameRowIndex
                Segments  = $segs
                Signature = Get-FrameRowSignature -Segments $segs
            }
        }
    }

    return [pscustomobject]@{
        Width  = $Frame.Width
        Height = $Frame.Height
        Rows   = $newRows
    }
}

function Build-FilesStatusBarRow {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Layout
    )

    $sourceChange = Get-PropertyValueOrDefault -Object $State.Data  -Name 'FilesSourceChange' -Default ''
    $sourceKind   = Get-PropertyValueOrDefault -Object $State.Data  -Name 'FilesSourceKind'   -Default ''
    $fileCount    = if (($State.Derived.PSObject.Properties.Match('VisibleFileIndices')).Count -gt 0) { $State.Derived.VisibleFileIndices.Count } else { 0 }
    $filePos      = if ($fileCount -gt 0) { $State.Cursor.FileIndex + 1 } else { 0 }
    $filterText   = Get-PropertyValueOrDefault -Object $State.Query -Name 'FileFilterText' -Default ''
    $filterHint   = if (-not [string]::IsNullOrWhiteSpace($filterText)) { "  Filter: $filterText" } else { '' }
    $cacheKey     = "${sourceChange}:${sourceKind}"
    $fileCacheStatus      = Get-PropertyValueOrDefault -Object $State.Data -Name 'FileCacheStatus' -Default $null
    $cacheStatus          = if ($null -ne $fileCacheStatus -and $fileCacheStatus.ContainsKey($cacheKey)) { [string]$fileCacheStatus[$cacheKey] } else { 'NotLoaded' }
    $enrichmentHint       = if ($cacheStatus -in @('BaseReady', 'LoadingEnrichment')) { '  Content: loading…' } else { '' }
    $fileCache            = Get-PropertyValueOrDefault -Object $State.Data -Name 'FileCache' -Default $null
    $unresolvedCount      = 0
    if ($null -ne $fileCache -and $fileCache.ContainsKey($cacheKey)) {
        foreach ($f in @($fileCache[$cacheKey])) {
            if ([bool](Get-PropertyValueOrDefault -Object $f -Name 'IsUnresolved' -Default $false)) { $unresolvedCount++ }
        }
    }
    $unresolvedHint       = if ($unresolvedCount -gt 0) { "  $UNRESOLVED_GLYPH $unresolvedCount unresolved" } else { '' }

    $statusText  = "[Files] CL $sourceChange ($sourceKind)  $filePos/$fileCount${filterHint}${enrichmentHint}${unresolvedHint} | [/] Filter  [Esc/←] Back  [Tab] Pane  [F1] Help  [F5] Reload  [Q] Quit"
    $statusWidth = [Math]::Max(0, $Layout.StatusPane.W - 1)

    $seg  = @{ Text = $statusText; Color = 'DarkGray'; BackgroundColor = '' }
    $segs = Write-ColorSegments -Segments @($seg) -Width $statusWidth
    $segs = foreach ($s in @($segs)) {
        @{ Text            = [string](Get-PropertyValueOrDefault -Object $s -Name 'Text'            -Default '')
           Color           = [string](Get-PropertyValueOrDefault -Object $s -Name 'Color'           -Default 'Gray')
           BackgroundColor = '' }
    }
    $mergedSegs = Merge-AdjacentSegments -Segments $segs
    $signature  = Get-FrameRowSignature   -Segments $mergedSegs

    return [pscustomobject]@{
        Y         = $Layout.StatusPane.Y
        Segments  = $mergedSegs
        Signature = $signature
    }
}

function Build-FilesScreenFrame {
    <#
    .SYNOPSIS
        Builds the terminal frame for the Files screen.
    .DESCRIPTION
        Step 1 skeleton: left pane shows filter summary; top-right pane shows
        file list placeholder; bottom-right pane shows a file inspector
        placeholder. File rows are rendered in Step 2 once loading is wired up.
    #>
    param([Parameter(Mandatory = $true)]$State)

    $layout        = $State.Ui.Layout
    $filterBorder  = Get-PaneBorderColor -PaneName 'Filters'    -State $State
    $listBorder    = Get-PaneBorderColor -PaneName 'Changelists' -State $State
    $detailBorder  = 'DarkGray'

    $sourceChange  = Get-PropertyValueOrDefault -Object $State.Data  -Name 'FilesSourceChange' -Default ''
    $sourceKind    = Get-PropertyValueOrDefault -Object $State.Data  -Name 'FilesSourceKind'   -Default ''
    $filterText    = Get-PropertyValueOrDefault -Object $State.Query -Name 'FileFilterText'    -Default ''
    $fileCount     = if (($State.Derived.PSObject.Properties.Match('VisibleFileIndices')).Count -gt 0) { $State.Derived.VisibleFileIndices.Count } else { 0 }
    $isLoading     = ($State.Runtime.PSObject.Properties['PendingRequest']?.Value?.Kind -in @('LoadFiles', 'LoadFilesEnrichment'))
    $cacheKey      = "${sourceChange}:${sourceKind}"
    $fileCache     = Get-PropertyValueOrDefault -Object $State.Data -Name 'FileCache' -Default $null
    [object[]]$allFiles = if ($null -ne $fileCache -and $fileCache.ContainsKey($cacheKey)) { @($fileCache[$cacheKey]) } else { @() }
    $fileCacheStatus    = Get-PropertyValueOrDefault -Object $State.Data -Name 'FileCacheStatus' -Default $null
    $cacheStatus        = if ($null -ne $fileCacheStatus -and $fileCacheStatus.ContainsKey($cacheKey)) { [string]$fileCacheStatus[$cacheKey] } else { 'NotLoaded' }
    $isEnrichmentPending = $cacheStatus -in @('BaseReady', 'LoadingEnrichment')

    $selectedFile = $null
    if ($fileCount -gt 0 -and $State.Cursor.FileIndex -ge 0 -and $State.Cursor.FileIndex -lt $fileCount) {
        $selectedVisibleIndex = [int]$State.Derived.VisibleFileIndices[$State.Cursor.FileIndex]
        if ($selectedVisibleIndex -ge 0 -and $selectedVisibleIndex -lt $allFiles.Count) {
            $selectedFile = $allFiles[$selectedVisibleIndex]
        }
    }

    $listPaneTitle = "[Files — CL $sourceChange ($sourceKind)]"
    $rows          = [System.Collections.Generic.List[object]]::new($layout.Height)

    for ($globalRow = 0; $globalRow -lt $layout.FilterPane.H; $globalRow++) {
        # ── Left pane (filter) ───────────────────────────────────────────────
        $leftSegs = @()
        if ($globalRow -eq 0) {
            $leftSegs = Build-BoxTopSegments -Title '[Filter]' -Width $layout.FilterPane.W `
                            -BorderColor $filterBorder -TitleColor $filterBorder
        } elseif ($globalRow -eq ($layout.FilterPane.H - 1)) {
            $leftSegs = Build-BoxBottomSegments -Width $layout.FilterPane.W -BorderColor $filterBorder
        } else {
            $filterInnerRow = $globalRow - 1
            $inner = if ($filterInnerRow -eq 0) {
                if (-not [string]::IsNullOrWhiteSpace($filterText)) {
                    @(@{ Text = "🔍 $filterText"; Color = 'Cyan' })
                } else {
                    @(@{ Text = '(no filter)'; Color = 'DarkGray' })
                }
            } elseif ($filterInnerRow -eq 1) {
                @(@{ Text = ''; Color = 'Gray' })
            } elseif ($filterInnerRow -eq 2) {
                @(@{ Text = '[/] Set filter'; Color = 'DarkGray' })
            } elseif ($filterInnerRow -eq 3) {
                @(@{ Text = '[Esc] Clear'; Color = 'DarkGray' })
            } else {
                @(@{ Text = ''; Color = 'Gray' })
            }
            $leftSegs = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.FilterPane.W -BorderColor $filterBorder
        }

        # ── Right pane ───────────────────────────────────────────────────────
        $rightSegs            = @()
        $rightBackgroundColor = ''

        if ($globalRow -lt $layout.ListPane.H) {
            if ($globalRow -eq 0) {
                $rightSegs = Build-BoxTopSegments -Title $listPaneTitle -Width $layout.ListPane.W `
                                 -BorderColor $listBorder -TitleColor $listBorder
            } elseif ($globalRow -eq ($layout.ListPane.H - 1)) {
                $rightSegs = Build-BoxBottomSegments -Width $layout.ListPane.W -BorderColor $listBorder
            } else {
                $fileInnerRow = $globalRow - 1
                $fileIdx      = $State.Cursor.FileScrollTop + $fileInnerRow

                if ($fileCount -eq 0 -and $fileInnerRow -eq 0) {
                    $msg   = if ($isLoading) { 'Loading…' } else { '(no files loaded)' }
                    $inner = @(@{ Text = $msg; Color = 'DarkGray' })
                } elseif ($fileIdx -lt $fileCount) {
                    $visibleIndex = [int]$State.Derived.VisibleFileIndices[$fileIdx]
                    $file         = if ($visibleIndex -ge 0 -and $visibleIndex -lt $allFiles.Count) { $allFiles[$visibleIndex] } else { $null }
                    $isSelected = ($fileIdx -eq $State.Cursor.FileIndex)
                    $marker     = if ($isSelected) { $CURSOR_GLYPH } else { ' ' }
                    $mColor     = if ($isSelected) { 'Cyan' } else { 'DarkGray' }
                    $tColor     = if ($isSelected) { 'White' } else { 'Gray' }

                    if ($null -ne $file) {
                        $action       = [string](Get-PropertyValueOrDefault -Object $file -Name 'Action'       -Default '')
                        $fileName     = [string](Get-PropertyValueOrDefault -Object $file -Name 'FileName'     -Default '')
                        $depot        = [string](Get-PropertyValueOrDefault -Object $file -Name 'DepotPath'    -Default '')
                        $isUnresolved = [bool]  (Get-PropertyValueOrDefault -Object $file -Name 'IsUnresolved' -Default $false)
                        $isContentModified = [bool](Get-PropertyValueOrDefault -Object $file -Name 'IsContentModified' -Default $false)
                        if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = $depot }
                        $statusBadge = if ($isUnresolved) {
                            $UNRESOLVED_GLYPH + ' '
                        } elseif ($isContentModified) {
                            $MODIFIED_GLYPH + ' '
                        } elseif ($isEnrichmentPending) {
                            $PENDING_GLYPH + ' '
                        } else {
                            '  '
                        }
                        $statusBadgeColor = if ($isUnresolved) {
                            'Yellow'
                        } elseif ($isContentModified) {
                            'Cyan'
                        } elseif ($isEnrichmentPending) {
                            'DarkGray'
                        } else {
                            'DarkGray'
                        }
                        $inner = @(
                            @{ Text = $marker;                Color = $mColor           },
                            @{ Text = $statusBadge;           Color = $statusBadgeColor },
                            @{ Text = ('{0,-10}' -f $action); Color = 'DarkYellow'      },
                            @{ Text = $fileName;              Color = $tColor           }
                        )
                    } else {
                        $inner = @(
                            @{ Text = $marker; Color = $mColor },
                            @{ Text = ' (missing file entry)'; Color = 'Red' }
                        )
                    }

                    if ($isSelected) { $rightBackgroundColor = 'DarkCyan' }
                } else {
                    $inner = @(@{ Text = ''; Color = 'Gray' })
                }
                $rightSegs = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.ListPane.W -BorderColor $listBorder
            }
        } elseif ($globalRow -eq $layout.ListPane.H) {
            # Gap row between list pane and detail pane
            $rightSegs = @(@{ Text = (' ' * $layout.DetailPane.W); Color = 'DarkGray' })
        } else {
            # Detail pane rows — file inspector placeholder
            $detailLocalRow = $globalRow - $layout.ListPane.H - 1
            if ($detailLocalRow -eq 0) {
                $rightSegs = Build-BoxTopSegments -Title '[Inspector]' -Width $layout.DetailPane.W `
                                 -BorderColor $detailBorder -TitleColor $detailBorder
            } elseif ($detailLocalRow -eq ($layout.DetailPane.H - 1)) {
                $rightSegs = Build-BoxBottomSegments -Width $layout.DetailPane.W -BorderColor $detailBorder
            } else {
                $detailContentRow = $detailLocalRow - 1
                $inner = if ($null -eq $selectedFile) {
                    if ($detailContentRow -eq 0) {
                        @(@{ Text = if ($isLoading) { 'Loading…' } else { '(no file selected)' }; Color = 'DarkGray' })
                    } else {
                        @(@{ Text = ''; Color = 'Gray' })
                    }
                } else {
                    $selectedFileName  = [string](Get-PropertyValueOrDefault -Object $selectedFile -Name 'FileName'     -Default '')
                    $selectedDepot     = [string](Get-PropertyValueOrDefault -Object $selectedFile -Name 'DepotPath'    -Default '')
                    $selectedAction    = [string](Get-PropertyValueOrDefault -Object $selectedFile -Name 'Action'       -Default '')
                    $selectedType      = [string](Get-PropertyValueOrDefault -Object $selectedFile -Name 'FileType'     -Default '')
                    $selectedChange    = [string](Get-PropertyValueOrDefault -Object $selectedFile -Name 'Change'       -Default '')
                    $selectedUnresolvd = [bool]  (Get-PropertyValueOrDefault -Object $selectedFile -Name 'IsUnresolved' -Default $false)
                    $selectedContentModified = [bool](Get-PropertyValueOrDefault -Object $selectedFile -Name 'IsContentModified' -Default $false)
                    $resolveLabel      = if ($selectedUnresolvd) { 'unresolved' } else { 'clean' }
                    $resolveColor      = if ($selectedUnresolvd) { 'Yellow' } else { 'DarkGray' }
                    $contentLabel      = if ($selectedContentModified) { 'modified' } elseif ($isEnrichmentPending) { [char]0x2026 } else { 'clean' }
                    $contentColor      = if ($selectedContentModified) { 'Cyan' } elseif ($isEnrichmentPending) { 'DarkGray' } else { 'DarkGray' }
                    $resolveHintLine   = if ($selectedUnresolvd) {
                        @(@{ Text = '[R] Resolve  [Shift+R] Merge tool'; Color = 'DarkCyan' })
                    } else {
                        @(@{ Text = '';  Color = 'Gray' })
                    }
                    $inspectorLines = @(
                        @(@{ Text = "File: $selectedFileName"; Color = 'White'       }),
                        @(@{ Text = "Action: $selectedAction"; Color = 'DarkYellow' }),
                        @(@{ Text = "Type: $selectedType";     Color = 'Gray'        }),
                        @(@{ Text = "Change: $selectedChange"; Color = 'DarkGray'   }),
                        @(@{ Text = "Source: $sourceKind";     Color = 'DarkGray'   }),
                        @(@{ Text = "Resolve: $resolveLabel";  Color = $resolveColor }),
                        @(@{ Text = "Content: $contentLabel";  Color = $contentColor }),
                        $resolveHintLine,
                        @(@{ Text = $selectedDepot;            Color = 'Gray'        })
                    )
                    if ($detailContentRow -lt $inspectorLines.Count) {
                        $inspectorLines[$detailContentRow]
                    } else {
                        @(@{ Text = ''; Color = 'Gray' })
                    }
                }
                $rightSegs = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.DetailPane.W -BorderColor $detailBorder
            }
        }

        $row = Compose-FrameRow -Y $globalRow `
                   -LeftSegments $leftSegs   -LeftWidth  $layout.FilterPane.W `
                   -RightSegments $rightSegs -RightWidth $layout.ListPane.W `
                   -RightBackgroundColor $rightBackgroundColor `
                   -TotalWidth $layout.Width -IsLastRow $false
        $rows.Add($row)
    }

    $rows.Add((Build-FilesStatusBarRow -State $State -Layout $layout))

    return [pscustomobject]@{
        Width  = $layout.Width
        Height = $layout.Height
        Rows   = $rows.ToArray()
    }
}

function Build-CommandLogRowSegments {
    <#
    .SYNOPSIS
        Builds render segments for a single command log row.
    .DESCRIPTION
        Primary row: HH:mm:ss  ✓  p4 changes ...
        Duration and output count are shown in the expanded row (E key).
        The p4 global metadata flags (-ztag -Mj) are stripped from the display.
    #>
    param(
        [Parameter(Mandatory)]$Entry,           # CommandLog metadata item
        [Parameter(Mandatory)][bool]$IsSelected,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker
    )

    if ($null -eq $Entry) {
        if ($Marker -ne ' ' -and -not [string]::IsNullOrEmpty($Marker)) {
            Write-Output -NoEnumerate @(@{ Text = $Marker; Color = (Get-MarkerColor -Marker $Marker) })
        } else {
            Write-Output -NoEnumerate @()
        }
        return
    }

    $timeStr   = ([datetime]$Entry.StartedAt).ToString('HH:mm:ss')
    $outcome   = if (($Entry.PSObject.Properties.Match('Outcome')).Count -gt 0) { [string]$Entry.Outcome } else { if ([bool]$Entry.Succeeded) { 'Completed' } else { 'Failed' } }
    switch ($outcome) {
        'Completed' { $tag = [char]0x2713; $tagColor = 'Green'  }
        'TimedOut'  { $tag = [char]0x23F1; $tagColor = 'Yellow' }
        'Cancelled' { $tag = [char]0x26A0; $tagColor = 'Yellow' }
        default     { $tag = [char]0x2717; $tagColor = 'Red'    }
    }
    # Strip p4 global metadata flags added by Invoke-P4 (-ztag -Mj) so the user
    # sees only the meaningful subcommand and its arguments.
    $cmdLine   = ([string]$Entry.CommandLine) -replace ' -ztag -Mj', ''
    $mColor    = if ($IsSelected) { 'Cyan' } else { Get-MarkerColor -Marker $Marker }
    $durationClass = if (($Entry.PSObject.Properties.Match('DurationClass')).Count -gt 0) { [string]$Entry.DurationClass } else { 'Normal' }
    $textColor = if ($IsSelected) {
        'White'
    } else {
        switch ($durationClass) {
            'Critical' { 'Red'    }
            'Warning'  { 'Yellow' }
            'Info'     { 'Cyan'   }
            default    { 'Gray'   }
        }
    }

    Write-Output -NoEnumerate @(
        @{ Text = $Marker;         Color = $mColor    },
        @{ Text = " $timeStr ";    Color = 'DarkGray' },
        @{ Text = " $tag ";        Color = $tagColor  },
        @{ Text = $cmdLine;        Color = $textColor }
    )
}

function Build-CommandExpandedRowSegments {
    <#
    .SYNOPSIS
        Builds the expanded summary row shown below a command when it is expanded (E key).
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker
    )

    if ($null -eq $Entry) {
        Write-Output -NoEnumerate @()
        return
    }

    $mColor     = Get-MarkerColor -Marker $Marker
    $durationMs = [int]$Entry.DurationMs
    $summary    = [string]$Entry.SummaryLine

    if ([string]::IsNullOrWhiteSpace($summary)) {
        $outputCount = [int]$Entry.OutputCount
        $succeeded   = [bool]$Entry.Succeeded
        $errText     = [string]$Entry.ErrorText
        if (-not $succeeded -and -not [string]::IsNullOrWhiteSpace($errText)) {
            $firstLine = ($errText -split '\r?\n' | Where-Object { $_ -ne '' } | Select-Object -First 1)
            $summary   = "Error: $firstLine"
        } else {
            $summary = "$outputCount entries"
        }
    }

    Write-Output -NoEnumerate @(
        @{ Text = $Marker;              Color = $mColor     },
        @{ Text = "  ${durationMs}ms";  Color = 'Gray'      },
        @{ Text = "  $summary";         Color = 'DarkGray'  }
    )
}

function Build-CommandDetailContent {
    <#
    .SYNOPSIS
        Builds detail pane rows showing the selected command's full info + output preview.
    #>
    param([Parameter(Mandatory)]$State)

    $rows = [System.Collections.Generic.List[object]]::new()

    # Find selected command entry
    $selectedEntry = $null
    if (($State.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0 -and $State.Derived.VisibleCommandIds.Count -gt 0) {
        $idx    = [Math]::Max(0, [Math]::Min($State.Cursor.CommandIndex, $State.Derived.VisibleCommandIds.Count - 1))
        $cmdId  = [string]$State.Derived.VisibleCommandIds[$idx]
        $cmdLog = @()
        $clProp = $State.Runtime.PSObject.Properties['CommandLog']
        if ($null -ne $clProp -and $null -ne $clProp.Value) { $cmdLog = @($clProp.Value) }
        $selectedEntry = $cmdLog | Where-Object { [string]$_.CommandId -eq $cmdId } | Select-Object -First 1
    }

    if ($null -eq $selectedEntry) {
        $rows.Add(@(@{ Text = '(no command selected)'; Color = 'DarkGray' }))
        Write-Output -NoEnumerate $rows.ToArray()
        return
    }

    $timeStr = ([datetime]$selectedEntry.StartedAt).ToString('yyyy-MM-dd HH:mm:ss')
    $endStr  = ([datetime]$selectedEntry.EndedAt).ToString('HH:mm:ss')
    $rows.Add(@(
        @{ Text = [string]$selectedEntry.CommandLine; Color = 'Cyan' }
    ))
    $rows.Add(@(
        @{ Text = "${timeStr}–${endStr}"; Color = 'DarkGray' },
        @{ Text = "  $([int]$selectedEntry.DurationMs)ms"; Color = 'Gray' }
    ))
    $statusText  = if ([bool]$selectedEntry.Succeeded) { 'OK' } else { "Exit $([int]$selectedEntry.ExitCode)" }
    $statusColor = if ([bool]$selectedEntry.Succeeded) { 'Green' } else { 'Red' }
    $rows.Add(@(@{ Text = $statusText; Color = $statusColor }))

    if (-not [bool]$selectedEntry.Succeeded -and -not [string]::IsNullOrWhiteSpace([string]$selectedEntry.ErrorText)) {
        $errText = [string]$selectedEntry.ErrorText
        $firstLine = ($errText -split '\r?\n' | Where-Object { $_ -ne '' } | Select-Object -First 1)
        $rows.Add(@(@{ Text = $firstLine; Color = 'DarkRed' }))
    }

    $rows.Add(@(@{ Text = ''; Color = 'Gray' }))

    # Preview first ~10 output lines
    $cache = $State.Data.PSObject.Properties['CommandOutputCache']?.Value
    $cmdId = [string]$selectedEntry.CommandId
    if ($null -ne $cache -and $cache.ContainsKey($cmdId)) {
        $lines = @($cache[$cmdId])
        $preview = $lines | Select-Object -First 10
        foreach ($line in $preview) {
            $rows.Add(@(@{ Text = [string]$line; Color = 'Gray' }))
        }
        if ($lines.Count -gt 10) {
            $rows.Add(@(@{ Text = "… $($lines.Count - 10) more lines (→ to view all)"; Color = 'DarkGray' }))
        }
    }

    Write-Output -NoEnumerate $rows.ToArray()
}

function Build-CommandLogStatusBarRow {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Layout
    )

    $totalCount    = if (($State.Runtime.PSObject.Properties.Match('CommandLog')).Count -gt 0) { @($State.Runtime.CommandLog).Count } else { 0 }
    $filteredCount = if (($State.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) { $State.Derived.VisibleCommandIds.Count } else { 0 }
    $statusText    = "[Commands] Showing: $filteredCount/$totalCount | [F1] Help [1/2/3] View [Tab] Pane [Space] Filter [E] Expand [→] Output [F5] Reload [Q] Quit"
    $statusWidth   = [Math]::Max(0, $Layout.StatusPane.W - 1)

    $seg  = @{ Text = $statusText; Color = 'DarkGray'; BackgroundColor = '' }
    $segs = Write-ColorSegments -Segments @($seg) -Width $statusWidth
    $segs = foreach ($s in @($segs)) {
        @{ Text = [string](Get-PropertyValueOrDefault -Object $s -Name 'Text' -Default '')
           Color = [string](Get-PropertyValueOrDefault -Object $s -Name 'Color' -Default 'Gray')
           BackgroundColor = '' }
    }
    $merged    = Merge-AdjacentSegments -Segments $segs
    $signature = Get-FrameRowSignature   -Segments $merged

    return [pscustomobject]@{ Y = $Layout.StatusPane.Y; Segments = $merged; Signature = $signature }
}

function Build-CommandLogFrame {
    <#
    .SYNOPSIS
        Builds the terminal frame for the CommandLog view (ViewMode = 'CommandLog').
    .DESCRIPTION
        Left pane: command status/type filters.
        Top-right pane: command list (one row per command, oldest at top).
        Bottom-right pane: command detail + output preview.
    #>
    param([Parameter(Mandatory)]$State)

    $layout        = $State.Ui.Layout
    $filterBorder  = Get-PaneBorderColor -PaneName 'Filters'     -State $State
    $listBorder    = Get-PaneBorderColor -PaneName 'Changelists'  -State $State
    $detailBorder  = 'DarkGray'

    $filterViewRows = [Math]::Max(1, $layout.FilterPane.H - 2)
    $changeViewRows = [Math]::Max(1, $layout.ListPane.H - 2)
    $detailRows     = [Math]::Max(0, $layout.DetailPane.H - 2)

    $visibleCommandIds = if (($State.Derived.PSObject.Properties.Match('VisibleCommandIds')).Count -gt 0) { @($State.Derived.VisibleCommandIds) } else { @() }
    $commandCount      = $visibleCommandIds.Count

    # Build the expanded-commands set
    $expandedSet = $null
    $expProp = $State.Ui.PSObject.Properties['ExpandedCommands']
    if ($null -ne $expProp) { $expandedSet = $expProp.Value }

    # Build command entry lookup (newest-first storage → look up by CommandId)
    $cmdLogMap  = @{}
    $clProp     = $State.Runtime.PSObject.Properties['CommandLog']
    if ($null -ne $clProp -and $null -ne $clProp.Value) {
        foreach ($entry in @($clProp.Value)) {
            $cmdLogMap[[string]$entry.CommandId] = $entry
        }
    }

    $FilterThumb   = Get-ScrollThumb -TotalItems $State.Derived.VisibleFilters.Count -ViewRows $filterViewRows  -ScrollTop $State.Cursor.FilterScrollTop
    $commandThumb  = Get-ScrollThumb -TotalItems $commandCount                        -ViewRows $changeViewRows  -ScrollTop $State.Cursor.CommandScrollTop

    $detailContent = Build-CommandDetailContent -State $State

    $rows = [System.Collections.Generic.List[object]]::new($layout.Height)

    for ($globalRow = 0; $globalRow -lt $layout.FilterPane.H; $globalRow++) {
        # ── Left pane (filters) ────────────────────────────────────────────────
        $leftSegments = @()
        if ($globalRow -eq 0) {
            $leftSegments = Build-BoxTopSegments -Title '[Filters]' -Width $layout.FilterPane.W -BorderColor $filterBorder -TitleColor $filterBorder
        } elseif ($globalRow -eq ($layout.FilterPane.H - 1)) {
            $leftSegments = Build-BoxBottomSegments -Width $layout.FilterPane.W -BorderColor $filterBorder
        } else {
            $filterInnerRow  = $globalRow - 1
            $FilterIndex     = $State.Cursor.FilterScrollTop + $filterInnerRow
            $filterRow       = Get-FilterRowModel -State $State -FilterIndex $FilterIndex -FilterRowOffset $filterInnerRow -FilterThumb $FilterThumb
            $filterInnerSegs = Build-FilterSegments -FilterText $filterRow.Text -FilterMarker $filterRow.Marker -FilterColor $filterRow.Color
            $leftSegments    = Build-BorderedRowSegments -InnerSegments $filterInnerSegs -Width $layout.FilterPane.W -BorderColor $filterBorder
        }

        # ── Right pane ─────────────────────────────────────────────────────────
        $rightSegments        = @()
        $rightBackgroundColor = ''

        if ($globalRow -lt $layout.ListPane.H) {
            if ($globalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title '[Command Log]' -Width $layout.ListPane.W -BorderColor $listBorder -TitleColor $listBorder
            } elseif ($globalRow -eq ($layout.ListPane.H - 1)) {
                $rightSegments = Build-BoxBottomSegments -Width $layout.ListPane.W -BorderColor $listBorder
            } else {
                $cmdInnerRow = $globalRow - 1
                $cmdClIdx    = $State.Cursor.CommandScrollTop + $cmdInnerRow
                $cmdId       = if ($cmdClIdx -lt $commandCount) { [string]$visibleCommandIds[$cmdClIdx] } else { $null }
                $entry       = if ($null -ne $cmdId) { $cmdLogMap[$cmdId] } else { $null }

                $isSelected = ($cmdClIdx -lt $commandCount -and $State.Cursor.CommandIndex -eq $cmdClIdx -and $null -ne $entry)
                $cmdMarker  = ' '
                if ($null -ne $entry) {
                    if ($isSelected) {
                        $cmdMarker = $CURSOR_GLYPH
                    } elseif ($null -ne $commandThumb) {
                        if ($cmdInnerRow -ge $commandThumb.Start -and $cmdInnerRow -le $commandThumb.End) {
                            $cmdMarker = $SCROLLBAR_THUMB_GLYPH
                        } else {
                            $cmdMarker = $SCROLLBAR_TRACK_GLYPH
                        }
                    }
                } elseif ($cmdClIdx -eq 0 -and $commandCount -eq 0 -and $cmdInnerRow -eq 0) {
                    $inner         = @(@{ Text = '(no commands yet)'; Color = 'DarkGray' })
                    $rightSegments = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.ListPane.W -BorderColor $listBorder
                    $row = Compose-FrameRow -Y $globalRow -LeftSegments $leftSegments -LeftWidth $layout.FilterPane.W -RightSegments $rightSegments -RightWidth $layout.ListPane.W -RightBackgroundColor '' -TotalWidth $layout.Width -IsLastRow $false
                    $rows.Add($row)
                    continue
                } elseif ($null -ne $commandThumb) {
                    $cmdMarker = if ($cmdInnerRow -ge $commandThumb.Start -and $cmdInnerRow -le $commandThumb.End) { $SCROLLBAR_THUMB_GLYPH } else { $SCROLLBAR_TRACK_GLYPH }
                }

                if ($null -eq $entry) {
                    # Trailing row beyond the command list — show scrollbar track only
                    $inner = @(@{ Text = $cmdMarker; Color = (Get-MarkerColor -Marker $cmdMarker) })
                    $rightSegments = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.ListPane.W -BorderColor $listBorder
                } else {
                    $inner         = Build-CommandLogRowSegments -Entry $entry -IsSelected $isSelected -Marker $cmdMarker
                    $rightSegments = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.ListPane.W -BorderColor $listBorder
                    if ($isSelected) { $rightBackgroundColor = 'DarkCyan' }
                }
            }
        } elseif ($globalRow -eq $layout.ListPane.H) {
            $rightSegments = @(@{ Text = (' ' * $layout.DetailPane.W); Color = 'DarkGray' })
        } else {
            $detailLocalRow = $globalRow - $layout.ListPane.H - 1
            if ($detailLocalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title '[Command Details]' -Width $layout.DetailPane.W -BorderColor $detailBorder -TitleColor $detailBorder
            } elseif ($detailLocalRow -eq ($layout.DetailPane.H - 1)) {
                $rightSegments = Build-BoxBottomSegments -Width $layout.DetailPane.W -BorderColor $detailBorder
            } else {
                $detailContentRow = $detailLocalRow - 1
                $inner = if ($detailContentRow -lt $detailContent.Count) {
                    @($detailContent[$detailContentRow])
                } else {
                    @(@{ Text = ''; Color = 'Gray' })
                }
                $rightSegments = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.DetailPane.W -BorderColor $detailBorder
            }
        }

        $row = New-FrameRowFromFlatSegments -Y $globalRow -LeftSegments $leftSegments -RightSegments $rightSegments -RightBackgroundColor $rightBackgroundColor
        $rows.Add($row)
    }

    $rows.Add((Build-CommandLogStatusBarRow -State $State -Layout $layout))

    return [pscustomobject]@{
        Width  = $layout.Width
        Height = $layout.Height
        Rows   = $rows.ToArray()
    }
}

function Build-CommandOutputStatusBarRow {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Layout
    )

    $cmdId     = ''
    $cidProp   = $State.Runtime.PSObject.Properties['CommandOutputCommandId']
    if ($null -ne $cidProp -and $null -ne $cidProp.Value) { $cmdId = [string]$cidProp.Value }

    $outputCount = 0
    $cache = $State.Data.PSObject.Properties['CommandOutputCache']?.Value
    if ($null -ne $cache -and $cache.ContainsKey($cmdId)) { $outputCount = @($cache[$cmdId]).Count }

    $posIdx    = if (($State.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) { $State.Cursor.OutputIndex } else { 0 }
    $lineNum   = if ($outputCount -gt 0) { $posIdx + 1 } else { 0 }

    $statusText  = "[Output] Line $lineNum of $outputCount | [← / Esc] Back  [↑↓ PgUp/PgDn Home/End] Scroll  [F1] Help  [Q] Quit"
    $statusWidth = [Math]::Max(0, $Layout.StatusPane.W - 1)

    $seg  = @{ Text = $statusText; Color = 'DarkGray'; BackgroundColor = '' }
    $segs = Write-ColorSegments -Segments @($seg) -Width $statusWidth
    $segs = foreach ($s in @($segs)) {
        @{ Text = [string](Get-PropertyValueOrDefault -Object $s -Name 'Text' -Default '')
           Color = [string](Get-PropertyValueOrDefault -Object $s -Name 'Color' -Default 'Gray')
           BackgroundColor = '' }
    }
    $merged    = Merge-AdjacentSegments -Segments $segs
    $signature = Get-FrameRowSignature   -Segments $merged

    return [pscustomobject]@{ Y = $Layout.StatusPane.Y; Segments = $merged; Signature = $signature }
}

function Build-CommandOutputFrame {
    <#
    .SYNOPSIS
        Builds the terminal frame for the CommandOutput screen.
    .DESCRIPTION
        Left pane: blank (output filters are a future extension).
        Right pane: scrollable list of formatted output lines.
        Status bar: [← Back]  Line X of Y.
    #>
    param([Parameter(Mandatory)]$State)

    $layout       = $State.Ui.Layout
    $filterBorder = Get-PaneBorderColor -PaneName 'Filters'     -State $State
    $listBorder   = Get-PaneBorderColor -PaneName 'Changelists'  -State $State

    $cmdId = ''
    $cidProp = $State.Runtime.PSObject.Properties['CommandOutputCommandId']
    if ($null -ne $cidProp -and $null -ne $cidProp.Value) { $cmdId = [string]$cidProp.Value }

    $outputLines = @()
    $cache = $State.Data.PSObject.Properties['CommandOutputCache']?.Value
    if ($null -ne $cache -and $cache.ContainsKey($cmdId)) { $outputLines = @($cache[$cmdId]) }

    $outputCount  = $outputLines.Count
    $scrollTop    = if (($State.Cursor.PSObject.Properties.Match('OutputScrollTop')).Count -gt 0) { [int]$State.Cursor.OutputScrollTop } else { 0 }
    $viewRows     = [Math]::Max(1, $layout.FilterPane.H - 2)   # FilterPane.H = ListPane.H in current layout
    $outputThumb  = Get-ScrollThumb -TotalItems $outputCount -ViewRows $viewRows -ScrollTop $scrollTop

    # Build a short title from the command line
    $cmdTitle   = ''
    $cmdLogProp = $State.Runtime.PSObject.Properties['CommandLog']
    if ($null -ne $cmdLogProp -and $null -ne $cmdLogProp.Value) {
        $entry = @($cmdLogProp.Value) | Where-Object { [string]$_.CommandId -eq $cmdId } | Select-Object -First 1
        if ($null -ne $entry) {
            $cl = [string]$entry.CommandLine
            $cmdTitle = if ($cl.Length -gt 40) { $cl.Substring(0, 37) + '...' } else { $cl }
        }
    }
    $listPaneTitle = "[Output: $cmdTitle]"

    $rows = [System.Collections.Generic.List[object]]::new($layout.Height)

    for ($globalRow = 0; $globalRow -lt $layout.FilterPane.H; $globalRow++) {
        # ── Left pane (blank) ─────────────────────────────────────────────────
        $leftSegments = @()
        if ($globalRow -eq 0) {
            $leftSegments = Build-BoxTopSegments -Title '[Filter]' -Width $layout.FilterPane.W -BorderColor $filterBorder -TitleColor $filterBorder
        } elseif ($globalRow -eq ($layout.FilterPane.H - 1)) {
            $leftSegments = Build-BoxBottomSegments -Width $layout.FilterPane.W -BorderColor $filterBorder
        } else {
            $leftSegments = Build-BorderedRowSegments -InnerSegments @(@{ Text = ''; Color = 'Gray' }) -Width $layout.FilterPane.W -BorderColor $filterBorder
        }

        # ── Right pane (output lines) ─────────────────────────────────────────
        $rightSegments        = @()
        $rightBackgroundColor = ''

        if ($globalRow -lt $layout.ListPane.H) {
            if ($globalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title $listPaneTitle -Width $layout.ListPane.W -BorderColor $listBorder -TitleColor $listBorder
            } elseif ($globalRow -eq ($layout.ListPane.H - 1)) {
                $rightSegments = Build-BoxBottomSegments -Width $layout.ListPane.W -BorderColor $listBorder
            } else {
                $innerRow  = $globalRow - 1
                $lineIdx   = $scrollTop + $innerRow
                $marker    = ' '
                if ($outputCount -gt 0 -and $null -ne $outputThumb) {
                    $marker = if ($innerRow -ge $outputThumb.Start -and $innerRow -le $outputThumb.End) { $SCROLLBAR_THUMB_GLYPH } else { $SCROLLBAR_TRACK_GLYPH }
                }

                if ($outputCount -eq 0 -and $innerRow -eq 0) {
                    $inner = @(@{ Text = '(no output)'; Color = 'DarkGray' })
                } elseif ($lineIdx -lt $outputCount) {
                    $cursorOutputIndex = if (($State.Cursor.PSObject.Properties.Match('OutputIndex')).Count -gt 0) { $State.Cursor.OutputIndex } else { 0 }
                    $isSelected = ($lineIdx -eq $cursorOutputIndex)
                    $tColor     = if ($isSelected) { 'White' } else { 'Gray' }
                    $mColor     = if ($isSelected) { 'Cyan' } else { Get-MarkerColor -Marker $marker }
                    $line       = [string]$outputLines[$lineIdx]
                    $inner      = @(
                        @{ Text = $marker; Color = $mColor },
                        @{ Text = " $line"; Color = $tColor }
                    )
                    if ($isSelected) { $rightBackgroundColor = 'DarkCyan' }
                } else {
                    $inner = @(@{ Text = $marker; Color = (Get-MarkerColor -Marker $marker) })
                }
                $rightSegments = Build-BorderedRowSegments -InnerSegments $inner -Width $layout.ListPane.W -BorderColor $listBorder
            }
        } elseif ($globalRow -eq $layout.ListPane.H) {
            $rightSegments = @(@{ Text = (' ' * $layout.DetailPane.W); Color = 'DarkGray' })
        } else {
            # Detail pane — show command metadata
            $detailBorder   = 'DarkGray'
            $detailLocalRow = $globalRow - $layout.ListPane.H - 1
            if ($detailLocalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title '[Inspector]' -Width $layout.DetailPane.W -BorderColor $detailBorder -TitleColor $detailBorder
            } elseif ($detailLocalRow -eq ($layout.DetailPane.H - 1)) {
                $rightSegments = Build-BoxBottomSegments -Width $layout.DetailPane.W -BorderColor $detailBorder
            } else {
                $rightSegments = Build-BorderedRowSegments -InnerSegments @(@{ Text = ''; Color = 'Gray' }) -Width $layout.DetailPane.W -BorderColor $detailBorder
            }
        }

        $row = Compose-FrameRow -Y $globalRow -LeftSegments $leftSegments -LeftWidth $layout.FilterPane.W -RightSegments $rightSegments -RightWidth $layout.ListPane.W -RightBackgroundColor $rightBackgroundColor -TotalWidth $layout.Width -IsLastRow $false
        $rows.Add($row)
    }

    $rows.Add((Build-CommandOutputStatusBarRow -State $State -Layout $layout))

    return [pscustomobject]@{
        Width  = $layout.Width
        Height = $layout.Height
        Rows   = $rows.ToArray()
    }
}

function Build-FrameFromState {
    param(
        [Parameter(Mandatory = $true)]$State
    )

    $layout = $State.Ui.Layout
    $rows = [System.Collections.Generic.List[object]]::new($layout.Height)
    $renderFields = Get-RenderProfileFields -State $State

    $filterBorderColor = Get-PaneBorderColor -PaneName 'Filters' -State $State
    $changeBorderColor = Get-PaneBorderColor -PaneName 'Changelists' -State $State
    $detailBorderColor = 'DarkGray'

    $filterTitleColor = $filterBorderColor
    $changeTitleColor = $changeBorderColor
    $detailTitleColor = 'DarkGray'

    $filterViewRows = [Math]::Max(1, $layout.FilterPane.H - 2)
    $changeViewRows = [Math]::Max(1, $layout.ListPane.H - 2)
    $detailRows = [Math]::Max(0, $layout.DetailPane.H - 2)

    $expandedChangelists = $false
    if ($null -ne $State.Ui -and ($State.Ui.PSObject.Properties.Match('ExpandedChangelists')).Count -gt 0) {
        $expandedChangelists = [bool]$State.Ui.ExpandedChangelists
    }
    $rowsPerCl = if ($expandedChangelists -and $changeViewRows -ge 2) { 2 } else { 1 }

    $FilterThumb = Get-ScrollThumb -TotalItems $State.Derived.VisibleFilters.Count -ViewRows $filterViewRows -ScrollTop $State.Cursor.FilterScrollTop
    $changeThumb = Get-ScrollThumb -TotalItems ($State.Derived.VisibleChangeIds.Count * $rowsPerCl) -ViewRows $changeViewRows -ScrollTop ($State.Cursor.ChangeScrollTop * $rowsPerCl)

    # View-mode context for list pane
    $prepareStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $viewMode         = Get-PropertyValueOrDefault -Object $State.Ui   -Name 'ViewMode'         -Default 'Pending'
    $submittedHasMore = [bool](Get-PropertyValueOrDefault -Object $State.Data -Name 'SubmittedHasMore' -Default $false)
    $activeChanges    = Get-ActiveChangesList -State $State
    $changeLookup     = Get-ChangeLookupById -Changes $activeChanges
    $selectedChange   = $null
    if ($State.Derived.VisibleChangeIds.Count -gt 0) {
        $selectedIndex = [Math]::Min($State.Cursor.ChangeIndex, $State.Derived.VisibleChangeIds.Count - 1)
        $selectedId = [string]$State.Derived.VisibleChangeIds[$selectedIndex]
        if ($changeLookup.ContainsKey($selectedId)) {
            $selectedChange = $changeLookup[$selectedId]
        }
    }
    $detailSegments   = Build-DetailSegments -State $State -SelectedChange $selectedChange
    $listPaneTitle    = if ($viewMode -eq 'Submitted') { '[Submitted Changelists]' } else { '[Pending Changelists]' }
    $prepareStopwatch.Stop()
    Invoke-RenderProfileEvent -Stage 'Render.BuildFrame.Prepare' -DurationMs ([int]$prepareStopwatch.ElapsedMilliseconds) -Fields $renderFields

    $filterPaneRows = Get-FilterPaneRowSegments -State $State -Layout $layout -BorderColor $filterBorderColor -TitleColor $filterTitleColor -FilterThumb $FilterThumb

    $leftPaneMs = 0
    $rightPaneMs = 0
    $composeMs = 0

    for ($globalRow = 0; $globalRow -lt $layout.FilterPane.H; $globalRow++) {
        $leftStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $leftSegments = $filterPaneRows[$globalRow]
        $leftStopwatch.Stop()
        $leftPaneMs += [int]$leftStopwatch.ElapsedMilliseconds

        $rightStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $rightSegments = @()
        $rightBackgroundColor = ''
        if ($globalRow -lt $layout.ListPane.H) {
            if ($globalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title $listPaneTitle -Width $layout.ListPane.W -BorderColor $changeBorderColor -TitleColor $changeTitleColor
            } elseif ($globalRow -eq ($layout.ListPane.H - 1)) {
                # Bottom border — show load-more hint in submitted view when more pages exist
                if ($viewMode -eq 'Submitted' -and $submittedHasMore) {
                    $hint       = ' [L] Load more '
                    $innerWidth = [Math]::Max(0, $layout.ListPane.W - 2)
                    $padLeft    = [Math]::Max(0, [Math]::Floor(($innerWidth - $hint.Length) / 2))
                    $padRight   = [Math]::Max(0, $innerWidth - $padLeft - $hint.Length)
                    $rightSegments = @(
                        @{ Text = '╰';                Color = $changeBorderColor },
                        @{ Text = ('─' * $padLeft);   Color = $changeBorderColor },
                        @{ Text = $hint;              Color = 'Yellow'           },
                        @{ Text = ('─' * $padRight);  Color = $changeBorderColor },
                        @{ Text = '╯';                Color = $changeBorderColor }
                    )
                } else {
                    $rightSegments = Build-BoxBottomSegments -Width $layout.ListPane.W -BorderColor $changeBorderColor
                }
            } else {
                $changeInnerRow = $globalRow - 1
                $changeMarker = ' '
                $changeClIdx  = $State.Cursor.ChangeScrollTop + [Math]::Floor($changeInnerRow / $rowsPerCl)
                $changeRowType = $changeInnerRow % $rowsPerCl   # 0 = title row, 1 = detail row
                $cl = $null
                $changeRendered = $false
                if ($changeClIdx -lt $State.Derived.VisibleChangeIds.Count) {
                    $entryId = $State.Derived.VisibleChangeIds[$changeClIdx]
                    if ($changeLookup.ContainsKey([string]$entryId)) {
                        $cl = $changeLookup[[string]$entryId]
                    }
                    if ($State.Cursor.ChangeIndex -eq $changeClIdx) {
                        $changeMarker = $CURSOR_GLYPH
                    } elseif ($null -ne $changeThumb) {
                        if ($changeInnerRow -ge $changeThumb.Start -and $changeInnerRow -le $changeThumb.End) {
                            $changeMarker = $SCROLLBAR_THUMB_GLYPH
                        } else {
                            $changeMarker = $SCROLLBAR_TRACK_GLYPH
                        }
                    }
                } elseif ($changeClIdx -eq 0 -and $State.Derived.VisibleChangeIds.Count -eq 0 -and $changeInnerRow -eq 0) {
                    # Empty list placeholder
                    $placeholderText = if ($viewMode -eq 'Submitted') {
                        if ($submittedHasMore) { 'Loading... press [L] to load submitted changelists' } else { 'No submitted changelists found.' }
                    } else {
                        '(no matching changelists)'
                    }
                    $changeInnerSegments = @(@{ Text = $placeholderText; Color = 'DarkGray' })
                    $rightSegments   = Build-BorderedRowSegments -InnerSegments $changeInnerSegments -Width $layout.ListPane.W -BorderColor $changeBorderColor
                    $changeRendered  = $true
                } elseif ($null -ne $changeThumb) {
                    if ($changeInnerRow -ge $changeThumb.Start -and $changeInnerRow -le $changeThumb.End) {
                        $changeMarker = $SCROLLBAR_THUMB_GLYPH
                    } else {
                        $changeMarker = $SCROLLBAR_TRACK_GLYPH
                    }
                }

                if (-not $changeRendered) {
                    $isSelectedChange = ($changeClIdx -lt $State.Derived.VisibleChangeIds.Count -and $State.Cursor.ChangeIndex -eq $changeClIdx -and $null -ne $cl)
                    $isMarkedChange   = $false
                    if ($null -ne $cl) {
                        $markedProp = $State.Query.PSObject.Properties['MarkedChangeIds']
                        if ($null -ne $markedProp -and $null -ne $markedProp.Value) {
                            $isMarkedChange = $markedProp.Value.Contains([string]$cl.Id)
                        }
                    }
                    if ($changeRowType -eq 1) {
                        # Detail row (expanded mode): marker + details
                        $markerSeg = @{ Text = $changeMarker; Color = (Get-MarkerColor -Marker $changeMarker) }
                        if ($viewMode -eq 'Submitted') {
                            $changeInnerSegments = @($markerSeg) + @(Build-SubmittedChangeDetailSegments -Change $cl)
                        } else {
                            $changeInnerSegments = @($markerSeg) + @(Build-ChangeDetailSegments -Change $cl)
                        }
                    } else {
                        $changeInnerSegments = Build-ChangeSegments -Marker $changeMarker -Change $cl -IsSelected $isSelectedChange -IsMarked $isMarkedChange
                    }
                    $rightSegments = Build-BorderedRowSegments -InnerSegments $changeInnerSegments -Width $layout.ListPane.W -BorderColor $changeBorderColor
                }
            }
        } elseif ($globalRow -eq $layout.ListPane.H) {
            $rightSegments = @(
                @{ Text = (' ' * $layout.DetailPane.W); Color = 'DarkGray' }
            )
        } else {
            $detailLocalRow = $globalRow - $layout.ListPane.H - 1
            if ($detailLocalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title '[Details]' -Width $layout.DetailPane.W -BorderColor $detailBorderColor -TitleColor $detailTitleColor
            } elseif ($detailLocalRow -eq ($layout.DetailPane.H - 1)) {
                $rightSegments = Build-BoxBottomSegments -Width $layout.DetailPane.W -BorderColor $detailBorderColor
            } else {
                $detailContentRow = $detailLocalRow - 1
                $detailInnerSegments = @()
                if ($detailContentRow -lt $detailRows) {
                    if ($detailContentRow -lt $detailSegments.Count) {
                        $detailInnerSegments = @($detailSegments[$detailContentRow])
                    }
                }
                $rightSegments = Build-BorderedRowSegments -InnerSegments $detailInnerSegments -Width $layout.DetailPane.W -BorderColor $detailBorderColor
            }
        }
        $rightStopwatch.Stop()
        $rightPaneMs += [int]$rightStopwatch.ElapsedMilliseconds

        $composeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $row = New-FrameRowFromFlatSegments -Y $globalRow -LeftSegments $leftSegments -RightSegments $rightSegments -RightBackgroundColor $rightBackgroundColor
        $composeStopwatch.Stop()
        $composeMs += [int]$composeStopwatch.ElapsedMilliseconds
        $rows.Add($row)
    }

    Invoke-RenderProfileEvent -Stage 'Render.BuildFrame.LeftPane' -DurationMs $leftPaneMs -Fields $renderFields
    Invoke-RenderProfileEvent -Stage 'Render.BuildFrame.RightPane' -DurationMs $rightPaneMs -Fields $renderFields
    Invoke-RenderProfileEvent -Stage 'Render.BuildFrame.ComposeRows' -DurationMs $composeMs -Fields $renderFields

    $statusStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $rows.Add((Build-StatusBarRow -State $State -Layout $layout))
    $statusStopwatch.Stop()
    Invoke-RenderProfileEvent -Stage 'Render.BuildFrame.StatusBar' -DurationMs ([int]$statusStopwatch.ElapsedMilliseconds) -Fields $renderFields

    return [pscustomobject]@{
        Width = $layout.Width
        Height = $layout.Height
        Rows = $rows.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Runtime integrity checker.
# Disabled by default.  Enable with Enable-FrameIntegrityTest (called
# automatically when Start-P4Browser -IntegrityTest is used).
#
# When enabled, every rendered frame is checked for:
#   1. Correct total character width per row.
#   2. Box-drawing border glyphs at the expected column positions (Normal
#      layout only, skipping the status bar and the pane separator row).
#
# On the first violation a terminating error is thrown, halting the loop
# immediately so the bad frame state can be inspected.
# ---------------------------------------------------------------------------
function Test-FrameIntegrity {
    param(
        [Parameter(Mandatory = $true)]$Frame,
        [AllowNull()]$Layout = $null
    )

    if (-not $script:IntegrityTestEnabled) { return }

    $lastRowY     = $Frame.Height - 1
    # │   ╭   ╮   ╰   ╯
    $borderGlyphs = [char[]]@([char]0x2502, [char]0x256D, [char]0x256E, [char]0x2570, [char]0x256F)

    foreach ($row in @($Frame.Rows)) {
        # --- 1. Width check ---------------------------------------------------
        $actualWidth = 0
        foreach ($seg in @($row.Segments)) {
            $actualWidth += ([string](Get-PropertyValueOrDefault -Object $seg -Name 'Text' -Default '')).Length
        }

        $expectedWidth = if ($row.Y -eq $lastRowY) { [Math]::Max(0, $Frame.Width - 1) } else { $Frame.Width }
        if ($actualWidth -ne $expectedWidth) {
            throw "Frame integrity violation — Row $($row.Y): width $actualWidth != expected $expectedWidth"
        }

        # --- 2. Border-position check (Normal layout content rows only) -------
        if ($null -eq $Layout -or $Layout.Mode -ne 'Normal') { continue }
        if ($row.Y -eq $lastRowY) { continue }                     # status bar — no pane borders
        if ($row.Y -eq $Layout.ListPane.H) { continue }            # separator gap row — right side is blank

        $rowText = ''
        foreach ($seg in @($row.Segments)) {
            $rowText += [string](Get-PropertyValueOrDefault -Object $seg -Name 'Text' -Default '')
        }

        # Helper: extract a labelled character window around $col for diagnostics
        $windowFn = {
            param([string]$s, [int]$col, [int]$radius = 6)
            $from = [Math]::Max(0, $col - $radius)
            $to   = [Math]::Min($s.Length - 1, $col + $radius)
            $chars = for ($i = $from; $i -le $to; $i++) {
                $marker = if ($i -eq $col) { '*' } else { ' ' }
                "$marker$i='$($s[$i])'"
            }
            "[layout FilterPane.W=$($Layout.FilterPane.W) frame.Width=$($Frame.Width)] " + ($chars -join ' ')
        }

        # Column: right edge of FilterPane
        $colFilterRight = $Layout.FilterPane.W - 1
        if ($rowText.Length -gt $colFilterRight) {
            if ($borderGlyphs -notcontains $rowText[$colFilterRight]) {
                $ctx = & $windowFn $rowText $colFilterRight
                throw "Frame integrity violation — Row $($row.Y): FilterPane right border overwritten at col $colFilterRight (found '$($rowText[$colFilterRight])') $ctx"
            }
        }

        # Column: gap between panes (must be a plain space)
        $colGap = $Layout.FilterPane.W
        if ($rowText.Length -gt $colGap) {
            if ($rowText[$colGap] -ne ' ') {
                $ctx = & $windowFn $rowText $colGap
                throw "Frame integrity violation — Row $($row.Y): pane gap at col $colGap overwritten (found '$($rowText[$colGap])') $ctx"
            }
        }

        # Column: left edge of the right pane (list or detail)
        $colRightLeft = $Layout.FilterPane.W + 1
        if ($rowText.Length -gt $colRightLeft) {
            if ($borderGlyphs -notcontains $rowText[$colRightLeft]) {
                $ctx = & $windowFn $rowText $colRightLeft
                throw "Frame integrity violation — Row $($row.Y): right-pane left border overwritten at col $colRightLeft (found '$($rowText[$colRightLeft])') $ctx"
            }
        }
    }
}

function Enable-FrameIntegrityTest {
    $script:IntegrityTestEnabled = $true
}

# Test seam: suppress all [Console]::Write calls so render logic can run in unit
# tests without leaking TUI output to the terminal.  Reset via InModuleScope:
#   InModuleScope Render { $script:SuppressFlush = $false }
function Disable-RenderFlush {
    $script:SuppressFlush = $true
}

function Render-BrowserState {
    param(
        [Parameter(Mandatory = $true)]$State
    )

    $layout = $State.Ui.Layout

    if ($layout.Mode -eq 'TooSmall') {
        $script:PreviousFrame = $null
        Clear-Host
        Write-Host ("Window too small. Need at least {0}x{1}." -f $layout.MinWidth, $layout.MinHeight) -ForegroundColor Yellow
        Write-Host "Resize window. Press Q to quit." -ForegroundColor Yellow
        return
    }

    $renderFields = Get-RenderProfileFields -State $State
    $activeScreen = $renderFields['Screen']
    $viewMode = $renderFields['ViewMode']

    $buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextFrame = if ($activeScreen -eq 'Files') {
        Build-FilesScreenFrame -State $State
    } elseif ($activeScreen -eq 'RevisionGraph') {
        Build-GraphFrame -State $State
    } elseif ($activeScreen -eq 'CommandOutput') {
        Build-CommandOutputFrame -State $State
    } elseif ($viewMode -eq 'CommandLog') {
        Build-CommandLogFrame -State $State
    } else {
        Build-FrameFromState -State $State
    }
    $buildStopwatch.Stop()
    Invoke-RenderProfileEvent -Stage 'Render.BuildFrame' -DurationMs ([int]$buildStopwatch.ElapsedMilliseconds) -Fields $renderFields

    # Check structural integrity of the base frame before overlays are applied.
    # Overlays intentionally cover pane borders, so checking after them would
    # produce false positives.
    $integrityStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Test-FrameIntegrity -Frame $nextFrame -Layout $layout
    $integrityStopwatch.Stop()
    Invoke-RenderProfileEvent -Stage 'Render.IntegrityCheck' -DurationMs ([int]$integrityStopwatch.ElapsedMilliseconds) -Fields $renderFields

    $overlayMode    = [string](Get-PropertyValueOrDefault -Object $State.Ui -Name 'OverlayMode' -Default 'None')
    $overlayPayload = Get-PropertyValueOrDefault -Object $State.Ui -Name 'OverlayPayload' -Default $null
    $commandModal   = Get-PropertyValueOrDefault -Object $State.Runtime -Name 'ModalPrompt' -Default $null
    # Apply overlays in precedence order: help (lowest) → menu → confirm → command modal (highest)
    $overlayStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($overlayMode -eq 'Help') {
        $nextFrame = Apply-HelpOverlay -Frame $nextFrame -IsOpen $true
    }
    if ($overlayMode -eq 'Menu') {
        $nextFrame = Apply-MenuOverlay -Frame $nextFrame -Payload $overlayPayload
    }
    if ($overlayMode -eq 'Confirm') {
        $nextFrame = Apply-ConfirmDialogOverlay -Frame $nextFrame -Payload $overlayPayload
    }
    if ($null -ne $commandModal -and [bool](Get-PropertyValueOrDefault -Object $commandModal -Name 'IsOpen' -Default $false)) {
        $activeWorkflow  = Get-PropertyValueOrDefault -Object $State.Runtime -Name 'ActiveWorkflow'  -Default $null
        $cancelRequested = [bool](Get-PropertyValueOrDefault -Object $State.Runtime -Name 'CancelRequested' -Default $false)
        $quitRequested   = [bool](Get-PropertyValueOrDefault -Object $State.Runtime -Name 'QuitRequested'   -Default $false)
        $startedAt = if ($null -ne $State.Runtime.ActiveCommand) { [datetime]$State.Runtime.ActiveCommand.StartedAt } else { [datetime]::MinValue }
        $nextFrame = Apply-ModalOverlay -Frame $nextFrame -ModalPrompt $commandModal -ActiveWorkflow $activeWorkflow -CancelRequested $cancelRequested -QuitRequested $quitRequested -StartedAt $startedAt
    }
    $overlayStopwatch.Stop()
    Invoke-RenderProfileEvent -Stage 'Render.ApplyOverlays' -DurationMs ([int]$overlayStopwatch.ElapsedMilliseconds) -Fields $renderFields

    $diffStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $changedRows = Get-FrameDiff -PreviousFrame $script:PreviousFrame -NextFrame $nextFrame
    $diffStopwatch.Stop()
    $diffFields = @{}
    foreach ($key in $renderFields.Keys) { $diffFields[$key] = $renderFields[$key] }
    $diffFields['ChangedRowCount'] = @($changedRows).Count
    Invoke-RenderProfileEvent -Stage 'Render.FrameDiff' -DurationMs ([int]$diffStopwatch.ElapsedMilliseconds) -Fields $diffFields

    $flushStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $flushOk = Flush-FrameDiff -ChangedRows $changedRows -Frame $nextFrame
    $flushStopwatch.Stop()
    Invoke-RenderProfileEvent -Stage 'Render.FlushFrameDiff' -DurationMs ([int]$flushStopwatch.ElapsedMilliseconds) -Fields $diffFields
    if ($flushOk) {
        $script:PreviousFrame = $nextFrame
    }
}

Export-ModuleMember -Function Render-BrowserState, Flush-FrameDiff, Disable-RenderFlush, Reset-RenderState, Get-ScrollThumb, Build-ChangeDetailSegments, Build-SubmittedChangeDetailSegments, Build-HelpOverlayRows, Build-ConfirmDialogRows, Apply-ConfirmDialogOverlay, Build-MenuOverlayRows, Apply-MenuOverlay, Get-ActiveChangesList, Build-FilesScreenFrame, Build-FilesStatusBarRow, Build-CommandLogFrame, Build-CommandOutputFrame, Test-FrameIntegrity, Enable-FrameIntegrityTest, Set-RenderProfiler
