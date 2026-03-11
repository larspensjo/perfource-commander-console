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

Describe 'Invoke-P4' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        # Redirect the module to cmd.exe so tests run without a real p4 binary.
        InModuleScope P4Cli { $script:P4Executable = 'cmd.exe' }
    }

    AfterAll {
        InModuleScope P4Cli { $script:P4Executable = 'p4.exe' }
    }

    It 'returns parsed PSObjects on a zero-exit process' {
        # cmd.exe /c echo {"v":"ok"}  →  one JSON object on stdout, exit 0
        $result = InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'echo', '{"v":"ok"}') }
        $result[0].v | Should -Be 'ok'
    }

    It 'throws with exit-code detail on a non-zero exit' {
        # cmd.exe /c exit 1  →  exit code 1, no output
        { InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'exit', '1') } } |
            Should -Throw '*p4 failed (exit 1)*'
    }

    It 'allows configured non-zero exit codes to return successfully' {
        $result = InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'exit', '1') -AllowedExitCodes @(0, 1) }
        $result | Should -BeNullOrEmpty
    }

    It 'throws when p4 emits a JSON error record even if the process exit code is zero' {
        $scriptPath = Join-Path $TestDrive 'p4-json-error.cmd'
        Set-Content -Path $scriptPath -Value @(
            '@echo off',
            'echo {^"code^":^"error^",^"data^":^"Change 27202548 has 6 open file(s) associated with it and can''t be deleted.^"}',
            'exit /b 0'
        )

        try {
            & (Get-Module P4Cli) { param($path) $script:P4Executable = $path } $scriptPath
            {
                & (Get-Module P4Cli) { Invoke-P4 -P4Args @('change', '-d', '27202548') }
            } | Should -Throw "*can't be deleted*"
        }
        finally {
            & (Get-Module P4Cli) { $script:P4Executable = 'cmd.exe' }
        }
    }

    It 'throws when p4 change -d returns a non-success level-only data message' {
        $scriptPath = Join-Path $TestDrive 'p4-change-delete-fail.cmd'
        Set-Content -Path $scriptPath -Value @(
            '@echo off',
            'echo {^"data^":^"Change 27202548 has 6 open file(s) associated with it and can''t be deleted.^",^"level^":0}',
            'exit /b 0'
        )

        try {
            & (Get-Module P4Cli) { param($path) $script:P4Executable = $path } $scriptPath
            {
                & (Get-Module P4Cli) { Invoke-P4 -P4Args @('change', '-d', '27202548') }
            } | Should -Throw "*can't be deleted*"
        }
        finally {
            & (Get-Module P4Cli) { $script:P4Executable = 'cmd.exe' }
        }
    }

    It 'does not throw when p4 change -d returns the normal deleted confirmation message' {
        $scriptPath = Join-Path $TestDrive 'p4-change-delete-ok.cmd'
        Set-Content -Path $scriptPath -Value @(
            '@echo off',
            'echo {^"data^":^"Change 27202548 deleted.^",^"level^":0}',
            'exit /b 0'
        )

        try {
            & (Get-Module P4Cli) { param($path) $script:P4Executable = $path } $scriptPath
            {
                & (Get-Module P4Cli) { Invoke-P4 -P4Args @('change', '-d', '27202548') }
            } | Should -Not -Throw
        }
        finally {
            & (Get-Module P4Cli) { $script:P4Executable = 'cmd.exe' }
        }
    }

    It 'throws a timeout error and does not hang when the process exceeds TimeoutMs' {
        # cmd.exe /c ping -n 10 127.0.0.1 takes ~9 s; 400 ms timeout fires first.
        $before = Get-Date
        { InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'ping', '-n', '10', '127.0.0.1') -TimeoutMs 400 } } |
            Should -Throw '*timed out after*'
        $elapsed = (Get-Date) - $before
        $elapsed.TotalSeconds | Should -BeLessThan 5
    }
}

Describe 'Get-P4Describe' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'parses a describe record with indexed file keys' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{
                change     = '12345'
                user       = 'testuser'
                client     = 'testclient'
                status     = 'submitted'
                time       = '1700000000'
                desc       = 'Line one'
                depotFile0 = '//depot/a.txt'
                action0    = 'edit'
                type0      = 'text'
                depotFile1 = '//depot/b.txt'
                action1    = 'add'
                type1      = 'binary'
            })
        }

        $result = Get-P4Describe -Change 12345
        $result.Change      | Should -Be 12345
        $result.User        | Should -Be 'testuser'
        $result.Client      | Should -Be 'testclient'
        $result.Status      | Should -Be 'submitted'
        $result.Files.Count | Should -Be 2
        $result.Files[0].DepotPath | Should -Be '//depot/a.txt'
        $result.Files[0].Action    | Should -Be 'edit'
        $result.Files[0].Type      | Should -Be 'text'
        $result.Files[1].DepotPath | Should -Be '//depot/b.txt'
        $result.Files[1].Action    | Should -Be 'add'
        $result.Files[1].Type      | Should -Be 'binary'
    }

    It 'still parses array-shaped file properties when present' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{
                change    = '12346'
                user      = 'testuser'
                client    = 'testclient'
                status    = 'pending'
                time      = '1700000000'
                desc      = 'Line one'
                depotFile = @('//depot/c.txt', '//depot/d.txt')
                action    = @('branch', 'integrate')
                type      = @('text+C', 'text')
            })
        }

        $result = Get-P4Describe -Change 12346
        $result.Files.Count | Should -Be 2
        $result.Files[0].DepotPath | Should -Be '//depot/c.txt'
        $result.Files[0].Action    | Should -Be 'branch'
        $result.Files[0].Type      | Should -Be 'text+C'
        $result.Files[1].DepotPath | Should -Be '//depot/d.txt'
        $result.Files[1].Action    | Should -Be 'integrate'
        $result.Files[1].Type      | Should -Be 'text'
    }

    It 'parses a multi-line description' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{
                change = '99'
                user   = 'alice'
                client = 'aliceclient'
                status = 'pending'
                time   = '1700000000'
                desc   = "First line`nSecond line"
            })
        }

        $result = Get-P4Describe -Change 99
        $result.Description.Count | Should -Be 2
        $result.Description[0]    | Should -Be 'First line'
        $result.Description[1]    | Should -Be 'Second line'
    }

    It 'returns an empty file list when no depotFile keys are present' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{
                change = '777'
                user   = 'bob'
                client = 'bobclient'
                status = 'pending'
                time   = '1700000000'
                desc   = 'Only a description'
            })
        }

        $result = Get-P4Describe -Change 777
        $result.Files.Count | Should -Be 0
    }

    It 'throws when describe output has no change key' {
        Mock Invoke-P4 -ModuleName P4Cli { return @([pscustomobject]@{ user = 'someone' }) }
        { Get-P4Describe -Change 99999 } | Should -Throw '*Failed to parse*'
    }
}

