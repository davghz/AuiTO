#import "TouchInjectionInternal.h"
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <errno.h>
#import <stdlib.h>
#import <math.h>

#define KimiRunResolveMethod KimiRunResolveTouchMethod
#define KimiRunRejectUnverifiedExplicitResult KimiRunRejectUnverifiedTouchResult
#define DispatchPhaseWithOptions KimiRunDispatchPhase
#define KimiRunPrefString KimiRunTouchPrefString
#define KimiRunPrefBool KimiRunTouchPrefBool
#define KimiRunEnvBool KimiRunTouchEnvBool

#define CreateTouchEvent KimiRunCreateTouchEvent
#define CreateBKSTouchEvent KimiRunCreateBKSTouchEvent
#define PostTouchEvent KimiRunPostTouchEvent
#define PostSimulateTouchEvent KimiRunPostSimulateTouchEvent
#define PostSimulateTouchEventViaConnection KimiRunPostSimulateTouchEventViaConnection
#define PostLegacyTouchEventPhase KimiRunPostLegacyTouchEventPhase
#define PostBKSTouchEventPhase KimiRunPostBKSTouchEventPhase

// Extracted from TouchInjection.m: gesture transport helpers (ZXTouch + point normalization)
static CGPoint KimiRunNormalizePoint(CGPoint point) {
    CGFloat x = point.x;
    CGFloat y = point.y;
    AdjustInputCoordinates(&x, &y);
    return CGPointMake(x, y);
}

static double KimiRunTouchEnvDouble(const char *key, double defaultValue) {
    if (!key) {
        return defaultValue;
    }
    const char *value = getenv(key);
    if (!value || value[0] == '\0') {
        return defaultValue;
    }
    char *endPtr = NULL;
    double parsed = strtod(value, &endPtr);
    if (endPtr == value || !isfinite(parsed)) {
        return defaultValue;
    }
    return parsed;
}

static double KimiRunTouchPrefDouble(NSString *key, double defaultValue) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return defaultValue;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id raw = [prefs objectForKey:key];
    if (!raw) {
        return defaultValue;
    }
    if ([raw respondsToSelector:@selector(doubleValue)]) {
        double value = [raw doubleValue];
        if (isfinite(value)) {
            return value;
        }
    }
    return defaultValue;
}

static double KimiRunGestureDeltaPixels(void) {
    double env = KimiRunTouchEnvDouble("KIMIRUN_GESTURE_DELTA_PX", NAN);
    if (isfinite(env) && env > 0.0) {
        return env;
    }
    double pref = KimiRunTouchPrefDouble(@"GestureDeltaPx", 0.0);
    return (isfinite(pref) && pref > 0.0) ? pref : 0.0;
}

