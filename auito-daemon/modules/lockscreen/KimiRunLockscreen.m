//
//  KimiRunLockscreen.m
//  KimiRun - Lock Screen Control Module
//

#import "KimiRunLockscreen.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>

@interface SBLockScreenDisableAssertion : NSObject
- (instancetype)initWithIdentifier:(id)identifier;
- (void)invalidate;
@end

@interface SBLockScreenManager : NSObject
+ (id)sharedInstance;
- (void)addLockScreenDisableAssertion:(id)assertion;
- (void)removeLockScreenDisableAssertion:(id)assertion;
- (BOOL)isLockScreenDisabledForAssertion;
@end

static SBLockScreenDisableAssertion *g_lockScreenAssertion = nil;
static dispatch_source_t g_unlockTimer = nil;

static NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";

static void KimiRunLockscreenPrefsChanged(__unused CFNotificationCenterRef center,
                                          __unused void *observer,
                                          __unused CFStringRef name,
                                          __unused const void *object,
                                          __unused CFDictionaryRef userInfo) {
    [KimiRunLockscreen applyLockscreenState];
}

static BOOL KimiRunIsSpringBoard(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

static BOOL KimiRunIsUIApplicationReady(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return NO;
    }
    if (@available(iOS 13.0, *)) {
        if (app.connectedScenes.count == 0) {
            return NO;
        }
    }
    return YES;
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
    BOOL enabled = KimiRunPrefBool(@"DisableLockScreen", YES);
    const char *env = getenv("KIMIRUN_DISABLE_LOCKSCREEN");
    if (env && env[0] != '\0') {
        enabled = (env[0] == '1');
    }
    return enabled;
}

