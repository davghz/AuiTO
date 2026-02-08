/*
 * IOHIDEvent.h - IOKit HID Event declarations for iOS 13.2.3
 * 
 * These are the core functions and types needed for touch/gesture injection
 * via IOKit framework on iOS 13.2.3
 */

#ifndef IOHIDEVENT_H
#define IOHIDEVENT_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - IOHIDEvent Types

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

#pragma mark - IOHIDEventType (Key event types for touch injection)

typedef uint32_t IOHIDEventType;

// Event types available in iOS 13.2.3
#define kIOHIDEventTypeNULL                     0
#define kIOHIDEventTypeVendorDefined            1
#define kIOHIDEventTypeButton                   3
#define kIOHIDEventTypeTranslation              4
#define kIOHIDEventTypeRotation                 5
#define kIOHIDEventTypeScale                    6
#define kIOHIDEventTypeVelocity                 7
#define kIOHIDEventTypeScroll                   8
#define kIOHIDEventTypeZoomToggle               9
#define kIOHIDEventTypeSwipe                    10
#define kIOHIDEventTypeNavigationSwipe          13
#define kIOHIDEventTypeDockSwipe                14
#define kIOHIDEventTypeFluidTouchGesture        15
#define kIOHIDEventTypeBoundaryScroll           16
#define kIOHIDEventTypeProgress                 17
#define kIOHIDEventTypeDigitizer                29
#define kIOHIDEventTypeKeyboard                 3
#define kIOHIDEventTypeAccelerometer            20
#define kIOHIDEventTypeGyro                     21
#define kIOHIDEventTypeProximity                26
#define kIOHIDEventTypeOrientation              35

#pragma mark - Digitizer Event Masks (Touch states)

typedef uint32_t IOHIDDigitizerEventMask;

#define kIOHIDDigitizerEventRange               0x00000001
#define kIOHIDDigitizerEventTouch               0x00000002
#define kIOHIDDigitizerEventPosition            0x00000004
#define kIOHIDDigitizerEventStop                0x00000008
#define kIOHIDDigitizerEventPeak                0x00000010
#define kIOHIDDigitizerEventIdentity            0x00000020
#define kIOHIDDigitizerEventAttribute           0x00000040
#define kIOHIDDigitizerEventCancel              0x00000080
#define kIOHIDDigitizerEventStart               0x00000100
#define kIOHIDDigitizerEventResting             0x00000200
#define kIOHIDDigitizerEventFromEdgeFlat        0x00000400
#define kIOHIDDigitizerEventFromEdgeTip         0x00000800
#define kIOHIDDigitizerEventFromCorner          0x00001000
#define kIOHIDDigitizerEventThumbnail           0x00002000
#define kIOHIDDigitizerEventTouchCancelled      0x00008000

#pragma mark - Digitizer Transducer Types

typedef uint32_t IOHIDDigitizerTransducerType;

#define kIOHIDDigitizerTransducerTypeStylus     0
#define kIOHIDDigitizerTransducerTypePuck       1
#define kIOHIDDigitizerTransducerTypeFinger     2
#define kIOHIDDigitizerTransducerTypeHand       3

#pragma mark - Event Flags

typedef uint32_t IOHIDEventOptionBits;

#define kIOHIDEventOptionNone                   0
#define kIOHIDEventOptionIsAbsolute             0x00000001
#define kIOHIDEventOptionIsRelative             0x00000002
#define kIOHIDEventOptionIsCollection           0x00000004
#define kIOHIDEventOptionPixelUnits             0x00000008
#define kIOHIDEventOptionCenterOrigin           0x00000010
#define kIOHIDEventOptionSingleton              0x00000020

#pragma mark - Event Fields (for IOHIDEventGet/SetInteger/FloatValue)

typedef uint32_t IOHIDEventField;

