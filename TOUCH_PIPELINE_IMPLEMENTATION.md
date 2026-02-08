# AuiTO Touch Pipeline Implementation

## Overview

This document describes the complete iOS 13.2.3 touch pipeline implementation in AuiTO, from MCP client commands through to hardware-level event injection.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                 MCP CLIENT (Claude/Code)                             │
│                              JSON-RPC over stdio                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              MCP SERVER (Python)                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │  mcp_server.py                                                              │   │
│  │  └── run_server()                                                           │   │
│  │       └── DeviceToolRegistry                                                │   │
│  │            ├── device_tap() ──┐                                            │   │
│  │            ├── device_swipe() │                                            │   │
│  │            ├── device_type_text()                                          │   │
│  │            └── ... 20+ tools                                               │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼ HTTP/JSON
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           AUITO DAEMON (iOS Daemon)                                  │
│  Port: 8876                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │  DaemonHTTPServer.m                                                         │   │
│  │  ├── /ping, /state                                                          │   │
│  │  ├── /tap, /swipe, /drag, /longpress                                       │   │
│  │  ├── /touch/tap, /touch/swipe (iOSRunPortal-style)                         │   │
│  │  ├── /touch/senderid, /touch/forcefocus                                    │   │
│  │  ├── /gestures/tap, /gestures/swipe (strict mode)                          │   │
│  │  └── /a11y/interactive, /a11y/activate                                     │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           TOUCH INJECTION MODULE                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │  TouchInjection.m                                                           │   │
│  │  ├── +initialize()                     → TouchInjectionBootstrap            │   │
│  │  ├── +tapAtX:Y:method:                 → StrategyRouter                     │   │
│  │  ├── +swipeFromX:Y:toX:Y:duration:     → GestureComposer                    │   │
│  │  └── +deliverViaBKS:                   → BKSDispatch                        │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
                    ▼                     ▼                     ▼
┌───────────────────────┐ ┌───────────────────────┐ ┌───────────────────────┐
│  AX METHOD            │ │  IOHID METHOD         │ │  BKS METHOD           │
│  AXTouchInjection.m   │ │  TouchInjectionEvent  │ │  TouchInjectionBKS    │
│                       │ │  Builder.m            │ │  Dispatch.m           │
│  +performAXTapAtX:Y:  │ │                       │ │                       │
│  Uses accessibility   │ │  CreateTouchEvent()   │ │  +deliverViaBKS:      │
│  AX UI elements       │ │  CreateBKSTouchEvent()│ │  BKS routing rules    │
│                       │ │  IOHIDEventCreate     │ │  dispatchDiscrete...  │
│  Reliable ✅          │ │  DigitizerEvent()     │ │  Focus override       │
│  Works in any ctx     │ │  IOHIDEventSetSenderID│ │                       │
│                       │ │                       │ │  Experimental ⚠️      │
│                       │ │  Normalized coords    │ │  Daemon ctx issues    │
│                       │ │  Parent+Child events  │ │                       │
│                       │ │  Sender ID capture    │ │                       │
└───────────────────────┘ └───────────────────────┘ └───────────────────────┘
                    │                     │                     │
                    └─────────────────────┼─────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           IOS HID EVENT SYSTEM                                       │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │  IOKit.framework                                                            │   │
│  │  ├── IOHIDEventSystemClientCreateSimpleClient()  ← iOS 13+ requirement      │   │
│  │  ├── IOHIDEventSystemClientSetDispatchQueue()    ← Required               │   │
│  │  ├── IOHIDEventSystemClientActivate()            ← Required               │   │
│  │  ├── IOHIDEventSystemClientDispatchEvent()       ← Event injection        │   │
│  │  └── IOHIDEventSetSenderID()                     ← iOS 13+ routing        │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           BACKBOARDD / SPRINGBOARD                                   │
│                                                                                      │
│  ┌──────────────────────────────┐      ┌──────────────────────────────┐             │
│  │  backboardd (system)         │      │  SpringBoard (com.apple.     │             │
│  │  BKSHIDEventDeliveryManager  │◄────►│  springboard)                │             │
│  │  Event routing & dispatch    │      │  UI event consumption        │             │
│  └──────────────────────────────┘      └──────────────────────────────┘             │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. MCP Server Layer (`mcp_server/`)

**Files:**
- `mcp_server.py` - Main entry point
- `tools/device_tools.py` - 20+ MCP tool definitions
- `tools/server.py` - MCP protocol handler

**Key Tools:**
| Tool | Description | HTTP Endpoint |
|------|-------------|---------------|
| `device_tap` | Tap at coordinates | POST /touch/tap |
| `device_swipe` | Swipe gesture | POST /touch/swipe |
| `device_type_text` | Keyboard input | GET /keyboard/type |
| `device_screenshot` | Screen capture | GET /screenshot |
| `device_a11y_interactive` | Get UI elements | GET /a11y/interactive |
| `device_a11y_activate` | Tap element by index | GET /a11y/activate |
| `device_touch_senderid` | Get sender ID diagnostics | GET /touch/senderid |

