$modulePath = Join-Path $PSScriptRoot '..\tui\Reducer.psm1'
Import-Module $modulePath -Force -Global

Describe 'Browser reducer' {
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

    It 'Describe action sets PendingRequest with kind FetchDescribe' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Describe' })
        $next.Runtime.PendingRequest.Kind     | Should -Be 'FetchDescribe'
        $next.Runtime.PendingRequest.ChangeId | Should -Be $state.Derived.VisibleChangeIds[$state.Cursor.ChangeIndex]
    }

    It 'Describe action on empty list is a no-op' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'Describe' })
        $next.Runtime.PendingRequest | Should -BeNullOrEmpty
    }

    It 'Copy-BrowserState preserves DescribeCache by reference and copies PendingRequest' {
        $state.Data.DescribeCache[42] = 'cached-value'
        $state.Runtime.PendingRequest = [pscustomobject]@{ Kind = 'FetchDescribe'; ChangeId = 'FI-2' }
        $copy = Copy-BrowserState -State $state
        $copy.Data.DescribeCache[42]        | Should -Be 'cached-value'
        $copy.Runtime.PendingRequest.Kind   | Should -Be 'FetchDescribe'
        $copy.Runtime.PendingRequest.ChangeId | Should -Be 'FI-2'
        # shared reference — mutation visible in copy
        $state.Data.DescribeCache[99] = 'new-entry'
        $copy.Data.DescribeCache[99]    | Should -Be 'new-entry'
    }

    It 'Reload clears DescribeCache and sets PendingRequest ReloadPending' {
        $state.Data.DescribeCache[1] = 'something'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
        $next.Data.DescribeCache.Count         | Should -Be 0
        $next.Runtime.PendingRequest.Kind      | Should -Be 'ReloadPending'
    }

    It 'Reload does not modify AllFilters in the reducer' {
        $before = $state.Data.AllFilters.Count
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })
        $next.Data.AllFilters.Count            | Should -Be $before
        $next.Runtime.PendingRequest.Kind      | Should -Be 'ReloadPending'
    }

    It 'DeleteChange action without marks sets PendingRequest with kind DeleteChange' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'DeleteChange' })
        $next.Runtime.PendingRequest.Kind     | Should -Be 'DeleteChange'
        $next.Runtime.PendingRequest.ChangeId | Should -Be $state.Derived.VisibleChangeIds[$state.Cursor.ChangeIndex]
    }

    It 'DeleteChange action with marks opens confirm dialog for marked changelists' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'DeleteChange' })
        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'DeleteMarked'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '101'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Not -Contain '102'
    }

    It 'DeleteChange action filters null and empty marked changelist ids' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        [void]$state.Query.MarkedChangeIds.Add('101')
        [void]$state.Query.MarkedChangeIds.Add('')
        [void]$state.Query.MarkedChangeIds.Add($null)

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'DeleteChange' })

        $next.Ui.OverlayMode | Should -Be 'Confirm'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Be @('101')
    }

    It 'DeleteShelvedFiles action without marks sets PendingRequest with kind DeleteShelvedFiles' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'DeleteShelvedFiles' })
        $next.Runtime.PendingRequest.Kind     | Should -Be 'DeleteShelvedFiles'
        $next.Runtime.PendingRequest.ChangeId | Should -Be '102'
    }

    It 'DeleteShelvedFiles action with marks opens confirm dialog for marked changelists with shelved files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'DeleteShelvedFiles' })
        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'DeleteShelvedFiles'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '102'
    }

    It 'DeleteChange action on empty list is a no-op' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'DeleteChange' })
        $next.Runtime.PendingRequest | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-ChangeNumberFromId' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    It 'extracts change number from numeric id' {
        ConvertTo-ChangeNumberFromId -Id '12345' | Should -Be '12345'
    }

    It 'preserves the default changelist id' {
        ConvertTo-ChangeNumberFromId -Id 'default' | Should -Be 'default'
    }

    It 'maps 0 to the default changelist id' {
        ConvertTo-ChangeNumberFromId -Id '0' | Should -Be 'default'
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

    It 'HideCommandModal when busy sets CancelRequested and keeps modal open (M3.2)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Runtime.ModalPrompt.IsOpen | Should -BeTrue
        $next.Runtime.ModalPrompt.IsBusy | Should -BeTrue
        $next.Runtime.CancelRequested   | Should -BeTrue
    }

    It 'HideCommandModal when busy still dismisses active overlay first (M3.2)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $state.Ui.OverlayMode = 'Help'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.OverlayMode              | Should -Be 'None'
        $next.Runtime.CancelRequested    | Should -BeFalse
        $next.Runtime.ModalPrompt.IsBusy | Should -BeTrue
    }

    It 'Quit when busy sets QuitRequested instead of stopping (M3.2)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'CommandStart'; CommandLine = 'p4 changes'; StartedAt = (Get-Date)
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Quit' })
        $next.Runtime.IsRunning     | Should -BeTrue
        $next.Runtime.QuitRequested | Should -BeTrue
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

    It 'New-BrowserState includes PendingRequest defaulting to null' {
        $state.Runtime.PendingRequest | Should -BeNullOrEmpty
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
        $next.Data.FilesSourceChange | Should -Be '102'
    }

    It 'OpenFilesScreen keeps the default changelist id intact' {
        $defaultState = New-BrowserState -Changes @(
            [pscustomobject]@{ Id = 'default'; Title = 'Default'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        ) -InitialWidth 120 -InitialHeight 40

        $next = Invoke-BrowserReducer -State $defaultState -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Data.FilesSourceChange | Should -Be 'default'
    }

    It 'OpenFilesScreen stores FilesSourceKind Opened for pending view' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Data.FilesSourceKind | Should -Be 'Opened'
    }

    It 'OpenFilesScreen sets PendingRequest to LoadFiles' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $next.Runtime.PendingRequest.Kind | Should -Be 'LoadFiles'
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
        $next.Runtime.PendingRequest | Should -BeNullOrEmpty
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
        $state.Runtime.PendingRequest = $null   # consume flag so screen stays on Files
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }

    It 'HideCommandModal closes active overlay first when overlay is open on Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $state.Ui.OverlayMode   = 'Help'
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.OverlayMode    | Should -Be 'None'
        $next.Ui.ScreenStack    | Should -Be @('Changelists', 'Files')  # screen NOT closed
    }

    It 'LeftArrow action (CloseFilesScreen) on Files screen pops to Changelists' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'CloseFilesScreen' })
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }

    # ── Navigation on Files screen ────────────────────────────────────────────

    It 'MoveDown/MoveUp navigate FileIndex when files are loaded' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
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
        $state.Runtime.PendingRequest = $null
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
        $state.Runtime.PendingRequest = $null
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
        $state.Runtime.PendingRequest = $null
        $state = Update-BrowserDerivedState -State $state
        $state.Derived.VisibleFileIndices.Count | Should -Be 0
    }

    It 'VisibleFileIndices contains 0..N-1 after files are loaded into cache' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @(0..4 | ForEach-Object { [pscustomobject]@{ DepotPath = "//depot/f$_.txt" } })
        $state = Update-BrowserDerivedState -State $state
        $state.Derived.VisibleFileIndices | Should -Be @(0, 1, 2, 3, 4)
    }

    It 'VisibleFileIndices with a single file returns @(0) not $null' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
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
        $state.Runtime.PendingRequest = $null
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Quit' })
        $next.Runtime.IsRunning | Should -BeFalse
    }

    It 'Resize on Files screen updates Layout and keeps ScreenStack' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'Resize'; Width = 160; Height = 50
        })
        $next.Ui.Layout.Width    | Should -Be 160
        $next.Ui.Layout.Height   | Should -Be 50
        $next.Ui.ScreenStack[-1] | Should -Be 'Files'
    }

    It 'ToggleHelpOverlay is forwarded on Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHelpOverlay' })
        $next.Ui.OverlayMode     | Should -Be 'Help'
        $next.Ui.ScreenStack[-1] | Should -Be 'Files'
    }

    It 'LogCommandExecution on Files screen is forwarded into CommandLog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
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
        $state.Runtime.PendingRequest = $null

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' })

        $next.Ui.ViewMode | Should -Be 'CommandLog'
        $next.Ui.ScreenStack | Should -Be @('Changelists')
    }

    It 'Copy-BrowserState preserves FileCacheStatus as shared reference (M0.4)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $state.Data.FileCacheStatus['101:Opened'] = 'BaseReady'
        $copy = Copy-BrowserState -State $state
        $copy.Data.FileCacheStatus.ContainsKey('101:Opened') | Should -BeTrue
        $copy.Data.FileCacheStatus['101:Opened'] | Should -Be 'BaseReady'
        # Shared reference: mutation visible in both
        $state.Data.FileCacheStatus['202:Submitted'] = 'Ready'
        $copy.Data.FileCacheStatus.ContainsKey('202:Submitted') | Should -BeTrue
    }

    It 'Reload on Files screen evicts FileCache AND FileCacheStatus (M2.2)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $cacheKey = "$($state.Data.FilesSourceChange):$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey]       = @([pscustomobject]@{ DepotPath = '//depot/f.txt' })
        $state.Data.FileCacheStatus[$cacheKey] = 'Ready'
        $state.Runtime.PendingRequest = $null

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'Reload' })

        $next.Data.FileCache.ContainsKey($cacheKey)       | Should -BeFalse
        $next.Data.FileCacheStatus.ContainsKey($cacheKey) | Should -BeFalse
        $next.Runtime.PendingRequest.Kind                 | Should -Be 'LoadFiles'
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
Describe 'Mark actions — MarkedChangeIds' {
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

    It 'New-BrowserState includes MarkedChangeIds as an empty HashSet' {
        ($state.Query.MarkedChangeIds -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
        $state.Query.MarkedChangeIds.Count | Should -Be 0
    }

    It 'ToggleMarkCurrent marks the currently focused changelist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        # Focused CL is now index 1 = '102'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $next.Query.MarkedChangeIds.Contains('102') | Should -BeTrue
        $next.Query.MarkedChangeIds.Count            | Should -Be 1
    }

    It 'ToggleMarkCurrent unmarks an already-marked changelist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        # '101' is now marked; toggle again to unmark
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $next.Query.MarkedChangeIds.Contains('101') | Should -BeFalse
        $next.Query.MarkedChangeIds.Count            | Should -Be 0
    }

    It 'ToggleMarkCurrent on empty list is a no-op' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $next.Query.MarkedChangeIds.Count | Should -Be 0
    }

    It 'MarkAllVisible unions all visible IDs into MarkedChangeIds' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MarkAllVisible' })
        $next.Query.MarkedChangeIds.Count | Should -Be 3
        $next.Query.MarkedChangeIds.Contains('101') | Should -BeTrue
        $next.Query.MarkedChangeIds.Contains('102') | Should -BeTrue
        $next.Query.MarkedChangeIds.Contains('103') | Should -BeTrue
    }

    It 'MarkAllVisible does not discard previously marked hidden items' {
        # Mark 102 first (it will become hidden after filter)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        # Apply filter: only 101 and 103 visible (no shelved files)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'No shelved files' })
        # Now MarkAllVisible — should union 101 and 103 but keep 102
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MarkAllVisible' })
        $next.Query.MarkedChangeIds.Contains('101') | Should -BeTrue
        $next.Query.MarkedChangeIds.Contains('102') | Should -BeTrue  # hidden but still marked
        $next.Query.MarkedChangeIds.Contains('103') | Should -BeTrue
    }

    It 'ClearMarks empties MarkedChangeIds' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MarkAllVisible' })
        $state.Query.MarkedChangeIds.Count | Should -Be 3
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ClearMarks' })
        $next.Query.MarkedChangeIds.Count | Should -Be 0
    }

    It 'marks persist across SwitchView' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MarkAllVisible' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' })
        $next.Query.MarkedChangeIds.Count | Should -Be 3
        $next.Query.MarkedChangeIds.Contains('101') | Should -BeTrue
    }

    It 'marks persist across filter change' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        # Toggle filter
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleFilter'; Filter = 'No shelved files' })
        $next.Query.MarkedChangeIds.Contains('101') | Should -BeTrue
    }

    It 'Copy-BrowserState preserves MarkedChangeIds as an independent copy' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MarkAllVisible' })
        $copy  = Copy-BrowserState -State $state
        $copy.Query.MarkedChangeIds.Count | Should -Be 3
        # Mutating original does not affect copy
        [void]$state.Query.MarkedChangeIds.Remove('101')
        $copy.Query.MarkedChangeIds.Contains('101') | Should -BeTrue
    }
}
# ─── Overlay framework ────────────────────────────────────────────────────────

