import traceback
from dataclasses import asdict, is_dataclass
from typing import Any, Awaitable, Callable, Dict, Optional


def _serialize(value: Any) -> Any:
    if is_dataclass(value):
        return asdict(value)
    if isinstance(value, list):
        return [_serialize(v) for v in value]
    if isinstance(value, tuple):
        return [_serialize(v) for v in value]
    if isinstance(value, dict):
        return {k: _serialize(v) for k, v in value.items()}
    return value


class Server:
    def __init__(self, name: str):
        self._name = name
        self._list_tools_handler: Optional[Callable[[], Awaitable[Any]]] = None
        self._call_tool_handler: Optional[Callable[[str, Dict[str, Any]], Awaitable[Any]]] = None

    def list_tools(self):
        def decorator(func):
            self._list_tools_handler = func
            return func

        return decorator

    def call_tool(self):
        def decorator(func):
            self._call_tool_handler = func
            return func

        return decorator

    def create_initialization_options(self) -> Dict[str, Any]:
        return {}

    async def run(self, read_stream, write_stream, _init_options: Dict[str, Any]) -> None:
        while True:
            message = await read_stream.read_message()
            if message is None:
                break
            if not isinstance(message, dict):
                continue

            method = message.get("method")
            message_id = message.get("id")
            params = message.get("params") or {}

            if method and message_id is not None:
                response = await self._handle_request(method, message_id, params)
                await write_stream.write_message(response)

    async def _handle_request(self, method: str, message_id: Any, params: Dict[str, Any]) -> Dict[str, Any]:
        try:
            if method == "initialize":
                requested_version = params.get("protocolVersion") or "2025-06-18"
                return {
                    "jsonrpc": "2.0",
                    "id": message_id,
                    "result": {
                        "protocolVersion": requested_version,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": self._name, "version": "0.1.0"},
                    },
                }

            if method == "ping":
                return {"jsonrpc": "2.0", "id": message_id, "result": {}}

            if method == "tools/list":
                tools = []
                if self._list_tools_handler is not None:
                    tools = await self._list_tools_handler()
                return {"jsonrpc": "2.0", "id": message_id, "result": {"tools": _serialize(tools)}}

            if method == "tools/call":
                if self._call_tool_handler is None:
                    result = [{"type": "text", "text": "Tool handler unavailable"}]
                    return {
                        "jsonrpc": "2.0",
                        "id": message_id,
                        "result": {"content": result, "isError": True},
                    }
                tool_name = params.get("name", "")
                arguments = params.get("arguments") or {}
                content = await self._call_tool_handler(tool_name, arguments)
                return {
                    "jsonrpc": "2.0",
                    "id": message_id,
                    "result": {"content": _serialize(content)},
                }

            if method == "resources/list":
                return {"jsonrpc": "2.0", "id": message_id, "result": {"resources": []}}

            if method == "resources/templates/list":
                return {"jsonrpc": "2.0", "id": message_id, "result": {"resourceTemplates": []}}

            if method == "prompts/list":
                return {"jsonrpc": "2.0", "id": message_id, "result": {"prompts": []}}

            return {
                "jsonrpc": "2.0",
                "id": message_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
        except Exception as exc:
            trace = traceback.format_exc(limit=3)
            return {
                "jsonrpc": "2.0",
                "id": message_id,
                "error": {
                    "code": -32603,
                    "message": f"{type(exc).__name__}: {exc}",
                    "data": trace,
                },
            }

