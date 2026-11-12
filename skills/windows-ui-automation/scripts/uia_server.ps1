# Persistent UIA automation server — communicates via named pipe transport.
# Zero dependencies: uses only built-in .NET assemblies available on all Windows 10/11 systems.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File uia_server.ps1 [--pipe-name <name>]
#
# Protocol: newline-delimited JSON (one JSON object per line) over named pipe.
# Request:  {"cmd": "...", "args": {...}}
# Response: {"ok": true, ...} or {"ok": false, "error": "..."}

$ErrorActionPreference = 'Stop'

# ── Load assemblies once (the whole point of keeping this process alive) ──
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# ── Native SendInput for clicking + PrintWindow for screenshots ──
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NativeInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public InputUnion u;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X, Y;
    }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

    public const uint INPUT_MOUSE    = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint MOUSEEVENTF_MOVE        = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN    = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP      = 0x0004;
    public const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    public const uint MOUSEEVENTF_ABSOLUTE    = 0x8000;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const ushort VK_SHIFT   = 0x10;
    public const ushort VK_CONTROL = 0x11;
    public const ushort VK_ESCAPE  = 0x1B;
    const int SM_CXDRAG = 68, SM_CYDRAG = 69;
    const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
    const uint GA_ROOTOWNER = 3;

    static INPUT Mouse(uint flags, int dx, int dy) {
        INPUT i = new INPUT();
        i.type = INPUT_MOUSE;
        i.u.mi.dwFlags = flags;
        i.u.mi.dx = dx;
        i.u.mi.dy = dy;
        return i;
    }

    static INPUT Key(ushort vk, bool up) {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        i.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        return i;
    }

    static uint Send(params INPUT[] inputs) {
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // Like Send, but throws when the input was blocked (e.g. UIPI: target runs elevated).
    static void SendChecked(string what, params INPUT[] inputs) {
        uint n = Send(inputs);
        if (n != inputs.Length) {
            throw new InvalidOperationException(what + ": SendInput injected " + n + " of " + inputs.Length +
                " events (Win32 error " + Marshal.GetLastWin32Error() + "; blocked by UIPI or a secure desktop?)");
        }
    }

    public static void ClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(30);
        Send(Mouse(MOUSEEVENTF_LEFTDOWN, 0, 0), Mouse(MOUSEEVENTF_LEFTUP, 0, 0));
    }

    public static void DoubleClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(30);
        Send(Mouse(MOUSEEVENTF_LEFTDOWN, 0, 0), Mouse(MOUSEEVENTF_LEFTUP, 0, 0),
             Mouse(MOUSEEVENTF_LEFTDOWN, 0, 0), Mouse(MOUSEEVENTF_LEFTUP, 0, 0));
    }

    // ── Drag primitives: separate down / move / up so a caller can hold the button ──

    // Absolute move in virtual-desktop coordinates. Real SendInput moves produce the
    // WM_MOUSEMOVE stream that OLE DoDragDrop and Chromium/WebView2 drag tracking need.
    public static void MoveTo(int x, int y) {
        int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (w < 2 || h < 2) throw new InvalidOperationException("virtual screen metrics unavailable");
        int nx = (int)Math.Round((x - left) * 65535.0 / (w - 1));
        int ny = (int)Math.Round((y - top) * 65535.0 / (h - 1));
        SendChecked("mouse move", Mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, nx, ny));
    }

    public static void MouseDown() { SendChecked("left button down", Mouse(MOUSEEVENTF_LEFTDOWN, 0, 0)); }
    public static void MouseUp()   { SendChecked("left button up", Mouse(MOUSEEVENTF_LEFTUP, 0, 0)); }
    public static void KeyDown(ushort vk) { SendChecked("key down", Key(vk, false)); }
    public static void KeyUp(ushort vk)   { SendChecked("key up", Key(vk, true)); }

    public static bool IsLeftButtonDown() { return (GetAsyncKeyState(0x01) & 0x8000) != 0; }
    public static int DragThresholdX() { return GetSystemMetrics(SM_CXDRAG); }
    public static int DragThresholdY() { return GetSystemMetrics(SM_CYDRAG); }

    public static int[] CursorPos() {
        POINT p;
        GetCursorPos(out p);
        return new int[] { p.X, p.Y };
    }

    static uint RootOwnerPid(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return 0;
        IntPtr root = GetAncestor(hwnd, GA_ROOTOWNER);
        if (root == IntPtr.Zero) root = hwnd;
        uint pid;
        GetWindowThreadProcessId(root, out pid);
        return pid;
    }

    static IntPtr RootOwner(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        IntPtr root = GetAncestor(hwnd, GA_ROOTOWNER);
        return root == IntPtr.Zero ? hwnd : root;
    }

    // Top-level (root owner) window under a screen point; Zero if none. Cross-process
    // child windows (e.g. WebView2's renderer HWND) resolve to the hosting app's window.
    public static IntPtr RootOwnerAt(int x, int y) {
        POINT p; p.X = x; p.Y = y;
        return RootOwner(WindowFromPoint(p));
    }

    // PID owning the root owner window under a screen point; 0 if none.
    public static uint RootOwnerPidAt(int x, int y) {
        POINT p; p.X = x; p.Y = y;
        return RootOwnerPid(WindowFromPoint(p));
    }

    public static IntPtr ForegroundRoot() { return RootOwner(GetForegroundWindow()); }
    public static uint ForegroundPid() { return RootOwnerPid(GetForegroundWindow()); }

    // Per-monitor-v2 DPI awareness for the calling thread, so UIA rects, metrics and
    // SendInput all use physical pixels. Returns the previous context (Zero if unsupported).
    public static IntPtr EnterPerMonitorDpi() {
        try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); }
        catch (EntryPointNotFoundException) { return IntPtr.Zero; }
    }
    public static void RestoreDpi(IntPtr previous) {
        if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
    }

    // PrintWindow for window-scoped screenshots
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    public const uint PW_RENDERFULLCONTENT = 0x00000002;

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left, Top, Right, Bottom;
    }
}
"@

