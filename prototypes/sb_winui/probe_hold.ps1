# probe_hold.ps1 -- IDENTIFY the `move != k` source. It is characterised; this
# names it.
#
# WHAT IS BEING IDENTIFIED
# ------------------------
# PR #117 measured, over 13 configurations, that the S-B shell counts one EXTRA
# `PointerMoved` per few hundred ms while the button is held, and none at all
# under ~160 ms. The reading reverses BOTH ways in k and in duration (k=7 at
# 10 ms reads 7; k=4 at 100 ms reads 5; k=1 at 300 ms reads 2; k=2 at 800 ms
# reads 4), so the source is PERIODIC and has nothing to do with k. #117 said so
# in its own words -- "characterised, not identified" -- and #118 priced the
# extras rather than explaining them.
#
# ⛔ AN EXPLANATION IS NOT AN IDENTIFICATION. Reading a candidate mechanism out
# of the platform's documentation would produce a paragraph, not a finding: #115
# already shipped one candidate (the positioned button events) that #117 then
# refuted by measurement. So this probe MEASURES, and it is built to make the
# defect reverse in every direction that could be the cause rather than to
# confirm one hypothesis.
#
# THE THREE KNOBS, AND WHY EACH IS A CONFOUND AND NOT A HYPOTHESIS
# ----------------------------------------------------------------
#   1. `-HoldMs`   -- how long the state is held with ZERO injected moves.
#                     If arrivals scale with duration, the source is a clock.
#                     If they do not, everything #117 measured was about k after
#                     all and this whole reading is wrong.
#   2. `-Press`    -- whether the button is DOWN for that hold. The shell only
#                     counts moves between press and release, so the button is
#                     confounded with the counting window in every reading on
#                     record. Holding the same duration with the button UP
#                     separates them for the first time.
#   3. `-Pointer`  -- whether this process reads the pointer stack
#                     (`EnableMouseInPointer` -> `WM_POINTERUPDATE`) or the
#                     legacy mouse stack (`WM_MOUSEMOVE`). WinUI 3 is a pointer
#                     app; every reading on record came through the pointer
#                     stack, so nothing has ever asked whether the extras are
#                     the pointer stack's doing or the mouse's.
#
# ⭐ AND THE WINDOW HERE IS A BARE WIN32 ONE, which is the fourth discriminator
# and the reason this is a new program rather than another sitting. The shell is
# WinUI 3 over a SwapChainPanel with a render thread and a compositor. If a
# 40-line Win32 window with no XAML, no swapchain and no compositor sees the same
# extras, the source is BELOW the app; if it does not, the source is the app's
# own input layer and the platform is innocent.
#
# ⛔ IT MUST RUN IN SESSION 1 AND IT SAYS SO. Injected input goes to the
# interactive desktop; a session-0 run would create a window nobody can point at
# and count zero of everything, which reads exactly like a negative result. The
# worker refuses to report a count from session 0, and the driver launches it
# through the same interactive scheduled task the rest of this harness uses.
#
#   powershell -File probe_hold.ps1 -OutDir <dir>            # the sweep
#   powershell -File probe_hold.ps1 -Worker -Out <file> ...  # one run (session 1)

