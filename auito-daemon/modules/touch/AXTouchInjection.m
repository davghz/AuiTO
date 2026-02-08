//
//  AXTouchInjection.m
//  KimiRun - Accessibility-based Touch Injection
//
//  Uses AccessibilityUtilities framework as fallback
//

#import "AXTouchInjection.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "../accessibility/AccessibilityTree.h"

// AXEventRepresentation (Private API)
@interface AXEventRepresentation : NSObject
+ (id)touchRepresentationWithHandType:(int)handType location:(CGPoint)location;
@end

// AXBackBoardServer (Private API)
@interface AXBackBoardServer : NSObject
+ (instancetype)server;
- (void)postEvent:(id)event systemEvent:(BOOL)systemEvent;
@end

static void *LoadAXUtilities(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_NOW);
        if (!handle) {
            NSLog(@"[AXTouchInjection] Failed to load AccessibilityUtilities: %s", dlerror());
        }
    });
    return handle;
}

static id AXSettingsInstance(void) {
    Class cls = NSClassFromString(@"AXSettings");
    if (!cls) {
        return nil;
    }
    id inst = nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        inst = [cls performSelector:@selector(sharedInstance)];
    } else if ([cls respondsToSelector:@selector(sharedSettings)]) {
        inst = [cls performSelector:@selector(sharedSettings)];
    } else {
        inst = [[cls alloc] init];
    }
    return inst;
}

static BOOL AXBoolGetter(id obj, SEL sel, BOOL *outValue) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) {
        return NO;
    }
    BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
    if (outValue) {
        *outValue = value;
    }
    return YES;
}

static BOOL AXBoolSetter(id obj, SEL sel, BOOL value) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) {
        return NO;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, value);
    return YES;
}

static UIWindow *AXPreferredWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    NSMutableArray<UIWindow *> *candidates = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            BOOL fg = (windowScene.activationState == UISceneActivationStateForegroundActive ||
                       windowScene.activationState == UISceneActivationStateForegroundInactive);
            if (!fg) continue;
            for (UIWindow *window in windowScene.windows) {
                if (window && !window.hidden && window.alpha > 0.01f) {
                    [candidates addObject:window];
                }
            }
        }
    }
    if (candidates.count == 0) {
        for (UIWindow *window in app.windows) {
            if (window && !window.hidden && window.alpha > 0.01f) {
                [candidates addObject:window];
            }
        }
    }
    for (UIWindow *window in candidates) {
        if (window.isKeyWindow) return window;
    }
    return candidates.lastObject;
}

static UIScrollView *AXAncestorScrollView(UIView *view) {
    UIView *node = view;
    while (node) {
        if ([node isKindOfClass:[UIScrollView class]]) {
            return (UIScrollView *)node;
        }
        node = node.superview;
    }
    return nil;
}

static BOOL AXScrollViewSwipe(CGPoint startPoint, CGPoint endPoint, NSTimeInterval duration) {
    UIWindow *window = AXPreferredWindow();
    if (!window) return NO;

    CGPoint localStart = [window convertPoint:startPoint fromWindow:nil];
    UIView *hit = [window hitTest:localStart withEvent:nil];
    UIScrollView *scrollView = AXAncestorScrollView(hit);
    if (!scrollView) return NO;

    CGFloat dx = endPoint.x - startPoint.x;
    CGFloat dy = endPoint.y - startPoint.y;

    UIEdgeInsets inset = scrollView.contentInset;
    if (@available(iOS 11.0, *)) {
        inset = scrollView.adjustedContentInset;
    }

    CGPoint current = scrollView.contentOffset;
    CGPoint target = CGPointMake(current.x - dx, current.y - dy);

    CGFloat minX = -inset.left;
    CGFloat minY = -inset.top;
    CGFloat maxX = MAX(minX, scrollView.contentSize.width - scrollView.bounds.size.width + inset.right);
    CGFloat maxY = MAX(minY, scrollView.contentSize.height - scrollView.bounds.size.height + inset.bottom);

    if (target.x < minX) target.x = minX;
    if (target.x > maxX) target.x = maxX;
    if (target.y < minY) target.y = minY;
    if (target.y > maxY) target.y = maxY;

    if (fabs(target.x - current.x) < 0.5 && fabs(target.y - current.y) < 0.5) {
        return NO;
    }

    BOOL animated = duration > 0.05;
    [scrollView setContentOffset:target animated:animated];
    if (!animated) {
        [scrollView layoutIfNeeded];
    }
    return YES;
}

