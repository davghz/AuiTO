#import "AUIVirtualTouch.h"
#import <IOKit/IOReturn.h>
#import <mach/mach_time.h>
#import <dlfcn.h>

// IOHIDUserDevice private API - dynamically resolved at runtime
typedef CFTypeRef IOHIDUserDeviceRef;

typedef IOHIDUserDeviceRef (*IOHIDUserDeviceCreateFunc)(CFAllocatorRef allocator, CFDictionaryRef properties);
typedef IOReturn (*IOHIDUserDeviceHandleReportFunc)(IOHIDUserDeviceRef device, uint8_t *report, CFIndex length);
typedef IOReturn (*IOHIDUserDeviceHandleReportWithTimeStampFunc)(IOHIDUserDeviceRef device, uint64_t timestamp, uint8_t *report, CFIndex length);
typedef void (*IOHIDUserDeviceScheduleWithRunLoopFunc)(IOHIDUserDeviceRef device, CFRunLoopRef runLoop, CFStringRef mode);

static IOHIDUserDeviceCreateFunc _IOHIDUserDeviceCreate = NULL;
static IOHIDUserDeviceHandleReportFunc _IOHIDUserDeviceHandleReport = NULL;
static IOHIDUserDeviceHandleReportWithTimeStampFunc _IOHIDUserDeviceHandleReportWithTimeStamp = NULL;
static IOHIDUserDeviceScheduleWithRunLoopFunc _IOHIDUserDeviceScheduleWithRunLoop = NULL;

static BOOL _auiSymbolsResolved = NO;

static void AUIResolveSymbols(void) {
    if (_auiSymbolsResolved) return;
    _auiSymbolsResolved = YES;

    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!handle) {
        NSLog(@"[AUI] Failed to dlopen IOKit: %s", dlerror());
        return;
    }

    _IOHIDUserDeviceCreate = (IOHIDUserDeviceCreateFunc)dlsym(handle, "IOHIDUserDeviceCreate");
    _IOHIDUserDeviceHandleReport = (IOHIDUserDeviceHandleReportFunc)dlsym(handle, "IOHIDUserDeviceHandleReport");
    _IOHIDUserDeviceHandleReportWithTimeStamp = (IOHIDUserDeviceHandleReportWithTimeStampFunc)dlsym(handle, "IOHIDUserDeviceHandleReportWithTimeStamp");
    _IOHIDUserDeviceScheduleWithRunLoop = (IOHIDUserDeviceScheduleWithRunLoopFunc)dlsym(handle, "IOHIDUserDeviceScheduleWithRunLoop");

    NSLog(@"[AUI] Symbol resolution: Create=%p HandleReport=%p HandleReportTS=%p Schedule=%p",
          _IOHIDUserDeviceCreate, _IOHIDUserDeviceHandleReport,
          _IOHIDUserDeviceHandleReportWithTimeStamp, _IOHIDUserDeviceScheduleWithRunLoop);

    if (!_IOHIDUserDeviceCreate) {
        NSLog(@"[AUI] CRITICAL: IOHIDUserDeviceCreate not found in IOKit");
    }
}

#define AUI_MAX_FINGERS 5
#define AUI_REPORT_ID 1
#define AUI_COORD_MAX 32767

// Report: 1 (report ID) + 5 * 5 (per-finger: tip, contactID, X_lo, X_hi, Y_lo, Y_hi → packed to 5 bytes) + 1 (contact count) = 27 bytes
// Per finger: [tip_switch(1 byte)] [contact_id(1 byte)] [X_lo X_hi] [Y_lo Y_hi] → but plan says 5 bytes per finger
// Plan report: tip(1) + id(1) + X(2) + Y(2) = 6 bytes per finger... but plan table says 5 bytes
// Let's use the correct HID structure: tip(1 bit padded to 1 byte), contact_id(1 byte), X(2 bytes), Y(2 bytes) = 6 bytes
// But plan says 5 bytes per finger total. Let's re-read: "Finger 0: tip+id+x+y | 5 bytes"
// This means tip and id are packed: tip(1 bit) + contactID(7 bits) = 1 byte, X(2), Y(2) = 5 bytes total
// Actually for simplicity and standard HID compliance, let's use:
//   Byte 0: tip switch (1 bit) in low bit, remaining 7 bits padding
//   Byte 1: contact ID (8 bits)
//   Bytes 2-3: X (16-bit LE)
//   Bytes 4-5: Y (16-bit LE)
// = 6 bytes per finger, 5 fingers = 30, + 1 report ID + 1 contact count = 32 bytes
// This matches standard multitouch HID descriptors better.

#define AUI_FINGER_SIZE 6
#define AUI_REPORT_SIZE (1 + AUI_MAX_FINGERS * AUI_FINGER_SIZE + 1) // 32 bytes

