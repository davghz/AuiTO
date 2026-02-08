#import "DaemonHTTPServer.h"
#import <Foundation/Foundation.h>

static const NSUInteger kSpringBoardProxyPort = 8765;
static const NSUInteger kPreferencesProxyPort = 8766;
static const NSUInteger kMobileSafariProxyPort = 8767;
static NSString *const kKimiRunPrefsSuite = @"com.auito.daemon";

static uint64_t KimiRunFNV1aHash(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || length == 0) {
        return 0;
    }
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < length; i++) {
        hash ^= (uint64_t)bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static BOOL KimiRunProxyBodyIndicatesSuccess(NSString *body) {
    if (![body isKindOfClass:[NSString class]] || body.length == 0) {
        return NO;
    }
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)obj;
            id status = dict[@"status"];
            if ([status isKindOfClass:[NSString class]] &&
                [[(NSString *)status lowercaseString] isEqualToString:@"ok"]) {
                return YES;
            }
            id success = dict[@"success"];
            if ([success respondsToSelector:@selector(boolValue)] && [success boolValue]) {
                return YES;
            }
            return NO;
        }
    }
    NSString *lower = [body lowercaseString];
    if ([lower containsString:@"\"status\":\"ok\""] ||
        [lower containsString:@"\"status\": \"ok\""] ||
        [lower containsString:@"\"success\":true"] ||
        [lower containsString:@"\"success\": true"]) {
        return YES;
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

static BOOL KimiRunIsStrictExplicitTouchMethod(NSString *method) {
    NSString *lower = KimiRunCanonicalTouchMethod(method);
    return ([lower isEqualToString:@"sim"] ||
            [lower isEqualToString:@"direct"] ||
            [lower isEqualToString:@"legacy"] ||
            [lower isEqualToString:@"conn"] ||
            [lower isEqualToString:@"bks"] ||
            [lower isEqualToString:@"zxtouch"]);
}

static NSString *KimiRunProxyModeFromBody(NSString *body) {
    if (![body isKindOfClass:[NSString class]] || body.length == 0) {
        return nil;
    }

    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [obj isKindOfClass:[NSDictionary class]]) {
            NSString *mode = [(NSDictionary *)obj objectForKey:@"mode"];
            NSString *canonical = KimiRunCanonicalTouchMethod(mode);
            if (canonical.length > 0) {
                return canonical;
            }
        }
    }
    return nil;
}

static BOOL KimiRunProxyModeMatchesRequestedMethod(NSString *proxyMode, NSString *requestedMethod) {
    NSString *mode = KimiRunCanonicalTouchMethod(proxyMode);
    NSString *requested = KimiRunCanonicalTouchMethod(requestedMethod);
    if (mode.length == 0 || requested.length == 0) {
        return NO;
    }
    if ([requested isEqualToString:@"sim"] ||
        [requested isEqualToString:@"direct"] ||
        [requested isEqualToString:@"legacy"] ||
        [requested isEqualToString:@"conn"] ||
        [requested isEqualToString:@"bks"] ||
        [requested isEqualToString:@"zxtouch"]) {
        return [requested isEqualToString:mode];
    }
    return YES;
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

static BOOL KimiRunStrictProxyFallbackToLocalEnabled(void) {
    return KimiRunEnvBool("KIMIRUN_STRICT_PROXY_FALLBACK_LOCAL",
                          KimiRunPrefBool(@"StrictProxyFallbackLocal", YES));
}

static BOOL KimiRunStrictAllowDebugDigestFallback(void) {
    return KimiRunEnvBool("KIMIRUN_STRICT_ALLOW_DEBUG_DIGEST_FALLBACK",
                          KimiRunPrefBool(@"StrictAllowDebugDigestFallback", NO));
}

static NSString *KimiRunStrictUIDigestSource(void) {
    const char *env = getenv("KIMIRUN_STRICT_UIDIGEST_SOURCE");
    NSString *raw = nil;
    if (env && env[0] != '\0') {
        raw = [NSString stringWithUTF8String:env];
    } else {
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
        raw = [prefs stringForKey:@"StrictUIDigestSource"];
    }
    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) {
        return @"a11y";
    }
    NSString *lower = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([lower isEqualToString:@"a11y"] || [lower isEqualToString:@"accessibility"]) {
        return @"a11y";
    }
    if ([lower isEqualToString:@"screenshot"] || [lower isEqualToString:@"png"]) {
        return @"screenshot";
    }
    return @"hybrid";
}

