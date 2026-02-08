/*
 * ScreenshotServices.h
 * Stub header for iOS 13.2.3 SDK screenshot implementation
 * Private framework for system screenshot functionality
 */

#ifndef SCREENSHOTSERVICES_H
#define SCREENSHOTSERVICES_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurface.h>

/*
 * SSImageSurface - Wrapper around IOSurface for screenshots
 */
@interface SSImageSurface : NSObject <NSSecureCoding>

@property(nonatomic) struct __IOSurface *backingSurface;
@property(nonatomic) double scale;
@property(nonatomic) long long orientation;

- (instancetype)init;
- (void)dealloc;

@end

/*
 * SSScreenSnapshotter - Base class for screen snapshotting
 */
@interface SSScreenSnapshotter : NSObject

@property(readonly, nonatomic) UIScreen *screen;

+ (instancetype)snapshotterForScreen:(UIScreen *)screen;
- (instancetype)initWithScreen:(UIScreen *)screen;
- (UIImage *)takeScreenshot;

@end

/*
 * SSMainScreenSnapshotter - Snapshotter for main display
 */
@interface SSMainScreenSnapshotter : SSScreenSnapshotter

- (UIImage *)takeScreenshot;

@end

/*
 * SSScreenCapturer - High-level screenshot interface
 */
@protocol SSScreenCapturerDelegate;

@interface SSScreenCapturer : NSObject

@property(nonatomic, weak) id<SSScreenCapturerDelegate> delegate;
@property(readonly, nonatomic) UIWindow *screenshotsWindow;

+ (void)playScreenshotSound;
+ (BOOL)shouldUseScreenCapturerForScreenshots;

- (instancetype)init;
- (void)takeScreenshot;
- (void)takeScreenshotWithPresentationOptions:(id)presentationOptions;
- (void)takeScreenshotWithOptionsCollection:(id)optionsCollection 
                         presentationOptions:(id)presentationOptions;
- (void)preheatWithPresentationOptions:(id)presentationOptions;

/* Recap (screen recording) */
- (void)startRecap;

@end

/*
 * SSScreenCapturerDelegate
 */
@protocol SSScreenCapturerDelegate <NSObject>
@optional
- (void)screenCapturer:(SSScreenCapturer *)capturer 
    didCaptureScreenshot:(UIImage *)screenshot;
- (void)screenCapturerDidFinish:(SSScreenCapturer *)capturer;
@end

/*
 * SSScreenshotAction - Action for screenshot handling
 */
@interface SSScreenshotAction : NSObject

- (instancetype)init;

@end

/*
 * SSScreenCapturerScreenshotOptions - Options for screenshots
 */
@interface SSScreenCapturerScreenshotOptions : NSObject

@property(nonatomic) BOOL shouldSaveToPhotoLibrary;
@property(nonatomic) BOOL shouldShowUI;
@property(nonatomic) BOOL shouldPlaySound;

@end

/*
 * SSUIService - UI service for screenshots
 */
@interface SSUIService : NSObject

- (instancetype)init;
- (void)showScreenshotUIWithImage:(UIImage *)image;

@end

/*
 * UIImage category for SSImageSurface
 */
@interface UIImage (SSImageSurface)

+ (UIImage *)imageWithSSImageSurface:(SSImageSurface *)surface;
- (SSImageSurface *)ssImageSurface;

@end

#endif /* SCREENSHOTSERVICES_H */
