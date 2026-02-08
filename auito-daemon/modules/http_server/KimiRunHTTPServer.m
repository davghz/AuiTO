//
//  KimiRunHTTPServer.m
//  KimiRun Modular - HTTP Server Module
//
//  HTTP server implementation using CFSocket
//

#import "KimiRunHTTPServer.h"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../touch/TouchInjection.h"
#import "../touch/AXTouchInjection.h"
#import "../screenshot/KimiRunScreenshot.h"
#import "../accessibility/AccessibilityTree.h"

// HTTP request buffer size
#define HTTP_BUFFER_SIZE 4096

@interface KimiRunHTTPServer ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) CFSocketRef socket;
@property (nonatomic, assign) CFRunLoopSourceRef runLoopSource;
@end

// Forward declaration of callback
static void SocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);
static NSString *KimiRunCanonicalModeFromMethod(NSString *method);
static NSDictionary *KimiRunWakeAndUnlockDevice(void);
static NSString *KimiRunFrontmostBundleID(void);
static NSDictionary *KimiRunLockState(void);
static BOOL KimiRunLaunchAppBundleID(NSString *bundleID);
static NSArray *KimiRunListApplications(BOOL includeSystem);
static NSUInteger sLastGoodCapturePort = 0;
static NSUInteger sLastGoodTouchPort = 0;

@implementation KimiRunHTTPServer

static NSString *KimiRunCanonicalModeFromMethod(NSString *method) {
    if (![method isKindOfClass:[NSString class]] || method.length == 0) {
        return @"auto";
    }
    NSString *lower = [[method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) return @"auto";
    if ([lower isEqualToString:@"iohid"]) return @"sim";
    if ([lower isEqualToString:@"old"]) return @"legacy";
    if ([lower isEqualToString:@"connection"]) return @"conn";
    if ([lower isEqualToString:@"zx"]) return @"zxtouch";
    if ([lower isEqualToString:@"a11y"]) return @"ax";
    return lower;
}

static NSDictionary *KimiRunWakeAndUnlockDevice(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    CGFloat brightnessBefore = [UIScreen mainScreen].brightness;

    BOOL backlightAttempted = NO;
    BOOL backlightSucceeded = NO;
    Class backlightClass = NSClassFromString(@"SBBacklightController");
    id backlight = nil;
    if (backlightClass && [backlightClass respondsToSelector:@selector(sharedInstance)]) {
        backlight = [backlightClass performSelector:@selector(sharedInstance)];
    } else if (backlightClass && [backlightClass respondsToSelector:@selector(sharedBrightnessController)]) {
        backlight = [backlightClass performSelector:@selector(sharedBrightnessController)];
    }
    if (backlight) {
        NSArray<NSString *> *wakeSelectors = @[
            @"turnOnScreenFullyWithBacklightSource:",
            @"_turnOnScreenFullyWithBacklightSource:",
            @"wakeDisplay",
            @"_wakeUpDisplay"
        ];
        for (NSString *name in wakeSelectors) {
            SEL sel = NSSelectorFromString(name);
            if (![backlight respondsToSelector:sel]) {
                continue;
            }
            @try {
                backlightAttempted = YES;
                if ([name hasSuffix:@":"]) {
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(backlight, sel, 1);
                } else {
                    ((void (*)(id, SEL))objc_msgSend)(backlight, sel);
                }
                backlightSucceeded = YES;
                result[@"backlightSelector"] = name;
                break;
            } @catch (__unused NSException *e) {
            }
        }
    }
    result[@"backlightClass"] = backlightClass ? @"SBBacklightController" : @"";
    result[@"backlightAttempted"] = @(backlightAttempted);
    result[@"backlightSucceeded"] = @(backlightSucceeded);

    BOOL unlockAttempted = NO;
    BOOL unlockSucceeded = NO;
    Class lockClass = NSClassFromString(@"SBLockScreenManager");
    id lock = nil;
    if (lockClass && [lockClass respondsToSelector:@selector(sharedInstance)]) {
        lock = [lockClass performSelector:@selector(sharedInstance)];
    }
    if (lock) {
        NSArray<NSString *> *unlockSelectors = @[
            @"startUIUnlockFromSource:withOptions:",
            @"unlockUIFromSource:withOptions:",
            @"unlockUIFromSource:",
            @"_finishUIUnlockFromSource:withOptions:",
            @"_finishUIUnlockFromSource:",
            @"lockScreenViewControllerRequestsUnlock"
        ];
        for (NSString *name in unlockSelectors) {
            SEL sel = NSSelectorFromString(name);
            if (![lock respondsToSelector:sel]) {
                continue;
            }
            @try {
                unlockAttempted = YES;
                if ([name isEqualToString:@"lockScreenViewControllerRequestsUnlock"]) {
                    ((void (*)(id, SEL))objc_msgSend)(lock, sel);
                    unlockSucceeded = YES;
                } else if ([name hasSuffix:@"withOptions:"]) {
                    BOOL ok = ((BOOL (*)(id, SEL, NSInteger, id))objc_msgSend)(lock, sel, 0, nil);
                    unlockSucceeded = unlockSucceeded || ok;
                } else if ([name hasSuffix:@":"]) {
                    BOOL ok = ((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(lock, sel, 0);
                    unlockSucceeded = unlockSucceeded || ok;
                }
                if (unlockSucceeded && !result[@"unlockSelector"]) {
                    result[@"unlockSelector"] = name;
                }
            } @catch (__unused NSException *e) {
            }
        }
    }
    result[@"lockManagerClass"] = lockClass ? @"SBLockScreenManager" : @"";
    result[@"unlockAttempted"] = @(unlockAttempted);
    result[@"unlockSucceeded"] = @(unlockSucceeded);

    BOOL brightnessAdjusted = NO;
    CGFloat brightnessAfter = [UIScreen mainScreen].brightness;
    if (brightnessAfter <= 0.01f) {
        @try {
            [UIScreen mainScreen].brightness = 0.35f;
            brightnessAdjusted = YES;
        } @catch (__unused NSException *e) {
        }
        brightnessAfter = [UIScreen mainScreen].brightness;
    }
    result[@"brightnessBefore"] = @(brightnessBefore);
    result[@"brightnessAfter"] = @(brightnessAfter);
    result[@"brightnessAdjusted"] = @(brightnessAdjusted);

    return result;
}

static NSString *KimiRunFrontmostBundleID(void) {
    NSArray<NSString *> *selectors = @[
        @"frontMostApplication",
        @"_accessibilityFrontMostApplication",
        @"_topApplication",
        @"foregroundApplication"
    ];
    NSArray<NSString *> *workspaceClasses = @[
        @"SBMainWorkspace",
        @"SBWorkspace",
        @"SBApplicationController"
    ];

    for (NSString *className in workspaceClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;

        id shared = nil;
        if ([cls respondsToSelector:@selector(sharedInstance)]) {
            shared = [cls performSelector:@selector(sharedInstance)];
        } else if ([cls respondsToSelector:@selector(sharedWorkspace)]) {
            shared = [cls performSelector:@selector(sharedWorkspace)];
        }
        if (!shared) continue;

        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            if (![shared respondsToSelector:sel]) continue;
            @try {
                id app = ((id (*)(id, SEL))objc_msgSend)(shared, sel);
                if (!app) continue;
                if ([app isKindOfClass:[NSString class]]) {
                    return (NSString *)app;
                }
                SEL bundleSel = NSSelectorFromString(@"bundleIdentifier");
                SEL displaySel = NSSelectorFromString(@"displayIdentifier");
                if ([app respondsToSelector:bundleSel]) {
                    id bid = ((id (*)(id, SEL))objc_msgSend)(app, bundleSel);
                    if ([bid isKindOfClass:[NSString class]] && [bid length] > 0) {
                        return bid;
                    }
                }
                if ([app respondsToSelector:displaySel]) {
                    id did = ((id (*)(id, SEL))objc_msgSend)(app, displaySel);
                    if ([did isKindOfClass:[NSString class]] && [did length] > 0) {
                        return did;
                    }
                }
            } @catch (__unused NSException *e) {
            }
        }
    }
    return @"";
}

static NSDictionary *KimiRunLockState(void) {
    Class lockClass = NSClassFromString(@"SBLockScreenManager");
    id lock = nil;
    if (lockClass && [lockClass respondsToSelector:@selector(sharedInstance)]) {
        lock = [lockClass performSelector:@selector(sharedInstance)];
    }
    BOOL uiLocked = NO;
    BOOL lockVisible = NO;
    if (lock) {
        SEL isLockedSel = NSSelectorFromString(@"isUILocked");
        SEL isVisibleSel = NSSelectorFromString(@"isLockScreenVisible");
        @try {
            if ([lock respondsToSelector:isLockedSel]) {
                uiLocked = ((BOOL (*)(id, SEL))objc_msgSend)(lock, isLockedSel);
            }
            if ([lock respondsToSelector:isVisibleSel]) {
                lockVisible = ((BOOL (*)(id, SEL))objc_msgSend)(lock, isVisibleSel);
            }
        } @catch (__unused NSException *e) {
        }
    }
    return @{
        @"lockManagerPresent": @(lock != nil),
        @"uiLocked": @(uiLocked),
        @"lockVisible": @(lockVisible)
    };
}

static BOOL KimiRunLaunchAppBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) {
        return NO;
    }

    // Prefer BKS system service first (closest to SpringBoard activation path).
    @try {
        dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        Class bksClass = NSClassFromString(@"BKSSystemService");
        if (bksClass) {
            id bksService = [[bksClass alloc] init];
            SEL openSel = NSSelectorFromString(@"openApplication:options:withResult:");
            if ([bksService respondsToSelector:openSel]) {
                __block BOOL callbackFired = NO;
                __block BOOL callbackSuccess = NO;
                void (^resultBlock)(id) = ^(id result) {
                    callbackFired = YES;
                    if (result == nil || result == [NSNull null]) {
                        callbackSuccess = YES;
                    } else if ([result respondsToSelector:@selector(boolValue)]) {
                        callbackSuccess = ((BOOL (*)(id, SEL))objc_msgSend)(result, @selector(boolValue));
                    } else {
                        callbackSuccess = NO;
                    }
                };
                NSDictionary *options = @{@"SBUserInitiatedLaunchKey": @YES};
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(bksService, openSel, bundleID, options, resultBlock);

                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
                while (!callbackFired && [deadline timeIntervalSinceNow] > 0) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
                }
                if (callbackFired ? callbackSuccess : YES) {
                    return YES;
                }
            }
        }
    } @catch (__unused NSException *e) {
    }

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return NO;
    id workspace = nil;
    if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
    }
    if (!workspace) return NO;

    @try {
        SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if ([workspace respondsToSelector:openSel]) {
            return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID);
        }
    } @catch (__unused NSException *e) {
    }

    @try {
        SEL openOptionsSel = NSSelectorFromString(@"openApplicationWithBundleID:options:");
        if ([workspace respondsToSelector:openOptionsSel]) {
            return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(workspace, openOptionsSel, bundleID, nil);
        }
    } @catch (__unused NSException *e) {
    }

    return NO;
}