Describe 'Overlay framework — OverlayMode and confirm dialog' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'Alpha'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2025-01-01' },
            [pscustomobject]@{ Id = '102'; Title = 'Beta';  HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2025-01-02' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'New-BrowserState initialises OverlayMode to None' {
        $state.Ui.OverlayMode    | Should -Be 'None'
        $state.Ui.OverlayPayload | Should -BeNullOrEmpty
    }

    It 'ToggleHelpOverlay sets OverlayMode to Help' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHelpOverlay' })
        $next.Ui.OverlayMode | Should -Be 'Help'
    }

    It 'ToggleHelpOverlay again clears OverlayMode back to None' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHelpOverlay' })
        $state.Ui.OverlayMode | Should -Be 'Help'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleHelpOverlay' })
        $next.Ui.OverlayMode | Should -Be 'None'
    }

    It 'HideHelpOverlay clears OverlayMode to None' {
        $state.Ui.OverlayMode = 'Help'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideHelpOverlay' })
        $next.Ui.OverlayMode | Should -Be 'None'
    }

    It 'OpenConfirmDialog sets OverlayMode to Confirm with payload' {
        $payload = [pscustomobject]@{
            Title            = 'Delete 2 changelists?'
            SummaryLines     = @('Selected: 2 changelists')
            ConsequenceLines = @('Only empty changelists can be deleted')
            ConfirmLabel     = 'Y = confirm'
            CancelLabel      = 'N / Esc = cancel'
        }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenConfirmDialog'; Payload = $payload })
        $next.Ui.OverlayMode               | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.Title      | Should -Be 'Delete 2 changelists?'
        $next.Ui.OverlayPayload.SummaryLines[0] | Should -Be 'Selected: 2 changelists'
    }

    It 'AcceptDialog clears overlay' {
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{ Title = 'Test?'; SummaryLines = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'AcceptDialog' })
        $next.Ui.OverlayMode    | Should -Be 'None'
        $next.Ui.OverlayPayload | Should -BeNullOrEmpty
    }

    It 'CancelDialog clears overlay' {
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{ Title = 'Test?'; SummaryLines = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'CancelDialog' })
        $next.Ui.OverlayMode    | Should -Be 'None'
        $next.Ui.OverlayPayload | Should -BeNullOrEmpty
    }

    It 'HideCommandModal (Esc) closes active overlay on Changelists screen' {
        $state.Ui.OverlayMode = 'Help'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.OverlayMode | Should -Be 'None'
    }

    It 'HideCommandModal (Esc) closes Confirm overlay on Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{ Title = 'Test?'; SummaryLines = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.OverlayMode    | Should -Be 'None'
        $next.Ui.ScreenStack    | Should -Be @('Changelists', 'Files')   # screen NOT closed
    }

    It 'overlay-first routing: AcceptDialog closes overlay even when Files screen is active' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{ Title = 'Test?'; SummaryLines = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'AcceptDialog' })
        $next.Ui.OverlayMode | Should -Be 'None'
        $next.Ui.ScreenStack | Should -Be @('Changelists', 'Files')   # screen still Files
    }
}

