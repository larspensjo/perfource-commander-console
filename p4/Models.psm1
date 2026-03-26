Set-StrictMode -Version Latest

function New-P4Changelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Change,
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
        [Parameter(Mandatory = $false)][int]$ShelvedFileCount = 0,
        [Parameter(Mandatory = $false)][int]$UnresolvedFileCount = 0
    )

    $title = ([string]$Changelist.Description -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no description)' }

    [pscustomobject]@{
        Id                   = "$($Changelist.Change)"
        Title                = $title
        HasShelvedFiles      = ($ShelvedFileCount -gt 0)
        HasOpenedFiles       = ($OpenedFileCount -gt 0)
        HasUnresolvedFiles   = [bool]($UnresolvedFileCount -gt 0)
        OpenedFileCount      = $OpenedFileCount
        ShelvedFileCount     = $ShelvedFileCount
        UnresolvedFileCount  = $UnresolvedFileCount
        Captured             = $Changelist.Time
    }
}

function ConvertTo-SubmittedChangelistEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Changelist
    )

    $title = ([string]$Changelist.Description -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
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
        [Parameter(Mandatory = $false)][string]$Action       = '',
        [Parameter(Mandatory = $false)][string]$FileType     = '',
        [Parameter(Mandatory = $false)][string]$Change = '0',
        [Parameter(Mandatory = $false)][string]$SourceKind   = 'Opened',
        [Parameter(Mandatory = $false)][bool]$IsUnresolved   = $false,
        [Parameter(Mandatory = $false)][bool]$IsContentModified = $false
    )

    # Derive FileName: last path segment after the final '/'
    $fileName = if ($DepotPath -match '[^/]+$') { $Matches[0] } else { $DepotPath }

    # Precompute SearchKey once to avoid repeated allocations in the filter hot-path.
    # Includes FileType so future 'type:' facets work without cache invalidation.
    # Appends 'unresolved' token when the file is unresolved so future file-level
    # filtering can match without cache invalidation.
    # Appends 'modified' token when the workspace content differs from depot so
    # future file-level filtering can match without cache invalidation.
    $searchKey = ($DepotPath + ' ' + $Action + ' ' + $FileType).ToLowerInvariant()
    if ($IsUnresolved) { $searchKey = $searchKey + ' unresolved' }
    if ($IsContentModified) { $searchKey = $searchKey + ' modified' }

    [pscustomobject]@{
        DepotPath    = $DepotPath
        FileName     = $fileName
        Action       = $Action
        FileType     = $FileType
        Change       = $Change
        SourceKind   = $SourceKind
        IsUnresolved = $IsUnresolved
        IsContentModified = $IsContentModified
        SearchKey    = $searchKey
    }
}

function Get-IntegrationDirection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$How)
    if ($How -match '\bfrom\b') { return 'inbound' }
    if ($How -match '\binto\b') { return 'outbound' }
    return 'unknown'
}

function New-IntegrationRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$How,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][int]$StartRev,
        [Parameter(Mandatory)][int]$EndRev
    )
    [pscustomobject]@{
        How       = $How
        Direction = Get-IntegrationDirection -How $How
        File      = $File
        StartRev  = $StartRev
        EndRev    = $EndRev
    }
}

function New-RevisionNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DepotFile,
        [Parameter(Mandatory)][int]$Rev,
        [Parameter(Mandatory)][int]$Change,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory = $false)][string]$FileType    = '',
        [Parameter(Mandatory = $false)][int]$Time           = 0,
        [Parameter(Mandatory = $false)][string]$User        = '',
        [Parameter(Mandatory = $false)][string]$Client      = '',
        [Parameter(Mandatory = $false)][string]$Description = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Integrations = @()
    )
    [pscustomobject]@{
        DepotFile    = $DepotFile
        Rev          = $Rev
        Change       = $Change
        Action       = $Action
        FileType     = $FileType
        Time         = $Time
        User         = $User
        Client       = $Client
        Description  = $Description
        Integrations = @($Integrations)
    }
}

Export-ModuleMember -Function *-P4Changelist, ConvertTo-ChangelistEntry, ConvertTo-SubmittedChangelistEntry, New-P4FileEntry, `
    Get-IntegrationDirection, New-IntegrationRecord, New-RevisionNode