// Digitizer event fields
#define kIOHIDEventFieldDigitizerX                          0x00040000
#define kIOHIDEventFieldDigitizerY                          0x00040001
#define kIOHIDEventFieldDigitizerZ                          0x00040002
#define kIOHIDEventFieldDigitizerButtonMask                 0x00040003
#define kIOHIDEventFieldDigitizerType                       0x00040004
#define kIOHIDEventFieldDigitizerIndex                      0x00040005
#define kIOHIDEventFieldDigitizerIdentity                   0x00040006
#define kIOHIDEventFieldDigitizerEventMask                  0x00040007
#define kIOHIDEventFieldDigitizerRange                      0x00040008
#define kIOHIDEventFieldDigitizerTouch                      0x00040009
#define kIOHIDEventFieldDigitizerPressure                   0x0004000A
#define kIOHIDEventFieldDigitizerBarrelPressure             0x0004000B
#define kIOHIDEventFieldDigitizerTwist                      0x0004000C
#define kIOHIDEventFieldDigitizerTiltX                      0x0004000D
#define kIOHIDEventFieldDigitizerTiltY                      0x0004000E
#define kIOHIDEventFieldDigitizerAltitude                   0x0004000F
#define kIOHIDEventFieldDigitizerAzimuth                    0x00040010
#define kIOHIDEventFieldDigitizerQuality                    0x00040011
#define kIOHIDEventFieldDigitizerDensity                    0x00040012
#define kIOHIDEventFieldDigitizerIrregularity               0x00040013
#define kIOHIDEventFieldDigitizerMajorRadius                0x00040014
#define kIOHIDEventFieldDigitizerMinorRadius                0x00040015
#define kIOHIDEventFieldDigitizerCollectionRange            0x00040016
#define kIOHIDEventFieldDigitizerCollectionTouch            0x00040017
#define kIOHIDEventFieldDigitizerCollectionIndex            0x00040018
#define kIOHIDEventFieldDigitizerCollectionIdentity         0x00040019
#define kIOHIDEventFieldDigitizerCollectionEventMask        0x0004001A
#define kIOHIDEventFieldDigitizerChildEventMask             0x0004001B
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated        0x0004001C
#define kIOHIDEventFieldDigitizerPolarOrientation           0x0004001D
#define kIOHIDEventFieldDigitizerTiltAltitude               0x0004001E
#define kIOHIDEventFieldDigitizerTiltAzimuth                0x0004001F

#pragma mark - IOHIDEvent Core Functions

// Create an empty HID event
IOHIDEventRef IOHIDEventCreate(
    CFAllocatorRef allocator,
    IOHIDEventType type,
    uint64_t timestamp,
    IOHIDEventOptionBits options);

// Create a digitizer event (multi-touch)
IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDDigitizerTransducerType type,
    uint32_t index,
    uint32_t identity,
    IOHIDDigitizerEventMask eventMask,
    uint32_t buttonMask,
    float x,
    float y,
    float z,
    float pressure,
    float twist,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options);

// Create a single finger touch event
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
    IOHIDEventOptionBits options);

// Create finger event with quality parameters (iOS 13+)
IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
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
    float majorRadius,
    float minorRadius,
    float quality,
    float density,
    float irregularity,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options);

// Create stylus event
IOHIDEventRef IOHIDEventCreateDigitizerStylusEvent(
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
    float altitude,
    float azimuth,
    float barrelPressure,
    Boolean range,
    Boolean touch,
    Boolean invert,
    IOHIDEventOptionBits options);

// Create swipe events
IOHIDEventRef IOHIDEventCreateSwipeEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDEventOptionBits options,
    float progress,
    float position,
    float velocity);

IOHIDEventRef IOHIDEventCreateNavigationSwipeEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDEventOptionBits options,
    float progress,
    float position,
    float velocity);

IOHIDEventRef IOHIDEventCreateDockSwipeEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDEventOptionBits options,
    float progress,
    float position,
    float velocity);

// Create gesture events
IOHIDEventRef IOHIDEventCreateGenericGestureEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDEventOptionBits options);

IOHIDEventRef IOHIDEventCreateFluidTouchGestureEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDEventOptionBits options,
    float progress,
    float position,
    float velocity);

IOHIDEventRef IOHIDEventCreateMotionGestureEvent(
    CFAllocatorRef allocator,
    uint64_t timestamp,
    IOHIDEventOptionBits options);

#pragma mark - Event Modification

// Append child events (for multi-touch)
void IOHIDEventAppendEvent(
    IOHIDEventRef event,
    IOHIDEventRef childEvent,
    Boolean copy);

// Remove child events
void IOHIDEventRemoveEvent(
    IOHIDEventRef event,
    IOHIDEventRef childEvent,
    Boolean release);

