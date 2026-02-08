/**
 * AccessibilityTree.m - UI hierarchy traversal implementation
 */

#import "AccessibilityTree.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Interactive element types we care about
static NSSet<NSString *> *interactiveTraits = nil;
static NSDictionary *cachedFullTree = nil;
static NSTimeInterval cachedFullTreeAt = 0;
static NSArray *cachedInteractive = nil;
static NSTimeInterval cachedInteractiveAt = 0;
static const NSTimeInterval kTreeCacheTTL = 0.25;
static const NSTimeInterval kInteractiveCacheTTL = 0.5;
static const NSUInteger kAXMaxElements = 500;
static const NSUInteger kOverlayMaxElements = 200;
static UIWindow *overlayWindow = nil;
static CAShapeLayer *overlayLayer = nil;
static NSMutableArray<CATextLayer *> *overlayTextLayers = nil;
static BOOL overlayEnabled = NO;
static BOOL overlayInteractiveOnly = YES;
static BOOL overlayRefreshing = NO;
static NSMutableArray *lastInteractiveElements = nil;

static BOOL IOSRunClassNameContainsAny(NSString *className, NSArray<NSString *> *needles) {
    if (className.length == 0) return NO;
    NSString *lower = [className lowercaseString];
    for (NSString *needle in needles) {
        if ([lower containsString:[needle lowercaseString]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL IOSRunWindowLooksOverlay(UIWindow *window) {
    if (!window) return YES;
    NSString *windowClass = NSStringFromClass([window class]) ?: @"";
    NSString *rootVCClass = window.rootViewController ? (NSStringFromClass([window.rootViewController class]) ?: @"") : @"";
    NSArray<NSString *> *overlayHints = @[@"homegrabber", @"statusbar", @"overlay", @"keyboard", @"assistive", @"banner", @"hud", @"dock"];
    if (IOSRunClassNameContainsAny(windowClass, overlayHints) || IOSRunClassNameContainsAny(rootVCClass, overlayHints)) {
        return YES;
    }
    if (fabs(window.windowLevel) > 10.0) {
        return YES;
    }
    return NO;
}

static BOOL IOSRunWindowLikelyContent(UIWindow *window) {
    if (!window) return NO;
    if (window.hidden || window.alpha < 0.01f) return NO;
    if (IOSRunWindowLooksOverlay(window)) return NO;
    CGRect bounds = window.bounds;
    if (CGRectIsEmpty(bounds)) return NO;
    if (bounds.size.width < 100.0 || bounds.size.height < 100.0) return NO;
    return YES;
}

static BOOL IOSRunElementDictLooksOverlayOnly(NSDictionary *element) {
    if (![element isKindOfClass:[NSDictionary class]]) return YES;
    NSString *className = [element[@"className"] isKindOfClass:[NSString class]] ? element[@"className"] : @"";
    NSString *label = [element[@"label"] isKindOfClass:[NSString class]] ? element[@"label"] : @"";
    NSString *identifier = [element[@"identifier"] isKindOfClass:[NSString class]] ? element[@"identifier"] : @"";
    NSString *type = [element[@"type"] isKindOfClass:[NSString class]] ? element[@"type"] : @"";
    if (IOSRunClassNameContainsAny(className, @[@"homegrabber", @"statusbar", @"overlay", @"keyboard", @"dock", @"assistive"])) {
        return YES;
    }
    if (label.length == 0 && identifier.length == 0 && [type isEqualToString:@"Other"]) {
        return YES;
    }
    return NO;
}

static BOOL IOSRunElementsNeedAXFallback(NSArray<NSDictionary *> *elements) {
    if (elements.count == 0) return YES;
    NSUInteger useful = 0;
    for (NSDictionary *element in elements) {
        if (!IOSRunElementDictLooksOverlayOnly(element)) {
            useful++;
        }
    }
    return useful == 0;
}

static NSArray<UIWindow *> *IOSRunActiveWindows(void) {
    NSMutableArray<UIWindow *> *foregroundWindows = [NSMutableArray array];
    NSMutableArray<UIWindow *> *fallbackWindows = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return @[];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            BOOL isForeground = (windowScene.activationState == UISceneActivationStateForegroundActive ||
                                 windowScene.activationState == UISceneActivationStateForegroundInactive);
            for (UIWindow *window in windowScene.windows) {
                if (!window) continue;
                [fallbackWindows addObject:window];
                if (isForeground) {
                    [foregroundWindows addObject:window];
                }
            }
        }
    }

    if (fallbackWindows.count == 0) {
        [fallbackWindows addObjectsFromArray:app.windows ?: @[]];
    }
    if (foregroundWindows.count == 0) {
        [foregroundWindows addObjectsFromArray:fallbackWindows];
    }

    UIWindow *keyWindow = nil;
    if ([app respondsToSelector:@selector(keyWindow)]) {
        UIWindow *(*msgSend)(id, SEL) = (UIWindow *(*)(id, SEL))objc_msgSend;
        keyWindow = msgSend(app, @selector(keyWindow));
    }
    if (keyWindow && ![foregroundWindows containsObject:keyWindow]) {
        [foregroundWindows addObject:keyWindow];
    }

    // De-duplicate by pointer identity
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSHashTableObjectPointerPersonality];
    NSMutableArray<UIWindow *> *unique = [NSMutableArray array];
    for (UIWindow *window in foregroundWindows) {
        if (!window) continue;
        if (window.hidden || window.alpha < 0.01f) continue;
        if ([seen containsObject:window]) continue;
        [seen addObject:window];
        [unique addObject:window];
    }

    return unique;
}

static UIWindow *IOSRunPreferredWindow(void) {
    NSArray<UIWindow *> *windows = IOSRunActiveWindows();
    if (windows.count == 0) return nil;

    for (UIWindow *window in windows) {
        if (window.isKeyWindow && IOSRunWindowLikelyContent(window)) {
            return window;
        }
    }

    UIWindow *bestNormal = nil;
    CGFloat bestNormalScore = -CGFLOAT_MAX;
    UIWindow *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIWindow *window in windows) {
        if (!window) continue;
        CGRect bounds = window.bounds;
        CGFloat area = bounds.size.width * bounds.size.height;
        NSUInteger subviewCount = window.subviews.count;
        CGFloat score = area + (CGFloat)subviewCount * 1000.0 - fabs(window.windowLevel) * 10000.0;
        if (IOSRunWindowLooksOverlay(window)) {
            score -= 1000000.0;
        }
        BOOL likelyContentWindow = (window.windowLevel >= -0.5 && window.windowLevel <= 1.5);
        if (IOSRunWindowLooksOverlay(window)) {
            likelyContentWindow = NO;
        }
        if (likelyContentWindow && score > bestNormalScore) {
            bestNormal = window;
            bestNormalScore = score;
        }
        if (!best || score > bestScore) {
            best = window;
            bestScore = score;
        }
    }
    return bestNormal ?: best ?: windows.lastObject;
}

