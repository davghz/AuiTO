"""
KimiRun MCP Server Tools

A modular system for device control.

## Module Structure

```
tools/
├── __init__.py           # This file - exports all public APIs
├── device_tools.py       # Device control tools (tap, swipe, screenshot, etc.)
├── unified_tools.py      # Combines all tool registries
├── server.py             # MCP server implementation
└── test_tools.py         # Test suite
```

## Quick Start

```python
from tools import get_unified_registry, run_server

# Get all tool definitions
registry = get_unified_registry()
tools = registry.get_all_tool_definitions()

# Handle tool calls
result = await registry.handle_tool_call("device_tap", {"x": 100, "y": 200})
```

## Available Tools

### Device Control
- `device_ping` - Check device online status
- `device_tap` - Tap at coordinates
- `device_screenshot` - Capture screenshot
- `device_type_text` - Type text
- `device_swipe` - Swipe gesture
- `device_press_home` - Press home button
- `device_launch_app` - Launch app by bundle ID
- `device_get_ui_hierarchy` - Get UI hierarchy
- `device_list_apps` - List installed apps
- `device_get_screen_size` - Get screen dimensions
"""

__version__ = "1.0.0"

# Optional AI research tools flag (kept for compatibility with mcp_server.py)
AI_TOOLS_AVAILABLE = False

# Device control
from .device_tools import (
    KimiRunDeviceClient,
    DeviceToolRegistry,
    get_device_registry,
    KIMIRUN_HOST,
    KIMIRUN_PORT,
    BASE_URL
)

# Unified registry
from .unified_tools import (
    UnifiedToolRegistry,
    get_unified_registry
)

# Server
from .server import (
    create_mcp_server,
    run_server,
    print_startup_info
)

__all__ = [
    # Version
    "__version__",
    
    # Device control
    "KimiRunDeviceClient",
    "DeviceToolRegistry",
    "get_device_registry",
    "KIMIRUN_HOST",
    "KIMIRUN_PORT",
    "BASE_URL",
    "AI_TOOLS_AVAILABLE",
    
    # Unified registry
    "UnifiedToolRegistry",
    "get_unified_registry",
    
    # Server
    "create_mcp_server",
    "run_server",
    "print_startup_info",
]
