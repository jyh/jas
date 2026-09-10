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

# ⛔ AN EMPTY PATTERN IS A REFUSAL, NEVER A MATCH. `'' -match ''` is TRUE for
# every row, so a caller that built its pattern list from a TABLE -- and got
# `$null` back for a key that was not there -- would silently select the last
# unrelated row and end its wait at 0s with a confident answer. That is not
# hypothetical: `[string[]]` coercion turns a `$null` element into `''` before
# this function ever sees it, so the empty pattern arrives looking deliberate.
# Refusing by name is the only way an instrument's own bad input surfaces.
function Select-SbRow($Rows, [string]$Pattern) {
    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        throw "Select-SbRow: the pattern is empty -- refusing to match every row."
    }
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

# ---------------------------------------------------------------------------
# WAVE 1's RECEIPT ROWS, AS READINGS (P1-P4)
# ---------------------------------------------------------------------------
#
# ⛔ THEY LIVE HERE, NOT IN `verify_assertions.ps1`, FOR THE REASON THAT FILE
# ALREADY STATES ABOUT THE CHOOSER: it cannot be dot-sourced without a Windows
# desktop, so anything inside it has no arm. These are PURE FUNCTIONS OVER
# STRINGS -- `harness_selftest.ps1` drives them in CI, on the row text the box
# actually printed, with no app and no session. P1-P4 are then thin: read, then
# compare.
#
# ⛔⛔ AND EVERY ONE OF THEM REFUSES BY NAME RATHER THAN RETURNING $null. A
# reader that answers `$null` for BOTH "the field is absent" and "the field is
# malformed" hands an assertion a value that reads as FALSE, and a malformed row
# then convicts the app of the defect the READER has. The refusal carries the
# reason so the verdict can be NOT RUN -- which is a first-class verdict here
# and is never a pass.

# `name=a/b` or `name=a/b/c`: the paired readings wave 1 puts on one field.
# `menu-enabled=43/44` (before/after a mutation), `can-undo=false/true/false`
# (before/after the edit/after the undo), `svg-bytes=505/616`.
function Get-SbSlashField([string]$Row, [string]$Name, [int]$Parts) {
    $raw = Get-SbField $Row $Name
    if ($null -eq $raw) {
        return @{ Ok = $false; Parts = @(); Raw = ''
                  Reason = "the row carries no '$Name=' field" }
    }
    $bits = @($raw -split '/')
    if ($bits.Count -ne $Parts) {
        # ⛔ REFUSING TO GUESS WHICH PART IS WHICH. A two-reading field that
        # arrived with three parts is a shell change, and silently taking the
        # first two would compare readings that are not the ones named.
        return @{ Ok = $false; Parts = @(); Raw = $raw
                  Reason = "'$Name=$raw' has $($bits.Count) slash-separated part(s), not $Parts" }
    }
    return @{ Ok = $true; Parts = $bits; Raw = $raw; Reason = '' }
}

# A count the shell asserts is STABLE across a pair of readings. The shell
# writes `55` when the two agreed and `55!=57` when they did not, so the
# disagreement is IN the field rather than inferable from its absence -- and a
# reader that accepted only digits would treat the anti-collapse signal as a
# malformed row.
function Get-SbStableCount([string]$Row, [string]$Name) {
    $raw = Get-SbField $Row $Name
    if ($null -eq $raw) {
        return @{ Ok = $false; Stable = $false; Value = -1; Raw = ''
                  Reason = "the row carries no '$Name=' field" }
    }
    $m = [regex]::Match($raw, '^([0-9]+)$')
    if ($m.Success) {
        return @{ Ok = $true; Stable = $true; Value = [int]$m.Groups[1].Value; Raw = $raw; Reason = '' }
    }
    $d = [regex]::Match($raw, '^([0-9]+)!=([0-9]+)$')
    if ($d.Success) {
        return @{ Ok = $true; Stable = $false; Value = [int]$d.Groups[1].Value
                  Other = [int]$d.Groups[2].Value; Raw = $raw; Reason = '' }
    }
    return @{ Ok = $false; Stable = $false; Value = -1; Raw = $raw
              Reason = "'$Name=$raw' is neither a count nor the shell's disagreement form 'n!=m'" }
}

