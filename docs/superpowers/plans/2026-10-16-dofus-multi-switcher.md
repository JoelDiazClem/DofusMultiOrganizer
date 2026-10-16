# Dofus Multi-Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PowerShell-based background utility that lets the user cycle keyboard focus between their open Dofus game windows using global F2 (next) / F3 (previous) hotkeys, launched from a desktop shortcut.

**Architecture:** A single PowerShell entry script dot-sources small, single-responsibility library files (Win32 interop, window enumeration, taskbar-order detection via UI Automation, pure cycle-index logic, foreground-focus helper, hotkey listener). The entry script registers global hotkeys on a hidden WinForms window and blocks in a message loop; each hotkey press recomputes the current set of Dofus windows and their taskbar order live, then focuses the next/previous one.

**Tech Stack:** Windows PowerShell 5.1 (the only PowerShell present on this machine), .NET Framework types via `Add-Type` (`user32.dll` P/Invoke, `System.Windows.Forms`, `System.Windows.Automation`), Pester 3.4.0 (built into Windows PowerShell 5.1) for the one unit-testable piece of pure logic.

## Global Constraints

- Target machine runs Windows PowerShell 5.1.19041.6456 (Windows 10 build 10.0.19045) — all code must be Windows PowerShell 5.1 compatible, not PowerShell 7/Core-only syntax.
- Only Pester 3.4.0 is installed — tests must use Pester 3.x syntax (`Should Be`, not the `Should -Be` operator syntax from Pester 4/5).
- No external modules may be installed — use only built-in .NET Framework / Win32 APIs (`Add-Type`, `System.Windows.Forms`, `System.Windows.Automation`, `user32.dll`).
- The game process to detect is named `Dofus` (verified: `Dofus.exe` under `%LOCALAPPDATA%\Ankama\Dofus-dofus3\`, `Dofus-beta\`, `Dofus-experimental\`).
- The script must never automate the Ankama Launcher or any login flow — it only ever reads/focuses windows of already-running `Dofus.exe` processes.
- All project files live under `C:\Users\19lil\Documents\organizador\dofus-multi\`.
- F2/F3 hotkeys are global and unmodified (no Ctrl/Alt/Shift) — if registration fails (already in use), the script must report clearly which key failed and stop, not run partially.

---

## File Structure

```
C:\Users\19lil\Documents\organizador\dofus-multi\
  dofus-multi.ps1              # Entry point: dot-sources libs, mutex check, starts hotkey listener
  lib\
    WindowInterop.ps1           # Win32 P/Invoke declarations (user32.dll) - no logic
    DofusWindows.ps1            # Get-ProcessWindows / Get-DofusWindows
    ForegroundHelper.ps1        # Set-ForegroundWindowReliable
    TaskbarOrder.ps1            # Get-TaskbarOrder (UI Automation)
    WindowCycle.ps1             # Get-NextWindowHandle (pure logic) + Get-OrderedProcessHandles + Switch-DofusWindow
    HotkeyListener.ps1          # HotkeyWindow .NET class + Start-HotkeyListener
  tests\
    WindowCycle.Tests.ps1       # Pester tests for Get-NextWindowHandle
  New-DesktopShortcut.ps1       # One-off setup script that creates the desktop .lnk
```

---

### Task 1: Pure window-cycle index logic (TDD)

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1`
- Test: `C:\Users\19lil\Documents\organizador\dofus-multi\tests\WindowCycle.Tests.ps1`

**Interfaces:**
- Produces: `Get-NextWindowHandle -OrderedHandles <array> -CurrentHandle <object> -Direction ('Next'|'Prev')` → returns the element of `OrderedHandles` to focus next, or `$null` if `OrderedHandles` is empty. This is the only function later tasks rely on from this file at this stage (Task 5 appends more functions to the same file).

This is the one piece of genuinely pure, OS-independent logic in the whole project (no Win32 calls), so it is the only part that gets real red/green unit tests.

- [ ] **Step 1: Write the failing tests**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\tests\WindowCycle.Tests.ps1`:

```powershell
. "$PSScriptRoot\..\lib\WindowCycle.ps1"

Describe "Get-NextWindowHandle" {

    It "returns null when the list is empty" {
        $result = Get-NextWindowHandle -OrderedHandles @() -CurrentHandle 999 -Direction Next
        $result | Should Be $null
    }

    It "Next from no-match (-1) goes to the first element" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 999 -Direction Next
        $result | Should Be 10
    }

    It "Prev from no-match (-1) goes to the last element" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 999 -Direction Prev
        $result | Should Be 40
    }

    It "Next from a middle element advances by one" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 20 -Direction Next
        $result | Should Be 30
    }

    It "Prev from a middle element goes back by one" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 30 -Direction Prev
        $result | Should Be 20
    }

    It "Next from the last element wraps to the first" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 40 -Direction Next
        $result | Should Be 10
    }

    It "Prev from the first element wraps to the last" {
        $result = Get-NextWindowHandle -OrderedHandles @(10,20,30,40) -CurrentHandle 10 -Direction Prev
        $result | Should Be 40
    }

    It "works with a single-element list (wraps to itself)" {
        $result = Get-NextWindowHandle -OrderedHandles @(10) -CurrentHandle 10 -Direction Next
        $result | Should Be 10
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```powershell
Invoke-Pester "C:\Users\19lil\Documents\organizador\dofus-multi\tests\WindowCycle.Tests.ps1"
```
Expected: errors/failures for every `It`, because `Get-NextWindowHandle` is not defined yet (dot-sourcing a nonexistent file or missing function).

- [ ] **Step 3: Create the library folder and write the minimal implementation**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1`:

```powershell
function global:Get-NextWindowHandle {
    param(
        [Parameter(Mandatory)][array]$OrderedHandles,
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
    }

    return $OrderedHandles[$nextIndex]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```powershell
Invoke-Pester "C:\Users\19lil\Documents\organizador\dofus-multi\tests\WindowCycle.Tests.ps1"
```
Expected: `Tests completed` with 0 failed, 8 passed.

- [ ] **Step 5: Commit**

This directory is not a git repository (confirmed during design), so skip `git commit`. Just leave the files saved.

---

### Task 2: Win32 interop foundation + Dofus window enumeration

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1`
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `[Win32]` .NET type with static methods: `EnumWindows`, `IsWindowVisible`, `GetWindowTextLength`, `GetWindowText`, `GetWindowThreadProcessId`, `GetForegroundWindow`, `SetForegroundWindow`, `ShowWindow`, `IsIconic`, `keybd_event`, `FindWindow`, `RegisterHotKey`, `UnregisterHotKey`. Later tasks (3, 4, 5, 6) call these directly.
  - `Get-ProcessWindows -ProcessName <string>` → array of `[PSCustomObject]@{ Handle = [IntPtr]; Title = [string] }` for every visible top-level window owned by a process with that name.
  - `Get-DofusWindows` → same shape, pre-filtered to `-ProcessName 'Dofus'`. Used by Task 5.

- [ ] **Step 1: Write the Win32 interop declarations**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1`:

```powershell
if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class Win32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}
"@
}
```

- [ ] **Step 2: Write Get-ProcessWindows / Get-DofusWindows**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1`:

```powershell
function global:Get-ProcessWindows {
    param(
        [Parameter(Mandatory)][string]$ProcessName
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    $callback = {
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if ([Win32]::IsWindowVisible($hWnd)) {
            $len = [Win32]::GetWindowTextLength($hWnd)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 1)
                [void][Win32]::GetWindowText($hWnd, $sb, $sb.Capacity)
                $title = $sb.ToString()

                [uint32]$procId = 0
                [void][Win32]::GetWindowThreadProcessId($hWnd, [ref]$procId)

                $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -eq $ProcessName) {
                    $results.Add([PSCustomObject]@{ Handle = $hWnd; Title = $title })
                }
            }
        }
        return $true
    }

    [void][Win32]::EnumWindows($callback, [IntPtr]::Zero)
    return $results
}

