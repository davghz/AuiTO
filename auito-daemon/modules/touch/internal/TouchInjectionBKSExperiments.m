#import "TouchInjectionInternal.h"
#import <stdlib.h>

NSInteger KimiRunClampInteger(NSInteger value, NSInteger minimum, NSInteger maximum) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

NSInteger KimiRunTouchPrefInteger(NSString *key, NSInteger defaultValue) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return defaultValue;
    }
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kKimiRunPrefsSuite];
    id value = [prefs objectForKey:key];
    if (!value) {
        return defaultValue;
    }
    if ([value respondsToSelector:@selector(integerValue)]) {
        return [value integerValue];
    }
    return defaultValue;
}

NSInteger KimiRunTouchEnvInteger(const char *key, NSInteger defaultValue) {
    if (!key) {
        return defaultValue;
    }
    const char *raw = getenv(key);
    if (!raw || raw[0] == '\0') {
        return defaultValue;
    }
    char *endPtr = NULL;
    long parsed = strtol(raw, &endPtr, 10);
    if (endPtr == raw) {
        return defaultValue;
    }
    return (NSInteger)parsed;
}

NSString *KimiRunTouchEnvOrPrefString(const char *envKey,
                                      NSString *prefKey,
                                      NSString *defaultValue) {
    if (envKey) {
        const char *raw = getenv(envKey);
        if (raw && raw[0] != '\0') {
            return [NSString stringWithUTF8String:raw];
        }
    }
    NSString *pref = KimiRunTouchPrefString(prefKey);
    if ([pref isKindOfClass:[NSString class]] && pref.length > 0) {
        return pref;
    }
    return defaultValue;
}

NSString *KimiRunNormalizeExperimentMode(NSString *value,
                                         NSArray<NSString *> *allowed,
                                         NSString *fallback) {
    NSString *lower = [[value ?: fallback ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([allowed containsObject:lower]) {
        return lower;
    }
    return fallback ?: @"";
}
