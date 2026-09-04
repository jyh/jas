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
function Stop-SbAppByPid {
    param(
        [int]$TargetPid,
        [string]$ExpectName,
        [int]$GraceSeconds = 5
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

function Get-SbField([string]$Row, [string]$Name) {
    if ([string]::IsNullOrEmpty($Row)) { return $null }
    $m = [regex]::Match($Row, [regex]::Escape($Name) + '=([^\s]+)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Get-SbPoint([string]$Row, [string]$Name) {
    if ([string]::IsNullOrEmpty($Row)) { return $null }
    $m = [regex]::Match($Row, [regex]::Escape($Name) + '=\(([-0-9.]+),([-0-9.]+)\)')
    if (-not $m.Success) { return $null }
    return @{ X = [double]$m.Groups[1].Value; Y = [double]$m.Groups[2].Value }
}
