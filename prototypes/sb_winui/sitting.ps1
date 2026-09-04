# sitting.ps1 -- drive the Windows app's scenes in one command, correctly, and
# hold one instance open when a person needs to look at it.
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
#     app drew anything. Requiring "| RUSTOK" in the title turns the same oracle
#     into one that asserts the Rust half, at zero code cost.
#
# ---------------------------------------------------------------------------
# F-2: RUN AND STAY, PID-SCOPED THROUGHOUT
# ---------------------------------------------------------------------------
#
#   sitting.ps1 -Stay [-Scene stay] [-Svg <path>]
#       registers `jas-sb-app-stay`, launches, waits -- BOUNDED, with a named
#       refusal on timeout -- for the app's OWN `STAY pid=<n>` row, prints the
#       PID, and DOES NOT KILL.
#
#   sitting.ps1 -Stop <pid>
#       kills BY PID ONLY, REFUSES if that PID is not an SbWinUi, and drops the
#       task.
#
# ⛔ `-Stay` WHILE A RECORDED STAY PID IS ALIVE REFUSES BY NAME (O5). Two stays
# are two windows with one record file, and the second `-Stop` would then be
# aimed at a pid nobody is holding. A second instance is available deliberately
# (`-Stay -Force`), never by accident.

[CmdletBinding()]
param(
    # The document for every scene that opens one. Resolved to an absolute
    # path; the scenes refuse BY NAME rather than defaulting to a built-in,
    # which is the mislabelled-experiment shape they exist to avoid.
    #
    # `complex_document.svg` is also the CALIBRATED fixture the `retained`
    # scene pins by name: O1 compares hashes with no tolerance, and an
    # uncalibrated document is refused as `NOT RUN`, never hashed anyway.
    [string]$Svg = "test_fixtures\svg\complex_document.svg",
    # ⛔ `selection` IS GONE FROM THE DEFAULT LIST, AND THAT IS THE RENAME'S
    # CONSEQUENCE, NOT A REDUCTION IN SCOPE. It is now `selection-marquee` and
    # the shell REFUSES the old spelling by name, so leaving it here would have
    # made every default sitting red on a scene that no longer exists. The
    # marquee is a CONTROL -- a synthetic gesture that moves nothing and selects
    # N -- and the freeze says it does not belong in the default list; run it
    # deliberately with `-Scenes selection-marquee`.
    #
    # ⛔ `stay` IS NOT HERE EITHER, and for the opposite reason: it does not
    # complete and does not exit. A sitting that included it would hang on it
    # forever. It has its own switch (`-Stay`) because it is a different verb.
    [string[]]$Scenes = @('benchmark', 'document', 'retained', 'stall', 'pointer', 'goldens'),
    [int]$Seconds = 12,
    # Skip the cdylib rebuild. Only for someone who has just built it and knows
    # nothing has touched target/ since -- it is the one guard worth keeping.
    [switch]$NoRebuild,

    # ---- F-2 -------------------------------------------------------------
    [switch]$Stay,
    [string]$Scene = 'stay',
    [int]$Stop = 0,
    [switch]$Force,

    # Resolve every knob and print the plan; launch nothing.
    [Alias('WhatIf')][switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe  = Join-Path $repo 'prototypes\sb_winui\bin\Debug\net10.0-windows10.0.22621.0\win-x64\SbWinUi.exe'
$verify = Join-Path $repo 'prototypes\sb_winui\verify_window.ps1'
$title = 'JAS S-B MATERIALIZER CHECKPOINT 3 | RUSTOK'
$stayTask = 'jas-sb-app-stay'

if (-not (Test-Path $exe)) {
    Write-Host "REFUSED: the shell is not built at" -ForegroundColor Red
    Write-Host "  $exe"
    Write-Host "Build it with the REAL SDK -- the dotnet on PATH is runtime-only and"
    Write-Host "shadows it, printing the same error as a machine with no SDK at all:"
    Write-Host "  & `"`$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe`" build prototypes\sb_winui\SbWinUi.csproj"
    exit 4
}
$exe = Resolve-SbExe $exe
$scratch = Split-Path $exe -Parent
$stayRecord = Join-Path $scratch 'sb-stay.pid'
$log = Get-SbLogPath $exe
$procName = Get-SbProcessName $exe

# ===========================================================================
# -Stop <pid> -- BY PID ONLY
# ===========================================================================
if ($Stop -gt 0) {
    $r = Stop-SbAppByPid -TargetPid $Stop -ExpectName $procName
    Write-Host "  $($r.Verdict)"
    Remove-SbTask $stayTask
    Write-Host "  ok  : scheduled task '$stayTask' dropped"
    if (Test-Path $stayRecord) {
        $recorded = (Get-Content $stayRecord -Raw).Trim()
        if ($recorded -eq [string]$Stop) {
            Remove-Item $stayRecord -ErrorAction SilentlyContinue
            Write-Host "  ok  : the stay record named pid $Stop and is cleared"
        } else {
            # ⛔ NOT CLEARED. The record names a DIFFERENT pid, and deleting it
            # here would orphan whatever it names -- a live window nothing can
            # find again. Reported instead of tidied.
            Write-Host "  note: the stay record names pid $recorded, not $Stop -- LEFT IN PLACE" -ForegroundColor Yellow
        }
    }
    if ($r.Ok) { exit 0 }
    exit 1
}

# ===========================================================================
# The cdylib, first, every time (see the header)
# ===========================================================================
if (-not $NoRebuild -and -not $DryRun) {
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

# ===========================================================================
# The document
# ===========================================================================
$svgAbs = $null
$svgScenes = @('document', 'selection-marquee', 'retained', 'pointer', 'stall', 'stay')
$needsSvg = ($Stay -and ($svgScenes -contains $Scene)) -or
            (@($Scenes | Where-Object { $svgScenes -contains $_ }).Count -gt 0)
if ($needsSvg) {
    if (-not [System.IO.Path]::IsPathRooted($Svg)) { $Svg = Join-Path $repo $Svg }
    if (-not (Test-Path $Svg)) {
        Write-Host "REFUSED: no such document -- $Svg" -ForegroundColor Red
        exit 4
    }
    $svgAbs = (Resolve-Path $Svg).Path
}

$env:SB_TOPMOST = '1'   # Windows Terminal ignores -WindowStyle Hidden; without
                        # this the harness photographs its own console.

# ===========================================================================
# -Stay -- launch and HOLD, PID-scoped
# ===========================================================================
if ($Stay) {
    # ⛔ THE REFUSAL COMES FIRST, AND IT IS O5's OWN CLAUSE. A recorded stay pid
    # that is STILL ALIVE means someone is holding a window; a second -Stay would
    # overwrite the record and orphan it.
    if ((Test-Path $stayRecord) -and -not $Force) {
        $recorded = (Get-Content $stayRecord -Raw).Trim()
        $n = 0
        if ([int]::TryParse($recorded, [ref]$n)) {
            $alive = Get-Process -Id $n -ErrorAction SilentlyContinue
            if ($null -ne $alive -and $alive.ProcessName -eq $procName) {
                Write-Host "REFUSED: a stay instance is already up -- pid $n ($procName), Responding=$($alive.Responding)." -ForegroundColor Red
                Write-Host "         Stop it first:  sitting.ps1 -Stop $n"
                Write-Host "         A second stay would overwrite the record and orphan that window."
                Write-Host "         Deliberate second instance: -Stay -Force"
                exit 6
            }
            # The record names a dead pid: stale, and saying so is cheaper than
            # letting the next reader wonder which of the two facts is true.
            Write-Host "  note: the stay record named pid $n, which is no longer running; replacing it"
        }
    }

    $env:SB_SCENE = $Scene
    if ($Scene -eq 'goldens' -or $null -eq $svgAbs) { Remove-Item env:SB_SVG -ErrorAction SilentlyContinue }
    else { $env:SB_SVG = $svgAbs }

    $fwd = Get-SbForwardedEnv
    $known = Get-SbAppPids $exe
    $logMark = Get-SbLogMark $log

    if ($DryRun) {
        Write-Host "== DRY RUN -- -Stay plan, nothing launched =="
        Write-Host "  exe          : $exe"
        Write-Host "  scene        : $Scene"
        Write-Host "  svg          : $(if ($svgAbs) { $svgAbs } else { '(none)' })"
        Write-Host "  task         : $stayTask"
        Write-Host "  waits for    : the app's own `"RUSTOK STAY pid=<n>`" row in $([IO.Path]::GetFileName($log))"
        Write-Host "  timeout      : 90s, then a named refusal"
        Write-Host "  record       : $stayRecord"
        Write-Host "  already up   : $(($known -join ', '))"
        Write-Host "  forwarded    : $(if ($fwd.Names.Count) { $fwd.Names -join ' ' } else { '(none)' })"
        Write-Host "  teardown     : NONE. -Stay does not kill; use -Stop <pid>."
        exit 0
    }

    Remove-SbTask $stayTask
    New-SbLaunchTask -TaskName $stayTask -Exe $exe -EnvPrefix $fwd.Prefix
    $start = Start-SbAppTask -TaskName $stayTask -Exe $exe -Known $known -TimeoutSeconds 60
    if ($start.Pid -le 0) {
        Write-Host "  $($start.Refusal)" -ForegroundColor Red
        Remove-SbTask $stayTask
        exit 1
    }

    # ⛔ THE ROW IS THE ORACLE, NOT THE PROCESS. A process exists the moment the
    # task starts it; the `STAY pid=` row exists only once the scene has loaded,
    # painted and decided to hold. Waiting on the row is what makes the printed
    # pid a pid of a window somebody can look at, and the wait is BOUNDED with a
    # refusal that says which of the two happened.
    $wait = Wait-SbRow -Log $log -Mark $logMark -Patterns @('RUSTOK STAY pid=') -TimeoutSeconds 90
    if ($null -eq $wait.Row) {
        Write-Host "  NOT RUN: timed out after $($wait.Waited)s waiting for the app's own STAY pid= row." -ForegroundColor Red
        Write-Host "           Process $($start.Pid) IS running; it just never reported the stay scene."
        Write-Host "           Left alive deliberately -- stop it with:  sitting.ps1 -Stop $($start.Pid)"
        "$($start.Pid)" | Set-Content -Path $stayRecord -Encoding utf8
        exit 2
    }

    $rowPid = Get-SbField $wait.Row 'pid'
    if ($rowPid -ne [string]$start.Pid) {
        # TWO INDEPENDENT IDENTIFICATIONS THAT DISAGREE. Reported, never
        # reconciled by picking one: a stay whose pid is in doubt cannot be
        # stopped by pid, which is the only way this harness stops anything.
        Write-Host "  REFUSED: the app reports pid=$rowPid and this harness launched pid $($start.Pid)." -ForegroundColor Red
        Write-Host "           Two identifications, one process, and they disagree. Not recording either."
        exit 3
    }

    "$rowPid" | Set-Content -Path $stayRecord -Encoding utf8
    Write-Host ""
    Write-Host "STAY pid=$rowPid  (scene '$Scene', after $($wait.Waited)s)" -ForegroundColor Green
    Write-Host "  row   : $($wait.Row)"
    Write-Host "  record: $stayRecord"
    Write-Host "  ⛔ NOT killed. Stop it with:  sitting.ps1 -Stop $rowPid"
    Write-Host "  (verify_window.ps1 runs beside it are PID-scoped and leave it alive.)"
    exit 0
}

# ===========================================================================
# The sitting: one RUN per row, and a run is not the same thing as a scene
# ===========================================================================
#
# ⛔ THE UNIT IS THE RUN. `pointer` appears twice -- once with the session-1 hand
# and once with SB_SYNTH_DRAG -- because O4's control is the SAME oracle read
# through the other provenance, and a summary that counted scenes would report
# "6 of 6" over seven runs. k is VARIED between the two hand runs (2, then 7)
# because a control that cannot follow a varied k is weaker than the hand it
# stands in for.
$runPlan = @{
    'benchmark' = @(
        @{ Name = 'benchmark'; Scene = 'benchmark'; Env = @{}; Args = @() }
    )
    'document' = @(
        @{ Name = 'document (O1''s golden control)'; Scene = 'document'; Env = @{}; Args = @() }
    )
    'retained' = @(
        @{ Name = 'retained (hand, k=2)'; Scene = 'retained';
           Env = @{ SB_RESIZE = '1000x600,original' };
           Args = @('-Hand', '-HandMoves', '2') }
    )
    'stall' = @(
        @{ Name = 'stall (render stall 20s)'; Scene = 'stall';
           Env = @{ SB_RENDER_STALL_MS = '20000'; SB_RESIZE = '1000x600' };
           Args = @() }
    )
    'pointer' = @(
        @{ Name = 'pointer (hand, k=7)'; Scene = 'pointer'; Env = @{}; Args = @('-Hand', '-HandMoves', '7') },
        @{ Name = 'pointer (SB_SYNTH_DRAG control, k=7)'; Scene = 'pointer'; Env = @{};
           Args = @('-SynthFromDump', '-HandMoves', '7') }
    )
    'goldens' = @(
        @{ Name = 'goldens'; Scene = 'goldens'; Env = @{}; Args = @() }
    )
    'selection-marquee' = @(
        @{ Name = 'selection-marquee (control only)'; Scene = 'selection-marquee'; Env = @{}; Args = @() }
    )
}

$runs = @()
foreach ($s in $Scenes) {
    if ($runPlan.ContainsKey($s)) { $runs += $runPlan[$s] }
    else { $runs += @{ Name = $s; Scene = $s; Env = @{}; Args = @() } }
}

if ($DryRun) {
    Write-Host "== DRY RUN -- sitting plan, nothing launched =="
    Write-Host "  exe    : $exe"
    Write-Host "  svg    : $(if ($svgAbs) { $svgAbs } else { '(none)' })"
    Write-Host "  runs   : $($runs.Count) across $($Scenes.Count) scene(s)"
    foreach ($r in $runs) {
        $kv = @($r.Env.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        Write-Host ("   - {0,-40} scene={1,-18} env={2,-40} args={3}" -f
            $r.Name, $r.Scene, $(if ($kv.Count) { $kv -join ' ' } else { '(none)' }), $($r.Args -join ' '))
    }
    Write-Host "  Each run then dry-runs verify_window.ps1 for its own resolved plan:"
    foreach ($r in $runs) {
        Write-Host ""
        Write-Host "   == $($r.Name) ==" -ForegroundColor Cyan
        $env:SB_SCENE = $r.Scene
        if ($r.Scene -eq 'goldens') { Remove-Item env:SB_SVG -ErrorAction SilentlyContinue }
        else { $env:SB_SVG = $svgAbs }
        foreach ($k in $r.Env.Keys) { Set-Item -Path "env:$k" -Value $r.Env[$k] }
        # ⛔ A PLAIN ARRAY VARIABLE, NOT `@(...)` IN ARGUMENT POSITION. `@x` is
        # splatting only for a bare variable name; `@($r.Args)` is an array
        # SUBEXPRESSION, and PowerShell would have passed it to a native command
        # as one flattened argument list anyway -- which happens to work, and
        # happening to work is not a reason to write it ambiguously.
        $extraArgs = @($r.Args)
        & powershell -File $verify -Title $title -Exe $exe -Seconds $Seconds -Scene $r.Scene -DryRun $extraArgs 2>&1 |
            ForEach-Object { Write-Host "     $_" }
        foreach ($k in $r.Env.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
    }
    exit 0
}

$passed = 0; $failed = 0; $incomplete = 0; $results = @()
foreach ($r in $runs) {
    Write-Host ""
    Write-Host "== RUN: $($r.Name) ==" -ForegroundColor Cyan
    $env:SB_SCENE = $r.Scene
    if ($r.Scene -eq 'goldens') { Remove-Item env:SB_SVG -ErrorAction SilentlyContinue }
    else { $env:SB_SVG = $svgAbs }
    foreach ($k in $r.Env.Keys) { Set-Item -Path "env:$k" -Value $r.Env[$k] }

    $extraArgs = @($r.Args)
    $out = & powershell -File $verify -Title $title -Exe $exe -Seconds $Seconds -Scene $r.Scene $extraArgs 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }

    # ⛔ EVERY KNOB THIS RUN SET IS UNSET AGAIN. A leaked SB_RENDER_STALL_MS would
    # stall the NEXT scene too, and that scene's row would be a true statement
    # about an experiment nobody asked for.
    foreach ($k in $r.Env.Keys) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
    Remove-Item env:SB_SYNTH_DRAG -ErrorAction SilentlyContinue

    # The receipt is the window title the app itself wrote -- the one value only
    # a run that actually painted can produce.
    #
    # ⛔ AND IT MUST SURVIVE ITS OWN ABSENCE. A FAILING run has no RUSTOK line at
    # all, so the obvious `(...).Matches.Groups[1].Value` indexes into a null
    # array and THROWS -- killing the sitting before the summary prints, on
    # exactly the path where the summary matters most.
    $m = $out | Select-String -Pattern 'RUSTOK (.+)$' | Select-Object -First 1
    $receipt = if ($m) { $m.Matches[0].Groups[1].Value } else { '(no RUSTOK receipt -- it did not paint)' }
    switch ($rc) {
        0 { $passed++;     $results += "  PASS        $($r.Name) -- $receipt" }
        6 { $incomplete++; $results += "  INCOMPLETE  $($r.Name) -- assertions NOT RUN; see the run above -- $receipt" }
        default { $failed++; $results += "  FAIL($rc)    $($r.Name) -- $receipt" }
    }
}

# THE TOTALS MUST CLOSE. Same law as the witness pass's summary: a run that was
# attempted and landed in no column is a lost row, and a headline that cannot
# account for every run it drove must say so rather than imply the rest.
#
# ⛔ AND `INCOMPLETE` IS ITS OWN COLUMN. Folding it into PASS would turn "the
# assertion could not be evaluated" into "the assertion held"; folding it into
# FAIL would convict the app of something nobody measured.
Write-Host ""
Write-Host ("=== SITTING RESULT: {0} passed, {1} incomplete, {2} failed, of {3} runs attempted ===" -f `
            $passed, $incomplete, $failed, $runs.Count)
$results | ForEach-Object { Write-Host $_ }
if (($passed + $incomplete + $failed) -ne $runs.Count) {
    Write-Host "  |X| THE TOTALS DO NOT CLOSE -- this runner lost a run and its" -ForegroundColor Red
    Write-Host "      own verdict is void. Do not read the line above as a result." -ForegroundColor Red
    exit 3
}
if ($failed -gt 0) { exit 1 }
if ($incomplete -gt 0) { exit 6 }
exit 0
