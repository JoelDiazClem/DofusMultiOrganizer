function global:Set-ForegroundWindowReliable {
    param(
        [Parameter(Mandatory)][IntPtr]$Handle
    )

    $SW_RESTORE = 9
    $VK_MENU = 0x12
    $KEYEVENTF_KEYUP = 0x2

    if ([Win32]::IsIconic($Handle)) {
        [void][Win32]::ShowWindow($Handle, $SW_RESTORE)
    }

    # Windows blocks SetForegroundWindow from background processes unless a
    # recent input event is detected on the calling thread; tapping Alt
    # satisfies that check without visibly doing anything to the target window.
    [Win32]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
    [Win32]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)

    [void][Win32]::SetForegroundWindow($Handle)
}
