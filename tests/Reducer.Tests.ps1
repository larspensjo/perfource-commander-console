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
        $next.Runtime.ModalPrompt.IsOpen         | Should -BeTrue
        $next.Runtime.ModalPrompt.IsBusy         | Should -BeTrue
        $next.Runtime.ModalPrompt.CurrentCommand | Should -Be 'p4 changes'
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
        $next.Runtime.ModalPrompt.IsOpen              | Should -BeFalse
        $next.Runtime.ModalPrompt.IsBusy              | Should -BeFalse
        $next.Runtime.ModalPrompt.History.Count       | Should -Be 1
        $next.Runtime.ModalPrompt.History[0].DurationMs | Should -Be 1000
        $next.Runtime.ModalPrompt.History[0].Succeeded  | Should -BeTrue
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
        $next.Runtime.ModalPrompt.IsOpen                | Should -BeTrue
        $next.Runtime.ModalPrompt.IsBusy                | Should -BeFalse
        $next.Runtime.ModalPrompt.History[0].Succeeded  | Should -BeFalse
        $next.Runtime.ModalPrompt.History[0].ErrorText  | Should -Be 'connection error'
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
        $state.Runtime.ModalPrompt.History.Count | Should -Be 50

        # Add one more — must trim to 50
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 new'; StartedAt = $start
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandFinish'; CommandLine = 'p4 new'
            StartedAt = $start; EndedAt = $end
            ExitCode = 0; Succeeded = $true; ErrorText = ''
        })
        $next.Runtime.ModalPrompt.History.Count              | Should -Be 50
        $next.Runtime.ModalPrompt.History[0].CommandLine     | Should -Be 'p4 new'
    }

    It 'ShowCommandModal opens modal' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ShowCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeTrue
    }

    It 'ToggleCommandModal opens modal when closed' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeTrue
    }

    It 'ToggleCommandModal closes modal when open' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ShowCommandModal' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeFalse
    }

    It 'ToggleCommandModal is a no-op while busy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeTrue
        $next.Runtime.ModalPrompt.IsBusy | Should -BeTrue
    }

    It 'HideCommandModal closes modal when not busy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ShowCommandModal' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeFalse
    }

    It 'HideCommandModal is a no-op while busy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeTrue
        $next.Runtime.ModalPrompt.IsBusy | Should -BeTrue
    }

    It 'Copy-BrowserState copies ModalPrompt and History' {
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
        $copy.Runtime.ModalPrompt.History.Count       | Should -Be 1
        $copy.Runtime.ModalPrompt.History[0].CommandLine | Should -Be 'p4 info'
    }
}

Describe 'ToggleChangelistView' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One';   HasShelvedFiles = $false; HasOpenedFiles = $true;  Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = '102'; Title = 'Two';   HasShelvedFiles = $true;  HasOpenedFiles = $true;  Captured = [datetime]'2026-02-09' },
            [pscustomobject]@{ Id = '103'; Title = 'Three'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-02-08' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'ExpandedChangelists defaults to false in new state' {
        $state.Ui.ExpandedChangelists | Should -BeFalse
    }

    It 'ToggleChangelistView flips the flag to true then back to false' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $next.Ui.ExpandedChangelists | Should -BeTrue

        $next2 = Invoke-BrowserReducer -State $next -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $next2.Ui.ExpandedChangelists | Should -BeFalse
    }

    It 'Copy-BrowserState preserves ExpandedChangelists flag' {
        $expanded = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $copy = Copy-BrowserState -State $expanded
        $copy.Ui.ExpandedChangelists | Should -BeTrue
    }

    It 'ToggleChangelistView re-clamps cursor into valid range' {
        # Move cursor to last item
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $state.Cursor.ChangeIndex | Should -Be 2

        # Toggle expand — cursor should still be valid
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $next.Cursor.ChangeIndex | Should -BeGreaterOrEqual 0
        $next.Cursor.ChangeIndex | Should -BeLessOrEqual 2
    }
}

