function global:Find-ChildWindowByClass {
    param(
        [Parameter(Mandatory)][IntPtr]$Parent,
        [Parameter(Mandatory)][string]$ClassName
    )

    $GW_CHILD = 5
    $GW_HWNDNEXT = 2

    $child = [Win32]::GetWindow($Parent, $GW_CHILD)
    while ($child -ne [IntPtr]::Zero) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][Win32]::GetClassName($child, $sb, $sb.Capacity)
        if ($sb.ToString() -eq $ClassName) {
            return $child
        }
        $child = [Win32]::GetWindow($child, $GW_HWNDNEXT)
    }
    return [IntPtr]::Zero
}

function global:Get-TaskbarOrder {
    try {
        $taskbarHwnd = [Win32]::FindWindow("Shell_TrayWnd", $null)
        if ($taskbarHwnd -eq [IntPtr]::Zero) {
            return $null
        }

        $rebarHwnd = Find-ChildWindowByClass -Parent $taskbarHwnd -ClassName "ReBarWindow32"
        if ($rebarHwnd -eq [IntPtr]::Zero) { return $null }

        $taskSwHwnd = Find-ChildWindowByClass -Parent $rebarHwnd -ClassName "MSTaskSwWClass"
        if ($taskSwHwnd -eq [IntPtr]::Zero) { return $null }

        $taskListHwnd = Find-ChildWindowByClass -Parent $taskSwHwnd -ClassName "MSTaskListWClass"
        if ($taskListHwnd -eq [IntPtr]::Zero) { return $null }

        $OBJID_CLIENT = [uint32]0xFFFFFFFC
        $IID_IAccessible = [Guid]"618736E0-3C3D-11CF-810C-00AA00389B71"
        $iacc = $null
        $hr = [Oleacc]::AccessibleObjectFromWindow($taskListHwnd, $OBJID_CLIENT, [ref]$IID_IAccessible, [ref]$iacc)
        if ($hr -ne 0 -or $null -eq $iacc) {
            return $null
        }

        $count = $iacc.accChildCount
        if ($count -le 0) {
            return $null
        }

        $items = New-Object System.Collections.Generic.List[PSCustomObject]
        for ($i = 1; $i -le $count; $i++) {
            $childId = [object]$i
            $name = $null
            $left = $i
            try { $name = $iacc.accName($childId) } catch {}
            try {
                [int]$l = 0; [int]$t = 0; [int]$w = 0; [int]$h = 0
                $iacc.accLocation([ref]$l, [ref]$t, [ref]$w, [ref]$h, $childId)
                $left = $l
            } catch {}
            if ($name) {
                $items.Add([PSCustomObject]@{ Name = $name; Left = $left })
            }
        }
        if ($items.Count -eq 0) {
            return $null
        }

        return ($items | Sort-Object Left | ForEach-Object { $_.Name })
    } catch {
        return $null
    }
}
