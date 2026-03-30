$modulePath = Join-Path $PSScriptRoot '..\PerfourceCommanderConsole.psm1'
Import-Module $modulePath -Force

Describe 'Start-P4Browser integration' {
    BeforeEach {
        InModuleScope Render {
            $script:PreviousFrame        = $null
            $script:IntegrityTestEnabled = $false
        }

        # Suppress [Console]::Write in the nested Render module used by PerfourceCommanderConsole.
        # Cannot use InModuleScope 'Render' here because Render.Tests.ps1 loads a separate
        # top-level Render instance; PerfourceCommanderConsole uses its own nested instance.
        InModuleScope PerfourceCommanderConsole { Disable-RenderFlush }

        # M4: inject synchronous test executor so async workers run inline and complete
        # immediately without ThreadJob / runspace overhead.
        InModuleScope PerfourceCommanderConsole {
            Set-BrowserAsyncExecutor -Executor ([pscustomobject]@{
                Execute = {
                    param([pscustomobject]$Envelope, [scriptblock]$Worker)
                    $result = & $Worker $Envelope ''   # ModuleRoot='' → skip module imports
                    $script:AsyncJobRegistry[[string]$Envelope.RequestId] = $result
                }
                Poll = {
                    param([string]$RequestId)
                    if ($script:AsyncJobRegistry.ContainsKey($RequestId)) {
                        $r = $script:AsyncJobRegistry[$RequestId]
                        [void]$script:AsyncJobRegistry.Remove($RequestId)
                        return $r
                    }
                    return $null
                }
                Cancel = {
                    param([string]$RequestId)
                    [void]$script:AsyncJobRegistry.Remove($RequestId)
                }
            })
        }

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
            param([string]$Change)
            switch ($Change) {
                '1002' {
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
                '2001' {
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
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false))
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

    It 'surfaces startup p4 failures as a browser error instead of throwing' {
        $script:RenderedLastErrors = [System.Collections.Generic.List[string]]::new()
        $script:PrintedStartupErrors = [System.Collections.Generic.List[string]]::new()
        $script:KeyQueue = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
        $script:KeyQueue.Enqueue([System.ConsoleKeyInfo]::new('q', [System.ConsoleKey]::Q, $false, $false, $false))
        $script:StartupErrorMessage = 'Perforce connection or workspace information is unavailable. Open the browser from a configured workspace or verify your Perforce environment (P4PORT/P4CLIENT).'

        Mock Test-BrowserConsoleKeyAvailable -ModuleName PerfourceCommanderConsole {
            return $script:KeyQueue.Count -gt 0
        }

        Mock Read-BrowserConsoleKey -ModuleName PerfourceCommanderConsole {
            if ($script:KeyQueue.Count -le 0) {
                throw 'Test key queue unexpectedly empty.'
            }
            return $script:KeyQueue.Dequeue()
        }

        Mock Get-P4Info -ModuleName PerfourceCommanderConsole {
            throw $script:StartupErrorMessage
        }

        Mock Get-P4ChangelistEntries -ModuleName PerfourceCommanderConsole {
            throw $script:StartupErrorMessage
        }

        Mock Render-BrowserState -ModuleName PerfourceCommanderConsole {
            param($State)
            $script:RenderedLastErrors.Add([string]$State.Runtime.LastError) | Out-Null
        }

        Mock Write-Host -ModuleName PerfourceCommanderConsole {
            param($Object)
            $script:PrintedStartupErrors.Add([string]$Object) | Out-Null
        }

        {
            Start-P4Browser -IntegrityTest -MaxChanges 3
        } | Should -Not -Throw

        @($script:RenderedLastErrors) | Should -Contain $script:StartupErrorMessage
        @($script:PrintedStartupErrors) | Should -Contain $script:StartupErrorMessage
    }

    It 'terminates immediately after startup p4 info failure' {
        $script:RenderedLastErrors = [System.Collections.Generic.List[string]]::new()
        $script:PrintedStartupErrors = [System.Collections.Generic.List[string]]::new()
        $script:StartupErrorMessage = 'Perforce connection or workspace information is unavailable. Open the browser from a configured workspace or verify your Perforce environment (P4PORT/P4CLIENT).'

        Mock Test-BrowserConsoleKeyAvailable -ModuleName PerfourceCommanderConsole {
            throw 'startup failure should not enter the main input loop'
        }

        Mock Get-P4Info -ModuleName PerfourceCommanderConsole {
            throw $script:StartupErrorMessage
        }

        Mock Get-P4ChangelistEntries -ModuleName PerfourceCommanderConsole {
            throw 'initial load should not run after p4 info fails'
        }

        Mock Render-BrowserState -ModuleName PerfourceCommanderConsole {
            param($State)
            $script:RenderedLastErrors.Add([string]$State.Runtime.LastError) | Out-Null
        }

        Mock Write-Host -ModuleName PerfourceCommanderConsole {
            param($Object)
            $script:PrintedStartupErrors.Add([string]$Object) | Out-Null
        }

        {
            Start-P4Browser -IntegrityTest -MaxChanges 3
        } | Should -Not -Throw

        Assert-MockCalled Get-P4Info -ModuleName PerfourceCommanderConsole -Times 1 -Exactly
        Assert-MockCalled Get-P4ChangelistEntries -ModuleName PerfourceCommanderConsole -Times 0 -Exactly
        @($script:RenderedLastErrors) | Should -Contain $script:StartupErrorMessage
        @($script:PrintedStartupErrors) | Should -Contain $script:StartupErrorMessage
    }

    It 'resets stale render diff state before a new browser session starts' {
        InModuleScope Render {
            $script:PreviousFrame = [pscustomobject]@{
                Width = 140
                Height = 36
                Rows = @([pscustomobject]@{ Y = 0; Signature = 'stale-row'; Segments = @() })
            }
        }

        $script:KeyQueue = [System.Collections.Generic.Queue[System.ConsoleKeyInfo]]::new()
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

        Mock Reset-RenderState -ModuleName PerfourceCommanderConsole {
            InModuleScope Render {
                $script:PreviousFrame = $null
            }
        }

        {
            Start-P4Browser -IntegrityTest -MaxChanges 3
        } | Should -Not -Throw

        Assert-MockCalled Reset-RenderState -ModuleName PerfourceCommanderConsole -Times 2 -Exactly
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

    It 'base load stores opened files without content-modified enrichment (M2.1)' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4OpenedFiles {
                @(
                    (New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened' -IsUnresolved $true),
                    (New-P4FileEntry -DepotPath '//depot/b.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened')
                )
            }
            # Get-P4ModifiedDepotPaths must NOT be called during base load
            Mock Get-P4ModifiedDepotPaths { throw 'enrichment should not run in base load' }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $next  = Invoke-BrowserFilesLoad -State $state -Change 101 -SourceKind 'Opened' -CacheKey '101:Opened'

            $cached = @($next.Data.FileCache['101:Opened'])
            $cached.Count | Should -Be 2
            $cached[0].IsUnresolved | Should -BeTrue
            # IsContentModified not enriched yet — should be absent or false
            $cmProp = $cached[1].PSObject.Properties['IsContentModified']
            if ($null -ne $cmProp) { [bool]$cmProp.Value | Should -BeFalse }

            # FileCacheStatus should be BaseReady
            $next.Data.FileCacheStatus['101:Opened'] | Should -Be 'BaseReady'

            # PendingRequest should signal LoadFilesEnrichment
            $next.Runtime.PendingRequest.Kind | Should -Be 'LoadFilesEnrichment'
            $next.Runtime.PendingRequest.CacheKey | Should -Be '101:Opened'

            Assert-MockCalled Get-P4OpenedFiles -Times 1 -Exactly
            Assert-MockCalled Get-P4ModifiedDepotPaths -Times 0 -Exactly
        }
    }

    It 'enrichment sets IsContentModified and FileCacheStatus Ready (M2.1)' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4ModifiedDepotPaths {
                $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                [void]$set.Add('//depot/b.cpp')
                return $set
            }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $state.Data.FileCache['101:Opened'] = @(
                (New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened'),
                (New-P4FileEntry -DepotPath '//depot/b.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened')
            )
            $state.Data.FileCacheStatus['101:Opened'] = 'BaseReady'

            $next = Invoke-BrowserFilesEnrichment -State $state -CacheKey '101:Opened'

            $cached = @($next.Data.FileCache['101:Opened'])
            $cached[0].IsContentModified | Should -BeFalse
            $cached[1].IsContentModified | Should -BeTrue
            $next.Data.FileCacheStatus['101:Opened'] | Should -Be 'Ready'
        }
    }

    It 'enrichment sets FileCacheStatus EnrichmentFailed when diff throws (M2.1)' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4ModifiedDepotPaths { throw 'p4 diff failed' }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $state.Data.FileCache['101:Opened'] = @(
                (New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened')
            )
            $state.Data.FileCacheStatus['101:Opened'] = 'BaseReady'

            $next = Invoke-BrowserFilesEnrichment -State $state -CacheKey '101:Opened'

            $next.Data.FileCacheStatus['101:Opened'] | Should -Be 'EnrichmentFailed'
        }
    }

    It 'enrichment is a no-op when FileCacheStatus is already Ready (M2.4)' {
        InModuleScope PerfourceCommanderConsole {
            Mock Get-P4ModifiedDepotPaths { throw 'should not be called' }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $state.Data.FileCache['101:Opened'] = @(
                (New-P4FileEntry -DepotPath '//depot/a.cpp' -Action 'edit' -FileType 'text' -Change 101 -SourceKind 'Opened')
            )
            $state.Data.FileCacheStatus['101:Opened'] = 'Ready'

            { Invoke-BrowserFilesEnrichment -State $state -CacheKey '101:Opened' } | Should -Not -Throw
            Assert-MockCalled Get-P4ModifiedDepotPaths -Times 0 -Exactly
        }
    }

    It 'stores an empty opened-file cache entry when the changelist has no opened files' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Get-P4OpenedFiles { return @() }

            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $next = Invoke-BrowserFilesLoad -State $state -Change 202 -SourceKind 'Opened' -CacheKey '202:Opened'

            $next.Data.FileCache.ContainsKey('202:Opened') | Should -BeTrue
            @($next.Data.FileCache['202:Opened']).Count | Should -Be 0
            $next.Data.FileCacheStatus['202:Opened'] | Should -Be 'BaseReady'

            Assert-MockCalled Get-P4OpenedFiles -Times 1 -Exactly -ParameterFilter {
                $Change -eq 202
            }
        }
    }
}

