#import <Foundation/Foundation.h>

@interface DaemonHTTPServer : NSObject

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;

@end