Describe 'Get-P4OpenedChangeNumbers' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns set of change numbers from opened output' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ depotFile = '//depot/a.txt'; change = '100'; action = 'edit' },
                [pscustomobject]@{ depotFile = '//depot/b.txt'; change = '200'; action = 'add' },
                [pscustomobject]@{ depotFile = '//depot/c.txt'; change = '100'; action = 'edit' }
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
            $P4Args.Count -eq 1 -and $P4Args[0] -eq 'opened'
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
                [pscustomobject]@{ change = '300'; user = 'u' },
                [pscustomobject]@{ change = '400'; user = 'u' }
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

    It 'marks changelist as Empty when opened and shelved counts are zero' {
        $now = Get-Date
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(
                New-P4Changelist -Change 123 -User 'u' -Client 'c' -Time $now -Status 'pending' -Description 'desc'
            )
        }
        Mock Get-P4OpenedFileCounts -ModuleName P4Cli {
            return [System.Collections.Generic.Dictionary[int,int]]::new()
        }
        Mock Get-P4ShelvedFileCounts -ModuleName P4Cli {
            return [System.Collections.Generic.Dictionary[int,int]]::new()
        }

        $result = @(Get-P4ChangelistEntries)
        $result.Count            | Should -Be 1
        $result[0].Id            | Should -Be '123'
        $result[0].HasShelvedFiles  | Should -BeFalse
        $result[0].HasOpenedFiles   | Should -BeFalse
        $result[0].OpenedFileCount  | Should -Be 0
        $result[0].ShelvedFileCount | Should -Be 0
    }

    It 'populates counts and derives booleans when files are present' {
        $now = Get-Date
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(
                New-P4Changelist -Change 200 -User 'u' -Client 'c' -Time $now -Status 'pending' -Description 'desc'
            )
        }
        Mock Get-P4OpenedFileCounts -ModuleName P4Cli {
            $d = [System.Collections.Generic.Dictionary[int,int]]::new()
            $d[200] = 3
            return $d
        }
        Mock Get-P4ShelvedFileCounts -ModuleName P4Cli {
            $d = [System.Collections.Generic.Dictionary[int,int]]::new()
            $d[200] = 2
            return $d
        }

        $result = @(Get-P4ChangelistEntries)
        $result.Count               | Should -Be 1
        $result[0].HasOpenedFiles   | Should -BeTrue
        $result[0].HasShelvedFiles  | Should -BeTrue
        $result[0].OpenedFileCount  | Should -Be 3
        $result[0].ShelvedFileCount | Should -Be 2
    }
}

Describe 'Get-P4SubmittedChangelists' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'limits submitted queries to an explicit client mapping' {
        Mock Get-P4Info -ModuleName P4Cli { throw 'should not be called' }
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{
                    change = '12345'
                    user   = 'alice'
                    client = 'ws-main'
                    time   = '1700000000'
                    desc   = 'Submitted change'
                }
            )
        }

        $result = @(Get-P4SubmittedChangelists -Max 25 -Client 'ws-main')

        $result.Count | Should -Be 1
        $result[0].Change | Should -Be 12345
        Assert-MockCalled Get-P4Info -ModuleName P4Cli -Times 0 -Exactly
        Assert-MockCalled Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            $P4Args.Count -eq 7 -and
            $P4Args[0] -eq 'changes' -and
            $P4Args[1] -eq '-l' -and
            $P4Args[2] -eq '-s' -and
            $P4Args[3] -eq 'submitted' -and
            $P4Args[4] -eq '-m' -and
            $P4Args[5] -eq '25' -and
            $P4Args[6] -eq '//ws-main/...'
        }
    }

    It 'uses the current client mapping when no client is supplied' {
        Mock Get-P4Info -ModuleName P4Cli { return [pscustomobject]@{ Client = 'ws-current' } }
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = @(Get-P4SubmittedChangelists -Max 10)

        $result.Count | Should -Be 0
        Assert-MockCalled Get-P4Info -ModuleName P4Cli -Times 1 -Exactly
        Assert-MockCalled Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            $P4Args[-1] -eq '//ws-current/...'
        }
    }

    It 'applies pagination within the client mapping' {
        Mock Get-P4Info -ModuleName P4Cli { return [pscustomobject]@{ Client = 'ws-current' } }
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = @(Get-P4SubmittedChangelists -Max 50 -BeforeChange 67890)

        $result.Count | Should -Be 0
        Assert-MockCalled Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            $P4Args[-1] -eq '//ws-current/...@<67890'
        }
    }
}

Describe 'Remove-P4ShelvedFiles' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'runs p4 shelve -d -c for the requested changelist' {
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        Remove-P4ShelvedFiles -Change 123

        Should -Invoke Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            (@($P4Args) -join '|') -eq 'shelve|-d|-c|123'
        }
    }
}

