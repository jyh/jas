# sample_liveness.ps1 -- O3's LIVENESS ORACLE, read from SESSION 1.
#
# WHY THIS FILE EXISTS, AND IT IS A MEASURED DEFECT AND NOT A PRECAUTION
# ---------------------------------------------------------------------
# O3.3 used to read `(Get-Process -Id n).Responding` from the session-0 agent
# shell. On kenai, 2026-09-03 (PR #110), that reading was proved VACUOUS -- not
# doubtful, VACUOUS -- against the live `-Stay` window:
#
#     ProcessName      = SbWinUi        SessionId        = 1
#     MainWindowHandle = 0              MainWindowTitle  = ''
#     Responding       = True           my own SessionId = 0
#
#     positive control -- the reading shell, which has NO WINDOW AT ALL:
#     self: MainWindowHandle=0  Responding=True
#
# `Process.Responding` is documented to return TRUE when `MainWindowHandle` is
# zero, and from session 0 the handle of a session-1 window is ALWAYS zero. So
# the oracle returned True for a live app, for a hung app, and for a process with
# no window whatsoever -- and the third case was measured directly. That is why
# O3.C1 (`SB_UI_STALL_MS=20000`, where the oracle MUST say False) could not say
# False: not because the app was live, but because the instrument could not
# convict anything.
#
# ⛔ THE PRECONDITION IS PART OF THE MEASUREMENT, NOT A COMMENT ABOUT IT. Every
# sample records `MainWindowHandle` beside `Responding`, and the caller asserts
# the liveness clause ONLY when the handle was non-zero at every sample. A
# `Responding` read against a zero handle is the vacuous reading this file was
# written to retire, and it must never be able to come back wearing a session-1
# label.
#
# HOW IT GETS INTO SESSION 1: the same interactive scheduled task the launcher,
# the camera and the hand already use. `send_hand.ps1` resolved this app's window
# handle from session 1 without difficulty on the same box on the same night, so
# the mechanism is not in question -- only the shell that was asking.
#
# ⛔ WHAT IT STILL CANNOT DO. `Responding` is a `SendMessageTimeout(WM_NULL)`
# against the window's own thread: it measures that the UI thread PUMPS, and
# nothing else. It is a LIVENESS control, never a residency proof; residency is
# the tid tail on the rows.

[CmdletBinding()]
param(
    # The app process, PID-scoped like everything else in this harness.
    [Parameter(Mandatory = $true)][int]$ProcessId,
    # The sample times, in seconds from THIS script's start. The caller starts it
    # on the shell's own `STALL ARMED` row, so t=0 is the top of the stall.
    [int[]]$At = @(2, 5, 10),
    # Where the readings go. The caller reads this back from session 0.
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Continue'
$log = New-Object System.Collections.Generic.List[string]
$log.Add("sample_liveness: pid=$ProcessId at=$($At -join ',')s out=$Out")
$log.Add("session=$((Get-Process -Id $PID).SessionId)")
$log.Add("started=$((Get-Date).ToString('o'))")

# ⛔ WRITTEN AS THEY ARE TAKEN, NOT AT THE END. The caller may read this file
# while the scene is still running, and a sampler that only writes on completion
# is a sampler whose evidence is lost exactly when the app hangs hard enough to
# make the reading interesting.
function Save-SbSamples {
    $script:log | Set-Content -Path $Out -Encoding utf8
}
Save-SbSamples

$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($t in ($At | Sort-Object)) {
    while ($sw.Elapsed.TotalSeconds -lt $t) { Start-Sleep -Milliseconds 100 }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $p) {
        $log.Add("t=$($t)s handle=GONE responding=GONE elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,2))s")
    } else {
        # The handle FIRST and on its own line's own field: it is the
        # precondition, and a reading that cannot show its precondition is the
        # reading this file replaced.
        $h = $p.MainWindowHandle
        $r = [string]$p.Responding
        $log.Add("t=$($t)s handle=$h responding=$r elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,2))s")
    }
    Save-SbSamples
}

$log.Add("done samples=$($At.Count)")
Save-SbSamples
exit 0
