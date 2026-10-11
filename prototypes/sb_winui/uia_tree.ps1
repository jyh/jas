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
    [Parameter(Mandatory = $true)][string]$Out,
    # Read only BELOW the element with this AutomationId (the pane's host,
    # `PaneScroll`), so the shell's own XAML chrome -- Menu, PanePicker,
    # StatusLine, which surface their x:Name as an AutomationId -- is not read
    # as a widget the plan lacks. Empty reads the whole window.
    [string]$Root = ''
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
    $under = $window
    if ($Root.Length -gt 0) {
        $byId = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Root)
        $under = $window.FindFirst($scope::Descendants, $byId)
        if ($null -eq $under) { $err = "no element with AutomationId '$Root' under pid $ProcessId" }
    }
}
# A plan widget is a LEAF, so the walk stops at the first element carrying an
# AutomationId: what is below it is that control's own template (an editable
# ComboBox surfaces `EditableText`, measured on Windows in gradient and stroke),
# not a widget the plan could hold. Elements without one are walked through.
function Read-SbUiaLeaves($Parent, $Walker, $Rows) {
    $child = $Walker.GetFirstChild($Parent)
    while ($null -ne $child) {
        $c = $child.Current
        if ([string]::IsNullOrEmpty($c.AutomationId)) {
            Read-SbUiaLeaves $child $Walker $Rows
        } else {
            $Rows.Add([ordered]@{
                id        = $c.AutomationId
                type      = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')
                enabled   = $c.IsEnabled
                offscreen = $c.IsOffscreen
                name      = $c.Name
            })
        }
        $child = $Walker.GetNextSibling($child)
    }
}
if ($null -eq $err) {
    Read-SbUiaLeaves $under ([System.Windows.Automation.TreeWalker]::RawViewWalker) $rows
}
[ordered]@{
    pid     = $ProcessId
    root    = $Root
    session = (Get-Process -Id $PID).SessionId
    error   = $err
    count   = $rows.Count
    rows    = $rows
} | ConvertTo-Json -Depth 4 | Set-Content -Path $Out -Encoding ascii