static NSArray *KimiRunListApplications(BOOL includeSystem) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return @[];

    id workspace = nil;
    if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
    }
    if (!workspace) return @[];

    NSArray *proxies = nil;
    @try {
        SEL allSel = NSSelectorFromString(@"allApplications");
        if ([workspace respondsToSelector:allSel]) {
            proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, allSel);
        }
    } @catch (__unused NSException *e) {
    }
    if (![proxies isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *apps = [NSMutableArray arrayWithCapacity:proxies.count];
    for (id proxy in proxies) {
        @autoreleasepool {
            NSString *bundleID = @"";
            NSString *name = @"";
            BOOL systemApp = NO;

            @try {
                SEL bundleSel = NSSelectorFromString(@"bundleIdentifier");
                if ([proxy respondsToSelector:bundleSel]) {
                    id val = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleSel);
                    if ([val isKindOfClass:[NSString class]]) bundleID = val;
                }
                if (bundleID.length == 0) {
                    SEL appIdSel = NSSelectorFromString(@"applicationIdentifier");
                    if ([proxy respondsToSelector:appIdSel]) {
                        id val = ((id (*)(id, SEL))objc_msgSend)(proxy, appIdSel);
                        if ([val isKindOfClass:[NSString class]]) bundleID = val;
                    }
                }

                SEL localizedSel = NSSelectorFromString(@"localizedName");
                if ([proxy respondsToSelector:localizedSel]) {
                    id val = ((id (*)(id, SEL))objc_msgSend)(proxy, localizedSel);
                    if ([val isKindOfClass:[NSString class]]) name = val;
                }
                if (name.length == 0) {
                    SEL displaySel = NSSelectorFromString(@"displayName");
                    if ([proxy respondsToSelector:displaySel]) {
                        id val = ((id (*)(id, SEL))objc_msgSend)(proxy, displaySel);
                        if ([val isKindOfClass:[NSString class]]) name = val;
                    }
                }

                SEL systemSel = NSSelectorFromString(@"isSystemApplication");
                if ([proxy respondsToSelector:systemSel]) {
                    systemApp = ((BOOL (*)(id, SEL))objc_msgSend)(proxy, systemSel);
                }
            } @catch (__unused NSException *e) {
            }

            if (!includeSystem && systemApp) continue;
            if (bundleID.length == 0) continue;
            [apps addObject:@{
                @"bundleID": bundleID,
                @"name": name ?: @"",
                @"system": @(systemApp),
            }];
        }
    }

    return apps;
}