Describe 'Menu reducer actions' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }
    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'OpenMenu File sets OverlayMode to Menu with File payload' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next.Ui.OverlayMode              | Should -Be 'Menu'
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'File'
        $next.Ui.OverlayPayload.FocusIndex | Should -Be 0
        @($next.Ui.OverlayPayload.MenuItems).Count | Should -BeGreaterThan 0
    }

    It 'OpenMenu View sets OverlayMode to Menu with View payload' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'View' })
        $next.Ui.OverlayMode              | Should -Be 'Menu'
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'View'
    }

    It 'OpenMenu with unknown name is a no-op' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'bogus' })
        $next.Ui.OverlayMode | Should -Be 'None'
    }

    It 'MenuMoveDown advances FocusIndex' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuMoveDown' })
        $next.Ui.OverlayPayload.FocusIndex | Should -Be 1
    }

    It 'MenuMoveDown clamps at last navigable item' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        # Move down many times
        for ($i = 0; $i -lt 20; $i++) {
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuMoveDown' })
        }
        $navCount = Get-MenuNavigableCount -ComputedItems @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload.FocusIndex | Should -Be ($navCount - 1)
    }

    It 'MenuMoveUp clamps at 0' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuMoveUp' })
        $next.Ui.OverlayPayload.FocusIndex | Should -Be 0
    }

    It 'MenuSwitchLeft switches from File to View' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSwitchLeft' })
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'View'
        $next.Ui.OverlayPayload.FocusIndex | Should -Be 0
    }

    It 'MenuSwitchRight switches from View to File' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'View' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSwitchRight' })
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'File'
    }

    It 'MenuSelect Refresh closes menu and sets PendingRequest ReloadPending' {
        # Open menu and move to Refresh by item id.
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        # Find navigable index of Refresh
        [object[]]$items = @($state.Ui.OverlayPayload.MenuItems)
        $navIdx = 0
        $refreshIdx = -1
        foreach ($item in $items) {
            if (-not [bool]$item.IsSeparator) {
                if ([string]$item.Id -eq 'Refresh') { $refreshIdx = $navIdx; break }
                $navIdx++
            }
        }
        # set focus to Refresh
        $state.Ui.OverlayPayload = [pscustomobject]@{
            ActiveMenu = 'File'; FocusIndex = $refreshIdx; MenuItems = $items
        }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })
        $next.Ui.OverlayMode             | Should -Be 'None'
        $next.Runtime.PendingRequest.Kind | Should -Be 'ReloadPending'
    }

    It 'MenuSelect on disabled item closes menu but does not dispatch action' {
        # DeleteShelvedFiles is disabled when the focused changelist has no shelved files (default state)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        # FocusIndex=1 is DeleteShelvedFiles which should be disabled
        $state.Ui.OverlayPayload = [pscustomobject]@{
            ActiveMenu = 'File'; FocusIndex = 1; MenuItems = $state.Ui.OverlayPayload.MenuItems
        }
        $focusedItem = Get-MenuFocusedItem -ComputedItems @($state.Ui.OverlayPayload.MenuItems) -FocusIndex 1
        if (-not [bool]$focusedItem.IsEnabled) {
            $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })
            $next.Ui.OverlayMode | Should -Be 'None'
            # PendingRequest should remain null (no reload triggered)
            $next.Runtime.PendingRequest | Should -BeNullOrEmpty
        } else {
            # Skip: DeleteShelvedFiles is enabled for this setup
            Set-ItResult -Skipped -Because 'Item was enabled; skipping disabled-item path'
        }
    }

    It 'MenuAccelerator R selects Refresh from File menu' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'R' })
        $next.Ui.OverlayMode             | Should -Be 'None'
        $next.Runtime.PendingRequest.Kind | Should -Be 'ReloadPending'
    }

    It 'MenuAccelerator with unknown key leaves menu open' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'Z' })
        $next.Ui.OverlayMode | Should -Be 'Menu'
    }

    It 'Get-ComputedMenuItems returns items with resolved IsEnabled booleans for non-separators' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $items.Count | Should -BeGreaterThan 0
        $nonSeps = @($items | Where-Object { -not [bool]$_.IsSeparator })
        $nonSeps.Count | Should -BeGreaterThan 0
        foreach ($item in $nonSeps) {
            $item.PSObject.Properties['IsEnabled'] | Should -Not -BeNull
            $item.IsEnabled | Should -BeOfType [bool]
        }
    }

    It 'Get-MenuNavigableCount excludes separators' {
        $items = @(Get-ComputedMenuItems -MenuName 'View' -State $state)
        $navCount = Get-MenuNavigableCount -ComputedItems $items
        # View menu has: ViewPending, ViewSubmitted, ViewCommandLog, sep, ViewRevisionGraph, sep, ToggleHideFilters, ExpandCollapse, sep, Help = 7 navigable
        $navCount | Should -Be 7
    }

    It 'Get-MenuFocusedItem returns item at navigable index skipping separators' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        # Navigable index 0 = first non-separator item
        $focused = Get-MenuFocusedItem -ComputedItems $items -FocusIndex 0
        $focused.IsSeparator | Should -Be $false
    }

    It 'MenuSelect Quit sets Runtime.IsRunning to false' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$items = @($state.Ui.OverlayPayload.MenuItems)
        $navIdx = 0; $qIdx = -1
        foreach ($item in $items) {
            if (-not [bool]$item.IsSeparator) {
                if ([string]$item.Id -eq 'Quit') { $qIdx = $navIdx; break }
                $navIdx++
            }
        }
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = $qIdx; MenuItems = $items }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })
        $next.Ui.OverlayMode           | Should -Be 'None'
        $next.Runtime.IsRunning        | Should -Be $false
    }
}

# ─── Phase 4: Workflow execution framework ────────────────────────────────────

