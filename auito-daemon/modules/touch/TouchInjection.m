//
//  TouchInjection.m
//  KimiRun - Touch Injection Module
//
//  Implementation based on iOSRunPortal analysis.
//  Uses IOHIDEventCreateDigitizerEvent with normalized coordinates.
//

#import "TouchInjection.h"
#import "AXTouchInjection.h"
#import "internal/TouchInjectionInternal.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <mach/mach.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <errno.h>
#import <math.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <ctype.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOKit/IOKitLib.h>
#import "../../headers/IOHIDEvent.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"

#pragma mark - Private Classes

#pragma clang diagnostic pop

@interface UIResponder (KimiRunFirstResponder)
- (void)kr_setAsFirstResponder;
@end

#pragma mark - Static Variables

BOOL g_initialized = NO;
CGFloat g_screenWidth = 0;
CGFloat g_screenHeight = 0;
CGFloat g_screenScale = 1.0;
CGFloat g_screenPixelWidth = 0;
CGFloat g_screenPixelHeight = 0;

int g_simEventsToAppend[kSimulateTouchMaxFingerIndex][4];

// IOKit function pointers (loaded dynamically)
IOHIDEventRef (*_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef allocator,
    uint64_t timeStamp,
    IOHIDDigitizerTransducerType type,
    uint32_t index,
    uint32_t identity,
    IOHIDDigitizerEventMask eventMask,
    uint32_t buttonMask,
    float x,
    float y,
    float z,
    float pressure,
    float barrelPressure,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options) = NULL;

IOHIDEventRef (*_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t index,
    uint32_t identity,
    IOHIDDigitizerEventMask eventMask,
    float x,
    float y,
    float z,
    float pressure,
    float twist,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options) = NULL;

IOHIDEventRef (*_IOHIDEventCreateKeyboardEvent)(CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint16_t usagePage,
    uint16_t usage,
    Boolean down,
    IOHIDEventOptionBits flags) = NULL;

void (*_IOHIDEventSetIntegerValue)(IOHIDEventRef event, IOHIDEventField field, CFIndex value) = NULL;
void (*_IOHIDEventSetFloatValue)(IOHIDEventRef event, IOHIDEventField field, double value) = NULL;
void (*_IOHIDEventSetSenderID)(IOHIDEventRef event, uint64_t senderID) = NULL;
void (*_IOHIDEventAppendEvent)(IOHIDEventRef parent, IOHIDEventRef childEvent, Boolean copy) = NULL;
IOHIDEventType (*_IOHIDEventGetType)(IOHIDEventRef event) = NULL;
uint64_t (*_IOHIDEventGetSenderID)(IOHIDEventRef event) = NULL;
CFArrayRef (*_IOHIDEventGetChildren)(IOHIDEventRef event) = NULL;

IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreate)(CFAllocatorRef allocator) = NULL;
IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreateWithType)(CFAllocatorRef allocator, int type, int options) = NULL;
IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreateSimpleClient)(CFAllocatorRef allocator) = NULL;
void (*_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef client, IOHIDEventRef event) = NULL;
void (*_IOHIDEventSystemConnectionDispatchEvent)(void *connection, IOHIDEventRef event) = NULL;
void (*_IOHIDEventSystemClientSetDispatchQueue)(IOHIDEventSystemClientRef client, dispatch_queue_t queue) = NULL;
void (*_IOHIDEventSystemClientActivate)(IOHIDEventSystemClientRef client) = NULL;
void (*_IOHIDEventSystemClientScheduleWithRunLoop)(IOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode) = NULL;
void (*_IOHIDEventSystemClientRegisterEventCallback)(IOHIDEventSystemClientRef client, void *callback, void *target, void *refcon) = NULL;
void (*_IOHIDEventSystemClientUnregisterEventCallback)(IOHIDEventSystemClientRef client) = NULL;
void (*_IOHIDEventSystemClientUnscheduleWithRunLoop)(IOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode) = NULL;
int (*_IOHIDEventSystemClientSetMatching)(IOHIDEventSystemClientRef client, CFDictionaryRef match) = NULL;

