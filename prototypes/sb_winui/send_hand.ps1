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
    [int]$SettleMs = 40,
    # SHIFT, HELD (§331 node 5): `press` puts it down before the press, `move`
    # after the press and before the first move (draw_rect_shift.json's form);
    # either way it comes up after the release. The reader refuses any other
    # shape, so this never fakes a per-step modifier.
    [ValidateSet('none', 'press', 'move')][string]$Shift = 'none',
    # ALT, HELD (flask section 338 node 11), exactly as shift is.
    [ValidateSet('none', 'press', 'move')][string]$Alt = 'none',
    # KEYS (§333), delivered AFTER the release as real key events, so the
    # shell's own key route runs. One string, chords split by ';' and keys by
    # '+' (`Delete;ctrl+Z`): a comma list does not survive `-File`.
    [string]$Keys = '',
    # ⛔⛔ THE HIT TARGET'S INSET FROM THE WINDOW CLIENT, IN DIP, MEASURED BY THE
    # SHELL AND PASSED IN -- NEVER GUESSED HERE.
    #
    # This injector aims from `ClientToScreen(0,0)`, which is the WINDOW client:
    # the top of `Grid.Row="0"`, the MenuBar. The pointer handlers live on
    # `Grid.Row="1"`. Measured on kenai 2026-09-11: the target begins 40 DIP
    # down, the aim pressed 54 physical px (36 DIP) from the client top, and
    # 54 < 60 -- so every injected press landed SIX PHYSICAL PIXELS inside the
    # MenuBar and the canvas never saw a gesture (STATUS-flask §54).
    #
    # ⭐ IT IS A PARAMETER AND NOT A CONSTANT ON PURPOSE. A hard-coded menubar
    # height is correct until someone changes the layout and then silently wrong
    # in the same direction. The shell reports `HITTARGET offset-dips=` and the
    # caller forwards it, so the two sides can never drift apart without the row
    # saying so.
    [double]$TargetOffsetXDips = 0,
    [double]$TargetOffsetYDips = 0,
    # PANEL STEPS (jas section 373), delivered LAST through UI Automation: the
    # script's panel steps as ONE base64 string of their JSON
    # (`ConvertTo-SbPanelText`), because a commit's value is typed text and any
    # separator could be inside it. The parsed count is echoed in the receipt.
    [string]$Panels = '',
    # How long a panel step re-reads a control the gesture is still enabling.
    [int]$PanelWaitMs = 3000
)

# Select-SbPanelAction and ConvertFrom-SbPanelText: the panel steps' rules,
# pure and self-tested beside the rest of the harness.
. (Join-Path $PSScriptRoot 'harness_common.ps1')

