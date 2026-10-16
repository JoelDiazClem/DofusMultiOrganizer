. "$PSScriptRoot\lib\WindowInterop.ps1"
. "$PSScriptRoot\lib\DofusWindows.ps1"
. "$PSScriptRoot\lib\ForegroundHelper.ps1"
. "$PSScriptRoot\lib\TaskbarOrder.ps1"
. "$PSScriptRoot\lib\WindowCycle.ps1"
. "$PSScriptRoot\lib\HotkeyListener.ps1"

$mutexName = "Global\DofusMultiSwitcher"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    Write-Host "Ya hay una instancia de Dofus Multi-switcher activa."
    exit 1
}

Start-HotkeyListener
