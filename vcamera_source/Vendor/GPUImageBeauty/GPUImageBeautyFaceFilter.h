// GPUImageBeautyFaceFilter.h
// Full beauty filter: extends base with skin tone and blemish correction.
#import "GPUImageBaseBeautyFaceFilter.h"

@interface GPUImageBeautyFaceFilter : GPUImageBaseBeautyFaceFilter
@property (nonatomic, assign) CGFloat skinTone;
@property (nonatomic, assign) CGFloat blemish;
- (id)init;
@end