# ── UIA globals ──
$uiaRoot   = [System.Windows.Automation.AutomationElement]::RootElement
$walker    = [System.Windows.Automation.TreeWalker]::RawViewWalker
$stopwatch = [System.Diagnostics.Stopwatch]::new()

# ── Helpers ──
function Find-Window([string]$name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name
    )
    return $uiaRoot.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
}

function Rect-To-Hash($rect) {
    if (-not $rect -or $rect.IsEmpty) { return $null }
    return @{ left = [int]$rect.Left; top = [int]$rect.Top; right = [int]$rect.Right; bottom = [int]$rect.Bottom }
}

function Element-To-Hash($el, $depth) {
    $ct = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
    $rect = Rect-To-Hash $el.Current.BoundingRectangle
    $h = @{
        name    = $el.Current.Name
        type    = $ct
        class   = $el.Current.ClassName
        depth   = $depth
        rect    = $rect
        auto_id = $el.Current.AutomationId
        enabled = $el.Current.IsEnabled
    }
    # Check RangeValuePattern
    try {
        $rvp = $el.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
        if ($rvp) {
            $h['range_value'] = @{
                value    = $rvp.Current.Value
                min      = $rvp.Current.Minimum
                max      = $rvp.Current.Maximum
                readonly = $rvp.Current.IsReadOnly
            }
        }
    } catch {}
    # Check ValuePattern
    try {
        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) {
            $h['value'] = $vp.Current.Value
            $h['value_readonly'] = $vp.Current.IsReadOnly
        }
    } catch {}
    # Check TogglePattern
    try {
        $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp) {
            $h['toggle_state'] = $tp.Current.ToggleState.ToString()
        }
    } catch {}
    return $h
}

# ── Command handlers ──

function Cmd-Ping($a) {
    return @{ ok = $true; msg = 'pong' }
}

function Cmd-ListWindows($a) {
    $cond = [System.Windows.Automation.Condition]::TrueCondition
    $wins = $uiaRoot.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $wins) {
        $name = $w.Current.Name
        if ($name) {
            $results.Add(@{
                name    = $name
                class   = $w.Current.ClassName
                auto_id = $w.Current.AutomationId
                rect    = Rect-To-Hash $w.Current.BoundingRectangle
                enabled = $w.Current.IsEnabled
            })
        }
    }
    return @{ ok = $true; count = $results.Count; windows = $results }
}

function Cmd-FindWindow($a) {
    $win = Find-Window $a.name
    if (-not $win) { return @{ ok = $false; error = "Window '$($a.name)' not found" } }
    return @{ ok = $true; element = (Element-To-Hash $win 0) }
}

