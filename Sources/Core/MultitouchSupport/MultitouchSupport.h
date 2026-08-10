// References:
//   https://github.com/auramagi/everypinch
//   https://github.com/asmagill/hs._asm.undocumented.touchdevice
// License notes are tracked in Sources/Resources/ThirdPartyNotices.

#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>

CF_IMPLICIT_BRIDGING_ENABLED
CF_ASSUME_NONNULL_BEGIN

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef CF_ENUM(int, MTPathStage) {
    kMTPathStageNotTracking,
    kMTPathStageStartInRange,
    kMTPathStageHoverInRange,
    kMTPathStageMakeTouch,
    kMTPathStageTouching,
    kMTPathStageBreakTouch,
    kMTPathStageLingerInRange,
    kMTPathStageOutOfRange,
};

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    MTPathStage stage;
    int fingerID;
    int handID;
    MTVector normalizedVector;
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int unknown14;
    int unknown15;
    float density;
} MTTouch;

typedef struct CF_BRIDGED_TYPE(id) MTDevice *MTDeviceRef;

typedef void (*MTFrameCallbackFunction)(
    MTDeviceRef device,
    MTTouch touches[],
    int numTouches,
    double timestamp,
    int frame
);

typedef void (*MTFrameCallbackWithRefconFunction)(
    MTDeviceRef device,
    MTTouch touches[],
    int numTouches,
    double timestamp,
    int frame,
    void * _Nullable refcon
);

bool MTDeviceIsAlive(MTDeviceRef)
    CF_SWIFT_NAME(getter:MTDevice.isAlive(self:));
bool MTDeviceIsRunning(MTDeviceRef)
    CF_SWIFT_NAME(getter:MTDevice.isRunning(self:));

void MTRegisterContactFrameCallback(MTDeviceRef, MTFrameCallbackFunction)
    CF_SWIFT_NAME(MTDevice.register(self:contactFrameCallback:));
void MTRegisterContactFrameCallbackWithRefcon(
    MTDeviceRef,
    MTFrameCallbackWithRefconFunction,
    void * _Nullable
);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTFrameCallbackFunction)
    CF_SWIFT_NAME(MTDevice.unregister(self:contactFrameCallback:));

void MTDeviceStart(MTDeviceRef, int runMode)
    CF_SWIFT_NAME(MTDevice.start(self:runMode:));
void MTDeviceStop(MTDeviceRef)
    CF_SWIFT_NAME(MTDevice.stop(self:));
void MTDeviceRelease(MTDeviceRef)
    CF_SWIFT_NAME(MTDevice.release(self:));

CF_ASSUME_NONNULL_END
CF_IMPLICIT_BRIDGING_DISABLED
