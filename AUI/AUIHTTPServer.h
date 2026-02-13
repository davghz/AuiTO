#import <Foundation/Foundation.h>

@class AUIVirtualTouch;

@interface AUIHTTPServer : NSObject

@property (nonatomic, strong) AUIVirtualTouch *touch;

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;

@end
