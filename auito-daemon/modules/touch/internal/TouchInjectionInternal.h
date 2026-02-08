#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <IOKit/IOKitLib.h>
#import "../../../headers/IOHIDEvent.h"
#import "../../../headers/BackBoardServices+Extended.h"
#import "../TouchInjection.h"
#import "../AXTouchInjection.h"

// Shared constants
#define kTouchSenderID 0xDEFACEDBEEFFECE5ULL
#define kBKSSenderID 0x8000000817319372ULL
#define kTransducerTypeHand   3
#define kTransducerTypeFinger 2

#define kZXTouchTaskPerformTouch 10
#define kZXTouchTouchUp 0
#define kZXTouchTouchDown 1
#define kZXTouchTouchMove 2

#define kDefaultTapDuration       0.05
#define kDefaultSwipeDuration     0.3
#define kDefaultDragDuration      1.0
#define kDefaultLongPressDuration 1.0

#define kSwipeSteps 20
#define kDragSteps  50

#define kSimulateTouchMaxFingerIndex 20
#define kSimulateTouchPrimaryFingerIndex 1

typedef NS_ENUM(NSInteger, KimiRunTouchPhase) {
    KimiRunTouchPhaseDown = 0,
    KimiRunTouchPhaseMove = 1,
    KimiRunTouchPhaseUp   = 2
};

typedef NS_ENUM(NSInteger, KimiRunSimTouchValidity) {
    KimiRunSimTouchInvalid = 0,
    KimiRunSimTouchValid = 1,
    KimiRunSimTouchValidAtNextAppend = 2
};

enum {
    kSimTouchValidIndex = 0,
    kSimTouchPhaseIndex = 1,
    kSimTouchXIndex = 2,
    kSimTouchYIndex = 3
};

@interface KimiRunTouchInjection (Private)
+ (BOOL)deliverViaBKS:(IOHIDEventRef)event;
@end

// Shared globals from TouchInjection.m
extern BOOL g_initialized;
extern CGFloat g_screenWidth;
extern CGFloat g_screenHeight;
extern CGFloat g_screenScale;
extern CGFloat g_screenPixelWidth;
extern CGFloat g_screenPixelHeight;
extern int g_simEventsToAppend[kSimulateTouchMaxFingerIndex][4];

extern IOHIDEventRef (*_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef allocator,
    uint64_t timeStamp,
    IOHIDDigitizerTransducerType type,
    uint32_t index,
    uint32_t identity,
    IOHIDDigitizerEventMask eventMask,
    uint32_t buttonMask,
    float x,
    float y,
    float z,
    float pressure,
    float barrelPressure,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options);

extern IOHIDEventRef (*_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t index,
    uint32_t identity,
    IOHIDDigitizerEventMask eventMask,
    float x,
    float y,
    float z,
    float pressure,
    float twist,
    Boolean range,
    Boolean touch,
    IOHIDEventOptionBits options);

extern IOHIDEventRef (*_IOHIDEventCreateKeyboardEvent)(CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint16_t usagePage,
    uint16_t usage,
    Boolean down,
    IOHIDEventOptionBits flags);

extern void (*_IOHIDEventSetIntegerValue)(IOHIDEventRef event, IOHIDEventField field, CFIndex value);
extern void (*_IOHIDEventSetFloatValue)(IOHIDEventRef event, IOHIDEventField field, double value);
extern void (*_IOHIDEventSetSenderID)(IOHIDEventRef event, uint64_t senderID);
extern void (*_IOHIDEventAppendEvent)(IOHIDEventRef parent, IOHIDEventRef childEvent, Boolean copy);
extern IOHIDEventType (*_IOHIDEventGetType)(IOHIDEventRef event);
extern uint64_t (*_IOHIDEventGetSenderID)(IOHIDEventRef event);
extern CFArrayRef (*_IOHIDEventGetChildren)(IOHIDEventRef event);

