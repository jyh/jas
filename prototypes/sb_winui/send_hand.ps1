# send_hand.ps1 -- O4's HAND. A real mouse gesture, injected in SESSION 1.
#
# WHAT IT IS FOR
# --------------
# O4 asks for a receipt that only a REAL `PointerPressed` / `PointerMoved` /
# `PointerReleased` can produce. The shell's counters are incremented ONLY inside
# the WinUI handlers, so a row that says `pointer=REAL press=1 move=k release=1`
# is a claim about the window's own input stack. Nothing in session 0 can make
# that happen: the desktop is session 1, and a session-0 process cannot even
# enumerate its windows. So this script runs AS A SCHEDULED TASK under the
# interactive principal -- the same mechanism `verify_window.ps1` already uses to
# launch the app and to take the DXGI capture.
#
# ⛔ IT IS AIMED FROM OUTSIDE, AND THAT IS THE DISCRIMINATOR. The point and the
# delta are PARAMETERS, chosen by the harness from `sb-doc-before.json` -- a
# point the shell provably cannot compute, because it is derived from a file the
# shell wrote and never read back. A hardwired gesture could not follow a varied
# `k` or a harness-chosen element, which is exactly what separates this from the
# synthetic marquee that emitted `press=1 move=2 release=1` for its whole life
# without a pointer ever existing.
#
# ⛔ UIPI FAILURE IS UNDETECTABLE HERE. `SendInput` returns the number of events
# inserted; per its own documentation it returns success and the events are
# silently discarded when the target window belongs to a higher-integrity
# process. So this script's receipt is EVIDENCE OF SENDING, never of arrival --
# arrival is the SHELL's counters and nothing else. When the counters read 0 the
# scene is `NOT RUN: hand refused`, never a pass, and never a synthetic receipt
# wearing REAL.
#
# COORDINATES
# -----------
# The caller passes DOCUMENT coordinates (DIPs -- the shell divides physical
# pixels by the composition scale before the core sees them, `ffi_pointer.rs`,
# so a document unit IS a DIP in this shell, which has no pan and no zoom this
# wave). This script converts:
#
#     canvas physical px = document DIP * (GetDpiForWindow / 96)
#     screen px          = ClientToScreen(0,0) + canvas physical px
#
# The second line holds because the `SwapChainPanel` is `Grid.Row="0"` of a
# two-row grid whose second row is `Auto` (the status line), so the canvas starts
# at the client origin. It is stated here because it is an assumption about
# `MainWindow.xaml` that this file cannot check.
#
# ⛔ THERE IS NO `-Scale` PARAMETER HERE AND THERE NEVER WAS, WHICH IS WHY
# `verify_window.ps1` NO LONGER HAS ONE EITHER. The factor comes from
# `GetDpiForWindow` and from nothing else, so a caller's `-Scale 1.5` reached this
# gesture in no way at all -- measured on kenai 2026-09-03 (PR #110), where a run
# driven with it read identically to one without it, down to the digit.
#
# ⚠️ AND `GetDpiForWindow` IS HONEST ABOUT A DISHONEST WINDOW. On a DPI-UNAWARE
# process Windows bitmap-virtualises the window and returns 96 for it correctly,
# so this script computes `scale = 1` correctly and the gesture lands at 2/3 of
# the asked point on a 150% display -- measured on kenai before the shell wave
# gave the app a manifest. Nothing here can detect that; the two numbers that CAN
# are `client=` below and the shell's own `surface=`, and O4.8 compares them.
# ⛔ WHAT THAT COMPARISON EXPECTS DEPENDS ON THE SHELL: with the surface sized in
# DIPs the ratio WAS the scale, and with it derived in physical pixels the two are
# one measurement and the ratio is 1.0. The assertion reads the shell's `STARTUP`
# row to know which, and never guesses.

[CmdletBinding()]
param(
    # The app process to aim at. PID-scoped, like everything else in this
    # harness: the window is found BY OWNER, never by title, so a stale window
    # from an earlier run cannot receive this gesture.
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][double]$DocX,
    [Parameter(Mandatory = $true)][double]$DocY,
    [Parameter(Mandatory = $true)][double]$DocDx,
    [Parameter(Mandatory = $true)][double]$DocDy,
    # k, VARIED by the caller (O4 asks for 2, then 7). The shell's `move=<n>`
    # must equal it.
    [int]$Moves = 2,
    # Where the receipt goes. The caller reads it back from session 0.
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$SettleMs = 40
)

$ErrorActionPreference = 'Continue'
$log = New-Object System.Collections.Generic.List[string]
$log.Add("send_hand: pid=$ProcessId doc=($DocX,$DocY) delta=($DocDx,$DocDy) k=$Moves")

$source = @'
using System;
using System.Runtime.InteropServices;