Describe 'Workflow framework actions' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'New-BrowserState initialises ActiveWorkflow to null' {
        $state.Runtime.ActiveWorkflow | Should -BeNullOrEmpty
    }

    It 'WorkflowBegin sets ActiveWorkflow with Kind and TotalCount' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 5
        })
        $next.Runtime.ActiveWorkflow.Kind        | Should -Be 'DeleteMarked'
        $next.Runtime.ActiveWorkflow.TotalCount  | Should -Be 5
        $next.Runtime.ActiveWorkflow.DoneCount   | Should -Be 0
        $next.Runtime.ActiveWorkflow.FailedCount | Should -Be 0
        @($next.Runtime.ActiveWorkflow.FailedIds).Count | Should -Be 0
    }

    It 'WorkflowItemComplete increments DoneCount' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 3
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        $next.Runtime.ActiveWorkflow.DoneCount | Should -Be 1
    }

    It 'WorkflowItemComplete is a no-op when no workflow is active' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        $next.Runtime.ActiveWorkflow | Should -BeNullOrEmpty
    }

    It 'WorkflowItemFailed increments FailedCount and appends ChangeId' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 3
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowItemFailed'; ChangeId = '101'
        })
        $next.Runtime.ActiveWorkflow.FailedCount | Should -Be 1
        @($next.Runtime.ActiveWorkflow.FailedIds) | Should -Contain '101'
    }

    It 'WorkflowItemFailed is a no-op when no workflow is active' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowItemFailed'; ChangeId = '101'
        })
        $next.Runtime.ActiveWorkflow | Should -BeNullOrEmpty
    }

    It 'WorkflowEnd clears ActiveWorkflow' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 3
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })
        $next.Runtime.ActiveWorkflow | Should -BeNullOrEmpty
    }

    It 'WorkflowEnd clears CancelRequested (M3.2)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 2
        })
        $state.Runtime.CancelRequested = $true
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })
        $next.Runtime.CancelRequested | Should -BeFalse
    }

    It 'AcceptDialog with OnAccept queues PendingRequest from OnAccept' {
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{
            Title        = 'Delete?'
            SummaryLines = @()
            OnAccept     = [pscustomobject]@{ Kind = 'ExecuteWorkflow'; WorkflowKind = 'DeleteMarked' }
        }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'AcceptDialog' })
        $next.Ui.OverlayMode                      | Should -Be 'None'
        $next.Runtime.PendingRequest.Kind         | Should -Be 'ExecuteWorkflow'
        $next.Runtime.PendingRequest.WorkflowKind | Should -Be 'DeleteMarked'
    }

    It 'AcceptDialog without OnAccept clears overlay and leaves PendingRequest null' {
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{ Title = 'Test?'; SummaryLines = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'AcceptDialog' })
        $next.Ui.OverlayMode         | Should -Be 'None'
        $next.Runtime.PendingRequest | Should -BeNullOrEmpty
    }

    It 'WorkflowBegin is a global action handled from Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 2
        })
        $next.Runtime.ActiveWorkflow.Kind | Should -Be 'DeleteMarked'
    }

    It 'Test-IsBrowserGlobalAction returns true for WorkflowBegin/ItemComplete/ItemFailed/WorkflowEnd' {
        (Test-IsBrowserGlobalAction -ActionType 'WorkflowBegin')       | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'WorkflowItemComplete') | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'WorkflowItemFailed')   | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'WorkflowEnd')          | Should -BeTrue
    }
}

# ─── Phase 5: First workflows ─────────────────────────────────────────────────