function global:Get-DofusWindows {
    Get-ProcessWindows -ProcessName 'Dofus'
}
```

- [ ] **Step 3: Manually verify against real windows (Notepad stand-in)**

There is no running Dofus process during development, so verify the enumeration logic against Notepad windows with distinct titles.

Run in a PowerShell session:
```powershell
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-1.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-2.txt"
```
(Create the two empty files first with `New-Item` if they don't exist, so Notepad opens without a "Save?" prompt complication — either path works, just note the exact titles Notepad shows.)

Then:
```powershell
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1"
Get-ProcessWindows -ProcessName 'notepad' | Format-Table Handle, Title -AutoSize
```
Expected: a table with exactly 2 rows, one per open Notepad window, each with a non-zero `Handle` and the correct file name in `Title`.

Close both Notepad windows afterward.

- [ ] **Step 4: Commit**

Not a git repository — skip `git commit`.

---

### Task 3: Reliable foreground-focus helper

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\ForegroundHelper.ps1`

**Interfaces:**
- Consumes: `[Win32]::IsIconic`, `[Win32]::ShowWindow`, `[Win32]::keybd_event`, `[Win32]::SetForegroundWindow` from Task 2's `WindowInterop.ps1`.
- Produces: `Set-ForegroundWindowReliable -Handle <IntPtr>` (no return value). Used by Task 5's `Switch-DofusWindow`.

