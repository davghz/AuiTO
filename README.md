# AuiTO (AI Automation for iOS)

AuiTO is the release of the worlds first daemon + MCP bridge, only works for iOS 13.2.3.

This folder is self-contained for release:

- `auito-daemon/` : THEOS daemon package + PreferenceLoader settings bundle
- `mcp_server/` : MCP server that calls AuiTO HTTP endpoints

## What Works Today

- AX touch path is the stable default (`tap` and `swipe`).
- Strict non-AX (`bks`, `sim`, `legacy`, `conn`, `zxtouch`) is available behind opt-in toggles for R&D.

## Settings Bundle

Open Settings -> AuiTO Daemon.

Key toggles:

- `Enable Strict Non-AX Methods`
- `Enable ZXTouch Backend (Unsafe)`
- `Proxy All Strict Methods`
- `Block Side Button Sleep`
- `Allow Sleep (Override)`

Default behavior is AX-first and safe.

## Build and Install (Daemon)

```bash
cd /home/davgz/Documents/Cursor/kimirun/AuiTO/auito-daemon
export THEOS=/home/davgz/theos
export TARGET=iphone:clang:13.2.3:13.0
export ARCHS=arm64
export THEOS_DEVICE_IP=YOUR_IP_ADDRESS

make package install
```

Package identity:

- Package: `com.auito.daemon`
- Binary: `/usr/bin/auito-daemon`
- LaunchDaemon: `/Library/LaunchDaemons/com.auito.daemon.plist`
- Preferences domain: `com.auito.daemon`

## MCP Server Setup

```bash
cd /AuiTO/mcp_server
python3 -m pip install -r requirements.txt
python3 mcp_server.py
```

Env vars:

- Preferred: `AUITO_HOST`, `AUITO_PORT`
- Backward-compatible aliases: `KIMIRUN_HOST`, `KIMIRUN_PORT`

See `mcp_server/README.md` for MCP client config JSON.

## Quick Validation

On device:

```bash
curl -s http://127.0.0.1:8765/ping
curl -s "http://127.0.0.1:8765/tap?x=80&y=700"
```

Expected:

- `/ping` returns `{"status":"ok","message":"pong"}`
- default `/tap` returns `mode:"a11y"`
