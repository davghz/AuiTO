/*
 * BackBoardServices+Extended.h
 *
 * Declaration-only extensions for iOS 13.2.3 BackBoardServices touch/HID APIs.
 * This file is intentionally minimal and safe for dynamic invocation experiments.
 * No runtime behavior is introduced by this header.
 */

#ifndef BACKBOARDSERVICES_EXTENDED_H
#define BACKBOARDSERVICES_EXTENDED_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "BackBoardServices.h"
#import "IOHIDEvent.h"
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Forward Declarations

@class BKSEventFocusDeferralProperties;
@class BKSHIDEventBaseAttributes;
@class BKSHIDEventDeferringEnvironment;
@class BKSHIDEventDeferringResolution;
@class BKSHIDEventDeferringToken;
@class BKSHIDEventDisplay;
@class BKSHIDEventDiscreteDispatchingPredicate;
@class BKSHIDEventDispatchingTarget;
@class BKSHIDEventRouter;
@class BKSHIDEventSenderDescriptor;
@class BKSHIDEventDescriptor;
@class BKSHIDEventRedirectAttributes;
@class BSServiceConnection;
@class BSMutableIntegerMap;
@class UIApplication;
@class NSHashTable;
@class NSMapTable;
@protocol OS_dispatch_queue;
@protocol OS_xpc_object;

#pragma mark - Runtime HID Manager Classes (undeclared in public SDK headers)

@interface BKAccessibility : NSObject

+ (id)_eventRoutingClientConnectionManager;

@end

@interface BKHIDClientConnectionManager : NSObject

+ (instancetype)sharedInstance;
+ (instancetype)sharedManager;
+ (instancetype)defaultManager;
+ (instancetype)manager;
- (void *)clientForTaskPort:(mach_port_t)port;

@end

#pragma mark - Focus Manager / Routing

@interface BKSEventFocusManager : NSObject

+ (instancetype)sharedInstance;
- (void)setSystemAppControlsFocusOnMainDisplay:(BOOL)controlsFocus;
- (void)setForegroundApplicationOnMainDisplay:(id)foreground pid:(int)pid;
- (void)flush;
- (id)foregroundApplicationOnMainDisplay;
- (id)foregroundApplication;
- (int)foregroundApplicationProcessIDOnMainDisplay;
- (int)foregroundAppPIDOnMainDisplay;
- (int)foregroundAppPID;
- (int)activeApplicationPID;
- (int)activeApplicationProcessID;

@end

@interface BKSHIDEventDispatchingTarget (Extended)

+ (instancetype)focusTargetForPID:(int)pid;
+ (instancetype)targetForPID:(int)pid environment:(id)environment;
+ (instancetype)targetForDeferringEnvironment:(id)environment;
+ (instancetype)keyboardFocusTarget;
+ (instancetype)systemTarget;
@property(readonly, nonatomic) int pid;
@property(readonly, copy, nonatomic) BKSHIDEventDeferringEnvironment *deferringEnvironment;

@end

@interface BKSHIDEventRouterManager : NSObject

+ (instancetype)sharedInstance;
@property(retain, nonatomic) NSArray *eventRouters;
- (id)_targetForDestination:(long long)destination;

@end

@interface BKSHIDEventRouter : NSObject

+ (instancetype)defaultEventRouters;
+ (instancetype)defaultFocusedAppEventRouter;
+ (instancetype)defaultSystemAppEventRouter;
+ (instancetype)routerWithDestination:(long long)destination;
@property(readonly, nonatomic) long long destination;
@property(readonly, copy, nonatomic) NSSet *hidEventDescriptors;
- (void)addHIDEventDescriptors:(NSSet *)descriptors;

@end

@interface BKSHIDEventDisplay (Extended)

+ (instancetype)displayWithHardwareIdentifier:(NSString *)hardwareIdentifier;
+ (instancetype)builtinDisplay;
+ (instancetype)nullDisplay;

@end

@interface BKSHIDEventDeferringEnvironment : NSObject

+ (instancetype)environmentWithIdentifier:(NSString *)identifier;
+ (instancetype)keyboardFocusEnvironment;
+ (instancetype)systemEnvironment;

@end

#pragma mark - Sender Descriptor APIs

@interface BKSHIDEventSenderDescriptor : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>

+ (instancetype)wildcard;
+ (instancetype)build:(id)builder;

@property(readonly, nonatomic) long long hardwareType;
@property(readonly, nonatomic, getter=isAuthenticated) BOOL authenticated;
@property(readonly, nonatomic) BKSHIDEventDisplay *associatedDisplay;
@property(readonly, nonatomic) unsigned int primaryPage;
@property(readonly, nonatomic) unsigned int primaryUsage;

