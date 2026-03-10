Set-StrictMode -Version Latest

# Module-scoped cached theme object — allocated once at module load time.
# Callers should use Get-BrowserUiTheme rather than accessing the variable directly.
$script:BrowserUiTheme = [pscustomobject]@{
    Glyphs = [pscustomobject]@{
        Cursor     = [char]0x25B6  # ▶
        Mark       = [char]0x25CF  # ●
        Unresolved = [string]'⚠'
        Modified   = [string]'≠'
    }
    Labels = [pscustomobject]@{
        FilterPendingUnresolved = 'Has unresolved files'
    }
}

function Get-BrowserUiTheme {
    <#
    .SYNOPSIS
        Returns the shared browser UI theme object (glyphs and labels).
    .DESCRIPTION
        Returns the same cached module-scoped object on every call.
        Do not mutate the returned object.
    #>
    return $script:BrowserUiTheme
}

Export-ModuleMember -Function Get-BrowserUiTheme
