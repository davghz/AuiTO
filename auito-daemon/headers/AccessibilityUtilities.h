/*
 * AccessibilityUtilities.h - AccessibilityUtilities framework for iOS 13.2.3
 * 
 * This framework provides high-level APIs for touch/gesture injection
 * and accessibility event generation. Often easier to use than raw HID events.
 */

#ifndef ACCESSIBILITYUTILITIES_H
#define ACCESSIBILITYUTILITIES_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - Forward Declarations

@class AXEventRepresentation;
@class AXEventHandInfoRepresentation;
@class AXEventKeyInfoRepresentation;
@class AXEventAccelerometerInfoRepresentation;
@class AXEventGameControllerInfoRepresentation;
@class AXEventPointerInfoRepresentation;
@class AXEventIOSMACPointerInfoRepresentation;

#pragma mark - AXEventRepresentation

// Event types
#define kAXEventTypeTouch                       1
#define kAXEventTypeButton                      2
#define kAXEventTypeKeyboard                    3
#define kAXEventTypeAccelerometer               4
#define kAXEventTypeGameController              5
#define kAXEventTypePointerController           6
#define kAXEventTypeIOSMACPointer               7

@interface AXEventRepresentation : NSObject <NSSecureCoding, NSCopying>

#pragma mark - Properties

@property(nonatomic) unsigned int type;
@property(nonatomic) int subtype;
@property(nonatomic) int flags;
@property(nonatomic) NSUInteger time;
@property(nonatomic) NSUInteger senderID;
@property(nonatomic) CGPoint location;
@property(nonatomic) CGPoint windowLocation;
@property(nonatomic) unsigned int contextId;
@property(nonatomic) unsigned int displayId;
@property(nonatomic) int pid;
@property(nonatomic) unsigned int taskPort;
@property(nonatomic) BOOL isBuiltIn;
@property(nonatomic) BOOL isDisplayIntegrated;
@property(nonatomic) BOOL isGeneratedEvent;
@property(nonatomic) BOOL useOriginalHIDTime;
@property(nonatomic) BOOL redirectEvent;
@property(nonatomic) BOOL systemDrag;

@property(retain, nonatomic) AXEventHandInfoRepresentation *handInfo;
@property(retain, nonatomic) AXEventKeyInfoRepresentation *keyInfo;
@property(retain, nonatomic) AXEventAccelerometerInfoRepresentation *accelerometerInfo;
@property(retain, nonatomic) AXEventGameControllerInfoRepresentation *gameControllerInfo;
@property(retain, nonatomic) AXEventPointerInfoRepresentation *pointerControllerInfo;
@property(retain, nonatomic) AXEventIOSMACPointerInfoRepresentation *iosmacPointerInfo;
@property(retain, nonatomic) NSString *clientId;
@property(nonatomic) NSUInteger HIDTime;
@property(retain, nonatomic) NSData *HIDAttributeData;
@property(nonatomic) long long scrollAmount;
@property(nonatomic) long long scrollAccelAmount;
@property(nonatomic) NSUInteger additionalFlags;
@property(nonatomic) long long generationCount;

#pragma mark - Factory Methods for Touch Events

// Create a single touch event
+ (instancetype)touchRepresentationWithHandType:(unsigned int)handType
                                       location:(CGPoint)location;

// Create a multi-touch gesture event
+ (instancetype)gestureRepresentationWithHandType:(unsigned int)handType
                                         locations:(NSArray *)locations;

// Create from HID event
+ (instancetype)representationWithHIDEvent:(struct __IOHIDEvent *)event
                            serviceClient:(struct __IOHIDServiceClient *)serviceClient
                         hidStreamIdentifier:(NSString *)identifier
                                   taskPort:(unsigned int)taskPort;

+ (instancetype)representationWithHIDEvent:(struct __IOHIDEvent *)event
                         hidStreamIdentifier:(NSString *)identifier
                                   clientID:(NSString *)clientID
                                   taskPort:(unsigned int)taskPort;

// Create with location and hand info
+ (instancetype)representationWithLocation:(CGPoint)location
                            windowLocation:(CGPoint)windowLocation
                                  handInfo:(AXEventHandInfoRepresentation *)handInfo;

// Create full representation
+ (instancetype)representationWithType:(unsigned int)type
                               subtype:(int)subtype
                                  time:(NSUInteger)time
                              location:(CGPoint)location
                          windowLocation:(CGPoint)windowLocation
                               handInfo:(AXEventHandInfoRepresentation *)handInfo;

#pragma mark - Factory Methods for Other Events

