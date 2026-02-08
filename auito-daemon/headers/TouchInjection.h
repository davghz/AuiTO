/*
 * TouchInjection.h - Convenience header for touch/gesture injection on iOS 13.2.3
 * 
 * This header provides simplified C++ and Objective-C interfaces for common
 * touch injection tasks. Include this for the easiest integration.
 */

#ifndef TOUCHINJECTION_H
#define TOUCHINJECTION_H

#import "IOHIDEvent.h"
#import "BackBoardServices.h"
#import "AccessibilityUtilities.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Convenient Touch Injection Functions

/*
 * Simple tap at screen coordinates
 * 
 * @param x Screen X coordinate
 * @param y Screen Y coordinate  
 * @param duration Duration in seconds (0 for instant)
 */
void TIInjectTap(float x, float y, double duration);

/*
 * Simple swipe gesture
 * 
 * @param startX Starting X coordinate
 * @param startY Starting Y coordinate
 * @param endX Ending X coordinate
 * @param endY Ending Y coordinate
 * @param duration Duration in seconds
 */
void TIInjectSwipe(float startX, float startY, float endX, float endY, double duration);

/*
 * Multi-touch pinch gesture (zoom)
 * 
 * @param centerX Center X coordinate
 * @param centerY Center Y coordinate
 * @param scale Scale factor (>1 = zoom in, <1 = zoom out)
 * @param duration Duration in seconds
 */
void TIInjectPinch(float centerX, float centerY, float scale, double duration);

/*
 * Long press gesture
 * 
 * @param x Screen X coordinate
 * @param y Screen Y coordinate
 * @param duration Duration in seconds
 */
void TIInjectLongPress(float x, float y, double duration);

/*
 * Pan gesture (drag)
 * 
 * @param points Array of CGPoint positions
 * @param pointCount Number of points
 * @param duration Duration in seconds
 */
void TIInjectPan(const CGPoint *points, int pointCount, double duration);

#pragma mark - Multi-Touch Support

#define TI_MAX_TOUCHES                          5

typedef struct {
    float x;
    float y;
    float pressure;
    float majorRadius;
    float minorRadius;
    uint32_t fingerId;
    BOOL isTouching;
} TIFingerState;

/*
 * Begin multi-touch session
 */
void TIBeginMultiTouch(void);

/*
 * Update finger state
 */
void TIUpdateFinger(uint32_t fingerIndex, const TIFingerState *state);

/*
 * Send current multi-touch state
 */
void TICommitMultiTouch(void);

/*
 * End multi-touch session
 */
void TIEndMultiTouch(void);

#pragma mark - Accessibility Mode (Recommended for iOS 13)

/*
 * Inject using Accessibility framework (easiest method)
 */
void TIInjectTapAccessibility(float x, float y);
void TIInjectSwipeAccessibility(float startX, float startY, float endX, float endY);
void TIInjectMultiTouchAccessibility(const CGPoint *positions, int count);

#pragma mark - Timing Utilities

/*
 * Get timestamp for HID events
 */
uint64_t TIGetCurrentTimestamp(void);

/*
 * Convert seconds to HID timestamp units
 */
uint64_t TISecondsToTimestamp(double seconds);

/*
 * Sleep with high precision (for gesture timing)
 */
void TIPreciseSleep(double seconds);

#pragma mark - Screen Information

/*
 * Get main screen bounds
 */
CGRect TIGetMainScreenBounds(void);

/*
 * Get screen scale factor
 */
float TIGetScreenScale(void);

/*
 * Convert point to screen coordinates (handles scale)
 */
CGPoint TIConvertToScreenCoordinates(float x, float y);

#ifdef __cplusplus
}
#endif

#pragma mark - Objective-C Helper Classes (when using Obj-C++)

#ifdef __OBJC__

@interface TITouchInjector : NSObject

+ (instancetype)sharedInjector;

// Simple gestures
- (void)tapAtPoint:(CGPoint)point;
- (void)tapAtPoint:(CGPoint)point duration:(NSTimeInterval)duration;
- (void)swipeFromPoint:(CGPoint)startPoint toPoint:(CGPoint)endPoint;
- (void)swipeFromPoint:(CGPoint)startPoint toPoint:(CGPoint)endPoint duration:(NSTimeInterval)duration;
- (void)longPressAtPoint:(CGPoint)point;
- (void)longPressAtPoint:(CGPoint)point duration:(NSTimeInterval)duration;

// Multi-touch
- (void)beginMultiTouch;
- (void)updateFinger:(NSUInteger)fingerIndex atPoint:(CGPoint)point;
- (void)updateFinger:(NSUInteger)fingerIndex atPoint:(CGPoint)point pressure:(CGFloat)pressure;
- (void)liftFinger:(NSUInteger)fingerIndex;
- (void)commitTouches;
- (void)endMultiTouch;

// Pinch
- (void)pinchAtCenter:(CGPoint)center scale:(CGFloat)scale;
- (void)pinchAtCenter:(CGPoint)center scale:(CGFloat)scale duration:(NSTimeInterval)duration;

// Pan
- (void)panAlongPoints:(NSArray<NSValue *> *)points;
- (void)panAlongPoints:(NSArray<NSValue *> *)points duration:(NSTimeInterval)duration;

@end

#endif /* __OBJC__ */

#endif /* TOUCHINJECTION_H */
