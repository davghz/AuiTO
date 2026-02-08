#import "DaemonHTTPServer.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import "../touch/TouchInjection.h"
#import "../touch/AXTouchInjection.h"
#import "../screenshot/KimiRunScreenshot.h"
#import "../accessibility/AccessibilityTree.h"
#import "../app/AppLauncher.h"

#define HTTP_BUFFER_SIZE 4096
static const NSUInteger kSpringBoardProxyPort = 8765;
static const NSUInteger kPreferencesProxyPort = 8766;
static const NSUInteger kMobileSafariProxyPort = 8767;

@interface DaemonHTTPServer ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) CFSocketRef socket;
- (NSArray<NSDictionary *> *)fetchSpringBoardInteractiveElements;
- (NSDictionary *)fetchSpringBoardDebugInfo;
- (NSData *)fetchSpringBoardScreenshotData;
- (NSData *)fetchURL:(NSURL *)url timeout:(NSTimeInterval)timeout;
- (NSString *)proxySpringBoardResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (NSString *)proxyTouchResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (NSString *)proxyTouchResponseForPath:(NSString *)path
                                timeout:(NSTimeInterval)timeout
                        resolvedPortOut:(NSUInteger *)resolvedPortOut;
- (id)proxyTouchHTTPResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (id)strictProxyResponseForPath:(NSString *)path
                          timeout:(NSTimeInterval)timeout
                 forceProxyMethod:(BOOL)forceProxyMethod
            verifyUIDeltaOnSuccess:(BOOL)verifyUIDeltaOnSuccess
               strictProxyBodyOut:(NSString **)strictProxyBodyOut
        strictProxyHadResponseOut:(BOOL *)strictProxyHadResponseOut;
- (NSString *)springBoardScreenshotDigest;
- (BOOL)verifySpringBoardUIDeltaFromDigest:(NSString *)beforeDigest timeout:(NSTimeInterval)timeout;
- (NSArray<NSDictionary *> *)fetchInteractiveElementsForPort:(NSUInteger)port;
- (NSDictionary *)fetchDebugInfoForPort:(NSUInteger)port;
- (NSString *)uiDigestForPort:(NSUInteger)port;
- (BOOL)verifyUIDeltaForPort:(NSUInteger)port
                  fromDigest:(NSString *)beforeDigest
                     timeout:(NSTimeInterval)timeout;
- (NSString *)handleSenderIDRequestAllowProxy:(BOOL)allowProxy;
- (NSString *)handleSenderIDSetRequest:(NSString *)body query:(NSString *)fullPath;
- (NSString *)handleForceFocusRequest;
- (NSString *)handleBKHIDSelectorsRequestAllowProxy:(BOOL)allowProxy;
- (id)handleClassDumpRequest:(NSString *)path;
- (id)handleClassMethodsRequest:(NSString *)path;
- (NSString *)handleAXEnableRequest:(NSString *)path;
- (NSString *)handleAXStatusRequest;
- (NSDictionary *)syncSenderIDFromSpringBoardProxyForStrictMethod:(NSString *)method;
- (NSString *)jsonResponse:(NSInteger)statusCode body:(NSString *)body;
- (NSData *)binaryResponse:(NSInteger)statusCode contentType:(NSString *)contentType body:(NSData *)body;
- (CGFloat)floatValueFromQuery:(NSString *)query key:(NSString *)key;
- (NSString *)stringValueFromQuery:(NSString *)query key:(NSString *)key;
- (BOOL)boolValueFromQuery:(NSString *)query key:(NSString *)key defaultValue:(BOOL)defaultValue;
- (NSInteger)contentLengthFromHeaderString:(NSString *)headerString;
- (NSDictionary *)parseJSONBody:(NSString *)body;
- (NSArray<NSNumber *> *)numbersFromString:(NSString *)text;
- (BOOL)extractRectFromString:(NSString *)rectStr x:(CGFloat *)x y:(CGFloat *)y w:(CGFloat *)w h:(CGFloat *)h;
- (NSString *)sanitizeA11yString:(NSString *)text;
- (NSString *)accessibilityTreeStringFromElements:(NSArray<NSDictionary *> *)elements;
@end

static void DaemonSocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);
static CGFloat ClampValue(CGFloat value, CGFloat minValue, CGFloat maxValue);
static NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";

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

static NSString *KimiRunPrefString(NSString *key) {
    if (!key || key.length == 0) {
        return nil;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs stringForKey:key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *KimiRunDefaultTouchMethod(void) {
    const char *env = getenv("KIMIRUN_TOUCH_METHOD");
    if (env && env[0] != '\0') {
        return [NSString stringWithUTF8String:env];
    }
    NSString *prefMethod = KimiRunPrefString(@"TouchMethod");
    if ([prefMethod isKindOfClass:[NSString class]] && prefMethod.length > 0) {
        return prefMethod;
    }
    // Default to AX for stable real-world operation.
    return @"ax";
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

static BOOL KimiRunTouchProxyEnabled(void) {
    if (KimiRunEnvBool("KIMIRUN_TOUCH_PROXY", NO)) {
        return YES;
    }
    if (KimiRunEnvBool("KIMIRUN_NONAX_VIA_SPRINGBOARD", NO)) {
        return YES;
    }
    return KimiRunPrefBool(@"TouchProxy", NO);
}

static BOOL KimiRunIsStrictExplicitTouchMethod(NSString *method) {
    if (![method isKindOfClass:[NSString class]] || method.length == 0) {
        return NO;
    }
    NSString *lower = [[method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) {
        return NO;
    }
    return ([lower isEqualToString:@"sim"] ||
            [lower isEqualToString:@"iohid"] ||
            [lower isEqualToString:@"direct"] ||
            [lower isEqualToString:@"legacy"] ||
            [lower isEqualToString:@"old"] ||
            [lower isEqualToString:@"conn"] ||
            [lower isEqualToString:@"connection"] ||
            [lower isEqualToString:@"bks"] ||
            [lower isEqualToString:@"zx"] ||
            [lower isEqualToString:@"zxtouch"]);
}

static BOOL KimiRunShouldForceProxyMethod(NSString *method) {
    if (![method isKindOfClass:[NSString class]] || method.length == 0) {
        return NO;
    }
    NSString *lower = [[method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) {
        return NO;
    }
    if ([lower isEqualToString:@"zx"] || [lower isEqualToString:@"zxtouch"]) {
        return KimiRunEnvBool("KIMIRUN_FORCE_STRICT_PROXY_ZX",
                              KimiRunPrefBool(@"ForceStrictProxyZX", NO));
    }
    if ([lower isEqualToString:@"bks"]) {
        return KimiRunEnvBool("KIMIRUN_FORCE_STRICT_PROXY_BKS",
                              KimiRunPrefBool(@"ForceStrictProxyBKS", NO));
    }
    return NO;
}

static NSString *KimiRunLowerTrimmedString(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        return nil;
    }
    NSString *lower = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return lower.length > 0 ? lower : nil;
}

static NSString *KimiRunCanonicalTouchMethod(NSString *method) {
    NSString *lower = KimiRunLowerTrimmedString(method);
    if (!lower) {
        return nil;
    }
    if ([lower isEqualToString:@"iohid"]) return @"sim";
    if ([lower isEqualToString:@"old"]) return @"legacy";
    if ([lower isEqualToString:@"connection"]) return @"conn";
    if ([lower isEqualToString:@"zx"]) return @"zxtouch";
    if ([lower isEqualToString:@"a11y"]) return @"ax";
    return lower;
}

static NSString *KimiRunUnsupportedTouchMethodMessage(NSString *method) {
    NSString *canonical = KimiRunCanonicalTouchMethod(method);
    if (!canonical.length) {
        return nil;
    }
    if (KimiRunIsStrictExplicitTouchMethod(canonical) &&
        !KimiRunEnvBool("KIMIRUN_ENABLE_STRICT_NON_AX",
                        KimiRunPrefBool(@"EnableStrictNonAX", NO)) &&
        !KimiRunEnvBool("KIMIRUN_NONAX_VIA_SPRINGBOARD", NO)) {
        return @"Strict non-AX methods are disabled by default (set EnableStrictNonAX=true or KIMIRUN_NONAX_VIA_SPRINGBOARD=1 to opt in)";
    }
    if ([canonical isEqualToString:@"zxtouch"]) {
        BOOL enabled = KimiRunEnvBool("KIMIRUN_ENABLE_ZXTOUCH",
                                      KimiRunPrefBool(@"EnableZXTouch", NO));
        if (!enabled) {
            return @"ZXTouch disabled for safety on this build (set EnableZXTouch=true or KIMIRUN_ENABLE_ZXTOUCH=1 to opt in)";
        }
    }
    return nil;
}

static BOOL KimiRunProxyAllStrictMethodsEnabled(void) {
    if (KimiRunEnvBool("KIMIRUN_TOUCH_PROXY_ALL_STRICT", NO)) {
        return YES;
    }
    if (KimiRunEnvBool("KIMIRUN_NONAX_VIA_SPRINGBOARD", NO)) {
        return YES;
    }
    return KimiRunPrefBool(@"TouchProxyAllStrict", NO);
}

static BOOL KimiRunUIDeltaGateStrictLocalEnabled(void) {
    return KimiRunEnvBool("KIMIRUN_STRICT_LOCAL_UIDELTA",
                          KimiRunPrefBool(@"StrictLocalUIDelta", YES));
}

static BOOL KimiRunShouldUseStrictProxyOnly(NSString *method) {
    if (KimiRunShouldForceProxyMethod(method)) {
        return YES;
    }
    if (!KimiRunIsStrictExplicitTouchMethod(method)) {
        return NO;
    }
    return KimiRunTouchProxyEnabled() && KimiRunProxyAllStrictMethodsEnabled();
}

static BOOL KimiRunShouldGateLocalStrictMethodWithUIDelta(NSString *method) {
    if (!KimiRunUIDeltaGateStrictLocalEnabled()) {
        return NO;
    }
    NSString *canonical = KimiRunCanonicalTouchMethod(method);
    if (canonical.length == 0) {
        return NO;
    }
    return ([canonical isEqualToString:@"bks"] ||
            [canonical isEqualToString:@"direct"] ||
            [canonical isEqualToString:@"zxtouch"]);
}

static NSDictionary *KimiRunMergeFields(NSDictionary *baseFields, NSDictionary *extraFields) {
    BOOL hasBase = [baseFields isKindOfClass:[NSDictionary class]] && baseFields.count > 0;
    BOOL hasExtra = [extraFields isKindOfClass:[NSDictionary class]] && extraFields.count > 0;
    if (!hasBase && !hasExtra) {
        return @{};
    }
    if (!hasBase) {
        return [extraFields copy];
    }
    if (!hasExtra) {
        return [baseFields copy];
    }
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:baseFields];
    [merged addEntriesFromDictionary:extraFields];
    return merged;
}

static uint64_t KimiRunParseSenderIDValue(id rawValue) {
    if ([rawValue respondsToSelector:@selector(unsignedLongLongValue)]) {
        return [rawValue unsignedLongLongValue];
    }
    if ([rawValue isKindOfClass:[NSString class]]) {
        const char *utf8 = [(NSString *)rawValue UTF8String];
        if (utf8 && utf8[0] != '\0') {
            return strtoull(utf8, NULL, 0);
        }
    }
    return 0;
}

static NSString *KimiRunTouchLogPath(void) {
    return @"/var/mobile/Library/Preferences/kimirun_touch.log";
}

static NSTimeInterval KimiRunBKSDispatchTimestampFromInfo(NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]]) {
        return 0;
    }
    NSNumber *timestamp = info[@"timestamp"];
    if ([timestamp respondsToSelector:@selector(doubleValue)]) {
        return [timestamp doubleValue];
    }
    return 0;
}

