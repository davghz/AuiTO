#import "TouchInjectionInternal.h"
#import <dlfcn.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KimiRunTouchInjection (Bootstrap)

+ (BOOL)initialize {
    if (g_initialized) {
        return YES;
    }
    
    NSLog(@"[KimiRunTouchInjection] Initializing...");
    
    // Update screen metrics
    if (!UpdateScreenMetrics()) {
        NSLog(@"[KimiRunTouchInjection] Warning: Could not get screen metrics, will retry on first use");
    }

    // Configure senderID capture tuning (env overrides prefs)
    g_senderUseMatching = KimiRunTouchEnvBool("KIMIRUN_SENDER_MATCHING",
                                              KimiRunTouchPrefBool(@"SenderUseMatching", NO));
    g_senderUseExtraCallbacks = KimiRunTouchEnvBool("KIMIRUN_SENDER_EXTRACB",
                                                    KimiRunTouchPrefBool(@"SenderUseExtraCallbacks", YES));
    g_touchUseMatching = KimiRunTouchEnvBool("KIMIRUN_TOUCH_MATCHING",
                                             KimiRunTouchPrefBool(@"TouchUseMatching", NO));

    // Load persisted sender ID if available
    KimiRunLoadPersistedSenderID();
    // Try IORegistry-based sender ID (Multitouch ID) before callbacks
    KimiRunTryLoadSenderIDFromIORegistry();
    
    // Load IOKit dynamically
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) {
        NSLog(@"[KimiRunTouchInjection] Failed to load IOKit: %s", dlerror());
        return NO;
    }
    
    // Load function pointers
    _IOHIDEventCreateDigitizerEvent = dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
    _IOHIDEventCreateDigitizerFingerEvent = dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
    _IOHIDEventCreateKeyboardEvent = dlsym(iokit, "IOHIDEventCreateKeyboardEvent");
    _IOHIDEventSetIntegerValue = dlsym(iokit, "IOHIDEventSetIntegerValue");
    _IOHIDEventSetFloatValue = dlsym(iokit, "IOHIDEventSetFloatValue");
    _IOHIDEventSetSenderID = dlsym(iokit, "IOHIDEventSetSenderID");
    _IOHIDEventAppendEvent = dlsym(iokit, "IOHIDEventAppendEvent");
    _IOHIDEventGetType = dlsym(iokit, "IOHIDEventGetType");
    _IOHIDEventGetSenderID = dlsym(iokit, "IOHIDEventGetSenderID");
    _IOHIDEventGetChildren = dlsym(iokit, "IOHIDEventGetChildren");
    _IOHIDEventSystemClientCreate = dlsym(iokit, "IOHIDEventSystemClientCreate");
    _IOHIDEventSystemClientCreateWithType = dlsym(iokit, "IOHIDEventSystemClientCreateWithType");
    _IOHIDEventSystemClientCreateSimpleClient = dlsym(iokit, "IOHIDEventSystemClientCreateSimpleClient");
    _IOHIDEventSystemClientDispatchEvent = dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
    _IOHIDEventSystemConnectionDispatchEvent = dlsym(iokit, "IOHIDEventSystemConnectionDispatchEvent");
    if (!_IOHIDEventSystemConnectionDispatchEvent) {
        _IOHIDEventSystemConnectionDispatchEvent = dlsym(iokit, "__IOHIDEventSystemConnectionDispatchEvent");
    }
    _IOHIDEventSystemClientSetDispatchQueue = dlsym(iokit, "IOHIDEventSystemClientSetDispatchQueue");
    _IOHIDEventSystemClientActivate = dlsym(iokit, "IOHIDEventSystemClientActivate");
    _IOHIDEventSystemClientScheduleWithRunLoop = dlsym(iokit, "IOHIDEventSystemClientScheduleWithRunLoop");
    _IOHIDEventSystemClientRegisterEventCallback = dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback");
    _IOHIDEventSystemClientUnregisterEventCallback = dlsym(iokit, "IOHIDEventSystemClientUnregisterEventCallback");
    _IOHIDEventSystemClientUnscheduleWithRunLoop = dlsym(iokit, "IOHIDEventSystemClientUnscheduleWithRunLoop");
    _IOHIDEventSystemClientSetMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching");
    
    // Verify required functions
    if (!_IOHIDEventCreateDigitizerEvent || !_IOHIDEventCreateDigitizerFingerEvent) {
        NSLog(@"[KimiRunTouchInjection] Failed to load required IOKit functions");
        return NO;
    }
    
    if (!_IOHIDEventSystemClientDispatchEvent) {
        NSLog(@"[KimiRunTouchInjection] Failed to load event dispatch function");
        return NO;
    }
    
    // Create event system client (legacy path)
    if (_IOHIDEventSystemClientCreateSimpleClient) {
        g_hidClient = _IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    } else if (_IOHIDEventSystemClientCreate) {
        g_hidClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    
    if (!g_hidClient) {
        NSLog(@"[KimiRunTouchInjection] Failed to create HID event system client");
        // Continue - SimulateTouch uses its own client
    }
    
    // Set up dispatch queue and activate (critical for event delivery)
    if (_IOHIDEventSystemClientSetDispatchQueue) {
        _IOHIDEventSystemClientSetDispatchQueue(g_hidClient, dispatch_get_main_queue());
    }
    if (_IOHIDEventSystemClientActivate) {
        _IOHIDEventSystemClientActivate(g_hidClient);
    }
    if (g_touchUseMatching) {
        KimiRunApplyDigitizerMatching(g_hidClient);
    }

    memset(g_simEventsToAppend, 0, sizeof(g_simEventsToAppend));

    // SimulateTouch client
    if (_IOHIDEventSystemClientCreate) {
        g_simClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    }
    if (g_simClient) {
        if (_IOHIDEventSystemClientSetDispatchQueue) {
            _IOHIDEventSystemClientSetDispatchQueue(g_simClient, dispatch_get_main_queue());
        }
        if (_IOHIDEventSystemClientActivate) {
            _IOHIDEventSystemClientActivate(g_simClient);
        }
        if (g_touchUseMatching) {
            KimiRunApplyDigitizerMatching(g_simClient);
        }
    }

    // Optional admin client (CreateWithType)
    if (_IOHIDEventSystemClientCreateWithType) {
        int typesToTry[] = {2, 1, 0, 3};
        size_t count = sizeof(typesToTry) / sizeof(typesToTry[0]);
        for (size_t i = 0; i < count; i++) {
            g_adminClient = _IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, typesToTry[i], 0);
            if (g_adminClient) {
                g_adminClientType = typesToTry[i];
                break;
            }
        }
        if (g_adminClient) {
            if (_IOHIDEventSystemClientSetDispatchQueue) {
                _IOHIDEventSystemClientSetDispatchQueue(g_adminClient, dispatch_get_main_queue());
            }
            if (_IOHIDEventSystemClientActivate) {
                _IOHIDEventSystemClientActivate(g_adminClient);
            }
            if (g_touchUseMatching) {
                KimiRunApplyDigitizerMatching(g_adminClient);
            }
            NSLog(@"[KimiRunTouchInjection] Admin client created with type=%d", g_adminClientType);
        }
    }

    NSLog(@"[KimiRunTouchInjection] SimulateTouch options: touchMatching=%d senderMatching=%d extraCallbacks=%d",
          g_touchUseMatching, g_senderUseMatching, g_senderUseExtraCallbacks);

    // Start sender ID capture (SimulateTouch)
    if (!g_senderCaptured &&
        _IOHIDEventSystemClientCreate && _IOHIDEventSystemClientScheduleWithRunLoop &&
        _IOHIDEventSystemClientRegisterEventCallback && _IOHIDEventGetType && _IOHIDEventGetSenderID) {
        if (!g_senderThread) {
            g_senderThread = [[NSThread alloc] initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
                KimiRunSenderIDThreadMain();
            }] selector:@selector(main) object:nil];
            g_senderThread.name = @"KimiRunSenderIDThread";
            [g_senderThread start];
        }
        if (g_senderUseExtraCallbacks) {
            dispatch_async(dispatch_get_main_queue(), ^{
                KimiRunRegisterSenderIDCallbackOnMainRunLoop();
                KimiRunRegisterSenderIDCallbackOnDispatchQueue();
            });
        }
    }
    
    // Load BackBoardServices as fallback
    void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    if (bbs) {
        KimiRunResolveBKSManagers();
        if (g_bksDeliveryManagerClass) {
            NSLog(@"[KimiRunTouchInjection] BKSHIDEventDeliveryManager loaded: %p", g_bksSharedDeliveryManager);
            KimiRunLog([NSString stringWithFormat:@"[BKS] deliveryManager=%p routerManager=%p",
                        g_bksSharedDeliveryManager,
                        g_bksSharedRouterManager]);
        } else {
            NSLog(@"[KimiRunTouchInjection] BKSHIDEventDeliveryManager class not found");
            KimiRunLog(@"[BKS] delivery manager class not found");
        }
    } else {
        NSLog(@"[KimiRunTouchInjection] Failed to load BackBoardServices: %s", dlerror());
        KimiRunLog(@"[BKS] failed to load BackBoardServices dylib");
    }

    UpdateHIDConnection();
    
    g_initialized = YES;
    NSLog(@"[KimiRunTouchInjection] Initialized (legacy client=%p, sim client=%p, sender client=%p, bks=%p)", g_hidClient, g_simClient, g_senderClient, g_bksSharedDeliveryManager);
    
    return YES;
}


@end
#pragma clang diagnostic pop
