"""
AuiTO MCP Server

Main MCP server implementation using stdio transport.
"""

import sys
from mcp.server import Server
from mcp.server.stdio import stdio_server

from .unified_tools import get_unified_registry
from .device_tools import KIMIRUN_HOST, KIMIRUN_PORT, BASE_URL


def create_mcp_server() -> Server:
    """Create and configure the MCP server"""
    app = Server("auito")
    registry = get_unified_registry()
    
    @app.list_tools()
    async def list_tools():
        """List all available tools"""
        return registry.get_all_tool_definitions()
    
    @app.call_tool()
    async def call_tool(name: str, arguments: dict):
        """Handle tool calls"""
        return await registry.handle_tool_call(name, arguments)
    
    return app


async def run_server():
    """Run the MCP server using stdio transport"""
    app = create_mcp_server()
    
    async with stdio_server() as (read_stream, write_stream):
        await app.run(
            read_stream,
            write_stream,
            app.create_initialization_options()
        )


def print_startup_info():
    """Print startup information to stderr"""
    print("Starting AuiTO MCP Server...", file=sys.stderr)
    print(f"Connecting to AuiTO device at {BASE_URL}", file=sys.stderr)
    print(
        "Environment: "
        f"AUITO_HOST/KIMIRUN_HOST={KIMIRUN_HOST}, "
        f"AUITO_PORT/KIMIRUN_PORT={KIMIRUN_PORT}",
        file=sys.stderr,
    )
