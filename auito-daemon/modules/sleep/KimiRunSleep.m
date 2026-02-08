//
//  KimiRunSleep.m
//  KimiRun - Prevent Sleep Module
//

#import "KimiRunSleep.h"
#import <UIKit/UIKit.h>

static NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";

static BOOL KimiRunIsSpringBoard(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

static BOOL KimiRunPrefBool(NSString *key, BOOL defaultValue) {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs objectForKey:key];
    if (!value) {
        return defaultValue;
    }
    return [prefs boolForKey:key];
}

static BOOL KimiRunDisableLockscreenEnabled(void) {
    BOOL enabled = KimiRunPrefBool(@"DisableLockScreen", NO);
    const char *env = getenv("KIMIRUN_DISABLE_LOCKSCREEN");
    if (env && env[0] != '\0') {
        enabled = (env[0] == '1');
    }
    return enabled;
}

static BOOL KimiRunAllowSleepEnabled(void) {
    BOOL enabled = KimiRunPrefBool(@"AllowSleep", NO);
    const char *env = getenv("KIMIRUN_ALLOW_SLEEP");
    if (env && env[0] != '\0') {
        enabled = (env[0] == '1');
    }
    return enabled;
}

static BOOL KimiRunBlockSideButtonSleepEnabled(void) {
    BOOL enabled = KimiRunPrefBool(@"BlockSideButtonSleep", KimiRunPrefBool(@"PreventSleep", NO));
    const char *env = getenv("KIMIRUN_BLOCK_SIDE_BUTTON_SLEEP");
    if (env && env[0] != '\0') {
        enabled = (env[0] == '1');
    }
    return enabled;
}

static BOOL KimiRunPreventSleepEnabledInternal(void) {
    BOOL enabled = KimiRunPrefBool(@"PreventSleep", NO);
    const char *env = getenv("KIMIRUN_PREVENT_SLEEP");
    if (env && env[0] != '\0') {
        enabled = (env[0] == '1');
    }
    if (KimiRunDisableLockscreenEnabled() || KimiRunBlockSideButtonSleepEnabled()) {
        enabled = YES;
    }
    if (KimiRunAllowSleepEnabled()) {
        enabled = NO;
    }
    return enabled;
}

static void KimiRunSleepPrefsChanged(__unused CFNotificationCenterRef center,
                                     __unused void *observer,
                                     __unused CFStringRef name,
                                     __unused const void *object,
                                     __unused CFDictionaryRef userInfo) {
    [KimiRunSleep applyPreventSleep];
}

@implementation KimiRunSleep

+ (BOOL)preventSleepEnabled {
    return KimiRunPreventSleepEnabledInternal();
}

+ (BOOL)blockSideButtonSleepEnabled {
    if (KimiRunAllowSleepEnabled()) {
        return NO;
    }
    return KimiRunBlockSideButtonSleepEnabled();
}

+ (void)applyPreventSleep {
    if (!KimiRunIsSpringBoard()) {
        return;
    }
    BOOL prevent = KimiRunPreventSleepEnabledInternal();
    [UIApplication sharedApplication].idleTimerDisabled = prevent;
    if (prevent) {
        NSLog(@"[KimiRunSleep] Prevent sleep enabled (idleTimerDisabled=YES)");
    } else {
        NSLog(@"[KimiRunSleep] Prevent sleep disabled (idleTimerDisabled=NO)");
    }
}

+ (void)registerPreferenceObserver {
    if (!KimiRunIsSpringBoard()) {
        return;
    }
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)KimiRunSleepPrefsChanged,
        CFSTR("com.auito.daemon/prefsChanged"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    NSLog(@"[KimiRunSleep] Registered preference change observer");
}

@end
