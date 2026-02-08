#import "DaemonHTTPServer.h"
#import <Foundation/Foundation.h>
#import "../touch/TouchInjection.h"
#import "../touch/AXTouchInjection.h"

static NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";

static BOOL KimiRunPrefBool(NSString *key, BOOL defaultValue) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return defaultValue;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs objectForKey:key];
    if (!value) {
        return defaultValue;
    }
    return [prefs boolForKey:key];
}

static void KimiRunSetPrefBool(NSString *key, BOOL value) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    [prefs setBool:value forKey:key];
    [prefs synchronize];
}

static void KimiRunSetPrefString(NSString *key, NSString *value) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    if ([value isKindOfClass:[NSString class]] && value.length > 0) {
        [prefs setObject:value forKey:key];
    } else {
        [prefs removeObjectForKey:key];
    }
    [prefs synchronize];
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
    return KimiRunPrefBool(@"TouchProxy", NO);
}

@interface DaemonHTTPServer (TouchAdminPrivate)
- (NSString *)proxyTouchResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (NSString *)jsonResponse:(NSInteger)statusCode body:(NSString *)body;
- (NSString *)stringValueFromQuery:(NSString *)query key:(NSString *)key;
- (BOOL)boolValueFromQuery:(NSString *)query key:(NSString *)key defaultValue:(BOOL)defaultValue;
- (NSDictionary *)parseJSONBody:(NSString *)body;
@end

@implementation DaemonHTTPServer (TouchAdmin)

- (NSString *)handleSenderIDRequestAllowProxy:(BOOL)allowProxy {
    BOOL preferProxy = allowProxy && KimiRunTouchProxyEnabled();
    if (preferProxy) {
        NSString *proxyBody = [self proxyTouchResponseForPath:@"/touch/senderid" timeout:0.6];
        if (proxyBody.length > 0) {
            return [self jsonResponse:200 body:proxyBody];
        }
    }
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
    BOOL bksDeliveryReady = [KimiRunTouchInjection bksDeliveryManagerAvailable];
    uintptr_t bksDeliveryPtr = [KimiRunTouchInjection bksDeliveryManagerPtr];
    BOOL bksRouterReady = [KimiRunTouchInjection bksRouterManagerAvailable];
    uintptr_t bksRouterPtr = [KimiRunTouchInjection bksRouterManagerPtr];
    NSString *source = [KimiRunTouchInjection senderIDSourceString];
    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"senderID\":\"0x%llX\",\"captured\":%s,\"fallbackEnabled\":%s,\"callbackCount\":%d,\"digitizerCount\":%d,\"lastEventType\":%d,\"threadRunning\":%s,\"mainRegistered\":%s,\"dispatchRegistered\":%s,\"hidConnection\":\"0x%lX\",\"adminClientType\":%d,\"bksDeliveryReady\":%s,\"bksDeliveryManager\":\"0x%lX\",\"bksRouterReady\":%s,\"bksRouterManager\":\"0x%lX\",\"source\":\"%@\"}",
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
                      bksDeliveryReady ? "true" : "false",
                      (unsigned long)bksDeliveryPtr,
                      bksRouterReady ? "true" : "false",
                      (unsigned long)bksRouterPtr,
                      source];
    return [self jsonResponse:200 body:json];
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
        NSDictionary *json = [self parseJSONBody:body];
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
        return [self jsonResponse:400 body:@"{\"status\":\"error\",\"message\":\"Missing id\"}"];
    }

    unsigned long long senderID = strtoull([idStr UTF8String], NULL, 0);
    BOOL persist = (persistStr && persistStr.length > 0) ? ([persistStr intValue] != 0) : NO;

    BOOL preferProxy = KimiRunTouchProxyEnabled();
    if (preferProxy) {
        NSString *proxyPath = [NSString stringWithFormat:@"/touch/senderid/set?id=%@&persist=%@",
                               idStr,
                               persist ? @"1" : @"0"];
        NSString *proxyBody = [self proxyTouchResponseForPath:proxyPath timeout:0.6];
        if (proxyBody.length > 0) {
            return [self jsonResponse:200 body:proxyBody];
        }
    }

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
    return ok ? [self jsonResponse:200 body:json] : [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Failed to set senderID\"}"];
}

- (NSString *)handleForceFocusRequest {
    BOOL preferProxy = KimiRunTouchProxyEnabled();
    if (preferProxy) {
        NSString *proxyBody = [self proxyTouchResponseForPath:@"/touch/forcefocus" timeout:0.6];
        if (proxyBody.length > 0) {
            return [self jsonResponse:200 body:proxyBody];
        }
    }
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

- (NSString *)handleBKHIDSelectorsRequestAllowProxy:(BOOL)allowProxy {
    BOOL preferProxy = allowProxy && KimiRunTouchProxyEnabled();
    if (preferProxy) {
        NSString *proxyBody = [self proxyTouchResponseForPath:@"/touch/bkhid_selectors" timeout:0.6];
        if (proxyBody.length > 0) {
            return [self jsonResponse:200 body:proxyBody];
        }
    }
    [KimiRunTouchInjection logBKHIDSelectorsNow];
    NSString *path = [KimiRunTouchInjection bkhidSelectorsLogPath];
    NSString *json = [NSString stringWithFormat:
                      @"{\"status\":\"ok\",\"logged\":true,\"path\":\"%@\"}",
                      path];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleAXEnableRequest:(NSString *)path {
    BOOL enabled = [self boolValueFromQuery:path key:@"enabled" defaultValue:YES];
    // AX/BKS delivery is typically more reliable in SpringBoard, so proxy is on by default when enabling AX.
    BOOL setProxy = [self boolValueFromQuery:path key:@"proxy" defaultValue:enabled];
    if (enabled) {
        KimiRunSetPrefBool(@"ForceAX", YES);
        KimiRunSetPrefString(@"TouchMethod", @"ax");
        KimiRunSetPrefBool(@"TouchProxy", setProxy);
    } else {
        KimiRunSetPrefBool(@"ForceAX", NO);
        KimiRunSetPrefString(@"TouchMethod", @"auto");
    }

    NSDictionary *enableResult = enabled ? [AXTouchInjection ensureAccessibilityEnabled] : @{};
    NSDictionary *status = [AXTouchInjection accessibilityStatus] ?: @{};
    NSDictionary *payload = @{
        @"status": @"ok",
        @"forceAX": @(enabled),
        @"touchProxy": @(setProxy),
        @"enableResult": enableResult ?: @{},
        @"axStatus": status
    };
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    NSString *json = error ? @"{\"status\":\"error\",\"message\":\"Failed to encode\"}" :
                     [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self jsonResponse:200 body:json];
}

- (NSString *)handleAXStatusRequest {
    NSDictionary *status = [AXTouchInjection accessibilityStatus] ?: @{};
    NSDictionary *payload = @{@"status": @"ok", @"axStatus": status};
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    NSString *json = error ? @"{\"status\":\"error\",\"message\":\"Failed to encode\"}" :
                     [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self jsonResponse:200 body:json];
}

@end
