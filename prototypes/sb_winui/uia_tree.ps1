# uia_tree.ps1 -- the RENDERED widget tree, read through UI Automation.
#
# docs/TESTING.md section 5, item 2: LOOK-structure needs a reader of the
# RENDERED tree -- accessibility identifiers on macOS, UI Automation on
# Windows. Every PaneView control carries AutomationId = its widget id (the
# Mac's `.accessibilityIdentifier(element["id"])`, the same string), so this
# dumps what a person's screen holds, not what the plan says it should.
#
# UIA cannot see a desktop from session 0 (an ssh shell), so the caller runs
# this IN SESSION 1 through a scheduled task, as send_hand.ps1 is run.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script as cp1252.

param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$scope = [System.Windows.Automation.TreeScope]

$byPid = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)
$window = $AE::RootElement.FindFirst($scope::Children, $byPid)
$rows = New-Object System.Collections.Generic.List[object]
$err = $null
if ($null -eq $window) {
    $err = "no top-level UIA element for pid $ProcessId (session=$((Get-Process -Id $PID).SessionId))"
} else {
    $all = $window.FindAll($scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        $c = $el.Current
        if ([string]::IsNullOrEmpty($c.AutomationId)) { continue }
        $rows.Add([ordered]@{
            id        = $c.AutomationId
            type      = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')
            enabled   = $c.IsEnabled
            offscreen = $c.IsOffscreen
            name      = $c.Name
        })
    }
}
[ordered]@{
    pid     = $ProcessId
    session = (Get-Process -Id $PID).SessionId
    error   = $err
    count   = $rows.Count
    rows    = $rows
} | ConvertTo-Json -Depth 4 | Set-Content -Path $Out -Encoding ascii
