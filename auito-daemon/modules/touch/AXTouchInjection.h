//
//  AXTouchInjection.h
//  KimiRun - Accessibility-based Touch Injection
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface AXTouchInjection : NSObject

+ (BOOL)tapAtPoint:(CGPoint)point;
+ (BOOL)swipeFromPoint:(CGPoint)startPoint
               toPoint:(CGPoint)endPoint
              duration:(NSTimeInterval)duration;
+ (NSDictionary *)accessibilityStatus;
+ (NSDictionary *)ensureAccessibilityEnabled;

@end