+ (instancetype)buttonRepresentationWithType:(unsigned int)type;
+ (instancetype)keyRepresentationWithType:(unsigned int)type;
+ (instancetype)accelerometerRepresentation:(id)info;
+ (instancetype)iosmacPointerRepresentationWithTypeWithPointerInfo:(AXEventIOSMACPointerInfoRepresentation *)info;

#pragma mark - Event Queries

@property(readonly, nonatomic) BOOL isTouchDown;
@property(readonly, nonatomic) BOOL isLift;
@property(readonly, nonatomic) BOOL isMove;
@property(readonly, nonatomic) BOOL isInRange;
@property(readonly, nonatomic) BOOL isInRangeLift;
@property(readonly, nonatomic) BOOL isChordChange;
@property(readonly, nonatomic) BOOL isCancel;
@property(readonly, nonatomic) NSUInteger fingerCount;
@property(readonly, nonatomic) BOOL willBeUpdated;
@property(readonly, nonatomic) BOOL isUpdate;

- (BOOL)isDownEvent;
- (unsigned char)screenEdgeForPoint:(CGPoint)point;
- (unsigned int)pathIndexMask;
- (unsigned int)firstPathContextId;

#pragma mark - Event Conversion

// Convert to HID event
- (struct __IOHIDEvent *)newHIDEventRef;
- (struct __IOHIDEvent *)_newHandHIDEventRef;
- (struct __IOHIDEvent *)_newButtonHIDEventRefWithType:(unsigned int)type;
- (struct __IOHIDEvent *)_newKeyboardHIDEventRef;
- (struct __IOHIDEvent *)_newAccelerometerHIDEventRef;
- (struct __IOHIDEvent *)_newIOSMACPointerRef;

// Legacy GSEvent conversion
- (struct __GSEvent *)newGSEventRef;

// Data representation
- (NSData *)dataRepresentation;
+ (instancetype)representationWithData:(NSData *)data;

#pragma mark - Event Modification

- (instancetype)normalizedEventRepresentation:(BOOL)normalize scale:(BOOL)scale;
- (instancetype)denormalizedEventRepresentation:(BOOL)denormalize descale:(BOOL)descale;
- (instancetype)fakeTouchScaleEventRepresentation:(BOOL)scale;
- (void)modifyPoints:(void (^)(CGPoint *point))block;
- (void)neuterUpdates;
- (void)resetInitialTouchCountValueForHidStreamIdentifier:(NSString *)identifier;

@end

#pragma mark - AXEventHandInfoRepresentation

@interface AXEventHandInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) unsigned int eventType;
@property(nonatomic) unsigned short initialFingerCount;
@property(nonatomic) unsigned short currentFingerCount;
@property(nonatomic) unsigned int handIdentity;
@property(nonatomic) unsigned int handIndex;
@property(nonatomic) unsigned int handEventMask;
@property(nonatomic) unsigned int additionalHandEventFlagsForGeneratedEvents;
@property(nonatomic) unsigned char systemGesturePossible;
@property(nonatomic) unsigned char swipe;
@property(nonatomic) CGPoint handPosition;
@property(retain, nonatomic) NSArray *paths;  // Array of AXEventPathInfoRepresentation

@property(readonly, nonatomic) BOOL isStylus;
@property(readonly, nonatomic) NSUInteger length;

+ (instancetype)representationWithHandInfo:(struct CDStruct_f2c5c900)handInfo;
- (void)writeToHandInfo:(struct CDStruct_f2c5c900)handInfo;

@end

#pragma mark - AXEventPathInfoRepresentation (touch path/finger)

@interface AXEventPathInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) unsigned char pathIndex;
@property(nonatomic) unsigned char pathIdentity;
@property(nonatomic) unsigned int pathEventMask;
@property(nonatomic) CGFloat x;
@property(nonatomic) CGFloat y;
@property(nonatomic) CGFloat z;
@property(nonatomic) CGFloat pressure;
@property(nonatomic) CGFloat twist;
@property(nonatomic) CGFloat majorRadius;
@property(nonatomic) CGFloat minorRadius;
@property(nonatomic) CGFloat density;
@property(nonatomic) CGFloat irregularity;
@property(nonatomic) CGFloat quality;
@property(nonatomic) CGFloat altitude;
@property(nonatomic) CGFloat azimuth;
@property(nonatomic) BOOL isDisplayIntegrated;
@property(nonatomic) BOOL isStylus;
@property(nonatomic) BOOL isInRange;
@property(nonatomic) BOOL isTouchDown;
@property(nonatomic) unsigned int pathWindowContextID;
@property(nonatomic) NSUInteger fingerID;

