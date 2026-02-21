#import "DaemonHTTPServer.h"
#import <Foundation/Foundation.h>
#import <unistd.h>
#import "../screenshot/KimiRunScreenshot.h"

static const NSUInteger kSpringBoardProxyPort = 8765;
static const NSUInteger kPreferencesProxyPort = 8766;
static const NSUInteger kMobileSafariProxyPort = 8767;

static BOOL KimiRunDaemonLocalScreenshotEnabled(void) {
    const char *value = getenv("KIMIRUN_DAEMON_LOCAL_SCREENSHOT");
    if (!value || value[0] == '\0') {
        return NO;
    }
    NSString *lower = [[[NSString stringWithUTF8String:value]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                       lowercaseString];
    return ([lower isEqualToString:@"1"] ||
            [lower isEqualToString:@"true"] ||
            [lower isEqualToString:@"yes"] ||
            [lower isEqualToString:@"on"]);
}

@implementation DaemonHTTPServer (Network)

- (NSData *)fetchURL:(NSURL *)url timeout:(NSTimeInterval)timeout {
    if (!url) return nil;
    __block NSData *result = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = timeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURLSessionDataTask *task = [session dataTaskWithURL:url
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (!err && data.length > 0) {
            result = data;
        } else {
            error = err;
        }
        dispatch_semaphore_signal(sema);
    }];
    [task resume];

    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sema, t) != 0) {
        [task cancel];
        [session invalidateAndCancel];
        return nil;
    }
    [session finishTasksAndInvalidate];
    if (error) {
        return nil;
    }
    return result;
}

- (NSString *)proxySpringBoardResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout {
    if (!path || path.length == 0) {
        return nil;
    }
    NSString *normalized = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%lu%@",
                           (unsigned long)kSpringBoardProxyPort,
                           normalized];
    NSData *data = [self fetchURL:[NSURL URLWithString:urlString] timeout:timeout];
    if (!data || data.length == 0) {
        return nil;
    }
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return body.length > 0 ? body : nil;
}

- (NSString *)proxyTouchResponseForPath:(NSString *)path timeout:(NSTimeInterval)timeout {
    return [self proxyTouchResponseForPath:path timeout:timeout resolvedPortOut:NULL];
}

- (NSString *)proxyAppResponseForPath:(NSString *)path
                               timeout:(NSTimeInterval)timeout
                       resolvedPortOut:(NSUInteger *)resolvedPortOut {
    if (!path || path.length == 0) {
        return nil;
    }
    if (resolvedPortOut) {
        *resolvedPortOut = 0;
    }

    NSString *normalized = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    const NSUInteger ports[] = {kPreferencesProxyPort, kMobileSafariProxyPort};
    const NSUInteger count = sizeof(ports) / sizeof(ports[0]);

    for (NSUInteger i = 0; i < count; i++) {
        NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%lu%@",
                               (unsigned long)ports[i],
                               normalized];
        NSData *data = [self fetchURL:[NSURL URLWithString:urlString] timeout:timeout];
        if (!data || data.length == 0) {
            continue;
        }
        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (body.length > 0) {
            if (resolvedPortOut) {
                *resolvedPortOut = ports[i];
            }
            return body;
        }
    }

    return nil;
}

- (NSString *)proxyTouchResponseForPath:(NSString *)path
                                timeout:(NSTimeInterval)timeout
                        resolvedPortOut:(NSUInteger *)resolvedPortOut {
    if (!path || path.length == 0) {
        return nil;
    }
    if (resolvedPortOut) {
        *resolvedPortOut = 0;
    }

    NSString *normalized = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    const NSUInteger ports[] = {kPreferencesProxyPort, kMobileSafariProxyPort, kSpringBoardProxyPort};
    const NSUInteger count = sizeof(ports) / sizeof(ports[0]);

    for (NSUInteger i = 0; i < count; i++) {
        NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%lu%@",
                               (unsigned long)ports[i],
                               normalized];
        NSData *data = [self fetchURL:[NSURL URLWithString:urlString] timeout:timeout];
        if (!data || data.length == 0) {
            continue;
        }
        NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (body.length > 0) {
            if (resolvedPortOut) {
                *resolvedPortOut = ports[i];
            }
            return body;
        }
    }

    return nil;
}

