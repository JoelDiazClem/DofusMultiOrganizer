Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function global:Get-TaskbarOrder {
    try {
        $taskbarHwnd = [Win32]::FindWindow("Shell_TrayWnd", $null)
        if ($taskbarHwnd -eq [IntPtr]::Zero) {
            return $null
        }

        $taskbarElement = [System.Windows.Automation.AutomationElement]::FromHandle($taskbarHwnd)

        $listCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, "MSTaskListWClass")
        $taskListElement = $taskbarElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $listCondition)

        if (-not $taskListElement) {
            return $null
        }

        $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $buttons = $taskListElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $buttonCondition)

        $order = New-Object System.Collections.Generic.List[string]
        foreach ($button in $buttons) {
            $order.Add($button.Current.Name)
        }
        return $order
    } catch {
        return $null
    }
}