public static class SbHand
{
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    // Only the MOUSEINPUT arm is declared. It is the LARGEST arm of the real
    // union, so the struct size this produces (40 bytes on x64) is the size
    // SendInput expects; a smaller arm would have made cbSize wrong.
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);

    // The constant lives on THIS side of the boundary. Casting -4 to an IntPtr
    // from PowerShell works on some hosts and throws on others, and a harness
    // that throws while setting up its coordinate space fails in the one place
    // where the failure looks like a miss.
    public static IntPtr SetDpiAwarenessV2()
    {
        return SetProcessDpiAwarenessContext(new IntPtr(-4));
    }

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public const uint MOVE = 0x0001;
    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;
    public const uint MOVE_NOCOALESCE = 0x2000;
    public const uint VIRTUALDESK = 0x4000;
    public const uint ABSOLUTE = 0x8000;

    public static uint Send(uint flags, int nx, int ny)
    {
        INPUT[] one = new INPUT[1];
        one[0].type = 0; // INPUT_MOUSE
        one[0].mi.dx = nx;
        one[0].mi.dy = ny;
        one[0].mi.dwFlags = flags;
        return SendInput(1, one, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

try {
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
} catch {
    $log.Add("FAIL: Add-Type: $($_.Exception.Message)")
    $log | Set-Content -Path $Out -Encoding utf8
    exit 3
}

# ⛔ PER-MONITOR-V2 AWARENESS, FIRST. Without it Windows virtualises this
# process's coordinates on a scaled display: `ClientToScreen` hands back numbers
# in a made-up space and every point below lands somewhere else. It is set
# before any window is measured, and the result is RECORDED -- a failure here
# does not stop the run, it explains the miss that follows.
try {
    $ctx = [SbHand]::SetDpiAwarenessV2()  # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    $log.Add("dpi-awareness: SetProcessDpiAwarenessContext(-4) -> $ctx (0 means it was already set)")
} catch {
    $log.Add("dpi-awareness: NOT SET -- $($_.Exception.Message)")
}

$log.Add("session=$((Get-Process -Id $PID).SessionId)")

# THE WINDOW IS FOUND BY OWNER. `Get-Process -Id n` from session 1 reports a real
# MainWindowHandle (the 0 this harness's README warns about is a SESSION-0
# reading, and this script is not in session 0).
$proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
if ($null -eq $proc) {
    $log.Add("NOT RUN: hand refused (no process $ProcessId)")
    $log | Set-Content -Path $Out -Encoding utf8
    exit 4
}
$hwnd = $proc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) {
    $log.Add("NOT RUN: hand refused (process $ProcessId has no MainWindowHandle in this session)")
    $log | Set-Content -Path $Out -Encoding utf8
    exit 4
}
$log.Add("hwnd=$hwnd title='$($proc.MainWindowTitle)'")
[void][SbHand]::SetForegroundWindow($hwnd)

$rc = New-Object 'SbHand+RECT'
if (-not [SbHand]::GetClientRect($hwnd, [ref]$rc)) {
    $log.Add("NOT RUN: hand refused (GetClientRect failed)")
    $log | Set-Content -Path $Out -Encoding utf8
    exit 4
}
$origin = New-Object 'SbHand+POINT'
$origin.X = 0
$origin.Y = 0
if (-not [SbHand]::ClientToScreen($hwnd, [ref]$origin)) {
    $log.Add("NOT RUN: hand refused (ClientToScreen failed)")
    $log | Set-Content -Path $Out -Encoding utf8
    exit 4
}
$dpi = [SbHand]::GetDpiForWindow($hwnd)
if ($dpi -le 0) { $dpi = 96 }
$scale = $dpi / 96.0
$log.Add("client=$($rc.Right)x$($rc.Bottom) origin=($($origin.X),$($origin.Y)) dpi=$dpi scale=$scale")

# document DIP -> canvas physical px -> screen px. The canvas is Grid.Row 0 and
# starts at the client origin (see the header).
$px0 = $origin.X + ($DocX * $scale)
$py0 = $origin.Y + ($DocY * $scale)
$px1 = $px0 + ($DocDx * $scale)
$py1 = $py0 + ($DocDy * $scale)
$log.Add("press-screen=($px0,$py0) release-screen=($px1,$py1)")
$log.Add("canvas-physical press=($($DocX * $scale),$($DocY * $scale)) delta=($($DocDx * $scale),$($DocDy * $scale))")

# SM_XVIRTUALSCREEN 76, SM_YVIRTUALSCREEN 77, SM_CXVIRTUALSCREEN 78,
# SM_CYVIRTUALSCREEN 79. MOUSEEVENTF_VIRTUALDESK normalises over the whole
# virtual desktop, which is the only correct denominator on a multi-monitor box.
$vx = [SbHand]::GetSystemMetrics(76)
$vy = [SbHand]::GetSystemMetrics(77)
$vw = [SbHand]::GetSystemMetrics(78)
$vh = [SbHand]::GetSystemMetrics(79)
if ($vw -le 1) { $vw = 2 }
if ($vh -le 1) { $vh = 2 }
$log.Add("virtual-desktop=($vx,$vy,$vw,$vh)")

function ConvertTo-Normalized([double]$x, [double]$y) {
    $nx = [int][math]::Round((($x - $vx) * 65535.0) / ($vw - 1))
    $ny = [int][math]::Round((($y - $vy) * 65535.0) / ($vh - 1))
    return @($nx, $ny)
}

$moveFlags = [SbHand]::MOVE -bor [SbHand]::ABSOLUTE -bor [SbHand]::VIRTUALDESK -bor [SbHand]::MOVE_NOCOALESCE
$sent = 0

# ---------------------------------------------------------------------------
# THE GESTURE: position, press, EXACTLY k moves, release
# ---------------------------------------------------------------------------
#
# ⛔ THE BUTTON EVENTS NO LONGER CARRY A POSITION, AND THAT IS THE REPAIR.
# Measured on kenai 2026-09-03 (PR #110): at k=7 the shell counted `move=8`
# TWICE, while at k=2 it counted exactly 2. The seam control drove the same
# element and the same delta through the C ABI and reported `move=7`, so the
# extra arrival is the INJECTOR's, not the app's.
#
# The shell counts a move ONLY between the press and the release
# (`MainWindow.xaml.cs`'s `OnPointerMoved` returns early unless `_gestureOpen`, and
# `OnPointerPressed` zeroes `_moveCount`), so the pre-press positioning move
# cannot be one of the eight. What CAN be is a button event carrying absolute
# coordinates: `SendInput` applies a position given with `MOUSEEVENTF_ABSOLUTE`
# and the window sees the motion, so a `LEFTDOWN`/`LEFTUP` at a point is a move
# AND a click. Both button events used to carry one. They no longer do: with no
# `MOUSEEVENTF_MOVE` and no `MOUSEEVENTF_ABSOLUTE` the button occurs AT THE
# CURSOR, which is exactly where the preceding move already put it.
#
# ⚠️ THIS IS A CANDIDATE MECHANISM, NOT A PROVEN ONE. Nothing here has been
# executed on the box, and the k=2 run counted 2 under the SAME construction, so
# the mechanism does not explain both readings on its own. What this change does
# guarantee is that the injector emits exactly k events capable of being counted
# as moves after the press -- so a `move != k` reading now belongs to the app or
# to the window manager and cannot be blamed on the instrument. The receipt below
# carries the counts needed to tell those apart.
if ($Moves -lt 1) { $Moves = 1 }

$n = ConvertTo-Normalized $px0 $py0
$sent += [SbHand]::Send($moveFlags, $n[0], $n[1])
Start-Sleep -Milliseconds $SettleMs

# The press, AT THE CURSOR. No MOVE, no ABSOLUTE: dx/dy are ignored for motion.
$sent += [SbHand]::Send([SbHand]::LEFTDOWN, 0, 0)
Start-Sleep -Milliseconds $SettleMs

# k MOVES ALONG THE SEGMENT, the k-th landing exactly on the release point, and
# NONE of them at the press point (i runs from 1, so t is never 0).
#
# ⛔ EVERY STEP CARRIES MOVE_NOCOALESCE. Without it Windows is free to merge
# adjacent moves and the shell's `move=<n>` would read below k for a reason that
# has nothing to do with the app -- an instrument defect wearing an application
# failure's clothes.
#
# ⛔ AND THE NORMALISED POINTS ARE CHECKED FOR COLLISION. `ConvertTo-Normalized`
# rounds into a 0..65535 grid over the virtual desktop; on a 3840-wide desktop one
# grid step is ~1/17 of a pixel, but a SMALL delta divided by a LARGE k can still
# put two consecutive steps on the same grid point, and Windows emits no motion
# for a move that does not move. That would read as coalescence -- `move < k` --
# and be blamed on the app. It is counted and reported instead.
$prev = $n
$collisions = 0
for ($i = 1; $i -le $Moves; $i++) {
    $t = $i / [double]$Moves
    $mx = $px0 + (($px1 - $px0) * $t)
    $my = $py0 + (($py1 - $py0) * $t)
    $nm = ConvertTo-Normalized $mx $my
    if ($nm[0] -eq $prev[0] -and $nm[1] -eq $prev[1]) { $collisions++ }
    $prev = $nm
    $sent += [SbHand]::Send($moveFlags, $nm[0], $nm[1])
    Start-Sleep -Milliseconds $SettleMs
}

# The release, AT THE CURSOR -- which the k-th move has already put on the
# release point. A positioned LEFTUP would be a (k+1)-th motion.
$sent += [SbHand]::Send([SbHand]::LEFTUP, 0, 0)

$log.Add("positioning-move=1 post-press-moves=$Moves normalized-collisions=$collisions button-events-carry-a-position=no")
$log.Add("events-inserted=$sent expected=$($Moves + 3)")
$log.Add("NOTE: SendInput returning the expected count proves the events were INSERTED, not that they ARRIVED. UIPI discards are invisible here by design; the shell's counters are the only oracle for arrival.")
$log.Add("NOTE: post-press-moves is what the shell's move= must equal. move=k+1 means the window saw an arrival this injector did not send (a motion synthesised on capture, or a stray real mouse); move<k with normalized-collisions=0 means the window coalesced despite MOVE_NOCOALESCE.")
$log | Set-Content -Path $Out -Encoding utf8
if ($sent -ne ($Moves + 3)) { exit 5 }
exit 0
