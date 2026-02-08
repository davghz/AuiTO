#import "DaemonHTTPServer.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

@implementation DaemonHTTPServer (Helpers)

- (id)handleClassDumpRequest:(NSString *)path {
    @try {
        NSString *query = nil;
        if ([path containsString:@"?"]) {
            NSRange queryRange = [path rangeOfString:@"?"];
            query = [path substringFromIndex:queryRange.location + 1];
        }

        NSString *contains = [self stringValueFromQuery:query key:@"contains"];
        NSString *prefix = [self stringValueFromQuery:query key:@"prefix"];
        NSString *image = [self stringValueFromQuery:query key:@"image"];
        BOOL all = [self boolValueFromQuery:query key:@"all" defaultValue:NO];
        NSInteger limit = (NSInteger)[self floatValueFromQuery:query key:@"limit"];
        if (limit <= 0) limit = 200;
        if (limit > 2000) limit = 2000;
        BOOL includeImages = [self boolValueFromQuery:query key:@"images" defaultValue:NO];

        NSString *containsLower = contains ? [contains lowercaseString] : nil;
        NSString *prefixLower = prefix ? [prefix lowercaseString] : nil;

        if (!image.length && !all) {
            NSString *json = @"{\"status\":\"error\",\"message\":\"Provide ?image=... or ?all=1\"}";
            return [self jsonResponse:400 body:json];
        }

        __block NSArray *results = nil;
        void (^collectClasses)(void) = ^{
            NSMutableArray *accum = [NSMutableArray array];
            if (image.length) {
                unsigned int count = 0;
                const char **names = objc_copyClassNamesForImage([image UTF8String], &count);
                if (names && count > 0) {
                    for (unsigned int i = 0; i < count; i++) {
                        const char *name = names[i];
                        if (!name) continue;
                        NSString *className = [NSString stringWithUTF8String:name];
                        if (!className) continue;
                        NSString *lower = [className lowercaseString];
                        if (containsLower && [lower rangeOfString:containsLower].location == NSNotFound) {
                            continue;
                        }
                        if (prefixLower && ![lower hasPrefix:prefixLower]) {
                            continue;
                        }
                        [accum addObject:className];
                        if (accum.count >= (NSUInteger)limit) {
                            break;
                        }
                    }
                }
                if (names) free(names);
            } else if (all) {
                // Enumerate classes image-by-image (stable path) instead of global runtime
                // class list walking, which can reset the connection in this daemon context.
                NSMutableSet<NSString *> *seenNames = [NSMutableSet set];
                uint32_t imageCount = _dyld_image_count();
                for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
                    if (accum.count >= (NSUInteger)limit) {
                        break;
                    }
                    const char *imageCStr = _dyld_get_image_name(imageIndex);
                    if (!imageCStr || imageCStr[0] == '\0') {
                        continue;
                    }
                    NSString *imageName = [[NSString alloc] initWithUTF8String:imageCStr];
                    if (!imageName || imageName.length == 0) {
                        continue;
                    }

                    unsigned int count = 0;
                    const char **names = objc_copyClassNamesForImage(imageCStr, &count);
                    if (!names || count == 0) {
                        if (names) free(names);
                        continue;
                    }

                    for (unsigned int i = 0; i < count; i++) {
                        if (accum.count >= (NSUInteger)limit) {
                            break;
                        }
                        const char *name = names[i];
                        if (!name || name[0] == '\0') {
                            continue;
                        }
                        NSString *className = [[NSString alloc] initWithUTF8String:name];
                        if (!className || className.length == 0 || [seenNames containsObject:className]) {
                            continue;
                        }
                        NSString *lower = [className lowercaseString];
                        if (containsLower && [lower rangeOfString:containsLower].location == NSNotFound) {
                            continue;
                        }
                        if (prefixLower && ![lower hasPrefix:prefixLower]) {
                            continue;
                        }
                        [seenNames addObject:className];
                        if (includeImages) {
                            [accum addObject:@{@"name": className, @"image": imageName}];
                        } else {
                            [accum addObject:className];
                        }
                    }
                    free(names);
                }
            }
            results = [accum copy];
        };

        // Runtime class enumeration does not require main-thread affinity and is
        // safer off-main for large class lists.
        collectClasses();

        NSDictionary *payload = @{@"status": @"ok",
                                  @"count": @(results.count),
                                  @"classes": results ?: @[]};
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        if (!jsonData || error) {
            return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Failed to encode\"}"];
        }
        return [self binaryResponse:200 contentType:@"application/json" body:jsonData];
    } @catch (NSException *e) {
        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"error\",\"message\":\"Exception: %@\"}",
                          e.reason ?: @"unknown"];
        return [self jsonResponse:500 body:json];
    }
}

