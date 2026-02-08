#import "TouchInjectionInternal.h"
#include <mach/kern_return.h>

// IOKit function not declared in our SDK headers
extern kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *entryID);

static void CleanupSenderCallbacks(void);

// Extracted from TouchInjection.m: senderID persistence + capture management
static void PersistSenderID(uint64_t senderID) {
    if (senderID == 0) {
        return;
    }
    @try {
        NSInteger currentTime = (NSInteger)[[NSDate date] timeIntervalSince1970];
        NSInteger timeSinceReboot = (NSInteger)[NSProcessInfo processInfo].systemUptime;
        NSInteger rebootTime = currentTime - timeSinceReboot;
        NSDictionary *dict = @{@"lastReboot": @(rebootTime), @"senderID": @(senderID)};
        [dict writeToFile:SenderIDPlistPath() atomically:YES];
    } @catch (NSException *e) {
        // Best effort only
    }
}

static void LoadPersistedSenderID(void) {
    @try {
        NSString *path = SenderIDPlistPath();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return;
        }
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!dict) {
            return;
        }
        NSInteger lastReboot = [dict[@"lastReboot"] longValue];
        NSInteger currentTime = (NSInteger)[[NSDate date] timeIntervalSince1970];
        NSInteger timeSinceReboot = (NSInteger)[NSProcessInfo processInfo].systemUptime;
        NSInteger thisRebootTime = currentTime - timeSinceReboot;
        if (llabs(lastReboot - thisRebootTime) <= 3) {
            uint64_t persisted = [dict[@"senderID"] unsignedLongLongValue];
            if (persisted != 0 && persisted != kTouchSenderID) {
                g_senderID = persisted;
                g_senderCaptured = NO;
                g_senderSource = 3;
                NSLog(@"[KimiRunTouchInjection] Loaded persisted senderID: 0x%llX", g_senderID);
            } else if (persisted == kTouchSenderID) {
                NSLog(@"[KimiRunTouchInjection] Ignoring persisted fallback senderID");
            }
        }
    } @catch (NSException *e) {
        // Best effort only
    }
}

static void TryLoadSenderIDFromIORegistry(void) {
    if (g_senderID != 0) {
        return;
    }
    @try {
        CFMutableDictionaryRef matching = IOServiceMatching("AppleMultitouchDevice");
        if (!matching) {
            return;
        }
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
        if (!service) {
            return;
        }
        // Use the IORegistry entry ID (same as IOHIDEventGetSenderID returns for
        // digitizer events). Previous code used the "Multitouch ID" property which
        // is a different value and does NOT match the sender ID in HID events.
        uint64_t entryID = 0;
        kern_return_t kr = IORegistryEntryGetRegistryEntryID(service, &entryID);
        if (kr == KERN_SUCCESS && entryID != 0) {
            g_senderID = entryID;
            g_senderCaptured = NO;
            g_senderSource = 1;
            NSLog(@"[KimiRunTouchInjection] Loaded senderID from IORegistry entry ID: 0x%llX", g_senderID);
            KimiRunLog([NSString stringWithFormat:@"[SenderID] IORegistry entryID=0x%llX", g_senderID]);
            PersistSenderID(g_senderID);
        } else {
            // Fallback: try Multitouch ID property (less reliable but non-zero)
            CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
                uint64_t mtID = 0;
                if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &mtID) && mtID != 0) {
                    g_senderID = mtID;
                    g_senderCaptured = NO;
                    g_senderSource = 1;
                    NSLog(@"[KimiRunTouchInjection] Loaded senderID from IORegistry Multitouch ID (fallback): 0x%llX", g_senderID);
                    KimiRunLog([NSString stringWithFormat:@"[SenderID] IORegistry MultitouchID(fallback)=0x%llX", g_senderID]);
                    PersistSenderID(g_senderID);
                }
            }
            if (value) {
                CFRelease(value);
            }
        }
        IOObjectRelease(service);
    } @catch (NSException *e) {
        // Best effort only
    }
}

