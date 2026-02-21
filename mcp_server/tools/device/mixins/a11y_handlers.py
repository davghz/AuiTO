"""Accessibility handlers."""
from typing import List

from mcp.types import TextContent


class DeviceA11yHandlersMixin:
    async def _handle_a11y_interactive(self, arguments: dict) -> List[TextContent]:
        compact = arguments.get("compact", True)
        limit = arguments.get("limit", 60)
        params = {}
        if compact:
            params["compact"] = "1"
        if limit:
            params["limit"] = str(limit)
        try:
            response = self._daemon_get("/a11y/interactive", params=params)
        except Exception:
            response = self.client.get("/a11y/interactive", params=params)
        return [TextContent(type="text", text=response.text)]

    async def _handle_a11y_activate(self, arguments: dict) -> List[TextContent]:
        index = int(arguments.get("index"))
        try:
            response = self._daemon_get("/a11y/activate", params={"index": index})
        except Exception:
            response = self.client.get("/a11y/activate", params={"index": index})
        return [TextContent(type="text", text=f"Activated index {index}: {response.text}")]

    async def _handle_a11y_overlay(self, arguments: dict) -> List[TextContent]:
        enabled = arguments.get("enabled")
        interactive_only = arguments.get("interactiveOnly", True)
        params = {
            "enabled": "true" if enabled else "false",
            "interactiveOnly": "true" if interactive_only else "false",
        }
        try:
            response = self._daemon_get("/a11y/overlay", params=params)
        except Exception:
            response = self.client.get("/a11y/overlay", params=params)
        return [TextContent(type="text", text=response.text)]
