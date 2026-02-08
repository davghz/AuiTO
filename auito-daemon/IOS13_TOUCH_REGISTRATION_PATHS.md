# iOS 13.2.3 Touch Registration Paths (AuiTO Daemon)

Date: 2026-02-06

## Scope
- Identify the real touch registration/dispatch paths available on iOS 13.2.3.
- Verify runtime availability in the current daemon process.
- Map SimulateTouch architecture to KimiRun modules.

## 1) Modularization Pass Applied

Touch injection internals remain functionally equivalent, but code boundaries were tightened:

- `kimirun-daemon/modules/touch/internal/TouchInjectionEventBuilder.m`
  - owns: coordinate normalization, low-level dispatch, and single-event posting.
- `kimirun-daemon/modules/touch/internal/TouchInjectionSenderIDManager.m`
  - owns: senderID persistence, callback registration, and capture lifecycle.
- `kimirun-daemon/modules/touch/internal/TouchInjectionStrategyRouter.m`
  - owns: method resolution and strict-verification routing decisions.
- `kimirun-daemon/modules/touch/internal/TouchInjectionGestureComposer.m`
  - owns: tap/swipe/drag/long-press composition plus ZXTouch transport helpers.
- `kimirun-daemon/modules/touch/TouchInjection.m`
  - now holds initialization, symbol loading, BKS dispatch targeting, and shared globals.
  - behavior preserved; build/install succeeded after modularization.

Build/install verification:
- `make clean && make package install THEOS_DEVICE_IP=10.0.0.9` succeeded.
- Respring completed.
- Endpoint sanity after install:
  - `/ping` -> ok
  - explicit `method=ax` tap -> success with visible UI response
  - explicit `method=sim/legacy` swipe -> success
  - explicit `method=bks/zxtouch` swipe -> hard failure (strict, no false-success)

MCP validation snapshot (after daemon + MCP restart):
- `device_tap(method=\"ax\")` on Settings `General` row opens `General` screen.
- `device_swipe(method=\"ax\")` scrolls to `Reset`/`Shut Down` in `General`.
- strict explicit non-AX failures are surfaced (`bks` and `zxtouch` swipe return error).

## 2) Runtime Discovery (Device)

### SenderID diagnostics
From `GET /touch/senderid`:
- `senderID=0x100000558`
- `source=callback`
- `captured=true`
- `callbackCount=319`
- `digitizerCount=1`
- `threadRunning=false`
- `hidConnection=0x0`

Interpretation:
- Daemon now has sender ID captured by callback (not only persisted state).
- SenderID capture callback path is functional in daemon context.
- Connection-based dispatch path currently has no resolved HID connection pointer.

### BKS/HID runtime class probing
From `GET /touch/bkhid_selectors` log file:
- `BKHIDClientConnectionManager class not found at runtime`

From `GET /debug/classes` (image-scoped query):
- `GET /debug/classes?image=/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices&prefix=BK&limit=30`
  - returned BK* runtime classes in daemon context (example set includes `BKSHIDTouchRoutingPolicy`, `BKSHIDEventRouter`, `BKSHIDEventDeferringTarget`, `BKSHIDEventDispatchingTarget`).
- `GET /debug/classes?all=1...` now returns stable JSON via image-by-image enumeration.

From `GET /debug/class_methods`:
- `BKSHIDEventDeliveryManager` exists (image: BackBoardServices)
  - class methods: `sharedInstance`
  - instance methods include:
    - `deferEventsMatchingPredicate:toTarget:withReason:`
    - `dispatchDiscreteEventsForReason:withRules:`
    - `dispatchKeyCommandsForReason:withRule:`
- `BKSHIDEventRouterManager` exists (image: BackBoardServices)
  - class methods: `sharedInstance`
- `BKAccessibility` class not found in daemon process.
- `BKHIDClientConnectionManager` class not found in daemon process.

Important implication:
- Current fallback selectors in code (`deliverHIDEvent:`/`postHIDEvent:`/`dispatchHIDEvent:`) are not exposed by this runtime class surface.
- The old `clientForTaskPort:` path cannot work in this daemon process if manager class is absent.