@end

@interface BKSMutableHIDEventSenderDescriptor : BKSHIDEventSenderDescriptor

- (void)setPrimaryPage:(unsigned int)page primaryUsage:(unsigned int)usage;
@property(nonatomic) long long hardwareType;
@property(nonatomic, getter=isAuthenticated) BOOL authenticated;
@property(copy, nonatomic) BKSHIDEventDisplay *associatedDisplay;

@end

@interface BKSHIDEventDiscreteDispatchingPredicate : NSObject <NSSecureCoding, NSCopying, NSMutableCopying>

@property(readonly, copy, nonatomic) NSSet *descriptors;
@property(readonly, copy, nonatomic) NSSet *senderDescriptors;
@property(readonly, copy, nonatomic) NSSet *displays;
- (instancetype)_initWithSourceDescriptors:(nullable NSSet *)sourceDescriptors
                               descriptors:(NSSet *)descriptors;

@end

@interface BKSMutableHIDEventDiscreteDispatchingPredicate : BKSHIDEventDiscreteDispatchingPredicate

+ (instancetype)defaultFocusPredicate;
+ (instancetype)defaultSystemPredicate;
@property(copy, nonatomic) NSSet *descriptors;
@property(copy, nonatomic) NSSet *senderDescriptors;
@property(copy, nonatomic) NSSet *displays;

@end

@interface BKSHIDEventSenderSpecificDescriptor : BKSHIDEventDescriptor

- (instancetype)initWithDescriptor:(BKSHIDEventDescriptor *)descriptor senderID:(NSUInteger)senderID;
@property(readonly, nonatomic) NSUInteger senderID;
@property(retain, nonatomic) BKSHIDEventDescriptor *sourceDescriptor;

@end

#pragma mark - Digitizer Attributes

// Keep superclass as NSObject to avoid requiring private superclass headers at compile time.
@interface BKSHIDEventDigitizerAttributes : NSObject

@property(nonatomic) float maximumForce;

@end

#pragma mark - Focus / Deferral

@interface BKSEventFocusDeferral : NSObject <NSSecureCoding>

- (instancetype)initWithProperties:(BKSEventFocusDeferralProperties *)properties
                deferredProperties:(BKSEventFocusDeferralProperties *)deferredProperties;
- (instancetype)initWithProperties:(BKSEventFocusDeferralProperties *)properties
                deferredProperties:(BKSEventFocusDeferralProperties *)deferredProperties
                      withPriority:(int)priority;
- (BOOL)defersProperties:(BKSEventFocusDeferralProperties *)properties;
- (BKSEventFocusDeferralProperties *)deferredPropertiesForProperties:(BKSEventFocusDeferralProperties *)properties;

@property(readonly, nonatomic) BKSEventFocusDeferralProperties *properties;
@property(readonly, nonatomic) BKSEventFocusDeferralProperties *deferredProperties;
@property(readonly, nonatomic) int priority;
@property(readonly, nonatomic) BOOL isCycle;

@end

@interface BKSEventFocusDeferralProperties : NSObject <NSSecureCoding>

+ (instancetype)propertiesWithClientID:(NSString *)clientID
                                   pid:(int)pid
                           displayUUID:(nullable NSString *)displayUUID
                             contextID:(unsigned int)contextID;
+ (instancetype)propertiesWithMainDisplayAndClientID:(NSString *)clientID
                                                 pid:(int)pid
                                           contextID:(unsigned int)contextID;
@property(readonly, nonatomic) unsigned int contextID;
@property(readonly, copy, nonatomic) NSString *displayUUID;
@property(readonly, nonatomic) int pid;
@property(readonly, copy, nonatomic) NSString *clientID;

@end

@interface BKSHIDEventDeferringTarget (Extended)

@property(readonly, nonatomic) int pid;
@property(readonly, copy, nonatomic) BKSHIDEventDeferringToken *token;

@end

@interface BKSMutableHIDEventDeferringTarget : BKSHIDEventDeferringTarget

@property(copy, nonatomic) BKSHIDEventDeferringToken *token;
@property(nonatomic) int pid;

@end

@interface BKSHIDEventDeferringPredicate (Extended)

@property(readonly, nonatomic) BKSHIDEventDeferringEnvironment *environment;
@property(readonly, copy, nonatomic) BKSHIDEventDisplay *display;
@property(readonly, copy, nonatomic) BKSHIDEventDeferringToken *token;

@end

@interface BKSMutableHIDEventDeferringPredicate : BKSHIDEventDeferringPredicate

