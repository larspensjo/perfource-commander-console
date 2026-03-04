Describe 'Get-VisibleChangeIds' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\tui\Filtering.psm1'
        Import-Module $modulePath -Force

        $ideas = @(
            [pscustomobject]@{ Id = 'FI-A-0001'; Title = 'Alpha'; Filters = @('ux', 'preview'); Priority = 'P2'; Risk = 'M'; Captured = [datetime]'2026-02-10' },
            [pscustomobject]@{ Id = 'FI-A-0002'; Title = 'Beta'; Filters = @('ux'); Priority = 'P1'; Risk = 'H'; Captured = [datetime]'2026-02-12' },
            [pscustomobject]@{ Id = 'FI-A-0003'; Title = 'Gamma'; Filters = @('security'); Priority = 'P1'; Risk = 'L'; Captured = [datetime]'2026-02-11' }
        )
    }

    It 'returns all ids when selected filters is null' {
        $ids = Get-VisibleChangeIds -AllChanges $ideas -SelectedFilters $null
        $ids | Should -Be @('FI-A-0001', 'FI-A-0002', 'FI-A-0003')
    }

    It 'uses AND semantics for filters' {
        $ids = Get-VisibleChangeIds -AllChanges $ideas -SelectedFilters @('ux', 'preview')
        $ids | Should -Be @('FI-A-0001')
    }

    It 'returns empty result when no idea matches' {
        $ids = Get-VisibleChangeIds -AllChanges $ideas -SelectedFilters @('does-not-exist')
        $ids.Count | Should -Be 0
    }

    It 'has stable tie-breaker by id for same priority' {
        $ids = Get-VisibleChangeIds -AllChanges $ideas -SelectedFilters @() -SortMode Priority
        $ids | Should -Be @('FI-A-0002', 'FI-A-0003', 'FI-A-0001')
    }
}
