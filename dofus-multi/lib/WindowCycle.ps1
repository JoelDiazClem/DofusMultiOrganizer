function global:Get-NextWindowHandle {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$OrderedHandles,
        [Parameter(Mandatory)]$CurrentHandle,
        [Parameter(Mandatory)][ValidateSet('Next', 'Prev')]$Direction
    )

    if (-not $OrderedHandles -or $OrderedHandles.Count -eq 0) {
        return $null
    }

    $currentIndex = -1
    for ($i = 0; $i -lt $OrderedHandles.Count; $i++) {
        if ($OrderedHandles[$i] -eq $CurrentHandle) {
            $currentIndex = $i
            break
        }
    }

    $count = $OrderedHandles.Count
    if ($Direction -eq 'Next') {
        $nextIndex = ($currentIndex + 1) % $count
    } else {
        $nextIndex = (($currentIndex - 1) + $count) % $count
        # When currentIndex is -1 (not found), wrap to the last element
        if ($currentIndex -eq -1) {
            $nextIndex = $count - 1
        }
    }

    return $OrderedHandles[$nextIndex]
}

function global:Get-OrderedProcessHandles {
    param(
        [Parameter(Mandatory)][string]$ProcessName
    )

    $windows = Get-ProcessWindows -ProcessName $ProcessName
    if (-not $windows -or $windows.Count -eq 0) {
        return @()
    }

    $taskbarOrder = Get-TaskbarOrder
    if (-not $taskbarOrder) {
        Write-Host "Aviso: no se pudo leer el orden de la barra de tareas, usando orden alternativo."
        return @($windows | ForEach-Object { $_.Handle })
    }

    $ordered = [System.Collections.Generic.List[IntPtr]]::new()
    $remaining = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($w in $windows) { $remaining.Add($w) }

    foreach ($title in $taskbarOrder) {
        # Get-TaskbarOrder's entries can carry a locale-dependent suffix beyond the
        # real window title (e.g. "<title>: 4 ventanas en ejecución" when Windows
        # groups several windows of the same app) - verified empirically on this
        # machine's real taskbar during Task 4. Match by prefix, not exact equality,
        # so this still works regardless of what (if anything) follows the title.
        $match = $remaining | Where-Object { $_.Title -and $title.StartsWith($_.Title) } | Select-Object -First 1
        if ($match) {
            $ordered.Add($match.Handle)
            [void]$remaining.Remove($match)
        }
    }
    foreach ($leftover in $remaining) {
        $ordered.Add($leftover.Handle)
    }

    return $ordered
}

function global:Switch-DofusWindow {
    param(
        [Parameter(Mandatory)][ValidateSet('Next', 'Prev')]$Direction
    )

    $ordered = $global:DofusCachedOrder
    if (-not $ordered -or $ordered.Count -eq 0) {
        return
    }

    $current = [Win32]::GetForegroundWindow()
    $target = Get-NextWindowHandle -OrderedHandles $ordered -CurrentHandle $current -Direction $Direction

    if ($null -ne $target) {
        Set-ForegroundWindowReliable -Handle $target
    }
}
