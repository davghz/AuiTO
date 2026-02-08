#import "TouchInjectionInternal.h"
#import <dlfcn.h>

static BOOL DispatchSimulateTouchEvent(IOHIDEventRef parent);
static BOOL DispatchSimulateTouchEventViaConnection(IOHIDEventRef parent);
static IOHIDEventRef CreateBKSTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y);
static void SimulateTouchSetParentFlags(IOHIDEventRef parent);
static uint64_t KimiRunPreferredBKSSenderID(void);
static NSString *KimiRunSimDispatchMode(void);
static NSString *KimiRunBKSEventMode(void);
static NSString *KimiRunSimEventMaskProfile(void);
static BOOL KimiRunNonAXContextBindEnabled(void);
static BOOL KimiRunNonAXSetSimpleDeliveryInfoEnabled(void);
static BOOL KimiRunNonAXVerboseEventDebugEnabled(void);
static BOOL KimiRunIsSpringBoardProcess(void);
static uint32_t KimiRunCurrentWindowContextID(void);
static BOOL KimiRunApplyBKSDigitizerInfoIfAvailable(IOHIDEventRef event);
static BOOL KimiRunDispatchEventWithContextBindInternal(IOHIDEventRef event, NSString **pathOut);

static const IOHIDEventField kKimiRunIOHIDEventFieldBuiltIn = (IOHIDEventField)0x000B0019;
static const IOHIDEventField kKimiRunIOHIDEventFieldLegacyBuiltIn = (IOHIDEventField)0x00000004;
static BKSHIDEventSetDigitizerInfoFunc g_BKSHIDEventSetDigitizerInfo = NULL;
static BKSHIDEventSendToFocusedProcessFunc g_BKSHIDEventSendToFocusedProcess = NULL;
static BKSHIDEventSetSimpleDeliveryInfoFunc g_BKSHIDEventSetSimpleDeliveryInfo = NULL;
static BKSHIDEventGetContextIDFromEventFunc g_BKSHIDEventGetContextIDFromEvent = NULL;
static BKSHIDEventGetTouchStreamIdentifierFunc g_BKSHIDEventGetTouchStreamIdentifier = NULL;
static BKSHIDEventCopyDisplayIDFromEventFunc g_BKSHIDEventCopyDisplayIDFromEvent = NULL;
static BKSHIDEventGetClientIdentifierFunc g_BKSHIDEventGetClientIdentifier = NULL;
static BKSHIDEventGetClientPidFunc g_BKSHIDEventGetClientPid = NULL;
static BKSHIDEventDigitizerGetTouchIdentifierFunc g_BKSHIDEventDigitizerGetTouchIdentifier = NULL;
static BKSHIDEventGetPointFromDigitizerEventFunc g_BKSHIDEventGetPointFromDigitizerEvent = NULL;
static BKSHIDEventGetMaximumForceFromDigitizerEventFunc g_BKSHIDEventGetMaximumForceFromDigitizerEvent = NULL;
static BKSHIDEventDescriptionFunc g_BKSHIDEventDescription = NULL;
static dispatch_once_t g_BackBoardTouchSPILoadOnce;
static BOOL g_ContextBindNonSpringBoardLogged = NO;

// Extracted from TouchInjection.m: IOHID event building + low-level posting
// Normalize coordinates to 0.0-1.0 range for IOHIDEvent
static void NormalizeCoordinates(CGFloat x, CGFloat y, float *normX, float *normY) {
    if (g_screenWidth <= 0 || g_screenHeight <= 0) {
        UpdateScreenMetrics();
    }

    *normX = (float)(x / g_screenWidth);
    *normY = (float)(y / g_screenHeight);

    // Clamp to valid range
    *normX = fmaxf(0.0f, fminf(1.0f, *normX));
    *normY = fmaxf(0.0f, fminf(1.0f, *normY));
}

static uint64_t KimiRunPreferredBKSSenderID(void) {
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
            return sender;
        }
    }
    if (proxyLikelyLive) {
        return proxySender;
    }
    if (g_senderFallbackEnabled) {
        return kTouchSenderID;
    }
    return kBKSSenderID;
}

static NSString *KimiRunBKSEventMode(void) {
    NSString *raw = KimiRunTouchEnvOrPrefString("KIMIRUN_BKS_EVENT_MODE",
                                                @"BKSEventMode",
                                                @"sim_parent");
    if (![raw isKindOfClass:[NSString class]]) {
        return @"sim_parent";
    }
    NSString *lower = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"legacy"] || [lower isEqualToString:@"legacy_hand"]) {
        return @"legacy_hand";
    }
    return @"sim_parent";
}

static NSString *KimiRunSimEventMaskProfile(void) {
    NSString *raw = KimiRunTouchEnvOrPrefString("KIMIRUN_SIM_EVENT_MASK_PROFILE",
                                                @"SimEventMaskProfile",
                                                @"legacy_raw");
    if (![raw isKindOfClass:[NSString class]]) {
        return @"legacy_raw";
    }
    NSString *lower = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"xxtouch"] || [lower isEqualToString:@"xxtouch_masked"]) {
        return @"xxtouch";
    }
    return @"legacy_raw";
}