static BOOL KimiRunGestureUseSimpleCurve(void) {
    NSString *raw = KimiRunTouchEnvOrPrefString("KIMIRUN_GESTURE_INTERPOLATION",
                                                @"GestureInterpolation",
                                                @"linear");
    if (![raw isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *lower = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return ([lower isEqualToString:@"simple_curve"] ||
            [lower isEqualToString:@"simplecurve"] ||
            [lower isEqualToString:@"curve"] ||
            [lower isEqualToString:@"xxtouch_curve"]);
}

static double KimiRunGestureCurveInterpolation(double a, double b, double t) {
    double warped = sin(1.5707963267948966 * t);
    double easedT = sin(warped * t * 1.5707963267948966);
    return a + ((b - a) * easedT);
}

static NSInteger KimiRunGestureStepCount(CGPoint start, CGPoint end, NSInteger fallbackSteps) {
    NSInteger safeFallback = (fallbackSteps > 0) ? fallbackSteps : 1;
    double deltaPx = KimiRunGestureDeltaPixels();
    if (!(deltaPx > 0.0)) {
        return safeFallback;
    }

    double dx = (double)end.x - (double)start.x;
    double dy = (double)end.y - (double)start.y;
    double distance = sqrt((dx * dx) + (dy * dy));
    if (!(distance > 0.0)) {
        return 1;
    }

    NSInteger steps = (NSInteger)ceil(distance / deltaPx);
    return (steps > 0) ? steps : 1;
}

static useconds_t KimiRunGestureStepDelayMicros(NSTimeInterval duration, NSInteger steps) {
    NSInteger safeSteps = (steps > 0) ? steps : 1;
    double micros = (duration * 1000000.0) / (double)safeSteps;
    if (!isfinite(micros) || micros < 1000.0) {
        micros = 1000.0;
    }
    return (useconds_t)llround(micros);
}

static CGPoint KimiRunGesturePointAtStep(CGPoint start,
                                         CGPoint end,
                                         NSInteger step,
                                         NSInteger totalSteps,
                                         BOOL useSimpleCurve) {
    if (totalSteps <= 0) {
        return end;
    }
    NSInteger clampedStep = step;
    if (clampedStep < 0) {
        clampedStep = 0;
    } else if (clampedStep > totalSteps) {
        clampedStep = totalSteps;
    }
    double t = (double)clampedStep / (double)totalSteps;
    if (useSimpleCurve) {
        return CGPointMake((CGFloat)KimiRunGestureCurveInterpolation(start.x, end.x, t),
                           (CGFloat)KimiRunGestureCurveInterpolation(start.y, end.y, t));
    }
    return CGPointMake((CGFloat)(start.x + ((end.x - start.x) * t)),
                       (CGFloat)(start.y + ((end.y - start.y) * t)));
}

static BOOL KimiRunZXTouchEnabled(void) {
    // ZXTouch can destabilize SpringBoard on some iOS 13 setups.
    // Keep it opt-in until explicitly enabled by operator.
    return KimiRunEnvBool("KIMIRUN_ENABLE_ZXTOUCH",
                          KimiRunPrefBool(@"EnableZXTouch", NO));
}

static NSString *KimiRunZXTouchHost(void) {
    const char *env = getenv("KIMIRUN_ZXTOUCH_HOST");
    if (env && env[0] != '\0') {
        return [NSString stringWithUTF8String:env];
    }
    NSString *host = KimiRunPrefString(@"ZXTouchHost");
    return (host.length > 0) ? host : @"127.0.0.1";
}

static int KimiRunZXTouchPort(void) {
    const char *env = getenv("KIMIRUN_ZXTOUCH_PORT");
    if (env && env[0] != '\0') {
        return atoi(env);
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    NSInteger port = [prefs integerForKey:@"ZXTouchPort"];
    return (port > 0) ? (int)port : 6000;
}

static int KimiRunZXTouchConnect(void) {
    NSString *host = KimiRunZXTouchHost();
    int port = KimiRunZXTouchPort();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) <= 0) {
        close(fd);
        return -1;
    }

    int res = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (res < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }

    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 200000;
    int sel = select(fd + 1, NULL, &wfds, NULL, &tv);
    if (sel <= 0) {
        close(fd);
        return -1;
    }

    int so_error = 0;
    socklen_t len = sizeof(so_error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_error, &len) != 0 || so_error != 0) {
        close(fd);
        return -1;
    }

    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags);
    }

    struct timeval send_to;
    send_to.tv_sec = 0;
    send_to.tv_usec = 500000;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send_to, sizeof(send_to));
    return fd;
}

static BOOL KimiRunZXTouchSendLines(NSArray<NSString *> *lines, useconds_t delayBetween) {
    if (!KimiRunZXTouchEnabled()) {
        return NO;
    }
    if (!lines || lines.count == 0) {
        return NO;
    }
    int fd = KimiRunZXTouchConnect();
    if (fd < 0) {
        return NO;
    }
    ssize_t total = 0;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        if (!line) {
            continue;
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        ssize_t sent = send(fd, data.bytes, data.length, 0);
        if (sent != (ssize_t)data.length) {
            close(fd);
            return NO;
        }
        total += sent;
        if (delayBetween > 0 && i + 1 < lines.count) {
            usleep(delayBetween);
        }
    }
    close(fd);
    return (total > 0);
}

static NSString *KimiRunZXTouchFormatTouchLine(int type, int fingerIndex, CGFloat x, CGFloat y) {
    int scaledX = (int)llround(x * 10.0);
    int scaledY = (int)llround(y * 10.0);
    if (scaledX < 0) scaledX = 0;
    if (scaledY < 0) scaledY = 0;
    if (scaledX > 99999) scaledX = 99999;
    if (scaledY > 99999) scaledY = 99999;
    NSString *event = [NSString stringWithFormat:@"1%d%02d%05d%05d", type, fingerIndex, scaledX, scaledY];
    return [NSString stringWithFormat:@"%d%@\r\n", kZXTouchTaskPerformTouch, event];
}

static BOOL KimiRunZXTouchTap(CGPoint point) {
    point = KimiRunNormalizePoint(point);
    NSArray<NSString *> *lines = @[
        KimiRunZXTouchFormatTouchLine(kZXTouchTouchDown, 1, point.x, point.y),
        KimiRunZXTouchFormatTouchLine(kZXTouchTouchUp, 1, point.x, point.y)
    ];
    return KimiRunZXTouchSendLines(lines, 50000);
}

static BOOL KimiRunZXTouchLongPress(CGPoint point, NSTimeInterval duration) {
    point = KimiRunNormalizePoint(point);
    NSString *down = KimiRunZXTouchFormatTouchLine(kZXTouchTouchDown, 1, point.x, point.y);
    NSString *up = KimiRunZXTouchFormatTouchLine(kZXTouchTouchUp, 1, point.x, point.y);
    if (!KimiRunZXTouchSendLines(@[down], 0)) {
        return NO;
    }
    usleep((useconds_t)(duration * 1000000));
    return KimiRunZXTouchSendLines(@[up], 0);
}

