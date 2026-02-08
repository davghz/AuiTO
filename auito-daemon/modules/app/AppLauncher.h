#import <Foundation/Foundation.h>

@interface AppLauncher : NSObject
+ (BOOL)launchAppWithBundleID:(NSString *)bundleID;
+ (BOOL)terminateAppWithBundleID:(NSString *)bundleID;
+ (NSArray<NSDictionary *> *)listApplicationsIncludeSystem:(BOOL)includeSystem;
@end