static BOOL KimiRunUseXXTouchMaskProfile(void) {
    return [[KimiRunSimEventMaskProfile() lowercaseString] isEqualToString:@"xxtouch"];
}

static IOHIDDigitizerEventMask KimiRunSimulateTouchParentEventMask(KimiRunTouchPhase phase) {
    switch (phase) {
        case KimiRunTouchPhaseDown:
        case KimiRunTouchPhaseUp:
            return (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity);
        case KimiRunTouchPhaseMove:
            return (kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventAttribute);
    }
    return 0;
}

static IOHIDDigitizerEventMask KimiRunSimulateTouchChildEventMask(KimiRunTouchPhase phase) {
    switch (phase) {
        case KimiRunTouchPhaseDown:
        case KimiRunTouchPhaseUp:
            return (kIOHIDDigitizerEventTouch |
                    kIOHIDDigitizerEventRange |
                    kIOHIDDigitizerEventIdentity);
        case KimiRunTouchPhaseMove:
            return (kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventAttribute);
    }
    return 0;
}

static NSString *KimiRunSimDispatchMode(void) {
    NSString *raw = KimiRunTouchEnvOrPrefString("KIMIRUN_SIM_DISPATCH_MODE",
                                                @"SimDispatchMode",
                                                @"all");
    if (![raw isKindOfClass:[NSString class]]) {
        return @"all";
    }
    NSString *lower = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"sim"] || [lower isEqualToString:@"sim_only"]) {
        return @"sim_only";
    }
    if ([lower isEqualToString:@"hid"] || [lower isEqualToString:@"hid_only"]) {
        return @"hid_only";
    }
    if ([lower isEqualToString:@"admin"] || [lower isEqualToString:@"admin_only"]) {
        return @"admin_only";
    }
    if ([lower isEqualToString:@"legacy_client"] || [lower isEqualToString:@"legacy"]) {
        return @"legacy_client";
    }
    return @"all";
}

static void KimiRunLoadBackBoardTouchSPIs(void) {
    dispatch_once(&g_BackBoardTouchSPILoadOnce, ^{
        void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (!bbs) {
            return;
        }
        g_BKSHIDEventSetDigitizerInfo = (BKSHIDEventSetDigitizerInfoFunc)dlsym(bbs, "BKSHIDEventSetDigitizerInfo");
        g_BKSHIDEventSendToFocusedProcess = (BKSHIDEventSendToFocusedProcessFunc)dlsym(bbs, "BKSHIDEventSendToFocusedProcess");
        g_BKSHIDEventSetSimpleDeliveryInfo =
            (BKSHIDEventSetSimpleDeliveryInfoFunc)dlsym(bbs, "BKSHIDEventSetSimpleDeliveryInfo");
        g_BKSHIDEventGetContextIDFromEvent =
            (BKSHIDEventGetContextIDFromEventFunc)dlsym(bbs, "BKSHIDEventGetContextIDFromEvent");
        g_BKSHIDEventGetTouchStreamIdentifier =
            (BKSHIDEventGetTouchStreamIdentifierFunc)dlsym(bbs, "BKSHIDEventGetTouchStreamIdentifier");
        g_BKSHIDEventCopyDisplayIDFromEvent =
            (BKSHIDEventCopyDisplayIDFromEventFunc)dlsym(bbs, "BKSHIDEventCopyDisplayIDFromEvent");
        g_BKSHIDEventGetClientIdentifier =
            (BKSHIDEventGetClientIdentifierFunc)dlsym(bbs, "BKSHIDEventGetClientIdentifier");
        g_BKSHIDEventGetClientPid =
            (BKSHIDEventGetClientPidFunc)dlsym(bbs, "BKSHIDEventGetClientPid");
        g_BKSHIDEventDigitizerGetTouchIdentifier =
            (BKSHIDEventDigitizerGetTouchIdentifierFunc)dlsym(bbs, "BKSHIDEventDigitizerGetTouchIdentifier");
        g_BKSHIDEventGetPointFromDigitizerEvent =
            (BKSHIDEventGetPointFromDigitizerEventFunc)dlsym(bbs, "BKSHIDEventGetPointFromDigitizerEvent");
        g_BKSHIDEventGetMaximumForceFromDigitizerEvent =
            (BKSHIDEventGetMaximumForceFromDigitizerEventFunc)dlsym(bbs, "BKSHIDEventGetMaximumForceFromDigitizerEvent");
        g_BKSHIDEventDescription =
            (BKSHIDEventDescriptionFunc)dlsym(bbs, "BKSHIDEventDescription");
    });
}

static BOOL KimiRunNonAXContextBindEnabled(void) {
    return KimiRunTouchEnvBool("KIMIRUN_NONAX_CONTEXT_BIND",
                               KimiRunTouchPrefBool(@"NonAXContextBind", NO));
}

static BOOL KimiRunNonAXSetSimpleDeliveryInfoEnabled(void) {
    return KimiRunTouchEnvBool("KIMIRUN_NONAX_SET_SIMPLE_DELIVERY_INFO",
                               KimiRunTouchPrefBool(@"NonAXSetSimpleDeliveryInfo", NO));
}

