"""Touch diagnostics and senderid handlers."""

from typing import List

from mcp.types import TextContent


class DeviceTouchHandlersMixin:
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