static void KimiRunAttemptUnlockIfNeeded(id manager) {
    if (!manager) {
        return;
    }
    BOOL locked = NO;
    @try {
        SEL isLockedSel = NSSelectorFromString(@"isUILocked");
        if ([manager respondsToSelector:isLockedSel]) {
            BOOL (*msgSendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            locked = msgSendBool(manager, isLockedSel);
        }
        SEL isVisibleSel = NSSelectorFromString(@"isLockScreenVisible");
        if ([manager respondsToSelector:isVisibleSel]) {
            BOOL (*msgSendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            locked = locked || msgSendBool(manager, isVisibleSel);
        }
    } @catch (__unused NSException *e) {
    }
    if (!locked) {
        return;
    }

    @try {
        SEL startSel = NSSelectorFromString(@"startUIUnlockFromSource:withOptions:");
        if ([manager respondsToSelector:startSel]) {
            void (*msgSendStart)(id, SEL, int, id) = (void (*)(id, SEL, int, id))objc_msgSend;
            msgSendStart(manager, startSel, 0, nil);
            NSLog(@"[KimiRunLockscreen] startUIUnlockFromSource:withOptions:");
        }

        SEL unlockSel2 = NSSelectorFromString(@"unlockUIFromSource:withOptions:");
        if ([manager respondsToSelector:unlockSel2]) {
            BOOL (*msgSendUnlock2)(id, SEL, int, id) = (BOOL (*)(id, SEL, int, id))objc_msgSend;
            BOOL ok = msgSendUnlock2(manager, unlockSel2, 0, nil);
            NSLog(@"[KimiRunLockscreen] unlockUIFromSource:withOptions: -> %@", ok ? @"YES" : @"NO");
        }

        SEL unlockSel = NSSelectorFromString(@"unlockUIFromSource:");
        if ([manager respondsToSelector:unlockSel]) {
            BOOL (*msgSendUnlock)(id, SEL, int) = (BOOL (*)(id, SEL, int))objc_msgSend;
            BOOL ok = msgSendUnlock(manager, unlockSel, 0);
            NSLog(@"[KimiRunLockscreen] unlockUIFromSource: -> %@", ok ? @"YES" : @"NO");
        }

        SEL unlockSel3 = NSSelectorFromString(@"_finishUIUnlockFromSource:withOptions:");
        if ([manager respondsToSelector:unlockSel3]) {
            BOOL (*msgSendUnlock3)(id, SEL, int, id) = (BOOL (*)(id, SEL, int, id))objc_msgSend;
            BOOL ok = msgSendUnlock3(manager, unlockSel3, 0, nil);
            NSLog(@"[KimiRunLockscreen] _finishUIUnlockFromSource:withOptions: -> %@", ok ? @"YES" : @"NO");
        }

        SEL legacyFinish = NSSelectorFromString(@"_finishUIUnlockFromSource:");
        if ([manager respondsToSelector:legacyFinish]) {
            void (*msgSendUnlock3b)(id, SEL, int) = (void (*)(id, SEL, int))objc_msgSend;
            msgSendUnlock3b(manager, legacyFinish, 0);
            NSLog(@"[KimiRunLockscreen] _finishUIUnlockFromSource:");
        }

        SEL reqUnlock = NSSelectorFromString(@"lockScreenViewControllerRequestsUnlock");
        if ([manager respondsToSelector:reqUnlock]) {
            void (*msgSendReq)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            msgSendReq(manager, reqUnlock);
            NSLog(@"[KimiRunLockscreen] lockScreenViewControllerRequestsUnlock");
        }
    } @catch (__unused NSException *e) {
    }
}

@implementation KimiRunLockscreen

+ (BOOL)disableLockscreenEnabled {
    return KimiRunDisableLockscreenEnabled();
}

+ (void)applyLockscreenState {
    if (!KimiRunIsSpringBoard()) {
        return;
    }
    if (!KimiRunIsUIApplicationReady()) {
        NSLog(@"[KimiRunLockscreen] UIApplication not ready; skipping update");
        return;
    }

    @try {
        BOOL disableLockscreen = KimiRunDisableLockscreenEnabled();
        SBLockScreenManager *manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if (!manager) {
            NSLog(@"[KimiRunLockscreen] Manager not available yet");
            return;
        }

        if (disableLockscreen && !g_lockScreenAssertion) {
            g_lockScreenAssertion = [[NSClassFromString(@"SBLockScreenDisableAssertion") alloc]
                                     initWithIdentifier:@"KimiRun"];
            [manager addLockScreenDisableAssertion:g_lockScreenAssertion];
            NSLog(@"[KimiRunLockscreen] Lock screen DISABLED via assertion");
            KimiRunAttemptUnlockIfNeeded(manager);
        } else if (!disableLockscreen && g_lockScreenAssertion) {
            [manager removeLockScreenDisableAssertion:g_lockScreenAssertion];
            [g_lockScreenAssertion invalidate];
            g_lockScreenAssertion = nil;
            NSLog(@"[KimiRunLockscreen] Lock screen ENABLED (assertion removed)");
        }
    } @catch (NSException *e) {
        NSLog(@"[KimiRunLockscreen] update failed: %@", e);
    }
}

+ (void)startUnlockGuard {
    if (!KimiRunIsSpringBoard()) {
        return;
    }
    if (g_unlockTimer) {
        return;
    }
    g_unlockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_unlockTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(3.0 * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_unlockTimer, ^{
        if (!KimiRunDisableLockscreenEnabled()) {
            return;
        }
        if (!KimiRunIsUIApplicationReady()) {
            return;
        }
        id manager = [NSClassFromString(@"SBLockScreenManager") sharedInstance];
        if (manager) {
            KimiRunAttemptUnlockIfNeeded(manager);
        }
    });
    dispatch_resume(g_unlockTimer);
    NSLog(@"[KimiRunLockscreen] Unlock guard timer started");
}

+ (void)registerPreferenceObserver {
    if (!KimiRunIsSpringBoard()) {
        return;
    }
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)KimiRunLockscreenPrefsChanged,
        CFSTR("com.auito.daemon/prefsChanged"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    NSLog(@"[KimiRunLockscreen] Registered preference change observer");
}

@end
