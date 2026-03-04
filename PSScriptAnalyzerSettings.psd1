@{
    ExcludeRules = @(
        # Lab cmdlets intentionally mutate Perforce state; ShouldProcess overhead
        # is not warranted for this test-harness context.
        'PSUseShouldProcessForStateChangingFunctions',

        # 'Seed' is domain language for pre-populating depot content.
        # Renaming to an approved verb would obscure intent.
        'PSUseApprovedVerbs',

        # Several cmdlets return collections by design (e.g. Get-LabRawRecords).
        # Forcing singular names would misrepresent the API surface.
        'PSUseSingularNouns',

        # Return types are dynamic (tagged hashtables). Declaring OutputType
        # accurately would require per-branch [OutputType] attributes throughout.
        'PSUseOutputTypeCorrectly',

        # Files are saved UTF-8 without BOM, which is the modern default.
        # BOM causes issues with some tooling.
        'PSUseBOMForUnicodeEncodedFile',

        # PSScriptAnalyzer incorrectly flags Write-Output -NoEnumerate @(...) as
        # mis-usage.  The -NoEnumerate switch is a valid parameter, not missing args.
        'PSUseCmdletCorrectly',

        # This is a TUI renderer.  Writing directly to the console host via
        # Write-Host / [Console]::Write is intentional and required.
        'PSAvoidUsingWriteHost',

        # Pester BeforeAll/BeforeEach scopes are invisible to PSScriptAnalyzer;
        # variables set there appear unread to static analysis.
        'PSUseDeclaredVarsMoreThanAssignments',

        # Internal project; comment-based help on every function would add noise
        # without benefit.
        'PSProvideCommentHelp',

        # The outer catch in Flush-FrameDiff contains a best-effort cleanup try/catch.
        # That inner catch intentionally swallows errors to avoid masking the original
        # exception.  PSScriptAnalyzer treats comment-only catch blocks as empty.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
