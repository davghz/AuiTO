//
// KimiRunScreenshot.h - Screenshot capture module for KimiRun
// Supports multiple capture methods for iOS 13.2.3
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KimiRunScreenshot : NSObject

+ (instancetype)sharedScreenshot;

/*
 * Capture full screen using CARenderServer + IOSurface
 * Best method for SpringBoard context - captures everything
 */
- (nullable UIImage *)captureScreen;
- (nullable NSData *)captureScreenAsPNG;
- (nullable NSData *)captureScreenAsJPEGWithQuality:(CGFloat)quality;

/*
 * Capture specific window (UIKit method - fallback)
 */
- (nullable UIImage *)captureWindow:(UIWindow *)window;

/*
 * HTTP-compatible method - returns base64 string
 */
- (nullable NSString *)captureScreenAsBase64PNG;

@end

NS_ASSUME_NONNULL_END