@property(copy, nonatomic) BKSHIDEventDeferringToken *token;
@property(copy, nonatomic) BKSHIDEventDisplay *display;
@property(retain, nonatomic) BKSHIDEventDeferringEnvironment *environment;

@end

@interface BKSHIDEventDeferringResolution : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>

@property(readonly, copy, nonatomic) BKSHIDEventDeferringToken *token;
@property(readonly, nonatomic) int pid;
@property(readonly, copy, nonatomic) BKSHIDEventDeferringEnvironment *environment;
@property(readonly, copy, nonatomic) BKSHIDEventDisplay *display;

@end

@interface BKSMutableHIDEventDeferringResolution : BKSHIDEventDeferringResolution

@property(copy, nonatomic) BKSHIDEventDeferringToken *token;
@property(nonatomic) int pid;
@property(copy, nonatomic) BKSHIDEventDeferringEnvironment *environment;
@property(copy, nonatomic) BKSHIDEventDisplay *display;

@end

@interface BKSHIDEventDeferringRule : NSObject <NSCopying, NSSecureCoding>

+ (instancetype)ruleForDeferringEventsMatchingPredicate:(BKSHIDEventDeferringPredicate *)predicate
                                               toTarget:(BKSHIDEventDeferringTarget *)target
                                             withReason:(NSString *)reason;

@property(readonly, copy, nonatomic) BKSHIDEventDeferringPredicate *predicate;
@property(readonly, copy, nonatomic) BKSHIDEventDeferringTarget *target;
@property(readonly, copy, nonatomic) NSString *reason;

@end

@interface BKSHIDEventDiscreteDispatchingRule : NSObject <NSSecureCoding, NSCopying>

+ (instancetype)ruleForDispatchingDiscreteEventsMatchingPredicate:(BKSHIDEventDiscreteDispatchingPredicate *)predicate
                                                         toTarget:(BKSHIDEventDispatchingTarget *)target;

@property(readonly, copy, nonatomic) BKSHIDEventDiscreteDispatchingPredicate *predicate;
@property(readonly, copy, nonatomic) BKSHIDEventDispatchingTarget *target;

@end

@interface BKSHIDEventRedirectAttributes : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) int pid;

@end

#pragma mark - Touch Delivery Observation

@interface BKSTouchDeliveryObservationService : NSObject

+ (instancetype)sharedInstance;
- (oneway void)addObserver:(id)observer;
- (oneway void)addObserver:(id)observer forTouchIdentifier:(unsigned int)touchIdentifier;
- (oneway void)removeObserver:(id)observer;

@property(retain, nonatomic) BSServiceConnection *connection;
@property(retain, nonatomic) BSMutableIntegerMap *touchIdentifierToObserverLists;
@property(retain, nonatomic) NSMapTable *observersToTouchIdentifiers;
@property(retain, nonatomic) NSHashTable *generalObservers;

@end

#pragma mark - Touch Delivery Policy Extensions

@interface BKSTouchDeliveryPolicy (Extended)

@property(retain, nonatomic) NSObject<OS_xpc_object> *assertionEndpoint;
- (id)reducePolicyToObjectWithBlock:(id)block;
- (id)policyByMappingContainedPoliciesWithBlock:(id)block;

@end

@interface BKSTouchDeliveryPolicyAssertion : NSObject

- (void)invalidate;
- (id)endpoint;

@end

@interface BKSTouchDeliveryUpdate : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) BOOL isDetached;
@property(nonatomic) unsigned int touchIdentifier;
@property(nonatomic) unsigned int contextID;
@property(nonatomic) int pid;
@property(nonatomic) long long type;

@end

#pragma mark - Private Delivery Manager Helpers (Typed Invocation)

@interface BKSHIDEventDeliveryManager (ExtendedPrivate)

- (void)_setFocusTargetOverride:(nullable BKSHIDEventDispatchingTarget *)target;
- (void)_syncServiceFlushState;

@end

#pragma mark - BackBoardServices Touch SPI (exported in .tbd, missing from SDK headers)

// Known signature from iOS 13-era projects (TouchSimulator/IOS13 SimulateTouch derivatives).
typedef void (*BKSHIDEventSetDigitizerInfoFunc)(IOHIDEventRef event,
                                                uint32_t contextID,
                                                uint8_t systemGestureIsPotential,
                                                uint8_t systemGestureStage,
                                                CFStringRef _Nullable displayUUID,
                                                CFTimeInterval maxForce,
                                                CFTimeInterval twist);
