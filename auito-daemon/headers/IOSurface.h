/*
 * IOSurface.h
 * Stub header for iOS 13.2.3 SDK screenshot implementation
 * Based on IOSurface.framework/Headers/IOSurfaceRef.h
 */

#ifndef IOSURFACE_H
#define IOSURFACE_H

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* IOSurfaceID is a unique identifier for an IOSurface */
typedef uint32_t IOSurfaceID;

/* Lock options */
typedef CF_OPTIONS(uint32_t, IOSurfaceLockOptions) {
    kIOSurfaceLockReadOnly  = 0x00000001,
    kIOSurfaceLockAvoidSync = 0x00000002,
};

/* Purgeability states */
typedef CF_OPTIONS(uint32_t, IOSurfacePurgeabilityState) {
    kIOSurfacePurgeableNonVolatile = 0,
    kIOSurfacePurgeableVolatile    = 1,
    kIOSurfacePurgeableEmpty       = 2,
    kIOSurfacePurgeableKeepCurrent = 3,
};

/* Property keys for IOSurface creation */
extern const CFStringRef kIOSurfaceAllocSize;
extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceElementWidth;
extern const CFStringRef kIOSurfaceElementHeight;
extern const CFStringRef kIOSurfaceOffset;
extern const CFStringRef kIOSurfacePlaneInfo;
extern const CFStringRef kIOSurfacePlaneWidth;
extern const CFStringRef kIOSurfacePlaneHeight;
extern const CFStringRef kIOSurfacePlaneBytesPerRow;
extern const CFStringRef kIOSurfacePlaneOffset;
extern const CFStringRef kIOSurfacePlaneSize;
extern const CFStringRef kIOSurfacePlaneBase;
extern const CFStringRef kIOSurfacePlaneBytesPerElement;
extern const CFStringRef kIOSurfacePlaneElementWidth;
extern const CFStringRef kIOSurfacePlaneElementHeight;
extern const CFStringRef kIOSurfaceCacheMode;
extern const CFStringRef kIOSurfacePixelFormat;
extern const CFStringRef kIOSurfacePixelSizeCastingAllowed;

/* Pixel format types commonly used */
#define kCVPixelFormatType_32BGRA  'BGRA'
#define kCVPixelFormatType_32ARGB  'ARGB'

/* IOSurfaceRef type */
typedef struct __IOSurface *IOSurfaceRef;

/* Creation and lifecycle */
CFTypeID IOSurfaceGetTypeID(void);
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
IOSurfaceRef IOSurfaceLookup(IOSurfaceID csid);
IOSurfaceID IOSurfaceGetID(IOSurfaceRef buffer);

/* Locking/Unlocking for CPU access */
kern_return_t IOSurfaceLock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);
kern_return_t IOSurfaceUnlock(IOSurfaceRef buffer, IOSurfaceLockOptions options, uint32_t *seed);

/* Getting surface properties */
size_t IOSurfaceGetAllocSize(IOSurfaceRef buffer);
size_t IOSurfaceGetWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetHeight(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerElement(IOSurfaceRef buffer);
size_t IOSurfaceGetBytesPerRow(IOSurfaceRef buffer);
void *IOSurfaceGetBaseAddress(IOSurfaceRef buffer);
size_t IOSurfaceGetElementWidth(IOSurfaceRef buffer);
size_t IOSurfaceGetElementHeight(IOSurfaceRef buffer);
OSType IOSurfaceGetPixelFormat(IOSurfaceRef buffer);
uint32_t IOSurfaceGetSeed(IOSurfaceRef buffer);

/* Plane information (for planar surfaces) */
size_t IOSurfaceGetPlaneCount(IOSurfaceRef buffer);
size_t IOSurfaceGetWidthOfPlane(IOSurfaceRef buffer, size_t planeIndex);
size_t IOSurfaceGetHeightOfPlane(IOSurfaceRef buffer, size_t planeIndex);
size_t IOSurfaceGetBytesPerElementOfPlane(IOSurfaceRef buffer, size_t planeIndex);
size_t IOSurfaceGetBytesPerRowOfPlane(IOSurfaceRef buffer, size_t planeIndex);
void *IOSurfaceGetBaseAddressOfPlane(IOSurfaceRef buffer, size_t planeIndex);

/* Mach port for cross-process sharing */
mach_port_t IOSurfaceCreateMachPort(IOSurfaceRef buffer);
IOSurfaceRef IOSurfaceLookupFromMachPort(mach_port_t port);

/* Use count management */
void IOSurfaceIncrementUseCount(IOSurfaceRef buffer);
void IOSurfaceDecrementUseCount(IOSurfaceRef buffer);
int32_t IOSurfaceGetUseCount(IOSurfaceRef buffer);
Boolean IOSurfaceIsInUse(IOSurfaceRef buffer);

/* Purgeable state */
kern_return_t IOSurfaceSetPurgeable(IOSurfaceRef buffer, uint32_t newState, uint32_t *oldState);

/* Utility functions */
size_t IOSurfaceGetPropertyMaximum(CFStringRef property);
size_t IOSurfaceGetPropertyAlignment(CFStringRef property);
size_t IOSurfaceAlignProperty(CFStringRef property, size_t value);

#ifdef __cplusplus
}
#endif

#endif /* IOSURFACE_H */
