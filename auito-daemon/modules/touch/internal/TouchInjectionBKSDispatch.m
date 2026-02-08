#import "TouchInjectionInternal.h"
#import <unistd.h>
#import <limits.h>

static uint64_t KimiRunPreferredBKSSenderID(NSString **sourceOut) {
    uint64_t sender = [KimiRunTouchInjection senderID];
    uint64_t proxySender = [KimiRunTouchInjection proxySenderID];
    BOOL proxyLikelyLive = (proxySender != 0 && [KimiRunTouchInjection proxySenderLikelyLive]);
    if (sender != 0) {
        NSString *localSource = [[KimiRunTouchInjection senderIDSourceString] lowercaseString] ?: @"unknown";
        BOOL localCaptured = [KimiRunTouchInjection senderIDCaptured];
        BOOL localLooksSynthetic = (!localCaptured ||
                                    [localSource isEqualToString:@"override"] ||
                                    [localSource isEqualToString:@"persisted"] ||
                                    [localSource isEqualToString:@"unknown"]);
        if (!(proxyLikelyLive && localLooksSynthetic)) {
            if (sourceOut) {
                *sourceOut = localSource;
            }
            return sender;
        }
    }
    if (proxyLikelyLive) {
        if (sourceOut) {
            *sourceOut = [KimiRunTouchInjection proxySenderSourceString] ?: @"proxy";
        }
        return proxySender;
    }
    if (g_senderFallbackEnabled) {
        if (sourceOut) {
            *sourceOut = @"fallback";
        }
        return kTouchSenderID;
    }
    if (sourceOut) {
        *sourceOut = @"bks-default";
    }
    return kBKSSenderID;
}

static NSString *KimiRunLowerTrimmed(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return trimmed.length > 0 ? trimmed : nil;
}

static NSString *KimiRunBKSEventMode(void) {
    NSString *raw = KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_EVENT_MODE",
                                                @"BKSEventMode",
                                                @"sim_parent");
    NSString *lower = KimiRunLowerTrimmed(raw);
    if ([lower isEqualToString:@"legacy"] || [lower isEqualToString:@"legacy_hand"]) {
        return @"legacy_hand";
    }
    return @"sim_parent";
}

static BKSHIDEventDiscreteDispatchingPredicate *
KimiRunCreateDispatchPredicate(id descriptor, BOOL useSourceDescriptor)
{
    if (!descriptor) {
        return nil;
    }

    NSSet *descriptors = [NSSet setWithObject:descriptor];
    NSSet *sourceDescriptors = useSourceDescriptor ? [NSSet setWithObject:descriptor] : nil;

    // Prefer typed mutable API from BackBoardServices headers.
    BKSMutableHIDEventDiscreteDispatchingPredicate *mutablePredicate =
        [[BKSMutableHIDEventDiscreteDispatchingPredicate alloc] init];
    if (mutablePredicate) {
        mutablePredicate.descriptors = descriptors;
        if (sourceDescriptors) {
            mutablePredicate.senderDescriptors = sourceDescriptors;
        }
        return mutablePredicate;
    }

    // Fallback to private initializer path when mutable class is unavailable.
    BKSHIDEventDiscreteDispatchingPredicate *predicate =
        [[BKSHIDEventDiscreteDispatchingPredicate alloc] init];
    if (!predicate) {
        return nil;
    }
    if ([predicate respondsToSelector:@selector(_initWithSourceDescriptors:descriptors:)]) {
        return [predicate _initWithSourceDescriptors:sourceDescriptors
                                         descriptors:descriptors];
    }
    return nil;
}

static void KimiRunBKSAddTargetCandidate(NSMutableArray<NSDictionary *> *candidates,
                                          NSMutableSet<NSValue *> *seenTargets,
                                          id target,
                                          NSString *source,
                                          NSNumber *destination)
{
    if (!target || !source || source.length == 0) {
        return;
    }
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)target];
    if ([seenTargets containsObject:key]) {
        return;
    }
    [seenTargets addObject:key];
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                  target, @"target",
                                  source, @"source",
                                  nil];
    if (destination) {
        entry[@"destination"] = destination;
    }
    [candidates addObject:entry];
}

static int KimiRunBKSTargetPID(id target) {
    SEL pidSel = @selector(pid);
    if (!target || ![target respondsToSelector:pidSel]) {
        return -1;
    }
    return ((int (*)(id, SEL))objc_msgSend)(target, pidSel);
}

static int KimiRunForcedTargetPIDForProcess(NSString *processName,
                                            int frontmostPid,
                                            int springboardPid,
                                            int backboarddPid)
{
    NSString *process = KimiRunLowerTrimmed(processName);
    if (!process) {
        return -1;
    }
    if ([process isEqualToString:@"frontmost"]) {
        return frontmostPid;
    }
    if ([process isEqualToString:@"preferences"]) {
        return KimiRunPIDForProcessName(@"Preferences");
    }
    if ([process isEqualToString:@"springboard"]) {
        return springboardPid;
    }
    if ([process isEqualToString:@"backboardd"]) {
        return backboarddPid;
    }
    return -1;
}

static NSInteger KimiRunBKSTargetPreferenceScore(NSString *source,
                                                 int targetPid,
                                                 int frontmostPid,
                                                 int springboardPid,
                                                 int backboarddPid)
{
    NSInteger score = 0;
    if ([source hasPrefix:@"targetForPIDEnvironmentFrontmost"]) {
        score += 140;
    }
    if ([source hasPrefix:@"targetForPIDEnvironmentPreferences"]) {
        score += 70;
    }
    if ([source hasPrefix:@"targetForPIDEnvironment"]) {
        score += 50;
    }
    if ([source hasPrefix:@"targetForDeferringEnvironment"]) {
        score += 35;
    }
    if ([source isEqualToString:@"focusTargetForPIDFrontmost"]) {
        score += 100;
    }
    if (targetPid > 0 && frontmostPid > 0 && targetPid == frontmostPid) {
        score += 100;
    }
    if ([source isEqualToString:@"focusTargetForPIDPreferences"]) {
        score += 40;
    }
    if ([source isEqualToString:@"routerDestination"] || [source isEqualToString:@"manualDestination"]) {
        score += 20;
    }
    if (targetPid > 0 && springboardPid > 0 && targetPid == springboardPid) {
        score -= 20;
    }
    if (targetPid > 0 && backboarddPid > 0 && targetPid == backboarddPid) {
        score -= 30;
    }
    return score;
}

