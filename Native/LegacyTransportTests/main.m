#import "LegacyVirtualCameraServer.h"

#import <IOSurface/IOSurface.h>
#import <mach/mach.h>

@interface TestClient : NSObject <NSPortDelegate>
@property(nonatomic) BOOL receivedFrame;
@property(nonatomic) uint64_t timestamp;
@property(nonatomic) size_t width;
@property(nonatomic) size_t height;
@end

@implementation TestClient
- (void)handlePortMessage:(NSPortMessage *)message
{
    if (message.msgid != 2 || message.components.count < 4) {
        return;
    }
    NSMachPort *framePort = message.components[0];
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(framePort.machPort);
    if (!surface) {
        return;
    }
    CVPixelBufferRef frame = nil;
    CVReturn status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &frame);
    CFRelease(surface);
    if (status == kCVReturnSuccess && frame) {
        self.width = CVPixelBufferGetWidth(frame);
        self.height = CVPixelBufferGetHeight(frame);
        [message.components[1] getBytes:&_timestamp length:sizeof(_timestamp)];
        self.receivedFrame = YES;
        CVPixelBufferRelease(frame);
    }
    [framePort invalidate];
}
@end

static BOOL RunUntil(BOOL (^condition)(void), NSTimeInterval timeout)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

int main(void)
{
    @autoreleasepool {
        NSString *serviceName = @"com.yigit.asciicamera.transport-test";
        LegacyVirtualCameraServer *server = [[LegacyVirtualCameraServer alloc] initWithServiceName:serviceName];
        NSError *error = nil;
        NSCAssert([server start:&error], @"server start failed: %@", error);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSPort *serverPort = [[NSMachBootstrapServer sharedInstance] portForName:serviceName];
#pragma clang diagnostic pop
        NSCAssert(serverPort, @"could not find test server port");

        TestClient *client = [TestClient new];
        NSPort *receivePort = [NSMachPort port];
        receivePort.delegate = client;
        [NSRunLoop.currentRunLoop addPort:receivePort forMode:NSDefaultRunLoopMode];
        NSPortMessage *connect = [[NSPortMessage alloc] initWithSendPort:serverPort
                                                            receivePort:receivePort
                                                             components:nil];
        connect.msgid = 1;
        NSCAssert([connect sendBeforeDate:[NSDate dateWithTimeIntervalSinceNow:1]], @"connect failed");
        NSCAssert(RunUntil(^BOOL { return server.clientCount == 1; }, 1), @"server did not register client");

        CVPixelBufferRef frame = nil;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA,
                                               (__bridge CFDictionaryRef)attributes, &frame);
        NSCAssert(status == kCVReturnSuccess && frame, @"could not create IOSurface pixel buffer");
        [server sendPixelBuffer:frame timestamp:123456789 fpsNumerator:30 fpsDenominator:1];
        CVPixelBufferRelease(frame);

        NSCAssert(RunUntil(^BOOL { return client.receivedFrame; }, 1), @"client did not receive frame");
        NSCAssert(client.width == 64 && client.height == 36, @"frame dimensions changed");
        NSCAssert(client.timestamp == 123456789, @"timestamp changed");
        [server stop];
        puts("Legacy IOSurface transport test passed");
    }
    return 0;
}