static CGPoint IOSRunPreferredProbePoint(void) {
    UIWindow *window = IOSRunPreferredWindow();
    if (window) {
        CGPoint localCenter = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
        CGPoint globalCenter = [window convertPoint:localCenter toWindow:nil];
        if (!isnan(globalCenter.x) && !isnan(globalCenter.y) && isfinite(globalCenter.x) && isfinite(globalCenter.y)) {
            return globalCenter;
        }
    }
    CGRect bounds = [UIScreen mainScreen].bounds;
    return CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
}

static UITableViewCell *IOSRunFindTableCell(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            return (UITableViewCell *)v;
        }
        v = v.superview;
    }
    return nil;
}

static UITableView *IOSRunFindTableView(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UITableView class]]) {
            return (UITableView *)v;
        }
        v = v.superview;
    }
    return nil;
}

static UICollectionViewCell *IOSRunFindCollectionCell(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UICollectionViewCell class]]) {
            return (UICollectionViewCell *)v;
        }
        v = v.superview;
    }
    return nil;
}

static UICollectionView *IOSRunFindCollectionView(UIView *view) {
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:[UICollectionView class]]) {
            return (UICollectionView *)v;
        }
        v = v.superview;
    }
    return nil;
}

static BOOL IOSRunActivateView(UIView *view) {
    if (!view) return NO;

    if ([view respondsToSelector:@selector(accessibilityActivate)]) {
        BOOL (*msgSend)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        if (msgSend(view, @selector(accessibilityActivate))) {
            return YES;
        }
    }

    if ([view isKindOfClass:[UIControl class]]) {
        [(UIControl *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }

    UITableViewCell *cell = IOSRunFindTableCell(view);
    if (cell) {
        UITableView *table = IOSRunFindTableView(cell);
        if (table) {
            NSIndexPath *indexPath = [table indexPathForCell:cell];
            if (indexPath) {
                [table selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
                id<UITableViewDelegate> delegate = table.delegate;
                if ([delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                    [delegate tableView:table didSelectRowAtIndexPath:indexPath];
                }
                return YES;
            }
        }
    }

    UICollectionViewCell *cCell = IOSRunFindCollectionCell(view);
    if (cCell) {
        UICollectionView *collection = IOSRunFindCollectionView(cCell);
        if (collection) {
            NSIndexPath *indexPath = [collection indexPathForCell:cCell];
            if (indexPath) {
                [collection selectItemAtIndexPath:indexPath animated:YES scrollPosition:UICollectionViewScrollPositionNone];
                id<UICollectionViewDelegate> delegate = collection.delegate;
                if ([delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                    [delegate collectionView:collection didSelectItemAtIndexPath:indexPath];
                }
                return YES;
            }
        }
    }

    return NO;
}

static BOOL IOSRunActivateElement(id element) {
    if (!element) return NO;

    if ([element respondsToSelector:@selector(accessibilityActivate)]) {
        BOOL (*msgSend)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        if (msgSend(element, @selector(accessibilityActivate))) {
            return YES;
        }
    }

    if ([element isKindOfClass:[UIView class]]) {
        return IOSRunActivateView((UIView *)element);
    }

    return NO;
}

static BOOL IOSRunTryScrollElement(id element, NSInteger direction) {
    if (!element) return NO;

    SEL scrollSel = NSSelectorFromString(@"accessibilityScroll:");
    if ([element respondsToSelector:scrollSel]) {
        BOOL (*msgSend)(id, SEL, NSInteger) = (BOOL (*)(id, SEL, NSInteger))objc_msgSend;
        if (msgSend(element, scrollSel, direction)) {
            return YES;
        }
    }

    SEL privateScrollSel = NSSelectorFromString(@"_accessibilityScrollWithDirection:");
    if ([element respondsToSelector:privateScrollSel]) {
        BOOL (*msgSendPrivate)(id, SEL, NSInteger) = (BOOL (*)(id, SEL, NSInteger))objc_msgSend;
        if (msgSendPrivate(element, privateScrollSel, direction)) {
            return YES;
        }
    }

    return NO;
}

static CGRect IOSRunAXRect(id element, SEL selector) {
    if (!element || !selector) return CGRectZero;
    if (![element respondsToSelector:selector]) return CGRectZero;
    CGRect (*msgSend)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    return msgSend(element, selector);
}

static CGPoint IOSRunAXPoint(id element, SEL selector) {
    if (!element || !selector) return CGPointZero;
    if (![element respondsToSelector:selector]) return CGPointZero;
    CGPoint (*msgSend)(id, SEL) = (CGPoint (*)(id, SEL))objc_msgSend;
    return msgSend(element, selector);
}

static id IOSRunAXUIElementAtPoint(CGPoint point) {
    Class AXUIElementClass = NSClassFromString(@"AXUIElement");
    if (!AXUIElementClass) return nil;
    SEL sel = @selector(uiApplicationAtCoordinate:);
    if (![AXUIElementClass respondsToSelector:sel]) return nil;
    id (*msgSend)(id, SEL, CGPoint) = (id (*)(id, SEL, CGPoint))objc_msgSend;
    return msgSend(AXUIElementClass, sel, point);
}

static NSUInteger IOSRunAXUnsigned(id element, SEL selector) {
    if (!element || !selector) return 0;
    if (![element respondsToSelector:selector]) return 0;
    NSUInteger (*msgSend)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
    return msgSend(element, selector);
}

static NSString *IOSRunAXString(id element, SEL selector) {
    if (!element || !selector) return @"";
    if (![element respondsToSelector:selector]) return @"";
    NSString *(*msgSend)(id, SEL) = (NSString *(*)(id, SEL))objc_msgSend;
    return msgSend(element, selector) ?: @"";
}

static BOOL IOSRunAXBool(id element, SEL selector) {
    if (!element || !selector) return NO;
    if (![element respondsToSelector:selector]) return NO;
    BOOL (*msgSend)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    return msgSend(element, selector);
}

static id IOSRunAXElementFromPoint(CGPoint point) {
    Class AXUIElementClass = NSClassFromString(@"AXUIElement");
    Class AXElementClass = NSClassFromString(@"AXElement");
    if (!AXUIElementClass || !AXElementClass) return nil;
    SEL sel = @selector(uiElementAtCoordinate:);
    if (![AXUIElementClass respondsToSelector:sel]) return nil;
    id (*msgSendPoint)(id, SEL, CGPoint) = (id (*)(id, SEL, CGPoint))objc_msgSend;
    id uiElem = msgSendPoint(AXUIElementClass, sel, point);
    if (!uiElem) return nil;
    if ([AXElementClass respondsToSelector:@selector(elementWithUIElement:)]) {
        return [AXElementClass performSelector:@selector(elementWithUIElement:) withObject:uiElem];
    }
    return nil;
}

static CGRect IOSRunRectFromDict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return CGRectZero;
    CGFloat x = [dict[@"x"] doubleValue];
    CGFloat y = [dict[@"y"] doubleValue];
    CGFloat w = [dict[@"width"] doubleValue];
    CGFloat h = [dict[@"height"] doubleValue];
    return CGRectMake(x, y, w, h);
}

@implementation AccessibilityTree

static BOOL IOSRunIsInteractiveAccessibilityElement(UIAccessibilityElement *element) {
    if (!element) return NO;
    if (element.accessibilityTraits != UIAccessibilityTraitNone) return YES;
    if (element.accessibilityLabel.length > 0) return YES;
    if (element.accessibilityIdentifier.length > 0) return YES;
    if (element.accessibilityValue.length > 0) return YES;
    if (element.accessibilityHint.length > 0) return YES;
    return NO;
}

static BOOL IOSRunIsInteractiveGenericElement(id element) {
    if (!element) return NO;
    NSString *label = IOSRunAXString(element, @selector(accessibilityLabel));
    NSString *identifier = IOSRunAXString(element, @selector(accessibilityIdentifier));
    NSString *value = IOSRunAXString(element, @selector(accessibilityValue));
    NSString *hint = IOSRunAXString(element, @selector(accessibilityHint));
    NSUInteger traits = IOSRunAXUnsigned(element, @selector(accessibilityTraits));
    if (label.length || identifier.length || value.length || hint.length) return YES;
    if (traits != UIAccessibilityTraitNone) return YES;
    return NO;
}

static NSDictionary *IOSRunDictForGenericElement(id element) {
    if (!element) return nil;
    CGRect frame = IOSRunAXRect(element, @selector(accessibilityFrame));
    NSString *label = IOSRunAXString(element, @selector(accessibilityLabel));
    NSString *identifier = IOSRunAXString(element, @selector(accessibilityIdentifier));
    NSString *value = IOSRunAXString(element, @selector(accessibilityValue));
    NSString *hint = IOSRunAXString(element, @selector(accessibilityHint));
    NSUInteger traits = IOSRunAXUnsigned(element, @selector(accessibilityTraits));

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"type"] = @"Other";
    dict[@"className"] = NSStringFromClass([element class]);
    dict[@"label"] = label ?: @"";
    dict[@"identifier"] = identifier ?: @"";
    dict[@"value"] = value ?: @"";
    dict[@"hint"] = hint ?: @"";
    dict[@"traits"] = [AccessibilityTree traitsToArray:traits];
    dict[@"bounds"] = [AccessibilityTree rectToDict:frame];
    dict[@"rect"] = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                     frame.origin.x, frame.origin.y,
                     frame.size.width, frame.size.height];
    dict[@"center_x"] = @(CGRectGetMidX(frame));
    dict[@"center_y"] = @(CGRectGetMidY(frame));
    dict[@"enabled"] = @YES;
    dict[@"visible"] = @YES;
    return dict;
}

static NSDictionary *IOSRunDictForAXElement(id element) {
    if (!element) return nil;
    CGRect frame = IOSRunAXRect(element, @selector(frame));
    CGPoint center = IOSRunAXPoint(element, @selector(centerPoint));
    NSString *label = IOSRunAXString(element, @selector(label));
    NSString *identifier = IOSRunAXString(element, @selector(identifier));
    NSString *value = IOSRunAXString(element, @selector(value));
    NSString *hint = IOSRunAXString(element, @selector(hint));
    NSString *processName = IOSRunAXString(element, @selector(processName));
    NSString *bundleId = IOSRunAXString(element, @selector(bundleId));
    NSUInteger traits = IOSRunAXUnsigned(element, @selector(traits));
    BOOL visible = IOSRunAXBool(element, @selector(isVisible));

    return @{
        @"type": @"AXElement",
        @"className": @"AXElement",
        @"label": label ?: @"",
        @"identifier": identifier ?: @"",
        @"value": value ?: @"",
        @"hint": hint ?: @"",
        @"traits": @(traits),
        @"bounds": @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"width": @(frame.size.width),
            @"height": @(frame.size.height)
        },
        @"rect": [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                  frame.origin.x, frame.origin.y,
                  frame.size.width, frame.size.height],
        @"center_x": @(center.x),
        @"center_y": @(center.y),
        @"enabled": @YES,
        @"visible": @(visible),
        @"processName": processName ?: @"",
        @"bundleID": bundleId ?: @""
    };
}

static BOOL IOSRunAXElementIsInteractive(id element) {
    if (!element) return NO;
    NSString *label = IOSRunAXString(element, @selector(label));
    NSString *identifier = IOSRunAXString(element, @selector(identifier));
    NSString *value = IOSRunAXString(element, @selector(value));
    NSString *hint = IOSRunAXString(element, @selector(hint));
    NSUInteger traits = IOSRunAXUnsigned(element, @selector(traits));
    if (label.length || identifier.length || value.length || hint.length) return YES;
    if (traits != 0) return YES;
    return NO;
}

static void IOSRunAXCollectFromElement(id element,
                                       NSMutableSet<NSValue *> *visited,
                                       NSMutableArray<NSDictionary *> *out,
                                       NSUInteger *count) {
    if (!element || !visited || !out || !count) return;
    if (*count >= kAXMaxElements) return;

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)(element)];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    if (IOSRunAXElementIsInteractive(element)) {
        NSDictionary *dict = IOSRunDictForAXElement(element);
        if (dict) {
            NSMutableDictionary *mutable = [dict mutableCopy];
            mutable[@"index"] = @(*count);
            [out addObject:mutable];
            (*count)++;
            if (*count >= kAXMaxElements) return;
        }
    }

    if ([element respondsToSelector:@selector(children)]) {
        NSArray *children = [element performSelector:@selector(children)];
        for (id child in children ?: @[]) {
            IOSRunAXCollectFromElement(child, visited, out, count);
            if (*count >= kAXMaxElements) return;
        }
    }
}

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        interactiveTraits = [NSSet setWithArray:@[
            @"Button", @"Link", @"SearchField", @"TextField", @"SecureTextField",
            @"TextArea", @"Switch", @"Slider", @"Stepper", @"Picker",
            @"DatePicker", @"PageIndicator", @"Tab", @"Cell", @"MenuItem"
        ]];
        NSLog(@"[KimiRunA11y] AccessibilityTree initialized");
    });
}

