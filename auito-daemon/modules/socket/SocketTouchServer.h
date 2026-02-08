//
//  SocketTouchServer.h
//  KimiRun - Socket-based Touch Server (ZXTouch-style)
//
//  Runs inside SpringBoard to allow external touch control via TCP socket
//

#import <Foundation/Foundation.h>

@interface SocketTouchServer : NSObject

+ (instancetype)sharedServer;
- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error;
- (void)stop;
- (BOOL)isRunning;

@end