- (id)handleClassMethodsRequest:(NSString *)path {
    @try {
        NSString *query = nil;
        if ([path containsString:@"?"]) {
            NSRange queryRange = [path rangeOfString:@"?"];
            query = [path substringFromIndex:queryRange.location + 1];
        }

        NSString *className = [self stringValueFromQuery:query key:@"class"];
        NSString *contains = [self stringValueFromQuery:query key:@"contains"];
        NSInteger limit = (NSInteger)[self floatValueFromQuery:query key:@"limit"];
        if (limit <= 0) limit = 400;
        if (limit > 4000) limit = 4000;
        if (!className.length) {
            return [self jsonResponse:400 body:@"{\"status\":\"error\",\"message\":\"Provide ?class=ClassName\"}"];
        }

        NSString *containsLower = contains.length > 0 ? [contains lowercaseString] : nil;
        __block NSDictionary *payload = nil;
        void (^collectMethods)(void) = ^{
            Class cls = NSClassFromString(className);
            if (!cls) {
                payload = @{@"status": @"error", @"message": @"Class not found", @"class": className};
                return;
            }

            NSMutableArray<NSString *> *instanceMethods = [NSMutableArray array];
            NSMutableArray<NSString *> *classMethods = [NSMutableArray array];

            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                SEL sel = method_getName(methods[i]);
                if (!sel) continue;
                NSString *name = NSStringFromSelector(sel);
                if (containsLower && [[name lowercaseString] rangeOfString:containsLower].location == NSNotFound) {
                    continue;
                }
                [instanceMethods addObject:name];
                if ((NSInteger)instanceMethods.count >= limit) {
                    break;
                }
            }
            if (methods) free(methods);

            Class meta = object_getClass((id)cls);
            count = 0;
            methods = meta ? class_copyMethodList(meta, &count) : NULL;
            for (unsigned int i = 0; i < count; i++) {
                SEL sel = method_getName(methods[i]);
                if (!sel) continue;
                NSString *name = NSStringFromSelector(sel);
                if (containsLower && [[name lowercaseString] rangeOfString:containsLower].location == NSNotFound) {
                    continue;
                }
                [classMethods addObject:name];
                if ((NSInteger)classMethods.count >= limit) {
                    break;
                }
            }
            if (methods) free(methods);

            const char *img = class_getImageName(cls);
            NSString *imageName = img ? [NSString stringWithUTF8String:img] : @"";
            if (!imageName) imageName = @"";

            payload = @{
                @"status": @"ok",
                @"class": className,
                @"image": imageName,
                @"instanceCount": @((NSInteger)instanceMethods.count),
                @"classCount": @((NSInteger)classMethods.count),
                @"instanceMethods": instanceMethods,
                @"classMethods": classMethods
            };
        };

        if ([NSThread isMainThread]) {
            collectMethods();
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                collectMethods();
            });
        }

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:(payload ?: @{})
                                                           options:0
                                                             error:&error];
        if (!jsonData || error) {
            return [self jsonResponse:500 body:@"{\"status\":\"error\",\"message\":\"Failed to encode\"}"];
        }
        return [self binaryResponse:200 contentType:@"application/json" body:jsonData];
    } @catch (NSException *e) {
        NSString *json = [NSString stringWithFormat:
                          @"{\"status\":\"error\",\"message\":\"Exception: %@\"}",
                          e.reason ?: @"unknown"];
        return [self jsonResponse:500 body:json];
    }
}

- (NSString *)jsonResponse:(NSInteger)statusCode body:(NSString *)body {
    NSString *safeBody = body ?: @"";
    NSData *bodyData = [safeBody dataUsingEncoding:NSUTF8StringEncoding];
    NSString *statusText = statusCode == 200 ? @"OK" : @"Not Found";
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

- (NSData *)binaryResponse:(NSInteger)statusCode contentType:(NSString *)contentType body:(NSData *)body {
    NSString *statusText = statusCode == 200 ? @"OK" : @"Error";
    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 %ld %@\r\n"
                        @"Content-Type: %@\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        (long)statusCode, statusText,
                        contentType ?: @"application/octet-stream",
                        (unsigned long)(body ? body.length : 0)];
    NSMutableData *data = [NSMutableData data];
    [data appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    if (body && body.length > 0) {
        [data appendData:body];
    }
    return data;
}

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

    if (!value.length) return nil;
    NSString *plusReplaced = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    NSString *decoded = [plusReplaced stringByRemovingPercentEncoding];
    return decoded.length ? decoded : plusReplaced;
}