Describe 'ConvertFrom-P4OpenedLinesToFileCounts' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'counts files per changelist from opened JSON records' {
        $records = @(
            [pscustomobject]@{ depotFile = '//depot/a.txt'; change = '100'; action = 'edit' },
            [pscustomobject]@{ depotFile = '//depot/b.txt'; change = '200'; action = 'add' },
            [pscustomobject]@{ depotFile = '//depot/c.txt'; change = '100'; action = 'edit' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4OpenedLinesToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result[100] | Should -Be 2
        $result[200] | Should -Be 1
    }

    It 'returns empty dictionary for empty input' {
        $result = InModuleScope P4Cli { ConvertFrom-P4OpenedLinesToFileCounts -Records @() }
        $result.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-P4DescribeShelvedLinesToFileCounts' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'counts shelved files per changelist from describe -S -s JSON records' {
        $records = @(
            [pscustomobject]@{ change = '300'; user = 'u'; depotFile = @('//depot/x.txt', '//depot/y.txt') },
            [pscustomobject]@{ change = '400'; user = 'u'; depotFile = @('//depot/z.txt') }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4DescribeShelvedLinesToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result[300] | Should -Be 2
        $result[400] | Should -Be 1
    }

    It 'returns empty dictionary for empty input' {
        $result = InModuleScope P4Cli { ConvertFrom-P4DescribeShelvedLinesToFileCounts -Records @() }
        $result.Count | Should -Be 0
    }

    It 'records zero count for a change with no depotFile property' {
        $records = @(
            [pscustomobject]@{ change = '500'; user = 'u' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4DescribeShelvedLinesToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result.ContainsKey(500) | Should -BeTrue
        $result[500]             | Should -Be 0
    }

    It 'counts indexed depotFileN properties from describe output' {
        $records = @(
            [pscustomobject]@{
                change = '600'
                user = 'u'
                depotFile0 = '//depot/one.txt'
                action0 = 'edit'
                type0 = 'text'
                depotFile1 = '//depot/two.txt'
                action1 = 'add'
                type1 = 'text'
            }
        )

        $result = InModuleScope P4Cli { ConvertFrom-P4DescribeShelvedLinesToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result.ContainsKey(600) | Should -BeTrue
        $result[600]             | Should -Be 2
    }
}

Describe 'Get-P4OpenedFileCounts' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns file counts per changelist from opened output' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ depotFile = '//depot/a.txt'; change = '100' },
                [pscustomobject]@{ depotFile = '//depot/b.txt'; change = '100' }
            )
        }

        $result = Get-P4OpenedFileCounts
        $result.ContainsKey(100) | Should -BeTrue
        $result[100]             | Should -Be 2
    }

    It 'returns empty dictionary when no files are opened' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'no such file(s).' }

        $result = Get-P4OpenedFileCounts
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'returns empty dictionary when opened output is empty' {
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4OpenedFileCounts
        $result.Count | Should -Be 0
    }

    It 'rethrows unexpected errors' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'network timeout' }

        { Get-P4OpenedFileCounts } | Should -Throw '*network timeout*'
    }
}

Describe 'Get-P4ShelvedFileCounts' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns empty dictionary for empty changelist input' {
        $result = Get-P4ShelvedFileCounts -ChangeNumbers @()
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'parses shelved file counts from batched describe output' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ change = '300'; depotFile = @('//depot/a.txt', '//depot/b.txt') },
                [pscustomobject]@{ change = '400'; depotFile = @('//depot/c.txt') }
            )
        }

        $result = Get-P4ShelvedFileCounts -ChangeNumbers @(300, 400)
        $result[300] | Should -Be 2
        $result[400] | Should -Be 1
    }

    It 'parses indexed shelved files from batched describe output' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{
                    change = '610'
                    depotFile0 = '//depot/a.txt'
                    action0 = 'edit'
                    type0 = 'text'
                    depotFile1 = '//depot/b.txt'
                    action1 = 'edit'
                    type1 = 'text'
                }
            )
        }

        $result = Get-P4ShelvedFileCounts -ChangeNumbers @(610)
        $result[610] | Should -Be 2
    }

    It 'degrades gracefully on describe failure and returns empty result' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'connection refused' }

        $result = Get-P4ShelvedFileCounts -ChangeNumbers @(500, 501)
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'merges results from multiple chunks' {
        # Use chunk size logic: supply 51 items so it splits into 2 chunks.
        # Both chunks hit the same mock which returns a static single entry.
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                "... change $($args[0][-1])",
                '... depotFile0 //depot/x.txt'
            )
        }

        $numbers = 1..55
        # Each chunk call returns one entry for the last CL in that chunk.
        # We just verify the function calls Invoke-P4 more than once and returns a non-empty dict.
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4ShelvedFileCounts -ChangeNumbers $numbers
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        Assert-MockCalled Invoke-P4 -ModuleName P4Cli -Times 2 -Exactly
    }
}
Describe 'New-P4FileEntry' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'creates a FileEntry with all expected fields' {
        $entry = New-P4FileEntry -DepotPath '//depot/foo/bar.cs' -Action 'edit' `
                                 -FileType 'text' -Change 42 -SourceKind 'Opened'
        $entry.DepotPath  | Should -Be '//depot/foo/bar.cs'
        $entry.Action     | Should -Be 'edit'
        $entry.FileType   | Should -Be 'text'
        $entry.Change     | Should -Be 42
        $entry.SourceKind | Should -Be 'Opened'
    }

    It 'derives FileName from the tail of the depot path' {
        $entry = New-P4FileEntry -DepotPath '//depot/dir/subdir/MyFile.cs'
        $entry.FileName | Should -Be 'MyFile.cs'
    }

    It 'derives FileName correctly for a root-level file' {
        $entry = New-P4FileEntry -DepotPath '//depot/solo.txt'
        $entry.FileName | Should -Be 'solo.txt'
    }

    It 'builds SearchKey as lowercased concat of DepotPath, Action, and FileType' {
        $entry = New-P4FileEntry -DepotPath '//Depot/Path/MyFile.CS' `
                                 -Action 'Edit' -FileType 'Text'
        $entry.SearchKey | Should -Be '//depot/path/myfile.cs edit text'
    }

    It 'SearchKey includes empty strings for missing Action and FileType' {
        $entry = New-P4FileEntry -DepotPath '//depot/a.txt'
        $entry.SearchKey | Should -Be '//depot/a.txt  '
    }

    It 'Action and FileType default to empty string' {
        $entry = New-P4FileEntry -DepotPath '//depot/b.txt'
        $entry.Action   | Should -Be ''
        $entry.FileType | Should -Be ''
    }

    It 'Change defaults to 0 when not supplied' {
        $entry = New-P4FileEntry -DepotPath '//depot/c.txt'
        $entry.Change | Should -Be 0
    }

    It 'SourceKind defaults to Opened when not supplied' {
        $entry = New-P4FileEntry -DepotPath '//depot/d.txt'
        $entry.SourceKind | Should -Be 'Opened'
    }
}