+ (instancetype)sharedServer {
    static KimiRunHTTPServer *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRunning = NO;
        _port = 0;
        _socket = NULL;
        _runLoopSource = NULL;
    }
    return self;
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error {
    if (self.isRunning) {
        NSLog(@"[KimiRunHTTPServer] Server already running on port %lu", (unsigned long)self.port);
        return YES;
    }
    
    NSLog(@"[KimiRunHTTPServer] Starting HTTP server on port %lu", (unsigned long)port);
    
    self.port = port;
    
    // Set up socket context
    CFSocketContext context = {0};
    context.info = (__bridge void *)self;
    
    // Create socket
    CFSocketRef socket = CFSocketCreate(
        kCFAllocatorDefault,
        PF_INET,
        SOCK_STREAM,
        IPPROTO_TCP,
        kCFSocketAcceptCallBack,
        SocketCallback,
        &context
    );
    
    if (!socket) {
        NSLog(@"[KimiRunHTTPServer] Failed to create socket");
        if (error) {
            *error = [NSError errorWithDomain:@"KimiRunHTTPServer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        }
        return NO;
    }
    
    // Allow address reuse
    int yes = 1;
    setsockopt(CFSocketGetNative(socket), SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    
    // Bind to address
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    
    NSData *addressData = [NSData dataWithBytes:&addr length:sizeof(addr)];
    
    if (CFSocketSetAddress(socket, (__bridge CFDataRef)addressData) != kCFSocketSuccess) {
        NSLog(@"[KimiRunHTTPServer] Failed to bind to port %lu", (unsigned long)port);
        if (error) {
            *error = [NSError errorWithDomain:@"KimiRunHTTPServer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind to port"}];
        }
        CFRelease(socket);
        return NO;
    }
    
    NSLog(@"[KimiRunHTTPServer] Socket bound to port %lu", (unsigned long)port);
    
    // Add to run loop
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    
    self.socket = socket;
    self.isRunning = YES;
    
    NSLog(@"[KimiRunHTTPServer] HTTP server started on port %lu", (unsigned long)port);
    
    return YES;
}

- (void)stop {
    if (!self.isRunning) {
        return;
    }
    
    NSLog(@"[KimiRunHTTPServer] Stopping HTTP server");
    
    if (self.socket) {
        CFSocketInvalidate(self.socket);
        CFRelease(self.socket);
        self.socket = NULL;
    }
    
    self.isRunning = NO;
    self.port = 0;
    
    NSLog(@"[KimiRunHTTPServer] HTTP server stopped");
}

#pragma mark - Request Handling

- (void)handleConnection:(CFSocketNativeHandle)nativeSocket {
    NSLog(@"[KimiRunHTTPServer] Handling new connection");
    
    // Create read stream
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocket, &readStream, &writeStream);
    
    if (!readStream || !writeStream) {
        NSLog(@"[KimiRunHTTPServer] Failed to create streams");
        close(nativeSocket);
        return;
    }
    
    CFReadStreamOpen(readStream);
    CFWriteStreamOpen(writeStream);
    
    // Read HTTP request - wait for header terminator \r\n\r\n
    UInt8 buffer[HTTP_BUFFER_SIZE];
    NSMutableData *requestData = [NSMutableData data];
    BOOL headerComplete = NO;
    NSDate *startTime = [NSDate date];
    
    while (!headerComplete) {
        // Timeout after 3 seconds
        if ([[NSDate date] timeIntervalSinceDate:startTime] > 3.0) {
            NSLog(@"[KimiRunHTTPServer] Read timeout");
            break;
        }
        
        if (CFReadStreamHasBytesAvailable(readStream)) {
            CFIndex bytesRead = CFReadStreamRead(readStream, buffer, HTTP_BUFFER_SIZE - 1);
            if (bytesRead > 0) {
                buffer[bytesRead] = 0;
                [requestData appendBytes:buffer length:bytesRead];
                
                // Check if we have complete HTTP header (ends with \r\n\r\n)
                NSString *tempString = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
                if ([tempString rangeOfString:@"\r\n\r\n"].location != NSNotFound) {
                    headerComplete = YES;
                }
            } else if (bytesRead == 0) {
                break;
            } else {
                NSLog(@"[KimiRunHTTPServer] Error reading from stream");
                break;
            }
        } else {
            // Small delay to prevent busy-waiting
            usleep(1000); // 1ms
        }
    }
    
    NSString *requestString = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    if (!requestString || requestString.length == 0) {
        NSLog(@"[KimiRunHTTPServer] Empty request");
        requestString = @"";
    }
    NSLog(@"[KimiRunHTTPServer] Received request:\n%@", requestString);
    
    // Parse request
    NSString *response = [self generateResponseForRequest:requestString];
    
    // Send response
    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
    const UInt8 *bytes = [responseData bytes];
    CFIndex totalLength = [responseData length];
    CFIndex bytesWritten = 0;
    
    // Ensure all bytes are written (important for large responses like screenshots)
    while (bytesWritten < totalLength) {
        CFIndex result = CFWriteStreamWrite(writeStream, bytes + bytesWritten, totalLength - bytesWritten);
        if (result < 0) {
            NSLog(@"[KimiRunHTTPServer] Write error");
            break;
        }
        if (result == 0) {
            // Would block, wait a bit
            usleep(1000);
        }
        bytesWritten += result;
    }
    
    NSLog(@"[KimiRunHTTPServer] Sent %ld/%ld bytes", (long)bytesWritten, (long)totalLength);
    
    // Clean up
    CFReadStreamClose(readStream);
    CFWriteStreamClose(writeStream);
    CFRelease(readStream);
    CFRelease(writeStream);
    close(nativeSocket);
    
    NSLog(@"[KimiRunHTTPServer] Connection handled and closed");
}

- (NSString *)generateResponseForRequest:(NSString *)request {
    // Parse request line
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        return [self errorResponse:400 message:@"Bad Request"];
    }
    
    NSString *requestLine = lines[0];
    NSArray *requestParts = [requestLine componentsSeparatedByString:@" "];
    
    if (requestParts.count < 2) {
        return [self errorResponse:400 message:@"Bad Request"];
    }
    
    NSString *method = requestParts[0];
    NSString *fullPath = requestParts[1];
    
    // Strip query string from path for routing
    NSString *path = fullPath;
    NSRange queryRange = [fullPath rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        path = [fullPath substringToIndex:queryRange.location];
    }
    
    NSLog(@"[KimiRunHTTPServer] %@ %@", method, fullPath);
    
    // Extract body if present (after \r\n\r\n)
    NSString *body = nil;
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location != NSNotFound) {
        body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    }

    // Foreground ownership recovery:
    // When SpringBoard is serving capture endpoints for a foreground app with its own
    // injected server (Preferences/Safari), proxy to that process so screenshot + AX
    // are sourced from the true foreground context.
    NSString *captureProxyResponse = [self proxyForegroundCaptureRequestIfNeededWithMethod:method
                                                                                   fullPath:fullPath
                                                                                       path:path
                                                                                       body:body];
    if (captureProxyResponse) {
        return captureProxyResponse;
    }

    NSString *touchProxyResponse = [self proxyForegroundTouchRequestIfNeededWithMethod:method
                                                                               fullPath:fullPath
                                                                                   path:path
                                                                                   body:body];
    if (touchProxyResponse) {
        return touchProxyResponse;
    }
    
    // Route to endpoint
    if ([path isEqualToString:@"/ping"]) {
        return [self pingResponse];
    } else if ([path isEqualToString:@"/state"]) {
        return [self stateResponse];
    } else if ([path isEqualToString:@"/tap_raw"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleRawSimulateTouchTap:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/tap"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleTapRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/swipe"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleSwipeRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/drag"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleDragRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/longpress"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleLongPressRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/touch/senderid"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleSenderIDRequest];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/touch/senderid/set"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleSenderIDSetRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/touch/diagnostics"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleTouchDiagnosticsRequest];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/touch/forcefocus"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleForceFocusRequest];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/touch/bkhid_selectors"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleBKHIDSelectorsRequest];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/keyboard/type"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleKeyboardTypeRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/keyboard/key"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleKeyboardKeyRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/a11y/tree"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleA11yTreeRequest:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/a11y/interactive"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleA11yInteractiveRequest:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/a11y/overlay"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleA11yOverlayRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/a11y/activate"]) {
        if ([method isEqualToString:@"POST"] || [method isEqualToString:@"GET"]) {
            return [self handleA11yActivateRequest:body query:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/a11y/debug"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleA11yDebugRequest];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/ax/status"]) {
        if ([method isEqualToString:@"GET"]) {
            __block NSDictionary *status = nil;
            if ([NSThread isMainThread]) {
                status = [AXTouchInjection accessibilityStatus];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    status = [AXTouchInjection accessibilityStatus];
                });
            }
            NSDictionary *payload = @{@"status": @"ok", @"axStatus": (status ?: @{})};
            NSError *err = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
            if (jsonData.length > 0 && !err) {
                NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                return [self jsonResponse:200 body:json];
            }
            return [self jsonResponse:200 body:@"{\"status\":\"ok\",\"axStatus\":{}}"];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/ax/enable"]) {
        if ([method isEqualToString:@"GET"] || [method isEqualToString:@"POST"]) {
            __block NSDictionary *result = nil;
            if ([NSThread isMainThread]) {
                result = [AXTouchInjection ensureAccessibilityEnabled];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    result = [AXTouchInjection ensureAccessibilityEnabled];
                });
            }
            NSDictionary *payload = @{@"status": @"ok", @"result": (result ?: @{})};
            NSError *err = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
            if (jsonData.length > 0 && !err) {
                NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                return [self jsonResponse:200 body:json];
            }
            return [self jsonResponse:200 body:@"{\"status\":\"ok\",\"result\":{}}"];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/diagnostics"]) {
        if ([method isEqualToString:@"GET"]) {
            __block NSDictionary *payload = nil;
            if ([NSThread isMainThread]) {
                UIApplication *app = [UIApplication sharedApplication];
                NSUInteger sceneCount = 0;
                NSUInteger activeSceneCount = 0;
                NSUInteger totalWindows = 0;
                NSMutableArray *windowSummaries = [NSMutableArray array];
                for (id scene in app.connectedScenes) {
                    sceneCount++;
                    NSInteger sceneState = -1;
                    SEL activationSel = NSSelectorFromString(@"activationState");
                    if ([scene respondsToSelector:activationSel]) {
                        sceneState = ((NSInteger (*)(id, SEL))objc_msgSend)(scene, activationSel);
                        if (sceneState == 0 || sceneState == 1) { // foreground active/inactive
                            activeSceneCount++;
                        }
                    }
                    SEL windowsSel = NSSelectorFromString(@"windows");
                    if ([scene respondsToSelector:windowsSel]) {
                        NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(scene, windowsSel);
                        if ([wins isKindOfClass:[NSArray class]]) {
                            totalWindows += wins.count;
                            for (UIWindow *window in wins) {
                                if (![window isKindOfClass:[UIWindow class]]) continue;
                                if (windowSummaries.count >= 24) break;
                                CGRect frame = window.frame;
                                NSString *vcName = window.rootViewController ? NSStringFromClass([window.rootViewController class]) : @"";
                                [windowSummaries addObject:@{
                                    @"class": NSStringFromClass([window class]) ?: @"",
                                    @"level": @(window.windowLevel),
                                    @"hidden": @(window.hidden),
                                    @"alpha": @(window.alpha),
                                    @"key": @(window.isKeyWindow),
                                    @"subviews": @(window.subviews.count),
                                    @"sceneState": @(sceneState),
                                    @"rootVC": vcName,
                                    @"frame": @{
                                        @"x": @(frame.origin.x),
                                        @"y": @(frame.origin.y),
                                        @"w": @(frame.size.width),
                                        @"h": @(frame.size.height),
                                    }
                                }];
                            }
                        }
                    }
                }
                NSDictionary *a11y = [AccessibilityTree debugInfo] ?: @{};
                payload = @{
                    @"status": @"ok",
                    @"bundleID": [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                    @"frontmostBundleID": KimiRunFrontmostBundleID() ?: @"",
                    @"screenBrightness": @([UIScreen mainScreen].brightness),
                    @"idleTimerDisabled": @(app.idleTimerDisabled),
                    @"sceneCount": @(sceneCount),
                    @"activeSceneCount": @(activeSceneCount),
                    @"windowCount": @(totalWindows),
                    @"windows": windowSummaries,
                    @"lockState": KimiRunLockState(),
                    @"a11yDebug": a11y
                };
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    UIApplication *app = [UIApplication sharedApplication];
                    NSUInteger sceneCount = 0;
                    NSUInteger activeSceneCount = 0;
                    NSUInteger totalWindows = 0;
                    NSMutableArray *windowSummaries = [NSMutableArray array];
                    for (id scene in app.connectedScenes) {
                        sceneCount++;
                        NSInteger sceneState = -1;
                        SEL activationSel = NSSelectorFromString(@"activationState");
                        if ([scene respondsToSelector:activationSel]) {
                            sceneState = ((NSInteger (*)(id, SEL))objc_msgSend)(scene, activationSel);
                            if (sceneState == 0 || sceneState == 1) {
                                activeSceneCount++;
                            }
                        }
                        SEL windowsSel = NSSelectorFromString(@"windows");
                        if ([scene respondsToSelector:windowsSel]) {
                            NSArray *wins = ((id (*)(id, SEL))objc_msgSend)(scene, windowsSel);
                            if ([wins isKindOfClass:[NSArray class]]) {
                                totalWindows += wins.count;
                                for (UIWindow *window in wins) {
                                    if (![window isKindOfClass:[UIWindow class]]) continue;
                                    if (windowSummaries.count >= 24) break;
                                    CGRect frame = window.frame;
                                    NSString *vcName = window.rootViewController ? NSStringFromClass([window.rootViewController class]) : @"";
                                    [windowSummaries addObject:@{
                                        @"class": NSStringFromClass([window class]) ?: @"",
                                        @"level": @(window.windowLevel),
                                        @"hidden": @(window.hidden),
                                        @"alpha": @(window.alpha),
                                        @"key": @(window.isKeyWindow),
                                        @"subviews": @(window.subviews.count),
                                        @"sceneState": @(sceneState),
                                        @"rootVC": vcName,
                                        @"frame": @{
                                            @"x": @(frame.origin.x),
                                            @"y": @(frame.origin.y),
                                            @"w": @(frame.size.width),
                                            @"h": @(frame.size.height),
                                        }
                                    }];
                                }
                            }
                        }
                    }
                    NSDictionary *a11y = [AccessibilityTree debugInfo] ?: @{};
                    payload = @{
                        @"status": @"ok",
                        @"bundleID": [[NSBundle mainBundle] bundleIdentifier] ?: @"",
                        @"frontmostBundleID": KimiRunFrontmostBundleID() ?: @"",
                        @"screenBrightness": @([UIScreen mainScreen].brightness),
                        @"idleTimerDisabled": @(app.idleTimerDisabled),
                        @"sceneCount": @(sceneCount),
                        @"activeSceneCount": @(activeSceneCount),
                        @"windowCount": @(totalWindows),
                        @"windows": windowSummaries,
                        @"lockState": KimiRunLockState(),
                        @"a11yDebug": a11y
                    };
                });
            }

            NSError *err = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(payload ?: @{@"status": @"ok"}) options:0 error:&err];
            if (jsonData.length > 0 && !err) {
                NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                return [self jsonResponse:200 body:json];
            }
            return [self jsonResponse:200 body:@"{\"status\":\"ok\"}"];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/device/wake"]) {
        if ([method isEqualToString:@"GET"] || [method isEqualToString:@"POST"]) {
            __block NSDictionary *info = nil;
            if ([NSThread isMainThread]) {
                info = KimiRunWakeAndUnlockDevice();
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    info = KimiRunWakeAndUnlockDevice();
                });
            }

            NSMutableDictionary *payload = [NSMutableDictionary dictionary];
            payload[@"status"] = @"ok";
            if ([info isKindOfClass:[NSDictionary class]]) {
                [payload addEntriesFromDictionary:info];
            }

            NSError *jsonError = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
            if (jsonData.length > 0 && !jsonError) {
                NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                return [self jsonResponse:200 body:json];
            }
            return [self jsonResponse:200 body:@"{\"status\":\"ok\"}"];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/app/launch"]) {
        if ([method isEqualToString:@"GET"] || [method isEqualToString:@"POST"]) {
            NSString *bundleID = nil;
            if ([fullPath containsString:@"?"]) {
                NSRange queryRange = [fullPath rangeOfString:@"?"];
                NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
                bundleID = [self stringValueFromQuery:queryString key:@"bundleID"];
                if (!bundleID || bundleID.length == 0) {
                    bundleID = [self stringValueFromQuery:queryString key:@"bundleIdentifier"];
                }
            }

            if ((!bundleID || bundleID.length == 0) && body.length > 0) {
                NSDictionary *jsonBody = [self parseJSON:body];
                if ([jsonBody[@"bundleID"] isKindOfClass:[NSString class]]) {
                    bundleID = jsonBody[@"bundleID"];
                } else if ([jsonBody[@"bundleIdentifier"] isKindOfClass:[NSString class]]) {
                    bundleID = jsonBody[@"bundleIdentifier"];
                }
            }

            if (!bundleID || bundleID.length == 0) {
                return [self errorResponse:400 message:@"Missing bundleID"];
            }

            __block BOOL ok = NO;
            if ([NSThread isMainThread]) {
                ok = KimiRunLaunchAppBundleID(bundleID);
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    ok = KimiRunLaunchAppBundleID(bundleID);
                });
            }
            NSString *json = [NSString stringWithFormat:@"{\"status\":\"ok\",\"bundleID\":\"%@\",\"launched\":%s}",
                              bundleID, ok ? "true" : "false"];
            return [self jsonResponse:200 body:json];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/apps"]) {
        if ([method isEqualToString:@"GET"]) {
            BOOL includeSystem = NO;
            NSInteger limit = 0;
            BOOL compact = YES;

            if ([fullPath containsString:@"?"]) {
                NSRange queryRange = [fullPath rangeOfString:@"?"];
                NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
                NSString *systemApps = [self stringValueFromQuery:queryString key:@"systemApps"];
                includeSystem = [systemApps.lowercaseString isEqualToString:@"true"] ||
                                [systemApps isEqualToString:@"1"];
                NSString *limitStr = [self stringValueFromQuery:queryString key:@"limit"];
                if (limitStr.length > 0) {
                    limit = [limitStr integerValue];
                }
                NSString *compactStr = [self stringValueFromQuery:queryString key:@"compact"];
                if (compactStr.length > 0) {
                    compact = ([compactStr.lowercaseString isEqualToString:@"true"] ||
                               [compactStr isEqualToString:@"1"]);
                }
            }

            __block NSArray *apps = nil;
            if ([NSThread isMainThread]) {
                apps = KimiRunListApplications(includeSystem);
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    apps = KimiRunListApplications(includeSystem);
                });
            }

            if (limit > 0 && apps.count > (NSUInteger)limit) {
                apps = [apps subarrayWithRange:NSMakeRange(0, (NSUInteger)limit)];
            }

            NSError *error = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(apps ?: @[])
                                                               options:(compact ? 0 : NSJSONWritingPrettyPrinted)
                                                                 error:&error];
            if (error || !jsonData) {
                return [self jsonResponse:500 body:@"{\"success\":false,\"error\":\"Failed to serialize app list\"}"];
            }
            NSString *appsJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            NSString *json = [NSString stringWithFormat:@"{\"success\":true,\"data\":%@}", appsJson ?: @"[]"];
            return [self jsonResponse:200 body:json];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/uiHierarchy"]) {
        if ([method isEqualToString:@"GET"]) {
            __block NSDictionary *tree = nil;
            if ([NSThread isMainThread]) {
                tree = [AccessibilityTree getFullTree];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    tree = [AccessibilityTree getFullTree];
                });
            }

            NSError *error = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(tree ?: @{})
                                                               options:NSJSONWritingPrettyPrinted
                                                                 error:&error];
            if (error || !jsonData) {
                return [self jsonResponse:500 body:@"{\"success\":false,\"error\":\"Failed to build UI hierarchy\"}"];
            }
            NSString *treeJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            NSString *json = [NSString stringWithFormat:@"{\"success\":true,\"data\":%@}", treeJson ?: @"{}"];
            return [self jsonResponse:200 body:json];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/screen"]) {
        if ([method isEqualToString:@"GET"]) {
            __block NSDictionary *data = nil;
            if ([NSThread isMainThread]) {
                UIScreen *screen = [UIScreen mainScreen];
                CGRect bounds = screen.bounds;
                data = @{
                    @"width": @(CGRectGetWidth(bounds)),
                    @"height": @(CGRectGetHeight(bounds)),
                    @"scale": @(screen.scale),
                };
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    UIScreen *screen = [UIScreen mainScreen];
                    CGRect bounds = screen.bounds;
                    data = @{
                        @"width": @(CGRectGetWidth(bounds)),
                        @"height": @(CGRectGetHeight(bounds)),
                        @"scale": @(screen.scale),
                    };
                });
            }

            NSError *error = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@{@"success": @YES, @"data": (data ?: @{})}
                                                               options:0
                                                                 error:&error];
            if (error || !jsonData) {
                return [self jsonResponse:500 body:@"{\"success\":false,\"error\":\"Failed to get screen info\"}"];
            }
            NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            return [self jsonResponse:200 body:json ?: @"{\"success\":false}"];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/screenshot"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleScreenshotRequest];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else if ([path isEqualToString:@"/screenshot/file"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleScreenshotFileRequest:fullPath];
        }
        return [self errorResponse:405 message:@"Method Not Allowed"];
    } else {
        return [self errorResponse:404 message:@"Not Found"];
    }
}