// HID Report Descriptor for a multitouch digitizer (5 fingers)
// Standard USB HID multitouch adapted for iOS
static const uint8_t kAUIReportDescriptor[] = {
    0x05, 0x0D,       // Usage Page (Digitizers)
    0x09, 0x04,       // Usage (Touch Screen)
    0xA1, 0x01,       // Collection (Application)
    0x85, AUI_REPORT_ID, // Report ID (1)

    // Finger 0
    0x05, 0x0D,       //   Usage Page (Digitizers)
    0x09, 0x22,       //   Usage (Finger)
    0xA1, 0x02,       //   Collection (Logical)
    0x09, 0x42,       //     Usage (Tip Switch)
    0x15, 0x00,       //     Logical Minimum (0)
    0x25, 0x01,       //     Logical Maximum (1)
    0x75, 0x01,       //     Report Size (1)
    0x95, 0x01,       //     Report Count (1)
    0x81, 0x02,       //     Input (Data, Variable, Absolute)
    0x75, 0x07,       //     Report Size (7) - padding
    0x95, 0x01,       //     Report Count (1)
    0x81, 0x03,       //     Input (Constant, Variable, Absolute)
    0x09, 0x51,       //     Usage (Contact Identifier)
    0x15, 0x00,       //     Logical Minimum (0)
    0x25, 0x1F,       //     Logical Maximum (31)
    0x75, 0x08,       //     Report Size (8)
    0x95, 0x01,       //     Report Count (1)
    0x81, 0x02,       //     Input (Data, Variable, Absolute)
    0x05, 0x01,       //     Usage Page (Generic Desktop)
    0x09, 0x30,       //     Usage (X)
    0x15, 0x00,       //     Logical Minimum (0)
    0x26, 0xFF, 0x7F, //     Logical Maximum (32767)
    0x75, 0x10,       //     Report Size (16)
    0x95, 0x01,       //     Report Count (1)
    0x81, 0x02,       //     Input (Data, Variable, Absolute)
    0x09, 0x31,       //     Usage (Y)
    0x15, 0x00,       //     Logical Minimum (0)
    0x26, 0xFF, 0x7F, //     Logical Maximum (32767)
    0x75, 0x10,       //     Report Size (16)
    0x95, 0x01,       //     Report Count (1)
    0x81, 0x02,       //     Input (Data, Variable, Absolute)
    0xC0,             //   End Collection (Logical)

    // Finger 1
    0x05, 0x0D,
    0x09, 0x22,
    0xA1, 0x02,
    0x09, 0x42,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x01,
    0x81, 0x02,
    0x75, 0x07,
    0x95, 0x01,
    0x81, 0x03,
    0x09, 0x51,
    0x15, 0x00,
    0x25, 0x1F,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x02,
    0x05, 0x01,
    0x09, 0x30,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0x09, 0x31,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0xC0,

    // Finger 2
    0x05, 0x0D,
    0x09, 0x22,
    0xA1, 0x02,
    0x09, 0x42,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x01,
    0x81, 0x02,
    0x75, 0x07,
    0x95, 0x01,
    0x81, 0x03,
    0x09, 0x51,
    0x15, 0x00,
    0x25, 0x1F,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x02,
    0x05, 0x01,
    0x09, 0x30,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0x09, 0x31,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0xC0,

    // Finger 3
    0x05, 0x0D,
    0x09, 0x22,
    0xA1, 0x02,
    0x09, 0x42,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x01,
    0x81, 0x02,
    0x75, 0x07,
    0x95, 0x01,
    0x81, 0x03,
    0x09, 0x51,
    0x15, 0x00,
    0x25, 0x1F,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x02,
    0x05, 0x01,
    0x09, 0x30,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0x09, 0x31,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0xC0,

    // Finger 4
    0x05, 0x0D,
    0x09, 0x22,
    0xA1, 0x02,
    0x09, 0x42,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x01,
    0x81, 0x02,
    0x75, 0x07,
    0x95, 0x01,
    0x81, 0x03,
    0x09, 0x51,
    0x15, 0x00,
    0x25, 0x1F,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x02,
    0x05, 0x01,
    0x09, 0x30,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0x09, 0x31,
    0x15, 0x00,
    0x26, 0xFF, 0x7F,
    0x75, 0x10,
    0x95, 0x01,
    0x81, 0x02,
    0xC0,

    // Contact Count
    0x05, 0x0D,       //   Usage Page (Digitizers)
    0x09, 0x54,       //   Usage (Contact Count)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x05,       //   Logical Maximum (5)
    0x75, 0x08,       //   Report Size (8)
    0x95, 0x01,       //   Report Count (1)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)

    // Contact Count Maximum (Feature report)
    0x05, 0x0D,       //   Usage Page (Digitizers)
    0x09, 0x55,       //   Usage (Contact Count Maximum)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x05,       //   Logical Maximum (5)
    0x75, 0x08,       //   Report Size (8)
    0x95, 0x01,       //   Report Count (1)
    0x85, 0x02,       //   Report ID (2) - Feature report
    0xB1, 0x02,       //   Feature (Data, Variable, Absolute)

    0xC0              // End Collection (Application)
};