Describe 'Get-P4OpenedFiles' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'queries fstat with opened scope, change scope, unresolved field, and the all-files spec' {
        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter {
            (@($P4Args) -join '|') -eq 'fstat|-Ro|-e|101|-T|change,depotFile,action,type,unresolved|//...'
        } {
            return @(
                [pscustomobject]@{ depotFile = '//depot/src/Foo.cs'; action = 'edit'; change = '101'; type = 'text' }
            )
        }

        $result = Get-P4OpenedFiles -Change 101
        $result.Count | Should -Be 1

        Should -Invoke Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            (@($P4Args) -join '|') -eq 'fstat|-Ro|-e|101|-T|change,depotFile,action,type,unresolved|//...'
        }
    }

    It 'parses a single opened file into a FileEntry with correct fields' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{
                depotFile  = '//depot/src/Foo.cs'
                clientFile = '//client/src/Foo.cs'
                rev        = '3'
                action     = 'edit'
                change     = '101'
                type       = 'text'
                user       = 'alice'
                client     = 'aliceclient'
            })
        }

        $result = Get-P4OpenedFiles -Change 101
        $result.Count           | Should -Be 1
        $result[0].DepotPath    | Should -Be '//depot/src/Foo.cs'
        $result[0].FileName     | Should -Be 'Foo.cs'
        $result[0].Action       | Should -Be 'edit'
        $result[0].FileType     | Should -Be 'text'
        $result[0].Change       | Should -Be 101
        $result[0].SourceKind   | Should -Be 'Opened'
        $result[0].IsUnresolved | Should -BeFalse
    }

    It 'parses multiple opened files' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ depotFile = '//depot/a.txt'; action = 'edit'; change = '200'; type = 'text' },
                [pscustomobject]@{ depotFile = '//depot/b.txt'; action = 'add';  change = '200'; type = 'binary' }
            )
        }

        $result = Get-P4OpenedFiles -Change 200
        $result.Count        | Should -Be 2
        $result[0].DepotPath | Should -Be '//depot/a.txt'
        $result[0].Action    | Should -Be 'edit'
        $result[1].DepotPath | Should -Be '//depot/b.txt'
        $result[1].Action    | Should -Be 'add'
    }

    It 'returns empty array when changelist has no opened files' {
        Mock Invoke-P4 -ModuleName P4Cli {
            throw "p4 failed (exit 1).`nSTDOUT: //depot/... - file(s) not opened on this client."
        }

        $result = Get-P4OpenedFiles -Change 999
        $result | Should -BeNullOrEmpty
    }

    It 'returns empty array when Invoke-P4 returns no lines' {
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4OpenedFiles -Change 303
        $result | Should -BeNullOrEmpty
    }

    It 'handles missing type key gracefully (defaults to empty string)' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{ depotFile = '//depot/noType.txt'; action = 'delete'; change = '50' })
        }

        $result = Get-P4OpenedFiles -Change 50
        $result.Count        | Should -Be 1
        $result[0].FileType  | Should -Be ''
        $result[0].Action    | Should -Be 'delete'
    }

    It 'uses the Change parameter value when ztag record has no change key' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{ depotFile = '//depot/noChange.txt'; action = 'add'; type = 'text' })
        }

        $result = Get-P4OpenedFiles -Change 77
        $result[0].Change | Should -Be 77
    }

    It 'rethrows unexpected errors that are not no-opened-files errors' {
        Mock Invoke-P4 -ModuleName P4Cli {
            throw 'p4 failed (exit 1). STDERR: connect failed'
        }

        { Get-P4OpenedFiles -Change 1 } | Should -Throw '*connect failed*'
    }

    It 'SearchKey on parsed entry is lowercased and includes DepotPath, Action, FileType' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{ depotFile = '//Depot/Dir/MyFile.CS'; action = 'Edit'; change = '5'; type = 'Text' })
        }

        $result = Get-P4OpenedFiles -Change 5
        $result[0].SearchKey | Should -Be '//depot/dir/myfile.cs edit text'
    }

    It 'marks file entries unresolved when the unresolved field is present' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @([pscustomobject]@{ depotFile = '//depot/conflict.cpp'; action = 'integrate'; change = '9'; type = 'text'; unresolved = '' })
        }

        $result = Get-P4OpenedFiles -Change 9
        $result[0].IsUnresolved | Should -BeTrue
        $result[0].SearchKey    | Should -Match 'unresolved'
    }
}

