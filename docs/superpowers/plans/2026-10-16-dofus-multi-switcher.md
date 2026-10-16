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

**Outcome of this revision:** implemented exactly as specified (commit `a77f6ce`), and it also failed — but with the failure fully characterized. `FindWindowEx($rebarHwnd, Zero, "MSTaskSwWClass", $null)` mysteriously returns `IntPtr.Zero` on this machine, even though `GetWindow($rebarHwnd, GW_CHILD)` independently proves that exact window (verified byte-for-byte on its class name) is the true, immediate child. `FindWindowEx` works correctly one level up (`Shell_TrayWnd` → `ReBarWindow32`) but not one level deeper into the rebar's hosted controls — root cause undetermined (no useful `GetLastError`, clean "not found" return), but `GetWindow`/`GW_CHILD`+`GW_HWNDNEXT` traversal is proven to work as a substitute. Separately, the exact line `$OBJID_CLIENT = [uint32]([int32]-4)` was found to throw `OverflowException` in Windows PowerShell 5.1 (PowerShell's cast operator is range-checked, unlike C#'s unchecked reinterpretation) — a second, independent bug in this plan's own code, previously masked by the `FindWindowEx` failure.

### Task 4 — Revision 2 (replace FindWindowEx traversal with GetWindow, fix OBJID_CLIENT cast)

**Files:**
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1` (add `GetWindow` and `GetClassName` to `[Win32]`; `FindWindowEx` from Revision 1 can stay, it's unused now but harmless — this project already has a precedent of Task 2 declaring P/Invoke signatures ahead of their first use)
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1` (replace the `FindWindowEx`-based traversal with a `Find-ChildWindowByClass` helper built on `GetWindow`, and fix the `OBJID_CLIENT` literal)

**Exact code — add to the `Win32` C# source in `WindowInterop.ps1`:**

```csharp
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
```

