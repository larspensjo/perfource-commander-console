Set-StrictMode -Version Latest

$SCROLLBAR_THUMB_GLYPH = [char]0x2591
$SCROLLBAR_TRACK_GLYPH = [char]0x2502

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

function Test-IsSegmentLike {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $true }
    return $Value.PSObject.Properties.Match('Text').Count -gt 0
}

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

function Write-ColorSegments {
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][int]$Width,
        [switch]$NoEmit
    )

    if ($Width -le 0) {
        Write-Output -NoEnumerate @()
        return
    }

    $flat = @()
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        if ($segment -is [System.Collections.IEnumerable] -and -not ($segment -is [string]) -and -not (Test-IsSegmentLike -Value $segment)) {
            $flat += @(Write-ColorSegments -Segments $segment -Width 2147483647 -NoEmit)
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
        if ($Width -le 3) {
            $text = $text.Substring(0, $Width)
        } else {
            $text = $text.Substring(0, $Width - 3) + '...'
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
    $inner = Write-ColorSegments -Segments $InnerSegments -Width $innerWidth -NoEmit
    Write-Output -NoEnumerate @(
        @{ Text = '│'; Color = $BorderColor },
        @($inner),
        @{ Text = '│'; Color = $BorderColor }
    )
}

function Resize-SegmentRow {
    # Truncate or pad a row of multi-colored segments to exactly $Width characters,
    # preserving each segment's Color and BackgroundColor.
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][int]$Width
    )

    if ($Width -le 0) { return @() }

    $result = [System.Collections.Generic.List[object]]::new()
    $remaining = $Width

    foreach ($seg in @($Segments)) {
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

    $left = Write-ColorSegments -Segments $LeftSegments -Width ([Math]::Max(0, $LeftWidth)) -NoEmit
    $right = Write-ColorSegments -Segments $RightSegments -Width ([Math]::Max(0, $RightWidth)) -NoEmit

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

    $targetWidth = if ($IsLastRow) { [Math]::Max(0, $TotalWidth - 1) } else { [Math]::Max(0, $TotalWidth) }
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

    $parts = foreach ($segment in @($Segments)) {
        $color = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Color' -Default 'Gray')
        $background = [string](Get-PropertyValueOrDefault -Object $segment -Name 'BackgroundColor' -Default '')
        $text = [string](Get-PropertyValueOrDefault -Object $segment -Name 'Text' -Default '')
        "$color|$background|$text"
    }

    return ($parts -join ';')
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

                [Console]::Write($text)
            }
        }

        [Console]::ResetColor()
        return $true
    }
    catch {
        try { [Console]::ResetColor() } catch {}
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

function Get-IdeaById {
    param(
        [Parameter(Mandatory = $true)][object[]]$Ideas,
        [Parameter(Mandatory = $true)][string]$Id
    )

    return $Ideas | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Get-VisibleTagByIndex {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$TagIndex
    )

    if ($TagIndex -lt 0 -or $TagIndex -ge $State.Derived.VisibleTags.Count) {
        return $null
    }

    return $State.Derived.VisibleTags[$TagIndex]
}

function Get-PriorityColor {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Priority)

    switch ($Priority) {
        'P0' { return 'Red' }
        'P1' { return 'Red' }
        'P2' { return 'Yellow' }
        'P3' { return 'DarkCyan' }
        default { return 'Gray' }
    }
}

function Get-RiskColor {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Risk)

    switch ($Risk) {
        'H' { return 'Red' }
        'M' { return 'Yellow' }
        'L' { return 'DarkGray' }
        default { return 'Gray' }
    }
}

function Get-MarkerColor {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Marker)

    switch ($Marker) {
        '>' { return 'Cyan' }
        $SCROLLBAR_THUMB_GLYPH { return 'Gray' }
        $SCROLLBAR_TRACK_GLYPH { return 'DarkGray' }
        default { return 'DarkGray' }
    }
}

