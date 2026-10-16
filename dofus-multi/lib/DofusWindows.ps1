function global:Get-ProcessWindows {
    param(
        [Parameter(Mandatory)][string]$ProcessName
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $callback = {
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if ([Win32]::IsWindowVisible($hWnd)) {
            $len = [Win32]::GetWindowTextLength($hWnd)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 1)
                [void][Win32]::GetWindowText($hWnd, $sb, $sb.Capacity)
                $title = $sb.ToString()

                [uint32]$procId = 0
                [void][Win32]::GetWindowThreadProcessId($hWnd, [ref]$procId)

                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -eq $ProcessName) {
                    $results.Add([PSCustomObject]@{ Handle = $hWnd; Title = $title })
                }
            }
        }
        return $true
    }

    [void][Win32]::EnumWindows($callback, [IntPtr]::Zero)
    return $results
}

function global:Get-DofusWindows {
    Get-ProcessWindows -ProcessName 'Dofus'
}