static BOOL KimiRunZXTouchGesture(CGPoint start, CGPoint end, NSTimeInterval duration, int steps) {
    if (steps <= 0) {
        steps = 1;
    }
    start = KimiRunNormalizePoint(start);
    end = KimiRunNormalizePoint(end);
    BOOL useSimpleCurve = KimiRunGestureUseSimpleCurve();
    useconds_t stepDelay = KimiRunGestureStepDelayMicros(duration, steps);

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:(NSUInteger)(steps + 2)];
    [lines addObject:KimiRunZXTouchFormatTouchLine(kZXTouchTouchDown, 1, start.x, start.y)];
    for (int i = 1; i <= steps; i++) {
        CGPoint point = KimiRunGesturePointAtStep(start, end, i, steps, useSimpleCurve);
        [lines addObject:KimiRunZXTouchFormatTouchLine(kZXTouchTouchMove, 1, point.x, point.y)];
    }
    [lines addObject:KimiRunZXTouchFormatTouchLine(kZXTouchTouchUp, 1, end.x, end.y)];
    return KimiRunZXTouchSendLines(lines, stepDelay);
}

static BOOL KimiRunZXTouchAvailable(void) {
    if (!KimiRunZXTouchEnabled()) {
        return NO;
    }
    int fd = KimiRunZXTouchConnect();
    if (fd < 0) {
        return NO;
    }
    close(fd);
    return YES;
}

@implementation KimiRunTouchInjection (GestureComposer)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
// Extracted from TouchInjection.m: gesture composition methods
+ (BOOL)tapAtX:(CGFloat)x Y:(CGFloat)y {
    return [self tapAtX:x Y:y method:nil];
}

