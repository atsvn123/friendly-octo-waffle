// BINFlashFaceRegion.h
// Reconstructed from:
//   sub_5F50  (0x5F50)  — face region calculator (called from sub_4628)
//   sub_678C  (0x678C)  — swizzled GPUImageThinFaceFilter::setUniformsWithLandmarks:
//
// Global face-tracking state is shared between sub_678C (writer) and sub_5F50 (reader).
// Face position expires after 1 second (kBINFlashFaceTTL) — tracked via timestamp.
//
// The four face globals (qword_C2B8/C2C0/C2C8/C2D0) are in normalized [0,1] space.
// sub_5F50 converts them to pixel coordinates for use by sub_4628.

#import <Foundation/Foundation.h>

// How long a face detection remains valid before fallback to center
#define kBINFlashFaceTTL  1.0

// Globals written by sub_678C (the swizzled setUniformsWithLandmarks: hook)
// and read by sub_5F50.
extern double g_faceCX;       // qword_C2B8: face center X, normalized [0,1]
extern double g_faceCY;       // qword_C2C0: face center Y, normalized [0,1]
extern double g_faceRX;       // qword_C2C8: face ellipse half-width, normalized
extern double g_faceRY;       // qword_C2D0: face ellipse half-height, normalized
extern double g_faceTimestamp; // qword_C328: CFAbsoluteTime of last detection

// sub_5F50 — compute face ellipse in pixel coordinates.
// Returns face center (cx,cy) and half-radii (rx,ry) in pixels.
void BINFlashComputeFaceRegion(NSDictionary *prefs,
                                size_t imgWidth, size_t imgHeight,
                                double *outCX, double *outCY,
                                double *outRX, double *outRY);

// sub_678C — called by the swizzled setUniformsWithLandmarks: hook.
// Extracts face bounding box from GPUImage landmark array, stores in globals above.
// Also suppresses the original setWhite: and calls the original setUniformsWithLandmarks:.
// (Called inside BINFlashCameraHooks.m's swizzle handler)
void BINFlashUpdateFaceFromLandmarks(NSArray *landmarks);