#pragma mark - Raw SimulateTouch Tap (exact replica)

- (NSString *)handleRawSimulateTouchTap:(NSString *)fullPath {
    // Parse x,y,sid from query
    CGFloat x = 0, y = 0;
    NSString *sidOverride = nil;
    NSURLComponents *comps = [NSURLComponents componentsWithString:fullPath ?: @""];
    for (NSURLQueryItem *item in comps.queryItems) {
        if ([item.name isEqualToString:@"x"]) x = [item.value doubleValue];
        if ([item.name isEqualToString:@"y"]) y = [item.value doubleValue];
        if ([item.name isEqualToString:@"sid"]) sidOverride = item.value;
    }
    if (x <= 0 || y <= 0) {
        return [self errorResponse:400 message:@"Missing x,y"];
    }

    // Load IOKit functions via dlsym - use void* to avoid type conflicts
    typedef void* (*RawCreateDigitizerFunc)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, float, float, float, float, float, uint8_t, uint8_t, uint32_t);
    typedef void* (*RawCreateFingerFunc)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, float, float, float, float, float, uint8_t, uint8_t, uint32_t);
    typedef void (*RawSetIntFunc)(void*, uint32_t, long);
    typedef void (*RawSetFloatFunc)(void*, uint32_t, float);
    typedef void (*RawSetSenderFunc)(void*, uint64_t);
    typedef void (*RawAppendFunc)(void*, void*);
    typedef void* (*RawCreateClientFunc)(CFAllocatorRef);
    typedef void (*RawDispatchFunc)(void*, void*);

    static void *s_iokit = NULL;
    static RawCreateDigitizerFunc s_createDigi = NULL;
    static RawCreateFingerFunc s_createFinger = NULL;
    static RawSetIntFunc s_setInt = NULL;
    static RawSetFloatFunc s_setFloat = NULL;
    static RawSetSenderFunc s_setSender = NULL;
    static RawAppendFunc s_append = NULL;
    static RawCreateClientFunc s_createClient = NULL;
    static RawDispatchFunc s_dispatch = NULL;
    static void *s_rawClient = NULL;

    if (!s_iokit) {
        s_iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (s_iokit) {
            s_createDigi = (RawCreateDigitizerFunc)dlsym(s_iokit, "IOHIDEventCreateDigitizerEvent");
            s_createFinger = (RawCreateFingerFunc)dlsym(s_iokit, "IOHIDEventCreateDigitizerFingerEvent");
            s_setInt = (RawSetIntFunc)dlsym(s_iokit, "IOHIDEventSetIntegerValue");
            s_setFloat = (RawSetFloatFunc)dlsym(s_iokit, "IOHIDEventSetFloatValue");
            s_setSender = (RawSetSenderFunc)dlsym(s_iokit, "IOHIDEventSetSenderID");
            s_append = (RawAppendFunc)dlsym(s_iokit, "IOHIDEventAppendEvent");
            s_createClient = (RawCreateClientFunc)dlsym(s_iokit, "IOHIDEventSystemClientCreate");
            s_dispatch = (RawDispatchFunc)dlsym(s_iokit, "IOHIDEventSystemClientDispatchEvent");
        }
    }
    if (!s_createDigi || !s_createFinger || !s_setInt || !s_setSender || !s_createClient || !s_dispatch) {
        return [self errorResponse:500 message:@"IOKit symbols not loaded"];
    }

    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat sw = bounds.size.width > 0 ? bounds.size.width : 375.0;
    CGFloat sh = bounds.size.height > 0 ? bounds.size.height : 812.0;
    uint64_t senderID = [KimiRunTouchInjection senderID];
    if (senderID == 0) senderID = 0x100000568;
    // Allow sender ID override via ?sid=0x... or ?sid=decimal
    if (sidOverride.length > 0) {
        if ([sidOverride hasPrefix:@"0x"] || [sidOverride hasPrefix:@"0X"]) {
            unsigned long long parsed = 0;
            NSScanner *sc = [NSScanner scannerWithString:sidOverride];
            [sc scanHexLongLong:&parsed];
            if (parsed > 0) senderID = parsed;
        } else {
            uint64_t parsed = (uint64_t)[sidOverride longLongValue];
            if (parsed > 0) senderID = parsed;
        }
    }

    if (!s_rawClient) {
        s_rawClient = s_createClient(kCFAllocatorDefault);
    }
    if (!s_rawClient) {
        return [self errorResponse:500 message:@"Client creation failed"];
    }

    float normX = (float)(x / sw);
    float normY = (float)(y / sh);
    NSString *usedDispatch = @"client_dispatch";

    // Helper block: create event pair (down + up) and dispatch
    void (^createAndDispatch)(void (^)(void *, uint64_t)) = ^(void (^dispatchFn)(void *, uint64_t)) {
        // === TOUCH DOWN ===
        uint64_t ts = mach_absolute_time();
        void *parent = s_createDigi(kCFAllocatorDefault, ts, 3, 99, 1, 0, 0,
            0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0, 0, 0);
        s_setInt(parent, 0xb0019, 1);
        s_setInt(parent, 0x4, 1);
        void *child = s_createFinger(kCFAllocatorDefault, ts, 0, 3, 3,
            normX, normY, 0.0f, 0.0f, 0.0f, 1, 1, 0);
        if (s_setFloat) {
            s_setFloat(child, 0xb0014, 0.04f);
            s_setFloat(child, 0xb0015, 0.04f);
        }
        s_append(parent, child);
        CFRelease(child);
        s_setInt(parent, 0xb0007, 0x23);
        s_setInt(parent, 0xb0008, 0x1);
        s_setInt(parent, 0xb0009, 0x1);
        s_setSender(parent, senderID);
        dispatchFn(parent, senderID);
        CFRelease(parent);

        usleep(50000);

        // === TOUCH UP ===
        ts = mach_absolute_time();
        parent = s_createDigi(kCFAllocatorDefault, ts, 3, 99, 1, 0, 0,
            0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0, 0, 0);
        s_setInt(parent, 0xb0019, 1);
        s_setInt(parent, 0x4, 1);
        child = s_createFinger(kCFAllocatorDefault, ts, 0, 3, 2,
            normX, normY, 0.0f, 0.0f, 0.0f, 0, 0, 0);
        if (s_setFloat) {
            s_setFloat(child, 0xb0014, 0.04f);
            s_setFloat(child, 0xb0015, 0.04f);
        }
        s_append(parent, child);
        CFRelease(child);
        s_setInt(parent, 0xb0007, 0x23);
        s_setInt(parent, 0xb0008, 0x1);
        s_setInt(parent, 0xb0009, 0x1);
        s_setSender(parent, senderID);
        dispatchFn(parent, senderID);
        CFRelease(parent);
    };

    // Only safe dispatch: IOHIDEventSystemClientDispatchEvent on current thread
    // NOTE: enqueue/focused/main dispatch modes removed - they crash backboardd
    createAndDispatch(^(void *event, uint64_t sid) {
        s_dispatch(s_rawClient, event);
    });
    usedDispatch = @"client_dispatch";

    return [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"mode\":\"raw_simtouch\",\"x\":%.1f,\"y\":%.1f,\"senderID\":\"0x%llX\",\"normX\":%.4f,\"normY\":%.4f,\"dispatch\":\"%@\"}",
        x, y, senderID, normX, normY, usedDispatch];
}