+ (BOOL)tapAtX:(CGFloat)x Y:(CGFloat)y method:(NSString *)method {
    NSString *lower = KimiRunResolveMethod(method);
    BOOL wantSim = ([lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"sim"] ||
                    [lower isEqualToString:@"iohid"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantLegacy = ([lower isEqualToString:@"legacy"] ||
                       [lower isEqualToString:@"old"] ||
                       [lower isEqualToString:@"all"]);
    BOOL wantConn = ([lower isEqualToString:@"conn"] ||
                     [lower isEqualToString:@"connection"] ||
                     [lower isEqualToString:@"all"]);
    BOOL wantBKS = ([lower isEqualToString:@"bks"] ||
                    [lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantAX = ([lower isEqualToString:@"ax"] ||
                   [lower isEqualToString:@"all"]);
    BOOL wantZX = ([lower isEqualToString:@"zx"] ||
                   [lower isEqualToString:@"zxtouch"] ||
                   [lower isEqualToString:@"all"]);
    BOOL allowFallback = ([lower isEqualToString:@"auto"] ||
                          [lower isEqualToString:@"all"]);

    NSLog(@"[KimiRunTouchInjection] Tap requested at (%.1f, %.1f), method=%@ initialized=%d, onMainThread=%d",
          x, y, lower, g_initialized, [NSThread isMainThread]);
    
    // Ensure touch injection runs on main thread
    if (![NSThread isMainThread]) {
        NSLog(@"[KimiRunTouchInjection] Dispatching to main thread...");
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self tapAtX:x Y:y method:lower];
        });
        return result;
    }
    
    if (!g_initialized) {
        NSLog(@"[KimiRunTouchInjection] Not initialized, calling initialize...");
        if (![self initialize]) {
            NSLog(@"[KimiRunTouchInjection] Initialize failed!");
            return NO;
        }
    }
    
    CGFloat adjX = x;
    CGFloat adjY = y;
    AdjustInputCoordinates(&adjX, &adjY);
    NSLog(@"[KimiRunTouchInjection] Tap at (%.1f, %.1f), screen=%.0fx%.0f", adjX, adjY, g_screenWidth, g_screenHeight);

    // Direct IOHID dispatch: SimulateTouch-exact path, no BKS, no fallback.
    // Must run inside SpringBoard context to produce real UI movement.
    if ([lower isEqualToString:@"direct"]) {
        BOOL downOk = PostSimulateTouchEvent(KimiRunTouchPhaseDown, adjX, adjY);
        if (!downOk) {
            NSLog(@"[KimiRunTouchInjection] Direct tap down failed");
            return NO;
        }
        usleep(50000);
        BOOL upOk = PostSimulateTouchEvent(KimiRunTouchPhaseUp, adjX, adjY);
        if (!upOk) {
            NSLog(@"[KimiRunTouchInjection] Direct tap up failed");
            return NO;
        }
        NSLog(@"[KimiRunTouchInjection] Tap completed via direct IOHID");
        return YES;
    }

    // SimulateTouch-style IOHIDEvent injection
    BOOL ioHIDSuccess = NO;
    if (wantSim) {
        ioHIDSuccess = YES;
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseDown, adjX, adjY)) {
            NSLog(@"[KimiRunTouchInjection] SimulateTouch down failed");
            ioHIDSuccess = NO;
        }

        usleep(50000);

        if (ioHIDSuccess) {
            if (!PostSimulateTouchEvent(KimiRunTouchPhaseUp, adjX, adjY)) {
                NSLog(@"[KimiRunTouchInjection] SimulateTouch up failed");
                ioHIDSuccess = NO;
            }
        }
    }

    // Legacy path (hand+finger with explicit masks)
    BOOL legacySuccess = NO;
    if (wantLegacy) {
        legacySuccess = YES;
        if (!PostTouchEvent(KimiRunTouchPhaseDown, adjX, adjY)) {
            NSLog(@"[KimiRunTouchInjection] Legacy down failed");
            legacySuccess = NO;
        }
        usleep(50000);
        if (legacySuccess) {
            if (!PostTouchEvent(KimiRunTouchPhaseUp, adjX, adjY)) {
                NSLog(@"[KimiRunTouchInjection] Legacy up failed");
                legacySuccess = NO;
            }
        }
    }

    // Connection-based dispatch (experimental)
    BOOL connSuccess = NO;
    if (wantConn) {
        connSuccess = YES;
        if (!PostSimulateTouchEventViaConnection(KimiRunTouchPhaseDown, adjX, adjY)) {
            NSLog(@"[KimiRunTouchInjection] Connection down failed");
            connSuccess = NO;
        }
        usleep(50000);
        if (connSuccess) {
            if (!PostSimulateTouchEventViaConnection(KimiRunTouchPhaseUp, adjX, adjY)) {
                NSLog(@"[KimiRunTouchInjection] Connection up failed");
                connSuccess = NO;
            }
        }
    }
    BOOL anySuccess = (ioHIDSuccess || connSuccess || legacySuccess);
    
    // AX delivery first when explicitly requested.
    if (wantAX) {
        NSLog(@"[KimiRunTouchInjection] Trying AX (Accessibility) delivery...");
        [AXTouchInjection ensureAccessibilityEnabled];
        BOOL axSuccess = [AXTouchInjection tapAtPoint:CGPointMake(adjX, adjY)];
        if (axSuccess) {
            NSLog(@"[KimiRunTouchInjection] Tap completed via AX");
            return YES;
        }
        NSLog(@"[KimiRunTouchInjection] AX delivery failed");
    }

    // BKS delivery (optional or fallback)
    if ((wantBKS || (allowFallback && !anySuccess)) && g_bksSharedDeliveryManager) {
        NSLog(@"[KimiRunTouchInjection] Trying BKS delivery...");
        
        uint64_t timestamp = GetCurrentTimestamp();
        
        // Create and deliver touch down via BKS
        IOHIDEventRef downEvent = CreateBKSTouchEvent(timestamp, KimiRunTouchPhaseDown, adjX, adjY);
        if (downEvent) {
            BOOL bksDown = [self deliverViaBKS:downEvent];
            CFRelease(downEvent);
            
            if (bksDown) {
                usleep(50000);
                
                // Touch up via BKS
                IOHIDEventRef upEvent = CreateBKSTouchEvent(GetCurrentTimestamp(), KimiRunTouchPhaseUp, adjX, adjY);
                if (upEvent) {
                    BOOL bksUp = [self deliverViaBKS:upEvent];
                    CFRelease(upEvent);
                    
                    if (bksUp) {
                        NSLog(@"[KimiRunTouchInjection] Tap completed via BKS");
                        if (KimiRunRejectUnverifiedExplicitResult(lower, @"bks")) {
                            return NO;
                        }
                        return YES;
                    }
                }
            }
        }
        
        NSLog(@"[KimiRunTouchInjection] BKS delivery failed");
    }
    
    // ZXTouch delivery (optional or fallback)
    if ((wantZX || (allowFallback && !anySuccess)) && KimiRunZXTouchAvailable()) {
        NSLog(@"[KimiRunTouchInjection] Trying ZXTouch delivery...");
        if (KimiRunZXTouchTap(CGPointMake(adjX, adjY))) {
            NSLog(@"[KimiRunTouchInjection] Tap completed via ZXTouch");
            if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                return NO;
            }
            return YES;
        }
        NSLog(@"[KimiRunTouchInjection] ZXTouch delivery failed");
    }

    // AX delivery as fallback for auto/all when no prior path produced delivery.
    if (!wantAX && (allowFallback && !anySuccess)) {
        NSLog(@"[KimiRunTouchInjection] Trying AX (Accessibility) delivery...");
        [AXTouchInjection ensureAccessibilityEnabled];
        BOOL axSuccess = [AXTouchInjection tapAtPoint:CGPointMake(adjX, adjY)];
        if (axSuccess) {
            NSLog(@"[KimiRunTouchInjection] Tap completed via AX");
            return YES;
        }
        NSLog(@"[KimiRunTouchInjection] AX delivery failed");
    }
    
    if (ioHIDSuccess) {
        NSLog(@"[KimiRunTouchInjection] Tap completed via SimulateTouch IOHIDEvent");
        if (KimiRunRejectUnverifiedExplicitResult(lower, @"sim")) {
            return NO;
        }
        return YES;
    }
    if (connSuccess) {
        NSLog(@"[KimiRunTouchInjection] Tap completed via connection dispatch");
        if (KimiRunRejectUnverifiedExplicitResult(lower, @"connection")) {
            return NO;
        }
        return YES;
    }
    if (legacySuccess) {
        NSLog(@"[KimiRunTouchInjection] Tap completed via legacy path");
        if (KimiRunRejectUnverifiedExplicitResult(lower, @"legacy")) {
            return NO;
        }
        return YES;
    }
    
    return NO;
}

