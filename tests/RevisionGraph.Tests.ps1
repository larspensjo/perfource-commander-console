# tests/RevisionGraph.Tests.ps1 — Phase 1 tests for the revision graph feature.
# Covers: P4FileLog parsing, GraphReducer state transitions, and GraphRender output.

$rootPath = Join-Path $PSScriptRoot '..'
Import-Module (Join-Path $rootPath 'p4\Models.psm1')        -Force -Global
Import-Module (Join-Path $rootPath 'p4\P4Cli.psm1')         -Force -Global
Import-Module (Join-Path $rootPath 'tui\Theme.psm1')        -Force -Global
Import-Module (Join-Path $rootPath 'tui\Layout.psm1')       -Force -Global
Import-Module (Join-Path $rootPath 'tui\Filtering.psm1')    -Force -Global
Import-Module (Join-Path $rootPath 'tui\Reducer.psm1')      -Force -Global
Import-Module (Join-Path $rootPath 'tui\GraphReducer.psm1') -Force -Global
Import-Module (Join-Path $rootPath 'tui\Helpers.psm1')      -Force -Global
Import-Module (Join-Path $rootPath 'tui\Render.psm1')       -Force -Global -DisableNameChecking
Import-Module (Join-Path $rootPath 'tui\GraphRender.psm1')  -Force -Global -DisableNameChecking

function New-MinimalState {
    param([int]$Width = 120, [int]$Height = 40)
    New-BrowserState -Changes @() -InitialWidth $Width -InitialHeight $Height
}

function New-MockFileLogRecord {
    param(
        [string]$DepotFile = '//depot/main/foo.cpp',
        [int]$Rev       = 1,
        [int]$Change    = 40000,
        [string]$Action = 'add',
        [string]$User   = 'artist',
        [string]$Client = 'WORKSTATION',
        [int]$Time      = 1700000000,
        [string]$Desc   = 'First revision',
        [hashtable[]]$Howfiles = @()
    )

    $obj = [ordered]@{
        depotFile = $DepotFile
        rev       = "$Rev"
        change    = "$Change"
        action    = $Action
        type      = 'text'
        time      = "$Time"
        user      = $User
        client    = $Client
        desc      = $Desc
    }
    for ($i = 0; $i -lt $Howfiles.Count; $i++) {
        $obj["how$i"]  = $Howfiles[$i].How
        $obj["file$i"] = $Howfiles[$i].File
        $obj["srev$i"] = "#$($Howfiles[$i].StartRev)"
        $obj["erev$i"] = "#$($Howfiles[$i].EndRev)"
    }
    return [pscustomobject]$obj
}

# ─── Models ───────────────────────────────────────────────────────────────────

Describe 'Get-IntegrationDirection' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force -Global }
    It 'returns inbound for merge from' {
        Get-IntegrationDirection -How 'merge from' | Should -Be 'inbound'
    }
    It 'returns inbound for copy from' {
        Get-IntegrationDirection -How 'copy from'  | Should -Be 'inbound'
    }
    It 'returns outbound for branch into' {
        Get-IntegrationDirection -How 'branch into' | Should -Be 'outbound'
    }
    It 'returns outbound for merge into' {
        Get-IntegrationDirection -How 'merge into'  | Should -Be 'outbound'
    }
    It 'returns unknown for unrecognised how value' {
        Get-IntegrationDirection -How 'ignored'     | Should -Be 'unknown'
    }
}

Describe 'New-IntegrationRecord' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force -Global }
    It 'sets Direction from How' {
        $rec = New-IntegrationRecord -How 'copy from' -File '//depot/dev/foo.cpp' -StartRev 2 -EndRev 3
        $rec.Direction | Should -Be 'inbound'
        $rec.File      | Should -Be '//depot/dev/foo.cpp'
        $rec.StartRev  | Should -Be 2
        $rec.EndRev    | Should -Be 3
    }
}