- [ ] **Step 1: Write the implementation**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\ForegroundHelper.ps1`:

```powershell
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
```

- [ ] **Step 2: Manually verify against real windows (Notepad stand-in)**

Run:
```powershell
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-1.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-2.txt"
```

Click into the second Notepad window so it has focus, then minimize the first one by hand (or via `[Win32]::ShowWindow`). Then:

```powershell
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\ForegroundHelper.ps1"

$targets = Get-ProcessWindows -ProcessName 'notepad'
$minimizedOne = $targets | Where-Object { $_.Title -like '*dofus-test-1*' }
Set-ForegroundWindowReliable -Handle $minimizedOne.Handle
```
Expected: the minimized `dofus-test-1` Notepad window restores and becomes the active, focused window on screen.

Close both Notepad windows afterward.

- [ ] **Step 3: Commit**

Not a git repository — skip `git commit`.

---

### Task 4: Taskbar visual order via UI Automation

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1`

**Interfaces:**
- Consumes: `[Win32]::FindWindow` from Task 2's `WindowInterop.ps1`.
- Produces: `Get-TaskbarOrder` → an ordered `[string[]]` of window titles as they appear left-to-right in the Windows taskbar, or `$null` if the taskbar structure couldn't be read. Used by Task 5.

- [ ] **Step 1: Write the implementation**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1`:

```powershell
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function global:Get-TaskbarOrder {
    try {
        $taskbarHwnd = [Win32]::FindWindow("Shell_TrayWnd", $null)
        if ($taskbarHwnd -eq [IntPtr]::Zero) {
            return $null
        }

        $taskbarElement = [System.Windows.Automation.AutomationElement]::FromHandle($taskbarHwnd)

        $listCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, "MSTaskListWClass")
        $taskListElement = $taskbarElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $listCondition)

        if (-not $taskListElement) {
            return $null
        }

        $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Button)
        $buttons = $taskListElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children, $buttonCondition)

        $order = New-Object System.Collections.Generic.List[string]
        foreach ($button in $buttons) {
            $order.Add($button.Current.Name)
        }
        return $order
    } catch {
        return $null
    }
}
```

- [ ] **Step 2: Manually verify against real windows (Notepad stand-in)**

Run:
```powershell
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-1.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-2.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-3.txt"
```

Note the visual left-to-right order of their icons in the Windows taskbar. Then:

```powershell
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1"
Get-TaskbarOrder
```
Expected: a list of window titles containing the three `dofus-test-*.txt` Notepad windows (mixed with other taskbar entries you have open), in the same left-to-right order you observed on screen.

Close the three Notepad windows afterward.

- [ ] **Step 3: Commit**

Not a git repository — skip `git commit`.

---

### Task 4 — Revision (post-implementation)

**Outcome of the original Task 4 as written:** implemented exactly as specified and verified live on the target machine. `Get-TaskbarOrder` (UI Automation / `System.Windows.Automation`) correctly finds `Shell_TrayWnd` and its `MSTaskListWClass` descendant (real, on-screen bounding rectangle), but every UIA enumeration method (`FindAll` Children/Descendants, `TreeWalker` Raw/Control view) returns **zero child elements** for that node, with or without real windows open — on this exact machine, which is the machine the user will actually run Dofus on. This was independently diagnosed (session, bitness, STA/message-pump, integrity level all ruled out) as an environment-specific limitation of this Windows installation's taskbar accessibility provider, not a bug in the implementation. Commit `51a6650` keeps the brief's original UIA code as-is (kept for the record; superseded below).

**Decision (user, asked directly given this changes real delivered behavior):** rather than accept the spec's documented Z-order fallback permanently, attempt the classic MSAA/`IAccessible` technique (via `oleacc.dll`), which is what pre-UIA taskbar automation tools have historically used and does not depend on the modern UIA-over-taskbar bridge that failed above.

**Revised approach:**
- Add `FindWindowEx` to the `[Win32]` type in `WindowInterop.ps1` (Task 2's file), to walk `Shell_TrayWnd` → `ReBarWindow32` → `MSTaskSwWClass` → `MSTaskListWClass` by real child HWNDs (these are genuine native child windows on classic Windows 10 taskbars, not virtual UIA nodes).
- Add a new `Oleacc` P/Invoke type (`AccessibleObjectFromWindow`) and use the .NET Framework's built-in `Accessibility` assembly (`Accessibility.IAccessible`) to fetch the task list's MSAA accessible object directly, bypassing the UIA bridge entirely.
- Enumerate children via `accChildCount`/`accName`/`accLocation` (simple child IDs, not separate COM objects), and sort by each child's `accLocation` left (x) screen coordinate — this gives true left-to-right visual order directly from on-screen position, which is even more robust than relying on enumeration order.
- `Get-TaskbarOrder`'s contract to callers is unchanged: still returns an ordered `[string[]]` of window titles, or `$null` on failure. Task 5 is unaffected either way.

**Files:**
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1` (add `FindWindowEx` to `[Win32]`, add new `[Oleacc]` type)
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1` (replace the `Get-TaskbarOrder` body; keep the function name/signature/contract identical)

**Exact code — append to the `Win32` C# source in `WindowInterop.ps1`** (inside the existing `public class Win32 { ... }` block, alongside the other methods):

```csharp
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
```

**Exact code — new type, added to `WindowInterop.ps1` after the existing `Win32` type guard block:**

```powershell
Add-Type -AssemblyName Accessibility

