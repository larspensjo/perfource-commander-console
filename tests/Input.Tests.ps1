$modulePath = Join-Path $PSScriptRoot '..\tui\Input.psm1'
Import-Module $modulePath -Force

Describe 'ConvertFrom-KeyInfoToAction' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\tui\Input.psm1') -Force

        function New-KeyInfo {
            param([System.ConsoleKey]$Key)
            # ConsoleKeyInfo(char keyChar, ConsoleKey key, bool shift, bool alt, bool control)
            return [System.ConsoleKeyInfo]::new([char]0, $Key, $false, $false, $false)
        }
    }

    It 'Q maps to Quit' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Q)
        $action.Type | Should -Be 'Quit'
    }

    It 'Tab maps to SwitchPane' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Tab)
        $action.Type | Should -Be 'SwitchPane'
    }

    It 'UpArrow maps to MoveUp' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key UpArrow)
        $action.Type | Should -Be 'MoveUp'
    }

    It 'DownArrow maps to MoveDown' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key DownArrow)
        $action.Type | Should -Be 'MoveDown'
    }

    It 'PageUp maps to PageUp' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key PageUp)
        $action.Type | Should -Be 'PageUp'
    }

    It 'PageDown maps to PageDown' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key PageDown)
        $action.Type | Should -Be 'PageDown'
    }

    It 'Home maps to MoveHome' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Home)
        $action.Type | Should -Be 'MoveHome'
    }

    It 'End maps to MoveEnd' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key End)
        $action.Type | Should -Be 'MoveEnd'
    }

    It 'Spacebar maps to ToggleFilter' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Spacebar)
        $action.Type | Should -Be 'ToggleFilter'
    }

    It 'Enter maps to Describe' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Enter)
        $action.Type | Should -Be 'Describe'
    }

    It 'D maps to Describe' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key D)
        $action.Type | Should -Be 'Describe'
    }

    It 'E maps to ToggleChangelistView' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key E)
        $action.Type | Should -Be 'ToggleChangelistView'
    }

    It 'Delete maps to DeleteChange' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Delete)
        $action.Type | Should -Be 'DeleteChange'
    }

    It 'X maps to DeleteChange' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key X)
        $action.Type | Should -Be 'DeleteChange'
    }

    It 'F5 maps to Reload' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key F5)
        $action.Type | Should -Be 'Reload'
    }

    It 'F12 maps to SwitchView CommandLog' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key F12)
        $action.Type | Should -Be 'SwitchView'
        $action.View | Should -Be 'CommandLog'
    }

    It 'D3 maps to SwitchView CommandLog' {
        $keyInfo = [System.ConsoleKeyInfo]::new([char][System.ConsoleKey]::D3, [System.ConsoleKey]::D3, $false, $false, $false)
        $action  = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo
        $action.Type | Should -Be 'SwitchView'
        $action.View | Should -Be 'CommandLog'
    }

    It 'Escape maps to HideCommandModal' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Escape)
        $action.Type | Should -Be 'HideCommandModal'
    }

    It 'H maps to ToggleHideUnavailableFilters' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key H)
        $action.Type | Should -Be 'ToggleHideUnavailableFilters'
    }

    It 'F1 maps to ToggleHelpOverlay' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key F1)
        $action.Type | Should -Be 'ToggleHelpOverlay'
    }

    It 'Insert maps to ToggleMarkCurrent' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key Insert)
        $action.Type | Should -Be 'ToggleMarkCurrent'
    }

    It 'M maps to ToggleMarkCurrent' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key M)
        $action.Type | Should -Be 'ToggleMarkCurrent'
    }

    It 'Shift+M maps to MarkAllVisible' {
        $keyInfo = [System.ConsoleKeyInfo]::new([char][System.ConsoleKey]::M, [System.ConsoleKey]::M, $true, $false, $false)
        $action  = ConvertFrom-KeyInfoToAction -KeyInfo $keyInfo
        $action.Type | Should -Be 'MarkAllVisible'
    }

    It 'C maps to ClearMarks' {
        $action = ConvertFrom-KeyInfoToAction -KeyInfo (New-KeyInfo -Key C)
        $action.Type | Should -Be 'ClearMarks'
    }}