Describe 'New-RevisionNode' {
    BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force -Global }
    It 'stores all fields correctly' {
        $integ = New-IntegrationRecord -How 'branch into' -File '//depot/rel/foo.cpp' -StartRev 0 -EndRev 1
        $node  = New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 `
                    -Action 'integrate' -User 'dev' -Client 'WS' -Integrations @($integ)
        $node.Rev         | Should -Be 2
        $node.Change      | Should -Be 41000
        $node.Action      | Should -Be 'integrate'
        $node.Integrations.Count | Should -Be 1
        $node.Integrations[0].How | Should -Be 'branch into'
    }
}

# ─── P4Cli parsing ────────────────────────────────────────────────────────────

Describe 'Get-P4FileLog parsing' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')  -Force
        InModuleScope P4Cli { $script:P4Executable = 'cmd.exe' }

        function script:New-MockFileLogRecord {
            param(
                [string]$DepotFile = '//depot/main/foo.cpp',
                [int]$Rev       = 1,
                [int]$Change    = 40000,
                [string]$Action = 'add',
                [string]$User   = 'artist',
                [string]$Client = 'WORKSTATION',
                [int]$Time      = 1700000000,
                [string]$Desc   = 'First revision',
                [hashtable[]]$Howfiles = @()
            )
            $obj = [ordered]@{
                depotFile = $DepotFile; rev = "$Rev"; change = "$Change"
                action = $Action; type = 'text'; time = "$Time"
                user = $User; client = $Client; desc = $Desc
            }
            for ($i = 0; $i -lt $Howfiles.Count; $i++) {
                $obj["how$i"]  = $Howfiles[$i].How
                $obj["file$i"] = $Howfiles[$i].File
                $obj["srev$i"] = "#$($Howfiles[$i].StartRev)"
                $obj["erev$i"] = "#$($Howfiles[$i].EndRev)"
            }
            return [pscustomobject]$obj
        }
    }
    AfterAll {
        InModuleScope P4Cli { $script:P4Executable = 'p4.exe' }
    }

    It 'parses a single revision with no integrations' {
        $rec1 = New-MockFileLogRecord -DepotFile '//depot/main/foo.cpp' -Rev 1 -Change 40000 -Action 'add'
        $json1 = $rec1 | ConvertTo-Json -Compress

        InModuleScope P4Cli { $script:P4Executable = 'cmd.exe' }

        # Stub Invoke-P4 via mock
        Mock -CommandName Invoke-P4 -ModuleName P4Cli -MockWith {
            return @($rec1)
        }

        $result = InModuleScope P4Cli { Get-P4FileLog -DepotFile '//depot/main/foo.cpp' -Limit 30 }
        $result.Count              | Should -Be 1
        $result[0].DepotFile       | Should -Be '//depot/main/foo.cpp'
        $result[0].Rev             | Should -Be 1
        $result[0].Change          | Should -Be 40000
        $result[0].Action          | Should -Be 'add'
        $result[0].Integrations.Count | Should -Be 0
    }

    It 'parses integration records from numbered fields' {
        $rec = New-MockFileLogRecord -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 `
                   -Action 'integrate' -Howfiles @(
                       @{ How = 'merge from'; File = '//depot/dev/foo.cpp'; StartRev = 2; EndRev = 3 },
                       @{ How = 'branch into'; File = '//depot/release/foo.cpp'; StartRev = 0; EndRev = 1 }
                   )

        Mock -CommandName Invoke-P4 -ModuleName P4Cli -MockWith { return @($rec) }

        $result = InModuleScope P4Cli { Get-P4FileLog -DepotFile '//depot/main/foo.cpp' -Limit 30 }
        $result[0].Integrations.Count    | Should -Be 2
        $result[0].Integrations[0].How   | Should -Be 'merge from'
        $result[0].Integrations[0].Direction | Should -Be 'inbound'
        $result[0].Integrations[0].EndRev    | Should -Be 3
        $result[0].Integrations[1].How   | Should -Be 'branch into'
        $result[0].Integrations[1].Direction | Should -Be 'outbound'
    }

    It 'returns multiple revisions sorted as returned by p4' {
        $rec1 = New-MockFileLogRecord -Rev 4 -Change 45000 -Action 'edit'
        $rec2 = New-MockFileLogRecord -Rev 3 -Change 43500 -Action 'integrate'
        $rec3 = New-MockFileLogRecord -Rev 1 -Change 40000 -Action 'add'

        Mock -CommandName Invoke-P4 -ModuleName P4Cli -MockWith { return @($rec1, $rec2, $rec3) }

        $result = InModuleScope P4Cli { Get-P4FileLog -DepotFile '//depot/main/foo.cpp' -Limit 30 }
        $result.Count        | Should -Be 3
        $result[0].Rev       | Should -Be 4
        $result[1].Rev       | Should -Be 3
        $result[2].Rev       | Should -Be 1
    }
}

# ─── GraphReducer state transitions ──────────────────────────────────────────