#pragma mark - Touch Endpoints

- (NSString *)handleTapRequest:(NSString *)body query:(NSString *)fullPath {
    CGFloat x = 0, y = 0;
    NSString *method = nil;
    
    // Try to parse from query string (GET request)
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        x = [self floatValueFromQuery:queryString key:@"x"];
        y = [self floatValueFromQuery:queryString key:@"y"];
        method = [self stringValueFromQuery:queryString key:@"method"];
    }
    
    // If no query params, try to parse from JSON body
    if (x == 0 && y == 0 && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        x = [json[@"x"] floatValue];
        y = [json[@"y"] floatValue];
        if ([json[@"method"] isKindOfClass:[NSString class]]) {
            method = json[@"method"];
        }
    }
    
    // Validate coordinates
    if (x <= 0 || y <= 0) {
        return [self errorResponse:400 message:@"Missing or invalid coordinates (x, y)"];
    }
    
    NSLog(@"[KimiRunHTTPServer] Tap request: (%.1f, %.1f)", x, y);
    
    // Execute tap on main thread
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [KimiRunTouchInjection tapAtX:x Y:y method:method];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [KimiRunTouchInjection tapAtX:x Y:y method:method];
        });
    }
    
    NSString *mode = KimiRunCanonicalModeFromMethod(method);
    BOOL isNonAX = (mode && ![mode isEqualToString:@"ax"] && ![mode isEqualToString:@"auto"]);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"action"] = @"tap";
    payload[@"x"] = @(x);
    payload[@"y"] = @(y);
    payload[@"mode"] = mode ?: @"auto";
    if (isNonAX) {
        NSDictionary *diag = [KimiRunTouchInjection hidDiagnostics];
        payload[@"telemetry"] = @{
            @"senderID": diag[@"senderID"] ?: @"0x0",
            @"senderCaptured": diag[@"senderCaptured"] ?: @NO,
            @"senderSource": diag[@"senderSource"] ?: @"none",
            @"hidClient": diag[@"hidClient"] ?: @"0x0",
            @"simClient": diag[@"simClient"] ?: @"0x0",
            @"dispatchedIn": @"SpringBoard",
        };
    }

    if (success) {
        payload[@"status"] = @"ok";
    } else {
        payload[@"status"] = @"error";
        payload[@"message"] = @"Failed to execute tap";
    }

    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    NSString *json = (jsonData.length > 0 && !err)
        ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
        : [NSString stringWithFormat:@"{\"status\":\"%@\",\"action\":\"tap\",\"mode\":\"%@\"}", success ? @"ok" : @"error", mode];
    return [self jsonResponse:(success ? 200 : 500) body:json];
}

- (NSString *)handleSwipeRequest:(NSString *)body query:(NSString *)path {
    CGFloat x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    NSTimeInterval duration = 0.3;  // Default 300ms
    NSString *method = nil;
    
    // Try to parse from query string (GET request)
    if ([path containsString:@"?"]) {
        NSRange queryRange = [path rangeOfString:@"?"];
        NSString *queryString = [path substringFromIndex:queryRange.location + 1];
        x1 = [self floatValueFromQuery:queryString key:@"x1"];
        y1 = [self floatValueFromQuery:queryString key:@"y1"];
        x2 = [self floatValueFromQuery:queryString key:@"x2"];
        y2 = [self floatValueFromQuery:queryString key:@"y2"];
        duration = [self floatValueFromQuery:queryString key:@"duration"];
        method = [self stringValueFromQuery:queryString key:@"method"];
    }
    
    // If no query params, try to parse from JSON body
    if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0 && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        x1 = [json[@"x1"] floatValue];
        y1 = [json[@"y1"] floatValue];
        x2 = [json[@"x2"] floatValue];
        y2 = [json[@"y2"] floatValue];
        if (json[@"duration"]) {
            duration = [json[@"duration"] doubleValue];
        }
        if ([json[@"method"] isKindOfClass:[NSString class]]) {
            method = json[@"method"];
        }
    }
    
    // Validate coordinates
    if (x1 <= 0 || y1 <= 0 || x2 <= 0 || y2 <= 0) {
        return [self errorResponse:400 message:@"Missing or invalid coordinates (x1, y1, x2, y2)"];
    }
    
    NSLog(@"[KimiRunHTTPServer] Swipe request: (%.1f, %.1f) -> (%.1f, %.1f) duration: %.2f",
          x1, y1, x2, y2, duration);
    
    // Execute swipe on main thread
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [KimiRunTouchInjection swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [KimiRunTouchInjection swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
        });
    }
    
    NSString *mode = KimiRunCanonicalModeFromMethod(method);
    BOOL isNonAX = (mode && ![mode isEqualToString:@"ax"] && ![mode isEqualToString:@"auto"]);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"action"] = @"swipe";
    payload[@"x1"] = @(x1);
    payload[@"y1"] = @(y1);
    payload[@"x2"] = @(x2);
    payload[@"y2"] = @(y2);
    payload[@"duration"] = @(duration);
    payload[@"mode"] = mode ?: @"auto";
    if (isNonAX) {
        NSDictionary *diag = [KimiRunTouchInjection hidDiagnostics];
        payload[@"telemetry"] = @{
            @"senderID": diag[@"senderID"] ?: @"0x0",
            @"senderCaptured": diag[@"senderCaptured"] ?: @NO,
            @"senderSource": diag[@"senderSource"] ?: @"none",
            @"hidClient": diag[@"hidClient"] ?: @"0x0",
            @"simClient": diag[@"simClient"] ?: @"0x0",
            @"dispatchedIn": @"SpringBoard",
        };
    }

    if (success) {
        payload[@"status"] = @"ok";
    } else {
        payload[@"status"] = @"error";
        payload[@"message"] = @"Failed to execute swipe";
    }

    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    NSString *json = (jsonData.length > 0 && !err)
        ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
        : [NSString stringWithFormat:@"{\"status\":\"%@\",\"action\":\"swipe\",\"mode\":\"%@\"}", success ? @"ok" : @"error", mode];
    return [self jsonResponse:(success ? 200 : 500) body:json];
}

- (NSString *)handleDragRequest:(NSString *)body query:(NSString *)path {
    CGFloat x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    NSTimeInterval duration = 1.0;  // Default 1 second
    NSString *method = nil;
    
    // Try to parse from query string (GET request)
    if ([path containsString:@"?"]) {
        NSRange queryRange = [path rangeOfString:@"?"];
        NSString *queryString = [path substringFromIndex:queryRange.location + 1];
        x1 = [self floatValueFromQuery:queryString key:@"x1"];
        y1 = [self floatValueFromQuery:queryString key:@"y1"];
        x2 = [self floatValueFromQuery:queryString key:@"x2"];
        y2 = [self floatValueFromQuery:queryString key:@"y2"];
        duration = [self floatValueFromQuery:queryString key:@"duration"];
        method = [self stringValueFromQuery:queryString key:@"method"];
    }
    
    // If no query params, try to parse from JSON body
    if (x1 == 0 && y1 == 0 && x2 == 0 && y2 == 0 && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        x1 = [json[@"x1"] floatValue];
        y1 = [json[@"y1"] floatValue];
        x2 = [json[@"x2"] floatValue];
        y2 = [json[@"y2"] floatValue];
        if (json[@"duration"]) {
            duration = [json[@"duration"] doubleValue];
        }
        if ([json[@"method"] isKindOfClass:[NSString class]]) {
            method = json[@"method"];
        }
    }
    
    // Validate coordinates
    if (x1 <= 0 || y1 <= 0 || x2 <= 0 || y2 <= 0) {
        return [self errorResponse:400 message:@"Missing or invalid coordinates (x1, y1, x2, y2)"];
    }
    
    NSLog(@"[KimiRunHTTPServer] Drag request: (%.1f, %.1f) -> (%.1f, %.1f) duration: %.2f",
          x1, y1, x2, y2, duration);
    
    // Execute drag on main thread
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [KimiRunTouchInjection dragFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [KimiRunTouchInjection dragFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
        });
    }
    
    NSString *mode = KimiRunCanonicalModeFromMethod(method);
    BOOL isNonAX = (mode && ![mode isEqualToString:@"ax"] && ![mode isEqualToString:@"auto"]);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"action"] = @"drag";
    payload[@"x1"] = @(x1);
    payload[@"y1"] = @(y1);
    payload[@"x2"] = @(x2);
    payload[@"y2"] = @(y2);
    payload[@"duration"] = @(duration);
    payload[@"mode"] = mode ?: @"auto";
    if (isNonAX) {
        NSDictionary *diag = [KimiRunTouchInjection hidDiagnostics];
        payload[@"telemetry"] = @{
            @"senderID": diag[@"senderID"] ?: @"0x0",
            @"senderCaptured": diag[@"senderCaptured"] ?: @NO,
            @"senderSource": diag[@"senderSource"] ?: @"none",
            @"hidClient": diag[@"hidClient"] ?: @"0x0",
            @"simClient": diag[@"simClient"] ?: @"0x0",
            @"dispatchedIn": @"SpringBoard",
        };
    }
    if (success) {
        payload[@"status"] = @"ok";
    } else {
        payload[@"status"] = @"error";
        payload[@"message"] = @"Failed to execute drag";
    }
    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    NSString *json = (jsonData.length > 0 && !err)
        ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
        : [NSString stringWithFormat:@"{\"status\":\"%@\",\"action\":\"drag\",\"mode\":\"%@\"}", success ? @"ok" : @"error", mode];
    return [self jsonResponse:(success ? 200 : 500) body:json];
}