if (-not ([System.Management.Automation.PSTypeName]'Oleacc').Type) {
    Add-Type -ReferencedAssemblies Accessibility -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Accessibility;

public class Oleacc {
    [DllImport("oleacc.dll")]
    public static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint dwId, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IAccessible ppvObject);
}
"@
}
```

**Exact code — full replacement of `TaskbarOrder.ps1`:**

```powershell
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function global:Get-TaskbarOrder {
    try {
        $taskbarHwnd = [Win32]::FindWindow("Shell_TrayWnd", $null)
        if ($taskbarHwnd -eq [IntPtr]::Zero) {
            return $null
        }

        $rebarHwnd = [Win32]::FindWindowEx($taskbarHwnd, [IntPtr]::Zero, "ReBarWindow32", $null)
        if ($rebarHwnd -eq [IntPtr]::Zero) { return $null }

        $taskSwHwnd = [Win32]::FindWindowEx($rebarHwnd, [IntPtr]::Zero, "MSTaskSwWClass", $null)
        if ($taskSwHwnd -eq [IntPtr]::Zero) { return $null }

        $taskListHwnd = [Win32]::FindWindowEx($taskSwHwnd, [IntPtr]::Zero, "MSTaskListWClass", $null)
        if ($taskListHwnd -eq [IntPtr]::Zero) { return $null }

        $OBJID_CLIENT = [uint32]([int32]-4)
        $IID_IAccessible = [Guid]"618736E0-3C3D-11CF-810C-00AA00389B71"
        $iacc = $null
        $hr = [Oleacc]::AccessibleObjectFromWindow($taskListHwnd, $OBJID_CLIENT, [ref]$IID_IAccessible, [ref]$iacc)
        if ($hr -ne 0 -or $null -eq $iacc) {
            return $null
        }

        $count = $iacc.accChildCount
        if ($count -le 0) {
            return $null
        }

        $items = New-Object System.Collections.Generic.List[PSCustomObject]
        for ($i = 1; $i -le $count; $i++) {
            $childId = [object]$i
            $name = $null
            $left = $i
            try { $name = $iacc.accName($childId) } catch {}
            try {
                [int]$l = 0; [int]$t = 0; [int]$w = 0; [int]$h = 0
                $iacc.accLocation([ref]$l, [ref]$t, [ref]$w, [ref]$h, $childId)
                $left = $l
            } catch {}
            if ($name) {
                $items.Add([PSCustomObject]@{ Name = $name; Left = $left })
            }
        }
        if ($items.Count -eq 0) {
            return $null
        }

        return ($items | Sort-Object Left | ForEach-Object { $_.Name })
    } catch {
        return $null
    }
}
```

**Manual verification:** repeat the original Task 4 Step 2 verification (three Notepad windows with distinct `dofus-test-*.txt` names, confirm visual left-to-right order, dot-source and call `Get-TaskbarOrder`), run as a single self-contained PowerShell invocation producing real, pasted-verbatim output. If this also returns `$null`, report the exact `$hr` value from `AccessibleObjectFromWindow` and which step (`FindWindowEx` chain vs. `AccessibleObjectFromWindow` vs. `accChildCount`) failed — do not silently fall back without reporting which layer broke.

---

### Task 5: Order composition and the switch action

**Files:**
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1` (append below the Task 1 content)

