/*
 * CARenderServer.h
 * Stub header for iOS 13.2.3 SDK screenshot implementation
 * Private API from QuartzCore.framework
 */

#ifndef CARENDERSERVER_H
#define CARENDERSERVER_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * CARenderServer is a private API in QuartzCore.framework
 * Used for capturing display contents to IOSurface
 */

/* Display and context IDs */
typedef uint32_t CARenderServerDisplayID;
typedef uint32_t CARenderServerContextID;

/* Port for communicating with render server */
typedef mach_port_t CARenderServerPort;

/* Snapshot creation options (keys for CFDictionary) */
extern CFStringRef kCASnapshotContextId;
extern CFStringRef kCASnapshotContextList;
extern CFStringRef kCASnapshotDestination;
extern CFStringRef kCASnapshotDisplayName;
extern CFStringRef kCASnapshotEnforceSecureMode;
extern CFStringRef kCASnapshotFormatOpaque;
extern CFStringRef kCASnapshotFormatWideGamut;
extern CFStringRef kCASnapshotIgnoreLayerFixup;
extern CFStringRef kCASnapshotIgnoreRootAccessibilityFilters;
extern CFStringRef kCASnapshotIgnoreSublayers;
extern CFStringRef kCASnapshotLayerId;
extern CFStringRef kCASnapshotMode;
extern CFStringRef kCASnapshotModeDisplay;
extern CFStringRef kCASnapshotModeExcludeContextList;
extern CFStringRef kCASnapshotModeIncludeContextList;
extern CFStringRef kCASnapshotModeLayer;
extern CFStringRef kCASnapshotModeStopAfterContextList;
extern CFStringRef kCASnapshotOriginX;
extern CFStringRef kCASnapshotOriginY;
extern CFStringRef kCASnapshotReuseBackdropContents;
extern CFStringRef kCASnapshotSizeHeight;
extern CFStringRef kCASnapshotSizeWidth;
extern CFStringRef kCASnapshotTimeOffset;
extern CFStringRef kCASnapshotTransform;

/*
 * Server lifecycle
 */

/* Start/Stop server */
Boolean CARenderServerStart(void);
void CARenderServerShutdown(void);
Boolean CARenderServerIsRunning(void);

/* Get server port for communication */
mach_port_t CARenderServerGetServerPort(void);
mach_port_t CARenderServerGetPort(void);

/* Register with render server */
CARenderServerPort CARenderServerRegister(mach_port_t port);

/*
 * Display capture functions
 */

/* Get display information */
CGRect CARenderServerGetDisplayLogicalBounds(CARenderServerDisplayID display);

/* Capture display to IOSurface */
CGImageRef CARenderServerCaptureDisplay(CARenderServerDisplayID display);
CGImageRef CARenderServerCaptureDisplayWithTransform(CARenderServerDisplayID display, 
                                                      CGAffineTransform transform);

/* Render display to IOSurface */
int CARenderServerRenderDisplay(CARenderServerPort serverPort,
                                 CARenderServerDisplayID display,
                                 IOSurfaceRef surface,
                                 int unknown);

/* Capture with more options */
CGImageRef CARenderServerCaptureDisplayClientList(CARenderServerDisplayID display,
                                                   CFArrayRef clientList);
CGImageRef CARenderServerCaptureDisplayClientListWithTransform(CARenderServerDisplayID display,
                                                                CFArrayRef clientList,
                                                                CGAffineTransform transform);

/*
 * Layer capture functions
 */

/* Capture specific layer */
CGImageRef CARenderServerCaptureLayer(CARenderServerContextID context,
                                       uint32_t layerID);
CGImageRef CARenderServerCaptureLayerWithTransform(CARenderServerContextID context,
                                                    uint32_t layerID,
                                                    CGAffineTransform transform);
CGImageRef CARenderServerCaptureLayerWithTransformAndTimeOffset(CARenderServerContextID context,
                                                                 uint32_t layerID,
                                                                 CGAffineTransform transform,
                                                                 CFTimeInterval timeOffset);

/* Render layer to IOSurface */
int CARenderServerRenderLayer(CARenderServerPort serverPort,
                               CARenderServerContextID context,
                               uint32_t layerID,
                               IOSurfaceRef surface);
int CARenderServerRenderLayerWithTransform(CARenderServerPort serverPort,
                                            CARenderServerContextID context,
                                            uint32_t layerID,
                                            CGAffineTransform transform,
                                            IOSurfaceRef surface);

/*
 * Batch snapshot creation
 */

/* Create multiple snapshots at once */
CFArrayRef CARenderServerCreateSnapshots(CFDictionaryRef options);

/*
 * Debug and info functions
 */

/* Get debug info */
CFDictionaryRef CARenderServerCopyODStatistics(void);
CFDictionaryRef CARenderServerGetStatistics(void);
CFDictionaryRef CARenderServerGetPerformanceInfo(void);
CFDictionaryRef CARenderServerGetInfo(void);

/* Debug options */
uint32_t CARenderServerGetDebugFlags(void);
void CARenderServerSetDebugFlags(uint32_t flags);
void CARenderServerClearDebugOptions(void);
float CARenderServerGetDebugValueFloat(uint32_t option);
void CARenderServerSetDebugValueFloat(uint32_t option, float value);
uint32_t CARenderServerGetDebugValue(uint32_t option);
void CARenderServerSetDebugValue(uint32_t option, uint32_t value);

/* Frame counter */
uint32_t CARenderServerGetFrameCounter(void);
uint32_t CARenderServerGetFrameCounterByIndex(uint32_t index);

/* Client info */
mach_port_t CARenderServerGetClientPort(CARenderServerContextID context);
pid_t CARenderServerGetClientProcessId(CARenderServerContextID context);

/*
 * Simplified screenshot helper (recommended)
 * 
 * Usage for iOS 13.2.3:
 * 
 * 1. Create IOSurface with proper dimensions
 * 2. Call CARenderServerRenderDisplay to capture
 * 3. Lock IOSurface and read pixel data
 * 4. Create CGImage from pixel data
 * 5. Unlock and release IOSurface
 */

/* Helper to get main display ID */
#define kCARenderServerMainDisplayID 0

/* Convenience function for screenshot (not in SDK, implement yourself) */
/*
static inline CGImageRef CARenderServerTakeScreenshot(void) {
    // Implementation would:
    // 1. Get server port
    // 2. Create IOSurface with screen bounds
    // 3. Call CARenderServerRenderDisplay
    // 4. Convert IOSurface to CGImage
    // 5. Return CGImage
}
*/

#ifdef __cplusplus
}
#endif

#endif /* CARENDERSERVER_H */
