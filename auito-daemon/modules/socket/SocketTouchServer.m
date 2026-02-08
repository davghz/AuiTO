//
//  SocketTouchServer.m
//  KimiRun - Socket-based Touch Server
//
//  Protocol compatible with ZXTouch for maximum compatibility
//

#import "SocketTouchServer.h"
#import "../touch/TouchInjection.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

// ZXTouch Protocol Constants
#define kZXTouchPort 6000
#define kZXTouchTaskPerformTouch 10

// Touch event types
#define kZXTouchUp   0
#define kZXTouchDown 1
#define kZXTouchMove 2

@interface SocketTouchServer ()
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, strong) NSThread *serverThread;
@property (nonatomic, assign) BOOL shouldStop;
@end

@implementation SocketTouchServer

+ (instancetype)sharedServer {
    static SocketTouchServer *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _port = 0;
        _shouldStop = NO;
    }
    return self;
}

- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error {
    if (self.isRunning) {
        [self stop];
    }
    
    self.port = port;
    self.shouldStop = NO;
    
    // Create socket
    self.serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverSocket < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SocketTouchServer" 
                                         code:errno 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        }
        return NO;
    }
    
    // Allow socket reuse
    int reuse = 1;
    setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    
    // Bind to address
    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    serverAddr.sin_port = htons(port);
    
    if (bind(self.serverSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SocketTouchServer" 
                                         code:errno 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind socket"}];
        }
        close(self.serverSocket);
        self.serverSocket = -1;
        return NO;
    }
    
    // Listen for connections
    if (listen(self.serverSocket, 5) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"SocketTouchServer" 
                                         code:errno 
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to listen on socket"}];
        }
        close(self.serverSocket);
        self.serverSocket = -1;
        return NO;
    }
    
    // Start server thread
    self.serverThread = [[NSThread alloc] initWithTarget:self 
                                                selector:@selector(serverLoop) 
                                                  object:nil];
    self.serverThread.name = @"SocketTouchServer";
    [self.serverThread start];
    
    NSLog(@"[SocketTouchServer] Started on port %d", port);
    return YES;
}

- (void)stop {
    self.shouldStop = YES;
    
    if (self.serverSocket >= 0) {
        close(self.serverSocket);
        self.serverSocket = -1;
    }
    
    // Wait for thread to finish
    if (self.serverThread && !self.serverThread.isFinished) {
        [self.serverThread cancel];
        [NSThread sleepForTimeInterval:0.1];
    }
    
    NSLog(@"[SocketTouchServer] Stopped");
}

- (BOOL)isRunning {
    return self.serverSocket >= 0 && !self.shouldStop;
}

- (void)serverLoop {
    @autoreleasepool {
        NSLog(@"[SocketTouchServer] Server loop started");
        
        while (!self.shouldStop) {
            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            
            // Accept connection (with timeout)
            int clientSocket = accept(self.serverSocket, 
                                     (struct sockaddr *)&clientAddr, 
                                     &clientLen);
            
            if (clientSocket < 0) {
                if (errno == EINTR || errno == EAGAIN) {
                    continue;
                }
                NSLog(@"[SocketTouchServer] Accept error: %d", errno);
                [NSThread sleepForTimeInterval:0.1];
                continue;
            }
            
            NSLog(@"[SocketTouchServer] Client connected from %s:%d", 
                  inet_ntoa(clientAddr.sin_addr), ntohs(clientAddr.sin_port));
            
            // Handle client in a separate thread
            [self handleClient:clientSocket];
        }
        
        NSLog(@"[SocketTouchServer] Server loop ended");
    }
}

- (void)handleClient:(int)clientSocket {
    @autoreleasepool {
        char buffer[1024];
        ssize_t bytesRead;
        
        while ((bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0)) > 0) {
            buffer[bytesRead] = '\0';
            
            // Process command
            NSString *command = [[NSString alloc] initWithUTF8String:buffer];
            NSString *response = [self processCommand:command];
            
            // Send response
            const char *responseBytes = [response UTF8String];
            send(clientSocket, responseBytes, strlen(responseBytes), 0);
        }
        
        close(clientSocket);
        NSLog(@"[SocketTouchServer] Client disconnected");
    }
}

