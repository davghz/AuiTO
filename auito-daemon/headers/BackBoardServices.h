/*
 * BackBoardServices.h - BackBoardServices framework declarations for iOS 13.2.3
 * 
 * BackBoardServices provides high-level touch event delivery and management
 * on iOS 13.2.3
 */

#ifndef BACKBOARDSERVICES_H
#define BACKBOARDSERVICES_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - Forward Declarations

@class BKSHIDEventDeliveryManager;
@class BKSHIDEventDescriptor;
@class BKSHIDEventDispatchingTarget;
@class BKSHIDEventDeferringTarget;
@class BKSHIDEventDeferringPredicate;
@class BKSTouchDeliveryPolicy;
@class BKSHIDEventDisplay;
@class BKSHIDTouchRoutingPolicy;

#pragma mark - BKSHIDEventDeliveryManager

@interface BKSHIDEventDeliveryManager : NSObject

+ (instancetype)sharedInstance;

// Event dispatching rules
- (id)dispatchDiscreteEventsForReason:(NSString *)reason withRules:(NSArray *)rules;
- (id)dispatchKeyCommandsForReason:(NSString *)reason withRule:(id)rule;

// Event deferring (for routing events to specific targets)
- (id)deferEventsMatchingPredicate:(BKSHIDEventDeferringPredicate *)predicate
                          toTarget:(BKSHIDEventDeferringTarget *)target
                        withReason:(NSString *)reason;

// Key commands registration
- (id)registerKeyCommands:(NSArray *)keyCommands;

// Transaction assertions (for batching event changes)
- (id)transactionAssertionWithReason:(NSString *)reason;

@end

#pragma mark - BKSHIDEventDescriptor

@interface BKSHIDEventDescriptor : NSObject <NSSecureCoding, NSCopying>

@property(readonly, nonatomic) unsigned int hidEventType;

+ (instancetype)descriptorWithEventType:(unsigned int)eventType;
+ (instancetype)descriptorForHIDEvent:(struct __IOHIDEvent *)event;

- (BOOL)matchesHIDEvent:(struct __IOHIDEvent *)event;
- (BOOL)describes:(id)descriptor;
- (instancetype)descriptorByAddingSenderIDToMatchCriteria:(NSUInteger)senderID;

@end

#pragma mark - BKSHIDEventDispatchingTarget

@interface BKSHIDEventDispatchingTarget : NSObject <NSSecureCoding, NSCopying>

+ (instancetype)targetForDefaultConfiguration;
+ (instancetype)targetForResponder:(id)responder;
+ (instancetype)targetForUIApplication:(id)application;
+ (instancetype)targetForMainDisplay;
+ (instancetype)targetForDisplay:(BKSHIDEventDisplay *)display;
+ (instancetype)targetForTouchRoutingPolicy:(BKSHIDTouchRoutingPolicy *)policy;

@end

#pragma mark - BKSHIDEventDeferringTarget

@interface BKSHIDEventDeferringTarget : NSObject <NSSecureCoding, NSCopying>

+ (instancetype)targetWithEventDispatchingTarget:(BKSHIDEventDispatchingTarget *)target;

@end

#pragma mark - BKSHIDEventDeferringPredicate

@interface BKSHIDEventDeferringPredicate : NSObject <NSSecureCoding, NSCopying>

+ (instancetype)predicateWithEventDescriptor:(BKSHIDEventDescriptor *)descriptor
                                   toTarget:(BKSHIDEventDeferringTarget *)target;

@end

#pragma mark - BKSTouchDeliveryPolicy

@interface BKSTouchDeliveryPolicy : NSObject <NSSecureCoding>

// Cancel touches delivered to a specific context
+ (instancetype)policyCancelingTouchesDeliveredToContextId:(unsigned int)contextId
                                   withInitialTouchTimestamp:(double)timestamp;

// Require sharing of touches between child and host contexts
+ (instancetype)policyRequiringSharingOfTouchesDeliveredToChildContextId:(unsigned int)childContextId
                                                          withHostContextId:(unsigned int)hostContextId;

// Combine multiple policies
+ (instancetype)policyByCombiningPolicies:(NSArray *)policies;

- (instancetype)policyIncludingPolicy:(BKSTouchDeliveryPolicy *)policy;
- (instancetype)policyExcludingPolicy:(BKSTouchDeliveryPolicy *)policy;

@end

#pragma mark - BKSHIDTouchRoutingPolicy

@interface BKSHIDTouchRoutingPolicy : NSObject <NSSecureCoding, NSCopying>

+ (instancetype)policyForRoutingPolicy:(id)policy;

@end

#pragma mark - BKSHIDEventDisplay

@interface BKSHIDEventDisplay : NSObject <NSSecureCoding, NSCopying>

+ (instancetype)mainDisplay;
+ (instancetype)displayWithDisplayID:(unsigned int)displayID;
+ (instancetype)displayWithIdentifier:(NSString *)identifier;

@property(readonly, nonatomic) unsigned int displayID;
@property(readonly, nonatomic) NSString *identifier;

@end

#pragma mark - BKSSystemApplication

@interface BKSSystemApplication : NSObject

+ (instancetype)sharedInstance;

- (void)sendEvent:(struct __IOHIDEvent *)event;

@end

#pragma mark - BKSApplicationDataStore

@interface BKSApplicationDataStore : NSObject

+ (instancetype)sharedInstance;

@end

#pragma mark - BKSHitTestRegion

@interface BKSHitTestRegion : NSObject <NSSecureCoding, NSCopying>

@property(readonly, nonatomic) CGRect rect;
@property(readonly, nonatomic) unsigned int contextID;

+ (instancetype)regionWithRect:(CGRect)rect contextID:(unsigned int)contextID;

@end

#pragma mark - BKSHIDEventKeyCommand

@interface BKSHIDEventKeyCommand : NSObject <NSSecureCoding, NSCopying>

@property(readonly, nonatomic) unsigned short keyCode;
@property(readonly, nonatomic) unsigned int modifierFlags;
@property(readonly, copy, nonatomic) NSString *input;
@property(readonly, copy, nonatomic) NSString *discoverabilityTitle;

+ (instancetype)keyCommandWithInput:(NSString *)input
                      modifierFlags:(unsigned int)flags
                 discoverabilityTitle:(NSString *)title
                             action:(SEL)action;

@end

#pragma mark - BKSAnimationFenceHandle

@interface BKSAnimationFenceHandle : NSObject <NSSecureCoding>

+ (instancetype)animationFence;
+ (instancetype)animationFenceWithAuditToken:(id)auditToken;

- (void)waitForCommit;
- (void)waitForFence;
- (void)invalidate;

@end

#pragma mark - Constants

// Common sender IDs for touch injection
#define kBKSHIDEventSenderIDSystem              0x0000000000000001ULL
#define kBKSHIDEventSenderIDAccessibility       0x00000000000000A1ULL
#define kBKSHIDEventSenderIDAssistiveTouch      0x00000000000000A2ULL
#define kBKSHIDEventSenderIDSwitchControl       0x00000000000000A3ULL
#define kBKSHIDEventSenderIDVoiceControl        0x00000000000000A4ULL

#endif /* BACKBOARDSERVICES_H */