static BOOL KimiRunNonAXVerboseEventDebugEnabled(void) {
    return KimiRunTouchEnvBool("KIMIRUN_NONAX_VERBOSE_EVENT_DEBUG",
                               KimiRunTouchPrefBool(@"NonAXVerboseEventDebug", NO));
}

static BOOL KimiRunIsSpringBoardProcess(void) {
    static dispatch_once_t onceToken;
    static BOOL isSpringBoard = NO;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *processName = [[NSProcessInfo processInfo] processName];
        isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"] ||
                        [processName isEqualToString:@"SpringBoard"];
    });
    return isSpringBoard;
}

static uint32_t KimiRunCurrentWindowContextID(void) {
    Class uiAppClass = NSClassFromString(@"UIApplication");
    SEL sharedAppSel = @selector(sharedApplication);
    if (!uiAppClass || ![uiAppClass respondsToSelector:sharedAppSel]) {
        return 0;
    }

    id app = nil;
    @try {
        app = ((id (*)(id, SEL))objc_msgSend)(uiAppClass, sharedAppSel);
    } @catch (NSException *e) {
        return 0;
    }
    if (!app) {
        return 0;
    }

    id keyWindow = nil;
    SEL keyWindowSel = @selector(keyWindow);
    if ([app respondsToSelector:keyWindowSel]) {
        @try {
            keyWindow = ((id (*)(id, SEL))objc_msgSend)(app, keyWindowSel);
        } @catch (NSException *e) {
            keyWindow = nil;
        }
    }
    if (!keyWindow) {
        SEL windowsSel = @selector(windows);
        if ([app respondsToSelector:windowsSel]) {
            @try {
                NSArray *windows = ((id (*)(id, SEL))objc_msgSend)(app, windowsSel);
                if ([windows isKindOfClass:[NSArray class]]) {
                    for (id window in windows) {
                        if (!window) {
                            continue;
                        }
                        SEL isKeyWindowSel = @selector(isKeyWindow);
                        if ([window respondsToSelector:isKeyWindowSel]) {
                            BOOL isKey = ((BOOL (*)(id, SEL))objc_msgSend)(window, isKeyWindowSel);
                            if (isKey) {
                                keyWindow = window;
                                break;
                            }
                        }
                    }
                    if (!keyWindow && windows.count > 0) {
                        keyWindow = windows.firstObject;
                    }
                }
            } @catch (NSException *e) {
                keyWindow = nil;
            }
        }
    }
    if (!keyWindow) {
        return 0;
    }

    @try {
        SEL contextIdSel = @selector(_contextId);
        if ([keyWindow respondsToSelector:contextIdSel]) {
            return ((uint32_t (*)(id, SEL))objc_msgSend)(keyWindow, contextIdSel);
        }
        SEL contextIDSel = @selector(_contextID);
        if ([keyWindow respondsToSelector:contextIDSel]) {
            return ((uint32_t (*)(id, SEL))objc_msgSend)(keyWindow, contextIDSel);
        }
        return 0;
    } @catch (NSException *e) {
        return 0;
    }
}

