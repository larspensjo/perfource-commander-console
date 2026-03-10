$modulePath = Join-Path $PSScriptRoot '..\PerfourceCommanderConsole.psm1'
Import-Module $modulePath -Force

Describe 'Start-P4Browser integration' {
    BeforeEach {
        InModuleScope Render {
            $script:PreviousFrame = $null
            $script:IntegrityTestEnabled = $false
        }

        Mock Flush-FrameDiff -ModuleName Render { $true }

        Mock Get-BrowserConsoleSize -ModuleName PerfourceCommanderConsole {
            [pscustomobject]@{ Width = 140; Height = 36 }
        }

        Mock Initialize-BrowserConsole -ModuleName PerfourceCommanderConsole {
            [pscustomobject]@{ OutputEncoding = [System.Text.Encoding]::UTF8; CursorVisible = $true }
        }

        Mock Restore-BrowserConsole -ModuleName PerfourceCommanderConsole { }
        Mock Start-Sleep -ModuleName PerfourceCommanderConsole { }

        Mock Get-P4Info -ModuleName PerfourceCommanderConsole {
            [pscustomobject]@{
                User   = 'alice'
                Client = 'workspace-main'
                Port   = 'ssl:perforce:1666'
                Root   = 'C:\workspace-main'
            }
        }

        Mock Get-P4ChangelistEntries -ModuleName PerfourceCommanderConsole {
            @(
                [pscustomobject]@{
                    Id               = '1001'
                    Title            = 'Fix build pipeline'
                    Kind             = 'Pending'
                    User             = 'alice'
                    Captured         = [datetime]'2026-03-07 09:15:00'
                    HasOpenedFiles   = $true
                    HasShelvedFiles  = $false
                    OpenedFileCount  = 4
                    ShelvedFileCount = 0
                },
                [pscustomobject]@{
                    Id               = '1002'
                    Title            = 'Refactor submit flow'
                    Kind             = 'Pending'
                    User             = 'alice'
                    Captured         = [datetime]'2026-03-06 17:30:00'
                    HasOpenedFiles   = $false
                    HasShelvedFiles  = $true
                    OpenedFileCount  = 0
                    ShelvedFileCount = 2
                },
                [pscustomobject]@{
                    Id               = '1003'
                    Title            = 'Improve panel layout'
                    Kind             = 'Pending'
                    User             = 'alice'
                    Captured         = [datetime]'2026-03-05 13:45:00'
                    HasOpenedFiles   = $true
                    HasShelvedFiles  = $true
                    OpenedFileCount  = 6
                    ShelvedFileCount = 1
                }
            )
        }

        Mock Get-P4SubmittedChangelistEntries -ModuleName PerfourceCommanderConsole {
            @(
                [pscustomobject]@{
                    Id         = '2001'
                    Title      = 'Submitted fix for file loading'
                    Kind       = 'Submitted'
                    User       = 'alice'
                    Client     = 'workspace-main'
                    SubmitTime = [datetime]'2026-03-07 10:00:00'
                    Captured   = [datetime]'2026-03-07 10:00:00'
                }
            )
        }

        Mock Get-P4Describe -ModuleName PerfourceCommanderConsole {
            param([int]$Change)
            switch ($Change) {
                1002 {
                    return [pscustomobject]@{
                        Change      = 1002
                        User        = 'alice'
                        Client      = 'workspace-main'
                        Status      = 'pending'
                        Time        = [datetime]'2026-03-06 17:30:00'
                        Description = @('Refactor submit flow', 'Tighten render sequencing')
                        Files       = @(
                            [pscustomobject]@{ DepotPath = '//depot/app.ps1';  Action = 'edit'; Type = 'text' },
                            [pscustomobject]@{ DepotPath = '//depot/view.psm1'; Action = 'edit'; Type = 'text' }
                        )
                    }
                }
                2001 {
                    return [pscustomobject]@{
                        Change      = 2001
                        User        = 'alice'
                        Client      = 'workspace-main'
                        Status      = 'submitted'
                        Time        = [datetime]'2026-03-07 10:00:00'
                        Description = @('Submitted fix for file loading')
                        Files       = @(
                            [pscustomobject]@{ DepotPath = '//depot/submitted/a.cpp'; Action = 'edit'; Type = 'text' },
                            [pscustomobject]@{ DepotPath = '//depot/submitted/b.h';   Action = 'add';  Type = 'text' }
                        )
                    }
                }
                default {
                    throw "Unexpected describe change $Change"
                }
            }
        }
    }

    It 'runs end-to-end with mocked p4 and integrity testing enabled' {
        $script:KeyQueue = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new(' ', [System.ConsoleKey]::Tab, $false, $false, $false))
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new(' ', [System.ConsoleKey]::DownArrow, $false, $false, $false))
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new('d', [System.ConsoleKey]::D, $false, $false, $false))
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new('q', [System.ConsoleKey]::Q, $false, $false, $false))

        Mock Test-BrowserConsoleKeyAvailable -ModuleName PerfourceCommanderConsole {
            return $script:KeyQueue.Count -gt 0
        }

        Mock Read-BrowserConsoleKey -ModuleName PerfourceCommanderConsole {
            if ($script:KeyQueue.Count -le 0) {
                throw 'Test key queue unexpectedly empty.'
            }
            return $script:KeyQueue.Dequeue()
        }

        {
            Start-P4Browser -IntegrityTest -MaxChanges 3
        } | Should -Not -Throw

        Assert-MockCalled Get-P4Info -ModuleName PerfourceCommanderConsole -Times 1 -Exactly
        Assert-MockCalled Get-P4ChangelistEntries -ModuleName PerfourceCommanderConsole -Times 1 -Exactly -ParameterFilter {
            $Max -eq 3
        }
        Assert-MockCalled Get-P4Describe -ModuleName PerfourceCommanderConsole -Times 1 -Exactly -ParameterFilter {
            $Change -eq 1002
        }
    }

    It 'loads submitted files via describe when opening files from submitted view' {
        $script:KeyQueue = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new('2', [System.ConsoleKey]::D2, $false, $false, $false))
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new(' ', [System.ConsoleKey]::Tab, $false, $false, $false))
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::RightArrow, $false, $false, $false))
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new('q', [System.ConsoleKey]::Q, $false, $false, $false))

        Mock Test-BrowserConsoleKeyAvailable -ModuleName PerfourceCommanderConsole {
            return $script:KeyQueue.Count -gt 0
        }

        Mock Read-BrowserConsoleKey -ModuleName PerfourceCommanderConsole {
            if ($script:KeyQueue.Count -le 0) {
                throw 'Test key queue unexpectedly empty.'
            }
            return $script:KeyQueue.Dequeue()
        }

        {
            Start-P4Browser -IntegrityTest -MaxChanges 3
        } | Should -Not -Throw

        Assert-MockCalled Get-P4SubmittedChangelistEntries -ModuleName PerfourceCommanderConsole -Times 1 -Exactly -ParameterFilter {
            $Max -eq 50 -and $Client -eq 'workspace-main'
        }
        Assert-MockCalled Get-P4Describe -ModuleName PerfourceCommanderConsole -Times 1 -ParameterFilter {
            $Change -eq 2001
        }
    }
}

