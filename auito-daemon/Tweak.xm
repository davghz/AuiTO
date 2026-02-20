//
// KimiRun - Modular Tweak
// HTTP Server + Socket Server + Touch Injection
//

#import <Foundation/Foundation.h>
#import "modules/http_server/KimiRunHTTPServer.h"
#import "modules/touch/TouchInjection.h"
#import "modules/socket/SocketTouchServer.h"
#import "modules/lockscreen/KimiRunLockscreen.h"
#import "modules/sleep/KimiRunSleep.h"

static KimiRunHTTPServer *g_httpServer = nil;
static SocketTouchServer *g_socketServer = nil;
static NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";

static BOOL KimiRunEnvBool(const char *key, BOOL defaultValue) {
    if (!key) return defaultValue;
    const char *value = getenv(key);
    if (!value || value[0] == '\0') return defaultValue;
    NSString *lower = [[[NSString stringWithUTF8String:value]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                       lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] ||
        [lower isEqualToString:@"yes"] || [lower isEqualToString:@"on"]) {
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] ||
        [lower isEqualToString:@"no"] || [lower isEqualToString:@"off"]) {
        return NO;
    }
    return defaultValue;
}

static BOOL KimiRunPrefBool(NSString *key, BOOL defaultValue) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return defaultValue;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs objectForKey:key];
    if (!value) return defaultValue;
    return [prefs boolForKey:key];
}

static BOOL KimiRunShouldStartSpringBoardHTTPServer(void) {
    if (KimiRunEnvBool("KIMIRUN_DISABLE_SPRINGBOARD_HTTP", NO)) {
        return NO;
    }
    if (KimiRunPrefBool(@"DisableSpringBoardHTTP", NO)) {
        return NO;
    }
    if (KimiRunEnvBool("KIMIRUN_NONAX_VIA_SPRINGBOARD", NO)) {
        return YES;
    }
    if (KimiRunEnvBool("KIMIRUN_ENABLE_SPRINGBOARD_HTTP", NO)) {
        return YES;
    }
    if (KimiRunPrefBool(@"EnableSpringBoardHTTP", NO)) {
        return YES;
    }
    // Keep SpringBoard HTTP on by default: MCP screenshot + strict touch proxy
    // routes depend on this endpoint.
    return YES;
}

static BOOL KimiRunShouldStartSocketServer(void) {
    if (KimiRunEnvBool("KIMIRUN_ENABLE_SOCKET_SERVER", NO)) {
        return YES;
    }
    return KimiRunPrefBool(@"EnableSocketServer", NO);
}

static BOOL KimiRunShouldStartAppProcessHTTPServer(void) {
    if (KimiRunEnvBool("KIMIRUN_ENABLE_APP_HTTP", NO)) {
        return YES;
    }
    return KimiRunPrefBool(@"EnableAppProcessHTTP", NO);
}

static BOOL KimiRunShouldInitializeSpringBoardTouch(void) {
    if (KimiRunEnvBool("KIMIRUN_ENABLE_SPRINGBOARD_TOUCH", NO)) {
        return YES;
    }
    if (KimiRunPrefBool(@"EnableSpringBoardTouch", NO)) {
        return YES;
    }
    if (KimiRunShouldStartSpringBoardHTTPServer()) {
        return YES;
    }
    if (KimiRunShouldStartSocketServer()) {
        return YES;
    }
    return NO;
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    NSLog(@"[KimiRun] SpringBoard launched, starting servers...");
    
    // Apply lockscreen state and unlock guard
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [KimiRunLockscreen applyLockscreenState];
        [KimiRunLockscreen startUnlockGuard];
        [KimiRunLockscreen registerPreferenceObserver];
        [KimiRunSleep applyPreventSleep];
        [KimiRunSleep registerPreferenceObserver];
    });

    if (KimiRunShouldInitializeSpringBoardTouch()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL touchAvailable = [KimiRunTouchInjection initialize];
            NSLog(@"[KimiRun] Touch injection initialized: %@", touchAvailable ? @"YES" : @"NO");
        });
    } else {
        NSLog(@"[KimiRun] SpringBoard touch injection disabled (EnableSpringBoardTouch=0)");
    }
    
    if (KimiRunShouldStartSpringBoardHTTPServer()) {
        // Optional SpringBoard HTTP server (port 8765).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            g_httpServer = [[KimiRunHTTPServer alloc] init];
            NSError *error = nil;
            
            if ([g_httpServer startOnPort:8765 error:&error]) {
                NSLog(@"[KimiRun] SUCCESS: HTTP server on port 8765");
            } else {
                NSLog(@"[KimiRun] FAILED to start HTTP server: %@", error);
            }
        });
    } else {
        NSLog(@"[KimiRun] SpringBoard HTTP server disabled by default (EnableSpringBoardHTTP=0)");
    }
    
    if (KimiRunShouldStartSocketServer()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSError *error = nil;

            if ([[SocketTouchServer sharedServer] startOnPort:6000 error:&error]) {
                NSLog(@"[KimiRun] SUCCESS: Socket server on port 6000 (ZXTouch compatible)");
            } else {
                NSLog(@"[KimiRun] FAILED to start socket server: %@", error);
            }
        });
    } else {
        NSLog(@"[KimiRun] Socket server disabled (EnableSocketServer=0)");
    }
}

%end

%ctor {
    NSLog(@"[KimiRun] Tweak loaded - v2 with socket support");

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
        if (!KimiRunShouldStartAppProcessHTTPServer()) {
            NSLog(@"[KimiRun] Preferences HTTP server disabled (EnableAppProcessHTTP=0)");
            return;
        }
        NSLog(@"[KimiRun] Preferences detected, starting HTTP server on 8766");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            g_httpServer = [[KimiRunHTTPServer alloc] init];
            NSError *error = nil;
            if ([g_httpServer startOnPort:8766 error:&error]) {
                NSLog(@"[KimiRun] SUCCESS: Preferences HTTP server on port 8766");
            } else {
                NSLog(@"[KimiRun] FAILED to start Preferences HTTP server: %@", error);
            }
        });
    } else if ([bundleID isEqualToString:@"com.apple.mobilesafari"]) {
        if (!KimiRunShouldStartAppProcessHTTPServer()) {
            NSLog(@"[KimiRun] MobileSafari HTTP server disabled (EnableAppProcessHTTP=0)");
            return;
        }
        NSLog(@"[KimiRun] MobileSafari detected, starting HTTP server on 8767");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            g_httpServer = [[KimiRunHTTPServer alloc] init];
            NSError *error = nil;
            if ([g_httpServer startOnPort:8767 error:&error]) {
                NSLog(@"[KimiRun] SUCCESS: MobileSafari HTTP server on port 8767");
            } else {
                NSLog(@"[KimiRun] FAILED to start MobileSafari HTTP server: %@", error);
            }
        });
    }
}