static BOOL KimiRunApplyBKSDigitizerInfoIfAvailable(IOHIDEventRef event) {
    if (!event) {
        return NO;
    }
    KimiRunLoadBackBoardTouchSPIs();
    if (!g_BKSHIDEventSetDigitizerInfo) {
        return NO;
    }
    uint32_t contextID = KimiRunCurrentWindowContextID();
    g_BKSHIDEventSetDigitizerInfo(event, contextID, 0, 0, NULL, 0.0, 0.0);
    if (KimiRunNonAXSetSimpleDeliveryInfoEnabled() && g_BKSHIDEventSetSimpleDeliveryInfo) {
        // Keep source/display conservative for runtime safety; contextID is the important binding signal.
        g_BKSHIDEventSetSimpleDeliveryInfo(event, 0, contextID, NULL);
    }
    if (contextID == 0) {
        KimiRunLog(@"[ContextBind] BKSHIDEventSetDigitizerInfo contextID=0 (fallback)");
    } else {
        KimiRunLog([NSString stringWithFormat:@"[ContextBind] BKSHIDEventSetDigitizerInfo contextID=%u",
                    contextID]);
    }
    if (g_BKSHIDEventGetContextIDFromEvent) {
        uint32_t reflectedContextID = g_BKSHIDEventGetContextIDFromEvent(event);
        KimiRunLog([NSString stringWithFormat:@"[ContextBind] reflected contextID=%u",
                    reflectedContextID]);
    }
    if (g_BKSHIDEventGetTouchStreamIdentifier) {
        uint64_t streamID = g_BKSHIDEventGetTouchStreamIdentifier(event);
        KimiRunLog([NSString stringWithFormat:@"[ContextBind] touchStreamIdentifier=0x%llX",
                    (unsigned long long)streamID]);
    }
    if (g_BKSHIDEventGetClientIdentifier) {
        int32_t clientIdentifier = g_BKSHIDEventGetClientIdentifier(event);
        KimiRunLog([NSString stringWithFormat:@"[ContextBind] clientIdentifier=%d",
                    (int)clientIdentifier]);
    }
    if (g_BKSHIDEventGetClientPid) {
        pid_t clientPid = g_BKSHIDEventGetClientPid(event);
        KimiRunLog([NSString stringWithFormat:@"[ContextBind] clientPid=%d",
                    (int)clientPid]);
    }
    if (g_BKSHIDEventCopyDisplayIDFromEvent) {
        CFStringRef displayID = g_BKSHIDEventCopyDisplayIDFromEvent(event);
        if (displayID) {
            KimiRunLog([NSString stringWithFormat:@"[ContextBind] displayID=%@",
                        (__bridge NSString *)displayID]);
            CFRelease(displayID);
        }
    }
    if (KimiRunNonAXVerboseEventDebugEnabled()) {
        if (g_BKSHIDEventDigitizerGetTouchIdentifier) {
            uint32_t touchIdentifier = g_BKSHIDEventDigitizerGetTouchIdentifier(event);
            KimiRunLog([NSString stringWithFormat:@"[ContextBind] touchIdentifier=%u",
                        touchIdentifier]);
        }
        if (g_BKSHIDEventGetPointFromDigitizerEvent) {
            CGPoint point = g_BKSHIDEventGetPointFromDigitizerEvent(event);
            KimiRunLog([NSString stringWithFormat:@"[ContextBind] eventPoint=(%.3f, %.3f)",
                        point.x, point.y]);
        }
        if (g_BKSHIDEventGetMaximumForceFromDigitizerEvent) {
            double maximumForce = g_BKSHIDEventGetMaximumForceFromDigitizerEvent(event);
            KimiRunLog([NSString stringWithFormat:@"[ContextBind] maxForce=%.4f",
                        maximumForce]);
        }
        if (g_BKSHIDEventDescription) {
            CFStringRef eventDescription = g_BKSHIDEventDescription(event);
            if (eventDescription) {
                KimiRunLog([NSString stringWithFormat:@"[ContextBind] eventDescription=%@",
                            (__bridge NSString *)eventDescription]);
                CFRelease(eventDescription);
            }
        }
    }
    return YES;
}

static BOOL KimiRunDispatchEventWithContextBindInternal(IOHIDEventRef event, NSString **pathOut) {
    if (pathOut) {
        *pathOut = nil;
    }
    if (!event || !KimiRunNonAXContextBindEnabled()) {
        return NO;
    }
    if (!KimiRunIsSpringBoardProcess()) {
        if (!g_ContextBindNonSpringBoardLogged) {
            g_ContextBindNonSpringBoardLogged = YES;
            NSLog(@"[KimiRunTouchInjection] Context bind disabled outside SpringBoard process");
        }
        if (pathOut) {
            *pathOut = @"disabled_non_springboard";
        }
        return NO;
    }

    // Ensure sender ID is populated before UIApplication/backboard consumption.
    if (_IOHIDEventSetSenderID && _IOHIDEventGetSenderID) {
        uint64_t sender = _IOHIDEventGetSenderID(event);
        if (sender == 0) {
            _IOHIDEventSetSenderID(event, KimiRunPreferredBKSSenderID());
        }
    }
    KimiRunApplyBKSDigitizerInfoIfAvailable(event);

    Class uiAppClass = NSClassFromString(@"UIApplication");
    SEL sharedAppSel = @selector(sharedApplication);
    SEL enqueueSel = @selector(_enqueueHIDEvent:);
    if (uiAppClass && [uiAppClass respondsToSelector:sharedAppSel]) {
        @try {
            id app = ((id (*)(id, SEL))objc_msgSend)(uiAppClass, sharedAppSel);
            if (app && [app respondsToSelector:enqueueSel]) {
                ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, enqueueSel, event);
                if (pathOut) {
                    *pathOut = @"app_enqueue_hid_event";
                }
                return YES;
            }
        } @catch (NSException *e) {
            NSLog(@"[KimiRunTouchInjection] Context bind enqueue exception: %@", e);
        }
    }

    KimiRunLoadBackBoardTouchSPIs();
    if (g_BKSHIDEventSendToFocusedProcess) {
        g_BKSHIDEventSendToFocusedProcess(event);
        if (pathOut) {
            *pathOut = @"bks_send_to_focused_process";
        }
        return YES;
    }
    return NO;
}

// Dispatch event to system
static BOOL DispatchEvent(IOHIDEventRef event) {
    NSLog(@"[KimiRunTouchInjection] DispatchEvent called");

    if (!event) {
        NSLog(@"[KimiRunTouchInjection] DispatchEvent: event is NULL");
        return NO;
    }
    if (!g_hidClient) {
        NSLog(@"[KimiRunTouchInjection] DispatchEvent: hidClient is NULL");
        return NO;
    }
    if (!_IOHIDEventSystemClientDispatchEvent) {
        NSLog(@"[KimiRunTouchInjection] DispatchEvent: dispatch function not loaded");
        return NO;
    }

    // Notify BKUserEventTimer first
    NSLog(@"[KimiRunTouchInjection] Notifying BKUserEventTimer...");
    NotifyUserEvent();

    // Dispatch the event
    NSLog(@"[KimiRunTouchInjection] Dispatching event via IOHIDEventSystemClient (client=%p, event=%p)", g_hidClient, event);
    _IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
    NSLog(@"[KimiRunTouchInjection] Event dispatched");

    return YES;
}