function Cmd-TreeWalk($a) {
    if (-not $a.window) { return @{ ok = $false; error = "'window' is required" } }
    $maxDepth = if ($a.max_depth) { $a.max_depth } else { 15 }
    $typeFilter = $a.type_filter  # e.g. @('Slider', 'Button')

    $win = Find-Window $a.window
    if (-not $win) { return @{ ok = $false; error = "Window '$($a.window)' not found" } }

    $elements = [System.Collections.Generic.List[object]]::new()

    function Walk($el, $depth) {
        if ($depth -gt $maxDepth) { return }
        $child = $walker.GetFirstChild($el)
        while ($child) {
            $ct = $child.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $include = (-not $typeFilter) -or ($ct -in $typeFilter)
            if ($include) {
                $elements.Add((Element-To-Hash $child $depth))
            }
            Walk $child ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }

    $stopwatch.Restart()
    Walk $win 0
    $elapsed = $stopwatch.Elapsed.TotalSeconds

    return @{
        ok       = $true
        time_s   = [math]::Round($elapsed, 4)
        count    = $elements.Count
        elements = $elements
    }
}

function Cmd-FindElements($a) {
    if (-not $a.window) { return @{ ok = $false; error = "'window' is required" } }
    $maxDepth = if ($a.max_depth) { $a.max_depth } else { 15 }

    $win = Find-Window $a.window
    if (-not $win) { return @{ ok = $false; error = "Window '$($a.window)' not found" } }

    $results = [System.Collections.Generic.List[object]]::new()

    function Search($el, $depth) {
        if ($depth -gt $maxDepth) { return }
        $child = $walker.GetFirstChild($el)
        while ($child) {
            $ct   = $child.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $name = $child.Current.Name
            $aid  = $child.Current.AutomationId
            $cls  = $child.Current.ClassName

            $match = $true
            if ($a.type -and $ct -ne $a.type) { $match = $false }
            if ($a.name -and $name -ne $a.name) { $match = $false }
            if ($a.name_contains -and $name -notlike "*$($a.name_contains)*") { $match = $false }
            if ($a.auto_id -and $aid -ne $a.auto_id) { $match = $false }
            if ($a.auto_id_contains -and $aid -notlike "*$($a.auto_id_contains)*") { $match = $false }
            if ($a.class_name -and $cls -ne $a.class_name) { $match = $false }

            if ($match) {
                $results.Add((Element-To-Hash $child $depth))
            }

            Search $child ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }

    $stopwatch.Restart()
    Search $win 0
    $elapsed = $stopwatch.Elapsed.TotalSeconds

    return @{
        ok       = $true
        time_s   = [math]::Round($elapsed, 4)
        count    = $results.Count
        elements = $results
    }
}

function Cmd-SetValue($a) {
    if (-not $a.window) { return @{ ok = $false; error = "'window' is required" } }
    $maxDepth = if ($a.max_depth) { $a.max_depth } else { 15 }

    $win = Find-Window $a.window
    if (-not $win) { return @{ ok = $false; error = "Window '$($a.window)' not found" } }

    $script:target = $null
    function FindTarget($el, $depth) {
        if ($script:target -or $depth -gt $maxDepth) { return }
        $child = $walker.GetFirstChild($el)
        while ($child -and -not $script:target) {
            $name = $child.Current.Name
            $aid  = $child.Current.AutomationId
            $ct   = $child.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $match = $true
            if (-not $child.Current.IsEnabled) { $match = $false }
            if ($a.type -and $ct -ne $a.type) { $match = $false }
            if ($a.name -and $name -ne $a.name) { $match = $false }
            if ($a.auto_id -and $aid -ne $a.auto_id) { $match = $false }
            if ($a.auto_id_contains -and $aid -notlike "*$($a.auto_id_contains)*") { $match = $false }
            if ($match) { $script:target = $child; return }
            FindTarget $child ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }

    $stopwatch.Restart()
    FindTarget $win 0

    if (-not $target) {
        return @{ ok = $false; error = 'Target element not found' }
    }

    # Try RangeValuePattern first
    try {
        $rvp = $target.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
        if ($rvp -and -not $rvp.Current.IsReadOnly) {
            $oldVal = $rvp.Current.Value
            $rvp.SetValue([double]$a.value)
            $newVal = $rvp.Current.Value
            $elapsed = $stopwatch.Elapsed.TotalSeconds
            return @{
                ok        = $true
                time_s    = [math]::Round($elapsed, 4)
                pattern   = 'RangeValue'
                old_value = $oldVal
                new_value = $newVal
            }
        }
    } catch {}

    # Try ValuePattern
    try {
        $vp = $target.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp -and -not $vp.Current.IsReadOnly) {
            $oldVal = $vp.Current.Value
            $vp.SetValue([string]$a.value)
            $newVal = $vp.Current.Value
            $elapsed = $stopwatch.Elapsed.TotalSeconds
            return @{
                ok        = $true
                time_s    = [math]::Round($elapsed, 4)
                pattern   = 'Value'
                old_value = $oldVal
                new_value = $newVal
            }
        }
    } catch {}

    return @{ ok = $false; error = 'Element does not support settable Value or RangeValue pattern' }
}

function Cmd-Click($a) {
    $x = [int]$a.x
    $y = [int]$a.y
    $double = [bool]$a.double

    $stopwatch.Restart()
    if ($double) {
        [NativeInput]::DoubleClickAt($x, $y)
    } else {
        [NativeInput]::ClickAt($x, $y)
    }
    $elapsed = $stopwatch.Elapsed.TotalSeconds

    return @{
        ok     = $true
        time_s = [math]::Round($elapsed, 4)
        x = $x; y = $y; double = $double
    }
}

function Find-ElementFast($win, $a) {
    # Try fast UIA FindFirst with PropertyCondition when possible (avoids full tree walk)
    $conditions = [System.Collections.Generic.List[object]]::new()

    if ($a.type) {
        $ctProp = [System.Windows.Automation.AutomationElement]::ControlTypeProperty
        $ctVal  = [System.Windows.Automation.ControlType]::$($a.type)
        if ($ctVal) {
            $conditions.Add((New-Object System.Windows.Automation.PropertyCondition($ctProp, $ctVal)))
        }
    }
    if ($a.name) {
        $nameProp = [System.Windows.Automation.AutomationElement]::NameProperty
        $conditions.Add((New-Object System.Windows.Automation.PropertyCondition($nameProp, $a.name)))
    }
    if ($a.auto_id) {
        $aidProp = [System.Windows.Automation.AutomationElement]::AutomationIdProperty
        $conditions.Add((New-Object System.Windows.Automation.PropertyCondition($aidProp, $a.auto_id)))
    }
    if ($a.class_name) {
        $clsProp = [System.Windows.Automation.AutomationElement]::ClassNameProperty
        $conditions.Add((New-Object System.Windows.Automation.PropertyCondition($clsProp, $a.class_name)))
    }

    # Can only use fast path when we have exact-match conditions (no name/auto_id_contains) and at least one condition
    if ($conditions.Count -gt 0 -and -not $a.name_contains -and -not $a.auto_id_contains) {
        if ($conditions.Count -eq 1) {
            $cond = $conditions[0]
        } else {
            $cond = New-Object System.Windows.Automation.AndCondition($conditions.ToArray())
        }
        $el = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
        return $el
    }

    # Fall back to manual tree walk for name_contains or complex filters
    $maxDepth = if ($a.max_depth) { $a.max_depth } else { 15 }
    $script:found = $null
    function WalkFind($el, $depth) {
        if ($script:found -or $depth -gt $maxDepth) { return }
        $child = $walker.GetFirstChild($el)
        while ($child -and -not $script:found) {
            $ct   = $child.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $name = $child.Current.Name
            $aid  = $child.Current.AutomationId
            $cls  = $child.Current.ClassName

            $match = $true
            if ($a.type -and $ct -ne $a.type) { $match = $false }
            if ($a.name -and $name -ne $a.name) { $match = $false }
            if ($a.name_contains -and $name -notlike "*$($a.name_contains)*") { $match = $false }
            if ($a.auto_id -and $aid -ne $a.auto_id) { $match = $false }
            if ($a.auto_id_contains -and $aid -notlike "*$($a.auto_id_contains)*") { $match = $false }
            if ($a.class_name -and $cls -ne $a.class_name) { $match = $false }

            if ($match) { $script:found = $child; return }
            WalkFind $child ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }
    WalkFind $win 0
    return $script:found
}

function Cmd-ClickElement($a) {
    if (-not $a.window) { return @{ ok = $false; error = "'window' is required" } }
    $offset_x = if ($a.offset_x) { [int]$a.offset_x } else { 0 }
    $offset_y = if ($a.offset_y) { [int]$a.offset_y } else { 0 }

    $win = Find-Window $a.window
    if (-not $win) { return @{ ok = $false; error = "Window '$($a.window)' not found" } }

    $stopwatch.Restart()
    $found = Find-ElementFast $win $a

    if (-not $found) {
        return @{ ok = $false; error = 'Element not found'; time_s = [math]::Round($stopwatch.Elapsed.TotalSeconds, 4) }
    }

    $rect = $found.Current.BoundingRectangle
    $cx = [int](($rect.Left + $rect.Right) / 2) + $offset_x
    $cy = [int](($rect.Top + $rect.Bottom) / 2) + $offset_y
    $double = [bool]$a.double

    if ($double) {
        [NativeInput]::DoubleClickAt($cx, $cy)
    } else {
        [NativeInput]::ClickAt($cx, $cy)
    }
    $elapsed = $stopwatch.Elapsed.TotalSeconds

    # Return trimmed element info (no class, value, value_readonly, depth — agent doesn't need them after clicking)
    $rect = Rect-To-Hash $found.Current.BoundingRectangle
    $elTrimmed = @{
        name    = $found.Current.Name
        type    = $found.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
        auto_id = $found.Current.AutomationId
        rect    = $rect
        enabled = $found.Current.IsEnabled
    }
    return @{
        ok      = $true
        time_s  = [math]::Round($elapsed, 4)
        x       = $cx
        y       = $cy
        double  = $double
        element = $elTrimmed
    }
}

# ── drag: UIA locates the endpoints, real SendInput performs the drag ──
# UIA has no API that performs a drag (DragPattern/DropTargetPattern are read-only), so
# this resolves each endpoint (element in its own window, or raw x/y), then drives the
# real mouse: down at the source, past the system drag threshold, interpolated moves to
# the target, hover, release. Source and target may be in different processes (e.g. a
# file from File Explorer into another app).

function Find-DragWindow($ep, [string]$label) {
    # Exact title, optionally narrowed by window class and/or owning process.
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, [string]$ep.window
    )
    $wins = @($uiaRoot.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) | Where-Object {
        (-not $ep.window_class -or $_.Current.ClassName -eq $ep.window_class) -and
        ($null -eq $ep.window_pid -or $_.Current.ProcessId -eq [int]$ep.window_pid)
    })
    if ($wins.Count -eq 0) { throw "${label}: window '$($ep.window)' not found" }
    if ($wins.Count -gt 1) {
        throw "${label}: $($wins.Count) windows titled '$($ep.window)' match; narrow with window_class / window_pid"
    }
    return $wins[0]
}

function Resolve-DragEndpoint($ep, [string]$label) {
    if (-not $ep) { throw "'$label' is required (window + element filters, or x and y)" }
    $hasX = $null -ne $ep.x
    $hasY = $null -ne $ep.y
    if ($ep.window) {
        if ($hasX -or $hasY) { throw "${label}: give either window + element filters or x/y, not both" }
        if (-not ($ep.name -or $ep.name_contains -or $ep.auto_id -or $ep.auto_id_contains -or $ep.type -or $ep.class_name)) {
            throw "${label}: needs at least one element filter (name, name_contains, auto_id, auto_id_contains, type, class_name)"
        }
        $win = Find-DragWindow $ep $label
        $el  = Find-ElementFast $win $ep
        if (-not $el) { throw "${label}: element not found in window '$($ep.window)'" }
        # The endpoint's process is the top-level window's: an element inside a hosted
        # control (e.g. WebView2 content) can report a child process's id instead.
        return @{
            label    = $label
            window   = $win
            hwnd     = [IntPtr]$win.Current.NativeWindowHandle
            element  = $el
            pid      = [int]$win.Current.ProcessId
            offset_x = if ($ep.offset_x) { [int]$ep.offset_x } else { 0 }
            offset_y = if ($ep.offset_y) { [int]$ep.offset_y } else { 0 }
        }
    }
    if (-not ($hasX -and $hasY)) { throw "${label}: needs either 'window' + element filters, or both 'x' and 'y'" }
    return @{ label = $label; window = $null; hwnd = [IntPtr]::Zero; element = $null; pid = $null; x = [int]$ep.x; y = [int]$ep.y }
}

# Live re-read of an endpoint's press/release point (element rects can move between steps).
# The point is the element's center + offset, and it must lie in the VISIBLE part of the
# element (its rect clipped to its top-level window's rect): a wide row in a narrow window
# can have its center outside the window. Without an offset, the center of the visible part
# is used instead (clamped = $true); with an offset, a point outside the visible part throws.
# Dry-run and the live drag both use this, so they evaluate the same point.
function Get-DragPoint($r) {
    if (-not $r.element) { return @{ x = $r.x; y = $r.y } }
    $rect = $r.element.Current.BoundingRectangle
    if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
        throw "$($r.label): element has no on-screen rectangle (offscreen or gone)"
    }
    $wr = New-Object NativeInput+RECT
    if (-not [NativeInput]::GetWindowRect($r.hwnd, [ref]$wr)) {
        throw "$($r.label): cannot read the window rectangle (window closed?)"
    }
    $vl = [math]::Max([int]$rect.Left, $wr.Left);   $vt = [math]::Max([int]$rect.Top, $wr.Top)
    $vr = [math]::Min([int]$rect.Right, $wr.Right); $vb = [math]::Min([int]$rect.Bottom, $wr.Bottom)
    if ($vr - $vl -lt 1 -or $vb - $vt -lt 1) {
        throw "$($r.label): element lies entirely outside its window (scroll it into view)"
    }
    $x = [int](($rect.Left + $rect.Right) / 2) + $r.offset_x
    $y = [int](($rect.Top + $rect.Bottom) / 2) + $r.offset_y
    $inside = $x -ge $vl -and $x -lt $vr -and $y -ge $vt -and $y -lt $vb
    if ($inside) { return @{ x = $x; y = $y; clamped = $false } }
    if ($r.offset_x -ne 0 -or $r.offset_y -ne 0) {
        throw "$($r.label): point ($x,$y) (element center + offset) is outside the element's visible part [$vl,$vt - $vr,$vb]"
    }
    return @{ x = [int](($vl + $vr) / 2); y = [int](($vt + $vb) / 2); clamped = $true }
}

