//
//  KimiRunLockscreen.h
//  KimiRun - Lock Screen Control Module
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KimiRunLockscreen : NSObject

/**
 * Apply lock screen state based on preferences/environment.
 */
+ (void)applyLockscreenState;

/**
 * Start periodic unlock guard (auto-unlock if lockscreen reappears).
 */
+ (void)startUnlockGuard;

/**
 * Register for preference change notifications.
 */
+ (void)registerPreferenceObserver;

/**
 * Whether lockscreen should be disabled.
 */
+ (BOOL)disableLockscreenEnabled;

@end

NS_ASSUME_NONNULL_END
