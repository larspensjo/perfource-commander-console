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
        [Parameter(Mandatory = $false)][int]$OpenedFileCount = 0,
        [Parameter(Mandatory = $false)][int]$ShelvedFileCount = 0
    )

    $title = [string]$Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    [pscustomobject]@{
        Id               = "$($Changelist.Change)"
        Title            = $title
        HasShelvedFiles  = ($ShelvedFileCount -gt 0)
        HasOpenedFiles   = ($OpenedFileCount -gt 0)
        OpenedFileCount  = $OpenedFileCount
        ShelvedFileCount = $ShelvedFileCount
        Captured         = $Changelist.Time
    }
}

function ConvertTo-SubmittedChangelistEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Changelist
    )

    $title = [string]$Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    [pscustomobject]@{
        Id         = "$($Changelist.Change)"
        Title      = $title
        User       = [string]$Changelist.User
        Client     = [string]$Changelist.Client
        SubmitTime = $Changelist.Time
        Captured   = $Changelist.Time
        Kind       = 'Submitted'
    }
}

function New-P4FileEntry {
    <#
    .SYNOPSIS
        Constructs a FileEntry object from raw Perforce file data.
    .DESCRIPTION
        Derives FileName from the tail of DepotPath and precomputes SearchKey
        (lowercased concatenation of DepotPath, Action, and FileType) for fast
        in-memory substring filtering without repeated string allocations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DepotPath,
        [Parameter(Mandatory = $false)][string]$Action     = '',
        [Parameter(Mandatory = $false)][string]$FileType   = '',
        [Parameter(Mandatory = $false)][int]$Change        = 0,
        [Parameter(Mandatory = $false)][string]$SourceKind = 'Opened'
    )

    # Derive FileName: last path segment after the final '/'
    $fileName = if ($DepotPath -match '[^/]+$') { $Matches[0] } else { $DepotPath }

    # Precompute SearchKey once to avoid repeated allocations in the filter hot-path.
    # Includes FileType so future 'type:' facets work without cache invalidation.
    $searchKey = ($DepotPath + ' ' + $Action + ' ' + $FileType).ToLowerInvariant()

    [pscustomobject]@{
        DepotPath  = $DepotPath
        FileName   = $fileName
        Action     = $Action
        FileType   = $FileType
        Change     = $Change
        SourceKind = $SourceKind
        SearchKey  = $searchKey
    }
}

Export-ModuleMember -Function *-P4Changelist, ConvertTo-ChangelistEntry, ConvertTo-SubmittedChangelistEntry, New-P4FileEntry
