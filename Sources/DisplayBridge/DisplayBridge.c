#include "DisplayBridge.h"
#include <dlfcn.h>
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID);
CFDictionaryRef IBCopyDisplayInfo(CGDirectDisplayID display) {
    return CoreDisplay_DisplayCreateInfoDictionary(display);
}
typedef CGError (*EnableFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static EnableFn enableFunction(void) {
    return (EnableFn)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
}
bool IBEnableAvailable(void) { return enableFunction() != NULL; }
CGError IBConfigureEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled) {
    EnableFn fn = enableFunction();
    return fn ? fn(config, display, enabled) : kCGErrorNotImplemented;
}
