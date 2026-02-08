//
//  TouchInjection.h
//  KimiRun - Touch Injection Module
//
//  Based on iOSRunPortal analysis and iOS 13.2.3 SDK
//  Uses IOHIDEvent method with normalized coordinates
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface KimiRunTouchInjection : NSObject

/**
 * Initialize the touch injection system.
 * Call once on startup before using other methods.
 * @return YES if initialization succeeded, NO otherwise
 */
+ (BOOL)initialize;

/**
 * Check if touch injection is available/initialized
 */
+ (BOOL)isAvailable;

/**
 * Get the currently captured sender ID (0 if not captured).
 */
+ (uint64_t)senderID;

/**
 * Whether sender ID was captured from events (not fallback).
 */
+ (BOOL)senderIDCaptured;

/**
 * Override sender ID for testing (pass 0 to clear).
 * If persist=YES, write to senderID plist for this boot.
 */
+ (void)setSenderIDOverride:(uint64_t)senderID persist:(BOOL)persist;

/**
 * Set sender capture context learned from SpringBoard-side proxy.
 * This is used to decide whether strict BKS sender-descriptor matching
 * can be safely enforced in daemon routing.
 */
+ (void)setProxySenderContextWithID:(uint64_t)senderID
                           captured:(BOOL)captured
                     digitizerCount:(NSInteger)digitizerCount
                             source:(nullable NSString *)source;

/**
 * Whether latest proxy sender context is likely live (captured or digitizer activity).
 */
+ (BOOL)proxySenderLikelyLive;

/**
 * Last sender ID observed from SpringBoard-side proxy context (0 if none).
 */
+ (uint64_t)proxySenderID;

/**
 * Whether proxy sender context reported captured=true.
 */
+ (BOOL)proxySenderCaptured;

/**
 * Digitizer event count reported by proxy sender diagnostics.
 */
+ (int)proxySenderDigitizerCount;

/**
 * Proxy sender source label, when available.
 */
+ (NSString *)proxySenderSourceString;

/**
 * Sender ID source label (none/ioreg/callback/persisted/override).
 */
+ (NSString *)senderIDSourceString;

/**
 * Whether sender ID fallback to constant is enabled.
 */
+ (BOOL)senderIDFallbackEnabled;

/**
 * Number of times senderID callback has fired.
 */
+ (int)senderIDCallbackCount;

/**
 * Whether senderID capture thread is running.
 */
+ (BOOL)senderIDCaptureThreadRunning;

/**
 * Number of digitizer events seen by senderID callback.
 */
+ (int)senderIDDigitizerCount;

/**
 * Last event type seen by senderID callback (or -1).
 */
+ (int)senderIDLastEventType;

/**
 * Whether senderID callback is registered on main runloop.
 */
+ (BOOL)senderIDMainRegistered;

/**
 * Whether senderID callback is registered on dispatch queue.
 */
+ (BOOL)senderIDDispatchRegistered;

/**
 * Pointer to HID connection if available (0 if not).
 */
+ (uintptr_t)hidConnectionPtr;

/**
 * Admin client type used for IOHIDEventSystemClientCreateWithType (-1 if none).
 */
+ (int)adminClientType;

/**
 * Whether BKSHIDEventDeliveryManager instance is available.
 */
+ (BOOL)bksDeliveryManagerAvailable;

/**
 * Pointer to BKSHIDEventDeliveryManager instance (0 if unavailable).
 */
+ (uintptr_t)bksDeliveryManagerPtr;

/**
 * Whether BKSHIDEventRouterManager instance is available.
 */
+ (BOOL)bksRouterManagerAvailable;

/**
 * Pointer to BKSHIDEventRouterManager instance (0 if unavailable).
 */
+ (uintptr_t)bksRouterManagerPtr;

/**
 * Last BKS dispatch telemetry from daemon routing pass.
 * Includes chosen target source/destination/class/pid and route attempts.
 */
+ (nullable NSDictionary *)lastBKSDispatchInfo;

/**
 * Recent BKS dispatch telemetry snapshots, oldest to newest.
 * Pass 0 to return all retained snapshots.
 */
+ (NSArray<NSDictionary *> *)recentBKSDispatchHistory:(NSUInteger)limit;

/**
 * Perform a single tap at the specified screen coordinates.
 * Coordinates are in screen points (not normalized).
 * Includes 50ms delay between touch down and up.
 *
 * @param x Screen X coordinate in points
 * @param y Screen Y coordinate in points
 * @return YES if tap was successfully injected
 */
+ (BOOL)tapAtX:(CGFloat)x Y:(CGFloat)y;