### 2. Daemon HTTP Server (`modules/http_server/`)

**Files:**
- `DaemonHTTPServer.m` - Main server (port 8876)
- `DaemonHTTPServer+TouchAdmin.m` - Touch admin endpoints
- `DaemonHTTPServer+StrictProxy.m` - Strict proxy verification
- `DaemonHTTPServer+Network.m` - Network utilities
- `DaemonHTTPServer+Helpers.m` - Helper functions

**Endpoints:**
```
GET  /ping                    → Health check
GET  /state                   → Device state
POST /touch/tap               → Tap with method selection
POST /touch/swipe             → Swipe with method selection
GET  /touch/senderid          → Sender ID diagnostics
POST /touch/senderid/set      → Override sender ID
GET  /touch/forcefocus        → Focus Settings search
GET  /a11y/interactive        → Interactive elements
GET  /a11y/activate           → Activate by index
GET  /screenshot              → Capture screen
GET  /app/launch              → Launch app
```

### 3. Touch Injection Module (`modules/touch/`)

#### Core Files

**TouchInjection.m** - Public API
```objc
@interface KimiRunTouchInjection : NSObject
+ (BOOL)initialize;
+ (BOOL)tapAtX:(CGFloat)x Y:(CGFloat)y method:(NSString *)method;
+ (BOOL)swipeFromX:(CGFloat)x1 Y:(CGFloat)y1 toX:(CGFloat)x2 Y:(CGFloat)y2 
          duration:(NSTimeInterval)duration method:(NSString *)method;
+ (BOOL)sendKeyUsage:(uint16_t)usage down:(BOOL)down;
+ (uint64_t)senderID;
+ (BOOL)deliverViaBKS:(IOHIDEventRef)event;
@end
```

#### Internal Implementation Files

| File | Purpose |
|------|---------|
| `TouchInjectionBootstrap.m` | Initialize HID clients, load IOKit functions |
| `TouchInjectionEventBuilder.m` | Create IOHIDEvent objects (parent/child) |
| `TouchInjectionSenderIDManager.m` | Capture sender ID from real events |
| `TouchInjectionStrategyRouter.m` | Route to AX, IOHID, or BKS method |
| `TouchInjectionGestureComposer.m` | Compose multi-step gestures (swipe, drag) |
| `TouchInjectionBKSDispatch.m` | BackBoardServices dispatch implementation |
| `TouchInjectionBKSFocus.m` | Focus target management |
| `TouchInjectionBKSRouting.m` | BKS routing utilities |
| `TouchInjectionBKSExperiments.m` | Experimental BKS features |

### 4. SpringBoard Tweak (`Tweak.xm`)

**Purpose:** Proxy for SpringBoard-context injection

```objc
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // Initialize touch injection
    [KimiRunTouchInjection initialize];
    
    // Start HTTP server on port 8765
    g_httpServer = [[KimiRunHTTPServer alloc] init];
    [g_httpServer startOnPort:8765 error:&error];
    
    // Start Socket server on port 6000 (ZXTouch compatible)
    [[SocketTouchServer sharedServer] startOnPort:6000 error:&error];
}
%end
```

**Ports:**
- 8765 - SpringBoard HTTP proxy
- 8766 - Preferences app HTTP (if injected)
- 8767 - MobileSafari HTTP (if injected)
- 6000 - ZXTouch-compatible socket

### 5. IOHID Event Construction

From `TouchInjectionEventBuilder.m`:

```objc
// 1. Create parent HAND event
IOHIDEventRef handEvent = IOHIDEventCreateDigitizerEvent(
    kCFAllocatorDefault,
    mach_absolute_time(),
    kTransducerTypeHand,     // 3
    0, 0,                    // index, identity
    eventMask,               // kIOHIDDigitizerEventRange|Touch|Position
    0,                       // buttonMask
    normX, normY, 0,         // x, y, z (normalized 0.0-1.0)
    pressure,
    barrelPressure,
    inRange,
    touch,
    options
);

// 2. Create child FINGER event
IOHIDEventRef fingerEvent = IOHIDEventCreateDigitizerFingerEvent(
    kCFAllocatorDefault,
    mach_absolute_time(),
    1, 3,                    // index, identity
    eventMask,
    normX, normY, 0,         // normalized coordinates
    pressure, twist,
    inRange, touch,
    options
);

// 3. Append child to parent
IOHIDEventAppendEvent(handEvent, fingerEvent, true);

// 4. Set sender ID (CRITICAL for iOS 13+)
IOHIDEventSetSenderID(handEvent, senderID);

// 5. Dispatch
IOHIDEventSystemClientDispatchEvent(client, handEvent);
```

