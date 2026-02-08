//
//  KimiRunSleep.h
//  KimiRun - Prevent Sleep Module
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KimiRunSleep : NSObject

/**
 * Whether sleep prevention is enabled.
 */
+ (BOOL)preventSleepEnabled;

/**
 * Whether side-button initiated sleep should be blocked.
 */
+ (BOOL)blockSideButtonSleepEnabled;

/**
 * Apply idle timer settings based on preferences.
 */
+ (void)applyPreventSleep;

/**
 * Register for preference change notifications.
 */
+ (void)registerPreferenceObserver;

@end

NS_ASSUME_NONNULL_END
