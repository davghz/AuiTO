# iOS 13.2.3 SDK Touch/Gesture Injection Analysis

## Executive Summary

The iOS 13.2.3 SDK provides multiple frameworks for touch/gesture injection. The most reliable methods are:

1. **AccessibilityUtilities** (Recommended) - High-level AXEventRepresentation API
2. **IOKit** (IOHIDEvent) - Low-level HID event injection
3. **BackBoardServices** - Event delivery management

GSEvent/GraphicsServices is deprecated but still functional.

### Header Gap Pass (2026-02-08)

Using `BackBoardServices.tbd` vs extracted headers in
`sdk/iPhoneOS13.2.3.sdk/System/Library/PrivateFrameworks/BackBoardServices.framework/Headers`,
there are additional exported touch/HID SPI symbols not declared in SDK headers (for example:
`BKSHIDEventSetDigitizerInfo*`, `BKSHIDEventSendToFocusedProcess`,
`BKSHIDEventSendToProcess*`).

Additional exported symbols observed in `BackBoardServices.tbd` and now declaration-covered in
`BackBoardServices+Extended.h` for experiment wiring:
- `BKSHIDEventSendToApplicationWithBundleID`
- `BKSHIDEventSendToApplicationWithBundleIDAndPid`
- `BKSHIDEventSendToApplicationWithBundleIDAndPidAndFollowingFocusChain`
- `BKSHIDEventSendToResolvedProcessForDeferringEnvironment`
- runtime HID manager classes used by routing probes: `BKAccessibility`, `BKHIDClientConnectionManager`
- additional touch SPI used by iOS13-era projects and now declaration-covered:
  - `BKSHIDEventSetDigitizerInfoWithTouchStreamIdentifier`
  - `BKSHIDEventSetDigitizerInfoWithSubEventInfos`
  - `BKSHIDEventSetDigitizerInfoWithSubEventInfoAndTouchStreamIdentifier`
  - `BKSHIDEventSetBaseAttributes` / `BKSHIDEventSetDigitizerAttributes`
  - `BKSHIDEventSetSimpleInfo` / `BKSHIDEventSetSimpleDeliveryInfo`
  - event-introspection helpers used for context telemetry:
    - `BKSHIDEventGetContextIDFromEvent`
    - `BKSHIDEventGetContextIDFromDigitizerEvent`
    - `BKSHIDEventGetTouchStreamIdentifier`
    - `BKSHIDEventGetClientIdentifier`
    - `BKSHIDEventGetClientPid`
    - `BKSHIDEventCopyDisplayIDFromEvent`
    - `BKSHIDEventCopyDisplayIDFromDigitizerEvent`
    - `BKSHIDEventContainsUpdates`
  - additional touch stream/control helpers now declaration-covered:
    - `BKSHIDEventDigitizerDetachTouches`
    - `BKSHIDEventDigitizerDetachTouchesWithIdentifiers`
    - `BKSHIDEventDigitizerDetachTouchesWithIdentifiersAndPolicy`
    - `BKSHIDEventDigitizerSetTouchRoutingPolicy`
  - `BKSHIDEventRegisterEventCallback` / `BKSHIDEventRegisterEventCallbackOnRunLoop`
  - `BKSHIDSetEventDeferringRules` / `BKSHIDSetEventDeferringRulesForClient`
  - mutable deferring model classes:
    - `BKSMutableHIDEventDeferringPredicate`
    - `BKSMutableHIDEventDeferringTarget`
    - `BKSMutableHIDEventDeferringResolution`
    - `BKSEventFocusDeferralProperties`
  - private UI context hooks used by iOS13/14 SimulateTouch variants:
    - `UIApplication -_enqueueHIDEvent:`
    - `UIWindow -_contextId` / `UIWindow -_contextID`
  - private export alias occasionally present on iOS 13 builds:
    - `__BKSHIDSetEventDeferringRulesForClient` (mapped as `_BKSHIDSetEventDeferringRulesForClientFunc`)
  - service helper useful for cleanup/edge experiments:
    - `BKSHIDServicesCancelTouchesOnMainDisplay`
    - `BKHIDServicesCancelPhysicalButtonEvents`
    - `BKHIDServicesGetCurrentDeviceOrientation`
    - `BKHIDServicesGetNonFlatDeviceOrientation`
  - additional event-introspection helpers (declaration-only, for optional diagnostics):
    - `BKSHIDEventDigitizerGetTouchIdentifier`
    - `BKSHIDEventDigitizerGetTouchUserIdentifier`
    - `BKSHIDEventDigitizerGetTouchLocus`
    - `BKSHIDEventGetPointFromDigitizerEvent`
    - `BKSHIDEventGetMaximumForceFromDigitizerEvent`
    - `BKSHIDEventDescription` / `BKSHIDEventGetConciseDescription`
    - `BKSHIDEventSourceStringName`
  - redirect helper surface now declaration-covered:
    - `BKSHIDEventRedirectAttributes`
    - `__BKSHIDEventSetRedirectInfo`

