export THEOS=/home/davgz/theos
export TARGET=iphone:clang:13.2.3:13.0
export ARCHS=arm64

TOOL_NAME = aui-touch

aui-touch_FILES = main.m AUIVirtualTouch.m AUIHTTPServer.m
aui-touch_FRAMEWORKS = Foundation CoreFoundation IOKit
aui-touch_CFLAGS = -fobjc-arc -Wno-unused-function
aui-touch_CODESIGN_FLAGS = -Sentitlements.plist
aui-touch_INSTALL_PATH = /usr/bin

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-install::
	install.exec "launchctl unload /Library/LaunchDaemons/com.aui.touch.plist >/dev/null 2>&1 || true"
	install.exec "launchctl load /Library/LaunchDaemons/com.aui.touch.plist >/dev/null 2>&1 || true"