## 3) SDK Symbol Discovery (iPhoneOS13.2.3)

### IOKit symbols present
File: `sdk/iPhoneOS13.2.3.sdk/System/Library/Frameworks/IOKit.framework/IOKit.tbd`

Confirmed symbols:
- `_IOHIDEventCreateDigitizerEvent`
- `_IOHIDEventCreateDigitizerFingerEvent`
- `_IOHIDEventSetSenderID`
- `_IOHIDEventGetSenderID`
- `_IOHIDEventSystemClientCreate`
- `_IOHIDEventSystemClientCreateSimpleClient`
- `_IOHIDEventSystemClientCreateWithType`
- `_IOHIDEventSystemClientSetDispatchQueue`
- `_IOHIDEventSystemClientActivate`
- `_IOHIDEventSystemClientScheduleWithRunLoop`
- `_IOHIDEventSystemClientRegisterEventCallback`
- `_IOHIDEventSystemClientDispatchEvent`
- `_IOHIDEventSystemClientSetMatching`
- `_IOHIDEventSystemClientUnregisterEventCallback`
- `_IOHIDEventSystemClientUnscheduleWithRunLoop`

### BackBoardServices classes present in SDK
File: `sdk/iPhoneOS13.2.3.sdk/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices.tbd`

Confirmed classes:
- `_OBJC_CLASS_$_BKSHIDEventDeliveryManager`
- `_OBJC_CLASS_$_BKSHIDEventRouterManager`

Not found in this SDK tbd scan:
- `BKHIDClientConnectionManager`
- `BKAccessibility`

## 4) SimulateTouch Architecture Mapping

Reference file:
- `SimulateTouch-master/pccontrol/Touch.xm`

Observed flow:
1. Build parent digitizer event (`IOHIDEventCreateDigitizerEvent`).
2. Append child finger events (`IOHIDEventCreateDigitizerFingerEvent`) with masks `3/4/2` for down/move/up.
3. Set sender ID (`IOHIDEventSetSenderID`) before dispatch.
4. Dispatch through `IOHIDEventSystemClientDispatchEvent`.
5. Capture sender ID by registering callback via `IOHIDEventSystemClientRegisterEventCallback` and reading `IOHIDEventGetSenderID`.

KimiRun mapping:
- Event builder: `modules/touch/internal/TouchInjectionEventBuilder.m`
- SenderID manager: `modules/touch/internal/TouchInjectionSenderIDManager.m`
- Strategy router: `modules/touch/internal/TouchInjectionStrategyRouter.m`
- Gesture composer: `modules/touch/internal/TouchInjectionGestureComposer.m`

## 5) Practical Path Ranking on Current Device

Most viable to least viable in daemon context:
1. AX path (`method=ax`) -> confirmed delivered.
2. IOHID dispatch with valid sender ID (`sim` route) -> endpoint success; delivery depends on foreground/focus state.
3. Connection dispatch (`IOHIDEventSystemConnectionDispatchEvent`) -> currently blocked by missing HID connection object.
4. BKS discrete dispatch (`BKSHIDEventDeliveryManager` + router targets) -> correctly wired but still not consistently delivering swipe in daemon context.

## 6) Next Fix Direction

To make non-AX injection viable in daemon context:
- Stop relying on `BKHIDClientConnectionManager`/`BKAccessibility` in daemon for connection acquisition.
- Rework BKS routing against actual `BKSHIDEventDeliveryManager` method surface observed at runtime.
- Keep strict explicit method behavior (already done) so failures are visible and measurable.

## 7) Follow-up Patches Applied

