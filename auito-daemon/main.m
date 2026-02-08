#import <Foundation/Foundation.h>
#import "modules/http_server/DaemonHTTPServer.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[KimiRunDaemon] Starting daemon");

        DaemonHTTPServer *server = [[DaemonHTTPServer alloc] init];
        NSError *error = nil;
        NSUInteger port = 8876;
        if (![server startOnPort:port error:&error]) {
            NSLog(@"[KimiRunDaemon] Failed to bind port %lu: %@", (unsigned long)port, error);
            port = 8877;
            error = nil;
            if (![server startOnPort:port error:&error]) {
                NSLog(@"[KimiRunDaemon] Failed to bind fallback port %lu: %@", (unsigned long)port, error);
            } else {
                NSLog(@"[KimiRunDaemon] HTTP server started on fallback port %lu", (unsigned long)port);
            }
        } else {
            NSLog(@"[KimiRunDaemon] HTTP server started on port %lu", (unsigned long)port);
        }

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
