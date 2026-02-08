#!/usr/bin/env python3
"""
AuiTO MCP Server

A Model Context Protocol server that wraps the AuiTO HTTP API,
exposing device control functionality as MCP tools.

This is the main entry point. All implementation is modularized in the `tools` package.
"""

import asyncio
import sys

# Import from modularized tools package
from tools import (
    run_server,
    print_startup_info,
    AI_TOOLS_AVAILABLE
)


def main():
    """Main entry point"""
    # Print startup info to stderr (stdout is used for MCP protocol)
    print_startup_info()
    
    if AI_TOOLS_AVAILABLE:
        print("AI-powered research tools: ENABLED", file=sys.stderr)
    else:
        print("AI-powered research tools: DISABLED (missing dependencies)", file=sys.stderr)
    
    # Run the server
    asyncio.run(run_server())


if __name__ == "__main__":
    main()