Practical impact for AuiTO non-AX experiments:
- Typed class APIs are present for routing managers/rules.
- Several useful C-level event-consumption helpers exist at runtime but require `dlsym` + local typedefs.
- `UIApplication` private `_enqueueHIDEvent:` remains undeclared by SDK headers and must be category-declared locally.
- Residual undeclared `_BKSHIDEvent*` exports after this pass are mostly non-core for current
  non-AX gesture work (key-command/keyboard/biometric/smart-cover/event-description variants).
  They can be added later if those domains are explicitly targeted.

---

## Available Frameworks

### 1. IOKit.framework (System Framework)
**Location:** `/System/Library/Frameworks/IOKit.framework/`

**Key Components:**
- `IOHIDEvent` - Core HID event creation and manipulation
- `IOHIDEventSystemClient` - Event dispatching to system

**Availability:** ✅ Available and functional in iOS 13.2.3

### 2. BackBoardServices.framework (Private Framework)
**Location:** `/System/Library/PrivateFrameworks/BackBoardServices.framework/`

**Key Components:**
- `BKSHIDEventDeliveryManager` - Event routing and delivery
- `BKSHIDEventDescriptor` - Event type matching
- `BKSTouchDeliveryPolicy` - Touch delivery policies

**Availability:** ✅ Available and functional in iOS 13.2.3

### 3. AccessibilityUtilities.framework (Private Framework)
**Location:** `/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/`

**Key Components:**
- `AXEventRepresentation` - High-level event abstraction
- `AXEventHandInfoRepresentation` - Multi-touch hand info
- `AXBackBoardServer` - Server for posting events

**Availability:** ✅ Available and functional in iOS 13.2.3

### 4. GraphicsServices.framework (Private Framework)
**Location:** `/System/Library/PrivateFrameworks/GraphicsServices.framework/`

**Key Components:**
- `GSEvent` - Legacy event system (deprecated)

**Availability:** ⚠️ Available but deprecated in iOS 13

### 5. SpringBoardServices.framework (Private Framework)
**Location:** `/System/Library/PrivateFrameworks/SpringBoardServices.framework/`

**Key Components:**
- App lifecycle management
- Limited touch-related APIs

**Availability:** ⚠️ Available but NOT recommended for touch injection

### 6. HID.framework (Private Framework)
**Location:** `/System/Library/PrivateFrameworks/HID.framework/`

**Key Components:**
- `HIDEventSystemClient` - Alternative event client
- `HIDEvent` - Event wrapper

**Availability:** ✅ Available in iOS 13.2.3

### 7. AccessibilityPhysicalInteraction.framework (Private Framework)
**Location:** `/System/Library/PrivateFrameworks/AccessibilityPhysicalInteraction.framework/`

**Key Components:**
- `AXPIEventSender` - Event sender implementation
- `AXPIFingerEventSender` - Finger-specific events

**Availability:** ✅ Available in iOS 13.2.3

---

## Key Functions for Touch Injection

### IOKit (Low-level HID Events)

```c
// Core event creation
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    uint32_t index,
    uint32_t identity,
    IOHIDDigitizerEventMask eventMask,
    float x,
    float y,
    float z,
    float pressure,
    float twist,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options
);

// Multi-touch (digitizer) event
IOHIDEventRef IOHIDEventCreateDigitizerEvent(...);

// Event system client
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
```

### AccessibilityUtilities (Recommended High-level)

```objc
// Create touch event
+ (AXEventRepresentation *)touchRepresentationWithHandType:(unsigned int)handType
                                                   location:(CGPoint)location;

// Create gesture event
+ (AXEventRepresentation *)gestureRepresentationWithHandType:(unsigned int)handType
                                                   locations:(NSArray *)locations;

// Post event via AXBackBoardServer
- (void)postEvent:(AXEventRepresentation *)event systemEvent:(BOOL)systemEvent;
```

### BackBoardServices (Event Routing)

```objc
// Get shared delivery manager
+ (BKSHIDEventDeliveryManager *)sharedInstance;

// Dispatch events
- (id)dispatchDiscreteEventsForReason:(NSString *)reason withRules:(NSArray *)rules;
```

---

## iOS 13.2.3 Specific Notes

### Changes from iOS 12

1. **GSEvent Deprecated**: GraphicsServices/GSEvent is deprecated. Use IOHIDEvent or AXEventRepresentation instead.