typedef void (*BKSHIDEventSetDigitizerInfoWithTouchStreamIdentifierFunc)(IOHIDEventRef event,
                                                                          uint32_t contextID,
                                                                          uint8_t systemGestureIsPotential,
                                                                          uint8_t systemGestureStage,
                                                                          CFStringRef _Nullable displayUUID,
                                                                          CFTimeInterval maxForce,
                                                                          CFTimeInterval twist,
                                                                          uint64_t touchStreamIdentifier);
typedef void (*BKSHIDEventSetDigitizerInfoWithSubEventInfosFunc)(IOHIDEventRef event,
                                                                  uint32_t contextID,
                                                                  uint8_t systemGestureIsPotential,
                                                                  uint8_t systemGestureStage,
                                                                  CFStringRef _Nullable displayUUID,
                                                                  CFArrayRef _Nullable subEventInfos,
                                                                  CFTimeInterval maxForce,
                                                                  CFTimeInterval twist);
typedef void (*BKSHIDEventSetDigitizerInfoWithSubEventInfoAndTouchStreamIdentifierFunc)(IOHIDEventRef event,
                                                                                          uint32_t contextID,
                                                                                          uint8_t systemGestureIsPotential,
                                                                                          uint8_t systemGestureStage,
                                                                                          CFStringRef _Nullable displayUUID,
                                                                                          CFArrayRef _Nullable subEventInfos,
                                                                                          CFTimeInterval maxForce,
                                                                                          CFTimeInterval twist,
                                                                                          uint64_t touchStreamIdentifier);

typedef BKSHIDEventBaseAttributes * _Nullable (*BKSHIDEventGetBaseAttributesFunc)(IOHIDEventRef event);
typedef BKSHIDEventDigitizerAttributes * _Nullable (*BKSHIDEventGetDigitizerAttributesFunc)(IOHIDEventRef event);
typedef uint32_t (*BKSHIDEventGetContextIDFromEventFunc)(IOHIDEventRef event);
typedef uint32_t (*BKSHIDEventGetContextIDFromDigitizerEventFunc)(IOHIDEventRef event);
typedef uint64_t (*BKSHIDEventGetTouchStreamIdentifierFunc)(IOHIDEventRef event);
typedef int32_t (*BKSHIDEventGetClientIdentifierFunc)(IOHIDEventRef event);
typedef pid_t (*BKSHIDEventGetClientPidFunc)(IOHIDEventRef event);
typedef uint32_t (*BKSHIDEventDigitizerGetTouchIdentifierFunc)(IOHIDEventRef event);
typedef uint32_t (*BKSHIDEventDigitizerGetTouchUserIdentifierFunc)(IOHIDEventRef event);
typedef uint32_t (*BKSHIDEventDigitizerGetTouchLocusFunc)(IOHIDEventRef event);
typedef CGPoint (*BKSHIDEventGetPointFromDigitizerEventFunc)(IOHIDEventRef event);
typedef CGPoint (*BKSHIDEventGetHitTestPointFromDigitizerEventForPathEventFunc)(IOHIDEventRef digitizerEvent,
                                                                                  IOHIDEventRef pathEvent);
typedef CGPoint (*BKSHIDEventGetPrecisePointFromDigitizerEventForPathEventFunc)(IOHIDEventRef digitizerEvent,
                                                                                  IOHIDEventRef pathEvent);
typedef double (*BKSHIDEventGetMaximumForceFromDigitizerEventFunc)(IOHIDEventRef event);
typedef uint64_t (*BKSHIDEventGetInitialTouchTimestampFromDigitizerEventFunc)(IOHIDEventRef event);
typedef bool (*BKSHIDEventGetIsSystemAppEventFromEventFunc)(IOHIDEventRef event);
typedef bool (*BKSHIDEventGetIsSystemGestureStateChangeFromDigitizerEventFunc)(IOHIDEventRef event);
typedef int (*BKSHIDEventGetSystemGestureStatusFromDigitizerEventFunc)(IOHIDEventRef event);
typedef CFStringRef _Nullable (*BKSHIDEventDescriptionFunc)(IOHIDEventRef event);
typedef CFStringRef _Nullable (*BKSHIDEventGetConciseDescriptionFunc)(IOHIDEventRef event);
typedef CFStringRef _Nullable (*BKSHIDEventSourceStringNameFunc)(int source);
typedef CFStringRef _Nullable (*BKSHIDEventCopyDisplayIDFromEventFunc)(IOHIDEventRef event);
typedef CFStringRef _Nullable (*BKSHIDEventCopyDisplayIDFromDigitizerEventFunc)(IOHIDEventRef event);
typedef void (*BKSHIDEventSetBaseAttributesFunc)(IOHIDEventRef event, BKSHIDEventBaseAttributes * _Nullable attributes);
typedef void (*BKSHIDEventSetDigitizerAttributesFunc)(IOHIDEventRef event, BKSHIDEventDigitizerAttributes * _Nullable attributes);
typedef void (*BKSHIDEventSetSimpleInfoFunc)(IOHIDEventRef event, int source, uint32_t contextID);
typedef void (*BKSHIDEventSetSimpleDeliveryInfoFunc)(IOHIDEventRef event, int source, uint32_t contextID, CFStringRef _Nullable displayUUID);
typedef bool (*BKSHIDEventContainsUpdatesFunc)(IOHIDEventRef event);
typedef void (*BKSHIDEventRegisterEventCallbackFunc)(id _Nullable callback);
typedef void (*BKSHIDEventRegisterEventCallbackOnRunLoopFunc)(CFRunLoopRef _Nullable runloop,
                                                               CFStringRef _Nullable mode,
                                                               id _Nullable callback);