static NSArray<NSDictionary *> *KimiRunBKSBuildTargetCandidates(Class targetClass,
                                                                 id routerManager,
                                                                 Class routerClass)
{
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSValue *> *seenTargets = [NSMutableSet set];

    SEL keyboardFocusTargetSel = @selector(keyboardFocusTarget);
    SEL systemTargetSel = @selector(systemTarget);
    SEL focusTargetForPIDSel = @selector(focusTargetForPID:);
    SEL targetForPIDEnvironmentSel = @selector(targetForPID:environment:);
    SEL targetForDeferringEnvironmentSel = @selector(targetForDeferringEnvironment:);
    SEL targetForDestinationSel = @selector(_targetForDestination:);
    SEL eventRoutersSel = @selector(eventRouters);
    SEL defaultRoutersSel = @selector(defaultEventRouters);
    SEL destinationSel = @selector(destination);
    SEL environmentSel = @selector(environment);

    NSMutableArray *environmentCandidates = [NSMutableArray array];
    NSMutableSet<NSValue *> *seenEnvironments = [NSMutableSet set];
    void (^addEnvironmentCandidate)(id) = ^(id environment) {
        if (!environment) {
            return;
        }
        NSValue *environmentKey = [NSValue valueWithPointer:(__bridge const void *)environment];
        if ([seenEnvironments containsObject:environmentKey]) {
            return;
        }
        [seenEnvironments addObject:environmentKey];
        [environmentCandidates addObject:environment];
    };

    if (routerManager) {
        if ([routerManager respondsToSelector:environmentSel]) {
            id environment = ((id (*)(id, SEL))objc_msgSend)(routerManager, environmentSel);
            addEnvironmentCandidate(environment);
        }
        @try {
            addEnvironmentCandidate([routerManager valueForKey:@"_environment"]);
            addEnvironmentCandidate([routerManager valueForKey:@"environment"]);
            addEnvironmentCandidate([routerManager valueForKey:@"eventEnvironment"]);
        } @catch (NSException *e) {
            // Optional KVC probing only.
        }
    }

    if ([targetClass respondsToSelector:keyboardFocusTargetSel]) {
        id target = ((id (*)(id, SEL))objc_msgSend)(targetClass, keyboardFocusTargetSel);
        KimiRunBKSAddTargetCandidate(candidates, seenTargets, target, @"keyboardFocusTarget", nil);
    }
    if ([targetClass respondsToSelector:focusTargetForPIDSel]) {
        NSMutableArray<NSNumber *> *pidCandidates = [NSMutableArray array];
        NSMutableArray<NSString *> *sourceCandidates = [NSMutableArray array];
        void (^appendPID)(int, NSString *) = ^(int pid, NSString *source) {
            if (pid <= 0 || ![source isKindOfClass:[NSString class]] || source.length == 0) {
                return;
            }
            if ([pidCandidates containsObject:@(pid)]) {
                return;
            }
            [pidCandidates addObject:@(pid)];
            [sourceCandidates addObject:source];
        };

        appendPID(KimiRunFrontmostApplicationPID(), @"focusTargetForPIDFrontmost");
        appendPID((int)getpid(), @"focusTargetForPIDSelf");
        appendPID(KimiRunPIDForProcessName(@"Preferences"), @"focusTargetForPIDPreferences");
        appendPID(KimiRunPIDForProcessName(@"SpringBoard"), @"focusTargetForPIDSpringBoard");
        appendPID(KimiRunPIDForProcessName(@"backboardd"), @"focusTargetForPIDBackboardd");

        for (NSUInteger i = 0; i < pidCandidates.count && i < sourceCandidates.count; i++) {
            int pid = [pidCandidates[i] intValue];
            NSString *source = sourceCandidates[i];
            id target = ((id (*)(id, SEL, int))objc_msgSend)(targetClass, focusTargetForPIDSel, pid);
            KimiRunBKSAddTargetCandidate(candidates, seenTargets, target, source, @(pid));

            if ([targetClass respondsToSelector:targetForPIDEnvironmentSel] && environmentCandidates.count > 0) {
                NSString *envSource = [NSString stringWithFormat:@"targetForPIDEnvironment%@",
                                       [source hasPrefix:@"focusTargetForPID"] ? [source substringFromIndex:[@"focusTargetForPID" length]] : @""];
                for (id environment in environmentCandidates) {
                    id environmentTarget = ((id (*)(id, SEL, int, id))objc_msgSend)(targetClass,
                                                                                      targetForPIDEnvironmentSel,
                                                                                      pid,
                                                                                      environment);
                    KimiRunBKSAddTargetCandidate(candidates, seenTargets, environmentTarget, envSource, @(pid));
                }
            }
        }
    }

    if (routerManager && [routerManager respondsToSelector:targetForDestinationSel]) {
        id routers = nil;
        if ([routerManager respondsToSelector:eventRoutersSel]) {
            routers = ((id (*)(id, SEL))objc_msgSend)(routerManager, eventRoutersSel);
        }
        if ((!routers || ![routers isKindOfClass:[NSArray class]] || [(NSArray *)routers count] == 0) &&
            routerClass && [routerClass respondsToSelector:defaultRoutersSel]) {
            routers = ((id (*)(id, SEL))objc_msgSend)(routerClass, defaultRoutersSel);
        }
        if ([routers isKindOfClass:[NSArray class]]) {
            for (id router in (NSArray *)routers) {
                if (!router || ![router respondsToSelector:destinationSel]) {
                    continue;
                }
                if ([router respondsToSelector:environmentSel]) {
                    id environment = ((id (*)(id, SEL))objc_msgSend)(router, environmentSel);
                    addEnvironmentCandidate(environment);
                }
                long long destination = ((long long (*)(id, SEL))objc_msgSend)(router, destinationSel);
                id target = ((id (*)(id, SEL, long long))objc_msgSend)(routerManager, targetForDestinationSel, destination);
                KimiRunBKSAddTargetCandidate(candidates, seenTargets, target, @"routerDestination", @(destination));
            }
        }

        // Probe known destination slots directly; router list may omit active runtime destination.
        for (long long destination = 0; destination <= 6; destination++) {
            id target = ((id (*)(id, SEL, long long))objc_msgSend)(routerManager, targetForDestinationSel, destination);
            KimiRunBKSAddTargetCandidate(candidates, seenTargets, target, @"manualDestination", @(destination));
        }
    }

    if ([targetClass respondsToSelector:targetForDeferringEnvironmentSel] && environmentCandidates.count > 0) {
        for (id environment in environmentCandidates) {
            id target = ((id (*)(id, SEL, id))objc_msgSend)(targetClass,
                                                             targetForDeferringEnvironmentSel,
                                                             environment);
            KimiRunBKSAddTargetCandidate(candidates, seenTargets, target, @"targetForDeferringEnvironment", nil);
        }
    }

    if ([targetClass respondsToSelector:systemTargetSel]) {
        id target = ((id (*)(id, SEL))objc_msgSend)(targetClass, systemTargetSel);
        KimiRunBKSAddTargetCandidate(candidates, seenTargets, target, @"systemTarget", nil);
    }

    return [candidates copy];
}

static void KimiRunInvalidateBKSAssertion(id assertion) {
    if (!assertion) {
        return;
    }
    SEL invalidateSel = @selector(invalidate);
    SEL relinquishSel = @selector(relinquish);
    SEL endSel = @selector(endAssertion);
    @try {
        if ([assertion respondsToSelector:invalidateSel]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, invalidateSel);
            return;
        }
        if ([assertion respondsToSelector:relinquishSel]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, relinquishSel);
            return;
        }
        if ([assertion respondsToSelector:endSel]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, endSel);
        }
    } @catch (NSException *e) {
        KimiRunLog([NSString stringWithFormat:@"[BKS] assertion cleanup exception: %@ reason=%@",
                    e.name ?: @"(unknown)",
                    e.reason ?: @"(no reason)"]);
    }
}

// Deliver event via BackBoardServices (fallback method)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KimiRunTouchInjection (BKSRoutingDispatch)

static BOOL KimiRunBKSPostRouteDispatchEnabled(void) {
    return KimiRunTouchEnvBool("KIMIRUN_BKS_POST_ROUTE_DISPATCH",
                               KimiRunTouchPrefBool(@"BKSPostRouteDispatch", NO));
}

static BOOL KimiRunBKSPostRouteContextDispatchEnabled(void) {
    return KimiRunTouchEnvBool("KIMIRUN_BKS_POST_ROUTE_CONTEXT_DISPATCH",
                               KimiRunTouchPrefBool(@"BKSPostRouteContextDispatch", NO));
}