// Set event timestamp
void IOHIDEventSetTimeStamp(
    IOHIDEventRef event,
    uint64_t timestamp);

// Get event timestamp
uint64_t IOHIDEventGetTimeStamp(IOHIDEventRef event);

// Set sender ID
void IOHIDEventSetSenderID(
    IOHIDEventRef event,
    uint64_t senderID);

// Get sender ID
uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);

// Get event type
IOHIDEventType IOHIDEventGetType(IOHIDEventRef event);

// Set/get integer values
void IOHIDEventSetIntegerValue(
    IOHIDEventRef event,
    IOHIDEventField field,
    CFIndex value);

CFIndex IOHIDEventGetIntegerValue(
    IOHIDEventRef event,
    IOHIDEventField field);

// Set/get float values
void IOHIDEventSetFloatValue(
    IOHIDEventRef event,
    IOHIDEventField field,
    double value);

double IOHIDEventGetFloatValue(
    IOHIDEventRef event,
    IOHIDEventField field);

// Set/get position
void IOHIDEventSetPosition(
    IOHIDEventRef event,
    IOHIDEventField field,
    float x,
    float y);

// Check event type
Boolean IOHIDEventConformsTo(
    IOHIDEventRef event,
    IOHIDEventType type);

// Get phase (for gesture events)
uint32_t IOHIDEventGetPhase(IOHIDEventRef event);
void IOHIDEventSetPhase(
    IOHIDEventRef event,
    uint32_t phase);

// Event flags
void IOHIDEventSetEventFlags(
    IOHIDEventRef event,
    uint64_t flags);

uint64_t IOHIDEventGetEventFlags(IOHIDEventRef event);

// Retain/Release
IOHIDEventRef IOHIDEventCreateCopy(
    CFAllocatorRef allocator,
    IOHIDEventRef event);

#pragma mark - Event System Client (for dispatching events)

// Create event system client
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);

IOHIDEventSystemClientRef IOHIDEventSystemClientCreateSimpleClient(CFAllocatorRef allocator);

IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(
    CFAllocatorRef allocator,
    uint32_t type,
    CFDictionaryRef properties);

// Dispatch event
void IOHIDEventSystemClientDispatchEvent(
    IOHIDEventSystemClientRef client,
    IOHIDEventRef event);

// Schedule/unschedule
void IOHIDEventSystemClientScheduleWithRunLoop(
    IOHIDEventSystemClientRef client,
    CFRunLoopRef runLoop,
    CFStringRef mode);

void IOHIDEventSystemClientUnscheduleWithRunLoop(
    IOHIDEventSystemClientRef client,
    CFRunLoopRef runLoop,
    CFStringRef mode);

void IOHIDEventSystemClientScheduleWithDispatchQueue(
    IOHIDEventSystemClientRef client,
    dispatch_queue_t queue);

void IOHIDEventSystemClientUnscheduleFromDispatchQueue(
    IOHIDEventSystemClientRef client,
    dispatch_queue_t queue);

// Activate/Cancel
void IOHIDEventSystemClientActivate(IOHIDEventSystemClientRef client);
void IOHIDEventSystemClientCancel(IOHIDEventSystemClientRef client);

// Get type ID
CFTypeID IOHIDEventSystemClientGetTypeID(void);
CFTypeID IOHIDEventGetTypeID(void);

#pragma mark - Legacy Event Posting (deprecated but functional in iOS 13)

// Legacy function - still works in iOS 13.2.3 for simple use cases
void IOHIDPostEvent(
    mach_port_t port,
    UInt32 eventType,
    UInt32 flags,
    void *data);

#pragma mark - Helper Functions

// Get event type name
CFStringRef IOHIDEventTypeGetName(IOHIDEventType type);

// Check if event is absolute
Boolean IOHIDEventIsAbsolute(IOHIDEventRef event);

// Create event from bytes
IOHIDEventRef IOHIDEventCreateWithBytes(
    CFAllocatorRef allocator,
    const uint8_t *bytes,
    CFIndex length);

IOHIDEventRef IOHIDEventCreateWithData(
    CFAllocatorRef allocator,
    CFDataRef data);

// Serialize to data
CFDataRef IOHIDEventCreateData(
    CFAllocatorRef allocator,
    IOHIDEventRef event);

#ifdef __cplusplus
}
#endif

#endif /* IOHIDEVENT_H */
