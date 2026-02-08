#import "TouchInjectionInternal.h"

#define PostBKSTouchEventPhase KimiRunPostBKSTouchEventPhase
#define PostSimulateTouchEvent KimiRunPostSimulateTouchEvent
#define PostSimulateTouchEventViaConnection KimiRunPostSimulateTouchEventViaConnection
#define PostLegacyTouchEventPhase KimiRunPostLegacyTouchEventPhase

// Extracted from TouchInjection.m: strategy resolution + dispatch routing
static NSString *KimiRunPrefString(NSString *key) {
    if (!key || key.length == 0) {
        return nil;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs stringForKey:key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL KimiRunPrefBool(NSString *key, BOOL defaultValue) {
    if (!key || key.length == 0) {
        return defaultValue;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs objectForKey:key];
    if (!value) {
        return defaultValue;
    }
    return [prefs boolForKey:key];
}

static BOOL KimiRunEnvBool(const char *key, BOOL defaultValue) {
    if (!key) {
        return defaultValue;
    }
    const char *value = getenv(key);
    if (!value || value[0] == '\0') {
        return defaultValue;
    }
    NSString *lower = [[[NSString stringWithUTF8String:value] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"on"]) {
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] || [lower isEqualToString:@"off"]) {
        return NO;
    }
    return defaultValue;
}

static BOOL KimiRunForceAXEnabled(void) {
    // Default to AX on-device unless explicitly disabled.
    // Non-AX paths can still be tested by setting KIMIRUN_FORCE_AX=0
    // or preference ForceAX=false.
    return KimiRunEnvBool("KIMIRUN_FORCE_AX",
                          KimiRunPrefBool(@"ForceAX", YES));
}

static NSString *KimiRunDefaultMethod(void) {
    const char *env = getenv("KIMIRUN_TOUCH_METHOD");
    if (env && env[0] != '\0') {
        return [NSString stringWithUTF8String:env];
    }
    return KimiRunPrefString(@"TouchMethod");
}

static NSString *KimiRunResolveMethod(NSString *method) {
    if ([method isKindOfClass:[NSString class]] && method.length > 0) {
        NSString *trimmedRequested = [method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *lowerRequested = [trimmedRequested lowercaseString];
        if (lowerRequested.length > 0) {
            // 'direct' always routes to SimulateTouch-style IOHID dispatch,
            // bypassing ForceAX. Requires EnableStrictNonAX at the HTTP layer.
            if ([lowerRequested isEqualToString:@"direct"]) {
                return @"direct";
            }
            // Preserve explicit routing requests even when ForceAX is enabled.
            // This allows strict method validation for sim/legacy/bks/zx paths.
            if ([lowerRequested isEqualToString:@"auto"] && KimiRunForceAXEnabled()) {
                return @"ax";
            }
            return lowerRequested;
        }
    }

    NSString *value = method;
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        value = KimiRunDefaultMethod();
    }
    if (KimiRunForceAXEnabled()) {
        return @"ax";
    }
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        return @"auto";
    }
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? [trimmed lowercaseString] : @"auto";
}

static BOOL KimiRunMethodRequiresVerifiedDelivery(NSString *lowerMethod) {
    if (![lowerMethod isKindOfClass:[NSString class]] || lowerMethod.length == 0) {
        return NO;
    }
    return ([lowerMethod isEqualToString:@"sim"] ||
            [lowerMethod isEqualToString:@"iohid"] ||
            [lowerMethod isEqualToString:@"direct"] ||
            [lowerMethod isEqualToString:@"legacy"] ||
            [lowerMethod isEqualToString:@"old"] ||
            [lowerMethod isEqualToString:@"conn"] ||
            [lowerMethod isEqualToString:@"connection"] ||
            [lowerMethod isEqualToString:@"bks"] ||
            [lowerMethod isEqualToString:@"zx"] ||
            [lowerMethod isEqualToString:@"zxtouch"]);
}

static BOOL KimiRunStrictRequireLiveSenderEnabled(void) {
    return KimiRunEnvBool("KIMIRUN_STRICT_REQUIRE_LIVE_SENDER",
                          KimiRunPrefBool(@"StrictRequireLiveSender", NO));
}

static BOOL KimiRunContextBindExperimentEnabled(void) {
    return KimiRunEnvBool("KIMIRUN_NONAX_CONTEXT_BIND",
                          KimiRunPrefBool(@"NonAXContextBind", NO));
}

static BOOL KimiRunSenderLikelyLiveForStrict(void) {
    BOOL localCaptured = [KimiRunTouchInjection senderIDCaptured];
    int localDigitizerCount = [KimiRunTouchInjection senderIDDigitizerCount];
    if (localCaptured && localDigitizerCount > 0) {
        return YES;
    }
    if ([KimiRunTouchInjection proxySenderLikelyLive] &&
        [KimiRunTouchInjection proxySenderDigitizerCount] > 0) {
        return YES;
    }
    return NO;
}