+ (BOOL)swipeFromX:(CGFloat)x1 Y:(CGFloat)y1 toX:(CGFloat)x2 Y:(CGFloat)y2 duration:(NSTimeInterval)duration {
    return [self swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:nil];
}

+ (BOOL)swipeFromX:(CGFloat)x1
                 Y:(CGFloat)y1
               toX:(CGFloat)x2
                 Y:(CGFloat)y2
          duration:(NSTimeInterval)duration
            method:(NSString *)method {
    NSString *lower = KimiRunResolveMethod(method);
    BOOL wantSim = ([lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"sim"] ||
                    [lower isEqualToString:@"iohid"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantLegacy = ([lower isEqualToString:@"legacy"] ||
                       [lower isEqualToString:@"old"] ||
                       [lower isEqualToString:@"all"]);
    BOOL wantConn = ([lower isEqualToString:@"conn"] ||
                     [lower isEqualToString:@"connection"] ||
                     [lower isEqualToString:@"all"]);
    BOOL wantBKS = ([lower isEqualToString:@"bks"] ||
                    [lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantAX = ([lower isEqualToString:@"ax"] ||
                   [lower isEqualToString:@"all"]);
    BOOL wantZX = ([lower isEqualToString:@"zx"] ||
                   [lower isEqualToString:@"zxtouch"] ||
                   [lower isEqualToString:@"all"]);
    BOOL allowFallback = ([lower isEqualToString:@"auto"] ||
                          [lower isEqualToString:@"all"]);

    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self swipeFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:lower];
        });
        return result;
    }

    if (!g_initialized) {
        if (![self initialize]) {
            return NO;
        }
    }

    // Use default duration if not specified
    if (duration <= 0) {
        duration = kDefaultSwipeDuration;
    }

    CGFloat ax1 = x1, ay1 = y1, ax2 = x2, ay2 = y2;
    AdjustInputCoordinates(&ax1, &ay1);
    AdjustInputCoordinates(&ax2, &ay2);
    CGPoint startPoint = CGPointMake(ax1, ay1);
    CGPoint endPoint = CGPointMake(ax2, ay2);
    int steps = (int)KimiRunGestureStepCount(startPoint, endPoint, kSwipeSteps);
    useconds_t stepDelay = KimiRunGestureStepDelayMicros(duration, steps);
    BOOL useSimpleCurve = KimiRunGestureUseSimpleCurve();
    double deltaPx = KimiRunGestureDeltaPixels();
    NSLog(@"[KimiRunTouchInjection] Swipe(%@) from (%.1f, %.1f) to (%.1f, %.1f) duration: %.2fs steps=%d interpolation=%@ deltaPx=%.2f",
          lower, ax1, ay1, ax2, ay2, duration, steps,
          useSimpleCurve ? @"simple_curve" : @"linear",
          deltaPx);

    if ([lower isEqualToString:@"ax"]) {
        [AXTouchInjection ensureAccessibilityEnabled];
        BOOL axSuccess = [AXTouchInjection swipeFromPoint:CGPointMake(ax1, ay1)
                                                  toPoint:CGPointMake(ax2, ay2)
                                                 duration:duration];
        if (axSuccess) {
            NSLog(@"[KimiRunTouchInjection] Swipe completed via AX accessibility scroll");
            return YES;
        }
        // Keep AX as preferred path, but do not hard-fail here.
        // Fallback to the existing phase dispatcher to preserve prior behavior.
        NSLog(@"[KimiRunTouchInjection] AX swipe delivery failed, falling back to phase dispatch");
    }

    if ([lower isEqualToString:@"direct"]) {
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseDown, ax1, ay1)) {
            NSLog(@"[KimiRunTouchInjection] Direct swipe down failed");
            return NO;
        }
        for (int i = 1; i <= steps; i++) {
            usleep(stepDelay);
            CGPoint movePoint = KimiRunGesturePointAtStep(startPoint, endPoint, i, steps, useSimpleCurve);
            if (!PostSimulateTouchEvent(KimiRunTouchPhaseMove, movePoint.x, movePoint.y)) {
                NSLog(@"[KimiRunTouchInjection] Direct swipe move failed at step %d", i);
                return NO;
            }
        }
        usleep(stepDelay);
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseUp, ax2, ay2)) {
            NSLog(@"[KimiRunTouchInjection] Direct swipe up failed");
            return NO;
        }
        NSLog(@"[KimiRunTouchInjection] Swipe completed via direct IOHID");
        return YES;
    }

    if (wantZX && !allowFallback) {
        BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                               CGPointMake(ax2, ay2),
                                               duration,
                                               steps);
        if (zxSuccess) {
            NSLog(@"[KimiRunTouchInjection] Swipe completed via ZXTouch");
            if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                return NO;
            }
        } else {
            NSLog(@"[KimiRunTouchInjection] ZXTouch swipe failed");
        }
        return zxSuccess;
    }

    if (!DispatchPhaseWithOptions(KimiRunTouchPhaseDown, ax1, ay1,
                                  wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
        if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
            BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                                   CGPointMake(ax2, ay2),
                                                   duration,
                                                   steps);
            if (zxSuccess) {
                NSLog(@"[KimiRunTouchInjection] Swipe completed via ZXTouch");
                if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                    return NO;
                }
            }
            return zxSuccess;
        }
        return NO;
    }

    for (int i = 1; i <= steps; i++) {
        usleep(stepDelay);
        CGPoint movePoint = KimiRunGesturePointAtStep(startPoint, endPoint, i, steps, useSimpleCurve);
        if (!DispatchPhaseWithOptions(KimiRunTouchPhaseMove, movePoint.x, movePoint.y,
                                      wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
            if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
                BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                                       CGPointMake(ax2, ay2),
                                                       duration,
                                                       steps);
                if (zxSuccess) {
                    NSLog(@"[KimiRunTouchInjection] Swipe completed via ZXTouch");
                    if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                        return NO;
                    }
                }
                return zxSuccess;
            }
            return NO;
        }
    }

    usleep(stepDelay);
    if (!DispatchPhaseWithOptions(KimiRunTouchPhaseUp, ax2, ay2,
                                  wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
        if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
            BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                                   CGPointMake(ax2, ay2),
                                                   duration,
                                                   steps);
            if (zxSuccess) {
                NSLog(@"[KimiRunTouchInjection] Swipe completed via ZXTouch");
                if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                    return NO;
                }
            }
            return zxSuccess;
        }
        return NO;
    }

    NSLog(@"[KimiRunTouchInjection] Swipe completed");
    if (KimiRunRejectUnverifiedExplicitResult(lower, @"dispatch")) {
        return NO;
    }
    return YES;
}