- (NSString *)handleLongPressRequest:(NSString *)body query:(NSString *)path {
    CGFloat x = 0, y = 0;
    NSTimeInterval duration = 1.0;  // Default 1 second
    NSString *method = nil;
    
    // Try to parse from query string (GET request)
    if ([path containsString:@"?"]) {
        NSRange queryRange = [path rangeOfString:@"?"];
        NSString *queryString = [path substringFromIndex:queryRange.location + 1];
        x = [self floatValueFromQuery:queryString key:@"x"];
        y = [self floatValueFromQuery:queryString key:@"y"];
        duration = [self floatValueFromQuery:queryString key:@"duration"];
        method = [self stringValueFromQuery:queryString key:@"method"];
    }
    
    // If no query params, try to parse from JSON body
    if (x == 0 && y == 0 && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        x = [json[@"x"] floatValue];
        y = [json[@"y"] floatValue];
        if (json[@"duration"]) {
            duration = [json[@"duration"] doubleValue];
        }
        if ([json[@"method"] isKindOfClass:[NSString class]]) {
            method = json[@"method"];
        }
    }
    
    // Validate coordinates
    if (x <= 0 || y <= 0) {
        return [self errorResponse:400 message:@"Missing or invalid coordinates (x, y)"];
    }
    
    NSLog(@"[KimiRunHTTPServer] Long press request: (%.1f, %.1f) duration: %.2f", x, y, duration);
    
    // Execute long press on main thread
    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [KimiRunTouchInjection longPressAtX:x Y:y duration:duration method:method];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [KimiRunTouchInjection longPressAtX:x Y:y duration:duration method:method];
        });
    }
    
    NSString *mode = KimiRunCanonicalModeFromMethod(method);
    BOOL isNonAX = (mode && ![mode isEqualToString:@"ax"] && ![mode isEqualToString:@"auto"]);

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"action"] = @"longpress";
    payload[@"x"] = @(x);
    payload[@"y"] = @(y);
    payload[@"duration"] = @(duration);
    payload[@"mode"] = mode ?: @"auto";
    if (isNonAX) {
        NSDictionary *diag = [KimiRunTouchInjection hidDiagnostics];
        payload[@"telemetry"] = @{
            @"senderID": diag[@"senderID"] ?: @"0x0",
            @"senderCaptured": diag[@"senderCaptured"] ?: @NO,
            @"senderSource": diag[@"senderSource"] ?: @"none",
            @"hidClient": diag[@"hidClient"] ?: @"0x0",
            @"simClient": diag[@"simClient"] ?: @"0x0",
            @"dispatchedIn": @"SpringBoard",
        };
    }
    if (success) {
        payload[@"status"] = @"ok";
    } else {
        payload[@"status"] = @"error";
        payload[@"message"] = @"Failed to execute long press";
    }
    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    NSString *json = (jsonData.length > 0 && !err)
        ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]
        : [NSString stringWithFormat:@"{\"status\":\"%@\",\"action\":\"longpress\",\"mode\":\"%@\"}", success ? @"ok" : @"error", mode];
    return [self jsonResponse:(success ? 200 : 500) body:json];
}

- (NSString *)handleSenderIDRequest {
    uint64_t senderID = [KimiRunTouchInjection senderID];
    BOOL captured = [KimiRunTouchInjection senderIDCaptured];
    BOOL fallback = [KimiRunTouchInjection senderIDFallbackEnabled];
    int callbackCount = [KimiRunTouchInjection senderIDCallbackCount];
    BOOL threadRunning = [KimiRunTouchInjection senderIDCaptureThreadRunning];
    int digitizerCount = [KimiRunTouchInjection senderIDDigitizerCount];
    int lastEventType = [KimiRunTouchInjection senderIDLastEventType];
    BOOL mainRegistered = [KimiRunTouchInjection senderIDMainRegistered];
    BOOL dispatchRegistered = [KimiRunTouchInjection senderIDDispatchRegistered];
    uintptr_t hidConn = [KimiRunTouchInjection hidConnectionPtr];
    int adminClientType = [KimiRunTouchInjection adminClientType];
    NSString *source = [KimiRunTouchInjection senderIDSourceString];
    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"senderID\":\"0x%llX\",\"captured\":%s,\"fallbackEnabled\":%s,\"callbackCount\":%d,\"digitizerCount\":%d,\"lastEventType\":%d,\"threadRunning\":%s,\"mainRegistered\":%s,\"dispatchRegistered\":%s,\"hidConnection\":\"0x%lX\",\"adminClientType\":%d,\"source\":\"%@\"}",
                      senderID,
                      (captured ? "true" : "false"),
                      fallback ? "true" : "false",
                      callbackCount,
                      digitizerCount,
                      lastEventType,
                      threadRunning ? "true" : "false",
                      mainRegistered ? "true" : "false",
                      dispatchRegistered ? "true" : "false",
                      (unsigned long)hidConn,
                      adminClientType,
                      source];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleTouchDiagnosticsRequest {
    NSDictionary *diag = [KimiRunTouchInjection hidDiagnostics];
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:diag];
    payload[@"status"] = @"ok";
    payload[@"process"] = @"SpringBoard";
    payload[@"port"] = @(self.port);

    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&err];
    if (jsonData.length > 0 && !err) {
        return [self jsonResponse:200 body:[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]];
    }
    return [self jsonResponse:200 body:@"{\"status\":\"ok\"}"];
}

- (NSString *)handleSenderIDSetRequest:(NSString *)body query:(NSString *)fullPath {
    NSString *idStr = nil;
    NSString *persistStr = nil;

    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        idStr = [self stringValueFromQuery:queryString key:@"id"];
        if (!idStr || idStr.length == 0) {
            idStr = [self stringValueFromQuery:queryString key:@"senderID"];
        }
        persistStr = [self stringValueFromQuery:queryString key:@"persist"];
    }

    if ((!idStr || idStr.length == 0) && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        if ([json[@"id"] isKindOfClass:[NSString class]]) {
            idStr = json[@"id"];
        } else if ([json[@"id"] isKindOfClass:[NSNumber class]]) {
            idStr = [json[@"id"] stringValue];
        } else if ([json[@"senderID"] isKindOfClass:[NSString class]]) {
            idStr = json[@"senderID"];
        } else if ([json[@"senderID"] isKindOfClass:[NSNumber class]]) {
            idStr = [json[@"senderID"] stringValue];
        }
        if ([json[@"persist"] isKindOfClass:[NSNumber class]]) {
            persistStr = [json[@"persist"] stringValue];
        }
    }

    if (!idStr || idStr.length == 0) {
        return [self errorResponse:400 message:@"Missing id"];
    }

    unsigned long long senderID = strtoull([idStr UTF8String], NULL, 0);
    BOOL persist = (persistStr && persistStr.length > 0) ? ([persistStr intValue] != 0) : NO;
    __block BOOL ok = NO;
    if ([NSThread isMainThread]) {
        [KimiRunTouchInjection setSenderIDOverride:senderID persist:persist];
        ok = YES;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [KimiRunTouchInjection setSenderIDOverride:senderID persist:persist];
            ok = YES;
        });
    }

    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"senderID\":\"0x%llX\",\"persist\":%s}",
                      senderID, persist ? "true" : "false"];
    return ok ? [self jsonResponse:200 body:json] : [self errorResponse:500 message:@"Failed to set senderID"];
}

- (NSString *)handleForceFocusRequest {
    __block BOOL ok = NO;
    if ([NSThread isMainThread]) {
        ok = [KimiRunTouchInjection forceFocusSearchField];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            ok = [KimiRunTouchInjection forceFocusSearchField];
        });
    }
    NSString *json = [NSString stringWithFormat:@"{\"status\":\"ok\",\"forceFocused\":%s}",
                      ok ? "true" : "false"];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleBKHIDSelectorsRequest {
    [KimiRunTouchInjection logBKHIDSelectorsNow];
    NSString *path = [KimiRunTouchInjection bkhidSelectorsLogPath];
    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"logged\":true,\"path\":\"%@\"}",
                      path];
    return [self jsonResponse:200 body:json];
}

#pragma mark - Keyboard Endpoints

- (NSString *)handleKeyboardTypeRequest:(NSString *)body query:(NSString *)fullPath {
    NSString *text = nil;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        text = [self stringValueFromQuery:queryString key:@"text"];
    }
    if ((!text || text.length == 0) && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        if ([json[@"text"] isKindOfClass:[NSString class]]) {
            text = json[@"text"];
        }
    }
    if (!text || text.length == 0) {
        return [self errorResponse:400 message:@"Missing text"];
    }

    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [KimiRunTouchInjection typeText:text];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [KimiRunTouchInjection typeText:text];
        });
    }

    if (success) {
        NSString *json = [NSString stringWithFormat:@"{\"status\":\"ok\",\"action\":\"type\",\"text\":\"%@\"}", text];
        return [self jsonResponse:200 body:json];
    }
    return [self errorResponse:500 message:@"Failed to type text"];
}

- (NSString *)handleKeyboardKeyRequest:(NSString *)body query:(NSString *)fullPath {
    NSString *usageStr = nil;
    NSString *downStr = nil;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        usageStr = [self stringValueFromQuery:queryString key:@"usage"];
        downStr = [self stringValueFromQuery:queryString key:@"down"];
    }
    if ((!usageStr || usageStr.length == 0) && body && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        if ([json[@"usage"] isKindOfClass:[NSString class]]) {
            usageStr = json[@"usage"];
        } else if ([json[@"usage"] isKindOfClass:[NSNumber class]]) {
            usageStr = [json[@"usage"] stringValue];
        }
        if ([json[@"down"] isKindOfClass:[NSNumber class]]) {
            downStr = [json[@"down"] stringValue];
        }
    }

    if (!usageStr || usageStr.length == 0) {
        return [self errorResponse:400 message:@"Missing usage"];
    }

    unsigned long usage = strtoul([usageStr UTF8String], NULL, 0);
    BOOL hasDown = (downStr && downStr.length > 0);
    BOOL down = hasDown ? ([downStr intValue] != 0) : YES;

    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:down];
        if (!hasDown) {
            [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:NO];
        }
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:down];
            if (!hasDown) {
                [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:NO];
            }
        });
    }

    if (success) {
        NSString *json = [NSString stringWithFormat:@"{\"status\":\"ok\",\"action\":\"key\",\"usage\":%lu,\"down\":%s}",
                          usage, down ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }
    return [self errorResponse:500 message:@"Failed to send key"];
}

