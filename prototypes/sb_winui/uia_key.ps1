param([int]$ProcessId, [string]$Out)
# One real Ctrl+Z into the app's window, IN SESSION 1: the window is found by
# its owner pid, brought forward, and the chord sent as key events, so the
# shell's own key route runs. Evidence of SENDING only; arrival is the shell's
# row. ASCII only.
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SbKey {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@
$r = 'none'
try {
    $p = Get-Process -Id $ProcessId
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { $r = "no window for pid $ProcessId" }
    else {
        $fg = [SbKey]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 300
        $isFg = ([SbKey]::GetForegroundWindow() -eq $h)
        [SbKey]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)      # Ctrl down
        Start-Sleep -Milliseconds 40
        [SbKey]::keybd_event(0x5A, 0, 0, [UIntPtr]::Zero)      # Z down
        [SbKey]::keybd_event(0x5A, 0, 2, [UIntPtr]::Zero)      # Z up
        Start-Sleep -Milliseconds 40
        [SbKey]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)      # Ctrl up
        $r = "sent ctrl+Z set-foreground=$fg foreground=$isFg"
    }
} catch { $r = "error $($_.Exception.GetType().Name): $($_.Exception.Message)" }
Set-Content -Path $Out -Value $r -Encoding ascii
