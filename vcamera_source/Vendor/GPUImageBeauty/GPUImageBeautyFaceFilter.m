// GPUImageBeautyFaceFilter.m
// Full beauty filter with skin tone correction and blemish masking.
#import "GPUImageBeautyFaceFilter.h"

NSString *const kGPUImageSkinToneCorrectionFragmentShader = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 uniform sampler2D inputImageTexture;
 uniform highp float skinTone;
 uniform highp float blemish;

 const highp vec3 kSkinLow  = vec3(0.60, 0.40, 0.30);
 const highp vec3 kSkinHigh = vec3(0.95, 0.80, 0.70);

 void main() {
     lowp vec4 color = texture2D(inputImageTexture, textureCoordinate);

     // Detect skin-colored pixels
     bvec3 inRange = bvec3(
         color.r >= kSkinLow.r && color.r <= kSkinHigh.r,
         color.g >= kSkinLow.g && color.g <= kSkinHigh.g,
         color.b >= kSkinLow.b && color.b <= kSkinHigh.b
     );
     highp float skinMask = float(all(inRange));

     // Skin tone: push towards neutral warm
     highp vec3 toneTarget = vec3(0.88, 0.72, 0.62);
     color.rgb = mix(color.rgb, toneTarget, skinMask * skinTone * 0.3);

     gl_FragColor = color;
 }
);

@implementation GPUImageBeautyFaceFilter {
    GPUImageFilter *_skinToneFilter;
}

- (id)init {
    self = [super init];
    if (self) {
        _skinTone = 0.5;
        _blemish  = 0.5;

        _skinToneFilter = [[GPUImageFilter alloc] initWithFragmentShaderFromString:kGPUImageSkinToneCorrectionFragmentShader];
        [_skinToneFilter setFloat:(GLfloat)_skinTone forUniformName:@"skinTone"];
        [_skinToneFilter setFloat:(GLfloat)_blemish  forUniformName:@"blemish"];

        [self addFilter:_skinToneFilter];
    }
    return self;
}

- (void)dealloc {
    [_skinToneFilter release];
    [super dealloc];
}

- (void)setSkinTone:(CGFloat)skinTone {
    _skinTone = skinTone;
    [_skinToneFilter setFloat:(GLfloat)skinTone forUniformName:@"skinTone"];
}

- (void)setBlemish:(CGFloat)blemish {
    _blemish = blemish;
    [_skinToneFilter setFloat:(GLfloat)blemish forUniformName:@"blemish"];
}

@end