+ (void)ensureOverlayWindow {
    if (overlayWindow) return;
    overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    overlayWindow.windowLevel = UIWindowLevelStatusBar + 1000;
    overlayWindow.backgroundColor = [UIColor clearColor];
    overlayWindow.userInteractionEnabled = NO;
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    overlayWindow.rootViewController = vc;
    overlayWindow.hidden = NO;
}

+ (void)teardownOverlay {
    if (overlayWindow) {
        overlayWindow.hidden = YES;
        overlayWindow.rootViewController = nil;
        overlayWindow = nil;
    }
    overlayLayer = nil;
    overlayTextLayers = nil;
}

+ (void)refreshOverlayWithElements:(NSArray<NSDictionary *> *)elements {
    if (!overlayEnabled || overlayRefreshing) return;
    overlayRefreshing = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!overlayEnabled) {
            overlayRefreshing = NO;
            return;
        }
        [self ensureOverlayWindow];
        if (!overlayLayer) {
            overlayLayer = [CAShapeLayer layer];
            overlayLayer.strokeColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.9].CGColor;
            overlayLayer.fillColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.08].CGColor;
            overlayLayer.lineWidth = 1.0;
            [overlayWindow.rootViewController.view.layer addSublayer:overlayLayer];
        }

        for (CATextLayer *layer in overlayTextLayers ?: @[]) {
            [layer removeFromSuperlayer];
        }
        overlayTextLayers = [NSMutableArray array];

        UIBezierPath *path = [UIBezierPath bezierPath];
        NSUInteger count = 0;
        for (NSDictionary *elem in elements ?: @[]) {
            NSDictionary *bounds = elem[@"bounds"];
            CGRect rect = IOSRunRectFromDict(bounds);
            if (CGRectIsEmpty(rect)) continue;
            [path appendPath:[UIBezierPath bezierPathWithRect:rect]];

            NSString *label = elem[@"label"];
            if (label.length > 0 && count < 30) {
                CATextLayer *textLayer = [CATextLayer layer];
                textLayer.string = label;
                textLayer.fontSize = 10.0;
                textLayer.foregroundColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.9].CGColor;
                textLayer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3].CGColor;
                textLayer.contentsScale = [UIScreen mainScreen].scale;
                CGFloat textX = rect.origin.x + 2;
                CGFloat textY = rect.origin.y + 2;
                textLayer.frame = CGRectMake(textX, textY, MIN(rect.size.width, 200), 14);
                [overlayWindow.rootViewController.view.layer addSublayer:textLayer];
                [overlayTextLayers addObject:textLayer];
            }

            count++;
            if (count >= kOverlayMaxElements) break;
        }
        overlayLayer.path = path.CGPath;
        overlayWindow.hidden = NO;
        overlayRefreshing = NO;
    });
}

