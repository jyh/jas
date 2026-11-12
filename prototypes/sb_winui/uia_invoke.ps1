param([int]$ProcessId, [string]$Id, [string]$Out)
# Invoke one element of a live window by AutomationId, IN SESSION 1 (UIA cannot
# see the desktop from session 0). Writes what it found and did. ASCII only.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$scope = [System.Windows.Automation.TreeScope]
$r = 'none'
try {
    $byPid = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)
    $window = $AE::RootElement.FindFirst($scope::Children, $byPid)
    if ($null -eq $window) { $r = "no window for pid $ProcessId" }
    else {
        $byId = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Id)
        $el = $window.FindFirst($scope::Descendants, $byId)
        if ($null -eq $el) { $r = "no element $Id" }
        else {
            # Read BEFORE invoking: an accepted bar collapses, and a read after
            # the press reports the collapsed button (offscreen, infinite rect).
            $b = $el.Current.BoundingRectangle
            $off = $el.Current.IsOffscreen
            $p = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $p.Invoke()
            $r = "invoked $Id offscreen-before=$off rect-before=$($b.X),$($b.Y),$($b.Width),$($b.Height)"
        }
    }
} catch { $r = "error $($_.Exception.GetType().Name): $($_.Exception.Message)" }
Set-Content -Path $Out -Value $r -Encoding ascii
