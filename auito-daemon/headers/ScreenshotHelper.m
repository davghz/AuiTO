/*
 * ScreenshotHelper.m
 * Implementation of screenshot methods for iOS 13.2.3
 */

#import "ScreenshotHelper.h"
#import "IOSurface.h"
#import "CARenderServer.h"
#import <QuartzCore/QuartzCore.h>

NSString * const ScreenshotHelperErrorDomain = @"ScreenshotHelperErrorDomain";

#pragma mark - ScreenshotResult Implementation

@implementation ScreenshotResult

- (instancetype)initWithImage:(UIImage *)image {
    self = [super init];
    if (self) {
        _image = image;
        _size = image.size;
        _scale = image.scale;
        _captureDate = [NSDate date];
    }
    return self;
}

- (NSData *)pngData {
    return UIImagePNGRepresentation(self.image);
}

- (NSData *)jpegData {
    return UIImageJPEGRepresentation(self.image, 0.95);
}

- (NSData *)jpegDataWithQuality:(CGFloat)quality {
    return UIImageJPEGRepresentation(self.image, quality);
}

- (BOOL)saveToFile:(NSString *)path error:(NSError **)error {
    NSData *data = self.pngData;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

- (BOOL)saveToPhotosWithError:(NSError **)error {
    // Would need Photos framework and proper entitlements
    // For now, just return NO
    if (error) {
        *error = [NSError errorWithDomain:ScreenshotHelperErrorDomain
                                     code:ScreenshotHelperErrorCodeSaveFailed
                                 userInfo:@{NSLocalizedDescriptionKey: @"Photo library access not implemented"}];
    }
    return NO;
}

@end

#pragma mark - ScreenshotHelper Implementation

@implementation ScreenshotHelper

+ (instancetype)sharedHelper {
    static ScreenshotHelper *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

+ (CGSize)mainScreenSize {
    return [UIScreen mainScreen].bounds.size;
}

+ (CGFloat)mainScreenScale {
    return [UIScreen mainScreen].scale;
}

+ (CGRect)mainScreenBounds {
    return [UIScreen mainScreen].bounds;
}

#pragma mark - Method 1: IOSurface + CARenderServer

- (nullable ScreenshotResult *)captureScreenUsingIOSurface {
    return [self captureScreenUsingIOSurfaceWithScale:[ScreenshotHelper mainScreenScale]];
}

- (nullable ScreenshotResult *)captureScreenUsingIOSurfaceWithScale:(CGFloat)scale {
    // Get screen dimensions
    CGRect bounds = [ScreenshotHelper mainScreenBounds];
    size_t width = (size_t)(bounds.size.width * scale);
    size_t size_t height = (size_t)(bounds.size.height * scale);
    
    // Create IOSurface properties
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    
    // Set dimensions
    CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &width);
    CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &height);
    CFDictionarySetValue(properties, kIOSurfaceWidth, widthNum);
    CFDictionarySetValue(properties, kIOSurfaceHeight, heightNum);
    CFRelease(widthNum);
    CFRelease(heightNum);
    
    // Set pixel format (BGRA is standard for iOS)
    uint32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef formatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);
    CFDictionarySetValue(properties, kIOSurfacePixelFormat, formatNum);
    CFRelease(formatNum);
    
    // Calculate bytes per row (4 bytes per pixel for BGRA)
    size_t bytesPerRow = width * 4;
    // Align to 64 bytes for better GPU performance
    bytesPerRow = (bytesPerRow + 63) & ~63;
    CFNumberRef bprNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bytesPerRow);
    CFDictionarySetValue(properties, kIOSurfaceBytesPerRow, bprNum);
    CFRelease(bprNum);
    
    // Create IOSurface
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    
    if (!surface) {
        NSLog(@"[ScreenshotHelper] Failed to create IOSurface");
        return nil;
    }
    
    // Get render server port
    mach_port_t serverPort = CARenderServerGetServerPort();
    if (serverPort == MACH_PORT_NULL) {
        NSLog(@"[ScreenshotHelper] Failed to get CARenderServer port");
        CFRelease(surface);
        return nil;
    }
    
    // Capture display to IOSurface
    // displayID 0 is typically the main display
    int result = CARenderServerRenderDisplay(serverPort, 0, surface, 0);
    if (result != 0) {
        NSLog(@"[ScreenshotHelper] CARenderServerRenderDisplay failed: %d", result);
        CFRelease(surface);
        return nil;
    }
    
    // Lock IOSurface for reading
    uint32_t seed;
    kern_return_t lockResult = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, &seed);
    if (lockResult != KERN_SUCCESS) {
        NSLog(@"[ScreenshotHelper] Failed to lock IOSurface: %d", lockResult);
        CFRelease(surface);
        return nil;
    }
    
    // Get pixel data
    void *baseAddress = IOSurfaceGetBaseAddress(surface);
    size_t actualWidth = IOSurfaceGetWidth(surface);
    size_t actualHeight = IOSurfaceGetHeight(surface);
    size_t actualBytesPerRow = IOSurfaceGetBytesPerRow(surface);
    
    // Create CGImage from pixel data
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        baseAddress,
        actualWidth,
        actualHeight,
        8,  // bits per component
        actualBytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little  // BGRA
    );
    
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    
    // Cleanup
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, &seed);
    CFRelease(surface);
    
    if (!cgImage) {
        NSLog(@"[ScreenshotHelper] Failed to create CGImage");
        return nil;
    }
    
    // Create UIImage
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    
    if (!image) {
        NSLog(@"[ScreenshotHelper] Failed to create UIImage");
        return nil;
    }
    
    return [[ScreenshotResult alloc] initWithImage:image];
}

#pragma mark - Method 2: ScreenshotServices

- (nullable ScreenshotResult *)captureScreenUsingScreenshotServices {
    // This would require linking against ScreenshotServices.framework
    // and using SSMainScreenSnapshotter
    
    NSLog(@"[ScreenshotHelper] ScreenshotServices method not implemented in this stub");
    
    // Example implementation:
    // SSMainScreenSnapshotter *snapshotter = [[SSMainScreenSnapshotter alloc] init];
    // UIImage *image = [snapshotter takeScreenshot];
    // return [[ScreenshotResult alloc] initWithImage:image];
    
    return nil;
}

#pragma mark - Method 3: UIKit

- (nullable ScreenshotResult *)captureView:(UIView *)view {
    if (!view) {
        return nil;
    }
    
    UIGraphicsBeginImageContextWithOptions(view.bounds.size, NO, 0.0);
    
    // Modern approach (iOS 7+)
    BOOL success = [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (!image || !success) {
        return nil;
    }
    
    return [[ScreenshotResult alloc] initWithImage:image];
}

- (nullable ScreenshotResult *)captureScreenUsingUIKit {
    // This only captures the current app's window
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    
    if (!keyWindow) {
        return nil;
    }
    
    return [self captureView:keyWindow];
}

#pragma mark - Method 4: CALayer

- (nullable ScreenshotResult *)captureLayer:(CALayer *)layer {
    if (!layer) {
        return nil;
    }
    
    CGSize size = layer.bounds.size;
    if (size.width == 0 || size.height == 0) {
        return nil;
    }
    
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    
    CGContextRef context = UIGraphicsGetCurrentContext();
    [layer renderInContext:context];
    
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    if (!image) {
        return nil;
    }
    
    return [[ScreenshotResult alloc] initWithImage:image];
}

@end
