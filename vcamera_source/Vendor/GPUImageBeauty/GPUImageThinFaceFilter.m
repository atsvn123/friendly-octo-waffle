// GPUImageThinFaceFilter.m
// GPU-based face thinning: warps image pixels near cheek/jaw landmarks towards
// the nose bridge, creating a slimming effect.
//
// Warp algorithm: for each fragment within a warp circle centered at a landmark,
// apply a smooth radial displacement towards the warp target (face center).
// Max 8 warp points per pass (GPU uniform array limit of 8 vec2 pairs).

#import "GPUImageThinFaceFilter.h"

#define kMaxWarpPoints 8

NSString *const kGPUImageThinFaceVertexShader = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 inputTextureCoordinate;
 varying   vec2 textureCoordinate;
 void main() {
     gl_Position = position;
     textureCoordinate = inputTextureCoordinate.xy;
 }
);

NSString *const kGPUImageThinFaceFragmentShader = SHADER_STRING
(
 precision highp float;
 varying vec2 textureCoordinate;
 uniform sampler2D inputImageTexture;
 uniform vec2  warpFrom[8];
 uniform vec2  warpTo[8];
 uniform float warpRadius[8];
 uniform int   warpCount;
 uniform float thinStrength;
 uniform vec2  aspectRatio;

 void main() {
     vec2 coord = textureCoordinate;

     for (int i = 0; i < 8; i++) {
         if (i >= warpCount) break;

         vec2 from   = warpFrom[i];
         vec2 to     = warpTo[i];
         float radius = warpRadius[i];

         vec2 diff  = coord - from;
         diff      *= aspectRatio;
         float dist = length(diff);

         if (dist < radius) {
             float factor = 1.0 - dist / radius;
             factor = factor * factor * (3.0 - 2.0 * factor);
             coord += (to - from) * factor * thinStrength;
         }
     }

     gl_FragColor = texture2D(inputImageTexture, coord);
 }
);

@implementation GPUImageThinFaceFilter {
    GLint  _warpFromLocation;
    GLint  _warpToLocation;
    GLint  _warpRadiusLocation;
    GLint  _warpCountLocation;
    GLint  _thinStrengthLocation;
    GLint  _aspectRatioLocation;

    GLfloat _warpFromData[kMaxWarpPoints * 2];
    GLfloat _warpToData[kMaxWarpPoints * 2];
    GLfloat _warpRadiusData[kMaxWarpPoints];
    GLint   _warpCount;

    CGSize  _lastSize;
}

- (id)init {
    self = [super initWithVertexShaderFromString:kGPUImageThinFaceVertexShader
                     fragmentShaderFromString:kGPUImageThinFaceFragmentShader];
    if (self) {
        _thinStrength = 0.5;
        _eyeEnlarge   = 0.0;
        _warpCount    = 0;
        _lastSize     = CGSizeZero;
        memset(_warpFromData,   0, sizeof(_warpFromData));
        memset(_warpToData,     0, sizeof(_warpToData));
        memset(_warpRadiusData, 0, sizeof(_warpRadiusData));

        [filterProgram use];
        _warpFromLocation     = [filterProgram uniformIndex:@"warpFrom"];
        _warpToLocation       = [filterProgram uniformIndex:@"warpTo"];
        _warpRadiusLocation   = [filterProgram uniformIndex:@"warpRadius"];
        _warpCountLocation    = [filterProgram uniformIndex:@"warpCount"];
        _thinStrengthLocation = [filterProgram uniformIndex:@"thinStrength"];
        _aspectRatioLocation  = [filterProgram uniformIndex:@"aspectRatio"];
    }
    return self;
}

- (void)setThinStrength:(CGFloat)thinStrength {
    _thinStrength = thinStrength;
    [self setFloat:(GLfloat)thinStrength forUniformName:@"thinStrength"];
}

