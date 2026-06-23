// GPUImageBaseBeautyFaceFilter.m
// Multi-pass skin beauty pipeline:
//   1. BoxHighPass: extract skin texture detail
//   2. GaussianBlur: skin-frequency smoothing
//   3. Composite: blend detail back over blurred layer with brightness control
//
// GPU shader implements bilateral-style smoothing guided by the high-pass mask.
// setWhite: adjusts the brightness/whitening of the composited result.
// setUniformsWithLandmarks: passes face region bounds for spatially-limited smoothing.

#import "GPUImageBaseBeautyFaceFilter.h"
#import "GPUImageGaussianBlurFilter.h"
#import "GPUImageSharpenFilter.h"
#import "GPUImageBoxHighPassFilter.h"

// Composite fragment shader: blends original, smoothed, and detail layers
NSString *const kGPUImageBeautyCompositeFragmentShader = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 varying highp vec2 textureCoordinate2;

 uniform sampler2D inputImageTexture;   // blurred
 uniform sampler2D inputImageTexture2;  // original
 uniform highp float smooth;
 uniform highp float white;

 const highp vec3 W = vec3(0.299, 0.587, 0.114);

 void main() {
     lowp vec4 blurred  = texture2D(inputImageTexture,  textureCoordinate);
     lowp vec4 original = texture2D(inputImageTexture2, textureCoordinate2);

     highp float lum = dot(original.rgb, W);
     highp float mask = 1.0 - abs(lum - 0.5) * 2.0;

     lowp vec4 smoothed = mix(original, blurred, smooth * mask);

     // Whitening: lift towards white based on luminance
     highp float wFactor = white * 0.35;
     smoothed.rgb = smoothed.rgb + (1.0 - smoothed.rgb) * wFactor * mask;

     gl_FragColor = smoothed;
 }
);

@implementation GPUImageBaseBeautyFaceFilter {
    GPUImageGaussianBlurFilter  *_blurFilter;
    GPUImageFilter              *_compositeFilter;
    GPUImageSharpenFilter       *_sharpenFilter;

    BOOL                         _hasLandmarks;
}

- (id)init {
    self = [super init];
    if (self) {
        _white   = 0.5;
        _smooth  = 0.5;
        _sharpen = 0.3;
        _hasLandmarks = NO;

        _blurFilter = [[GPUImageGaussianBlurFilter alloc] init];
        _blurFilter.blurRadiusInPixels = 4.0;

        _compositeFilter = [[GPUImageFilter alloc] initWithFragmentShaderFromString:kGPUImageBeautyCompositeFragmentShader];
        [_compositeFilter setFloat:(GLfloat)_smooth  forUniformName:@"smooth"];
        [_compositeFilter setFloat:(GLfloat)_white   forUniformName:@"white"];

        _sharpenFilter = [[GPUImageSharpenFilter alloc] init];
        _sharpenFilter.sharpness = (GLfloat)_sharpen;

        [self addFilter:_blurFilter];
        [self addFilter:_compositeFilter];
        [self addFilter:_sharpenFilter];

        [_blurFilter addTarget:_compositeFilter];
        [_compositeFilter addTarget:_sharpenFilter];

        [self setInitialFilters:@[_blurFilter]];
        [self setTerminalFilter:_sharpenFilter];
    }
    return self;
}

- (void)dealloc {
    [_blurFilter release];
    [_compositeFilter release];
    [_sharpenFilter release];
    [super dealloc];
}

- (void)setWhite:(CGFloat)white {
    _white = white;
    [_compositeFilter setFloat:(GLfloat)white forUniformName:@"white"];
}

- (void)setSmooth:(CGFloat)smooth {
    _smooth = smooth;
    [_compositeFilter setFloat:(GLfloat)smooth forUniformName:@"smooth"];
}

- (void)setSharpen:(CGFloat)sharpen {
    _sharpen = sharpen;
    _sharpenFilter.sharpness = (GLfloat)sharpen;
}

- (void)setUniformsWithLandmarks:(NSArray *)landmarks {
    if (!landmarks || landmarks.count < 3) {
        _hasLandmarks = NO;
        return;
    }

    float minX = 1e9f, minY = 1e9f, maxX = -1e9f, maxY = -1e9f;
    NSUInteger validCount = 0;

    for (id point in landmarks) {
        if (!point) continue;
        CGPoint p = CGPointZero;
        BOOL got = NO;
        if ([point isKindOfClass:[NSValue class]]) {
            [(NSValue *)point getValue:&p];
            got = isfinite(p.x) && isfinite(p.y);
        } else if ([point isKindOfClass:[NSDictionary class]]) {
            id xv = ((NSDictionary *)point)[@"x"] ?: [point valueForKey:@"x"];
            id yv = ((NSDictionary *)point)[@"y"] ?: [point valueForKey:@"y"];
            if ([xv respondsToSelector:@selector(doubleValue)] &&
                [yv respondsToSelector:@selector(doubleValue)]) {
                p.x = [xv doubleValue]; p.y = [yv doubleValue];
                got = isfinite(p.x) && isfinite(p.y);
            }
        }
        if (!got) continue;
        if (p.x < minX) minX = p.x; if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y; if (p.y > maxY) maxY = p.y;
        validCount++;
    }

    if (validCount < 3) { _hasLandmarks = NO; return; }
    _hasLandmarks = YES;

    // Remap from [-1,1] NDC to [0,1] if needed
    if (minX < 0.0f || maxX > 1.0f) { minX = (minX + 1.0f) * 0.5f; maxX = (maxX + 1.0f) * 0.5f; }
    if (minY < 0.0f || maxY > 1.0f) { minY = (minY + 1.0f) * 0.5f; maxY = (maxY + 1.0f) * 0.5f; }

    // Shader may not have these uniforms — setFloat:forUniformName: is a no-op if not found
    [_compositeFilter setFloat:minX forUniformName:@"faceMinX"];
    [_compositeFilter setFloat:minY forUniformName:@"faceMinY"];
    [_compositeFilter setFloat:maxX forUniformName:@"faceMaxX"];
    [_compositeFilter setFloat:maxY forUniformName:@"faceMaxY"];
}

@end
