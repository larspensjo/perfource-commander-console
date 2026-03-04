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
        [Parameter(Mandatory)][object]$Changelist
    )

    $title = [string]$Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    [pscustomobject]@{
        Id        = "CL-$($Changelist.Change)"
        Title     = $title
        Filters = @($Changelist.Status, $Changelist.Client, $Changelist.User) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Select-Object -Unique
        Priority  = 'P2'
        Risk      = 'M'
        Effort    = 'M'
        Summary   = $title
        Rationale = "User=$($Changelist.User)  Client=$($Changelist.Client)  Status=$($Changelist.Status)  Time=$($Changelist.Time.ToString('u'))"
        Captured  = $Changelist.Time
    }
}

Export-ModuleMember -Function *-P4Changelist, ConvertTo-ChangelistEntry