## Touch Injection Methods

### Method Priority

1. **AX (Accessibility)** - Default, most reliable
   - Uses `AXTouchInjection.m`
   - Requires accessibility elements
   - Works in any process context

2. **SimulateTouch (IOHID)** - Direct HID injection
   - Uses `TouchInjectionEventBuilder.m`
   - Requires proper sender ID
   - Best for system-wide gestures

3. **BKS (BackBoardServices)** - System routing
   - Uses `TouchInjectionBKSDispatch.m`
   - Routes through backboardd
   - Experimental for daemon context

### Method Selection

```objc
// From TouchInjectionStrategyRouter.m
NSString *KimiRunResolveTouchMethod(NSString *method) {
    // Default policy: AX first for safety
    if (!method || [method isEqualToString:@"auto"]) {
        return @"ax";  // AX-first policy
    }
    
    // Strict non-AX requires opt-in
    if ([@[@"sim", @"conn", @"legacy", @"bks"] containsObject:lowerMethod]) {
        if (!KimiRunTouchEnvBool("KIMIRUN_ENABLE_STRICT_NON_AX", NO)) {
            return @"ax";  // Fall back to AX
        }
    }
    
    return lowerMethod;
}
```

## Build System

### Makefile Targets

```bash
# Build daemon + tweak
make clean package

# Install to device
make install

# Respring after install
make respring
```

### Build Products

| Product | Path | Purpose |
|---------|------|---------|
| `auito-daemon` | `/usr/bin/auito-daemon` | Launch daemon |
| `auito.dylib` | `/Library/MobileSubstrate/DynamicLibraries/` | SpringBoard tweak |
| `auito.plist` | Same directory | Filter bundle IDs |

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `AUITO_HOST` | Device IP | 10.0.0.9 |
| `AUITO_PORT` | Daemon port | 8876 |
| `KIMIRUN_ENABLE_STRICT_NON_AX` | Enable strict methods | 0 |
| `KIMIRUN_BKS_EVENT_MODE` | BKS payload mode | sim_parent |
| `KIMIRUN_BKS_DISPATCH_REASON` | BKS dispatch reason | kimirun-touch |

### Preferences (Settings App)

Domain: `com.auito.daemon`

| Key | Type | Description |
|-----|------|-------------|
| `TouchMethod` | string | Default method (ax/sim/bks) |
| `EnableStrictNonAX` | bool | Allow strict non-AX methods |
| `EnableZXTouch` | bool | Enable ZXTouch socket server |
| `SenderIDFallback` | bool | Allow sender ID fallback |

## Safety Features

1. **AX-First Policy:** Default to accessibility methods
2. **Strict Mode Toggle:** Non-AX methods require explicit enable
3. **Sender ID Validation:** Require captured sender ID for HID methods
4. **UI Delta Verification:** Compare screenshots before/after touch
5. **Proxy Context Detection:** Auto-detect SpringBoard vs daemon context

## iOS 13.2.3 Specifics

### Required for IOHIDEvent:
- `IOHIDEventSystemClientCreateSimpleClient()` (not legacy `Create`)
- `IOHIDEventSystemClientSetDispatchQueue()`
- `IOHIDEventSystemClientActivate()`
- `IOHIDEventSetSenderID()` with captured value

### Sender ID Capture:
```objc
// From TouchInjectionSenderIDManager.m
void KimiRunRegisterSenderIDCallbackOnMainRunLoop(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    IOHIDEventSystemClientScheduleWithRunLoop(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    
    IOHIDEventSystemClientRegisterEventCallback(client, 
        ^(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
            if (IOHIDEventGetType(event) == kIOHIDEventTypeDigitizer) {
                uint64_t sender = IOHIDEventGetSenderID(event);
                if (sender != 0 && g_senderID == 0) {
                    g_senderID = sender;
                    g_senderCaptured = YES;
                    KimiRunPersistSenderID(sender);
                }
            }
        }, NULL, NULL);
}
```

## Testing

```bash
# Build
make clean package

# Install
make install

# Test endpoints
curl http://10.0.0.9:8876/ping
curl "http://10.0.0.9:8876/tap?x=200&y=400&method=ax"
curl "http://10.0.0.9:8876/swipe?x1=200&y1=500&x2=200&y2=200&duration=0.3"

# MCP test
python -m mcp_server.tools.server
```

## Summary

AuiTO implements a complete MCP-controllable touch pipeline:

1. **MCP Layer:** Python MCP server with 20+ tools
2. **HTTP Layer:** Daemon + SpringBoard HTTP servers
3. **Injection Layer:** AX, IOHID, BKS methods with strategy routing
4. **IOKit Layer:** Proper iOS 13+ HID event construction
5. **System Layer:** Integration with backboardd/SpringBoard

The implementation follows the iOS 13.2.3 touch pipeline architecture with proper safety guards and AX-first policy.
