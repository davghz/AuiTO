//
// KimiRunScreenshot.m - Screenshot capture implementation
// Uses UIKit's drawViewHierarchyInRect (like iOSRunPortal)
//

#import "KimiRunScreenshot.h"
#import <IOSurface/IOSurfaceRef.h>
#import "../../headers/CARenderServer.h"
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static UIImage *CaptureScreenUsingIOSurface(CGFloat scale);
static UIImage *CaptureScreenUsingUIKit(void);
static BOOL KimiRunImageAppearsBlack(UIImage *image);
static NSArray<UIWindow *> *KimiRunForegroundWindows(void);

@implementation KimiRunScreenshot

+ (instancetype)sharedScreenshot {
    static KimiRunScreenshot *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (nullable UIImage *)captureScreen {
    NSLog(@"[KimiRunScreenshot] Capturing screen");

    __block UIImage *image = nil;
    void (^captureBlock)(void) = ^{
        CGFloat scale = [UIScreen mainScreen].scale;
        image = CaptureScreenUsingIOSurface(scale);
        if (image && KimiRunImageAppearsBlack(image)) {
            NSLog(@"[KimiRunScreenshot] IOSurface frame appears black, falling back to UIKit composition");
            image = nil;
        }
        if (!image) {
            image = CaptureScreenUsingUIKit();
        }
    };

    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), captureBlock);
    }

    if (image) {
        NSLog(@"[KimiRunScreenshot] Captured: %.0fx%.0f", image.size.width, image.size.height);
    } else {
        NSLog(@"[KimiRunScreenshot] Failed to capture image");
    }

    return image;
}

- (nullable NSData *)captureScreenAsPNG {
    UIImage *image = [self captureScreen];
    if (!image) {
        return nil;
    }
    return UIImagePNGRepresentation(image);
}

- (nullable NSData *)captureScreenAsJPEGWithQuality:(CGFloat)quality {
    UIImage *image = [self captureScreen];
    if (!image) {
        return nil;
    }
    return UIImageJPEGRepresentation(image, quality);
}

- (nullable UIImage *)captureWindow:(UIWindow *)window {
    if (!window) {
        return nil;
    }
    
    __block UIImage *image = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 0);
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    
    return image;
}

- (nullable NSString *)captureScreenAsBase64PNG {
    NSData *pngData = [self captureScreenAsPNG];
    if (!pngData) {
        return nil;
    }
    return [pngData base64EncodedStringWithOptions:0];
}

@end

