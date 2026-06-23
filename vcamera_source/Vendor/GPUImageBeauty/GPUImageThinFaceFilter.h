// GPUImageThinFaceFilter.h
// Face-thinning filter using facial landmark warp.
// Takes 68-point face landmarks and warps cheek/jaw region towards face center.
// Hooked by BINFlashCamera to capture face positions for pixel-level flash.
#import "GPUImageFilter.h"
#import "GPUImageBaseBeautyFaceFilter.h"

@interface GPUImageThinFaceFilter : GPUImageFilter

@property (nonatomic, assign) CGFloat thinStrength;  // 0.0–1.0
@property (nonatomic, assign) CGFloat eyeEnlarge;    // 0.0–1.0
@property (nonatomic, assign) id target;             // GPUImageBaseBeautyFaceFilter

- (id)init;

// Called when face landmark detection produces new results.
// Forwards landmarks to target beauty filter and updates warp uniforms.
// landmarks: NSArray of NSValue-wrapped CGPoints (confirmed by IDA sub_678C isKindOfClass check)
- (void)setUniformsWithLandmarks:(NSArray *)landmarks;

@end
