# nightly.ps1 -- O97's unattended Windows UI run: the box preflight, every input
# script through prove_e2e.ps1, every panel through rendered_tree.ps1, and ONE
# receipt.
#
# The run reads GREEN, RED or NOT RUN (Get-SbNightlyVerdict), and the three are
# kept apart because they go to different places: RED to jas's queue, NOT RUN
# reported and paged to no one.
# * NOT RUN: the box was not ready at the start (Get-SbBoxReadiness, with the
#   quiet gate); or it went not ready mid-run, because after ANY failure the box
#   is read again and the run stops there, so a modal that appears at item 40
#   is NOT RUN and not 76 failures; or the run is torn.
# * RED: main does not build, an item is not CERTIFIED, or a panel exits non-zero.
#
# The corpus is read from the repo, never typed here: the scripts are
# test_fixtures/input_scripts/*.json (not *expected*), and the panels are
# workspace/panels/*.yaml's top-level ids.
#
# The tree must be clean, and the receipt names its HEAD. Updating the tree is
# the caller's job; this script never fetches or checks anything out.
#
# Receipt: line 1 is
#   O97-NIGHTLY v1 verdict=<V> head=<sha8> scope=<full|only(x)> date=<iso> minutes=<m> apps-left=<n>
# where <V> is `GREEN items=<c>/<n> panels=<k>/<m>`, `RED(...)` or `NOT RUN(...)`.
# then BOX, and one ITEM or PANEL line per failure. apps-left is a MACHINE READ
# of SbWinUi processes after the run; it should be 0.
#
#   exit 0 GREEN    1 RED    3 NOT RUN
#
#   powershell -File nightly.ps1 -Out <receipt> [-MinIdleSeconds 600] [-Only <substring>]
#
# -Only narrows both lists to names containing <substring>, for a short check of
# the runner itself. Its receipt says scope=only(...), and nothing should
# publish it as the night's.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$MinIdleSeconds = 600,
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$started = Get-Date
$head = "$(& git -C $repo rev-parse HEAD)".Trim()
$scope = if ($Only) { "only($Only)" } else { 'full' }
$lines = New-Object System.Collections.Generic.List[string]

