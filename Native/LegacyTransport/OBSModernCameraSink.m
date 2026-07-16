#import "OBSModernCameraSink.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CoreMediaIO.h>

static NSString *const OBSModernCameraDeviceUUID = @"7626645E-4425-469E-9D8B-97E0FA59AC75";
static const int32_t OBSModernCameraWidth = 1920;
static const int32_t OBSModernCameraHeight = 1080;

@interface OBSModernCameraSink ()
@property(nonatomic) CMIODeviceID deviceID;
@property(nonatomic) CMIOStreamID streamID;
@property(nonatomic) CMSimpleQueueRef queue;
@property(nonatomic) CMVideoFormatDescriptionRef formatDescription;
@end

@implementation OBSModernCameraSink

- (BOOL)isRunning
{
    return self.deviceID != 0 && self.streamID != 0 && self.queue != NULL;
}

- (BOOL)start:(NSError **)error
{
    if (self.isRunning) return YES;

    CMIOObjectPropertyAddress address = {
        kCMIOHardwarePropertyDevices,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain,
    };
    UInt32 size = 0;
    UInt32 used = 0;
    OSStatus status = CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        return [self fail:error code:1 message:@"OBS Camera Extension is not activated."];
    }

    NSMutableData *deviceData = [NSMutableData dataWithLength:size];
    status = CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, NULL, size, &used,
                                       deviceData.mutableBytes);
    if (status != noErr) {
        return [self fail:error code:2 message:@"Could not enumerate CoreMediaIO cameras."];
    }

    CMIODeviceID foundDevice = 0;
    CMIOObjectID *devices = deviceData.mutableBytes;
    for (NSUInteger index = 0; index < used / sizeof(CMIOObjectID); index++) {
        address.mSelector = kCMIODevicePropertyDeviceUID;
        UInt32 uidSize = sizeof(CFStringRef);
        UInt32 uidUsed = 0;
        CFStringRef uid = NULL;
        if (!CMIOObjectHasProperty(devices[index], &address)) continue;
        status = CMIOObjectGetPropertyData(devices[index], &address, 0, NULL, uidSize, &uidUsed, &uid);
        if (status == noErr && uid) {
            if ([(__bridge NSString *)uid caseInsensitiveCompare:OBSModernCameraDeviceUUID] == NSOrderedSame) {
                foundDevice = devices[index];
            }
            CFRelease(uid);
        }
        if (foundDevice != 0) break;
    }
    if (foundDevice == 0) {
        return [self fail:error code:3 message:@"OBS Camera Extension device is unavailable."];
    }

    address.mSelector = kCMIODevicePropertyStreams;
    status = CMIOObjectGetPropertyDataSize(foundDevice, &address, 0, NULL, &size);
    if (status != noErr || size < 2 * sizeof(CMIOStreamID)) {
        return [self fail:error code:4 message:@"OBS Camera Extension sink stream is unavailable."];
    }
    NSMutableData *streamData = [NSMutableData dataWithLength:size];
    status = CMIOObjectGetPropertyData(foundDevice, &address, 0, NULL, size, &used, streamData.mutableBytes);
    if (status != noErr || used < 2 * sizeof(CMIOStreamID)) {
        return [self fail:error code:5 message:@"Could not read the OBS Camera Extension streams."];
    }

    CMIOStreamID sinkStream = 0;
    [streamData getBytes:&sinkStream range:NSMakeRange(sizeof(CMIOStreamID), sizeof(CMIOStreamID))];
    CMSimpleQueueRef queue = NULL;
    status = CMIOStreamCopyBufferQueue(sinkStream, OBSModernCameraQueueChanged, NULL, &queue);
    if (status != noErr || !queue) {
        return [self fail:error code:6 message:@"Could not open the OBS Camera Extension sink queue."];
    }

    CMVideoFormatDescriptionRef format = NULL;
    status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_32BGRA,
                                             OBSModernCameraWidth, OBSModernCameraHeight, NULL, &format);
    if (status != noErr || !format) {
        CFRelease(queue);
        return [self fail:error code:7 message:@"Could not create the OBS Camera Extension video format."];
    }

    status = CMIODeviceStartStream(foundDevice, sinkStream);
    if (status != noErr) {
        CFRelease(format);
        CFRelease(queue);
        return [self fail:error code:8 message:@"Could not start the OBS Camera Extension sink stream."];
    }

    self.deviceID = foundDevice;
    self.streamID = sinkStream;
    self.queue = queue;
    self.formatDescription = format;
    return YES;
}

static void OBSModernCameraQueueChanged(CMIOStreamID streamID, void *token, void *refCon)
{
    (void)streamID;
    (void)token;
    (void)refCon;
}

- (void)sendPixelBuffer:(CVPixelBufferRef)frame timestamp:(uint64_t)timestamp
{
    if (!self.isRunning || CMSimpleQueueGetFullness(self.queue) >= 1.0) return;
    if (CVPixelBufferGetWidth(frame) != OBSModernCameraWidth ||
        CVPixelBufferGetHeight(frame) != OBSModernCameraHeight ||
        CVPixelBufferGetPixelFormatType(frame) != kCVPixelFormatType_32BGRA) return;

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake((int64_t)timestamp, NSEC_PER_SEC),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, frame, true, NULL, NULL,
                                                         self.formatDescription, &timing, &sampleBuffer);
    if (status != noErr || !sampleBuffer) return;
    status = CMSimpleQueueEnqueue(self.queue, sampleBuffer);
    if (status != noErr) CFRelease(sampleBuffer);
    // The extension owns successful queue entries, matching OBS's producer.
}

- (void)stop
{
    if (self.deviceID != 0 && self.streamID != 0) {
        CMIODeviceStopStream(self.deviceID, self.streamID);
        CMSimpleQueueRef ignoredQueue = NULL;
        if (CMIOStreamCopyBufferQueue(self.streamID, NULL, NULL, &ignoredQueue) == noErr && ignoredQueue) {
            CFRelease(ignoredQueue);
        }
    }
    if (self.formatDescription) CFRelease(self.formatDescription);
    if (self.queue) CFRelease(self.queue);
    self.formatDescription = NULL;
    self.queue = NULL;
    self.deviceID = 0;
    self.streamID = 0;
}

- (BOOL)fail:(NSError **)error code:(NSInteger)code message:(NSString *)message
{
    if (error) {
        *error = [NSError errorWithDomain:@"com.yigit.asciicamera.obs-modern-sink"
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

- (void)dealloc
{
    [self stop];
}

@end