// Create touch event (HAND parent with FINGER child) - legacy path
static IOHIDEventRef CreateTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    NSLog(@"[KimiRunTouchInjection] CreateTouchEvent phase=%d at (%.1f, %.1f)", (int)phase, x, y);
    
    if (!_IOHIDEventCreateDigitizerEvent) {
        NSLog(@"[KimiRunTouchInjection] ERROR: _IOHIDEventCreateDigitizerEvent is NULL");
        return NULL;
    }
    if (!_IOHIDEventCreateDigitizerFingerEvent) {
        NSLog(@"[KimiRunTouchInjection] ERROR: _IOHIDEventCreateDigitizerFingerEvent is NULL");
        return NULL;
    }
    
    // Normalize coordinates
    float normX, normY;
    NormalizeCoordinates(x, y, &normX, &normY);
    NSLog(@"[KimiRunTouchInjection] Normalized: (%.3f, %.3f)", normX, normY);
    
    // Determine phase-specific properties
    uint32_t eventMask = 0;
    BOOL inRange = YES;
    BOOL touch = YES;
    float pressure = 1.0f;
    uint32_t touchCount = 1;
    
    switch (phase) {
        case KimiRunTouchPhaseDown:
            eventMask = (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition);
            inRange = YES;
            touch = YES;
            pressure = 1.0f;
            touchCount = 1;
            break;
        case KimiRunTouchPhaseMove:
            eventMask = (kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventTouch);
            inRange = YES;
            touch = YES;
            pressure = 1.0f;
            touchCount = 1;
            break;
        case KimiRunTouchPhaseUp:
            eventMask = (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition);
            inRange = NO;
            touch = NO;
            pressure = 0.0f;
            touchCount = 0;
            break;
    }
    // iOS 13.2.3 requires identity flag in digitizer event mask
    eventMask |= kIOHIDDigitizerEventIdentity;
    
    NSLog(@"[KimiRunTouchInjection] Creating HAND event: mask=0x%02X, range=%d, touch=%d, pressure=%.1f", eventMask, inRange, touch, pressure);
    
    // Create parent HAND event
    IOHIDEventRef handEvent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timestamp,
        kTransducerTypeHand,
        0,                          // index
        0,                          // identity
        eventMask,
        0,                          // buttonMask
        normX, normY, 0.0f,         // x, y, z
        pressure,
        0.0f,                       // barrelPressure
        inRange,
        touch,
        0                           // options
    );
    
    if (!handEvent) {
        NSLog(@"[KimiRunTouchInjection] ERROR: Failed to create hand event");
        return NULL;
    }
    NSLog(@"[KimiRunTouchInjection] Hand event created: %p", handEvent);
    
    // Set hand event properties
    if (_IOHIDEventSetIntegerValue) {
        _IOHIDEventSetIntegerValue(handEvent, kKimiRunIOHIDEventFieldBuiltIn, 1);
        _IOHIDEventSetIntegerValue(handEvent, kKimiRunIOHIDEventFieldLegacyBuiltIn, 1);
        _IOHIDEventSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        _IOHIDEventSetIntegerValue(handEvent, 0x00040005, touchCount);  // field + 5 = touch count
        _IOHIDEventSetIntegerValue(handEvent, 0x0004000C, 1);           // field + 12
        NSLog(@"[KimiRunTouchInjection] Set hand event properties: touchCount=%d", touchCount);
    } else {
        NSLog(@"[KimiRunTouchInjection] WARNING: _IOHIDEventSetIntegerValue not available");
    }
    
    // Create child FINGER event
    IOHIDEventRef fingerEvent = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,
        timestamp,
        1,                          // index
        2,                          // identity
        eventMask,
        normX, normY, 0.0f,
        pressure,
        0.0f,                       // twist
        inRange,
        touch,
        0                           // options
    );
    
    if (fingerEvent) {
        // Set finger radius
        if (_IOHIDEventSetFloatValue) {
            _IOHIDEventSetFloatValue(fingerEvent, kIOHIDEventFieldDigitizerMajorRadius, 0.04);
            _IOHIDEventSetFloatValue(fingerEvent, kIOHIDEventFieldDigitizerMinorRadius, 0.04);
        }
        
        // Append finger to hand
        if (_IOHIDEventAppendEvent) {
            _IOHIDEventAppendEvent(handEvent, fingerEvent, true);
        }
        CFRelease(fingerEvent);
    }
    
    // Set sender ID (CRITICAL for event routing)
    if (_IOHIDEventSetSenderID) {
        _IOHIDEventSetSenderID(handEvent, kTouchSenderID);
    }
    
    return handEvent;
}