### BKS routing patch
- Removed speculative legacy selectors (`deliverHIDEvent:`/`postHIDEvent:`/`dispatchHIDEvent:`) from BKS delivery path.
- Reworked BKS path to use discovered BKSHID runtime surface:
  - `BKSHIDEventDescriptor descriptorForHIDEvent:`
  - `BKSHIDEventDiscreteDispatchingPredicate _initWithSourceDescriptors:descriptors:`
  - `BKSHIDEventDispatchingTarget keyboardFocusTarget/systemTarget`
  - `BKSHIDEventDiscreteDispatchingRule ruleForDispatchingDiscreteEventsMatchingPredicate:toTarget:`
  - `BKSHIDEventDeliveryManager dispatchDiscreteEventsForReason:withRules:`
  - `BKSHIDEventRouterManager/BKSHIDEventRouter` default router priming (when available)
- Delivery remains strict (`NO`) because this API path does not expose per-event acknowledgement and we avoid false-success.

### `/debug/classes?all=1` stability patch
- Replaced global runtime class-list walking with image-by-image enumeration:
  - iterate loaded images via `_dyld_image_count` + `_dyld_get_image_name`
  - collect class names via `objc_copyClassNamesForImage`
- This preserves image-scoped behavior and fixes empty-reply/reset seen in `all=1` mode.
- Verified on-device:
  - `GET /debug/classes?all=1&limit=20` -> HTTP 200 with class list
  - `GET /debug/classes?all=1&prefix=BK&images=1&limit=30` -> HTTP 200 with BK classes + image paths
  - `GET /debug/classes?image=...BackBoardServices...&prefix=BK&limit=20` remains HTTP 200

### Runtime class availability confirmation
- Present at runtime:
  - `BKSHIDEventDeliveryManager`
  - `BKSHIDEventRouterManager`
  - `BKSHIDEventRouter`
  - `BKSHIDEventDescriptor`
  - `BKSHIDEventDiscreteDispatchingPredicate`
  - `BKSHIDEventDiscreteDispatchingRule`
  - `BKSHIDEventDispatchingTarget`
- Not present at runtime in daemon process:
  - `BKHIDClientConnectionManager`
  - `BKAccessibility`

## 8) Exact iOS 13.2.3 BKSHID Registration Path (Confirmed)

From SDK headers + runtime method dumps:

1. Build descriptor:
   - `BKSHIDEventDescriptor descriptorForHIDEvent:`
2. Build predicate:
   - `BKSHIDEventDiscreteDispatchingPredicate _initWithSourceDescriptors:descriptors:`
3. Build rule:
   - `BKSHIDEventDiscreteDispatchingRule ruleForDispatchingDiscreteEventsMatchingPredicate:toTarget:`
4. Resolve target(s):
   - `BKSHIDEventRouterManager _targetForDestination:`
   - `BKSHIDEventDispatchingTarget keyboardFocusTarget`
   - `BKSHIDEventDispatchingTarget systemTarget`
5. Dispatch:
   - `BKSHIDEventDeliveryManager dispatchDiscreteEventsForReason:withRules:`
6. Flush:
   - `BKSHIDEventDeliveryManager _syncServiceFlushState`

Router setup surface confirmed on device:
- `BKSHIDEventRouter defaultEventRouters`
- `BKSHIDEventRouter defaultFocusedAppEventRouter`
- `BKSHIDEventRouter defaultSystemAppEventRouter`
- `BKSHIDEventRouter addHIDEventDescriptors:`
- `BKSHIDEventRouterManager eventRouters/setEventRouters:`

Focus control surface confirmed on device:
- `BKSEventFocusManager setForegroundApplicationOnMainDisplay:pid:`
- `BKSEventFocusManager setSystemAppControlsFocusOnMainDisplay:`
- `BKSEventFocusManager _focusDataLock_updateFocusTargetOverride`
  - Note: direct calls to `_focusDataLock_updateFocusTargetOverride` from daemon crash with lock ownership assertion on iOS 13.2.3; avoid calling it directly.

## 9) Focused BKS Experiment Result (Daemon Process)

Current explicit `bks` route diagnostics:
- BKS manager/router are now both non-nil in daemon (`/touch/senderid/local` exposes pointers).
- Predicate creation fixed (`-init` removed; designated private initializer used).
- Per-target route logs now emit reliably.
- Focus hints now apply before routing:
  - `setForegroundApplicationOnMainDisplay:nil pid:SpringBoardPID`
  - `setForegroundApplicationOnMainDisplay:nil pid:backboarddPID`
  - `setSystemAppControlsFocusOnMainDisplay:NO`
  - `flush`