# Dry-run form of Get-DragPoint: returns @{ point; problem } instead of throwing.
function Test-DragPoint($r) {
    try { return @{ point = (Get-DragPoint $r); problem = $null } }
    catch { return @{ point = $null; problem = $_.Exception.Message } }
}

function Describe-Pid([uint32]$procId) {
    if ($procId -eq 0) { return 'no window' }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($p) { return "$($p.ProcessName) (pid $procId)" }
    return "pid $procId"
}

# The top-level window under the point must belong to the expected process and, when the
# endpoint names a window, be that very window (no other window may cover the point).
function Test-PointOwner($pt, [int]$expectedPid, [IntPtr]$expectedHwnd) {
    $actual = [NativeInput]::RootOwnerPidAt($pt.x, $pt.y)
    if ($actual -ne $expectedPid) {
        return "point ($($pt.x),$($pt.y)) is over a window of $(Describe-Pid $actual), expected $(Describe-Pid $expectedPid)"
    }
    if ($expectedHwnd -ne [IntPtr]::Zero) {
        $root = [NativeInput]::RootOwnerAt($pt.x, $pt.y)
        if ($root -ne $expectedHwnd) {
            return "point ($($pt.x),$($pt.y)) is over another window (0x$($root.ToString('X'))) of the same process, not the named window (0x$($expectedHwnd.ToString('X')))"
        }
    }
    return $null
}

