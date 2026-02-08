/*
 * ScreenshotHelper.h
 * Helper interface for taking screenshots on iOS 13.2.3
 * Designed for use within SpringBoard context
 */

#ifndef SCREENSHOTHELPER_H
#define SCREENSHOTHELPER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Screenshot capture result
 */
@interface ScreenshotResult : NSObject

@property(nonatomic, readonly) UIImage *image;
@property(nonatomic, readonly) NSData *pngData;
@property(nonatomic, readonly) NSData *jpegData;
@property(nonatomic, readonly) CGSize size;
@property(nonatomic, readonly) CGFloat scale;
@property(nonatomic, readonly) NSDate *captureDate;

- (BOOL)saveToFile:(NSString *)path error:(NSError **)error;
- (BOOL)saveToPhotosWithError:(NSError **)error;

@end

/*
 * Main screenshot helper class
 * Supports multiple capture methods
 */
@interface ScreenshotHelper : NSObject

/* Singleton access */
+ (instancetype)sharedHelper;

/* 
 * Method 1: IOSurface + CARenderServer (Recommended for SpringBoard)
 * Fastest, captures entire display including SpringBoard
 */
- (nullable ScreenshotResult *)captureScreenUsingIOSurface;
- (nullable ScreenshotResult *)captureScreenUsingIOSurfaceWithScale:(CGFloat)scale;

/*
 * Method 2: ScreenshotServices (Private framework)
 * Uses system screenshot service
 */
- (nullable ScreenshotResult *)captureScreenUsingScreenshotServices;

/*
 * Method 3: UIKit Public API (Limited to current app)
 * Only works for views within the current app
 */
- (nullable ScreenshotResult *)captureView:(UIView *)view;
- (nullable ScreenshotResult *)captureScreenUsingUIKit;

/*
 * Method 4: CALayer renderInContext
 * Renders a specific layer
 */
- (nullable ScreenshotResult *)captureLayer:(CALayer *)layer;

/*
 * Utility methods
 */
+ (CGSize)mainScreenSize;
+ (CGFloat)mainScreenScale;
+ (CGRect)mainScreenBounds;

@end

/*
 * NSError domain and codes
 */
extern NSString * const ScreenshotHelperErrorDomain;

typedef NS_ENUM(NSInteger, ScreenshotHelperErrorCode) {
    ScreenshotHelperErrorCodeUnknown = 0,
    ScreenshotHelperErrorCodeIOSurfaceCreateFailed = 1,
    ScreenshotHelperErrorCodeRenderFailed = 2,
    ScreenshotHelperErrorCodeLockFailed = 3,
    ScreenshotHelperErrorCodeInvalidSize = 4,
    ScreenshotHelperErrorCodeScreenshotServicesUnavailable = 5,
    ScreenshotHelperErrorCodeSaveFailed = 6,
};

NS_ASSUME_NONNULL_END

#endif /* SCREENSHOTHELPER_H */