typedef struct {
    uint8_t tipSwitch;   // 1 = touching, 0 = not touching (only low bit used)
    uint8_t contactID;
    uint16_t x;          // little-endian
    uint16_t y;          // little-endian
} __attribute__((packed)) AUIFingerState;

@interface AUIVirtualTouch () {
    IOHIDUserDeviceRef _device;
    AUIFingerState _fingers[AUI_MAX_FINGERS];
    uint8_t _activeCount;
}
@end

@implementation AUIVirtualTouch

- (instancetype)init {
    self = [super init];
    if (self) {
        _device = NULL;
        memset(_fingers, 0, sizeof(_fingers));
        for (int i = 0; i < AUI_MAX_FINGERS; i++) {
            _fingers[i].contactID = i;
        }
        _activeCount = 0;
    }
    return self;
}

- (void)dealloc {
    [self destroyDevice];
}

- (BOOL)deviceActive {
    return _device != NULL;
}

- (BOOL)createDevice {
    if (_device) {
        NSLog(@"[AUI] Device already created");
        return YES;
    }

    AUIResolveSymbols();

    if (!_IOHIDUserDeviceCreate) {
        NSLog(@"[AUI] ERROR: IOHIDUserDeviceCreate symbol not available");
        return NO;
    }

    NSData *descriptorData = [NSData dataWithBytes:kAUIReportDescriptor length:sizeof(kAUIReportDescriptor)];

    NSDictionary *properties = @{
        @"HIDReportDescriptor": descriptorData,
        @"Product": @"AUI Virtual Touch Screen",
        @"VendorID": @(0x05AC),      // Apple vendor ID
        @"ProductID": @(0x8240),     // Unique product ID for our virtual device
        @"Transport": @"Virtual",
        @"PrimaryUsagePage": @(0x0D), // Digitizers
        @"PrimaryUsage": @(0x04),     // Touch Screen
    };

    NSLog(@"[AUI] Creating IOHIDUserDevice with multitouch descriptor (%lu bytes)",
          (unsigned long)sizeof(kAUIReportDescriptor));

    _device = _IOHIDUserDeviceCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties);

    if (!_device) {
        NSLog(@"[AUI] ERROR: IOHIDUserDeviceCreate returned NULL - device creation failed");
        NSLog(@"[AUI] This may require entitlements or different properties");
        return NO;
    }

    NSLog(@"[AUI] IOHIDUserDevice created successfully: %@", _device);

    // Schedule with the current run loop so the device stays alive
    if (_IOHIDUserDeviceScheduleWithRunLoop) {
        _IOHIDUserDeviceScheduleWithRunLoop(_device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        NSLog(@"[AUI] Device scheduled with run loop");
    } else {
        NSLog(@"[AUI] WARNING: IOHIDUserDeviceScheduleWithRunLoop not available, skipping");
    }

    // Send an initial empty report to register the device
    [self _sendReport];

    NSLog(@"[AUI] Virtual multitouch digitizer is active");
    return YES;
}

- (void)destroyDevice {
    if (_device) {
        NSLog(@"[AUI] Destroying virtual device");
        CFRelease(_device);
        _device = NULL;
    }
    memset(_fingers, 0, sizeof(_fingers));
    _activeCount = 0;
}

#pragma mark - Touch Methods

- (BOOL)touchDownWithFinger:(uint8_t)finger x:(uint16_t)x y:(uint16_t)y {
    if (!_device) {
        NSLog(@"[AUI] touchDown: device not active");
        return NO;
    }
    if (finger >= AUI_MAX_FINGERS) {
        NSLog(@"[AUI] touchDown: invalid finger %u (max %d)", finger, AUI_MAX_FINGERS - 1);
        return NO;
    }

    _fingers[finger].tipSwitch = 1;
    _fingers[finger].contactID = finger;
    _fingers[finger].x = x;
    _fingers[finger].y = y;
    [self _updateActiveCount];

    NSLog(@"[AUI] touchDown finger=%u x=%u y=%u count=%u", finger, x, y, _activeCount);
    return [self _sendReport];
}