function Assert-PointOwner($pt, [int]$expectedPid, [IntPtr]$expectedHwnd, [string]$what) {
    $problem = Test-PointOwner $pt $expectedPid $expectedHwnd
    if ($problem) { throw "${what}: $problem; aborting" }
}

function Test-SourceForeground([int]$srcPid, [IntPtr]$srcHwnd) {
    if ([NativeInput]::ForegroundPid() -ne $srcPid) { return $false }
    if ($srcHwnd -ne [IntPtr]::Zero -and [NativeInput]::ForegroundRoot() -ne $srcHwnd) { return $false }
    return $true
}

function Trim-Element($el) {
    if (-not $el) { return $null }
    return @{
        name    = $el.Current.Name
        type    = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
        auto_id = $el.Current.AutomationId
        rect    = Rect-To-Hash $el.Current.BoundingRectangle
    }
}

function Cmd-Drag($a) {
    $stopwatch.Restart()
    $oldDpi   = [NativeInput]::EnterPerMonitorDpi()
    $pressed  = [System.Collections.Generic.List[uint16]]::new()
    $downSent = $false
    $done     = $false
    $phase    = 'validate'
    $from = $null; $to = $null; $srcPid = $null; $dstPid = $null
    $result = $null
    try {
        # ── Validate args ──
        $mods = @()
        foreach ($m in @($a.modifiers)) {
            if ($null -eq $m) { continue }
            switch (([string]$m).ToLowerInvariant()) {
                { $_ -in 'ctrl', 'control' } { $mods += [NativeInput]::VK_CONTROL }
                'shift'                      { $mods += [NativeInput]::VK_SHIFT }
                default { throw "unknown modifier '$m' (allowed: ctrl, shift)" }
            }
        }
        $steps   = if ($null -ne $a.steps)         { [int]$a.steps }         else { 20 }
        $delayMs = if ($null -ne $a.step_delay_ms) { [int]$a.step_delay_ms } else { 15 }
        $holdMs  = if ($null -ne $a.hold_ms)       { [int]$a.hold_ms }       else { 150 }
        if ($steps -lt 1 -or $steps -gt 200)     { throw "'steps' must be 1..200" }
        if ($delayMs -lt 0 -or $delayMs -gt 200) { throw "'step_delay_ms' must be 0..200" }
        if ($holdMs -lt 0 -or $holdMs -gt 5000)  { throw "'hold_ms' must be 0..5000" }

        $src = Resolve-DragEndpoint $a.source 'source'
        $dst = Resolve-DragEndpoint $a.target 'target'

        # Expected owner per endpoint (source and target may be different processes):
        # explicit expect_*_pid, else the endpoint's own top-level window (pid + hwnd),
        # else (raw x/y) the other endpoint's window process. A drag never runs without one.
        # A raw x/y source must name its process: the drag activates the window under it.
        $srcHwnd = [IntPtr]::Zero; $dstHwnd = [IntPtr]::Zero
        if (-not $src.element -and $null -eq $a.expect_source_pid) {
            throw "a raw x/y source needs 'expect_source_pid' (the process whose window is under the point)"
        }
        if ($null -ne $a.expect_source_pid) { $srcPid = [int]$a.expect_source_pid }
        elseif ($src.pid) { $srcPid = $src.pid; $srcHwnd = $src.hwnd }
        else { $srcPid = $dst.pid }
        if ($null -ne $a.expect_target_pid) { $dstPid = [int]$a.expect_target_pid }
        elseif ($dst.pid) { $dstPid = $dst.pid; $dstHwnd = $dst.hwnd }
        else { $dstPid = $src.pid }
        if (-not $srcPid -or -not $dstPid) {
            throw "a drag between two raw x/y points needs 'expect_source_pid' and 'expect_target_pid'"
        }

        if ($a.dry_run) {
            # Resolve and check only: no input, no focus change. Same points and checks as
            # the live drag (Get-DragPoint, then the window under each point).
            $s = Test-DragPoint $src; $d = Test-DragPoint $dst
            $from = $s.point; $to = $d.point
            $srcProblem = if ($s.problem) { $s.problem } else { Test-PointOwner $from $srcPid $srcHwnd }
            $dstProblem = if ($d.problem) { $d.problem } else { Test-PointOwner $to $dstPid $dstHwnd }
            $result = @{
                ok                = (-not $srcProblem) -and (-not $dstProblem)
                dry_run           = $true
                from              = $from
                to                = $to
                source_pid        = $srcPid
                target_pid        = $dstPid
                source_check      = if ($srcProblem) { $srcProblem } else { 'ok' }
                target_check      = if ($dstProblem) { $dstProblem } else { 'ok' }
                source_foreground = Test-SourceForeground $srcPid $srcHwnd
                source_element    = Trim-Element $src.element
                target_element    = Trim-Element $dst.element
            }
            if (-not $src.element -and -not $srcProblem) {
                # Raw source: the window a live drag would activate (checked to be expect_source_pid's).
                $result.source_window_hwnd = [int64][NativeInput]::RootOwnerAt($from.x, $from.y)
            }
            if (-not $result.ok) { $result.error = 'an endpoint check failed (see source_check / target_check)' }
            $done = $true
        } else {

        if ([NativeInput]::IsLeftButtonDown()) {
            throw 'left mouse button is already down (another drag or the user is active); aborting'
        }

        # ── Source must be foreground: activate the source window, then verify ──
        $phase = 'activate'
        $srcWin = $src.window
        if (-not $src.element) {
            # Raw source: the top-level window under the point, only if it is expect_source_pid's.
            $pt = Get-DragPoint $src
            Assert-PointOwner $pt $srcPid ([IntPtr]::Zero) 'source'
            $srcHwnd = [NativeInput]::RootOwnerAt($pt.x, $pt.y)
            try { $srcWin = [System.Windows.Automation.AutomationElement]::FromHandle($srcHwnd) } catch { $srcWin = $null }
        }
        if (-not (Test-SourceForeground $srcPid $srcHwnd) -and $srcHwnd -ne [IntPtr]::Zero) {
            if (-not [NativeInput]::SetForegroundWindow($srcHwnd) -and $srcWin) {
                try { $srcWin.SetFocus() } catch {}
            }
            Start-Sleep -Milliseconds 150
        }
        if (-not (Test-SourceForeground $srcPid $srcHwnd)) {
            throw "foreground window belongs to $(Describe-Pid ([NativeInput]::ForegroundPid())), not the source window of $(Describe-Pid $srcPid); activate the source window first"
        }

        # ── Press at the source (rect re-read right before use) ──
        $phase = 'press'
        $from = Get-DragPoint $src
        Assert-PointOwner $from $srcPid $srcHwnd 'source'
        [NativeInput]::MoveTo($from.x, $from.y)
        Start-Sleep -Milliseconds 60
        $from = Get-DragPoint $src
        Assert-PointOwner $from $srcPid $srcHwnd 'source'
        $c = [NativeInput]::CursorPos()
        if ([math]::Abs($c[0] - $from.x) -gt 1 -or [math]::Abs($c[1] - $from.y) -gt 1) {
            throw "cursor is at ($($c[0]),$($c[1])), not the source point ($($from.x),$($from.y)); the source moved or the pointer is in use"
        }
        if (-not (Test-SourceForeground $srcPid $srcHwnd)) { throw 'source window lost the foreground before button-down; aborting' }
        $downSent = $true
        [NativeInput]::MouseDown()
        Start-Sleep -Milliseconds 80

        # ── Cross the system drag threshold in small moves toward the target ──
        $phase = 'start-drag'
        $to = Get-DragPoint $dst
        $dx = $to.x - $from.x; $dy = $to.y - $from.y
        $len = [math]::Sqrt($dx * $dx + $dy * $dy)
        if ($len -lt 1) { $ux = 1.0; $uy = 0.0 } else { $ux = $dx / $len; $uy = $dy / $len }
        $thresh = [math]::Max([NativeInput]::DragThresholdX(), [NativeInput]::DragThresholdY()) * 2 + 2
        $cur = $from
        for ($i = 1; $i -le 3; $i++) {
            $cur = @{ x = [int][math]::Round($from.x + $ux * $thresh * $i / 3); y = [int][math]::Round($from.y + $uy * $thresh * $i / 3) }
            [NativeInput]::MoveTo($cur.x, $cur.y)
            Start-Sleep -Milliseconds ([math]::Max($delayMs, 20))
        }

        # Modifiers go down once the drag is under way (drop effect is read during the drag
        # and at release; pressing them before button-down would change the click instead).
        foreach ($vk in $mods) { $pressed.Add($vk); [NativeInput]::KeyDown($vk) }
        if ($mods.Count) { Start-Sleep -Milliseconds 40 }

        # ── Interpolate to the target (rect re-read right before use) ──
        $phase = 'move'
        $to = Get-DragPoint $dst
        $start = $cur
        for ($i = 1; $i -le $steps; $i++) {
            $px = [int][math]::Round($start.x + ($to.x - $start.x) * $i / $steps)
            $py = [int][math]::Round($start.y + ($to.y - $start.y) * $i / $steps)
            [NativeInput]::MoveTo($px, $py)
            Start-Sleep -Milliseconds $delayMs
        }

        # ── Hover: re-read the target, nudge so the drop target sees a fresh drag-over ──
        $phase = 'hover'
        $to = Get-DragPoint $dst
        [NativeInput]::MoveTo($to.x + 1, $to.y)
        Start-Sleep -Milliseconds ([math]::Max($delayMs, 20))
        [NativeInput]::MoveTo($to.x, $to.y)
        Start-Sleep -Milliseconds $holdMs

        # ── Release only over the target's process ──
        $phase = 'release'
        Assert-PointOwner $to $dstPid $dstHwnd 'target'
        [NativeInput]::MouseUp()
        $downSent = $false
        $done = $true

        $cursor = [NativeInput]::CursorPos()
        $result = @{
            ok             = $true
            from           = $from
            to             = $to
            cursor         = @{ x = $cursor[0]; y = $cursor[1] }
            modifiers      = @($a.modifiers | Where-Object { $_ })
            steps          = $steps
            source_pid     = $srcPid
            target_pid     = $dstPid
            source_element = Trim-Element $src.element
            target_element = Trim-Element $dst.element
        }
        }  # end live (non-dry-run) drag
    } catch {
        $result = @{
            ok     = $false
            error  = $_.Exception.Message
            phase  = $phase
            from   = $from
            to     = $to
            source_pid = $srcPid
            target_pid = $dstPid
            button_was_down = $downSent
        }
    } finally {
        $cleanupErrors = @()
        # Modifiers up first: Escape with Ctrl held would be Ctrl+Esc (Start menu).
        for ($i = $pressed.Count - 1; $i -ge 0; $i--) {
            try { [NativeInput]::KeyUp($pressed[$i]) } catch { $cleanupErrors += $_.Exception.Message }
        }
        if ($downSent) {
            # Aborted mid-drag: cancel the OLE drag with Escape before releasing, so the
            # button-up does not drop — but only if our source/target process owns the
            # foreground (never send keys to a window the caller did not target).
            $fg = [NativeInput]::ForegroundPid()
            if (-not $done -and ($fg -eq $srcPid -or $fg -eq $dstPid)) {
                try {
                    [NativeInput]::KeyDown([NativeInput]::VK_ESCAPE)
                    [NativeInput]::KeyUp([NativeInput]::VK_ESCAPE)
                    Start-Sleep -Milliseconds 50
                } catch { $cleanupErrors += $_.Exception.Message }
            }
            try { [NativeInput]::MouseUp() } catch { $cleanupErrors += $_.Exception.Message }
        }
        [NativeInput]::RestoreDpi($oldDpi)
        if ($result -and $cleanupErrors.Count) { $result.cleanup_errors = $cleanupErrors }
    }
    if ($result) { $result.time_s = [math]::Round($stopwatch.Elapsed.TotalSeconds, 4) }
    return $result
}

