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
// Copies the Y-plane synchronously (while CVPixelBufferLock is held),
// then dispatches Vision face detection async on a background thread.
// Atomic busy flag prevents queue accumulation: if a previous detection is
// still running, this call is a no-op (no malloc, no dispatch).
void BINFlashScheduleVisionDetection(const void *yBytes,
                                      size_t yWidth, size_t yHeight,
                                      size_t yStride);
