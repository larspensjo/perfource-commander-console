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
        [Parameter(Mandatory = $false)][bool]$IsEmpty = $false
    )

    $title = [string]$Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    $filters = @($Changelist.Status, $Changelist.Client, $Changelist.User) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Select-Object -Unique
    if ($IsEmpty) {
        $filters = @($filters) + @('Empty')
    }

    [pscustomobject]@{
        Id        = "CL-$($Changelist.Change)"
        Title     = $title
        Filters   = $filters
        Priority  = 'P2'
        Risk      = 'M'
        Effort    = 'M'
        Summary   = $title
        Rationale = "User=$($Changelist.User)  Client=$($Changelist.Client)  Status=$($Changelist.Status)  Time=$($Changelist.Time.ToString('u'))"
        Captured  = $Changelist.Time
    }
}

Export-ModuleMember -Function *-P4Changelist, ConvertTo-ChangelistEntry
