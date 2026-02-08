"""
Unified MCP Tool Registry

Combines device control tools.
"""

from typing import List
from mcp.types import Tool

from .device_tools import DeviceToolRegistry, get_device_registry


class UnifiedToolRegistry:
    """
    Unified registry for MCP tools:
    - Device control tools (tap, swipe, screenshot, etc.)
    """
    
    def __init__(self):
        self.device_registry = get_device_registry()
    
    def get_all_tool_definitions(self) -> List[Tool]:
        """Get tool definitions from device registry"""
        return self.device_registry.get_tool_definitions()
    
    async def handle_tool_call(self, name: str, arguments: dict):
        """Route tool calls to appropriate handler"""
        
        # Device control tools
        if name.startswith("device_"):
            return await self.device_registry.handle_tool_call(name, arguments)
        
        else:
            from mcp.types import TextContent
            return [TextContent(type="text", text=f"Unknown tool: {name}")]


# Singleton instance
_unified_registry = None

def get_unified_registry() -> UnifiedToolRegistry:
    """Get singleton unified registry instance"""
    global _unified_registry
    if _unified_registry is None:
        _unified_registry = UnifiedToolRegistry()
    return _unified_registry
