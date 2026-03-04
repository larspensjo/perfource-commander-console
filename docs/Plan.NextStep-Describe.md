# PerFourceCommanderConsole — Next Step: `p4 describe` Details (On-demand + Cached)

Goal: when you move the cursor in the **Changelists** list (currently labeled **Ideas**), the **Details** pane shows real Perforce details:
- full changelist description (multi-line)
- file list (depot path + action/type if available)
- cached per changelist to avoid re-running `p4 describe` repeatedly

This document assumes your codebase still uses an “Idea-like” entry shape (Id/Title/Tags/etc.) and suggests minimal incremental edits.

---

## Overview of changes

### Files to edit / add

**Add**
- (Optional) `p4\Describe.psm1` (you can also keep everything in `p4\P4Cli.psm1`)

**Edit**
- `p4\P4Cli.psm1` — add `Get-P4Describe` and parsing helpers
- `browser\Reducer.psm1` — detect selection changes; populate a describe cache
- `browser\Render.psm1` — render describe output in Details pane
- `browser\State.psm1` (or where `New-BrowserState` lives) — add cache fields to the state shape
- `browser\Input.psm1` — optional: add F5 reload/clear cache

---

## 1) Data shape for describe output

Use a small explicit object:

```powershell
# Returned by Get-P4Describe
[pscustomobject]@{
  Change      = 26806903
  User        = 'DICE\pensjo'
  Client      = 'DICE\pensjo2_content_dev'
  Status      = 'pending'
  Time        = [datetime]...
  Description = @(
    'First line...',
    'Second line...',
    ...
  )
  Files       = @(
    [pscustomobject]@{ DepotPath='//depot/foo/bar.cpp'; Action='edit'; Type='text' },
    ...
  )
}
```

Keep `Description` as an array of lines to make wrapping/clipping simple.

---

## 2) Implement `Get-P4Describe` in `p4\P4Cli.psm1`

Use `-ztag` for stable parsing.

### 2.1 Add a helper to parse ztag “records”

If you already have a helper like this, reuse it. Otherwise add:

```powershell
function ConvertFrom-P4ZTagGroups {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Lines)

    # Creates a new record when a key repeats.
    $records = @()
    $cur = @{}

    foreach ($line in $Lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $k = $Matches.k
            $v = $Matches.v

            if ($cur.ContainsKey($k)) {
                $records += ,$cur
                $cur = @{}
            }
            $cur[$k] = $v
        }
    }

    if ($cur.Count -gt 0) { $records += ,$cur }
    return $records
}
```

### 2.2 Add `Get-P4Describe`

Append to `p4\P4Cli.psm1`:

```powershell
function Get-P4Describe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Change
    )

    $lines = Invoke-P4 -Args @('-ztag', 'describe', '-s', "$Change")
    $recs  = ConvertFrom-P4ZTagGroups -Lines $lines

    $header = $recs | Where-Object { $_.ContainsKey('change') -and $_.ContainsKey('user') } | Select-Object -First 1
    if (-not $header) { throw "Failed to parse describe header for CL $Change" }

    $time = if ($header.ContainsKey('time')) {
        [datetime]::UnixEpoch.AddSeconds([double]$header.time).ToLocalTime()
    } else { Get-Date }

    $descText  = $header.desc
    $descLines = if ($descText) { $descText -split "`r?`n" } else { @() }

    $files = foreach ($r in $recs) {
        if ($r.ContainsKey('depotFile')) {
            [pscustomobject]@{
                DepotPath = $r.depotFile
                Action    = $r.action
                Type      = $r.type
            }
        }
    }

    [pscustomobject]@{
        Change      = [int]$header.change
        User        = $header.user
        Client      = $header.client
        Status      = $header.status
        Time        = $time
        Description = @($descLines | Where-Object { $_ -ne '' })
        Files       = @($files)
    }
}
```

Export it:

```powershell
Export-ModuleMember -Function Get-P4Describe
```

### 2.3 Manual sanity check

```powershell
Import-Module .\p4\P4Cli.psm1 -Force
(Get-P4Describe -Change 26806903) | Format-List
```