Observed target resolution:
- `keyboardFocusTarget` resolves to daemon PID.
- `focusTargetForPID:SpringBoard` resolves to SpringBoard PID.
- `focusTargetForPID:backboardd` resolves to backboardd PID.
- `focusTargetForPID:Preferences` resolves to Preferences PID (when running).
- router destination `2` still resolves to daemon PID.

Interpretation:
- BKSHID dispatch path is now correctly wired and can resolve non-self focus targets from daemon.
- Meaningful-route acceptance can be observed from daemon logs and is now used as strict verification signal.

## 10) Proxy Strategy Update (Strict Methods)

To keep strict semantics while avoiding daemon-local crashes/self-target routing:
- Daemon HTTP handlers now run strict explicit methods (`sim/legacy/bks/zx*`) through proxy first.
- Local daemon execution is only attempted if proxy is unavailable.
- Proxy response HTTP code is derived from body (`status=ok/success=true` => HTTP 200, else 500).

Current behavior snapshot:
- strict tap:
  - `bks` -> HTTP 200 (`{"status":"ok","action":"tap"...}`)
- strict swipe:
  - `bks` -> HTTP 500 (`{"status":"error","message":"Failed to execute swipe"}`)
  - `zxtouch` -> HTTP 500 (`{"status":"error","message":"Failed to execute swipe"}`)
  - daemon remains stable (no restart observed in this path).

Implication:
- strict explicit routing now exposes non-delivery for `bks/zxtouch` swipe instead of reporting false-success.
- `bks` tap can still succeed depending on runtime focus/route state.

## 11) Runtime Discovery Endpoints (Validated)

- `GET /debug/classes?all=1&limit=2000` returns stable non-empty class list.
- `GET /debug/classes?image=/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices&contains=BKSHID`
  - returns BKSHID classes reliably from image-scoped dump.
- `GET /debug/class_methods?class=BKSEventFocusManager`
  - confirms runtime presence of:
    - `setForegroundApplicationOnMainDisplay:pid:`
    - `setSystemAppControlsFocusOnMainDisplay:`
    - `flush`

## 12) 2026-02-06 Validation Update (Post Strict-Routing Patch)

### Daemon strict-routing behavior
- `/debug/classes?all=1&limit=20` now returns HTTP 200 with non-empty classes (no empty reply/reset).
- Strict-proxy behavior changed:
  - `bks` and `zxtouch` are proxy-only by default.
  - other strict methods (`sim`, `legacy`, `conn`) are local by default.
  - enable all-strict proxying only via `TouchProxyAllStrict=true` or `KIMIRUN_TOUCH_PROXY_ALL_STRICT=1`.

### Explicit method matrix (daemon port 8765)
- Tap:
  - `auto`, `ax` => success
  - `sim`, `legacy` => strict fail (`Tap failed`)
  - `bks`, `zxtouch` => strict fail (`Strict method proxy response missing mode`)
- Swipe:
  - `auto`, `ax` => success
  - `sim`, `legacy` => strict fail
  - `bks`, `zxtouch` => strict fail

### SpringBoard proxy contract gap (port 8876)
- Direct proxy responses currently do not include a delivery `mode` field:
  - `GET /tap?x=...&y=...&method=auto` -> `{"status":"ok","action":"tap",...}`
  - `GET /tap?x=...&y=...&method=bks` -> same shape (no mode)
- Because strict daemon validation now checks explicit method/backend consistency, this missing `mode` prevents daemon from proving proxy-side `bks` delivery and is treated as strict-fail.

### MCP UI response check
- MCP-driven tap and swipe still move real UI in Settings (General page entry and scroll delta observed in screenshots).
- This confirms end-to-end touch path works for non-strict/default routing while strict explicit non-AX remains correctly non-green when not provably delivered.
