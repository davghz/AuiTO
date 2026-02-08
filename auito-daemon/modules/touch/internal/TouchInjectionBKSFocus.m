#import "TouchInjectionInternal.h"
#import <stdlib.h>
#import <sys/sysctl.h>
#import <unistd.h>

int KimiRunPIDForProcessName(NSString *processName) {
    if (![processName isKindOfClass:[NSString class]] || processName.length == 0) {
        return -1;
    }

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) {
        return -1;
    }

    struct kinfo_proc *processes = malloc(size);
    if (!processes) {
        return -1;
    }
    int pid = -1;
    if (sysctl(mib, 4, processes, &size, NULL, 0) == 0) {
        size_t count = size / sizeof(struct kinfo_proc);
        const char *target = processName.UTF8String;
        for (size_t i = 0; i < count; i++) {
            const char *comm = processes[i].kp_proc.p_comm;
            if (comm && strcmp(comm, target) == 0) {
                pid = processes[i].kp_proc.p_pid;
                break;
            }
        }
    }
    free(processes);
    return pid;
}

static int KimiRunPIDFromApplicationObject(id appObject) {
    if (!appObject) {
        return -1;
    }
    SEL pidSel = @selector(pid);
    SEL processIDSel = @selector(processID);
    SEL underscorePidSel = @selector(_pid);
    if ([appObject respondsToSelector:pidSel]) {
        return ((int (*)(id, SEL))objc_msgSend)(appObject, pidSel);
    }
    if ([appObject respondsToSelector:processIDSel]) {
        return ((int (*)(id, SEL))objc_msgSend)(appObject, processIDSel);
    }
    if ([appObject respondsToSelector:underscorePidSel]) {
        return ((int (*)(id, SEL))objc_msgSend)(appObject, underscorePidSel);
    }
    return -1;
}

int KimiRunFrontmostApplicationPID(void) {
    Class focusManagerClass = NSClassFromString(@"BKSEventFocusManager");
    if (!focusManagerClass || ![focusManagerClass respondsToSelector:@selector(sharedInstance)]) {
        return -1;
    }
    BKSEventFocusManager *focusManager = [focusManagerClass sharedInstance];
    if (!focusManager) {
        return -1;
    }

    if ([focusManager respondsToSelector:@selector(foregroundApplicationProcessIDOnMainDisplay)]) {
        int pid = [focusManager foregroundApplicationProcessIDOnMainDisplay];
        if (pid > 0) {
            return pid;
        }
    }
    if ([focusManager respondsToSelector:@selector(foregroundAppPIDOnMainDisplay)]) {
        int pid = [focusManager foregroundAppPIDOnMainDisplay];
        if (pid > 0) {
            return pid;
        }
    }
    if ([focusManager respondsToSelector:@selector(foregroundAppPID)]) {
        int pid = [focusManager foregroundAppPID];
        if (pid > 0) {
            return pid;
        }
    }
    if ([focusManager respondsToSelector:@selector(activeApplicationPID)]) {
        int pid = [focusManager activeApplicationPID];
        if (pid > 0) {
            return pid;
        }
    }
    if ([focusManager respondsToSelector:@selector(activeApplicationProcessID)]) {
        int pid = [focusManager activeApplicationProcessID];
        if (pid > 0) {
            return pid;
        }
    }

    if ([focusManager respondsToSelector:@selector(foregroundApplicationOnMainDisplay)]) {
        int pid = KimiRunPIDFromApplicationObject([focusManager foregroundApplicationOnMainDisplay]);
        if (pid > 0) {
            return pid;
        }
    }
    if ([focusManager respondsToSelector:@selector(foregroundApplication)]) {
        int pid = KimiRunPIDFromApplicationObject([focusManager foregroundApplication]);
        if (pid > 0) {
            return pid;
        }
    }

    return -1;
}

BOOL KimiRunApplyBKSSystemAppFocus(BOOL controlsFocus, NSString *phaseTag) {
    Class focusManagerClass = NSClassFromString(@"BKSEventFocusManager");
    if (!focusManagerClass || ![focusManagerClass respondsToSelector:@selector(sharedInstance)]) {
        return NO;
    }

    BKSEventFocusManager *focusManager = [focusManagerClass sharedInstance];
    if (!focusManager) {
        return NO;
    }

    if (![focusManager respondsToSelector:@selector(setSystemAppControlsFocusOnMainDisplay:)]) {
        return NO;
    }

    @try {
        [focusManager setSystemAppControlsFocusOnMainDisplay:controlsFocus];
        if ([focusManager respondsToSelector:@selector(flush)]) {
            [focusManager flush];
        }
        KimiRunLog([NSString stringWithFormat:@"[BKS] %@ systemAppControlsFocus=%@",
                    phaseTag ?: @"focus",
                    controlsFocus ? @"YES" : @"NO"]);
        return YES;
    } @catch (NSException *e) {
        KimiRunLog([NSString stringWithFormat:@"[BKS] %@ system focus exception: %@ reason=%@",
                    phaseTag ?: @"focus",
                    e.name ?: @"(unknown)",
                    e.reason ?: @"(no reason)"]);
        return NO;
    }
}