@interface DaemonHTTPServer (StrictProxyPrivate)
- (NSString *)proxyTouchResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout;
- (NSString *)proxyTouchResponseForPath:(NSString *)path
                                timeout:(NSTimeInterval)timeout
                        resolvedPortOut:(NSUInteger *)resolvedPortOut;
- (NSArray<NSDictionary *> *)fetchInteractiveElementsForPort:(NSUInteger)port;
- (NSDictionary *)fetchDebugInfoForPort:(NSUInteger)port;
- (NSData *)fetchURL:(NSURL *)url timeout:(NSTimeInterval)timeout;
- (NSString *)jsonResponse:(NSInteger)statusCode body:(NSString *)body;
- (NSString *)stringValueFromQuery:(NSString *)query key:(NSString *)key;
@end

@implementation DaemonHTTPServer (StrictProxy)

- (id)proxyTouchHTTPResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout {
    NSString *proxyBody = [self proxyTouchResponseForPath:path timeout:timeout];
    if (proxyBody.length == 0) {
        return nil;
    }
    BOOL success = KimiRunProxyBodyIndicatesSuccess(proxyBody);
    return [self jsonResponse:(success ? 200 : 500) body:proxyBody];
}

- (NSString *)uiDigestForPort:(NSUInteger)port {
    NSString *digestSource = KimiRunStrictUIDigestSource();
    BOOL allowScreenshotDigest = ![digestSource isEqualToString:@"a11y"];
    if (allowScreenshotDigest) {
        NSURL *screenshotURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/screenshot",
                                                     (unsigned long)port]];
        NSData *screenshotData = [self fetchURL:screenshotURL timeout:1.0];
        if ([screenshotData isKindOfClass:[NSData class]] && screenshotData.length > 0) {
            uint64_t screenshotHash = KimiRunFNV1aHash((const uint8_t *)screenshotData.bytes, screenshotData.length);
            return [NSString stringWithFormat:@"png-%lu-%016llx-%lu",
                    (unsigned long)port,
                    (unsigned long long)screenshotHash,
                    (unsigned long)screenshotData.length];
        }
        if ([digestSource isEqualToString:@"screenshot"]) {
            return nil;
        }
    }

    // Strict verification runs in a daemon constrained to a low jetsam limit.
    // Use a lightweight accessibility snapshot token rather than image decode.
    NSArray<NSDictionary *> *elements = [self fetchInteractiveElementsForPort:port];
    if (![elements isKindOfClass:[NSArray class]]) {
        elements = @[];
    }

    NSMutableString *token = [NSMutableString stringWithCapacity:4096];
    [token appendFormat:@"count:%lu|", (unsigned long)elements.count];

    NSUInteger cap = MIN((NSUInteger)120, elements.count);
    for (NSUInteger i = 0; i < cap; i++) {
        id obj = elements[i];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *entry = (NSDictionary *)obj;
        NSString *label = [entry[@"label"] isKindOfClass:[NSString class]] ? entry[@"label"] : @"";
        NSString *role = [entry[@"role"] isKindOfClass:[NSString class]] ? entry[@"role"] : @"";
        NSString *value = [entry[@"value"] isKindOfClass:[NSString class]] ? entry[@"value"] : @"";
        NSString *identifier = [entry[@"identifier"] isKindOfClass:[NSString class]] ? entry[@"identifier"] : @"";
        NSString *frame = [entry[@"frame"] isKindOfClass:[NSString class]] ? entry[@"frame"] : @"";
        [token appendFormat:@"%lu:%@|%@|%@|%@|%@;",
         (unsigned long)i, label, role, value, identifier, frame];
    }

    NSData *tokenData = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (!tokenData || tokenData.length == 0) {
        // Debug payloads often contain volatile fields and can produce false UI deltas.
        // Keep strict verification conservative unless explicitly enabled.
        if (!KimiRunStrictAllowDebugDigestFallback()) {
            return nil;
        }
        NSDictionary *debug = [self fetchDebugInfoForPort:port];
        if (![debug isKindOfClass:[NSDictionary class]] || debug.count == 0) {
            return nil;
        }
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:debug options:0 error:&error];
        if (!jsonData || error) {
            return nil;
        }
        uint64_t fallbackHash = KimiRunFNV1aHash((const uint8_t *)jsonData.bytes, jsonData.length);
        return [NSString stringWithFormat:@"dbg-%lu-%016llx-%lu",
                (unsigned long)port,
                (unsigned long long)fallbackHash,
                (unsigned long)jsonData.length];
    }

    uint64_t hash = KimiRunFNV1aHash((const uint8_t *)tokenData.bytes, tokenData.length);
    return [NSString stringWithFormat:@"ax-%lu-%016llx-%lu",
            (unsigned long)port,
            (unsigned long long)hash,
            (unsigned long)tokenData.length];
}