function Complete-Night([string]$Verdict) {
    $left = @(Get-Process -Name (Get-SbProcessName 'SbWinUi.exe') -ErrorAction SilentlyContinue).Count
    $short = if ($head.Length -ge 8) { $head.Substring(0, 8) } else { $head }
    $minutes = [math]::Round($clock.Elapsed.TotalMinutes, 1)
    $text = @("O97-NIGHTLY v1 verdict=$Verdict head=$short scope=$scope date=$($started.ToString('yyyy-MM-ddTHH:mm:ssK')) minutes=$minutes apps-left=$left") + $lines
    $dir = Split-Path -Parent $Out
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Out, (($text -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $text | ForEach-Object { Write-Output $_ }
    if ($Verdict -like 'GREEN*') { exit 0 }
    if ($Verdict -like 'RED*') { exit 1 }
    exit 3
}

# ---- the tree --------------------------------------------------------------
$dirty = @(& git -C $repo status --porcelain).Count
if ($dirty -ne 0) { Complete-Night "NOT RUN(tree: the worktree has $dirty uncommitted path(s))" }

# ---- the box, before anything touches the desktop ---------------------------
$box = Get-SbBoxReadiness (Read-SbBoxSnapshot) -MinIdleSeconds $MinIdleSeconds
$lines.Add("BOX $box")
if ($box -ne 'READY') { Complete-Night $box }

# ---- the corpus, from the repo ---------------------------------------------
$scripts = @(Get-ChildItem (Join-Path $repo 'test_fixtures\input_scripts\*.json') |
    Where-Object { $_.Name -notlike '*expected*' } | Sort-Object Name)
$specs = @(Get-ChildItem (Join-Path $repo 'workspace\panels\*.yaml') | Sort-Object Name)
$panelIds = @(Get-SbPanelIdsFromSpecs @($specs | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }))
if ($panelIds.Count -eq 1 -and "$($panelIds[0])" -like 'REFUSED*') { Complete-Night "NOT RUN(corpus: $($panelIds[0]))" }
if ($Only) {
    $scripts = @($scripts | Where-Object { $_.BaseName -like "*$Only*" })
    $panelIds = @($panelIds | Where-Object { $_ -like "*$Only*" })
}
$lines.Add("CORPUS items=$($scripts.Count) panels=$($panelIds.Count)")

# ---- build once: capture_desktop, then the cdylib lane LAST (the last lane to
# touch target/ decides what the shell loads), then the shell. prove_e2e.ps1
# rebuilds per item, and after this those are no-ops.
$exeDir = Join-Path $PSScriptRoot 'bin'
$buildLog = New-SbBuildLog $exeDir 'sb-nightly-build.txt'
$sdk = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
$crate = Join-Path $repo 'jas_dioxus'
$build = ''
& cmd /c "cd /d `"$crate`" && cargo build --no-default-features --features d2d,ffi --bin capture_desktop > `"$buildLog`" 2>&1"
if ($LASTEXITCODE -ne 0) { $build = "capture_desktop: cargo exit $LASTEXITCODE" }
if (-not $build) {
    & cmd /c "cd /d `"$crate`" && cargo $($SbCdylibLane -join ' ') >> `"$buildLog`" 2>&1"
    if ($LASTEXITCODE -ne 0) { $build = "cdylib: cargo exit $LASTEXITCODE" }
}
if (-not $build) {
    & cmd /c "`"$sdk`" build `"$(Join-Path $PSScriptRoot 'SbWinUi.csproj')`" -nologo >> `"$buildLog`" 2>&1"
    if ($LASTEXITCODE -ne 0) { $build = "shell: dotnet exit $LASTEXITCODE" }
}
if ($build) {
    $lines.Add("BUILD $build (log: $buildLog)")
    Complete-Night (Get-SbNightlyVerdict -Box $box -Build $build -ItemsWanted $scripts.Count -PanelsWanted $panelIds.Count)
}

# After a failure, the box is read again (with no quiet gate: this run's own
# SendInput is the last input). A box that is no longer ready ends the run as
# NOT RUN; one that is still ready leaves the failure standing. The shell's own
# windows are ignored here (jas's LOW on #826): it launches topmost, so a shell
# that outlived its item would otherwise turn that item's RED into NOT RUN.
function Get-SbStopAfter([string]$What) {
    $again = Get-SbBoxReadiness (Read-SbBoxSnapshot) -IgnoreProcess @(Get-SbProcessName 'SbWinUi.exe')
    if ($again -eq 'READY') { return '' }
    return ($again -replace '^NOT RUN\(box: ', "NOT RUN(box went not ready after $What`: ")
}

# CONTINUE from here, not Stop: under 5.1 a child's stderr, redirected by 2>&1,
# arrives as error records, and with Stop the first one would kill the run torn
# with no receipt. Each child is judged by its cert line or its exit code.
$ErrorActionPreference = 'Continue'

# ---- every input script ------------------------------------------------------
$items = New-Object System.Collections.Generic.List[string]
$stop = ''
Push-Location $repo
try {
    foreach ($f in $scripts) {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'prove_e2e.ps1') `
            -Script ('test_fixtures\input_scripts\' + $f.Name) 2>&1
        $cert = "" + (@($o | Where-Object { "$_" -like 'E2E-CERT*' }) | Select-Object -Last 1)
        if ($cert -eq '') { $cert = "E2E-CERT (none) item=$($f.BaseName) verdict=NO CERT LINE" }
        $items.Add($cert)
        if ($cert -cnotmatch ' verdict=CERTIFIED( |$)') {
            $lines.Add("ITEM $cert")
            $stop = Get-SbStopAfter "item $($f.BaseName)"
            if ($stop) { break }
        }
    }
} finally {
    Pop-Location
}

# ---- every panel -------------------------------------------------------------
$panels = @()
if (-not $stop) {
    foreach ($id in $panelIds) {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'rendered_tree.ps1') -Panel $id 2>&1
        $rc = $LASTEXITCODE
        $panels += @{ Panel = $id; Exit = $rc }
        if ($rc -ne 0) {
            $why = @($o | ForEach-Object { "$_" } | Where-Object { $_ -match '^(VERDICT|GAPS|KINDS-VERDICT):' -and $_ -notmatch ': PASS' }) -join ' | '
            $lines.Add("PANEL $id exit=$rc $why")
            $stop = Get-SbStopAfter "panel $id"
            if ($stop) { break }
        }
    }
}

Complete-Night (Get-SbNightlyVerdict -Box $box -Stop $stop -Items $items.ToArray() -ItemsWanted $scripts.Count `
    -Panels $panels -PanelsWanted $panelIds.Count)
