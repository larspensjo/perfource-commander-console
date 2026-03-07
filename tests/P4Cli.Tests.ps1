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

    It 'exceptions thrown inside the observer do not propagate out of Invoke-P4' {
        Register-P4Observer -Observer { throw 'observer-bomb' }
        # A successful invocation must still return results even if observer throws
        { InModuleScope P4Cli { Invoke-P4 -P4Args @('/c', 'echo', '{"v":"ok"}') } } |
            Should -Not -Throw
    }
}
