"""
KimiRun Device Control Tools

MCP tool definitions and handlers for device automation via HTTP API.
"""

import os
import atexit
import socket
import subprocess
import time
import base64
import httpx
from typing import List, Dict, Any
from mcp.types import Tool, TextContent, ImageContent

# AuiTO API configuration from environment or defaults.
# Keep KIMIRUN_* as backward-compatible aliases.
KIMIRUN_HOST = os.environ.get("AUITO_HOST", os.environ.get("KIMIRUN_HOST", "10.0.0.9"))
KIMIRUN_PORT = int(os.environ.get("AUITO_PORT", os.environ.get("KIMIRUN_PORT", "8876")))
BASE_URL = f"http://{KIMIRUN_HOST}:{KIMIRUN_PORT}"

_TUNNEL_STATE = {"proc": None, "local_port": None, "key": None}


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
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-N",
            "-L", f"{self.local_port}:127.0.0.1:{self.port}",
            f"{self.ssh_user}@{self.ssh_host}",
            "-p", str(self.ssh_port),
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


class DeviceToolRegistry:
    """Registry for device control MCP tools"""
    
    def __init__(self, client: KimiRunDeviceClient = None):
        self.client = client or KimiRunDeviceClient()
        self.daemon_port = int(os.environ.get("AUITO_DAEMON_PORT", "8876"))

    @staticmethod
    def _is_strict_non_ax_method(method: str) -> bool:
        if not isinstance(method, str):
            return False
        lower = method.strip().lower()
        if lower in {"a11y", "ax", "auto", ""}:
            return False
        aliases = {
            "iohid": "sim",
            "old": "legacy",
            "connection": "conn",
            "zx": "zxtouch",
        }
        canonical = aliases.get(lower, lower)
        return canonical in {"sim", "direct", "legacy", "conn", "bks", "zxtouch"}
    
    def get_tool_definitions(self) -> List[Tool]:
        """Get all device control tool definitions"""
        return [
            Tool(
                name="device_ping",
                description="Check if KimiRun device is online",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_state",
                description="Get device and server state (/state)",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_tap",
                description="Tap at screen coordinates",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "x": {"type": "number", "description": "X coordinate"},
                        "y": {"type": "number", "description": "Y coordinate"},
                        "method": {"type": "string", "description": "Touch method override (e.g., auto, ax, zxtouch, bks, sim, legacy)"},
                        "pixel": {"type": "boolean", "description": "Treat coordinates as pixels", "default": False}
                    },
                    "required": ["x", "y"]
                }
            ),
            Tool(
                name="device_screenshot",
                description="Capture device screenshot and return base64-encoded image",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_type_text",
                description="Type text on device",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "text": {"type": "string", "description": "Text to type"}
                    },
                    "required": ["text"]
                }
            ),
            Tool(
                name="device_swipe",
                description="Swipe on screen from start to end coordinates",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "startX": {"type": "number", "description": "Start X coordinate"},
                        "startY": {"type": "number", "description": "Start Y coordinate"},
                        "endX": {"type": "number", "description": "End X coordinate"},
                        "endY": {"type": "number", "description": "End Y coordinate"},
                        "duration": {"type": "number", "description": "Swipe duration in milliseconds", "default": 500},
                        "method": {"type": "string", "description": "Touch method override (e.g., auto, ax, zxtouch, bks, sim, legacy)"},
                        "pixel": {"type": "boolean", "description": "Treat coordinates as pixels", "default": False},
                        "scroll": {"type": "boolean", "description": "Prefer scroll semantics (if supported)", "default": False}
                    },
                    "required": ["startX", "startY", "endX", "endY"]
                }
            ),
            Tool(
                name="device_press_home",
                description="Press home button",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_launch_app",
                description="Launch an app by bundle ID",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "bundle_id": {"type": "string", "description": "App bundle ID (e.g., com.apple.mobilesafari)"}
                    },
                    "required": ["bundle_id"]
                }
            ),
            Tool(
                name="device_get_ui_hierarchy",
                description="Get current UI element hierarchy as JSON",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_list_apps",
                description="List installed apps on device",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "system_apps": {"type": "boolean", "description": "Include system apps", "default": False}
                    }
                }
            ),
            Tool(
                name="device_get_screen_size",
                description="Get device screen dimensions",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_a11y_interactive",
                description="Get accessibility interactive elements as JSON",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "compact": {"type": "boolean", "description": "Return compact JSON (recommended)", "default": True},
                        "limit": {"type": "integer", "description": "Limit number of elements", "default": 60}
                    }
                }
            ),
            Tool(
                name="device_a11y_activate",
                description="Activate an accessibility element by index from the most recent a11y/interactive result",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "index": {"type": "integer", "description": "Element index"}
                    },
                    "required": ["index"]
                }
            ),
            Tool(
                name="device_a11y_overlay",
                description="Show/hide accessibility overlay boxes on device",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "enabled": {"type": "boolean", "description": "Enable overlay"},
                        "interactiveOnly": {"type": "boolean", "description": "Only show interactive elements", "default": True}
                    },
                    "required": ["enabled"]
                }
            ),
            Tool(
                name="device_settings_safe_activate",
                description="Ensure Settings root (safe back) then activate element by index",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "index": {"type": "integer", "description": "Element index"},
                        "max_steps": {"type": "integer", "description": "Max back steps", "default": 6}
                    },
                    "required": ["index"]
                }
            ),
            Tool(
                name="device_touch_senderid",
                description="Get touch senderID diagnostics",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_touch_senderid_set",
                description="Override touch senderID (id can be hex string like 0x123 or integer)",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "id": {"type": "string", "description": "SenderID value (hex string or decimal)"},
                        "persist": {"type": "boolean", "description": "Persist for this boot", "default": False}
                    },
                    "required": ["id"]
                }
            ),
            Tool(
                name="device_touch_bkhid_selectors",
                description="Log BKHID selectors and return log path",
                inputSchema={"type": "object", "properties": {}}
            ),
            Tool(
                name="device_touch_forcefocus",
                description="Force focus Settings search field",
                inputSchema={"type": "object", "properties": {}}
            ),
        ]
    
    async def handle_tool_call(self, name: str, arguments: dict) -> List[TextContent]:
        """Handle device tool calls by mapping to KimiRun HTTP API endpoints."""
        try:
            if name == "device_ping":
                return await self._handle_ping()
            elif name == "device_state":
                return await self._handle_state()
            elif name == "device_tap":
                return await self._handle_tap(arguments)
            elif name == "device_screenshot":
                return await self._handle_screenshot()
            elif name == "device_type_text":
                return await self._handle_type_text(arguments)
            elif name == "device_swipe":
                return await self._handle_swipe(arguments)
            elif name == "device_press_home":
                return await self._handle_press_home()
            elif name == "device_launch_app":
                return await self._handle_launch_app(arguments)
            elif name == "device_get_ui_hierarchy":
                return await self._handle_ui_hierarchy()
            elif name == "device_list_apps":
                return await self._handle_list_apps(arguments)
            elif name == "device_get_screen_size":
                return await self._handle_screen_size()
            elif name == "device_a11y_interactive":
                return await self._handle_a11y_interactive(arguments)
            elif name == "device_a11y_activate":
                return await self._handle_a11y_activate(arguments)
            elif name == "device_a11y_overlay":
                return await self._handle_a11y_overlay(arguments)
            elif name == "device_settings_safe_activate":
                return await self._handle_settings_safe_activate(arguments)
            elif name == "device_touch_senderid":
                return await self._handle_touch_senderid()
            elif name == "device_touch_senderid_set":
                return await self._handle_touch_senderid_set(arguments)
            elif name == "device_touch_bkhid_selectors":
                return await self._handle_touch_bkhid_selectors()
            elif name == "device_touch_forcefocus":
                return await self._handle_touch_forcefocus()
            else:
                return [TextContent(type="text", text=f"Unknown tool: {name}")]
        
        except httpx.ConnectError as e:
            return [TextContent(type="text", text=f"Connection error: Cannot reach KimiRun device at {self.client.get_base_url()}. Is the device online?")]
        except httpx.TimeoutException as e:
            return [TextContent(type="text", text=f"Timeout error: Request to {self.client.get_base_url()} timed out.")]
        except Exception as e:
            return [TextContent(type="text", text=f"Error: {type(e).__name__}: {str(e)}")]
    
    async def _handle_ping(self) -> List[TextContent]:
        """Handle device_ping tool"""
        response = self.client.get("/ping")
        return [TextContent(type="text", text=f"Device status: {response.text}")]

    async def _handle_state(self) -> List[TextContent]:
        """Handle device_state tool"""
        response = self.client.get("/state")
        return [TextContent(type="text", text=response.text)]
    
    async def _handle_tap(self, arguments: dict) -> List[TextContent]:
        """Handle device_tap tool"""
        x = arguments.get("x")
        y = arguments.get("y")
        method = arguments.get("method")
        pixel = arguments.get("pixel")

        # Strict non-AX methods must go through daemon (8876) so strict verification runs centrally.
        if self._is_strict_non_ax_method(method):
            params = {"x": x, "y": y, "method": method}
            response = self._daemon_get("/tap", params=params)
            return [TextContent(type="text", text=f"Tapped at ({x}, {y}) [strict-daemon]: {response.text}")]

        # Prefer /touch/tap (iOSRunPortal-style) if available
        payload = {"x": x, "y": y}
        if isinstance(method, str) and method.strip():
            payload["method"] = method
        if isinstance(pixel, bool):
            payload["pixel"] = pixel

        headers = self.client.build_auth_headers()
        try:
            response = self.client.post("/touch/tap", json=payload, headers=headers)
            data = None
            try:
                data = response.json()
            except Exception:
                data = None
            if response.status_code < 400 and isinstance(data, dict):
                if data.get("success") is True or data.get("status") == "ok":
                    return [TextContent(type="text", text=f"Tapped at ({x}, {y}): {response.text}")]
        except Exception:
            pass

        # Fallback to /tap (KimiRun daemon)
        params = {"x": x, "y": y}
        if isinstance(method, str) and method.strip():
            params["method"] = method
        response = self.client.get("/tap", params=params)
        return [TextContent(type="text", text=f"Tapped at ({x}, {y}): {response.text}")]
    
    async def _handle_screenshot(self) -> List[TextContent]:
        """Handle device_screenshot tool"""
        response = self.client.get("/screenshot")
        content_type = (response.headers.get("content-type") or "").lower()

        # New daemon behavior: /screenshot can return raw image/png bytes.
        if content_type.startswith("image/") and response.content:
            mime = content_type.split(";")[0].strip() or "image/png"
            payload = base64.b64encode(response.content).decode("ascii")
            return [
                TextContent(type="text", text=f"Screenshot captured ({len(response.content)} bytes binary)"),
                ImageContent(type="image", data=payload, mimeType=mime),
            ]

        try:
            data = response.json()
        except Exception:
            return [TextContent(type="text", text=f"Screenshot failed: non-JSON response ({response.text})")]

        ok = False
        if isinstance(data, dict):
            if data.get("success") is True:
                ok = True
            elif data.get("status") == "ok":
                ok = True

        if ok:
            payload = data.get("data", "")
            size = len(payload) if isinstance(payload, str) else 0
            max_b64 = int(os.environ.get("KIMIRUN_SCREENSHOT_MAX_B64", "2000000"))
            if size > max_b64:
                return await self._handle_screenshot_file_fallback(reason=f"base64 too large ({size} > {max_b64})")
            if isinstance(payload, str) and payload:
                return [
                    TextContent(type="text", text=f"Screenshot captured ({size} bytes base64)"),
                    ImageContent(type="image", data=payload, mimeType="image/png")
                ]
            return await self._handle_screenshot_file_fallback(reason="missing base64 payload")

        err = data.get("error") if isinstance(data, dict) else None
        if not err and isinstance(data, dict):
            err = data.get("message")
        return await self._handle_screenshot_file_fallback(reason=err or "Unknown error")

    async def _handle_screenshot_file_fallback(self, reason: str) -> List[TextContent]:
        """Fallback to /screenshot/file to avoid huge base64 payloads."""
        fmt = os.environ.get("KIMIRUN_SCREENSHOT_FILE_FORMAT", "png").lower()
        quality = os.environ.get("KIMIRUN_SCREENSHOT_FILE_QUALITY", "0.6")
        params = {"format": fmt, "quality": quality}
        response = self.client.get("/screenshot/file", params=params)
        try:
            data = response.json()
        except Exception:
            return [TextContent(type="text", text=f"Screenshot fallback failed: non-JSON response ({response.text})")]

        if isinstance(data, dict) and data.get("status") == "ok":
            path = data.get("path", "")
            bytes_len = data.get("bytes", 0)
            return [
                TextContent(type="text", text=f"Screenshot fallback used: {reason}"),
                TextContent(type="text", text=f"Saved to {path} ({bytes_len} bytes, {data.get('format', '')})")
            ]

        err = data.get("error") if isinstance(data, dict) else None
        if not err and isinstance(data, dict):
            err = data.get("message")
        return [TextContent(type="text", text=f"Screenshot failed: {reason}. Fallback error: {err or 'Unknown error'}")]
    
    async def _handle_type_text(self, arguments: dict) -> List[TextContent]:
        """Handle device_type_text tool"""
        text = arguments.get("text", "")
        response = self.client.get("/keyboard/type", params={"text": text})
        return [TextContent(type="text", text=f"Typed text: {response.text}")]
    
    async def _handle_swipe(self, arguments: dict) -> List[TextContent]:
        """Handle device_swipe tool"""
        duration_ms = arguments.get("duration", 500)
        duration = float(duration_ms) / 1000.0
        method = arguments.get("method")
        pixel = arguments.get("pixel")
        scroll = arguments.get("scroll")

        # Strict non-AX methods must go through daemon (8876) so strict verification runs centrally.
        if self._is_strict_non_ax_method(method):
            params = {
                "x1": arguments.get("startX"),
                "y1": arguments.get("startY"),
                "x2": arguments.get("endX"),
                "y2": arguments.get("endY"),
                "duration": duration,
                "method": method,
            }
            response = self._daemon_get("/swipe", params=params)
            return [TextContent(type="text", text=f"Swiped [strict-daemon]: {response.text}")]

        # Prefer /touch/swipe (iOSRunPortal-style) if available
        payload = {
            "startX": arguments.get("startX"),
            "startY": arguments.get("startY"),
            "endX": arguments.get("endX"),
            "endY": arguments.get("endY"),
            "duration": duration,
        }
        if isinstance(method, str) and method.strip():
            payload["method"] = method
        if isinstance(pixel, bool):
            payload["pixel"] = pixel
        if isinstance(scroll, bool):
            payload["scroll"] = scroll

        headers = self.client.build_auth_headers()
        try:
            response = self.client.post("/touch/swipe", json=payload, headers=headers)
            data = None
            try:
                data = response.json()
            except Exception:
                data = None
            if response.status_code < 400 and isinstance(data, dict):
                if data.get("success") is True or data.get("status") == "ok":
                    return [TextContent(type="text", text=f"Swiped: {response.text}")]
        except Exception:
            pass

        # Fallback to /swipe (KimiRun daemon)
        params = {
            "x1": arguments.get("startX"),
            "y1": arguments.get("startY"),
            "x2": arguments.get("endX"),
            "y2": arguments.get("endY"),
            "duration": duration,
        }
        if isinstance(method, str) and method.strip():
            params["method"] = method
        response = self.client.get("/swipe", params=params)
        return [TextContent(type="text", text=f"Swiped: {response.text}")]
    
    async def _handle_press_home(self) -> List[TextContent]:
        """Handle device_press_home tool"""
        return [TextContent(type="text", text="Home button not supported by daemon API")]
    
    async def _handle_launch_app(self, arguments: dict) -> List[TextContent]:
        """Handle device_launch_app tool"""
        bundle_id = arguments.get("bundle_id", "")
        response = self.client.get("/app/launch", params={"bundleID": bundle_id})
        if response.status_code >= 400 or "Not Found" in (response.text or ""):
            response = self._daemon_get("/app/launch", params={"bundleID": bundle_id})
        return [TextContent(type="text", text=f"Launch app '{bundle_id}': {response.text}")]
    
    async def _handle_ui_hierarchy(self) -> List[TextContent]:
        """Handle device_get_ui_hierarchy tool"""
        response = self.client.get("/uiHierarchy")
        data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            response = self._daemon_get("/uiHierarchy")
            data = self._json_or_none(response)
        if not isinstance(data, dict):
            return [TextContent(type="text", text="UI hierarchy failed: Invalid JSON response")]
        if data.get("success"):
            import json
            hierarchy = json.dumps(data.get("data", {}), indent=2)
            return [TextContent(type="text", text=f"UI Hierarchy:\n{hierarchy}")]
        else:
            return [TextContent(type="text", text=f"UI hierarchy failed: {data.get('error', 'Unknown error')}")]
    
    async def _handle_list_apps(self, arguments: dict) -> List[TextContent]:
        """Handle device_list_apps tool"""
        system_apps = arguments.get("system_apps", False)
        response = self.client.get("/apps", params={"systemApps": "true" if system_apps else "false"})
        data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            response = self._daemon_get("/apps", params={"systemApps": "true" if system_apps else "false"})
            data = self._json_or_none(response)
        if not isinstance(data, dict):
            return [TextContent(type="text", text="List apps failed: Invalid JSON response")]
        if data.get("success"):
            import json
            apps = json.dumps(data.get("data", []), indent=2)
            return [TextContent(type="text", text=f"Installed apps:\n{apps}")]
        else:
            return [TextContent(type="text", text=f"List apps failed: {data.get('error', 'Unknown error')}")]
    
    async def _handle_screen_size(self) -> List[TextContent]:
        """Handle device_get_screen_size tool"""
        response = self.client.get("/screen")
        data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            response = self._daemon_get("/screen")
            data = self._json_or_none(response)
        if not isinstance(data, dict):
            return [TextContent(type="text", text="Get screen size failed: Invalid JSON response")]
        if data.get("success"):
            import json
            size_info = json.dumps(data.get("data", {}), indent=2)
            return [TextContent(type="text", text=f"Screen size:\n{size_info}")]
        else:
            return [TextContent(type="text", text=f"Get screen size failed: {data.get('error', 'Unknown error')}")]

    def _daemon_get(self, path: str, **kwargs):
        headers = kwargs.pop("headers", None)
        if headers is None:
            headers = self.client.build_auth_headers()
        url = f"http://{self.client.host}:{self.daemon_port}{path}"
        return httpx.get(url, headers=headers, timeout=30.0, **kwargs)

    @staticmethod
    def _json_or_none(response):
        try:
            return response.json()
        except Exception:
            return None

    def _get_a11y_interactive(self, compact: bool = True, limit: int = 60) -> List[Dict[str, Any]]:
        """Fetch a11y interactive elements with compact JSON to avoid truncation."""
        params = {}
        if compact:
            params["compact"] = "1"
        if limit and limit > 0:
            params["limit"] = str(limit)
        response = self.client.get("/a11y/interactive", params=params)
        return response.json()

    def _ensure_settings_root(self, max_steps: int = 6) -> bool:
        """Try to return to Settings root by activating back buttons or tapping top-left."""
        target_labels = {"Wi-Fi", "Bluetooth", "General"}
        back_labels = {"Settings", "General", "About", "Wi-Fi", "Bluetooth"}

        for _ in range(max_steps):
            try:
                items = self._get_a11y_interactive(compact=True, limit=40)
            except Exception:
                items = []

            labels = {(it.get("label") or "") for it in items}
            if target_labels.issubset(labels):
                return True

            back_index = None
            for it in items:
                label = it.get("label") or ""
                class_name = it.get("className") or ""
                if label in back_labels and class_name.endswith("Button"):
                    back_index = it.get("index")
                    break

            if back_index is not None:
                self.client.get("/a11y/activate", params={"index": back_index})
            else:
                # Fallback: tap top-left back area
                self.client.get("/tap", params={"x": 30, "y": 90})

        return False

    async def _handle_a11y_interactive(self, arguments: dict) -> List[TextContent]:
        compact = arguments.get("compact", True)
        limit = arguments.get("limit", 60)
        params = {}
        if compact:
            params["compact"] = "1"
        if limit:
            params["limit"] = str(limit)
        response = self.client.get("/a11y/interactive", params=params)
        return [TextContent(type="text", text=response.text)]

    async def _handle_a11y_activate(self, arguments: dict) -> List[TextContent]:
        index = int(arguments.get("index"))
        response = self.client.get("/a11y/activate", params={"index": index})
        return [TextContent(type="text", text=f"Activated index {index}: {response.text}")]

    async def _handle_a11y_overlay(self, arguments: dict) -> List[TextContent]:
        enabled = arguments.get("enabled")
        interactive_only = arguments.get("interactiveOnly", True)
        params = {
            "enabled": "true" if enabled else "false",
            "interactiveOnly": "true" if interactive_only else "false",
        }
        response = self.client.get("/a11y/overlay", params=params)
        return [TextContent(type="text", text=response.text)]

    async def _handle_settings_safe_activate(self, arguments: dict) -> List[TextContent]:
        index = int(arguments.get("index"))
        max_steps = int(arguments.get("max_steps", 6))
        ok = self._ensure_settings_root(max_steps=max_steps)
        response = self.client.get("/a11y/activate", params={"index": index})
        return [TextContent(type="text", text=f"Root OK={ok}. Activated index {index}: {response.text}")]

    async def _handle_touch_senderid(self) -> List[TextContent]:
        response = self.client.get("/touch/senderid")
        return [TextContent(type="text", text=response.text)]

    async def _handle_touch_senderid_set(self, arguments: dict) -> List[TextContent]:
        sender_id = arguments.get("id")
        persist = arguments.get("persist", False)
        if sender_id is None:
            return [TextContent(type="text", text="Missing id parameter")]

        payload = {"id": str(sender_id), "persist": bool(persist)}
        headers = self.client.build_auth_headers()
        try:
            response = self.client.post("/touch/senderid/set", json=payload, headers=headers)
            return [TextContent(type="text", text=response.text)]
        except Exception:
            params = {"id": str(sender_id), "persist": "1" if persist else "0"}
            response = self.client.get("/touch/senderid/set", params=params)
            return [TextContent(type="text", text=response.text)]

    async def _handle_touch_bkhid_selectors(self) -> List[TextContent]:
        response = self.client.get("/touch/bkhid_selectors")
        return [TextContent(type="text", text=response.text)]

    async def _handle_touch_forcefocus(self) -> List[TextContent]:
        response = self.client.get("/touch/forcefocus")
        return [TextContent(type="text", text=response.text)]


# Singleton instance
_device_registry = None

def get_device_registry(client: KimiRunDeviceClient = None) -> DeviceToolRegistry:
    """Get singleton device tool registry instance"""
    global _device_registry
    if _device_registry is None:
        _device_registry = DeviceToolRegistry(client)
    return _device_registry
