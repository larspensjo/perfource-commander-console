# PerFourceCommanderConsole — Minimal Edits to Get an MVP Running

Target MVP: **launch TUI and browse pending changelists in the current workspace**.

The approach below is intentionally “minimum disruption”:

- **Keep the existing TUI modules** (`browser\*.psm1`) and their reducer/render logic intact for now.
- Add a thin Perforce layer (`p4\*.psm1`) that:
  - calls `p4.exe`
  - parses results
  - **adapts changelists into the “Idea-like” shape** your current UI already renders (`Id`, `Title`, `Tags`, etc.)

This lets you run end-to-end quickly. After MVP works, you can rename “Ideas” → “Changelists” in a second refactor without being blocked.

---

## 1) Create folder structure

Create:

```
p4/
  Models.psm1
  P4Cli.psm1
```

---

## 2) Create `p4\Models.psm1`

Purpose:
- define record shapes for parsed Perforce output
- provide an **adapter** that maps a changelist into the fields the current UI expects

Create file: `p4\Models.psm1`

```powershell
# p4/Models.psm1
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

function ConvertTo-IdeaLikeEntryFromP4Changelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Changelist
    )

    # Minimal adapter: map changelist into the fields your current UI expects.
    # This avoids touching browser/Render.psm1 and browser/Reducer.psm1 for MVP.

    $title = $Changelist.Description
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "(no description)" }

    [pscustomobject]@{
        # UI expects string Id.
        Id        = "CL-$($Changelist.Change)"
        Title     = $title

        # Reuse the tag pane by feeding it useful facets.
        Tags      = @($Changelist.Status, $Changelist.Client, $Changelist.User) |
                    Where-Object { $_ } |
                    Select-Object -Unique

        # Safe defaults if your renderer uses these for colors/badges.
        Priority  = 'P2'
        Risk      = 'M'
        Effort    = 'M'

        # Detail pane fields; pack useful P4 identity here.
        Summary   = $title
        Rationale = "User=$($Changelist.User)  Client=$($Changelist.Client)  Status=$($Changelist.Status)  Time=$($Changelist.Time.ToString('u'))"
        Captured  = $Changelist.Time
    }
}

Export-ModuleMember -Function *-P4Changelist, ConvertTo-IdeaLikeEntryFromP4Changelist
```

---

## 3) Create `p4\P4Cli.psm1`

Goals:
- provide a safe `Invoke-P4` wrapper
- read `p4 info` to infer current user/client
- list pending changelists using `-ztag` so parsing is stable

Create file: `p4\P4Cli.psm1`

```powershell
# p4/P4Cli.psm1
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Models.psm1') -Force

function Invoke-P4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Args
    )

    $exe = 'p4.exe'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.Arguments = ($Args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi

    if (-not $p.Start()) { throw "Failed to start p4.exe" }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
        $msg = @(
            "p4 failed (exit $($p.ExitCode)).",
            "Args: $($psi.Arguments)",
            if ($stderr) { "STDERR: $stderr" },
            if ($stdout) { "STDOUT: $stdout" }
        ) -join "`n"
        throw $msg
    }

    return ($stdout -split "`r?`n") | Where-Object { $_ -ne '' }
}

function Get-P4Info {
    [CmdletBinding()]
    param()

    $lines = Invoke-P4 -Args @('-ztag', 'info')

    $kv = @{}
    foreach ($line in $lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $kv[$Matches.k] = $Matches.v
        }
    }

    [pscustomobject]@{
        User   = $kv.userName
        Client = $kv.clientName
        Port   = $kv.serverAddress
        Root   = $kv.clientRoot
    }
}

function ConvertFrom-P4ZTagRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Lines
    )

    $records = @()
    $current = @{}

    foreach ($line in $Lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $k = $Matches.k
            $v = $Matches.v

            # New record heuristic: same key repeats.
            if ($current.ContainsKey($k)) {
                $records += ,$current
                $current = @{}
            }
            $current[$k] = $v
        }
    }

    if ($current.Count -gt 0) { $records += ,$current }
    return $records
}