- (NSString *)springBoardScreenshotDigest {
    return [self uiDigestForPort:kSpringBoardProxyPort];
}

- (BOOL)verifyUIDeltaForPort:(NSUInteger)port
                  fromDigest:(NSString *)beforeDigest
                     timeout:(NSTimeInterval)timeout {
    if (![beforeDigest isKindOfClass:[NSString class]] || beforeDigest.length == 0) {
        return NO;
    }
    if (timeout <= 0) {
        timeout = 1.0;
    }

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (CFAbsoluteTimeGetCurrent() <= deadline) {
        NSString *afterDigest = [self uiDigestForPort:port];
        if (afterDigest.length > 0 && ![afterDigest isEqualToString:beforeDigest]) {
            // Require one confirm sample to reduce false positives caused by transient AX tree churn.
            usleep(120000);
            NSString *confirmDigest = [self uiDigestForPort:port];
            if (confirmDigest.length > 0 && ![confirmDigest isEqualToString:beforeDigest]) {
                return YES;
            }
        }
        usleep(120000);
    }
    return NO;
}

- (BOOL)verifySpringBoardUIDeltaFromDigest:(NSString *)beforeDigest timeout:(NSTimeInterval)timeout {
    return [self verifyUIDeltaForPort:kSpringBoardProxyPort fromDigest:beforeDigest timeout:timeout];
}