**Interfaces:**
- Consumes: `Get-NextWindowHandle` (Task 1, same file), `Get-ProcessWindows`/`Get-DofusWindows` (Task 2), `Get-TaskbarOrder` (Task 4), `Set-ForegroundWindowReliable` (Task 3), `[Win32]::GetForegroundWindow` (Task 2).
- Produces:
  - `Get-OrderedProcessHandles -ProcessName <string>` → ordered `[IntPtr[]]` of that process's visible window handles, taskbar-order first, with any windows UI Automation couldn't place appended at the end; falls back to `Get-ProcessWindows`'s raw (Z-order) list if `Get-TaskbarOrder` returns `$null`, printing a warning.
  - `Switch-DofusWindow -Direction ('Next'|'Prev')` (no return value) — the function the hotkey listener (Task 6) calls directly.

- [ ] **Step 1: Append the composition and switch functions**

Append to `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1`:

```powershell
function global:Get-OrderedProcessHandles {
    param(
        [Parameter(Mandatory)][string]$ProcessName
    )

    $windows = Get-ProcessWindows -ProcessName $ProcessName
    if (-not $windows -or $windows.Count -eq 0) {
        return @()
    }

    $taskbarOrder = Get-TaskbarOrder
    if (-not $taskbarOrder) {
        Write-Host "Aviso: no se pudo leer el orden de la barra de tareas, usando orden alternativo."
        return @($windows | ForEach-Object { $_.Handle })
    }

    $ordered = [System.Collections.Generic.List[IntPtr]]::new()
    $remaining = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($w in $windows) { $remaining.Add($w) }

    foreach ($title in $taskbarOrder) {
        $match = $remaining | Where-Object { $_.Title -eq $title } | Select-Object -First 1
        if ($match) {
            $ordered.Add($match.Handle)
            [void]$remaining.Remove($match)
        }
    }
    foreach ($leftover in $remaining) {
        $ordered.Add($leftover.Handle)
    }

    return $ordered
}

function global:Switch-DofusWindow {
    param(
        [Parameter(Mandatory)][ValidateSet('Next', 'Prev')]$Direction
    )

    $ordered = Get-OrderedProcessHandles -ProcessName 'Dofus'
    if ($ordered.Count -eq 0) {
        Write-Host "No hay ninguna ventana de Dofus abierta ahora mismo."
        return
    }

    $current = [Win32]::GetForegroundWindow()
    $target = Get-NextWindowHandle -OrderedHandles $ordered -CurrentHandle $current -Direction $Direction

    if ($null -ne $target) {
        Set-ForegroundWindowReliable -Handle $target
        $matchedTitle = (Get-DofusWindows | Where-Object { $_.Handle -eq $target } | Select-Object -First 1).Title
        Write-Host "Cambiando a: $matchedTitle"
    }
}
```

