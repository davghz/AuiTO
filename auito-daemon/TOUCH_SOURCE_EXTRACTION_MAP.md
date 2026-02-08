# Touch Source Extraction Map (iOS 13)

Date: 2026-02-08

This document maps reusable touch-injection patterns from:

- `IOS13-SimulateTouch-0.0.7-10`
- `XXTouchNG/XXTouchNG` (cloned to `/tmp/XXTouchNG`)
- `facebook/idb` (cloned to `/tmp/idb`)

into `AuiTO/auito-daemon`.

## Applied Mappings

### 1) SimulateTouch lineage -> AuiTO event builder

Source references:

- `IOS13-SimulateTouch-0.0.7-10/pccontrol/Touch.xm`
- `IOS13-SimulateTouch-0.0.7-10/zxtouch-binary/main.mm`

Mapped into:

- `AuiTO/auito-daemon/modules/touch/internal/TouchInjectionEventBuilder.m`
- `AuiTO/auito-daemon/modules/touch/internal/TouchInjectionGestureComposer.m`

What is reused:

- Parent+child digitizer composition for touch phases
- SimulateTouch parent flags (`0xb0007`, `0xb0008`, `0xb0009`)
- ZXTouch socket wire format and endpoint flow (`127.0.0.1:6000`)
- Sender-ID-first dispatch expectations

### 2) XXTouchNG HID generator -> AuiTO optional event mask profile

Source references:

- `/tmp/XXTouchNG/touch/hid/STHIDEventGenerator.m`
- `/tmp/XXTouchNG/touch/hid/STHIDEventGenerator.h`

Mapped into:

- `AuiTO/auito-daemon/modules/touch/internal/TouchInjectionEventBuilder.m`

What is reused:

- Explicit per-phase parent/child mask strategy (touch/range/position/attribute/identity)
- Built-in/display-integrated parent flags in simulate path

Runtime toggle:

- `KIMIRUN_SIM_EVENT_MASK_PROFILE=legacy_raw|xxtouch`
- Preference key: `SimEventMaskProfile`
- Default remains `legacy_raw` (current behavior preserved)

### 3) XXTouchNG interpolation -> AuiTO gesture path

Source references:

- `/tmp/XXTouchNG/touch/hid/STHIDEventGenerator.m` (`simpleCurveInterpolation`)

Mapped into:

- `AuiTO/auito-daemon/modules/touch/internal/TouchInjectionGestureComposer.m`

What is reused:

- Optional simple-curve point interpolation for swipe/drag trajectories

Runtime toggle:

- `KIMIRUN_GESTURE_INTERPOLATION=linear|simple_curve`
- Preference key: `GestureInterpolation`
- Default: `linear`

### 4) facebook/idb HID swipe model -> AuiTO gesture step density

Source references:

- `/tmp/idb/FBSimulatorControl/HID/FBSimulatorHIDEvent.m`
- `/tmp/idb/proto/idb.proto` (`HIDSwipe.delta`, `HIDSwipe.duration`)

Mapped into:

- `AuiTO/auito-daemon/modules/touch/internal/TouchInjectionGestureComposer.m`

What is reused:

- Distance/delta-based step count for swipe/drag planning
- Duration-aware per-step pacing model

Runtime toggle:

- `KIMIRUN_GESTURE_DELTA_PX=<positive float>`
- Preference key: `GestureDeltaPx`
- Default: unset (falls back to legacy fixed step counts)

## Quick Validation

Build:

```bash
cd /home/davgz/Documents/Cursor/kimirun/AuiTO/auito-daemon
HOME=$PWD/.home TMPDIR=$PWD/.tmp make -j4 package
```

Result:

- `packages/com.auito.daemon_0.0.1-5+debug_iphoneos-arm.deb`

Suggested runtime A/B:

```bash
# XXTouch-style mask profile
launchctl setenv KIMIRUN_SIM_EVENT_MASK_PROFILE xxtouch

# idb-style delta control + XXTouch-style curve
launchctl setenv KIMIRUN_GESTURE_DELTA_PX 10
launchctl setenv KIMIRUN_GESTURE_INTERPOLATION simple_curve
```