Describe 'Invoke-GraphReducer — OpenRevisionGraph' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1')        -Force
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')         -Force
        Import-Module (Join-Path $script:rp 'tui\Theme.psm1')        -Force
        Import-Module (Join-Path $script:rp 'tui\Layout.psm1')       -Force
        Import-Module (Join-Path $script:rp 'tui\Filtering.psm1')    -Force
        Import-Module (Join-Path $script:rp 'tui\Reducer.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\GraphReducer.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'tui\Helpers.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\Render.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $script:rp 'tui\GraphRender.psm1')  -Force -DisableNameChecking
    }
    BeforeEach {
        $script:state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        # Simulate having a Files screen open with a file loaded in the cache
        $fileEntry = New-P4FileEntry -DepotPath '//depot/main/foo.cpp' -Action 'edit' -Change '100'
        $script:state.Data.FileCache['100:Opened'] = @($fileEntry)
        $script:state.Data.FilesSourceChange       = '100'
        $script:state.Data.FilesSourceKind         = 'Opened'
        $script:state.Ui.ScreenStack               = @('Changelists', 'Files')
        $script:state                              = Update-BrowserDerivedState -State $script:state
    }

    It 'pushes RevisionGraph onto ScreenStack' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type      = 'OpenRevisionGraph'
            DepotFile = '//depot/main/foo.cpp'
        })
        $next.Ui.ScreenStack[-1] | Should -Be 'RevisionGraph'
    }

    It 'creates one loading lane' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type      = 'OpenRevisionGraph'
            DepotFile = '//depot/main/foo.cpp'
        })
        $next.Data.RevisionGraph.Lanes.Count | Should -Be 1
        $next.Data.RevisionGraph.Lanes[0].IsLoading  | Should -BeTrue
        $next.Data.RevisionGraph.Lanes[0].DepotFile  | Should -Be '//depot/main/foo.cpp'
    }

    It 'sets PendingRequest to LoadFileLog' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type      = 'OpenRevisionGraph'
            DepotFile = '//depot/main/foo.cpp'
        })
        $next.Runtime.PendingRequest.Kind      | Should -Be 'LoadFileLog'
        $next.Runtime.PendingRequest.DepotFile | Should -Be '//depot/main/foo.cpp'
    }

    It 'increments GraphGeneration to invalidate stale loads' {
        $genBefore = [int]$script:state.Data.GraphGeneration
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type      = 'OpenRevisionGraph'
            DepotFile = '//depot/main/foo.cpp'
        })
        $next.Data.GraphGeneration | Should -BeGreaterThan $genBefore
    }
}

