---
name: windows-ui-automation
description: Interact with Windows desktop UI — click, type, find elements, read UI trees, take screenshots, set values. Uses a persistent PowerShell UIA server with zero dependencies.
---

# Windows UI Automation Skill

Automate any Windows desktop application using the UIA CLI. This tool wraps the Windows UI Automation framework behind a simple JSON command interface, powered by a persistent background PowerShell server.

## Quick Setup

Run this once at the start of your session to set up shorthand variables:

```bash
UIA="powershell -NoProfile -ExecutionPolicy Bypass -File ${CLAUDE_SKILL_DIR}/scripts/uia_cli.ps1"
UIA_TYPE="${CLAUDE_SKILL_DIR}/scripts/uia_type.ps1"
$UIA '{"cmd":"ping"}'
```

Then use `$UIA '{"cmd":"..."}'` for all subsequent calls.

The CLI auto-starts the UIA server on the first call (takes ~1 second for .NET assembly loading). Subsequent calls reuse the running server and complete in ~5ms.

All commands return JSON with an `"ok": true/false` field. On failure, an `"error"` string is included.

## Commands

### ping — Health Check

```bash
$UIA '{"cmd":"ping"}'
# => {"ok":true,"msg":"pong"}
```

### list_windows — Discover Open Windows

```bash
$UIA '{"cmd":"list_windows"}'
# => {"ok":true,"count":5,"windows":[{"name":"Untitled - Notepad","class":"Notepad",...},...]}
```

### find_window — Find a Specific Window

```bash
$UIA '{"cmd":"find_window","args":{"name":"Untitled - Notepad"}}'
# => {"ok":true,"element":{"name":"Untitled - Notepad","type":"Window",...}}
```

### tree_walk — Walk the UI Element Tree

Get all UI elements in a window. Use `type_filter` to limit to specific control types and `max_depth` to control traversal depth:

```bash
$UIA '{"cmd":"tree_walk","args":{"window":"Untitled - Notepad"}}'
$UIA '{"cmd":"tree_walk","args":{"window":"Untitled - Notepad","type_filter":["Button","Slider"],"max_depth":5}}'
```

Returns an array of elements, each with `name`, `type`, `auto_id`, `rect`, `class`, `depth`, `enabled`, and pattern info (value, range_value, toggle_state) where applicable.

### find_elements — Search for Specific Elements

Search by any combination of `type`, `name`, `name_contains`, `auto_id`, `class_name`:

```bash
$UIA '{"cmd":"find_elements","args":{"window":"My App","type":"Button"}}'
$UIA '{"cmd":"find_elements","args":{"window":"My App","name_contains":"Save"}}'
$UIA '{"cmd":"find_elements","args":{"window":"My App","auto_id":"slider_brightness"}}'
```

### click_element — Find and Click in One Call (preferred)

Find an element by filters and click its center. This is the **fastest way to click** — uses native UIA FindFirst (not tree walk) when possible:

```bash
$UIA '{"cmd":"click_element","args":{"window":"My App","name":"Save","type":"Button"}}'
$UIA '{"cmd":"click_element","args":{"window":"My App","type":"ListItem","name_contains":"file.mp4","offset_x":-100}}'
```

Accepts all `find_elements` filters plus `offset_x`/`offset_y` (relative to center) and `double` (for double-click). Returns the matched element info alongside the click coordinates.

### click — Click at Coordinates

```bash
$UIA '{"cmd":"click","args":{"x":500,"y":300}}'
$UIA '{"cmd":"click","args":{"x":500,"y":300,"double":true}}'
```

### type — Send Keystrokes

Send keystrokes using .NET SendKeys syntax. Special keys use braces: `{ENTER}`, `{TAB}`, `{ESC}`, `{BACKSPACE}`, `{DELETE}`, `{UP}`, `{DOWN}`, `{LEFT}`, `{RIGHT}`, `{F1}`-`{F12}`. Modifiers: `+` (Shift), `^` (Ctrl), `%` (Alt).

```bash
$UIA '{"cmd":"type","args":{"text":"Hello World"}}'
$UIA '{"cmd":"type","args":{"text":"{ENTER}"}}'
$UIA '{"cmd":"type","args":{"text":"^s"}}'  # Ctrl+S
```

### set_value — Set Slider/Input Values Directly

Set values on elements that support the UIA ValuePattern or RangeValuePattern. Identify the target by `name`, `auto_id`, and/or `type`:

```bash
$UIA '{"cmd":"set_value","args":{"window":"My App","auto_id":"slider_brightness","value":75}}'
$UIA '{"cmd":"set_value","args":{"window":"My App","name":"Volume","type":"Slider","value":50}}'
```

This is far more reliable than click-dragging sliders. It sets the value programmatically via UIA patterns.

### screenshot — Capture Screen

```bash
$UIA '{"cmd":"screenshot"}'
# Saves to %TEMP%/uia_screenshot.png by default. Then use Read tool on the path to view the image.
```

## Key Patterns

### Click an Element

**Preferred**: Use `click_element` — finds and clicks in one call, uses fast UIA FindFirst:
```bash
$UIA '{"cmd":"click_element","args":{"window":"My App","name":"OK","type":"Button"}}'
```

**Fallback**: Use `find_elements` → compute center from `rect` → `click` when you need the element details first or `click_element` can't handle the search criteria.

### Set Slider Value

Do not try to click-drag sliders. Use `set_value` with the slider's `auto_id` or `name` to set its value directly via UIA patterns. This is instant and precise.

### Discover UI Structure

When working with an unfamiliar application:

1. `list_windows` to find the window name
2. `tree_walk` with a shallow `max_depth` (3-5) to get an overview
3. `tree_walk` with `type_filter` to find specific control types
4. `find_elements` with `name_contains` for targeted searches

## Reference

See [references/commands.md](references/commands.md) for the full command protocol with detailed request/response examples.