Describe 'Workflow error handling' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Reducer.psm1') -Force
    }

    It 'Start-BrowserAsyncWorkflow filters null and empty change ids before dispatch' {
        InModuleScope PerfourceCommanderConsole {
            $script:CapturedAsyncWorkflowRequest = $null
            Mock Invoke-BrowserStartAsyncRequest {
                param($State, $Request)
                $script:CapturedAsyncWorkflowRequest = $Request
                return $State
            }

            $state = New-BrowserState -Changes @(
                [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $true; Captured = [datetime]'2026-03-07 09:15:00' }
            ) -InitialWidth 120 -InitialHeight 40

            $next = Start-BrowserAsyncWorkflow -State $state -Request ([pscustomobject]@{
                WorkflowKind = 'DeleteMarked'
                ChangeIds    = @($null, '', '101')
            })

            $null = $next
            $script:CapturedAsyncWorkflowRequest | Should -Not -BeNullOrEmpty
            $script:CapturedAsyncWorkflowRequest.Kind     | Should -Be 'DeleteChange'
            $script:CapturedAsyncWorkflowRequest.ChangeId | Should -Be '101'
        }
    }

    It 'DeleteMarked workflow filters null and empty change ids before delete commands' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Remove-P4Changelist { }
            Mock Get-P4ChangelistEntries { @() }

            $changes = @(
                [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false; HasOpenedFiles = $false; Captured = [datetime]'2026-03-01' }
            )
            $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
            $state.Runtime.ConfiguredMax = 25

            $next = & $script:WorkflowRegistry['DeleteMarked'] -State $state -Request ([pscustomobject]@{
                ChangeIds = @($null, '', '101')
            })

            $null = $next
            Assert-MockCalled Remove-P4Changelist -Times 1 -Exactly -ParameterFilter {
                $Change -eq 101
            }
        }
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

    It 'ShelveFiles preserves shelve failures after refreshing pending changelists' {
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
                        HasOpenedFiles   = $false
                        HasShelvedFiles  = $false
                        OpenedFileCount  = 0
                        ShelvedFileCount = 0
                    }
                )
            }
            Mock Invoke-P4ShelveFiles {
                throw "p4 failed (exit 1).`nArgs: shelve -f -c 101`nSTDERR: No files to shelve."
            }

            $changes = @(
                [pscustomobject]@{
                    Id              = '101'
                    Title           = 'One'
                    HasShelvedFiles = $false
                    HasOpenedFiles  = $false
                    Captured        = [datetime]'2026-03-07 09:15:00'
                }
            )
            $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
            $state.Runtime.ConfiguredMax = 25

            $next = & $script:WorkflowRegistry['ShelveFiles'] -State $state -Request ([pscustomobject]@{
                ChangeIds = @('101')
            })

            $next.Runtime.PendingRequest | Should -BeNullOrEmpty
            $next.Runtime.LastWorkflowResult.Kind        | Should -Be 'ShelveFiles'
            $next.Runtime.LastWorkflowResult.DoneCount   | Should -Be 0
            $next.Runtime.LastWorkflowResult.FailedCount | Should -Be 1
            @($next.Runtime.LastWorkflowResult.FailedIds) | Should -Contain '101'
            $next.Runtime.LastError | Should -Match 'No files to shelve'

            Assert-MockCalled Invoke-P4ShelveFiles -Times 1 -Exactly -ParameterFilter {
                $Change -eq 101
            }
            Assert-MockCalled Get-P4ChangelistEntries -Times 1 -Exactly -ParameterFilter {
                $Max -eq 25
            }

            $shelveHistory = @(
                $next.Runtime.ModalPrompt.History |
                    Where-Object { [string]$_.CommandLine -eq 'p4 shelve -f -c 101' }
            )
            $shelveHistory.Count | Should -Be 1
            $shelveHistory[0].Succeeded | Should -BeFalse
            $shelveHistory[0].ErrorText | Should -Match 'No files to shelve'
        }
    }

    It 'DeleteShelvedFiles preserves delete-shelved failures after refreshing pending changelists' {
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
            Mock Remove-P4ShelvedFiles {
                throw "p4 failed (exit 1).`nArgs: shelve -d -c 101`nSTDERR: No shelved files in changelist 101."
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

            $next = & $script:WorkflowRegistry['DeleteShelvedFiles'] -State $state -Request ([pscustomobject]@{
                ChangeIds = @('101')
            })

            $next.Runtime.PendingRequest | Should -BeNullOrEmpty
            $next.Runtime.LastWorkflowResult.Kind        | Should -Be 'DeleteShelvedFiles'
            $next.Runtime.LastWorkflowResult.DoneCount   | Should -Be 0
            $next.Runtime.LastWorkflowResult.FailedCount | Should -Be 1
            @($next.Runtime.LastWorkflowResult.FailedIds) | Should -Contain '101'
            $next.Runtime.LastError | Should -Match 'No shelved files in changelist 101'

            Assert-MockCalled Remove-P4ShelvedFiles -Times 1 -Exactly -ParameterFilter {
                $Change -eq 101
            }
            Assert-MockCalled Get-P4ChangelistEntries -Times 1 -Exactly -ParameterFilter {
                $Max -eq 25
            }

            $deleteShelvedHistory = @(
                $next.Runtime.ModalPrompt.History |
                    Where-Object { [string]$_.CommandLine -eq 'p4 shelve -d -c 101' }
            )
            $deleteShelvedHistory.Count | Should -Be 1
            $deleteShelvedHistory[0].Succeeded | Should -BeFalse
            $deleteShelvedHistory[0].ErrorText | Should -Match 'No shelved files in changelist 101'
        }
    }
}