+ (void)setOverlayEnabled:(BOOL)enabled interactiveOnly:(BOOL)interactiveOnly {
    overlayEnabled = enabled;
    overlayInteractiveOnly = interactiveOnly;
    if (!enabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self teardownOverlay];
        });
        return;
    }

    NSArray *elements = [self getInteractiveElements];
    [self refreshOverlayWithElements:elements];
}

+ (BOOL)isOverlayEnabled {
    return overlayEnabled;
}

+ (NSDictionary *)debugInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    Class AXElementClass = NSClassFromString(@"AXElement");
    Class AXUIElementClass = NSClassFromString(@"AXUIElement");
    info[@"AXElementClass"] = AXElementClass ? @"YES" : @"NO";
    info[@"AXUIElementClass"] = AXUIElementClass ? @"YES" : @"NO";

    id app = nil;
    if (AXElementClass && [AXElementClass respondsToSelector:@selector(primaryApp)]) {
        app = [AXElementClass performSelector:@selector(primaryApp)];
    }
    info[@"primaryAppExists"] = app ? @"YES" : @"NO";
    if (app) {
        info[@"primaryAppBundleID"] = IOSRunAXString(app, @selector(bundleId));
        info[@"primaryAppProcessName"] = IOSRunAXString(app, @selector(processName));
    }

    id system = nil;
    if (AXElementClass && [AXElementClass respondsToSelector:@selector(systemWideElement)]) {
        system = [AXElementClass performSelector:@selector(systemWideElement)];
    }
    info[@"systemWideExists"] = system ? @"YES" : @"NO";

    CGPoint center = IOSRunPreferredProbePoint();
    id uiApp = IOSRunAXUIElementAtPoint(center);
    info[@"uiAppAtCenter"] = uiApp ? @"YES" : @"NO";
    info[@"probePoint"] = @{
        @"x": @(center.x),
        @"y": @(center.y),
    };
    if (uiApp && AXElementClass && [AXElementClass respondsToSelector:@selector(elementWithUIElement:)]) {
        id elem = [AXElementClass performSelector:@selector(elementWithUIElement:) withObject:uiApp];
        info[@"uiAppElementBundleID"] = IOSRunAXString(elem, @selector(bundleId));
        info[@"uiAppElementProcessName"] = IOSRunAXString(elem, @selector(processName));
    }

    NSArray *sources = @[app ?: [NSNull null], system ?: [NSNull null]];
    NSMutableArray *counts = [NSMutableArray array];
    for (id src in sources) {
        if ((id)src == [NSNull null]) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"bundleID"] = IOSRunAXString(src, @selector(bundleId));
        entry[@"processName"] = IOSRunAXString(src, @selector(processName));
        if ([src respondsToSelector:@selector(nativeFocusableElements)]) {
            NSArray *arr = [src performSelector:@selector(nativeFocusableElements)];
            entry[@"nativeFocusableElements"] = @((int)arr.count);
        }
        if ([src respondsToSelector:@selector(explorerElements)]) {
            NSArray *arr = [src performSelector:@selector(explorerElements)];
            entry[@"explorerElements"] = @((int)arr.count);
        }
        if ([src respondsToSelector:@selector(elementsWithSemanticContext)]) {
            NSArray *arr = [src performSelector:@selector(elementsWithSemanticContext)];
            entry[@"elementsWithSemanticContext"] = @((int)arr.count);
        }
        [counts addObject:entry];
    }
    info[@"sourceCounts"] = counts;
    return info;
}

