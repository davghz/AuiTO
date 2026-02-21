"""Device MCP tool definitions."""

from typing import List
from mcp.types import Tool


def get_device_tool_definitions() -> List[Tool]:
    """Return all device control tool definitions."""
    return [
        Tool(
            name="device_ping",
            description="Check if KimiRun device is online",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_state",
            description="Get device and server state (/state)",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_tap",
            description="Tap at screen coordinates",
            inputSchema={
                "type": "object",
                "properties": {
                    "x": {"type": "number", "description": "X coordinate"},
                    "y": {"type": "number", "description": "Y coordinate"},
                    "method": {
                        "type": "string",
                        "description": "Touch method override (e.g., auto, direct, ax, zxtouch, bks, sim, legacy)",
                    },
                    "pixel": {"type": "boolean", "description": "Treat coordinates as pixels", "default": False},
                },
                "required": ["x", "y"],
            },
        ),
        Tool(
            name="device_screenshot",
            description="Capture device screenshot and return base64-encoded image",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_type_text",
            description="Type text on device",
            inputSchema={
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "Text to type"},
                },
                "required": ["text"],
            },
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
                    "method": {
                        "type": "string",
                        "description": "Touch method override (e.g., auto, direct, ax, zxtouch, bks, sim, legacy)",
                    },
                    "pixel": {"type": "boolean", "description": "Treat coordinates as pixels", "default": False},
                    "scroll": {"type": "boolean", "description": "Prefer scroll semantics (if supported)", "default": False},
                },
                "required": ["startX", "startY", "endX", "endY"],
            },
        ),
        Tool(
            name="device_open_app_switcher",
            description="Open App Switcher",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_press_home",
            description="Press home button (go to Home screen)",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_launch_app",
            description="Launch an app by bundle ID",
            inputSchema={
                "type": "object",
                "properties": {
                    "bundle_id": {"type": "string", "description": "App bundle ID (e.g., com.apple.mobilesafari)"},
                },
                "required": ["bundle_id"],
            },
        ),
        Tool(
            name="device_get_ui_hierarchy",
            description="Get current UI element hierarchy as JSON",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_list_apps",
            description="List installed apps on device",
            inputSchema={
                "type": "object",
                "properties": {
                    "system_apps": {"type": "boolean", "description": "Include system apps", "default": False},
                },
            },
        ),
        Tool(
            name="device_get_screen_size",
            description="Get device screen dimensions",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_a11y_interactive",
            description="Get accessibility interactive elements as JSON",
            inputSchema={
                "type": "object",
                "properties": {
                    "compact": {"type": "boolean", "description": "Return compact JSON (recommended)", "default": True},
                    "limit": {"type": "integer", "description": "Limit number of elements", "default": 60},
                },
            },
        ),
        Tool(
            name="device_a11y_activate",
            description="Activate an accessibility element by index from the most recent a11y/interactive result",
            inputSchema={
                "type": "object",
                "properties": {
                    "index": {"type": "integer", "description": "Element index"},
                },
                "required": ["index"],
            },
        ),
        Tool(
            name="device_a11y_overlay",
            description="Show/hide accessibility overlay boxes on device",
            inputSchema={
                "type": "object",
                "properties": {
                    "enabled": {"type": "boolean", "description": "Enable overlay"},
                    "interactiveOnly": {"type": "boolean", "description": "Only show interactive elements", "default": True},
                },
                "required": ["enabled"],
            },
        ),
        Tool(
            name="device_touch_senderid",
            description="Get touch senderID diagnostics",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_touch_senderid_set",
            description="Override touch senderID (id can be hex string like 0x123 or integer)",
            inputSchema={
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "SenderID value (hex string or decimal)"},
                    "persist": {"type": "boolean", "description": "Persist for this boot", "default": False},
                },
                "required": ["id"],
            },
        ),
        Tool(
            name="device_touch_bkhid_selectors",
            description="Log BKHID selectors and return log path",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="device_touch_forcefocus",
            description="Force focus Settings search field",
            inputSchema={"type": "object", "properties": {}},
        ),
    ]