- [ ] **Step 2: Manually verify the composition against Notepad windows**

Run:
```powershell
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-1.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-2.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-3.txt"
```

```powershell
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\ForegroundHelper.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1"

Get-OrderedProcessHandles -ProcessName 'notepad'
```
Expected: an ordered list of 3 handles matching the visual taskbar order of the 3 Notepad windows.

Then simulate a couple of cycle steps manually (since `Switch-DofusWindow` is hardcoded to `'Dofus'`, exercise the same underlying pieces directly):
```powershell
$ordered = Get-OrderedProcessHandles -ProcessName 'notepad'
$current = [Win32]::GetForegroundWindow()
$next = Get-NextWindowHandle -OrderedHandles $ordered -CurrentHandle $current -Direction Next
Set-ForegroundWindowReliable -Handle $next
```
Expected: focus visibly moves to the next Notepad window in taskbar order.

Close the three Notepad windows afterward.

- [ ] **Step 3: Commit**

Not a git repository — skip `git commit`.

---

### Task 6: Global hotkey listener, single-instance guard, and entry script

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\HotkeyListener.ps1`
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\dofus-multi.ps1`

**Interfaces:**
- Consumes: `[Win32]::RegisterHotKey`/`UnregisterHotKey` (Task 2), `Switch-DofusWindow` (Task 5).
- Produces: `Start-HotkeyListener` — registers F2/F3 as global hotkeys, starts the message loop, and never returns until the process is killed (closing the console window). This is called once, from `dofus-multi.ps1`.

- [ ] **Step 1: Write the HotkeyWindow type and Start-HotkeyListener**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\HotkeyListener.ps1`:

```powershell
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
    [System.Windows.Forms.Application]::Run()
}
```

- [ ] **Step 2: Write the entry script**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\dofus-multi.ps1`:

```powershell
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
```

- [ ] **Step 3: Verify hotkey registration and end-to-end switching with Notepad stand-ins**

Open three Notepad windows as before:
```powershell
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-1.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-2.txt"
notepad.exe "C:\Users\19lil\AppData\Local\Temp\dofus-test-3.txt"
```

Temporarily point the entry script at `notepad` instead of `Dofus` to test without a real Dofus process running. In a new PowerShell window:
```powershell
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\ForegroundHelper.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\HotkeyListener.ps1"

function global:Switch-DofusWindow {
    param([Parameter(Mandatory)][ValidateSet('Next','Prev')]$Direction)
    $ordered = Get-OrderedProcessHandles -ProcessName 'notepad'
    if ($ordered.Count -eq 0) { Write-Host "No hay ninguna ventana de notepad abierta ahora mismo."; return }
    $current = [Win32]::GetForegroundWindow()
    $target = Get-NextWindowHandle -OrderedHandles $ordered -CurrentHandle $current -Direction $Direction
    if ($null -ne $target) { Set-ForegroundWindowReliable -Handle $target }
}

Start-HotkeyListener
```
Expected: console prints the "activo" message. Click on one of the Notepad windows to focus it, then press F2 — focus should move to the next Notepad window in taskbar order. Press F3 — focus should move back. Press F2 repeatedly and confirm it cycles through all three and wraps around.

