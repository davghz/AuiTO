# AuiTO Makefile (daemon tool + SpringBoard tweak)

export THEOS=/home/davgz/theos
export TARGET=iphone:clang:13.2.3:13.0
export ARCHS=arm64

TOOL_NAME = auito-daemon
TWEAK_NAME = auito

auito-daemon_FILES = \
	main.m \
	modules/http_server/DaemonHTTPServer.m \
	modules/http_server/DaemonHTTPServer+Helpers.m \
	modules/http_server/DaemonHTTPServer+Network.m \
	modules/http_server/DaemonHTTPServer+TouchAdmin.m \
	modules/http_server/DaemonHTTPServer+StrictProxy.m \
	modules/touch/TouchInjection.m \
	modules/touch/internal/TouchInjectionBootstrap.m \
	modules/touch/internal/TouchInjectionBKSRouting.m \
	modules/touch/internal/TouchInjectionBKSFocus.m \
	modules/touch/internal/TouchInjectionBKSDispatch.m \
	modules/touch/internal/TouchInjectionBKSExperiments.m \
	modules/touch/internal/TouchInjectionSenderIDManager.m \
	modules/touch/internal/TouchInjectionStrategyRouter.m \
	modules/touch/internal/TouchInjectionEventBuilder.m \
	modules/touch/internal/TouchInjectionGestureComposer.m \
	modules/touch/AXTouchInjection.m \
	modules/screenshot/KimiRunScreenshot.m \
	modules/accessibility/AccessibilityTree.m \
	modules/app/AppLauncher.m

auito-daemon_FRAMEWORKS = Foundation CoreFoundation UIKit QuartzCore IOKit IOSurface
auito-daemon_PRIVATE_FRAMEWORKS = BackBoardServices AccessibilityUtilities AXRuntime MobileCoreServices CoreServices
auito-daemon_CFLAGS = -fobjc-arc -Imodules -Iheaders -Wno-arc-performSelector-leaks -Wno-unused-function -Wno-unused-variable -Wno-incomplete-implementation

# SpringBoard tweak (lockscreen/sleep hooks + in-process HTTP/touch proxy)
auito_FILES = \
	Tweak.xm \
	modules/http_server/KimiRunHTTPServer.m \
	modules/touch/TouchInjection.m \
	modules/touch/internal/TouchInjectionBootstrap.m \
	modules/touch/internal/TouchInjectionBKSRouting.m \
	modules/touch/internal/TouchInjectionBKSFocus.m \
	modules/touch/internal/TouchInjectionBKSDispatch.m \
	modules/touch/internal/TouchInjectionBKSExperiments.m \
	modules/touch/internal/TouchInjectionSenderIDManager.m \
	modules/touch/internal/TouchInjectionStrategyRouter.m \
	modules/touch/internal/TouchInjectionEventBuilder.m \
	modules/touch/internal/TouchInjectionGestureComposer.m \
	modules/touch/AXTouchInjection.m \
	modules/screenshot/KimiRunScreenshot.m \
	modules/accessibility/AccessibilityTree.m \
	modules/socket/SocketTouchServer.m \
	modules/lockscreen/KimiRunLockscreen.m \
	modules/sleep/KimiRunSleep.m \
	modules/sleep/KimiRunSleepHook.xm

auito_FRAMEWORKS = Foundation CoreFoundation UIKit QuartzCore IOKit IOSurface
auito_PRIVATE_FRAMEWORKS = BackBoardServices AccessibilityUtilities AXRuntime MobileCoreServices CoreServices
auito_CFLAGS = -fobjc-arc -Imodules -Iheaders -Wno-arc-performSelector-leaks -Wno-unused-function -Wno-unused-variable -Wno-incomplete-implementation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "launchctl unload /Library/LaunchDaemons/com.auito.daemon.plist >/dev/null 2>&1 || true"
	install.exec "launchctl load /Library/LaunchDaemons/com.auito.daemon.plist >/dev/null 2>&1 || true"
	install.exec "killall -9 SpringBoard"
