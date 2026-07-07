#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

CGError MTConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
bool MTDisplayEnableSPIAvailable(void);