@implementation AXTouchInjection

+ (NSDictionary *)accessibilityStatus {
    LoadAXUtilities();
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    Class eventClass = NSClassFromString(@"AXEventRepresentation");
    Class serverClass = NSClassFromString(@"AXBackBoardServer");
    Class settingsClass = NSClassFromString(@"AXSettings");

    status[@"axEventRepresentation"] = eventClass ? @"present" : @"missing";
    status[@"axBackBoardServer"] = serverClass ? @"present" : @"missing";
    status[@"axSettings"] = settingsClass ? @"present" : @"missing";

    BOOL voiceOverRunning = UIAccessibilityIsVoiceOverRunning();
    BOOL switchControlRunning = UIAccessibilityIsSwitchControlRunning();
    status[@"voiceOverRunning"] = @(voiceOverRunning);
    status[@"switchControlRunning"] = @(switchControlRunning);

    id settings = AXSettingsInstance();
    BOOL voEnabled = NO;
    BOOL accEnabled = NO;
    BOOL assistiveTouchEnabled = NO;
    if (settings) {
        AXBoolGetter(settings, NSSelectorFromString(@"voiceOverTouchEnabled"), &voEnabled);
        AXBoolGetter(settings, NSSelectorFromString(@"accessibilityEnabled"), &accEnabled);
        AXBoolGetter(settings, NSSelectorFromString(@"assistiveTouchEnabled"), &assistiveTouchEnabled);
    }
    status[@"voiceOverTouchEnabled"] = @(voEnabled);
    status[@"accessibilityEnabled"] = @(accEnabled);
    status[@"assistiveTouchEnabled"] = @(assistiveTouchEnabled);
    return status;
}

+ (NSDictionary *)ensureAccessibilityEnabled {
    LoadAXUtilities();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    id settings = AXSettingsInstance();
    BOOL changed = NO;
    if (settings) {
        if (AXBoolSetter(settings, NSSelectorFromString(@"setAccessibilityEnabled:"), YES)) {
            changed = YES;
        }
        if (AXBoolSetter(settings, NSSelectorFromString(@"setVoiceOverTouchEnabled:"), YES)) {
            changed = YES;
        }
        if (AXBoolSetter(settings, NSSelectorFromString(@"setAssistiveTouchEnabled:"), YES)) {
            changed = YES;
        }
    }
    result[@"changed"] = @(changed);
    result[@"status"] = [self accessibilityStatus] ?: @{};
    return result;
}

+ (BOOL)tapAtPoint:(CGPoint)point {
    @try {
        // Load AccessibilityUtilities + try enabling AX services
        LoadAXUtilities();
        [self ensureAccessibilityEnabled];

        // Prefer direct accessibility activation at point when available.
        if ([AccessibilityTree activateElementAtPoint:point]) {
            NSLog(@"[AXTouchInjection] Tap activated element at (%.1f, %.1f)", point.x, point.y);
            return YES;
        }
        
        // Get AXEventRepresentation class
        Class AXEventRepClass = NSClassFromString(@"AXEventRepresentation");
        if (!AXEventRepClass) {
            NSLog(@"[AXTouchInjection] AXEventRepresentation not found");
            return NO;
        }

        // Create touch event (handType 2 = finger) using typed objc_msgSend.
        SEL createSel = NSSelectorFromString(@"touchRepresentationWithHandType:location:");
        if (![AXEventRepClass respondsToSelector:createSel]) {
            NSLog(@"[AXTouchInjection] Missing selector %@", NSStringFromSelector(createSel));
            return NO;
        }
        id (*CreateEventRepresentation)(id, SEL, int, CGPoint) = (id (*)(id, SEL, int, CGPoint))objc_msgSend;
        id event = CreateEventRepresentation(AXEventRepClass, createSel, 2, point);
        if (!event) {
            NSLog(@"[AXTouchInjection] Failed to create event");
            return NO;
        }
        
        // Get AXBackBoardServer
        Class AXServerClass = NSClassFromString(@"AXBackBoardServer");
        if (!AXServerClass) {
            NSLog(@"[AXTouchInjection] AXBackBoardServer not found");
            return NO;
        }
        
        id server = [AXServerClass performSelector:@selector(server)];
        if (!server) {
            NSLog(@"[AXTouchInjection] Failed to get server");
            return NO;
        }

        SEL postSel = NSSelectorFromString(@"postEvent:systemEvent:");
        if (![server respondsToSelector:postSel]) {
            NSLog(@"[AXTouchInjection] Missing selector %@", NSStringFromSelector(postSel));
            return NO;
        }
        void (*PostEvent)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
        PostEvent(server, postSel, event, YES);
        
        NSLog(@"[AXTouchInjection] Tap posted at (%.1f, %.1f)", point.x, point.y);
        return YES;
        
    } @catch (NSException *e) {
        NSLog(@"[AXTouchInjection] Exception: %@", e);
        return NO;
    }
}

