$root = Split-Path $PSScriptRoot -Parent
$files = @(
    'p4/Models.psm1',
    'p4/P4Cli.psm1',
    'tui/GraphReducer.psm1',
    'tui/GraphRender.psm1',
    'tui/Reducer.psm1'
)
foreach ($rel in $files) {
    $path = Join-Path $root $rel
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) {
        Write-Host "ERRORS in $rel" -ForegroundColor Red
        $errs | ForEach-Object { Write-Host "  Line $($_.Extent.StartLineNumber): $_" -ForegroundColor Red }
    } else {
        Write-Host "OK: $rel" -ForegroundColor Green
    }
}