#pragma mark - Full Tree

+ (NSDictionary *)getFullTree {
    __block NSDictionary *result = nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (cachedFullTree && (now - cachedFullTreeAt) < kTreeCacheTTL) {
        return cachedFullTree;
    }

    if ([NSThread isMainThread]) {
        result = [self buildTreeFromKeyWindow];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self buildTreeFromKeyWindow];
        });
    }

    if (result) {
        cachedFullTree = result;
        cachedFullTreeAt = now;
    }
    return result ?: @{@"error": @"No key window available"};
}

+ (NSString *)getFullTreeAsJSON {
    NSDictionary *tree = [self getFullTree];
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:tree
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error) {
        return [NSString stringWithFormat:@"{\"error\": \"%@\"}", error.localizedDescription];
    }
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (NSDictionary *)buildTreeFromKeyWindow {
    UIWindow *keyWindow = IOSRunPreferredWindow();

    if (!keyWindow) {
        return @{@"error": @"No window found"};
    }
    NSArray *viewChildren = [self buildTreeForView:keyWindow depth:0 maxDepth:30 index:[[NSMutableArray alloc] init]];
    if (![viewChildren isKindOfClass:[NSArray class]]) {
        viewChildren = @[];
    }

    // Foreground recovery fallback:
    // If key-window traversal yields no useful nodes, reuse interactive/AX
    // collection so /uiHierarchy still represents the current foreground UI.
    if (viewChildren.count == 0) {
        NSArray *interactiveFallback = [self collectInteractiveElements];
        if ([interactiveFallback isKindOfClass:[NSArray class]] && interactiveFallback.count > 0) {
            return @{
                @"type": @"Window",
                @"bounds": [self rectToDict:keyWindow.bounds],
                @"children": interactiveFallback,
                @"source": @"interactive_fallback"
            };
        }
    }

    return @{
        @"type": @"Window",
        @"bounds": [self rectToDict:keyWindow.bounds],
        @"children": viewChildren
    };
}

+ (NSArray *)buildTreeForView:(UIView *)view depth:(int)depth maxDepth:(int)maxDepth index:(NSMutableArray *)indexCounter {
    if (depth > maxDepth || !view || view.hidden || view.alpha < 0.01) {
        return @[];
    }

    NSMutableArray *elements = [NSMutableArray array];

    // Check if this view is accessible
    if (view.isAccessibilityElement || [self viewHasAccessibilityInfo:view]) {
        NSMutableDictionary *element = [self elementDictForView:view];

        // Assign index
        element[@"index"] = @(indexCounter.count);
        [indexCounter addObject:element];

        [elements addObject:element];
    }

    // Recurse into subviews
    for (UIView *subview in view.subviews) {
        [elements addObjectsFromArray:[self buildTreeForView:subview depth:depth+1 maxDepth:maxDepth index:indexCounter]];
    }

    // Also check accessibility elements if present
    if ([view respondsToSelector:@selector(accessibilityElements)] && view.accessibilityElements.count > 0) {
        for (id element in view.accessibilityElements) {
            if ([element isKindOfClass:[UIAccessibilityElement class]]) {
                UIAccessibilityElement *accElement = (UIAccessibilityElement *)element;
                NSMutableDictionary *dict = [self elementDictForAccessibilityElement:accElement];
                dict[@"index"] = @(indexCounter.count);
                [indexCounter addObject:dict];
                [elements addObject:dict];
            }
        }
    }

    return elements;
}

+ (BOOL)viewHasAccessibilityInfo:(UIView *)view {
    return view.accessibilityLabel.length > 0 ||
           view.accessibilityIdentifier.length > 0 ||
           view.accessibilityValue.length > 0 ||
           view.accessibilityHint.length > 0;
}

+ (NSMutableDictionary *)elementDictForView:(UIView *)view {
    CGRect screenFrame = [view.superview convertRect:view.frame toView:nil];

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"type"] = [self elementTypeForView:view];
    dict[@"className"] = NSStringFromClass([view class]);
    dict[@"label"] = view.accessibilityLabel ?: @"";
    dict[@"identifier"] = view.accessibilityIdentifier ?: @"";
    dict[@"value"] = view.accessibilityValue ?: @"";
    dict[@"hint"] = view.accessibilityHint ?: @"";
    dict[@"traits"] = [self traitsToArray:view.accessibilityTraits];
    dict[@"bounds"] = [self rectToDict:screenFrame];
    dict[@"rect"] = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                     screenFrame.origin.x, screenFrame.origin.y,
                     screenFrame.size.width, screenFrame.size.height];
    dict[@"center_x"] = @(CGRectGetMidX(screenFrame));
    dict[@"center_y"] = @(CGRectGetMidY(screenFrame));
    dict[@"enabled"] = @(view.userInteractionEnabled);
    dict[@"visible"] = @(!view.hidden && view.alpha > 0.01);

    // Extract text from common controls
    if ([view isKindOfClass:[UILabel class]]) {
        dict[@"text"] = ((UILabel *)view).text ?: @"";
    } else if ([view isKindOfClass:[UIButton class]]) {
        dict[@"text"] = ((UIButton *)view).titleLabel.text ?: @"";
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        dict[@"text"] = tf.text ?: @"";
        dict[@"placeholder"] = tf.placeholder ?: @"";
    } else if ([view isKindOfClass:[UITextView class]]) {
        dict[@"text"] = ((UITextView *)view).text ?: @"";
    } else if ([view isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)view;
        NSString *text = cell.textLabel.text ?: @"";
        NSString *detail = cell.detailTextLabel.text ?: @"";
        if (!dict[@"label"] || [dict[@"label"] length] == 0) {
            dict[@"label"] = text ?: @"";
        }
        if (detail.length > 0) {
            dict[@"value"] = detail;
        }
        if (text.length > 0) {
            dict[@"text"] = text;
        }
    }

    return dict;
}

