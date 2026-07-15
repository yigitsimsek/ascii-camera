#import "LegacyVirtualCameraServer.h"

#import <IOSurface/IOSurface.h>
#import <mach/mach.h>
#import <servers/bootstrap.h>

static NSString *const AsciiCameraLegacyServiceName = @"com.obsproject.obs-mac-virtualcam.server";

typedef NS_ENUM(uint32_t, LegacyMachMessageID) {
    LegacyMachMessageConnect = 1,
    LegacyMachMessageFrame = 2,
    LegacyMachMessageStop = 3,
};

@interface LegacyVirtualCameraServer () <NSPortDelegate>
@property(nonatomic, copy) NSString *serviceName;
@property(nonatomic) NSPort *port;
@property(nonatomic) NSRunLoop *runLoop;
@property(nonatomic) NSMutableSet<NSPort *> *clientPorts;
@end

@implementation LegacyVirtualCameraServer

- (instancetype)init
{
    return [self initWithServiceName:AsciiCameraLegacyServiceName];
}

- (instancetype)initWithServiceName:(NSString *)serviceName
{
    self = [super init];
    if (self) {
        _serviceName = [serviceName copy];
        _clientPorts = [NSMutableSet set];
    }
    return self;
}

- (BOOL)isRunning
{
    return self.port != nil && self.port.isValid;
}

- (NSUInteger)clientCount
{
    @synchronized(self) {
        return self.clientPorts.count;
    }
}

- (BOOL)start:(NSError **)error
{
    if (self.isRunning) {
        return YES;
    }

    mach_port_t checkedInPort = MACH_PORT_NULL;
    kern_return_t checkInResult = bootstrap_check_in(bootstrap_port, self.serviceName.UTF8String, &checkedInPort);
    NSPort *port = nil;
    if (checkInResult == KERN_SUCCESS && checkedInPort != MACH_PORT_NULL) {
        port = [[NSMachPort alloc] initWithMachPort:checkedInPort options:NSMachPortDeallocateNone];
    }

    // This fallback keeps the transport usable on older macOS releases. On
    // current macOS, launchd supplies the receive right declared by our agent.
    if (!port) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        port = [[NSMachBootstrapServer sharedInstance] servicePortWithName:self.serviceName];
#pragma clang diagnostic pop
    }
    if (!port) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.yigit.asciicamera.legacy-transport"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Could not claim the virtual-camera service. Start ASCII Camera through asciicam."}];
        }
        return NO;
    }

    self.port = port;
    self.port.delegate = self;
    self.runLoop = NSRunLoop.currentRunLoop;
    [self.runLoop addPort:self.port forMode:NSDefaultRunLoopMode];
    return YES;
}

- (void)handlePortMessage:(NSPortMessage *)message
{
    if (message.msgid != LegacyMachMessageConnect || !message.sendPort) {
        return;
    }
    @synchronized(self) {
        [self.clientPorts addObject:message.sendPort];
    }
}

- (void)sendPixelBuffer:(CVPixelBufferRef)frame
               timestamp:(uint64_t)timestamp
            fpsNumerator:(uint32_t)fpsNumerator
          fpsDenominator:(uint32_t)fpsDenominator
{
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(frame);
    if (!surface) {
        return;
    }

    NSArray<NSPort *> *ports;
    @synchronized(self) {
        if (self.clientPorts.count == 0) {
            return;
        }
        ports = self.clientPorts.allObjects;
    }

    mach_port_t framePort = IOSurfaceCreateMachPort(surface);
    if (framePort == MACH_PORT_NULL) {
        return;
    }

    NSData *timestampData = [NSData dataWithBytes:&timestamp length:sizeof(timestamp)];
    NSData *fpsNumeratorData = [NSData dataWithBytes:&fpsNumerator length:sizeof(fpsNumerator)];
    NSData *fpsDenominatorData = [NSData dataWithBytes:&fpsDenominator length:sizeof(fpsDenominator)];
    NSPort *surfacePort = [NSMachPort portWithMachPort:framePort options:NSMachPortDeallocateNone];
    NSArray *components = @[surfacePort, timestampData, fpsNumeratorData, fpsDenominatorData];
    NSMutableArray<NSPort *> *deadPorts = [NSMutableArray array];

    for (NSPort *clientPort in ports) {
        @try {
            NSPortMessage *message = [[NSPortMessage alloc] initWithSendPort:clientPort
                                                                receivePort:nil
                                                                 components:components];
            message.msgid = LegacyMachMessageFrame;
            if (!clientPort.isValid || ![message sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]) {
                [deadPorts addObject:clientPort];
            }
        } @catch (__unused NSException *exception) {
            [deadPorts addObject:clientPort];
        }
    }

    mach_port_deallocate(mach_task_self(), framePort);
    if (deadPorts.count > 0) {
        @synchronized(self) {
            [self.clientPorts minusSet:[NSSet setWithArray:deadPorts]];
        }
    }
}

- (void)stop
{
    NSArray<NSPort *> *ports;
    @synchronized(self) {
        ports = self.clientPorts.allObjects;
        [self.clientPorts removeAllObjects];
    }
    for (NSPort *clientPort in ports) {
        NSPortMessage *message = [[NSPortMessage alloc] initWithSendPort:clientPort
                                                            receivePort:nil
                                                             components:nil];
        message.msgid = LegacyMachMessageStop;
        [message sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }

    if (self.port) {
        [self.runLoop removePort:self.port forMode:NSDefaultRunLoopMode];
        self.port.delegate = nil;
        [self.port invalidate];
        self.port = nil;
    }
}

- (void)dealloc
{
    [self stop];
}

@end