[CmdletBinding()]
param(
    # WORKER MODE: do one run, here, in this process. The driver sets it.
    [switch]$Worker,

    # ---- worker parameters ------------------------------------------------
    [int]$HoldMs = 400,
    [switch]$Press,
    [switch]$Pointer,
    [string]$Out = '',
    # DRAG MODE: k moves at `-SettleMs` apart, `send_hand.ps1`'s construction
    # exactly. 0 means the plain hold above. The two are one program because the
    # only honest comparison is one that changes ONE thing.
    [int]$Moves = 0,
    [int]$SettleMs = 40,
    [double]$Dx = 60,
    [double]$Dy = 40,
    # Repaint the probe window this often during the hold/drag. 0 = never.
    [int]$RepaintMs = 0,

    # ---- driver parameters ------------------------------------------------
    # ⛔ A STRING, PARSED HERE, AND THE PARSED COUNT IS ECHOED. `powershell
    # -File` passes every argument as a literal string, so an `[int[]]`
    # parameter receives "0,200,400" and en-US parses it as the SINGLE integer
    # 200400 -- the comma is the digit group separator. That cost this seat the
    # liveness sampler on 2026-09-04, whose own receipt printed `at=2510s`.
    [string]$HoldMsList = '0,100,200,400,800,1600',
    # `hold` sweeps HoldMsList with no injected motion; `drag` replays the
    # k@settle configurations #117 measured on the shell, through the SAME
    # injector construction, into a bare window.
    [ValidateSet('hold', 'drag')][string]$Mode = 'hold',
    # k@settleMs, comma separated. Same string-not-int[] rule as HoldMsList.
    [string]$DragList = '7@10,7@40,4@100,1@300,2@800',
    [string]$OutDir = '',
    # How long to wait for one worker's receipt file.
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

# ===========================================================================
# THE WORKER
# ===========================================================================

$probeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

// A bare Win32 window that COUNTS what arrives. No XAML, no swapchain, no
// compositor, no render thread: if the extras show up here they are not the
// shell's doing.
public static class SbHold
{
    public delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct WNDCLASSEX
    {
        public uint cbSize;
        public uint style;
        public WndProcDelegate lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG
    {
        public IntPtr hwnd; public uint message;
        public IntPtr wParam; public IntPtr lParam;
        public uint time; public int ptX; public int ptY;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx; public int dy; public uint mouseData;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public MOUSEINPUT mi; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern ushort RegisterClassEx(ref WNDCLASSEX c);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CreateWindowEx(
        uint exStyle, string cls, string name, uint style,
        int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);

    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool UpdateWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern int GetMessageTime();
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool EnableMouseInPointer(bool enable);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string n);

    const uint WM_DESTROY       = 0x0002;
    const uint WM_MOUSEMOVE     = 0x0200;
    const uint WM_LBUTTONDOWN   = 0x0201;
    const uint WM_LBUTTONUP     = 0x0202;
    const uint WM_POINTERUPDATE = 0x0245;
    const uint WM_POINTERDOWN   = 0x0246;
    const uint WM_POINTERUP     = 0x0247;

    const uint MOVE            = 0x0001;
    const uint LEFTDOWN        = 0x0002;
    const uint LEFTUP          = 0x0004;
    const uint MOVE_NOCOALESCE = 0x2000;
    const uint VIRTUALDESK     = 0x4000;
    const uint ABSOLUTE        = 0x8000;

    static List<string> _log;
    static Stopwatch _sw;
    static WndProcDelegate _proc;   // FIELD: a local would be collected mid-run.
    static bool _marked;
    // ⭐ THE FOURTH KNOB. The shell REPAINTS under the held contact -- every
    // pointer event drives a frame. A bare window that never redraws is
    // therefore not the shell minus WinUI; it is the shell minus WinUI AND
    // minus the redraw. This makes the redraw a knob of its own so the two can
    // be separated instead of confounded.
    static int _repaintMs;
    static IntPtr _hwnd;
    static int _repaints;
    static int _moves;
    static int _pointerUpdates;

    static IntPtr Proc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        if (msg == WM_MOUSEMOVE || msg == WM_POINTERUPDATE ||
            msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP ||
            msg == WM_POINTERDOWN || msg == WM_POINTERUP)
        {
            string name = "?";
            if (msg == WM_MOUSEMOVE) name = "MOUSEMOVE";
            else if (msg == WM_POINTERUPDATE) name = "POINTERUPDATE";
            else if (msg == WM_LBUTTONDOWN) name = "LBUTTONDOWN";
            else if (msg == WM_LBUTTONUP) name = "LBUTTONUP";
            else if (msg == WM_POINTERDOWN) name = "POINTERDOWN";
            else if (msg == WM_POINTERUP) name = "POINTERUP";

            if (_marked)
            {
                if (msg == WM_MOUSEMOVE) _moves++;
                if (msg == WM_POINTERUPDATE) _pointerUpdates++;
            }
            // ⭐ `GetMessageTime` IS THE FIELD THAT SEPARATES "queued at
            // injection" FROM "generated during the hold". It is the hardware
            // timestamp the message was posted with, not the time it was
            // dispatched, so a burst of extras all carrying the injection's own
            // timestamp is a very different finding from extras spread across
            // the hold.
            _log.Add(string.Format(
                "  msg {0,-14} at={1,6}ms msgtime={2} lparam=0x{3:X} wparam=0x{4:X} counted={5}",
                name, _sw.ElapsedMilliseconds, GetMessageTime(),
                l.ToInt64(), w.ToInt64(), _marked ? "yes" : "no"));
        }
        return DefWindowProc(h, msg, w, l);
    }

    static void Pump(int ms)
    {
        Stopwatch s = Stopwatch.StartNew();
        MSG m;
        long lastPaint = -100000;
        while (s.ElapsedMilliseconds < ms)
        {
            while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1))
            {
                TranslateMessage(ref m);
                DispatchMessage(ref m);
            }
            if (_repaintMs > 0 && _hwnd != IntPtr.Zero &&
                s.ElapsedMilliseconds - lastPaint >= _repaintMs)
            {
                lastPaint = s.ElapsedMilliseconds;
                InvalidateRect(_hwnd, IntPtr.Zero, true);
                UpdateWindow(_hwnd);
                _repaints++;
            }
            Thread.Sleep(1);
        }
        // Drain whatever landed in the final millisecond.
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1))
        {
            TranslateMessage(ref m);
            DispatchMessage(ref m);
        }
    }

    static uint Send(uint flags, int nx, int ny)
    {
        INPUT[] one = new INPUT[1];
        one[0].type = 0;
        one[0].mi.dx = nx;
        one[0].mi.dy = ny;
        one[0].mi.dwFlags = flags;
        return SendInput(1, one, Marshal.SizeOf(typeof(INPUT)));
    }

    /// One run. Returns the whole receipt; the caller decides what to do with it.
    /// `moves > 0` replays send_hand.ps1's construction instead of a bare hold.
    public static string[] Run(int holdMs, bool press, bool pointerMode,
                               int moves, int settleMs, double dx, double dy,
                               int repaintMs)
    {
        _log = new List<string>();
        _sw = Stopwatch.StartNew();
        _marked = false;
        _moves = 0;
        _pointerUpdates = 0;
        _repaintMs = repaintMs;
        _hwnd = IntPtr.Zero;
        _repaints = 0;

        SetProcessDpiAwarenessContext(new IntPtr(-4));

        if (pointerMode)
        {
            bool ok = EnableMouseInPointer(true);
            _log.Add("EnableMouseInPointer(true) -> " + ok +
                     " (err " + Marshal.GetLastWin32Error() + ")");
        }
        else
        {
            _log.Add("EnableMouseInPointer NOT called -- legacy WM_MOUSEMOVE stack");
        }

        _proc = new WndProcDelegate(Proc);
        string cls = "SbHoldProbe" + Process.GetCurrentProcess().Id;
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.style = 0;
        wc.lpfnWndProc = _proc;
        wc.hInstance = GetModuleHandle(null);
        wc.hbrBackground = new IntPtr(6); // COLOR_WINDOW + 1
        wc.lpszClassName = cls;
        ushort atom = RegisterClassEx(ref wc);
        if (atom == 0)
        {
            _log.Add("REFUSED: RegisterClassEx failed, err " + Marshal.GetLastWin32Error());
            return _log.ToArray();
        }

        IntPtr hwnd = CreateWindowEx(0, cls, "SB HOLD PROBE", 0x00CF0000,
                                     120, 120, 480, 360,
                                     IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero)
        {
            _log.Add("REFUSED: CreateWindowEx failed, err " + Marshal.GetLastWin32Error());
            return _log.ToArray();
        }
        _hwnd = hwnd;
        ShowWindow(hwnd, 5);
        UpdateWindow(hwnd);
        SetForegroundWindow(hwnd);
        Pump(400);   // settle: let the shown window's own moves arrive and pass

        RECT rc;
        GetClientRect(hwnd, out rc);
        POINT o = new POINT();
        ClientToScreen(hwnd, ref o);
        double cx = o.X + rc.Right / 2.0;
        double cy = o.Y + rc.Bottom / 2.0;

        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        if (vw <= 1) vw = 2;
        if (vh <= 1) vh = 2;
        int nx = (int)Math.Round(((cx - vx) * 65535.0) / (vw - 1));
        int ny = (int)Math.Round(((cy - vy) * 65535.0) / (vh - 1));
        _log.Add(string.Format("client={0}x{1} origin=({2},{3}) centre=({4},{5}) normalized=({6},{7})",
                               rc.Right, rc.Bottom, o.X, o.Y, cx, cy, nx, ny));

        // Position the cursor over the window, exactly as send_hand.ps1 does.
        Send(MOVE | ABSOLUTE | VIRTUALDESK | MOVE_NOCOALESCE, nx, ny);
        Pump(150);

        // ⭐ THE MARK. Everything counted is after this line, so the positioning
        // move and the window's own startup traffic cannot be one of the extras.
        _marked = true;
        _log.Add("--- MARK (counting starts) ---");

        if (press)
        {
            Send(LEFTDOWN, 0, 0);   // AT THE CURSOR: no MOVE, no ABSOLUTE.
            Pump(30);
        }

        long holdStart = _sw.ElapsedMilliseconds;
        int movesAtHoldStart = _moves;
        int updatesAtHoldStart = _pointerUpdates;
        int collisions = 0;

        if (moves <= 0)
        {
            // ⛔ THE HOLD ITSELF: NOT ONE MOVE IS INJECTED HERE. Whatever
            // arrives between this line and the next is not something this
            // program sent.
            Pump(holdMs);
        }
        else
        {
            // ⭐ send_hand.ps1's CONSTRUCTION, TRANSCRIBED: k steps along the
            // segment, the i-th at t = i/k so none lands on the press point,
            // MOVE_NOCOALESCE on every one, `settleMs` between them, and the
            // normalised collision check that separates "the injector sent the
            // same grid point twice" from "the window coalesced".
            //
            // ⛔ IT MUST BE THE SAME CONSTRUCTION OR THIS PROBE ANSWERS A
            // DIFFERENT QUESTION. The only intended difference from the sitting
            // is the WINDOW: bare Win32 here, WinUI there.
            double px1 = cx + dx, py1 = cy + dy;
            int pnx = nx, pny = ny;
            for (int i = 1; i <= moves; i++)
            {
                double t = i / (double)moves;
                double mx = cx + (px1 - cx) * t;
                double my = cy + (py1 - cy) * t;
                int mnx = (int)Math.Round(((mx - vx) * 65535.0) / (vw - 1));
                int mny = (int)Math.Round(((my - vy) * 65535.0) / (vh - 1));
                if (mnx == pnx && mny == pny) collisions++;
                pnx = mnx; pny = mny;
                Send(MOVE | ABSOLUTE | VIRTUALDESK | MOVE_NOCOALESCE, mnx, mny);
                Pump(settleMs);
            }
        }
        long holdEnd = _sw.ElapsedMilliseconds;

        if (press)
        {
            Send(LEFTUP, 0, 0);
            Pump(60);
        }

        int movesInHold = _moves - movesAtHoldStart;
        int updatesInHold = _pointerUpdates - updatesAtHoldStart;

        _log.Add(string.Format(
            "RESULT hold-asked={0}ms hold-actual={1}ms press={2} pointer-mode={3} " +
            "moves-in-hold={4} pointer-updates-in-hold={5} moves-total={6} updates-total={7} " +
            "k={8} settle-ms={9} normalized-collisions={10} arrivals={11} " +
            "repaint-ms={12} repaints={13}",
            holdMs, holdEnd - holdStart, press ? "down" : "up", pointerMode,
            movesInHold, updatesInHold, _moves, _pointerUpdates,
            moves, settleMs, collisions,
            pointerMode ? updatesInHold : movesInHold,
            repaintMs, _repaints));

        DestroyWindow(hwnd);
        Pump(30);
        return _log.ToArray();
    }
}
'@

