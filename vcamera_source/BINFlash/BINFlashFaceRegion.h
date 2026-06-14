// BINFlashFaceRegion.h
// Face position tracking for pixel effect targeting.

#import <Foundation/Foundation.h>

#define kBINFlashFaceTTL  1.0

extern double g_faceCX;
extern double g_faceCY;
extern double g_faceRX;
extern double g_faceRY;
extern double g_faceTimestamp;
extern BOOL   g_faceEverDetected;

void BINFlashComputeFaceRegion(NSDictionary *prefs,
                                size_t imgWidth, size_t imgHeight,
                                double *outCX, double *outCY,
                                double *outRX, double *outRY);

// Called from BINFlash_hook_setUniformsWithLandmarks in BINFlashEffectBridge.
void BINFlashUpdateFaceFromLandmarks(NSArray *landmarks);

// Called from BINFlashApplyToPixelBuffer every 9 frames.
// fmt=0: grayscale Y-plane (YUV 420 biplanar), bytesPerRow = Y stride.
// fmt=1: BGRA packed pixels, bytesPerRow = full BGRA stride (4 bytes/px).
// fmt=2: YUYV packed 4:2:2, bytesPerRow = 2*width; Y extracted internally.
// Copies pixels synchronously (while CVPixelBufferLock is held),
// then dispatches Vision face detection async on a background thread.
// Atomic busy flag prevents queue accumulation.
void BINFlashScheduleVisionDetection(const void *pixels,
                                      size_t width, size_t height,
                                      size_t bytesPerRow,
                                      int fmt);