static NSTimeInterval KimiRunCurrentBKSDispatchTimestamp(void) {
    return KimiRunBKSDispatchTimestampFromInfo([KimiRunTouchInjection lastBKSDispatchInfo]);
}

static NSDictionary *KimiRunBKSDispatchInfoForMethod(NSString *method, NSTimeInterval baselineTimestamp) {
    NSString *canonical = KimiRunCanonicalTouchMethod(method);
    if (![canonical isEqualToString:@"bks"] && ![canonical isEqualToString:@"zxtouch"]) {
        return nil;
    }
    NSDictionary *info = [KimiRunTouchInjection lastBKSDispatchInfo];
    if (![info isKindOfClass:[NSDictionary class]] || info.count == 0) {
        return nil;
    }
    NSTimeInterval timestamp = KimiRunBKSDispatchTimestampFromInfo(info);
    if (timestamp > 0) {
        NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - timestamp;
        if (age < 0 || age > 5.0) {
            return nil;
        }
        if (baselineTimestamp > 0 && timestamp <= (baselineTimestamp + 0.000001)) {
            return nil;
        }
    }
    return info;
}

static NSArray<NSDictionary *> *KimiRunBKSDispatchHistoryForMethod(NSString *method,
                                                                   NSTimeInterval baselineTimestamp,
                                                                   NSUInteger maxItems) {
    NSString *canonical = KimiRunCanonicalTouchMethod(method);
    if (![canonical isEqualToString:@"bks"] && ![canonical isEqualToString:@"zxtouch"]) {
        return @[];
    }
    NSArray<NSDictionary *> *history = [KimiRunTouchInjection recentBKSDispatchHistory:maxItems];
    if (![history isKindOfClass:[NSArray class]] || history.count == 0) {
        return @[];
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray arrayWithCapacity:history.count];
    for (id item in history) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *info = (NSDictionary *)item;
        NSTimeInterval timestamp = KimiRunBKSDispatchTimestampFromInfo(info);
        if (timestamp > 0) {
            NSTimeInterval age = now - timestamp;
            if (age < 0 || age > 5.0) {
                continue;
            }
            if (baselineTimestamp > 0 && timestamp <= (baselineTimestamp + 0.000001)) {
                continue;
            }
        }
        NSMutableDictionary *compact = [NSMutableDictionary dictionary];
        if (timestamp > 0) {
            compact[@"timestamp"] = @(timestamp);
        }
        id ok = info[@"ok"];
        if (ok) {
            compact[@"ok"] = ok;
        }
        id reason = info[@"reason"];
        if ([reason isKindOfClass:[NSString class]] && [reason length] > 0) {
            compact[@"reason"] = reason;
        }
        id chosenSource = info[@"chosenSource"];
        if ([chosenSource isKindOfClass:[NSString class]] && [chosenSource length] > 0) {
            compact[@"source"] = chosenSource;
        }
        id chosenDestination = info[@"chosenDestination"];
        if (chosenDestination) {
            compact[@"destination"] = chosenDestination;
        }
        id chosenTargetClass = info[@"chosenTargetClass"];
        if ([chosenTargetClass isKindOfClass:[NSString class]] && [chosenTargetClass length] > 0) {
            compact[@"targetClass"] = chosenTargetClass;
        }
        id chosenPID = info[@"chosenPID"];
        if (chosenPID) {
            compact[@"pid"] = chosenPID;
        }
        id acceptedDispatches = info[@"acceptedDispatches"];
        if (acceptedDispatches) {
            compact[@"acceptedDispatches"] = acceptedDispatches;
        }
        id candidateCount = info[@"candidateCount"];
        if (candidateCount) {
            compact[@"candidateCount"] = candidateCount;
        }
        [filtered addObject:compact];
    }
    return filtered;
}

