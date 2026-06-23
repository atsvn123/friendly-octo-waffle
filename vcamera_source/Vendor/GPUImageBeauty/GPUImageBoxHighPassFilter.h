// GPUImageBoxHighPassFilter.h
// High-pass filter using box blur: extracts fine skin texture detail.
#import "GPUImageFilterGroup.h"

@interface GPUImageBoxHighPassFilter : GPUImageFilterGroup
@property (nonatomic, assign) CGFloat blurRadius;
@property (nonatomic, assign) CGFloat strength;
- (id)init;
@end
