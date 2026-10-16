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
    $index = 0
    foreach ($handle in $global:DofusCachedOrder) {
        if ($index -ge 4) { break }
        $q = $quadrants[$index]
        [void][Win32]::ShowWindow($handle, $SW_RESTORE)
        [void][Win32]::MoveWindow($handle, $q.X, $q.Y, $q.W, $q.H, $true)
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
