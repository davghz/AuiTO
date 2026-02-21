"""Device MCP tool registry."""

import os
from typing import List, Optional

import httpx
from mcp.types import TextContent, Tool

from .client import KimiRunDeviceClient, _http_ping_ok
from .definitions import get_device_tool_definitions
from .mixins import (
    DeviceA11yHandlersMixin,
    DeviceCommonMixin,
    DeviceCoreHandlersMixin,
    DeviceTouchHandlersMixin,
)


class DeviceToolRegistry(
    DeviceCoreHandlersMixin,
    DeviceA11yHandlersMixin,
    DeviceTouchHandlersMixin,
    DeviceCommonMixin,
):
    """Registry for device control MCP tools."""

    def __init__(self, client: KimiRunDeviceClient = None):
        self.client = client or KimiRunDeviceClient()
        self.daemon_port = int(
            os.environ.get("AUITO_DAEMON_PORT", os.environ.get("KIMIRUN_DAEMON_PORT", "8876"))
        )
        self._last_screenshot_hash: Optional[str] = None
        self._last_screenshot_bytes: int = 0
        self._stale_screenshot_count: int = 0

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
        """Get all device control tool definitions."""
        return get_device_tool_definitions()

    async def handle_tool_call(self, name: str, arguments: dict) -> List[TextContent]:
        """Handle device tool calls by mapping to KimiRun HTTP API endpoints."""
        return await self._handle_tool_call_internal(name, arguments, retry_on_connect_error=True)

    async def _handle_tool_call_internal(
        self,
        name: str,
        arguments: dict,
        retry_on_connect_error: bool,
    ) -> List[TextContent]:
        try:
            return await self._dispatch_tool(name, arguments)
        except httpx.ConnectError:
            if retry_on_connect_error and self._recover_connection():
                return await self._handle_tool_call_internal(
                    name,
                    arguments,
                    retry_on_connect_error=False,
                )
            return [
                TextContent(
                    type="text",
                    text=f"Connection error: Cannot reach KimiRun device at {self.client.get_base_url()}. Is the device online?",
                )
            ]
        except httpx.TimeoutException:
            return [TextContent(type="text", text=f"Timeout error: Request to {self.client.get_base_url()} timed out.")]
        except Exception as e:
            return [TextContent(type="text", text=f"Error: {type(e).__name__}: {str(e)}")]

    async def _dispatch_tool(self, name: str, arguments: dict) -> List[TextContent]:
        if name == "device_ping":
            return await self._handle_ping()
        if name == "device_state":
            return await self._handle_state()
        if name == "device_tap":
            return await self._handle_tap(arguments)
        if name == "device_screenshot":
            return await self._handle_screenshot()
        if name == "device_type_text":
            return await self._handle_type_text(arguments)
        if name == "device_swipe":
            return await self._handle_swipe(arguments)
        if name == "device_open_app_switcher":
            return await self._handle_open_app_switcher()
        if name == "device_press_home":
            return await self._handle_press_home()
        if name == "device_launch_app":
            return await self._handle_launch_app(arguments)
        if name == "device_get_ui_hierarchy":
            return await self._handle_ui_hierarchy()
        if name == "device_list_apps":
            return await self._handle_list_apps(arguments)
        if name == "device_get_screen_size":
            return await self._handle_screen_size()
        if name == "device_a11y_interactive":
            return await self._handle_a11y_interactive(arguments)
        if name == "device_a11y_activate":
            return await self._handle_a11y_activate(arguments)
        if name == "device_a11y_overlay":
            return await self._handle_a11y_overlay(arguments)
        if name == "device_touch_senderid":
            return await self._handle_touch_senderid()
        if name == "device_touch_senderid_set":
            return await self._handle_touch_senderid_set(arguments)
        if name == "device_touch_bkhid_selectors":
            return await self._handle_touch_bkhid_selectors()
        if name == "device_touch_forcefocus":
            return await self._handle_touch_forcefocus()
        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    def _recover_connection(self) -> bool:
        """Best-effort reconnect: re-resolve ports and restart local daemon when possible."""
        previous_base = self.client.get_base_url()
        if self.client.use_ssh_tunnel:
            try:
                self.client._ensure_ssh_tunnel()
            except Exception:
                return False
        else:
            self.client._resolve_working_port()
            new_base = f"http://{self.client.host}:{self.client.port}"
            if new_base != previous_base:
                try:
                    self.client.client.close()
                except Exception:
                    pass
                self.client.base_url = new_base
                self.client.client = httpx.Client(base_url=self.client.base_url, timeout=30.0)
            if "AUITO_DAEMON_PORT" not in os.environ:
                self.daemon_port = int(self.client.port)

        return _http_ping_ok(self.client.host, self.client.port, timeout=1.2)

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


_device_registry = None


def get_device_registry(client: KimiRunDeviceClient = None) -> DeviceToolRegistry:
    """Get singleton device tool registry instance."""
    global _device_registry
    if _device_registry is None:
        _device_registry = DeviceToolRegistry(client)
    return _device_registry
