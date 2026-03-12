# Persistent UIA automation server — reads JSON commands from stdin, writes JSON responses to stdout.
# Zero dependencies: uses only built-in .NET assemblies available on all Windows 10/11 systems.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File uia_server.ps1
#
# Protocol: newline-delimited JSON (one JSON object per line).
# Request:  {"cmd": "...", "args": {...}}
# Response: {"ok": true, ...} or {"ok": false, "error": "..."}

$ErrorActionPreference = 'Stop'

# ── Load assemblies once (the whole point of keeping this process alive) ──
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# ── Native SendInput for clicking ──
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NativeInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public MOUSEINPUT mi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;

    public static void ClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(30);
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = 0;
        inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        inputs[1].type = 0;
        inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void DoubleClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(30);
        INPUT[] inputs = new INPUT[4];
        inputs[0].type = 0; inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        inputs[1].type = 0; inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        inputs[2].type = 0; inputs[2].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        inputs[3].type = 0; inputs[3].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
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

    $target = $null
    function FindTarget($el, $depth) {
        if ($script:target -or $depth -gt $maxDepth) { return }
        $child = $walker.GetFirstChild($el)
        while ($child -and -not $script:target) {
            $name = $child.Current.Name
            $aid  = $child.Current.AutomationId
            $ct   = $child.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
            $match = $true
            if ($a.type -and $ct -ne $a.type) { $match = $false }
            if ($a.name -and $name -ne $a.name) { $match = $false }
            if ($a.auto_id -and $aid -ne $a.auto_id) { $match = $false }
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

function Cmd-Screenshot($a) {
    $path = $a.path
    if (-not $path) {
        $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'uia_screenshot.png')
    }

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $bounds = $screen.Bounds

    $stopwatch.Restart()
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

# ── Main loop ──
$reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput())

# Signal ready
$ready = @{ ok = $true; msg = 'ready' } | ConvertTo-Json -Compress
[Console]::Out.WriteLine($ready)
[Console]::Out.Flush()

while ($true) {
    $line = $reader.ReadLine()
    if ($null -eq $line) { break }  # stdin closed
    $line = $line.Trim()
    if ($line -eq '') { continue }

    try {
        $req = $line | ConvertFrom-Json
    } catch {
        $err = @{ ok = $false; error = "Invalid JSON: $_" } | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($err)
        [Console]::Out.Flush()
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
            'screenshot'    { $response = Cmd-Screenshot $a }
            'type'          { $response = Cmd-Type $a }
            'quit'          {
                $quit = @{ ok = $true; msg = 'bye' } | ConvertTo-Json -Compress
                [Console]::Out.WriteLine($quit)
                [Console]::Out.Flush()
                exit 0
            }
            default         { $response = @{ ok = $false; error = "Unknown command: $cmd" } }
        }
    } catch {
        $response = @{ ok = $false; error = $_.Exception.Message }
    }

    $json = $response | ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}
