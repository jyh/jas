# harness_common.ps1 -- the pieces `verify_window.ps1` and `sitting.ps1` BOTH
# need, in one file, dot-sourced by both.
#
# WHY A SHARED FILE AND NOT A SECOND COPY.
#
# `sitting.ps1 -Stay` has to register a session-1 launch task, forward every
# `SB_*` variable, set DOTNET_ROOT and resolve the exe to an absolute path --
# which is, line for line, what `verify_window.ps1` already does. Copying it
# would put the environment forwarding in two places, and that forwarding is the
# one mechanism in this harness with a MEASURED history of silent failure:
# `verify_window.ps1`'s own header records SB_FRAMES being dropped (a run that
# asked for 120 frames quietly measured 60) and predicts, in as many words, that
# "the NEXT variable added needs it again". A copy is that prediction with a new
# way to come true -- one harness path forwarding a knob the other does not, so
# the same command means two different experiments depending on which entry
# point drove it.
#
# ⛔ NOTHING HERE DECIDES ANYTHING. It launches, it waits, it stops, it reads
# rows. Every assertion lives in `verify_window.ps1`, where its expected reading
# is written beside it.

# ---------------------------------------------------------------------------
# Identity and paths
# ---------------------------------------------------------------------------

# USE $env:COMPUTERNAME, NOT $env:USERDOMAIN. In an ssh session the latter reads
# "WORKGROUP" and Register-ScheduledTask dies with "No mapping between account
# names and security IDs was done" -- and the failure is NON-TERMINATING, so a
# script that prints its own success line will happily do so over nothing.
function Get-SbUid {
    return "$env:COMPUTERNAME\$env:USERNAME"
}

function Resolve-SbExe([string]$Exe) {
    # ⛔ A RELATIVE -Exe MAKES THE WHOLE HARNESS A SILENT NO-OP: the launcher and
    # the capture run as SCHEDULED TASKS in session 1, whose working directory is
    # NOT the caller's, so a relative path resolves against C:\Windows\system32,
    # the app never starts, and the run reads as THE ORACLE failing. Measured
    # 2026-08-27; the mechanism was fine the whole time.
    #
    # AND ONLY JOIN WHEN IT IS ACTUALLY RELATIVE -- joining unconditionally turns
    # an already-absolute path into a doubled one and GetFullPath throws.
    if (-not [System.IO.Path]::IsPathRooted($Exe)) {
        $Exe = Join-Path (Get-Location) $Exe
    }
    return [System.IO.Path]::GetFullPath($Exe)
}

function Get-SbLogPath([string]$Exe) {
    # The shell writes `sb-runs.log` next to itself (AppContext.BaseDirectory).
    return (Join-Path (Split-Path $Exe -Parent) 'sb-runs.log')
}

function Get-SbProcessName([string]$Exe) {
    return [System.IO.Path]::GetFileNameWithoutExtension($Exe)
}

# ---------------------------------------------------------------------------
# The log, read as a WINDOW and never as a whole file
# ---------------------------------------------------------------------------
#
# ⛔ `sb-runs.log` IS APPENDED ACROSS RUNS AND IS NEVER TRUNCATED. Reading the
# whole file would let a row from an EARLIER run satisfy a wait or an assertion
# for THIS one -- a green that is a true statement about a different experiment,
# which is the exact shape of mislabelling this harness exists to prevent. So
# every caller records a byte MARK before launching and reads only past it.

function Get-SbLogMark([string]$Log) {
    if (Test-Path $Log) { return (Get-Item $Log).Length }
    return [long]0
}

