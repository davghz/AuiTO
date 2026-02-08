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

    // Initialize touch injection
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL touchAvailable = [KimiRunTouchInjection initialize];
        NSLog(@"[KimiRun] Touch injection initialized: %@", touchAvailable ? @"YES" : @"NO");
    });
    
    // Start HTTP server (port 8765)
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
    
    // Start Socket server (port 6000 - ZXTouch compatible)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSError *error = nil;
        
        if ([[SocketTouchServer sharedServer] startOnPort:6000 error:&error]) {
            NSLog(@"[KimiRun] SUCCESS: Socket server on port 6000 (ZXTouch compatible)");
        } else {
            NSLog(@"[KimiRun] FAILED to start socket server: %@", error);
        }
    });
}

%end

%ctor {
    NSLog(@"[KimiRun] Tweak loaded - v2 with socket support");

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
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