// BackBoardServices fallback
Class g_bksDeliveryManagerClass = nil;
id g_bksSharedDeliveryManager = nil;
id g_bksSharedRouterManager = nil;

// Event system client
IOHIDEventSystemClientRef g_hidClient = NULL;
IOHIDEventSystemClientRef g_simClient = NULL;
IOHIDEventSystemClientRef g_adminClient = NULL;
int g_adminClientType = -1;
void *g_hidConnection = NULL;

IOHIDEventSystemClientRef g_senderClient = NULL;
uint64_t g_senderID = 0;
BOOL g_senderCaptured = NO;
int g_senderSource = 0; // 0=none, 1=ioreg, 2=callback, 3=persisted, 4=override
BOOL g_senderFallbackEnabled = YES;
int g_senderCallbackCount = 0;
BOOL g_senderThreadRunning = NO;
NSThread *g_senderThread = nil;
CFRunLoopRef g_senderRunLoop = NULL;
BOOL g_senderCleanupDone = NO;
IOHIDEventSystemClientRef g_senderClientMain = NULL;
BOOL g_senderMainRegistered = NO;
int g_senderCallbackDigitizerCount = 0;
int g_senderLastEventType = -1;
IOHIDEventSystemClientRef g_senderClientDispatch = NULL;
BOOL g_senderDispatchRegistered = NO;
// Mirror SimulateTouch defaults: no matching filters, no extra callback registrations
BOOL g_touchUseMatching = NO;
BOOL g_senderUseMatching = NO;
BOOL g_senderUseExtraCallbacks = NO;
uint64_t g_proxySenderID = 0;
BOOL g_proxySenderCaptured = NO;
int g_proxySenderDigitizerCount = 0;
NSString *g_proxySenderSource = nil;
BOOL g_loggedBKHIDSelectors = NO;
__weak id g_currentFirstResponder = nil;
NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";
static NSString *KimiRunLogPath(void) {
    return @"/var/mobile/Library/Preferences/kimirun_touch.log";
}

void KimiRunLog(NSString *line) {
    if (!line) {
        return;
    }
    @try {
        NSString *msg = [line stringByAppendingString:@"\n"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:KimiRunLogPath()];
        if (!fh) {
            [msg writeToFile:KimiRunLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            [fh writeData:data];
        }
        [fh closeFile];
    } @catch (NSException *e) {
        // Best effort only
    }
}


NSString *SenderIDPlistPath(void) {
    return @"/var/mobile/Library/Preferences/kimirun_senderid.plist";
}


#pragma mark - Helper Functions

// Get current timestamp for HID events
uint64_t GetCurrentTimestamp(void) {
    return mach_absolute_time();
}

// Update screen metrics
BOOL UpdateScreenMetrics(void) {
    UIScreen *mainScreen = [UIScreen mainScreen];
    if (!mainScreen) {
        NSLog(@"[KimiRunTouchInjection] Warning: UIScreen not available");
        return NO;
    }
    
    CGRect bounds = mainScreen.bounds;
    g_screenWidth = bounds.size.width;
    g_screenHeight = bounds.size.height;
    g_screenScale = mainScreen.scale > 0 ? mainScreen.scale : 1.0;
    if ([mainScreen respondsToSelector:@selector(nativeBounds)]) {
        CGRect nativeBounds = mainScreen.nativeBounds;
        g_screenPixelWidth = nativeBounds.size.width;
        g_screenPixelHeight = nativeBounds.size.height;
    } else {
        g_screenPixelWidth = g_screenWidth * g_screenScale;
        g_screenPixelHeight = g_screenHeight * g_screenScale;
    }
    
    if (g_screenWidth <= 0 || g_screenHeight <= 0) {
        NSLog(@"[KimiRunTouchInjection] Warning: Invalid screen dimensions");
        return NO;
    }
    
    return YES;
}

// Convert pixel coordinates to points if needed (e.g. from screenshots)
void AdjustInputCoordinates(CGFloat *x, CGFloat *y) {
    if (!x || !y) {
        return;
    }
    if (g_screenWidth <= 0 || g_screenHeight <= 0) {
        if (!UpdateScreenMetrics()) {
            return;
        }
    }
    if (g_screenScale <= 1.0) {
        return;
    }
    BOOL looksLikePixels = (*x > g_screenWidth + 1.0 || *y > g_screenHeight + 1.0) &&
                           (*x <= g_screenPixelWidth + 1.0) &&
                           (*y <= g_screenPixelHeight + 1.0);
    if (looksLikePixels) {
        *x = *x / g_screenScale;
        *y = *y / g_screenScale;
        NSLog(@"[KimiRunTouchInjection] Converted pixel coords to points: (%.1f, %.1f) scale=%.1f",
              *x, *y, g_screenScale);
    }
}


// Notify BKUserEventTimer to prevent idle timeout
void NotifyUserEvent(void) {
    @try {
        Class BKUserEventTimer = NSClassFromString(@"BKUserEventTimer");
        if (BKUserEventTimer) {
            id timer = [BKUserEventTimer performSelector:@selector(sharedInstance)];
            if (timer && [timer respondsToSelector:@selector(userEventOccurred)]) {
                [timer performSelector:@selector(userEventOccurred)];
            }
        }
    } @catch (NSException *e) {
        // Ignore - this is best-effort
    }
}

@implementation UIResponder (KimiRunFirstResponder)
- (void)kr_setAsFirstResponder {
    g_currentFirstResponder = self;
}
@end

static id CurrentFirstResponder(void) {
    g_currentFirstResponder = nil;
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(kr_setAsFirstResponder)
                                               to:nil
                                             from:nil
                                         forEvent:nil];
    } @catch (NSException *e) {
        return nil;
    }
    return g_currentFirstResponder;
}