#pragma mark - Screenshot Endpoint

- (NSString *)handleScreenshotRequest {
    NSLog(@"[KimiRunHTTPServer] Screenshot request");
    
    // Capture directly - UIKit screenshot needs main thread
    // We're called from CFSocket callback which is on main run loop
    NSString *base64String = [[KimiRunScreenshot sharedScreenshot] captureScreenAsBase64PNG];
    
    if (base64String) {
        NSString *json = [NSString stringWithFormat:@"{\"status\":\"ok\",\"format\":\"PNG\",\"data\":\"%@\"}", base64String];
        return [self jsonResponse:200 body:json];
    } else {
        return [self errorResponse:500 message:@"Failed to capture screenshot"];
    }
}

- (NSString *)handleScreenshotFileRequest:(NSString *)fullPath {
    NSString *format = nil;
    NSString *qualityStr = nil;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        format = [self stringValueFromQuery:queryString key:@"format"];
        qualityStr = [self stringValueFromQuery:queryString key:@"quality"];
    }

    NSString *lower = format ? [format lowercaseString] : @"png";
    NSData *data = nil;
    if ([lower isEqualToString:@"jpeg"] || [lower isEqualToString:@"jpg"]) {
        CGFloat quality = 0.8;
        if (qualityStr && qualityStr.length > 0) {
            quality = (CGFloat)[qualityStr doubleValue];
        }
        data = [[KimiRunScreenshot sharedScreenshot] captureScreenAsJPEGWithQuality:quality];
    } else {
        data = [[KimiRunScreenshot sharedScreenshot] captureScreenAsPNG];
        lower = @"png";
    }

    if (!data) {
        return [self errorResponse:500 message:@"Failed to capture screenshot"];
    }

    NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];
    NSString *path = [NSString stringWithFormat:@"/tmp/kimirun_screen_%.0f.%@", ts, lower];
    BOOL ok = [data writeToFile:path atomically:YES];
    if (!ok) {
        return [self errorResponse:500 message:@"Failed to write screenshot"];
    }
    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"path\":\"%@\",\"bytes\":%lu,\"format\":\"%@\"}",
                      path, (unsigned long)data.length, lower];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleA11yTreeRequest:(NSString *)fullPath {
    BOOL pretty = YES;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        NSString *compactStr = [self stringValueFromQuery:queryString key:@"compact"];
        NSString *prettyStr = [self stringValueFromQuery:queryString key:@"pretty"];
        if (compactStr && [self boolValueFromString:compactStr defaultValue:NO]) {
            pretty = NO;
        }
        if (prettyStr) {
            pretty = [self boolValueFromString:prettyStr defaultValue:YES];
        }
    }

    __block NSDictionary *tree = nil;
    if ([NSThread isMainThread]) {
        tree = [AccessibilityTree getFullTree];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            tree = [AccessibilityTree getFullTree];
        });
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(tree ?: @{})
                                                       options:(pretty ? NSJSONWritingPrettyPrinted : 0)
                                                         error:&error];
    NSString *json = error ? @"{}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self jsonResponse:200 body:(json ?: @"{}")];
}

- (NSString *)handleA11yInteractiveRequest:(NSString *)fullPath {
    BOOL pretty = YES;
    NSInteger limit = 0;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        NSString *compactStr = [self stringValueFromQuery:queryString key:@"compact"];
        NSString *prettyStr = [self stringValueFromQuery:queryString key:@"pretty"];
        NSString *limitStr = [self stringValueFromQuery:queryString key:@"limit"];
        if (compactStr && [self boolValueFromString:compactStr defaultValue:NO]) {
            pretty = NO;
        }
        if (prettyStr) {
            pretty = [self boolValueFromString:prettyStr defaultValue:YES];
        }
        if (limitStr) {
            limit = [limitStr integerValue];
        }
    }

    __block NSArray *elements = nil;
    if ([NSThread isMainThread]) {
        elements = [AccessibilityTree getInteractiveElements];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            elements = [AccessibilityTree getInteractiveElements];
        });
    }

    if (limit > 0 && elements.count > (NSUInteger)limit) {
        elements = [elements subarrayWithRange:NSMakeRange(0, (NSUInteger)limit)];
    }

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(elements ?: @[])
                                                       options:(pretty ? NSJSONWritingPrettyPrinted : 0)
                                                         error:&error];
    NSString *json = error ? @"[]" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self jsonResponse:200 body:(json ?: @"[]")];
}

- (NSString *)handleA11yOverlayRequest:(NSString *)body query:(NSString *)fullPath {
    NSString *enabledStr = nil;
    NSString *interactiveStr = nil;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        enabledStr = [self stringValueFromQuery:queryString key:@"enabled"];
        interactiveStr = [self stringValueFromQuery:queryString key:@"interactiveOnly"];
    }

    NSDictionary *jsonBody = nil;
    if (!enabledStr && body && body.length > 0) {
        jsonBody = [self parseJSON:body];
        if ([jsonBody[@"enabled"] isKindOfClass:[NSNumber class]] ||
            [jsonBody[@"enabled"] isKindOfClass:[NSString class]]) {
            enabledStr = [NSString stringWithFormat:@"%@", jsonBody[@"enabled"]];
        }
        if ([jsonBody[@"interactiveOnly"] isKindOfClass:[NSNumber class]] ||
            [jsonBody[@"interactiveOnly"] isKindOfClass:[NSString class]]) {
            interactiveStr = [NSString stringWithFormat:@"%@", jsonBody[@"interactiveOnly"]];
        }
    }

    if (!enabledStr) {
        return [self errorResponse:400 message:@"Missing enabled parameter"];
    }

    BOOL enabled = [self boolValueFromString:enabledStr defaultValue:NO];
    BOOL interactiveOnly = interactiveStr ? [self boolValueFromString:interactiveStr defaultValue:YES] : YES;

    if ([NSThread isMainThread]) {
        [AccessibilityTree setOverlayEnabled:enabled interactiveOnly:interactiveOnly];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [AccessibilityTree setOverlayEnabled:enabled interactiveOnly:interactiveOnly];
        });
    }

    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"enabled\":%s,\"interactiveOnly\":%s}",
                      enabled ? "true" : "false",
                      interactiveOnly ? "true" : "false"];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleA11yDebugRequest {
    __block NSDictionary *info = nil;
    if ([NSThread isMainThread]) {
        info = [AccessibilityTree debugInfo];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            info = [AccessibilityTree debugInfo];
        });
    }
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(info ?: @{}) options:0 error:&error];
    NSString *json = error ? @"{}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleA11yActivateRequest:(NSString *)body query:(NSString *)fullPath {
    NSString *indexStr = nil;
    if ([fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        indexStr = [self stringValueFromQuery:queryString key:@"index"];
    }

    NSDictionary *jsonBody = nil;
    if (!indexStr && body && body.length > 0) {
        jsonBody = [self parseJSON:body];
        if (jsonBody[@"index"]) {
            indexStr = [NSString stringWithFormat:@"%@", jsonBody[@"index"]];
        }
    }

    if (!indexStr) {
        return [self errorResponse:400 message:@"Missing index parameter"];
    }

    NSInteger index = [indexStr integerValue];
    if (index < 0) {
        return [self errorResponse:400 message:@"Invalid index parameter"];
    }

    __block BOOL success = NO;
    if ([NSThread isMainThread]) {
        success = [AccessibilityTree activateInteractiveElementAtIndex:(NSUInteger)index];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            success = [AccessibilityTree activateInteractiveElementAtIndex:(NSUInteger)index];
        });
    }

    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"index\":%ld,\"activated\":%s}",
                      (long)index,
                      success ? "true" : "false"];
    return [self jsonResponse:200 body:json];
}

#pragma mark - Helper Methods

- (CGFloat)floatValueFromQuery:(NSString *)query key:(NSString *)key {
    NSString *pattern = [NSString stringWithFormat:@"%@=", key];
    NSRange keyRange = [query rangeOfString:pattern];
    if (keyRange.location == NSNotFound) {
        return 0;
    }
    
    NSUInteger start = keyRange.location + keyRange.length;
    NSRange endRange = [query rangeOfString:@"&" options:0 range:NSMakeRange(start, query.length - start)];
    
    NSString *value;
    if (endRange.location == NSNotFound) {
        value = [query substringFromIndex:start];
    } else {
        value = [query substringWithRange:NSMakeRange(start, endRange.location - start)];
    }
    
    return [value floatValue];
}

- (NSString *)stringValueFromQuery:(NSString *)query key:(NSString *)key {
    NSString *pattern = [NSString stringWithFormat:@"%@=", key];
    NSRange keyRange = [query rangeOfString:pattern];
    if (keyRange.location == NSNotFound) {
        return nil;
    }
    
    NSUInteger start = keyRange.location + keyRange.length;
    NSRange endRange = [query rangeOfString:@"&" options:0 range:NSMakeRange(start, query.length - start)];
    
    NSString *value;
    if (endRange.location == NSNotFound) {
        value = [query substringFromIndex:start];
    } else {
        value = [query substringWithRange:NSMakeRange(start, endRange.location - start)];
    }
    
    return value.length ? value : nil;
}

- (BOOL)boolValueFromString:(NSString *)value defaultValue:(BOOL)defaultValue {
    if (!value || value.length == 0) {
        return defaultValue;
    }
    NSString *lower = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]) {
        return YES;
    }
    if ([lower isEqualToString:@"0"] || [lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]) {
        return NO;
    }
    return defaultValue;
}

- (NSDictionary *)parseJSON:(NSString *)jsonString {
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        return nil;
    }
    
    NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![result isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    
    return result;
}

#pragma mark - Endpoint Responses

- (NSString *)pingResponse {
    NSString *json = @"{\"status\":\"ok\",\"message\":\"pong\"}";
    return [self jsonResponse:200 body:json];
}

- (NSString *)stateResponse {
    UIDevice *device = [UIDevice currentDevice];
    struct utsname systemInfo;
    uname(&systemInfo);
    
    NSString *deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    NSString *systemName = device.systemName;
    NSString *systemVersion = device.systemVersion;
    NSString *deviceName = device.name;
    
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    
    NSDictionary *state = @{
        @"status": @"ok",
        @"device": @{
            @"name": deviceName ?: @"Unknown",
            @"model": deviceModel ?: @"Unknown",
            @"system": @{
                @"name": systemName ?: @"Unknown",
                @"version": systemVersion ?: @"Unknown"
            },
            @"screen": @{
                @"width": @(screenBounds.size.width),
                @"height": @(screenBounds.size.height)
            }
        },
        @"server": @{
            @"port": @(self.port),
            @"running": @(self.isRunning)
        },
        @"touch": @{
            @"available": @([KimiRunTouchInjection isAvailable])
        }
    };
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    NSString *jsonString = error ? @"{\"status\":\"error\"}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    return [self jsonResponse:200 body:jsonString];
}