Describe 'Browser file loading helpers' {
    It 'throws for unsupported file source kinds' {
        InModuleScope PerfourceCommanderConsole {
            $state = [pscustomobject]@{}
            {
                Invoke-BrowserFilesLoad -State $state -Change 1 -SourceKind 'UnknownKind' -CacheKey '1:UnknownKind'
            } | Should -Throw "*Unsupported FilesSourceKind 'UnknownKind'*"
        }
    }

    It 'stores opened files with content-modified enrichment in FileCache' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4OpenedFiles {
                @(
                    (New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened' -IsUnresolved $true),
                    (New-P4FileEntry -DepotPath '//depot/b.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened')
                )
            }
            Mock Get-P4ModifiedDepotPaths {
                $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                [void]$set.Add('//depot/b.cpp')
                return $set
            }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $next = Invoke-BrowserFilesLoad -State $state -Change 101 -SourceKind 'Opened' -CacheKey '101:Opened'

            $cached = @($next.Data.FileCache['101:Opened'])
            $cached.Count | Should -Be 2
            $cached[0].IsUnresolved | Should -BeTrue
            $cached[0].IsContentModified | Should -BeFalse
            $cached[1].IsUnresolved | Should -BeFalse
            $cached[1].IsContentModified | Should -BeTrue

            Assert-MockCalled Get-P4OpenedFiles -Times 1 -Exactly -ParameterFilter {
                $Change -eq 101
            }
            Assert-MockCalled Get-P4ModifiedDepotPaths -Times 1 -Exactly -ParameterFilter {
                @($FileEntries).Count -eq 2
            }
        }
    }

    It 'stores an empty opened-file cache entry when the changelist has no opened files' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4OpenedFiles { return @() }
            Mock Get-P4ModifiedDepotPaths {
                $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                return $set
            }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $next = Invoke-BrowserFilesLoad -State $state -Change 202 -SourceKind 'Opened' -CacheKey '202:Opened'

            $next.Data.FileCache.ContainsKey('202:Opened') | Should -BeTrue
            @($next.Data.FileCache['202:Opened']).Count | Should -Be 0

            Assert-MockCalled Get-P4OpenedFiles -Times 1 -Exactly -ParameterFilter {
                $Change -eq 202
            }
            Assert-MockCalled Get-P4ModifiedDepotPaths -Times 1 -Exactly -ParameterFilter {
                @($FileEntries).Count -eq 0
            }
        }
    }
}