static void LogFocusContext(NSString *prefix) {
    NSString *tag = prefix ?: @"Focus";
    id responder = CurrentFirstResponder();
    NSString *responderClass = responder ? NSStringFromClass([responder class]) : @"(nil)";
    NSLog(@"[KimiRunTouchInjection] %@: firstResponder=%@", tag, responderClass);
    KimiRunLog([NSString stringWithFormat:@"[%@] firstResponder=%@", tag, responderClass]);

    Class kbClass = NSClassFromString(@"UIKeyboardImpl");
    if (!kbClass) {
        NSLog(@"[KimiRunTouchInjection] %@: UIKeyboardImpl not found", tag);
        KimiRunLog([NSString stringWithFormat:@"[%@] UIKeyboardImpl not found", tag]);
        return;
    }
    id kb = nil;
    if ([kbClass respondsToSelector:@selector(activeInstance)]) {
        kb = [kbClass performSelector:@selector(activeInstance)];
    } else if ([kbClass respondsToSelector:@selector(sharedInstance)]) {
        kb = [kbClass performSelector:@selector(sharedInstance)];
    }
    NSLog(@"[KimiRunTouchInjection] %@: UIKeyboardImpl instance=%p", tag, kb);
    KimiRunLog([NSString stringWithFormat:@"[%@] UIKeyboardImpl instance=%p", tag, kb]);
}

