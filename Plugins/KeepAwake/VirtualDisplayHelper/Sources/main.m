#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>

// These private CoreGraphics classes are discovered by name at runtime. Declaring
// the selectors on NSObject lets this helper compile without linking private
// symbols into the plugin or its host process.
@interface NSObject (MacToolsVirtualDisplayDescriptor)
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setName:(NSString *)name;
- (void)setWhitePoint:(CGPoint)whitePoint;
- (void)setRedPrimary:(CGPoint)redPrimary;
- (void)setGreenPrimary:(CGPoint)greenPrimary;
- (void)setBluePrimary:(CGPoint)bluePrimary;
- (void)setMaxPixelsWide:(unsigned int)width;
- (void)setMaxPixelsHigh:(unsigned int)height;
- (void)setSizeInMillimeters:(CGSize)size;
- (void)setVendorID:(unsigned int)vendorID;
- (void)setProductID:(unsigned int)productID;
- (void)setSerialNum:(unsigned int)serialNumber;
- (void)setSerialNumber:(unsigned int)serialNumber;
@end

@interface NSObject (MacToolsVirtualDisplayMode)
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface NSObject (MacToolsVirtualDisplaySettings)
- (void)setModes:(NSArray *)modes;
- (void)setHiDPI:(unsigned int)hiDPI;
- (void)setRotation:(unsigned int)rotation;
@end

@interface NSObject (MacToolsVirtualDisplay)
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (CGDirectDisplayID)displayID;
@end

static id virtualDisplay;
static pid_t parentPID;

static void WriteError(NSString *message) {
    NSData *data = [[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(STDERR_FILENO, data.bytes, data.length);
}

static BOOL ClassSupportsSelectors(Class cls, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(selectorName)]) {
            WriteError([NSString stringWithFormat:@"Missing selector %@ on %@", selectorName, NSStringFromClass(cls)]);
            return NO;
        }
    }
    return YES;
}

static BOOL ValidateRuntime(
    Class descriptorClass,
    Class modeClass,
    Class settingsClass,
    Class displayClass
) {
    if (descriptorClass == Nil || modeClass == Nil || settingsClass == Nil || displayClass == Nil) {
        WriteError(@"Virtual display API is unavailable on this version of macOS.");
        return NO;
    }

    return
        ClassSupportsSelectors(descriptorClass, @[
            @"setQueue:", @"setName:", @"setWhitePoint:", @"setRedPrimary:",
            @"setGreenPrimary:", @"setBluePrimary:", @"setMaxPixelsWide:",
            @"setMaxPixelsHigh:", @"setSizeInMillimeters:", @"setVendorID:",
            @"setProductID:", @"setSerialNum:", @"setSerialNumber:"
        ])
        && ClassSupportsSelectors(modeClass, @[@"initWithWidth:height:refreshRate:"])
        && ClassSupportsSelectors(settingsClass, @[@"setModes:", @"setHiDPI:", @"setRotation:"])
        && ClassSupportsSelectors(displayClass, @[@"initWithDescriptor:", @"applySettings:", @"displayID"]);
}

static BOOL CreateVirtualDisplay(void) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    if (!ValidateRuntime(descriptorClass, modeClass, settingsClass, displayClass)) {
        return NO;
    }

    const unsigned int physicalWidth = 3840;
    const unsigned int physicalHeight = 2160;
    const double pixelsPerInch = 192.0;
    const unsigned int serialNumber = (unsigned int)getpid();

    id descriptor = [[descriptorClass alloc] init];
    [descriptor setQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)];
    [descriptor setName:@"MacTools Virtual Display"];
    [descriptor setWhitePoint:CGPointMake(0.3125, 0.3291)];
    [descriptor setRedPrimary:CGPointMake(0.6797, 0.3203)];
    [descriptor setGreenPrimary:CGPointMake(0.2559, 0.6983)];
    [descriptor setBluePrimary:CGPointMake(0.1494, 0.0557)];
    [descriptor setMaxPixelsWide:physicalWidth];
    [descriptor setMaxPixelsHigh:physicalHeight];
    [descriptor setSizeInMillimeters:CGSizeMake(
        25.4 * physicalWidth / pixelsPerInch,
        25.4 * physicalHeight / pixelsPerInch
    )];
    [descriptor setVendorID:505];
    [descriptor setProductID:0];
    [descriptor setSerialNum:serialNumber];
    [descriptor setSerialNumber:serialNumber];

    virtualDisplay = [[displayClass alloc] initWithDescriptor:descriptor];
    if (virtualDisplay == nil) {
        WriteError(@"macOS rejected the virtual display descriptor.");
        return NO;
    }

    id mode = [[modeClass alloc] initWithWidth:physicalWidth / 2
                                       height:physicalHeight / 2
                                  refreshRate:60.0];
    id settings = [[settingsClass alloc] init];
    [settings setModes:@[mode]];
    [settings setHiDPI:YES];
    [settings setRotation:0];

    if (![virtualDisplay applySettings:settings]) {
        virtualDisplay = nil;
        WriteError(@"macOS rejected the virtual display settings.");
        return NO;
    }

    NSString *ready = [NSString stringWithFormat:@"READY %u\n", [virtualDisplay displayID]];
    NSData *readyData = [ready dataUsingEncoding:NSUTF8StringEncoding];
    (void)write(STDOUT_FILENO, readyData.bytes, readyData.length);
    return YES;
}

static void StopHelper(void) {
    virtualDisplay = nil;
    exit(EXIT_SUCCESS);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        parentPID = getppid();

        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);

        dispatch_source_t terminateSource = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL,
            SIGTERM,
            0,
            dispatch_get_main_queue()
        );
        dispatch_source_set_event_handler(terminateSource, ^{
            StopHelper();
        });
        dispatch_resume(terminateSource);

        dispatch_source_t interruptSource = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL,
            SIGINT,
            0,
            dispatch_get_main_queue()
        );
        dispatch_source_set_event_handler(interruptSource, ^{
            StopHelper();
        });
        dispatch_resume(interruptSource);

        if (!CreateVirtualDisplay()) {
            return EXIT_FAILURE;
        }

        dispatch_source_t parentMonitor = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER,
            0,
            0,
            dispatch_get_main_queue()
        );
        dispatch_source_set_timer(
            parentMonitor,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
            NSEC_PER_SEC,
            NSEC_PER_SEC / 10
        );
        dispatch_source_set_event_handler(parentMonitor, ^{
            if (getppid() != parentPID || kill(parentPID, 0) != 0) {
                StopHelper();
            }
        });
        dispatch_resume(parentMonitor);

        dispatch_main();
    }
}
