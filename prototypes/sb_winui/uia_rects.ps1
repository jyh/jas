# uia_rects.ps1 -- the BoundingRectangle of each named element of a live window,
# read through UI Automation, and a photograph of that window.
#
# R1-4b S6 (flask STATUS 829): edge_dock_e2e.ps1 judges where the edge docks
# are DRAWN against the engine's rects, so it needs the rects a person's screen
# holds, not the ones the shell set. UIA rects are PHYSICAL pixels (this box is
# 150%), written as read; the judge divides.
#
# UIA cannot see a desktop from session 0 (an ssh shell), so the caller runs
# this IN SESSION 1 through a scheduled task, as uia_tree.ps1 is run.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.
param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    # Comma-separated AutomationIds. Crossed as ONE string: a -File boundary
    # does not carry an array (flask bank, the comma-list card).
    [Parameter(Mandatory = $true)][string]$Ids,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Png = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$scope = [System.Windows.Automation.TreeScope]
$want = @($Ids.Split(',') | Where-Object { $_.Length -gt 0 })
$rects = [ordered]@{}
$err = $null
$shot = $null
$byPid = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)
$window = $AE::RootElement.FindFirst($scope::Children, $byPid)
if ($null -eq $window) {
    $err = "no top-level UIA element for pid $ProcessId (session=$((Get-Process -Id $PID).SessionId))"
} else {
    foreach ($id in $want) {
        $byId = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
        $el = $window.FindFirst($scope::Descendants, $byId)
        if ($null -eq $el) { continue }
        $r = $el.Current.BoundingRectangle
        $rects[$id] = [ordered]@{ X = $r.X; Y = $r.Y; W = $r.Width; H = $r.Height; offscreen = $el.Current.IsOffscreen }
    }
    if ($Png.Length -gt 0) {
        try {
            Add-Type -AssemblyName System.Drawing
            $w = $window.Current.BoundingRectangle
            $bmp = New-Object System.Drawing.Bitmap ([int]$w.Width), ([int]$w.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen([int]$w.X, [int]$w.Y, 0, 0, $bmp.Size)
            $g.Dispose()
            $bmp.Save($Png, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $shot = [ordered]@{ X = $w.X; Y = $w.Y; W = $w.Width; H = $w.Height }
        } catch { $err = "photograph failed: $($_.Exception.Message)" }
    }
}
[ordered]@{
    pid     = $ProcessId
    session = (Get-Process -Id $PID).SessionId
    error   = $err
    asked   = $want.Count
    found   = $rects.Count
    rects   = $rects
    window  = $shot
} | ConvertTo-Json -Depth 4 | Set-Content -Path $Out -Encoding ascii