function Cmd-Toggle($a) {
    if (-not $a.window) { return @{ ok = $false; error = "'window' is required" } }
    $maxDepth = if ($a.max_depth) { $a.max_depth } else { 15 }

    $win = Find-Window $a.window
    if (-not $win) { return @{ ok = $false; error = "Window '$($a.window)' not found" } }

    $stopwatch.Restart()
    $found = Find-ElementFast $win $a

    if (-not $found) {
        return @{ ok = $false; error = 'Element not found'; time_s = [math]::Round($stopwatch.Elapsed.TotalSeconds, 4) }
    }

    # Try TogglePattern
    $oldState = $null
    try {
        $tp = $found.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp) {
            $oldState = $tp.Current.ToggleState.ToString()
            $tp.Toggle()
            Start-Sleep -Milliseconds 100
            $newState = $tp.Current.ToggleState.ToString()
            # If state actually changed, return success
            if ($newState -ne $oldState) {
                $elapsed = $stopwatch.Elapsed.TotalSeconds
                return @{
                    ok        = $true
                    time_s    = [math]::Round($elapsed, 4)
                    old_state = $oldState
                    new_state = $newState
                    element   = @{
                        name    = $found.Current.Name
                        type    = $found.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
                        auto_id = $found.Current.AutomationId
                    }
                }
            }
            # State didn't change — Toggle() is read-only, fall through to click
        }
    } catch {}

    # Fallback: click at left edge of element (where checkbox typically is in ListItems)
    $rect = $found.Current.BoundingRectangle
    $cy = [int](($rect.Top + $rect.Bottom) / 2)
    # Click near left edge — checkbox is typically at the start of the item
    $cx = [int]$rect.Left + 15
    [NativeInput]::ClickAt($cx, $cy)
    Start-Sleep -Milliseconds 200

    # Read toggle_state after click if available
    $newState = $null
    try {
        $tp2 = $found.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp2) { $newState = $tp2.Current.ToggleState.ToString() }
    } catch {}

    $elapsed = $stopwatch.Elapsed.TotalSeconds
    return @{
        ok        = $true
        time_s    = [math]::Round($elapsed, 4)
        fallback  = 'click_checkbox'
        old_state = $oldState
        new_state = $newState
        element   = @{
            name    = $found.Current.Name
            type    = $found.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            auto_id = $found.Current.AutomationId
        }
    }
}