+ (NSMutableDictionary *)elementDictForAccessibilityElement:(UIAccessibilityElement *)element {
    CGRect frame = element.accessibilityFrame;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"type"] = [self elementTypeForTraits:element.accessibilityTraits];
    dict[@"className"] = @"UIAccessibilityElement";
    dict[@"label"] = element.accessibilityLabel ?: @"";
    dict[@"identifier"] = element.accessibilityIdentifier ?: @"";
    dict[@"value"] = element.accessibilityValue ?: @"";
    dict[@"hint"] = element.accessibilityHint ?: @"";
    dict[@"traits"] = [self traitsToArray:element.accessibilityTraits];
    dict[@"bounds"] = [self rectToDict:frame];
    dict[@"rect"] = [NSString stringWithFormat:@"%.1f,%.1f,%.1f,%.1f",
                     frame.origin.x, frame.origin.y,
                     frame.size.width, frame.size.height];
    dict[@"center_x"] = @(CGRectGetMidX(frame));
    dict[@"center_y"] = @(CGRectGetMidY(frame));
    dict[@"enabled"] = @YES;
    dict[@"visible"] = @YES;

    return dict;
}

+ (NSString *)elementTypeForView:(UIView *)view {
    // Check traits first
    NSString *traitType = [self elementTypeForTraits:view.accessibilityTraits];
    if (![traitType isEqualToString:@"Other"]) {
        return traitType;
    }

    // Check class
    if ([view isKindOfClass:[UIButton class]]) return @"Button";
    if ([view isKindOfClass:[UILabel class]]) return @"StaticText";
    if ([view isKindOfClass:[UITextField class]]) return @"TextField";
    if ([view isKindOfClass:[UITextView class]]) return @"TextArea";
    if ([view isKindOfClass:[UISwitch class]]) return @"Switch";
    if ([view isKindOfClass:[UISlider class]]) return @"Slider";
    if ([view isKindOfClass:[UIStepper class]]) return @"Stepper";
    if ([view isKindOfClass:[UISegmentedControl class]]) return @"SegmentedControl";
    if ([view isKindOfClass:[UITableViewCell class]]) return @"Cell";
    if ([view isKindOfClass:[UICollectionViewCell class]]) return @"Cell";
    if ([view isKindOfClass:[UIImageView class]]) return @"Image";
    if ([view isKindOfClass:[UIScrollView class]]) return @"ScrollView";

    return @"Other";
}

+ (NSString *)elementTypeForTraits:(UIAccessibilityTraits)traits {
    if (traits & UIAccessibilityTraitButton) return @"Button";
    if (traits & UIAccessibilityTraitLink) return @"Link";
    if (traits & UIAccessibilityTraitSearchField) return @"SearchField";
    if (traits & UIAccessibilityTraitKeyboardKey) return @"KeyboardKey";
    if (traits & UIAccessibilityTraitStaticText) return @"StaticText";
    if (traits & UIAccessibilityTraitImage) return @"Image";
    if (traits & UIAccessibilityTraitHeader) return @"Header";
    if (traits & UIAccessibilityTraitTabBar) return @"TabBar";
    if (traits & UIAccessibilityTraitAdjustable) return @"Adjustable";
    return @"Other";
}

+ (NSArray *)traitsToArray:(UIAccessibilityTraits)traits {
    NSMutableArray *arr = [NSMutableArray array];
    if (traits & UIAccessibilityTraitButton) [arr addObject:@"Button"];
    if (traits & UIAccessibilityTraitLink) [arr addObject:@"Link"];
    if (traits & UIAccessibilityTraitSearchField) [arr addObject:@"SearchField"];
    if (traits & UIAccessibilityTraitImage) [arr addObject:@"Image"];
    if (traits & UIAccessibilityTraitSelected) [arr addObject:@"Selected"];
    if (traits & UIAccessibilityTraitNotEnabled) [arr addObject:@"NotEnabled"];
    if (traits & UIAccessibilityTraitStaticText) [arr addObject:@"StaticText"];
    if (traits & UIAccessibilityTraitHeader) [arr addObject:@"Header"];
    if (traits & UIAccessibilityTraitAdjustable) [arr addObject:@"Adjustable"];
    return arr;
}

+ (NSDictionary *)rectToDict:(CGRect)rect {
    return @{
        @"x": @(rect.origin.x),
        @"y": @(rect.origin.y),
        @"width": @(rect.size.width),
        @"height": @(rect.size.height)
    };
}

#pragma mark - Interactive Elements

+ (NSArray<NSDictionary *> *)getInteractiveElements {
    __block NSArray *result = nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (cachedInteractive && (now - cachedInteractiveAt) < kInteractiveCacheTTL) {
        return cachedInteractive;
    }

    if ([NSThread isMainThread]) {
        result = [self collectInteractiveElements];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self collectInteractiveElements];
        });
    }

    if (result) {
        cachedInteractive = result;
        cachedInteractiveAt = now;
    }
    return result ?: @[];
}

