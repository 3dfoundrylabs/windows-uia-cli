---
name: windows-ui-automation
description: Interact with Windows desktop UI — click, type, find elements, read UI trees, take screenshots, set values. Uses a persistent PowerShell UIA server with zero dependencies.
---

# Windows UI Automation Skill

Automate any Windows desktop application using the UIA CLI. This tool wraps the Windows UI Automation framework behind a simple JSON command interface, powered by a persistent background PowerShell server.

## How to Call

Use the Bash tool to invoke the CLI:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/uia_cli.ps1" '{"cmd":"ping"}'
```

The CLI auto-starts the UIA server on the first call (takes ~1 second for .NET assembly loading). Subsequent calls reuse the running server and complete in ~5ms.

All commands return JSON with an `"ok": true/false` field. On failure, an `"error"` string is included.

## Commands

### ping — Health Check

Verify the server is running:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/uia_cli.ps1" '{"cmd":"ping"}'
# => {"ok":true,"msg":"pong"}
```

### list_windows — Discover Open Windows

List all top-level windows with names:

```bash
powershell ... '{"cmd":"list_windows"}'
# => {"ok":true,"count":5,"windows":[{"name":"Untitled - Notepad","class":"Notepad",...},...]}}
```

### find_window — Find a Specific Window

Find a window by its exact title:

```bash
powershell ... '{"cmd":"find_window","args":{"name":"Untitled - Notepad"}}'
# => {"ok":true,"element":{"name":"Untitled - Notepad","type":"Window",...}}
```

### tree_walk — Walk the UI Element Tree

Get all UI elements in a window. Use `type_filter` to limit to specific control types and `max_depth` to control traversal depth:

```bash
powershell ... '{"cmd":"tree_walk","args":{"window":"Untitled - Notepad"}}'
powershell ... '{"cmd":"tree_walk","args":{"window":"Untitled - Notepad","type_filter":["Button","Slider"],"max_depth":5}}'
```

Returns an array of elements, each with `name`, `type`, `auto_id`, `rect`, `class`, `depth`, `enabled`, and pattern info (value, range_value, toggle_state) where applicable.

### find_elements — Search for Specific Elements

Search by any combination of `type`, `name`, `name_contains`, `auto_id`, `class_name`:

```bash
powershell ... '{"cmd":"find_elements","args":{"window":"My App","type":"Button"}}'
powershell ... '{"cmd":"find_elements","args":{"window":"My App","name_contains":"Save"}}'
powershell ... '{"cmd":"find_elements","args":{"window":"My App","auto_id":"slider_brightness"}}'
```

### click — Click at Coordinates

Click at screen coordinates. Supports double-click:

```bash
powershell ... '{"cmd":"click","args":{"x":500,"y":300}}'
powershell ... '{"cmd":"click","args":{"x":500,"y":300,"double":true}}'
```

### type — Send Keystrokes

Send keystrokes using .NET SendKeys syntax. Special keys use braces: `{ENTER}`, `{TAB}`, `{ESC}`, `{BACKSPACE}`, `{DELETE}`, `{UP}`, `{DOWN}`, `{LEFT}`, `{RIGHT}`, `{F1}`-`{F12}`. Modifiers: `+` (Shift), `^` (Ctrl), `%` (Alt).

```bash
powershell ... '{"cmd":"type","args":{"text":"Hello World"}}'
powershell ... '{"cmd":"type","args":{"text":"{ENTER}"}}'
powershell ... '{"cmd":"type","args":{"text":"^s"}}'  # Ctrl+S
```

### set_value — Set Slider/Input Values Directly

Set values on elements that support the UIA ValuePattern or RangeValuePattern. Identify the target by `name`, `auto_id`, and/or `type`:

```bash
powershell ... '{"cmd":"set_value","args":{"window":"My App","auto_id":"slider_brightness","value":75}}'
powershell ... '{"cmd":"set_value","args":{"window":"My App","name":"Volume","type":"Slider","value":50}}'
```

This is far more reliable than click-dragging sliders. It sets the value programmatically via UIA patterns.

### screenshot — Capture Screen

Capture the primary screen to a PNG file. Use the Read tool to view the image:

```bash
powershell ... '{"cmd":"screenshot"}'
# Saves to %TEMP%/uia_screenshot.png by default. Then use Read tool on the path to view the image.
```

If `path` is omitted, saves to `%TEMP%/uia_screenshot.png`.

## Key Patterns

### Find Then Click

Use `find_elements` to locate an element, compute its center from the bounding rect, then `click`:

1. Find the element: `find_elements` with appropriate filters
2. From the result's `rect` (`left`, `top`, `right`, `bottom`), compute center: `x = (left + right) / 2`, `y = (top + bottom) / 2`
3. Click at the center coordinates

### Set Slider Value

Do not try to click-drag sliders. Use `set_value` with the slider's `auto_id` or `name` to set its value directly via UIA patterns. This is instant and precise.

### Verify State After Actions

After performing an action (clicking a button, setting a value), use `tree_walk` or `find_elements` to confirm the state changed as expected. This is especially important for toggle buttons and checkboxes -- check the `toggle_state` field.

### Discover UI Structure

When working with an unfamiliar application:

1. `list_windows` to find the window name
2. `tree_walk` with a shallow `max_depth` (3-5) to get an overview
3. `tree_walk` with `type_filter` to find specific control types
4. `find_elements` with `name_contains` for targeted searches

## Reference

See [references/commands.md](references/commands.md) for the full command protocol with detailed request/response examples.