static UIView *FindSearchFieldInView(UIView *view) {
    if (!view) {
        return nil;
    }
    Class searchBarClass = NSClassFromString(@"UISearchBar");
    Class textFieldClass = NSClassFromString(@"UITextField");
    Class searchTextFieldClass = NSClassFromString(@"UISearchTextField");

    if (searchBarClass && [view isKindOfClass:searchBarClass]) {
        if ([view respondsToSelector:NSSelectorFromString(@"searchTextField")]) {
            id field = [view performSelector:NSSelectorFromString(@"searchTextField")];
            if ([field isKindOfClass:textFieldClass]) {
                return field;
            }
        }
    }

    if (searchTextFieldClass && [view isKindOfClass:searchTextFieldClass]) {
        return view;
    }
    if (textFieldClass && [view isKindOfClass:textFieldClass]) {
        NSString *placeholder = nil;
        if ([view respondsToSelector:@selector(placeholder)]) {
            placeholder = [view performSelector:@selector(placeholder)];
        }
        if (placeholder && [placeholder.lowercaseString containsString:@"search"]) {
            return view;
        }
    }

    for (UIView *sub in view.subviews) {
        UIView *found = FindSearchFieldInView(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

static UITableView *FindTableViewInView(UIView *view) {
    if (!view) {
        return nil;
    }
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }
    for (UIView *sub in view.subviews) {
        UITableView *found = FindTableViewInView(sub);
        if (found) {
            return found;
        }
    }
    return nil;
}

static UIViewController *TopViewController(UIViewController *root) {
    if (!root) {
        return nil;
    }
    UIViewController *current = root;
    while (current.presentedViewController) {
        current = current.presentedViewController;
    }
    if ([current isKindOfClass:[UINavigationController class]]) {
        return TopViewController(((UINavigationController *)current).topViewController);
    }
    if ([current isKindOfClass:[UITabBarController class]]) {
        return TopViewController(((UITabBarController *)current).selectedViewController);
    }
    return current;
}

static UISearchController *FindSearchControllerInViewController(UIViewController *vc) {
    if (!vc) {
        return nil;
    }
    @try {
        if ([vc respondsToSelector:@selector(navigationItem)]) {
            UINavigationItem *item = [vc navigationItem];
            if (item && [item respondsToSelector:@selector(searchController)]) {
                UISearchController *sc = [item searchController];
                if (sc) {
                    return sc;
                }
            }
        }
        id sc = [vc valueForKey:@"searchController"];
        if ([sc isKindOfClass:[UISearchController class]]) {
            return (UISearchController *)sc;
        }
    } @catch (NSException *e) {
        // ignore
    }
    for (UIViewController *child in vc.childViewControllers) {
        UISearchController *found = FindSearchControllerInViewController(child);
        if (found) {
            return found;
        }
    }
    return nil;
}

static void LogSearchSelectorsForClass(Class cls, NSString *tag) {
    if (!cls) {
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    int logged = 0;
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (!sel) {
            continue;
        }
        NSString *name = NSStringFromSelector(sel);
        if ([name rangeOfString:@"search" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            KimiRunLog([NSString stringWithFormat:@"[%@] selector: %@", tag, name]);
            logged++;
            if (logged >= 40) {
                break;
            }
        }
    }
    if (methods) {
        free(methods);
    }
}

static BOOL ActivateSearchControllerInApp(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return NO;
    }
    UIWindow *keyWindow = nil;
    for (UIWindow *win in app.windows) {
        if (win.isKeyWindow) {
            keyWindow = win;
            break;
        }
    }
    if (!keyWindow && app.windows.count > 0) {
        keyWindow = app.windows.firstObject;
    }
    UIViewController *root = keyWindow ? keyWindow.rootViewController : nil;
    UIViewController *top = TopViewController(root);
    KimiRunLog([NSString stringWithFormat:@"[ForceFocus] topVC=%@", top ? NSStringFromClass([top class]) : @"(nil)"]);
    UISearchController *sc = FindSearchControllerInViewController(top);
    if (!sc) {
        if (top) {
            LogSearchSelectorsForClass([top class], @"ForceFocus");
        }
        return NO;
    }
    @try {
        if ([sc respondsToSelector:@selector(setActive:)]) {
            [sc setActive:YES];
        } else if ([sc respondsToSelector:@selector(setSearchResultsController:)]) {
            // no-op, but ensures selector is linked
        }
        if (sc.searchBar) {
            [sc.searchBar becomeFirstResponder];
        }
        KimiRunLog([NSString stringWithFormat:@"[ForceFocus] activated UISearchController=%@", sc]);
        return YES;
    } @catch (NSException *e) {
        KimiRunLog([NSString stringWithFormat:@"[ForceFocus] activate search controller failed: %@", e]);
        return NO;
    }
}

BOOL ForceFocusSearchField(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return NO;
    }
    // First pass: look for search field directly
    for (UIWindow *window in app.windows) {
        UIView *found = FindSearchFieldInView(window);
        if (found && [found respondsToSelector:@selector(becomeFirstResponder)]) {
            BOOL ok = (BOOL)[found becomeFirstResponder];
            NSLog(@"[KimiRunTouchInjection] ForceFocusSearchField on %@ -> %d", found, ok);
            KimiRunLog([NSString stringWithFormat:@"[ForceFocus] field=%@ ok=%d",
                      NSStringFromClass([found class]), ok]);
            return ok;
        }
    }

    if (ActivateSearchControllerInApp()) {
        return YES;
    }

    // Scroll tables to top to reveal search field, then rescan
    for (UIWindow *window in app.windows) {
        UITableView *table = FindTableViewInView(window);
        if (table) {
            CGPoint offset = CGPointMake(0, -200);
            [table setContentOffset:offset animated:NO];
            KimiRunLog(@"[ForceFocus] scrolled table to top");
        }
    }
    // Give the run loop a moment to layout
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);

    for (UIWindow *window in app.windows) {
        UIView *found = FindSearchFieldInView(window);
        if (found && [found respondsToSelector:@selector(becomeFirstResponder)]) {
            BOOL ok = (BOOL)[found becomeFirstResponder];
            NSLog(@"[KimiRunTouchInjection] ForceFocusSearchField (after scroll) on %@ -> %d", found, ok);
            KimiRunLog([NSString stringWithFormat:@"[ForceFocus] after scroll field=%@ ok=%d",
                      NSStringFromClass([found class]), ok]);
            return ok;
        }
    }

    KimiRunLog(@"[ForceFocus] no search field found (after scroll)");
    return NO;
}

