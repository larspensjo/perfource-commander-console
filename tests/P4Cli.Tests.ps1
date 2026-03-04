$modulePath = Join-Path $PSScriptRoot '..\p4\P4Cli.psm1'
Import-Module $modulePath -Force

Describe 'Format-P4CommandLine' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'prepends p4 and leaves plain arguments unquoted' {
        $result = Format-P4CommandLine -P4Args @('changes', '-s', 'pending')
        $result | Should -Be 'p4 changes -s pending'
    }

    It 'quotes arguments that contain spaces' {
        $result = Format-P4CommandLine -P4Args @('changes', '-u', 'user name with spaces')
        $result | Should -Be 'p4 changes -u "user name with spaces"'
    }

    It 'handles a single argument' {
        $result = Format-P4CommandLine -P4Args @('info')
        $result | Should -Be 'p4 info'
    }
}

Describe 'Get-P4Describe' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'parses a describe record with indexed file keys' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                '... change 12345',
                '... user testuser',
                '... client testclient',
                '... status pending',
                '... time 1700000000',
                '... desc Line one',
                '... depotFile0 //depot/a.txt',
                '... action0 edit',
                '... type0 text',
                '... depotFile1 //depot/b.txt',
                '... action1 add',
                '... type1 binary'
            )
        }

        $result = Get-P4Describe -Change 12345
        $result.Change      | Should -Be 12345
        $result.User        | Should -Be 'testuser'
        $result.Client      | Should -Be 'testclient'
        $result.Status      | Should -Be 'pending'
        $result.Files.Count | Should -Be 2
        $result.Files[0].DepotPath | Should -Be '//depot/a.txt'
        $result.Files[0].Action    | Should -Be 'edit'
        $result.Files[0].Type      | Should -Be 'text'
        $result.Files[1].DepotPath | Should -Be '//depot/b.txt'
        $result.Files[1].Action    | Should -Be 'add'
        $result.Files[1].Type      | Should -Be 'binary'
    }

    It 'parses a multi-line description' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                '... change 99',
                '... user alice',
                '... client aliceclient',
                '... status pending',
                '... time 1700000000',
                '... desc First line',
                'Second line'
            )
        }

        $result = Get-P4Describe -Change 99
        $result.Description.Count | Should -BeGreaterOrEqual 1
        $result.Description[0]    | Should -Be 'First line'
    }

    It 'returns an empty file list when no depotFile keys are present' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                '... change 777',
                '... user bob',
                '... client bobclient',
                '... status pending',
                '... time 1700000000',
                '... desc Only a description'
            )
        }

        $result = Get-P4Describe -Change 777
        $result.Files.Count | Should -Be 0
    }

    It 'throws when describe output has no change key' {
        Mock Invoke-P4 -ModuleName P4Cli { return @('... user someone') }
        { Get-P4Describe -Change 99999 } | Should -Throw '*Failed to parse*'
    }
}

Describe 'ConvertFrom-P4ZTagRecords' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'splits records when a key repeats' {
        $lines = @(
            '... change 1',
            '... user a',
            '... change 2',
            '... user b'
        )
        $records = InModuleScope P4Cli { ConvertFrom-P4ZTagRecords -Lines $args[0] } -ArgumentList @(,$lines)
        $records.Count | Should -Be 2
        $records[0].change | Should -Be '1'
        $records[1].change | Should -Be '2'
    }
}