- (NSString *)processCommand:(NSString *)command {
    // Remove newlines and whitespace
    command = [command stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (command.length == 0) {
        return @"ERROR: Empty command\r\n";
    }
    
    NSLog(@"[SocketTouchServer] Processing command: %@", command);
    
    // Parse ZXTouch protocol
    // Format: "10<type><fingerIndex><x><y>"
    // Example: "10110123401234" = touch down, finger 1, x=123.4, y=123.4
    
    if (command.length >= 3) {
        NSString *taskIdStr = [command substringToIndex:2];
        int taskId = [taskIdStr intValue];
        
        if (taskId == kZXTouchTaskPerformTouch) {
            return [self handleTouchCommand:command];
        }
        
        // Simple test command
        if ([command hasPrefix:@"TEST"]) {
            return @"OK: Server is running\r\n";
        }
        
        // Simple tap command: "TAP x y"
        if ([command hasPrefix:@"TAP "]) {
            NSArray *parts = [command componentsSeparatedByString:@" "];
            if (parts.count >= 3) {
                CGFloat x = [parts[1] floatValue];
                CGFloat y = [parts[2] floatValue];
                
                BOOL success = [KimiRunTouchInjection tapAtX:x Y:y];
                return success ? @"OK\r\n" : @"ERROR\r\n";
            }
        }
    }
    
    return @"ERROR: Unknown command\r\n";
}

- (NSString *)handleTouchCommand:(NSString *)command {
    // ZXTouch format: "10" + count + events
    // Each event: type(1) + finger(2) + x(5) + y(5) = 13 chars
    
    if (command.length < 3) {
        return @"ERROR: Invalid touch command\r\n";
    }
    
    NSString *countStr = [command substringWithRange:NSMakeRange(2, 1)];
    int eventCount = [countStr intValue];
    
    if (eventCount < 1 || eventCount > 20) {
        return @"ERROR: Invalid event count\r\n";
    }
    
    NSUInteger offset = 3;
    NSMutableArray *events = [NSMutableArray array];
    
    for (int i = 0; i < eventCount; i++) {
        if (offset + 13 > command.length) {
            return @"ERROR: Incomplete event data\r\n";
        }
        
        NSString *eventStr = [command substringWithRange:NSMakeRange(offset, 13)];
        
        // Parse event
        int type = [[eventStr substringWithRange:NSMakeRange(0, 1)] intValue];
        int finger = [[eventStr substringWithRange:NSMakeRange(1, 2)] intValue];
        int xScaled = [[eventStr substringWithRange:NSMakeRange(3, 5)] intValue];
        int yScaled = [[eventStr substringWithRange:NSMakeRange(8, 5)] intValue];
        
        CGFloat x = xScaled / 10.0;
        CGFloat y = yScaled / 10.0;
        
        [events addObject:@{
            @"type": @(type),
            @"finger": @(finger),
            @"x": @(x),
            @"y": @(y)
        }];
        
        offset += 13;
    }
    
    // Execute touch events on main thread
    __block BOOL success = YES;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (NSDictionary *event in events) {
            int type = [event[@"type"] intValue];
            CGFloat x = [event[@"x"] floatValue];
            CGFloat y = [event[@"y"] floatValue];
            
            BOOL result = NO;
            switch (type) {
                case kZXTouchDown:
                    // Note: We need to add injectTouchDown method
                    result = [KimiRunTouchInjection tapAtX:x Y:y]; // Simplified
                    break;
                case kZXTouchUp:
                    result = YES; // Up is handled by tap
                    break;
                case kZXTouchMove:
                    // Would need swipe implementation
                    result = YES;
                    break;
            }
            
            if (!result) {
                success = NO;
            }
        }
    });
    
    return success ? @"0\r\n" : @"ERROR\r\n";
}

@end