static NSString *KimiRunTouchActionJSON(NSString *action,
                                        NSString *method,
                                        BOOL success,
                                        NSDictionary *fields,
                                        NSString *message,
                                        NSTimeInterval bksBaselineTimestamp) {
    NSMutableDictionary *obj = [NSMutableDictionary dictionary];
    obj[@"status"] = success ? @"ok" : @"error";
    if ([action isKindOfClass:[NSString class]] && action.length > 0) {
        obj[@"action"] = action;
    }

    NSString *canonical = KimiRunCanonicalTouchMethod(method);
    obj[@"mode"] = canonical ?: @"auto";

    if ([message isKindOfClass:[NSString class]] && message.length > 0) {
        obj[@"message"] = message;
    }

    if ([fields isKindOfClass:[NSDictionary class]] && fields.count > 0) {
        [obj addEntriesFromDictionary:fields];
    }

    NSDictionary *bksInfo = KimiRunBKSDispatchInfoForMethod(method, bksBaselineTimestamp);
    if (bksInfo.count > 0) {
        obj[@"bksDispatch"] = bksInfo;
        id chosenDestination = bksInfo[@"chosenDestination"];
        id chosenTargetClass = bksInfo[@"chosenTargetClass"];
        id chosenPID = bksInfo[@"chosenPID"];
        id chosenSource = bksInfo[@"chosenSource"];
        id acceptedDispatches = bksInfo[@"acceptedDispatches"];
        id candidateCount = bksInfo[@"candidateCount"];
        id senderIDHex = bksInfo[@"senderIDHex"];
        id senderIDSource = bksInfo[@"senderIDSource"];
        id senderIDCaptured = bksInfo[@"senderIDCaptured"];
        id senderIDCallbackCount = bksInfo[@"senderIDCallbackCount"];
        id senderIDDigitizerCount = bksInfo[@"senderIDDigitizerCount"];
        id senderIDLastEventType = bksInfo[@"senderIDLastEventType"];
        id senderIDMainRegistered = bksInfo[@"senderIDMainRegistered"];
        id senderIDDispatchRegistered = bksInfo[@"senderIDDispatchRegistered"];
        id senderIDCaptureThreadRunning = bksInfo[@"senderIDCaptureThreadRunning"];
        id hidConnectionHex = bksInfo[@"hidConnectionHex"];
        id hidConnectionPtr = bksInfo[@"hidConnectionPtr"];
        if (chosenDestination) {
            obj[@"bksDestination"] = chosenDestination;
        }
        if ([chosenTargetClass isKindOfClass:[NSString class]] && [chosenTargetClass length] > 0) {
            obj[@"bksTargetClass"] = chosenTargetClass;
        }
        if (chosenPID) {
            obj[@"bksPID"] = chosenPID;
        }
        if ([chosenSource isKindOfClass:[NSString class]] && [chosenSource length] > 0) {
            obj[@"bksSource"] = chosenSource;
        }
        if (acceptedDispatches) {
            obj[@"bksAcceptedDispatches"] = acceptedDispatches;
        }
        if (candidateCount) {
            obj[@"bksCandidateCount"] = candidateCount;
        }
        if ([senderIDHex isKindOfClass:[NSString class]] && [senderIDHex length] > 0) {
            obj[@"bksSenderIDHex"] = senderIDHex;
        }
        if ([senderIDSource isKindOfClass:[NSString class]] && [senderIDSource length] > 0) {
            obj[@"bksSenderIDSource"] = senderIDSource;
        }
        if (senderIDCaptured) {
            obj[@"bksSenderIDCaptured"] = senderIDCaptured;
        }
        if (senderIDCallbackCount) {
            obj[@"bksSenderIDCallbackCount"] = senderIDCallbackCount;
        }
        if (senderIDDigitizerCount) {
            obj[@"bksSenderIDDigitizerCount"] = senderIDDigitizerCount;
        }
        if (senderIDLastEventType) {
            obj[@"bksSenderIDLastEventType"] = senderIDLastEventType;
        }
        if (senderIDMainRegistered) {
            obj[@"bksSenderIDMainRegistered"] = senderIDMainRegistered;
        }
        if (senderIDDispatchRegistered) {
            obj[@"bksSenderIDDispatchRegistered"] = senderIDDispatchRegistered;
        }
        if (senderIDCaptureThreadRunning) {
            obj[@"bksSenderIDCaptureThreadRunning"] = senderIDCaptureThreadRunning;
        }
        if ([hidConnectionHex isKindOfClass:[NSString class]] && [hidConnectionHex length] > 0) {
            obj[@"bksHIDConnectionHex"] = hidConnectionHex;
        }
        if (hidConnectionPtr) {
            obj[@"bksHIDConnectionPtr"] = hidConnectionPtr;
        }
    }
    NSArray<NSDictionary *> *bksHistory = KimiRunBKSDispatchHistoryForMethod(method,
                                                                              bksBaselineTimestamp,
                                                                              12);
    if (bksHistory.count > 0) {
        obj[@"bksDispatchHistory"] = bksHistory;
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&jsonError];
    if (data.length > 0 && !jsonError) {
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return success ? @"{\"status\":\"ok\"}" : @"{\"status\":\"error\"}";
}

static NSArray<NSString *> *TailFileLines(NSString *path, NSUInteger maxLines) {
    if (!path || path.length == 0) {
        return @[];
    }
    if (maxLines == 0) {
        maxLines = 200;
    }
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!content || error) {
        return @[];
    }
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (lines.count == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:MIN(maxLines, lines.count)];
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0 && out.count < maxLines; i--) {
        NSString *line = lines[(NSUInteger)i];
        if (line.length == 0) {
            continue;
        }
        [out insertObject:line atIndex:0];
    }
    return out;
}

@implementation DaemonHTTPServer

- (instancetype)init {
    self = [super init];
    if (self) {
        _isRunning = NO;
        _port = 0;
        _socket = NULL;
    }
    return self;
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error {
    if (self.isRunning) {
        return YES;
    }

    self.port = port;

    CFSocketContext context = {0};
    context.info = (__bridge void *)self;

    CFSocketRef socket = CFSocketCreate(
        kCFAllocatorDefault,
        PF_INET,
        SOCK_STREAM,
        IPPROTO_TCP,
        kCFSocketAcceptCallBack,
        DaemonSocketCallback,
        &context
    );

    if (!socket) {
        if (error) {
            *error = [NSError errorWithDomain:@"KimiRunDaemonHTTP" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        }
        return NO;
    }

    int yes = 1;
    setsockopt(CFSocketGetNative(socket), SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    NSData *addressData = [NSData dataWithBytes:&addr length:sizeof(addr)];

    if (CFSocketSetAddress(socket, (__bridge CFDataRef)addressData) != kCFSocketSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"KimiRunDaemonHTTP" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind port"}];
        }
        CFRelease(socket);
        return NO;
    }

    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);

    self.socket = socket;
    self.isRunning = YES;
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    if (self.socket) {
        CFSocketInvalidate(self.socket);
        CFRelease(self.socket);
        self.socket = NULL;
    }
    self.isRunning = NO;
    self.port = 0;
}

- (void)handleConnection:(CFSocketNativeHandle)nativeSocket {
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocket, &readStream, &writeStream);
    if (!readStream || !writeStream) {
        close(nativeSocket);
        return;
    }

    CFReadStreamOpen(readStream);
    CFWriteStreamOpen(writeStream);

    UInt8 buffer[HTTP_BUFFER_SIZE];
    NSMutableData *requestData = [NSMutableData data];
    BOOL headerComplete = NO;
    NSInteger contentLength = 0;
    NSUInteger headerEndIndex = 0;

    while (!headerComplete) {
        if (CFReadStreamHasBytesAvailable(readStream)) {
            CFIndex bytesRead = CFReadStreamRead(readStream, buffer, HTTP_BUFFER_SIZE - 1);
            if (bytesRead > 0) {
                [requestData appendBytes:buffer length:bytesRead];
                NSString *tempString = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
                if ([tempString rangeOfString:@"\r\n\r\n"].location != NSNotFound) {
                    headerComplete = YES;
                    NSRange headerRange = [tempString rangeOfString:@"\r\n\r\n"];
                    headerEndIndex = headerRange.location + headerRange.length;
                    contentLength = [self contentLengthFromHeaderString:tempString];
                }
            } else {
                break;
            }
        } else {
            usleep(1000);
        }
    }

    if (headerComplete && contentLength > 0) {
        while ((NSInteger)requestData.length < (NSInteger)headerEndIndex + contentLength) {
            if (CFReadStreamHasBytesAvailable(readStream)) {
                CFIndex bytesRead = CFReadStreamRead(readStream, buffer, HTTP_BUFFER_SIZE - 1);
                if (bytesRead > 0) {
                    [requestData appendBytes:buffer length:bytesRead];
                } else {
                    break;
                }
            } else {
                usleep(1000);
            }
        }
    }

    NSString *requestString = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding] ?: @"";
    id response = [self responseForRequest:requestString];

    NSData *responseData = nil;
    if ([response isKindOfClass:[NSData class]]) {
        responseData = (NSData *)response;
    } else if ([response isKindOfClass:[NSString class]]) {
        responseData = [(NSString *)response dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        responseData = [@"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n"
                        dataUsingEncoding:NSUTF8StringEncoding];
    }
    const UInt8 *bytes = responseData.bytes;
    CFIndex totalLength = responseData.length;
    CFIndex bytesWritten = 0;
    while (bytesWritten < totalLength) {
        CFIndex result = CFWriteStreamWrite(writeStream, bytes + bytesWritten, totalLength - bytesWritten);
        if (result <= 0) break;
        bytesWritten += result;
    }

    CFReadStreamClose(readStream);
    CFWriteStreamClose(writeStream);
    CFRelease(readStream);
    CFRelease(writeStream);
    close(nativeSocket);
}