$ErrorActionPreference = 'Continue'
$log = New-Object System.Collections.Generic.List[string]
$log.Add("send_hand: pid=$ProcessId doc=($DocX,$DocY) delta=($DocDx,$DocDy) k=$Moves shift=$Shift alt=$Alt keys=$Keys")

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

    // ⛔ THE DIAGNOSTIC PAIR FOR A CALL THAT FAILS BY RETURNING false.
    // Windows REFUSES a cross-process foreground change rather than throwing,
    // so the only evidence a refusal ever leaves is the bool below and the
    // window that actually holds the foreground afterwards.
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    // ⛔ WHO OWNS THE PIXEL. Mouse input is delivered by POSITION, not by focus,
    // so a foreground target is not the same claim as a target that will receive
    // the press. `WindowFromPoint` answers the second question and no other call
    // in this injector does.
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT p);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public const byte VK_SHIFT = 0x10;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    public static void Shift(bool down)
    {
        Key(VK_SHIFT, down);
    }

    public static void Key(byte vk, bool down)
    {
        keybd_event(vk, 0, down ? 0u : KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

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
# ⛔⛔ THE RETURN VALUE WAS DISCARDED HERE AND IT IS THE ONLY WITNESS THIS CALL
# EVER PRODUCES. `SetForegroundWindow` is REFUSED -- returning false, never
# throwing -- when the calling process does not hold the foreground privilege,
# which is the ordinary case for one scheduled task aiming at another's window.
#
# Why it matters here and not in the control: `probe_hold.ps1` creates its window
# IN ITS OWN PROCESS and reads arrivals == k in ten of ten configurations, while
# this injector aims at a window owned by a DIFFERENT process and the shell sees
# no press at all (STATUS-flask §48). A refused foreground change explains both
# halves with one mechanism, and it is invisible unless the bool is read.
#
# ⚠️ `foreground-after=` is the second half on purpose: the bool says whether the
# request was ACCEPTED, and the handle says which window actually holds the
# foreground when the events are inserted. They can disagree -- the call can
# return true and a race can take it away -- and a receipt must not collapse them.
$fgOk = [SbHand]::SetForegroundWindow($hwnd)
$fgNow = [SbHand]::GetForegroundWindow()
$log.Add("set-foreground=$fgOk foreground-after=$fgNow target=$hwnd foreground-is-target=$($fgNow -eq $hwnd)")

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

# document DIP -> canvas physical px -> screen px.
#
# ⛔ THE COMMENT THAT USED TO SIT HERE SAID "the canvas is Grid.Row 0 and starts
# at the client origin", AND IT WAS THE DEFECT, WRITTEN DOWN. It was true before
# W4 added the MenuBar on 09/08; after it the canvas is `Grid.Row="1"` and starts
# `$TargetOffsetYDips` BELOW the client origin. The assumption outlived the layout
# it described and nothing re-read it -- so the aim stayed 6 px high and every
# real gesture was refused for three days while the synthetic arm passed.
$px0 = $origin.X + (($DocX + $TargetOffsetXDips) * $scale)
$py0 = $origin.Y + (($DocY + $TargetOffsetYDips) * $scale)
$px1 = $px0 + ($DocDx * $scale)
$py1 = $py0 + ($DocDy * $scale)
$log.Add("press-screen=($px0,$py0) release-screen=($px1,$py1) target-offset-dips=($TargetOffsetXDips,$TargetOffsetYDips)")

# ⛔⛔ WHO ACTUALLY OWNS THE PRESS PIXEL. Foreground is NOT the same claim:
# mouse input is routed by POSITION. STATUS-flask §48 measured that this
# injector inserts 10/10 events into a window that IS foreground and IS the
# target, and the shell still sees no press -- so the next thing that can be
# false is that the pixel under the press belongs to some other window.
#
# GA_ROOT (2) is reported beside the raw handle because `WindowFromPoint`
# returns the deepest CHILD at that point, and a XAML island is a child HWND:
# a raw handle that differs from the target is EXPECTED and proves nothing,
# while a ROOT that differs is the finding.
$wfpPoint = New-Object 'SbHand+POINT'
$wfpPoint.X = [int]$px0
$wfpPoint.Y = [int]$py0
$wfpRaw = [SbHand]::WindowFromPoint($wfpPoint)
$wfpRoot = if ($wfpRaw -ne [IntPtr]::Zero) { [SbHand]::GetAncestor($wfpRaw, 2) } else { [IntPtr]::Zero }
$log.Add("window-at-press raw=$wfpRaw root=$wfpRoot target=$hwnd root-is-target=$($wfpRoot -eq $hwnd)")
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
# k = 0 is a CLICK (flask section 348): press and release at one point, no
# move, because SendInput emits no motion for a move that does not move.
# The reader admits k = 0 only when press == release.
if ($Moves -lt 0) { $Moves = 0 }

$n = ConvertTo-Normalized $px0 $py0
$sent += [SbHand]::Send($moveFlags, $n[0], $n[1])
Start-Sleep -Milliseconds $SettleMs

# ⛔ A SHIFT LEFT DOWN WOULD MODIFY EVERY LATER INPUT ON THE DESKTOP, so the
# key-up is in a `finally` that runs whatever happens between.
$shiftDown = $false
$altDown = $false
try {
if ($Shift -eq 'press') { [SbHand]::Shift($true); $shiftDown = $true; Start-Sleep -Milliseconds $SettleMs }
if ($Alt -eq 'press') { [SbHand]::Key(0x12, $true); $altDown = $true; Start-Sleep -Milliseconds $SettleMs }

# The press, AT THE CURSOR. No MOVE, no ABSOLUTE: dx/dy are ignored for motion.
$heldSw = [System.Diagnostics.Stopwatch]::StartNew()
$sent += [SbHand]::Send([SbHand]::LEFTDOWN, 0, 0)
Start-Sleep -Milliseconds $SettleMs
if ($Shift -eq 'move') { [SbHand]::Shift($true); $shiftDown = $true; Start-Sleep -Milliseconds $SettleMs }
if ($Alt -eq 'move') { [SbHand]::Key(0x12, $true); $altDown = $true; Start-Sleep -Milliseconds $SettleMs }

# ⭐ THE DRAG'S DURATION IS A RECEIPT FIELD NOW, BECAUSE IT IS THE VARIABLE THE
# `move != k` DEFECT TURNED OUT TO BE ABOUT. Measured on kenai 2026-09-04 across
# 13 configurations with `-SettleMs` varied: the window sees one EXTRA arrival
# per few hundred ms while the button is held, and none at all under ~160 ms --
# k=7 at 10 ms reads 7, k=1 at 300 ms reads 2. Without this field the harness
# would have to RECOMPUTE the duration from k and the settle, which is the same
# number derived by a second party instead of measured by the one that sent the
# events.
#
# ⛔ `post-press-ms` IS FIRST-MOVE-TO-RELEASE, and that is the column the
# boundary was calibrated on (k x settle). `button-held-ms` is press-to-release
# and is a NOTE: it is the physically meaningful window, it is one settle longer,
# and quoting one where the other was calibrated would move the budget by a step.
$dragSw = [System.Diagnostics.Stopwatch]::StartNew()

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
$dragSw.Stop()
$sent += [SbHand]::Send([SbHand]::LEFTUP, 0, 0)
$heldSw.Stop()
} finally {
    if ($altDown) { Start-Sleep -Milliseconds $SettleMs; [SbHand]::Key(0x12, $false) }
    if ($shiftDown) { Start-Sleep -Milliseconds $SettleMs; [SbHand]::Shift($false) }
}
# THE KEYS, after the gesture: each chord's modifiers down, the key down and
# up, the modifiers up in reverse. The reader admits only the names mapped here.
$keyEvents = 0
$chords = @($Keys -split ';' | Where-Object { $_ -ne '' })
foreach ($chord in $chords) {
    $parts = @($chord -split '\+')
    $mods = @($parts | Select-Object -First ($parts.Count - 1) | ForEach-Object {
        switch ($_) { 'ctrl' { [byte]0x11 } 'shift' { [byte]0x10 } 'alt' { [byte]0x12 } default { throw "unknown modifier $_" } }
    })
    $name = $parts[$parts.Count - 1]
    $vk = switch -CaseSensitive -Regex ($name) {
        '^Delete$' { [byte]0x2E } '^Backspace$' { [byte]0x08 } '^Enter$' { [byte]0x0D }
        '^Escape$' { [byte]0x1B } '^Tab$' { [byte]0x09 }
        '^[A-Za-z0-9]$' { [byte][char]$name.ToUpperInvariant() }
        default { throw "no virtual key for $name" }
    }
    Start-Sleep -Milliseconds $SettleMs
    foreach ($m in $mods) { [SbHand]::Key($m, $true); $keyEvents++ }
    [SbHand]::Key($vk, $true); [SbHand]::Key($vk, $false); $keyEvents += 2
    [array]::Reverse($mods)
    foreach ($m in $mods) { [SbHand]::Key($m, $false); $keyEvents++ }
}
$log.Add("keys=$Keys chords=$($chords.Count) key-events=$keyEvents")

# THE PANEL STEPS (jas section 373), last, through UI Automation. Each finds
# the panel by AutomationId (the panel content id, `PanelHost`), the widget by
# AutomationId inside it (`PaneView` sets the widget id on every leaf that has
# one), and acts through the pattern its control exposes, as a screen reader
# or a person would: Invoke/Toggle/SelectionItem for a click, Value for a
# commit followed by Enter, which is how a person commits a text field here.
# `Select-SbPanelAction` (harness_common.ps1) decides the action or the
# refusal; every refusal has a self-test arm. A refusal ends the hand with
# `PANEL REFUSED` in the receipt and exit 6, and nothing after it is sent.
$panelSteps = @(ConvertFrom-SbPanelText $Panels)
$log.Add("late-steps=$($panelSteps.Count) panels=$(@($panelSteps | Where-Object { $_.panel }).Count) menus=$(@($panelSteps | Where-Object { $_.menu }).Count) parsed-from-bytes=$($Panels.Length)")
if ($panelSteps.Count -gt 0) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $AE = [System.Windows.Automation.AutomationElement]
    $tree = [System.Windows.Automation.TreeScope]
    $byPid = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)
    $window = $AE::RootElement.FindFirst($tree::Children, $byPid)
    # A refusal ends the hand: written to the receipt by name, exit 6.
    function Stop-SbPanelHand([string]$Why) {
        $log.Add("PANEL REFUSED: $Why")
        $log | Set-Content -Path $Out -Encoding utf8
        exit 6
    }
    # A CHOOSE (jas section 381), for a select's commit and for opening a panel
    # in the pane's selector: open the list as a person does, find the item
    # whose AutomationId is the VALUE (the shell sets it), select it, and close
    # the list if it is still open. The items appear on the open, so they are
    # re-read for PanelWaitMs. Returns null, or the refusal.
    function Invoke-SbChoose($List, [string]$Value, [string]$Widget, [string]$Tag) {
        $ec = $List.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $ec.Expand()
        $byValue = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Value)
        $isw = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $items = $List.FindAll($tree::Descendants, $byValue)
            if ($items.Count -eq 0) { Start-Sleep -Milliseconds 100 }
        } while ($items.Count -eq 0 -and $isw.ElapsedMilliseconds -lt $PanelWaitMs)
        $itemPats = if ($items.Count -eq 1) { @($items[0].GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) } else { @() }
        $choice = Select-SbChoiceItem -Widget $Widget -Value $Value -ItemCount $items.Count -Patterns $itemPats
        $log.Add("$Tag choose items=$($items.Count) item-patterns=[$($itemPats -join ',')] waited-ms=$($isw.ElapsedMilliseconds)")
        if ($null -ne $choice.Refusal) {
            try { $ec.Collapse() } catch { }
            return $choice.Refusal
        }
        $items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Start-Sleep -Milliseconds $SettleMs
        $state = $ec.Current.ExpandCollapseState
        if ($state -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed) { $ec.Collapse() }
        $log.Add("$Tag chose '$Value' list-after-select=$state")
        return $null
    }
    function Find-SbById($Under, [string]$Id) {
        $Under.FindAll($tree::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Id)))
    }
    if ($null -eq $window) { Stop-SbPanelHand "no top-level UI Automation element for pid $ProcessId" }

    # OPEN THE PANEL (jas section 383) as a person does: nothing when it is
    # shown, else choose it in the pane's selector, `PanePicker`, whose items
    # carry the panel content ids, and wait for its controls to be built. The
    # reader admits one panel per script, so this runs once.
    $firstPanel = @($panelSteps | Where-Object { $_.panel }) | Select-Object -First 1
    $want = if ($null -ne $firstPanel) { "$($firstPanel.panel)" } else { '' }
    $openTag = "open $want"
    if ($want.Length -gt 0) {
        $shown = Find-SbById $window $want
        $pickers = Find-SbById $window 'PanePicker'
        $pickerPats = if ($pickers.Count -eq 1) { @($pickers[0].GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) } else { @() }
        $open = Select-SbPanelOpen -Panel $want -PanelCount $shown.Count -PickerCount $pickers.Count -PickerPatterns $pickerPats
        $log.Add("$openTag shown=$($shown.Count) pickers=$($pickers.Count) action=$(if ($open.Action) { $open.Action } else { 'refused' })")
        if ($null -ne $open.Refusal) { Stop-SbPanelHand "$openTag -- $($open.Refusal)" }
        if ($open.Action -eq 'Choose') {
            $why = Invoke-SbChoose -List $pickers[0] -Value $want -Widget 'PanePicker' -Tag $openTag
            if ($null -ne $why) { Stop-SbPanelHand "$openTag -- $why" }
            $osw = [System.Diagnostics.Stopwatch]::StartNew()
            do {
                $shown = Find-SbById $window $want
                if ($shown.Count -eq 0) { Start-Sleep -Milliseconds 100 }
            } while ($shown.Count -eq 0 -and $osw.ElapsedMilliseconds -lt $PanelWaitMs)
            $log.Add("$openTag panel-appeared=$($shown.Count -eq 1) waited-ms=$($osw.ElapsedMilliseconds)")
            if ($shown.Count -ne 1) { Stop-SbPanelHand "$openTag -- panel '$want' was chosen in PanePicker and $($shown.Count) such panels were shown after $($PanelWaitMs) ms" }
        }
    }
    $n = 0
    foreach ($ps in $panelSteps) {
        $n++
        # A MENU STEP (jas sections 389/392): open each top menu of the menubar
        # in turn, as a person looks for an item, until one shows an item whose
        # AutomationId is the step's node id; then Invoke it. The flyout is a
        # popup, so its items are searched under the window, not the top item.
        if ($ps.menu) {
            $mtag = "step $n menu:$($ps.menu)"
            $byClass = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'Microsoft.UI.Xaml.Controls.MenuBarItem')
            $tops = $window.FindAll($tree::Descendants, $byClass)
            $hits = $null; $openTop = $null; $looked = @()
            foreach ($top in $tops) {
                $tec = $top.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                $tec.Expand()
                $looked += "$($top.Current.Name)"
                $msw = [System.Diagnostics.Stopwatch]::StartNew()
                do {
                    $hits = Find-SbById $window "$($ps.menu)"
                    if ($hits.Count -eq 0) { Start-Sleep -Milliseconds 100 }
                } while ($hits.Count -eq 0 -and $msw.ElapsedMilliseconds -lt 600)
                if ($hits.Count -gt 0) { $openTop = $tec; break }
                $tec.Collapse()
                Start-Sleep -Milliseconds $SettleMs
            }
            $found = if ($null -eq $hits) { 0 } else { $hits.Count }
            $menuEnabled = $found -eq 1 -and $hits[0].Current.IsEnabled
            $menuPats = if ($found -eq 1) { @($hits[0].GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) } else { @() }
            $mpick = Select-SbMenuItem -Item "$($ps.menu)" -Found $found -Enabled $menuEnabled -Patterns $menuPats
            $log.Add("$mtag tops=$($tops.Count) looked-in=[$($looked -join ',')] found=$found enabled=$menuEnabled patterns=[$($menuPats -join ',')]")
            if ($null -ne $mpick.Refusal) {
                if ($null -ne $openTop) { try { $openTop.Collapse() } catch { } }
                Stop-SbPanelHand "$mtag -- $($mpick.Refusal)"
            }
            Start-Sleep -Milliseconds $SettleMs
            $hits[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            $log.Add("MENU SENT: $mtag action=Invoke")
            continue
        }
        $tag = "step $n $($ps.panel)/$($ps.widget):$($ps.event)"
        # A pane redraws on the UI thread after the gesture lands, so a control
        # the gesture enables (Align once two things are selected) may still
        # read disabled for a moment. It is re-read for up to PanelWaitMs; the
        # wait is written down, and a control still disabled then is refused.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $panelHits = $window.FindAll($tree::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, "$($ps.panel)")))
            $widgetHits = $null; $el = $null; $enabled = $false; $ctype = ''; $pats = @()
            if ($panelHits.Count -eq 1) {
                $widgetHits = $panelHits[0].FindAll($tree::Descendants,
                    (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, "$($ps.widget)")))
                if ($widgetHits.Count -eq 1) {
                    $el = $widgetHits[0]
                    $enabled = $el.Current.IsEnabled
                    $ctype = $el.Current.ControlType.ProgrammaticName
                    $pats = @($el.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName })
                }
            }
            $pick = Select-SbPanelAction -Panel "$($ps.panel)" -Widget "$($ps.widget)" -Event "$($ps.event)" `
                -PanelCount $panelHits.Count -WidgetCount $(if ($null -eq $widgetHits) { 0 } else { $widgetHits.Count }) `
                -Enabled $enabled -ControlType $ctype -Patterns $pats
            $settled = $null -eq $pick.Refusal -or $panelHits.Count -ne 1 -or $null -eq $widgetHits -or $widgetHits.Count -ne 1 -or $enabled
            if (-not $settled) { Start-Sleep -Milliseconds 100 }
        } while (-not $settled -and $sw.ElapsedMilliseconds -lt $PanelWaitMs)
        $log.Add("$tag panel-hits=$($panelHits.Count) widget-hits=$(if ($null -eq $widgetHits) { 0 } else { $widgetHits.Count }) type=$ctype enabled=$enabled patterns=[$($pats -join ',')] waited-ms=$($sw.ElapsedMilliseconds)")
        if ($null -ne $pick.Refusal) { Stop-SbPanelHand "$tag -- $($pick.Refusal)" }
        Start-Sleep -Milliseconds $SettleMs
        switch ($pick.Action) {
            'Invoke' { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
            'Toggle' { $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() }
            'SelectionItem' { $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() }
            'Choose' {
                $why = Invoke-SbChoose -List $el -Value "$($ps.value)" -Widget "$($ps.widget)" -Tag $tag
                if ($null -ne $why) { Stop-SbPanelHand "$tag -- $why" }
            }
            'Value' {
                $el.SetFocus()
                $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("$($ps.value)")
                Start-Sleep -Milliseconds $SettleMs
                [SbHand]::Key(0x0D, $true); [SbHand]::Key(0x0D, $false)
            }
        }
        $log.Add("PANEL SENT: $tag action=$($pick.Action)")
    }
}
$log.Add("alt=$Alt alt-down=$(if ($Alt -eq 'none') { 'never' } else { "before-$Alt" }) alt-up=$(if ($altDown) { 'after-release' } else { 'never' })")
$log.Add("shift=$Shift shift-down=$(if ($Shift -eq 'none') { 'never' } else { "before-$Shift" }) shift-up=$(if ($shiftDown) { 'after-release' } else { 'never' })")