+ (NSString *)getInteractiveElementsAsJSON {
    NSArray *elements = [self getInteractiveElements];
    if (overlayEnabled) {
        [self refreshOverlayWithElements:elements];
    }
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:elements
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error) {
        return @"[]";
    }
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (NSArray *)collectInteractiveElements {
    NSMutableArray *elements = [NSMutableArray array];
    NSMutableArray *indexCounter = [NSMutableArray array];
    NSMutableArray *elementRefs = [NSMutableArray array];

    for (UIWindow *window in IOSRunActiveWindows()) {
        if (!window.hidden) {
            [self collectInteractiveFromView:window into:elements indexCounter:indexCounter elementRefs:elementRefs];
        }
    }

    if (elements.count > 0 && !IOSRunElementsNeedAXFallback(elements)) {
        @synchronized(self) {
            lastInteractiveElements = elementRefs;
        }
        return elements;
    }

    // Keep AX fallback enabled when view traversal only sees SpringBoard overlays.
    [elements removeAllObjects];
    [elementRefs removeAllObjects];
    [indexCounter removeAllObjects];

    // Fallback: AXRuntime cross-app elements
    Class AXElementClass = NSClassFromString(@"AXElement");
    if (!AXElementClass) {
        return elements;
    }

    @try {
        id app = nil;
        if ([AXElementClass respondsToSelector:@selector(primaryApp)]) {
            app = [AXElementClass performSelector:@selector(primaryApp)];
        }
        // Try to resolve the frontmost app using AXUIElement if primaryApp is nil
        if (!app) {
            CGPoint center = IOSRunPreferredProbePoint();
            id uiApp = IOSRunAXUIElementAtPoint(center);
            if (uiApp && [AXElementClass respondsToSelector:@selector(elementWithUIElement:)]) {
                app = [AXElementClass performSelector:@selector(elementWithUIElement:) withObject:uiApp];
            }
        }
        id system = nil;
        if ([AXElementClass respondsToSelector:@selector(systemWideElement)]) {
            system = [AXElementClass performSelector:@selector(systemWideElement)];
        }

        NSMutableArray *sources = [NSMutableArray array];
        if (app) [sources addObject:app];
        if (system && system != app) [sources addObject:system];

        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        NSUInteger count = 0;

        for (id source in sources) {
            if ([source respondsToSelector:@selector(nativeFocusableElements)]) {
                NSArray *axElems = [source performSelector:@selector(nativeFocusableElements)];
                for (id ax in axElems ?: @[]) {
                    IOSRunAXCollectFromElement(ax, visited, elements, &count);
                    [elementRefs addObject:ax ?: [NSNull null]];
                    if (count >= kAXMaxElements) break;
                }
            }

            if (count >= kAXMaxElements) break;

            if ([source respondsToSelector:@selector(explorerElements)]) {
                NSArray *axElems = [source performSelector:@selector(explorerElements)];
                for (id ax in axElems ?: @[]) {
                    IOSRunAXCollectFromElement(ax, visited, elements, &count);
                    [elementRefs addObject:ax ?: [NSNull null]];
                    if (count >= kAXMaxElements) break;
                }
            }

            if (count >= kAXMaxElements) break;

            if ([source respondsToSelector:@selector(elementsWithSemanticContext)]) {
                NSArray *axElems = [source performSelector:@selector(elementsWithSemanticContext)];
                for (id ax in axElems ?: @[]) {
                    IOSRunAXCollectFromElement(ax, visited, elements, &count);
                    [elementRefs addObject:ax ?: [NSNull null]];
                    if (count >= kAXMaxElements) break;
                }
            }

            if (count >= kAXMaxElements) break;

            if ([source respondsToSelector:@selector(firstElementInApplication)]) {
                id root = [source performSelector:@selector(firstElementInApplication)];
                IOSRunAXCollectFromElement(root, visited, elements, &count);
                [elementRefs addObject:root ?: [NSNull null]];
            }
        }
    } @catch (__unused NSException *e) {
    }

    if (elements.count > 0) {
        @synchronized(self) {
            lastInteractiveElements = elementRefs;
        }
        return elements;
    }

    // Last-resort fallback: sample grid with AXUIElement at coordinates
    @try {
        UIWindow *window = IOSRunPreferredWindow();
        CGRect bounds = window ? [window convertRect:window.bounds toWindow:nil] : [UIScreen mainScreen].bounds;
        if (CGRectIsEmpty(bounds)) {
            bounds = [UIScreen mainScreen].bounds;
        }
        NSInteger cols = 6;
        NSInteger rows = 10;
        CGFloat dx = bounds.size.width / cols;
        CGFloat dy = bounds.size.height / rows;
        NSMutableSet<NSValue *> *seen = [NSMutableSet set];
        NSUInteger count = 0;
        for (NSInteger r = 0; r < rows; r++) {
            for (NSInteger c = 0; c < cols; c++) {
                CGPoint p = CGPointMake((c + 0.5) * dx, (r + 0.5) * dy);
                id axElem = IOSRunAXElementFromPoint(p);
                if (!axElem) continue;
                NSValue *key = [NSValue valueWithPointer:(__bridge const void *)(axElem)];
                if ([seen containsObject:key]) continue;
                [seen addObject:key];
                if (!IOSRunAXElementIsInteractive(axElem)) continue;
                NSDictionary *dict = IOSRunDictForAXElement(axElem);
                if (!dict) continue;
                NSMutableDictionary *mutable = [dict mutableCopy];
                mutable[@"index"] = @(count);
                [elements addObject:mutable];
                [elementRefs addObject:axElem ?: [NSNull null]];
                count++;
                if (count >= kAXMaxElements) break;
            }
            if (count >= kAXMaxElements) break;
        }
    } @catch (__unused NSException *e) {
    }

    if (elements.count > 0) {
        @synchronized(self) {
            lastInteractiveElements = elementRefs;
        }
    }
    return elements;
}

+ (void)collectInteractiveFromView:(UIView *)view
                               into:(NSMutableArray *)elements
                      indexCounter:(NSMutableArray *)indexCounter
                       elementRefs:(NSMutableArray *)elementRefs {
    if (view.hidden || view.alpha < 0.01) return;

    // Check if interactive
    BOOL isInteractive = NO;

    if (view.userInteractionEnabled) {
        if ([view isKindOfClass:[UIButton class]] ||
            [view isKindOfClass:[UITextField class]] ||
            [view isKindOfClass:[UITextView class]] ||
            [view isKindOfClass:[UISwitch class]] ||
            [view isKindOfClass:[UISlider class]] ||
            [view isKindOfClass:[UITableViewCell class]] ||
            [view isKindOfClass:[UICollectionViewCell class]]) {
            isInteractive = YES;
        }

        // Check traits
        if (view.accessibilityTraits & UIAccessibilityTraitButton ||
            view.accessibilityTraits & UIAccessibilityTraitLink ||
            view.accessibilityTraits & UIAccessibilityTraitSearchField) {
            isInteractive = YES;
        }
    }

    // Treat accessible elements with labels/traits as interactive
    if (!isInteractive && (view.isAccessibilityElement || [self viewHasAccessibilityInfo:view])) {
        BOOL hasActionableTraits = ((view.accessibilityTraits & UIAccessibilityTraitButton) ||
                                    (view.accessibilityTraits & UIAccessibilityTraitLink) ||
                                    (view.accessibilityTraits & UIAccessibilityTraitSearchField) ||
                                    (view.accessibilityTraits & UIAccessibilityTraitAdjustable));
        BOOL hasSemanticIdentity = (view.accessibilityLabel.length > 0 ||
                                    view.accessibilityIdentifier.length > 0 ||
                                    view.accessibilityValue.length > 0 ||
                                    view.accessibilityHint.length > 0);
        BOOL isActionableClass = ([view isKindOfClass:[UIControl class]] ||
                                  [view isKindOfClass:[UITableViewCell class]] ||
                                  [view isKindOfClass:[UICollectionViewCell class]]);
        if ((hasActionableTraits || isActionableClass) && hasSemanticIdentity) {
            isInteractive = YES;
        }
    }

    if (isInteractive) {
        NSString *className = NSStringFromClass([view class]) ?: @"";
        if (IOSRunClassNameContainsAny(className, @[@"homegrabber", @"statusbar", @"overlay", @"keyboard", @"dock", @"assistive"])) {
            isInteractive = NO;
        }
    }

    if (isInteractive) {
        NSMutableDictionary *element = [self elementDictForView:view];
        element[@"index"] = @(indexCounter.count);
        [indexCounter addObject:element];
        [elements addObject:element];
        if (elementRefs) {
            [elementRefs addObject:view ?: [NSNull null]];
        }
    }

    // Recurse
    for (UIView *subview in view.subviews) {
        [self collectInteractiveFromView:subview into:elements indexCounter:indexCounter elementRefs:elementRefs];
    }

    // Include accessibility elements if present (SpringBoard often exposes these)
    if ([view respondsToSelector:@selector(accessibilityElements)] && view.accessibilityElements.count > 0) {
        for (id element in view.accessibilityElements) {
            if ([element isKindOfClass:[UIAccessibilityElement class]]) {
                UIAccessibilityElement *accElement = (UIAccessibilityElement *)element;
                if (!IOSRunIsInteractiveAccessibilityElement(accElement)) {
                    continue;
                }
                NSMutableDictionary *dict = [self elementDictForAccessibilityElement:accElement];
                dict[@"index"] = @(indexCounter.count);
                [indexCounter addObject:dict];
                [elements addObject:dict];
                if (elementRefs) {
                    [elementRefs addObject:accElement ?: [NSNull null]];
                }
                continue;
            }
            if ([element respondsToSelector:@selector(accessibilityFrame)] &&
                IOSRunIsInteractiveGenericElement(element)) {
                NSMutableDictionary *dict = [IOSRunDictForGenericElement(element) mutableCopy];
                if (!dict) continue;
                dict[@"index"] = @(indexCounter.count);
                [indexCounter addObject:dict];
                [elements addObject:dict];
                if (elementRefs) {
                    [elementRefs addObject:element ?: [NSNull null]];
                }
            }
        }
    }
}