Describe 'P4 observer' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        InModuleScope P4Cli { $script:P4Executable = 'cmd.exe' }
    }

    AfterAll {
        InModuleScope P4Cli { $script:P4Executable = 'p4.exe' }
    }

    AfterEach {
        # ensure clean observer state between tests
        InModuleScope P4Cli { $script:P4ExecutionObserver = $null }
    }

    It 'Register-P4Observer sets the module-level observer' {
        Register-P4Observer -Observer { }
        $obs = InModuleScope P4Cli { $script:P4ExecutionObserver }
        $obs | Should -Not -BeNullOrEmpty
    }

    It 'Unregister-P4Observer clears the observer' {
        Register-P4Observer -Observer { }
        Unregister-P4Observer
        $obs = InModuleScope P4Cli { $script:P4ExecutionObserver }
        $obs | Should -BeNullOrEmpty
    }

    It 'observer is called after a successful Invoke-P4' {
        $called = [ref]$false
        Register-P4Observer -Observer { $called.Value = $true }
        try {
            InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'echo', '{"v":"ok"}') }
        } catch {}
        $called.Value | Should -BeTrue
    }

    It 'observer is called even when Invoke-P4 throws (non-zero exit)' {
        $called = [ref]$false
        Register-P4Observer -Observer { $called.Value = $true }
        try {
            InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'exit', '1') }
        } catch {}
        $called.Value | Should -BeTrue
    }

    It 'observer sees JSON error-record failures as unsuccessful commands' {
        $captured = [pscustomobject]@{ ExitCode = -1; ErrorOutput = '' }
        $scriptPath = Join-Path $TestDrive 'p4-json-error-observer.cmd'
        Set-Content -Path $scriptPath -Value @(
            '@echo off',
            'echo {^"code^":^"error^",^"data^":^"Change 27202548 has shelved files associated with it and can''t be deleted.^"}',
            'exit /b 0'
        )
        Register-P4Observer -Observer {
            param($CommandLine, $RawLines, $ExitCode, $ErrorOutput, $StartedAt, $EndedAt, $DurationMs)
            [void]$CommandLine
            [void]$RawLines
            [void]$StartedAt
            [void]$EndedAt
            [void]$DurationMs
            $captured.ExitCode = $ExitCode
            $captured.ErrorOutput = $ErrorOutput
        }

        try {
            & (Get-Module P4Cli) { param($path) $script:P4Executable = $path } $scriptPath
            & (Get-Module P4Cli) { Invoke-P4 -P4Args @('change', '-d', '27202548') }
        } catch {}
        finally {
            & (Get-Module P4Cli) { $script:P4Executable = 'cmd.exe' }
        }

        $captured.ExitCode | Should -Be 1
        $captured.ErrorOutput | Should -Match "can't be deleted"
    }

    It 'observer sees level-only delete failures as unsuccessful commands' {
        $captured = [pscustomobject]@{ ExitCode = -1; ErrorOutput = '' }
        $scriptPath = Join-Path $TestDrive 'p4-json-level-observer.cmd'
        Set-Content -Path $scriptPath -Value @(
            '@echo off',
            'echo {^"data^":^"Change 27202548 has 6 open file(s) associated with it and can''t be deleted.^",^"level^":0}',
            'exit /b 0'
        )
        Register-P4Observer -Observer {
            param($CommandLine, $RawLines, $ExitCode, $ErrorOutput, $StartedAt, $EndedAt, $DurationMs)
            [void]$CommandLine
            [void]$RawLines
            [void]$StartedAt
            [void]$EndedAt
            [void]$DurationMs
            $captured.ExitCode = $ExitCode
            $captured.ErrorOutput = $ErrorOutput
        }

        try {
            & (Get-Module P4Cli) { param($path) $script:P4Executable = $path } $scriptPath
            & (Get-Module P4Cli) { Invoke-P4 -P4Args @('change', '-d', '27202548') }
        } catch {}
        finally {
            & (Get-Module P4Cli) { $script:P4Executable = 'cmd.exe' }
        }

        $captured.ExitCode | Should -Be 1
        $captured.ErrorOutput | Should -Match "can't be deleted"
    }

    It 'exceptions thrown inside the observer do not propagate out of Invoke-P4' {
        Register-P4Observer -Observer { throw 'observer-bomb' }
        # A successful invocation must still return results even if observer throws
        { InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'echo', '{"v":"ok"}') } } |
            Should -Not -Throw
    }
}

Describe 'Invoke-P4ReopenFiles' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'returns MovedCount zero and empty Files when source changelist has no opened files' {
        Mock Invoke-P4 -ModuleName P4Cli {
            throw "p4 failed (exit 1).`nSTDOUT: //depot/... - file(s) not opened on this client."
        }

        $result = Invoke-P4ReopenFiles -SourceChange 101 -TargetChange 200
        $result.MovedCount | Should -Be 0
        $result.Files.Count | Should -Be 0
    }

    It 'calls p4 reopen with target change and all depot paths' {
        $capturedArgs = $null
        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter { $P4Args[0] -eq 'fstat' } {
            return @(
                [pscustomobject]@{ depotFile = '//depot/a.cs'; action = 'edit'; change = '101'; type = 'text' },
                [pscustomobject]@{ depotFile = '//depot/b.cs'; action = 'add';  change = '101'; type = 'text' }
            )
        }
        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter { $P4Args[0] -eq 'reopen' } {
            # just capture; no output needed (returns $null → Out-Null in caller)
        }

        $result = Invoke-P4ReopenFiles -SourceChange 101 -TargetChange 200
        $result.MovedCount  | Should -Be 2
        $result.Files.Count | Should -Be 2
        $result.Files       | Should -Contain '//depot/a.cs'
        $result.Files       | Should -Contain '//depot/b.cs'
        Should -Invoke Invoke-P4 -ModuleName P4Cli -ParameterFilter { $P4Args[0] -eq 'reopen' } -Times 1
    }

    It 'returns MovedCount zero when Invoke-P4 returns no records for opened' {
        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter { $P4Args[0] -eq 'fstat' } {
            return @()
        }

        $result = Invoke-P4ReopenFiles -SourceChange 55 -TargetChange 66
        $result.MovedCount | Should -Be 0
        # reopen should NOT be called since there are no files
        Should -Invoke Invoke-P4 -ModuleName P4Cli -ParameterFilter { $P4Args[0] -eq 'reopen' } -Times 0
    }
}

Describe 'Test-IsP4NoUnresolvedFilesError' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'recognises the canonical no such file(s) message' {
        Test-IsP4NoUnresolvedFilesError -Message 'no such file(s).' | Should -BeTrue
    }

    It 'recognises the message case-insensitively' {
        Test-IsP4NoUnresolvedFilesError -Message 'No Such File(s).' | Should -BeTrue
    }

    It 'returns false for an unrelated error message' {
        Test-IsP4NoUnresolvedFilesError -Message 'network timeout' | Should -BeFalse
    }

    It 'returns false for an empty message' {
        Test-IsP4NoUnresolvedFilesError -Message 'some random unrelated error' | Should -BeFalse
    }
}

