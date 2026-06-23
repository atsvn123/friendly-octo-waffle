// GPUImageBoxHighPassFilter.m
// High-pass filter: subtracts box-blurred version from original.
// Used for skin detail preservation in the beauty pipeline.
#import "GPUImageBoxHighPassFilter.h"
#import "GPUImageBoxBlurFilter.h"
#import "GPUImageBoxDifferenceFilter.h"

@implementation GPUImageBoxHighPassFilter {
    GPUImageBoxBlurFilter      *_blurFilter;
    GPUImageBoxDifferenceFilter *_diffFilter;
}

- (id)init {
    self = [super init];
    if (self) {
        _blurRadius = 4.0;
        _strength   = 1.0;

        _blurFilter = [[GPUImageBoxBlurFilter alloc] init];
        _diffFilter = [[GPUImageBoxDifferenceFilter alloc] init];

        [self addFilter:_blurFilter];
        [self addFilter:_diffFilter];

        // original -> diff input 0
        [self setInitialFilters:@[_blurFilter, _diffFilter]];
        [self setTerminalFilter:_diffFilter];
    }
    return self;
}

- (void)dealloc {
    [_blurFilter release];
    [_diffFilter release];
    [super dealloc];
}

- (void)setBlurRadius:(CGFloat)blurRadius {
    _blurRadius = blurRadius;
    _blurFilter.blurRadiusInPixels = (GLfloat)blurRadius;
}

- (void)setStrength:(CGFloat)strength {
    _strength = strength;
    _diffFilter.strength = strength;
}

@end