+ (BOOL)swipeFromPoint:(CGPoint)startPoint
               toPoint:(CGPoint)endPoint
              duration:(NSTimeInterval)duration {
    @try {
        LoadAXUtilities();
        [self ensureAccessibilityEnabled];

        // Primary AX swipe path: perform real scrolling on the target UIScrollView.
        if (AXScrollViewSwipe(startPoint, endPoint, duration)) {
            NSLog(@"[AXTouchInjection] Swipe via UIScrollView contentOffset from (%.1f, %.1f) to (%.1f, %.1f)",
                  startPoint.x, startPoint.y, endPoint.x, endPoint.y);
            return YES;
        }

        CGFloat dx = endPoint.x - startPoint.x;
        CGFloat dy = endPoint.y - startPoint.y;
        UIAccessibilityScrollDirection direction = UIAccessibilityScrollDirectionDown;

        if (fabs(dx) > fabs(dy)) {
            direction = (dx > 0) ? UIAccessibilityScrollDirectionRight : UIAccessibilityScrollDirectionLeft;
        } else {
            // Finger swiping up usually means content scrolls down.
            direction = (dy < 0) ? UIAccessibilityScrollDirectionDown : UIAccessibilityScrollDirectionUp;
        }

        BOOL ok = NO;
        // AXRuntime path can control foreground app elements even from SpringBoard process.
        ok = [AccessibilityTree scrollAtPoint:startPoint direction:(NSInteger)direction];
        if (!ok && direction == UIAccessibilityScrollDirectionDown) {
            ok = [AccessibilityTree scrollAtPoint:startPoint direction:(NSInteger)UIAccessibilityScrollDirectionUp];
        } else if (!ok && direction == UIAccessibilityScrollDirectionUp) {
            ok = [AccessibilityTree scrollAtPoint:startPoint direction:(NSInteger)UIAccessibilityScrollDirectionDown];
        }

        UIApplication *app = [UIApplication sharedApplication];
        SEL scrollSel = NSSelectorFromString(@"_accessibilityScrollWithDirection:");
        if (!ok && app && [app respondsToSelector:scrollSel]) {
            BOOL (*msgSend)(id, SEL, NSInteger) = (BOOL (*)(id, SEL, NSInteger))objc_msgSend;
            ok = msgSend(app, scrollSel, (NSInteger)direction);
        }
        if (!ok) {
            SEL altSel = NSSelectorFromString(@"accessibilityScroll:");
            if (app && [app respondsToSelector:altSel]) {
                BOOL (*msgSendAlt)(id, SEL, NSInteger) = (BOOL (*)(id, SEL, NSInteger))objc_msgSend;
                ok = msgSendAlt(app, altSel, (NSInteger)direction);
            }
        }
        if (!ok) {
            // Try opposite vertical direction once for framework behavior variance.
            if (direction == UIAccessibilityScrollDirectionDown) {
                if (app && [app respondsToSelector:scrollSel]) {
                    BOOL (*msgSend)(id, SEL, NSInteger) = (BOOL (*)(id, SEL, NSInteger))objc_msgSend;
                    ok = msgSend(app, scrollSel, (NSInteger)UIAccessibilityScrollDirectionUp);
                }
            } else if (direction == UIAccessibilityScrollDirectionUp) {
                if (app && [app respondsToSelector:scrollSel]) {
                    BOOL (*msgSend)(id, SEL, NSInteger) = (BOOL (*)(id, SEL, NSInteger))objc_msgSend;
                    ok = msgSend(app, scrollSel, (NSInteger)UIAccessibilityScrollDirectionDown);
                }
            }
        }

        NSLog(@"[AXTouchInjection] Swipe via accessibility scroll dir=%ld success=%@ duration=%.2f",
              (long)direction, ok ? @"YES" : @"NO", duration);
        return ok;
    } @catch (NSException *e) {
        NSLog(@"[AXTouchInjection] Swipe exception: %@", e);
        return NO;
    }
}

@end