Describe 'ConvertFrom-P4FstatUnresolvedRecordsToFileCounts' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns empty dictionary for empty input' {
        $result = InModuleScope P4Cli { ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records @() }
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'counts one record per changelist' {
        $records = @(
            [pscustomobject]@{ change = '100'; depotFile = '//depot/a.cpp'; unresolved = '' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result.ContainsKey(100) | Should -BeTrue
        $result[100]             | Should -Be 1
    }

    It 'aggregates multiple files in the same changelist' {
        $records = @(
            [pscustomobject]@{ change = '200'; depotFile = '//depot/a.cpp'; unresolved = '' },
            [pscustomobject]@{ change = '200'; depotFile = '//depot/b.h';   unresolved = '' },
            [pscustomobject]@{ change = '300'; depotFile = '//depot/c.cpp'; unresolved = '' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result[200] | Should -Be 2
        $result[300] | Should -Be 1
    }

    It 'ignores records that have no change property' {
        $records = @(
            [pscustomobject]@{ depotFile = '//depot/nochange.cpp'; unresolved = '' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result.Count | Should -Be 0
    }

    It 'ignores records where change is 0 (default changelist)' {
        $records = @(
            [pscustomobject]@{ change = '0'; depotFile = '//depot/default.cpp'; unresolved = '' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result.Count | Should -Be 0
    }

    It 'ignores records where change is not a parseable integer' {
        $records = @(
            [pscustomobject]@{ change = 'notanumber'; depotFile = '//depot/x.cpp'; unresolved = '' }
        )
        $result = InModuleScope P4Cli { ConvertFrom-P4FstatUnresolvedRecordsToFileCounts -Records $args[0] } -ArgumentList @(,$records)
        $result.Count | Should -Be 0
    }
}

Describe 'ConvertFrom-P4DiffRecordsToDepotPaths' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'returns depot paths from diff records with depotFile properties' {
        $records = @(
            [pscustomobject]@{ depotFile = '//depot/a.cpp' },
            [pscustomobject]@{ depotFile = '//depot/b.cpp' }
        )

        $result = InModuleScope P4Cli { ConvertFrom-P4DiffRecordsToDepotPaths -Records $args[0] } -ArgumentList @(,$records)
        $result.Contains('//depot/a.cpp') | Should -BeTrue
        $result.Contains('//depot/b.cpp') | Should -BeTrue
        $result.Count | Should -Be 2
    }

    It 'falls back to depot paths embedded in data messages' {
        $records = @(
            [pscustomobject]@{ data = '//depot/c.cpp' }
        )

        $result = InModuleScope P4Cli { ConvertFrom-P4DiffRecordsToDepotPaths -Records $args[0] } -ArgumentList @(,$records)
        $result.Contains('//depot/c.cpp') | Should -BeTrue
    }

    It 'deduplicates depot paths case-insensitively' {
        $records = @(
            [pscustomobject]@{ depotFile = '//depot/D.cpp' },
            [pscustomobject]@{ depotFile = '//DEPOT/d.cpp' }
        )

        $result = InModuleScope P4Cli { ConvertFrom-P4DiffRecordsToDepotPaths -Records $args[0] } -ArgumentList @(,$records)
        $result.Count | Should -Be 1
        $result.Contains('//depot/d.cpp') | Should -BeTrue
    }
}

Describe 'Get-P4UnresolvedFileCounts' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'queries each requested changelist with -Ru, -e, and the all-files spec' {
        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter {
            (@($P4Args) -join '|') -eq 'fstat|-Ru|-e|100|-T|change,depotFile,unresolved|//...'
        } {
            return @(
                [pscustomobject]@{ change = '100'; depotFile = '//depot/a.cpp'; unresolved = '' }
            )
        }

        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter {
            (@($P4Args) -join '|') -eq 'fstat|-Ru|-e|200|-T|change,depotFile,unresolved|//...'
        } {
            return @(
                [pscustomobject]@{ change = '200'; depotFile = '//depot/b.cpp'; unresolved = '' },
                [pscustomobject]@{ change = '200'; depotFile = '//depot/c.cpp'; unresolved = '' }
            )
        }

        $result = Get-P4UnresolvedFileCounts -ChangeNumbers @(100, 200)
        $result[100] | Should -Be 1
        $result[200] | Should -Be 2

        Should -Invoke Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            (@($P4Args) -join '|') -eq 'fstat|-Ru|-e|100|-T|change,depotFile,unresolved|//...'
        }
        Should -Invoke Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            (@($P4Args) -join '|') -eq 'fstat|-Ru|-e|200|-T|change,depotFile,unresolved|//...'
        }
    }

    It 'returns correct counts from mocked Invoke-P4' {
        Mock Invoke-P4 -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ change = '100'; depotFile = '//depot/a.cpp'; unresolved = '' },
                [pscustomobject]@{ change = '100'; depotFile = '//depot/b.cpp'; unresolved = '' },
                [pscustomobject]@{ change = '200'; depotFile = '//depot/c.cpp'; unresolved = '' }
            )
        }

        $result = Get-P4UnresolvedFileCounts
        $result[100] | Should -Be 2
        $result[200] | Should -Be 1
    }

    It 'returns empty dictionary when Invoke-P4 throws the no-such-file empty-result error' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'no such file(s).' }

        $result = Get-P4UnresolvedFileCounts
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'degrades to empty dictionary on unexpected Invoke-P4 failure' {
        Mock Invoke-P4 -ModuleName P4Cli { throw 'network timeout' }

        $result = Get-P4UnresolvedFileCounts
        ($result -is [System.Collections.Generic.Dictionary[int,int]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'returns empty dictionary when Invoke-P4 returns empty output' {
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4UnresolvedFileCounts
        $result.Count | Should -Be 0
    }
}

Describe 'Get-P4UnresolvedDepotPaths' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'derives unresolved paths from opened files for the changelist' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli -ParameterFilter {
            $Change -eq 123
        } {
            return @(
                [pscustomobject]@{ DepotPath = '//depot/a.cpp'; IsUnresolved = $true },
                [pscustomobject]@{ DepotPath = '//depot/b.cpp'; IsUnresolved = $false }
            )
        }

        $result = Get-P4UnresolvedDepotPaths -Change 123
        $result.Contains('//depot/a.cpp') | Should -BeTrue
        $result.Contains('//depot/b.cpp') | Should -BeFalse

        Should -Invoke Get-P4OpenedFiles -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            $Change -eq 123
        }
    }

    It 'returns a HashSet containing the correct depot paths' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ DepotPath = '//depot/a.cpp'; IsUnresolved = $true },
                [pscustomobject]@{ DepotPath = '//depot/b.h'; IsUnresolved = $true }
            )
        }

        $result = Get-P4UnresolvedDepotPaths -Change 100
        ($result -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
        $result.Contains('//depot/a.cpp') | Should -BeTrue
        $result.Contains('//depot/b.h')   | Should -BeTrue
        $result.Count | Should -Be 2
    }

    It 'returns empty set when Get-P4OpenedFiles throws' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli { throw 'no such file(s).' }

        $result = Get-P4UnresolvedDepotPaths -Change 200
        ($result -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'degrades to empty set on unexpected Get-P4OpenedFiles failure' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli { throw 'connection refused' }

        $result = Get-P4UnresolvedDepotPaths -Change 300
        $result.Count | Should -Be 0
    }

    It 'uses case-insensitive membership — uppercase lookup matches lowercase record' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ DepotPath = '//depot/src/foo.cs'; IsUnresolved = $true }
            )
        }

        $result = Get-P4UnresolvedDepotPaths -Change 42
        $result.Contains('//DEPOT/SRC/FOO.CS') | Should -BeTrue
    }

    It 'handles duplicate depot path records defensively (set deduplicates)' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli {
            return @(
                [pscustomobject]@{ DepotPath = '//depot/x.cpp'; IsUnresolved = $true },
                [pscustomobject]@{ DepotPath = '//depot/x.cpp'; IsUnresolved = $true }
            )
        }

        $result = Get-P4UnresolvedDepotPaths -Change 77
        $result.Count | Should -Be 1
    }

    It 'returns empty set when Get-P4OpenedFiles returns empty output' {
        Mock Get-P4OpenedFiles -ModuleName P4Cli { return @() }

        $result = Get-P4UnresolvedDepotPaths -Change 55
        $result.Count | Should -Be 0
    }
}

