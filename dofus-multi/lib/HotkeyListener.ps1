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
    $window = New-Object HotkeyWindow
    [void]$window.Handle  # forces native handle creation without showing the form

    $HOTKEY_ID_NEXT = 1
    $HOTKEY_ID_PREV = 2
    $MOD_NONE = 0x0000
    $VK_F2 = 0x71
    $VK_F3 = 0x72

    if (-not [Win32]::RegisterHotKey($window.Handle, $HOTKEY_ID_NEXT, $MOD_NONE, $VK_F2)) {
        Write-Error "No se pudo registrar F2 como hotkey global. ¿La está usando otra aplicación?"
        return
    }
    if (-not [Win32]::RegisterHotKey($window.Handle, $HOTKEY_ID_PREV, $MOD_NONE, $VK_F3)) {
        [void][Win32]::UnregisterHotKey($window.Handle, $HOTKEY_ID_NEXT)
        Write-Error "No se pudo registrar F3 como hotkey global. ¿La está usando otra aplicación?"
        return
    }

    Register-ObjectEvent -InputObject $window -EventName HotKeyPressed -SourceIdentifier DofusHotkeyPressed -Action {
        $hotkeyId = $Event.SourceEventArgs.Id
        if ($hotkeyId -eq 1) {
            Switch-DofusWindow -Direction Next
        } elseif ($hotkeyId -eq 2) {
            Switch-DofusWindow -Direction Prev
        }
    } | Out-Null

    Write-Host "Dofus Multi-switcher activo. F2 = siguiente, F3 = anterior. Cierra esta ventana para salir."
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}