(`GetClassName`'s `StringBuilder` parameter needs `using System.Text;`, already present in the file's existing C# source for `GetWindowText`.)

**Exact code — full replacement of `TaskbarOrder.ps1`:**

```powershell
function global:Find-ChildWindowByClass {
    param(
        [Parameter(Mandatory)][IntPtr]$Parent,
        [Parameter(Mandatory)][string]$ClassName
    )

    $GW_CHILD = 5
    $GW_HWNDNEXT = 2

    $child = [Win32]::GetWindow($Parent, $GW_CHILD)
    while ($child -ne [IntPtr]::Zero) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][Win32]::GetClassName($child, $sb, $sb.Capacity)
        if ($sb.ToString() -eq $ClassName) {
            return $child
        }
        $child = [Win32]::GetWindow($child, $GW_HWNDNEXT)
    }
    return [IntPtr]::Zero
}

function global:Get-TaskbarOrder {
    try {
        $taskbarHwnd = [Win32]::FindWindow("Shell_TrayWnd", $null)
        if ($taskbarHwnd -eq [IntPtr]::Zero) {
            return $null
        }

        $rebarHwnd = Find-ChildWindowByClass -Parent $taskbarHwnd -ClassName "ReBarWindow32"
        if ($rebarHwnd -eq [IntPtr]::Zero) { return $null }

        $taskSwHwnd = Find-ChildWindowByClass -Parent $rebarHwnd -ClassName "MSTaskSwWClass"
        if ($taskSwHwnd -eq [IntPtr]::Zero) { return $null }

        $taskListHwnd = Find-ChildWindowByClass -Parent $taskSwHwnd -ClassName "MSTaskListWClass"
        if ($taskListHwnd -eq [IntPtr]::Zero) { return $null }

        $OBJID_CLIENT = [uint32]0xFFFFFFFC
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

**Manual verification:** same as Revision 1's verification — three Notepad windows, single-invocation capture, real pasted output. If `Get-TaskbarOrder` still returns `$null`, report exactly which `Find-ChildWindowByClass` call returned `IntPtr.Zero` (i.e., which class name wasn't found among its parent's children) or whether it got past all three traversals and failed at `AccessibleObjectFromWindow`/`accChildCount` instead — do not silently accept fallback without this detail. If it succeeds, this is the final, working implementation — no further revision needed.

**Outcome of this revision:** implemented exactly as specified (commit `6952081`). The `Find-ChildWindowByClass`/`GetWindow` traversal works perfectly — `ReBarWindow32`, `MSTaskSwWClass`, and `MSTaskListWClass` were all found correctly on the first try. The function still returns `$null`, but now for a third, much smaller reason: `[uint32]0xFFFFFFFC` also throws in PowerShell 5.1 — PowerShell's hex-literal parser interprets `0xFFFFFFFC` using 32-bit bit-pattern typing, i.e. as `Int32 -4` (not promoted to a wider/unsigned type the way the plan assumed), so the cast hits the identical checked-overflow exception as the original `[uint32]([int32]-4)` attempt. Every other part of the implementation is confirmed working.

### Task 4 — Revision 3 (final: fix the OBJID_CLIENT literal with an unambiguous byte conversion)

**Files:**
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1` — change exactly one line.

**Exact one-line fix**, replacing the `$OBJID_CLIENT` line inside `Get-TaskbarOrder`:

```powershell
$OBJID_CLIENT = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]-4), 0)
```

This reinterprets the 4 bytes of the `Int32` value `-4` directly as a `UInt32` (matching C#'s `unchecked((uint)-4)` semantics exactly), with no dependence on how PowerShell types a numeric or hex literal — this sidesteps both prior overflow failures for good.

Nothing else in the file changes.

**Manual verification:** same three-Notepad-window procedure, single-invocation capture. This should be the final, working implementation — `Get-TaskbarOrder` should now return the three titles in true left-to-right visual order (sorted by `accLocation`'s on-screen X coordinate). If it still fails, report exactly where (`AccessibleObjectFromWindow`'s `$hr` value, or the `accChildCount`/per-child loop) — at that point stop iterating and report DONE_WITH_CONCERNS; the project's documented Z-order fallback remains available regardless.

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
        # Get-TaskbarOrder's entries can carry a locale-dependent suffix beyond the
        # real window title (e.g. "<title>: 4 ventanas en ejecución" when Windows
        # groups several windows of the same app) - verified empirically on this
        # machine's real taskbar during Task 4. Match by prefix, not exact equality,
        # so this still works regardless of what (if anything) follows the title.
        $match = $remaining | Where-Object { $_.Title -and $title.StartsWith($_.Title) } | Select-Object -First 1
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
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
}
```

**Revision (post-implementation):** the line above originally read `[System.Windows.Forms.Application]::Run()`. Implementation and live testing (commit `0a2c0a9`) proved this never works: `Application.Run()` blocks the PowerShell runspace's single pipeline thread in a native message loop, and `Register-ObjectEvent`'s queued action is only drained when the runspace becomes idle between pipeline statements — which never happens while `Run()` itself is the never-returning statement. Confirmed via two isolated diagnostics: a raw `WndProc`-level log proved `WM_HOTKEY` really is delivered to the window, while the `Register-ObjectEvent` action never fired after a 6-second wait. Replacing it with the `DoEvents()`/`Start-Sleep` polling loop above was validated empirically: the action fired immediately and reliably, and a full real end-to-end Next/Prev/wraparound cycle test against real Notepad windows (via simulated `keybd_event` key presses) passed. The code block above already reflects this fix — implementers should use it as-is, not the original `Application.Run()`.

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
$shortcut.Arguments = "-NoExit -WindowStyle Minimized -ExecutionPolicy Bypass -File `"$scriptDir\dofus-multi.ps1`""
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

**Revision (post-final-review):** the `Arguments` line originally omitted `-NoExit`. The final whole-branch review found this meant a hotkey-registration failure (a documented live scenario on the real machine — F2/F3 intermittently claimed by DofusGuide) would `Write-Error` and then the script would reach its end, closing the minimized console immediately — the user would see no feedback at all, silently violating the spec's "informa claramente cuál ha fallado" requirement. Adding `-NoExit` keeps the (still-minimized) console alive after any failure path, so the error text remains visible if the user checks the taskbar; it has no effect on the success path, which never returns (the hotkey listener's `DoEvents()` loop runs forever). The code block above already reflects this fix.

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

