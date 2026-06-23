// GPUImageBaseBeautyFaceFilter.h
// Base class for all VCam beauty face filters.
// Provides white-balance/brightness control and face landmark uniform injection.
// Hooked by BINFlashAddon and BINFlashCamera tweaks.
#import "GPUImageFilterGroup.h"

// Face landmark data passed from GPUImageThinFaceFilter
typedef struct {
    float x;
    float y;
} GPUFaceLandmarkPoint;

#define kGPUFaceLandmarkCount 68

typedef struct {
    GPUFaceLandmarkPoint points[kGPUFaceLandmarkCount];
    int count;
    float confidence;
} GPUFaceLandmarks;

@interface GPUImageBaseBeautyFaceFilter : GPUImageFilterGroup

// white: 0.0–1.0 skin whitening intensity (hooked by BINFlashAddon/BINFlashCamera)
@property (nonatomic, assign) CGFloat white;
// smooth: 0.0–1.0 skin smoothing intensity
@property (nonatomic, assign) CGFloat smooth;
// sharpen: sharpness boost after smoothing
@property (nonatomic, assign) CGFloat sharpen;

- (id)init;

// Called by GPUImageThinFaceFilter when face landmarks are detected (hooked by BINFlashCamera)
// landmarks: NSArray of NSValue-wrapped CGPoints (confirmed by IDA sub_678C isKindOfClass check)
- (void)setUniformsWithLandmarks:(NSArray *)landmarks;

@end