static BOOL KimiRunBKSDispatchEventAfterRouting(IOHIDEventRef event, NSString **pathOut) {
    if (pathOut) {
        *pathOut = nil;
    }
    if (!event) {
        return NO;
    }

    if (KimiRunBKSPostRouteContextDispatchEnabled()) {
        NSString *contextPath = nil;
        if (KimiRunDispatchEventWithContextBind(event, &contextPath)) {
            if (pathOut) {
                *pathOut = contextPath ?: @"context_bind";
            }
            return YES;
        }
    }

    // Prefer connection dispatch first to match low-level consumption paths.
    if (_IOHIDEventSystemConnectionDispatchEvent) {
        UpdateHIDConnection();
        if (g_hidConnection) {
            _IOHIDEventSystemConnectionDispatchEvent(g_hidConnection, event);
            if (pathOut) {
                *pathOut = @"connection";
            }
            return YES;
        }
    }

    // Fall back to available event system clients.
    if (_IOHIDEventSystemClientDispatchEvent) {
        BOOL dispatched = NO;
        if (g_simClient) {
            _IOHIDEventSystemClientDispatchEvent(g_simClient, event);
            dispatched = YES;
        }
        if (g_hidClient) {
            _IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
            dispatched = YES;
        }
        if (g_adminClient) {
            _IOHIDEventSystemClientDispatchEvent(g_adminClient, event);
            dispatched = YES;
        }
        if (dispatched) {
            if (pathOut) {
                *pathOut = @"client";
            }
            return YES;
        }
    }

    // Final fallback to legacy helper (currently uses hid client only).
    if (KimiRunDispatchEvent(event)) {
        if (pathOut) {
            *pathOut = @"dispatch_helper";
        }
        return YES;
    }

    return NO;
}