---

# v2 Addendum: System Tray Icon + Cached Window Order

> Added after the full v1 implementation (Tasks 1-7) was complete and verified against the user's real Dofus windows. See `docs/superpowers/specs/2026-10-16-dofus-multi-switcher-design.md`, section "Revisión v2", for the full rationale: the user wants a tray-icon process (no visible console) and wants F2/F3 to use a cached window order instead of recomputing the taskbar on every keypress (perceptible lag). These three tasks continue the task numbering from the v1 plan above.

## v2 Global Constraints (in addition to the original Global Constraints section)

- No visible console window at any point during normal operation — the shortcut launches with `-WindowStyle Hidden`.
- F2/F3 must read a cached, in-memory window order (`$global:DofusCachedOrder`) rather than recomputing `Get-TaskbarOrder`/`Get-ProcessWindows` on every press. The cache is populated once at startup and refreshed only via the tray icon's "Actualizar" menu item.
- If hotkey registration fails, the tray icon must remain visible and functional (Actualizar/Salir still work) — do not exit the process, unlike v1's "fail and exit" behavior (this is an intentional, explicit supersession of the original design, confirmed with the user).
- Icon: use a built-in system icon (`[System.Drawing.SystemIcons]::Application`) — no custom icon asset.

---

### Task 8: Tray icon module

**Files:**
- Create: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TrayIcon.ps1`

**Interfaces:**
- Consumes: `Get-OrderedProcessHandles` (Task 5, `lib\WindowCycle.ps1`).
- Produces: `Start-TrayIcon` (no params) → creates and returns a `[System.Windows.Forms.NotifyIcon]`, visible, with a right-click context menu ("Actualizar", "Salir"), and sets `$global:DofusCachedOrder` to the current `Get-OrderedProcessHandles -ProcessName 'Dofus'` result as a side effect. Task 9's `Start-HotkeyListener` consumes the returned `NotifyIcon` object (for error balloons); Task 9's `Switch-DofusWindow` consumes `$global:DofusCachedOrder`.

- [ ] **Step 1: Write the tray icon module**

Create `C:\Users\19lil\Documents\organizador\dofus-multi\lib\TrayIcon.ps1`:

```powershell
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
```

Note: `.GetNewClosure()` is required here — these scriptblocks are invoked later, asynchronously, by the .NET event machinery (not from within `Start-TrayIcon`'s own call stack), so they need the enclosing scope's `$notifyIcon` captured explicitly rather than relying on PowerShell's default dynamic scoping (which only works for callbacks invoked synchronously within the same call stack, like Task 2's `EnumWindows` callback).

- [ ] **Step 2: Manually verify the tray icon and menu in isolation**

Run in a PowerShell window (interactive, so you can see and click the icon):
```powershell
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowInterop.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\DofusWindows.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\ForegroundHelper.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\TaskbarOrder.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1"
. "C:\Users\19lil\Documents\organizador\dofus-multi\lib\TrayIcon.ps1"

