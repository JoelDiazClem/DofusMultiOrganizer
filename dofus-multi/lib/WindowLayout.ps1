Add-Type -AssemblyName System.Windows.Forms

function global:Get-DofusTargetScreen {
    $current = [Win32]::GetForegroundWindow()
    if ($global:DofusCachedOrder -and ($global:DofusCachedOrder -contains $current)) {
        return [System.Windows.Forms.Screen]::FromHandle($current)
    }
    if ($global:DofusCachedOrder -and $global:DofusCachedOrder.Count -gt 0) {
        return [System.Windows.Forms.Screen]::FromHandle($global:DofusCachedOrder[0])
    }
    return $null
}

function global:Set-DofusTiledLayout {
    $screen = Get-DofusTargetScreen
    if (-not $screen -or -not $global:DofusCachedOrder -or $global:DofusCachedOrder.Count -eq 0) {
        return
    }

    $area = $screen.WorkingArea
    $halfW = [int]($area.Width / 2)
    $halfH = [int]($area.Height / 2)

    $quadrants = @(
        @{ X = $area.Left;          Y = $area.Top;          W = $halfW;                 H = $halfH },
        @{ X = $area.Left + $halfW; Y = $area.Top;          W = $area.Width - $halfW;   H = $halfH },
        @{ X = $area.Left;          Y = $area.Top + $halfH; W = $halfW;                 H = $area.Height - $halfH },
        @{ X = $area.Left + $halfW; Y = $area.Top + $halfH; W = $area.Width - $halfW;   H = $area.Height - $halfH }
    )

    $SW_RESTORE = 9
    $DWMWA_EXTENDED_FRAME_BOUNDS = 9
    $rectSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'RECT')

    $index = 0
    foreach ($handle in $global:DofusCachedOrder) {
        if ($index -ge 4) { break }
        $q = $quadrants[$index]

        [void][Win32]::ShowWindow($handle, $SW_RESTORE)

        # Windows gives most windows an invisible resize border outside their
        # visible edge (e.g. a maximized window's real rect extends ~8px past
        # the screen on every side). MoveWindow positions by that real rect,
        # not the visible one, so tiling by raw quadrant math leaves a gap
        # between windows. DwmGetWindowAttribute's extended frame bounds give
        # the visible rect; the difference from GetWindowRect is the border,
        # which we then compensate for so the VISIBLE edges touch exactly.
        $windowRect = New-Object RECT
        [void][Win32]::GetWindowRect($handle, [ref]$windowRect)
        $visibleRect = New-Object RECT
        [void][Win32]::DwmGetWindowAttribute($handle, $DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$visibleRect, $rectSize)

        $borderLeft = $visibleRect.Left - $windowRect.Left
        $borderTop = $visibleRect.Top - $windowRect.Top
        $borderRight = $windowRect.Right - $visibleRect.Right
        $borderBottom = $windowRect.Bottom - $visibleRect.Bottom

        $targetX = $q.X - $borderLeft
        $targetY = $q.Y - $borderTop
        $targetW = $q.W + $borderLeft + $borderRight
        $targetH = $q.H + $borderTop + $borderBottom

        [void][Win32]::MoveWindow($handle, $targetX, $targetY, $targetW, $targetH, $true)
        $index++
    }
}

function global:Set-DofusFullscreenLayout {
    if (-not $global:DofusCachedOrder) {
        return
    }
    $SW_MAXIMIZE = 3
    foreach ($handle in $global:DofusCachedOrder) {
        [void][Win32]::ShowWindow($handle, $SW_MAXIMIZE)
    }
}

function global:Toggle-DofusLayout {
    if ($global:DofusTiled) {
        Set-DofusFullscreenLayout
        $global:DofusTiled = $false
    } else {
        Set-DofusTiledLayout
        $global:DofusTiled = $true
    }
}
