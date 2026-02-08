/*
 * GraphicsServices.h - GraphicsServices framework for iOS 13.2.3
 * 
 * Note: In iOS 13.x, many GraphicsServices functions have been moved to
 * BackBoardServices or deprecated. This header includes legacy GSEvent
 * support and any remaining useful functions.
 */

#ifndef GRAPHICSSERVICES_H
#define GRAPHICSSERVICES_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - GSEvent (Legacy - Deprecated but functional in iOS 13)

typedef struct __GSEvent *GSEventRef;

// GSEvent types
#define kGSEventTypeMouseDown                   1
#define kGSEventTypeMouseUp                     2
#define kGSEventTypeMouseDragged                6
#define kGSEventTypeKeyDown                     10
#define kGSEventTypeKeyUp                       11
#define kGSEventTypeLockDevice                  23
#define kGSEventTypeVolumeDown                  24
#define kGSEventTypeVolumeUp                    25
#define kGSEventTypeMenuButtonDown              50
#define kGSEventTypeMenuButtonUp                51
#define kGSEventTypeStatusBarTapped             54
#define kGSEventTypeAlertSheetButtonTapped      60
#define kGSEventTypeHardwareKeyboardKeyDown     101
#define kGSEventTypeHardwareKeyboardKeyUp       102
#define kGSEventTypeOrientationsChanged         105

#pragma mark - GSEvent Functions (Legacy)

#ifdef __cplusplus
extern "C" {
#endif

// Get event type
unsigned int GSEventGetType(GSEventRef event);

// Get event location
CGPoint GSEventGetLocationInWindow(GSEventRef event);
CGPoint GSEventGetLocationInView(GSEventRef event, void *view);

// Get timestamp
double GSEventGetTimestamp(GSEventRef event);

// Get subtype
unsigned int GSEventGetSubType(GSEventRef event);

// Get flags
unsigned int GSEventGetFlags(GSEventRef event);

// Get modifier flags
unsigned int GSEventGetModifierFlags(GSEventRef event);

// Get key code
unsigned short GSEventGetKeyCode(GSEventRef event);

// Create synthetic event (limited support in iOS 13)
GSEventRef GSEventCreateWithEventRecord(CFAllocatorRef allocator, void *eventRecord);

// Send event to application
void GSEventSendToApplication(GSEventRef event, void *application);

// Send event to PID
void GSEventSendToPID(GSEventRef event, int pid);

#pragma mark - Display Management

// Get main display bounds
CGRect GSGetMainDisplayBounds(void);

// Get display scale
float GSGetDisplayScale(void);

#pragma mark - Hardware Keyboard

BOOL GSEventIsHardwareKeyboardAttached(void);
BOOL GSEventIsHardwareKeyboardVisible(void);

#pragma mark - Orientation

int GSEventGetCurrentOrientation(void);
void GSEventSetOrientation(int orientation);

// Orientation values
#define kGSOrientationPortrait                  1
#define kGSOrientationPortraitUpsideDown        2
#define kGSOrientationLandscapeLeft             3
#define kGSOrientationLandscapeRight            4

#pragma mark - Alert/Sheet

void GSEventPopRunLoopMode(CFStringRef mode);
void GSEventPushRunLoopMode(CFStringRef mode);

#ifdef __cplusplus
}
#endif

#pragma mark - PurpleSystemEvent (Deprecated)

// PurpleSystemEvent was renamed to GSEvent in later iOS versions
// The following are aliases for compatibility:
#define PurpleEventGetType                      GSEventGetType
#define PurpleEventGetLocationInWindow          GSEventGetLocationInWindow

#pragma mark - Notes for iOS 13.2.3

/*
 * IMPORTANT NOTES FOR iOS 13.2.3:
 * 
 * 1. GSEvent has been deprecated in favor of IOHIDEvent via IOKit
 * 2. For touch injection, prefer using:
 *    - IOKit (IOHIDEventCreateDigitizerFingerEvent, etc.)
 *    - AccessibilityUtilities (AXEventRepresentation)
 *    - BackBoardServices (BKSHIDEventDeliveryManager)
 * 
 * 3. GSEvent functions may still work but are not recommended for new code
 * 
 * 4. SpringBoard and BackBoard now handle touch events directly through
 *    the HID event system
 */

#endif /* GRAPHICSSERVICES_H */
