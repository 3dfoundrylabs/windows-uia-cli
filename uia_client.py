"""
Python client for the persistent PowerShell UIA server.

Usage:
    from uia_client import UIAClient

    with UIAClient() as uia:
        uia.ping()
        windows = uia.list_windows()
        elements = uia.tree_walk('My App', type_filter=['Slider'])
        uia.click(500, 300)
        uia.set_value('My App', name='brightness', value=75)
        uia.screenshot('/tmp/shot.png')
"""

import json
import re
import subprocess
import time
from pathlib import Path
from typing import Any


class UIAClient:
    """Persistent PowerShell UIA automation client.

    Spawns a single PowerShell process that keeps .NET UIA assemblies loaded.
    Commands are sent as newline-delimited JSON over stdin/stdout, giving
    sub-millisecond per-command overhead instead of ~1s cold start per call.
    """

    def __init__(self, server_script: str | None = None, timeout: float = 30.0):
        if server_script is None:
            server_script = str(Path(__file__).parent / 'uia_server.ps1')
        self._script = server_script
        self._timeout = timeout
        self._proc: subprocess.Popen | None = None

    def start(self) -> dict:
        """Launch the PowerShell server process."""
        if self._proc and self._proc.poll() is None:
            return {'ok': True, 'msg': 'already running'}

        self._proc = subprocess.Popen(
            ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', self._script],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        ready_line = self._proc.stdout.readline()
        if not ready_line:
            err = self._proc.stderr.read()
            raise RuntimeError(f'UIA server failed to start: {err}')
        ready = json.loads(ready_line)
        if not ready.get('ok'):
            raise RuntimeError(f'UIA server startup error: {ready}')
        return ready

    def stop(self):
        """Gracefully shut down the server."""
        if self._proc and self._proc.poll() is None:
            try:
                self._send({'cmd': 'quit'})
            except Exception:
                pass
            self._proc.terminate()
            self._proc.wait(timeout=5)
        self._proc = None

    def _send(self, request: dict) -> dict:
        """Send a JSON command and read the JSON response."""
        if not self._proc or self._proc.poll() is not None:
            raise RuntimeError('UIA server is not running - call start() first')

        line = json.dumps(request, separators=(',', ':')) + '\n'
        self._proc.stdin.write(line)
        self._proc.stdin.flush()

        resp_line = self._proc.stdout.readline()
        if not resp_line:
            err = self._proc.stderr.read()
            raise RuntimeError(f'UIA server died: {err}')
        # PowerShell ConvertTo-Json can emit control chars from UI element text
        clean = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', resp_line)
        return json.loads(clean)

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()

    # ── Commands ──

    def ping(self) -> dict:
        return self._send({'cmd': 'ping'})

    def list_windows(self) -> dict:
        return self._send({'cmd': 'list_windows'})

    def find_window(self, name: str) -> dict:
        return self._send({'cmd': 'find_window', 'args': {'name': name}})

    def tree_walk(
        self,
        window: str,
        max_depth: int = 15,
        type_filter: list[str] | None = None,
    ) -> dict:
        args: dict[str, Any] = {'window': window, 'max_depth': max_depth}
        if type_filter:
            args['type_filter'] = type_filter
        return self._send({'cmd': 'tree_walk', 'args': args})

    def find_elements(
        self,
        window: str,
        type: str | None = None,
        name: str | None = None,
        name_contains: str | None = None,
        auto_id: str | None = None,
        class_name: str | None = None,
        max_depth: int = 15,
    ) -> dict:
        args: dict[str, Any] = {'window': window, 'max_depth': max_depth}
        if type:
            args['type'] = type
        if name:
            args['name'] = name
        if name_contains:
            args['name_contains'] = name_contains
        if auto_id:
            args['auto_id'] = auto_id
        if class_name:
            args['class_name'] = class_name
        return self._send({'cmd': 'find_elements', 'args': args})

    def set_value(
        self,
        window: str,
        value: float | str,
        type: str | None = None,
        name: str | None = None,
        auto_id: str | None = None,
    ) -> dict:
        args: dict[str, Any] = {'window': window, 'value': value}
        if type:
            args['type'] = type
        if name:
            args['name'] = name
        if auto_id:
            args['auto_id'] = auto_id
        return self._send({'cmd': 'set_value', 'args': args})

    def click(self, x: int, y: int, double: bool = False) -> dict:
        return self._send({'cmd': 'click', 'args': {'x': x, 'y': y, 'double': double}})

    def screenshot(self, path: str | None = None) -> dict:
        args = {}
        if path:
            args['path'] = path
        return self._send({'cmd': 'screenshot', 'args': args})

    def type_text(self, text: str) -> dict:
        return self._send({'cmd': 'type', 'args': {'text': text}})


if __name__ == '__main__':
    print('Starting UIA server...')
    t0 = time.perf_counter()
    with UIAClient() as uia:
        startup = time.perf_counter() - t0
        print(f'Server started in {startup:.3f}s')

        print('\n--- ping ---')
        print(uia.ping())

        print('\n--- list_windows ---')
        result = uia.list_windows()
        print(f'Found {result.get("count", 0)} windows:')
        for w in (result.get('windows') or [])[:10]:
            print(f'  {w.get("name")!r}')

        print('\n--- ping (warm round-trip overhead) ---')
        times = []
        for _ in range(10):
            t1 = time.perf_counter()
            uia.ping()
            times.append(time.perf_counter() - t1)
        avg = sum(times) / len(times)
        print(f'Ping avg: {avg*1000:.1f}ms over 10 calls')

    print('\nDone.')