Describe 'Invoke-GraphReducer — RevisionLogLoaded' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1')        -Force
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')         -Force
        Import-Module (Join-Path $script:rp 'tui\Theme.psm1')        -Force
        Import-Module (Join-Path $script:rp 'tui\Layout.psm1')       -Force
        Import-Module (Join-Path $script:rp 'tui\Filtering.psm1')    -Force
        Import-Module (Join-Path $script:rp 'tui\Reducer.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\GraphReducer.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'tui\Helpers.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\Render.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $script:rp 'tui\GraphRender.psm1')  -Force -DisableNameChecking
    }
    BeforeEach {
        $script:state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        # Drive the state through OpenRevisionGraph first
        $script:state = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type      = 'OpenRevisionGraph'
            DepotFile = '//depot/main/foo.cpp'
        })
        $script:generation = [int]$script:state.Data.GraphGeneration

        $script:revisions = @(
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 1 -Change 40000 -Action 'add'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 -Action 'integrate' `
                -Integrations @((New-IntegrationRecord -How 'merge from' -File '//depot/dev/foo.cpp' -StartRev 2 -EndRev 3))),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 3 -Change 43500 -Action 'edit')
        )
    }

    It 'populates lane revisions and marks lane as not loading' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type       = 'RevisionLogLoaded'
            DepotFile  = '//depot/main/foo.cpp'
            LaneIndex  = 0
            Generation = $script:generation
            Revisions  = $script:revisions
            HasMore    = $false
        })
        $next.Data.RevisionGraph.Lanes[0].IsLoading            | Should -BeFalse
        $next.Data.RevisionGraph.Lanes[0].Revisions.Count      | Should -Be 3
        $next.Data.RevisionGraph.Lanes[0].HasMore              | Should -BeFalse
    }

    It 'builds GraphRows from loaded revisions' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type       = 'RevisionLogLoaded'
            DepotFile  = '//depot/main/foo.cpp'
            LaneIndex  = 0
            Generation = $script:generation
            Revisions  = $script:revisions
            HasMore    = $false
        })
        # 3 nodes + 1 integration on rev2 + 2 spines (between node-pairs) = 6 rows
        $next.Derived.GraphRows.Count | Should -Be 6
    }

    It 'produces rows in ascending change order (oldest at top)' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type       = 'RevisionLogLoaded'
            DepotFile  = '//depot/main/foo.cpp'
            LaneIndex  = 0
            Generation = $script:generation
            Revisions  = $script:revisions
            HasMore    = $false
        })
        $nodeRows = @($next.Derived.GraphRows | Where-Object { $_.RowType -eq 'Node' })
        $nodeRows[0].RevisionNode.Change | Should -Be 40000
        $nodeRows[1].RevisionNode.Change | Should -Be 41000
        $nodeRows[2].RevisionNode.Change | Should -Be 43500
    }

    It 'discards stale completions whose generation is behind current' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type       = 'RevisionLogLoaded'
            DepotFile  = '//depot/main/foo.cpp'
            LaneIndex  = 0
            Generation = 0   # stale — current generation is higher
            Revisions  = $script:revisions
            HasMore    = $false
        })
        $next.Derived.GraphRows.Count | Should -Be 0
    }

    It 'places cursor on newest (last) navigable row after initial load' {
        $next = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type       = 'RevisionLogLoaded'
            DepotFile  = '//depot/main/foo.cpp'
            LaneIndex  = 0
            Generation = $script:generation
            Revisions  = $script:revisions
            HasMore    = $false
        })
        $rows      = @($next.Derived.GraphRows)
        $cursorIdx = [int]$next.Cursor.GraphRowIndex
        $rows[$cursorIdx].RowType | Should -Be 'Node'
        ([int]$rows[$cursorIdx].RevisionNode.Change) | Should -Be 43500
    }
}

Describe 'Invoke-GraphReducer — Navigation' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1')        -Force
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')         -Force
        Import-Module (Join-Path $script:rp 'tui\Theme.psm1')        -Force
        Import-Module (Join-Path $script:rp 'tui\Layout.psm1')       -Force
        Import-Module (Join-Path $script:rp 'tui\Filtering.psm1')    -Force
        Import-Module (Join-Path $script:rp 'tui\Reducer.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\GraphReducer.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'tui\Helpers.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\Render.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $script:rp 'tui\GraphRender.psm1')  -Force -DisableNameChecking
    }
    BeforeEach {
        $script:state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $script:state = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type = 'OpenRevisionGraph'; DepotFile = '//depot/main/foo.cpp'
        })
        $gen = [int]$script:state.Data.GraphGeneration
        $revisions = @(
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 1 -Change 40000 -Action 'add'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 -Action 'edit'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 3 -Change 43500 -Action 'edit')
        )
        $script:state = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type = 'RevisionLogLoaded'; DepotFile = '//depot/main/foo.cpp'
            LaneIndex = 0; Generation = $gen; Revisions = $revisions; HasMore = $false
        })
        # Cursor starts at last node (rev 3, change 43500)
    }

    It 'MoveUp moves cursor to previous navigable row' {
        $before = [int]$script:state.Cursor.GraphRowIndex
        $next   = Invoke-BrowserReducer -State $script:state -Action ([pscustomobject]@{ Type = 'MoveUp' })
        $next.Cursor.GraphRowIndex | Should -BeLessThan $before
        $rows = @($next.Derived.GraphRows)
        [bool]$rows[$next.Cursor.GraphRowIndex].IsNavigable | Should -BeTrue
    }

    It 'MoveDown does not advance past last navigable row' {
        # Already at last node — MoveDown should stay put
        $next = Invoke-BrowserReducer -State $script:state -Action ([pscustomobject]@{ Type = 'MoveDown' })
        $next.Cursor.GraphRowIndex | Should -Be $script:state.Cursor.GraphRowIndex
    }

    It 'MoveHome moves to first navigable row' {
        $next = Invoke-BrowserReducer -State $script:state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $rows = @($next.Derived.GraphRows)
        $rows[$next.Cursor.GraphRowIndex].RevisionNode.Change | Should -Be 40000
    }

    It 'MoveEnd moves to last navigable row' {
        # Move to start first
        $state = Invoke-BrowserReducer -State $script:state -Action ([pscustomobject]@{ Type = 'MoveHome' })
        $next  = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{ Type = 'MoveEnd' })
        $rows  = @($next.Derived.GraphRows)
        $rows[$next.Cursor.GraphRowIndex].RevisionNode.Change | Should -Be 43500
    }

    It 'cursor always lands on a navigable row' {
        $next = Invoke-BrowserReducer -State $script:state -Action ([pscustomobject]@{ Type = 'MoveUp' })
        $rows = @($next.Derived.GraphRows)
        [bool]$rows[$next.Cursor.GraphRowIndex].IsNavigable | Should -BeTrue
    }

    It 'HideCommandModal pops RevisionGraph from ScreenStack' {
        $next = Invoke-BrowserReducer -State $script:state -Action ([pscustomobject]@{ Type = 'HideCommandModal' })
        $next.Ui.ScreenStack | Should -Not -Contain 'RevisionGraph'
    }
}

Describe 'Invoke-GraphReducer — RevisionLogFailed' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1')        -Force
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')         -Force
        Import-Module (Join-Path $script:rp 'tui\Theme.psm1')        -Force
        Import-Module (Join-Path $script:rp 'tui\Layout.psm1')       -Force
        Import-Module (Join-Path $script:rp 'tui\Filtering.psm1')    -Force
        Import-Module (Join-Path $script:rp 'tui\Reducer.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\GraphReducer.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'tui\Helpers.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\Render.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $script:rp 'tui\GraphRender.psm1')  -Force -DisableNameChecking
    }
    It 'clears ActiveCommand and stores error in LastError' {
        $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $state = Invoke-GraphReducer -State $state -Action ([pscustomobject]@{
            Type = 'OpenRevisionGraph'; DepotFile = '//depot/main/foo.cpp'
        })
        $next = Invoke-GraphReducer -State $state -Action ([pscustomobject]@{
            Type      = 'RevisionLogFailed'
            LaneIndex = 0
            Error     = 'p4 failed: no such file'
        })
        $next.Runtime.LastError | Should -Be 'p4 failed: no such file'
        $next.Data.RevisionGraph.Lanes[0].IsLoading | Should -BeFalse
    }
}

# ─── Update-GraphDerivedState (flat row generation) ───────────────────────────

Describe 'Update-GraphDerivedState' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1')        -Force
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')         -Force
        Import-Module (Join-Path $script:rp 'tui\Theme.psm1')        -Force
        Import-Module (Join-Path $script:rp 'tui\Layout.psm1')       -Force
        Import-Module (Join-Path $script:rp 'tui\Filtering.psm1')    -Force
        Import-Module (Join-Path $script:rp 'tui\Reducer.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\GraphReducer.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'tui\Helpers.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\Render.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $script:rp 'tui\GraphRender.psm1')  -Force -DisableNameChecking
    }
    It 'produces no rows when RevisionGraph state is null' {
        $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $state = Update-GraphDerivedState -State $state
        $state.Derived.GraphRows.Count | Should -Be 0
    }

    It 'interleaves Spine rows between nodes' {
        $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $state = Invoke-GraphReducer -State $state -Action ([pscustomobject]@{
            Type = 'OpenRevisionGraph'; DepotFile = '//depot/main/foo.cpp'
        })
        $gen = [int]$state.Data.GraphGeneration
        $revisions = @(
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 1 -Change 40000 -Action 'add'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 -Action 'edit')
        )
        $state = Invoke-GraphReducer -State $state -Action ([pscustomobject]@{
            Type = 'RevisionLogLoaded'; DepotFile = '//depot/main/foo.cpp'
            LaneIndex = 0; Generation = $gen; Revisions = $revisions; HasMore = $false
        })
        # 2 nodes + 1 spine = 3 rows
        $state.Derived.GraphRows.Count | Should -Be 3
        $rowTypes = @($state.Derived.GraphRows | ForEach-Object { $_.RowType })
        $rowTypes[0] | Should -Be 'Node'
        $rowTypes[1] | Should -Be 'Spine'
        $rowTypes[2] | Should -Be 'Node'
    }

    It 'Spine rows are not navigable; Node rows are navigable' {
        $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $state = Invoke-GraphReducer -State $state -Action ([pscustomobject]@{
            Type = 'OpenRevisionGraph'; DepotFile = '//depot/main/foo.cpp'
        })
        $gen = [int]$state.Data.GraphGeneration
        $revisions = @(
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 1 -Change 40000 -Action 'add'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 -Action 'edit')
        )
        $state = Invoke-GraphReducer -State $state -Action ([pscustomobject]@{
            Type = 'RevisionLogLoaded'; DepotFile = '//depot/main/foo.cpp'
            LaneIndex = 0; Generation = $gen; Revisions = $revisions; HasMore = $false
        })
        $nodeRows  = @($state.Derived.GraphRows | Where-Object { $_.RowType -eq 'Node'  })
        $spineRows = @($state.Derived.GraphRows | Where-Object { $_.RowType -eq 'Spine' })
        foreach ($r in $nodeRows)  { [bool]$r.IsNavigable | Should -BeTrue  }
        foreach ($r in $spineRows) { [bool]$r.IsNavigable | Should -BeFalse }
    }
}

# ─── GraphRender ──────────────────────────────────────────────────────────────

Describe 'Build-GraphFrame' {
    BeforeAll {
        $script:rp = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $script:rp 'p4\Models.psm1')        -Force
        Import-Module (Join-Path $script:rp 'p4\P4Cli.psm1')         -Force
        Import-Module (Join-Path $script:rp 'tui\Theme.psm1')        -Force
        Import-Module (Join-Path $script:rp 'tui\Layout.psm1')       -Force
        Import-Module (Join-Path $script:rp 'tui\Filtering.psm1')    -Force
        Import-Module (Join-Path $script:rp 'tui\Reducer.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\GraphReducer.psm1') -Force -Global
        Import-Module (Join-Path $script:rp 'tui\Helpers.psm1')      -Force
        Import-Module (Join-Path $script:rp 'tui\Render.psm1')       -Force -DisableNameChecking
        Import-Module (Join-Path $script:rp 'tui\GraphRender.psm1')  -Force -DisableNameChecking
    }
    BeforeEach {
        $script:state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $script:state = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type = 'OpenRevisionGraph'; DepotFile = '//depot/main/foo.cpp'
        })
        $gen = [int]$script:state.Data.GraphGeneration
        $revisions = @(
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 1 -Change 40000 -Action 'add'   -User 'artist' -Client 'WS' -Time 1700000000 -Description 'First commit'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 2 -Change 41000 -Action 'edit'  -User 'artist' -Client 'WS' -Time 1700100000 -Description 'Second commit'),
            (New-RevisionNode -DepotFile '//depot/main/foo.cpp' -Rev 3 -Change 43500 -Action 'edit'  -User 'dev'    -Client 'WS' -Time 1700200000 -Description 'Third commit')
        )
        $script:state = Invoke-GraphReducer -State $script:state -Action ([pscustomobject]@{
            Type = 'RevisionLogLoaded'; DepotFile = '//depot/main/foo.cpp'
            LaneIndex = 0; Generation = $gen; Revisions = $revisions; HasMore = $false
        })
    }

    It 'returns a frame with correct Width and Height' {
        $frame = Build-GraphFrame -State $script:state
        $frame.Width  | Should -Be 120
        $frame.Height | Should -Be 40
    }

    It 'returns exactly Height rows' {
        $frame = Build-GraphFrame -State $script:state
        @($frame.Rows).Count | Should -Be 40
    }

    It 'first row contains the depot path' {
        $frame = Build-GraphFrame -State $script:state
        $frame.Rows[0].Segments[0].Text | Should -Match 'depot/main/foo'
    }

    It 'loading state shows loading message when no rows yet' {
        $loadingState = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
        $loadingState = Invoke-GraphReducer -State $loadingState -Action ([pscustomobject]@{
            Type = 'OpenRevisionGraph'; DepotFile = '//depot/main/foo.cpp'
        })
        $frame = Build-GraphFrame -State $loadingState
        $allText = ($frame.Rows | ForEach-Object { $_.Segments[0].Text }) -join ' '
        $allText | Should -Match 'Loading'
    }

    It 'each row has Y equal to its index in the Rows array' {
        $frame = Build-GraphFrame -State $script:state
        for ($i = 0; $i -lt $frame.Rows.Count; $i++) {
            $frame.Rows[$i].Y | Should -Be $i
        }
    }

    It 'each row has a non-empty Signature' {
        $frame = Build-GraphFrame -State $script:state
        foreach ($row in $frame.Rows) {
            $row.Signature | Should -Not -BeNullOrEmpty
        }
    }
}