$log.Add("positioning-move=1 post-press-moves=$Moves normalized-collisions=$collisions button-events-carry-a-position=no")
$log.Add(("post-press-ms={0} button-held-ms={1} settle-ms={2}" -f
          [int]$dragSw.Elapsed.TotalMilliseconds, [int]$heldSw.Elapsed.TotalMilliseconds, $SettleMs))
$log.Add("events-inserted=$sent expected=$($Moves + 3)")
$log.Add("NOTE: SendInput returning the expected count proves the events were INSERTED, not that they ARRIVED. UIPI discards are invisible here by design; the shell's counters are the only oracle for arrival.")
$log.Add("NOTE: post-press-moves is what THIS injector sent, and as of 2026-09-06 it is also what the shell counts. The `move != k` extras are IDENTIFIED: they were RE-DELIVERIES of a pointer frame the shell had already applied -- same FrameId, same Timestamp, same position, raised again by XAML while the contact sat still, so they multiplied with the idle gap after each move (settle 10ms: 0 extras; 40/100/300ms: 1; 800ms: 5). NOT a system arrival: probe_hold.ps1 drives a bare Win32 window with THIS construction at these same configurations and reads arrivals == k exactly, in both input stacks. The shell now suppresses a repeated frame and reports the count as `dup-frames=` on its POINTER row. move<k with normalized-collisions=0 still means the window coalesced despite MOVE_NOCOALESCE.")
$log | Set-Content -Path $Out -Encoding utf8
if ($sent -ne ($Moves + 3)) { exit 5 }
exit 0
