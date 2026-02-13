#import <Foundation/Foundation.h>
#import "AUIVirtualTouch.h"
#import "AUIHTTPServer.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[AUI] Starting AUI Virtual Touch daemon");

        // Create virtual multitouch digitizer
        AUIVirtualTouch *touch = [[AUIVirtualTouch alloc] init];
        BOOL deviceOK = [touch createDevice];

        if (deviceOK) {
            NSLog(@"[AUI] Virtual HID device created successfully");
        } else {
            NSLog(@"[AUI] WARNING: Virtual HID device creation failed - touch will not work");
            NSLog(@"[AUI] HTTP server will still start for diagnostics");
        }

        // Start HTTP server
        AUIHTTPServer *server = [[AUIHTTPServer alloc] init];
        server.touch = touch;

        NSError *error = nil;
        NSUInteger port = 8877;
        if (![server startOnPort:port error:&error]) {
            NSLog(@"[AUI] Failed to bind port %lu: %@", (unsigned long)port, error);
            port = 8878;
            error = nil;
            if (![server startOnPort:port error:&error]) {
                NSLog(@"[AUI] Failed to bind fallback port %lu: %@", (unsigned long)port, error);
            } else {
                NSLog(@"[AUI] HTTP server started on fallback port %lu", (unsigned long)port);
            }
        } else {
            NSLog(@"[AUI] HTTP server started on port %lu", (unsigned long)port);
        }

        // Run forever
        NSLog(@"[AUI] Entering run loop");
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