// SimulateTouch-style parent event
static IOHIDEventRef CreateSimulateTouchParentEvent(uint64_t timestamp, KimiRunTouchPhase phase) {
    if (!_IOHIDEventCreateDigitizerEvent) {
        return NULL;
    }

    BOOL useXXTouchMaskProfile = KimiRunUseXXTouchMaskProfile();
    IOHIDDigitizerEventMask eventMask = useXXTouchMaskProfile
        ? KimiRunSimulateTouchParentEventMask(phase)
        : 0;
    BOOL isTouching = useXXTouchMaskProfile ? (phase != KimiRunTouchPhaseUp) : NO;

    IOHIDEventRef parent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault,
        timestamp,
        3,      // type
        99,     // index
        1,      // identity
        eventMask,
        0,      // buttonMask
        0.0f, 0.0f, 0.0f, // x, y, z
        0.0f,           // pressure
        0.0f,           // barrelPressure
        0,              // range
        isTouching,     // touch
        0               // options
    );

    if (!parent) {
        return NULL;
    }

    if (_IOHIDEventSetIntegerValue) {
        _IOHIDEventSetIntegerValue(parent, kKimiRunIOHIDEventFieldBuiltIn, 1);
        _IOHIDEventSetIntegerValue(parent, kKimiRunIOHIDEventFieldLegacyBuiltIn, 1);
        _IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
    }

    return parent;
}

// SimulateTouch-style child event
static IOHIDEventRef CreateSimulateTouchChildEvent(KimiRunTouchPhase phase, int index, float x, float y) {
    if (!_IOHIDEventCreateDigitizerFingerEvent) {
        return NULL;
    }
    if (g_screenWidth <= 0 || g_screenHeight <= 0) {
        if (!UpdateScreenMetrics()) {
            return NULL;
        }
    }

    BOOL useXXTouchMaskProfile = KimiRunUseXXTouchMaskProfile();
    uint32_t eventMask = 0;
    BOOL inRange = YES;
    BOOL touch = YES;
    if (useXXTouchMaskProfile) {
        eventMask = (uint32_t)KimiRunSimulateTouchChildEventMask(phase);
        switch (phase) {
            case KimiRunTouchPhaseDown:
                inRange = YES;
                touch = YES;
                break;
            case KimiRunTouchPhaseMove:
                inRange = YES;
                touch = YES;
                break;
            case KimiRunTouchPhaseUp:
                inRange = NO;
                touch = NO;
                break;
        }
    } else {
        // Legacy SimulateTouch mask profile (3/4/2).
        switch (phase) {
            case KimiRunTouchPhaseDown:
                eventMask = 3;
                inRange = YES;
                touch = YES;
                break;
            case KimiRunTouchPhaseMove:
                eventMask = 4;
                inRange = YES;
                touch = YES;
                break;
            case KimiRunTouchPhaseUp:
                eventMask = 2;
                inRange = NO;
                touch = NO;
                break;
        }
    }

    IOHIDEventRef child = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault,
        GetCurrentTimestamp(),
        index,
        3, // identity
        eventMask,
        x / g_screenWidth,
        y / g_screenHeight,
        0.0f,
        0.0f,
        0.0f,
        inRange,
        touch,
        0
    );

    if (child && _IOHIDEventSetFloatValue) {
        _IOHIDEventSetFloatValue(child, 0xb0014, 0.04f);
        _IOHIDEventSetFloatValue(child, 0xb0015, 0.04f);
    }

    return child;
}

static IOHIDEventRef CreateBKSTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    NSString *eventMode = KimiRunBKSEventMode();
    if ([eventMode isEqualToString:@"legacy_hand"]) {
        // Experiment: feed BKS using legacy hand+finger payload to match older consuming paths.
        IOHIDEventRef legacy = CreateTouchEvent(timestamp, phase, x, y);
        if (legacy && _IOHIDEventSetSenderID) {
            _IOHIDEventSetSenderID(legacy, KimiRunPreferredBKSSenderID());
        }
        return legacy;
    }

    IOHIDEventRef parent = CreateSimulateTouchParentEvent(timestamp, phase);
    if (!parent) {
        return NULL;
    }

    IOHIDEventRef child = CreateSimulateTouchChildEvent(phase, kSimulateTouchPrimaryFingerIndex, (float)x, (float)y);
    if (!child) {
        CFRelease(parent);
        return NULL;
    }

    if (_IOHIDEventAppendEvent) {
        _IOHIDEventAppendEvent(parent, child, true);
    }
    CFRelease(child);

    SimulateTouchSetParentFlags(parent);
    if (_IOHIDEventSetIntegerValue) {
        BOOL isTouching = (phase != KimiRunTouchPhaseUp);
        _IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        _IOHIDEventSetIntegerValue(parent, 0x00040005, isTouching ? 1 : 0);
        _IOHIDEventSetIntegerValue(parent, 0x0004000C, 1);
    }
    if (_IOHIDEventSetSenderID) {
        _IOHIDEventSetSenderID(parent, KimiRunPreferredBKSSenderID());
    }
    return parent;
}

static void SimulateTouchSetParentFlags(IOHIDEventRef parent) {
    if (!_IOHIDEventSetIntegerValue || !parent) {
        return;
    }
    _IOHIDEventSetIntegerValue(parent, 0xb0007, 0x23);
    _IOHIDEventSetIntegerValue(parent, 0xb0008, 0x1);
    _IOHIDEventSetIntegerValue(parent, 0xb0009, 0x1);
}