function Read-SbRows([string]$Log, [long]$Mark) {
    if (-not (Test-Path $Log)) { return @() }
    # FileShare::ReadWrite, because the app holds the file open and appends to it
    # while we read. A plain Get-Content would intermittently throw here, and an
    # intermittent throw inside a polling loop is a wait that ends for the wrong
    # reason.
    $text = ''
    $fs = $null
    try {
        $fs = [System.IO.File]::Open(
            $Log,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $start = $Mark
        if ($start -gt $fs.Length) { $start = 0 }   # truncated under us
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
    } catch {
        return @()
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
    return @($text -split "`n" | Where-Object { $_.Trim().Length -gt 0 })
}

# The rows written BEFORE the mark -- history, used only where an assertion says
# in as many words that it is reading an earlier run (O1's `document` control).
function Read-SbRowsBefore([string]$Log, [long]$Mark) {
    $all = Read-SbRows $Log 0
    $after = Read-SbRows $Log $Mark
    $keep = $all.Count - $after.Count
    # `0..-1` in PowerShell counts DOWN and yields @(0, -1), so an empty history
    # would come back as two bogus rows. Guarded rather than trusted.
    if ($keep -le 0) { return @() }
    return @($all[0..($keep - 1)])
}

function Select-SbRow($Rows, [string]$Pattern) {
    $hit = @($Rows | Where-Object { $_ -match $Pattern })
    if ($hit.Count -eq 0) { return $null }
    return $hit[-1]
}

function Select-SbRows($Rows, [string]$Pattern) {
    return @($Rows | Where-Object { $_ -match $Pattern })
}

# ---------------------------------------------------------------------------
# Waiting on a row -- BOUNDED, with a NAMED refusal
# ---------------------------------------------------------------------------
#
# Returns a hashtable: Row (the matching line or $null), Waited (seconds),
# Rows (every row since the mark at the moment the wait ended).
#
# `Tick` is invoked once per poll with the elapsed whole seconds. O3's liveness
# sampler rides it, so `(Get-Process -Id n).Responding` is read AT t=2, 5 and 10
# of the scene's own wait rather than of some sleep beside it.
function Wait-SbRow {
    param(
        [string]$Log,
        [long]$Mark,
        [string[]]$Patterns,
        [int]$TimeoutSeconds,
        [scriptblock]$Tick = $null
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rows = @()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $rows = Read-SbRows $Log $Mark
        foreach ($p in $Patterns) {
            $hit = Select-SbRow $rows $p
            if ($null -ne $hit) {
                return @{ Row = $hit; Waited = [math]::Round($sw.Elapsed.TotalSeconds, 1); Rows = $rows }
            }
        }
        if ($null -ne $Tick) { & $Tick ([int][math]::Floor($sw.Elapsed.TotalSeconds)) }
        Start-Sleep -Milliseconds 250
    }
    $rows = Read-SbRows $Log $Mark
    return @{ Row = $null; Waited = [math]::Round($sw.Elapsed.TotalSeconds, 1); Rows = $rows }
}

# ---------------------------------------------------------------------------
# Launching, in session 1
# ---------------------------------------------------------------------------

function Get-SbForwardedEnv {
    # ⛔ FORWARD EVERY SB_* VARIABLE, GENERICALLY -- enumerate the environment
    # rather than naming members of it. An unforwarded setting is the worst
    # defect this harness can have: the app falls back to a default, every number
    # looks reasonable, and the run is LABELLED as one experiment while MEASURING
    # another.
    $prefix = ''
    $names = @()
    foreach ($v in (Get-ChildItem env: | Where-Object { $_.Name -like 'SB_*' } | Sort-Object Name)) {
        # Single quotes delimit the generated command, so a value containing one
        # would break out of the string. Refuse rather than mangle.
        if ($v.Value -match "'") {
            throw "harness: $($v.Name) contains a single quote; refusing to forward it."
        }
        $prefix += '$env:' + $v.Name + '=''' + $v.Value + '''; '
        $names += "$($v.Name)=$($v.Value)"
    }
    return @{ Prefix = $prefix; Names = $names }
}

function New-SbLaunchTask {
    param(
        [string]$TaskName,
        [string]$Exe,
        [string]$EnvPrefix
    )
    $principal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
    # DOTNET_ROOT is not optional: the dotnet on PATH is a RUNTIME-ONLY install
    # that shadows the real SDK in LOCALAPPDATA, and a net10 app dies with "You
    # must install or update .NET" without it.
    #
    # -WindowStyle Hidden is not cosmetic either: this task starts the app
    # THROUGH powershell.exe (it has to -- DOTNET_ROOT and the SB_* variables are
    # set in that shell), and that console lands at the top-left of the
    # interactive desktop, exactly where a document's artwork is painted.
    $arg = '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command ' +
        '"$env:DOTNET_ROOT=''' + "$env:LOCALAPPDATA\Microsoft\dotnet" + '''; ' +
        $EnvPrefix + '& ''' + $Exe + '''"'
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "task registration reported success but no task exists: $TaskName"
    }
}

function Remove-SbTask([string]$TaskName) {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop } catch { }
}

function Get-SbAppPids([string]$Exe) {
    $name = Get-SbProcessName $Exe
    return @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

# Start the task and IDENTIFY THE PROCESS IT STARTED, by difference.
#
# ⛔ THIS IS THE WHOLE POINT OF F-2's PID SCOPE. `Known` is the set of
# SbWinUi processes that were already running -- a `-Stay` instance, most often
# -- and they are excluded by construction, so nothing this function returns can
# name a process this call did not start. A name sweep here would kill a live
# `-Stay`, which is how O5 died under its own harness.
#
# More than one new process is a REFUSAL, not a pick: choosing between two would
# be guessing which one the run is about.
function Start-SbAppTask {
    param(
        [string]$TaskName,
        [string]$Exe,
        [int[]]$Known,
        [int]$TimeoutSeconds = 30
    )
    Start-ScheduledTask -TaskName $TaskName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $now = Get-SbAppPids $Exe
        $new = @($now | Where-Object { $Known -notcontains $_ })
        if ($new.Count -eq 1) {
            return @{ Pid = [int]$new[0]; Waited = [math]::Round($sw.Elapsed.TotalSeconds, 1); Refusal = $null }
        }
        if ($new.Count -gt 1) {
            return @{ Pid = 0; Waited = [math]::Round($sw.Elapsed.TotalSeconds, 1);
                      Refusal = "REFUSED: $($new.Count) new $(Get-SbProcessName $Exe) processes appeared ($($new -join ', ')) -- this harness is PID-scoped and will not guess which one the run is about" }
        }
        Start-Sleep -Milliseconds 250
    }
    return @{ Pid = 0; Waited = [math]::Round($sw.Elapsed.TotalSeconds, 1);
              Refusal = "NOT RUN: no new $(Get-SbProcessName $Exe) process appeared within $($TimeoutSeconds)s of starting task '$TaskName'" }
}

# ---------------------------------------------------------------------------
# Stopping, BY PID ONLY
# ---------------------------------------------------------------------------
#
# ⛔ THE TEARDOWN THIS REPLACES WAS `Get-Process -Name ... | Stop-Process -Force`
# and it killed every instance on the desktop, including a `-Stay` the operator
# had deliberately left up. Here the PID is the subject and the NAME is a GUARD:
# a pid that is not an SbWinUi is refused rather than killed, so a recycled pid
# cannot make this harness shoot a stranger.
#
# A pid that is ALREADY GONE is refused too, and that is the freeze's letter:
# "record the launched PID, kill only it, REFUSE if it is gone". A process that
# vanished before teardown is a fact about the run -- most likely a crash -- and
# reporting it as a successful cleanup would erase it.
# ⛔ VALIDATE, THEN ACT -- AND THE VALIDATION IS ITS OWN FUNCTION BECAUSE TWO
# CALLERS NEED IT AT TWO DIFFERENT MOMENTS.
#
# Measured on kenai 2026-09-03 (PR #110): a refused `-Stop <pid>` -- a pid that
# was not an SbWinUi, and a pid that was already gone -- still printed
# `ok  : scheduled task 'jas-sb-app-stay' dropped`. A refusal aimed at a STRANGER
# tore down the launcher of a LIVE stay it had just declined to touch. The
# refusal was correct and the side effect was not, which is the shape a caller
# cannot see: the verdict line says REFUSED and the machine state says otherwise.
#
# So the decision is separable from the act. `sitting.ps1` asks this FIRST and
# touches nothing when it says no; `Stop-SbAppByPid` asks it again immediately
# before killing, so there is exactly ONE spelling of each refusal and the two
# callers cannot drift into disagreeing about what a stranger is.
function Test-SbStopTarget {
    param(
        [int]$TargetPid,
        [string]$ExpectName
    )
    if ($TargetPid -le 0) {
        return @{ Ok = $false; Verdict = "REFUSED: no pid recorded -- this harness kills by PID only, never by name" }
    }
    $p = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if ($null -eq $p) {
        return @{ Ok = $false; Verdict = "REFUSED: pid $TargetPid is not running -- the process this harness launched is GONE before teardown, which is a fact about the run and not a clean exit" }
    }
    if ($p.ProcessName -ne $ExpectName) {
        return @{ Ok = $false; Verdict = "REFUSED: pid $TargetPid is '$($p.ProcessName)', not '$ExpectName' -- refusing to kill a stranger (a pid can be recycled; the name is the guard, never the target)" }
    }
    return @{ Ok = $true; Verdict = "ok  : pid $TargetPid is a live $ExpectName -- this call may act on it" }
}

function Stop-SbAppByPid {
    param(
        [int]$TargetPid,
        [string]$ExpectName,
        [int]$GraceSeconds = 5
    )
    $check = Test-SbStopTarget -TargetPid $TargetPid -ExpectName $ExpectName
    if (-not $check.Ok) {
        return @{ Ok = $false; Verdict = $check.Verdict }
    }
    Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $GraceSeconds) {
        if ($null -eq (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)) {
            return @{ Ok = $true; Verdict = "ok  : pid $TargetPid ($ExpectName) stopped in $([math]::Round($sw.Elapsed.TotalSeconds,1))s" }
        }
        Start-Sleep -Milliseconds 200
    }
    return @{ Ok = $false; Verdict = "FAIL: pid $TargetPid ($ExpectName) is still running $($GraceSeconds)s after Stop-Process" }
}

# ---------------------------------------------------------------------------
# Row field readers -- ONE parser, so two assertions cannot disagree
# ---------------------------------------------------------------------------
#
# ⛔ A FIELD NAME IS ONLY A FIELD NAME AT THE START OF A TOKEN.
#
# Measured on kenai 2026-09-04, the second harness run, on main f2da1654: the
# sitting died at run 2 of 8 with
#
#     Cannot convert value "1.5x1.5" to type "System.Double"
#
# because the shell wave (PR #113) added
#
#     STARTUP ... composition-scale=1.5x1.5 ...
#
# and this reader, asked for `scale`, matched INSIDE `composition-scale=` and
# returned `1.5x1.5`. The first run of the sitting WROTE that row; every run
# after it read the row back out of the log and threw before it launched
# anything. Six of eight runs were lost to it, and the two-arm control is in
# `harness_selftest.ps1`: the same reader on a row carrying a bare `scale=1.5`
# returns `1.5` correctly, so the reader is right and the ANCHOR was missing.
#
# The rows are whitespace-separated (`Report()` joins fields with a space and
# the log prefixes tab-separated columns), so requiring start-of-string or
# whitespace before the name is exactly the row format's own rule. This is the
# same class PR #115 already met at `) policy=` and solved in one caller; here
# it is solved once, in the reader, for every caller.
#
# ⚠️ IT DOES NOT DISAMBIGUATE TWO FIELDS OF THE SAME NAME on one row -- the
# `SQUEEZE delivered` row carries `min-height policy=<m>` and `policy=<decision>`
# and both are token-initial. That row needs its own anchored pattern and has
# one; see `verify_assertions.ps1`. The self-test pins that limitation as a case
# so the next reader does not reach for this function there.

# The anchor, written once. A caller that needs a bare `<name>=` SELECTOR (rather
# than a read) uses this so the selector and the reader cannot disagree about
# what counts as a field -- which is the second half of the same defect: an
# unanchored selector picks the STARTUP row, the anchored reader then finds
# nothing on it, and the run silently falls back to an ASSUMED scale of 1.0
# instead of throwing. A wrong number that reads as a measurement is worse than
# a crash.
$SbFieldAnchor = '(?:^|\s)'

function Get-SbFieldPattern([string]$Name, [string]$ValuePattern = '[^\s]+') {
    return ($SbFieldAnchor + [regex]::Escape($Name) + '=' + $ValuePattern)
}

# ---------------------------------------------------------------------------
# A LIST OF INTEGERS THAT SURVIVES `powershell -File`
# ---------------------------------------------------------------------------
#
# ⛔ `-File` PASSES EVERY ARGUMENT AS A LITERAL STRING. It does not parse
# PowerShell array syntax, so a script parameter typed `[int[]]` receiving
# `-At 2,5,10` gets handed the single string "2,5,10" and coerces it -- and in an
# en-US console the comma is the DIGIT GROUP SEPARATOR, so `[int[]]"2,5,10"` is
# the single integer 2510. Not an error. Not a warning. One number.
#
# Measured on kenai 2026-09-04: `sample_liveness.ps1` is dispatched exactly that
# way through a scheduled task, so O3's liveness sampler slept toward t=2510 s
# (41.8 minutes), wrote ZERO of its three samples inside a 20-second stall, and
# left an orphan process behind on every stall run. Its own receipt printed the
# evidence -- `at=2510s` -- and nothing read it. O3.3 and O3.C1 read NOT RUN.
#
# ⚠️ AND THE FAILURE IS CULTURE-DEPENDENT: under a culture whose group separator
# is not a comma the same string THROWS rather than becoming 2510. A harness that
# reads differently on two machines because of a number format is not an
# instrument. So the list crosses the boundary as a STRING and is split here,
# where the separator is this code's decision and not the console's.
function ConvertTo-SbIntList([string]$Text) {
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Text -split ',')) {
        $s = $part.Trim()
        if ($s -eq '') { continue }
        $n = 0
        # ⛔ InvariantCulture AND NumberStyles.None: no group separators, no
        # sign, no decimal point. "2,510" must not become 2510 here either --
        # that is the same defect wearing this function's name.
        if (-not [int]::TryParse($s, [System.Globalization.NumberStyles]::None,
                                 [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
            throw "ConvertTo-SbIntList: '$s' (in '$Text') is not a plain integer -- refusing to guess"
        }
        $out.Add($n)
    }
    return $out.ToArray()
}

function Get-SbField([string]$Row, [string]$Name) {
    if ([string]::IsNullOrEmpty($Row)) { return $null }
    $m = [regex]::Match($Row, $SbFieldAnchor + [regex]::Escape($Name) + '=([^\s]+)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-SbPoint([string]$Row, [string]$Name) {
    if ([string]::IsNullOrEmpty($Row)) { return $null }
    $m = [regex]::Match($Row, $SbFieldAnchor + [regex]::Escape($Name) + '=\(([-0-9.]+),([-0-9.]+)\)')
    if (-not $m.Success) { return $null }
    return @{ X = [double]$m.Groups[1].Value; Y = [double]$m.Groups[2].Value }
}

# `Stat()` (Canvas.cs) writes `<name> first=<a>ms steady-mean=<b>ms min=... max=...
# n=...` and a BENCHMARK row carries THREE of them: `paint`, `paint+copy` and
# `present`. The space before `first=` is load-bearing -- `paint first=` cannot
# match inside `paint+copy first=` -- and it is why this is one function rather
# than a regex written twice.
function Get-SbSteadyMean([string]$Row, [string]$Stat) {
    if ([string]::IsNullOrEmpty($Row)) { return $null }
    $m = [regex]::Match($Row, [regex]::Escape($Stat) + ' first=[0-9.]+ms steady-mean=([0-9.]+)ms')
    if (-not $m.Success) { return $null }
    return [double]$m.Groups[1].Value
}


# ---------------------------------------------------------------------------
# THE COMPLETION ROWS' VERDICT PREFIX
# ---------------------------------------------------------------------------
#
# ⛔ EVERY SCENE-COMPLETION ROW CARRIES `RUSTOK `/`RUSTFAIL ` SINCE THIS PR, AND
# EVERY PATTERN THAT MATCHES ONE MUST ACCEPT IT WITHOUT REQUIRING IT. `Report`
# writes the LAST row into the window title and the session-1 oracle requires
# `| RUSTOK` there -- so `retained`, `stall` and the o6 squeeze, whose last rows
# were `A'`, `STALL ...` and `SQUEEZE delivered ...`, FAILED three runs that had
# succeeded. The rule is right and the rows were missing the field it reads.
#
# ⚠️ OPTIONAL, NOT REQUIRED: a pattern that demanded the prefix would stop
# matching a bisected build, which is the mirror of the defect being repaired.
# And the TAB stays the anchor -- without it `A'` matches inside another row's
# prose, which is why it was there in the first place.
$SbRowVerdictPrefix = '(?:RUSTOK |RUSTFAIL )?'

# The completion-row pattern, built once so the waits (`verify_window.ps1`) and
# the readers (`verify_assertions.ps1`) cannot disagree about what a completion
# row looks like -- the same law the field anchor is under.
function Get-SbRowPattern([string]$Label, [string]$Tail = '') {
    return ("`t" + $SbRowVerdictPrefix + [regex]::Escape($Label) + $Tail)
}

# ---------------------------------------------------------------------------
# THE ROWS THE RENDER THREAD WROTE (O3.1 / O3.2)
# ---------------------------------------------------------------------------
#
# ⛔ A ROW THAT CARRIES THE TID TAIL IS NOT NECESSARILY A ROW THE RENDER
# THREAD WROTE, AND THE DIFFERENCE COST 8 OF 11 FAILS. `STARTUP` is written at
# first layout ON THE UI THREAD, before the render thread has run: measured on
# kenai 2026-09-04 it carried `ui-tid=0 render-tid=0 paint-tid=0 present-tid=0
# render-has-dispatcher=true`, and O3.2 -- deliberately written over EVERY row
# carrying the tail, because that clause is about the THREAD and holds on a row
# that painted nothing -- convicted the render thread of a flag describing the
# XAML one. Every one of the sitting's eight runs read `VERIFY: FAIL` for it.
#
# The shell now prints `n/a` for the four render-side fields on such a row, and
# the subject of O3.1 and O3.2 is the rows whose `render-tid` is a NON-ZERO
# INTEGER. `n/a` fails that test, and so does `0` -- the pre-repair shell's row
# shape is excluded by the same predicate, so this harness reads a bisected
# build correctly instead of only the newest one.
function Test-SbRenderThreadRow([string]$Row) {
    $rt = Get-SbField $Row 'render-tid'
    if ($null -eq $rt) { return $false }
    $n = 0
    # NumberStyles.None, InvariantCulture: `n/a` is not a number, `0` is a
    # number that is zero, and neither is a row the render thread wrote.
    if (-not [int]::TryParse($rt, [System.Globalization.NumberStyles]::None,
                             [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $false
    }
    return ($n -ne 0)
}

# ---------------------------------------------------------------------------
# THE BENCHMARK ROW'S SURFACE -- O2.2's BAND SOURCE
# ---------------------------------------------------------------------------
#
# ⛔ THE OLD READER SCRAPED `([0-9]+x[0-9]+)px` OFF THE ROW AND GOT A SIZE
# THAT DOES NOT EXIST. Since the shell wave the surface is derived in PHYSICAL
# pixels, but the row's LABEL still applied the composition scale a second time:
# `2858x1429DIP buffer @scale 1.5x1.5 -> 4287x2144px on screen`, on a panel
# 3840 px wide. The reader keyed on the stale half, so O2.2 refused on a surface
# mismatch that was a LABEL and not a geometry.
#
# The repaired row names the surface ONCE, as a field: `surface=2858x1429
# physical @scale 1.5x1.5 (client 1905x953 DIP)`. This reader takes that field
# and REFUSES the old shape BY NAME -- it does not fall back to reading the DIP
# half, because a band silently priced off a row written by a different shell is
# exactly the wave-boundary defect this whole PR is repairing.
function Get-SbBenchmarkSurface([string]$Row) {
    if ([string]::IsNullOrEmpty($Row)) {
        return @{ Ok = $false; Surface = ''; Reason = 'no BENCHMARK row was given to read a surface from' }
    }
    if ($Row -match 'DIP buffer' -or $Row -match 'on screen') {
        return @{ Ok = $false; Surface = ''
                  Reason = 'the BENCHMARK row still carries the PRE-REPAIR surface label ("<W>x<H>DIP buffer @scale <s> -> <W>x<H>px on screen"), which applies the composition scale a SECOND time since the surface became physical. Refusing to read a band surface off it: the px half is a size the panel cannot display and the DIP half is not what the REPAINT rows report' }
    }
    $s = Get-SbField $Row 'surface'
    if ($null -eq $s -or $s -notmatch '^[0-9]+x[0-9]+$') {
        return @{ Ok = $false; Surface = ''
                  Reason = "the BENCHMARK row carries no readable surface=<W>x<H> field (read '$s')" }
    }
    return @{ Ok = $true; Surface = $s; Reason = '' }
}

# ---------------------------------------------------------------------------
# THE MOVE COUNT, PRICED AGAINST THE DRAG'S DURATION (O4.4 / O4.4x)
# ---------------------------------------------------------------------------
#
# ⭐ `move != k` IS THE DRAG'S DURATION, NOT ITS STEP COUNT. Measured on
# kenai 2026-09-04 across 13 configurations with `-HandSettleMs` varying the
# injector's per-step pause -- the arm that breaks the confound, because at a
# fixed 40 ms pause the step count and the elapsed time are perfectly
# correlated. Three readings reverse the defect in both directions: k=7 at 10 ms
# (a 70 ms drag) reads exactly 7, the same k=7 that has read 8 in every sitting
# since PR #110 at 40 ms (a 280 ms drag); k=4 at 100 ms (400 ms) reads 5 while
# k=4 at 40 ms (160 ms) reads 4; and k=1 at 300 ms reads 2, so the extra has
# nothing to do with k at all. k=2 over 800 ms reads 4 -- TWO extras -- so the
# source is periodic. The boundary is between 160 ms and 180 ms.
#
# ⚠ THE SOURCE IS CHARACTERISED, NOT IDENTIFIED. A periodic system arrival
# while the button is held fits every reading on record; which mechanism emits
# it is a NAMED OPEN FINDING in the README and is not claimed here.
#
# So O4.4 is `move >= k` with the extras PRICED: one arrival per 160 ms of
# post-press drag, rounded up. ⛔ THE BUDGET IS AN UPPER BOUND AND IT IS
# LOOSE ON PURPOSE -- at the measured boundary a 280 ms drag is allowed 2 extras
# and produced 1 -- which is exactly why it cannot be the only arm. `O4.4x`
# drives the SAME oracle under the boundary, where the answer must be EXACTLY k,
# and that is the arm that can still convict the app of miscounting.
$SbMoveExactBoundaryMs = 160

function Get-SbMoveExtrasBudget([int]$PostPressMs) {
    if ($PostPressMs -le 0) { return 0 }
    return [int][math]::Ceiling($PostPressMs / [double]$SbMoveExactBoundaryMs)
}

function Test-SbMoveCount {
    param([int]$Move, [int]$K, [int]$PostPressMs)
    $budget = Get-SbMoveExtrasBudget $PostPressMs
    $extras = $Move - $K
    return @{
        Ok = (($extras -ge 0) -and ($extras -le $budget))
        Extras = $extras
        Budget = $budget
        Text = "move=$Move k=$K extras=$extras post-press=$($PostPressMs)ms budget=$budget"
    }
}

# The EXACT arm. It APPLIES only when the post-press drag is at or under the
# measured boundary -- outside it the extra arrival is expected and an exact
# assertion would red on a run that is behaving as characterised. `Applies` is
# false rather than `Ok` being true: an arm that cannot run says so by name.
function Test-SbMoveExact {
    param([int]$Move, [int]$K, [int]$PostPressMs)
    return @{
        Applies = (($PostPressMs -gt 0) -and ($PostPressMs -le $SbMoveExactBoundaryMs))
        Ok = ($Move -eq $K)
        Text = "move=$Move k=$K post-press=$($PostPressMs)ms boundary=$($SbMoveExactBoundaryMs)ms"
    }
}

# ---------------------------------------------------------------------------
# THE TITLE ORACLE
# ---------------------------------------------------------------------------
#
# ⛔ `| RUSTOK` IN THE TITLE IS THE RULE AND IT STAYS. A bare title passes a
# window that says RUSTFAIL, which is the whole reason the required substring
# carries the verdict. On kenai 2026-09-04 it FAILED three runs that had
# succeeded -- `retained`, `stall` and the o6 squeeze -- because each scene's
# LAST row (`A'`, `STALL ...`, `SQUEEZE delivered ...`) carried no verdict and
# `Report` puts the last row in the title. The repair is in the SHELL: every
# scene-completion row now carries the prefix. This function is the rule,
# unchanged, in one place a self-test can drive.
function Select-SbTitleMatch($Titles, [string]$Required) {
    if ($null -eq $Titles) { return @() }
    return @($Titles | Where-Object { $_ -like "*$Required*" })
}

# ---------------------------------------------------------------------------
# THE DOCUMENT, AS THE HARNESS READS IT
# ---------------------------------------------------------------------------
#
# ⭐ THE DISCRIMINATOR LIVES HERE. O4's claim is not that a pointer arrived;
# it is that a pointer arrived AT A POINT THE SHELL COULD NOT HAVE COMPUTED. The
# point comes from `sb-doc-before.json`, which the shell WROTE and never reads
# back, so an element chosen from it is chosen outside the app entirely.
#
# ⛔ THESE FUNCTIONS MOVED HERE FROM `verify_window.ps1` SO THE SELF-TEST CAN
# DRIVE THEM. They are pure over a parsed document -- no window, no session, no
# app -- and the one part of this harness that was measured wrong on the box
# (the chooser) had no arm that could see it. Every file reader below is a thin
# wrapper over a `...FromDoc` core, and the core is what the self-test calls.
function Get-SbFlatElements($node, [string]$path, $acc) {
    if ($null -eq $node) { return }
    # ⛔ SCALARS FIRST, AND `-isnot [psobject]` IS NOT THE TEST. Everything in
    # PowerShell is a PSObject, including a string and a double, so that spelling
    # excludes nothing and the walk would recurse into every leaf.
    if ($node -is [string] -or $node -is [bool] -or $node -is [valuetype]) { return }
    if ($node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $node.Count; $i++) {
            Get-SbFlatElements $node[$i] "$path[$i]" $acc
        }
        return
    }
    $props = @($node.PSObject.Properties | ForEach-Object { $_.Name })
    if ($props -contains 'type') {
        $acc.Add([pscustomobject]@{ Path = $path; Node = $node }) | Out-Null
    }
    foreach ($key in @('layers', 'children')) {
        if ($props -contains $key) {
            Get-SbFlatElements $node.$key "$path.$key" $acc
        }
    }
}

function Read-SbDoc([string]$JsonPath) {
    if (-not (Test-Path $JsonPath)) { return $null }
    return (Get-Content $JsonPath -Raw | ConvertFrom-Json)
}

# The bounding box of one element AND ITS DESCENDANTS, which is what a container
# has instead of coordinates. Returns $null when nothing under it carries
# readable geometry -- a node with no bounds cannot be hit-tested and is skipped
# rather than guessed at.
function Get-SbNodeBounds($Node) {
    if ($null -eq $Node) { return $null }
    $props = @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    $minX = $null; $minY = $null; $maxX = $null; $maxY = $null
    $xs = @(); $ys = @()
    if (($props -contains 'x') -and ($props -contains 'width')) {
        $xs += [double]$Node.x; $xs += ([double]$Node.x + [double]$Node.width)
        $ys += [double]$Node.y; $ys += ([double]$Node.y + [double]$Node.height)
    }
    if ($props -contains 'cx') {
        $rx = if ($props -contains 'rx') { [double]$Node.rx } elseif ($props -contains 'r') { [double]$Node.r } else { 0.0 }
        $ry = if ($props -contains 'ry') { [double]$Node.ry } elseif ($props -contains 'r') { [double]$Node.r } else { $rx }
        $xs += ([double]$Node.cx - $rx); $xs += ([double]$Node.cx + $rx)
        $ys += ([double]$Node.cy - $ry); $ys += ([double]$Node.cy + $ry)
    }
    foreach ($pair in @(@('x1', 'y1'), @('x2', 'y2'))) {
        if (($props -contains $pair[0]) -and ($props -contains $pair[1])) {
            $xs += [double]$Node.($pair[0]); $ys += [double]$Node.($pair[1])
        }
    }
    foreach ($v in $xs) {
        if ($null -eq $minX -or $v -lt $minX) { $minX = $v }
        if ($null -eq $maxX -or $v -gt $maxX) { $maxX = $v }
    }
    foreach ($v in $ys) {
        if ($null -eq $minY -or $v -lt $minY) { $minY = $v }
        if ($null -eq $maxY -or $v -gt $maxY) { $maxY = $v }
    }
    if ($props -contains 'children') {
        foreach ($c in @($Node.children)) {
            $cb = Get-SbNodeBounds $c
            if ($null -eq $cb) { continue }
            if ($null -eq $minX -or $cb.MinX -lt $minX) { $minX = $cb.MinX }
            if ($null -eq $maxX -or $cb.MaxX -gt $maxX) { $maxX = $cb.MaxX }
            if ($null -eq $minY -or $cb.MinY -lt $minY) { $minY = $cb.MinY }
            if ($null -eq $maxY -or $cb.MaxY -gt $maxY) { $maxY = $cb.MaxY }
        }
    }
    if ($null -eq $minX -or $null -eq $minY) { return $null }
    return @{ MinX = $minX; MinY = $minY; MaxX = $maxX; MaxY = $maxY }
}

# ⛔ THE APP'S HIT TEST IS A TOP-LEVEL LAYER-CHILD SCAN IN REVERSE DOCUMENT
# ORDER, AND THAT IS WHAT THIS MIRRORS. Read out of the reference interpreter --
# `workspace_interpreter/doc_primitives.py`, `hit_test(x, y)`: it walks
# `layers` from last to first and each layer's `children` from last to first,
# skipping locked and invisible ones, and returns the FIRST `[li, ci]` whose
# BOUNDS contain the point. It returns the top-level child, NOT the deepest
# leaf -- `hit_test_deep` is the other primitive and is not what a selection
# press uses.
#
# This is the F-B repair. The chooser aimed at the centre of the LARGEST FILLED
# shape and then asserted against THAT element; the app selected the TOPMOST one
# over the same point. Measured on kenai 2026-09-04: the aim landed on
# `$.layers[0].children[0]` (a 72x72 rect), the app selected
# `$.layers[0].children[2]` (its own answer, in the after-dump's `selection[0]`),
# and the element under that path had moved by exactly the asked delta. Two reds
# landed on a run in which everything worked.
function Get-SbLayerChildren($Doc) {
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Doc) { return $out }
    $dp = @($Doc.PSObject.Properties | ForEach-Object { $_.Name })
    if ($dp -notcontains 'layers') { return $out }
    $layers = @($Doc.layers)
    for ($li = 0; $li -lt $layers.Count; $li++) {
        $layer = $layers[$li]
        if (Test-SbNodeSkipped $layer) { continue }
        $lp = @($layer.PSObject.Properties | ForEach-Object { $_.Name })
        if ($lp -notcontains 'children') { continue }
        $kids = @($layer.children)
        for ($ci = 0; $ci -lt $kids.Count; $ci++) {
            if (Test-SbNodeSkipped $kids[$ci]) { continue }
            $out.Add([pscustomobject]@{
                Path = "`$.layers[$li].children[$ci]"
                Li = $li; Ci = $ci; Node = $kids[$ci]
                Bounds = (Get-SbNodeBounds $kids[$ci])
            }) | Out-Null
        }
    }
    return $out
}

# Locked or invisible children are skipped BY THE REFERENCE (`_child_is_locked`
# / `_child_visibility_invisible`), so they are skipped here.
#
# ⚠️ TODAY'S DOCUMENTS CARRY BOTH FIELDS AND NEITHER TRIGGERS A SKIP --
# `test_fixtures/expected/complex_document.json` reads `locked: false` and
# `visibility: "preview"` on the layer and on every child -- so this branch has
# never been taken and is written for the document that will take it. An ABSENT
# field is NOT a skip: inventing a default here would make the mirror disagree
# with the interpreter on exactly the documents the skips exist for.
function Test-SbNodeSkipped($Node) {
    if ($null -eq $Node) { return $true }
    $p = @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    if (($p -contains 'locked') -and ([bool]$Node.locked)) { return $true }
    if (($p -contains 'visibility') -and ("$($Node.visibility)" -match '(?i)invisible')) { return $true }
    return $false
}

function Get-SbTopmostAt($Doc, [double]$X, [double]$Y) {
    $kids = @(Get-SbLayerChildren $Doc)
    for ($i = $kids.Count - 1; $i -ge 0; $i--) {
        $b = $kids[$i].Bounds
        if ($null -eq $b) { continue }
        if ($b.MinX -le $X -and $X -le $b.MaxX -and $b.MinY -le $Y -and $Y -le $b.MaxY) {
            return $kids[$i]
        }
    }
    return $null
}

function Get-SbHitTargetFromDoc($Doc) {
    if ($null -eq $Doc) { return $null }
    $flat = New-Object System.Collections.Generic.List[object]
    Get-SbFlatElements $Doc '$' $flat
    $cands = @()
    foreach ($e in $flat) {
        $n = $e.Node
        $props = @($n.PSObject.Properties | ForEach-Object { $_.Name })
        $t = [string]$n.type
        $hit = $null
        $area = 0.0
        if ($t -eq 'rect' -and ($props -contains 'x') -and ($props -contains 'width')) {
            $hit = @{ X = [double]$n.x + ([double]$n.width / 2.0); Y = [double]$n.y + ([double]$n.height / 2.0) }
            $area = [double]$n.width * [double]$n.height
        } elseif (($t -eq 'ellipse' -or $t -eq 'circle') -and ($props -contains 'cx')) {
            $rx = if ($props -contains 'rx') { [double]$n.rx } elseif ($props -contains 'r') { [double]$n.r } else { 0.0 }
            $ry = if ($props -contains 'ry') { [double]$n.ry } elseif ($props -contains 'r') { [double]$n.r } else { $rx }
            $hit = @{ X = [double]$n.cx; Y = [double]$n.cy }
            $area = 4.0 * $rx * $ry
        }
        if ($null -eq $hit) { continue }
        # FILLED FIRST. A stroke-only shape is a hairline at its centre: aiming
        # there would test the hit test rather than the pointer seam, and a miss
        # would be indistinguishable from an input failure.
        $filled = 0
        if (($props -contains 'fill') -and ($null -ne $n.fill)) { $filled = 1 }
        $id = if ($props -contains 'id') { [string]$n.id } else { '' }
        $cands += [pscustomobject]@{
            Path = $e.Path; Id = $id; Type = $t; Filled = $filled; Area = $area
            X = $hit.X; Y = $hit.Y; Node = $n
        }
    }
    if ($cands.Count -eq 0) { return $null }
    # THE AIM POINT is unchanged: the centre of the largest filled shape.
    $aim = @($cands | Sort-Object -Property @{Expression = 'Filled'; Descending = $true},
                                            @{Expression = 'Area'; Descending = $true},
                                            @{Expression = 'Path'; Descending = $false})[0]
    # THE TARGET is the app's own rule applied to that point.
    $top = Get-SbTopmostAt $Doc $aim.X $aim.Y
    if ($null -eq $top) {
        return [pscustomobject]@{
            Path = $aim.Path; Id = $aim.Id; Type = $aim.Type; Filled = $aim.Filled
            Area = $aim.Area; X = $aim.X; Y = $aim.Y; Node = $aim.Node
            AimPath = $aim.Path
            Rule = 'NO top-level layer child''s bounds contain the aim point, so the chooser fell back to the aimed shape itself. O1.2c is what reports a disagreement with the app'
        }
    }
    $tn = $top.Node
    $tp = @($tn.PSObject.Properties | ForEach-Object { $_.Name })
    return [pscustomobject]@{
        Path = $top.Path
        Id = $(if ($tp -contains 'id') { [string]$tn.id } else { '' })
        Type = [string]$tn.type
        Filled = $aim.Filled; Area = $aim.Area
        X = $aim.X; Y = $aim.Y; Node = $tn
        AimPath = $aim.Path
        Rule = 'the TOPMOST top-level layer child whose bounds contain the aim point (the reference interpreter''s own rule: workspace_interpreter/doc_primitives.py hit_test scans layers and their children in REVERSE document order and returns the first [li,ci] whose bounds contain the point)'
    }
}

function Get-SbHitTarget([string]$JsonPath) {
    return (Get-SbHitTargetFromDoc (Read-SbDoc $JsonPath))
}

# The furthest coordinate any element in the document reaches, so a point can be
# shown to be OUTSIDE the artwork rather than assumed to be. Returns $null when
# the document holds nothing with readable coordinates.
function Get-SbDocExtentFromDoc($Doc) {
    if ($null -eq $Doc) { return $null }
    $flat = New-Object System.Collections.Generic.List[object]
    Get-SbFlatElements $Doc '$' $flat
    $maxX = $null
    $maxY = $null
    foreach ($e in $flat) {
        $b = Get-SbNodeBounds $e.Node
        if ($null -eq $b) { continue }
        if ($null -eq $maxX -or $b.MaxX -gt $maxX) { $maxX = $b.MaxX }
        if ($null -eq $maxY -or $b.MaxY -gt $maxY) { $maxY = $b.MaxY }
    }
    if ($null -eq $maxX) { return $null }
    return @{ MaxX = $maxX; MaxY = $maxY }
}

function Get-SbDocExtent([string]$JsonPath) {
    return (Get-SbDocExtentFromDoc (Read-SbDoc $JsonPath))
}

function Get-SbElementByPathFromDoc($Doc, [string]$Path) {
    if ($null -eq $Doc -or [string]::IsNullOrEmpty($Path)) { return $null }
    $flat = New-Object System.Collections.Generic.List[object]
    Get-SbFlatElements $Doc '$' $flat
    foreach ($e in $flat) { if ($e.Path -eq $Path) { return $e.Node } }
    return $null
}

function Get-SbElementByPath([string]$JsonPath, [string]$Path) {
    return (Get-SbElementByPathFromDoc (Read-SbDoc $JsonPath) $Path)
}

# ⭐ THE APP'S OWN ANSWER TO "WHICH ELEMENT DID THE GESTURE TAKE". The
# after-dump carries `selection[0].path` as a list of indices, and reading O1.2
# against THAT instead of against the harness's guess is what turns two false
# reds into one true finding (F-B). The index list is rendered in this harness's
# own path spelling so the two can be compared as strings.
function ConvertTo-SbElementPath($Indices) {
    $ix = @($Indices)
    if ($ix.Count -lt 1) { return $null }
    $p = '$.layers[' + [int]$ix[0] + ']'
    for ($i = 1; $i -lt $ix.Count; $i++) { $p += '.children[' + [int]$ix[$i] + ']' }
    return $p
}

function Get-SbSelectionPathFromDoc($Doc) {
    if ($null -eq $Doc) { return $null }
    $dp = @($Doc.PSObject.Properties | ForEach-Object { $_.Name })
    if ($dp -notcontains 'selection') { return $null }
    $sel = @($Doc.selection)
    if ($sel.Count -lt 1 -or $null -eq $sel[0]) { return $null }
    $sp = @($sel[0].PSObject.Properties | ForEach-Object { $_.Name })
    if ($sp -notcontains 'path') { return $null }
    return (ConvertTo-SbElementPath $sel[0].path)
}

function Get-SbSelectionPath([string]$JsonPath) {
    return (Get-SbSelectionPathFromDoc (Read-SbDoc $JsonPath))
}

# WHERE AN ELEMENT IS, read the same way before and after so a difference is a
# MOVE and not a change of instrument. A rect answers with `x/y`, an ellipse
# with `cx/cy`, and anything else -- a line, a group, a layer child holding the
# moved shape -- with the origin of its subtree's bounding box. `How` is
# returned and PRINTED: two readings taken by different rules are not a delta.
function Get-SbElementOrigin($Node) {
    if ($null -eq $Node) { return $null }
    $p = @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    if (($p -contains 'x') -and ($p -contains 'y')) {
        return @{ X = [double]$Node.x; Y = [double]$Node.y; How = 'the x/y pair' }
    }
    if (($p -contains 'cx') -and ($p -contains 'cy')) {
        return @{ X = [double]$Node.cx; Y = [double]$Node.cy; How = 'the cx/cy pair' }
    }
    $b = Get-SbNodeBounds $Node
    if ($null -eq $b) { return $null }
    return @{ X = $b.MinX; Y = $b.MinY
              How = 'the origin of its bounding box (min over this element and its descendants)' }
}

# ---------------------------------------------------------------------------
# CROSS-RUN RECEIPTS, SCOPED TO ONE SITTING
# ---------------------------------------------------------------------------
#
# ⛔ SOME ASSERTIONS NEED A FIGURE FROM A DIFFERENT RUN, AND `sb-runs.log` CANNOT
# CARRY IT. The log is read as a WINDOW past this run's mark, on purpose: a row
# from an earlier run must never satisfy this one. But O2's band is a multiple of
# the SAME SITTING's benchmark frame, and O6.4 reads a squeeze run together with a
# probe run -- two figures that are, by construction, outside the window.
#
# So they travel as FILES, and every file carries the sitting it belongs to.
# `JAS_SB_SITTING` is set once per sitting by `sitting.ps1` (a GUID) and is NOT an
# `SB_*` name, so `Get-SbForwardedEnv` never forwards it to the app: it labels the
# HARNESS's runs and is invisible to the shell, which is what stops it becoming a
# knob nobody documented.
#
# Two runs driven by hand carry no sitting, so they share the id 'no-sitting' --
# and a 'no-sitting' receipt EXPIRES after an hour, because otherwise a figure
# measured last week would silently price a run taken today. The expiry is
# reported by name; it is never a silent miss.
function Get-SbSittingId {
    $s = $env:JAS_SB_SITTING
    if ([string]::IsNullOrWhiteSpace($s)) { return 'no-sitting' }
    return $s
}

function Write-SbReceipt {
    param([string]$Path, [hashtable]$Data)
    $Data['sitting'] = Get-SbSittingId
    $Data['written'] = (Get-Date).ToString('o')
    ($Data | ConvertTo-Json -Depth 6) | Set-Content -Path $Path -Encoding utf8
}

# Returns @{ Ok; Data; Reason }. `Ok=$false` ALWAYS carries a Reason written to be
# printed as a `NOT RUN` detail -- a receipt that cannot be used has to say which
# of the three reasons applies (absent, another sitting, expired), because those
# are three different things for the reader to do next.
function Read-SbReceipt {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        return @{ Ok = $false; Data = $null; Reason = "no $Label receipt at $([IO.Path]::GetFileName($Path)) -- that run has not happened in this sitting" }
    }
    $data = $null
    try { $data = Get-Content $Path -Raw | ConvertFrom-Json } catch {
        return @{ Ok = $false; Data = $null; Reason = "the $Label receipt $([IO.Path]::GetFileName($Path)) could not be read as JSON: $($_.Exception.Message)" }
    }
    $mine = Get-SbSittingId
    if ([string]$data.sitting -ne $mine) {
        return @{ Ok = $false; Data = $null; Reason = "the $Label receipt belongs to sitting '$($data.sitting)' and this run is sitting '$mine' -- a figure from another sitting is a figure from another box state" }
    }
    if ($mine -eq 'no-sitting') {
        # ⛔ PARSED DEFENSIVELY, AND WITH THE INVARIANT CULTURE. The callers run
        # under `$ErrorActionPreference = 'Stop'`, so a throw here would kill the
        # whole run over a stale receipt -- an unreadable timestamp must refuse the
        # FIGURE, never the RUN.
        $age = 0.0
        try {
            $written = [datetime]::Parse([string]$data.written, [Globalization.CultureInfo]::InvariantCulture)
            $age = ((Get-Date) - $written).TotalMinutes
        } catch {
            return @{ Ok = $false; Data = $null; Reason = "the $Label receipt carries no readable timestamp ('$($data.written)'), and with no sitting id there is nothing else to scope it by" }
        }
        if ($age -gt 60) {
            return @{ Ok = $false; Data = $null; Reason = ("the $Label receipt is {0:N0} minutes old and carries no sitting id (both runs were driven by hand) -- refusing to price this run with it" -f $age) }
        }
    }
    return @{ Ok = $true; Data = $data; Reason = '' }
}
