# box_windows.ps1 -- the window half of the box preflight (O97's nightly run).
#
# Runs IN THE CONSOLE SESSION, started by Read-SbBoxSnapshot through an
# Interactive scheduled task: session 0, where an ssh or service shell runs,
# sees no desktop at all, so a window read from there is vacuous.
#
# Writes one header and one row per visible, uncloaked, non-empty TOPMOST
# top-level window, in the rows Get-SbBoxWindowReasons reads:
#   BOX WINDOWS session=<n> screen=<l>,<t>,<r>,<b> topmost=<count>
#   TOPMOST process=<name> rect=<l>,<t>,<r>,<b> class=<class>
# The screen is the primary monitor, read through GetSystemMetrics in this same
# process, so it and every rect share one DPI context. The class goes last
# because a class name may hold a space.
#
# The file is written whole to a temporary name and then renamed, so a reader
# that polls for it never sees half a read.
#
#   powershell -File box_windows.ps1 -Out <path>

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Out)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class SbBoxWindows {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int n);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    const int GWL_EXSTYLE = -20, WS_EX_TOPMOST = 0x8, DWMWA_CLOAKED = 14;

    // One entry per topmost window: pid, l, t, r, b, class.
    public static List<object[]> Topmost() {
        var o = new List<object[]>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0) return true;
            int cloaked = 0;
            DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4);
            if (cloaked != 0) return true;
            RECT r;
            if (!GetWindowRect(h, out r) || r.R <= r.L || r.B <= r.T) return true;
            var c = new StringBuilder(256);
            GetClassName(h, c, 256);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            o.Add(new object[] { (int)pid, r.L, r.T, r.R, r.B, c.ToString() });
            return true;
        }, IntPtr.Zero);
        return o;
    }
}
'@

$rows = New-Object System.Collections.Generic.List[string]
foreach ($w in [SbBoxWindows]::Topmost()) {
    $proc = (Get-Process -Id $w[0] -ErrorAction SilentlyContinue).ProcessName
    if (-not $proc) { $proc = "pid$($w[0])" }
    $rows.Add("TOPMOST process=$proc rect=$($w[1]),$($w[2]),$($w[3]),$($w[4]) class=$($w[5])")
}
$session = (Get-Process -Id $PID).SessionId
$cx = [SbBoxWindows]::GetSystemMetrics(0)
$cy = [SbBoxWindows]::GetSystemMetrics(1)
$text = @("BOX WINDOWS session=$session screen=0,0,$cx,$cy topmost=$($rows.Count)") + $rows
$tmp = "$Out.tmp"
[System.IO.File]::WriteAllLines($tmp, [string[]]$text, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $Out -Force
