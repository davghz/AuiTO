//
//  KimiRunSleepHook.xm
//  KimiRun - Prevent Sleep Hardware Button Hook
//

#import "KimiRunSleep.h"

// Block sleep from hardware lock button when PreventSleep is enabled.
%hook SBSleepWakeHardwareButtonInteraction
- (void)_performSleep {
    if ([KimiRunSleep blockSideButtonSleepEnabled]) {
        NSLog(@"[KimiRunSleep] Blocked _performSleep (BlockSideButtonSleep enabled)");
        return;
    }
    %orig;
}
%end