function Cmd-Screenshot($a) {
    $path = $a.path
    if (-not $path) {
        $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'uia_screenshot.png')
    }

    $stopwatch.Restart()

    if ($a.window) {
        # Window-scoped screenshot via PrintWindow API
        $win = Find-Window $a.window
        if (-not $win) { return @{ ok = $false; error = "Window '$($a.window)' not found" } }

        $hwnd = [IntPtr]$win.Current.NativeWindowHandle
        $winRect = New-Object NativeInput+RECT
        [NativeInput]::GetWindowRect($hwnd, [ref]$winRect) | Out-Null

        $w = $winRect.Right - $winRect.Left
        $h = $winRect.Bottom - $winRect.Top
        if ($w -le 0 -or $h -le 0) {
            return @{ ok = $false; error = "Window has zero/negative dimensions: ${w}x${h}" }
        }

        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gfx.GetHdc()
        [NativeInput]::PrintWindow($hwnd, $hdc, [NativeInput]::PW_RENDERFULLCONTENT) | Out-Null
        $gfx.ReleaseHdc($hdc)
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose()
        $bmp.Dispose()
        $elapsed = $stopwatch.Elapsed.TotalSeconds

        $fileSize = (Get-Item $path).Length
        return @{
            ok           = $true
            time_s       = [math]::Round($elapsed, 4)
            path         = $path
            resolution   = "${w}x${h}"
            file_size_kb = [math]::Round($fileSize / 1024, 1)
            window       = $a.window
        }
    }

    # Full-screen screenshot (default)
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $bounds = $screen.Bounds

    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $gfx.Dispose()
    $bmp.Dispose()
    $elapsed = $stopwatch.Elapsed.TotalSeconds

    $fileSize = (Get-Item $path).Length

    return @{
        ok           = $true
        time_s       = [math]::Round($elapsed, 4)
        path         = $path
        resolution   = "$($bounds.Width)x$($bounds.Height)"
        file_size_kb = [math]::Round($fileSize / 1024, 1)
    }
}

