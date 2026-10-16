Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function global:Start-TrayIcon {
    $global:DofusCachedOrder = Get-OrderedProcessHandles -ProcessName 'Dofus'

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    $notifyIcon.Text = "Dofus Multi-switcher (F2/F3)"
    $notifyIcon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem "Actualizar"
    $refreshItem.add_Click({
        $global:DofusCachedOrder = Get-OrderedProcessHandles -ProcessName 'Dofus'
        $count = $global:DofusCachedOrder.Count
        $notifyIcon.ShowBalloonTip(2000, "Dofus Multi-switcher", "Orden actualizado ($count ventanas).", [System.Windows.Forms.ToolTipIcon]::Info)
    }.GetNewClosure())
    [void]$menu.Items.Add($refreshItem)

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "Salir"
    $exitItem.add_Click({
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        [System.Environment]::Exit(0)
    }.GetNewClosure())
    [void]$menu.Items.Add($exitItem)

    $notifyIcon.ContextMenuStrip = $menu

    return $notifyIcon
}