static UIImage *CaptureScreenUsingIOSurface(CGFloat scale) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    size_t width = (size_t)lrint(bounds.size.width * scale);
    size_t height = (size_t)lrint(bounds.size.height * scale);

    if (width == 0 || height == 0) {
        return nil;
    }

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    CFNumberRef widthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &width);
    CFNumberRef heightNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &height);
    CFDictionarySetValue(props, kIOSurfaceWidth, widthNum);
    CFDictionarySetValue(props, kIOSurfaceHeight, heightNum);
    CFRelease(widthNum);
    CFRelease(heightNum);

    uint32_t pixelFormat = kCVPixelFormatType_32BGRA;
    CFNumberRef formatNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);
    CFDictionarySetValue(props, kIOSurfacePixelFormat, formatNum);
    CFRelease(formatNum);

    size_t bytesPerRow = width * 4;
    bytesPerRow = (bytesPerRow + 63) & ~63;
    CFNumberRef bprNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bytesPerRow);
    CFDictionarySetValue(props, kIOSurfaceBytesPerRow, bprNum);
    CFRelease(bprNum);

    IOSurfaceRef surface = IOSurfaceCreate(props);
    CFRelease(props);

    if (!surface) {
        NSLog(@"[KimiRunScreenshot] IOSurface create failed");
        return nil;
    }

    mach_port_t serverPort = CARenderServerGetServerPort();
    if (serverPort == MACH_PORT_NULL) {
        serverPort = CARenderServerGetPort();
    }
    if (serverPort == MACH_PORT_NULL) {
        CGImageRef directImage = CARenderServerCaptureDisplay(0);
        if (directImage) {
            UIImage *image = [UIImage imageWithCGImage:directImage scale:scale orientation:UIImageOrientationUp];
            CGImageRelease(directImage);
            CFRelease(surface);
            return image;
        }
        if (CARenderServerStart()) {
            serverPort = CARenderServerGetServerPort();
            if (serverPort == MACH_PORT_NULL) {
                serverPort = CARenderServerGetPort();
            }
        }
    }
    if (serverPort == MACH_PORT_NULL) {
        NSLog(@"[KimiRunScreenshot] CARenderServer port unavailable");
        CFRelease(surface);
        return nil;
    }

    int result = CARenderServerRenderDisplay(serverPort, 0, surface, 0);
    if (result != 0) {
        NSLog(@"[KimiRunScreenshot] CARenderServerRenderDisplay failed: %d", result);
        CGImageRef directImage = CARenderServerCaptureDisplay(0);
        if (directImage) {
            UIImage *image = [UIImage imageWithCGImage:directImage scale:scale orientation:UIImageOrientationUp];
            CGImageRelease(directImage);
            CFRelease(surface);
            return image;
        }
        CFRelease(surface);
        return nil;
    }

    uint32_t seed = 0;
    kern_return_t lockResult = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, &seed);
    if (lockResult != KERN_SUCCESS) {
        NSLog(@"[KimiRunScreenshot] IOSurface lock failed: %d", lockResult);
        CFRelease(surface);
        return nil;
    }

    void *base = IOSurfaceGetBaseAddress(surface);
    size_t actualWidth = IOSurfaceGetWidth(surface);
    size_t actualHeight = IOSurfaceGetHeight(surface);
    size_t actualBpr = IOSurfaceGetBytesPerRow(surface);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        base,
        actualWidth,
        actualHeight,
        8,
        actualBpr,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );

    CGImageRef cgImage = ctx ? CGBitmapContextCreateImage(ctx) : NULL;

    if (ctx) {
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(colorSpace);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, &seed);
    CFRelease(surface);

    if (!cgImage) {
        NSLog(@"[KimiRunScreenshot] Failed to create CGImage");
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:cgImage scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static UIImage *CaptureScreenUsingUIKit(void) {
    NSArray<UIWindow *> *windows = KimiRunForegroundWindows();
    if (windows.count == 0) {
        NSLog(@"[KimiRunScreenshot] No foreground windows found for UIKit capture");
        return nil;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    UIGraphicsBeginImageContextWithOptions(screenBounds.size, NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    for (UIWindow *window in windows) {
        if (!window || window.hidden || window.alpha < 0.01f) {
            continue;
        }
        CGRect drawRect = [window convertRect:window.bounds toWindow:nil];
        if (CGRectIsEmpty(drawRect)) {
            drawRect = window.frame;
        }
        BOOL drew = [window drawViewHierarchyInRect:drawRect afterScreenUpdates:NO];
        if (!drew) {
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, drawRect.origin.x, drawRect.origin.y);
            [window.layer renderInContext:ctx];
            CGContextRestoreGState(ctx);
        }
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static NSArray<UIWindow *> *KimiRunForegroundWindows(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return @[];
    }

    NSMutableArray<UIWindow *> *foreground = [NSMutableArray array];
    NSMutableArray<UIWindow *> *all = [NSMutableArray array];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            BOOL isForeground = (windowScene.activationState == UISceneActivationStateForegroundActive ||
                                 windowScene.activationState == UISceneActivationStateForegroundInactive);
            for (UIWindow *window in windowScene.windows) {
                if (!window) {
                    continue;
                }
                [all addObject:window];
                if (isForeground) {
                    [foreground addObject:window];
                }
            }
        }
    }

    if (all.count == 0) {
        [all addObjectsFromArray:app.windows ?: @[]];
    }
    if (foreground.count == 0) {
        [foreground addObjectsFromArray:all];
    }

    NSArray<UIWindow *> *sorted = [foreground sortedArrayUsingComparator:^NSComparisonResult(UIWindow *w1, UIWindow *w2) {
        if (w1.windowLevel < w2.windowLevel) return NSOrderedAscending;
        if (w1.windowLevel > w2.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return sorted ?: @[];
}

static BOOL KimiRunImageAppearsBlack(UIImage *image) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return YES;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        return YES;
    }

    size_t sampleCount = 0;
    size_t darkCount = 0;
    size_t alphaZeroCount = 0;
    const size_t stepX = MAX((size_t)1, width / 24);
    const size_t stepY = MAX((size_t)1, height / 24);

    CFDataRef dataRef = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    if (!dataRef) {
        return NO;
    }
    const UInt8 *bytes = CFDataGetBytePtr(dataRef);
    size_t bpr = CGImageGetBytesPerRow(cgImage);

    for (size_t y = 0; y < height; y += stepY) {
        for (size_t x = 0; x < width; x += stepX) {
            const UInt8 *px = bytes + y * bpr + x * 4;
            UInt8 b = px[0];
            UInt8 g = px[1];
            UInt8 r = px[2];
            UInt8 a = px[3];
            sampleCount++;
            if (a < 8) {
                alphaZeroCount++;
            }
            if ((r + g + b) < 24) {
                darkCount++;
            }
        }
    }
    CFRelease(dataRef);

    if (sampleCount == 0) {
        return YES;
    }
    double darkRatio = (double)darkCount / (double)sampleCount;
    double alphaZeroRatio = (double)alphaZeroCount / (double)sampleCount;
    return (darkRatio > 0.985 || alphaZeroRatio > 0.985);
}
