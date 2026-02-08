#import "TouchInjectionInternal.h"
#import <stdlib.h>
#import <sys/sysctl.h>
#import <unistd.h>

volatile BOOL g_bksLastMeaningfulDispatch = NO;
volatile CFAbsoluteTime g_bksLastMeaningfulDispatchTime = 0;
volatile CFAbsoluteTime g_bksLastFocusHintTime = 0;
static NSDictionary *g_bksLastDispatchInfo = nil;
static NSMutableArray<NSDictionary *> *g_bksDispatchHistory = nil;
static const NSUInteger kKimiRunBKSDispatchHistoryLimit = 64;

static void KimiRunSetLastBKSDispatchInfo(NSDictionary *info) {
    NSDictionary *safeInfo = [info isKindOfClass:[NSDictionary class]] ? [info copy] : @{};
    @synchronized([KimiRunTouchInjection class]) {
        g_bksLastDispatchInfo = safeInfo;
        if (!g_bksDispatchHistory) {
            g_bksDispatchHistory = [NSMutableArray array];
        }
        [g_bksDispatchHistory addObject:safeInfo];
        if (g_bksDispatchHistory.count > kKimiRunBKSDispatchHistoryLimit) {
            NSRange trimRange = NSMakeRange(0, g_bksDispatchHistory.count - kKimiRunBKSDispatchHistoryLimit);
            [g_bksDispatchHistory removeObjectsInRange:trimRange];
        }
    }
}

static void KimiRunSetBKSDispatchFailureInfo(NSString *reason) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"ok"] = @NO;
    info[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    if ([reason isKindOfClass:[NSString class]] && reason.length > 0) {
        info[@"reason"] = reason;
    } else {
        info[@"reason"] = @"unknown";
    }
    KimiRunSetLastBKSDispatchInfo(info);
}

NSDictionary *KimiRunCopyLastBKSDispatchInfo(void) {
    @synchronized([KimiRunTouchInjection class]) {
        return [g_bksLastDispatchInfo copy];
    }
}

NSArray<NSDictionary *> *KimiRunCopyRecentBKSDispatchHistory(NSUInteger limit) {
    @synchronized([KimiRunTouchInjection class]) {
        if (!g_bksDispatchHistory || g_bksDispatchHistory.count == 0) {
            return @[];
        }
        NSUInteger count = g_bksDispatchHistory.count;
        if (limit == 0 || limit >= count) {
            return [g_bksDispatchHistory copy];
        }
        NSRange tailRange = NSMakeRange(count - limit, limit);
        return [[g_bksDispatchHistory subarrayWithRange:tailRange] copy];
    }
}

void KimiRunResolveBKSManagers(void) {
    SEL sharedSel = @selector(sharedInstance);

    if (!g_bksDeliveryManagerClass) {
        g_bksDeliveryManagerClass = NSClassFromString(@"BKSHIDEventDeliveryManager");
    }

    Class routerManagerClass = NSClassFromString(@"BKSHIDEventRouterManager");
    if (!g_bksSharedRouterManager && routerManagerClass && [routerManagerClass respondsToSelector:sharedSel]) {
        g_bksSharedRouterManager = ((id (*)(id, SEL))objc_msgSend)(routerManagerClass, sharedSel);
    }

    if (!g_bksSharedDeliveryManager &&
        g_bksDeliveryManagerClass &&
        [g_bksDeliveryManagerClass respondsToSelector:sharedSel]) {
        g_bksSharedDeliveryManager = ((id (*)(id, SEL))objc_msgSend)(g_bksDeliveryManagerClass, sharedSel);
    }

    if (!g_bksSharedDeliveryManager && g_bksSharedRouterManager) {
        @try {
            id delivery = [g_bksSharedRouterManager valueForKey:@"_deliveryManager"];
            if (delivery) {
                g_bksSharedDeliveryManager = delivery;
                g_bksDeliveryManagerClass = [delivery class];
            }
        } @catch (NSException *e) {
            // Best effort only.
        }
    }

    if (!g_bksSharedDeliveryManager && g_bksDeliveryManagerClass) {
        @try {
            id instance = [[g_bksDeliveryManagerClass alloc] init];
            if (instance) {
                g_bksSharedDeliveryManager = instance;
            }
        } @catch (NSException *e) {
            // Best effort only.
        }
    }
}


void KimiRunRecordBKSDispatchInfo(NSDictionary *info) {
    KimiRunSetLastBKSDispatchInfo(info);
}

void KimiRunRecordBKSDispatchFailure(NSString *reason) {
    KimiRunSetBKSDispatchFailureInfo(reason);
}

static void LogSelectorsForClass(Class cls, const char *tag) {
    if (!cls || !tag) {
        return;
    }
    NSString *logPath = @"/var/mobile/Library/Preferences/kimirun_bkhid_selectors.txt";
    void (^appendLine)(NSString *) = ^(NSString *line) {
        if (!line) {
            return;
        }
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (!fh) {
                [line stringByAppendingString:@"\n"];
                [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                return;
            }
            [fh seekToEndOfFile];
            NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
            if (data) {
                [fh writeData:data];
            }
            [fh closeFile];
        } @catch (NSException *e) {
            // Best effort only
        }
    };

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSLog(@"[KimiRunTouchInjection] %s instance methods (%u)", tag, count);
    appendLine([NSString stringWithFormat:@"%s instance methods (%u)", tag, count]);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (sel) {
            NSLog(@"[KimiRunTouchInjection] %s - %@", tag, NSStringFromSelector(sel));
            appendLine([NSString stringWithFormat:@"%s - %@", tag, NSStringFromSelector(sel)]);
        }
    }
    if (methods) {
        free(methods);
    }

    Class meta = object_getClass((id)cls);
    if (!meta) {
        return;
    }
    count = 0;
    methods = class_copyMethodList(meta, &count);
    NSLog(@"[KimiRunTouchInjection] %s class methods (%u)", tag, count);
    appendLine([NSString stringWithFormat:@"%s class methods (%u)", tag, count]);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (sel) {
            NSLog(@"[KimiRunTouchInjection] %s + %@", tag, NSStringFromSelector(sel));
            appendLine([NSString stringWithFormat:@"%s + %@", tag, NSStringFromSelector(sel)]);
        }
    }
    if (methods) {
        free(methods);
    }
}

