#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

@interface AUIVirtualTouch : NSObject

/// Create the virtual HID multitouch digitizer device.
/// Must be called before any touch methods. Returns YES on success.
- (BOOL)createDevice;

/// Destroy the virtual device.
- (void)destroyDevice;

/// Whether the virtual device is currently active.
@property (nonatomic, readonly) BOOL deviceActive;

/// Send a single finger down event.
- (BOOL)touchDownWithFinger:(uint8_t)finger x:(uint16_t)x y:(uint16_t)y;

/// Send a single finger move event.
- (BOOL)touchMoveWithFinger:(uint8_t)finger x:(uint16_t)x y:(uint16_t)y;

/// Send a single finger up event.
- (BOOL)touchUpWithFinger:(uint8_t)finger;

/// Send a tap gesture (down + 80ms + up).
- (BOOL)tapAtX:(uint16_t)x y:(uint16_t)y;

/// Send a swipe gesture with interpolated steps.
- (BOOL)swipeFromX:(uint16_t)x1 y:(uint16_t)y1
             toX:(uint16_t)x2 y:(uint16_t)y2
        duration:(NSTimeInterval)duration
           steps:(NSUInteger)steps;

@end
