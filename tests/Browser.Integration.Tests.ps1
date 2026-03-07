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

        Mock Get-P4Describe -ModuleName PerfourceCommanderConsole {
            [pscustomobject]@{
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
}