function Get-TagRowModel {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$TagIndex,
        [Parameter(Mandatory = $true)][int]$TagRowOffset,
        [AllowNull()]$TagThumb
    )

    $tagText = ''
    $tagColor = 'Gray'
    $tagMarker = ' '
    $tagItem = Get-VisibleTagByIndex -State $State -TagIndex $TagIndex

    if ($null -ne $tagItem) {
        if ($State.Cursor.TagIndex -eq $TagIndex) {
            $tagMarker = '>'
        } elseif ($null -ne $TagThumb) {
            if ($TagRowOffset -ge $TagThumb.Start -and $TagRowOffset -le $TagThumb.End) {
                $tagMarker = $SCROLLBAR_THUMB_GLYPH
            } else {
                $tagMarker = $SCROLLBAR_TRACK_GLYPH
            }
        }

        $isSelected = [bool](Get-PropertyValueOrDefault -Object $tagItem -Name 'IsSelected' -Default $false)
        $isSelectable = [bool](Get-PropertyValueOrDefault -Object $tagItem -Name 'IsSelectable' -Default $true)
        $tagName = [string](Get-PropertyValueOrDefault -Object $tagItem -Name 'Name' -Default '')
        $tagMatchCount = [string](Get-PropertyValueOrDefault -Object $tagItem -Name 'MatchCount' -Default '')
        $mark = if ($isSelected) { '[x]' } else { '[ ]' }
        $tagText = "$tagMarker $mark $tagName ($tagMatchCount)"

        if (-not $isSelectable -and -not $isSelected) {
            $tagColor = 'DarkGray'
        } elseif ($isSelected) {
            $tagColor = 'Green'
        }
    } elseif ($null -ne $TagThumb) {
        if ($TagRowOffset -ge $TagThumb.Start -and $TagRowOffset -le $TagThumb.End) {
            $tagMarker = $SCROLLBAR_THUMB_GLYPH
        } else {
            $tagMarker = $SCROLLBAR_TRACK_GLYPH
        }
        $tagText = $tagMarker
        $tagColor = 'DarkGray'
    }

    return [pscustomobject]@{
        Text = $tagText
        Color = $tagColor
        Marker = $tagMarker
    }
}

function Build-TagSegments {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TagText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TagMarker,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TagColor
    )

    if ($TagText.Length -eq 0) {
        Write-Output -NoEnumerate @()
        return
    }

    $markerLength = [Math]::Max(0, [Math]::Min($TagText.Length, $TagMarker.Length))
    if ($markerLength -le 0) {
        Write-Output -NoEnumerate @(
            @{ Text = $TagText; Color = $TagColor }
        )
        return
    }

    $restText = $TagText.Substring($markerLength)
    $segments = @(
        @{ Text = $TagText.Substring(0, $markerLength); Color = (Get-MarkerColor -Marker $TagMarker) }
    )

    if ($restText.Length -gt 0) {
        $segments += @{ Text = $restText; Color = $TagColor }
    }

    Write-Output -NoEnumerate $segments
}

function Build-IdeaSegments {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Marker,
        [AllowNull()]$Idea,
        [Parameter(Mandatory = $true)][bool]$IsSelected
    )

    if ($null -eq $Idea) {
        if ([string]::IsNullOrEmpty($Marker) -or $Marker -eq ' ') {
            Write-Output -NoEnumerate @()
            return
        }
        Write-Output -NoEnumerate @(
            @{ Text = $Marker; Color = (Get-MarkerColor -Marker $Marker) }
        )
        return
    }

    $ideaId = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Id' -Default '')
    $ideaTitle = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Title' -Default '')

    $markerColor = if ($IsSelected) { 'Cyan' } else { Get-MarkerColor -Marker $Marker }
    $titleColor = if ($IsSelected) { 'White' } else { 'Gray' }

    $segments = @(
        @{ Text = $Marker; Color = $markerColor },
        @{ Text = " $ideaId"; Color = 'DarkGray' }
    )

    if ($ideaTitle.Length -gt 0) {
        $segments += @{ Text = " $ideaTitle"; Color = $titleColor }
    }

    Write-Output -NoEnumerate $segments
}

