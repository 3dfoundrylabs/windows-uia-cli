# windows-uia-cli

A **Claude Code plugin** that provides Windows UI automation capabilities. It wraps the Windows UI Automation (UIA) framework behind a simple JSON CLI, powered by a persistent PowerShell background server with zero dependencies.

## What's Included

- **Skill** (`skills/windows-ui-automation/`) — auto-discovered by Claude Code agents, teaches them how to use the CLI
- **CLI** (`skills/windows-ui-automation/scripts/uia_cli.ps1`) — thin client that sends JSON commands to the server
- **Server** (`skills/windows-ui-automation/scripts/uia_server.ps1`) — persistent background process with .NET UIA assemblies loaded; communicates via named pipe (`\\.\pipe\uia-server`)

## Prerequisites

- Windows 10 or Windows 11
- PowerShell 5.1+ (included with Windows)

## Installation

Load as a Claude Code plugin during development:

```bash
claude --plugin-dir <path-to-this-repo>
```

The skill will appear as `windows-uia-cli:windows-ui-automation` and be auto-discovered by agents.

## Quick Start

```powershell
# Health check (starts server automatically)
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\windows-ui-automation\scripts\uia_cli.ps1 '{"cmd":"ping"}'

# List all open windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\windows-ui-automation\scripts\uia_cli.ps1 '{"cmd":"list_windows"}'

# Find all buttons in Notepad
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\windows-ui-automation\scripts\uia_cli.ps1 '{"cmd":"find_elements","args":{"window":"Untitled - Notepad","type":"Button"}}'
```

## Commands

| Command | Description |
|---------|-------------|
| `ping` | Health check, returns `pong` |
| `list_windows` | List all top-level windows |
| `find_window` | Find a window by exact title |
| `tree_walk` | Walk UI element tree (supports `type_filter`, `max_depth`) |
| `find_elements` | Search elements by `type`, `name`, `name_contains`, `auto_id`, `class_name` |
| `click` | Click at screen coordinates (supports `double`) |
| `type` | Send keystrokes (SendKeys syntax) |
| `set_value` | Set slider/input values via UIA patterns |
| `screenshot` | Capture screen to PNG file |
| `quit` | Shut down the server |

See [skills/windows-ui-automation/references/commands.md](skills/windows-ui-automation/references/commands.md) for the full protocol reference with request/response examples.

## Architecture

On the first CLI call, `uia_cli.ps1` spawns `uia_server.ps1` as a hidden background process. The server loads .NET `UIAutomationClient` and `UIAutomationTypes` assemblies once, then listens on a named pipe. Each CLI invocation connects to the pipe, sends a JSON command, reads the JSON response, and disconnects. The server stays resident so assembly loading cost (~1s) is paid only once — subsequent calls complete in ~5ms. A PID file in `%TEMP%` tracks the server process for auto-restart if it dies.