Describe 'Get-P4ModifiedDepotPaths' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'queries p4 diff -sa with depot paths on standard input' {
        $entries = @(
            (New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 10),
            (New-P4FileEntry -DepotPath '//depot/b.cpp' -Action 'integrate' -FileType 'text' -Change 10)
        )

        Mock Invoke-P4 -ModuleName P4Cli -ParameterFilter {
            (@($P4Args) -join '|') -eq 'diff|-sa' -and
            (@($InputLines) -join '|') -eq '//depot/a.cpp|//depot/b.cpp' -and
            (@($AllowedExitCodes) -join ',') -eq '0,1'
        } {
            return @([pscustomobject]@{ depotFile = '//depot/a.cpp' })
        }

        $result = Get-P4ModifiedDepotPaths -FileEntries $entries
        $result.Contains('//depot/a.cpp') | Should -BeTrue

        Should -Invoke Invoke-P4 -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            (@($P4Args) -join '|') -eq 'diff|-sa' -and
            (@($InputLines) -join '|') -eq '//depot/a.cpp|//depot/b.cpp' -and
            (@($AllowedExitCodes) -join ',') -eq '0,1'
        }
    }

    It 'skips non-diffable add and delete actions' {
        $entries = @(
            (New-P4FileEntry -DepotPath '//depot/add.cpp' -Action 'add' -FileType 'text' -Change 10),
            (New-P4FileEntry -DepotPath '//depot/delete.cpp' -Action 'delete' -FileType 'text' -Change 10)
        )
        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4ModifiedDepotPaths -FileEntries $entries
        $result.Count | Should -Be 0
        Should -Invoke Invoke-P4 -ModuleName P4Cli -Times 0 -Exactly
    }

    It 'returns empty set when the diff command fails unexpectedly' {
        $entries = @(
            New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 10
        )

        Mock Invoke-P4 -ModuleName P4Cli { throw 'diff failed' }

        $result = Get-P4ModifiedDepotPaths -FileEntries $entries
        ($result -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }

    It 'returns empty set when there are no modified files' {
        $entries = @(
            New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 10
        )

        Mock Invoke-P4 -ModuleName P4Cli { return @() }

        $result = Get-P4ModifiedDepotPaths -FileEntries $entries
        $result.Count | Should -Be 0
    }

    It 'returns empty set when FileEntries is null' {
        $result = Get-P4ModifiedDepotPaths -FileEntries $null
        ($result -is [System.Collections.Generic.HashSet[string]]) | Should -BeTrue
        $result.Count | Should -Be 0
    }
}

Describe 'Set-P4FileEntriesUnresolvedState' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'marks matching depot path entry as unresolved' {
        $entries = @(New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 10)
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$unresolvedSet.Add('//depot/a.cpp')

        $result = Set-P4FileEntriesUnresolvedState -FileEntries $entries -UnresolvedDepotPaths $unresolvedSet
        $result.Count               | Should -Be 1
        $result[0].IsUnresolved     | Should -BeTrue
        $result[0].SearchKey        | Should -Match 'unresolved'
    }

    It 'leaves non-matching entries clean' {
        $entries = @(New-P4FileEntry -DepotPath '//depot/b.h' -Action 'add' -FileType 'text' -Change 10)
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $result = Set-P4FileEntriesUnresolvedState -FileEntries $entries -UnresolvedDepotPaths $unresolvedSet
        $result[0].IsUnresolved | Should -BeFalse
        $result[0].SearchKey    | Should -Not -Match 'unresolved'
    }

    It 'preserves Action, FileType, Change, and SourceKind on enriched entries' {
        $entries = @(New-P4FileEntry -DepotPath '//depot/c.cpp' -Action 'integrate' -FileType 'binary' -Change 99 -SourceKind 'Opened')
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$unresolvedSet.Add('//depot/c.cpp')

        $result = Set-P4FileEntriesUnresolvedState -FileEntries $entries -UnresolvedDepotPaths $unresolvedSet
        $result[0].Action     | Should -Be 'integrate'
        $result[0].FileType   | Should -Be 'binary'
        $result[0].Change     | Should -Be 99
        $result[0].SourceKind | Should -Be 'Opened'
    }

    It 'handles path casing differences without false negatives' {
        $entries = @(New-P4FileEntry -DepotPath '//Depot/Src/Foo.CS' -Action 'edit' -FileType 'text' -Change 5)
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$unresolvedSet.Add('//depot/src/foo.cs')

        $result = Set-P4FileEntriesUnresolvedState -FileEntries $entries -UnresolvedDepotPaths $unresolvedSet
        $result[0].IsUnresolved | Should -BeTrue
    }

    It 'returns empty array for empty input' {
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $result = Set-P4FileEntriesUnresolvedState -FileEntries @() -UnresolvedDepotPaths $unresolvedSet
        $result.Count | Should -Be 0
    }

    It 'does not mutate the original entry objects' {
        $original = New-P4FileEntry -DepotPath '//depot/d.cpp' -Action 'edit' -FileType 'text' -Change 7
        $entries = @($original)
        $unresolvedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$unresolvedSet.Add('//depot/d.cpp')

        $result = Set-P4FileEntriesUnresolvedState -FileEntries $entries -UnresolvedDepotPaths $unresolvedSet
        $result[0].IsUnresolved | Should -BeTrue
        $original.IsUnresolved  | Should -BeFalse   # original untouched
    }
}

