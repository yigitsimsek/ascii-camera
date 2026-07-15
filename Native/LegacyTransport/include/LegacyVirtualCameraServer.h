#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends IOSurface-backed frames using the protocol understood by the
/// standalone OBS legacy DAL plug-in. OBS itself is not involved or running.
@interface LegacyVirtualCameraServer : NSObject

@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) NSUInteger clientCount;

- (instancetype)init;
- (instancetype)initWithServiceName:(NSString *)serviceName NS_DESIGNATED_INITIALIZER;
- (BOOL)start:(NSError **)error;
- (void)sendPixelBuffer:(CVPixelBufferRef)frame
               timestamp:(uint64_t)timestamp
            fpsNumerator:(uint32_t)fpsNumerator
          fpsDenominator:(uint32_t)fpsDenominator;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