static void SenderIDCallback(void* target, void* refcon, void* service, IOHIDEventRef event) {
    if (!_IOHIDEventGetType || !_IOHIDEventGetSenderID || !event) {
        return;
    }
    g_senderCallbackCount++;
    g_senderLastEventType = (int)_IOHIDEventGetType(event);
    BOOL isDigitizer = (g_senderLastEventType == kIOHIDEventTypeDigitizer || g_senderLastEventType == 11);
    uint64_t sender = 0;
    BOOL senderFromDigitizer = NO;
    if (isDigitizer) {
        g_senderCallbackDigitizerCount++;
        senderFromDigitizer = YES;
        sender = _IOHIDEventGetSenderID(event);
        if (g_senderCallbackCount <= 10) {
            KimiRunLog([NSString stringWithFormat:@"[SenderID] digitizer parent type=%d sender=0x%llX", g_senderLastEventType, sender]);
        }
    } else {
        // Log non-digitizer events but do NOT capture sender from them.
        // SimulateTouch only captures from kIOHIDEventTypeDigitizer events.
        // Non-digitizer events (type 1=VendorDefined, 15=Biometric, etc.) have
        // different sender IDs that do NOT match the touch digitizer.
        if (g_senderCallbackCount <= 10) {
            uint64_t nonDigSender = _IOHIDEventGetSenderID(event);
            KimiRunLog([NSString stringWithFormat:@"[SenderID] skip non-digitizer parent type=%d sender=0x%llX",
                        g_senderLastEventType,
                        nonDigSender]);
        }
        // Check children for digitizer sub-events
        if (_IOHIDEventGetChildren) {
            CFArrayRef children = _IOHIDEventGetChildren(event);
            if (children) {
                CFIndex count = CFArrayGetCount(children);
                for (CFIndex i = 0; i < count; i++) {
                    IOHIDEventRef child = (IOHIDEventRef)CFArrayGetValueAtIndex(children, i);
                    if (!child) {
                        continue;
                    }
                    IOHIDEventType childType = _IOHIDEventGetType(child);
                    if (childType == kIOHIDEventTypeDigitizer || childType == 11) {
                        g_senderCallbackDigitizerCount++;
                        senderFromDigitizer = YES;
                        sender = _IOHIDEventGetSenderID(child);
                        if (g_senderCallbackCount <= 10) {
                            KimiRunLog([NSString stringWithFormat:@"[SenderID] digitizer child type=%d sender=0x%llX",
                                        (int)childType,
                                        sender]);
                        }
                        if (sender != 0) {
                            break;
                        }
                    }
                }
            }
        }
    }
    if (sender != 0 && senderFromDigitizer) {
        if (sender == kTouchSenderID) {
            // Ignore fallback senderID from our own injected events
            KimiRunLog(@"[SenderID] ignoring fallback senderID from injected event");
        } else {
            if (g_senderID != sender) {
                g_senderID = sender;
                PersistSenderID(g_senderID);
            }
            g_senderCaptured = YES;
            g_senderSource = 2;
            NSLog(@"[KimiRunTouchInjection] Captured digitizer senderID: 0x%llX (eventType=%d)", g_senderID, g_senderLastEventType);
            KimiRunLog([NSString stringWithFormat:@"[SenderID] captured-digitizer 0x%llX eventType=%d", g_senderID, g_senderLastEventType]);
            CleanupSenderCallbacks();
        }
    }
    if (g_senderCallbackCount <= 5 || (g_senderCallbackCount % 100) == 0) {
        NSLog(@"[KimiRunTouchInjection] SenderID callback fired (%d), lastType=%d, digitizerCount=%d, senderFromDigitizer=%d",
              g_senderCallbackCount, g_senderLastEventType, g_senderCallbackDigitizerCount, senderFromDigitizer);
    }
}

static void ApplyDigitizerMatching(IOHIDEventSystemClientRef client) {
    if (!client || !_IOHIDEventSystemClientSetMatching) {
        return;
    }
    // Match Digitizer usage page (0x0D) and Touch Screen usage (0x04)
    int pageVal = 0x0D;
    int usageVal = 0x04;
    CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pageVal);
    CFNumberRef usage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usageVal);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { page, usage };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    _IOHIDEventSystemClientSetMatching(client, match);
    if (page) CFRelease(page);
    if (usage) CFRelease(usage);
    if (match) CFRelease(match);
}

