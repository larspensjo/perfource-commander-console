$modulePath = Join-Path $PSScriptRoot '..\tui\Helpers.psm1'
Import-Module $modulePath -Force

Describe 'Format-TruncatedDepotPath' {

    It 'returns empty string for empty path' {
        Format-TruncatedDepotPath -Path '' -MaxWidth 20 | Should -Be ''
    }

    It 'returns empty string when MaxWidth is 0' {
        Format-TruncatedDepotPath -Path '//depot/main/Foo.cs' -MaxWidth 0 | Should -Be ''
    }

    It 'returns empty string when MaxWidth is negative' {
        Format-TruncatedDepotPath -Path '//depot/main/Foo.cs' -MaxWidth -5 | Should -Be ''
    }

    It 'returns path unchanged when it fits within MaxWidth' {
        $path   = '//depot/main/src/Foo.cs'
        $result = Format-TruncatedDepotPath -Path $path -MaxWidth 100
        $result | Should -Be $path
    }

    It 'returns path unchanged when length equals MaxWidth exactly' {
        $path   = '//depot/main/Foo.cs'        # 18 chars
        $result = Format-TruncatedDepotPath -Path $path -MaxWidth $path.Length
        $result | Should -Be $path
    }

    It 'left-truncates with ellipsis when path exceeds MaxWidth' {
        $path   = '//depot/main/src/MyProject/Foo.cs'
        $result = Format-TruncatedDepotPath -Path $path -MaxWidth 20
        $result.Length | Should -Be 20
        $result | Should -BeLike '*Foo.cs'
        $result[0] | Should -Be ([char]0x2026)   # ellipsis '…'
    }

    It 'preserves filename when budget is large enough' {
        $path     = '//depot/main/src/MyProject/LongDirectoryName/Foo.cs'
        $maxWidth = 20
        $result   = Format-TruncatedDepotPath -Path $path -MaxWidth $maxWidth
        $result.Length | Should -Be $maxWidth
        $result | Should -BeLike '*Foo.cs'
    }

    It 'returns ellipsis-only string when MaxWidth is 1' {
        $result = Format-TruncatedDepotPath -Path '//depot/main/Foo.cs' -MaxWidth 1
        $result | Should -Be ([string][char]0x2026)
        $result.Length | Should -Be 1
    }

    It 'returns ellipsis plus one char when MaxWidth is 2' {
        $path   = '//depot/main/Foo.cs'
        $result = Format-TruncatedDepotPath -Path $path -MaxWidth 2
        $result.Length | Should -Be 2
        $result[0] | Should -Be ([char]0x2026)
    }

    It 'returned string never exceeds MaxWidth' {
        $path = '//depot/very/long/path/to/some/deeply/nested/file/in/the/depot.cs'
        foreach ($width in 1, 2, 5, 10, 20, 50, 100) {
            $result = Format-TruncatedDepotPath -Path $path -MaxWidth $width
            $result.Length | Should -BeLessOrEqual $width
        }
    }
}
