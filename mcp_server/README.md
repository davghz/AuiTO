# AuiTO MCP Server

MCP bridge for the AuiTO daemon HTTP API.

## Requirements

- Python 3.10+
- AuiTO daemon running on iOS (`http://<device-ip>:8765`)

## Install

```bash
cd /home/davgz/Documents/Cursor/kimirun/mcp_server
python3 -m pip install -r requirements.txt
```

## Environment

`AUITO_HOST` and `AUITO_PORT` are preferred.

Backwards compatibility aliases are also supported:

- `KIMIRUN_HOST`
- `KIMIRUN_PORT`

Default target is `10.0.0.9:8765`.

## MCP Config Example

```json
{
  "mcpServers": {
    "auito": {
      "command": "python3",
      "args": ["/home/davgz/Documents/Cursor/kimirun/mcp_server/mcp_server.py"],
      "env": {
        "AUITO_HOST": "10.0.0.9",
        "AUITO_PORT": "8765"
      }
    }
  }
}
```

## Run Manually

```bash
cd /home/davgz/Documents/Cursor/kimirun/mcp_server
python3 mcp_server.py
```

## Notes

- Server name is `auito`.
- Tool surface remains compatible with the existing device tool names (`device_tap`, `device_swipe`, `device_screenshot`, etc.).