static BOOL UsageForChar(unichar c, uint16_t *usage, BOOL *needsShift) {
    if (!usage || !needsShift) {
        return NO;
    }
    *needsShift = NO;

    if (c >= 'A' && c <= 'Z') {
        *needsShift = YES;
        c = (unichar)tolower((int)c);
    }
    if (c >= 'a' && c <= 'z') {
        *usage = (uint16_t)(0x04 + (c - 'a'));
        return YES;
    }
    if (c >= '1' && c <= '9') {
        *usage = (uint16_t)(0x1E + (c - '1'));
        return YES;
    }
    if (c == '0') {
        *usage = 0x27;
        return YES;
    }
    if (c == ' ') {
        *usage = 0x2C;
        return YES;
    }
    if (c == '\n' || c == '\r') {
        *usage = 0x28; // Enter
        return YES;
    }
    if (c == '\b') {
        *usage = 0x2A; // Backspace
        return YES;
    }
    return NO;
}

static BOOL TypeTextViaHID(NSString *text) {
    if (!text || text.length == 0) {
        return NO;
    }
    if (!_IOHIDEventCreateKeyboardEvent || !_IOHIDEventSystemClientDispatchEvent) {
        NSLog(@"[KimiRunTouchInjection] Keyboard HID symbols missing");
        return NO;
    }

    BOOL okAny = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        uint16_t usage = 0;
        BOOL needsShift = NO;
        if (!UsageForChar(c, &usage, &needsShift)) {
            continue;
        }
        if (needsShift) {
            [KimiRunTouchInjection sendKeyUsage:0xE1 down:YES];
            usleep(5000);
        }
        if ([KimiRunTouchInjection sendKeyUsage:usage down:YES]) {
            okAny = YES;
        }
        usleep(8000);
        [KimiRunTouchInjection sendKeyUsage:usage down:NO];
        if (needsShift) {
            usleep(3000);
            [KimiRunTouchInjection sendKeyUsage:0xE1 down:NO];
        }
        usleep(8000);
    }
    return okAny;
}


#pragma mark - Implementation

@implementation KimiRunTouchInjection

+ (uint64_t)senderID {
    return g_senderID;
}

+ (BOOL)senderIDCaptured {
    return g_senderCaptured;
}

+ (NSString *)senderIDSourceString {
    switch (g_senderSource) {
        case 1: return @"ioreg";
        case 2: return @"callback";
        case 3: return @"persisted";
        case 4: return @"override";
        default: return (g_senderID == 0 ? @"none" : @"unknown");
    }
}

