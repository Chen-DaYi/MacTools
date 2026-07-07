#include "DisplayEnableSPI.h"

#include <dlfcn.h>

typedef CGError (*MTConfigureDisplayEnabledFn)(
    CGDisplayConfigRef config,
    CGDirectDisplayID display,
    bool enabled
);

static MTConfigureDisplayEnabledFn MTResolveConfigureDisplayEnabled(void) {
    // The Swift caller is @MainActor-isolated, so this lazy cache is only
    // touched from one thread. Concurrent calls would race on these statics.
    static MTConfigureDisplayEnabledFn cachedFunction = NULL;
    static bool didResolve = false;

    if (didResolve) {
        return cachedFunction;
    }

    didResolve = true;

    void *skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    );

    if (skyLight) {
        cachedFunction = (MTConfigureDisplayEnabledFn)dlsym(
            skyLight,
            "SLSConfigureDisplayEnabled"
        );
    }

    if (!cachedFunction) {
        void *coreGraphics = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        );
        if (coreGraphics) {
            cachedFunction = (MTConfigureDisplayEnabledFn)dlsym(
                coreGraphics,
                "CGSConfigureDisplayEnabled"
            );
        }
    }

    if (!cachedFunction) {
        cachedFunction = (MTConfigureDisplayEnabledFn)dlsym(
            RTLD_DEFAULT,
            "CGSConfigureDisplayEnabled"
        );
    }

    return cachedFunction;
}

bool MTDisplayEnableSPIAvailable(void) {
    return MTResolveConfigureDisplayEnabled() != NULL;
}

CGError MTConfigureDisplayEnabled(
    CGDisplayConfigRef config,
    CGDirectDisplayID display,
    bool enabled
) {
    MTConfigureDisplayEnabledFn function = MTResolveConfigureDisplayEnabled();
    if (!function) {
        return kCGErrorFailure;
    }

    return function(config, display, enabled);
}
