$modulePath = Join-Path $PSScriptRoot '..\tui\Render.psm1'
Import-Module $modulePath -Force

function New-RenderTestState {
    param(
        [int]$Width = 80,
        [int]$Height = 20,
        [object[]]$VisibleChangeIds = @('FI-1', 'FI-2'),
        [int]$ChangeIndex = 0,
        [int]$ChangeScrollTop = 0
    )

    $SelectedFilters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$SelectedFilters.Add('alpha')

    $changes = @(
        [pscustomobject]@{
            Id = 'FI-1'
            Title = 'First idea'
            Priority = 'P2'
            Effort = 'M'
            Risk = 'L'
            Filters = @('alpha')
            Summary = 'Summary one'
            Rationale = 'Rationale one'
        },
        [pscustomobject]@{
            Id = 'FI-2'
            Title = 'Second idea'
            Priority = 'P0'
            Effort = 'H'
            Risk = 'H'
            Filters = @('beta')
            Summary = 'Summary two'
            Rationale = 'Rationale two'
        },
        [pscustomobject]@{
            Id = 'FI-3'
            Title = 'Third idea'
            Priority = 'P3'
            Effort = 'L'
            Risk = 'M'
            Filters = @('gamma')
            Summary = 'Summary three'
            Rationale = 'Rationale three'
        }
    )

    $contentHeight = $Height - 1
    $listHeight = 9
    $detailHeight = $contentHeight - $listHeight - 1
    $layout = [pscustomobject]@{
        Mode = 'Normal'
        Width = $Width
        Height = $Height
        FilterPane = [pscustomobject]@{ X = 0; Y = 0; W = 24; H = $contentHeight }
        ListPane = [pscustomobject]@{ X = 25; Y = 0; W = 55; H = $listHeight }
        DetailPane = [pscustomobject]@{ X = 25; Y = ($listHeight + 1); W = 55; H = $detailHeight }
        StatusPane = [pscustomobject]@{ X = 0; Y = $contentHeight; W = $Width; H = 1 }
    }

    return [pscustomobject]@{
        Data = [pscustomobject]@{
            AllChanges = $changes
            AllFilters = @('alpha', 'beta', 'gamma')
        }
        Ui = [pscustomobject]@{
            ActivePane = 'Changelists'
            IsMaximized = $false
            HideUnavailableFilters = $false
            ExpandedChangelists = $false
            Layout = $layout
        }
        Query = [pscustomobject]@{
            SelectedFilters = $SelectedFilters
            SearchText = ''
            SearchMode = 'None'
            SortMode = 'Default'
        }
        Derived = [pscustomobject]@{
            VisibleChangeIds = @($VisibleChangeIds)
            VisibleFilters = @(
                [pscustomobject]@{ Name = 'alpha'; MatchCount = 1; IsSelected = $true; IsSelectable = $true },
                [pscustomobject]@{ Name = 'beta'; MatchCount = 1; IsSelected = $false; IsSelectable = $true },
                [pscustomobject]@{ Name = 'gamma'; MatchCount = 1; IsSelected = $false; IsSelectable = $true }
            )
        }
        Cursor = [pscustomobject]@{
            FilterIndex = 0
            FilterScrollTop = 0
            ChangeIndex = $ChangeIndex
            ChangeScrollTop = $ChangeScrollTop
        }
        Runtime = [pscustomobject]@{
            IsRunning = $true
            LastError = $null
            DeleteChangeId = $null
            CommandModal = [pscustomobject]@{
                IsOpen         = $false
                IsBusy         = $false
                CurrentCommand = ''
                History        = @()
            }
        }
    }
}

Describe 'Get-ScrollThumb' {

    It 'returns null when content fits viewport' {
        $thumb = Get-ScrollThumb -TotalItems 10 -ViewRows 10 -ScrollTop 0
        $thumb | Should -BeNullOrEmpty
    }

    It 'returns thumb with min size and bounded range' {
        $thumb = Get-ScrollThumb -TotalItems 100 -ViewRows 10 -ScrollTop 0
        $thumb.Size | Should -BeGreaterThan 0
        $thumb.Start | Should -BeGreaterOrEqual 0
        $thumb.End | Should -BeLessThan 10
    }

    It 'moves thumb downward when scroll top increases' {
        $topThumb = Get-ScrollThumb -TotalItems 100 -ViewRows 10 -ScrollTop 0
        $midThumb = Get-ScrollThumb -TotalItems 100 -ViewRows 10 -ScrollTop 45
        $midThumb.Start | Should -BeGreaterThan $topThumb.Start
    }

    It 'clamps thumb at bottom when scroll top exceeds max' {
        $thumb = Get-ScrollThumb -TotalItems 40 -ViewRows 10 -ScrollTop 999
        $thumb.End | Should -Be 9
    }
}

