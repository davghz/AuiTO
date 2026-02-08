# iOS 13.2.3 Screenshot Headers

This directory contains stub headers for implementing screenshot functionality on iOS 13.2.3.

## Files

| File | Description |
|------|-------------|
| `IOSurface.h` | Public framework header for IOSurface (GPU buffer management) |
| `CARenderServer.h` | Private API header for CARenderServer (display capture) |
| `ScreenshotServices.h` | Private framework header for ScreenshotServices |
| `ScreenshotHelper.h` | Helper interface for easy screenshot capture |
| `ScreenshotHelper.m` | Implementation of screenshot methods |

## Recommended Method: IOSurface + CARenderServer

For SpringBoard tweaks or system-level screenshot capture, use the **IOSurface + CARenderServer** method.

### Quick Start

```objc
#import "ScreenshotHelper.h"

// Take screenshot
ScreenshotHelper *helper = [ScreenshotHelper sharedHelper];
ScreenshotResult *result = [helper captureScreenUsingIOSurface];

// Get image
UIImage *screenshot = result.image;

// Save to file
[result saveToFile:@"/var/mobile/screenshot.png" error:nil];
```

### Manual Implementation

```objc
#import "IOSurface.h"
#import "CARenderServer.h"

// 1. Create IOSurface
CFMutableDictionaryRef props = CFDictionaryCreateMutable(...);
// ... set properties (width, height, pixel format) ...
IOSurfaceRef surface = IOSurfaceCreate(props);

// 2. Capture display
mach_port_t port = CARenderServerGetServerPort();
CARenderServerRenderDisplay(port, 0, surface, 0);

// 3. Lock and read
IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
void *pixels = IOSurfaceGetBaseAddress(surface);
// ... create image from pixels ...
IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);

// 4. Cleanup
CFRelease(surface);
```

## Required Frameworks (Makefile)

```makefile
YOUR_TWEAK_NAME_FRAMEWORKS = IOSurface QuartzCore CoreGraphics UIKit
YOUR_TWEAK_NAME_PRIVATE_FRAMEWORKS = 
```

## Required Entitlements

```xml
<key>com.apple.springboard.debug</key>
<true/>
<key>com.apple.private.coreanimation.display-mirroring</key>
<true/>
```

## Method Comparison

| Method | Speed | Quality | SpringBoard | App Store |
|--------|-------|---------|-------------|-----------|
| IOSurface + CARenderServer | ⭐⭐⭐ Fast | ⭐⭐⭐ High | ✅ Yes | ❌ No |
| ScreenshotServices | ⭐⭐ Medium | ⭐⭐⭐ High | ✅ Yes | ❌ No |
| UIKit Public API | ⭐⭐ Medium | ⭐⭐ Medium | ❌ No | ✅ Yes |
| CALayer | ⭐⭐ Medium | ⭐⭐ Medium | ❌ No | ✅ Yes |

## SDK Sources

Headers based on iOS 13.2.3 SDK at:
- `/home/davgz/theos/sdks/iPhoneOS13.2.3.sdk/System/Library/Frameworks/IOSurface.framework/Headers/`
- `/home/davgz/theos/sdks/iPhoneOS13.2.3.sdk/System/Library/Frameworks/QuartzCore.framework/QuartzCore.tbd`
- `/home/davgz/theos/sdks/iPhoneOS13.2.3.sdk/System/Library/PrivateFrameworks/ScreenshotServices.framework/Headers/`

## See Also

- `../../SCREENSHOT_METHODS_RESEARCH.md` - Full research documentation
