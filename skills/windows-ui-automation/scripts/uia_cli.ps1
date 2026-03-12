$ErrorActionPreference = 'Stop'

$pipeName = 'uia-server'
$pidFile  = Join-Path $env:TEMP 'uia-server.pid'

# --- Parse argument ---
if ($args.Count -lt 1) {
    Write-Output '{"ok":false,"error":"Usage: uia_cli.ps1 ''{ \"cmd\": \"ping\" }''"}'
    exit 1
}
$jsonCmd = $args[0]

# --- Auto-start server if needed ---
$needStart = $true

if (Test-Path $pidFile) {
    $savedPid = (Get-Content $pidFile -Raw).Trim()
    if ($savedPid -match '^\d+$') {
        $proc = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
        if ($proc) { $needStart = $false }
    }
}

if ($needStart) {
    # Remove stale PID file
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force }

    $serverScript = Join-Path $PSScriptRoot 'uia_server.ps1'
    Start-Process -WindowStyle Hidden -FilePath 'powershell' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $serverScript

    # Wait for PID file to appear (server writes it on startup)
    $timeout = 100  # 100 x 100ms = 10s (server needs time for .NET assembly loading)
    for ($i = 0; $i -lt $timeout; $i++) {
        if (Test-Path $pidFile) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path $pidFile)) {
        Write-Output '{"ok":false,"error":"Server failed to start within 10 seconds"}'
        exit 1
    }
    # Give pipe a moment to start listening after PID file is written
    Start-Sleep -Milliseconds 200
}

# --- Send command via named pipe ---
try {
    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName,
        [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(10000)  # 10s timeout for connection

    $writer = New-Object System.IO.StreamWriter($pipe)
    $writer.AutoFlush = $true
    $writer.WriteLine($jsonCmd)

    $reader = New-Object System.IO.StreamReader($pipe)
    $response = $reader.ReadLine()

    $pipe.Dispose()

    Write-Output $response

    # Set exit code based on ok field
    if ($response -match '"ok"\s*:\s*false') {
        exit 1
    }
    exit 0
}
catch {
    $errMsg = $_.Exception.Message -replace '"', '\"'
    Write-Output "{`"ok`":false,`"error`":`"$errMsg`"}"
    exit 1
}