// Parse a single element from the landmarks NSArray into a CGPoint.
// Supports NSValue-wrapped CGPoints and NSDictionary with "x"/"y" keys.
static BOOL thinFaceExtractPoint(id obj, CGPoint *outP) {
    if (!obj) return NO;
    if ([obj isKindOfClass:[NSValue class]]) {
        [(NSValue *)obj getValue:outP];
        return isfinite(outP->x) && isfinite(outP->y);
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        id xv = ((NSDictionary *)obj)[@"x"] ?: [obj valueForKey:@"x"];
        id yv = ((NSDictionary *)obj)[@"y"] ?: [obj valueForKey:@"y"];
        if (![xv respondsToSelector:@selector(doubleValue)] ||
            ![yv respondsToSelector:@selector(doubleValue)]) return NO;
        outP->x = [xv doubleValue]; outP->y = [yv doubleValue];
        return isfinite(outP->x) && isfinite(outP->y);
    }
    return NO;
}

static void remapPoint(CGPoint *p) {
    if (p->x < 0.0 || p->x > 1.0 || p->y < 0.0 || p->y > 1.0) {
        p->x = (p->x + 1.0) * 0.5;
        p->y = (p->y + 1.0) * 0.5;
    }
}

- (void)setUniformsWithLandmarks:(NSArray *)landmarks {
    if (!landmarks || landmarks.count < 17) {
        _warpCount = 0;
        return;
    }

    // Forward to target beauty filter for skin smoothing region
    if ([self.target respondsToSelector:@selector(setUniformsWithLandmarks:)]) {
        [self.target setUniformsWithLandmarks:landmarks];
    }

    NSUInteger count = landmarks.count;

    // Compute face center from the mean of all valid points
    double sumX = 0, sumY = 0;
    int validCount = 0;
    for (id pt in landmarks) {
        CGPoint p;
        if (thinFaceExtractPoint(pt, &p)) {
            sumX += p.x; sumY += p.y;
            validCount++;
        }
    }
    if (validCount == 0) return;

    float centerX = (float)(sumX / validCount);
    float centerY = (float)(sumY / validCount);
    // Remap center if in [-1,1] NDC range
    if (centerX < 0.0f || centerX > 1.0f || centerY < 0.0f || centerY > 1.0f) {
        centerX = (centerX + 1.0f) * 0.5f;
        centerY = (centerY + 1.0f) * 0.5f;
    }

    // Cheek/jaw contour indices in standard 68-point face model (jawline 0-16)
    int cheekIndices[] = {1, 2, 3, 4, 5, 11, 12, 13};
    int nCheek = (int)(sizeof(cheekIndices) / sizeof(cheekIndices[0]));
    if (nCheek > kMaxWarpPoints) nCheek = kMaxWarpPoints;

    _warpCount = 0;
    for (int i = 0; i < nCheek && _warpCount < kMaxWarpPoints; i++) {
        int idx = cheekIndices[i];
        if (idx >= (int)count) continue;

        CGPoint p;
        if (!thinFaceExtractPoint(landmarks[idx], &p)) continue;
        remapPoint(&p);

        _warpFromData[_warpCount * 2 + 0] = (GLfloat)p.x;
        _warpFromData[_warpCount * 2 + 1] = (GLfloat)p.y;
        _warpToData[_warpCount * 2 + 0] = (GLfloat)(p.x + (centerX - p.x) * 0.1f);
        _warpToData[_warpCount * 2 + 1] = (GLfloat)(p.y + (centerY - p.y) * 0.1f);
        _warpRadiusData[_warpCount] = 0.12f;
        _warpCount++;
    }

    // Upload to GPU
    runSynchronouslyOnVideoProcessingQueue(^{
        [GPUImageContext setActiveShaderProgram:filterProgram];
        glUniform2fv(_warpFromLocation, _warpCount, _warpFromData);
        glUniform2fv(_warpToLocation, _warpCount, _warpToData);
        glUniform1fv(_warpRadiusLocation, _warpCount, _warpRadiusData);
        glUniform1i(_warpCountLocation, _warpCount);
    });
}

- (void)renderToTextureWithVertices:(const GLfloat *)vertices textureCoordinates:(const GLfloat *)textureCoordinates {
    // Update aspect ratio before each render
    CGSize size = outputFramebuffer.size;
    if (!CGSizeEqualToSize(size, _lastSize) && size.height > 0) {
        _lastSize = size;
        GLfloat aspect[2] = { (GLfloat)(size.height / size.width), 1.0f };
        glUniform2fv(_aspectRatioLocation, 1, aspect);
    }
    [super renderToTextureWithVertices:vertices textureCoordinates:textureCoordinates];
}

@end
