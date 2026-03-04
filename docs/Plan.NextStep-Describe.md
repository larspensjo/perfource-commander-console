# PerFourceCommanderConsole — Next Step: `p4 describe` Details (On-demand + Cached)

Goal: when you press **Enter** (or **D**) on a changelist in the **Changelists** pane, the **Details** pane shows real Perforce details:
- full changelist description (multi-line)
- file list (depot path + action/type if available)
- cached per changelist so subsequent views are instant

This document assumes the codebase uses an "Idea-like" entry shape (Id/Title/Tags/etc.) and makes minimal incremental edits.

### Design principles applied

- **Unidirectional data flow** — I/O lives outside the reducer; the reducer stays pure.
- **Correctness by Construction** — the ztag parser handles the real indexed-key format emitted by `p4 -ztag describe`.
- **Unit tests lock-in functionality** — every new function gets Pester tests.

---

## Overview of changes

### Files to edit

| File | Change |
|------|--------|
| `p4\P4Cli.psm1` | Add `Get-P4Describe` with indexed-key parser |
| `tui\Reducer.psm1` | Add `DescribeCache` + `LastSelectedId` to state; add `Describe` action type; update `Copy-BrowserState` |
| `tui\Render.psm1` | Render describe output in the Details pane |
| `tui\Input.psm1` | Map **Enter** / **D** to `Describe` action; F5 clears cache |
| `PerfourceCommanderConsole.psm1` | Fetch describe in main loop (after reduce, before render) |
| `tests\P4Cli.Tests.ps1` | New: tests for `Get-P4Describe` parsing |
| `tests\Reducer.Tests.ps1` | Add tests for Describe action + cache + Copy-BrowserState |

---

## 1) Data shape for describe output

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
    'Second line...'
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

### 2.1 Understand the actual `-ztag describe` output

`p4 -ztag describe -s <CL>` emits a **single flat record** with indexed keys — not multiple records:

```
... change 26806903
... user DICE\pensjo
... client DICE\pensjo2_content_dev
... status pending
... time 1740000000
... desc First line of description.
Second line...
... depotFile0 //depot/foo/bar.cpp
... action0 edit
... type0 text
... depotFile1 //depot/foo/new.txt
... action1 add
... type1 text
```

The existing `ConvertFrom-P4ZTagRecords` (which splits when a key repeats) would break this format because `depotFile0` and `depotFile1` are different keys. A dedicated parser is needed.

### 2.2 Add `Get-P4Describe`

Reuse `Invoke-P4` (with `-P4Args`) and parse the single flat record, extracting indexed file entries:

```powershell
function Get-P4Describe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Change
    )

    $lines = Invoke-P4 -P4Args @('-ztag', 'describe', '-s', "$Change")

    # Parse all ztag key-value pairs into a single flat hashtable.
    $kv = @{}
    foreach ($line in $lines) {
        if ($line -match '^\.\.\.\s+(?<k>\S+)\s+(?<v>.*)$') {
            $kv[$Matches.k] = $Matches.v
        }
    }

    if (-not $kv.ContainsKey('change')) {
        throw "Failed to parse describe output for CL $Change"
    }

    $time = if ($kv.ContainsKey('time')) {
        [datetime]::UnixEpoch.AddSeconds([double]$kv.time).ToLocalTime()
    } else { Get-Date }

    $descText  = if ($kv.ContainsKey('desc')) { $kv.desc } else { '' }
    $descLines = if ($descText) { $descText -split "`r?`n" } else { @() }

    # Extract indexed file entries: depotFile0/action0/type0, depotFile1/action1/type1, ...
    $files = @()
    for ($i = 0; ; $i++) {
        $depotKey = "depotFile$i"
        if (-not $kv.ContainsKey($depotKey)) { break }
        $files += [pscustomobject]@{
            DepotPath = [string]$kv[$depotKey]
            Action    = if ($kv.ContainsKey("action$i")) { [string]$kv["action$i"] } else { '' }
            Type      = if ($kv.ContainsKey("type$i"))   { [string]$kv["type$i"]   } else { '' }
        }
    }

    [pscustomobject]@{
        Change      = [int]$kv.change
        User        = [string]$kv.user
        Client      = [string]$kv.client
        Status      = [string]$kv.status
        Time        = $time
        Description = @($descLines | Where-Object { $_ -ne '' })
        Files       = @($files)
    }
}
```

