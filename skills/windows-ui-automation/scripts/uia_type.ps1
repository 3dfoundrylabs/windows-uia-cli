# uia_type.ps1 — Type text via UIA CLI without JSON escaping issues.
# Reads text from stdin or -Text parameter. Builds JSON internally.
#
# Usage (from bash):
#   echo 'Hello World' | powershell -NoProfile -ExecutionPolicy Bypass -File uia_type.ps1
#   echo '"C:\path\file (1).mp4"' | powershell -NoProfile -ExecutionPolicy Bypass -File uia_type.ps1 -Literal
#
# -Literal: Escape SendKeys special characters so text is typed as-is.
#           Without this, characters like () + ^ % ~ are interpreted as SendKeys commands.

param(
    [string]$Text,
    [switch]$Literal
)

$ErrorActionPreference = 'Stop'

# Read from stdin if no -Text provided
if (-not $Text) {
    $Text = [Console]::In.ReadToEnd().TrimEnd("`r", "`n")
}

if (-not $Text) {
    Write-Output '{"ok":false,"error":"No text provided. Pipe text via stdin or use -Text parameter."}'
    exit 1
}

# Escape SendKeys special characters for literal typing
if ($Literal) {
    # SendKeys specials: + ^ % ~ { } [ ] ( )
    # Must escape { } first since we use braces for escaping
    $Text = $Text.Replace('{', '{{OPEN}}')
    $Text = $Text.Replace('}', '{{CLOSE}}')
    $Text = $Text.Replace('{{OPEN}}', '{{}')
    $Text = $Text.Replace('{{CLOSE}}', '{}}')
    $Text = $Text.Replace('(', '{(}')
    $Text = $Text.Replace(')', '{)}')
    $Text = $Text.Replace('+', '{+}')
    $Text = $Text.Replace('^', '{^}')
    $Text = $Text.Replace('%', '{%}')
    $Text = $Text.Replace('~', '{~}')
}

# Build JSON command
$cmd = @{ cmd = 'type'; args = @{ text = $Text } } | ConvertTo-Json -Compress

# Call uia_cli.ps1 in the same process (avoids argument escaping across process boundaries)
$cliPath = Join-Path $PSScriptRoot 'uia_cli.ps1'
& $cliPath $cmd