Describe 'Phase 5 — DeleteChange, DeleteShelvedFiles and MoveMarkedFiles menu actions' {
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

    # ── File menu now includes delete-shelved support ─────────────────────────

    It 'File menu has 11 navigable items including DeleteShelvedFiles, SubmitChange, ResolveFile and MergeTool' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $navCount = Get-MenuNavigableCount -ComputedItems $items
        $navCount | Should -Be 11
    }

    # ── DeleteChange ─────────────────────────────────────────────────────────

    It 'MenuSelect DeleteChange opens confirm dialog when marks exist' {
        # Mark 101 and 102
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        # Open File menu and select DeleteChange (nav index 0)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = 0; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'DeleteMarked'
        $next.Ui.OverlayPayload.OnAccept.Kind         | Should -Be 'ExecuteWorkflow'
    }

    It 'DeleteChange confirm dialog OnAccept.ChangeIds contains all marked IDs' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = 0; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '101'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '102'
    }

    It 'DeleteChange menu item is enabled when focused changelist exists' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $deleteItem = $items | Where-Object { [string]$_.Id -eq 'DeleteChange' } | Select-Object -First 1
        $deleteItem.IsEnabled | Should -Be $true
    }

    It 'DeleteChange menu item is enabled when marks exist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $deleteItem = $items | Where-Object { [string]$_.Id -eq 'DeleteChange' } | Select-Object -First 1
        $deleteItem.IsEnabled | Should -Be $true
    }

    It 'DeleteChange menu item is disabled in Submitted view even with marks' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $deleteItem = $items | Where-Object { [string]$_.Id -eq 'DeleteChange' } | Select-Object -First 1
        $deleteItem.IsEnabled | Should -Be $false
    }

    # ── DeleteShelvedFiles ───────────────────────────────────────────────────

    It 'DeleteShelvedFiles menu item is enabled when the focused changelist has shelved files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $item = $items | Where-Object { [string]$_.Id -eq 'DeleteShelvedFiles' } | Select-Object -First 1
        $item.IsEnabled | Should -Be $true
    }

    It 'DeleteShelvedFiles menu item is disabled when the focused changelist has no shelved files' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $item = $items | Where-Object { [string]$_.Id -eq 'DeleteShelvedFiles' } | Select-Object -First 1
        $item.IsEnabled | Should -Be $false
    }

    It 'DeleteShelvedFiles menu item is enabled when marked changelists include shelved files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $item = $items | Where-Object { [string]$_.Id -eq 'DeleteShelvedFiles' } | Select-Object -First 1
        $item.IsEnabled | Should -Be $true
    }

    It 'DeleteShelvedFiles menu item is disabled when marks exist but none have shelved files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $item = $items | Where-Object { [string]$_.Id -eq 'DeleteShelvedFiles' } | Select-Object -First 1
        $item.IsEnabled | Should -Be $false
    }

    It 'DeleteShelvedFiles menu item is disabled in Submitted view' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $item = $items | Where-Object { [string]$_.Id -eq 'DeleteShelvedFiles' } | Select-Object -First 1
        $item.IsEnabled | Should -Be $false
    }

    It 'MenuSelect DeleteShelvedFiles opens confirm dialog when marks exist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = 1; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'DeleteShelvedFiles'
    }

    It 'DeleteShelvedFiles accelerator U opens the confirm dialog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'U' })
        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'DeleteShelvedFiles'
    }

    # ── MoveMarkedFiles ───────────────────────────────────────────────────────

    It 'MenuSelect MoveMarkedFiles opens confirm dialog when marks and focus exist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        # Advance focus to CL 102 to set a distinct target
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        # MoveMarkedFiles is nav index 2
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = 2; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'MoveMarkedFiles'
        $next.Ui.OverlayPayload.OnAccept.Kind         | Should -Be 'ExecuteWorkflow'
    }

    It 'MoveMarkedFiles confirm dialog OnAccept.TargetChangeId is the focused CL' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        # Focus is now on CL 101 (index 0)

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = 2; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        $next.Ui.OverlayPayload.OnAccept.TargetChangeId | Should -Be '101'
    }

    It 'MoveMarkedFiles confirm dialog OnAccept.ChangeIds contains marked IDs' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = 2; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '101'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '102'
    }

    It 'MoveMarkedFiles menu item is disabled when no marks exist' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $mmItem = $items | Where-Object { [string]$_.Id -eq 'MoveMarkedFiles' } | Select-Object -First 1
        $mmItem.IsEnabled | Should -Be $false
    }

    It 'MoveMarkedFiles menu item is enabled when marks and visible CLs exist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $mmItem = $items | Where-Object { [string]$_.Id -eq 'MoveMarkedFiles' } | Select-Object -First 1
        $mmItem.IsEnabled | Should -Be $true
    }

    It 'MoveMarkedFiles accelerator M opens the confirm dialog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'M' })
        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'MoveMarkedFiles'
    }

    It 'DeleteChange accelerator X opens the confirm dialog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'X' })
        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'DeleteMarked'
    }

    # ── ShelveFiles ───────────────────────────────────────────────────────────

    It 'ShelveFiles menu item is enabled when the focused changelist has opened files' {
        $items  = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $sfItem = $items | Where-Object { [string]$_.Id -eq 'ShelveFiles' } | Select-Object -First 1
        $sfItem.IsEnabled | Should -Be $true
    }

    It 'ShelveFiles menu item is disabled when the focused changelist has no opened files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })

        $items  = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $sfItem = $items | Where-Object { [string]$_.Id -eq 'ShelveFiles' } | Select-Object -First 1
        $sfItem.IsEnabled | Should -Be $false
    }

    It 'ShelveFiles menu item is enabled when marks exist' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $items  = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $sfItem = $items | Where-Object { [string]$_.Id -eq 'ShelveFiles' } | Select-Object -First 1
        $sfItem.IsEnabled | Should -Be $true
    }

    It 'ShelveFiles menu item is disabled when marked changelists have no opened files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        $items  = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $sfItem = $items | Where-Object { [string]$_.Id -eq 'ShelveFiles' } | Select-Object -First 1
        $sfItem.IsEnabled | Should -Be $false
    }

    It 'ShelveFiles menu item is disabled in Submitted view' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' })
        $items  = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $sfItem = $items | Where-Object { [string]$_.Id -eq 'ShelveFiles' } | Select-Object -First 1
        $sfItem.IsEnabled | Should -Be $false
    }

    It 'ShelveFiles with no marks opens confirm dialog targeting the focused CL' {
        # No marks; focus is on CL 101 (ChangeIndex 0)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $navIdx = 0; $sfIdx = -1
        foreach ($item in $menuItems) {
            if (-not [bool]$item.IsSeparator) {
                if ([string]$item.Id -eq 'ShelveFiles') { $sfIdx = $navIdx; break }
                $navIdx++
            }
        }
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = $sfIdx; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'ShelveFiles'
        $next.Ui.OverlayPayload.OnAccept.Kind         | Should -Be 'ExecuteWorkflow'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '101'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds).Count | Should -Be 1
    }

    It 'ShelveFiles with marks opens confirm dialog with all marked CL IDs' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$menuItems = @($state.Ui.OverlayPayload.MenuItems)
        $navIdx = 0; $sfIdx = -1
        foreach ($item in $menuItems) {
            if (-not [bool]$item.IsSeparator) {
                if ([string]$item.Id -eq 'ShelveFiles') { $sfIdx = $navIdx; break }
                $navIdx++
            }
        }
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'File'; FocusIndex = $sfIdx; MenuItems = $menuItems }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })

        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'ShelveFiles'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '101'
        @($next.Ui.OverlayPayload.OnAccept.ChangeIds) | Should -Contain '102'
    }

    It 'ShelveFiles accelerator S opens the confirm dialog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'S' })
        $next.Ui.OverlayMode                          | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.WorkflowKind | Should -Be 'ShelveFiles'
    }

    # ── SubmitChange ──────────────────────────────────────────────────────────

    It 'SubmitChange menu item is enabled when the focused changelist has opened files' {
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $scItem = $items | Where-Object { [string]$_.Id -eq 'SubmitChange' } | Select-Object -First 1
        [bool]$scItem.IsEnabled | Should -BeTrue
    }

    It 'SubmitChange menu item is disabled when the focused changelist has no opened files' {
        # Focus on CL 103 which has no opened files
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $scItem = $items | Where-Object { [string]$_.Id -eq 'SubmitChange' } | Select-Object -First 1
        [bool]$scItem.IsEnabled | Should -BeFalse
    }

    It 'SubmitChange menu item is disabled in Submitted view' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' })
        $items = @(Get-ComputedMenuItems -MenuName 'File' -State $state)
        $scItem = $items | Where-Object { [string]$_.Id -eq 'SubmitChange' } | Select-Object -First 1
        [bool]$scItem.IsEnabled | Should -BeFalse
    }

    It 'SubmitChange action opens confirm dialog targeting the focused CL' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SubmitChange' })
        $next.Ui.OverlayMode                    | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.Kind   | Should -Be 'SubmitChange'
        $next.Ui.OverlayPayload.OnAccept.ChangeId | Should -Be '101'
    }

    It 'SubmitChange action is no-op when focused CL has no opened files' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SubmitChange' })
        $next.Ui.OverlayMode | Should -Be 'None'
    }

    It 'SubmitChange action is no-op on empty list' {
        $emptyState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $next = Invoke-BrowserReducer -State $emptyState -Action ([pscustomobject]@{ Type = 'SubmitChange' })
        $next.Ui.OverlayMode | Should -Be 'None'
    }

    It 'SubmitChange confirm dialog accepted sets PendingRequest with kind SubmitChange' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SubmitChange' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'AcceptDialog' })
        $next.Runtime.PendingRequest.Kind     | Should -Be 'SubmitChange'
        $next.Runtime.PendingRequest.ChangeId | Should -Be '101'
    }

    It 'SubmitChange accelerator T opens the confirm dialog' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = 'T' })
        $next.Ui.OverlayMode                    | Should -Be 'Confirm'
        $next.Ui.OverlayPayload.OnAccept.Kind   | Should -Be 'SubmitChange'
    }
}

# ─── Phase 6: Hardening ───────────────────────────────────────────────────────

