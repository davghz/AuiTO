/*
 * SpringBoardServices.h - SpringBoardServices framework for iOS 13.2.3
 * 
 * SpringBoardServices provides interfaces for interacting with SpringBoard,
 * including app launching, badges, and some system-level functionality.
 * 
 * Note: Direct touch injection through SpringBoardServices is limited in iOS 13.
 * Use BackBoardServices or AccessibilityUtilities for touch injection instead.
 */

#ifndef SPRINGBOARDSERVICES_H
#define SPRINGBOARDSERVICES_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - SBSApplicationShortcutService

@interface SBSApplicationShortcutService : NSObject

+ (instancetype)sharedInstance;

- (void)launchShortcutWithIdentifier:(NSString *)identifier
                   forApplicationIdentifier:(NSString *)bundleIdentifier
                              completion:(void (^)(void))completion;

@end

#pragma mark - SBSApplicationShortcutItem

@interface SBSApplicationShortcutItem : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy) NSString *localizedTitle;
@property(nonatomic, copy) NSString *localizedSubtitle;
@property(nonatomic, copy) id icon;
@property(nonatomic, copy) NSDictionary *userInfo;

@end

#pragma mark - SBSApplicationService

@interface SBSApplicationService : NSObject

+ (instancetype)sharedInstance;

@end

#pragma mark - SBSApplicationClient

@interface SBSApplicationClient : NSObject

- (void)registerClient;
- (void)unregisterClient;

@end

#pragma mark - SBSHardwareButtonEvent

@interface SBSHardwareButtonEvent : NSObject

// Hardware button event types
+ (void)handleHomeButtonPress;
+ (void)handleVolumeUpButtonPress;
+ (void)handleVolumeDownButtonPress;
+ (void)handleLockButtonPress;

@end

#pragma mark - SBSAccelerometer

@interface SBSAccelerometer : NSObject

+ (instancetype)sharedInstance;

- (void)startMonitoring;
- (void)stopMonitoring;

@end

#pragma mark - SBSAssertion

@interface SBSAssertion : NSObject

- (instancetype)initWithAssertionType:(NSString *)type
                           identifier:(NSString *)identifier;
- (void)invalidate;

@end

#pragma mark - SBSBiometricsService

@interface SBSBiometricsService : NSObject

+ (instancetype)sharedInstance;

- (void)simulateFingerTouch:(BOOL)touch;

@end

#pragma mark - SBSCardItem

@interface SBSCardItem : NSObject

@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;

@end

#pragma mark - SBSAppSwitcherSystemService

@interface SBSAppSwitcherSystemService : NSObject

+ (instancetype)sharedInstance;

- (void)enableAppSwitcher;
- (void)disableAppSwitcher;
- (BOOL)isAppSwitcherEnabled;

@end

#pragma mark - SBSApplicationMultiwindowService

@interface SBSApplicationMultiwindowService : NSObject

+ (instancetype)sharedInstance;

- (BOOL)applicationSupportsMultiwindow:(NSString *)bundleIdentifier;

@end

#pragma mark - Helper Functions

#ifdef __cplusplus
extern "C" {
#endif

// Check if SpringBoard is active
BOOL SBSIsSpringBoardActive(void);

// Get frontmost application bundle ID
NSString *SBSGetFrontmostApplicationIdentifier(void);

// Suspend/Resume applications
void SBSSuspendFrontmostApplication(void);
void SBSResumeApplicationWithIdentifier(NSString *bundleIdentifier);

#ifdef __cplusplus
}
#endif

#pragma mark - Notifications

// SpringBoard notifications you can observe
#define SBSApplicationDidLaunchNotification             @"SBSApplicationDidLaunchNotification"
#define SBSApplicationDidTerminateNotification          @"SBSApplicationDidTerminateNotification"
#define SBSFrontmostApplicationChangedNotification      @"SBSFrontmostApplicationChangedNotification"

#endif /* SPRINGBOARDSERVICES_H */
