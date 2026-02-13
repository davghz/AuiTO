#import "AUIHTTPServer.h"
#import "AUIVirtualTouch.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

#define HTTP_BUFFER_SIZE 4096
#define AUI_COORD_MAX 32767

@interface AUIHTTPServer ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) CFSocketRef socket;
@end

static void AUISocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

@implementation AUIHTTPServer

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error {
    if (self.isRunning) return YES;

    self.port = port;

    CFSocketContext context = {0};
    context.info = (__bridge void *)self;

    CFSocketRef sock = CFSocketCreate(
        kCFAllocatorDefault,
        PF_INET,
        SOCK_STREAM,
        IPPROTO_TCP,
        kCFSocketAcceptCallBack,
        AUISocketCallback,
        &context
    );

    if (!sock) {
        if (error) {
            *error = [NSError errorWithDomain:@"AUIHTTPServer" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        }
        return NO;
    }

    int yes = 1;
    setsockopt(CFSocketGetNative(sock), SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    NSData *addressData = [NSData dataWithBytes:&addr length:sizeof(addr)];

    if (CFSocketSetAddress(sock, (__bridge CFDataRef)addressData) != kCFSocketSuccess) {
        if (error) {
            *error = [NSError errorWithDomain:@"AUIHTTPServer" code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind port"}];
        }
        CFRelease(sock);
        return NO;
    }

    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, sock, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);

    self.socket = sock;
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

#pragma mark - Connection Handling

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
                    contentLength = [self contentLengthFromHeader:tempString];
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
    NSString *response = [self responseForRequest:requestString];

    NSData *responseData = [response dataUsingEncoding:NSUTF8StringEncoding];
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

#pragma mark - Request Routing

- (NSString *)responseForRequest:(NSString *)request {
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.count > 0 ? lines[0] : @"";
    NSArray *parts = [requestLine componentsSeparatedByString:@" "];
    NSString *path = parts.count >= 2 ? parts[1] : @"/";

    NSString *routePath = path;
    NSRange queryRange = [path rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        routePath = [path substringToIndex:queryRange.location];
    }

    // GET /ping
    if ([routePath isEqualToString:@"/ping"]) {
        NSString *deviceStatus = self.touch.deviceActive ? @"active" : @"inactive";
        NSString *json = [NSString stringWithFormat:
            @"{\"status\":\"ok\",\"message\":\"pong\",\"device\":\"%@\"}", deviceStatus];
        return [self jsonResponse:200 body:json];
    }

    // GET /tap?x=N&y=N
    if ([routePath isEqualToString:@"/tap"]) {
        return [self handleTap:path];
    }

    // GET /swipe?x1=N&y1=N&x2=N&y2=N&duration=N&steps=N
    if ([routePath isEqualToString:@"/swipe"]) {
        return [self handleSwipe:path];
    }

    // GET /down?finger=N&x=N&y=N
    if ([routePath isEqualToString:@"/down"]) {
        return [self handleDown:path];
    }

    // GET /up?finger=N
    if ([routePath isEqualToString:@"/up"]) {
        return [self handleUp:path];
    }

    // GET /move?finger=N&x=N&y=N
    if ([routePath isEqualToString:@"/move"]) {
        return [self handleMove:path];
    }

    // GET /status
    if ([routePath isEqualToString:@"/status"]) {
        NSString *json = [NSString stringWithFormat:
            @"{\"status\":\"ok\",\"device_active\":%@,\"port\":%lu}",
            self.touch.deviceActive ? @"true" : @"false",
            (unsigned long)self.port];
        return [self jsonResponse:200 body:json];
    }

    return [self jsonResponse:404 body:@"{\"status\":\"error\",\"message\":\"not found\"}"];
}

#pragma mark - Endpoint Handlers

- (NSString *)handleTap:(NSString *)path {
    if (!self.touch.deviceActive) {
        return [self jsonResponse:503 body:@"{\"status\":\"error\",\"message\":\"device not active\"}"];
    }

    CGFloat x = [self floatFromQuery:path key:@"x"];
    CGFloat y = [self floatFromQuery:path key:@"y"];

    uint16_t nx = [self normalizeX:x];
    uint16_t ny = [self normalizeY:y];

    NSLog(@"[AUI-HTTP] tap x=%.1f y=%.1f -> normalized %u,%u", x, y, nx, ny);

    BOOL ok = [self.touch tapAtX:nx y:ny];
    NSString *json = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"x\":%.1f,\"y\":%.1f,\"nx\":%u,\"ny\":%u}",
        ok ? @"ok" : @"error", x, y, nx, ny];
    return [self jsonResponse:ok ? 200 : 500 body:json];
}

- (NSString *)handleSwipe:(NSString *)path {
    if (!self.touch.deviceActive) {
        return [self jsonResponse:503 body:@"{\"status\":\"error\",\"message\":\"device not active\"}"];
    }

    CGFloat x1 = [self floatFromQuery:path key:@"x1"];
    CGFloat y1 = [self floatFromQuery:path key:@"y1"];
    CGFloat x2 = [self floatFromQuery:path key:@"x2"];
    CGFloat y2 = [self floatFromQuery:path key:@"y2"];
    CGFloat duration = [self floatFromQuery:path key:@"duration"];
    CGFloat steps = [self floatFromQuery:path key:@"steps"];

    if (duration <= 0) duration = 300;
    if (steps <= 0) steps = 20;

    // Duration comes in as milliseconds from the API
    NSTimeInterval durationSec = duration / 1000.0;

    uint16_t nx1 = [self normalizeX:x1];
    uint16_t ny1 = [self normalizeY:y1];
    uint16_t nx2 = [self normalizeX:x2];
    uint16_t ny2 = [self normalizeY:y2];

    NSLog(@"[AUI-HTTP] swipe (%.1f,%.1f)->(%.1f,%.1f) dur=%.0fms steps=%.0f",
          x1, y1, x2, y2, duration, steps);

    BOOL ok = [self.touch swipeFromX:nx1 y:ny1 toX:nx2 y:ny2
                            duration:durationSec steps:(NSUInteger)steps];

    NSString *json = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"x1\":%.1f,\"y1\":%.1f,\"x2\":%.1f,\"y2\":%.1f}",
        ok ? @"ok" : @"error", x1, y1, x2, y2];
    return [self jsonResponse:ok ? 200 : 500 body:json];
}

- (NSString *)handleDown:(NSString *)path {
    if (!self.touch.deviceActive) {
        return [self jsonResponse:503 body:@"{\"status\":\"error\",\"message\":\"device not active\"}"];
    }

    uint8_t finger = (uint8_t)[self floatFromQuery:path key:@"finger"];
    CGFloat x = [self floatFromQuery:path key:@"x"];
    CGFloat y = [self floatFromQuery:path key:@"y"];

    uint16_t nx = [self normalizeX:x];
    uint16_t ny = [self normalizeY:y];

    BOOL ok = [self.touch touchDownWithFinger:finger x:nx y:ny];
    NSString *json = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"finger\":%u,\"x\":%.1f,\"y\":%.1f}",
        ok ? @"ok" : @"error", finger, x, y];
    return [self jsonResponse:ok ? 200 : 500 body:json];
}