Describe 'Workflow cancel semantics (M3.3)' {
    BeforeEach {
        InModuleScope PerfourceCommanderConsole {
            # Reset to always-continue between tests
            Set-BrowserCheckCancelCallback { return 'Continue' }
        }
    }

    It 'workflow stops after cancel signal and does not process remaining items (M3.3)' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Remove-P4Changelist { }
            Mock Get-P4ChangelistEntries {
                @([pscustomobject]@{
                    Id = '101'; Title = 'One'; Kind = 'Pending'; User = 'alice'
                    Captured = [datetime]'2026-03-01'; HasOpenedFiles = $false
                    HasShelvedFiles = $false; OpenedFileCount = 0; ShelvedFileCount = 0
                })
            }

            # Cancel AFTER processing item 101 (first cancel check fires for first item)
            $script:M3CancelSignals = @('Cancel', 'Continue', 'Continue')
            $script:M3CancelIdx    = 0
            Set-BrowserCheckCancelCallback {
                $sig = if ($script:M3CancelIdx -lt $script:M3CancelSignals.Count) {
                    $script:M3CancelSignals[$script:M3CancelIdx]
                } else { 'Continue' }
                $script:M3CancelIdx++
                return $sig
            }

            $changes = @(
                [pscustomobject]@{ Id = '101'; Title = 'One'; HasShelvedFiles = $false
                    HasOpenedFiles = $false; Captured = [datetime]'2026-03-01' }
            )
            $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
            $state.Runtime.ConfiguredMax = 25

            $next = & $script:WorkflowRegistry['DeleteMarked'] -State $state -Request ([pscustomobject]@{
                ChangeIds = @('101', '102', '103')
            })

            # Only item 101 should have been processed (cancelled after first check)
            Assert-MockCalled Remove-P4Changelist -Times 1 -Exactly

            # WorkflowEnd was dispatched cleanly
            $next.Runtime.ActiveWorkflow | Should -BeNullOrEmpty

            # CancelRequested cleared by WorkflowEnd
            $next.Runtime.CancelRequested | Should -BeFalse
        }
    }

    It 'deferred quit: QuitRequested survives WorkflowEnd for the main loop to act on (M3.1)' {
        InModuleScope PerfourceCommanderConsole {
            Mock Render-BrowserState { }
            Mock Remove-P4Changelist { }
            Mock Get-P4ChangelistEntries { @() }

            Set-BrowserCheckCancelCallback { return 'Quit' }

            $changes = @(
                [pscustomobject]@{ Id = '999'; Title = 'Q'; HasShelvedFiles = $false
                    HasOpenedFiles = $false; Captured = [datetime]'2026-03-01' }
            )
            $state = New-BrowserState -Changes $changes -InitialWidth 120 -InitialHeight 40
            $state.Runtime.ConfiguredMax = 25

            $next = & $script:WorkflowRegistry['DeleteMarked'] -State $state -Request ([pscustomobject]@{
                ChangeIds = @('999')
            })

            # QuitRequested survives WorkflowEnd so the main loop can check it
            $next.Runtime.QuitRequested   | Should -BeTrue
            # CancelRequested cleared by WorkflowEnd; QuitRequested persists
            $next.Runtime.CancelRequested  | Should -BeFalse
            $next.Runtime.ActiveWorkflow   | Should -BeNullOrEmpty
        }
    }
}