+ (void)setSenderIDOverride:(uint64_t)senderID persist:(BOOL)persist {
    g_senderID = senderID;
    g_senderCaptured = NO;
    g_senderSource = (senderID != 0) ? 4 : 0;
    if (persist && senderID != 0) {
        KimiRunPersistSenderID(senderID);
    }
    if (senderID == 0) {
        // Re-attempt IORegistry lookup when clearing override
        KimiRunTryLoadSenderIDFromIORegistry();
    }
    NSLog(@"[KimiRunTouchInjection] SenderID override set: 0x%llX (persist=%d)",
          g_senderID, persist ? 1 : 0);
    KimiRunLog([NSString stringWithFormat:@"[SenderID] override=0x%llX persist=%d",
                g_senderID, persist ? 1 : 0]);
}

+ (void)setProxySenderContextWithID:(uint64_t)senderID
                           captured:(BOOL)captured
                     digitizerCount:(NSInteger)digitizerCount
                             source:(NSString *)source
{
    g_proxySenderID = senderID;
    g_proxySenderCaptured = captured;
    g_proxySenderDigitizerCount = (int)MAX((NSInteger)0, digitizerCount);
    g_proxySenderSource = [source isKindOfClass:[NSString class]] ? [source copy] : nil;

    KimiRunLog([NSString stringWithFormat:
                @"[SenderID] proxy-context id=0x%llX captured=%d digitizers=%d source=%@",
                g_proxySenderID,
                g_proxySenderCaptured ? 1 : 0,
                g_proxySenderDigitizerCount,
                g_proxySenderSource ?: @"(nil)"]);
}

+ (BOOL)proxySenderLikelyLive {
    if (g_proxySenderCaptured) {
        return YES;
    }
    if (g_proxySenderDigitizerCount > 0) {
        return YES;
    }
    return NO;
}

+ (uint64_t)proxySenderID {
    return g_proxySenderID;
}

+ (BOOL)proxySenderCaptured {
    return g_proxySenderCaptured;
}

+ (int)proxySenderDigitizerCount {
    return g_proxySenderDigitizerCount;
}

+ (NSString *)proxySenderSourceString {
    return g_proxySenderSource ?: @"proxy";
}

+ (BOOL)senderIDFallbackEnabled {
    return g_senderFallbackEnabled;
}

+ (int)senderIDCallbackCount {
    return g_senderCallbackCount;
}

+ (BOOL)senderIDCaptureThreadRunning {
    return g_senderThreadRunning;
}

+ (int)senderIDDigitizerCount {
    return g_senderCallbackDigitizerCount;
}

+ (int)senderIDLastEventType {
    return g_senderLastEventType;
}

+ (BOOL)senderIDMainRegistered {
    return g_senderMainRegistered;
}

+ (BOOL)senderIDDispatchRegistered {
    return g_senderDispatchRegistered;
}

+ (uintptr_t)hidConnectionPtr {
    return (uintptr_t)g_hidConnection;
}

+ (int)adminClientType {
    return g_adminClientType;
}

+ (BOOL)bksDeliveryManagerAvailable {
    return g_bksSharedDeliveryManager != nil;
}

+ (uintptr_t)bksDeliveryManagerPtr {
    return (uintptr_t)(__bridge void *)g_bksSharedDeliveryManager;
}

+ (BOOL)bksRouterManagerAvailable {
    return g_bksSharedRouterManager != nil;
}

+ (uintptr_t)bksRouterManagerPtr {
    return (uintptr_t)(__bridge void *)g_bksSharedRouterManager;
}

+ (NSDictionary *)lastBKSDispatchInfo {
    NSDictionary *info = KimiRunCopyLastBKSDispatchInfo();
    return info ?: @{};
}

+ (NSArray<NSDictionary *> *)recentBKSDispatchHistory:(NSUInteger)limit {
    NSArray<NSDictionary *> *history = KimiRunCopyRecentBKSDispatchHistory(limit);
    return history ?: @[];
}

+ (BOOL)forceFocusSearchField {
    return ForceFocusSearchField();
}


