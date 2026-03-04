Set-StrictMode -Version Latest

function ConvertFrom-KeyInfoToAction {
    param(
        [Parameter(Mandatory = $true)][System.ConsoleKeyInfo]$KeyInfo
    )

    switch ($KeyInfo.Key) {
        'Q' { return [pscustomobject]@{ Type = 'Quit' } }
        'H' { return [pscustomobject]@{ Type = 'ToggleHideUnavailableFilters' } }
        'Tab' { return [pscustomobject]@{ Type = 'SwitchPane' } }
        'UpArrow' { return [pscustomobject]@{ Type = 'MoveUp' } }
        'DownArrow' { return [pscustomobject]@{ Type = 'MoveDown' } }
        'PageUp' { return [pscustomobject]@{ Type = 'PageUp' } }
        'PageDown' { return [pscustomobject]@{ Type = 'PageDown' } }
        'Home' { return [pscustomobject]@{ Type = 'MoveHome' } }
        'End' { return [pscustomobject]@{ Type = 'MoveEnd' } }
        'Spacebar' { return [pscustomobject]@{ Type = 'ToggleFilter' } }
        'Enter' { return [pscustomobject]@{ Type = 'Describe' } }
        'D' { return [pscustomobject]@{ Type = 'Describe' } }
        'Delete' { return [pscustomobject]@{ Type = 'DeleteChange' } }
        'X' { return [pscustomobject]@{ Type = 'DeleteChange' } }
        'F5' { return [pscustomobject]@{ Type = 'Reload' } }
        default { return $null }
    }
}

Export-ModuleMember -Function ConvertFrom-KeyInfoToAction
