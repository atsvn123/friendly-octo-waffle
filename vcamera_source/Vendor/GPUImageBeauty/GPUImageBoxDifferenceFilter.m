// GPUImageBoxDifferenceFilter.m
// Computes (original - boxBlur(original)) to extract high-frequency skin detail.
// Used in multi-pass skin smoothing pipeline.
#import "GPUImageBoxDifferenceFilter.h"

NSString *const kGPUImageBoxDifferenceVertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 inputTextureCoordinate;
 attribute vec4 inputTextureCoordinate2;
 varying vec2 textureCoordinate;
 varying vec2 textureCoordinate2;
 void main() {
     gl_Position = position;
     textureCoordinate  = inputTextureCoordinate.xy;
     textureCoordinate2 = inputTextureCoordinate2.xy;
 }
);

NSString *const kGPUImageBoxDifferenceFragmentShaderString = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 varying highp vec2 textureCoordinate2;
 uniform sampler2D inputImageTexture;
 uniform sampler2D inputImageTexture2;
 uniform highp float strength;

 void main() {
     lowp vec4 original  = texture2D(inputImageTexture,  textureCoordinate);
     lowp vec4 blurred   = texture2D(inputImageTexture2, textureCoordinate2);
     lowp vec4 diff = clamp((original - blurred) * strength + vec4(0.5), 0.0, 1.0);
     gl_FragColor = diff;
 }
);

@implementation GPUImageBoxDifferenceFilter

- (id)init {
    self = [super initWithFragmentShaderFromString:kGPUImageBoxDifferenceFragmentShaderString];
    if (self) {
        _blurRadius = 4.0;
        _strength   = 1.0;
        [self setFloat:_strength forUniformName:@"strength"];
    }
    return self;
}

- (void)setStrength:(CGFloat)strength {
    _strength = strength;
    [self setFloat:(GLfloat)strength forUniformName:@"strength"];
}

@end