typedef void (*BKSHIDEventEnumerateChildEventsFunc)(IOHIDEventRef event, void * _Nullable block);
typedef void (*BKSHIDEventEnumerateUpdatesWithBlockFunc)(IOHIDEventRef event, void * _Nullable block);

// Useful SPI often used to force direct process consumption after routing.
typedef void (*BKSHIDEventSendToFocusedProcessFunc)(IOHIDEventRef event);
typedef void (*BKSHIDEventSendToProcessFunc)(IOHIDEventRef event, pid_t pid);
typedef void (*BKSHIDEventSendToProcessAndFollowDeferringRulesFunc)(IOHIDEventRef event, pid_t pid);
typedef void (*BKSHIDEventSendToApplicationWithBundleIDFunc)(IOHIDEventRef event, CFStringRef bundleID);
typedef void (*BKSHIDEventSendToApplicationWithBundleIDAndPidFunc)(IOHIDEventRef event, CFStringRef bundleID, pid_t pid);
typedef void (*BKSHIDEventSendToApplicationWithBundleIDAndPidAndFollowingFocusChainFunc)(IOHIDEventRef event, CFStringRef bundleID, pid_t pid);
typedef void (*BKSHIDEventSendToResolvedProcessForDeferringEnvironmentFunc)(IOHIDEventRef event, BKSHIDEventDeferringEnvironment *environment);
typedef void (*BKSHIDSetEventDeferringRulesFunc)(CFArrayRef _Nullable rules);
typedef void (*BKSHIDSetEventDeferringRulesForClientFunc)(CFArrayRef _Nullable rules, int clientPid);
typedef void (*BKSHIDServicesCancelTouchesOnMainDisplayFunc)(void);
typedef void (*BKSHIDEventDigitizerDetachTouchesFunc)(IOHIDEventRef event);
typedef void (*BKSHIDEventDigitizerDetachTouchesWithIdentifiersFunc)(IOHIDEventRef event, CFArrayRef _Nullable identifiers);
typedef void (*BKSHIDEventDigitizerDetachTouchesWithIdentifiersAndPolicyFunc)(IOHIDEventRef event, CFArrayRef _Nullable identifiers, int policy);
typedef void (*BKSHIDEventDigitizerSetTouchRoutingPolicyFunc)(IOHIDEventRef event, int policy);
typedef void (*BKHIDServicesCancelPhysicalButtonEventsFunc)(void);
typedef int (*BKHIDServicesGetCurrentDeviceOrientationFunc)(void);
typedef int (*BKHIDServicesGetNonFlatDeviceOrientationFunc)(void);
typedef void (*BKSHIDEventSetRedirectInfoFunc)(IOHIDEventRef event, BKSHIDEventRedirectAttributes * _Nullable redirectAttributes);
typedef void (*_BKSHIDEventSetRedirectInfoFunc)(IOHIDEventRef event, BKSHIDEventRedirectAttributes * _Nullable redirectAttributes);

@interface UIApplication (AuiTOHIDPrivate)
- (void)_enqueueHIDEvent:(IOHIDEventRef)event;
@end

// Context ID selectors are used by known iOS13/14 touch injectors and remain private.
// Declare both spellings for runtime-safe probing in event builders.
@interface UIWindow (AuiTOHIDPrivate)
- (unsigned int)_contextId;
- (unsigned int)_contextID;
@end

// Some runtimes export a private-symbol variant for per-client deferring rules.
typedef void (*_BKSHIDSetEventDeferringRulesForClientFunc)(CFArrayRef _Nullable rules, int clientPid);

NS_ASSUME_NONNULL_END

#endif /* BACKBOARDSERVICES_EXTENDED_H */
