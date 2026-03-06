Set-StrictMode -Version Latest

function Format-TruncatedDepotPath {
    <#
    .SYNOPSIS
        Left-truncates a depot path to fit within MaxWidth characters.
    .DESCRIPTION
        Returns the path unchanged if it already fits within MaxWidth.
        When truncation is needed the leftmost characters are replaced with the
        ellipsis character U+2026 ('…') so that the rightmost portion — ideally
        including the filename — remains visible.

        Truncation strategy:
          1. If the path fits within MaxWidth, return as-is.
          2. Otherwise build:  '…' + Path[-available..]
             where available = MaxWidth - 1 (for the ellipsis character).
          3. Edge cases: empty path → '';  MaxWidth ≤ 0 → '';
             MaxWidth = 1 → '…'.

        The filename (tail after the last '/') is preserved whenever the
        available space after the ellipsis is large enough to hold it.  If the
        filename itself is longer than available, it is also truncated from the
        left (the rightmost characters are kept).
    .PARAMETER Path
        Depot path to format.  May be empty.
    .PARAMETER MaxWidth
        Maximum number of characters in the returned string.  Must be ≥ 0.
    .EXAMPLE
        Format-TruncatedDepotPath -Path '//depot/main/src/Foo.cs' -MaxWidth 20
        # Returns '…ain/src/Foo.cs' (or similar right-anchored truncation)
    .EXAMPLE
        Format-TruncatedDepotPath -Path '//depot/main/src/Foo.cs' -MaxWidth 100
        # Returns '//depot/main/src/Foo.cs'  (fits, no truncation)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][int]$MaxWidth
    )

    if ($MaxWidth -le 0)               { return '' }
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    if ($Path.Length -le $MaxWidth)    { return $Path }

    $ellipsis  = [string][char]0x2026   # U+2026 '…'
    $available = $MaxWidth - 1          # 1 char reserved for ellipsis

    if ($available -le 0) { return $ellipsis }

    # Take the rightmost $available characters — this preserves the filename
    # whenever it fits within the available budget.
    return $ellipsis + $Path.Substring($Path.Length - $available)
}

Export-ModuleMember -Function Format-TruncatedDepotPath
