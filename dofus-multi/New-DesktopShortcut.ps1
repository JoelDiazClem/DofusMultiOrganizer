$scriptDir = $PSScriptRoot
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "Dofus Multi.lnk"

$wshShell = New-Object -ComObject WScript.Shell
$shortcut = $wshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptDir\dofus-multi.ps1`""
$shortcut.WorkingDirectory = $scriptDir
$shortcut.Description = "Lanza el cambiador de ventanas de Dofus (F2/F3)"
$shortcut.Save()

Write-Host "Acceso directo creado en: $shortcutPath"