Describe 'Phase 6 — LastWorkflowResult and ReconcileMarks' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One';   HasShelvedFiles = $false; HasOpenedFiles = $true;  Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = '102'; Title = 'Two';   HasShelvedFiles = $false; HasOpenedFiles = $true;  Captured = [datetime]'2026-02-09' },
            [pscustomobject]@{ Id = '103'; Title = 'Three'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-02-08' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    # ── LastWorkflowResult ────────────────────────────────────────────────────

    It 'New-BrowserState initialises LastWorkflowResult to null' {
        $state.Runtime.LastWorkflowResult | Should -BeNullOrEmpty
    }

    It 'WorkflowEnd stores LastWorkflowResult with DoneCount and FailedCount' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 3
        })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowItemFailed'; ChangeId = '103'
        })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })

        $next.Runtime.LastWorkflowResult              | Should -Not -BeNullOrEmpty
        $next.Runtime.LastWorkflowResult.Kind         | Should -Be 'DeleteMarked'
        $next.Runtime.LastWorkflowResult.DoneCount    | Should -Be 2
        $next.Runtime.LastWorkflowResult.FailedCount  | Should -Be 1
        @($next.Runtime.LastWorkflowResult.FailedIds) | Should -Contain '103'
    }

    It 'WorkflowEnd clears ActiveWorkflow and preserves LastWorkflowResult' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 1
        })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })

        $next.Runtime.ActiveWorkflow     | Should -BeNullOrEmpty
        $next.Runtime.LastWorkflowResult | Should -Not -BeNullOrEmpty
    }

    It 'WorkflowBegin clears LastWorkflowResult from previous workflow' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'DeleteMarked'; TotalCount = 1
        })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowItemComplete' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })
        # Confirm result was set
        $state.Runtime.LastWorkflowResult | Should -Not -BeNullOrEmpty

        # Starting a new workflow clears the previous result
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'WorkflowBegin'; Kind = 'MoveMarkedFiles'; TotalCount = 2
        })
        $next.Runtime.LastWorkflowResult | Should -BeNullOrEmpty
    }

    It 'WorkflowEnd when no ActiveWorkflow leaves LastWorkflowResult unchanged' {
        # Inject a previous result
        $state.Runtime.LastWorkflowResult = [pscustomobject]@{
            Kind = 'DeleteMarked'; DoneCount = 5; FailedCount = 0; FailedIds = @()
        }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'WorkflowEnd' })
        $next.Runtime.LastWorkflowResult.DoneCount | Should -Be 5
    }

    # ── ReconcileMarks ────────────────────────────────────────────────────────

    It 'ReconcileMarks removes IDs that are no longer in AllChangeIds' {
        # Mark 101, 102, 999 (999 is stale — not in the new list)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })
        [void]$state.Query.MarkedChangeIds.Add('999')  # simulate stale ID

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type         = 'ReconcileMarks'
            AllChangeIds = @('101', '102', '103')
        })

        $next.Query.MarkedChangeIds | Should -Contain '101'
        $next.Query.MarkedChangeIds | Should -Contain '102'
        $next.Query.MarkedChangeIds | Should -Not -Contain '999'
    }

    It 'ReconcileMarks keeps valid IDs intact' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type         = 'ReconcileMarks'
            AllChangeIds = @('101', '102', '103')
        })

        $next.Query.MarkedChangeIds | Should -Contain '101'
    }

    It 'ReconcileMarks with empty AllChangeIds removes all marks' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'SwitchPane' })
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ToggleMarkCurrent' })

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type         = 'ReconcileMarks'
            AllChangeIds = @()
        })

        $next.Query.MarkedChangeIds.Count | Should -Be 0
    }

    It 'ReconcileMarks is a global action' {
        (Test-IsBrowserGlobalAction -ActionType 'ReconcileMarks') | Should -BeTrue
    }
}

