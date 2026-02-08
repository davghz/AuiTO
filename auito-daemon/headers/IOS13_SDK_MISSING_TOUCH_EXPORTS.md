# iOS 13.2.3 BackBoardServices Touch Export Gap (AuiTO Audit)

Date: 2026-02-08
Scope:
- SDK source: `sdk/iPhoneOS13.2.3.sdk/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices.tbd`
- Local declarations: `AuiTO/auito-daemon/headers/BackBoardServices+Extended.h`

## Summary

`BackBoardServices+Extended.h` now covers the core symbols required for current AuiTO non-AX R&D:
- dispatch/send helpers (`BKSHIDEventSendTo*`)
- digitizer context bind helpers (`BKSHIDEventSetDigitizerInfo*`, `BKSHIDEventSetSimpleDeliveryInfo`)
- sender/context introspection (`BKSHIDEventGetContextIDFromEvent`, `BKSHIDEventGetTouchStreamIdentifier`, `BKSHIDEventGetClient*`, `BKSHIDEventCopyDisplayIDFromEvent`)
- redirect support declarations (`BKSHIDEventRedirectAttributes`, `__BKSHIDEventSetRedirectInfo`)

Remaining undeclared `_BKSHIDEvent*` exports are mostly non-core for current touch/tap/swipe dispatch debugging.

## Remaining Undeclared Exports (26)

- `_BKSHIDEventBiometricDescriptor`
- `_BKSHIDEventDeliveryMIGService`
- `_BKSHIDEventDeliveryObserverBSServiceName`
- `_BKSHIDEventDeliveryPolicyObserver`
- `_BKSHIDEventDigitizerSetTouchOffset`
- `_BKSHIDEventGetButtonIsCancelledFromButtonEvent`
- `_BKSHIDEventGetConciseDescriptionGenericGesture`
- `_BKSHIDEventGetConciseDescriptionKeyboard`
- `_BKSHIDEventGetConciseDescriptionPointer`
- `_BKSHIDEventGetConciseDescriptionScroll`
- `_BKSHIDEventGetDigitizerEventInfoDescription`
- `_BKSHIDEventGetEventInfoDescription`
- `_BKSHIDEventGetSmartCoverStateFromEvent`
- `_BKSHIDEventGetSourceFromKeyboardEvent`
- `_BKSHIDEventGetSubEventInfoFromDigitierEventForPathEvent`
- `_BKSHIDEventGetZGradientFromDigitizerEventForPathEvent`
- `_BKSHIDEventKeyCommand`
- `_BKSHIDEventKeyCommandDescriptor`
- `_BKSHIDEventKeyCommandsDispatchingPredicate`
- `_BKSHIDEventKeyCommandsDispatchingRule`
- `_BKSHIDEventKeyCommandsRegistration`
- `_BKSHIDEventKeyboardDescriptor`
- `_BKSHIDEventObserver`
- `_BKSHIDEventSetSmartCoverState`
- `_BKSHIDEventUsagePairDescriptor`
- `_BKSHIDEventVendorDefinedDescriptor`

## Actionability

- Required now for non-AX tap/swipe delivery: `No`
- Useful later for deeper instrumentation domains (keyboard, key commands, smart-cover, richer descriptions): `Yes`

For current AuiTO strict non-AX work, these residual exports are not the primary blocker.