Describe 'Changelist geometry helpers' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    It 'Get-ChangeInnerViewRows returns ListPane.H minus 2 in Normal mode' {
        $changes = @(
            [pscustomobject]@{ Id = '1'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = (Get-Date) }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $innerRows = Get-ChangeInnerViewRows -State $state
        $innerRows | Should -Be ($state.Ui.Layout.ListPane.H - 2)
    }

    It 'Get-ChangeRowsPerItem returns 1 when ExpandedChangelists is false' {
        $changes = @(
            [pscustomobject]@{ Id = '1'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = (Get-Date) }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        Get-ChangeRowsPerItem -State $state | Should -Be 1
    }

    It 'Get-ChangeRowsPerItem returns 2 when ExpandedChangelists is true and height is sufficient' {
        $changes = @(
            [pscustomobject]@{ Id = '1'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = (Get-Date) }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        Get-ChangeRowsPerItem -State $state | Should -Be 2
    }

    It 'Get-ChangeViewCapacity equals inner rows in compressed mode' {
        $changes = @(
            [pscustomobject]@{ Id = '1'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = (Get-Date) }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $innerRows = Get-ChangeInnerViewRows -State $state
        Get-ChangeViewCapacity -State $state | Should -Be $innerRows
    }

    It 'Get-ChangeViewCapacity halves in expanded mode' {
        $changes = @(
            [pscustomobject]@{ Id = '1'; Title = 'X'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = (Get-Date) }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $innerRows = Get-ChangeInnerViewRows -State $state
        $capacity  = Get-ChangeViewCapacity  -State $state
        $capacity  | Should -Be ([Math]::Floor($innerRows / 2))
    }
}
Describe 'Files screen reducer — Step 1' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One';   HasShelvedFiles = $false; HasOpenedFiles = $true;  Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = '102'; Title = 'Two';   HasShelvedFiles = $true;  HasOpenedFiles = $true;  Captured = [datetime]'2026-02-09' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    # ── New-BrowserState defaults ─────────────────────────────────────────────

    It 'New-BrowserState includes ScreenStack defaulting to @(Changelists)' {
        $state.Ui.ScreenStack | Should -Be @('Changelists')
    }

    It 'New-BrowserState includes FileCache as an empty hashtable' {
        $state.Data.FileCache | Should -BeOfType [hashtable]
        $state.Data.FileCache.Count | Should -Be 0
    }

    It 'New-BrowserState includes FilesSourceChange and FilesSourceKind' {
        $state.Data.FilesSourceChange | Should -BeNullOrEmpty
        $state.Data.FilesSourceKind   | Should -BeNullOrEmpty
    }

    It 'New-BrowserState includes CurrentUser and CurrentClient defaults' {
        $state.Data.CurrentUser   | Should -Be ''
        $state.Data.CurrentClient | Should -Be ''
    }

    It 'New-BrowserState includes FileFilterTokens and FileFilterText' {
        $state.Query.FileFilterTokens.Count | Should -Be 0
        $state.Query.FileFilterText         | Should -BeNullOrEmpty
    }

    It 'New-BrowserState includes VisibleFileIndices as empty array' {
        $state.Derived.VisibleFileIndices.Count | Should -Be 0
    }

    It 'New-BrowserState includes FileIndex and FileScrollTop defaulting to 0' {
        $state.Cursor.FileIndex     | Should -Be 0
        $state.Cursor.FileScrollTop | Should -Be 0
    }

    It 'New-BrowserState includes LoadFilesRequested defaulting to false' {
        $state.Runtime.LoadFilesRequested | Should -BeFalse
    }

    # ── OpenFilesScreen (Changelists → Files) ─────────────────────────────────

    It 'OpenFilesScreen pushes Files onto ScreenStack' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Ui.ScreenStack | Should -Be @('Changelists', 'Files')
    }

    It 'OpenFilesScreen stores FilesSourceChange for the focused CL' {
        # Focus CL 102 (index 1)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Data.FilesSourceChange | Should -Be 102
    }

    It 'OpenFilesScreen stores FilesSourceKind Opened for pending view' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Data.FilesSourceKind | Should -Be 'Opened'
    }

    It 'OpenFilesScreen sets LoadFilesRequested flag' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Runtime.LoadFilesRequested | Should -BeTrue
    }

    It 'OpenFilesScreen clears FileFilterText and resets file cursor' {
        # Prime some stale file filter state
        $state.Query.FileFilterText = 'old filter'
        $state.Cursor.FileIndex     = 5
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Query.FileFilterText | Should -BeNullOrEmpty
        $next.Cursor.FileIndex     | Should -Be 0
    }

    It 'OpenFilesScreen is a no-op when visible change list is empty' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Runtime.LoadFilesRequested | Should -BeFalse
    }

    # ── CloseFilesScreen (Files → Changelists) ────────────────────────────────

    It 'CloseFilesScreen pops Files from ScreenStack' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        # Now on Files screen; dispatch CloseFilesScreen
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'CloseFilesScreen' })
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }

    It 'HideCommandModal (Esc) on Files screen closes the screen when no overlay is open' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false   # consume flag so screen stays on Files
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }

    It 'HideCommandModal closes help overlay first when overlay is open on Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $state.Runtime.HelpOverlayOpen   = $true
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Runtime.HelpOverlayOpen | Should -BeFalse
        $next.Ui.ScreenStack          | Should -Be @('Changelists', 'Files')  # screen NOT closed
    }

    It 'LeftArrow action (CloseFilesScreen) on Files screen pops to Changelists' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'CloseFilesScreen' })
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }

    # ── Navigation on Files screen ────────────────────────────────────────────

    It 'MoveDown/MoveUp navigate FileIndex when files are loaded' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        # Inject 5 fake file entries into the cache
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @(0..4 | ForEach-Object { [pscustomobject]@{ DepotPath = "//depot/file$_.txt" } })
        $state = Update-BrowserDerivedState -State $state

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state.Cursor.FileIndex | Should -Be 2

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveUp' })
        $state.Cursor.FileIndex | Should -Be 1
    }

    It 'MoveDown clamps FileIndex at last entry' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @(0..2 | ForEach-Object { [pscustomobject]@{ DepotPath = "//depot/f$_.txt" } })
        $state = Update-BrowserDerivedState -State $state

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state.Cursor.FileIndex | Should -Be 2
    }

    It 'MoveHome and MoveEnd work on Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @(0..9 | ForEach-Object { [pscustomobject]@{ DepotPath = "//depot/f$_.txt" } })
        $state = Update-BrowserDerivedState -State $state

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $state.Cursor.FileIndex | Should -Be 9

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $state.Cursor.FileIndex     | Should -Be 0
        $state.Cursor.FileScrollTop | Should -Be 0
    }

    # ── VisibleFileIndices derived state ──────────────────────────────────────

    It 'VisibleFileIndices is empty when no files are in FileCache' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $state = Update-BrowserDerivedState -State $state
        $state.Derived.VisibleFileIndices.Count | Should -Be 0
    }

    It 'VisibleFileIndices contains 0..N-1 after files are loaded into cache' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @(0..4 | ForEach-Object { [pscustomobject]@{ DepotPath = "//depot/f$_.txt" } })
        $state = Update-BrowserDerivedState -State $state
        $state.Derived.VisibleFileIndices | Should -Be @(0, 1, 2, 3, 4)
    }

    It 'VisibleFileIndices with a single file returns @(0) not $null' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @([pscustomobject]@{ DepotPath = '//depot/solo.txt' })
        $state = Update-BrowserDerivedState -State $state
        $state.Derived.VisibleFileIndices.Count | Should -Be 1
        $state.Derived.VisibleFileIndices[0]    | Should -Be 0
    }

    # ── Copy-BrowserState preserves file fields ───────────────────────────────

    It 'Copy-BrowserState preserves ScreenStack array' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $copy  = Copy-BrowserState -State $state
        $copy.Ui.ScreenStack | Should -Be @('Changelists', 'Files')
    }

    It 'Copy-BrowserState preserves FileCache as shared reference' {
        $state.Data.FileCache['101:Opened'] = @([pscustomobject]@{ DepotPath = '//depot/a.txt' })
        $copy = Copy-BrowserState -State $state
        # FileCache is append-only and shared across copies (by design)
        $copy.Data.FileCache.ContainsKey('101:Opened') | Should -BeTrue
        # Mutation visible in both
        $state.Data.FileCache['102:Submitted'] = @()
        $copy.Data.FileCache.ContainsKey('102:Submitted') | Should -BeTrue
    }

    It 'Copy-BrowserState copies FileFilterText and FileIndex independently' {
        $state.Query.FileFilterText = 'test filter'
        $state.Cursor.FileIndex     = 3
        $copy = Copy-BrowserState -State $state
        $copy.Query.FileFilterText | Should -Be 'test filter'
        $copy.Cursor.FileIndex     | Should -Be 3
        # Mutating original does not affect copy
        $state.Query.FileFilterText = 'changed'
        $copy.Query.FileFilterText  | Should -Be 'test filter'
    }

    # ── Global actions forwarded through FilesReducer ─────────────────────────

    It 'Quit action on Files screen stops the runtime' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Quit' })
        $next.Runtime.IsRunning | Should -BeFalse
    }

    It 'Resize on Files screen updates Layout and keeps ScreenStack' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'Resize'; Width = 160; Height = 50
        })
        $next.Ui.Layout.Width    | Should -Be 160
        $next.Ui.Layout.Height   | Should -Be 50
        $next.Ui.ScreenStack[-1] | Should -Be 'Files'
    }

    It 'ToggleHelpOverlay is forwarded on Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHelpOverlay' })
        $next.Runtime.HelpOverlayOpen    | Should -BeTrue
        $next.Ui.ScreenStack[-1]         | Should -Be 'Files'
    }

    It 'LogCommandExecution on Files screen is forwarded into CommandLog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false
        $action = [pscustomobject]@{
            Type           = 'LogCommandExecution'
            CommandLine    = 'p4 describe -s 123'
            FormattedLines = @('CL#123  Sample change')
            OutputCount    = 1
            SummaryLine    = ''
            ExitCode       = 0
            ErrorText      = ''
            Succeeded      = $true
            StartedAt      = (Get-Date)
            EndedAt        = (Get-Date)
            DurationMs     = 5
        }

        $next = Invoke-BrowserReducer -State $state -Action $action

        $next.Runtime.CommandLog.Count | Should -Be 1
        $next.Runtime.CommandLog[0].CommandLine | Should -Be 'p4 describe -s 123'
    }

    It 'SwitchView from Files screen is forwarded and pops back to the target root view' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.LoadFilesRequested = $false

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })

        $next.Ui.ViewMode | Should -Be 'CommandLog'
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }
}