static BOOL SimulateTouchValidFingerIndex(int index) {
    return (index >= 0 && index < kSimulateTouchMaxFingerIndex);
}

static void SimulateTouchTrackEvent(KimiRunTouchPhase phase, int index, CGFloat x, CGFloat y) {
    if (!SimulateTouchValidFingerIndex(index)) {
        return;
    }
    switch (phase) {
        case KimiRunTouchPhaseDown:
        case KimiRunTouchPhaseMove:
            g_simEventsToAppend[index][kSimTouchValidIndex] = KimiRunSimTouchValidAtNextAppend;
            g_simEventsToAppend[index][kSimTouchPhaseIndex] = (int)phase;
            g_simEventsToAppend[index][kSimTouchXIndex] = (int)llround(x);
            g_simEventsToAppend[index][kSimTouchYIndex] = (int)llround(y);
            break;
        case KimiRunTouchPhaseUp:
            g_simEventsToAppend[index][kSimTouchValidIndex] = KimiRunSimTouchInvalid;
            break;
    }
}

static void SimulateTouchAppendTrackedEvents(IOHIDEventRef parent) {
    if (!parent || !_IOHIDEventAppendEvent) {
        return;
    }
    for (int i = 0; i < kSimulateTouchMaxFingerIndex; i++) {
        if (g_simEventsToAppend[i][kSimTouchValidIndex] == KimiRunSimTouchValid) {
            KimiRunTouchPhase phase = (KimiRunTouchPhase)g_simEventsToAppend[i][kSimTouchPhaseIndex];
            CGFloat x = (CGFloat)g_simEventsToAppend[i][kSimTouchXIndex];
            CGFloat y = (CGFloat)g_simEventsToAppend[i][kSimTouchYIndex];
            IOHIDEventRef child = CreateSimulateTouchChildEvent(phase, i, (float)x, (float)y);
            if (child) {
                _IOHIDEventAppendEvent(parent, child, true);
                CFRelease(child);
            }
        } else if (g_simEventsToAppend[i][kSimTouchValidIndex] == KimiRunSimTouchValidAtNextAppend) {
            g_simEventsToAppend[i][kSimTouchValidIndex] = KimiRunSimTouchValid;
        }
    }
}

static BOOL PostSimulateTouchEventInternal(KimiRunTouchPhase phase, int fingerIndex, CGFloat x, CGFloat y, BOOL viaConnection) {
    uint64_t timestamp = GetCurrentTimestamp();
    IOHIDEventRef parent = CreateSimulateTouchParentEvent(timestamp, phase);
    if (!parent) {
        return NO;
    }

    IOHIDEventRef child = CreateSimulateTouchChildEvent(phase, fingerIndex, (float)x, (float)y);
    if (child && _IOHIDEventAppendEvent) {
        _IOHIDEventAppendEvent(parent, child, true);
        CFRelease(child);
    }

    SimulateTouchTrackEvent(phase, fingerIndex, x, y);
    SimulateTouchAppendTrackedEvents(parent);
    SimulateTouchSetParentFlags(parent);
    BOOL ok = viaConnection ? DispatchSimulateTouchEventViaConnection(parent) : DispatchSimulateTouchEvent(parent);
    CFRelease(parent);
    return ok;
}

static BOOL DispatchSimulateTouchEvent(IOHIDEventRef parent) {
    if (!parent) {
        return NO;
    }
    if (!_IOHIDEventSystemClientDispatchEvent) {
        return NO;
    }
    if (!_IOHIDEventSetSenderID) {
        return NO;
    }
    uint64_t sender = g_senderID;
    if (sender == 0 && g_senderFallbackEnabled) {
        sender = kTouchSenderID;
        NSLog(@"[KimiRunTouchInjection] Using fallback senderID: 0x%llX", sender);
    } else if (sender == 0) {
        NSLog(@"[KimiRunTouchInjection] SimulateTouch senderID is 0 (not ready)");
        return NO;
    }
    _IOHIDEventSetSenderID(parent, sender);
    NSString *contextDispatchPath = nil;
    if (KimiRunDispatchEventWithContextBindInternal(parent, &contextDispatchPath)) {
        NSLog(@"[KimiRunTouchInjection] SimulateTouch context-bind dispatch path=%@",
              contextDispatchPath ?: @"unknown");
        return YES;
    }
    NSString *dispatchMode = KimiRunSimDispatchMode();
    BOOL dispatched = NO;
    if ([dispatchMode isEqualToString:@"legacy_client"]) {
        static IOHIDEventSystemClientRef s_legacyDispatchClient = NULL;
        if (!s_legacyDispatchClient && _IOHIDEventSystemClientCreate) {
            s_legacyDispatchClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (s_legacyDispatchClient) {
                NSLog(@"[KimiRunTouchInjection] Sim dispatch legacy client created: %p", s_legacyDispatchClient);
            }
        }
        if (s_legacyDispatchClient) {
            _IOHIDEventSystemClientDispatchEvent(s_legacyDispatchClient, parent);
            dispatched = YES;
        }
    } else if ([dispatchMode isEqualToString:@"sim_only"]) {
        if (g_simClient) {
            _IOHIDEventSystemClientDispatchEvent(g_simClient, parent);
            dispatched = YES;
        }
    } else if ([dispatchMode isEqualToString:@"hid_only"]) {
        if (g_hidClient) {
            _IOHIDEventSystemClientDispatchEvent(g_hidClient, parent);
            dispatched = YES;
        }
    } else if ([dispatchMode isEqualToString:@"admin_only"]) {
        if (g_adminClient) {
            _IOHIDEventSystemClientDispatchEvent(g_adminClient, parent);
            dispatched = YES;
        }
    } else {
        // Default behavior: try all available clients.
        if (g_simClient) {
            _IOHIDEventSystemClientDispatchEvent(g_simClient, parent);
            dispatched = YES;
        }
        if (g_hidClient) {
            _IOHIDEventSystemClientDispatchEvent(g_hidClient, parent);
            dispatched = YES;
        }
        if (g_adminClient) {
            _IOHIDEventSystemClientDispatchEvent(g_adminClient, parent);
            dispatched = YES;
        }
    }
    return dispatched;
}