Describe 'Get-P4OpenedChangeNumbers' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns set of change numbers from opened output' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                '... depotFile //depot/a.txt',
                '... change 100',
                '... action edit',
                '... depotFile //depot/b.txt',
                '... change 200',
                '... action add',
                '... depotFile //depot/c.txt',
                '... change 100',
                '... action edit'
            )
        }

        $result = Get-P4OpenedChangeNumbers
        $result.Contains(100) | Should -BeTrue
        $result.Contains(200) | Should -BeTrue
        $result.Count | Should -Be 2
    }

    It 'returns empty set when no files are opened' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'no such file(s).' }

        $result = Get-P4OpenedChangeNumbers
        ($result -is [System.Collections.Generic.HashSet[int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'returns empty hashset when opened output is empty' {
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4OpenedChangeNumbers
        ($result -is [System.Collections.Generic.HashSet[int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'rethrows unexpected opened errors' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'network timeout' }

        { Get-P4OpenedChangeNumbers } | Should -Throw '*network timeout*'
    }

    It 'invokes p4 opened without client changelist filter args' {
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        Get-P4OpenedChangeNumbers | Out-Null

        Assert-MockCalled Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            $P4Args.Count -eq 2 -and $P4Args[0] -eq '-ztag' -and $P4Args[1] -eq 'opened'
        }
    }
}

Describe 'Get-P4ShelvedChangeNumbers' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns set of change numbers from shelved changes output' {
        Mock Get-P4Info -ModuleName P4Cli { return [pscustomobject]@{ User = 'u'; Client = 'c'; Port = 'p'; Root = 'r' } }
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                '... change 300',
                '... user u',
                '... change 400',
                '... user u'
            )
        }

        $result = Get-P4ShelvedChangeNumbers
        $result.Contains(300) | Should -BeTrue
        $result.Contains(400) | Should -BeTrue
        $result.Count | Should -Be 2
    }

    It 'returns empty set when no shelved changelists exist' {
        Mock Get-P4Info -ModuleName P4Cli { return [pscustomobject]@{ User = 'u'; Client = 'c'; Port = 'p'; Root = 'r' } }
        Mock Invoke-P4 -ModuleName P4Cli { throw 'no matching changelists.' }

        $result = Get-P4ShelvedChangeNumbers
        ($result -is [System.Collections.Generic.HashSet[int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'returns empty hashset when shelved output is empty' {
        Mock Get-P4Info -ModuleName P4Cli { return [pscustomobject]@{ User = 'u'; Client = 'c'; Port = 'p'; Root = 'r' } }
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4ShelvedChangeNumbers
        ($result -is [System.Collections.Generic.HashSet[int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'rethrows unexpected shelved errors' {
        Mock Get-P4Info -ModuleName P4Cli { return [pscustomobject]@{ User = 'u'; Client = 'c'; Port = 'p'; Root = 'r' } }
        Mock Invoke-P4 -ModuleName P4Cli { throw 'authentication failed' }

        { Get-P4ShelvedChangeNumbers } | Should -Throw '*authentication failed*'
    }
}

Describe 'Get-P4ChangelistEntries' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'marks changelist as Empty when opened and shelved sets are empty' {
        $now = Get-Date
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(
                New-P4Changelist -Change 123 -User 'u' -Client 'c' -Time $now -Status 'pending' -Description 'desc'
            )
        }
        Mock Get-P4OpenedChangeNumbers -ModuleName P4Cli {
            return [System.Collections.Generic.HashSet[int]]::new()
        }
        Mock Get-P4ShelvedChangeNumbers -ModuleName P4Cli {
            return [System.Collections.Generic.HashSet[int]]::new()
        }

        $result = @(Get-P4ChangelistEntries)
        $result.Count | Should -Be 1
        $result[0].Filters | Should -Contain 'Empty'
    }
}

Describe 'ConvertTo-ChangelistEntry with IsEmpty' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'adds Empty filter when IsEmpty is true' {
        $cl = New-P4Changelist -Change 1 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'test'
        $entry = ConvertTo-ChangelistEntry -Changelist $cl -IsEmpty $true
        $entry.Filters | Should -Contain 'Empty'
    }

    It 'does not add Empty filter when IsEmpty is false' {
        $cl = New-P4Changelist -Change 2 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'test'
        $entry = ConvertTo-ChangelistEntry -Changelist $cl -IsEmpty $false
        $entry.Filters | Should -Not -Contain 'Empty'
    }

    It 'does not add Empty filter by default' {
        $cl = New-P4Changelist -Change 3 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'test'
        $entry = ConvertTo-ChangelistEntry -Changelist $cl
        $entry.Filters | Should -Not -Contain 'Empty'
    }
}
