Describe 'Get-VisibleChangeIds' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\tui\Filtering.psm1'
        Import-Module $modulePath -Force

        # 101: no shelved, has files
        # 102: has shelved, has files
        # 103: no shelved, no files (empty)
        $changes = @(
            [pscustomobject]@{ Id = '101'; Title = 'Alpha'; HasShelvedFiles = $false; HasOpenedFiles = $true;  Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = '102'; Title = 'Beta';  HasShelvedFiles = $true;  HasOpenedFiles = $true;  Captured = [datetime]'2026-02-12' },
            [pscustomobject]@{ Id = '103'; Title = 'Gamma'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-02-11' }
        )
    }

    It 'returns all ids when selected filters is null' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters $null
        $ids | Should -Be @('101', '102', '103')
    }

    It 'returns all ids when selected filters is empty' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters @()
        $ids | Should -Be @('101', '102', '103')
    }

    It 'No shelved files filter excludes CLs with shelved files' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters @('No shelved files')
        $ids | Should -Be @('101', '103')
    }

    It 'No opened files filter shows only CLs with no opened files' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters @('No opened files')
        $ids | Should -Be @('103')
    }

    It 'uses AND semantics across filters' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters @('No shelved files', 'No opened files')
        $ids | Should -Be @('103')
    }

    It 'unknown filter name has no effect' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters @('does-not-exist')
        $ids | Should -Be @('101', '102', '103')
    }

    It 'returns empty when all CLs are excluded' {
        $allShelved = @(
            [pscustomobject]@{ Id = '201'; Title = 'A'; HasShelvedFiles = $true; HasOpenedFiles = $true; Captured = [datetime]'2026-02-10' }
        )
        $ids = Get-VisibleChangeIds -AllChanges $allShelved -SelectedFilters @('No shelved files')
        $ids.Count | Should -Be 0
    }

    It 'sorts by CapturedDesc' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters @() -SortMode CapturedDesc
        $ids | Should -Be @('102', '103', '101')
    }

    It 'filters by search text' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters $null -SearchText 'alph' -SearchMode Text
        $ids | Should -Be @('101')
    }

    It 'filters by search regex' {
        $ids = Get-VisibleChangeIds -AllChanges $changes -SelectedFilters $null -SearchText '^(Beta|Gamma)$' -SearchMode Regex
        $ids | Should -Be @('102', '103')
    }
}

Describe 'Filter predicate helpers' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\tui\Filtering.psm1'
        Import-Module $modulePath -Force
    }

    It 'Get-AllFilterNames returns the two predefined filters' {
        $names = Get-AllFilterNames
        $names | Should -Contain 'No shelved files'
        $names | Should -Contain 'No opened files'
        $names.Count | Should -Be 2
    }

    It 'Test-EntryMatchesFilter: No shelved files passes when HasShelvedFiles false' {
        $entry = [pscustomobject]@{ HasShelvedFiles = $false; HasOpenedFiles = $true }
        Test-EntryMatchesFilter -FilterName 'No shelved files' -Entry $entry | Should -BeTrue
    }

    It 'Test-EntryMatchesFilter: No shelved files fails when HasShelvedFiles true' {
        $entry = [pscustomobject]@{ HasShelvedFiles = $true; HasOpenedFiles = $true }
        Test-EntryMatchesFilter -FilterName 'No shelved files' -Entry $entry | Should -BeFalse
    }

    It 'Test-EntryMatchesFilter: No opened files passes when HasOpenedFiles false' {
        $entry = [pscustomobject]@{ HasShelvedFiles = $false; HasOpenedFiles = $false }
        Test-EntryMatchesFilter -FilterName 'No opened files' -Entry $entry | Should -BeTrue
    }

    It 'Test-EntryMatchesFilter: No opened files fails when HasOpenedFiles true' {
        $entry = [pscustomobject]@{ HasShelvedFiles = $false; HasOpenedFiles = $true }
        Test-EntryMatchesFilter -FilterName 'No opened files' -Entry $entry | Should -BeFalse
    }

    It 'Test-EntryMatchesFilter: unknown filter name returns false' {
        $entry = [pscustomobject]@{ HasShelvedFiles = $false; HasOpenedFiles = $false }
        Test-EntryMatchesFilter -FilterName 'Nonexistent' -Entry $entry | Should -BeFalse
    }
}

Describe 'Get-CommandLogFilterPredicates' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\tui\Filtering.psm1'
        Import-Module $modulePath -Force
    }

    It 'returns OK predicate that matches Succeeded=true entries' {
        $entry     = [pscustomobject]@{ Succeeded = $true; CommandLine = 'p4 changes' }
        $predicates = Get-CommandLogFilterPredicates -CommandLog @($entry)
        $predicates.Contains('OK') | Should -BeTrue
        $predicates['OK'].Invoke($entry) | Should -BeTrue
    }

    It 'returns OK predicate that rejects Succeeded=false entries' {
        $entry      = [pscustomobject]@{ Succeeded = $false; CommandLine = 'p4 changes' }
        $predicates = Get-CommandLogFilterPredicates -CommandLog @($entry)
        $predicates['OK'].Invoke($entry) | Should -BeFalse
    }

    It 'returns Error predicate matching failed entries' {
        $entry      = [pscustomobject]@{ Succeeded = $false; CommandLine = 'p4 info' }
        $predicates = Get-CommandLogFilterPredicates -CommandLog @($entry)
        $predicates.Contains('Error') | Should -BeTrue
        $predicates['Error'].Invoke($entry) | Should -BeTrue
    }

    It 'extracts command-type predicates from CommandLine' {
        $log = @(
            [pscustomobject]@{ Succeeded = $true; CommandLine = 'p4 changes -s pending' },
            [pscustomobject]@{ Succeeded = $true; CommandLine = 'p4 info' }
        )
        $predicates = Get-CommandLogFilterPredicates -CommandLog $log
        $predicates.Contains('cmd:changes') | Should -BeTrue
        $predicates.Contains('cmd:info')    | Should -BeTrue
    }

    It 'cmd predicate matches only entries with that subcommand' {
        $changes = [pscustomobject]@{ Succeeded = $true; CommandLine = 'p4 changes -s pending' }
        $info    = [pscustomobject]@{ Succeeded = $true; CommandLine = 'p4 info' }
        $log     = @($changes, $info)
        $predicates = Get-CommandLogFilterPredicates -CommandLog $log
        $predicates['cmd:changes'].Invoke($changes) | Should -BeTrue
        $predicates['cmd:changes'].Invoke($info)    | Should -BeFalse
    }

    It 'returns empty predicates when CommandLog is empty' {
        $predicates = Get-CommandLogFilterPredicates -CommandLog @()
        $predicates.Count | Should -Be 0
    }

    It 'handles unrecognised command line without error' {
        $entry      = [pscustomobject]@{ Succeeded = $true; CommandLine = 'something weird' }
        $predicates = Get-CommandLogFilterPredicates -CommandLog @($entry)
        # Should at minimum contain OK/Error
        $predicates.Contains('OK') | Should -BeTrue
    }
}