- (id)responseForRequest:(NSString *)request {
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.count > 0 ? lines[0] : @"";
    NSArray *parts = [requestLine componentsSeparatedByString:@" "];
    NSString *path = parts.count >= 2 ? parts[1] : @"/";

    NSString *routePath = path;
    NSRange queryRange = [path rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        routePath = [path substringToIndex:queryRange.location];
    }

    NSString *body = nil;
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location != NSNotFound) {
        body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    }

    if ([path isEqualToString:@"/ping"]) {
        NSString *json = @"{\"status\":\"ok\",\"message\":\"pong\"}";
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/state"]) {
        UIDevice *device = [UIDevice currentDevice];
        struct utsname systemInfo;
        uname(&systemInfo);

        NSString *deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
        NSString *systemName = device.systemName;
        NSString *systemVersion = device.systemVersion;
        NSString *deviceName = device.name;
        CGRect screenBounds = [UIScreen mainScreen].bounds;

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
        NSString *json = error ? @"{\"status\":\"error\"}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/screen"]) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        CGFloat scale = [UIScreen mainScreen].scale;
        NSString *json = [NSString stringWithFormat:
                          @"{\"success\":true,\"data\":{\"width\":%.0f,\"height\":%.0f,\"scale\":%.2f}}",
                          bounds.size.width, bounds.size.height, scale];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/vision/a11y"]) {
        __block NSArray *elements = nil;
        if ([NSThread isMainThread]) {
            elements = [AccessibilityTree getInteractiveElements];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                elements = [AccessibilityTree getInteractiveElements];
            });
        }

        if (!elements || elements.count == 0) {
            NSArray *proxyElements = [self fetchSpringBoardInteractiveElements];
            if (proxyElements.count > 0) {
                elements = proxyElements;
            }
        }

        NSString *treeString = [self accessibilityTreeStringFromElements:(elements ?: @[])];
        NSDictionary *payload = @{
            @"accessibilityTree": treeString ?: @""
        };
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        NSString *json = error ? @"{\"accessibilityTree\":\"\"}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/vision/state"]) {
        NSString *activity = @"Unknown";
        BOOL keyboardShown = NO;
        NSDictionary *payload = @{
            @"activity": activity,
            @"keyboardShown": @(keyboardShown)
        };
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        NSString *json = error ? @"{\"activity\":\"Unknown\",\"keyboardShown\":false}" :
                         [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/vision/debug"]) {
        __block NSDictionary *daemonInfo = nil;
        if ([NSThread isMainThread]) {
            daemonInfo = [AccessibilityTree debugInfo];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                daemonInfo = [AccessibilityTree debugInfo];
            });
        }

        NSDictionary *proxyInfo = [self fetchSpringBoardDebugInfo];
        NSDictionary *payload = @{
            @"daemon": daemonInfo ?: @{},
            @"springboard": proxyInfo ?: @{},
            @"springboardPort": @(kSpringBoardProxyPort)
        };
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        NSString *json = error ? @"{}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/debug/classes"]) {
        return [self handleClassDumpRequest:path];
    }

    if ([routePath isEqualToString:@"/debug/class_methods"]) {
        return [self handleClassMethodsRequest:path];
    }

    if ([routePath isEqualToString:@"/vision/screenshot"]) {
        NSData *png = [self fetchSpringBoardScreenshotData];
        if (!png) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Failed to capture screenshot\"}";
            return [self jsonResponse:500 body:json];
        }
        return [self binaryResponse:200 contentType:@"image/png" body:png];
    }

    if ([routePath isEqualToString:@"/touch/senderid"]) {
        return [self handleSenderIDRequestAllowProxy:YES];
    }

    if ([routePath isEqualToString:@"/touch/senderid/local"]) {
        return [self handleSenderIDRequestAllowProxy:NO];
    }

    if ([routePath isEqualToString:@"/touch/senderid/set"]) {
        return [self handleSenderIDSetRequest:body query:path];
    }

    if ([routePath isEqualToString:@"/touch/forcefocus"]) {
        return [self handleForceFocusRequest];
    }

    if ([routePath isEqualToString:@"/touch/bkhid_selectors"]) {
        return [self handleBKHIDSelectorsRequestAllowProxy:YES];
    }

    if ([routePath isEqualToString:@"/touch/bkhid_selectors/local"]) {
        return [self handleBKHIDSelectorsRequestAllowProxy:NO];
    }

    if ([routePath isEqualToString:@"/touch/ax/enable"]) {
        return [self handleAXEnableRequest:path];
    }

    if ([routePath isEqualToString:@"/touch/ax/status"]) {
        return [self handleAXStatusRequest];
    }

    if ([routePath isEqualToString:@"/gestures/tap"]) {
        NSDictionary *jsonBody = [self parseJSONBody:body];
        NSString *rectStr = nil;
        NSNumber *countNum = nil;
        NSNumber *longPressNum = nil;
        NSString *method = nil;
        if ([jsonBody isKindOfClass:[NSDictionary class]]) {
            rectStr = [jsonBody[@"rect"] isKindOfClass:[NSString class]] ? jsonBody[@"rect"] : nil;
            countNum = [jsonBody[@"count"] isKindOfClass:[NSNumber class]] ? jsonBody[@"count"] : nil;
            longPressNum = [jsonBody[@"longPress"] isKindOfClass:[NSNumber class]] ? jsonBody[@"longPress"] : nil;
            method = [jsonBody[@"method"] isKindOfClass:[NSString class]] ? jsonBody[@"method"] : nil;
        }

        CGFloat x = 0, y = 0, w = 0, h = 0;
        if (![self extractRectFromString:rectStr x:&x y:&y w:&w h:&h]) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing rect\"}";
            return [self jsonResponse:400 body:json];
        }

        CGFloat cx = x + (w / 2.0);
        CGFloat cy = y + (h / 2.0);
        NSInteger count = countNum ? [countNum integerValue] : 1;
        BOOL longPress = longPressNum ? [longPressNum boolValue] : NO;
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"tap",
                                                    method,
                                                    NO,
                                                    @{@"x": @(cx), @"y": @(cy)},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        NSDictionary *senderSyncFields = [self syncSenderIDFromSpringBoardProxyForStrictMethod:method];
        NSDictionary *tapFields = KimiRunMergeFields(@{@"x": @(cx), @"y": @(cy)}, senderSyncFields);
        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            if (longPress) {
                success = [KimiRunTouchInjection longPressAtX:cx Y:cy duration:0.8 method:method];
            } else if (count >= 2) {
                success = [KimiRunTouchInjection doubleTapAtX:cx Y:cy method:method];
            } else {
                success = [KimiRunTouchInjection tapAtX:cx Y:cy method:method];
            }
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (longPress) {
                    success = [KimiRunTouchInjection longPressAtX:cx Y:cy duration:0.8 method:method];
                } else if (count >= 2) {
                    success = [KimiRunTouchInjection doubleTapAtX:cx Y:cy method:method];
                } else {
                    success = [KimiRunTouchInjection tapAtX:cx Y:cy method:method];
                }
            });
        }

        if (success && gateLocalUIDelta &&
            ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
            success = NO;
        }

        if (!success && gateLocalUIDelta) {
            NSString *json = KimiRunTouchActionJSON(@"tap",
                                                    method,
                                                    NO,
                                                    tapFields,
                                                    @"Strict method failed verification: no UI delta observed",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"tap",
                                                    method,
                                                    NO,
                                                    tapFields,
                                                    @"Failed to execute tap",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"tap",
                                                method,
                                                YES,
                                                tapFields,
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/gestures/swipe"]) {
        NSDictionary *jsonBody = [self parseJSONBody:body];
        NSNumber *xNum = nil;
        NSNumber *yNum = nil;
        NSString *dir = nil;
        NSString *method = nil;
        if ([jsonBody isKindOfClass:[NSDictionary class]]) {
            if ([jsonBody[@"x"] isKindOfClass:[NSNumber class]]) xNum = jsonBody[@"x"];
            if ([jsonBody[@"y"] isKindOfClass:[NSNumber class]]) yNum = jsonBody[@"y"];
            if ([jsonBody[@"dir"] isKindOfClass:[NSString class]]) dir = jsonBody[@"dir"];
            if ([jsonBody[@"method"] isKindOfClass:[NSString class]]) method = jsonBody[@"method"];
        }

        if (!xNum || !yNum || !dir) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing x,y,dir\"}";
            return [self jsonResponse:400 body:json];
        }

        CGFloat x = [xNum floatValue];
        CGFloat y = [yNum floatValue];
        CGRect bounds = [UIScreen mainScreen].bounds;
        CGFloat distance = MIN(300.0, bounds.size.height * 0.35);
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        NSDictionary *senderSyncFields = [self syncSenderIDFromSpringBoardProxyForStrictMethod:method];
        NSDictionary *swipeFieldsSuccess = KimiRunMergeFields(@{@"success": @YES}, senderSyncFields);
        NSDictionary *swipeFieldsFailure = KimiRunMergeFields(@{@"success": @NO}, senderSyncFields);

        CGFloat x2 = x;
        CGFloat y2 = y;
        NSString *lower = [dir lowercaseString];
        if ([lower isEqualToString:@"up"]) {
            y2 = y - distance;
        } else if ([lower isEqualToString:@"down"]) {
            y2 = y + distance;
        } else if ([lower isEqualToString:@"left"]) {
            x2 = x - distance;
        } else if ([lower isEqualToString:@"right"]) {
            x2 = x + distance;
        }

        x2 = ClampValue(x2, 1, bounds.size.width - 1);
        y2 = ClampValue(y2, 1, bounds.size.height - 1);
        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection swipeFromX:x Y:y toX:x2 Y:y2 duration:0.3 method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection swipeFromX:x Y:y toX:x2 Y:y2 duration:0.3 method:method];
            });
        }

        if (success && gateLocalUIDelta &&
            ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
            success = NO;
        }

        if (!success && gateLocalUIDelta) {
            NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                    method,
                                                    NO,
                                                    swipeFieldsFailure,
                                                    @"Strict method failed verification: no UI delta observed",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                    method,
                                                    NO,
                                                    swipeFieldsFailure,
                                                    @"Failed to execute swipe",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                method,
                                                YES,
                                                swipeFieldsSuccess,
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/inputs/type"]) {
        NSDictionary *jsonBody = [self parseJSONBody:body];
        NSString *text = nil;
        if ([jsonBody isKindOfClass:[NSDictionary class]] &&
            [jsonBody[@"text"] isKindOfClass:[NSString class]]) {
            text = jsonBody[@"text"];
        }
        if (!text || text.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing text\"}";
            return [self jsonResponse:400 body:json];
        }

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection typeText:text];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection typeText:text];
            });
        }

        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"action\":\"type\",\"success\":%s}",
                          success ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/inputs/key"]) {
        NSDictionary *jsonBody = [self parseJSONBody:body];
        NSNumber *keyNum = nil;
        if ([jsonBody isKindOfClass:[NSDictionary class]] &&
            [jsonBody[@"key"] isKindOfClass:[NSNumber class]]) {
            keyNum = jsonBody[@"key"];
        }
        if (!keyNum) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing key\"}";
            return [self jsonResponse:400 body:json];
        }

        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"action\":\"key\",\"key\":%ld,\"success\":false}",
                          (long)[keyNum integerValue]];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/inputs/launch"]) {
        NSDictionary *jsonBody = [self parseJSONBody:body];
        NSString *bundleID = nil;
        if ([jsonBody isKindOfClass:[NSDictionary class]] &&
            [jsonBody[@"bundleIdentifier"] isKindOfClass:[NSString class]]) {
            bundleID = jsonBody[@"bundleIdentifier"];
        }
        if (!bundleID || bundleID.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing bundleIdentifier\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL ok = [AppLauncher launchAppWithBundleID:bundleID];
        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"bundleID\":\"%@\",\"launched\":%s}",
                          bundleID, ok ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/nonax/diagnostics"]) {
        NSURL *sbURL = [NSURL URLWithString:@"http://127.0.0.1:8765/touch/diagnostics"];
        NSData *sbData = [self fetchURL:sbURL timeout:1.0];
        NSDictionary *sbDiag = nil;
        if (sbData.length > 0) {
            NSError *err = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:sbData options:0 error:&err];
            if (!err && [obj isKindOfClass:[NSDictionary class]]) {
                sbDiag = (NSDictionary *)obj;
            }
        }

        NSDictionary *localDiag = [KimiRunTouchInjection hidDiagnostics];
        BOOL proxyEnabled = KimiRunTouchProxyEnabled();
        BOOL proxyAllStrict = KimiRunProxyAllStrictMethodsEnabled();
        BOOL enableStrictNonAX = KimiRunEnvBool("KIMIRUN_ENABLE_STRICT_NON_AX",
                                                 KimiRunPrefBool(@"EnableStrictNonAX", NO));
        BOOL nonaxViaSpringBoard = KimiRunEnvBool("KIMIRUN_NONAX_VIA_SPRINGBOARD", NO);

        BOOL sbReachable = (sbDiag != nil);
        BOOL sbHIDReady = NO;
        if (sbDiag) {
            NSString *hc = sbDiag[@"hidClient"];
            NSString *sc = sbDiag[@"simClient"];
            sbHIDReady = (hc && ![hc isEqualToString:@"0x0"]) ||
                         (sc && ![sc isEqualToString:@"0x0"]);
        }
        BOOL proxyPathViable = sbReachable && sbHIDReady && proxyEnabled && proxyAllStrict;

        NSDictionary *payload = @{
            @"status": @"ok",
            @"springboard": sbDiag ?: @{@"error": @"unreachable"},
            @"daemon": localDiag ?: @{},
            @"proxyConfig": @{
                @"touchProxyEnabled": @(proxyEnabled),
                @"touchProxyAllStrict": @(proxyAllStrict),
                @"enableStrictNonAX": @(enableStrictNonAX),
                @"nonaxViaSpringBoard": @(nonaxViaSpringBoard),
            },
            @"viable": @(proxyPathViable),
            @"viableIfEnabled": @(sbReachable && sbHIDReady),
        };

        NSError *err = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:&err];
        if (jsonData.length > 0 && !err) {
            return [self jsonResponse:200 body:[[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]];
        }
        return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Failed to build diagnostics\"}"];
    }

    if ([routePath isEqualToString:@"/tap"]) {
        CGFloat x = [self floatValueFromQuery:path key:@"x"];
        CGFloat y = [self floatValueFromQuery:path key:@"y"];
        NSString *method = [self stringValueFromQuery:path key:@"method"];
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"tap",
                                                    method,
                                                    NO,
                                                    @{@"x": @(x), @"y": @(y)},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL forceProxyMethod = KimiRunShouldForceProxyMethod(method);
        BOOL strictProxyOnly = KimiRunShouldUseStrictProxyOnly(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        if (x <= 0 || y <= 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing or invalid coordinates\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL proxyEnabled = KimiRunTouchProxyEnabled() || forceProxyMethod;
        NSString *strictProxyBody = nil;
        BOOL strictProxyHadResponse = NO;
        if (strictProxyOnly) {
            id strictProxyResponse = [self strictProxyResponseForPath:path
                                                              timeout:0.6
                                                     forceProxyMethod:forceProxyMethod
                                                verifyUIDeltaOnSuccess:strictMethod
                                                       strictProxyBodyOut:&strictProxyBody
                                                strictProxyHadResponseOut:&strictProxyHadResponse];
            if (strictProxyResponse) {
                return strictProxyResponse;
            }
        }
        BOOL preferProxy = proxyEnabled && !strictMethod;
        if (preferProxy) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.6];
            if (proxyResponse) {
                return proxyResponse;
            }
        }

        NSDictionary *senderSyncFields = [self syncSenderIDFromSpringBoardProxyForStrictMethod:method];
        NSDictionary *tapFields = KimiRunMergeFields(@{@"x": @(x), @"y": @(y)}, senderSyncFields);
        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection tapAtX:x Y:y method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection tapAtX:x Y:y method:method];
            });
        }

        if (success) {
            if (gateLocalUIDelta &&
                ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
                NSString *json = KimiRunTouchActionJSON(@"tap",
                                                        method,
                                                        NO,
                                                        tapFields,
                                                        @"Strict method failed verification: no UI delta observed",
                                                        bksBaselineTimestamp);
                return [self jsonResponse:500 body:json];
            }
            NSString *json = KimiRunTouchActionJSON(@"tap",
                                                    method,
                                                    YES,
                                                    tapFields,
                                                    nil,
                                                    bksBaselineTimestamp);
            return [self jsonResponse:200 body:json];
        }

        if (!strictMethod) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.6];
            if (proxyResponse) {
                return proxyResponse;
            }
        }
        if (strictMethod && strictProxyHadResponse) {
            return [self jsonResponse:500 body:strictProxyBody];
        }
        NSString *json = KimiRunTouchActionJSON(@"tap",
                                                method,
                                                NO,
                                                tapFields,
                                                @"Tap failed",
                                                bksBaselineTimestamp);
        return [self jsonResponse:500 body:json];
    }

    if ([routePath isEqualToString:@"/swipe"]) {
        CGFloat x1 = [self floatValueFromQuery:path key:@"x1"];
        CGFloat y1 = [self floatValueFromQuery:path key:@"y1"];
        CGFloat x2 = [self floatValueFromQuery:path key:@"x2"];
        CGFloat y2 = [self floatValueFromQuery:path key:@"y2"];
        CGFloat duration = [self floatValueFromQuery:path key:@"duration"];
        NSString *method = [self stringValueFromQuery:path key:@"method"];
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL forceProxyMethod = KimiRunShouldForceProxyMethod(method);
        BOOL strictProxyOnly = KimiRunShouldUseStrictProxyOnly(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        if (duration <= 0) duration = 0.35;

        if (x1 <= 0 || y1 <= 0 || x2 <= 0 || y2 <= 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing or invalid coordinates\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL proxyEnabled = KimiRunTouchProxyEnabled() || forceProxyMethod;
        NSString *strictProxyBody = nil;
        BOOL strictProxyHadResponse = NO;
        if (strictProxyOnly) {
            id strictProxyResponse = [self strictProxyResponseForPath:path
                                                              timeout:0.8
                                                     forceProxyMethod:forceProxyMethod
                                                verifyUIDeltaOnSuccess:strictMethod
                                                       strictProxyBodyOut:&strictProxyBody
                                                strictProxyHadResponseOut:&strictProxyHadResponse];
            if (strictProxyResponse) {
                return strictProxyResponse;
            }
        }
        BOOL preferProxy = proxyEnabled && !strictMethod;
        if (preferProxy) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.8];
            if (proxyResponse) {
                return proxyResponse;
            }
        }

        NSDictionary *senderSyncFields = [self syncSenderIDFromSpringBoardProxyForStrictMethod:method];
        NSDictionary *swipeFieldsSuccess = KimiRunMergeFields(@{@"success": @YES}, senderSyncFields);
        NSDictionary *swipeFieldsFailure = KimiRunMergeFields(@{@"success": @NO}, senderSyncFields);
        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
            });
        }

        if (success && gateLocalUIDelta &&
            ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
            success = NO;
        }

        if (!success && !strictMethod) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.8];
            if (proxyResponse) {
                return proxyResponse;
            }
        }
        if (!success && strictMethod && strictProxyHadResponse) {
            return [self jsonResponse:500 body:strictProxyBody];
        }

        if (!success && gateLocalUIDelta) {
            NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                    method,
                                                    NO,
                                                    swipeFieldsFailure,
                                                    @"Strict method failed verification: no UI delta observed",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                    method,
                                                    NO,
                                                    swipeFieldsFailure,
                                                    @"Failed to execute swipe",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"swipe",
                                                method,
                                                YES,
                                                swipeFieldsSuccess,
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/scroll"]) {
        NSString *direction = [self stringValueFromQuery:path key:@"direction"];
        CGFloat x = [self floatValueFromQuery:path key:@"x"];
        CGFloat y = [self floatValueFromQuery:path key:@"y"];
        CGFloat distance = [self floatValueFromQuery:path key:@"distance"];
        CGFloat duration = [self floatValueFromQuery:path key:@"duration"];
        NSString *method = [self stringValueFromQuery:path key:@"method"];
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"scroll",
                                                    method,
                                                    NO,
                                                    @{@"direction": direction ?: @"up", @"success": @NO},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        if (duration <= 0) duration = 0.35;

        CGRect bounds = [UIScreen mainScreen].bounds;
        if (x <= 0) x = CGRectGetMidX(bounds);
        if (y <= 0) y = CGRectGetMidY(bounds);
        if (distance <= 0) {
            distance = MIN(bounds.size.width, bounds.size.height) * 0.35;
        }

        NSString *dir = direction ? [direction lowercaseString] : @"up";
        CGFloat x1 = x, y1 = y, x2 = x, y2 = y;
        if ([dir isEqualToString:@"up"]) {
            y1 = y + (distance * 0.5);
            y2 = y - (distance * 0.5);
        } else if ([dir isEqualToString:@"down"]) {
            y1 = y - (distance * 0.5);
            y2 = y + (distance * 0.5);
        } else if ([dir isEqualToString:@"left"]) {
            x1 = x + (distance * 0.5);
            x2 = x - (distance * 0.5);
        } else if ([dir isEqualToString:@"right"]) {
            x1 = x - (distance * 0.5);
            x2 = x + (distance * 0.5);
        } else {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Invalid direction (use up/down/left/right)\"}";
            return [self jsonResponse:400 body:json];
        }

        x1 = ClampValue(x1, 1.0, bounds.size.width - 1.0);
        y1 = ClampValue(y1, 1.0, bounds.size.height - 1.0);
        x2 = ClampValue(x2, 1.0, bounds.size.width - 1.0);
        y2 = ClampValue(y2, 1.0, bounds.size.height - 1.0);

        __block BOOL success = NO;
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
            });
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"scroll",
                                                    method,
                                                    NO,
                                                    @{@"direction": dir, @"success": @NO},
                                                    @"Failed to execute scroll",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"scroll",
                                                method,
                                                YES,
                                                @{@"direction": dir, @"success": @YES},
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/drag"]) {
        CGFloat x1 = [self floatValueFromQuery:path key:@"x1"];
        CGFloat y1 = [self floatValueFromQuery:path key:@"y1"];
        CGFloat x2 = [self floatValueFromQuery:path key:@"x2"];
        CGFloat y2 = [self floatValueFromQuery:path key:@"y2"];
        CGFloat duration = [self floatValueFromQuery:path key:@"duration"];
        NSString *method = [self stringValueFromQuery:path key:@"method"];
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"drag",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL forceProxyMethod = KimiRunShouldForceProxyMethod(method);
        BOOL strictProxyOnly = KimiRunShouldUseStrictProxyOnly(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        if (duration <= 0) duration = 0.8;

        if (x1 <= 0 || y1 <= 0 || x2 <= 0 || y2 <= 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing or invalid coordinates\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL proxyEnabled = KimiRunTouchProxyEnabled() || forceProxyMethod;
        NSString *strictProxyBody = nil;
        BOOL strictProxyHadResponse = NO;
        if (strictProxyOnly) {
            id strictProxyResponse = [self strictProxyResponseForPath:path
                                                              timeout:0.9
                                                     forceProxyMethod:forceProxyMethod
                                                verifyUIDeltaOnSuccess:strictMethod
                                                       strictProxyBodyOut:&strictProxyBody
                                                strictProxyHadResponseOut:&strictProxyHadResponse];
            if (strictProxyResponse) {
                return strictProxyResponse;
            }
        }
        BOOL preferProxy = proxyEnabled && !strictMethod;
        if (preferProxy) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.9];
            if (proxyResponse) {
                return proxyResponse;
            }
        }

        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection dragFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection dragFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:method];
            });
        }

        if (success && gateLocalUIDelta &&
            ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
            success = NO;
        }

        if (!success && !strictMethod) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.9];
            if (proxyResponse) {
                return proxyResponse;
            }
        }
        if (!success && strictMethod && strictProxyHadResponse) {
            return [self jsonResponse:500 body:strictProxyBody];
        }

        if (!success && gateLocalUIDelta) {
            NSString *json = KimiRunTouchActionJSON(@"drag",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    @"Strict method failed verification: no UI delta observed",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"drag",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    @"Failed to execute drag",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"drag",
                                                method,
                                                YES,
                                                @{@"success": @YES},
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/doubletap"]) {
        CGFloat x = [self floatValueFromQuery:path key:@"x"];
        CGFloat y = [self floatValueFromQuery:path key:@"y"];
        NSString *method = [self stringValueFromQuery:path key:@"method"];
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"doubletap",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL forceProxyMethod = KimiRunShouldForceProxyMethod(method);
        BOOL strictProxyOnly = KimiRunShouldUseStrictProxyOnly(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        if (x <= 0 || y <= 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing or invalid coordinates\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL proxyEnabled = KimiRunTouchProxyEnabled() || forceProxyMethod;
        NSString *strictProxyBody = nil;
        BOOL strictProxyHadResponse = NO;
        if (strictProxyOnly) {
            id strictProxyResponse = [self strictProxyResponseForPath:path
                                                              timeout:0.6
                                                     forceProxyMethod:forceProxyMethod
                                                verifyUIDeltaOnSuccess:strictMethod
                                                       strictProxyBodyOut:&strictProxyBody
                                                strictProxyHadResponseOut:&strictProxyHadResponse];
            if (strictProxyResponse) {
                return strictProxyResponse;
            }
        }
        BOOL preferProxy = proxyEnabled && !strictMethod;
        if (preferProxy) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.6];
            if (proxyResponse) {
                return proxyResponse;
            }
        }

        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection doubleTapAtX:x Y:y method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection doubleTapAtX:x Y:y method:method];
            });
        }

        if (success && gateLocalUIDelta &&
            ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
            success = NO;
        }

        if (!success && !strictMethod) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.6];
            if (proxyResponse) {
                return proxyResponse;
            }
        }
        if (!success && strictMethod && strictProxyHadResponse) {
            return [self jsonResponse:500 body:strictProxyBody];
        }

        if (!success && gateLocalUIDelta) {
            NSString *json = KimiRunTouchActionJSON(@"doubletap",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    @"Strict method failed verification: no UI delta observed",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"doubletap",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    @"Failed to execute double tap",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"doubletap",
                                                method,
                                                YES,
                                                @{@"success": @YES},
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/longpress"]) {
        CGFloat x = [self floatValueFromQuery:path key:@"x"];
        CGFloat y = [self floatValueFromQuery:path key:@"y"];
        CGFloat duration = [self floatValueFromQuery:path key:@"duration"];
        NSString *method = [self stringValueFromQuery:path key:@"method"];
        NSString *unsupportedMethodMessage = KimiRunUnsupportedTouchMethodMessage(method);
        if (unsupportedMethodMessage.length > 0) {
            NSString *json = KimiRunTouchActionJSON(@"longpress",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    unsupportedMethodMessage,
                                                    KimiRunCurrentBKSDispatchTimestamp());
            return [self jsonResponse:400 body:json];
        }
        BOOL strictMethod = KimiRunIsStrictExplicitTouchMethod(method);
        BOOL forceProxyMethod = KimiRunShouldForceProxyMethod(method);
        BOOL strictProxyOnly = KimiRunShouldUseStrictProxyOnly(method);
        BOOL gateLocalUIDelta = strictMethod && KimiRunShouldGateLocalStrictMethodWithUIDelta(method);
        if (duration <= 0) duration = 0.8;

        if (x <= 0 || y <= 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing or invalid coordinates\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL proxyEnabled = KimiRunTouchProxyEnabled() || forceProxyMethod;
        NSString *strictProxyBody = nil;
        BOOL strictProxyHadResponse = NO;
        if (strictProxyOnly) {
            id strictProxyResponse = [self strictProxyResponseForPath:path
                                                              timeout:0.8
                                                     forceProxyMethod:forceProxyMethod
                                                verifyUIDeltaOnSuccess:strictMethod
                                                       strictProxyBodyOut:&strictProxyBody
                                                strictProxyHadResponseOut:&strictProxyHadResponse];
            if (strictProxyResponse) {
                return strictProxyResponse;
            }
        }
        BOOL preferProxy = proxyEnabled && !strictMethod;
        if (preferProxy) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.8];
            if (proxyResponse) {
                return proxyResponse;
            }
        }

        NSString *beforeLocalDigest = nil;
        if (gateLocalUIDelta) {
            beforeLocalDigest = [self springBoardScreenshotDigest];
            if (beforeLocalDigest.length == 0) {
                return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
            }
        }
        NSTimeInterval bksBaselineTimestamp = KimiRunCurrentBKSDispatchTimestamp();

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection longPressAtX:x Y:y duration:duration method:method];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection longPressAtX:x Y:y duration:duration method:method];
            });
        }

        if (success && gateLocalUIDelta &&
            ![self verifySpringBoardUIDeltaFromDigest:beforeLocalDigest timeout:1.0]) {
            success = NO;
        }

        if (!success && !strictMethod) {
            id proxyResponse = [self proxyTouchHTTPResponseForPath:path timeout:0.8];
            if (proxyResponse) {
                return proxyResponse;
            }
        }
        if (!success && strictMethod && strictProxyHadResponse) {
            return [self jsonResponse:500 body:strictProxyBody];
        }

        if (!success && gateLocalUIDelta) {
            NSString *json = KimiRunTouchActionJSON(@"longpress",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    @"Strict method failed verification: no UI delta observed",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        if (!success) {
            NSString *json = KimiRunTouchActionJSON(@"longpress",
                                                    method,
                                                    NO,
                                                    @{@"success": @NO},
                                                    @"Failed to execute long press",
                                                    bksBaselineTimestamp);
            return [self jsonResponse:500 body:json];
        }

        NSString *json = KimiRunTouchActionJSON(@"longpress",
                                                method,
                                                YES,
                                                @{@"success": @YES},
                                                nil,
                                                bksBaselineTimestamp);
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/keyboard/type"]) {
        NSString *text = [self stringValueFromQuery:path key:@"text"];
        if (!text || text.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing text\"}";
            return [self jsonResponse:400 body:json];
        }

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection typeText:text];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection typeText:text];
            });
        }

        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"action\":\"type\",\"success\":%s}",
                          success ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/keyboard/key"]) {
        NSString *usageStr = [self stringValueFromQuery:path key:@"usage"];
        NSString *downStr = [self stringValueFromQuery:path key:@"down"];
        if (!usageStr || usageStr.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing usage\"}";
            return [self jsonResponse:400 body:json];
        }

        unsigned long usage = strtoul([usageStr UTF8String], NULL, 0);
        BOOL down = downStr ? ([downStr intValue] != 0) : YES;

        __block BOOL success = NO;
        if ([NSThread isMainThread]) {
            success = [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:down];
            if (!downStr) {
                [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:NO];
            }
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                success = [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:down];
                if (!downStr) {
                    [KimiRunTouchInjection sendKeyUsage:(uint16_t)usage down:NO];
                }
            });
        }

        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"action\":\"key\",\"success\":%s}",
                          success ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/app/launch"]) {
        NSString *bundleID = [self stringValueFromQuery:path key:@"bundleID"];
        if (!bundleID || bundleID.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing bundleID\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL ok = [AppLauncher launchAppWithBundleID:bundleID];
        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"bundleID\":\"%@\",\"launched\":%s}",
                          bundleID, ok ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/app/terminate"]) {
        NSString *bundleID = [self stringValueFromQuery:path key:@"bundleID"];
        if (!bundleID || bundleID.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing bundleID\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL ok = [AppLauncher terminateAppWithBundleID:bundleID];
        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"bundleID\":\"%@\",\"terminated\":%s}",
                          bundleID, ok ? "true" : "false"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/apps"]) {
        BOOL systemApps = [self boolValueFromQuery:path key:@"systemApps" defaultValue:NO];
        if (!systemApps) {
            systemApps = [self boolValueFromQuery:path key:@"system_apps" defaultValue:NO];
        }
        BOOL compact = [self boolValueFromQuery:path key:@"compact" defaultValue:NO];
        NSInteger limit = (NSInteger)[self floatValueFromQuery:path key:@"limit"];

        __block NSArray *apps = nil;
        if ([NSThread isMainThread]) {
            apps = [AppLauncher listApplicationsIncludeSystem:systemApps];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                apps = [AppLauncher listApplicationsIncludeSystem:systemApps];
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
            NSString *json = @"{\"success\":false,\"error\":\"Failed to serialize app list\"}";
            return [self jsonResponse:500 body:json];
        }

        NSString *appsJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        NSString *json = [NSString stringWithFormat:@"{\"success\":true,\"data\":%@}", appsJson ?: @"[]"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/diagnostics"]) {
        NSString *method = KimiRunDefaultTouchMethod() ?: @"auto";
        BOOL disableLockscreen = KimiRunPrefBool(@"DisableLockScreen", NO);
        BOOL preventSleep = KimiRunPrefBool(@"PreventSleep", NO);
        BOOL blockSideButtonSleep = KimiRunPrefBool(@"BlockSideButtonSleep", NO);
        BOOL allowSleep = KimiRunPrefBool(@"AllowSleep", NO);
        NSString *senderID = [NSString stringWithFormat:@"0x%llX", [KimiRunTouchInjection senderID]];

        NSDictionary *payload = @{
            @"success": @YES,
            @"touch": @{
                @"available": @([KimiRunTouchInjection isAvailable]),
                @"senderID": senderID ?: @"0x0",
                @"senderSource": [KimiRunTouchInjection senderIDSourceString] ?: @"",
                @"method": method ?: @"auto"
            },
            @"lockscreen": @{
                @"disableLockscreen": @(disableLockscreen),
                @"preventSleep": @(preventSleep),
                @"blockSideButtonSleep": @(blockSideButtonSleep),
                @"allowSleep": @(allowSleep)
            },
            @"server": @{
                @"port": @(self.port),
                @"running": @(self.isRunning)
            }
        };

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        NSString *json = error ? @"{\"success\":false}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/logs"]) {
        NSInteger tail = (NSInteger)[self floatValueFromQuery:path key:@"tail"];
        if (tail <= 0) tail = 200;
        NSArray<NSString *> *lines = TailFileLines(KimiRunTouchLogPath(), (NSUInteger)tail);
        NSDictionary *payload = @{
            @"success": @YES,
            @"count": @(lines.count),
            @"logs": lines ?: @[]
        };

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        NSString *json = error ? @"{\"success\":false}" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/uiHierarchy"]) {
        NSUInteger resolvedPort = 0;
        NSString *proxyBody = [self proxyTouchResponseForPath:path timeout:1.2 resolvedPortOut:&resolvedPort];
        if (proxyBody.length > 0) {
            return [self jsonResponse:200 body:proxyBody];
        }

        BOOL compact = [self boolValueFromQuery:path key:@"compact" defaultValue:NO];
        BOOL pretty = [self boolValueFromQuery:path key:@"pretty" defaultValue:!compact];

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
        if (error || !jsonData) {
            NSString *json = @"{\"success\":false,\"error\":\"Failed to build UI hierarchy\"}";
            return [self jsonResponse:500 body:json];
        }

        NSString *treeJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        NSString *json = [NSString stringWithFormat:@"{\"success\":true,\"data\":%@}", treeJson ?: @"{}"];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/screenshot/file"]) {
        NSString *format = [self stringValueFromQuery:path key:@"format"];
        NSString *qualityStr = [self stringValueFromQuery:path key:@"quality"];
        __block NSString *lower = format ? [format lowercaseString] : @"png";
        __block NSData *data = nil;

        // Prefer SpringBoard proxy to avoid daemon capture crashes.
        NSData *proxyData = [self fetchSpringBoardScreenshotData];
        if (proxyData.length > 0) {
            if ([lower isEqualToString:@"jpeg"] || [lower isEqualToString:@"jpg"]) {
                __block NSData *jpeg = nil;
                if ([NSThread isMainThread]) {
                    UIImage *img = [UIImage imageWithData:proxyData];
                    CGFloat quality = 0.8;
                    if (qualityStr && qualityStr.length > 0) {
                        quality = (CGFloat)[qualityStr doubleValue];
                    }
                    jpeg = img ? UIImageJPEGRepresentation(img, quality) : nil;
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        UIImage *img = [UIImage imageWithData:proxyData];
                        CGFloat quality = 0.8;
                        if (qualityStr && qualityStr.length > 0) {
                            quality = (CGFloat)[qualityStr doubleValue];
                        }
                        jpeg = img ? UIImageJPEGRepresentation(img, quality) : nil;
                    });
                }
                data = jpeg ?: proxyData;
                lower = @"jpg";
            } else {
                data = proxyData;
                lower = @"png";
            }
        } else {
            // Fallback to local capture if proxy fails.
            if ([NSThread isMainThread]) {
                if ([lower isEqualToString:@"jpeg"] || [lower isEqualToString:@"jpg"]) {
                    CGFloat quality = 0.8;
                    if (qualityStr && qualityStr.length > 0) {
                        quality = (CGFloat)[qualityStr doubleValue];
                    }
                    data = [[KimiRunScreenshot sharedScreenshot] captureScreenAsJPEGWithQuality:quality];
                    lower = @"jpg";
                } else {
                    data = [[KimiRunScreenshot sharedScreenshot] captureScreenAsPNG];
                    lower = @"png";
                }
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    if ([lower isEqualToString:@"jpeg"] || [lower isEqualToString:@"jpg"]) {
                        CGFloat quality = 0.8;
                        if (qualityStr && qualityStr.length > 0) {
                            quality = (CGFloat)[qualityStr doubleValue];
                        }
                        data = [[KimiRunScreenshot sharedScreenshot] captureScreenAsJPEGWithQuality:quality];
                        lower = @"jpg";
                    } else {
                        data = [[KimiRunScreenshot sharedScreenshot] captureScreenAsPNG];
                        lower = @"png";
                    }
                });
            }
        }

        if (!data) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Failed to capture screenshot\"}";
            return [self jsonResponse:500 body:json];
        }

        NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];
        NSString *pathOut = [NSString stringWithFormat:@"/tmp/kimirun_daemon_%.0f.%@", ts, lower];
        BOOL ok = [data writeToFile:pathOut atomically:YES];
        if (!ok) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Failed to write screenshot\"}";
            return [self jsonResponse:500 body:json];
        }

        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"ok\",\"path\":\"%@\",\"bytes\":%lu,\"format\":\"%@\"}",
                          pathOut, (unsigned long)data.length, lower];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/screenshot"]) {
        NSData *data = [self fetchSpringBoardScreenshotData];
        if (!data) {
            __block NSData *fallback = nil;
            if ([NSThread isMainThread]) {
                fallback = [[KimiRunScreenshot sharedScreenshot] captureScreenAsPNG];
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    fallback = [[KimiRunScreenshot sharedScreenshot] captureScreenAsPNG];
                });
            }
            data = fallback;
        }
        if (!data) {
            NSString *json = @"{\"success\":false,\"error\":\"Failed to capture screenshot\"}";
            return [self jsonResponse:500 body:json];
        }
        return [self binaryResponse:200 contentType:@"image/png" body:data];
    }

    if ([routePath isEqualToString:@"/a11y/interactive"]) {
        NSUInteger resolvedPort = 0;
        NSString *proxyBody = [self proxyTouchResponseForPath:path timeout:1.2 resolvedPortOut:&resolvedPort];
        if (proxyBody.length > 0) {
            return [self jsonResponse:200 body:proxyBody];
        }

        BOOL compact = [self boolValueFromQuery:path key:@"compact" defaultValue:NO];
        NSInteger limit = (NSInteger)[self floatValueFromQuery:path key:@"limit"];

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
                                                           options:(compact ? 0 : NSJSONWritingPrettyPrinted)
                                                             error:&error];
        NSString *json = error ? @"[]" : [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self jsonResponse:200 body:json];
    }

    if ([routePath isEqualToString:@"/a11y/activate"]) {
        NSInteger index = (NSInteger)[self floatValueFromQuery:path key:@"index"];
        if (index < 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Invalid index\"}";
            return [self jsonResponse:400 body:json];
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

    if ([routePath isEqualToString:@"/a11y/overlay"]) {
        NSString *enabledStr = [self stringValueFromQuery:path key:@"enabled"];
        NSString *interactiveStr = [self stringValueFromQuery:path key:@"interactiveOnly"];
        if (!enabledStr || enabledStr.length == 0) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Missing enabled parameter\"}";
            return [self jsonResponse:400 body:json];
        }

        BOOL enabled = [self boolValueFromQuery:path key:@"enabled" defaultValue:NO];
        BOOL interactiveOnly = interactiveStr ? [self boolValueFromQuery:path key:@"interactiveOnly" defaultValue:YES] : YES;

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

    NSString *json = @"{\"status\":\"error\",\"message\":\"Not Found\"}";
    return [self jsonResponse:404 body:json];
}

- (NSDictionary *)syncSenderIDFromSpringBoardProxyForStrictMethod:(NSString *)method {
    NSString *canonical = KimiRunCanonicalTouchMethod(method);
    if (![canonical isEqualToString:@"bks"] && ![canonical isEqualToString:@"zxtouch"]) {
        return @{};
    }
    if (!KimiRunIsStrictExplicitTouchMethod(method)) {
        return @{};
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"senderSyncAttempted"] = @YES;

    NSArray<NSString *> *candidatePaths = @[ @"/touch/senderid/local", @"/touch/senderid" ];
    NSDictionary *senderInfo = nil;
    NSString *usedPath = nil;
    uint64_t senderID = 0;
    NSInteger senderScore = NSIntegerMin;

    BOOL needsRetry = NO;
    for (NSInteger pass = 0; pass < 2; pass++) {
        if (pass == 1) {
            if (!needsRetry) {
                break;
            }
            // Ask SpringBoard-side runtime to refresh focus context before retrying sender capture.
            [self proxySpringBoardResponseForPath:@"/touch/forcefocus" timeout:0.45];
            usleep(120000);
        }

        for (NSString *candidatePath in candidatePaths) {
            NSString *body = [self proxySpringBoardResponseForPath:candidatePath timeout:0.45];
            if (body.length == 0) {
                continue;
            }
            NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonError = nil;
            id payload = (jsonData.length > 0)
                ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError]
                : nil;
            if (jsonError || ![payload isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSDictionary *parsed = (NSDictionary *)payload;
            uint64_t parsedSenderID = KimiRunParseSenderIDValue(parsed[@"senderID"] ?: parsed[@"id"]);
            if (parsedSenderID == 0) {
                continue;
            }

            BOOL captured = [parsed[@"captured"] respondsToSelector:@selector(boolValue)] &&
                            [parsed[@"captured"] boolValue];
            NSInteger callbackCount = [parsed[@"callbackCount"] respondsToSelector:@selector(integerValue)]
                                        ? [parsed[@"callbackCount"] integerValue]
                                        : 0;
            NSInteger digitizerCount = [parsed[@"digitizerCount"] respondsToSelector:@selector(integerValue)]
                                         ? [parsed[@"digitizerCount"] integerValue]
                                         : 0;
            NSString *source = [parsed[@"source"] isKindOfClass:[NSString class]] ? parsed[@"source"] : @"";

            // Prefer true live capture from SpringBoard-side HID callbacks.
            NSInteger score = 0;
            if ([candidatePath isEqualToString:@"/touch/senderid/local"]) score += 4;
            if (captured) score += 8;
            if (digitizerCount > 0) score += 6;
            if (callbackCount > 0) score += 3;
            if ([source rangeOfString:@"captured" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 2;
            if ([source rangeOfString:@"fallback" options:NSCaseInsensitiveSearch].location != NSNotFound) score -= 3;

            if (!senderInfo || score > senderScore) {
                senderInfo = parsed;
                usedPath = candidatePath;
                senderID = parsedSenderID;
                senderScore = score;
            }
        }

        BOOL bestCaptured = [senderInfo[@"captured"] respondsToSelector:@selector(boolValue)] &&
                            [senderInfo[@"captured"] boolValue];
        NSInteger bestDigitizers = [senderInfo[@"digitizerCount"] respondsToSelector:@selector(integerValue)]
                                     ? [senderInfo[@"digitizerCount"] integerValue]
                                     : 0;
        needsRetry = !(bestCaptured || bestDigitizers > 0);
    }

    if (!senderInfo || senderID == 0) {
        [KimiRunTouchInjection setProxySenderContextWithID:0
                                                  captured:NO
                                            digitizerCount:0
                                                    source:@"missing"];
        info[@"senderSyncApplied"] = @NO;
        info[@"senderSyncReason"] = @"proxy_senderid_missing";
        return info;
    }
    info[@"senderSyncProxyPath"] = usedPath ?: @"unknown";

    id source = senderInfo[@"source"];
    id captured = senderInfo[@"captured"];
    id callbackCount = senderInfo[@"callbackCount"];
    id digitizerCount = senderInfo[@"digitizerCount"];
    if ([source isKindOfClass:[NSString class]] && [source length] > 0) {
        info[@"proxySenderIDSource"] = source;
    }
    if ([captured respondsToSelector:@selector(boolValue)]) {
        info[@"proxySenderIDCaptured"] = @([captured boolValue]);
    }
    if ([callbackCount respondsToSelector:@selector(integerValue)]) {
        info[@"proxySenderIDCallbackCount"] = @([callbackCount integerValue]);
    }
    if ([digitizerCount respondsToSelector:@selector(integerValue)]) {
        info[@"proxySenderIDDigitizerCount"] = @([digitizerCount integerValue]);
    }
    info[@"proxySenderIDHex"] = [NSString stringWithFormat:@"0x%llX", senderID];
    info[@"proxySenderIDScore"] = @(senderScore);
    BOOL proxyCaptured = [captured respondsToSelector:@selector(boolValue)] && [captured boolValue];
    NSInteger proxyDigitizers = [digitizerCount respondsToSelector:@selector(integerValue)] ? [digitizerCount integerValue] : 0;
    info[@"proxySenderIDLikelyLive"] = @((proxyCaptured || proxyDigitizers > 0));

    [KimiRunTouchInjection setProxySenderContextWithID:senderID
                                              captured:proxyCaptured
                                        digitizerCount:proxyDigitizers
                                                source:([source isKindOfClass:[NSString class]] ? (NSString *)source : nil)];

    __block BOOL applied = NO;
    if ([NSThread isMainThread]) {
        [KimiRunTouchInjection setSenderIDOverride:senderID persist:NO];
        applied = YES;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [KimiRunTouchInjection setSenderIDOverride:senderID persist:NO];
            applied = YES;
        });
    }

    info[@"senderSyncApplied"] = @(applied);
    info[@"senderSyncReason"] = applied ? @"applied" : @"apply_failed";
    return info;
}


@end

static void DaemonSocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    if (type != kCFSocketAcceptCallBack) return;
    DaemonHTTPServer *server = (__bridge DaemonHTTPServer *)info;
    CFSocketNativeHandle nativeSocket = *(CFSocketNativeHandle *)data;
    [server handleConnection:nativeSocket];
}

static CGFloat ClampValue(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}