# ─── CommandLog feature tests ─────────────────────────────────────────────────

Describe 'CommandLog reducer' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    # ── LogCommandExecution ───────────────────────────────────────────────────

    It 'LogCommandExecution prepends a new entry to CommandLog' {
        $action = [pscustomobject]@{
            Type           = 'LogCommandExecution'
            CommandLine    = 'p4 info'
            FormattedLines = @('line1')
            OutputCount    = 1
            SummaryLine    = ''
            ExitCode       = 0
            ErrorText      = ''
            Succeeded      = $true
            StartedAt      = (Get-Date)
            EndedAt        = (Get-Date)
            DurationMs     = 42
        }
        $next = Invoke-BrowserReducer -State $state -Action $action
        $next.Runtime.CommandLog.Count | Should -Be 1
        $next.Runtime.CommandLog[0].CommandLine | Should -Be 'p4 info'
    }

    It 'Test-IsBrowserGlobalAction returns true for SwitchView and LogCommandExecution' {
        (Test-IsBrowserGlobalAction -ActionType 'SwitchView')        | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'LogCommandExecution') | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'OpenFilesScreen')   | Should -BeFalse
    }

    It 'LogCommandExecution assigns incrementing CommandIds' {
        $mkAction = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkAction 'p4 info')
        $s = Invoke-BrowserReducer -State $s     -Action (& $mkAction 'p4 changes')
        $s.Runtime.CommandLog[0].CommandId | Should -Not -Be $s.Runtime.CommandLog[1].CommandId
    }

    It 'LogCommandExecution stores FormattedLines in CommandOutputCache' {
        $fmtLines = @('Entry A', 'Entry B')
        $action = [pscustomobject]@{
            Type='LogCommandExecution'; CommandLine='p4 changes'; FormattedLines=$fmtLines; OutputCount=2
            SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
            StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=5
        }
        $next  = Invoke-BrowserReducer -State $state -Action $action
        $cmdId = [string]$next.Runtime.CommandLog[0].CommandId
        $next.Data.CommandOutputCache.ContainsKey($cmdId) | Should -BeTrue
        $next.Data.CommandOutputCache[$cmdId][0]          | Should -Be 'Entry A'
    }

    # ── SwitchView CommandLog ─────────────────────────────────────────────────

    It 'SwitchView CommandLog sets ViewMode to CommandLog' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $next.Ui.ViewMode | Should -Be 'CommandLog'
    }

    It 'SwitchView CommandLog saves and restores CommandLog cursor snapshot' {
        # Set up some commands so CommandIndex can advance
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action (& $mkLog 'p4 changes')
        # Switch to CommandLog
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        # Move down once
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $indexAfterMove = $s.Cursor.CommandIndex
        # Switch away
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Pending' })
        # Switch back — snapshot should restore
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s.Cursor.CommandIndex | Should -Be $indexAfterMove
    }

    # ── Navigation in CommandLog mode ─────────────────────────────────────────

    It 'MoveDown advances CommandIndex in CommandLog mode' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action (& $mkLog 'p4 changes')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $s.Cursor.CommandIndex | Should -Be 1
    }

    It 'MoveDown clamps at last command' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 a')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $s.Cursor.CommandIndex | Should -Be 0
    }

    It 'MoveHome/MoveEnd jump to first/last command' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 a')
        $s = Invoke-BrowserReducer -State $s -Action (& $mkLog 'p4 b')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $s.Cursor.CommandIndex | Should -Be 1
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $s.Cursor.CommandIndex | Should -Be 0
    }

    # ── ToggleChangelistView in CommandLog mode ───────────────────────────────

    It 'ToggleChangelistView in CommandLog mode adds CommandId to ExpandedCommands' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $cmdId = [string]$s.Derived.VisibleCommandIds[0]
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $s.Ui.ExpandedCommands.Contains($cmdId) | Should -BeTrue
    }

    It 'ToggleChangelistView in CommandLog mode removes already-expanded CommandId' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $cmdId = [string]$s.Derived.VisibleCommandIds[0]
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'ToggleChangelistView' })
        $s.Ui.ExpandedCommands.Contains($cmdId) | Should -BeFalse
    }

    # ── Open CommandOutput screen ─────────────────────────────────────────────

    It 'OpenFilesScreen in CommandLog mode pushes CommandOutput onto ScreenStack' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@('line'); OutputCount=1
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $s.Ui.ScreenStack[-1] | Should -Be 'CommandOutput'
    }

    It 'CloseFilesScreen pops CommandOutput back to Changelists' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@('line'); OutputCount=1
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'CloseFilesScreen' })
        $s.Ui.ScreenStack[-1] | Should -Be 'Changelists'
    }

    # ── CommandLog trim + cache eviction ─────────────────────────────────────

    It 'CommandLog is trimmed when it exceeds CommandLogMaxSize' {
        $max = InModuleScope Reducer { $script:CommandLogMaxSize }
        $mkLog = {
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine='p4 x'; FormattedLines=@(); OutputCount=0
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = $state
        for ($i = 0; $i -lt ($max + 5); $i++) {
            $s = Invoke-BrowserReducer -State $s -Action (& $mkLog)
        }
        $s.Runtime.CommandLog.Count | Should -BeLessOrEqual $max
    }

    # ── Integration journey ───────────────────────────────────────────────────

    It 'Journey: Pending -> CommandLog -> CommandOutput -> back -> Submitted' {
        $mkLog = { param($cmd)
            [pscustomobject]@{
                Type='LogCommandExecution'; CommandLine=$cmd; FormattedLines=@('x'); OutputCount=1
                SummaryLine=''; ExitCode=0; ErrorText=''; Succeeded=$true
                StartedAt=(Get-Date); EndedAt=(Get-Date); DurationMs=1
            }
        }
        $s = Invoke-BrowserReducer -State $state -Action (& $mkLog 'p4 info')
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })
        $s.Ui.ViewMode | Should -Be 'CommandLog'

        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $s.Ui.ScreenStack[-1] | Should -Be 'CommandOutput'

        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'CloseFilesScreen' })
        $s.Ui.ScreenStack[-1] | Should -Be 'Changelists'

        $s = Invoke-BrowserReducer -State $s -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' })
        $s.Ui.ViewMode | Should -Be 'Submitted'
    }
}

Describe 'Reducer performance guard' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    It 'processes a representative navigation loop within a reasonable time budget' {
        $changes = 1..20 | ForEach-Object {
            [pscustomobject]@{
                Id              = (1000 + $_).ToString()
                Title           = "Change $_"
                HasShelvedFiles = (($_ % 2) -eq 0)
                HasOpenedFiles  = (($_ % 3) -ne 0)
                Captured        = ([datetime]'2026-03-07').AddDays(-$_)
            }
        }

        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40

        # Benchmark a reducer path that exercises full derived-state recalculation
        # over a moderately sized changelist set, while keeping the guard cheap.
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        1..40 | ForEach-Object {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        }
        $sw.Stop()

        # Keep this budget intentionally generous. The goal is to catch large
        # regressions in the reducer hot path, not tiny machine-to-machine noise.
        $sw.ElapsedMilliseconds | Should -BeLessThan 2200
    }
}
