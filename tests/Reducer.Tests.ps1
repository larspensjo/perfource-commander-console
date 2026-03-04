$modulePath = Join-Path $PSScriptRoot '..\tui\Reducer.psm1'
Import-Module $modulePath -Force

Describe 'Browser reducer' {
    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = 'FI-1'; Title = 'One'; Filters = @('a'); Priority = 'P1'; Risk = 'M'; Captured = [datetime]'2026-02-10'; Summary='S1'; Rationale='R1'; Effort='M' },
            [pscustomobject]@{ Id = 'FI-2'; Title = 'Two'; Filters = @('a', 'b'); Priority = 'P2'; Risk = 'L'; Captured = [datetime]'2026-02-09'; Summary='S2'; Rationale='R2'; Effort='S' },
            [pscustomobject]@{ Id = 'FI-3'; Title = 'Three'; Filters = @('b', 'c'); Priority = 'P3'; Risk = 'H'; Captured = [datetime]'2026-02-08'; Summary='S3'; Rationale='R3'; Effort='L' }
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

    It 'supports Home/End in filters pane' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $state.Cursor.FilterIndex | Should -Be 2

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $state.Cursor.FilterIndex | Should -Be 0
    }

    It 'scrolls filters as soon as cursor moves past last visible filter row' {
        $manyChanges = @()
        for ($i = 0; $i -lt 20; $i++) {
            $manyChanges += [pscustomobject]@{
                Id = "FI-T-$i"
                Title = "Tag $i"
                Filters = @("t$i")
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

        $state.Cursor.FilterIndex | Should -Be 13
        $state.Cursor.FilterScrollTop | Should -Be 1
    }

    It 'resets change index after filter change' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state.Cursor.ChangeIndex | Should -Be 1

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'b' })
        $state.Cursor.ChangeIndex | Should -Be 0
        $state.Derived.VisibleChangeIds | Should -Be @('FI-2', 'FI-3')
    }

    It 'supports multi-action sequence with consistent state' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'a' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'b' })

        $state.Derived.VisibleChangeIds | Should -Be @('FI-2')
        $state.Cursor.ChangeIndex | Should -Be 0
        $state.Query.SelectedFilters.Contains('a') | Should -BeTrue
        $state.Query.SelectedFilters.Contains('b') | Should -BeTrue
    }

    It 'toggles current filter when action has no Filter property' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter' })
        $state.Query.SelectedFilters.Contains('a') | Should -BeTrue
    }

    It 'derives unavailable filters from selected filters' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'a' })
        $tagC = $state.Derived.VisibleFilters | Where-Object Name -eq 'c' | Select-Object -First 1
        $tagC.IsSelectable | Should -BeFalse
        $tagC.MatchCount | Should -Be 0
    }

    It 'can hide unavailable filters with toggle action' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'a' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHideUnavailableFilters' })

        $names = @($state.Derived.VisibleFilters | ForEach-Object Name)
        $names -contains 'c' | Should -BeFalse
        $state.Ui.HideUnavailableFilters | Should -BeTrue
    }

    It 'keeps cursor on same filter identity in hide mode when toggling twice' {
        $changes = @(
            [pscustomobject]@{ Id = 'FI-1'; Title = 'One'; Filters = @('a', 'd'); Priority = 'P1'; Risk = 'M'; Captured = [datetime]'2026-02-10'; Summary='S1'; Rationale='R1'; Effort='M' },
            [pscustomobject]@{ Id = 'FI-2'; Title = 'Two'; Filters = @('b', 'd'); Priority = 'P2'; Risk = 'L'; Captured = [datetime]'2026-02-09'; Summary='S2'; Rationale='R2'; Effort='S' },
            [pscustomobject]@{ Id = 'FI-3'; Title = 'Three'; Filters = @('e', 'd'); Priority = 'P3'; Risk = 'H'; Captured = [datetime]'2026-02-08'; Summary='S3'; Rationale='R3'; Effort='L' },
            [pscustomobject]@{ Id = 'FI-4'; Title = 'Four'; Filters = @('c'); Priority = 'P3'; Risk = 'H'; Captured = [datetime]'2026-02-07'; Summary='S4'; Rationale='R4'; Effort='L' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHideUnavailableFilters' })

        $indexOfD = -1
        for ($i = 0; $i -lt $state.Derived.VisibleFilters.Count; $i++) {
            if ($state.Derived.VisibleFilters[$i].Name -eq 'd') { $indexOfD = $i; break }
        }
        $state.Cursor.FilterIndex = $indexOfD

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter' })
        $state.Query.SelectedFilters.Contains('d') | Should -BeTrue

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter' })
        $state.Query.SelectedFilters.Contains('d') | Should -BeFalse
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
        $state.Runtime.DeleteChangeId = 'FI-3'
        $copy = Copy-BrowserState -State $state
        $copy.Data.DescribeCache[42]    | Should -Be 'cached-value'
        $copy.Runtime.LastSelectedId    | Should -Be 'FI-2'
        $copy.Runtime.DeleteChangeId    | Should -Be 'FI-3'
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

    It 'Reload preserves selected filters in AllFilters' {
        Mock Get-P4ChangelistEntries -ModuleName Reducer { return @() }
        [void]$state.Query.SelectedFilters.Add('orphan-filter')

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
        $next.Data.AllFilters | Should -Contain 'orphan-filter'
    }

    It 'DeleteChange action sets DeleteChangeId to the currently focused changelist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'DeleteChange' })
        $next.Runtime.DeleteChangeId | Should -Be $state.Derived.VisibleChangeIds[$state.Cursor.ChangeIndex]
    }

    It 'DeleteChange action on empty list is a no-op' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'DeleteChange' })
        $next.Runtime.DeleteChangeId | Should -BeNullOrEmpty
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
