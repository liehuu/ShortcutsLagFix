TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Shortcuts

ARCHS = arm64 arm64e

# RootHide 加载器会跳过无签名 dylib，必须 adhoc 签名。
# install_name 必须指向 RootHide 的 .jbroot 布局，否则加载器找不到依赖。
PACKAGE_FORMAT = gnu-tar

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ShortcutsLagFix

ShortcutsLagFix_FILES = \
	ShortcutsLagFix/SLFMain.m \
	ShortcutsLagFix/SLFCore.m \
	ShortcutsLagFix/SLFWatchdog.m \
	ShortcutsLagFix/SLFHooks.m

ShortcutsLagFix_CFLAGS = -fobjc-arc \
	-Wno-unused-function \
	-Wno-deprecated-declarations \
	-Wno-objc-missing-super-calls \
	-Wno-nullability-completeness

ShortcutsLagFix_FRAMEWORKS = Foundation UIKit CoreFoundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

# RootHide：dylib 的 LC_ID_DYLIB 必须能被其加载器解析。
after-ShortcutsLagFix-stage::
	@echo "[stage] install_name: $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(TWEAK_NAME).dylib"

after-install::
	install.exec "killall -9 Shortcuts 2>/dev/null || true"