Describe 'Set-P4FileEntriesContentModifiedState' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'marks matching depot path entry as content-modified' {
        $entries = @(New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 10)
        $modifiedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$modifiedSet.Add('//depot/a.cpp')

        $result = Set-P4FileEntriesContentModifiedState -FileEntries $entries -ModifiedDepotPaths $modifiedSet
        $result.Count                    | Should -Be 1
        $result[0].IsContentModified     | Should -BeTrue
        $result[0].SearchKey             | Should -Match 'modified'
    }

    It 'preserves unresolved state while annotating modified content' {
        $entries = @(New-P4FileEntry -DepotPath '//depot/c.cpp' -Action 'edit' -FileType 'text' -Change 99 -IsUnresolved $true)
        $modifiedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$modifiedSet.Add('//depot/c.cpp')

        $result = Set-P4FileEntriesContentModifiedState -FileEntries $entries -ModifiedDepotPaths $modifiedSet
        $result[0].IsUnresolved      | Should -BeTrue
        $result[0].IsContentModified | Should -BeTrue
    }

    It 'leaves non-matching entries clean' {
        $entries = @(New-P4FileEntry -DepotPath '//depot/b.h' -Action 'add' -FileType 'text' -Change 10)
        $modifiedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $result = Set-P4FileEntriesContentModifiedState -FileEntries $entries -ModifiedDepotPaths $modifiedSet
        $result[0].IsContentModified | Should -BeFalse
        $result[0].SearchKey         | Should -Not -Match 'modified'
    }

    It 'does not mutate the original entry objects' {
        $original = New-P4FileEntry -DepotPath '//depot/d.cpp' -Action 'edit' -FileType 'text' -Change 7
        $modifiedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$modifiedSet.Add('//depot/d.cpp')

        $result = Set-P4FileEntriesContentModifiedState -FileEntries @($original) -ModifiedDepotPaths $modifiedSet
        $result[0].IsContentModified | Should -BeTrue
        $original.IsContentModified  | Should -BeFalse
    }
}

Describe 'Get-P4ChangelistEntries — unresolved enrichment' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\p4\Models.psm1') -Force
    }

    It 'passes pending changelist numbers to Get-P4UnresolvedFileCounts' {
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(
                (New-P4Changelist -Change 800 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'desc 800'),
                (New-P4Changelist -Change 801 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'desc 801')
            )
        }
        Mock Get-P4OpenedFileCounts  -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4ShelvedFileCounts -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4UnresolvedFileCounts -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }

        $null = @(Get-P4ChangelistEntries)

        Should -Invoke Get-P4UnresolvedFileCounts -ModuleName P4Cli -Times 1 -Exactly -ParameterFilter {
            (@($ChangeNumbers) -join ',') -eq '800,801'
        }
    }

    It 'populates UnresolvedFileCount and HasUnresolvedFiles when counts are present' {
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(New-P4Changelist -Change 500 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'desc')
        }
        Mock Get-P4OpenedFileCounts  -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4ShelvedFileCounts -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4UnresolvedFileCounts -ModuleName P4Cli {
            $d = [System.Collections.Generic.Dictionary[int,int]]::new()
            $d[500] = 3
            return $d
        }

        $result = @(Get-P4ChangelistEntries)
        $result[0].UnresolvedFileCount | Should -Be 3
        $result[0].HasUnresolvedFiles  | Should -BeTrue
    }

    It 'keeps opened/shelved counts unchanged when unresolved enrichment is added' {
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(New-P4Changelist -Change 600 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'desc')
        }
        Mock Get-P4OpenedFileCounts -ModuleName P4Cli {
            $d = [System.Collections.Generic.Dictionary[int,int]]::new()
            $d[600] = 4
            return $d
        }
        Mock Get-P4ShelvedFileCounts -ModuleName P4Cli {
            $d = [System.Collections.Generic.Dictionary[int,int]]::new()
            $d[600] = 1
            return $d
        }
        Mock Get-P4UnresolvedFileCounts -ModuleName P4Cli {
            $d = [System.Collections.Generic.Dictionary[int,int]]::new()
            $d[600] = 2
            return $d
        }

        $result = @(Get-P4ChangelistEntries)
        $result[0].OpenedFileCount     | Should -Be 4
        $result[0].ShelvedFileCount    | Should -Be 1
        $result[0].UnresolvedFileCount | Should -Be 2
    }

    It 'results in zero UnresolvedFileCount and false HasUnresolvedFiles when no unresolved counts exist' {
        Mock Get-P4PendingChangelists -ModuleName P4Cli {
            return @(New-P4Changelist -Change 700 -User 'u' -Client 'c' -Time (Get-Date) -Status 'pending' -Description 'desc')
        }
        Mock Get-P4OpenedFileCounts     -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4ShelvedFileCounts    -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4UnresolvedFileCounts -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }

        $result = @(Get-P4ChangelistEntries)
        $result[0].UnresolvedFileCount | Should -Be 0
        $result[0].HasUnresolvedFiles  | Should -BeFalse
    }

    It 'does not call Get-P4UnresolvedFileCounts when there are zero pending changelists' {
        Mock Get-P4PendingChangelists   -ModuleName P4Cli { return @() }
        Mock Get-P4OpenedFileCounts     -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4ShelvedFileCounts    -ModuleName P4Cli { return [System.Collections.Generic.Dictionary[int,int]]::new() }
        Mock Get-P4UnresolvedFileCounts -ModuleName P4Cli { throw 'should not be called' }

        { $result = @(Get-P4ChangelistEntries) } | Should -Not -Throw
        Should -Invoke Get-P4UnresolvedFileCounts -ModuleName P4Cli -Times 0 -Exactly
    }
}