extern IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreate)(CFAllocatorRef allocator);
extern IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreateWithType)(CFAllocatorRef allocator, int type, int options);
extern IOHIDEventSystemClientRef (*_IOHIDEventSystemClientCreateSimpleClient)(CFAllocatorRef allocator);
extern void (*_IOHIDEventSystemClientDispatchEvent)(IOHIDEventSystemClientRef client, IOHIDEventRef event);
extern void (*_IOHIDEventSystemConnectionDispatchEvent)(void *connection, IOHIDEventRef event);
extern void (*_IOHIDEventSystemClientSetDispatchQueue)(IOHIDEventSystemClientRef client, dispatch_queue_t queue);
extern void (*_IOHIDEventSystemClientActivate)(IOHIDEventSystemClientRef client);
extern void (*_IOHIDEventSystemClientScheduleWithRunLoop)(IOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
extern void (*_IOHIDEventSystemClientRegisterEventCallback)(IOHIDEventSystemClientRef client, void *callback, void *target, void *refcon);
extern void (*_IOHIDEventSystemClientUnregisterEventCallback)(IOHIDEventSystemClientRef client);
extern void (*_IOHIDEventSystemClientUnscheduleWithRunLoop)(IOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
extern int (*_IOHIDEventSystemClientSetMatching)(IOHIDEventSystemClientRef client, CFDictionaryRef match);

extern Class g_bksDeliveryManagerClass;
extern id g_bksSharedDeliveryManager;
extern id g_bksSharedRouterManager;

extern IOHIDEventSystemClientRef g_hidClient;
extern IOHIDEventSystemClientRef g_simClient;
extern IOHIDEventSystemClientRef g_adminClient;
extern int g_adminClientType;
extern void *g_hidConnection;

extern IOHIDEventSystemClientRef g_senderClient;
extern uint64_t g_senderID;
extern BOOL g_senderCaptured;
extern int g_senderSource;
extern BOOL g_senderFallbackEnabled;
extern int g_senderCallbackCount;
extern BOOL g_senderThreadRunning;
extern NSThread *g_senderThread;
extern CFRunLoopRef g_senderRunLoop;
extern BOOL g_senderCleanupDone;
extern IOHIDEventSystemClientRef g_senderClientMain;
extern BOOL g_senderMainRegistered;
extern int g_senderCallbackDigitizerCount;
extern int g_senderLastEventType;
extern IOHIDEventSystemClientRef g_senderClientDispatch;
extern BOOL g_senderDispatchRegistered;
extern BOOL g_touchUseMatching;
extern BOOL g_senderUseMatching;
extern BOOL g_senderUseExtraCallbacks;
extern BOOL g_loggedBKHIDSelectors;
extern __weak id g_currentFirstResponder;
extern NSString *const kKimiRunPrefsSuite;
extern volatile BOOL g_bksLastMeaningfulDispatch;
extern volatile CFAbsoluteTime g_bksLastMeaningfulDispatchTime;
extern volatile CFAbsoluteTime g_bksLastFocusHintTime;

// Shared helpers from TouchInjection.m
void KimiRunLog(NSString *line);
NSString *SenderIDPlistPath(void);
uint64_t GetCurrentTimestamp(void);
BOOL UpdateScreenMetrics(void);
void UpdateHIDConnection(void);
void AdjustInputCoordinates(CGFloat *x, CGFloat *y);
void NotifyUserEvent(void);
BOOL ForceFocusSearchField(void);
void KimiRunResolveBKSManagers(void);
void KimiRunApplyBKSFocusHints(void);
BOOL KimiRunApplyBKSEventFocusForPID(int targetPid, NSString *phaseTag, BOOL setAdjustedPID);
BOOL KimiRunApplyBKSSystemAppFocus(BOOL controlsFocus, NSString *phaseTag);
BOOL KimiRunBKSRecentMeaningfulDispatch(NSTimeInterval maxAgeSeconds);
NSDictionary *KimiRunCopyLastBKSDispatchInfo(void);
NSArray<NSDictionary *> *KimiRunCopyRecentBKSDispatchHistory(NSUInteger limit);
void KimiRunRecordBKSDispatchInfo(NSDictionary *info);
void KimiRunRecordBKSDispatchFailure(NSString *reason);
int KimiRunPIDForProcessName(NSString *processName);
int KimiRunFrontmostApplicationPID(void);
NSInteger KimiRunClampInteger(NSInteger value, NSInteger minimum, NSInteger maximum);
NSInteger KimiRunTouchPrefInteger(NSString *key, NSInteger defaultValue);
NSInteger KimiRunTouchEnvInteger(const char *key, NSInteger defaultValue);
NSString *KimiRunTouchEnvOrPrefString(const char *envKey,
                                      NSString *prefKey,
                                      NSString *defaultValue);
NSString *KimiRunNormalizeExperimentMode(NSString *value,
                                         NSArray<NSString *> *allowed,
                                         NSString *fallback);

// SenderID manager exported wrappers
void KimiRunLoadPersistedSenderID(void);
void KimiRunTryLoadSenderIDFromIORegistry(void);
void KimiRunSenderIDThreadMain(void);
void KimiRunRegisterSenderIDCallbackOnMainRunLoop(void);
void KimiRunRegisterSenderIDCallbackOnDispatchQueue(void);
void KimiRunCleanupSenderCallbacks(void);
void KimiRunApplyDigitizerMatching(IOHIDEventSystemClientRef client);
void KimiRunPersistSenderID(uint64_t senderID);

// Strategy router exported wrappers
NSString *KimiRunTouchPrefString(NSString *key);
BOOL KimiRunTouchPrefBool(NSString *key, BOOL defaultValue);
BOOL KimiRunTouchEnvBool(const char *key, BOOL defaultValue);
NSString *KimiRunResolveTouchMethod(NSString *method);
BOOL KimiRunRejectUnverifiedTouchResult(NSString *lowerMethod, NSString *backendTag);
BOOL KimiRunDispatchPhase(KimiRunTouchPhase phase,
                          CGFloat x,
                          CGFloat y,
                          BOOL wantSim,
                          BOOL wantConn,
                          BOOL wantLegacy,
                          BOOL wantBKS,
                          BOOL wantAX,
                          BOOL allowFallback);

// Event builder exported wrappers
BOOL KimiRunDispatchEvent(IOHIDEventRef event);
IOHIDEventRef KimiRunCreateTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y);
IOHIDEventRef KimiRunCreateBKSTouchEvent(uint64_t timestamp, KimiRunTouchPhase phase, CGFloat x, CGFloat y);
BOOL KimiRunPostTouchEvent(KimiRunTouchPhase phase, CGFloat x, CGFloat y);
BOOL KimiRunPostSimulateTouchEvent(KimiRunTouchPhase phase, CGFloat x, CGFloat y);
BOOL KimiRunPostSimulateTouchEventViaConnection(KimiRunTouchPhase phase, CGFloat x, CGFloat y);
BOOL KimiRunPostLegacyTouchEventPhase(KimiRunTouchPhase phase, CGFloat x, CGFloat y);
BOOL KimiRunPostBKSTouchEventPhase(KimiRunTouchPhase phase, CGFloat x, CGFloat y);
BOOL KimiRunDispatchEventWithContextBind(IOHIDEventRef event, NSString **pathOut);