Describe 'Async cancellation races (M5.5)' {
    BeforeEach {
        InModuleScope PerfourceCommanderConsole {
            $script:AsyncJobRegistry = @{}
            Set-BrowserAsyncExecutor -Executor ([pscustomobject]@{
                Execute = {
                    param([pscustomobject]$Envelope, [scriptblock]$Worker)
                    $null = $Envelope
                    $null = $Worker
                    throw 'Execute should not be called in this test.'
                }
                Poll = {
                    param([string]$RequestId)
                    if ($script:AsyncJobRegistry.ContainsKey($RequestId)) {
                        $result = $script:AsyncJobRegistry[$RequestId]
                        [void]$script:AsyncJobRegistry.Remove($RequestId)
                        return $result
                    }
                    return $null
                }
                Cancel = {
                    param([string]$RequestId)
                    [void]$script:AsyncJobRegistry.Remove($RequestId)
                }
            })
        }
    }

    It 'cancel arriving after completion is a no-op' {
        InModuleScope PerfourceCommanderConsole {
            $startedAt = [datetime]'2026-03-12T10:00:00'
            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type        = 'AsyncCommandStarted'
                RequestId   = 'req-1'
                Kind        = 'DeleteChange'
                Scope       = 'Mutation'
                Generation  = 0
                CommandLine = 'p4 change -d 101'
                StartedAt   = $startedAt
                TimeoutMs   = 30000
            })

            $script:AsyncJobRegistry['req-1'] = [pscustomobject]@{
                Type             = 'MutationCompleted'
                RequestId        = 'req-1'
                Generation       = 0
                Success          = $true
                Outcome          = 'Completed'
                ObservedCommands = @()
            }

            $drainResult = Invoke-BrowserCompletionDrain -State $state
            $drainResult.Completion.Type | Should -Be 'MutationCompleted'

            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type          = 'CommandFinish'
                CommandLine   = 'p4 change -d 101'
                StartedAt     = $startedAt
                EndedAt       = $startedAt.AddMilliseconds(250)
                ExitCode      = 0
                Succeeded     = $true
                ErrorText     = ''
                DurationClass = 'Info'
                Outcome       = 'Completed'
            })
            $state = Invoke-BrowserReducer -State $state -Action $drainResult.Completion

            $state.Runtime.ActiveCommand | Should -BeNullOrEmpty
            $cancelResult = Invoke-BrowserCancelActiveCommand -State $state
            $cancelResult | Should -BeNullOrEmpty
        }
    }

    It 'cancel takes precedence over a queued timeout completion' {
        InModuleScope PerfourceCommanderConsole {
            $startedAt = [datetime]'2026-03-12T10:05:00'
            $state = New-BrowserState -Changes @() -InitialWidth 120 -InitialHeight 40
            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type        = 'AsyncCommandStarted'
                RequestId   = 'req-2'
                Kind        = 'DeleteChange'
                Scope       = 'Mutation'
                Generation  = 0
                CommandLine = 'p4 change -d 202'
                StartedAt   = $startedAt
                TimeoutMs   = 30000
            })

            $script:AsyncJobRegistry['req-2'] = [pscustomobject]@{
                Type             = 'AsyncCommandFailed'
                RequestId        = 'req-2'
                Generation       = 0
                ErrorText        = 'p4 timed out after 10 ms. Args: change -d 202'
                Success          = $false
                Outcome          = 'TimedOut'
                ObservedCommands = @()
            }

            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type      = 'AsyncCommandCancelling'
                RequestId = 'req-2'
            })
            $cancelResult = Invoke-BrowserCancelActiveCommand -State $state

            $cancelResult.Completion.Type | Should -Be 'CommandCancelled'
            $cancelResult.Completion.Outcome | Should -Be 'Cancelled'

            $state = Invoke-BrowserReducer -State $state -Action ([pscustomobject]@{
                Type          = 'CommandFinish'
                CommandLine   = 'p4 change -d 202'
                StartedAt     = $startedAt
                EndedAt       = $startedAt.AddMilliseconds(150)
                ExitCode      = 1
                Succeeded     = $false
                ErrorText     = 'Command cancelled.'
                DurationClass = 'Info'
                Outcome       = 'Cancelled'
            })
            $state = Invoke-BrowserReducer -State $state -Action $cancelResult.Completion

            $state.Runtime.ActiveCommand | Should -BeNullOrEmpty
            $state.Runtime.LastError | Should -BeNullOrEmpty
            (Invoke-BrowserCompletionDrain -State $state) | Should -BeNullOrEmpty
        }
    }
}
