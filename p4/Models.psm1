Set-StrictMode -Version Latest

function New-P4Changelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Change,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Client,
        [Parameter(Mandatory)][datetime]$Time,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Description
    )

    [pscustomobject]@{
        Change      = $Change
        User        = $User
        Client      = $Client
        Time        = $Time
        Status      = $Status
        Description = $Description
    }
}

function ConvertTo-ChangelistEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Changelist,
        [Parameter(Mandatory = $false)][bool]$HasShelvedFiles = $false,
        [Parameter(Mandatory = $false)][bool]$HasOpenedFiles = $false
    )

    $title = [string]$Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    [pscustomobject]@{
        Id              = "$($Changelist.Change)"
        Title           = $title
        HasShelvedFiles = $HasShelvedFiles
        HasOpenedFiles  = $HasOpenedFiles
        Captured        = $Changelist.Time
    }
}

Export-ModuleMember -Function *-P4Changelist, ConvertTo-ChangelistEntry
