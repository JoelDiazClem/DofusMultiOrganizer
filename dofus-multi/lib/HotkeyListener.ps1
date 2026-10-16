Add-Type -AssemblyName System.Windows.Forms

if (-not ([System.Management.Automation.PSTypeName]'HotkeyWindow').Type) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;

public class HotkeyEventArgs : EventArgs {
    public int Id;
    public HotkeyEventArgs(int id) { Id = id; }
}

public class HotkeyWindow : Form {
    private const int WM_HOTKEY = 0x0312;
    public event EventHandler<HotkeyEventArgs> HotKeyPressed;

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            EventHandler<HotkeyEventArgs> handler = HotKeyPressed;
            if (handler != null) {
                handler(this, new HotkeyEventArgs((int)m.WParam));
            }
        }
        base.WndProc(ref m);
    }
}
"@
}

function global:Start-HotkeyListener {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.NotifyIcon]$NotifyIcon
    )

    $window = New-Object HotkeyWindow
    [void]$window.Handle  # forces native handle creation without showing the form

    $HOTKEY_ID_NEXT = 1
    $HOTKEY_ID_PREV = 2
    $MOD_NONE = 0x0000
    $VK_F2 = 0x71
    $VK_F3 = 0x72

    $failedKeys = @()

    $f2Ok = [Win32]::RegisterHotKey($window.Handle, $HOTKEY_ID_NEXT, $MOD_NONE, $VK_F2)
    if (-not $f2Ok) { $failedKeys += "F2" }

    $f3Ok = [Win32]::RegisterHotKey($window.Handle, $HOTKEY_ID_PREV, $MOD_NONE, $VK_F3)
    if (-not $f3Ok) { $failedKeys += "F3" }

    if ($failedKeys.Count -gt 0) {
        if ($f2Ok) { [void][Win32]::UnregisterHotKey($window.Handle, $HOTKEY_ID_NEXT) }
        if ($f3Ok) { [void][Win32]::UnregisterHotKey($window.Handle, $HOTKEY_ID_PREV) }
        $failedList = $failedKeys -join " y "
        $NotifyIcon.ShowBalloonTip(5000, "Dofus Multi-switcher", "No se pudo registrar $failedList como hotkey global. ¿Las esta usando otra aplicacion? El icono sigue activo, pero F2/F3 no funcionaran hasta que relances el programa.", [System.Windows.Forms.ToolTipIcon]::Warning)
    } else {
        Register-ObjectEvent -InputObject $window -EventName HotKeyPressed -SourceIdentifier DofusHotkeyPressed -Action {
            $hotkeyId = $Event.SourceEventArgs.Id
            if ($hotkeyId -eq 1) {
                Switch-DofusWindow -Direction Next
            } elseif ($hotkeyId -eq 2) {
                Switch-DofusWindow -Direction Prev
            }
        } | Out-Null
    }

    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}