static void CleanupSenderCallbacks(void) {
    if (g_senderCleanupDone) {
        return;
    }
    g_senderCleanupDone = YES;

    // Stop thread loop
    g_senderThreadRunning = NO;

    if (g_senderUseExtraCallbacks) {
        // Clean up main runloop registration
        if (g_senderClientMain && _IOHIDEventSystemClientUnregisterEventCallback && _IOHIDEventSystemClientUnscheduleWithRunLoop) {
            CFRunLoopRef mainLoop = CFRunLoopGetMain();
            _IOHIDEventSystemClientUnregisterEventCallback(g_senderClientMain);
            _IOHIDEventSystemClientUnscheduleWithRunLoop(g_senderClientMain, mainLoop, kCFRunLoopDefaultMode);
            _IOHIDEventSystemClientUnscheduleWithRunLoop(g_senderClientMain, mainLoop, kCFRunLoopCommonModes);
            g_senderMainRegistered = NO;
            NSLog(@"[KimiRunTouchInjection] SenderID callback unregistered from main runloop");
        }

        // Clean up dispatch queue registration
        if (g_senderClientDispatch && _IOHIDEventSystemClientUnregisterEventCallback) {
            _IOHIDEventSystemClientUnregisterEventCallback(g_senderClientDispatch);
            g_senderDispatchRegistered = NO;
            NSLog(@"[KimiRunTouchInjection] SenderID callback unregistered from dispatch queue");
        }
    }

    // Clean up sender thread runloop registration
    if (g_senderClient && g_senderRunLoop &&
        _IOHIDEventSystemClientUnregisterEventCallback && _IOHIDEventSystemClientUnscheduleWithRunLoop) {
        CFRunLoopRef runloop = g_senderRunLoop;
        CFRunLoopPerformBlock(runloop, kCFRunLoopDefaultMode, ^{
            _IOHIDEventSystemClientUnregisterEventCallback(g_senderClient);
            _IOHIDEventSystemClientUnscheduleWithRunLoop(g_senderClient, runloop, kCFRunLoopDefaultMode);
        });
        CFRunLoopWakeUp(runloop);
        NSLog(@"[KimiRunTouchInjection] SenderID callback unregistered from sender thread runloop");
    }
}

static void SenderIDThreadMain(void) {
    @autoreleasepool {
        g_senderThreadRunning = YES;
        if (!_IOHIDEventSystemClientCreate || !_IOHIDEventSystemClientScheduleWithRunLoop ||
            !_IOHIDEventSystemClientRegisterEventCallback || !_IOHIDEventGetType || !_IOHIDEventGetSenderID) {
            NSLog(@"[KimiRunTouchInjection] SenderID thread missing required symbols (create=%p schedule=%p register=%p getType=%p getSender=%p)",
                  _IOHIDEventSystemClientCreate,
                  _IOHIDEventSystemClientScheduleWithRunLoop,
                  _IOHIDEventSystemClientRegisterEventCallback,
                  _IOHIDEventGetType,
                  _IOHIDEventGetSenderID);
            g_senderThreadRunning = NO;
            return;
        }

        g_senderClient = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!g_senderClient) {
            NSLog(@"[KimiRunTouchInjection] SenderID thread failed to create client");
            g_senderThreadRunning = NO;
            return;
        }

        CFRunLoopRef runloop = CFRunLoopGetCurrent();
        if (!g_senderRunLoop) {
            g_senderRunLoop = (CFRunLoopRef)CFRetain(runloop);
        }
        if (g_senderUseMatching) {
            ApplyDigitizerMatching(g_senderClient);
        }
        _IOHIDEventSystemClientScheduleWithRunLoop(g_senderClient, runloop, kCFRunLoopDefaultMode);
        _IOHIDEventSystemClientRegisterEventCallback(g_senderClient, (void *)SenderIDCallback, NULL, NULL);
        NSLog(@"[KimiRunTouchInjection] SenderID thread registered callback on runloop %p", runloop);

        // Periodic logging to confirm thread is alive
        NSTimer *timer = [NSTimer timerWithTimeInterval:2.0
                                                 target:[NSBlockOperation blockOperationWithBlock:^{
            NSLog(@"[KimiRunTouchInjection] SenderID thread alive, callbackCount=%d, senderID=0x%llX",
                  g_senderCallbackCount, g_senderID);
        }]
                                               selector:@selector(main)
                                               userInfo:nil
                                                repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];

        while (g_senderThreadRunning) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
            }
        }
    }
}