/**
 * Perform a tap with a specific injection method.
 * method: "sim" (IOHID only), "bks", "ax", "zx", "zxtouch", "all",
 * or nil/"auto" for default behavior.
 */
+ (BOOL)tapAtX:(CGFloat)x Y:(CGFloat)y method:(nullable NSString *)method;

/**
 * Perform a swipe gesture from start point to end point.
 * Uses 20 interpolation steps with specified duration.
 *
 * @param x1 Starting X coordinate in points
 * @param y1 Starting Y coordinate in points
 * @param x2 Ending X coordinate in points
 * @param y2 Ending Y coordinate in points
 * @param duration Duration in seconds (default 0.3s if 0)
 * @return YES if swipe was successfully injected
 */
+ (BOOL)swipeFromX:(CGFloat)x1 Y:(CGFloat)y1 toX:(CGFloat)x2 Y:(CGFloat)y2 duration:(NSTimeInterval)duration;

/**
 * Perform a swipe with a specific injection method.
 * method: "sim", "conn", "legacy", "bks", "zx", "zxtouch", "all",
 * or nil/"auto" for default behavior.
 */
+ (BOOL)swipeFromX:(CGFloat)x1
                 Y:(CGFloat)y1
               toX:(CGFloat)x2
                 Y:(CGFloat)y2
          duration:(NSTimeInterval)duration
            method:(nullable NSString *)method;

/**
 * Send a keyboard usage code (usage page 0x07).
 * @param usage HID usage ID (keyboard page)
 * @param down YES for key down, NO for key up
 */
+ (BOOL)sendKeyUsage:(uint16_t)usage down:(BOOL)down;

/**
 * Type ASCII text using HID keyboard events (best-effort).
 */
+ (BOOL)typeText:(NSString *)text;

/**
 * Perform a drag gesture from start point to end point.
 * Uses 50 interpolation steps for smoother movement.
 *
 * @param x1 Starting X coordinate in points
 * @param y1 Starting Y coordinate in points
 * @param x2 Ending X coordinate in points
 * @param y2 Ending Y coordinate in points
 * @param duration Duration in seconds (default 1.0s if 0)
 * @return YES if drag was successfully injected
 */
+ (BOOL)dragFromX:(CGFloat)x1 Y:(CGFloat)y1 toX:(CGFloat)x2 Y:(CGFloat)y2 duration:(NSTimeInterval)duration;

/**
 * Perform a drag with a specific injection method.
 * method: "sim", "conn", "legacy", "bks", "zx", "zxtouch", "all",
 * or nil/"auto" for default behavior.
 */
+ (BOOL)dragFromX:(CGFloat)x1
                Y:(CGFloat)y1
              toX:(CGFloat)x2
                Y:(CGFloat)y2
         duration:(NSTimeInterval)duration
           method:(nullable NSString *)method;

/**
 * Perform a long press at the specified coordinates.
 *
 * @param x Screen X coordinate in points
 * @param y Screen Y coordinate in points
 * @param duration Duration in seconds to hold (default 1.0s if 0)
 * @return YES if long press was successfully injected
 */
+ (BOOL)longPressAtX:(CGFloat)x Y:(CGFloat)y duration:(NSTimeInterval)duration;

/**
 * Perform a long press with a specific injection method.
 * method: "sim", "conn", "legacy", "bks", "zx", "zxtouch", "all",
 * or nil/"auto" for default behavior.
 */
+ (BOOL)longPressAtX:(CGFloat)x Y:(CGFloat)y duration:(NSTimeInterval)duration method:(nullable NSString *)method;

/**
 * Perform a double tap at the specified coordinates.
 *
 * @param x Screen X coordinate in points
 * @param y Screen Y coordinate in points
 * @return YES if double tap was successfully injected
 */
+ (BOOL)doubleTapAtX:(CGFloat)x Y:(CGFloat)y;

/**
 * Perform a double tap with a specific injection method.
 * method: "sim", "conn", "legacy", "bks", "zx", "zxtouch", "all",
 * or nil/"auto" for default behavior.
 */
+ (BOOL)doubleTapAtX:(CGFloat)x Y:(CGFloat)y method:(nullable NSString *)method;

/**
 * Try to focus the Settings search field (best-effort).
 */
+ (BOOL)forceFocusSearchField;

/**
 * Log runtime selectors for BKHIDClientConnectionManager.
 */
+ (void)logBKHIDSelectorsNow;

/**
 * Path to the BKHID selector log file.
 */
+ (NSString *)bkhidSelectorsLogPath;

/**
 * Comprehensive HID subsystem diagnostic snapshot.
 * Returns a dictionary suitable for JSON serialization.
 */
+ (NSDictionary *)hidDiagnostics;

@end

NS_ASSUME_NONNULL_END