- (id)strictProxyResponseForPath:(NSString *)path
                          timeout:(NSTimeInterval)timeout
                 forceProxyMethod:(BOOL)forceProxyMethod
            verifyUIDeltaOnSuccess:(BOOL)verifyUIDeltaOnSuccess
               strictProxyBodyOut:(NSString **)strictProxyBodyOut
        strictProxyHadResponseOut:(BOOL *)strictProxyHadResponseOut {
    if (strictProxyBodyOut) {
        *strictProxyBodyOut = nil;
    }
    if (strictProxyHadResponseOut) {
        *strictProxyHadResponseOut = NO;
    }

    NSMutableDictionary<NSNumber *, NSString *> *beforeDigestsByPort = nil;
    if (verifyUIDeltaOnSuccess) {
        beforeDigestsByPort = [NSMutableDictionary dictionary];
        const NSUInteger digestPorts[] = {kPreferencesProxyPort, kMobileSafariProxyPort, kSpringBoardProxyPort};
        const NSUInteger digestCount = sizeof(digestPorts) / sizeof(digestPorts[0]);
        for (NSUInteger i = 0; i < digestCount; i++) {
            NSUInteger port = digestPorts[i];
            NSString *digest = [self uiDigestForPort:port];
            if (digest.length > 0) {
                beforeDigestsByPort[@(port)] = digest;
            }
        }
        if (beforeDigestsByPort.count == 0) {
            return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Unable to capture pre-dispatch UI snapshot\"}"];
        }
    }

    BOOL allowLocalFallback = (!forceProxyMethod && KimiRunStrictProxyFallbackToLocalEnabled());
    NSUInteger resolvedProxyPort = 0;
    NSString *strictProxyBody = [self proxyTouchResponseForPath:path
                                                        timeout:timeout
                                                resolvedPortOut:&resolvedProxyPort];
    if (strictProxyBody.length > 0) {
        if (strictProxyBodyOut) {
            *strictProxyBodyOut = strictProxyBody;
        }
        if (strictProxyHadResponseOut) {
            *strictProxyHadResponseOut = YES;
        }
        NSString *requestedMethod = KimiRunCanonicalTouchMethod([self stringValueFromQuery:path key:@"method"]);
        BOOL strictRequestedMethod = KimiRunIsStrictExplicitTouchMethod(requestedMethod);
        if (KimiRunProxyBodyIndicatesSuccess(strictProxyBody)) {
            if (strictRequestedMethod) {
                NSString *proxyMode = KimiRunProxyModeFromBody(strictProxyBody);
                if (proxyMode.length == 0) {
                    if (allowLocalFallback) {
                        if (strictProxyBodyOut) {
                            *strictProxyBodyOut = nil;
                        }
                        if (strictProxyHadResponseOut) {
                            *strictProxyHadResponseOut = NO;
                        }
                        return nil;
                    }
                    return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Strict method proxy response missing mode\"}"];
                }
                if (!KimiRunProxyModeMatchesRequestedMethod(proxyMode, requestedMethod)) {
                    if (allowLocalFallback) {
                        if (strictProxyBodyOut) {
                            *strictProxyBodyOut = nil;
                        }
                        if (strictProxyHadResponseOut) {
                            *strictProxyHadResponseOut = NO;
                        }
                        return nil;
                    }
                    NSString *json = [NSString stringWithFormat:
                                      @"{\"status\":\"error\",\"message\":\"Strict method mismatch: requested=%@ delivered=%@\"}",
                                      requestedMethod ?: @"unknown",
                                      proxyMode ?: @"unknown"];
                    return [self jsonResponse:500 body:json];
                }
            }
            NSString *beforeDigest = beforeDigestsByPort[@(resolvedProxyPort)];
            if (verifyUIDeltaOnSuccess &&
                (beforeDigest.length == 0 ||
                 ![self verifyUIDeltaForPort:(resolvedProxyPort ?: kSpringBoardProxyPort)
                                   fromDigest:beforeDigest
                                      timeout:1.0])) {
                if (allowLocalFallback) {
                    if (strictProxyBodyOut) {
                        *strictProxyBodyOut = nil;
                    }
                    if (strictProxyHadResponseOut) {
                        *strictProxyHadResponseOut = NO;
                    }
                    return nil;
                }
                NSString *json = [NSString stringWithFormat:
                                  @"{\"status\":\"error\",\"message\":\"Proxy reported success but no UI delta observed\",\"proxyPort\":%lu}",
                                  (unsigned long)resolvedProxyPort];
                return [self jsonResponse:500 body:json];
            }
            return [self jsonResponse:200 body:strictProxyBody];
        }
        if (forceProxyMethod) {
            return [self jsonResponse:500 body:strictProxyBody];
        }
        if (allowLocalFallback) {
            if (strictProxyBodyOut) {
                *strictProxyBodyOut = nil;
            }
            if (strictProxyHadResponseOut) {
                *strictProxyHadResponseOut = NO;
            }
            return nil;
        }
    }

    if (forceProxyMethod) {
        return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Touch proxy unavailable for explicit method\"}"];
    }
    return nil;
}

@end