Describe 'Frame helpers' {
    InModuleScope 'Render' {
        BeforeAll {
            function New-RenderStateFixture {
                param(
                    [int]$Width = 80,
                    [int]$Height = 20,
                    [object[]]$VisibleChangeIds = @('FI-1', 'FI-2'),
                    [int]$ChangeIndex = 0,
                    [int]$ChangeScrollTop = 0
                )

                $SelectedFilters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                [void]$SelectedFilters.Add('alpha')

                $changes = @(
                    [pscustomobject]@{
                        Id = 'FI-1'
                        Title = 'First idea'
                        Priority = 'P2'
                        Effort = 'M'
                        Risk = 'L'
                        Filters = @('alpha')
                        Summary = 'Summary one'
                        Rationale = 'Rationale one'
                    },
                    [pscustomobject]@{
                        Id = 'FI-2'
                        Title = 'Second idea'
                        Priority = 'P0'
                        Effort = 'H'
                        Risk = 'H'
                        Filters = @('beta')
                        Summary = 'Summary two'
                        Rationale = 'Rationale two'
                    },
                    [pscustomobject]@{
                        Id = 'FI-3'
                        Title = 'Third idea'
                        Priority = 'P3'
                        Effort = 'L'
                        Risk = 'M'
                        Filters = @('gamma')
                        Summary = 'Summary three'
                        Rationale = 'Rationale three'
                    }
                )

                $contentHeight = $Height - 1
                $listHeight = 9
                $detailHeight = $contentHeight - $listHeight - 1
                $layout = [pscustomobject]@{
                    Mode = 'Normal'
                    Width = $Width
                    Height = $Height
                    FilterPane = [pscustomobject]@{ X = 0; Y = 0; W = 24; H = $contentHeight }
                    ListPane = [pscustomobject]@{ X = 25; Y = 0; W = 55; H = $listHeight }
                    DetailPane = [pscustomobject]@{ X = 25; Y = ($listHeight + 1); W = 55; H = $detailHeight }
                    StatusPane = [pscustomobject]@{ X = 0; Y = $contentHeight; W = $Width; H = 1 }
                }

                return [pscustomobject]@{
                    Data = [pscustomobject]@{
                        AllChanges = $changes
                        AllFilters = @('alpha', 'beta', 'gamma')
                    }
                    Ui = [pscustomobject]@{
                        ActivePane = 'Changelists'
                        IsMaximized = $false
                        HideUnavailableFilters = $false
                        ExpandedChangelists = $false
                        Layout = $layout
                    }
                    Query = [pscustomobject]@{
                        SelectedFilters = $SelectedFilters
                        SearchText = ''
                        SearchMode = 'None'
                        SortMode = 'Default'
                    }
                    Derived = [pscustomobject]@{
                        VisibleChangeIds = @($VisibleChangeIds)
                        VisibleFilters = @(
                            [pscustomobject]@{ Name = 'alpha'; MatchCount = 1; IsSelected = $true; IsSelectable = $true },
                            [pscustomobject]@{ Name = 'beta'; MatchCount = 1; IsSelected = $false; IsSelectable = $true },
                            [pscustomobject]@{ Name = 'gamma'; MatchCount = 1; IsSelected = $false; IsSelectable = $true }
                        )
                    }
                    Cursor = [pscustomobject]@{
                        FilterIndex = 0
                        FilterScrollTop = 0
                        ChangeIndex = $ChangeIndex
                        ChangeScrollTop = $ChangeScrollTop
                    }
                    Runtime = [pscustomobject]@{
                        IsRunning = $true
                        LastError = $null
                        DeleteChangeId = $null
                        CommandModal = [pscustomobject]@{
                            IsOpen         = $false
                            IsBusy         = $false
                            CurrentCommand = ''
                            History        = @()
                        }
                    }
                }
            }
        }


        Context 'Merge-AdjacentSegments' {
            It 'merges neighbors with matching foreground and background' {
                $segments = @(
                    @{ Text = 'A'; Color = 'Gray'; BackgroundColor = '' },
                    @{ Text = 'B'; Color = 'Gray'; BackgroundColor = '' },
                    @{ Text = 'C'; Color = 'Red'; BackgroundColor = '' }
                )
                $merged = Merge-AdjacentSegments -Segments $segments
                $merged.Count | Should -Be 2
                $merged[0].Text | Should -Be 'AB'
                $merged[1].Text | Should -Be 'C'
            }

            It 'does not merge when foreground differs' {
                $segments = @(
                    @{ Text = 'A'; Color = 'Gray'; BackgroundColor = '' },
                    @{ Text = 'B'; Color = 'White'; BackgroundColor = '' }
                )
                (Merge-AdjacentSegments -Segments $segments).Count | Should -Be 2
            }

            It 'does not merge when background differs' {
                $segments = @(
                    @{ Text = 'A'; Color = 'Gray'; BackgroundColor = '' },
                    @{ Text = 'B'; Color = 'Gray'; BackgroundColor = 'DarkCyan' }
                )
                (Merge-AdjacentSegments -Segments $segments).Count | Should -Be 2
            }

            It 'returns single segment unchanged' {
                $single = @(@{ Text = 'Only'; Color = 'Gray'; BackgroundColor = '' })
                $merged = Merge-AdjacentSegments -Segments $single
                $merged.Count | Should -Be 1
                $merged[0].Text | Should -Be 'Only'
            }

            It 'returns empty output for empty input' {
                (Merge-AdjacentSegments -Segments @()).Count | Should -Be 0
            }
        }

        Context 'Get-FrameRowSignature' {
            It 'returns identical signatures for identical rows' {
                $segments = @(
                    @{ Text = 'A'; Color = 'Gray'; BackgroundColor = '' },
                    @{ Text = 'B'; Color = 'Red'; BackgroundColor = 'DarkCyan' }
                )
                (Get-FrameRowSignature -Segments $segments) | Should -Be (Get-FrameRowSignature -Segments $segments)
            }

            It 'changes when text changes' {
                $a = @(@{ Text = 'One'; Color = 'Gray'; BackgroundColor = '' })
                $b = @(@{ Text = 'Two'; Color = 'Gray'; BackgroundColor = '' })
                (Get-FrameRowSignature -Segments $a) | Should -Not -Be (Get-FrameRowSignature -Segments $b)
            }

            It 'changes when color changes' {
                $a = @(@{ Text = 'One'; Color = 'Gray'; BackgroundColor = '' })
                $b = @(@{ Text = 'One'; Color = 'White'; BackgroundColor = '' })
                (Get-FrameRowSignature -Segments $a) | Should -Not -Be (Get-FrameRowSignature -Segments $b)
            }

            It 'changes when background changes' {
                $a = @(@{ Text = 'One'; Color = 'Gray'; BackgroundColor = '' })
                $b = @(@{ Text = 'One'; Color = 'Gray'; BackgroundColor = 'DarkCyan' })
                (Get-FrameRowSignature -Segments $a) | Should -Not -Be (Get-FrameRowSignature -Segments $b)
            }

            It 'encodes empty background as an empty field' {
                $signature = Get-FrameRowSignature -Segments @(@{ Text = 'X'; Color = 'Gray'; BackgroundColor = '' })
                $signature | Should -Be 'Gray||X'
            }
        }

        Context 'Get-FrameDiff' {
            It 'returns all rows when previous frame is null' {
                $next = [pscustomobject]@{
                    Width = 10
                    Height = 2
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() }
                    )
                }
                (Get-FrameDiff -PreviousFrame $null -NextFrame $next).Count | Should -Be 2
            }

            It 'returns all rows when width differs' {
                $previous = [pscustomobject]@{
                    Width = 9
                    Height = 2
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() }
                    )
                }
                $next = [pscustomobject]@{
                    Width = 10
                    Height = 2
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() }
                    )
                }
                (Get-FrameDiff -PreviousFrame $previous -NextFrame $next).Count | Should -Be 2
            }

            It 'returns all rows when height differs' {
                $previous = [pscustomobject]@{
                    Width = 10
                    Height = 1
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() }
                    )
                }
                $next = [pscustomobject]@{
                    Width = 10
                    Height = 2
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() }
                    )
                }
                (Get-FrameDiff -PreviousFrame $previous -NextFrame $next).Count | Should -Be 2
            }

            It 'returns zero rows for identical frames' {
                $rows = @(
                    [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                    [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() }
                )
                $previous = [pscustomobject]@{ Width = 10; Height = 2; Rows = $rows }
                $next = [pscustomobject]@{ Width = 10; Height = 2; Rows = $rows }
                (Get-FrameDiff -PreviousFrame $previous -NextFrame $next).Count | Should -Be 0
            }

            It 'returns only the changed row when one row differs' {
                $previous = [pscustomobject]@{
                    Width = 10
                    Height = 2
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() }
                    )
                }
                $next = [pscustomobject]@{
                    Width = 10
                    Height = 2
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'changed'; Segments = @() }
                    )
                }
                $changed = Get-FrameDiff -PreviousFrame $previous -NextFrame $next
                $changed.Count | Should -Be 1
                $changed[0].Y | Should -Be 1
            }

            It 'returns multiple non-adjacent changed rows' {
                $previous = [pscustomobject]@{
                    Width = 10
                    Height = 4
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'a'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() },
                        [pscustomobject]@{ Y = 2; Signature = 'c'; Segments = @() },
                        [pscustomobject]@{ Y = 3; Signature = 'd'; Segments = @() }
                    )
                }
                $next = [pscustomobject]@{
                    Width = 10
                    Height = 4
                    Rows = @(
                        [pscustomobject]@{ Y = 0; Signature = 'x'; Segments = @() },
                        [pscustomobject]@{ Y = 1; Signature = 'b'; Segments = @() },
                        [pscustomobject]@{ Y = 2; Signature = 'y'; Segments = @() },
                        [pscustomobject]@{ Y = 3; Signature = 'd'; Segments = @() }
                    )
                }
                $changed = Get-FrameDiff -PreviousFrame $previous -NextFrame $next
                @($changed | ForEach-Object { $_.Y }) | Should -Be @(0, 2)
            }
        }

        Context 'Compose-FrameRow' {
            It 'uses full width for non-last rows' {
                $row = Compose-FrameRow -Y 0 -LeftSegments @(@{ Text = 'L'; Color = 'Gray' }) -LeftWidth 4 -RightSegments @(@{ Text = 'R'; Color = 'White' }) -RightWidth 5 -TotalWidth 10 -IsLastRow $false
                (($row.Segments | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum) | Should -Be 10
            }

            It 'reserves bottom-right dead zone on last row' {
                $row = Compose-FrameRow -Y 1 -LeftSegments @(@{ Text = 'L'; Color = 'Gray' }) -LeftWidth 4 -RightSegments @(@{ Text = 'R'; Color = 'White' }) -RightWidth 5 -TotalWidth 10 -IsLastRow $true
                (($row.Segments | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum) | Should -Be 9
            }

            It 'contains the gap character between panes' {
                $row = Compose-FrameRow -Y 0 -LeftSegments @(@{ Text = 'AB'; Color = 'Gray' }) -LeftWidth 4 -RightSegments @(@{ Text = 'CD'; Color = 'White' }) -RightWidth 5 -TotalWidth 10 -IsLastRow $false
                (($row.Segments | ForEach-Object { $_.Text }) -join '') | Should -Match '^AB\s'
            }

            It 'applies right pane background color when provided' {
                $row = Compose-FrameRow -Y 0 -LeftSegments @(@{ Text = 'AB'; Color = 'Red' }) -LeftWidth 4 -RightSegments @(@{ Text = 'CD'; Color = 'White' }) -RightWidth 5 -RightBackgroundColor 'DarkCyan' -TotalWidth 10 -IsLastRow $false
                ($row.Segments | Where-Object { $_.BackgroundColor -eq 'DarkCyan' }).Count | Should -BeGreaterThan 0
            }

            It 'keeps empty background on left and gap segments' {
                $row = Compose-FrameRow -Y 0 -LeftSegments @(@{ Text = 'AB'; Color = 'Red' }) -LeftWidth 4 -RightSegments @(@{ Text = 'CD'; Color = 'White' }) -RightWidth 5 -RightBackgroundColor 'DarkCyan' -TotalWidth 10 -IsLastRow $false
                $row.Segments[0].BackgroundColor | Should -Be ''
                ($row.Segments | Where-Object { $_.Text -match '\s' -and $_.BackgroundColor -eq '' }).Count | Should -BeGreaterThan 0
            }
        }

        Context 'Build-FrameFromState' {
            It 'produces a full frame with sequential row indices' {
                $state = New-RenderStateFixture
                $frame = Build-FrameFromState -State $state
                $frame.Rows.Count | Should -Be $state.Ui.Layout.Height
                @($frame.Rows | ForEach-Object { $_.Y }) | Should -Be @(0..($state.Ui.Layout.Height - 1))
            }

            It 'uses width for content rows and width-minus-one for status row' {
                $state = New-RenderStateFixture
                $frame = Build-FrameFromState -State $state
                foreach ($row in $frame.Rows | Where-Object { $_.Y -lt ($state.Ui.Layout.Height - 1) }) {
                    (($row.Segments | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum) | Should -Be $state.Ui.Layout.Width
                }
                $statusRow = $frame.Rows[$frame.Rows.Count - 1]
                (($statusRow.Segments | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum) | Should -Be ($state.Ui.Layout.Width - 1)
            }

            It 'places status bar on the last row' {
                $state = New-RenderStateFixture
                $frame = Build-FrameFromState -State $state
                $frame.Rows[$frame.Rows.Count - 1].Y | Should -Be ($state.Ui.Layout.Height - 1)
            }

            It 'renders no matching changelists message when there are zero visible changelists' {
                $state = New-RenderStateFixture -VisibleChangeIds @() -ChangeIndex 0
                $frame = Build-FrameFromState -State $state
                (($frame.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n") | Should -Match 'No matching changelists'
            }

            It 'applies selected row background in changelists pane' {
                $state = New-RenderStateFixture -ChangeIndex 1
                $frame = Build-FrameFromState -State $state
                @($frame.Rows | Where-Object { @($_.Segments | Where-Object { $_.BackgroundColor -eq 'DarkCyan' }).Count -gt 0 }).Count | Should -BeGreaterThan 0
            }
        }

        Context 'Frame integration intent' {
            It 'returns only changed rows between two identical frames with cursor move' {
                $stateA = New-RenderStateFixture -ChangeIndex 0
                $stateB = New-RenderStateFixture -ChangeIndex 1
                $frameA = Build-FrameFromState -State $stateA
                $frameB = Build-FrameFromState -State $stateB
                $changed = Get-FrameDiff -PreviousFrame $frameA -NextFrame $frameB
                $changed.Count | Should -BeGreaterThan 0
                $changed.Count | Should -BeLessOrEqual 12
            }

            It 'returns zero rows for identical rebuilt frames' {
                $state = New-RenderStateFixture -ChangeIndex 1
                $frameA = Build-FrameFromState -State $state
                $frameB = Build-FrameFromState -State $state
                (Get-FrameDiff -PreviousFrame $frameA -NextFrame $frameB).Count | Should -Be 0
            }
        }
        Context 'CommandModal overlay' {
            It 'does not overlay the frame when CommandModal is closed' {
                $state = New-RenderStateFixture
                $state.Runtime.CommandModal.IsOpen = $false
                $frame = Build-FrameFromState -State $state
                $allText = ($frame.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $allText | Should -Not -Match 'p4 Commands'
            }

            It 'renders modal overlay when CommandModal is open and includes current command' {
                $state = New-RenderStateFixture
                $state.Runtime.CommandModal.IsOpen         = $true
                $state.Runtime.CommandModal.IsBusy         = $true
                $state.Runtime.CommandModal.CurrentCommand = 'p4 changes -s pending'
                $frame    = Build-FrameFromState -State $state
                $overlaid = Apply-ModalOverlay -Frame $frame -CommandModal $state.Runtime.CommandModal
                $allText  = ($overlaid.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $allText | Should -Match 'p4 Commands'
                $allText | Should -Match 'p4 changes -s pending'
            }

            It 'renders history rows newest-first and includes duration' {
                $state  = New-RenderStateFixture
                $start1 = [datetime]'2026-01-01 10:00:00'
                $end1   = [datetime]'2026-01-01 10:00:02'
                $start2 = [datetime]'2026-01-01 10:00:05'
                $end2   = [datetime]'2026-01-01 10:00:06'
                $state.Runtime.CommandModal.IsOpen   = $true
                $state.Runtime.CommandModal.IsBusy   = $false
                $state.Runtime.CommandModal.History  = @(
                    [pscustomobject]@{ StartedAt = $start2; EndedAt = $end2; CommandLine = 'p4 describe -s 200'; ExitCode = 0; Succeeded = $true; ErrorText = ''; DurationMs = 1000 },
                    [pscustomobject]@{ StartedAt = $start1; EndedAt = $end1; CommandLine = 'p4 changes';         ExitCode = 0; Succeeded = $true; ErrorText = ''; DurationMs = 2000 }
                )
                $frame    = Build-FrameFromState -State $state
                $overlaid = Apply-ModalOverlay -Frame $frame -CommandModal $state.Runtime.CommandModal
                $allText  = ($overlaid.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $allText | Should -Match 'p4 describe -s 200'
                $allText | Should -Match '1000ms'
            }

            It 'footer shows Please wait while busy and dismiss hint when idle' {
                $state = New-RenderStateFixture
                $state.Runtime.CommandModal.IsOpen = $true
                $state.Runtime.CommandModal.IsBusy = $true
                $frame    = Build-FrameFromState -State $state
                $overlaid = Apply-ModalOverlay -Frame $frame -CommandModal $state.Runtime.CommandModal
                $busyText = ($overlaid.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $busyText | Should -Match 'Please wait'

                $state.Runtime.CommandModal.IsBusy = $false
                $frame2    = Build-FrameFromState -State $state
                $overlaid2 = Apply-ModalOverlay -Frame $frame2 -CommandModal $state.Runtime.CommandModal
                $idleText  = ($overlaid2.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $idleText | Should -Match 'Dismiss'
                $idleText | Should -Match 'Toggle'
            }

            It 'renders error detail row for failed history entries' {
                $state = New-RenderStateFixture
                $start = [datetime]'2026-01-01 09:00:00'
                $end   = [datetime]'2026-01-01 09:00:01'
                $state.Runtime.CommandModal.IsOpen  = $true
                $state.Runtime.CommandModal.IsBusy  = $false
                $state.Runtime.CommandModal.History = @(
                    [pscustomobject]@{
                        StartedAt  = $start; EndedAt = $end; CommandLine = 'p4 change -d 12345'
                        ExitCode   = 1; Succeeded = $false; DurationMs = 500
                        ErrorText  = "p4 failed (exit 1).`nArgs: change -d 12345`nSTDERR: Change 12345 has shelved files associated with it and can't be deleted."
                    }
                )
                $frame    = Build-FrameFromState -State $state
                $overlaid = Apply-ModalOverlay -Frame $frame -CommandModal $state.Runtime.CommandModal
                $allText  = ($overlaid.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $allText | Should -Match '\[ERR\]'
                $allText | Should -Match "shelved files associated with it and can't be deleted"
                $allText | Should -Not -Match 'STDERR:'  # raw prefix must be stripped
            }

            It 'sanitizes multi-line LastError in the status bar' {
                $state = New-RenderStateFixture
                $state.Runtime.LastError = "p4 failed (exit 1).`nArgs: change -d 99`nSTDERR: Change 99 has shelved files."
                $frame   = Build-FrameFromState -State $state
                $allText = ($frame.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
                $allText | Should -Match 'Change 99 has shelved files'
                $allText | Should -Not -Match 'STDERR:'  # raw prefix must be stripped
            }
        }
    }
}

Describe 'Color helpers' {
    InModuleScope 'Render' {
        It 'maps marker glyphs with cursor precedence' {
            Get-MarkerColor -Marker '>' | Should -Be 'Cyan'
            Get-MarkerColor -Marker '░' | Should -Be 'Gray'
            Get-MarkerColor -Marker '│' | Should -Be 'DarkGray'
            Get-MarkerColor -Marker ' ' | Should -Be 'DarkGray'
        }
    }
}

Describe 'Write-ColorSegments' {
    InModuleScope 'Render' {
        It 'pads content to requested width' {
            $result = Write-ColorSegments -Segments @(
                @{ Text = 'Hi'; Color = 'Red' }
            ) -Width 5
            ($result | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum | Should -Be 5
        }

        It 'truncates content using ellipsis policy' {
            $result = Write-ColorSegments -Segments @(
                @{ Text = 'ABCDEFGHIJ'; Color = 'Red' }
            ) -Width 7
            $result.Count | Should -Be 1
            $result[0].Text | Should -Be ("ABCDEF$([char]0x2026)")
            ($result | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum | Should -Be 7
        }

        It 'returns blank segment when no content exists' {
            $result = Write-ColorSegments -Segments @() -Width 4
            $result.Count | Should -Be 1
            $result[0].Text | Should -Be '    '
            $result[0].Color | Should -Be 'Gray'
        }

        It 'returns empty output when width is non-positive' {
            (Write-ColorSegments -Segments @(@{ Text = 'a'; Color = 'Red' }) -Width 0).Count | Should -Be 0
        }

        It 'flattens nested segment arrays' {
            $segments = @(
                @(
                    @{ Text = 'A'; Color = 'Gray' },
                    @{ Text = 'B'; Color = 'Gray' }
                )
            )
            $result = Write-ColorSegments -Segments $segments -Width 4
            (($result | ForEach-Object { $_.Text }) -join '') | Should -Be 'AB  '
        }
    }
}

Describe 'Segment builders' {
    InModuleScope 'Render' {
        It 'builds unselected changelist segments with semantic colors' {
            $cl = [pscustomobject]@{ Id = 'FI-1'; Title = 'Title' }
            $segments = Build-ChangeSegments -Marker '│' -Change $cl -IsSelected $false
            $segments.Count | Should -Be 3
            $segments[0].Color | Should -Be 'DarkGray'
            $segments[1].Color | Should -Be 'DarkGray'
            $segments[2].Color | Should -Be 'Gray'
        }

        It 'builds selected changelist segments with focus colors' {
            $cl = [pscustomobject]@{ Id = 'FI-2'; Title = 'Chosen' }
            $segments = Build-ChangeSegments -Marker '>' -Change $cl -IsSelected $true
            $segments[0].Color | Should -Be 'Cyan'
            $segments[1].Color | Should -Be 'DarkGray'
            $segments[2].Color | Should -Be 'White'
        }

        It 'builds scrollbar-only row as marker segment' {
            $segments = Build-ChangeSegments -Marker '░' -Change $null -IsSelected $false
            $segments.Count | Should -Be 1
            $segments[0].Color | Should -Be 'Gray'
        }

        It 'builds detail rows with label and value colors' {
            $idea = [pscustomobject]@{
                Id    = '12345'
                Title = 'A changelist title'
            }

            $rows = Build-ChangeSummarySegments -Change $idea
            $rows.Count | Should -Be 2
            $rows[0][0].Color | Should -Be 'DarkYellow'
            $rows[0][1].Color | Should -Be 'DarkGray'
            $rows[1][0].Color | Should -Be 'DarkYellow'
            $rows[1][1].Color | Should -Be 'Gray'
        }

        It 'handles missing detail fields safely' {
            $idea = [pscustomobject]@{ Id = '0' }
            $rows = Build-ChangeSummarySegments -Change $idea
            $rows.Count | Should -Be 2
            $rows[1][1].Text | Should -Be ''
        }
    }
}

Describe 'Box helpers' {
    InModuleScope 'Render' {
        It 'builds a top border with rounded corners and centered title' {
            $segments = Build-BoxTopSegments -Title '[Filters]' -Width 12 -BorderColor 'DarkGray' -TitleColor 'Cyan'
            $text = ($segments | ForEach-Object { $_.Text }) -join ''
            $text.Length | Should -Be 12
            $text[0] | Should -Be '╭'
            $text[11] | Should -Be '╮'
            $text | Should -Match '\[Filters\]'
        }

        It 'builds a bottom border with rounded corners' {
            $segments = Build-BoxBottomSegments -Width 10 -BorderColor 'DarkGray'
            $text = ($segments | ForEach-Object { $_.Text }) -join ''
            $text | Should -Be '╰────────╯'
        }

        It 'builds bordered rows with vertical side rails' {
            $segments = Build-BorderedRowSegments -InnerSegments @(@{ Text = 'abc'; Color = 'Gray' }) -Width 8 -BorderColor 'DarkGray'
            $text = ($segments | ForEach-Object { $_.Text }) -join ''
            $text.Length | Should -Be 8
            $text[0] | Should -Be '│'
            $text[7] | Should -Be '│'
        }
    }
}
Describe 'Build-ChangeDetailSegments' {
    InModuleScope 'Render' {
        It 'renders opened count, shelved count and date from change fields' {
            $cl = [pscustomobject]@{
                Id               = '999'
                Title            = 'My CL'
                OpenedFileCount  = 5
                ShelvedFileCount = 3
                Captured         = [datetime]'2025-03-01'
            }
            $segments = Build-ChangeDetailSegments -Change $cl
            $allText = ($segments | ForEach-Object { $_.Text }) -join ''
            $allText | Should -Match '5'
            $allText | Should -Match '3'
            $allText | Should -Match '2025-03-01'
        }

        It 'renders zero counts when count fields are absent' {
            $cl = [pscustomobject]@{ Id = '1'; Title = 'Only Title'; Captured = [datetime]'2025-01-01' }
            $segments = Build-ChangeDetailSegments -Change $cl
            $allText = ($segments | ForEach-Object { $_.Text }) -join ''
            $allText | Should -Match '0'
        }

        It 'uses DarkCyan for icon segments and Gray for count segments' {
            $cl = [pscustomobject]@{
                Id               = '1'
                Title            = 'T'
                OpenedFileCount  = 2
                ShelvedFileCount = 1
                Captured         = [datetime]'2025-06-01'
            }
            $segments = Build-ChangeDetailSegments -Change $cl
            ($segments | Where-Object { $_.Color -eq 'DarkCyan' }).Count | Should -BeGreaterThan 0
            ($segments | Where-Object { $_.Color -eq 'Gray' }).Count     | Should -BeGreaterThan 0
        }

        It 'returns empty array for null change' {
            $result = Build-ChangeDetailSegments -Change $null
            @($result).Count | Should -Be 0
        }
    }
}

Describe 'Expanded changelist frame rendering' {
    InModuleScope 'Render' {
        BeforeAll {
            function New-ExpandedStateFixture {
                param([bool]$Expanded = $true)

                $SelectedFilters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $changes = @(
                    [pscustomobject]@{
                        Id = 'CL-1'; Title = 'First'; OpenedFileCount = 2; ShelvedFileCount = 1
                        HasOpenedFiles = $true; HasShelvedFiles = $true; Captured = [datetime]'2025-01-10'
                    },
                    [pscustomobject]@{
                        Id = 'CL-2'; Title = 'Second'; OpenedFileCount = 0; ShelvedFileCount = 0
                        HasOpenedFiles = $false; HasShelvedFiles = $false; Captured = [datetime]'2025-01-09'
                    }
                )

                $contentHeight = 19
                $listHeight = 9
                $detailHeight = $contentHeight - $listHeight - 1
                $layout = [pscustomobject]@{
                    Mode       = 'Normal'
                    Width      = 200
                    Height     = 20
                    FilterPane = [pscustomobject]@{ X = 0; Y = 0; W = 24; H = $contentHeight }
                    ListPane   = [pscustomobject]@{ X = 25; Y = 0; W = 55; H = $listHeight }
                    DetailPane = [pscustomobject]@{ X = 25; Y = ($listHeight + 1); W = 55; H = $detailHeight }
                    StatusPane = [pscustomobject]@{ X = 0; Y = $contentHeight; W = 200; H = 1 }
                }

                return [pscustomobject]@{
                    Data    = [pscustomobject]@{ AllChanges = $changes; AllFilters = @() }
                    Ui      = [pscustomobject]@{
                        ActivePane             = 'Changelists'
                        IsMaximized            = $false
                        HideUnavailableFilters = $false
                        ExpandedChangelists    = $Expanded
                        Layout                 = $layout
                    }
                    Query   = [pscustomobject]@{
                        SelectedFilters = $SelectedFilters
                        SearchText      = ''
                        SearchMode      = 'None'
                        SortMode        = 'Default'
                    }
                    Derived = [pscustomobject]@{
                        VisibleChangeIds = @('CL-1', 'CL-2')
                        VisibleFilters   = @()
                    }
                    Cursor  = [pscustomobject]@{
                        FilterIndex     = 0
                        FilterScrollTop = 0
                        ChangeIndex     = 0
                        ChangeScrollTop = 0
                    }
                    Runtime = [pscustomobject]@{
                        IsRunning  = $true
                        LastError  = $null
                        DeleteChangeId = $null
                        CommandModal   = [pscustomobject]@{
                            IsOpen = $false; IsBusy = $false; CurrentCommand = ''; History = @()
                        }
                    }
                }
            }
        }

        It 'expanded frame contains date text in detail rows' {
            $state = New-ExpandedStateFixture -Expanded $true
            $frame = Build-FrameFromState -State $state
            $allText = ($frame.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
            $allText | Should -Match '2025-01-10'
        }

        It 'compressed frame does not contain date text' {
            $state = New-ExpandedStateFixture -Expanded $false
            $frame = Build-FrameFromState -State $state
            $allText = ($frame.Rows | ForEach-Object { ($_.Segments | ForEach-Object { $_.Text }) -join '' }) -join "`n"
            $allText | Should -Not -Match '2025-01-10'
        }

        It 'selected CL has DarkCyan background on its title row in expanded mode' {
            $state = New-ExpandedStateFixture -Expanded $true
            $frame = Build-FrameFromState -State $state
            # Row 1 (inner row 0) is the title row for CL-1 (selected)
            $row1 = $frame.Rows[1]
            ($row1.Segments | Where-Object { $_.BackgroundColor -eq 'DarkCyan' }).Count | Should -BeGreaterThan 0
        }

        It 'selected CL detail row also has DarkCyan background in expanded mode' {
            $state = New-ExpandedStateFixture -Expanded $true
            $frame = Build-FrameFromState -State $state
            # Row 2 (inner row 1) is the detail row for CL-1 (selected)
            $row2 = $frame.Rows[2]
            ($row2.Segments | Where-Object { $_.BackgroundColor -eq 'DarkCyan' }).Count | Should -BeGreaterThan 0
        }

        It 'status bar shows [E] Expand when compressed' {
            $state = New-ExpandedStateFixture -Expanded $false
            $frame = Build-FrameFromState -State $state
            $statusText = ($frame.Rows[-1].Segments | ForEach-Object { $_.Text }) -join ''
            $statusText | Should -Match '\[E\] Expand'
        }

        It 'status bar shows [E] Collapse when expanded' {
            $state = New-ExpandedStateFixture -Expanded $true
            $frame = Build-FrameFromState -State $state
            $statusText = ($frame.Rows[-1].Segments | ForEach-Object { $_.Text }) -join ''
            $statusText | Should -Match '\[E\] Collapse'
        }
    }
}