void UpdateHIDConnection(void) {
    if (g_hidConnection) {
        return;
    }
    @try {
        // Path 1: BKAccessibility -> eventRoutingClientConnectionManager
        Class bkAccClass = NSClassFromString(@"BKAccessibility");
        id mgr = nil;
        if (bkAccClass && [bkAccClass respondsToSelector:@selector(_eventRoutingClientConnectionManager)]) {
            mgr = ((id (*)(id, SEL))objc_msgSend)(bkAccClass, @selector(_eventRoutingClientConnectionManager));
        }
        if (mgr && [mgr respondsToSelector:@selector(clientForTaskPort:)]) {
            g_hidConnection = [mgr clientForTaskPort:mach_task_self()];
            NSLog(@"[KimiRunTouchInjection] HID connection from BKAccessibility: %p", g_hidConnection);
        }

        if (g_hidConnection) {
            return;
        }

        // Path 2: BKHIDClientConnectionManager singleton
        Class mgrClass = NSClassFromString(@"BKHIDClientConnectionManager");
        if (mgrClass) {
            if (!g_loggedBKHIDSelectors) {
                g_loggedBKHIDSelectors = YES;
                LogSelectorsForClass(mgrClass, "BKHIDClientConnectionManager");
            }
            id manager = nil;
            NSString *managerSource = nil;
            if ([mgrClass respondsToSelector:@selector(sharedInstance)]) {
                manager = [mgrClass sharedInstance];
                managerSource = @"sharedInstance";
            }
            if (!manager && [mgrClass respondsToSelector:@selector(sharedManager)]) {
                manager = [mgrClass sharedManager];
                managerSource = @"sharedManager";
            }
            if (!manager && [mgrClass respondsToSelector:@selector(defaultManager)]) {
                manager = [mgrClass defaultManager];
                managerSource = @"defaultManager";
            }
            if (!manager && [mgrClass respondsToSelector:@selector(manager)]) {
                manager = [mgrClass manager];
                managerSource = @"manager";
            }
            if (manager && [manager respondsToSelector:@selector(clientForTaskPort:)]) {
                g_hidConnection = [manager clientForTaskPort:mach_task_self()];
                if (g_hidConnection) {
                    NSLog(@"[KimiRunTouchInjection] HID connection from BKHIDClientConnectionManager(%@): %p",
                          managerSource ?: @"(unknown)", g_hidConnection);
                }
            }
        } else if (!g_loggedBKHIDSelectors) {
            g_loggedBKHIDSelectors = YES;
            NSLog(@"[KimiRunTouchInjection] BKHIDClientConnectionManager class not found at runtime");
            NSString *path = @"/var/mobile/Library/Preferences/kimirun_bkhid_selectors.txt";
            [@"BKHIDClientConnectionManager class not found at runtime\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {
        // Best effort only
    }
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KimiRunTouchInjection (BKSRouting)

+ (void)logBKHIDSelectorsNow {
    NSArray<NSString *> *candidateClasses = @[
        @"BKHIDClientConnectionManager",
        @"BKSHIDEventDeliveryManager",
        @"BKSHIDEventRouterManager",
        @"BKAccessibility"
    ];

    BOOL loggedAny = NO;
    for (NSString *name in candidateClasses) {
        Class cls = NSClassFromString(name);
        if (!cls) {
            KimiRunLog([NSString stringWithFormat:@"[BKHID] %@ class not found at runtime", name]);
            continue;
        }
        loggedAny = YES;
        LogSelectorsForClass(cls, [name UTF8String]);
    }

    @try {
        Class bkAccClass = NSClassFromString(@"BKAccessibility");
        if (bkAccClass && [bkAccClass respondsToSelector:@selector(_eventRoutingClientConnectionManager)]) {
            id manager = ((id (*)(id, SEL))objc_msgSend)(bkAccClass, @selector(_eventRoutingClientConnectionManager));
            if (manager) {
                loggedAny = YES;
                NSString *managerClassName = NSStringFromClass([manager class]) ?: @"(unknown)";
                KimiRunLog([NSString stringWithFormat:@"[BKHID] BKAccessibility manager instance class=%@", managerClassName]);
                LogSelectorsForClass([manager class], [managerClassName UTF8String]);
            } else {
                KimiRunLog(@"[BKHID] BKAccessibility returned nil manager");
            }
        }
    } @catch (NSException *e) {
        KimiRunLog([NSString stringWithFormat:@"[BKHID] exception while probing BKAccessibility manager: %@", e]);
    }

    if (!loggedAny) {
        KimiRunLog(@"[BKHID] no candidate HID classes available at runtime");
    }
}

+ (NSString *)bkhidSelectorsLogPath {
    return @"/var/mobile/Library/Preferences/kimirun_bkhid_selectors.txt";
}

@end
#pragma clang diagnostic pop