static BOOL KimiRunRejectUnverifiedExplicitResult(NSString *lowerMethod, NSString *backendTag) {
    if (!KimiRunMethodRequiresVerifiedDelivery(lowerMethod)) {
        return NO;
    }
    if (KimiRunStrictRequireLiveSenderEnabled() && !KimiRunSenderLikelyLiveForStrict()) {
        NSString *tag = backendTag ?: @"unknown";
        NSLog(@"[KimiRunTouchInjection] Rejecting strict result due to non-live sender method=%@ backend=%@",
              lowerMethod, tag);
        KimiRunLog([NSString stringWithFormat:@"[Delivery] rejected-nonlive-sender method=%@ backend=%@",
                    lowerMethod, tag]);
        return YES;
    }
    if (KimiRunContextBindExperimentEnabled()) {
        // In context-bind experiments, let daemon strict verifier be the source of truth.
        // This keeps explicit non-AX methods testable while still allowing live-sender gating above.
        NSString *tag = backendTag ?: @"unknown";
        KimiRunLog([NSString stringWithFormat:@"[Delivery] context-bind-pass method=%@ backend=%@",
                    lowerMethod, tag]);
        return NO;
    }
    NSString *tag = backendTag ?: @"unknown";
    NSLog(@"[KimiRunTouchInjection] Rejecting unverified explicit method result method=%@ backend=%@",
          lowerMethod, tag);
    KimiRunLog([NSString stringWithFormat:@"[Delivery] rejected-unverified method=%@ backend=%@",
                lowerMethod, tag]);
    return YES;
}

static BOOL DispatchPhaseWithOptions(KimiRunTouchPhase phase,
                                     CGFloat x,
                                     CGFloat y,
                                     BOOL wantSim,
                                     BOOL wantConn,
                                     BOOL wantLegacy,
                                     BOOL wantBKS,
                                     BOOL wantAX,
                                     BOOL allowFallback) {
    // Prefer BKS when requested (auto/ax), since IOHID dispatch can report success
    // even when the target process does not consume the event.
    if (wantBKS && PostBKSTouchEventPhase(phase, x, y)) {
        return YES;
    }
    if (wantSim && PostSimulateTouchEvent(phase, x, y)) {
        return YES;
    }
    if (wantConn && PostSimulateTouchEventViaConnection(phase, x, y)) {
        return YES;
    }
    if (wantLegacy && PostLegacyTouchEventPhase(phase, x, y)) {
        return YES;
    }
    if (wantAX) {
        // AX has reliable tap activation, but no native phase-based swipe/drag pipeline.
        // For gesture phases, fall back to in-process touch synthesis to keep auto/ax usable.
        if (PostSimulateTouchEvent(phase, x, y)) {
            return YES;
        }
        if (PostSimulateTouchEventViaConnection(phase, x, y)) {
            return YES;
        }
        if (PostLegacyTouchEventPhase(phase, x, y)) {
            return YES;
        }
        if (PostBKSTouchEventPhase(phase, x, y)) {
            return YES;
        }
        NSLog(@"[KimiRunTouchInjection] AX gesture fallback failed for phase=%d", (int)phase);
    }
    if (allowFallback) {
        if (!wantBKS && PostBKSTouchEventPhase(phase, x, y)) {
            return YES;
        }
        if (!wantSim && PostSimulateTouchEvent(phase, x, y)) {
            return YES;
        }
        if (!wantConn && PostSimulateTouchEventViaConnection(phase, x, y)) {
            return YES;
        }
        if (!wantLegacy && PostLegacyTouchEventPhase(phase, x, y)) {
            return YES;
        }
    }
    return NO;
}

#undef PostLegacyTouchEventPhase
#undef PostSimulateTouchEventViaConnection
#undef PostSimulateTouchEvent
#undef PostBKSTouchEventPhase

NSString *KimiRunTouchPrefString(NSString *key) {
    return KimiRunPrefString(key);
}

BOOL KimiRunTouchPrefBool(NSString *key, BOOL defaultValue) {
    return KimiRunPrefBool(key, defaultValue);
}

BOOL KimiRunTouchEnvBool(const char *key, BOOL defaultValue) {
    return KimiRunEnvBool(key, defaultValue);
}

NSString *KimiRunResolveTouchMethod(NSString *method) {
    return KimiRunResolveMethod(method);
}

BOOL KimiRunRejectUnverifiedTouchResult(NSString *lowerMethod, NSString *backendTag) {
    if (KimiRunStrictRequireLiveSenderEnabled() &&
        KimiRunMethodRequiresVerifiedDelivery(lowerMethod) &&
        !KimiRunSenderLikelyLiveForStrict()) {
        NSString *tag = backendTag ?: @"unknown";
        KimiRunLog([NSString stringWithFormat:@"[Delivery] rejected-nonlive-sender method=%@ backend=%@",
                    lowerMethod ?: @"(nil)", tag]);
        return YES;
    }
    if ([lowerMethod isEqualToString:@"bks"] &&
        ([backendTag isEqualToString:@"bks"] || [backendTag isEqualToString:@"dispatch"]) &&
        KimiRunBKSRecentMeaningfulDispatch(1.2)) {
        KimiRunLog(@"[Delivery] accepted verified bks dispatch");
        return NO;
    }
    return KimiRunRejectUnverifiedExplicitResult(lowerMethod, backendTag);
}

BOOL KimiRunDispatchPhase(KimiRunTouchPhase phase,
                          CGFloat x,
                          CGFloat y,
                          BOOL wantSim,
                          BOOL wantConn,
                          BOOL wantLegacy,
                          BOOL wantBKS,
                          BOOL wantAX,
                          BOOL allowFallback) {
    return DispatchPhaseWithOptions(phase, x, y, wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback);
}