Describe 'Browser reducer — M4 async actions' {
    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'AsyncCommandStarted sets ActiveCommand and IsBusy' {
        $started = [datetime]'2026-01-01 10:00:00'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type        = 'AsyncCommandStarted'
            RequestId   = 'req-1'
            Kind        = 'ReloadPending'
            Scope       = 'Global'
            Generation  = 0
            CommandLine = 'p4 changes -s pending'
            StartedAt   = $started
        })
        $next.Runtime.ActiveCommand.RequestId   | Should -Be 'req-1'
        $next.Runtime.ActiveCommand.Kind        | Should -Be 'ReloadPending'
        $next.Runtime.ActiveCommand.StartedAt   | Should -Be $started
        $next.Runtime.ModalPrompt.IsBusy        | Should -BeTrue
    }

    It 'CommandFinish clears ActiveCommand' {
        $state.Runtime.ActiveCommand = [pscustomobject]@{ RequestId = 'req-1'; Kind = 'ReloadPending' }
        $state.Runtime.ModalPrompt.IsBusy = $true
        $started = (Get-Date).AddSeconds(-1)
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type        = 'CommandFinish'
            CommandLine = 'p4 changes -s pending'
            ExitCode    = 0
            Succeeded   = $true
            DurationMs  = 120
            ErrorText   = ''
            StartedAt   = $started
            EndedAt     = $started.AddMilliseconds(120)
        })
        $next.Runtime.ActiveCommand | Should -BeNullOrEmpty
    }

    It 'PendingChangesLoaded updates AllChanges and clears ActiveCommand' {
        $state.Runtime.ActiveCommand = [pscustomobject]@{ RequestId = 'req-1'; Kind = 'ReloadPending' }
        $generation = $state.Data.PendingGeneration
        $newChanges = @(
            [pscustomobject]@{ Id = '201'; Title = 'New'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-03-01' }
        )
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type       = 'PendingChangesLoaded'
            AllChanges = $newChanges
            Generation = $generation
        })
        $next.Data.AllChanges.Count   | Should -Be 1
        $next.Data.AllChanges[0].Id   | Should -Be '201'
        $next.Runtime.ActiveCommand   | Should -BeNullOrEmpty
    }

    It 'PendingChangesLoaded with stale generation drops update but clears ActiveCommand' {
        $state.Runtime.ActiveCommand = [pscustomobject]@{ RequestId = 'req-1'; Kind = 'ReloadPending' }
        $newChanges = @(
            [pscustomobject]@{ Id = '999'; Title = 'Stale'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-03-01' }
        )
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type       = 'PendingChangesLoaded'
            AllChanges = $newChanges
            Generation = -1   # stale
        })
        # AllChanges unchanged — original change still there
        $next.Data.AllChanges.Count | Should -Be 1
        $next.Data.AllChanges[0].Id | Should -Be '101'
        # ActiveCommand cleared even on stale drop
        $next.Runtime.ActiveCommand | Should -BeNullOrEmpty
    }

    It 'SubmittedChangesLoaded (replace) updates SubmittedChanges' {
        $gen = $state.Data.SubmittedGeneration
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type       = 'SubmittedChangesLoaded'
            Entries    = @(
                [pscustomobject]@{ Id = '501'; Title = 'Sub'; Kind = 'Submitted'; User = 'alice'
                    Captured = [datetime]'2026-03-01'; HasOpenedFiles = $false; HasShelvedFiles = $false }
            )
            Generation = $gen
            AppendMode = $false
            OldestId   = '501'
            HasMore    = $false
        })
        $next.Data.SubmittedChanges.Count | Should -Be 1
        $next.Data.SubmittedChanges[0].Id | Should -Be '501'
    }

    It 'SubmittedChangesLoaded (append) appends to SubmittedChanges' {
        $gen = $state.Data.SubmittedGeneration
        $state.Data.SubmittedChanges = @(
            [pscustomobject]@{ Id = '501'; Title = 'Original'; Kind = 'Submitted'; User = 'alice'
                Captured = [datetime]'2026-03-01'; HasOpenedFiles = $false; HasShelvedFiles = $false }
        )
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type       = 'SubmittedChangesLoaded'
            Entries    = @(
                [pscustomobject]@{ Id = '502'; Title = 'More'; Kind = 'Submitted'; User = 'alice'
                    Captured = [datetime]'2026-03-01'; HasOpenedFiles = $false; HasShelvedFiles = $false }
            )
            Generation = $gen
            AppendMode = $true
            OldestId   = '502'
            HasMore    = $false
        })
        $next.Data.SubmittedChanges.Count | Should -Be 2
    }

    It 'FilesBaseLoaded (Submitted) sets FileCacheStatus to Ready' {
        $gen      = $state.Data.FilesGeneration
        $cacheKey = '101:Submitted'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type       = 'FilesBaseLoaded'
            CacheKey   = $cacheKey
            SourceKind = 'Submitted'
            FileEntries = @()
            Generation = $gen
        })
        $next.Data.FileCacheStatus[$cacheKey] | Should -Be 'Ready'
    }

    It 'FilesBaseLoaded (Opened) sets FileCacheStatus to BaseReady and signals LoadFilesEnrichment' {
        $gen      = $state.Data.FilesGeneration
        $cacheKey = '101:Opened'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type        = 'FilesBaseLoaded'
            CacheKey    = $cacheKey
            SourceKind  = 'Opened'
            FileEntries = @()
            Generation  = $gen
        })
        $next.Data.FileCacheStatus[$cacheKey] | Should -Be 'BaseReady'
        $next.Runtime.PendingRequest.Kind     | Should -Be 'LoadFilesEnrichment'
        $next.Runtime.PendingRequest.CacheKey | Should -Be $cacheKey
    }

    It 'FilesEnrichmentDone updates FileCache and sets status to Ready' {
        $gen      = $state.Data.FilesGeneration
        $cacheKey = '101:Opened'
        $state.Data.FileCacheStatus = @{ $cacheKey = 'BaseReady' }
        $enrichedFiles = @(
            [pscustomobject]@{ DepotPath = '//depot/foo.txt'; Action = 'edit'; ClientPath = 'C:\foo.txt' }
        )
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type        = 'FilesEnrichmentDone'
            CacheKey    = $cacheKey
            FileEntries = $enrichedFiles
            Generation  = $gen
        })
        $next.Data.FileCacheStatus[$cacheKey] | Should -Be 'Ready'
        $next.Data.FileCache[$cacheKey].Count | Should -Be 1
        $next.Runtime.ActiveCommand           | Should -BeNullOrEmpty
    }

    It 'DescribeLoaded updates DescribeCache' {
        $describe = [pscustomobject]@{ Description = 'A great change'; Files = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type     = 'DescribeLoaded'
            Change   = '101'
            Describe = $describe
        })
        $null -ne $next.Data.DescribeCache['101']        | Should -BeTrue
        $next.Data.DescribeCache['101'].Description      | Should -Be 'A great change'
    }

    It 'AsyncCommandCancelling marks ActiveCommand as Cancelling' {
        $state.Runtime.ActiveCommand = [pscustomobject]@{
            RequestId = 'req-1'; Kind = 'ReloadPending'; Scope = 'Pending'; Generation = 0
            CommandLine = 'p4 changes -s pending'; StartedAt = (Get-Date); Status = 'Running'
        }

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type      = 'AsyncCommandCancelling'
            RequestId = 'req-1'
        })

        $next.Runtime.ActiveCommand.Status | Should -Be 'Cancelling'
    }

    It 'ProcessStarted and ProcessFinished update active process tracking' {
        $state.Runtime.ActiveCommand = [pscustomobject]@{
            RequestId = 'req-1'; Kind = 'DeleteChange'; Scope = 'Mutation'; Generation = 0
            CommandLine = 'p4 change -d 101'; StartedAt = (Get-Date); Status = 'Running'
            CurrentProcessId = $null; ProcessIds = @()
        }

        $started = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'ProcessStarted'; RequestId = 'req-1'; ProcessId = 4242
        })
        $started.Runtime.ActiveCommand.CurrentProcessId | Should -Be 4242
        @($started.Runtime.ActiveCommand.ProcessIds)    | Should -Contain 4242

        $finished = Invoke-BrowserReducer -State $started -Action ([pscustomobject]@{
            Type = 'ProcessFinished'; RequestId = 'req-1'; ProcessId = 4242; ExitCode = 0
        })
        @($finished.Runtime.ActiveCommand.ProcessIds).Count | Should -Be 0
        $finished.Runtime.ActiveCommand.CurrentProcessId    | Should -BeNullOrEmpty
    }

    It 'ProcessStarted and ProcessFinished ignore malformed process-id entries' {
        $state.Runtime.ActiveCommand = [pscustomobject]@{
            RequestId = 'req-1'; Kind = 'DeleteChange'; Scope = 'Mutation'; Generation = 0
            CommandLine = 'p4 change -d 101'; StartedAt = (Get-Date); Status = 'Running'
            CurrentProcessId = $null; ProcessIds = @($null, '', '4242')
        }

        $started = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'ProcessStarted'; RequestId = 'req-1'; ProcessId = 4242
        })
        @($started.Runtime.ActiveCommand.ProcessIds) | Should -Be @(4242)

        $finished = Invoke-BrowserReducer -State $started -Action ([pscustomobject]@{
            Type = 'ProcessFinished'; RequestId = 'req-1'; ProcessId = 4242; ExitCode = 0
        })
        @($finished.Runtime.ActiveCommand.ProcessIds).Count | Should -Be 0
    }

    It 'FilesEnrichmentFailed marks cache status and records the error' {
        $cacheKey = '101:Opened'
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type      = 'FilesEnrichmentFailed'
            CacheKey  = $cacheKey
            ErrorText = 'p4 diff timed out'
        })

        $next.Data.FileCacheStatus[$cacheKey] | Should -Be 'EnrichmentFailed'
        $next.Runtime.LastError               | Should -Be 'p4 diff timed out'
    }

    It 'UnmarkChanges removes completed workflow change ids from the mark set' {
        [void]$state.Query.MarkedChangeIds.Add('101')
        [void]$state.Query.MarkedChangeIds.Add('102')

        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type      = 'UnmarkChanges'
            ChangeIds = @('101')
        })

        @($next.Query.MarkedChangeIds) | Should -Not -Contain '101'
        @($next.Query.MarkedChangeIds) | Should -Contain '102'
    }

    It 'M4 async action types are all registered as global actions' {
        (Test-IsBrowserGlobalAction -ActionType 'AsyncCommandStarted')    | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'PendingChangesLoaded')   | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'SubmittedChangesLoaded') | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'FilesBaseLoaded')        | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'FilesEnrichmentDone')    | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'DescribeLoaded')         | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'AsyncCommandCancelling') | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'CommandCancelled')       | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'ProcessStarted')         | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'ProcessFinished')        | Should -BeTrue
        (Test-IsBrowserGlobalAction -ActionType 'MutationCompleted')      | Should -BeTrue
    }
}

