# sitting.ps1 -- drive the Windows app's three scenes in one command, correctly.
#
# WHY THIS EXISTS, AND IT IS NOT CONVENIENCE.
#
# Running the documented lane list and THEN launching the shell fails, and it
# fails for a reason that has nothing to do with the app:
#
#     RUSTFAIL EntryPointNotFoundException:
#       Unable to find an entry point named 'jas_corpus_len' in DLL 'jas_dioxus'
#
# The last lane in that list is `cargo test --no-default-features --features ffi`
# -- NO d2d -- and it rebuilds and OVERWRITES target/debug/jas_dioxus.dll with a
# library that compiles `ffi_paint` out entirely (it is gated
# `all(feature="ffi", feature="d2d", windows)`). Measured 2026-09-03: the
# 7,351,296-byte DLL fails on every scene; rebuilt on the native lane it is
# 7,766,528 bytes and paints 21/21.
#
# => THE LAST LANE TO TOUCH target/ DECIDES WHAT THE SHELL LOADS. So this script
#    rebuilds the cdylib FIRST, every time, and refuses to launch if that fails.
#
# TWO OTHER TRAPS ARE HANDLED HERE RATHER THAN REMEMBERED:
#
#   * -Exe MUST BE ABSOLUTE. verify_window.ps1 launches through a scheduled task
#     in session 1, whose working directory is NOT the caller's -- a relative
#     path resolves against C:\Windows\system32, the app never starts, and the
#     whole run reads as an oracle failure. Resolved to absolute below.
#
#   * THE TITLE MUST CARRY THE VERDICT. verify_window.ps1 matches the title as a
#     SUBSTRING and has no arm that reads RUSTOK/RUSTFAIL, so a bare title passes
#     a window whose title says RUSTFAIL, and passes a capture taken before the
#     app drew anything (its "real desktop pixels" arm measures the whole
#     desktop, where the WALLPAPER supplies every colour it counts). Requiring
#     "| RUSTOK" in the title turns the same oracle into one that asserts the
#     Rust half, at zero code cost. Measured: the blank-canvas run that passed
#     under the bare title returns VERIFY: FAIL, exit 1, under this one.

[CmdletBinding()]
param(
    # The document for the `document` and `selection` scenes. Resolved to an
    # absolute path; the scenes refuse BY NAME rather than defaulting to a
    # built-in, which is the mislabelled-experiment shape they exist to avoid.
    [string]$Svg = "test_fixtures\svg\complex_document.svg",
    [string[]]$Scenes = @('goldens', 'document', 'selection'),
    [int]$Seconds = 12,
    # Skip the cdylib rebuild. Only for someone who has just built it and knows
    # nothing has touched target/ since -- it is the one guard worth keeping.
    [switch]$NoRebuild
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe  = Join-Path $repo 'prototypes\sb_winui\bin\Debug\net10.0-windows10.0.22621.0\win-x64\SbWinUi.exe'
$verify = Join-Path $repo 'prototypes\sb_winui\verify_window.ps1'
$title = 'JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK'

if (-not (Test-Path $exe)) {
    Write-Host "REFUSED: the shell is not built at" -ForegroundColor Red
    Write-Host "  $exe"
    Write-Host "Build it with the REAL SDK -- the dotnet on PATH is runtime-only and"
    Write-Host "shadows it, printing the same error as a machine with no SDK at all:"
    Write-Host "  & `"`$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe`" build prototypes\sb_winui\SbWinUi.csproj"
    exit 4
}

if (-not $NoRebuild) {
    Write-Host "== rebuilding the cdylib on the native lane (see the header) ==" -ForegroundColor Cyan
    Push-Location (Join-Path $repo 'jas_dioxus')
    try {
        & cargo build --no-default-features --features d2d,ffi --lib
        if ($LASTEXITCODE -ne 0) {
            Write-Host "REFUSED: the cdylib did not build. Nothing below would mean anything." -ForegroundColor Red
            exit 5
        }
    } finally { Pop-Location }
    $dll = Join-Path $repo 'jas_dioxus\target\debug\jas_dioxus.dll'
    Write-Host ("  cdylib: {0:N0} bytes, {1}" -f (Get-Item $dll).Length, (Get-Item $dll).LastWriteTime)
}

$svgAbs = $null
if ($Scenes -contains 'document' -or $Scenes -contains 'selection') {
    if (-not [System.IO.Path]::IsPathRooted($Svg)) { $Svg = Join-Path $repo $Svg }
    if (-not (Test-Path $Svg)) {
        Write-Host "REFUSED: no such document -- $Svg" -ForegroundColor Red
        exit 4
    }
    $svgAbs = (Resolve-Path $Svg).Path
}

$env:SB_TOPMOST = '1'   # Windows Terminal ignores -WindowStyle Hidden; without
                        # this the harness photographs its own console.

$passed = 0; $failed = 0; $results = @()
foreach ($scene in $Scenes) {
    Write-Host ""
    Write-Host "== SCENE: $scene ==" -ForegroundColor Cyan
    $env:SB_SCENE = $scene
    if ($scene -eq 'goldens') { Remove-Item env:SB_SVG -ErrorAction SilentlyContinue }
    else { $env:SB_SVG = $svgAbs }

    $out = & powershell -File $verify -Title $title -Exe $exe -Seconds $Seconds 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }

    # The receipt is the window title the app itself wrote -- the one value only
    # a run that actually painted can produce.
    #
    # ⛔ AND IT MUST SURVIVE ITS OWN ABSENCE. A FAILING scene has no RUSTOK line
    # at all, so the obvious `(...).Matches.Groups[1].Value` indexes into a null
    # array and THROWS -- killing the run before the summary prints, on exactly
    # the path where the summary matters most. Found by driving the failure
    # deliberately (a d2d-less cdylib), not by reading the code.
    $m = $out | Select-String -Pattern 'RUSTOK (.+)$' | Select-Object -First 1
    $receipt = if ($m) { $m.Matches[0].Groups[1].Value } else { '(no RUSTOK receipt -- it did not paint)' }
    if ($rc -eq 0) { $passed++; $results += "  PASS  $scene -- $receipt" }
    else           { $failed++; $results += "  FAIL  $scene -- $receipt" }
}

# THE TOTALS MUST CLOSE. Same law as the witness pass's summary: a scene that
# was attempted and landed in neither column is a lost row, and a headline that
# cannot account for every scene it drove must say so rather than imply the rest.
Write-Host ""
Write-Host ("=== SITTING RESULT: {0} passed, {1} failed, of {2} attempted ===" -f `
            $passed, $failed, $Scenes.Count)
$results | ForEach-Object { Write-Host $_ }
if (($passed + $failed) -ne $Scenes.Count) {
    Write-Host "  |X| THE TOTALS DO NOT CLOSE -- this runner lost a scene and its" -ForegroundColor Red
    Write-Host "      own verdict is void. Do not read the line above as a result." -ForegroundColor Red
    exit 3
}
if ($failed -gt 0) { exit 1 }
exit 0