- (BOOL)boolValueFromQuery:(NSString *)query key:(NSString *)key defaultValue:(BOOL)defaultValue {
    NSString *value = [self stringValueFromQuery:query key:key];
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

- (NSInteger)contentLengthFromHeaderString:(NSString *)headerString {
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

- (NSDictionary *)parseJSONBody:(NSString *)body {
    if (!body || body.length == 0) return nil;
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSError *error = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![obj isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return (NSDictionary *)obj;
}

- (NSArray<NSNumber *> *)numbersFromString:(NSString *)text {
    if (!text) return @[];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    NSMutableArray<NSNumber *> *nums = [NSMutableArray array];
    double value = 0;
    while (!scanner.isAtEnd) {
        if ([scanner scanDouble:&value]) {
            [nums addObject:@(value)];
        } else {
            scanner.scanLocation += 1;
        }
    }
    return nums;
}

- (BOOL)extractRectFromString:(NSString *)rectStr x:(CGFloat *)x y:(CGFloat *)y w:(CGFloat *)w h:(CGFloat *)h {
    if (!rectStr || rectStr.length == 0) return NO;
    NSArray<NSNumber *> *nums = [self numbersFromString:rectStr];
    if (nums.count < 4) return NO;
    CGFloat rx = nums[0].doubleValue;
    CGFloat ry = nums[1].doubleValue;
    CGFloat rw = nums[2].doubleValue;
    CGFloat rh = nums[3].doubleValue;
    if (rw <= 0) rw = 1;
    if (rh <= 0) rh = 1;
    if (x) *x = rx;
    if (y) *y = ry;
    if (w) *w = rw;
    if (h) *h = rh;
    return YES;
}

- (NSString *)sanitizeA11yString:(NSString *)text {
    if (!text) return @"";
    NSString *out = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    out = [out stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    out = [out stringByReplacingOccurrencesOfString:@"'" withString:@"’"];
    return out;
}

- (NSString *)accessibilityTreeStringFromElements:(NSArray<NSDictionary *> *)elements {
    NSMutableString *tree = [NSMutableString stringWithString:@"Element subtree:\n"];
    NSArray *preferred = @[@"Button", @"Link", @"SearchField", @"TextField", @"Cell", @"Switch", @"Slider", @"Stepper", @"Picker"];

    for (NSDictionary *elem in elements) {
        NSString *type = @"Button";
        if ([elem[@"traits"] isKindOfClass:[NSArray class]]) {
            for (NSString *t in (NSArray *)elem[@"traits"]) {
                if ([preferred containsObject:t]) {
                    type = t;
                    break;
                }
            }
        }
        NSString *className = [elem[@"className"] isKindOfClass:[NSString class]] ? elem[@"className"] : nil;
        if ([type isEqualToString:@"Button"] && className.length > 0) {
            for (NSString *t in preferred) {
                if ([className containsString:t]) {
                    type = t;
                    break;
                }
            }
        }

        CGFloat x = 0, y = 0, w = 0, h = 0;
        NSDictionary *bounds = [elem[@"bounds"] isKindOfClass:[NSDictionary class]] ? elem[@"bounds"] : nil;
        if (bounds) {
            x = [bounds[@"x"] doubleValue];
            y = [bounds[@"y"] doubleValue];
            w = [bounds[@"width"] doubleValue];
            h = [bounds[@"height"] doubleValue];
        } else if ([elem[@"rect"] isKindOfClass:[NSString class]]) {
            [self extractRectFromString:elem[@"rect"] x:&x y:&y w:&w h:&h];
        }

        NSString *label = [elem[@"label"] isKindOfClass:[NSString class]] ? elem[@"label"] : @"";
        NSString *identifier = [elem[@"identifier"] isKindOfClass:[NSString class]] ? elem[@"identifier"] : @"";
        NSString *placeholder = nil;
        if ([elem[@"placeholderValue"] isKindOfClass:[NSString class]]) {
            placeholder = elem[@"placeholderValue"];
        } else if ([elem[@"placeholder"] isKindOfClass:[NSString class]]) {
            placeholder = elem[@"placeholder"];
        }
        NSString *value = [elem[@"value"] isKindOfClass:[NSString class]] ? elem[@"value"] : @"";

        label = [self sanitizeA11yString:label];
        identifier = [self sanitizeA11yString:identifier];
        placeholder = [self sanitizeA11yString:placeholder];
        value = [self sanitizeA11yString:value];

        NSMutableString *line = [NSMutableString stringWithFormat:
                                 @"%@, {{%.1f, %.1f}, {%.1f, %.1f}}",
                                 type, x, y, w, h];
        if (label.length > 0) {
            [line appendFormat:@", label:'%@'", label];
        }
        if (identifier.length > 0) {
            [line appendFormat:@", identifier:'%@'", identifier];
        }
        if (placeholder.length > 0) {
            [line appendFormat:@", placeholderValue:'%@'", placeholder];
        }
        if (value.length > 0) {
            [line appendFormat:@", value:%@", value];
        }
        [tree appendFormat:@"%@\n", line];
    }

    return tree;
}

@end
