$modulePath = Join-Path $PSScriptRoot '..\tui\Reducer.psm1'
Import-Module $modulePath -Force

Describe 'Browser reducer' {
    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = 'FI-1'; Title = 'One'; Tags = @('a'); Priority = 'P1'; Risk = 'M'; Captured = [datetime]'2026-02-10'; Summary='S1'; Rationale='R1'; Effort='M' },
            [pscustomobject]@{ Id = 'FI-2'; Title = 'Two'; Tags = @('a', 'b'); Priority = 'P2'; Risk = 'L'; Captured = [datetime]'2026-02-09'; Summary='S2'; Rationale='R2'; Effort='S' },
            [pscustomobject]@{ Id = 'FI-3'; Title = 'Three'; Tags = @('b', 'c'); Priority = 'P3'; Risk = 'H'; Captured = [datetime]'2026-02-08'; Summary='S3'; Rationale='R3'; Effort='L' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'toggles active pane with SwitchPane' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $next.Ui.ActivePane | Should -Be 'Changelists'
    }

    It 'clamps change index at max when moving down' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })

        $state.Cursor.ChangeIndex | Should -Be 2
    }

    It 'supports PageDown/PageUp in changelists pane' {
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 16
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'PageDown' })
        $state.Cursor.ChangeIndex | Should -BeGreaterThan 0

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'PageUp' })
        $state.Cursor.ChangeIndex | Should -Be 0
    }

    It 'supports Home/End in changelists pane' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $state.Cursor.ChangeIndex | Should -Be 2

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $state.Cursor.ChangeIndex | Should -Be 0
    }

    It 'supports Home/End in tags pane' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $state.Cursor.TagIndex | Should -Be 2

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $state.Cursor.TagIndex | Should -Be 0
    }

    It 'scrolls tags as soon as cursor moves past last visible tag row' {
        $manyChanges = @()
        for ($i = 0; $i -lt 20; $i++) {
            $manyChanges += [pscustomobject]@{
                Id = "FI-T-$i"
                Title = "Tag $i"
                Tags = @("t$i")
                Priority = 'P2'
                Risk = 'M'
                Captured = [datetime]'2026-02-10'
                Summary = 'S'
                Rationale = 'R'
                Effort = 'M'
            }
        }

        $state = New-BrowserState -Changes $manyChanges -InitialWidth 120 -InitialHeight 16
        for ($n = 0; $n -lt 13; $n++) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        }

        $state.Cursor.TagIndex | Should -Be 13
        $state.Cursor.TagScrollTop | Should -Be 1
    }

    It 'resets change index after filter change' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state.Cursor.ChangeIndex | Should -Be 1

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag'; Tag = 'b' })
        $state.Cursor.ChangeIndex | Should -Be 0
        $state.Derived.VisibleChangeIds | Should -Be @('FI-2', 'FI-3')
    }

    It 'supports multi-action sequence with consistent state' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag'; Tag = 'a' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag'; Tag = 'b' })

        $state.Derived.VisibleChangeIds | Should -Be @('FI-2')
        $state.Cursor.ChangeIndex | Should -Be 0
        $state.Query.SelectedTags.Contains('a') | Should -BeTrue
        $state.Query.SelectedTags.Contains('b') | Should -BeTrue
    }

    It 'toggles current tag when action has no Tag property' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag' })
        $state.Query.SelectedTags.Contains('a') | Should -BeTrue
    }

    It 'derives unavailable tags from selected filters' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag'; Tag = 'a' })
        $tagC = $state.Derived.VisibleTags | Where-Object Name -eq 'c' | Select-Object -First 1
        $tagC.IsSelectable | Should -BeFalse
        $tagC.MatchCount | Should -Be 0
    }

    It 'can hide unavailable tags with toggle action' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag'; Tag = 'a' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHideUnavailableTags' })

        $names = @($state.Derived.VisibleTags | ForEach-Object Name)
        $names -contains 'c' | Should -BeFalse
        $state.Ui.HideUnavailableTags | Should -BeTrue
    }

    It 'keeps cursor on same tag identity in hide mode when toggling twice' {
        $changes = @(
            [pscustomobject]@{ Id = 'FI-1'; Title = 'One'; Tags = @('a', 'd'); Priority = 'P1'; Risk = 'M'; Captured = [datetime]'2026-02-10'; Summary='S1'; Rationale='R1'; Effort='M' },
            [pscustomobject]@{ Id = 'FI-2'; Title = 'Two'; Tags = @('b', 'd'); Priority = 'P2'; Risk = 'L'; Captured = [datetime]'2026-02-09'; Summary='S2'; Rationale='R2'; Effort='S' },
            [pscustomobject]@{ Id = 'FI-3'; Title = 'Three'; Tags = @('e', 'd'); Priority = 'P3'; Risk = 'H'; Captured = [datetime]'2026-02-08'; Summary='S3'; Rationale='R3'; Effort='L' },
            [pscustomobject]@{ Id = 'FI-4'; Title = 'Four'; Tags = @('c'); Priority = 'P3'; Risk = 'H'; Captured = [datetime]'2026-02-07'; Summary='S4'; Rationale='R4'; Effort='L' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHideUnavailableTags' })

        $indexOfD = -1
        for ($i = 0; $i -lt $state.Derived.VisibleTags.Count; $i++) {
            if ($state.Derived.VisibleTags[$i].Name -eq 'd') { $indexOfD = $i; break }
        }
        $state.Cursor.TagIndex = $indexOfD

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag' })
        $state.Query.SelectedTags.Contains('d') | Should -BeTrue

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleTag' })
        $state.Query.SelectedTags.Contains('d') | Should -BeFalse
    }

    It 'marks runtime as stopped on quit' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Quit' })
        $next.Runtime.IsRunning | Should -BeFalse
    }

    It 'Describe action sets LastSelectedId to the currently focused changelist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Describe' })
        $next.Runtime.LastSelectedId | Should -Be $state.Derived.VisibleChangeIds[$state.Cursor.ChangeIndex]
    }

    It 'Describe action on empty list is a no-op' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'Describe' })
        $next.Runtime.LastSelectedId | Should -BeNullOrEmpty
    }

    It 'Copy-BrowserState preserves DescribeCache by reference and copies LastSelectedId' {
        $state.Data.DescribeCache[42] = 'cached-value'
        $state.Runtime.LastSelectedId = 'FI-2'
        $copy = Copy-BrowserState -State $state
        $copy.Data.DescribeCache[42]    | Should -Be 'cached-value'
        $copy.Runtime.LastSelectedId    | Should -Be 'FI-2'
        # shared reference — mutation visible in copy
        $state.Data.DescribeCache[99] = 'new-entry'
        $copy.Data.DescribeCache[99]    | Should -Be 'new-entry'
    }

    It 'Reload clears DescribeCache and LastSelectedId' {
        Mock Get-P4ChangelistEntries -ModuleName Reducer { return @() }
        $state.Data.DescribeCache[1] = 'something'
        $state.Runtime.LastSelectedId = 'FI-1'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
        $next.Data.DescribeCache.Count  | Should -Be 0
        $next.Runtime.LastSelectedId    | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-ChangeNumberFromId' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    It 'extracts change number from CL-prefixed id' {
        ConvertTo-ChangeNumberFromId -Id 'CL-12345' | Should -Be 12345
    }

    It 'returns null for a non-CL id' {
        ConvertTo-ChangeNumberFromId -Id 'FI-001' | Should -BeNullOrEmpty
    }

    It 'returns null for an empty string' {
        ConvertTo-ChangeNumberFromId -Id '' | Should -BeNullOrEmpty
    }
}
