$modulePath = Join-Path $PSScriptRoot '..\tui\Reducer.psm1'
Import-Module $modulePath -Force

Describe 'Browser reducer' {
    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One';   HasShelvedFiles = $false; HasOpenedFiles = $true;  Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = '102'; Title = 'Two';   HasShelvedFiles = $true;  HasOpenedFiles = $true;  Captured = [datetime]'2026-02-09' },
            [pscustomobject]@{ Id = '103'; Title = 'Three'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-02-08' }
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
        $state.Cursor.FilterIndex | Should -Be 1

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $state.Cursor.FilterIndex | Should -Be 0
    }

    It 'resets change index after filter change' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state.Cursor.ChangeIndex | Should -Be 1

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'No shelved files' })
        $state.Cursor.ChangeIndex | Should -Be 0
        $state.Derived.VisibleChangeIds | Should -Be @('101', '103')
    }

    It 'supports multi-action sequence with consistent state' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'No shelved files' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'No opened files' })

        $state.Derived.VisibleChangeIds | Should -Be @('103')
        $state.Cursor.ChangeIndex | Should -Be 0
        $state.Query.SelectedFilters.Contains('No shelved files') | Should -BeTrue
        $state.Query.SelectedFilters.Contains('No opened files') | Should -BeTrue
    }

    It 'toggles current filter when action has no Filter property' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter' })
        $state.Query.SelectedFilters.Contains('No shelved files') | Should -BeTrue
    }

    It 'derives unavailable filters from visible set' {
        $allWithFiles = @(
            [pscustomobject]@{ Id = '201'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = '202'; Title = 'Y'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-09' }
        )
        $localState = New-BrowserState -Changes $allWithFiles -InitialWidth 120 -InitialHeight 40
        $noFilesFilter = $localState.Derived.VisibleFilters | Where-Object { $_.Name -eq 'No opened files' } | Select-Object -First 1
        $noFilesFilter.IsSelectable | Should -BeFalse
        $noFilesFilter.MatchCount | Should -Be 0
    }

    It 'can hide unavailable filters with toggle action' {
        $allWithFiles = @(
            [pscustomobject]@{ Id = '201'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $localState = New-BrowserState -Changes $allWithFiles -InitialWidth 120 -InitialHeight 40
        $localState = Invoke-BrowserReducer -State $localState -Action ([pscustomobject]@{ Type = 'ToggleHideUnavailableFilters' })

        $names = @($localState.Derived.VisibleFilters | ForEach-Object Name)
        $names -contains 'No opened files' | Should -BeFalse
        $localState.Ui.HideUnavailableFilters | Should -BeTrue
    }

    It 'keeps cursor on same filter when toggling filter on then off' {
        # Move cursor to 'No opened files' (index 1)
        $localState = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $localState.Cursor.FilterIndex | Should -Be 1

        # Toggle it on — cursor stays on it
        $localState = Invoke-BrowserReducer -State $localState -Action ([pscustomobject]@{ Type = 'ToggleFilter' })
        $localState.Query.SelectedFilters.Contains('No opened files') | Should -BeTrue

        # Toggle it off — cursor should still be on 'No opened files'
        $localState = Invoke-BrowserReducer -State $localState -Action ([pscustomobject]@{ Type = 'ToggleFilter' })
        $localState.Query.SelectedFilters.Contains('No opened files') | Should -BeFalse
        $localState.Cursor.FilterIndex | Should -Be 1
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

    It 'Reload clears DescribeCache and LastSelectedId and sets ReloadRequested' {
        $state.Data.DescribeCache[1] = 'something'
        $state.Runtime.LastSelectedId = 'FI-1'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
        $next.Data.DescribeCache.Count  | Should -Be 0
        $next.Runtime.LastSelectedId    | Should -BeNullOrEmpty
        $next.Runtime.ReloadRequested   | Should -BeTrue
    }

    It 'Reload does not modify AllFilters in the reducer' {
        $before = $state.Data.AllFilters.Count
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
        $next.Data.AllFilters.Count   | Should -Be $before
        $next.Runtime.ReloadRequested | Should -BeTrue
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

    It 'extracts change number from numeric id' {
        ConvertTo-ChangeNumberFromId -Id '12345' | Should -Be 12345
    }

    It 'returns null for a non-numeric id' {
        ConvertTo-ChangeNumberFromId -Id 'FI-001' | Should -BeNullOrEmpty
    }

    It 'returns null for an empty string' {
        ConvertTo-ChangeNumberFromId -Id '' | Should -BeNullOrEmpty
    }
}

Describe 'CommandModal reducer actions' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'CommandStart opens modal, sets busy, and records current command' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next.Runtime.CommandModal.IsOpen         | Should -BeTrue
        $next.Runtime.CommandModal.IsBusy         | Should -BeTrue
        $next.Runtime.CommandModal.CurrentCommand | Should -Be 'p4 changes'
    }

    It 'CommandFinish on success appends history with DurationMs and closes modal' {
        $start = [datetime]'2026-01-01 10:00:00'
        $end   = [datetime]'2026-01-01 10:00:01'
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = $start
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandFinish'; CommandLine = 'p4 changes'
            StartedAt = $start; EndedAt = $end
            ExitCode = 0; Succeeded = $true; ErrorText = ''
        })
        $next.Runtime.CommandModal.IsOpen              | Should -BeFalse
        $next.Runtime.CommandModal.IsBusy              | Should -BeFalse
        $next.Runtime.CommandModal.History.Count       | Should -Be 1
        $next.Runtime.CommandModal.History[0].DurationMs | Should -Be 1000
        $next.Runtime.CommandModal.History[0].Succeeded  | Should -BeTrue
    }

    It 'CommandFinish on failure keeps modal open' {
        $start = [datetime]'2026-01-01 10:00:00'
        $end   = [datetime]'2026-01-01 10:00:01'
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = $start
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandFinish'; CommandLine = 'p4 changes'
            StartedAt = $start; EndedAt = $end
            ExitCode = 1; Succeeded = $false; ErrorText = 'connection error'
        })
        $next.Runtime.CommandModal.IsOpen                | Should -BeTrue
        $next.Runtime.CommandModal.IsBusy                | Should -BeFalse
        $next.Runtime.CommandModal.History[0].Succeeded  | Should -BeFalse
        $next.Runtime.CommandModal.History[0].ErrorText  | Should -Be 'connection error'
    }

    It 'CommandFinish trims history to CommandHistoryMaxSize' {
        $start = [datetime]'2026-01-01 10:00:00'
        $end   = [datetime]'2026-01-01 10:00:01'
        for ($i = 0; $i -lt 50; $i++) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type = 'CommandStart'; CommandLine = "p4 cmd$i"; StartedAt = $start
            })
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type = 'CommandFinish'; CommandLine = "p4 cmd$i"
                StartedAt = $start; EndedAt = $end
                ExitCode = 0; Succeeded = $true; ErrorText = ''
            })
        }
        $state.Runtime.CommandModal.History.Count | Should -Be 50

        # Add one more — must trim to 50
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 new'; StartedAt = $start
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandFinish'; CommandLine = 'p4 new'
            StartedAt = $start; EndedAt = $end
            ExitCode = 0; Succeeded = $true; ErrorText = ''
        })
        $next.Runtime.CommandModal.History.Count              | Should -Be 50
        $next.Runtime.CommandModal.History[0].CommandLine     | Should -Be 'p4 new'
    }

    It 'ShowCommandModal opens modal' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ShowCommandModal' })
        $next.Runtime.CommandModal.IsOpen | Should -BeTrue
    }

    It 'ToggleCommandModal opens modal when closed' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleCommandModal' })
        $next.Runtime.CommandModal.IsOpen | Should -BeTrue
    }

    It 'ToggleCommandModal closes modal when open' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ShowCommandModal' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleCommandModal' })
        $next.Runtime.CommandModal.IsOpen | Should -BeFalse
    }

    It 'ToggleCommandModal is a no-op while busy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleCommandModal' })
        $next.Runtime.CommandModal.IsOpen | Should -BeTrue
        $next.Runtime.CommandModal.IsBusy | Should -BeTrue
    }

    It 'HideCommandModal closes modal when not busy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ShowCommandModal' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Runtime.CommandModal.IsOpen | Should -BeFalse
    }

    It 'HideCommandModal is a no-op while busy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Runtime.CommandModal.IsOpen | Should -BeTrue
        $next.Runtime.CommandModal.IsBusy | Should -BeTrue
    }

    It 'Copy-BrowserState copies CommandModal and History' {
        $start = [datetime]'2026-01-01 10:00:00'
        $end   = [datetime]'2026-01-01 10:00:01'
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 info'; StartedAt = $start
        })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandFinish'; CommandLine = 'p4 info'
            StartedAt = $start; EndedAt = $end
            ExitCode = 0; Succeeded = $true; ErrorText = ''
        })
        $copy = Copy-BrowserState -State $state
        $copy.Runtime.CommandModal.History.Count       | Should -Be 1
        $copy.Runtime.CommandModal.History[0].CommandLine | Should -Be 'p4 info'
    }
}
