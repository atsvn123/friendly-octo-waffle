// GPUImageBoxDifferenceFilter.h
// Custom beauty filter: computes difference between original and box-blurred version.
// Used as a high-frequency detail extraction layer for skin smoothing.
#import "GPUImageTwoInputFilter.h"

@interface GPUImageBoxDifferenceFilter : GPUImageTwoInputFilter
@property (nonatomic, assign) CGFloat blurRadius;
@property (nonatomic, assign) CGFloat strength;
- (id)init;
@end