function Cmd-Type($a) {
    $stopwatch.Restart()
    [System.Windows.Forms.SendKeys]::SendWait($a.text)
    $elapsed = $stopwatch.Elapsed.TotalSeconds
    return @{ ok = $true; time_s = [math]::Round($elapsed, 4) }
}

# ── Parse arguments ──
$pipeName = 'uia-server'
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--pipe-name' -and ($i + 1) -lt $args.Count) {
        $pipeName = $args[$i + 1]
        $i++
    }
}

# ── Write PID file ──
$pidFile = [System.IO.Path]::Combine($env:TEMP, "$pipeName.pid")
[System.IO.File]::WriteAllText($pidFile, "$PID")

# ── Main loop (named pipe transport) ──
try {
    while ($true) {
        $pipe = [System.IO.Pipes.NamedPipeServerStream]::new(
            $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut
        )

        try {
            $pipe.WaitForConnection()

            $reader = [System.IO.StreamReader]::new($pipe)
            $writer = [System.IO.StreamWriter]::new($pipe)
            $writer.AutoFlush = $false

            $line = $reader.ReadLine()
            if ($null -eq $line) {
                $pipe.Disconnect()
                $pipe.Dispose()
                continue
            }
            $line = $line.Trim()
            if ($line -eq '') {
                $pipe.Disconnect()
                $pipe.Dispose()
                continue
            }

            try {
                $req = $line | ConvertFrom-Json
            } catch {
                $err = @{ ok = $false; error = "Invalid JSON: $_" } | ConvertTo-Json -Compress
                $writer.WriteLine($err)
                $writer.Flush()
                $pipe.Disconnect()
                $pipe.Dispose()
                continue
            }

            $cmd = $req.cmd
            $a   = $req.args
            if (-not $a) { $a = @{} }

            $response = $null
            try {
                switch ($cmd) {
                    'ping'          { $response = Cmd-Ping $a }
                    'list_windows'  { $response = Cmd-ListWindows $a }
                    'find_window'   { $response = Cmd-FindWindow $a }
                    'tree_walk'     { $response = Cmd-TreeWalk $a }
                    'find_elements' { $response = Cmd-FindElements $a }
                    'set_value'     { $response = Cmd-SetValue $a }
                    'click'         { $response = Cmd-Click $a }
                    'click_element' { $response = Cmd-ClickElement $a }
                    'drag'          { $response = Cmd-Drag $a }
                    'toggle'        { $response = Cmd-Toggle $a }
                    'screenshot'    { $response = Cmd-Screenshot $a }
                    'type'          { $response = Cmd-Type $a }
                    'quit'          {
                        $quit = @{ ok = $true; msg = 'bye' } | ConvertTo-Json -Compress
                        $writer.WriteLine($quit)
                        $writer.Flush()
                        $pipe.Disconnect()
                        $pipe.Dispose()
                        if (Test-Path $pidFile) { Remove-Item $pidFile -Force }
                        exit 0
                    }
                    default         { $response = @{ ok = $false; error = "Unknown command: $cmd" } }
                }
            } catch {
                $response = @{ ok = $false; error = $_.Exception.Message }
            }

            $json = $response | ConvertTo-Json -Depth 10 -Compress
            $writer.WriteLine($json)
            $writer.Flush()
            $pipe.Disconnect()
        } finally {
            $pipe.Dispose()
        }
    }
} finally {
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force }
}