Press Ctrl+C or close the console window to stop; confirm F2/F3 no longer do anything afterward (hotkeys released automatically on process exit).

Close the three Notepad windows afterward.

- [ ] **Step 4: Commit**

Not a git repository — skip `git commit`.

---

### Task 7: Desktop shortcut and real end-to-end verification

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\New-DesktopShortcut.ps1`

**Interfaces:**
- Consumes: nothing (standalone setup script).
- Produces: a `.lnk` file on the user's Desktop that launches `dofus-multi.ps1` minimized.

- [ ] **Step 1: Write the shortcut-creation script**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\New-DesktopShortcut.ps1`:

```powershell
$scriptDir = $PSScriptRoot
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "Dofus Multi.lnk"

$wshShell = New-Object -ComObject WScript.Shell
$shortcut = $wshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-WindowStyle Minimized -ExecutionPolicy Bypass -File `"$scriptDir\dofus-multi.ps1`""
$shortcut.WorkingDirectory = $scriptDir
$shortcut.Description = "Lanza el cambiador de ventanas de Dofus (F2/F3)"
$shortcut.Save()

Write-Host "Acceso directo creado en: $shortcutPath"
```

- [ ] **Step 2: Run it and confirm the shortcut was created**

Run:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\19lil\Documents\organizador\dofus-multi\New-DesktopShortcut.ps1"
```
Expected output: `Acceso directo creado en: C:\Users\19lil\Desktop\Dofus Multi.lnk`

Verify the file exists:
```powershell
Test-Path "$([Environment]::GetFolderPath('Desktop'))\Dofus Multi.lnk"
```
Expected: `True`

- [ ] **Step 3: Full end-to-end verification with real Dofus windows**

This step requires the user to actually have Dofus accounts open — hand off to them (or run it live together):

1. Launch 2 or more Dofus accounts manually via the Ankama Launcher, as usual.
2. Double-click `Dofus Multi.lnk` on the Desktop.
3. Confirm a minimized PowerShell window appears and (if restored briefly to check) shows "Dofus Multi-switcher activo. F2 = siguiente, F3 = anterior.".
4. Click into one Dofus window, press F2, confirm focus moves to the next Dofus window in taskbar order.
5. Press F3, confirm focus moves back.
6. Close one Dofus account's game window, press F2/F3 again, confirm the remaining windows still cycle correctly without restarting the script.
7. Double-click `Dofus Multi.lnk` again while the first instance is still running — confirm it prints "Ya hay una instancia de Dofus Multi-switcher activa." and exits instead of registering duplicate hotkeys.
8. Close the minimized console window and confirm F2/F3 stop doing anything afterward.

- [ ] **Step 4: Commit**

Not a git repository — skip `git commit`.

---

## Self-Review Notes

- **Spec coverage:** entry point/shortcut (Task 7), process-based window detection (Task 2), taskbar-order detection with fallback (Task 4, fallback wired in Task 5), live recomputation per keypress (Task 5's `Switch-DofusWindow` calls `Get-OrderedProcessHandles` fresh every time), reliable foreground focus (Task 3), global F2/F3 hotkeys with clear failure reporting (Task 6), single-instance guard (Task 6), no-Dofus-window message (Task 5), window-closes-mid-session handled by live recompute (Task 5/7 step 6). All spec requirements map to a task.
- **Placeholder scan:** no TBD/TODO markers; every step has complete, runnable code or exact commands with expected output.
- **Type consistency:** `Get-NextWindowHandle` signature (`-OrderedHandles`, `-CurrentHandle`, `-Direction`) is identical between Task 1's definition and Task 5's usage. `Get-OrderedProcessHandles -ProcessName` and `Switch-DofusWindow -Direction` are used consistently between Task 5 and Task 6. `Get-DofusWindows` / `Get-ProcessWindows` return the same `[PSCustomObject]@{Handle; Title}` shape everywhere it's consumed.
