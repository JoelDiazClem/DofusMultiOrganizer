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