+ (BOOL)dragFromX:(CGFloat)x1 Y:(CGFloat)y1 toX:(CGFloat)x2 Y:(CGFloat)y2 duration:(NSTimeInterval)duration {
    return [self dragFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:nil];
}

+ (BOOL)dragFromX:(CGFloat)x1
                Y:(CGFloat)y1
              toX:(CGFloat)x2
                Y:(CGFloat)y2
         duration:(NSTimeInterval)duration
           method:(NSString *)method {
    NSString *lower = KimiRunResolveMethod(method);
    BOOL wantSim = ([lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"sim"] ||
                    [lower isEqualToString:@"iohid"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantLegacy = ([lower isEqualToString:@"legacy"] ||
                       [lower isEqualToString:@"old"] ||
                       [lower isEqualToString:@"all"]);
    BOOL wantConn = ([lower isEqualToString:@"conn"] ||
                     [lower isEqualToString:@"connection"] ||
                     [lower isEqualToString:@"all"]);
    BOOL wantBKS = ([lower isEqualToString:@"bks"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantAX = ([lower isEqualToString:@"ax"] ||
                   [lower isEqualToString:@"all"]);
    BOOL wantZX = ([lower isEqualToString:@"zx"] ||
                   [lower isEqualToString:@"zxtouch"] ||
                   [lower isEqualToString:@"all"]);
    BOOL allowFallback = ([lower isEqualToString:@"auto"] ||
                          [lower isEqualToString:@"all"]);

    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self dragFromX:x1 Y:y1 toX:x2 Y:y2 duration:duration method:lower];
        });
        return result;
    }

    if (!g_initialized) {
        if (![self initialize]) {
            return NO;
        }
    }

    if (duration <= 0) {
        duration = kDefaultDragDuration;
    }

    CGFloat ax1 = x1, ay1 = y1, ax2 = x2, ay2 = y2;
    AdjustInputCoordinates(&ax1, &ay1);
    AdjustInputCoordinates(&ax2, &ay2);
    CGPoint startPoint = CGPointMake(ax1, ay1);
    CGPoint endPoint = CGPointMake(ax2, ay2);
    int steps = (int)KimiRunGestureStepCount(startPoint, endPoint, kDragSteps);
    useconds_t stepDelay = KimiRunGestureStepDelayMicros(duration, steps);
    BOOL useSimpleCurve = KimiRunGestureUseSimpleCurve();
    double deltaPx = KimiRunGestureDeltaPixels();
    NSLog(@"[KimiRunTouchInjection] Drag(%@) from (%.1f, %.1f) to (%.1f, %.1f) duration: %.2fs steps=%d interpolation=%@ deltaPx=%.2f",
          lower, ax1, ay1, ax2, ay2, duration, steps,
          useSimpleCurve ? @"simple_curve" : @"linear",
          deltaPx);

    if ([lower isEqualToString:@"direct"]) {
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseDown, ax1, ay1)) {
            NSLog(@"[KimiRunTouchInjection] Direct drag down failed");
            return NO;
        }
        for (int i = 1; i <= steps; i++) {
            usleep(stepDelay);
            CGPoint movePoint = KimiRunGesturePointAtStep(startPoint, endPoint, i, steps, useSimpleCurve);
            if (!PostSimulateTouchEvent(KimiRunTouchPhaseMove, movePoint.x, movePoint.y)) {
                NSLog(@"[KimiRunTouchInjection] Direct drag move failed at step %d", i);
                return NO;
            }
        }
        usleep(stepDelay);
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseUp, ax2, ay2)) {
            NSLog(@"[KimiRunTouchInjection] Direct drag up failed");
            return NO;
        }
        NSLog(@"[KimiRunTouchInjection] Drag completed via direct IOHID");
        return YES;
    }

    if (wantZX && !allowFallback) {
        BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                               CGPointMake(ax2, ay2),
                                               duration,
                                               steps);
        if (zxSuccess) {
            NSLog(@"[KimiRunTouchInjection] Drag completed via ZXTouch");
            if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                return NO;
            }
        } else {
            NSLog(@"[KimiRunTouchInjection] ZXTouch drag failed");
        }
        return zxSuccess;
    }

    if (!DispatchPhaseWithOptions(KimiRunTouchPhaseDown, ax1, ay1,
                                  wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
        if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
            BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                                   CGPointMake(ax2, ay2),
                                                   duration,
                                                   steps);
            if (zxSuccess) {
                NSLog(@"[KimiRunTouchInjection] Drag completed via ZXTouch");
                if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                    return NO;
                }
            }
            return zxSuccess;
        }
        return NO;
    }

    for (int i = 1; i <= steps; i++) {
        usleep(stepDelay);
        CGPoint movePoint = KimiRunGesturePointAtStep(startPoint, endPoint, i, steps, useSimpleCurve);
        if (!DispatchPhaseWithOptions(KimiRunTouchPhaseMove, movePoint.x, movePoint.y,
                                      wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
            if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
                BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                                       CGPointMake(ax2, ay2),
                                                       duration,
                                                       steps);
                if (zxSuccess) {
                    NSLog(@"[KimiRunTouchInjection] Drag completed via ZXTouch");
                    if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                        return NO;
                    }
                }
                return zxSuccess;
            }
            return NO;
        }
    }

    usleep(stepDelay);
    if (!DispatchPhaseWithOptions(KimiRunTouchPhaseUp, ax2, ay2,
                                  wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
        if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
            BOOL zxSuccess = KimiRunZXTouchGesture(CGPointMake(ax1, ay1),
                                                   CGPointMake(ax2, ay2),
                                                   duration,
                                                   steps);
            if (zxSuccess) {
                NSLog(@"[KimiRunTouchInjection] Drag completed via ZXTouch");
                if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                    return NO;
                }
            }
            return zxSuccess;
        }
        return NO;
    }

    NSLog(@"[KimiRunTouchInjection] Drag completed");
    if (KimiRunRejectUnverifiedExplicitResult(lower, @"dispatch")) {
        return NO;
    }
    return YES;
}

