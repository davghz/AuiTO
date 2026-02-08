//
//  KimiRunHTTPServer.h
//  KimiRun Modular - HTTP Server Module
//
//  HTTP server using CFSocket for iOS
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

NS_ASSUME_NONNULL_BEGIN

@interface KimiRunHTTPServer : NSObject

@property (nonatomic, assign, readonly) BOOL isRunning;
@property (nonatomic, assign, readonly) NSUInteger port;

+ (instancetype)sharedServer;

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