---

## 3) Add a describe cache to browser state

Find `New-BrowserState` and extend it.

Add:
- `State.Data.DescribeCache = @{}` (hashtable: changeNumber -> describe object)
- `State.Runtime.LastSelectedId = $null` (track selection changes)

Example shape:

```powershell
Data = [pscustomobject]@{
  AllIdeas      = @($Ideas)
  AllTags       = @(...)
  DescribeCache = @{}
}

Runtime = [pscustomobject]@{
  LastError      = $null
  LastSelectedId = $null
}
```

---

## 4) Wire selection changes -> fetch describe in `browser\Reducer.psm1`

### 4.1 Parse CL number from the current `Id`

Add helper:

```powershell
function TryGet-ChangeNumberFromIdeaId {
    param([string]$Id)
    if ($Id -match '^CL-(\d+)$') { return [int]$Matches[1] }
    return $null
}
```

### 4.2 Add a post-reduce hook: `Update-DescribeForSelection`

```powershell
function Update-DescribeForSelection {
    param($State)

    if (-not $State.Derived.VisibleIdeaIds -or $State.Derived.VisibleIdeaIds.Count -eq 0) {
        $State.Runtime.LastSelectedId = $null
        return $State
    }

    $idx = $State.Cursor.IdeaIndex
    $idx = [Math]::Max(0, [Math]::Min($idx, $State.Derived.VisibleIdeaIds.Count - 1))
    $selId = $State.Derived.VisibleIdeaIds[$idx]

    if ($State.Runtime.LastSelectedId -eq $selId) { return $State }
    $State.Runtime.LastSelectedId = $selId

    $change = TryGet-ChangeNumberFromIdeaId -Id $selId
    if (-not $change) { return $State }

    if (-not $State.Data.DescribeCache.ContainsKey($change)) {
        try {
            Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
            $State.Data.DescribeCache[$change] = Get-P4Describe -Change $change
            $State.Runtime.LastError = $null
        } catch {
            $State.Runtime.LastError = $_.Exception.Message
        }
    }

    return $State
}
```

### 4.3 Ensure it is called after every reduce

At the bottom of your reducer entry point (often `Invoke-BrowserReducer`), do:

```powershell
$State = Update-DescribeForSelection -State $State
return $State
```

This will automatically fetch describe when:
- cursor moves
- tags/filters change visibility (selection changes)
- list reload happens

---

## 5) Render describe output in `browser\Render.psm1`

Replace the Details body (currently Summary/Rationale) with:

1) Header: `CL`, `Status`, `User`, `Client`, `Time`
2) Blank line
3) Description lines
4) Blank line
5) Files list

### 5.1 Find selected item and cache entry

In the details render function:

```powershell
$selId = $State.Derived.VisibleIdeaIds[$State.Cursor.IdeaIndex]
$change = TryGet-ChangeNumberFromIdeaId $selId
$desc = $null
if ($change -and $State.Data.DescribeCache.ContainsKey($change)) {
    $desc = $State.Data.DescribeCache[$change]
}
```

### 5.2 Render rules

- If `$State.Runtime.LastError` is set, show it at the top of the details pane.
- If `$desc` is `$null`, show “Loading...” (selection changed but not cached yet).
- Clip to pane height; long lists can scroll later.

Suggested file line formatting:

```
edit  //depot/path/file.cpp
add   //depot/path/new.txt
```

---

## 6) Optional: F5 reload clears cache

If you already have reload (or add it), clear describe cache too:

```powershell
$State.Data.DescribeCache = @{}
$State.Runtime.LastSelectedId = $null
```

---

## 7) Smoke-test checklist

1) Start app: list is populated (already).
2) Move selection: details updates with multi-line description + files.
3) Move back to a previously visited CL: details renders instantly (cache hit).
4) Break auth (expired ticket): details shows error message; UI remains responsive.

---

## 8) Next increment after this

Once `describe` works:
- Make the files block scrollable within Details (or split a Files pane)
- Add a first advanced command (command palette): `Shelve`, `Unshelve`, `Submit`, `Diff`