Export it:

```powershell
Export-ModuleMember -Function ..., Get-P4Describe
```

### 2.3 Manual sanity check

```powershell
Import-Module .\p4\P4Cli.psm1 -Force
(Get-P4Describe -Change 26806903) | Format-List
```

---

## 3) Add describe cache and tracking to browser state

Edit `New-BrowserState` in `tui\Reducer.psm1`.

Add:
- `State.Data.DescribeCache = @{}` — hashtable: change number (int) -> describe object
- `State.Runtime.LastSelectedId = $null` — tracks which CL the details pane shows

```powershell
Data = [pscustomobject]@{
  AllIdeas      = @($Ideas)
  AllTags       = @(...)
  DescribeCache = @{}
}

Runtime = [pscustomobject]@{
  IsRunning       = $true
  LastError       = $null
  LastSelectedId  = $null
}
```

### 3.1 Update `Copy-BrowserState`

The cache is append-only, so share it by reference. `LastSelectedId` must be copied explicitly:

```powershell
Data = [pscustomobject]@{
    AllIdeas      = @($State.Data.AllIdeas)
    AllTags       = @($State.Data.AllTags)
    DescribeCache = $State.Data.DescribeCache          # shared reference (append-only)
}

Runtime = [pscustomobject]@{
    IsRunning       = $State.Runtime.IsRunning
    LastError       = $State.Runtime.LastError
    LastSelectedId  = $State.Runtime.LastSelectedId     # new field
}
```

---

## 4) Add `Describe` action and keep the reducer pure

### 4.1 Map keys in `tui\Input.psm1`

Add to `ConvertFrom-KeyInfoToAction`:

```powershell
'Enter' { return [pscustomobject]@{ Type = 'Describe' } }
'D'     { return [pscustomobject]@{ Type = 'Describe' } }
```

### 4.2 Handle `Describe` action in `Invoke-BrowserReducer`

The reducer only records _which_ CL the user wants to view — no I/O:

```powershell
'Describe' {
    if ($next.Derived.VisibleIdeaIds.Count -eq 0) { return $next }
    $idx = [Math]::Max(0, [Math]::Min($next.Cursor.IdeaIndex,
                                       $next.Derived.VisibleIdeaIds.Count - 1))
    $next.Runtime.LastSelectedId = $next.Derived.VisibleIdeaIds[$idx]
    return Update-BrowserDerivedState -State $next
}
```

### 4.3 Parse CL number helper (in `tui\Reducer.psm1`)

```powershell
function ConvertTo-ChangeNumberFromIdeaId {
    param([string]$Id)
    if ($Id -match '^CL-(\d+)$') { return [int]$Matches[1] }
    return $null
}
```

### 4.4 Fetch describe in the main loop (not in the reducer)

In `PerfourceCommanderConsole.psm1`, **after** reduce but **before** render — this keeps the reducer pure and I/O explicit:

```powershell
# After: $state = Invoke-BrowserReducer -State $state -Action $action
# Before: Render-BrowserState -State $state

if ($null -ne $state.Runtime.LastSelectedId) {
    $change = ConvertTo-ChangeNumberFromIdeaId -Id $state.Runtime.LastSelectedId
    if ($null -ne $change -and -not $state.Data.DescribeCache.ContainsKey($change)) {
        try {
            $state.Data.DescribeCache[$change] = Get-P4Describe -Change $change
            $state.Runtime.LastError = $null
        } catch {
            $state.Runtime.LastError = $_.Exception.Message
        }
    }
}
```

