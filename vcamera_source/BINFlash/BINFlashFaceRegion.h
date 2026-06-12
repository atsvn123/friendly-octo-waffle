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

// Schedule async Vision face detection using a CPU-allocated YUV biplanar copy.
// Takes OWNERSHIP of both plane pointers (caller malloc'd them while holding the CPU lock).
// Creates a non-IOSurface CVPixelBuffer from the copies — safe, no kernel IOSurface access.
// Also writes result to /tmp/vcam_face_dbg for cross-process debug display.
void BINFlashScheduleVisionDetection(uint8_t *ownedYBytes,  size_t yBPR,
                                     uint8_t *ownedUVBytes, size_t uvBPR,
                                     size_t width, size_t height);