function Invoke-SbHoldWorker {
    param([int]$HoldMs, [bool]$Press, [bool]$PointerMode, [string]$OutFile,
          [int]$MoveCount, [int]$Settle, [double]$DeltaX, [double]$DeltaY, [int]$Repaint)

    $lines = New-Object System.Collections.Generic.List[string]
    $sid = (Get-Process -Id $PID).SessionId
    $lines.Add("probe_hold worker: pid=$PID session=$sid holdMs=$HoldMs press=$Press pointer=$PointerMode k=$MoveCount settle=$Settle repaint=$Repaint")

    # ⛔ SESSION 0 CANNOT ANSWER THIS QUESTION AND MUST NOT PRETEND TO. Injected
    # input goes to the interactive desktop; from session 0 every count would be
    # zero for a reason that has nothing to do with the hypothesis, and a zero
    # here reads exactly like "no extras". Refuse instead.
    if ($sid -ne 1) {
        $lines.Add("REFUSED: session $sid is not the interactive desktop (1). A count from here would be vacuous.")
        $lines | Set-Content -Path $OutFile -Encoding utf8
        return 2
    }

    try {
        Add-Type -TypeDefinition $probeSource -Language CSharp -ErrorAction Stop
    } catch {
        $lines.Add("REFUSED: Add-Type: $($_.Exception.Message)")
        $lines | Set-Content -Path $OutFile -Encoding utf8
        return 3
    }

    try {
        $out = [SbHold]::Run($HoldMs, $Press, $PointerMode, $MoveCount, $Settle, $DeltaX, $DeltaY, $Repaint)
        foreach ($l in $out) { $lines.Add($l) }
    } catch {
        $lines.Add("REFUSED: Run threw: $($_.Exception.Message)")
        $lines | Set-Content -Path $OutFile -Encoding utf8
        return 4
    }

    $lines | Set-Content -Path $OutFile -Encoding utf8
    return 0
}

