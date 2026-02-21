"""Device client and connection helpers for AuiTO MCP tools."""

import atexit
import os
import socket
import subprocess
import time
from typing import Dict, List

import httpx

# AuiTO API configuration from environment or defaults.
# Keep KIMIRUN_* as backward-compatible aliases.
KIMIRUN_HOST = os.environ.get("AUITO_HOST", os.environ.get("KIMIRUN_HOST", "10.0.0.9"))
KIMIRUN_PORT = int(os.environ.get("AUITO_PORT", os.environ.get("KIMIRUN_PORT", "8876")))
BASE_URL = f"http://{KIMIRUN_HOST}:{KIMIRUN_PORT}"

_TUNNEL_STATE = {"proc": None, "local_port": None, "key": None}
_DAEMON_STATE = {"proc": None, "bin": None}


def _is_truthy(value: str) -> bool:
    if not value:
        return False
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def _pick_free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    _, port = s.getsockname()
    s.close()
    return int(port)


def _parse_ports(value: str) -> List[int]:
    ports: List[int] = []
    if not value:
        return ports
    for token in value.split(","):
        token = token.strip()
        if not token:
            continue
        try:
            port = int(token)
        except ValueError:
            continue
        if 0 < port < 65536 and port not in ports:
            ports.append(port)
    return ports


def _is_local_host(host: str) -> bool:
    if not host:
        return False
    lowered = host.strip().lower()
    return lowered in {"127.0.0.1", "localhost", "::1"}


def _http_ping_ok(host: str, port: int, timeout: float = 1.0) -> bool:
    url = f"http://{host}:{int(port)}/ping"
    try:
        r = httpx.get(url, timeout=timeout)
        return r.status_code < 500
    except Exception:
        return False


def _start_local_daemon_if_needed(host: str) -> bool:
    """Best-effort local daemon start. Returns True if a process was started."""
    if not _is_local_host(host):
        return False
    if not _is_truthy(os.environ.get("AUITO_AUTOSTART_DAEMON", "1")):
        return False

    daemon_bin = os.environ.get("AUITO_DAEMON_BIN", "/usr/bin/auito-daemon").strip() or "/usr/bin/auito-daemon"
    if not os.path.exists(daemon_bin):
        return False

    proc = _DAEMON_STATE.get("proc")
    if proc and proc.poll() is None:
        return False

    try:
        proc = subprocess.Popen(
            [daemon_bin],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        return False

    _DAEMON_STATE["proc"] = proc
    _DAEMON_STATE["bin"] = daemon_bin

    def _cleanup():
        p = _DAEMON_STATE.get("proc")
        if p and p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass

    atexit.register(_cleanup)
    return True


class KimiRunDeviceClient:
    """HTTP client for KimiRun device API"""

    def __init__(self, host: str = None, port: int = None):
        self.host = host or KIMIRUN_HOST
        self.port = port or KIMIRUN_PORT
        self.use_ssh_tunnel = _is_truthy(os.environ.get("KIMIRUN_SSH_TUNNEL", ""))
        self.ssh_user = os.environ.get("KIMIRUN_SSH_USER", "root")
        self.ssh_host = os.environ.get("KIMIRUN_SSH_HOST", self.host)
        self.ssh_port = int(os.environ.get("KIMIRUN_SSH_PORT", "22"))
        self.local_port = None

        if self.use_ssh_tunnel:
            self._ensure_ssh_tunnel()
            self.base_url = f"http://127.0.0.1:{self.local_port}"
        else:
            self._resolve_working_port()
            self.base_url = f"http://{self.host}:{self.port}"

        self.client = httpx.Client(base_url=self.base_url, timeout=30.0)

    def get_base_url(self) -> str:
        return self.base_url

    def get(self, path: str, **kwargs):
        return self.client.get(path, **kwargs)

    def post(self, path: str, **kwargs):
        return self.client.post(path, **kwargs)

    def build_auth_headers(self) -> Dict[str, str]:
        token = (
            os.environ.get("AUITO_AUTH_TOKEN")
            or os.environ.get("AUITO_TOKEN")
            or os.environ.get("KIMIRUN_AUTH_TOKEN")
            or os.environ.get("KIMIRUN_TOKEN")
        )
        headers: Dict[str, str] = {}
        if token:
            headers["X-Auth-Token"] = token
        return headers

    def _resolve_working_port(self) -> None:
        """Pick the first responsive endpoint from configured and fallback ports."""
        configured = [self.port]
        fallback = _parse_ports(os.environ.get("AUITO_FALLBACK_PORTS", "8876,8765,8080"))
        candidates: List[int] = []
        for p in configured + fallback:
            if p not in candidates:
                candidates.append(p)

        for p in candidates:
            if _http_ping_ok(self.host, p, timeout=1.0):
                self.port = p
                return

        started = _start_local_daemon_if_needed(self.host)
        if started:
            time.sleep(0.3)
            for p in candidates:
                if _http_ping_ok(self.host, p, timeout=1.5):
                    self.port = p
                    return

        # Keep configured port if nothing responded; request handlers will surface the error.

    def _ensure_ssh_tunnel(self) -> None:
        global _TUNNEL_STATE
        local_port = os.environ.get("KIMIRUN_SSH_LOCAL_PORT", "").strip()
        if local_port:
            try:
                self.local_port = int(local_port)
            except ValueError:
                self.local_port = None

        if not self.local_port:
            self.local_port = _pick_free_port()

        key = (self.ssh_user, self.ssh_host, self.ssh_port, self.port, self.local_port)
        proc = _TUNNEL_STATE.get("proc")
        if proc and proc.poll() is None and _TUNNEL_STATE.get("key") == key:
            return

        if proc and proc.poll() is None:
            proc.terminate()

        cmd = [
            "ssh",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
            "-N",
            "-L",
            f"{self.local_port}:127.0.0.1:{self.port}",
            f"{self.ssh_user}@{self.ssh_host}",
            "-p",
            str(self.ssh_port),
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _TUNNEL_STATE["proc"] = proc
        _TUNNEL_STATE["local_port"] = self.local_port
        _TUNNEL_STATE["key"] = key

        def _cleanup():
            p = _TUNNEL_STATE.get("proc")
            if p and p.poll() is None:
                p.terminate()

        atexit.register(_cleanup)

        ok = False
        for _ in range(20):
            try:
                s = socket.create_connection(("127.0.0.1", self.local_port), timeout=0.2)
                s.close()
                ok = True
                break
            except OSError:
                time.sleep(0.1)

        if not ok:
            try:
                proc.terminate()
            except Exception:
                pass
            raise RuntimeError("SSH tunnel failed to start")