+ (NSDictionary *)hidDiagnostics {
    CGRect bounds = [UIScreen mainScreen].bounds;
    return @{
        @"senderID": [NSString stringWithFormat:@"0x%llX", (unsigned long long)g_senderID],
        @"senderCaptured": @(g_senderCaptured),
        @"senderSource": [self senderIDSourceString] ?: @"none",
        @"senderCallbackCount": @(g_senderCallbackCount),
        @"senderDigitizerCount": @(g_senderCallbackDigitizerCount),
        @"senderLastEventType": @(g_senderLastEventType),
        @"senderCaptureThreadRunning": @(g_senderThreadRunning),
        @"senderMainRegistered": @(g_senderMainRegistered),
        @"senderDispatchRegistered": @(g_senderDispatchRegistered),
        @"senderFallbackEnabled": @(g_senderFallbackEnabled),
        @"hidClient": [NSString stringWithFormat:@"0x%lX", (unsigned long)g_hidClient],
        @"simClient": [NSString stringWithFormat:@"0x%lX", (unsigned long)g_simClient],
        @"adminClient": [NSString stringWithFormat:@"0x%lX", (unsigned long)g_adminClient],
        @"adminClientType": @(g_adminClientType),
        @"hidConnection": [NSString stringWithFormat:@"0x%lX", (unsigned long)g_hidConnection],
        @"bksDeliveryManagerAvailable": @(g_bksSharedDeliveryManager != nil),
        @"bksDeliveryManager": [NSString stringWithFormat:@"0x%lX", (unsigned long)(uintptr_t)g_bksSharedDeliveryManager],
        @"bksRouterManagerAvailable": @(g_bksSharedRouterManager != nil),
        @"bksRouterManager": [NSString stringWithFormat:@"0x%lX", (unsigned long)(uintptr_t)g_bksSharedRouterManager],
        @"screenWidth": @(bounds.size.width),
        @"screenHeight": @(bounds.size.height),
        @"screenScale": @([UIScreen mainScreen].scale),
        @"initialized": @(g_initialized),
    };
}

+ (BOOL)isAvailable {
    return g_initialized && (g_simClient != NULL || g_hidClient != NULL || g_bksSharedDeliveryManager != nil);
}

+ (BOOL)sendKeyUsage:(uint16_t)usage down:(BOOL)down {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self sendKeyUsage:usage down:down];
        });
        return result;
    }

    if (!g_initialized) {
        if (![self initialize]) {
            return NO;
        }
    }

    if (!_IOHIDEventCreateKeyboardEvent || !_IOHIDEventSystemClientDispatchEvent) {
        NSLog(@"[KimiRunTouchInjection] Keyboard event symbols missing");
        return NO;
    }

    IOHIDEventRef event = _IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault,
                                                         GetCurrentTimestamp(),
                                                         0x07,
                                                         usage,
                                                         down,
                                                         0);
    if (!event) {
        return NO;
    }

    if (_IOHIDEventSetSenderID) {
        uint64_t sender = g_senderID != 0 ? g_senderID : kTouchSenderID;
        _IOHIDEventSetSenderID(event, sender);
    }

    BOOL dispatched = NO;
    if (g_hidClient) {
        _IOHIDEventSystemClientDispatchEvent(g_hidClient, event);
        dispatched = YES;
    }
    if (g_simClient) {
        _IOHIDEventSystemClientDispatchEvent(g_simClient, event);
        dispatched = YES;
    }
    if (g_adminClient) {
        _IOHIDEventSystemClientDispatchEvent(g_adminClient, event);
        dispatched = YES;
    }
    if (!dispatched && g_bksSharedDeliveryManager) {
        dispatched = [self deliverViaBKS:event];
    }

    CFRelease(event);
    return dispatched;
}