**Why the main loop and not the reducer?**
- The reducer is a pure function: state + action -> new state.
- `Get-P4Describe` calls `p4.exe` (network I/O). Mixing I/O into the reducer makes it untestable and breaks the UDDF contract.
- Fetching on an explicit user action (Enter/D) avoids flooding the server when the user holds an arrow key.

---

## 5) Render describe output in `tui\Render.psm1`

Replace the body of `Build-DetailSegments` with real describe output.

### 5.1 Find the cache entry

```powershell
$desc = $null
if ($null -ne $State.Runtime.LastSelectedId) {
    $change = ConvertTo-ChangeNumberFromIdeaId -Id $State.Runtime.LastSelectedId
    if ($null -ne $change -and $State.Data.DescribeCache.ContainsKey($change)) {
        $desc = $State.Data.DescribeCache[$change]
    }
}
```

### 5.2 Render rules

- If `$State.Runtime.LastError` is set, show the error at the top of the pane.
- If `$desc` is `$null`, show the existing Idea summary (no describe fetched yet).
- If `$desc` is present, show:
  1. Header: `CL <number>  <status>  <user>  <client>`
  2. Time line
  3. Blank line
  4. Description lines
  5. Blank line
  6. Files list formatted as: `edit  //depot/path/file.cpp`
- Clip to pane height; long lists can scroll in a future increment.

---

## 6) F5 reload clears cache

In the existing `Reload` case of `Invoke-BrowserReducer`, add:

```powershell
$next.Data.DescribeCache = @{}
$next.Runtime.LastSelectedId = $null
```

---

## 7) Unit tests

### 7.1 `tests\P4Cli.Tests.ps1` (new file)

Test `Get-P4Describe` by mocking `Invoke-P4` to return sample `-ztag` output:

```powershell
Describe 'Get-P4Describe' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\p4\P4Cli.psm1') -Force
    }

    It 'parses a describe record with indexed file keys' {
        Mock Invoke-P4 {
            return @(
                '... change 12345',
                '... user testuser',
                '... client testclient',
                '... status pending',
                '... time 1700000000',
                '... desc Line one',
                '... depotFile0 //depot/a.txt',
                '... action0 edit',
                '... type0 text',
                '... depotFile1 //depot/b.txt',
                '... action1 add',
                '... type1 binary'
            )
        }
        $result = Get-P4Describe -Change 12345
        $result.Change | Should -Be 12345
        $result.Files.Count | Should -Be 2
        $result.Files[0].DepotPath | Should -Be '//depot/a.txt'
        $result.Files[1].Action | Should -Be 'add'
    }

    It 'throws when describe output has no change key' {
        Mock Invoke-P4 { return @('... user someone') }
        { Get-P4Describe -Change 99999 } | Should -Throw '*Failed to parse*'
    }
}
```

### 7.2 `tests\Reducer.Tests.ps1` (additions)

- Test that `Describe` action sets `LastSelectedId`.
- Test that `Copy-BrowserState` preserves `DescribeCache` and `LastSelectedId`.
- Test that `Reload` clears the cache.

### 7.3 `ConvertTo-ChangeNumberFromIdeaId` tests

```powershell
It 'extracts change number from CL-prefixed id' {
    ConvertTo-ChangeNumberFromIdeaId -Id 'CL-12345' | Should -Be 12345
}
It 'returns null for non-CL id' {
    ConvertTo-ChangeNumberFromIdeaId -Id 'FI-001' | Should -BeNullOrEmpty
}
```

---

## 8) Smoke-test checklist

1. Start app — list is populated (existing behavior).
2. Press Enter on an item — details pane updates with description + files.
3. Move cursor away and back, press Enter again — details render instantly (cache hit).
4. Press F5 — cache is cleared; next Enter re-fetches.
5. Break auth (expired ticket) — details shows error message; UI remains responsive.

---

## 9) Next increment after this

Once `describe` works:
- Make the files block scrollable within the Details pane (or split into a dedicated Files pane)
- Add a command palette: `Shelve`, `Unshelve`, `Submit`, `Diff`