$icon = Start-TrayIcon
Write-Output "Cached order at startup: $($global:DofusCachedOrder -join ', ')"
while ($true) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
```
Expected: an icon appears in the system tray. Right-click it — confirm "Actualizar" and "Salir" both appear. Click "Actualizar" — confirm a balloon notification appears saying "Orden actualizado (N ventanas)." Click "Salir" — confirm the icon disappears from the tray and the PowerShell process exits (the `while` loop's console returns to a prompt / the window closes, depending on how you ran it).

- [ ] **Step 3: Commit**

Not a git repository (per the original plan) — actually this project IS a git repository as of the v1 implementation. Commit:
```bash
git add dofus-multi/lib/TrayIcon.ps1
git commit -m "feat: add system tray icon module with Actualizar/Salir menu"
```

---

### Task 9: Wire the cache and tray icon into the hotkey listener and entry script

**Files:**
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\WindowCycle.ps1` (replace `Switch-DofusWindow`'s body)
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\lib\HotkeyListener.ps1` (replace `Start-HotkeyListener`'s body)
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\dofus-multi.ps1` (dot-source the new lib, use the tray icon, MessageBox on mutex conflict)

**Interfaces:**
- Consumes: `Start-TrayIcon` (Task 8), `Get-NextWindowHandle` (Task 1), `Set-ForegroundWindowReliable` (Task 3), `[Win32]::GetForegroundWindow`/`RegisterHotKey`/`UnregisterHotKey` (Task 2).
- Produces: `Switch-DofusWindow -Direction` now reads `$global:DofusCachedOrder` instead of calling `Get-OrderedProcessHandles` each time. `Start-HotkeyListener -NotifyIcon <NotifyIcon>` (new mandatory parameter) now reports hotkey-registration failures via a balloon tip on that icon instead of `Write-Error`, and continues into the message loop regardless of failure (so the tray icon stays usable).

- [ ] **Step 1: Replace `Switch-DofusWindow` in `WindowCycle.ps1`**

Find the existing `function global:Switch-DofusWindow { ... }` block (appended in Task 5) and replace its entire body with:

```powershell
function global:Switch-DofusWindow {
    param(
        [Parameter(Mandatory)][ValidateSet('Next', 'Prev')]$Direction
    )

    $ordered = $global:DofusCachedOrder
    if (-not $ordered -or $ordered.Count -eq 0) {
        return
    }

    $current = [Win32]::GetForegroundWindow()
    $target = Get-NextWindowHandle -OrderedHandles $ordered -CurrentHandle $current -Direction $Direction

    if ($null -ne $target) {
        Set-ForegroundWindowReliable -Handle $target
    }
}
```

Leave `Get-OrderedProcessHandles` and `Get-NextWindowHandle` in the same file completely unchanged — `Get-OrderedProcessHandles` is still used by `Start-TrayIcon` (Task 8) for the initial cache and by the "Actualizar" menu handler for refreshes.

- [ ] **Step 2: Replace `Start-HotkeyListener` in `HotkeyListener.ps1`**

Keep the `HotkeyWindow`/`HotkeyEventArgs` C# type block exactly as-is. Replace only the `function global:Start-HotkeyListener { ... }` block with:

```powershell
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
```

Note: both failure-path and success-path end up at the same `while ($true)` message-pump loop — this is intentional. Unlike v1, a hotkey failure does NOT return early / exit the process; the tray icon (already created by Task 8's `Start-TrayIcon`, called before this function) must stay alive and interactive either way.

- [ ] **Step 3: Update the entry script**

Replace the full contents of `C:\Users\19lil\Documents\organizador\dofus-multi\dofus-multi.ps1` with:

```powershell
. "$PSScriptRoot\lib\WindowInterop.ps1"
. "$PSScriptRoot\lib\DofusWindows.ps1"
. "$PSScriptRoot\lib\ForegroundHelper.ps1"
. "$PSScriptRoot\lib\TaskbarOrder.ps1"
. "$PSScriptRoot\lib\WindowCycle.ps1"
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
```

`[System.Windows.Forms.MessageBox]` is available here because `lib\TrayIcon.ps1` and `lib\HotkeyListener.ps1` both `Add-Type -AssemblyName System.Windows.Forms` at dot-source time, before the mutex check runs.

- [ ] **Step 4: Manually verify with real or Notepad-stand-in processes**

With `Get-DofusWindows`-equivalent testing not available without real Dofus running, verify using the real `'Dofus'` target if the user currently has Dofus windows open (preferred — this machine often does), otherwise temporarily point `Start-TrayIcon`'s and `Switch-DofusWindow`'s `-ProcessName 'Dofus'` calls at `'notepad'` in a throwaway copy for testing, same technique as prior tasks.

Run the real, unmodified `dofus-multi.ps1` in a visible (non-hidden) PowerShell window first, so you can observe behavior directly:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\19lil\Documents\organizador\dofus-multi\dofus-multi.ps1"
```
Expected: no console text (there shouldn't be any `Write-Host` left in the success path), but a tray icon appears. Press F2/F3 (real keys, or verify via `keybd_event` injection from a second PowerShell window as in prior tasks) and confirm focus cycles using the order that was cached at startup — then open/close a window, press F2/F3 again, and confirm the cycle does NOT reflect the change (still using the stale cache) — then click "Actualizar" and confirm it now does. This proves the caching behavior (the actual point of this task) rather than just re-confirming live recompute (which v1 already proved and this task deliberately removes).

Also verify the hotkey-failure path if F2/F3 happen to be claimed at test time (real machine fact from Task 6/7): confirm a balloon tip appears and the tray icon (Actualizar/Salir) still works afterward.

- [ ] **Step 5: Commit**

```bash
git add dofus-multi/lib/WindowCycle.ps1 dofus-multi/lib/HotkeyListener.ps1 dofus-multi/dofus-multi.ps1
git commit -m "feat: cache window order, report hotkey failures via tray balloon instead of exiting"
```

---

### Task 10: Hidden launch + final real end-to-end verification

**Files:**
- Modify: `C:\Users\19lil\Documents\organizador\dofus-multi\New-DesktopShortcut.ps1`

**Interfaces:**
- Consumes: nothing (standalone setup script, unchanged interface).
- Produces: the same `.lnk` file, now launching with `-WindowStyle Hidden` instead of `-WindowStyle Minimized -NoExit` (no console at all, not even minimized).

- [ ] **Step 1: Update the shortcut arguments**

In `C:\Users\19lil\Documents\organizador\dofus-multi\New-DesktopShortcut.ps1`, change:
```powershell
$shortcut.Arguments = "-NoExit -WindowStyle Minimized -ExecutionPolicy Bypass -File `"$scriptDir\dofus-multi.ps1`""
```
to:
```powershell
$shortcut.Arguments = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptDir\dofus-multi.ps1`""
```
Nothing else in the file changes.

- [ ] **Step 2: Re-run it and confirm the shortcut was updated**

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\19lil\Documents\organizador\dofus-multi\New-DesktopShortcut.ps1"
```
Then inspect the shortcut's resolved `Arguments` property (via `WScript.Shell`, same technique as Task 7) and confirm it now reads `-WindowStyle Hidden -ExecutionPolicy Bypass -File "...\dofus-multi.ps1"` with no `-NoExit`.

- [ ] **Step 3: Full real end-to-end verification**

1. Double-click `Dofus Multi.lnk` on the Desktop.
2. Confirm NO console window (not even briefly) appears, and a tray icon appears near the clock within a couple seconds.
3. With real Dofus windows open, press F2/F3 (or simulate via `keybd_event` from another window) and confirm focus cycles correctly using the startup-cached order.
4. Open or close a Dofus window, press F2/F3 again, confirm it still uses the old cached order (expected — this is the intended caching behavior), then right-click the tray icon → "Actualizar", confirm the balloon tip appears, then press F2/F3 again and confirm the order now reflects the change.
5. Right-click the icon → "Salir" — confirm the icon disappears and the process is gone (`Get-Process powershell` no longer shows it).
6. Double-click the shortcut twice in a row — confirm the second launch shows the "Ya hay una instancia..." MessageBox and the first instance's tray icon is unaffected.

- [ ] **Step 4: Commit**

```bash
git add dofus-multi/New-DesktopShortcut.ps1
git commit -m "feat: launch hidden (no console) instead of minimized"
```

## v2 Self-Review Notes

- **Spec coverage:** tray icon with Actualizar/Salir (Task 8), cached order replacing live recompute (Task 9's `Switch-DofusWindow`), balloon-based error reporting with tray icon staying alive on hotkey failure (Task 9's `Start-HotkeyListener`), MessageBox for the mutex-conflict case (Task 9's entry script), hidden launch (Task 10). All v2 design requirements map to a task.
- **Placeholder scan:** no TBD/TODO markers; every step has complete code or exact commands with expected output.
- **Type consistency:** `Start-TrayIcon` (Task 8) returns a `[System.Windows.Forms.NotifyIcon]`, which Task 9's `Start-HotkeyListener -NotifyIcon` consumes with the matching type constraint. `$global:DofusCachedOrder` is written by both `Start-TrayIcon` (initial) and the "Actualizar" click handler (refresh) in Task 8, and read by `Switch-DofusWindow` in Task 9 — same variable name, same shape (`[IntPtr[]]`, matching `Get-OrderedProcessHandles`'s existing return type from Task 5).