+ (BOOL)typeText:(NSString *)text {
    if (!text || text.length == 0) {
        return NO;
    }
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self typeText:text];
        });
        return result;
    }

    LogFocusContext(@"BeforeType");

    id responder = CurrentFirstResponder();
    if (!responder) {
        ForceFocusSearchField();
        responder = CurrentFirstResponder();
        LogFocusContext(@"AfterForceFocus");
    }
    if (responder && [responder respondsToSelector:@selector(insertText:)]) {
        @try {
            [responder performSelector:@selector(insertText:) withObject:text];
            NSLog(@"[KimiRunTouchInjection] Inserted text via first responder: %@", responder);
            KimiRunLog([NSString stringWithFormat:@"[TypeText] inserted via firstResponder=%@", NSStringFromClass([responder class])]);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[KimiRunTouchInjection] First responder insertText failed: %@", e);
            KimiRunLog([NSString stringWithFormat:@"[TypeText] firstResponder insertText failed: %@", e]);
        }
    }

    Class kbClass = NSClassFromString(@"UIKeyboardImpl");
    if (kbClass) {
        id kb = nil;
        if ([kbClass respondsToSelector:@selector(activeInstance)]) {
            kb = [kbClass performSelector:@selector(activeInstance)];
        } else if ([kbClass respondsToSelector:@selector(sharedInstance)]) {
            kb = [kbClass performSelector:@selector(sharedInstance)];
        }
        if (kb && [kb respondsToSelector:@selector(insertText:)]) {
            @try {
                [kb performSelector:@selector(insertText:) withObject:text];
                NSLog(@"[KimiRunTouchInjection] Inserted text via UIKeyboardImpl");
                KimiRunLog(@"[TypeText] inserted via UIKeyboardImpl insertText");
                return YES;
            } @catch (NSException *e) {
                NSLog(@"[KimiRunTouchInjection] UIKeyboardImpl insertText failed: %@", e);
                KimiRunLog([NSString stringWithFormat:@"[TypeText] UIKeyboardImpl insertText failed: %@", e]);
            }
        }
        // Explicit focus+insert pipeline using UIKeyboardImpl task queue (only if UIKeyboardTaskQueue exists)
        if (kb && [kb respondsToSelector:NSSelectorFromString(@"taskQueue")]) {
            id queue = [kb performSelector:NSSelectorFromString(@"taskQueue")];
            Class queueClass = queue ? [queue class] : Nil;
            if (queue && queueClass && [NSStringFromClass(queueClass) containsString:@"UIKeyboardTaskQueue"] &&
                [queue respondsToSelector:NSSelectorFromString(@"addTask:")]) {
                @try {
                    // Ensure keyboard is active if possible
                    if ([kb respondsToSelector:NSSelectorFromString(@"setKeyboardActive:")]) {
                        void (*msgSendActive)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
                        msgSendActive(kb, NSSelectorFromString(@"setKeyboardActive:"), YES);
                    }

                    void (^taskBlock)(id, int) = ^(id context, int arg2) {
                        SEL addInputSel = NSSelectorFromString(@"addInputString:withFlags:executionContext:");
                        if ([kb respondsToSelector:addInputSel]) {
                            void (*msgSendAddInput)(id, SEL, id, int, id) = (void (*)(id, SEL, id, int, id))objc_msgSend;
                            msgSendAddInput(kb, addInputSel, text, 0, context);
                        }
                    };
                    void (*msgSendAddTask)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                    msgSendAddTask(queue, NSSelectorFromString(@"addTask:"), taskBlock);
                    NSLog(@"[KimiRunTouchInjection] Inserted text via UIKeyboardTaskQueue");
                    KimiRunLog(@"[TypeText] inserted via UIKeyboardTaskQueue");
                    return YES;
                } @catch (NSException *e) {
                    NSLog(@"[KimiRunTouchInjection] UIKeyboardTaskQueue insertText failed: %@", e);
                    KimiRunLog([NSString stringWithFormat:@"[TypeText] UIKeyboardTaskQueue insertText failed: %@", e]);
                }
            } else {
                NSLog(@"[KimiRunTouchInjection] UIKeyboardTaskQueue not available (queue=%p class=%@)",
                      queue, queueClass ? NSStringFromClass(queueClass) : @"(nil)");
                KimiRunLog([NSString stringWithFormat:@"[TypeText] UIKeyboardTaskQueue not available (queue=%p class=%@)",
                          queue, queueClass ? NSStringFromClass(queueClass) : @"(nil)"]);
            }
        }
    }

    return TypeTextViaHID(text);
}


@end