+ (BOOL)deliverViaBKS:(IOHIDEventRef)event {
    if (!event) {
        NSLog(@"[KimiRunTouchInjection] BKS delivery: event is NULL");
        KimiRunLog(@"[BKS] delivery called with NULL event");
        KimiRunRecordBKSDispatchFailure(@"null_event");
        return NO;
    }
    if (!g_bksSharedDeliveryManager) {
        KimiRunResolveBKSManagers();
    }
    if (!g_bksSharedDeliveryManager) {
        NSLog(@"[KimiRunTouchInjection] BKS delivery: manager not available");
        KimiRunLog(@"[BKS] delivery manager not available");
        KimiRunRecordBKSDispatchFailure(@"delivery_manager_unavailable");
        return NO;
    }
    KimiRunLog([NSString stringWithFormat:@"[BKS] delivery begin manager=%p router=%p",
                g_bksSharedDeliveryManager, g_bksSharedRouterManager]);
    
    id assertion = nil;
    BOOL focusOverrideEnabled = KimiRunTouchEnvBool("KIMIRUN_BKS_FOCUS_OVERRIDE",
                                                    KimiRunTouchPrefBool(@"BKSFocusOverride", NO));
    SEL setFocusTargetOverrideSel = @selector(_setFocusTargetOverride:);
    BOOL canSetFocusTargetOverride = focusOverrideEnabled &&
                                     [g_bksSharedDeliveryManager respondsToSelector:setFocusTargetOverrideSel];
    BOOL setFocusOverrideForAnyTarget = NO;

    BOOL timingExperimentEnabled = KimiRunTouchEnvBool("KIMIRUN_BKS_TIMING_EXPERIMENT",
                                                       KimiRunTouchPrefBool(@"BKSTimingExperimentEnabled", NO));
    NSString *focusHintPhase = KimiRunNormalizeExperimentMode(
        KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_FOCUS_HINT_PHASE",
                                    @"BKSFocusHintPhase",
                                    @"before"),
        @[ @"before", @"per_target", @"after", @"none" ],
        @"before");
    NSString *focusOverrideMode = KimiRunNormalizeExperimentMode(
        KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_FOCUS_OVERRIDE_MODE",
                                    @"BKSFocusOverrideMode",
                                    @"per_target"),
        @[ @"per_target", @"before_all", @"none" ],
        @"per_target");
    BOOL sortCandidatesByPreference = KimiRunTouchEnvBool("KIMIRUN_BKS_SORT_CANDIDATES",
                                                          KimiRunTouchPrefBool(@"BKSSortCandidates",
                                                                               timingExperimentEnabled));
    BOOL flushEachTarget = KimiRunTouchEnvBool("KIMIRUN_BKS_FLUSH_EACH_TARGET",
                                               KimiRunTouchPrefBool(@"BKSFlushEachTarget", NO));
    BOOL useSourceDescriptor = KimiRunTouchEnvBool("KIMIRUN_BKS_USE_SOURCE_DESCRIPTOR",
                                                   KimiRunTouchPrefBool(@"BKSUseSourceDescriptor", NO));
    BOOL noSenderDescriptorMatch = KimiRunTouchEnvBool("KIMIRUN_BKS_NO_SENDER_DESCRIPTOR_MATCH",
                                                       KimiRunTouchPrefBool(@"BKSNoSenderDescriptorMatch", NO));
    BOOL autoDisabledSenderDescriptorMatch = NO;
    if (!noSenderDescriptorMatch) {
        BOOL senderCaptured = [KimiRunTouchInjection senderIDCaptured];
        int digitizerCount = [KimiRunTouchInjection senderIDDigitizerCount];
        BOOL proxySenderLikelyLive = [KimiRunTouchInjection proxySenderLikelyLive];
        if (!senderCaptured && digitizerCount <= 0 && !proxySenderLikelyLive) {
            noSenderDescriptorMatch = YES;
            autoDisabledSenderDescriptorMatch = YES;
        }
    }
    BOOL pinFocusToTarget = KimiRunTouchEnvBool("KIMIRUN_BKS_PIN_FOCUS_TO_TARGET",
                                                KimiRunTouchPrefBool(@"BKSPinFocusToTarget", NO));
    BOOL pinFocusSetAdjustedPID = KimiRunTouchEnvBool("KIMIRUN_BKS_PIN_FOCUS_SET_ADJUSTED_PID",
                                                      KimiRunTouchPrefBool(@"BKSPinFocusSetAdjustedPID", NO));
    BOOL invalidateDispatchAssertion = KimiRunTouchEnvBool("KIMIRUN_BKS_DISPATCH_ASSERTION_INVALIDATE",
                                                           KimiRunTouchPrefBool(@"BKSDispatchAssertionInvalidate", YES));
    NSInteger dispatchAssertionHoldMS = KimiRunClampInteger(
        KimiRunTouchEnvInteger("KIMIRUN_BKS_DISPATCH_ASSERTION_HOLD_MS",
                               KimiRunTouchPrefInteger(@"BKSDispatchAssertionHoldMS", 0)),
        0, 2000);
    NSInteger preDispatchDelayMS = KimiRunClampInteger(
        KimiRunTouchEnvInteger("KIMIRUN_BKS_PRE_DISPATCH_DELAY_MS",
                               KimiRunTouchPrefInteger(@"BKSPredispatchDelayMS", 0)),
        0, 300);
    NSInteger perTargetDelayMS = KimiRunClampInteger(
        KimiRunTouchEnvInteger("KIMIRUN_BKS_PER_TARGET_DELAY_MS",
                               KimiRunTouchPrefInteger(@"BKSPerTargetDelayMS", 0)),
        0, 300);
    NSInteger postFocusDelayMS = KimiRunClampInteger(
        KimiRunTouchEnvInteger("KIMIRUN_BKS_POST_FOCUS_DELAY_MS",
                               KimiRunTouchPrefInteger(@"BKSPostFocusDelayMS", 0)),
        0, 300);
    NSInteger pinFocusDelayMS = KimiRunClampInteger(
        KimiRunTouchEnvInteger("KIMIRUN_BKS_PIN_FOCUS_DELAY_MS",
                               KimiRunTouchPrefInteger(@"BKSPinFocusDelayMS", 0)),
        0, 300);
    BOOL systemFocusExperimentEnabled = KimiRunTouchEnvBool("KIMIRUN_BKS_SYSTEM_FOCUS_EXPERIMENT",
                                                            KimiRunTouchPrefBool(@"BKSSystemFocusExperimentEnabled", NO));
    NSString *systemFocusPhase = KimiRunNormalizeExperimentMode(
        KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_SYSTEM_FOCUS_PHASE",
                                    @"BKSSystemFocusPhase",
                                    @"none"),
        @[ @"before", @"per_target", @"after", @"none" ],
        @"none");
    BOOL systemFocusValue = KimiRunTouchEnvBool("KIMIRUN_BKS_SYSTEM_FOCUS_VALUE",
                                                KimiRunTouchPrefBool(@"BKSSystemFocusValue", NO));
    NSInteger systemFocusDelayMS = KimiRunClampInteger(
        KimiRunTouchEnvInteger("KIMIRUN_BKS_SYSTEM_FOCUS_DELAY_MS",
                               KimiRunTouchPrefInteger(@"BKSSystemFocusDelayMS", 0)),
        0, 500);
    NSString *dispatchReason = KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_DISPATCH_REASON",
                                                           @"BKSDispatchReason",
                                                           @"kimirun-touch");
    if (![dispatchReason isKindOfClass:[NSString class]] || dispatchReason.length == 0) {
        dispatchReason = @"kimirun-touch";
    }

    if (![focusOverrideMode isEqualToString:@"per_target"] &&
        ![focusOverrideMode isEqualToString:@"before_all"] &&
        ![focusOverrideMode isEqualToString:@"none"]) {
        focusOverrideMode = @"per_target";
    }
    if ([focusOverrideMode isEqualToString:@"none"]) {
        canSetFocusTargetOverride = NO;
    }

    @try {
        NSString *selectedSenderSource = nil;
        uint64_t selectedSenderID = KimiRunPreferredBKSSenderID(&selectedSenderSource);

        // Set BKS sender ID. Prefer captured live sender, fallback to known constants.
        if (_IOHIDEventSetSenderID) {
            _IOHIDEventSetSenderID(event, selectedSenderID);
            NSLog(@"[KimiRunTouchInjection] Set BKS sender ID: 0x%llX (%@)",
                  selectedSenderID,
                  selectedSenderSource ?: @"unknown");
        }

        // Use discovered iOS 13.2.3 API surface:
        // BKSHIDEventDescriptor -> BKSHIDEventDiscreteDispatchingPredicate ->
        // BKSHIDEventDiscreteDispatchingRule -> BKSHIDEventDeliveryManager dispatchDiscreteEvents...
        Class descriptorClass = NSClassFromString(@"BKSHIDEventDescriptor");
        Class predicateClass = NSClassFromString(@"BKSHIDEventDiscreteDispatchingPredicate");
        Class targetClass = NSClassFromString(@"BKSHIDEventDispatchingTarget");
        Class ruleClass = NSClassFromString(@"BKSHIDEventDiscreteDispatchingRule");
        Class routerManagerClass = NSClassFromString(@"BKSHIDEventRouterManager");
        Class routerClass = NSClassFromString(@"BKSHIDEventRouter");
        SEL syncSel = @selector(_syncServiceFlushState);

        NSMutableDictionary *experimentInfo = [NSMutableDictionary dictionary];
        experimentInfo[@"enabled"] = @(timingExperimentEnabled);
        experimentInfo[@"focusHintPhase"] = focusHintPhase ?: @"before";
        experimentInfo[@"focusOverrideMode"] = focusOverrideMode ?: @"per_target";
        experimentInfo[@"sortCandidates"] = @(sortCandidatesByPreference);
        experimentInfo[@"flushEachTarget"] = @(flushEachTarget);
        experimentInfo[@"useSourceDescriptor"] = @(useSourceDescriptor);
        experimentInfo[@"noSenderDescriptorMatch"] = @(noSenderDescriptorMatch);
        experimentInfo[@"autoDisabledSenderDescriptorMatch"] = @(autoDisabledSenderDescriptorMatch);
        experimentInfo[@"proxySenderLikelyLive"] = @([KimiRunTouchInjection proxySenderLikelyLive]);
        experimentInfo[@"proxySenderCaptured"] = @([KimiRunTouchInjection proxySenderCaptured]);
        experimentInfo[@"proxySenderDigitizerCount"] = @([KimiRunTouchInjection proxySenderDigitizerCount]);
        uint64_t proxySenderID = [KimiRunTouchInjection proxySenderID];
        if (proxySenderID != 0) {
            experimentInfo[@"proxySenderIDHex"] = [NSString stringWithFormat:@"0x%llX", proxySenderID];
        }
        NSString *proxySource = [KimiRunTouchInjection proxySenderSourceString];
        if (proxySource.length > 0) {
            experimentInfo[@"proxySenderSource"] = proxySource;
        }
        experimentInfo[@"bksEventMode"] = KimiRunBKSEventMode();
        experimentInfo[@"pinFocusToTarget"] = @(pinFocusToTarget);
        experimentInfo[@"pinFocusSetAdjustedPID"] = @(pinFocusSetAdjustedPID);
        experimentInfo[@"dispatchAssertionInvalidate"] = @(invalidateDispatchAssertion);
        experimentInfo[@"dispatchAssertionHoldMS"] = @(dispatchAssertionHoldMS);
        experimentInfo[@"dispatchReason"] = dispatchReason ?: @"kimirun-touch";
        BOOL postRouteDispatchEnabled = KimiRunBKSPostRouteDispatchEnabled();
        BOOL postRouteContextDispatchEnabled = KimiRunBKSPostRouteContextDispatchEnabled();
        experimentInfo[@"postRouteDispatchEnabled"] = @(postRouteDispatchEnabled);
        experimentInfo[@"postRouteContextDispatchEnabled"] = @(postRouteContextDispatchEnabled);
        experimentInfo[@"preDispatchDelayMS"] = @(preDispatchDelayMS);
        experimentInfo[@"perTargetDelayMS"] = @(perTargetDelayMS);
        experimentInfo[@"postFocusDelayMS"] = @(postFocusDelayMS);
        experimentInfo[@"pinFocusDelayMS"] = @(pinFocusDelayMS);
        experimentInfo[@"systemFocusExperimentEnabled"] = @(systemFocusExperimentEnabled);
        experimentInfo[@"systemFocusPhase"] = systemFocusPhase ?: @"none";
        experimentInfo[@"systemFocusValue"] = @(systemFocusValue);
        experimentInfo[@"systemFocusDelayMS"] = @(systemFocusDelayMS);
        NSUInteger focusHintsAppliedBefore = 0;
        NSUInteger focusHintsAppliedPerTarget = 0;
        NSUInteger focusHintsAppliedAfter = 0;
        NSUInteger focusPinsAttempted = 0;
        NSUInteger focusPinsApplied = 0;
        NSUInteger systemFocusAppliedBefore = 0;
        NSUInteger systemFocusAppliedPerTarget = 0;
        NSUInteger systemFocusAppliedAfter = 0;
        BOOL focusOverrideAppliedBeforeAll = NO;
        int focusOverrideBeforeAllPID = -1;

        if (!descriptorClass || !predicateClass || !targetClass || !ruleClass) {
            NSLog(@"[KimiRunTouchInjection] BKS delivery: required BKSHID classes unavailable");
            KimiRunLog(@"[BKS] required BKSHID classes unavailable");
            KimiRunRecordBKSDispatchFailure(@"required_classes_unavailable");
            return NO;
        }

        id descriptor = nil;
        SEL descriptorForEventSel = @selector(descriptorForHIDEvent:);
        SEL descriptorWithTypeSel = @selector(descriptorWithEventType:);
        if ([descriptorClass respondsToSelector:descriptorForEventSel]) {
            descriptor = [descriptorClass descriptorForHIDEvent:(struct __IOHIDEvent *)event];
        }
        if (!descriptor && [descriptorClass respondsToSelector:descriptorWithTypeSel] && _IOHIDEventGetType) {
            NSUInteger eventType = (NSUInteger)_IOHIDEventGetType(event);
            descriptor = [descriptorClass descriptorWithEventType:(unsigned int)eventType];
        }
        if (!descriptor) {
            NSLog(@"[KimiRunTouchInjection] BKS delivery: failed to create HID descriptor");
            KimiRunLog(@"[BKS] failed to create HID descriptor");
            KimiRunRecordBKSDispatchFailure(@"descriptor_creation_failed");
            return NO;
        }

        SEL addSenderMatchSel = @selector(descriptorByAddingSenderIDToMatchCriteria:);
        BOOL senderDescriptorMatchApplied = NO;
        uint64_t senderDescriptorMatchValue = 0;
        if (!noSenderDescriptorMatch && _IOHIDEventGetSenderID && [descriptor respondsToSelector:addSenderMatchSel]) {
            uint64_t sender = _IOHIDEventGetSenderID(event);
            senderDescriptorMatchValue = sender;
            if (sender != 0) {
                id matched = [descriptor descriptorByAddingSenderIDToMatchCriteria:(NSUInteger)sender];
                if (matched) {
                    descriptor = matched;
                    senderDescriptorMatchApplied = YES;
                }
            }
        }
        experimentInfo[@"senderDescriptorMatchApplied"] = @(senderDescriptorMatchApplied);
        if (senderDescriptorMatchValue != 0) {
            experimentInfo[@"senderDescriptorMatchValueHex"] = [NSString stringWithFormat:@"0x%llX",
                                                                senderDescriptorMatchValue];
        }

        // Ensure router manager has event routers configured when available.
        id routerManager = nil;
        if (routerManagerClass && routerClass) {
            SEL sharedSel = @selector(sharedInstance);
            SEL eventRoutersSel = @selector(eventRouters);
            SEL setEventRoutersSel = @selector(setEventRouters:);
            SEL defaultRoutersSel = @selector(defaultEventRouters);
            SEL defaultFocusedSel = @selector(defaultFocusedAppEventRouter);
            SEL defaultSystemSel = @selector(defaultSystemAppEventRouter);
            SEL destinationSel = @selector(destination);
            SEL addDescriptorsSel = @selector(addHIDEventDescriptors:);
            if ([routerManagerClass respondsToSelector:sharedSel]) {
                routerManager = ((id (*)(id, SEL))objc_msgSend)(routerManagerClass, sharedSel);
                if (routerManager) {
                    g_bksSharedRouterManager = routerManager;
                }
                if (routerManager &&
                    [routerManager respondsToSelector:eventRoutersSel] &&
                    [routerManager respondsToSelector:setEventRoutersSel] &&
                    [routerClass respondsToSelector:defaultRoutersSel]) {
                    id existing = ((id (*)(id, SEL))objc_msgSend)(routerManager, eventRoutersSel);
                    NSMutableArray *routersToApply = [NSMutableArray array];
                    if ([existing isKindOfClass:[NSArray class]]) {
                        [routersToApply addObjectsFromArray:(NSArray *)existing];
                    }
                    if ([routersToApply count] == 0) {
                        id defaults = ((id (*)(id, SEL))objc_msgSend)(routerClass, defaultRoutersSel);
                        if ([defaults isKindOfClass:[NSArray class]]) {
                            [routersToApply addObjectsFromArray:(NSArray *)defaults];
                        }
                    }
                    if ([routerClass respondsToSelector:defaultFocusedSel]) {
                        id focused = ((id (*)(id, SEL))objc_msgSend)(routerClass, defaultFocusedSel);
                        if (focused) {
                            [routersToApply addObject:focused];
                        }
                    }
                    if ([routerClass respondsToSelector:defaultSystemSel]) {
                        id systemRouter = ((id (*)(id, SEL))objc_msgSend)(routerClass, defaultSystemSel);
                        if (systemRouter) {
                            [routersToApply addObject:systemRouter];
                        }
                    }

                    NSMutableArray *uniqueRouters = [NSMutableArray array];
                    NSMutableSet<NSNumber *> *seenDestinations = [NSMutableSet set];
                    for (id router in routersToApply) {
                        if (!router || ![router respondsToSelector:destinationSel]) {
                            continue;
                        }
                        long long destination = ((long long (*)(id, SEL))objc_msgSend)(router, destinationSel);
                        NSNumber *key = @(destination);
                        if ([seenDestinations containsObject:key]) {
                            continue;
                        }
                        [seenDestinations addObject:key];
                        [uniqueRouters addObject:router];
                        if ([router respondsToSelector:addDescriptorsSel]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(router, addDescriptorsSel, [NSSet setWithObject:descriptor]);
                        }
                    }
                    if (uniqueRouters.count > 0) {
                        ((void (*)(id, SEL, id))objc_msgSend)(routerManager, setEventRoutersSel, uniqueRouters);
                    }
                }
            }
        }

        NSArray<NSDictionary *> *targetCandidates = KimiRunBKSBuildTargetCandidates(targetClass,
                                                                                     routerManager,
                                                                                     routerClass);
        if (targetCandidates.count == 0) {
            NSLog(@"[KimiRunTouchInjection] BKS delivery: no dispatching targets");
            KimiRunLog(@"[BKS] no dispatching targets");
            KimiRunRecordBKSDispatchFailure(@"no_dispatch_targets");
            return NO;
        }

        int frontmostPid = KimiRunFrontmostApplicationPID();
        int springboardPid = KimiRunPIDForProcessName(@"SpringBoard");
        int backboarddPid = KimiRunPIDForProcessName(@"backboardd");

        if (sortCandidatesByPreference && targetCandidates.count > 1) {
            NSMutableArray<NSDictionary *> *sortedCandidates = [targetCandidates mutableCopy];
            [sortedCandidates sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
                id lhsTarget = lhs[@"target"];
                id rhsTarget = rhs[@"target"];
                NSString *lhsSource = lhs[@"source"] ?: @"";
                NSString *rhsSource = rhs[@"source"] ?: @"";
                int lhsPid = KimiRunBKSTargetPID(lhsTarget);
                int rhsPid = KimiRunBKSTargetPID(rhsTarget);
                NSInteger lhsScore = KimiRunBKSTargetPreferenceScore(lhsSource,
                                                                     lhsPid,
                                                                     frontmostPid,
                                                                     springboardPid,
                                                                     backboarddPid);
                NSInteger rhsScore = KimiRunBKSTargetPreferenceScore(rhsSource,
                                                                     rhsPid,
                                                                     frontmostPid,
                                                                     springboardPid,
                                                                     backboarddPid);
                if (lhsScore == rhsScore) {
                    return NSOrderedSame;
                }
                return (lhsScore > rhsScore) ? NSOrderedAscending : NSOrderedDescending;
            }];
            targetCandidates = [sortedCandidates copy];
        }

        NSString *forcedTargetSource = KimiRunLowerTrimmed(
            KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_FORCE_TARGET_SOURCE",
                                        @"BKSForceTargetSource",
                                        @""));
        NSInteger forcedTargetPIDRaw = KimiRunClampInteger(
            KimiRunTouchEnvInteger("KIMIRUN_BKS_FORCE_TARGET_PID",
                                   KimiRunTouchPrefInteger(@"BKSForceTargetPID", 0)),
            0, INT_MAX);
        NSString *forcedTargetProcess = KimiRunLowerTrimmed(
            KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_FORCE_TARGET_PROCESS",
                                        @"BKSForceTargetProcess",
                                        @""));
        BOOL forceTargetOnly = KimiRunTouchEnvBool("KIMIRUN_BKS_FORCE_TARGET_ONLY",
                                                   KimiRunTouchPrefBool(@"BKSForceTargetOnly", NO));
        int forcedTargetPID = (forcedTargetPIDRaw > 0) ? (int)forcedTargetPIDRaw : -1;
        if (forcedTargetPID <= 0) {
            forcedTargetPID = KimiRunForcedTargetPIDForProcess(forcedTargetProcess,
                                                               frontmostPid,
                                                               springboardPid,
                                                               backboarddPid);
        }

        BOOL hasForcedSelector = (forcedTargetPID > 0 || forcedTargetSource.length > 0);
        if (hasForcedSelector) {
            NSMutableArray<NSDictionary *> *forcedMatches = [NSMutableArray array];
            for (NSDictionary *candidate in targetCandidates) {
                NSString *source = KimiRunLowerTrimmed(candidate[@"source"]);
                int targetPid = KimiRunBKSTargetPID(candidate[@"target"]);
                BOOL sourceMatch = (forcedTargetSource.length == 0 ||
                                    [source isEqualToString:forcedTargetSource] ||
                                    [source hasPrefix:forcedTargetSource]);
                BOOL pidMatch = (forcedTargetPID <= 0 || targetPid == forcedTargetPID);
                if (sourceMatch && pidMatch) {
                    [forcedMatches addObject:candidate];
                }
            }

            experimentInfo[@"forcedTargetSource"] = forcedTargetSource ?: @"";
            experimentInfo[@"forcedTargetPID"] = @(forcedTargetPID);
            experimentInfo[@"forcedTargetOnly"] = @(forceTargetOnly);
            experimentInfo[@"forcedTargetMatches"] = @(forcedMatches.count);
            if (forcedTargetProcess.length > 0) {
                experimentInfo[@"forcedTargetProcess"] = forcedTargetProcess;
            }

            if (forcedMatches.count == 0 && forceTargetOnly) {
                KimiRunLog([NSString stringWithFormat:@"[BKS] forced target produced no candidates source=%@ pid=%d process=%@",
                            forcedTargetSource ?: @"",
                            forcedTargetPID,
                            forcedTargetProcess ?: @""]);
                KimiRunRecordBKSDispatchFailure(@"forced_target_no_match");
                return NO;
            }

            if (forcedMatches.count > 0) {
                if (forceTargetOnly) {
                    targetCandidates = [forcedMatches copy];
                } else {
                    NSMutableArray<NSDictionary *> *reordered = [forcedMatches mutableCopy];
                    for (NSDictionary *candidate in targetCandidates) {
                        if (![forcedMatches containsObject:candidate]) {
                            [reordered addObject:candidate];
                        }
                    }
                    targetCandidates = [reordered copy];
                }
            }
        }

        SEL ruleFactorySel = @selector(ruleForDispatchingDiscreteEventsMatchingPredicate:toTarget:);
        if (![ruleClass respondsToSelector:ruleFactorySel]) {
            NSLog(@"[KimiRunTouchInjection] BKS delivery: rule factory unavailable");
            KimiRunLog(@"[BKS] rule factory unavailable");
            KimiRunRecordBKSDispatchFailure(@"rule_factory_unavailable");
            return NO;
        }

        SEL dispatchSel = @selector(dispatchDiscreteEventsForReason:withRules:);
        if (![g_bksSharedDeliveryManager respondsToSelector:dispatchSel]) {
            NSLog(@"[KimiRunTouchInjection] BKS delivery manager missing dispatchDiscreteEventsForReason:withRules:");
            KimiRunLog(@"[BKS] delivery manager missing dispatchDiscreteEventsForReason:withRules:");
            KimiRunRecordBKSDispatchFailure(@"dispatch_selector_missing");
            return NO;
        }
        SEL transactionAssertionSel = @selector(transactionAssertionWithReason:);
        if ([g_bksSharedDeliveryManager respondsToSelector:transactionAssertionSel]) {
            @try {
                assertion = [g_bksSharedDeliveryManager transactionAssertionWithReason:@"kimirun-touch"];
            } @catch (NSException *e) {
                KimiRunLog([NSString stringWithFormat:@"[BKS] transaction assertion exception: %@ reason=%@",
                            e.name ?: @"(unknown)",
                            e.reason ?: @"(no reason)"]);
            }
        }

        if ([focusHintPhase isEqualToString:@"before"]) {
            KimiRunApplyBKSFocusHints();
            focusHintsAppliedBefore++;
            if (postFocusDelayMS > 0) {
                usleep((useconds_t)(postFocusDelayMS * 1000));
            }
        }
        if (systemFocusExperimentEnabled && [systemFocusPhase isEqualToString:@"before"]) {
            if (KimiRunApplyBKSSystemAppFocus(systemFocusValue, @"system_focus_before")) {
                systemFocusAppliedBefore++;
            }
            if (systemFocusDelayMS > 0) {
                usleep((useconds_t)(systemFocusDelayMS * 1000));
            }
        }
        if (preDispatchDelayMS > 0) {
            usleep((useconds_t)(preDispatchDelayMS * 1000));
        }

        if (canSetFocusTargetOverride && [focusOverrideMode isEqualToString:@"before_all"]) {
            NSDictionary *firstEntry = targetCandidates.firstObject;
            id firstTarget = firstEntry[@"target"];
            if (firstTarget) {
                @try {
                    [(BKSHIDEventDeliveryManager *)g_bksSharedDeliveryManager _setFocusTargetOverride:firstTarget];
                    setFocusOverrideForAnyTarget = YES;
                    focusOverrideAppliedBeforeAll = YES;
                    focusOverrideBeforeAllPID = KimiRunBKSTargetPID(firstTarget);
                } @catch (NSException *e) {
                    KimiRunLog([NSString stringWithFormat:@"[BKS] before_all override exception: %@ reason=%@",
                                e.name ?: @"(unknown)",
                                e.reason ?: @"(no reason)"]);
                }
            }
        }

        BOOL acceptedFocusedTarget = NO;
        NSUInteger acceptedDispatches = 0;
        NSInteger chosenScore = -1;
        NSString *chosenSource = nil;
        NSNumber *chosenDestination = nil;
        NSString *chosenTargetClass = nil;
        int chosenTargetPid = -1;
        NSMutableArray<NSDictionary *> *routeAttempts = [NSMutableArray array];
        NSMutableArray *pendingDispatchAssertions = [NSMutableArray array];
        g_bksLastMeaningfulDispatch = NO;

        for (NSDictionary *entry in targetCandidates) {
            id target = entry[@"target"];
            NSString *source = entry[@"source"] ?: @"unknown";
            NSNumber *destination = entry[@"destination"];
            if (!target) {
                continue;
            }
            int targetPid = KimiRunBKSTargetPID(target);

            if ([focusHintPhase isEqualToString:@"per_target"]) {
                KimiRunApplyBKSFocusHints();
                focusHintsAppliedPerTarget++;
                if (postFocusDelayMS > 0) {
                    usleep((useconds_t)(postFocusDelayMS * 1000));
                }
            }
            if (systemFocusExperimentEnabled && [systemFocusPhase isEqualToString:@"per_target"]) {
                if (KimiRunApplyBKSSystemAppFocus(systemFocusValue, @"system_focus_per_target")) {
                    systemFocusAppliedPerTarget++;
                }
                if (systemFocusDelayMS > 0) {
                    usleep((useconds_t)(systemFocusDelayMS * 1000));
                }
            }
            BOOL focusPinApplied = NO;
            if (pinFocusToTarget && targetPid > 0) {
                focusPinsAttempted++;
                focusPinApplied = KimiRunApplyBKSEventFocusForPID(targetPid,
                                                                  @"per_target_pin",
                                                                  pinFocusSetAdjustedPID);
                if (focusPinApplied) {
                    focusPinsApplied++;
                }
                if (pinFocusDelayMS > 0) {
                    usleep((useconds_t)(pinFocusDelayMS * 1000));
                }
            }

            @try {
                if (canSetFocusTargetOverride && [focusOverrideMode isEqualToString:@"per_target"]) {
                    [(BKSHIDEventDeliveryManager *)g_bksSharedDeliveryManager _setFocusTargetOverride:target];
                    setFocusOverrideForAnyTarget = YES;
                }
                if (perTargetDelayMS > 0) {
                    usleep((useconds_t)(perTargetDelayMS * 1000));
                }
                id predicate = KimiRunCreateDispatchPredicate(descriptor, useSourceDescriptor);
                if (!predicate) {
                    continue;
                }

                id rule = [ruleClass ruleForDispatchingDiscreteEventsMatchingPredicate:predicate
                                                                               toTarget:target];
                if (!rule) {
                    continue;
                }

                id dispatchResult = [g_bksSharedDeliveryManager dispatchDiscreteEventsForReason:dispatchReason
                                                                                         withRules:@[rule]];
                BOOL accepted = (dispatchResult != nil);
                NSString *targetClassName = NSStringFromClass([target class]) ?: @"(unknown)";
                BOOL sourceIsMeaningful = ([source isEqualToString:@"routerDestination"] ||
                                           [source isEqualToString:@"manualDestination"] ||
                                           [source isEqualToString:@"keyboardFocusTarget"] ||
                                           [source isEqualToString:@"systemTarget"] ||
                                           [source hasPrefix:@"focusTargetForPID"]);
                BOOL pidIsMeaningful = (targetPid <= 0 || targetPid != (int)getpid());
                BOOL meaningfulAcceptance = sourceIsMeaningful && pidIsMeaningful;
                NSInteger preferenceScore = KimiRunBKSTargetPreferenceScore(source,
                                                                            targetPid,
                                                                            frontmostPid,
                                                                            springboardPid,
                                                                            backboarddPid);
                NSInteger currentScore = 0;
                if (accepted) {
                    currentScore = (meaningfulAcceptance ? 1000 : 100) + preferenceScore;
                }

                if (accepted) {
                    acceptedDispatches++;
                    if (meaningfulAcceptance) {
                        acceptedFocusedTarget = YES;
                    }
                }
                if (currentScore > chosenScore) {
                    chosenScore = currentScore;
                    chosenSource = source;
                    chosenDestination = destination;
                    chosenTargetClass = targetClassName;
                    chosenTargetPid = targetPid;
                }

                NSMutableDictionary *attempt = [NSMutableDictionary dictionary];
                attempt[@"source"] = source ?: @"unknown";
                attempt[@"targetClass"] = targetClassName;
                attempt[@"pid"] = @(targetPid);
                attempt[@"accepted"] = @(accepted);
                attempt[@"meaningful"] = @(meaningfulAcceptance);
                attempt[@"focusPinApplied"] = @(focusPinApplied);
                if (destination) {
                    attempt[@"destination"] = destination;
                }
                [routeAttempts addObject:attempt];

                KimiRunLog([NSString stringWithFormat:@"[BKS] route source=%@ destination=%@ accepted=%@ meaningful=%@ pid=%d target=%@",
                            source,
                            destination ? [destination stringValue] : @"(none)",
                            accepted ? @"yes" : @"no",
                            meaningfulAcceptance ? @"yes" : @"no",
                            targetPid,
                            targetClassName]);
                // dispatchDiscreteEvents... may return a BSSimpleAssertion. Invalidation timing
                // can affect whether the target process consumes dispatched touch phases.
                if (dispatchResult) {
                    if (!invalidateDispatchAssertion || dispatchAssertionHoldMS > 0) {
                        [pendingDispatchAssertions addObject:dispatchResult];
                    } else {
                        KimiRunInvalidateBKSAssertion(dispatchResult);
                    }
                }
            } @catch (NSException *e) {
                NSMutableDictionary *attempt = [NSMutableDictionary dictionary];
                attempt[@"source"] = source ?: @"unknown";
                attempt[@"accepted"] = @NO;
                attempt[@"meaningful"] = @NO;
                attempt[@"focusPinApplied"] = @(focusPinApplied);
                attempt[@"exception"] = e.name ?: @"NSException";
                if (destination) {
                    attempt[@"destination"] = destination;
                }
                [routeAttempts addObject:attempt];
                KimiRunLog([NSString stringWithFormat:@"[BKS] route exception source=%@ destination=%@ name=%@ reason=%@",
                            source,
                            destination ? [destination stringValue] : @"(none)",
                            e.name ?: @"(unknown)",
                            e.reason ?: @"(no reason)"]);
            }

            if (flushEachTarget && [g_bksSharedDeliveryManager respondsToSelector:syncSel]) {
                @try {
                    [(BKSHIDEventDeliveryManager *)g_bksSharedDeliveryManager _syncServiceFlushState];
                } @catch (NSException *e) {
                    KimiRunLog([NSString stringWithFormat:@"[BKS] per-target flush exception: %@ reason=%@",
                                e.name ?: @"(unknown)",
                                e.reason ?: @"(no reason)"]);
                }
            }
        }

        if ([focusHintPhase isEqualToString:@"after"]) {
            KimiRunApplyBKSFocusHints();
            focusHintsAppliedAfter++;
            if (postFocusDelayMS > 0) {
                usleep((useconds_t)(postFocusDelayMS * 1000));
            }
        }
        if (systemFocusExperimentEnabled && [systemFocusPhase isEqualToString:@"after"]) {
            if (KimiRunApplyBKSSystemAppFocus(systemFocusValue, @"system_focus_after")) {
                systemFocusAppliedAfter++;
            }
            if (systemFocusDelayMS > 0) {
                usleep((useconds_t)(systemFocusDelayMS * 1000));
            }
        }

        if (pendingDispatchAssertions.count > 0) {
            if (dispatchAssertionHoldMS > 0) {
                usleep((useconds_t)(dispatchAssertionHoldMS * 1000));
            }
            if (invalidateDispatchAssertion) {
                for (id assertionObj in pendingDispatchAssertions) {
                    KimiRunInvalidateBKSAssertion(assertionObj);
                }
            }
        }

        if ([g_bksSharedDeliveryManager respondsToSelector:syncSel]) {
            [(BKSHIDEventDeliveryManager *)g_bksSharedDeliveryManager _syncServiceFlushState];
        }

        experimentInfo[@"focusHintsAppliedBefore"] = @(focusHintsAppliedBefore);
        experimentInfo[@"focusHintsAppliedPerTarget"] = @(focusHintsAppliedPerTarget);
        experimentInfo[@"focusHintsAppliedAfter"] = @(focusHintsAppliedAfter);
        experimentInfo[@"focusPinsAttempted"] = @(focusPinsAttempted);
        experimentInfo[@"focusPinsApplied"] = @(focusPinsApplied);
        experimentInfo[@"systemFocusAppliedBefore"] = @(systemFocusAppliedBefore);
        experimentInfo[@"systemFocusAppliedPerTarget"] = @(systemFocusAppliedPerTarget);
        experimentInfo[@"systemFocusAppliedAfter"] = @(systemFocusAppliedAfter);
        experimentInfo[@"dispatchAssertionCount"] = @(pendingDispatchAssertions.count);
        experimentInfo[@"focusOverrideAppliedBeforeAll"] = @(focusOverrideAppliedBeforeAll);
        if (focusOverrideBeforeAllPID > 0) {
            experimentInfo[@"focusOverrideBeforeAllPID"] = @(focusOverrideBeforeAllPID);
        }

        NSMutableDictionary *dispatchInfo = [NSMutableDictionary dictionary];
        dispatchInfo[@"ok"] = @(acceptedFocusedTarget);
        dispatchInfo[@"acceptedDispatches"] = @(acceptedDispatches);
        dispatchInfo[@"candidateCount"] = @(targetCandidates.count);
        dispatchInfo[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        dispatchInfo[@"attempts"] = routeAttempts;
        dispatchInfo[@"senderIDHex"] = [NSString stringWithFormat:@"0x%llX", selectedSenderID];
        dispatchInfo[@"senderIDSource"] = selectedSenderSource ?: @"unknown";
        dispatchInfo[@"senderIDCaptured"] = @([KimiRunTouchInjection senderIDCaptured]);
        dispatchInfo[@"senderIDCallbackCount"] = @([KimiRunTouchInjection senderIDCallbackCount]);
        dispatchInfo[@"senderIDDigitizerCount"] = @([KimiRunTouchInjection senderIDDigitizerCount]);
        dispatchInfo[@"senderIDLastEventType"] = @([KimiRunTouchInjection senderIDLastEventType]);
        dispatchInfo[@"senderIDCaptureThreadRunning"] = @([KimiRunTouchInjection senderIDCaptureThreadRunning]);
        dispatchInfo[@"senderIDMainRegistered"] = @([KimiRunTouchInjection senderIDMainRegistered]);
        dispatchInfo[@"senderIDDispatchRegistered"] = @([KimiRunTouchInjection senderIDDispatchRegistered]);
        uintptr_t hidConnectionPtr = [KimiRunTouchInjection hidConnectionPtr];
        dispatchInfo[@"hidConnectionPtr"] = @((unsigned long long)hidConnectionPtr);
        dispatchInfo[@"hidConnectionHex"] = [NSString stringWithFormat:@"0x%llX",
                                             (unsigned long long)hidConnectionPtr];
        if (chosenSource.length > 0) {
            dispatchInfo[@"chosenSource"] = chosenSource;
        }
        if (chosenDestination) {
            dispatchInfo[@"chosenDestination"] = chosenDestination;
        }
        if (chosenTargetClass.length > 0) {
            dispatchInfo[@"chosenTargetClass"] = chosenTargetClass;
        }
        dispatchInfo[@"chosenPID"] = @(chosenTargetPid);
        if (frontmostPid > 0) {
            dispatchInfo[@"frontmostPID"] = @(frontmostPid);
            dispatchInfo[@"chosenMatchesFrontmost"] = @(chosenTargetPid > 0 && chosenTargetPid == frontmostPid);
        }
        if (springboardPid > 0) {
            dispatchInfo[@"springBoardPID"] = @(springboardPid);
        }
        if (backboarddPid > 0) {
            dispatchInfo[@"backboarddPID"] = @(backboarddPid);
        }
        dispatchInfo[@"experiment"] = experimentInfo;
        if (!acceptedFocusedTarget) {
            dispatchInfo[@"reason"] = @"no_focused_or_router_acceptance";
        }
        KimiRunRecordBKSDispatchInfo(dispatchInfo);
        KimiRunLog([NSString stringWithFormat:@"[BKS] chosen source=%@ destination=%@ class=%@ pid=%d focusedAccepted=%@ accepted=%lu candidates=%lu",
                    chosenSource.length > 0 ? chosenSource : @"(none)",
                    chosenDestination ? [chosenDestination stringValue] : @"(none)",
                    chosenTargetClass.length > 0 ? chosenTargetClass : @"(none)",
                    chosenTargetPid,
                    acceptedFocusedTarget ? @"yes" : @"no",
                    (unsigned long)acceptedDispatches,
                    (unsigned long)targetCandidates.count]);

        BOOL postRouteDispatchSucceeded = NO;
        NSString *postRouteDispatchPath = nil;
        BOOL requirePostRouteDispatch = (postRouteDispatchEnabled || postRouteContextDispatchEnabled);
        if (acceptedFocusedTarget && requirePostRouteDispatch) {
            postRouteDispatchSucceeded = KimiRunBKSDispatchEventAfterRouting(event, &postRouteDispatchPath);
            if (!postRouteDispatchSucceeded) {
                KimiRunLog(@"[BKS] post-route event dispatch failed (no connection/client path)");
            }
        } else {
            postRouteDispatchSucceeded = YES;
        }

        dispatchInfo[@"eventDispatchSucceeded"] = @(postRouteDispatchSucceeded);
        if (postRouteDispatchPath.length > 0) {
            dispatchInfo[@"eventDispatchPath"] = postRouteDispatchPath;
        }

        if (acceptedFocusedTarget && postRouteDispatchSucceeded) {
            g_bksLastMeaningfulDispatch = YES;
            g_bksLastMeaningfulDispatchTime = CFAbsoluteTimeGetCurrent();
            NSLog(@"[KimiRunTouchInjection] BKS dispatch accepted on focused/router target");
            KimiRunLog([NSString stringWithFormat:@"[BKS] dispatch accepted on focused/router target (accepted=%lu)",
                        (unsigned long)acceptedDispatches]);
            return YES;
        }

        g_bksLastMeaningfulDispatch = NO;
        if (acceptedFocusedTarget && requirePostRouteDispatch && !postRouteDispatchSucceeded) {
            NSLog(@"[KimiRunTouchInjection] BKS routing accepted but post-route event dispatch failed");
            KimiRunLog([NSString stringWithFormat:@"[BKS] routing accepted but post-route dispatch failed (accepted=%lu)",
                        (unsigned long)acceptedDispatches]);
            KimiRunRecordBKSDispatchFailure(@"post_route_dispatch_failed");
        } else {
            NSLog(@"[KimiRunTouchInjection] BKS dispatch had no focused/router acceptance (accepted=%lu)",
                  (unsigned long)acceptedDispatches);
            KimiRunLog([NSString stringWithFormat:@"[BKS] no focused/router acceptance (accepted=%lu)",
                        (unsigned long)acceptedDispatches]);
        }
        return NO;
    } @catch (NSException *e) {
        g_bksLastMeaningfulDispatch = NO;
        NSLog(@"[KimiRunTouchInjection] BKS delivery exception: %@", e);
        KimiRunLog([NSString stringWithFormat:@"[BKS] delivery exception: %@ reason=%@",
                    e.name ?: @"(unknown)", e.reason ?: @"(no reason)"]);
        KimiRunRecordBKSDispatchFailure(@"delivery_exception");
        return NO;
    } @finally {
        if (canSetFocusTargetOverride && setFocusOverrideForAnyTarget) {
            @try {
                [(BKSHIDEventDeliveryManager *)g_bksSharedDeliveryManager _setFocusTargetOverride:nil];
            } @catch (NSException *e) {
                KimiRunLog([NSString stringWithFormat:@"[BKS] clear focus override exception: %@ reason=%@",
                            e.name ?: @"(unknown)",
                            e.reason ?: @"(no reason)"]);
            }
        }
        KimiRunInvalidateBKSAssertion(assertion);
    }
}

@end
#pragma clang diagnostic pop