2. **New APIs in iOS 13**:
   - `IOHIDEventCreateDigitizerFingerEventWithQuality` - Enhanced finger events with quality metrics
   - `IOHIDEventCreateFluidTouchGestureEvent` - Fluid touch gestures

3. **BackBoardServices Enhanced**: More robust event delivery with BKSHIDEventDeliveryManager

4. **AccessibilityUtilities**: Improved AXEventRepresentation with better multi-touch support

### Entitlements Required

```xml
<key>com.apple.private.hid.client.event-dispatch</key>
<true/>
<key>com.apple.private.hid.client.event-filter</key>
<true/>
<key>com.apple.accessibility.AccessibilityUIServer</key>
<true/>
<key>com.apple.backboardd.eventPoster</key>
<true/>
```

### Sender IDs for Event Injection

| Sender ID | Purpose |
|-----------|---------|
| `0x0000000000000001` | System |
| `0x00000000000000A1` | Accessibility |
| `0x00000000000000A2` | AssistiveTouch |
| `0x00000000000000A3` | SwitchControl |
| `0x00000000000000A4` | VoiceControl |

---

## Recommended Approach for iOS 13.2.3

### Option 1: AccessibilityUtilities (Easiest)

```objc
#import "AccessibilityUtilities.h"

// Create and post a touch event
AXEventRepresentation *event = [AXEventRepresentation 
    touchRepresentationWithHandType:0 
                           location:CGPointMake(100, 200)];

[[AXBackBoardServer server] postEvent:event systemEvent:YES];
```

### Option 2: IOKit (Most Control)

```c
#import "IOHIDEvent.h"

// Create event system client
IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);

// Create finger touch event
IOHIDEventRef event = IOHIDEventCreateDigitizerFingerEvent(
    kCFAllocatorDefault,
    TIGetCurrentTimestamp(),
    0,  // index
    1,  // identity
    kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition,
    100.0, 200.0, 0.0,  // x, y, z
    1.0, 0.0,  // pressure, twist
    true, true,  // range, touch
    kIOHIDEventOptionNone
);

// Dispatch event
IOHIDEventSystemClientDispatchEvent(client, event);

// Cleanup
CFRelease(event);
```

### Option 3: Hybrid (Best for Complex Gestures)

Use AccessibilityUtilities for gesture construction, then convert to HID for dispatch.

---

## Header Files Created

| File | Description |
|------|-------------|
| `IOHIDEvent.h` | Core IOKit HID event declarations |
| `BackBoardServices.h` | BackBoardServices framework interface |
| `AccessibilityUtilities.h` | High-level accessibility event interface |
| `GraphicsServices.h` | Legacy GSEvent (deprecated) |
| `SpringBoardServices.h` | SpringBoard interaction |
| `TouchInjection.h` | Convenience wrapper functions |

---

## Multi-Touch Support

iOS 13.2.3 supports up to 5 simultaneous touches. Use:

1. `IOHIDEventAppendEvent()` to combine finger events into a multi-touch event
2. `AXEventHandInfoRepresentation` with multiple paths

Example:
```objc
AXEventHandInfoRepresentation *handInfo = [[AXEventHandInfoRepresentation alloc] init];
handInfo.currentFingerCount = 2;

// Create path info for each finger
NSArray *paths = @[
    [AXEventPathInfoRepresentation representationWithPoint:CGPointMake(100, 100)],
    [AXEventPathInfoRepresentation representationWithPoint:CGPointMake(200, 200)]
];
handInfo.paths = paths;
```

---

## Deprecated APIs (iOS 13.2.3)

| API | Replacement |
|-----|-------------|
| `GSEvent` | `IOHIDEvent` or `AXEventRepresentation` |
| `IOHIDPostEvent` | `IOHIDEventSystemClientDispatchEvent` |
| `PurpleEvent` | `IOHIDEvent` |

---

## Build Configuration

### Linker Flags
```
-framework IOKit
-lBackBoardServices
-lAccessibilityUtilities
-lAccessibilityPhysicalInteraction
```

### Header Search Paths
```
$(THEOS)/sdks/iPhoneOS13.2.3.sdk/System/Library/PrivateFrameworks/BackBoardServices.framework/Headers
$(THEOS)/sdks/iPhoneOS13.2.3.sdk/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/Headers
$(THEOS)/sdks/iPhoneOS13.2.3.sdk/System/Library/Frameworks/IOKit.framework/Headers
```

---

## Summary

For touch/gesture injection on iOS 13.2.3:

1. **Use `AccessibilityUtilities` framework** for the simplest and most reliable approach
2. **Use `IOKit` framework** when you need low-level control
3. **Avoid `GraphicsServices/GSEvent`** - it's deprecated
4. **Link against `BackBoardServices`** for event delivery management

All frameworks listed are available in the iOS 13.2.3 SDK at the expected locations.