Describe 'OpenResolveSettings and SelectMergeTool' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
    }

    It 'OpenResolveSettings opens Menu overlay with ActiveMenu = Select merge tool' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next.Ui.OverlayMode               | Should -Be 'Menu'
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'Select merge tool'
    }

    It 'OpenResolveSettings menu contains one item per preset plus Enter path manually' {
        $next     = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        [object[]]$navigable = @($next.Ui.OverlayPayload.MenuItems | Where-Object { -not [bool]$_.IsSeparator })
        $presetCount = @(Get-P4MergeToolPresets).Count
        $navigable.Count | Should -Be ($presetCount + 1)    # presets + manual
    }

    It 'OpenResolveSettings last navigable item is MergeToolManual' {
        $next     = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        [object[]]$navigable = @($next.Ui.OverlayPayload.MenuItems | Where-Object { -not [bool]$_.IsSeparator })
        $navigable[-1].Id | Should -Be 'MergeToolManual'
    }

    It 'OpenResolveSettings preset items have IDs SelectMergeTool_0, _1, _2' {
        $next     = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        [object[]]$presetItems = @($next.Ui.OverlayPayload.MenuItems | Where-Object { [string]$_.Id -match '^SelectMergeTool_\d+$' })
        $presetItems.Count | Should -Be 3
        $presetItems[0].Id | Should -Be 'SelectMergeTool_0'
    }

    It 'OpenResolveSettings is a no-op when a non-Menu overlay is already open' {
        $state.Ui.OverlayMode    = 'Confirm'
        $state.Ui.OverlayPayload = [pscustomobject]@{ Title = 'Test?'; SummaryLines = @() }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next.Ui.OverlayMode | Should -Be 'Confirm'
    }

    It 'OpenResolveSettings is a global action and is forwarded on the Files screen' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next.Ui.OverlayMode     | Should -Be 'Menu'
        $next.Ui.ScreenStack[-1] | Should -Be 'Files'
    }

    It 'OpenResolveSettings is a global action' {
        (Test-IsBrowserGlobalAction -ActionType 'OpenResolveSettings') | Should -BeTrue
    }

    It 'MenuSwitchLeft is a no-op when ResolveSettings overlay is open' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSwitchLeft' })
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'Select merge tool'
    }

    It 'MenuSwitchRight is a no-op when ResolveSettings overlay is open' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSwitchRight' })
        $next.Ui.OverlayPayload.ActiveMenu | Should -Be 'Select merge tool'
    }

    It 'MenuSelect on SelectMergeTool_0 closes overlay and sets PendingRequest Kind SetMergeTool' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        # FocusIndex 0 = SelectMergeTool_0 (P4Merge)
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })
        $next.Ui.OverlayMode                 | Should -Be 'None'
        $next.Runtime.PendingRequest.Kind    | Should -Be 'SetMergeTool'
        $next.Runtime.PendingRequest.ToolPath | Should -Not -BeNullOrEmpty
    }

    It 'MenuSelect on SelectMergeTool_0 carries P4Merge path in PendingRequest' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })
        $expected = [string](@(Get-P4MergeToolPresets)[0].Path)
        $next.Runtime.PendingRequest.ToolPath | Should -Be $expected
    }

    It 'MenuSelect on MergeToolManual opens a Confirm overlay' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        [object[]]$items = @($state.Ui.OverlayPayload.MenuItems)
        # Find navigable index of MergeToolManual
        $navIdx = 0
        $manualNavIdx = -1
        foreach ($item in $items) {
            if (-not [bool]$item.IsSeparator) {
                if ([string]$item.Id -eq 'MergeToolManual') { $manualNavIdx = $navIdx; break }
                $navIdx++
            }
        }
        $state.Ui.OverlayPayload = [pscustomobject]@{ ActiveMenu = 'Select merge tool'; FocusIndex = $manualNavIdx; MenuItems = $items }
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuSelect' })
        $next.Ui.OverlayMode | Should -Be 'Confirm'
    }

    It 'MenuAccelerator 1 on ResolveSettings selects P4Merge preset (accelerator R)' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenResolveSettings' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MenuAccelerator'; Key = '1' })
        $next.Ui.OverlayMode                 | Should -Be 'None'
        $next.Runtime.PendingRequest.Kind    | Should -Be 'SetMergeTool'
    }

    It 'ResolveFile menu item exists in File menu definition' {
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' })
        [object[]]$items = @($state.Ui.OverlayPayload.MenuItems)
        $ids = @($items | Where-Object { -not [bool]$_.IsSeparator } | ForEach-Object { [string]$_.Id })
        $ids | Should -Contain 'ResolveFile'
    }
}

Describe 'ResolveFile action and dual-refresh chain' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    BeforeEach {
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'OpenFilesScreen' })
        $state.Runtime.PendingRequest = $null
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $state.Data.FileCache[$cacheKey] = @(
            [pscustomobject]@{ DepotPath = '//depot/main/a.txt'; IsUnresolved = $true  },
            [pscustomobject]@{ DepotPath = '//depot/main/b.txt'; IsUnresolved = $false }
        )
        $state = Update-BrowserDerivedState -State $state
    }

    # ── New-BrowserState state flag ───────────────────────────────────────────

    It 'New-BrowserState includes ReloadPendingAfterEnrichment defaulting to $false' {
        $fresh = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $fresh.Data.ReloadPendingAfterEnrichment | Should -BeFalse
    }

    # ── ResolveFile on Files screen — file is unresolved, P4MERGE is set ──────

    It 'ResolveFile sets PendingRequest Kind=ResolveFile when file is unresolved' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ResolveFile' })
        $next.Runtime.PendingRequest.Kind      | Should -Be 'ResolveFile'
        $next.Runtime.PendingRequest.DepotPath | Should -Be '//depot/main/a.txt'
    }

    It 'ResolveFile sets LastError and no PendingRequest when focused file is not unresolved' {
        # Move focus to file index 1 (IsUnresolved = $false)
        $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'ResolveFile' })
        $next.Runtime.LastError         | Should -Not -BeNullOrEmpty
        $next.Runtime.PendingRequest    | Should -BeNullOrEmpty
    }

    # ── MutationCompleted(ResolveFile) sets the dual-refresh flag ─────────────

    It 'MutationCompleted with MutationKind=ResolveFile sets ReloadPendingAfterEnrichment' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'MutationCompleted'; MutationKind = 'ResolveFile'; RequestId = 'req-1'; Generation = 0
        })
        $next.Data.ReloadPendingAfterEnrichment | Should -BeTrue
    }

    It 'MutationCompleted with other MutationKind does not set ReloadPendingAfterEnrichment' {
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type = 'MutationCompleted'; MutationKind = 'DeleteChange'; RequestId = 'req-1'; Generation = 0
        })
        $next.Data.ReloadPendingAfterEnrichment | Should -BeFalse
    }

    # ── FilesEnrichmentDone chains ReloadPending when flag is set ─────────────

    It 'FilesEnrichmentDone chains PendingRequest=ReloadPending when ReloadPendingAfterEnrichment is true' {
        $state.Data.ReloadPendingAfterEnrichment = $true
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type        = 'FilesEnrichmentDone'
            CacheKey    = $cacheKey
            Generation  = $state.Data.FilesGeneration
            FileEntries = @()
        })
        $next.Runtime.PendingRequest.Kind            | Should -Be 'ReloadPending'
        $next.Data.ReloadPendingAfterEnrichment       | Should -BeFalse
    }

    It 'FilesEnrichmentDone does not chain ReloadPending when ReloadPendingAfterEnrichment is false' {
        $state.Data.ReloadPendingAfterEnrichment = $false
        $cacheKey = "$($state.Data.FilesSourceChange)`:$($state.Data.FilesSourceKind)"
        $next = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
            Type        = 'FilesEnrichmentDone'
            CacheKey    = $cacheKey
            Generation  = $state.Data.FilesGeneration
            FileEntries = @()
        })
        $next.Runtime.PendingRequest | Should -BeNullOrEmpty
    }
}