function Get-P4PendingChangelists {
    [CmdletBinding()]
    param(
        [int]$Max = 200
    )

    $info = Get-P4Info

    $lines = Invoke-P4 -Args @(
        '-ztag', 'changes',
        '-s', 'pending',
        '-u', $info.User,
        '-c', $info.Client,
        '-m', "$Max"
    )

    $records = ConvertFrom-P4ZTagRecords -Lines $lines

    $result = foreach ($r in $records) {
        $time = [datetime]::UnixEpoch.AddSeconds([double]$r.time).ToLocalTime()

        New-P4Changelist `
            -Change ([int]$r.change) `
            -User $r.user `
            -Client $r.client `
            -Time $time `
            -Status $r.status `
            -Description $r.desc
    }

    $result | Sort-Object Time -Descending
}

function Get-P4PendingChangelistIdeaLikeEntries {
    [CmdletBinding()]
    param(
        [int]$Max = 200
    )

    Get-P4PendingChangelists -Max $Max |
        ForEach-Object { ConvertTo-IdeaLikeEntryFromP4Changelist -Changelist $_ }
}

Export-ModuleMember -Function Invoke-P4, Get-P4Info, Get-P4PendingChangelists, Get-P4PendingChangelistIdeaLikeEntries
```

---

## 4) Minimal edits to `Browse-P4.ps1`

Replace “load ideas from markdown” with “load changelists from Perforce”.

### 4.1 Replace the parameter block

Replace any `IdeasPath` parameter with:

```powershell
param(
    [Parameter(Mandatory = $false)]
    [int]$MaxChanges = 200
)
```

### 4.2 Replace imports

Remove the import of `common\IdeaDocCore.psm1`, and add:

```powershell
Import-Module (Join-Path $PSScriptRoot 'p4\Models.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'p4\P4Cli.psm1') -Force
```

Keep your existing `browser\*.psm1` imports.

### 4.3 Replace IdeaDoc loading with Perforce loading

Replace the block that resolves and reads a markdown file and creates `$doc.Entries` with:

```powershell
$ideas = Get-P4PendingChangelistIdeaLikeEntries -Max $MaxChanges

$width = [Console]::WindowWidth
$height = [Console]::WindowHeight
$state = New-BrowserState -Ideas $ideas -InitialWidth $width -InitialHeight $height
```

That should be enough to render a list of pending changelists **without touching UI code**.

---

## 5) Optional: F5 refresh reloads from Perforce

If you want reload without restarting:

1) In `browser\Input.psm1`, map `F5` to an action:

```powershell
# inside ConvertFrom-KeyInfoToAction
if ($KeyInfo.Key -eq 'F5') { return @{ Type = 'Reload' } }
```

2) In `browser\Reducer.psm1`, add a `'Reload'` case that replaces the list:

```powershell
'Reload' {
    try {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
        $fresh = Get-P4PendingChangelistIdeaLikeEntries -Max 200

        $State.Data.AllIdeas = $fresh
        $State.Data.AllTags = @($fresh | ForEach-Object { $_.Tags } | Where-Object { $_ } | Select-Object -Unique)

        $visibleIds = Get-VisibleIdeaIds -AllIdeas $State.Data.AllIdeas -SelectedTags @($State.Query.SelectedTags)
        $State.Derived.VisibleIdeaIds = @($visibleIds)

        if ($State.Cursor.IdeaIndex -ge $State.Derived.VisibleIdeaIds.Count) {
            $State.Cursor.IdeaIndex = [Math]::Max(0, $State.Derived.VisibleIdeaIds.Count - 1)
        }

        $State.Runtime.LastError = $null
    }
    catch {
        $State.Runtime.LastError = $_.Exception.Message
    }

    return $State
}
```

This is “impure” (does IO inside reducer), but it’s tiny and fine for an MVP. Refactor later to a `ReloadRequested` / `ReloadCompleted` pair.

---

## 6) Run it

From repo root:

```powershell
pwsh .\Browse-P4.ps1
```

If `p4.exe` is configured (ticket/env), you should see a list of items like:

- `CL-123456` with the changelist description
- tags showing `pending`, client, user (in the tag pane)

---

## 7) Next refactor (after MVP)

1) Rename “Ideas” → “Changelists” throughout `browser\*.psm1` and tests.  
2) Replace “tags” with Perforce-native filters (status/user/client/stream/path).  
3) Add details fetch: `p4 describe -s <change>` on selection change and show files/jobs.

---

## 8) Troubleshooting

- `p4.exe not found`: ensure it’s on PATH (or change `$exe` in `Invoke-P4`).
- auth: run `p4 login` in a shell first.
- no pending CLs: verify current client has pending CLs; adjust query to include more.