Describe 'Workflow error handling' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    It 'DeleteMarked preserves delete failures after refreshing pending changelists' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4ChangelistEntries {
                @(
                    [pscustomobject]@{
                        Id               = '101'
                        Title            = 'One'
                        Kind             = 'Pending'
                        User             = 'alice'
                        Captured         = [datetime]'2026-03-07 09:15:00'
                        HasOpenedFiles   = $true
                        HasShelvedFiles  = $true
                        OpenedFileCount  = 6
                        ShelvedFileCount = 1
                    }
                )
            }
            Mock Remove-P4Changelist {
                throw "p4 failed (exit 1).`nArgs: change -d 101`nSTDERR: Change 101 has 6 open file(s) associated with it and can't be deleted."
            }

            $changes = @(
                [pscustomobject]@{
                    Id              = '101'
                    Title           = 'One'
                    HasShelvedFiles = $true
                    HasOpenedFiles  = $true
                    Captured        = [datetime]'2026-03-07 09:15:00'
                }
            )
            $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
            $state.Runtime.ConfiguredMax = 25
            [void]$state.Query.MarkedChangeIds.Add('101')

            $next = & $script:WorkflowRegistry['DeleteMarked'] -State $state -Request ([pscustomobject]@{
                ChangeIds = @('101')
            })

            $next.Runtime.PendingRequest | Should -BeNullOrEmpty
            $next.Runtime.LastWorkflowResult.Kind        | Should -Be 'DeleteMarked'
            $next.Runtime.LastWorkflowResult.DoneCount   | Should -Be 0
            $next.Runtime.LastWorkflowResult.FailedCount | Should -Be 1
            @($next.Runtime.LastWorkflowResult.FailedIds) | Should -Contain '101'
            $next.Runtime.LastError | Should -Match "can't be deleted"
            @($next.Query.MarkedChangeIds) | Should -Contain '101'

            Assert-MockCalled Remove-P4Changelist -Times 1 -Exactly -ParameterFilter {
                $Change -eq 101
            }
            Assert-MockCalled Get-P4ChangelistEntries -Times 1 -Exactly -ParameterFilter {
                $Max -eq 25
            }

            $deleteHistory = @(
                $next.Runtime.ModalPrompt.History |
                    Where-Object { [string]$_.CommandLine -eq 'p4 change -d 101' }
            )
            $deleteHistory.Count | Should -Be 1
            $deleteHistory[0].Succeeded | Should -BeFalse
            $deleteHistory[0].ErrorText | Should -Match "can't be deleted"
        }
    }
}
