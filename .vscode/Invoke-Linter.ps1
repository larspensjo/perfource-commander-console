# Runs PSScriptAnalyzer on src/ and emits output in a format VS Code's
# problem matcher can parse into the Problems panel.
#
# Format: file(line,col): severity rulename: message

$srcPath      = Join-Path $PSScriptRoot '..'
$settingsFile = Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1'
$files = Get-ChildItem -Path $srcPath -Recurse -Include '*.ps1', '*.psd1', '*.psm1'

foreach ($file in $files) {
    $results = Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsFile -ErrorAction SilentlyContinue
    foreach ($r in $results) {
        $severity = $r.Severity.ToString().ToLower()
        "$($r.ScriptPath)($($r.Line),$($r.Column)): $severity $($r.RuleName): $($r.Message)"
    }
}

exit 0