BOOL KimiRunApplyBKSEventFocusForPID(int targetPid,
                                     NSString *phaseTag,
                                     BOOL setAdjustedPID) {
    Class focusManagerClass = NSClassFromString(@"BKSEventFocusManager");
    if (!focusManagerClass || ![focusManagerClass respondsToSelector:@selector(sharedInstance)]) {
        return NO;
    }

    BKSEventFocusManager *focusManager = [focusManagerClass sharedInstance];
    if (!focusManager) {
        return NO;
    }

    if (targetPid <= 0) {
        targetPid = KimiRunPIDForProcessName(@"Preferences");
        if (targetPid <= 0) {
            targetPid = KimiRunPIDForProcessName(@"SpringBoard");
        }
    }
    if (targetPid <= 0) {
        return NO;
    }

    BOOL applied = NO;
    @try {
        if ([focusManager respondsToSelector:@selector(setSystemAppControlsFocusOnMainDisplay:)]) {
            [focusManager setSystemAppControlsFocusOnMainDisplay:NO];
        }

        id foregroundObject = nil;
        if ([focusManager respondsToSelector:@selector(foregroundApplicationOnMainDisplay)]) {
            foregroundObject = [focusManager foregroundApplicationOnMainDisplay];
        }
        if (!foregroundObject && [focusManager respondsToSelector:@selector(foregroundApplication)]) {
            foregroundObject = [focusManager foregroundApplication];
        }
        if (!foregroundObject) {
            foregroundObject = @"com.apple.Preferences";
        }

        if ([focusManager respondsToSelector:@selector(setForegroundApplicationOnMainDisplay:pid:)]) {
            [focusManager setForegroundApplicationOnMainDisplay:foregroundObject pid:targetPid];
            applied = YES;
        }

        if (setAdjustedPID) {
            @try {
                [focusManager setValue:@YES forKey:@"_focusDataLock_adjustsFocusTargetPID"];
                [focusManager setValue:@(targetPid) forKey:@"_focusDataLock_adjustedFocusTargetPID"];
            } @catch (NSException *e) {
                KimiRunLog([NSString stringWithFormat:@"[BKS] %@ adjusted PID KVC failed: %@ reason=%@",
                            phaseTag ?: @"focus",
                            e.name ?: @"(unknown)",
                            e.reason ?: @"(no reason)"]);
            }
        }

        if ([focusManager respondsToSelector:@selector(flush)]) {
            [focusManager flush];
        }
    } @catch (NSException *e) {
        KimiRunLog([NSString stringWithFormat:@"[BKS] %@ focus pin exception: %@ reason=%@",
                    phaseTag ?: @"focus",
                    e.name ?: @"(unknown)",
                    e.reason ?: @"(no reason)"]);
        return NO;
    }

    if (applied) {
        KimiRunLog([NSString stringWithFormat:@"[BKS] %@ focus pinned pid=%d adjusted=%@",
                    phaseTag ?: @"focus",
                    targetPid,
                    setAdjustedPID ? @"yes" : @"no"]);
    }
    return applied;
}

void KimiRunApplyBKSFocusHints(void) {
    // Focus manager mutations can destabilize daemon context on iOS 13.2.3.
    // Keep disabled unless explicitly enabled for targeted experiments.
    BOOL focusHintsEnabled = KimiRunTouchEnvBool("KIMIRUN_BKS_FOCUS_HINTS",
                                                 KimiRunTouchPrefBool(@"BKSFocusHintsEnabled", NO));
    if (!focusHintsEnabled) {
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ((now - g_bksLastFocusHintTime) < 0.5) {
        return;
    }
    g_bksLastFocusHintTime = now;

    (void)KimiRunApplyBKSEventFocusForPID(-1, @"default_hint", NO);
}

BOOL KimiRunBKSRecentMeaningfulDispatch(NSTimeInterval maxAgeSeconds) {
    if (!g_bksLastMeaningfulDispatch) {
        return NO;
    }
    if (maxAgeSeconds <= 0) {
        maxAgeSeconds = 1.0;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime last = g_bksLastMeaningfulDispatchTime;
    if (last <= 0) {
        return NO;
    }
    return (now - last) <= maxAgeSeconds;
}
