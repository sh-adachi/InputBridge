#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/graphics/IOGraphicsLib.h>
CFDictionaryRef IBCopyDisplayInfo(CGDirectDisplayID display) CF_RETURNS_RETAINED;
bool IBEnableAvailable(void);
CGError IBConfigureEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