#pragma mark - Find Elements

+ (NSDictionary *)findElementWithLabel:(NSString *)label {
    NSArray *elements = [self getInteractiveElements];
    for (NSDictionary *element in elements) {
        if ([element[@"label"] isEqualToString:label]) {
            return element;
        }
    }
    return nil;
}

+ (NSDictionary *)findElementWithIdentifier:(NSString *)identifier {
    NSArray *elements = [self getInteractiveElements];
    for (NSDictionary *element in elements) {
        if ([element[@"identifier"] isEqualToString:identifier]) {
            return element;
        }
    }
    return nil;
}

+ (BOOL)activateInteractiveElementAtIndex:(NSUInteger)index {
    __block id element = nil;
    @synchronized(self) {
        if (index < (NSUInteger)lastInteractiveElements.count) {
            element = lastInteractiveElements[index];
            if ([element isKindOfClass:[NSNull class]]) {
                element = nil;
            }
        }
    }
    if (!element) return NO;

    if ([NSThread isMainThread]) {
        return IOSRunActivateElement(element);
    }

    __block BOOL success = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        success = IOSRunActivateElement(element);
    });
    return success;
}

+ (BOOL)activateElementAtPoint:(CGPoint)point {
    __block BOOL success = NO;
    void (^activateBlock)(void) = ^{
        // Try AX runtime lookup first (works for many UIKit accessibility elements).
        id axElement = IOSRunAXElementFromPoint(point);
        if (IOSRunActivateElement(axElement)) {
            success = YES;
            return;
        }

        id axUIElement = IOSRunAXUIElementAtPoint(point);
        if (IOSRunActivateElement(axUIElement)) {
            success = YES;
            return;
        }

        // Fall back to UIKit hit-testing in active windows.
        NSArray<UIWindow *> *windows = IOSRunActiveWindows();
        for (UIWindow *window in windows) {
            if (!window || window.hidden || window.alpha < 0.01f) {
                continue;
            }
            CGPoint local = [window convertPoint:point fromWindow:nil];
            UIView *hitView = [window hitTest:local withEvent:nil];
            if (IOSRunActivateView(hitView)) {
                success = YES;
                return;
            }
        }

        // Final fallback: choose nearest interactive element bounds and activate by index.
        NSArray<NSDictionary *> *interactive = [AccessibilityTree getInteractiveElements];
        NSUInteger bestIndex = NSNotFound;
        CGFloat bestDistance = CGFLOAT_MAX;
        for (NSDictionary *element in interactive) {
            NSDictionary *bounds = [element[@"bounds"] isKindOfClass:[NSDictionary class]] ? element[@"bounds"] : nil;
            if (!bounds) {
                continue;
            }
            CGFloat x = [bounds[@"x"] doubleValue];
            CGFloat y = [bounds[@"y"] doubleValue];
            CGFloat w = [bounds[@"width"] doubleValue];
            CGFloat h = [bounds[@"height"] doubleValue];
            CGRect rect = CGRectMake(x, y, w, h);
            if (CGRectIsEmpty(rect)) {
                continue;
            }
            NSUInteger idx = [element[@"index"] unsignedIntegerValue];
            if (CGRectContainsPoint(rect, point)) {
                if ([AccessibilityTree activateInteractiveElementAtIndex:idx]) {
                    success = YES;
                    return;
                }
            }
            CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
            CGFloat dx = center.x - point.x;
            CGFloat dy = center.y - point.y;
            CGFloat dist = (dx * dx) + (dy * dy);
            if (dist < bestDistance) {
                bestDistance = dist;
                bestIndex = idx;
            }
        }
        if (bestIndex != NSNotFound && bestDistance < 4000.0) { // ~63pt radius
            if ([AccessibilityTree activateInteractiveElementAtIndex:bestIndex]) {
                success = YES;
                return;
            }
        }
    };

    if ([NSThread isMainThread]) {
        activateBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), activateBlock);
    }
    return success;
}

+ (BOOL)scrollAtPoint:(CGPoint)point direction:(NSInteger)direction {
    __block BOOL success = NO;
    void (^scrollBlock)(void) = ^{
        id axElement = IOSRunAXElementFromPoint(point);
        if (IOSRunTryScrollElement(axElement, direction)) {
            success = YES;
            return;
        }

        id axUIElement = IOSRunAXUIElementAtPoint(point);
        if (IOSRunTryScrollElement(axUIElement, direction)) {
            success = YES;
            return;
        }
    };

    if ([NSThread isMainThread]) {
        scrollBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), scrollBlock);
    }
    return success;
}

+ (NSDictionary *)getTreeForView:(UIView *)view {
    if (!view) return @{};

    NSMutableDictionary *dict = [self elementDictForView:view];
    NSMutableArray *indexCounter = [NSMutableArray array];
    dict[@"children"] = [self buildTreeForView:view depth:0 maxDepth:20 index:indexCounter];

    return dict;
}

@end
