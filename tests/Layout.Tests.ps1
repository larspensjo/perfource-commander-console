Describe 'Get-BrowserLayout' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\browser\Layout.psm1'
        Import-Module $modulePath -Force
    }

    It 'returns TooSmall mode for small dimensions' {
        $layout = Get-BrowserLayout -Width 10 -Height 10
        $layout.Mode | Should -Be 'TooSmall'
    }

    It 'returns valid panes for normal dimensions' {
        $layout = Get-BrowserLayout -Width 120 -Height 40
        $layout.Mode | Should -Be 'Normal'
        $layout.TagPane.W | Should -BeGreaterThan 0
        $layout.ListPane.H | Should -BeGreaterThan 0
        $layout.DetailPane.H | Should -BeGreaterThan 0
    }
}
