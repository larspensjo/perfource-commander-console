Set-StrictMode -Version Latest

function ConvertFrom-KeyInfoToAction {
    param(
        [Parameter(Mandatory = $true)][System.ConsoleKeyInfo]$KeyInfo
    )

    switch ($KeyInfo.Key) {
        'Q' { return [pscustomobject]@{ Type = 'Quit' } }
        'H' { return [pscustomobject]@{ Type = 'ToggleHideUnavailableTags' } }
        'Tab' { return [pscustomobject]@{ Type = 'SwitchPane' } }
        'UpArrow' { return [pscustomobject]@{ Type = 'MoveUp' } }
        'DownArrow' { return [pscustomobject]@{ Type = 'MoveDown' } }
        'PageUp' { return [pscustomobject]@{ Type = 'PageUp' } }
        'PageDown' { return [pscustomobject]@{ Type = 'PageDown' } }
        'Home' { return [pscustomobject]@{ Type = 'MoveHome' } }
        'End' { return [pscustomobject]@{ Type = 'MoveEnd' } }
        'Spacebar' { return [pscustomobject]@{ Type = 'ToggleTag' } }
        default { return $null }
    }
}

Export-ModuleMember -Function ConvertFrom-KeyInfoToAction
