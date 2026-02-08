/**
 * AccessibilityTree.h - UI hierarchy traversal for accessibility tree export
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface AccessibilityTree : NSObject

+ (void)initialize;

// Get full accessibility tree as JSON
+ (NSDictionary *)getFullTree;
+ (NSString *)getFullTreeAsJSON;

// Get tree for specific view
+ (NSDictionary *)getTreeForView:(UIView *)view;

// Get interactive elements only (buttons, text fields, etc.)
+ (NSArray<NSDictionary *> *)getInteractiveElements;
+ (NSString *)getInteractiveElementsAsJSON;
// Activate interactive element by index (from getInteractiveElements)
+ (BOOL)activateInteractiveElementAtIndex:(NSUInteger)index;
// Activate best-match accessible element at screen point.
+ (BOOL)activateElementAtPoint:(CGPoint)point;
// Attempt AX scroll action at a screen point using AXRuntime elements.
+ (BOOL)scrollAtPoint:(CGPoint)point direction:(NSInteger)direction;

// Find element by properties
+ (NSDictionary *)findElementWithLabel:(NSString *)label;
+ (NSDictionary *)findElementWithIdentifier:(NSString *)identifier;

// Overlay controls (DroidRun-style a11y boxes)
+ (void)setOverlayEnabled:(BOOL)enabled interactiveOnly:(BOOL)interactiveOnly;
+ (BOOL)isOverlayEnabled;

// Debug info for AXRuntime availability
+ (NSDictionary *)debugInfo;

@end
