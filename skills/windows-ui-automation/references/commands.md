# UIA CLI Command Reference

All commands are sent as JSON strings to the CLI:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/uia_cli.ps1" '<json>'
```

Every response includes `"ok": true` on success or `"ok": false, "error": "..."` on failure.

---

## ping

Health check. Verifies the server is running.

**Request:**
```json
{"cmd": "ping"}
```

**Response:**
```json
{"ok": true, "msg": "pong"}
```

---

## list_windows

List all top-level windows that have a name.

**Request:**
```json
{"cmd": "list_windows"}
```

**Response:**
```json
{
  "ok": true,
  "count": 3,
  "windows": [
    {
      "name": "Untitled - Notepad",
      "class": "Notepad",
      "auto_id": "",
      "rect": {"left": 100, "top": 100, "right": 900, "bottom": 700},
      "enabled": true
    },
    {
      "name": "Task Manager",
      "class": "TaskManagerWindow",
      "auto_id": "",
      "rect": {"left": 200, "top": 150, "right": 1000, "bottom": 800},
      "enabled": true
    }
  ]
}
```

---

## find_window

Find a specific top-level window by exact name.

**Request:**
```json
{"cmd": "find_window", "args": {"name": "Untitled - Notepad"}}
```

**Response:**
```json
{
  "ok": true,
  "element": {
    "name": "Untitled - Notepad",
    "type": "Window",
    "class": "Notepad",
    "auto_id": "",
    "depth": 0,
    "rect": {"left": 100, "top": 100, "right": 900, "bottom": 700},
    "enabled": true
  }
}
```

**Args:**
| Arg | Type | Required | Description |
|-----|------|----------|-------------|
| `name` | string | yes | Exact window title |

**Error:**
```json
{"ok": false, "error": "Window 'Nonexistent' not found"}
```

---

## tree_walk

Walk the full UI element tree of a window. Returns all elements (or filtered subset).

**Request:**
```json
{"cmd": "tree_walk", "args": {"window": "My App"}}
```

**Request with filters:**
```json
{"cmd": "tree_walk", "args": {
  "window": "My App",
  "type_filter": ["Button", "Slider", "CheckBox"],
  "max_depth": 5
}}
```

**Response:**
```json
{
  "ok": true,
  "time_s": 0.0342,
  "count": 12,
  "elements": [
    {
      "name": "Save",
      "type": "Button",
      "class": "Button",
      "auto_id": "btn_save",
      "depth": 2,
      "rect": {"left": 10, "top": 50, "right": 90, "bottom": 80},
      "enabled": true
    },
    {
      "name": "Brightness",
      "type": "Slider",
      "class": "",
      "auto_id": "slider_brightness",
      "depth": 3,
      "rect": {"left": 10, "top": 100, "right": 300, "bottom": 130},
      "enabled": true,
      "range_value": {
        "value": 50.0,
        "min": 0.0,
        "max": 100.0,
        "readonly": false
      }
    },
    {
      "name": "Auto-Save",
      "type": "CheckBox",
      "class": "",
      "auto_id": "chk_autosave",
      "depth": 2,
      "rect": {"left": 10, "top": 140, "right": 150, "bottom": 160},
      "enabled": true,
      "toggle_state": "On"
    }
  ]
}
```

**Args:**
| Arg | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `window` | string | yes | - | Exact window title |
| `type_filter` | string[] | no | all types | Only include these control types (e.g. `["Button", "Slider"]`) |
| `max_depth` | int | no | 15 | Maximum tree depth to traverse |

---

## find_elements

Search for elements matching specific criteria. All filter args are optional but at least one should be provided.

**Request:**
```json
{"cmd": "find_elements", "args": {
  "window": "My App",
  "type": "Button",
  "name_contains": "Save"
}}
```

**Response:**
```json
{
  "ok": true,
  "time_s": 0.0156,
  "count": 1,
  "elements": [
    {
      "name": "Save Project",
      "type": "Button",
      "class": "Button",
      "auto_id": "btn_save",
      "depth": 2,
      "rect": {"left": 10, "top": 50, "right": 90, "bottom": 80},
      "enabled": true
    }
  ]
}
```

**Args:**
| Arg | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `window` | string | yes | - | Exact window title |
| `type` | string | no | - | Control type (e.g. `"Button"`, `"Slider"`, `"Edit"`, `"Text"`, `"CheckBox"`) |
| `name` | string | no | - | Exact element name |
| `name_contains` | string | no | - | Substring match on element name |
| `auto_id` | string | no | - | Exact AutomationId match |
| `class_name` | string | no | - | Exact ClassName match |
| `max_depth` | int | no | 15 | Maximum tree depth to search |

---

## set_value

Set the value of a UI element (slider, text input, etc.) using UIA ValuePattern or RangeValuePattern. The element is located by the filter args.

**Request (slider by auto_id):**
```json
{"cmd": "set_value", "args": {
  "window": "My App",
  "auto_id": "slider_brightness",
  "value": 75
}}
```

**Request (slider by name and type):**
```json
{"cmd": "set_value", "args": {
  "window": "My App",
  "name": "Volume",
  "type": "Slider",
  "value": 50
}}
```

**Response:**
```json
{
  "ok": true,
  "time_s": 0.0089,
  "pattern": "RangeValue",
  "old_value": 50.0,
  "new_value": 75.0
}
```

**Args:**
| Arg | Type | Required | Description |
|-----|------|----------|-------------|
| `window` | string | yes | Exact window title |
| `value` | number/string | yes | Value to set |
| `name` | string | no | Element name filter |
| `auto_id` | string | no | AutomationId filter |
| `type` | string | no | Control type filter |
| `max_depth` | int | no | Maximum search depth (default 15) |

**Notes:** Tries RangeValuePattern first (for sliders, progress bars), then ValuePattern (for text inputs). Returns `"pattern"` to indicate which was used.

**Error:**
```json
{"ok": false, "error": "Element does not support settable Value or RangeValue pattern"}
```

---

## click

Click at absolute screen coordinates using native SendInput.

**Request (single click):**
```json
{"cmd": "click", "args": {"x": 500, "y": 300}}
```

**Request (double click):**
```json
{"cmd": "click", "args": {"x": 500, "y": 300, "double": true}}
```

**Response:**
```json
{
  "ok": true,
  "time_s": 0.0312,
  "x": 500,
  "y": 300,
  "double": false
}
```

**Args:**
| Arg | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `x` | int | yes | - | Screen X coordinate |
| `y` | int | yes | - | Screen Y coordinate |
| `double` | bool | no | false | Double-click if true |

---

## click_element

Find an element by filters and click its center — combines `find_elements` + `click` in one call. Accepts the same filter args as `find_elements`. Clicks the first matching element.

**Request:**
```json
{"cmd": "click_element", "args": {"window": "My App", "name": "Save", "type": "Button"}}
```

**Request (with offset — e.g., click checkbox area at left edge):**
```json
{"cmd": "click_element", "args": {"window": "My App", "type": "ListItem", "name_contains": "file.mp4", "offset_x": -100}}
```

**Response:**
```json
{
  "ok": true,
  "time_s": 0.0523,
  "x": 450,
  "y": 300,
  "double": false,
  "element": {
    "name": "Save",
    "type": "Button",
    "class": "Button",
    "auto_id": "btn_save",
    "depth": 0,
    "rect": {"left": 400, "top": 280, "right": 500, "bottom": 320},
    "enabled": true
  }
}
```

**Args:**
| Arg | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `window` | string | yes | - | Exact window title |
| `type` | string | no | - | Control type filter |
| `name` | string | no | - | Exact name filter |
| `name_contains` | string | no | - | Substring name filter |
| `auto_id` | string | no | - | AutomationId filter |
| `class_name` | string | no | - | ClassName filter |
| `offset_x` | int | no | 0 | X offset from element center |
| `offset_y` | int | no | 0 | Y offset from element center |
| `double` | bool | no | false | Double-click if true |
| `max_depth` | int | no | 15 | Maximum search depth |

**Error (not found):**
```json
{"ok": false, "error": "Element not found", "time_s": 0.0342}
```

---

## screenshot

Capture the primary screen to a PNG file.

**Request:**
```json
{"cmd": "screenshot", "args": {"path": "C:/temp/screen.png"}}
```

**Request (default path):**
```json
{"cmd": "screenshot"}
```

**Response:**
```json
{
  "ok": true,
  "time_s": 0.1234,
  "path": "C:\\temp\\screen.png",
  "resolution": "1920x1080",
  "file_size_kb": 842.3
}
```

**Args:**
| Arg | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `path` | string | no | `%TEMP%/uia_screenshot.png` | Output file path |

**Notes:** Use the Read tool to view the captured image after taking the screenshot.

---

## type

Send keystrokes to the currently focused window using .NET SendKeys syntax.

**Request (text):**
```json
{"cmd": "type", "args": {"text": "Hello World"}}
```

**Request (special keys):**
```json
{"cmd": "type", "args": {"text": "{ENTER}"}}
```

**Request (keyboard shortcut):**
```json
{"cmd": "type", "args": {"text": "^s"}}
```

**Response:**
```json
{"ok": true, "time_s": 0.0021}
```

**Args:**
| Arg | Type | Required | Description |
|-----|------|----------|-------------|
| `text` | string | yes | SendKeys-format string |

**SendKeys Reference:**
| Syntax | Meaning |
|--------|---------|
| `{ENTER}` | Enter key |
| `{TAB}` | Tab key |
| `{ESC}` | Escape key |
| `{BACKSPACE}` or `{BS}` | Backspace |
| `{DELETE}` or `{DEL}` | Delete |
| `{UP}` `{DOWN}` `{LEFT}` `{RIGHT}` | Arrow keys |
| `{F1}` - `{F12}` | Function keys |
| `{HOME}` `{END}` | Home / End |
| `{PGUP}` `{PGDN}` | Page Up / Page Down |
| `+` | Shift modifier (e.g. `+{TAB}` = Shift+Tab) |
| `^` | Ctrl modifier (e.g. `^c` = Ctrl+C) |
| `%` | Alt modifier (e.g. `%{F4}` = Alt+F4) |
| `{key N}` | Repeat key N times (e.g. `{RIGHT 5}`) |

---

## quit

Shut down the UIA server process.

**Request:**
```json
{"cmd": "quit"}
```

**Response:**
```json
{"ok": true, "msg": "bye"}
```

**Notes:** The server process exits and the PID file is cleaned up. The next CLI call will auto-start a new server.