# The MENU row's arithmetic. `items`, `enabled` and `disabled` are three
# independent readings of one menubar and the first must be the sum of the
# other two; a shell drawing a different menubar than it counted breaks it.
#
# ⚠️ `enabled` AND `disabled` COLLIDE BY SUFFIX, and the harness's field anchor
# `(?:^|\s)` is the only thing that keeps `Get-SbField <row> 'enabled'` off
# `disabled=12`. That is the `composition-scale` defect's exact shape, on a new
# row, so `harness_selftest.ps1` drives BOTH names against a real MENU row.
function Get-SbMenuRowReading([string]$Row) {
    $out = @{ Ok = $false; Items = -1; Enabled = -1; Disabled = -1; Seq = -1
              Missed = -1; StateAge = -1; ShortcutsUnparsed = -1
              ShortcutsApply = $false; Reason = '' }
    foreach ($name in @('items', 'enabled', 'disabled', 'seq', 'missed')) {
        $v = Get-SbField $Row $name
        if ($null -eq $v -or -not ($v -match '^[0-9]+$')) {
            $out.Reason = "the MENU row carries no readable '$name=' field"
            return $out
        }
    }
    $age = Get-SbField $Row 'state-age'
    if ($null -eq $age -or -not ($age -match '^[0-9]+$')) {
        $out.Reason = "the MENU row carries no readable 'state-age=' field"
        return $out
    }
    $out.Items = [int](Get-SbField $Row 'items')
    $out.Enabled = [int](Get-SbField $Row 'enabled')
    $out.Disabled = [int](Get-SbField $Row 'disabled')
    $out.Seq = [int](Get-SbField $Row 'seq')
    $out.Missed = [int](Get-SbField $Row 'missed')
    $out.StateAge = [int]$age
    # ⚠️ `shortcuts-unparsed` IS OPTIONAL AND `Applies` SAYS SO -- the same rule
    # `raised=` follows. The field is newer than the corpus of MENU rows on
    # record, and a bisected build's row must not be refused for lacking a field
    # it never carried. ABSENT is not zero: "no accelerator failed" and "this
    # build does not report accelerator failures" are different readings.
    $su = Get-SbField $Row 'shortcuts-unparsed'
    if ($null -ne $su -and ($su -match '^[0-9]+$')) {
        $out.ShortcutsUnparsed = [int]$su
        $out.ShortcutsApply = $true
    } else {
        $out.ShortcutsUnparsed = -1
        $out.ShortcutsApply = $false
    }
    $out.Ok = $true
    return $out
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
# THE SCENES, AND THE ROW EACH ONE FINISHES WITH
# ---------------------------------------------------------------------------
#
# ⛔ THIS TABLE IS THE REPLACEMENT FOR THE FIXED SLEEPS, AND IT IS THE WHOLE
# REPAIR. A sleep asks "has enough time passed"; a row asks "has the thing I am
# measuring happened". The two differ exactly when the answer matters -- O3's
# 20 s stall against an 8 s sleep.
#
# `Done` entries are matched as regular expressions against rows written SINCE
# this run's mark. The leading tab is `Report`'s own separator, and it is there so
# `A'` cannot be matched inside some other row's prose.
#
# ⛔ IT LIVES IN THIS FILE BECAUSE BOTH HALVES OF THE HARNESS READ IT, AND THE
# ONE THAT DID NOT HAD ITS OWN COPY. `verify_window.ps1` waits on `Done` to
# decide a run is over; `sitting.ps1 -Stay` waits on it to learn the pid of a
# window it is about to hand to a person. `sitting.ps1` used to hardcode
# `RUSTOK STAY pid=` for EVERY scene, so `-Stay -Scene app` waited 90 s for a
# row the app scene is not written to produce and left the window alive
# (measured on kenai 2026-09-09 by the seat with hands on the box). Two
# lists, one harness.
# `scripts/check_scene_tables.py` joins this table to the shell's dispatch and
# REFUSES if a second `$sceneSpec` ever appears.
#
# ⭐ `Holds = $true` MARKS A SCENE THAT DOES NOT COMPLETE AND DOES NOT EXIT.
# `stay` and `app` are applications, not measurements: they write their row and
# keep the window up. The field is what `sitting.ps1` reads to know that
# `-Stay` is the ONLY legitimate way to launch them, and it is on the table
# rather than in a list somewhere so a new holding scene declares itself in the
# same place it declares its row.
$sceneSpec = @{
    # ⛔ THE VERDICT PREFIX IS OPTIONAL IN THE PATTERN, AND THAT IS NOT
    # LOOSENESS. The shell wave in this PR puts `RUSTOK `/`RUSTFAIL ` in front of
    # every scene-COMPLETION row, because `Report` writes the last row into the
    # window title and the session-1 oracle requires `| RUSTOK` there -- three
    # successful runs were FAILED by it on kenai 2026-09-04. A pattern that
    # REQUIRED the prefix would stop matching a bisected build's rows, which is
    # the mirror defect of the one being repaired: this harness must read both
    # shells. The tab is still the anchor, so `A'` cannot match inside prose.
    'retained' = @{
        Done    = @((Get-SbRowPattern "A'" " surface="))
        # ⛔ `Refused` IS NOT IN `Done` HERE, AND THAT IS DELIBERATE. Measured on
        # kenai 2026-09-09: this scene does NOT time out on a bad document -- the
        # `SB_RESIZE` walk writes `A'` independently of the scene's return value,
        # so `Done` already matches and the wait ends at 0s. Adding this pattern
        # to `Done` would change nothing.
        # ⭐ THIS SCENE IS WHY THE VERDICT IS CLASSIFIED AND NOT INFERRED FROM THE
        # WAIT. Because `A'` arrives after a refusal, the completion line read
        # `ok  : completed` over a hash of a blank white surface. The pattern
        # below is what `Get-SbSceneVerdict` reads to say REFUSED instead -- and
        # what ends the hand's dump wait, which has no terminal condition at all
        # when the scene refuses and burned 90 s each time.
        Refused = @("RUSTFAIL RETAINED ")
        Label   = "the A' hash row (the round trip's H2)"
        Timeout = 150
    }
    'benchmark' = @{
        Done    = @("RUSTOK BENCHMARK frames=", "RUSTFAIL BENCHMARK")
        Refused = @("RUSTFAIL BENCHMARK ")
        Label   = "the BENCHMARK row"
        Timeout = 150
    }
    'document' = @{
        Done    = @("RUSTOK DOCUMENT '", "RUSTFAIL DOCUMENT")
        Refused = @("RUSTFAIL DOCUMENT ")
        Label   = "the DOCUMENT control row"
        Timeout = 120
    }
    'goldens' = @{
        Done    = @("RUSTOK GOLDENS ", "GOLDENS FAILED")
        Refused = @("RUSTFAIL GOLDENS ")
        Label   = "the GOLDENS row"
        Timeout = 120
    }
    'selection-marquee' = @{
        Done    = @("RUSTOK SELECTION '", "RUSTFAIL SELECTION")
        Refused = @("RUSTFAIL SELECTION ")
        Label   = "the SELECTION row"
        Timeout = 120
    }
    'stall' = @{
        # ⛔ THE FAILURE PATTERN IS MEASURED, NOT ASSUMED. Driven on kenai
        # 2026-09-09 with a non-SVG document: `RenderStall` refuses in under a
        # second and labels its row (`RUSTFAIL STALL FAILED: LOAD FAILED
        # '<p>': BAD SVG`), and with only the success pattern here that named
        # refusal was waited out for the full 140 s (120 + the derived stall
        # budget) and reported `FAIL: NOT RUN: timed out waiting for the STALL
        # row` -- 237 s of wall-clock for a fault the shell had already named.
        # A labelled row nothing waits on is a label with no reader.
        Done    = @((Get-SbRowPattern 'STALL' ' render-stall='), "RUSTFAIL STALL ")
        Refused = @("RUSTFAIL STALL ")
        Label   = "the STALL row, or the scene's own named refusal"
        Timeout = 120
    }
    'pointer' = @{
        # ⛔ THE THIRD PATTERN IS THE SYNTHETIC ARM'S, AND WITHOUT IT THAT RUN
        # COULD NEVER COMPLETE. Measured 2026-09-06: the `SB_SYNTH_DRAG` run in
        # `sitting.ps1`'s pointer set burned its full 120 s and reported
        # `FAIL: NOT RUN: timed out`, on every sitting since `bf99ad62`, while
        # its ten assertions PASSED off a row that had been on disk for two
        # minutes. `Canvas.ApplyPointerReport` says why in its own comment --
        # `if (_handDeadlineMs < 0 || provenance != "REAL") { return; }`, so the
        # synthetic replay NEVER writes `HAND CLOSED` by design. The wait was
        # asking for a row the arm is constructed not to produce.
        #
        # ⛔ AND IT IS THE SYNTHETIC-SPECIFIC SPELLING, NOT A BARE `POINTER `.
        # A real hand writes its `POINTER REAL` row BEFORE `HAND CLOSED`, so a
        # generic pattern would complete a real run early and skip the
        # after-dump that O1.2 reads. `POINTER SYNTHETIC ` cannot appear in a
        # real run at all: `Canvas.cs` derives the provenance from the kind and
        # a row can never claim one its counters did not come from.
        #
        # ⛔ AND THE FOURTH IS THE SCENE'S OWN REFUSAL, MEASURED ON kenai
        # 2026-09-09. With a non-SVG document `RenderPointer` refuses at once
        # and labels the row (`RUSTFAIL POINTER FAILED: LOAD FAILED '<p>': BAD
        # SVG`) -- and the run still burned its full 120 s and reported
        # `FAIL: NOT RUN: timed out`, with that labelled row sitting in the log
        # and in the window title the whole time. Three pointer runs are
        # planned per sitting, so the class cost 560 s in one measurement.
        Done    = @("HAND CLOSED scene=", "NOT RUN: hand refused", "POINTER SYNTHETIC press=",
                    "RUSTFAIL POINTER ")
        Refused = @("RUSTFAIL POINTER ")
        Label   = "the HAND CLOSED row, its named refusal, the SYNTHETIC control's own POINTER row, or the scene's own named refusal"
        Timeout = 120
    }
    # ⛔ THE FAILURE PATTERN IS NOT DECORATION HERE. `RenderStay` refuses BY
    # NAME on an unreadable document (`STAY FAILED: cannot read '<p>'`), and
    # with only the success pattern in this list that fast, named refusal was
    # waited out for the full 120 s and then reported as a TIMEOUT -- which
    # reads as a hung app instead of a refused one. Every other scene in this
    # table already carries both verdicts; `stay` did not, and nothing looked
    # at it because `stay` is never in the default scene list.
    'stay' = @{
        Done    = @("RUSTOK STAY pid=", "RUSTFAIL STAY ")
        Refused = @("RUSTFAIL STAY ")
        Label   = "the STAY pid row, or the stay scene's named refusal"
        Timeout = 120
        Holds   = $true
    }
    # ⭐ W3's CONSUMER. One row, all five of wave 1's bindings driven against
    # the engine this shell is holding. It COMPLETES, so it is an ordinary
    # measurement scene and belongs in a sitting.
    'abi' = @{
        Done    = @("RUSTOK ABI menu-items=", "RUSTFAIL ABI ")
        Refused = @("RUSTFAIL ABI ")
        Label   = "the ABI probe row"
        Timeout = 120
    }
    # ⭐ W4's ENTRY -- the thing a person double-clicks -- and it is `stay`'s
    # shape, not `benchmark`'s. It writes `RUSTOK APP pid=` and then HOLDS.
    #
    # ⛔ IT IS IN THIS TABLE THOUGH IT NEVER COMPLETES, AND THAT IS THE POINT.
    # Its absence was not a decision anyone recorded; it was an omission that
    # made `-Scenes app` refuse by name and `-Stay -Scene app` time out. A
    # holding scene is kept out of the DEFAULT scene list (`sitting.ps1`'s
    # `-Scenes` default) -- never out of the table, which is where the harness
    # learns the row to wait for.
    'app' = @{
        Done    = @("RUSTOK APP pid=", "RUSTFAIL APP ")
        Refused = @("RUSTFAIL APP ")
        Label   = "the APP pid row, or the app entry's named refusal"
        Timeout = 120
        Holds   = $true
    }
}

# ⭐ THE SCENE'S OWN NAMED REFUSALS. IT HAS TWO CONSUMERS AND THEY ARE NOT ALIKE.
#
# ⛔ THIS HEADING USED TO READ "FOR WAITS THAT ARE NOT THE COMPLETION WAIT" AND
# THAT WENT FALSE ONE PR LATER. `Get-SbSceneVerdict` reads the same key to decide
# the completion VERDICT. Corrected here rather than left, because a heading that
# names one consumer reads as a statement that there is only one.
#
#   (a) THE WAITS INSIDE A RUN -- the hand's document dump, the stall's ARMED
#       row. They want only the REFUSAL half: a refusal means the row they are
#       waiting for is never coming, while a SUCCESS pattern would end them early
#       on a row that says nothing about their own subject.
#   (b) THE COMPLETION VERDICT -- `Get-SbSceneVerdict`, which reads REFUSED if
#       any of these appears ANYWHERE in the region, regardless of what ended the
#       wait.
#
# ⛔ WHY THIS IS A SEPARATE KEY RATHER THAN A SECOND READ OF `Done`. `Done` is
# the set that ENDS THE SCENE -- success or refusal, both are terminal and the
# completion wait wants both. Neither consumer above wants the success half.
#
# Measured on kenai 2026-09-10, one bad-document run per scene: the hand's dump
# wait burned 90.2 s and the stall's ARMED wait burned 90.2 s, in both cases
# with the scene's own labelled refusal already sitting in the log. A third wait
# of the same shape -- `retained`'s FIRST-PRESENT gate -- was censused and does
# NOT burn, because the shell presents even on a refusal; it is left alone
# rather than "fixed" on the strength of the other two.
#
# Returns an empty array for a scene with no declared refusals -- but see
# `Get-SbWaitPatterns` below: an empty return does NOT survive a parenthesised
# call, so no caller should splat this directly.
function Get-SbSceneRefusals([string]$Scene) {
    $spec = $sceneSpec[$Scene]
    if ($null -eq $spec) { return @() }
    if (-not $spec.ContainsKey('Refused')) { return @() }
    return @($spec.Refused)
}

# ⭐ THE LIST A WAIT INSIDE A RUN ACTUALLY WANTS: the caller's own patterns plus
# the scene's declared refusals, with any empty entry dropped.
#
# ⛔ IT EXISTS BECAUSE `+` IS NOT SAFE HERE AND THE UNSAFE CASE IS SILENT. A
# PowerShell function whose output stream is empty evaluates to `$null` in a
# parenthesised call, so `@('DUMP ...') + (Get-SbSceneRefusals $Scene)` is a
# TWO-element list for any scene with no `Refused` key, and `[string[]]` then
# turns the second element into `''` -- a pattern that matches every row. The
# concatenation looks right at the call site and reads right in review.
#
# Every scene in `$sceneSpec` declares `Refused` today, and
# `scripts/check_scene_refusal_labels.py` clause (d) keeps it that way, so the
# empty case is unreachable through the table. This is the belt to that
# braces: `verify_window.ps1 -Hand -Scene <anything>` is a legal invocation and
# a future scene is one edit away.
function Get-SbWaitPatterns([string[]]$Patterns, [string]$Scene) {
    $all = @($Patterns) + @(Get-SbSceneRefusals $Scene)
    return @($all | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# ⛔⛔ THE COMPLETION WAIT AND THE COMPLETION VERDICT ARE TWO QUESTIONS, AND ONE
# MECHANISM WAS ANSWERING BOTH. That conflation IS the defect.
#
#   "May I stop waiting?"                 any `Done` row is a legitimate answer.
#   "Did the scene do what it was asked?" ONLY the scene may answer that.
#
# Measured on kenai 2026-09-09: on a bad document `retained` refuses in under a
# second, and the `SB_RESIZE` walk writes `A'` ANYWAY, because that walk runs
# independently of the scene's return value. `A'` is in `Done`. So the wait ended
# correctly and the verdict line read `ok  : scene 'retained' completed` over a
# hash taken on a BLANK WHITE SURFACE.
#
# ⛔ THE FIX IS NOT TO STOP WRITING `A'`. That row is TRUE -- the walk really did
# run and really did hash that surface -- and the blank window was only
# diagnosable BECAUSE the row exists. Deleting a true record to stop a reader
# misreading it is the wrong repair every time, and it would have made the
# finding unfindable.
#
# ⇒ RULED: if the scene wrote its OWN named refusal anywhere in the region, the
# verdict is REFUSED -- REGARDLESS of which pattern ended the wait. ⭐ That kills
# the race by not depending on ordering at all: both rows landing in the same
# second stops mattering, because arrival order stops being an input.
#
# ⛔ AND IT IS ONLY SOUND BECAUSE EVERY REFUSAL PATH NAMES ITS SCENE. "The scene
# wrote its own named refusal" is `RUSTFAIL <PREFIX> `, and before that labelling
# landed the pattern covered 26 of the shell's 44 refusal paths -- so this
# function would have read REFUSED for some refusals and DONE for the rest, which
# is WORSE than not classifying at all. `scripts/check_scene_refusal_labels.py`
# is what keeps the premise true, and it is why the labelling had to come first.
#
# Returns a hashtable: Verdict ('DONE' | 'REFUSED' | 'TIMEOUT'), Row, Pattern.
function Get-SbSceneVerdict($Rows, [string]$Scene, $DoneRow) {
    # `@(...)` for the same reason `Get-SbWaitPatterns` has it: a function whose
    # output stream is empty evaluates to `$null` here, and `foreach` over `$null`
    # is a version-dependent question this seat cannot run. `@()` settles it.
    foreach ($p in @(Get-SbSceneRefusals $Scene)) {
        $hit = Select-SbRow $Rows $p
        if ($null -ne $hit) {
            return @{ Verdict = 'REFUSED'; Row = $hit; Pattern = $p }
        }
    }
    if ($null -eq $DoneRow) {
        return @{ Verdict = 'TIMEOUT'; Row = $null; Pattern = $null }
    }
    return @{ Verdict = 'DONE'; Row = $DoneRow; Pattern = $null }
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
# THE MOVE COUNT: `move == k`, UNCONDITIONALLY (O4.4), AND THE DUPLICATES
# THAT ARE STILL ARRIVING (O4.4x)
# ---------------------------------------------------------------------------
#
# ⭐ `move != k` IS IDENTIFIED (flask, 2026-09-06) AND FIXED AT THE SOURCE.
# The extras were never new input: XAML RE-DELIVERS a pointer frame the shell
# has already applied -- same FrameId AND Timestamp AND position -- while the
# contact sits still, and the repeats multiply with the idle gap after each move
# (settle 10 ms: none; 800 ms: five). `MainWindow.OnPointerMoved` suppresses a
# repeated frame, counts it, and reports the count as `dup-frames=`.
#
# Everything below the app was excluded FIRST, by measurement rather than by
# argument: `probe_hold.ps1` drives a BARE WIN32 WINDOW with this harness's own
# injector construction and reads arrivals == k EXACTLY at every configuration
# on record, in BOTH input stacks, with the button held and with the window
# repainting at 5 ms. So SendInput, the mouse stack, the pointer stack, the
# message queue and the redraw are innocent.
#
# ⛔ THE HISTORICAL RULING WAS `move >= k` WITH THE EXTRAS PRICED at one arrival
# per 160 ms of post-press drag (the boundary measured on kenai 2026-09-04
# between 160 ms and 180 ms), and O4.4x asserted equality only UNDER that
# boundary. The budget existed for exactly one reason, stated in the ruling
# itself: the source was an open finding and could not be charged to the app's
# counting. RE-CUT 2026-09-06 BY jas, THE RULING'S AUTHOR, BECAUSE THAT PREMISE
# IS REFUTED. A budget whose stated reason has been withdrawn is not a loose
# assertion, it is an assertion about nothing: it would absorb a NEW duplicate
# shape -- one the FrameId/Timestamp/position triple does not catch -- in
# perfect silence, which is the exact failure the suppression exists to prevent.
#
# ⇒ O4.4 IS `move == k` AT EVERY DURATION. Any extra is a finding; `move < k` is
# still a finding and still reports its own sign (coalescence, a UIPI discard,
# or two steps colliding on one normalized grid point -- the injector's
# `normalized-collisions=` says which). The measured post-repair readings are
# k=1@300, k=2@800, k=4@100, k=7@10 and k=7@40, all exact, dup-frames 1,5,1,0,1.
#
# ⚠️ `-PostPressMs` IS REPORTED AND NO LONGER GATES ANYTHING. It is kept because
# the drag's duration is the first thing a reader of a failing row wants, and it
# is said here so nobody assumes a parameter in the signature decides the
# verdict. The 160 ms boundary constant and its budget function are DELETED
# rather than left unread: a knob nothing reads still looks live to the next
# reader. The calibration survives as history, in this comment and the README.
function Test-SbMoveCount {
    param([int]$Move, [int]$K, [int]$PostPressMs)
    $extras = $Move - $K
    return @{
        Ok = ($extras -eq 0)
        Extras = $extras
        Text = "move=$Move k=$K extras=$extras post-press=$($PostPressMs)ms"
    }
}

# ⭐ O4.4x -- THE DUPLICATES ARE STILL ARRIVING, AND THIS IS THE ONLY SURFACE
# THAT SAYS SO. Before the repair, the evidence that the phenomenon existed WAS
# the extras count. After it, the extras are zero by construction and the sole
# remaining evidence is `dup-frames=` on the POINTER row. Nothing asserted that
# field's VALUE -- only a lexical case proving `frames=` cannot match inside it.
# `MainWindow.OnPointerMoved`'s own comment says a shell that quietly swallowed
# the repeats "would be indistinguishable from one where they had stopped
# happening, and the next wave would have to rediscover the whole finding";
# this arm is what holds the shell to that.
#
# ⛔ WHAT THIS ARM DOES NOT COVER, SAID ON ITS OWN PASS LINE RATHER THAN HERE
# ONLY: it asserts the count is REPORTED and well-formed, not that it is
# correct. A shell that kept suppressing but stopped INCREMENTING would read
# `dup-frames=0` with `move == k` and pass. That residual hole is diagnostic
# only -- a shell that stopped SUPPRESSING is caught by O4.4, because the
# repeats would reach the core and drive move past k.
function Test-SbDupFramesReported([string]$Row) {
    $raw = Get-SbField $Row 'dup-frames'
    $ok = ($null -ne $raw) -and ($raw -match '^[0-9]+$')
    # ⛔ `Dups`, NOT `Count`. A PowerShell hashtable already HAS a `Count` member
    # (its number of entries) and the .NET member wins over a key of the same
    # name, so `$r.Count` on this result would read 4 -- a small integer from a
    # field called Count, which reads exactly like a measurement. Censused the
    # harness for the class (Count/Keys/Values/Item/IsReadOnly/IsFixedSize/
    # SyncRoot/IsSynchronized as keys): this was the only hit.
    $dups = -1
    $text = 'dup-frames= is ABSENT from the row'
    if ($ok) {
        $dups = [int]$raw
        $text = "dup-frames=$raw"
    } elseif ($null -ne $raw) {
        $text = "dup-frames= is not a count (read '$raw')"
    }
    return @{ Ok = $ok; Dups = $dups; Raw = $raw; Text = $text }
}

# ⭐ O4.4z -- THE FIELD O4.4y READS MUST ITSELF BE REPORTED, AND ITS ABSENCE IS A
# REFUSAL RATHER THAN A SHRUG.
#
# ⛔ THIS IS O4.4x's HOLE ONE LEVEL UP, IN THE ARM THAT CLOSED IT. `raised=` is
# produced by `Canvas.cs` for exactly one consumer, `Test-SbMoveIdentity`, and
# that function answers `Applies = $false` -- NOT RUN -- for a row that does not
# carry the field, so that a build older than the identity is not failed for a
# field it never had. Right for the identity; but `NOT RUN` is tallied apart
# from FAIL and fails no run, so the same tolerance is a switch: delete
# `raised=` from the POINTER row and the arm built to make `dup-frames=`
# checkable stops running, green, in silence.
#
# `dup-frames=` is not exposed that way -- an absent field is a FAIL on O4.4x,
# and the §18 P3 field-removal mutant measured it going red. This function is
# that same guarantee for `raised=`, drawn on the same line O4.4/O4.4x drew: the
# REPORT and the VALUE are two questions, so the report gets an arm that cannot
# be silenced and the identity keeps its tolerance for the value.
#
# ⚠️ `n/a` IS A REPORT. The synthetic control declines the COUNT -- its replay
# is applied inline on the render thread and enters `MainWindow.OnPointerMoved`,
# where the three counters live, never -- and says so in the field. Declining a
# count is not dropping a field, and only the dropped field is a defect here.
function Test-SbRaisedReported([string]$Row) {
    $raw = Get-SbField $Row 'raised'
    $ok = ($null -ne $raw) -and (($raw -match '^[0-9]+$') -or ($raw -eq 'n/a'))
    # `Raw`/`Ok`/`Text`, and deliberately no key named for a hashtable member --
    # `Count`, `Keys`, `Values`, `Item`: the .NET member wins over a key of the
    # same name and returns a small integer that reads like a measurement. That
    # was a live defect in this file on 2026-09-06; the class is censused.
    $text = 'raised= is ABSENT from the row'
    if ($ok) {
        $text = "raised=$raw"
    } elseif ($null -ne $raw) {
        $text = "raised= is neither a count nor the declined marker n/a (read '$raw')"
    }
    return @{ Ok = $ok; Raw = $raw; Text = $text }
}

# ⭐ O4.4y -- THE IDENTITY THAT MAKES `dup-frames=` CHECKABLE
# ---------------------------------------------------------------------------
#
# ⛔ THE HOLE THIS CLOSES IS NAMED ON O4.4x's OWN PASS LINE. That arm asserts
# `dup-frames=` is REPORTED and well-formed, NOT that it is correct: a shell
# that kept suppressing but stopped INCREMENTING reads `dup-frames=0` with
# `move == k` and passes O4.4 and O4.4x both.
#
# ⛔ AND THE ROUTE §18 P4 PROPOSED DOES NOT CLOSE IT -- read, not assumed.
# Counting `SB_TRACE_POINTER`'s `MOVE-DUP` rows against `dup-frames=` is the
# same number twice: in `MainWindow.OnPointerMoved`, `_dupFrames++` and
# `TracePointer("MOVE-DUP", ...)` are ADJACENT STATEMENTS IN ONE BLOCK, so a
# shell that stopped incrementing stops tracing in the same breath. P4's own
# precondition -- "only if the two counts come from different code paths" -- is
# not met, so that arm was NOT built.
#
# What IS built is an identity over THREE counters at THREE sites:
#
#     raised == move + dup-frames
#
# `raised` before the branch, `move` in the applied branch, `dup-frames` in the
# suppressed branch. No single edit keeps the identity true while making a count
# wrong, which is exactly what `MOVE-DUP` could not give.
#
# ⚠️ A ROW WITHOUT `raised=` IS `Applies = $false`, NOT A PASS AND NOT A FAIL.
# The field is newer than the corpus of rows on record, and a bisected build's
# row must not red an arm about a field it never carried -- the same rule the
# completion-row pattern already follows.
function Test-SbMoveIdentity {
    param([string]$Row)
    $raised = Get-SbField $Row 'raised'
    $move   = Get-SbField $Row 'move'
    $dups   = Get-SbField $Row 'dup-frames'
    if ($null -eq $raised) {
        return @{ Applies = $false; Ok = $false
                  Text = 'raised= is absent from the row (a build older than the identity)' }
    }
    # ⛔ `n/a` IS A THIRD ANSWER AND IT IS THE SHELL SAYING SO DELIBERATELY. The
    # three counters live in `MainWindow.OnPointerMoved`; the SB_SYNTH_DRAG
    # control is applied inline on the render thread and enters that method
    # never, so there is no raised count to compare -- not a zero. `Canvas.cs`
    # prints `raised=n/a` on any row whose provenance is not REAL, and this arm
    # declines to judge it rather than reading the absence as a violation.
    # Measured 2026-09-06: printing `0` there made this arm FAIL on the
    # synthetic run, which is the unmeasured-slot-wearing-a-measurement class
    # this seat already repaired once as `STARTUP render-tid=0`.
    if ($raised -notmatch '^[0-9]+$') {
        return @{ Applies = $false; Ok = $false
                  Text = "raised=$raised -- the shell declines the count on this arm (the synthetic control never enters the WinUI handler where the three counters live)" }
    }
    if ($null -eq $move -or $move -notmatch '^[0-9]+$' -or
        $null -eq $dups -or $dups -notmatch '^[0-9]+$') {
        return @{ Applies = $true; Ok = $false
                  Text = "raised=$raised but move= or dup-frames= is missing or not a count" }
    }
    $r = [int]$raised; $m = [int]$move; $d = [int]$dups
    return @{
        Applies = $true
        Ok = ($r -eq ($m + $d))
        Text = "raised=$r move=$m dup-frames=$d -- $m + $d = $($m + $d)"
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
# `Report` puts the last row in the title.
#
# ⛔ AND THE REPAIR MOVED. PR #118 prefixed those three rows BY NAME; that left
# ~20 other verdict-less `Report` callers able to blank the title the moment one
# of them lands last, which is #115's failure mode a third time. The shell now
# folds: `TitleVerdict.Compose` writes `<name> | <verdict>[ fails=N] | <row>`,
# the verdict being the RUN's. So the title's shape changed and THIS FUNCTION
# DID NOT -- it is still the substring rule, in one place a self-test can drive,
# and `harness_selftest.ps1` now drives it against BOTH shapes.
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
