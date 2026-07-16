#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Publishes frames into the sink stream of OBS's signed CoreMediaIO Camera
/// Extension. OBS Studio activates/owns the extension but does not need to run.
@interface OBSModernCameraSink : NSObject

@property(nonatomic, readonly, getter=isRunning) BOOL running;

- (BOOL)start:(NSError **)error;
- (void)sendPixelBuffer:(CVPixelBufferRef)frame timestamp:(uint64_t)timestamp;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