- (NSString *)handleUp:(NSString *)path {
    if (!self.touch.deviceActive) {
        return [self jsonResponse:503 body:@"{\"status\":\"error\",\"message\":\"device not active\"}"];
    }

    uint8_t finger = (uint8_t)[self floatFromQuery:path key:@"finger"];

    BOOL ok = [self.touch touchUpWithFinger:finger];
    NSString *json = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"finger\":%u}", ok ? @"ok" : @"error", finger];
    return [self jsonResponse:ok ? 200 : 500 body:json];
}

- (NSString *)handleMove:(NSString *)path {
    if (!self.touch.deviceActive) {
        return [self jsonResponse:503 body:@"{\"status\":\"error\",\"message\":\"device not active\"}"];
    }

    uint8_t finger = (uint8_t)[self floatFromQuery:path key:@"finger"];
    CGFloat x = [self floatFromQuery:path key:@"x"];
    CGFloat y = [self floatFromQuery:path key:@"y"];

    uint16_t nx = [self normalizeX:x];
    uint16_t ny = [self normalizeY:y];

    BOOL ok = [self.touch touchMoveWithFinger:finger x:nx y:ny];
    NSString *json = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"finger\":%u,\"x\":%.1f,\"y\":%.1f}",
        ok ? @"ok" : @"error", finger, x, y];
    return [self jsonResponse:ok ? 200 : 500 body:json];
}

#pragma mark - Coordinate Normalization

// Coordinates come in as pixel values (iPhone X: 375x812 points or 1125x2436 pixels)
// We normalize to 0-32767 range for the HID digitizer
// Assume point coordinates (375x812) by default since that's what most callers use
- (uint16_t)normalizeX:(CGFloat)x {
    // iPhone X point width = 375
    CGFloat ratio = x / 375.0;
    if (ratio < 0) ratio = 0;
    if (ratio > 1) ratio = 1;
    return (uint16_t)(ratio * AUI_COORD_MAX);
}

- (uint16_t)normalizeY:(CGFloat)y {
    // iPhone X point height = 812
    CGFloat ratio = y / 812.0;
    if (ratio < 0) ratio = 0;
    if (ratio > 1) ratio = 1;
    return (uint16_t)(ratio * AUI_COORD_MAX);
}

#pragma mark - HTTP Helpers

- (NSString *)jsonResponse:(NSInteger)statusCode body:(NSString *)body {
    NSString *safeBody = body ?: @"";
    NSData *bodyData = [safeBody dataUsingEncoding:NSUTF8StringEncoding];
    NSString *statusText = statusCode == 200 ? @"OK" :
                           statusCode == 404 ? @"Not Found" :
                           statusCode == 503 ? @"Service Unavailable" : @"Error";
    return [NSString stringWithFormat:
            @"HTTP/1.1 %ld %@\r\n"
            @"Content-Type: application/json\r\n"
            @"Content-Length: %lu\r\n"
            @"Connection: close\r\n"
            @"\r\n"
            @"%@",
            (long)statusCode, statusText,
            (unsigned long)(bodyData ? bodyData.length : 0),
            safeBody];
}

- (CGFloat)floatFromQuery:(NSString *)query key:(NSString *)key {
    NSString *pattern = [NSString stringWithFormat:@"%@=", key];
    NSRange keyRange = [query rangeOfString:pattern];
    if (keyRange.location == NSNotFound) return 0;

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

- (NSInteger)contentLengthFromHeader:(NSString *)headerString {
    if (!headerString || headerString.length == 0) return 0;
    NSRange headerRange = [headerString rangeOfString:@"\r\n\r\n"];
    NSString *headers = headerRange.location != NSNotFound ? [headerString substringToIndex:headerRange.location] : headerString;
    __block NSInteger length = 0;
    [headers enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if ([[line lowercaseString] hasPrefix:@"content-length:"]) {
            NSString *value = [line substringFromIndex:15];
            length = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] integerValue];
            *stop = YES;
        }
    }];
    return length;
}

@end

#pragma mark - Socket Callback

static void AUISocketCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    if (type != kCFSocketAcceptCallBack) return;
    AUIHTTPServer *server = (__bridge AUIHTTPServer *)info;
    CFSocketNativeHandle nativeSocket = *(CFSocketNativeHandle *)data;
    [server handleConnection:nativeSocket];
}
