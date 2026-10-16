. "$PSScriptRoot\lib\WindowInterop.ps1"
. "$PSScriptRoot\lib\DofusWindows.ps1"
. "$PSScriptRoot\lib\ForegroundHelper.ps1"
. "$PSScriptRoot\lib\TaskbarOrder.ps1"
. "$PSScriptRoot\lib\WindowCycle.ps1"
. "$PSScriptRoot\lib\WindowLayout.ps1"
. "$PSScriptRoot\lib\HotkeyListener.ps1"
. "$PSScriptRoot\lib\TrayIcon.ps1"

$mutexName = "Global\DofusMultiSwitcher"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show("Ya hay una instancia de Dofus Multi-switcher activa.", "Dofus Multi-switcher") | Out-Null
    exit 1
}

$notifyIcon = Start-TrayIcon
Start-HotkeyListener -NotifyIcon $notifyIcon
