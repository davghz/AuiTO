#import "AppLauncher.h"
#import <objc/message.h>
#import <dlfcn.h>

static Class FBSSystemServiceClass = nil;
static id g_systemService = nil;
static Class BKSSystemServiceClass = nil;

static id AppLauncherSystemService(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
        FBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
        if (FBSSystemServiceClass && [FBSSystemServiceClass respondsToSelector:@selector(sharedService)]) {
            g_systemService = [FBSSystemServiceClass performSelector:@selector(sharedService)];
        }
    });
    return g_systemService;
}

static id AppLauncherBKSSystemService(void) {
    static id service = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        BKSSystemServiceClass = NSClassFromString(@"BKSSystemService");
        if (BKSSystemServiceClass) {
            service = [[BKSSystemServiceClass alloc] init];
        }
    });
    return service;
}

static BOOL AppLauncherOpenWithBKS(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) {
        return NO;
    }
    id service = AppLauncherBKSSystemService();
    if (!service) {
        return NO;
    }

    SEL openSel = NSSelectorFromString(@"openApplication:options:withResult:");
    if (![service respondsToSelector:openSel]) {
        return NO;
    }

    __block BOOL callbackFired = NO;
    __block BOOL callbackSuccess = NO;
    void (^resultBlock)(id) = ^(id result) {
        callbackFired = YES;
        if (result == nil || result == [NSNull null]) {
            callbackSuccess = YES;
            return;
        }
        if ([result respondsToSelector:@selector(boolValue)]) {
            callbackSuccess = ((BOOL (*)(id, SEL))objc_msgSend)(result, @selector(boolValue));
            return;
        }
        callbackSuccess = NO;
    };

    NSDictionary *options = @{
        @"SBUserInitiatedLaunchKey": @YES
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, openSel, bundleID, options, resultBlock);

    // Allow the callback to run briefly if the implementation is async.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
    while (!callbackFired && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }

    return callbackFired ? callbackSuccess : YES;
}

@implementation AppLauncher

+ (BOOL)launchAppWithBundleID:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) {
        return NO;
    }

    // Prefer BKS system service when available; this is closer to SpringBoard activation flow.
    if (AppLauncherOpenWithBKS(bundleID)) {
        return YES;
    }

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) {
        NSLog(@"[KimiRunDaemon] LSApplicationWorkspace not found");
        return NO;
    }

    id ws = nil;
    if ([wsClass respondsToSelector:@selector(defaultWorkspace)]) {
        ws = [wsClass performSelector:@selector(defaultWorkspace)];
    }
    if (!ws) {
        NSLog(@"[KimiRunDaemon] defaultWorkspace unavailable");
        return NO;
    }

    SEL sel = @selector(openApplicationWithBundleID:);
    if ([ws respondsToSelector:sel]) {
        BOOL (*msgSend)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
        return msgSend(ws, sel, bundleID);
    }

    SEL sel2 = @selector(openApplicationWithBundleID:options:);
    if ([ws respondsToSelector:sel2]) {
        BOOL (*msgSend2)(id, SEL, NSString *, NSDictionary *) = (BOOL (*)(id, SEL, NSString *, NSDictionary *))objc_msgSend;
        return msgSend2(ws, sel2, bundleID, @{});
    }

    NSLog(@"[KimiRunDaemon] No suitable launch selector on LSApplicationWorkspace");
    return NO;
}

+ (BOOL)terminateAppWithBundleID:(NSString *)bundleID {
    if (!bundleID || bundleID.length == 0) {
        return NO;
    }

    id systemService = AppLauncherSystemService();
    if (!systemService) {
        NSLog(@"[KimiRunDaemon] FBSSystemService unavailable for termination");
        return NO;
    }

    SEL terminateSel = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:completion:");
    if (![systemService respondsToSelector:terminateSel]) {
        NSLog(@"[KimiRunDaemon] FBSSystemService termination selector not found");
        return NO;
    }

    @try {
        NSMethodSignature *sig = [systemService methodSignatureForSelector:terminateSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:systemService];
        [inv setSelector:terminateSel];
        [inv setArgument:&bundleID atIndex:2];

        long long reason = 1; // User initiated
        [inv setArgument:&reason atIndex:3];

        BOOL report = NO;
        [inv setArgument:&report atIndex:4];

        NSString *desc = @"Terminated by KimiRun";
        [inv setArgument:&desc atIndex:5];

        void (^completion)(void) = ^{};
        [inv setArgument:&completion atIndex:6];

        [inv invoke];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[KimiRunDaemon] Terminate error: %@", e);
        return NO;
    }
}