+ (instancetype)representationWithPathInfo:(struct CDStruct_8b65991f)pathInfo;
- (void)writeToPathInfo:(struct CDStruct_8b65991f)pathInfo;

@end

#pragma mark - AXEventKeyInfoRepresentation

@interface AXEventKeyInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) unsigned short keyCode;
@property(nonatomic) unsigned int modifierFlags;
@property(nonatomic) BOOL isKeyDown;
@property(nonatomic) BOOL isRepeat;
@property(nonatomic) BOOL isReservedKey;
@property(nonatomic) BOOL useExtendedModifierFlags;
@property(nonatomic) BOOL isTopRowKey;
@property(nonatomic) BOOL useSecondaryModifierFlags;
@property(nonatomic) BOOL isSecondFunction;

+ (instancetype)representationWithKeyInfo:(struct CDStruct_7a0c8fcf)keyInfo;
- (void)writeToKeyInfo:(struct CDStruct_7a0c8fcf)keyInfo;

@end

#pragma mark - AXBackBoardServer

@interface AXBackBoardServer : NSObject

+ (instancetype)server;

// Event posting
- (void)postEvent:(AXEventRepresentation *)event systemEvent:(BOOL)systemEvent;
- (void)postEvent:(AXEventRepresentation *)event
    afterNamedTap:(NSString *)tapName
      includeTaps:(NSArray *)tapNames;

// PID registration
- (void)registerAssistiveTouchPID:(int)pid;
- (void)registerAccessibilityUIServicePID:(int)pid;
- (void)registerSiriViewServicePID:(int)pid;
- (int)accessibilityUIServicePID;
- (int)accessibilityAssistiveTouchPID;

// Coordinate conversion
- (CGRect)convertFrame:(CGRect)frame fromContextId:(unsigned int)contextId;
- (CGRect)convertFrame:(CGRect)frame toContextId:(unsigned int)contextId;
- (CGRect)convertFrame:(CGRect)frame
         fromContextId:(unsigned int)fromContextId
           toContextId:(unsigned int)toContextId;
- (unsigned int)contextIdForPosition:(CGPoint)position;
- (unsigned int)contextIdHostingContextId:(unsigned int)contextId;

// User activity
- (void)userEventOccurred;

// Zoom
- (void)adjustSystemZoom:(int)adjustment;
- (void)registerGestureConflictWithZoom:(id)gesture;
- (CGRect)zoomInitialFocusRectWithQueryingContext:(unsigned int)contextId;
- (void)setZoomInitialFocusRect:(CGRect)rect fromContext:(unsigned int)contextId;

@end

#pragma mark - AXEventAccelerometerInfoRepresentation

@interface AXEventAccelerometerInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) CGFloat x;
@property(nonatomic) CGFloat y;
@property(nonatomic) CGFloat z;

@end

#pragma mark - AXEventGameControllerInfoRepresentation

@interface AXEventGameControllerInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) unsigned int buttonMask;
@property(nonatomic) CGFloat joystickX;
@property(nonatomic) CGFloat joystickY;

@end

#pragma mark - AXEventPointerInfoRepresentation

@interface AXEventPointerInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) unsigned int buttonMask;
@property(nonatomic) CGFloat x;
@property(nonatomic) CGFloat y;
@property(nonatomic) CGFloat z;
@property(nonatomic) CGFloat deltaX;
@property(nonatomic) CGFloat deltaY;
@property(nonatomic) CGFloat deltaZ;

@end

#pragma mark - AXEventIOSMACPointerInfoRepresentation

@interface AXEventIOSMACPointerInfoRepresentation : NSObject <NSSecureCoding, NSCopying>

@property(nonatomic) unsigned int buttonMask;
@property(nonatomic) CGFloat x;
@property(nonatomic) CGFloat y;
@property(nonatomic) CGFloat deltaX;
@property(nonatomic) CGFloat deltaY;

@end

#pragma mark - Helper Functions

// Common sender IDs
#define kAXSenderIDSystem                       0x0000000000000001ULL
#define kAXSenderIDAccessibility                0x00000000000000A1ULL
#define kAXSenderIDAssistiveTouch               0x00000000000000A2ULL
#define kAXSenderIDSwitchControl                0x00000000000000A3ULL
#define kAXSenderIDVoiceControl                 0x00000000000000A4ULL

#endif /* ACCESSIBILITYUTILITIES_H */