static void RegisterSenderIDCallbackOnMainRunLoop(void) {
    if (!g_senderUseExtraCallbacks) {
        return;
    }
    if (g_senderMainRegistered) {
        return;
    }
    if (!_IOHIDEventSystemClientCreate || !_IOHIDEventSystemClientScheduleWithRunLoop ||
        !_IOHIDEventSystemClientRegisterEventCallback || !_IOHIDEventGetType || !_IOHIDEventGetSenderID) {
        return;
    }
    g_senderClientMain = _IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!g_senderClientMain) {
        return;
    }
    if (g_senderUseMatching) {
        ApplyDigitizerMatching(g_senderClientMain);
    }
    CFRunLoopRef mainLoop = CFRunLoopGetMain();
    _IOHIDEventSystemClientScheduleWithRunLoop(g_senderClientMain, mainLoop, kCFRunLoopDefaultMode);
    _IOHIDEventSystemClientRegisterEventCallback(g_senderClientMain, (void *)SenderIDCallback, NULL, NULL);
    g_senderMainRegistered = YES;
    NSLog(@"[KimiRunTouchInjection] SenderID callback registered on main runloop %p", mainLoop);
}

static void RegisterSenderIDCallbackOnDispatchQueue(void) {
    if (!g_senderUseExtraCallbacks) {
        return;
    }
    if (g_senderDispatchRegistered) {
        return;
    }
    if (!_IOHIDEventSystemClientCreateSimpleClient || !_IOHIDEventSystemClientSetDispatchQueue ||
        !_IOHIDEventSystemClientActivate || !_IOHIDEventSystemClientRegisterEventCallback ||
        !_IOHIDEventGetType || !_IOHIDEventGetSenderID) {
        return;
    }

    g_senderClientDispatch = _IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!g_senderClientDispatch) {
        return;
    }
    if (g_senderUseMatching) {
        ApplyDigitizerMatching(g_senderClientDispatch);
    }
    _IOHIDEventSystemClientSetDispatchQueue(g_senderClientDispatch, dispatch_get_main_queue());
    _IOHIDEventSystemClientRegisterEventCallback(g_senderClientDispatch, (void *)SenderIDCallback, NULL, NULL);
    _IOHIDEventSystemClientActivate(g_senderClientDispatch);
    g_senderDispatchRegistered = YES;
    NSLog(@"[KimiRunTouchInjection] SenderID callback registered on dispatch queue");
}

void KimiRunLoadPersistedSenderID(void) {
    LoadPersistedSenderID();
}

void KimiRunTryLoadSenderIDFromIORegistry(void) {
    TryLoadSenderIDFromIORegistry();
}

void KimiRunSenderIDThreadMain(void) {
    SenderIDThreadMain();
}

void KimiRunRegisterSenderIDCallbackOnMainRunLoop(void) {
    RegisterSenderIDCallbackOnMainRunLoop();
}

void KimiRunRegisterSenderIDCallbackOnDispatchQueue(void) {
    RegisterSenderIDCallbackOnDispatchQueue();
}

void KimiRunCleanupSenderCallbacks(void) {
    CleanupSenderCallbacks();
}

void KimiRunApplyDigitizerMatching(IOHIDEventSystemClientRef client) {
    ApplyDigitizerMatching(client);
}

void KimiRunPersistSenderID(uint64_t senderID) {
    PersistSenderID(senderID);
}