+ (NSArray<NSDictionary *> *)listApplicationsIncludeSystem:(BOOL)includeSystem {
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsClass) {
        NSLog(@"[KimiRunDaemon] LSApplicationWorkspace not found");
        return @[];
    }

    id ws = nil;
    if ([wsClass respondsToSelector:@selector(defaultWorkspace)]) {
        ws = [wsClass performSelector:@selector(defaultWorkspace)];
    }
    if (!ws) {
        NSLog(@"[KimiRunDaemon] defaultWorkspace unavailable");
        return @[];
    }

    SEL allAppsSel = @selector(allApplications);
    SEL allInstalledSel = @selector(allInstalledApplications);
    NSArray *apps = nil;

    if ([ws respondsToSelector:allAppsSel]) {
        apps = ((id (*)(id, SEL))objc_msgSend)(ws, allAppsSel);
    } else if ([ws respondsToSelector:allInstalledSel]) {
        apps = ((id (*)(id, SEL))objc_msgSend)(ws, allInstalledSel);
    }

    if (![apps isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:apps.count];
    for (id proxy in apps) {
        if (!proxy) continue;

        SEL bundleIDSel = @selector(bundleIdentifier);
        SEL nameSel = @selector(localizedName);
        SEL itemNameSel = @selector(itemName);
        SEL typeSel = @selector(applicationType);
        SEL shortVerSel = @selector(shortVersionString);
        SEL bundleVerSel = @selector(bundleVersion);

        NSString *bundleID = nil;
        if ([proxy respondsToSelector:bundleIDSel]) {
            bundleID = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleIDSel);
        }
        if (!bundleID || ![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
            continue;
        }

        NSString *name = nil;
        if ([proxy respondsToSelector:nameSel]) {
            name = ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel);
        }
        if ((!name || ![name isKindOfClass:[NSString class]] || name.length == 0) && [proxy respondsToSelector:itemNameSel]) {
            name = ((id (*)(id, SEL))objc_msgSend)(proxy, itemNameSel);
        }

        NSString *type = nil;
        if ([proxy respondsToSelector:typeSel]) {
            type = ((id (*)(id, SEL))objc_msgSend)(proxy, typeSel);
        }

        NSString *shortVer = nil;
        if ([proxy respondsToSelector:shortVerSel]) {
            shortVer = ((id (*)(id, SEL))objc_msgSend)(proxy, shortVerSel);
        }

        NSString *bundleVer = nil;
        if ([proxy respondsToSelector:bundleVerSel]) {
            bundleVer = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleVerSel);
        }

        BOOL isSystem = NO;
        if ([type isKindOfClass:[NSString class]] && [type length] > 0) {
            isSystem = [type isEqualToString:@"System"];
        } else if ([bundleID hasPrefix:@"com.apple."]) {
            isSystem = YES;
        }

        if (!includeSystem && isSystem) {
            continue;
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"bundleID"] = bundleID;
        if (name && [name isKindOfClass:[NSString class]]) {
            entry[@"name"] = name;
        }
        if (type && [type isKindOfClass:[NSString class]]) {
            entry[@"type"] = type;
        }
        if (shortVer && [shortVer isKindOfClass:[NSString class]]) {
            entry[@"version"] = shortVer;
        }
        if (bundleVer && [bundleVer isKindOfClass:[NSString class]]) {
            entry[@"bundleVersion"] = bundleVer;
        }

        [out addObject:entry];
    }

    return out;
}

@end