- (BOOL)touchMoveWithFinger:(uint8_t)finger x:(uint16_t)x y:(uint16_t)y {
    if (!_device) {
        NSLog(@"[AUI] touchMove: device not active");
        return NO;
    }
    if (finger >= AUI_MAX_FINGERS) {
        return NO;
    }
    if (!_fingers[finger].tipSwitch) {
        NSLog(@"[AUI] touchMove: finger %u not down, sending down first", finger);
        return [self touchDownWithFinger:finger x:x y:y];
    }

    _fingers[finger].x = x;
    _fingers[finger].y = y;

    return [self _sendReport];
}

- (BOOL)touchUpWithFinger:(uint8_t)finger {
    if (!_device) {
        NSLog(@"[AUI] touchUp: device not active");
        return NO;
    }
    if (finger >= AUI_MAX_FINGERS) {
        return NO;
    }

    _fingers[finger].tipSwitch = 0;
    [self _updateActiveCount];

    NSLog(@"[AUI] touchUp finger=%u count=%u", finger, _activeCount);
    BOOL result = [self _sendReport];

    // Clear finger state after sending the up report
    _fingers[finger].x = 0;
    _fingers[finger].y = 0;

    return result;
}

- (BOOL)tapAtX:(uint16_t)x y:(uint16_t)y {
    NSLog(@"[AUI] tap at x=%u y=%u", x, y);

    if (![self touchDownWithFinger:0 x:x y:y]) {
        return NO;
    }

    // Hold for 80ms
    usleep(80000);

    return [self touchUpWithFinger:0];
}

- (BOOL)swipeFromX:(uint16_t)x1 y:(uint16_t)y1
             toX:(uint16_t)x2 y:(uint16_t)y2
        duration:(NSTimeInterval)duration
           steps:(NSUInteger)steps {
    if (steps == 0) steps = 20;
    if (duration <= 0) duration = 0.3;

    NSLog(@"[AUI] swipe (%u,%u)->(%u,%u) duration=%.3f steps=%lu",
          x1, y1, x2, y2, duration, (unsigned long)steps);

    // Finger down at start
    if (![self touchDownWithFinger:0 x:x1 y:y1]) {
        return NO;
    }

    NSTimeInterval stepDelay = duration / (NSTimeInterval)steps;

    // Interpolate movement
    for (NSUInteger i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)steps;
        uint16_t cx = (uint16_t)((1.0 - t) * x1 + t * x2);
        uint16_t cy = (uint16_t)((1.0 - t) * y1 + t * y2);

        usleep((useconds_t)(stepDelay * 1000000));

        if (![self touchMoveWithFinger:0 x:cx y:cy]) {
            [self touchUpWithFinger:0];
            return NO;
        }
    }

    // Small delay before lift
    usleep(10000);

    return [self touchUpWithFinger:0];
}

#pragma mark - Internal

- (void)_updateActiveCount {
    uint8_t count = 0;
    for (int i = 0; i < AUI_MAX_FINGERS; i++) {
        if (_fingers[i].tipSwitch) count++;
    }
    _activeCount = count;
}

- (BOOL)_sendReport {
    if (!_device) return NO;

    uint8_t report[AUI_REPORT_SIZE];
    memset(report, 0, sizeof(report));

    // Report ID
    report[0] = AUI_REPORT_ID;

    // Pack each finger: 6 bytes per finger
    for (int i = 0; i < AUI_MAX_FINGERS; i++) {
        int offset = 1 + i * AUI_FINGER_SIZE;
        report[offset + 0] = _fingers[i].tipSwitch & 0x01;
        report[offset + 1] = _fingers[i].contactID;
        report[offset + 2] = (uint8_t)(_fingers[i].x & 0xFF);
        report[offset + 3] = (uint8_t)((_fingers[i].x >> 8) & 0xFF);
        report[offset + 4] = (uint8_t)(_fingers[i].y & 0xFF);
        report[offset + 5] = (uint8_t)((_fingers[i].y >> 8) & 0xFF);
    }

    // Contact count at the end
    report[1 + AUI_MAX_FINGERS * AUI_FINGER_SIZE] = _activeCount;

    // Use timestamp version if available, fallback to non-timestamp version
    IOReturn ret;
    if (_IOHIDUserDeviceHandleReportWithTimeStamp) {
        uint64_t timestamp = mach_absolute_time();
        ret = _IOHIDUserDeviceHandleReportWithTimeStamp(_device, timestamp, report, sizeof(report));
    } else if (_IOHIDUserDeviceHandleReport) {
        ret = _IOHIDUserDeviceHandleReport(_device, report, sizeof(report));
    } else {
        NSLog(@"[AUI] ERROR: No IOHIDUserDeviceHandleReport symbol available");
        return NO;
    }

    if (ret != kIOReturnSuccess) {
        NSLog(@"[AUI] IOHIDUserDeviceHandleReport failed: 0x%x", ret);
        return NO;
    }

    return YES;
}

@end