function Build-DetailSegments {
    param([AllowNull()]$Idea)

    if ($null -eq $Idea) {
        Write-Output -NoEnumerate @(
            @(
                @{ Text = 'No matching ideas'; Color = 'DarkGray' }
            )
        )
        return
    }

    $ideaId = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Id' -Default '')
    $priority = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Priority' -Default '')
    $effort = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Effort' -Default '')
    $risk = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Risk' -Default '')
    $summary = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Summary' -Default '')
    $rationale = [string](Get-PropertyValueOrDefault -Object $Idea -Name 'Rationale' -Default '')
    $tagsRaw = Get-PropertyValueOrDefault -Object $Idea -Name 'Tags' -Default @()
    $tags = @($tagsRaw | ForEach-Object { [string]$_ })
    $tagsText = $tags -join ', '

    Write-Output -NoEnumerate @(
        @(
            @{ Text = 'ID: '; Color = 'DarkYellow' },
            @{ Text = $ideaId; Color = 'DarkGray' }
        ),
        @(
            @{ Text = 'Priority: '; Color = 'DarkYellow' },
            @{ Text = $priority; Color = (Get-PriorityColor -Priority $priority) },
            @{ Text = '  Effort: '; Color = 'DarkYellow' },
            @{ Text = $effort; Color = 'Gray' },
            @{ Text = '  Risk: '; Color = 'DarkYellow' },
            @{ Text = $risk; Color = (Get-RiskColor -Risk $risk) }
        ),
        @(
            @{ Text = 'Tags: '; Color = 'DarkYellow' },
            @{ Text = $tagsText; Color = 'Gray' }
        ),
        @(
            @{ Text = ''; Color = 'Gray' }
        ),
        @(
            @{ Text = 'Summary: '; Color = 'DarkYellow' },
            @{ Text = $summary; Color = 'Gray' }
        ),
        @(
            @{ Text = 'Rationale: '; Color = 'DarkYellow' },
            @{ Text = $rationale; Color = 'Gray' }
        )
    )
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

    $hideMode = if ($State.Ui.HideUnavailableTags) { 'On' } else { 'Off' }
    $statusText = "Total: $($State.Data.AllIdeas.Count) | Filtered: $($State.Derived.VisibleIdeaIds.Count) | Selected Tags: $($State.Query.SelectedTags.Count) | HideUnavailable: $hideMode | [Tab] Switch [Space] Toggle [PgUp/PgDn] Page [Home/End] Jump [F5] Reload [H] Hide [Q] Quit"
    $statusWidth = [Math]::Max(0, $Layout.StatusPane.W - 1)

    $segments = Write-ColorSegments -Segments @(@{
        Text = $statusText
        Color = 'DarkGray'
        BackgroundColor = ''
    }) -Width $statusWidth -NoEmit

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

function Build-FrameFromState {
    param(
        [Parameter(Mandatory = $true)]$State
    )

    $layout = $State.Ui.Layout
    $rows = [System.Collections.Generic.List[object]]::new($layout.Height)

    $tagBorderColor = Get-PaneBorderColor -PaneName 'Tags' -State $State
    $ideaBorderColor = Get-PaneBorderColor -PaneName 'Ideas' -State $State
    $detailBorderColor = 'DarkGray'

    $tagTitleColor = $tagBorderColor
    $ideaTitleColor = $ideaBorderColor
    $detailTitleColor = 'DarkGray'

    $tagViewRows = [Math]::Max(1, $layout.TagPane.H - 2)
    $ideaViewRows = [Math]::Max(1, $layout.ListPane.H - 2)
    $detailRows = [Math]::Max(0, $layout.DetailPane.H - 2)
    $tagThumb = Get-ScrollThumb -TotalItems $State.Derived.VisibleTags.Count -ViewRows $tagViewRows -ScrollTop $State.Cursor.TagScrollTop
    $ideaThumb = Get-ScrollThumb -TotalItems $State.Derived.VisibleIdeaIds.Count -ViewRows $ideaViewRows -ScrollTop $State.Cursor.IdeaScrollTop

    $detailSegments = @()
    if ($State.Derived.VisibleIdeaIds.Count -eq 0) {
        $detailSegments = Build-DetailSegments -Idea $null
    } else {
        $selectedId = $State.Derived.VisibleIdeaIds[[Math]::Min($State.Cursor.IdeaIndex, $State.Derived.VisibleIdeaIds.Count - 1)]
        $selectedIdea = Get-IdeaById -Ideas $State.Data.AllIdeas -Id $selectedId
        $detailSegments = Build-DetailSegments -Idea $selectedIdea
    }

    for ($globalRow = 0; $globalRow -lt $layout.TagPane.H; $globalRow++) {
        $leftSegments = @()
        if ($globalRow -eq 0) {
            $leftSegments = Build-BoxTopSegments -Title '[Tags]' -Width $layout.TagPane.W -BorderColor $tagBorderColor -TitleColor $tagTitleColor
        } elseif ($globalRow -eq ($layout.TagPane.H - 1)) {
            $leftSegments = Build-BoxBottomSegments -Width $layout.TagPane.W -BorderColor $tagBorderColor
        } else {
            $tagInnerRow = $globalRow - 1
            $tagIndex = $State.Cursor.TagScrollTop + $tagInnerRow
            $tagRow = Get-TagRowModel -State $State -TagIndex $tagIndex -TagRowOffset $tagInnerRow -TagThumb $tagThumb
            $tagInnerSegments = Build-TagSegments -TagText $tagRow.Text -TagMarker $tagRow.Marker -TagColor $tagRow.Color
            $leftSegments = Build-BorderedRowSegments -InnerSegments $tagInnerSegments -Width $layout.TagPane.W -BorderColor $tagBorderColor
        }

        $rightSegments = @()
        $rightBackgroundColor = ''
        if ($globalRow -lt $layout.ListPane.H) {
            if ($globalRow -eq 0) {
                $rightSegments = Build-BoxTopSegments -Title '[Ideas]' -Width $layout.ListPane.W -BorderColor $ideaBorderColor -TitleColor $ideaTitleColor
            } elseif ($globalRow -eq ($layout.ListPane.H - 1)) {
                $rightSegments = Build-BoxBottomSegments -Width $layout.ListPane.W -BorderColor $ideaBorderColor
            } else {
                $ideaInnerRow = $globalRow - 1
                $ideaMarker = ' '
                $ideaIndex = $State.Cursor.IdeaScrollTop + $ideaInnerRow
                $idea = $null
                if ($ideaIndex -lt $State.Derived.VisibleIdeaIds.Count) {
                    $ideaId = $State.Derived.VisibleIdeaIds[$ideaIndex]
                    $idea = Get-IdeaById -Ideas $State.Data.AllIdeas -Id $ideaId
                    if ($State.Cursor.IdeaIndex -eq $ideaIndex) {
                        $ideaMarker = '>'
                    } elseif ($null -ne $ideaThumb) {
                        if ($ideaInnerRow -ge $ideaThumb.Start -and $ideaInnerRow -le $ideaThumb.End) {
                            $ideaMarker = $SCROLLBAR_THUMB_GLYPH
                        } else {
                            $ideaMarker = $SCROLLBAR_TRACK_GLYPH
                        }
                    }
                } elseif ($null -ne $ideaThumb) {
                    if ($ideaInnerRow -ge $ideaThumb.Start -and $ideaInnerRow -le $ideaThumb.End) {
                        $ideaMarker = $SCROLLBAR_THUMB_GLYPH
                    } else {
                        $ideaMarker = $SCROLLBAR_TRACK_GLYPH
                    }
                }

                $isSelectedIdea = ($ideaIndex -lt $State.Derived.VisibleIdeaIds.Count -and $State.Cursor.IdeaIndex -eq $ideaIndex -and $null -ne $idea)
                $ideaInnerSegments = Build-IdeaSegments -Marker $ideaMarker -Idea $idea -IsSelected $isSelectedIdea
                $rightSegments = Build-BorderedRowSegments -InnerSegments $ideaInnerSegments -Width $layout.ListPane.W -BorderColor $ideaBorderColor
                if ($isSelectedIdea) {
                    $rightBackgroundColor = 'DarkCyan'
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

        $row = Compose-FrameRow -Y $globalRow -LeftSegments $leftSegments -LeftWidth $layout.TagPane.W -RightSegments $rightSegments -RightWidth $layout.ListPane.W -RightBackgroundColor $rightBackgroundColor -TotalWidth $layout.Width -IsLastRow $false
        $rows.Add($row)
    }

    $rows.Add((Build-StatusBarRow -State $State -Layout $layout))

    return [pscustomobject]@{
        Width = $layout.Width
        Height = $layout.Height
        Rows = $rows.ToArray()
    }
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

    $nextFrame = Build-FrameFromState -State $State
    $changedRows = Get-FrameDiff -PreviousFrame $script:PreviousFrame -NextFrame $nextFrame
    $flushOk = Flush-FrameDiff -ChangedRows $changedRows -Frame $nextFrame
    if ($flushOk) {
        $script:PreviousFrame = $nextFrame
    }
}

Export-ModuleMember -Function Render-BrowserState, Get-ScrollThumb