- (NSArray<NSDictionary *> *)fetchInteractiveElementsForPort:(NSUInteger)port {
    if (port == 0) {
        return @[];
    }
    NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%lu/a11y/interactive?compact=1",
                           (unsigned long)port];
    NSData *data = [self fetchURL:[NSURL URLWithString:urlString] timeout:0.6];
    if (!data) return @[];
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSArray class]]) {
        return @[];
    }
    return (NSArray<NSDictionary *> *)obj;
}

- (NSArray<NSDictionary *> *)fetchSpringBoardInteractiveElements {
    return [self fetchInteractiveElementsForPort:kSpringBoardProxyPort];
}

- (NSDictionary *)fetchDebugInfoForPort:(NSUInteger)port {
    if (port == 0) {
        return @{@"error": @"invalid_port"};
    }
    NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%lu/a11y/debug",
                           (unsigned long)port];
    NSData *data = [self fetchURL:[NSURL URLWithString:urlString] timeout:0.6];
    if (!data) {
        return @{@"error": @"unreachable"};
    }
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        return @{@"error": @"invalid_response"};
    }
    return (NSDictionary *)obj;
}

- (NSDictionary *)fetchSpringBoardDebugInfo {
    return [self fetchDebugInfoForPort:kSpringBoardProxyPort];
}

- (NSData *)fetchSpringBoardScreenshotData {
    // Prioritize SpringBoard first for stability; app-process servers are optional.
    const NSUInteger ports[] = {kSpringBoardProxyPort, kPreferencesProxyPort, kMobileSafariProxyPort};
    const NSUInteger portCount = sizeof(ports) / sizeof(ports[0]);

    // Attempt file-based capture first. Some app-process servers can stall this
    // endpoint, so keep timeout conservative and continue on failure.
    for (NSUInteger i = 0; i < portCount; i++) {
        NSUInteger port = ports[i];
        NSTimeInterval timeout = (port == kSpringBoardProxyPort) ? 1.2 : 0.45;
        NSString *fileURL = [NSString stringWithFormat:@"http://127.0.0.1:%lu/screenshot/file?format=png",
                             (unsigned long)port];
        NSData *fileResp = [self fetchURL:[NSURL URLWithString:fileURL] timeout:timeout];
        if (fileResp.length == 0) {
            continue;
        }
        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:fileResp options:0 error:&error];
        if (error || ![obj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *path = [obj[@"path"] isKindOfClass:[NSString class]] ? obj[@"path"] : nil;
        if (path.length == 0) {
            continue;
        }
        NSData *fileData = [NSData dataWithContentsOfFile:path];
        if (fileData.length > 0) {
            unlink([path fileSystemRepresentation]);
            return fileData;
        }
    }

    // Fall back to base64 screenshot endpoint. SpringBoard payload is large, so
    // this timeout must be high enough to transfer and decode the full JSON blob.
    for (NSUInteger i = 0; i < portCount; i++) {
        NSUInteger port = ports[i];
        NSTimeInterval timeout = (port == kSpringBoardProxyPort) ? 2.6 : 0.8;
        NSString *b64URL = [NSString stringWithFormat:@"http://127.0.0.1:%lu/screenshot",
                            (unsigned long)port];
        NSData *b64Resp = [self fetchURL:[NSURL URLWithString:b64URL] timeout:timeout];
        if (b64Resp.length == 0) {
            continue;
        }

        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:b64Resp options:0 error:&error];
        if (error || ![obj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *dataB64 = [obj[@"data"] isKindOfClass:[NSString class]] ? obj[@"data"] : nil;
        if (dataB64.length == 0) {
            continue;
        }
        NSData *proxyData = [[NSData alloc] initWithBase64EncodedString:dataB64 options:0];
        if (proxyData.length > 0) {
            return proxyData;
        }
    }

    if (!KimiRunDaemonLocalScreenshotEnabled()) {
        return nil;
    }

    __block NSData *localData = nil;
    void (^captureBlock)(void) = ^{
        localData = [[KimiRunScreenshot sharedScreenshot] captureScreenAsPNG];
    };
    if ([NSThread isMainThread]) {
        captureBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), captureBlock);
    }
    return localData.length > 0 ? localData : nil;
}

@end
