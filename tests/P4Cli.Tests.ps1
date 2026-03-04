$modulePath = Join-Path $PSScriptRoot '..\p4\P4Cli.psm1'
Import-Module $modulePath -Force

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
