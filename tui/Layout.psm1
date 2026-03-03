Set-StrictMode -Version Latest

function Get-BrowserLayout {
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )

    $minWidth = 60
    $minHeight = 16

    if ($Width -lt $minWidth -or $Height -lt $minHeight) {
        return [pscustomobject]@{
            Mode = 'TooSmall'
            MinWidth = $minWidth
            MinHeight = $minHeight
            Width = $Width
            Height = $Height
            StatusPane = [pscustomobject]@{ X = 0; Y = [Math]::Max(0, $Height - 1); W = [Math]::Max(0, $Width); H = 1 }
        }
    }

    $statusH = 1
    $contentH = $Height - $statusH

    $leftW = [Math]::Max(20, [Math]::Floor($Width * 0.3))
    if ($leftW -gt ($Width - 25)) {
        $leftW = [Math]::Max(20, $Width - 25)
    }

    $rightX = $leftW + 1
    $rightW = $Width - $rightX

    $listH = [Math]::Floor($contentH / 2)
    $listH = [Math]::Max(6, $listH)
    $detailY = $listH + 1
    $detailH = $contentH - $detailY
    if ($detailH -lt 4) {
        $detailH = 4
        $listH = $contentH - $detailH - 1
    }

    return [pscustomobject]@{
        Mode = 'Normal'
        Width = $Width
        Height = $Height
        TagPane = [pscustomobject]@{ X = 0; Y = 0; W = $leftW; H = $contentH }
        ListPane = [pscustomobject]@{ X = $rightX; Y = 0; W = $rightW; H = $listH }
        DetailPane = [pscustomobject]@{ X = $rightX; Y = $detailY; W = $rightW; H = $detailH }
        StatusPane = [pscustomobject]@{ X = 0; Y = $contentH; W = $Width; H = 1 }
    }
}

Export-ModuleMember -Function Get-BrowserLayout