#pragma mark - HTTP Response Helpers

- (NSString *)jsonResponse:(NSInteger)statusCode body:(NSString *)body {
    NSString *safeBody = body ?: @"";
    NSData *bodyData = [safeBody dataUsingEncoding:NSUTF8StringEncoding];
    NSString *statusText = [self statusTextForCode:statusCode];
    return [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"\r\n"
        @"%@",
        (long)statusCode, statusText,
        (unsigned long)(bodyData ? bodyData.length : 0),
        safeBody
    ];
}

- (NSString *)errorResponse:(NSInteger)statusCode message:(NSString *)message {
    NSString *json = [NSString stringWithFormat:@"{\"status\":\"error\",\"message\":\"%@\"}", message];
    return [self jsonResponse:statusCode body:json];
}

- (NSString *)statusTextForCode:(NSInteger)code {
    switch (code) {
        case 200: return @"OK";
        case 400: return @"Bad Request";
        case 404: return @"Not Found";
        case 405: return @"Method Not Allowed";
        case 500: return @"Internal Server Error";
        default: return @"Unknown";
    }
}

- (BOOL)isCaptureEndpointPath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return NO;
    }
    if ([path isEqualToString:@"/uiHierarchy"] ||
        [path isEqualToString:@"/screenshot"] ||
        [path isEqualToString:@"/screenshot/file"] ||
        [path isEqualToString:@"/a11y/tree"] ||
        [path isEqualToString:@"/a11y/interactive"] ||
        [path isEqualToString:@"/a11y/debug"] ||
        [path isEqualToString:@"/a11y/activate"] ||
        [path isEqualToString:@"/a11y/overlay"]) {
        return YES;
    }
    return NO;
}

- (BOOL)isTouchEndpointPath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return NO;
    }
    return ([path isEqualToString:@"/tap"] ||
            [path isEqualToString:@"/swipe"] ||
            [path isEqualToString:@"/drag"] ||
            [path isEqualToString:@"/longpress"]);
}

- (NSString *)touchMethodFromFullPath:(NSString *)fullPath body:(NSString *)body {
    NSString *method = nil;
    if ([fullPath isKindOfClass:[NSString class]] && [fullPath containsString:@"?"]) {
        NSRange queryRange = [fullPath rangeOfString:@"?"];
        NSString *query = [fullPath substringFromIndex:queryRange.location + 1];
        method = [self stringValueFromQuery:query key:@"method"];
    }
    if ((![method isKindOfClass:[NSString class]] || method.length == 0) &&
        [body isKindOfClass:[NSString class]] && body.length > 0) {
        NSDictionary *json = [self parseJSON:body];
        if ([json[@"method"] isKindOfClass:[NSString class]]) {
            method = json[@"method"];
        }
    }
    if (![method isKindOfClass:[NSString class]] || method.length == 0) {
        return @"auto";
    }
    NSString *lower = [[method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return lower.length ? lower : @"auto";
}

- (BOOL)shouldProxyForegroundTouchMethod:(NSString *)method {
    NSString *lower = @"auto";
    if ([method isKindOfClass:[NSString class]] && method.length > 0) {
        lower = [[method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    }
    if (lower.length == 0 || [lower isEqualToString:@"auto"] || [lower isEqualToString:@"ax"]) {
        return YES;
    }
    return NO;
}

- (NSString *)proxyForegroundTouchRequestIfNeededWithMethod:(NSString *)method
                                                   fullPath:(NSString *)fullPath
                                                       path:(NSString *)path
                                                       body:(NSString *)body {
    // Only SpringBoard touch server should proxy touch actions into foreground app process.
    if (self.port != 8765 || ![self isTouchEndpointPath:path]) {
        return nil;
    }

    NSString *requestedMethod = [self touchMethodFromFullPath:fullPath body:body];
    if (![self shouldProxyForegroundTouchMethod:requestedMethod]) {
        return nil;
    }

    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    if (sLastGoodTouchPort != 0 && sLastGoodTouchPort != self.port) {
        [candidates addObject:@(sLastGoodTouchPort)];
    }
    for (NSNumber *candidate in @[@8766, @8767]) {
        NSUInteger candidatePort = candidate.unsignedIntegerValue;
        if (candidatePort == 0 || candidatePort == self.port) {
            continue;
        }
        if ([candidates containsObject:@(candidatePort)]) {
            continue;
        }
        [candidates addObject:@(candidatePort)];
    }

    for (NSNumber *candidate in candidates) {
        NSUInteger port = candidate.unsignedIntegerValue;
        NSString *fallbackResponse = [self proxyRequestToLocalPort:port method:method fullPath:fullPath body:body];
        if (fallbackResponse) {
            sLastGoodTouchPort = port;
            NSLog(@"[KimiRunHTTPServer] Foreground touch proxy -> :%lu for %@ method=%@",
                  (unsigned long)port, fullPath, requestedMethod ?: @"auto");
            return fallbackResponse;
        }
    }
    return nil;
}

- (NSString *)proxyForegroundCaptureRequestIfNeededWithMethod:(NSString *)method
                                                     fullPath:(NSString *)fullPath
                                                         path:(NSString *)path
                                                         body:(NSString *)body {
    // Only SpringBoard capture server (8765) should proxy to foreground app servers.
    if (self.port != 8765 || ![self isCaptureEndpointPath:path]) {
        return nil;
    }

    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    if (sLastGoodCapturePort != 0 && sLastGoodCapturePort != self.port) {
        [candidates addObject:@(sLastGoodCapturePort)];
    }

    // Foreground ownership recovery:
    // Prefer known in-app capture servers first. This avoids blocking on
    // fragile SpringBoard foreground queries when capture is requested.
    for (NSNumber *candidate in @[@8766, @8767]) {
        NSUInteger candidatePort = candidate.unsignedIntegerValue;
        if (candidatePort == 0 || candidatePort == self.port) {
            continue;
        }
        if ([candidates containsObject:@(candidatePort)]) {
            continue;
        }
        [candidates addObject:@(candidatePort)];
    }

    for (NSNumber *candidate in candidates) {
        NSUInteger port = candidate.unsignedIntegerValue;
        NSString *fallbackResponse = [self proxyRequestToLocalPort:port method:method fullPath:fullPath body:body];
        if (fallbackResponse) {
            sLastGoodCapturePort = port;
            NSLog(@"[KimiRunHTTPServer] Foreground capture fallback -> :%lu for %@",
                  (unsigned long)port, fullPath);
            return fallbackResponse;
        }
    }

    return nil;
}

- (NSString *)proxyRequestToLocalPort:(NSUInteger)port
                               method:(NSString *)method
                             fullPath:(NSString *)fullPath
                                 body:(NSString *)body {
    NSString *requestPath = ([fullPath isKindOfClass:[NSString class]] && fullPath.length > 0) ? fullPath : @"/";
    NSString *httpMethod = ([method isKindOfClass:[NSString class]] && method.length > 0) ? method : @"GET";

    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        return nil;
    }

    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons((uint16_t)port);
    serverAddr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(sockfd, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
        close(sockfd);
        return nil;
    }

    NSData *bodyData = nil;
    BOOL includeBody = body.length > 0 && ![httpMethod isEqualToString:@"GET"];
    if (includeBody) {
        bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSMutableString *rawRequest = [NSMutableString stringWithFormat:
                                   @"%@ %@ HTTP/1.1\r\n"
                                   @"Host: 127.0.0.1:%lu\r\n"
                                   @"Connection: close\r\n",
                                   httpMethod, requestPath, (unsigned long)port];
    if (includeBody && bodyData.length > 0) {
        [rawRequest appendString:@"Content-Type: application/json\r\n"];
        [rawRequest appendFormat:@"Content-Length: %lu\r\n", (unsigned long)bodyData.length];
    }
    [rawRequest appendString:@"\r\n"];

    NSMutableData *requestData = [[rawRequest dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (includeBody && bodyData.length > 0) {
        [requestData appendData:bodyData];
    }

    ssize_t sent = send(sockfd, requestData.bytes, requestData.length, 0);
    if (sent < 0) {
        close(sockfd);
        return nil;
    }

    NSMutableData *responseData = [NSMutableData data];
    uint8_t buffer[4096];
    while (1) {
        ssize_t bytesRead = recv(sockfd, buffer, sizeof(buffer), 0);
        if (bytesRead <= 0) {
            break;
        }
        [responseData appendBytes:buffer length:(NSUInteger)bytesRead];
    }
    close(sockfd);

    if (responseData.length == 0) {
        return nil;
    }

    NSString *rawResponse = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
    if (rawResponse.length == 0) {
        return nil;
    }

    NSInteger statusCode = 200;
    NSRange firstLineEnd = [rawResponse rangeOfString:@"\r\n"];
    if (firstLineEnd.location != NSNotFound) {
        NSString *statusLine = [rawResponse substringToIndex:firstLineEnd.location];
        NSArray<NSString *> *parts = [statusLine componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            NSInteger parsed = [parts[1] integerValue];
            if (parsed > 0) {
                statusCode = parsed;
            }
        }
    }

    NSRange bodyRange = [rawResponse rangeOfString:@"\r\n\r\n"];
    NSString *responseBody = nil;
    if (bodyRange.location != NSNotFound) {
        responseBody = [rawResponse substringFromIndex:(bodyRange.location + bodyRange.length)];
    } else {
        responseBody = rawResponse;
    }
    if (!responseBody) {
        responseBody = @"{}";
    }

    NSLog(@"[KimiRunHTTPServer] Foreground capture proxied %@ -> :%lu%@ (status=%ld)",
          httpMethod, (unsigned long)port, requestPath, (long)statusCode);
    return [self jsonResponse:statusCode body:responseBody];
}

@end

#pragma mark - CFSocket Callback

static void SocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    KimiRunHTTPServer *server = (__bridge KimiRunHTTPServer *)info;
    
    if (type == kCFSocketAcceptCallBack) {
        CFSocketNativeHandle nativeSocket = *(CFSocketNativeHandle *)data;
        NSLog(@"[KimiRunHTTPServer] New connection accepted");
        [server handleConnection:nativeSocket];
    }
}