static BOOL DispatchSimulateTouchEventViaConnection(IOHIDEventRef parent) {
    if (!parent || !_IOHIDEventSystemConnectionDispatchEvent) {
        return NO;
    }
    if (!_IOHIDEventSetSenderID) {
        return NO;
    }
    uint64_t sender = g_senderID;
    if (sender == 0 && g_senderFallbackEnabled) {
        sender = kTouchSenderID;
        NSLog(@"[KimiRunTouchInjection] Using fallback senderID (conn): 0x%llX", sender);
    } else if (sender == 0) {
        NSLog(@"[KimiRunTouchInjection] SimulateTouch senderID is 0 (conn not ready)");
        return NO;
    }
    _IOHIDEventSetSenderID(parent, sender);

    BOOL dispatched = NO;
    UpdateHIDConnection();
    if (g_hidConnection) {
        _IOHIDEventSystemConnectionDispatchEvent(g_hidConnection, parent);
        dispatched = YES;
    }
    return dispatched;
}

static BOOL PostLegacyTouchEventPhase(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    uint64_t timestamp = GetCurrentTimestamp();
    IOHIDEventRef event = CreateTouchEvent(timestamp, phase, x, y);
    if (!event) {
        return NO;
    }
    BOOL ok = DispatchEvent(event);
    CFRelease(event);
    return ok;
}

static BOOL PostBKSTouchEventPhase(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    uint64_t timestamp = GetCurrentTimestamp();
    IOHIDEventRef event = CreateBKSTouchEvent(timestamp, phase, x, y);
    if (!event) {
        return NO;
    }
    BOOL ok = [KimiRunTouchInjection deliverViaBKS:event];
    CFRelease(event);
    return ok;
}

// Post a single touch event
static BOOL PostTouchEvent(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    uint64_t timestamp = GetCurrentTimestamp();
    CGFloat adjX = x, adjY = y;
    AdjustInputCoordinates(&adjX, &adjY);
    NSLog(@"[KimiRunTouchInjection] PostTouchEvent phase=%d at (%.1f, %.1f)", (int)phase, adjX, adjY);

    IOHIDEventRef event = CreateTouchEvent(timestamp, phase, adjX, adjY);

    if (!event) {
        NSLog(@"[KimiRunTouchInjection] Failed to create touch event");
        return NO;
    }

    BOOL success = DispatchEvent(event);
    NSLog(@"[KimiRunTouchInjection] DispatchEvent returned %d", success);
    CFRelease(event);

    return success;
}


static BOOL PostSimulateTouchEvent(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostSimulateTouchEventInternal(phase, kSimulateTouchPrimaryFingerIndex, x, y, NO);
}

static BOOL PostSimulateTouchEventViaConnection(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostSimulateTouchEventInternal(phase, kSimulateTouchPrimaryFingerIndex, x, y, YES);
}

BOOL KimiRunDispatchEvent(IOHIDEventRef event) {
    return DispatchEvent(event);
}

IOHIDEventRef KimiRunCreateTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return CreateTouchEvent(timestamp, phase, x, y);
}

IOHIDEventRef KimiRunCreateBKSTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return CreateBKSTouchEvent(timestamp, phase, x, y);
}

BOOL KimiRunPostTouchEvent(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostTouchEvent(phase, x, y);
}

BOOL KimiRunPostSimulateTouchEvent(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostSimulateTouchEvent(phase, x, y);
}

BOOL KimiRunPostSimulateTouchEventViaConnection(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostSimulateTouchEventViaConnection(phase, x, y);
}

BOOL KimiRunPostLegacyTouchEventPhase(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostLegacyTouchEventPhase(phase, x, y);
}

BOOL KimiRunPostBKSTouchEventPhase(KimiRunTouchPhase phase, CGFloat x, CGFloat y) {
    return PostBKSTouchEventPhase(phase, x, y);
}

BOOL KimiRunDispatchEventWithContextBind(IOHIDEventRef event, NSString **pathOut) {
    return KimiRunDispatchEventWithContextBindInternal(event, pathOut);
}