if ($Worker) {
    if ([string]::IsNullOrWhiteSpace($Out)) {
        Write-Output "REFUSED: -Worker needs -Out"
        exit 1
    }
    exit (Invoke-SbHoldWorker -HoldMs $HoldMs -Press ([bool]$Press) -PointerMode ([bool]$Pointer) `
                              -OutFile $Out -MoveCount $Moves -Settle $SettleMs -DeltaX $Dx -DeltaY $Dy -Repaint $RepaintMs)
}

# ===========================================================================
# THE DRIVER -- the sweep, in session 1, through the interactive task
# ===========================================================================

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $env:TEMP ("sb-hold-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$me = $MyInvocation.MyCommand.Path
$rows = @()

# One scheduled-task run, and the ONLY place a worker is launched. It returns
# the RESULT row or $null, and it never invents a number for a run that did not
# happen -- a missing receipt is `n/a`, printed, and carried into the table.
function Invoke-SbProbeRun {
    param([string]$Tag, [string]$ExtraArgs)

    $file = Join-Path $OutDir ("$Tag.txt")
    if (Test-Path $file) { Remove-Item $file -Force }

    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$script:me`" -Worker -Out `"$file`" $ExtraArgs"
    $task = "jas-sb-hold-$Tag"
    $principal = New-ScheduledTaskPrincipal -UserId (Get-SbUid) -LogonType Interactive -RunLevel Limited
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $task

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $file)) {
        Start-Sleep -Milliseconds 200
    }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue

    if (-not (Test-Path $file)) {
        Write-Output ("  {0,-26} NOT RUN: no receipt within {1}s" -f $Tag, $TimeoutSeconds)
        return $null
    }
    $text = Get-Content -Raw -LiteralPath $file
    $line = ($text -split "`r?`n" | Where-Object { $_ -like 'RESULT *' } | Select-Object -First 1)
    if ($null -eq $line) {
        $why = ($text -split "`r?`n" | Where-Object { $_ -like 'REFUSED*' } | Select-Object -First 1)
        if ($null -eq $why) { $why = 'no RESULT row' }
        Write-Output ("  {0,-26} NOT RUN: {1}" -f $Tag, $why)
        return $null
    }
    return $line
}

if ($Mode -eq 'hold') {
    $holds = @()
    foreach ($piece in ($HoldMsList -split ',')) {
        $t = $piece.Trim()
        if ($t.Length -gt 0) { $holds += [int]$t }
    }
    # ⛔ THE PARSED COUNT, ECHOED. See -HoldMsList's own note: this line is what
    # turns the comma trap from a silent single value into a visible one.
    Write-Output ("holds parsed: count={0} values={1}" -f $holds.Count, ($holds -join ' '))
    Write-Output ("out dir: {0}" -f $OutDir)
    if ($holds.Count -lt 2) {
        Write-Output "REFUSED: a sweep needs at least two hold durations -- one point cannot show a slope."
        exit 1
    }

    foreach ($pointerMode in @($false, $true)) {
        foreach ($pressed in @($true, $false)) {
            foreach ($h in $holds) {
                $stack = 'legacy'
                if ($pointerMode) { $stack = 'pointer' }
                $btn = 'up'
                if ($pressed) { $btn = 'down' }
                $tag = "$stack-$btn-${h}ms"
                $extra = "-HoldMs $h -RepaintMs $RepaintMs"
                if ($pressed) { $extra += " -Press" }
                if ($pointerMode) { $extra += " -Pointer" }

                $line = Invoke-SbProbeRun -Tag $tag -ExtraArgs $extra
                if ($null -eq $line) {
                    $rows += [pscustomobject]@{ Tag = $tag; Stack = $stack; Press = $btn
                                                K = 0; Settle = 0; Hold = $h
                                                Arrivals = 'n/a'; Extras = 'n/a'; Actual = 'n/a' }
                    continue
                }
                $m = Get-SbField $line 'moves-in-hold'
                $u = Get-SbField $line 'pointer-updates-in-hold'
                $a = Get-SbField $line 'hold-actual'
                $arr = Get-SbField $line 'arrivals'
                Write-Output ("  {0,-26} moves={1,-4} updates={2,-4} actual={3}" -f $tag, $m, $u, $a)
                $rows += [pscustomobject]@{ Tag = $tag; Stack = $stack; Press = $btn
                                            K = 0; Settle = 0; Hold = $h
                                            Arrivals = $arr; Extras = $arr; Actual = $a }
            }
        }
    }
} else {
    # ⭐ DRAG MODE: the sitting's own configurations, into a bare window.
    $drags = @()
    foreach ($piece in ($DragList -split ',')) {
        $t = $piece.Trim()
        if ($t.Length -eq 0) { continue }
        $bits = $t -split '@'
        if ($bits.Count -ne 2) {
            Write-Output "REFUSED: '$t' is not k@settleMs"
            exit 1
        }
        $drags += [pscustomobject]@{ K = [int]$bits[0]; Settle = [int]$bits[1] }
    }
    Write-Output ("drags parsed: count={0} values={1}" -f $drags.Count,
                  (($drags | ForEach-Object { "$($_.K)@$($_.Settle)" }) -join ' '))
    Write-Output ("out dir: {0}" -f $OutDir)
    if ($drags.Count -lt 2) {
        Write-Output "REFUSED: a replication needs at least two configurations."
        exit 1
    }

    foreach ($pointerMode in @($false, $true)) {
        foreach ($d in $drags) {
            $stack = 'legacy'
            if ($pointerMode) { $stack = 'pointer' }
            $tag = "$stack-k$($d.K)-s$($d.Settle)"
            $extra = "-Press -Moves $($d.K) -SettleMs $($d.Settle) -RepaintMs $RepaintMs"
            if ($pointerMode) { $extra += " -Pointer" }

            $line = Invoke-SbProbeRun -Tag $tag -ExtraArgs $extra
            if ($null -eq $line) {
                $rows += [pscustomobject]@{ Tag = $tag; Stack = $stack; Press = 'down'
                                            K = $d.K; Settle = $d.Settle; Hold = 0
                                            Arrivals = 'n/a'; Extras = 'n/a'; Actual = 'n/a' }
                continue
            }
            $arr = Get-SbField $line 'arrivals'
            $a = Get-SbField $line 'hold-actual'
            $col = Get-SbField $line 'normalized-collisions'
            # THE NUMBER THE SITTING READS is `move=` minus k. Printed as its own
            # column so a zero is visibly a zero and not an absent value.
            $extras = [int]$arr - $d.K
            Write-Output ("  {0,-26} k={1,-3} settle={2,-4} arrivals={3,-4} extras={4,-4} post-press={5} collisions={6}" -f
                          $tag, $d.K, $d.Settle, $arr, $extras, $a, $col)
            $rows += [pscustomobject]@{ Tag = $tag; Stack = $stack; Press = 'down'
                                        K = $d.K; Settle = $d.Settle; Hold = 0
                                        Arrivals = $arr; Extras = $extras; Actual = $a }
        }
    }
}

Write-Output ""
Write-Output "=== THE TABLE ==="
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Write-Output ("receipts: {0}" -f $OutDir)
