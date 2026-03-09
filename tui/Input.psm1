Set-StrictMode -Version Latest

function ConvertFrom-KeyInfoToAction {
    param(
        [Parameter(Mandatory = $true)][System.ConsoleKeyInfo]$KeyInfo,
        $State = $null
    )

    # When a menu is open, route all keys through the menu key handler
    if ($null -ne $State) {
        $overlayModeProp = $State.Ui.PSObject.Properties['OverlayMode']
        if ($null -ne $overlayModeProp -and [string]$overlayModeProp.Value -eq 'Menu') {
            switch ($KeyInfo.Key) {
                'UpArrow'   { return [pscustomobject]@{ Type = 'MenuMoveUp' } }
                'DownArrow' { return [pscustomobject]@{ Type = 'MenuMoveDown' } }
                'Enter'     { return [pscustomobject]@{ Type = 'MenuSelect' } }
                'Escape'    { return [pscustomobject]@{ Type = 'HideCommandModal' } }
                'LeftArrow' { return [pscustomobject]@{ Type = 'MenuSwitchLeft' } }
                'RightArrow'{ return [pscustomobject]@{ Type = 'MenuSwitchRight' } }
                default {
                    $char = $KeyInfo.KeyChar
                    if ($char -ne [char]0) {
                        return [pscustomobject]@{ Type = 'MenuAccelerator'; Key = $char.ToString().ToUpper() }
                    }
                    return $null
                }
            }
        }
    }

    # Modifier-aware chords (checked before the plain-key switch)
    $isAlt   = ($KeyInfo.Modifiers -band [System.ConsoleModifiers]::Alt)   -ne 0
    $isShift = ($KeyInfo.Modifiers -band [System.ConsoleModifiers]::Shift) -ne 0

    if ($isShift -and -not $isAlt) {
        switch ($KeyInfo.Key) {
            'M' { return [pscustomobject]@{ Type = 'MarkAllVisible' } }
        }
    }

    if ($isAlt -and -not $isShift) {
        switch ([string]$KeyInfo.Key) {
            'F' { return [pscustomobject]@{ Type = 'OpenMenu'; Menu = 'File' } }
            'V' { return [pscustomobject]@{ Type = 'OpenMenu'; Menu = 'View' } }
        }
    }

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
        'E' { return [pscustomobject]@{ Type = 'ToggleChangelistView' } }
        'Delete' { return [pscustomobject]@{ Type = 'DeleteChange' } }
        'X' { return [pscustomobject]@{ Type = 'DeleteChange' } }
        'Insert' { return [pscustomobject]@{ Type = 'ToggleMarkCurrent' } }
        'M' { return [pscustomobject]@{ Type = 'ToggleMarkCurrent' } }
        'C' { return [pscustomobject]@{ Type = 'ClearMarks' } }
        'F1' { return [pscustomobject]@{ Type = 'ToggleHelpOverlay' } }
        'F5' { return [pscustomobject]@{ Type = 'Reload' } }
        'F12' { return [pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' } }
        'Escape' { return [pscustomobject]@{ Type = 'HideCommandModal' } }
        'D1' { return [pscustomobject]@{ Type = 'SwitchView'; View = 'Pending' } }
        'D2' { return [pscustomobject]@{ Type = 'SwitchView'; View = 'Submitted' } }
        'D3' { return [pscustomobject]@{ Type = 'SwitchView'; View = 'CommandLog' } }
        'L' { return [pscustomobject]@{ Type = 'LoadMore' } }
        'Y' { return [pscustomobject]@{ Type = 'AcceptDialog' } }
        'N' { return [pscustomobject]@{ Type = 'CancelDialog' } }
        # Files screen navigation
        'RightArrow' { return [pscustomobject]@{ Type = 'OpenFilesScreen' } }
        'O' { return [pscustomobject]@{ Type = 'OpenFilesScreen' } }
        'LeftArrow' { return [pscustomobject]@{ Type = 'CloseFilesScreen' } }
        # '/' key (OemQuestion on US keyboard) — opens filter prompt on files screen
        'OemQuestion' { return [pscustomobject]@{ Type = 'OpenFilterPrompt' } }
        default { return $null }
    }
}

Export-ModuleMember -Function ConvertFrom-KeyInfoToAction