+ (BOOL)longPressAtX:(CGFloat)x Y:(CGFloat)y duration:(NSTimeInterval)duration {
    return [self longPressAtX:x Y:y duration:duration method:nil];
}

+ (BOOL)longPressAtX:(CGFloat)x Y:(CGFloat)y duration:(NSTimeInterval)duration method:(NSString *)method {
    NSString *lower = KimiRunResolveMethod(method);
    BOOL wantSim = ([lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"sim"] ||
                    [lower isEqualToString:@"iohid"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantLegacy = ([lower isEqualToString:@"legacy"] ||
                       [lower isEqualToString:@"old"] ||
                       [lower isEqualToString:@"all"]);
    BOOL wantConn = ([lower isEqualToString:@"conn"] ||
                     [lower isEqualToString:@"connection"] ||
                     [lower isEqualToString:@"all"]);
    BOOL wantBKS = ([lower isEqualToString:@"bks"] ||
                    [lower isEqualToString:@"all"]);
    BOOL wantAX = ([lower isEqualToString:@"ax"] ||
                   [lower isEqualToString:@"all"]);
    BOOL wantZX = ([lower isEqualToString:@"zx"] ||
                   [lower isEqualToString:@"zxtouch"] ||
                   [lower isEqualToString:@"all"]);
    BOOL allowFallback = ([lower isEqualToString:@"auto"] ||
                          [lower isEqualToString:@"all"]);

    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self longPressAtX:x Y:y duration:duration method:lower];
        });
        return result;
    }

    if (!g_initialized) {
        if (![self initialize]) {
            return NO;
        }
    }

    if (duration <= 0) {
        duration = kDefaultLongPressDuration;
    }

    CGFloat adjX = x, adjY = y;
    AdjustInputCoordinates(&adjX, &adjY);
    NSLog(@"[KimiRunTouchInjection] Long press(%@) at (%.1f, %.1f) duration: %.2fs", lower, adjX, adjY, duration);

    if ([lower isEqualToString:@"direct"]) {
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseDown, adjX, adjY)) {
            NSLog(@"[KimiRunTouchInjection] Direct long press down failed");
            return NO;
        }
        usleep((useconds_t)(duration * 1000000.0));
        if (!PostSimulateTouchEvent(KimiRunTouchPhaseUp, adjX, adjY)) {
            NSLog(@"[KimiRunTouchInjection] Direct long press up failed");
            return NO;
        }
        NSLog(@"[KimiRunTouchInjection] Long press completed via direct IOHID");
        return YES;
    }

    if (wantZX && !allowFallback) {
        BOOL zxSuccess = KimiRunZXTouchLongPress(CGPointMake(adjX, adjY), duration);
        if (zxSuccess) {
            NSLog(@"[KimiRunTouchInjection] Long press completed via ZXTouch");
            if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                return NO;
            }
        } else {
            NSLog(@"[KimiRunTouchInjection] ZXTouch long press failed");
        }
        return zxSuccess;
    }

    if (!DispatchPhaseWithOptions(KimiRunTouchPhaseDown, adjX, adjY,
                                  wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
        if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
            BOOL zxSuccess = KimiRunZXTouchLongPress(CGPointMake(adjX, adjY), duration);
            if (zxSuccess) {
                NSLog(@"[KimiRunTouchInjection] Long press completed via ZXTouch");
                if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                    return NO;
                }
            }
            return zxSuccess;
        }
        return NO;
    }

    usleep((useconds_t)(duration * 1000000.0));

    if (!DispatchPhaseWithOptions(KimiRunTouchPhaseUp, adjX, adjY,
                                  wantSim, wantConn, wantLegacy, wantBKS, wantAX, allowFallback)) {
        if ((wantZX || allowFallback) && KimiRunZXTouchAvailable()) {
            BOOL zxSuccess = KimiRunZXTouchLongPress(CGPointMake(adjX, adjY), duration);
            if (zxSuccess) {
                NSLog(@"[KimiRunTouchInjection] Long press completed via ZXTouch");
                if (KimiRunRejectUnverifiedExplicitResult(lower, @"zxtouch")) {
                    return NO;
                }
            }
            return zxSuccess;
        }
        return NO;
    }

    NSLog(@"[KimiRunTouchInjection] Long press completed");
    if (KimiRunRejectUnverifiedExplicitResult(lower, @"dispatch")) {
        return NO;
    }
    return YES;
}

+ (BOOL)doubleTapAtX:(CGFloat)x Y:(CGFloat)y {
    return [self doubleTapAtX:x Y:y method:nil];
}

+ (BOOL)doubleTapAtX:(CGFloat)x Y:(CGFloat)y method:(NSString *)method {
    if (!g_initialized) {
        if (![self initialize]) {
            return NO;
        }
    }

    NSLog(@"[KimiRunTouchInjection] Double tap at (%.1f, %.1f)", x, y);

    if (![self tapAtX:x Y:y method:method]) {
        return NO;
    }

    usleep(100000);

    if (![self tapAtX:x Y:y method:method]) {
        return NO;
    }

    NSLog(@"[KimiRunTouchInjection] Double tap completed");
    return YES;
}
#pragma clang diagnostic pop

@end

#undef PostBKSTouchEventPhase
#undef PostLegacyTouchEventPhase
#undef PostSimulateTouchEventViaConnection
#undef PostSimulateTouchEvent
#undef PostTouchEvent
#undef CreateBKSTouchEvent
#undef CreateTouchEvent

#undef DispatchPhaseWithOptions
#undef KimiRunRejectUnverifiedExplicitResult
#undef KimiRunResolveMethod
#undef KimiRunPrefString
