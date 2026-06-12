// BINFlashFaceRegion.m
// Reconstructed from sub_5F50 (0x5F50) and sub_678C (0x678C)

#import "BINFlashFaceRegion.h"
#import "../Prefs/BINFlashCameraPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// ── Global face-tracking state (qword_C2B8/C2C0/C2C8/C2D0/C328) ──
double g_faceCX        = 0.5;
double g_faceCY        = 0.42;
double g_faceRX        = 0.30;
double g_faceRY        = 0.35;
double g_faceTimestamp = 0.0;

// Once set to YES, the last known face position is held permanently instead of
// falling back to frame-center. The binary falls back after 1s TTL, but holding
// the last known position prevents the flash from jumping when GPUImage briefly
// loses tracking (occlusion, head turn).
static BOOL g_faceEverDetected = NO;

#define clamp(x, lo, hi) fmax((lo), fmin((hi), (x)))

// ── sub_5F50 ──
// Computes face ellipse in pixel coordinates for use by sub_4628.
//
// IDA-confirmed parameter order: (prefs, width, height, *CX, *CY, *RX, *RY)
// IDA-confirmed base-radius swap: portrait uses (smaller, larger) for (RX, RY);
//   landscape swaps to (larger, smaller) so the horizontal axis gets the wider base.
void BINFlashComputeFaceRegion(NSDictionary *prefs,
                                size_t imgWidth, size_t imgHeight,
                                double *outCX, double *outCY,
                                double *outRX, double *outRY)
{
    BOOL manualRegion = BINFlashCameraBoolForKey(prefs, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion);
    double region     = BINFlashCameraDoubleForKey(prefs, kBINFlashKeyRegion, kBINFlashDefaultRegion);

    double faceCX, faceCY;
    BOOL usingFaceData = NO;

    if (manualRegion) {
        faceCX = BINFlashCameraDoubleForKey(prefs, kBINFlashKeyRegionX, kBINFlashDefaultRegionX);
        faceCY = BINFlashCameraDoubleForKey(prefs, kBINFlashKeyRegionY, kBINFlashDefaultRegionY);
    } else if (g_faceEverDetected || CFAbsoluteTimeGetCurrent() - g_faceTimestamp < kBINFlashFaceTTL) {
        // Hold the last detected face position. Binary uses 1s TTL only; we also
        // keep it permanently after first detection so the flash doesn't snap to
        // center on brief tracking gaps.
        faceCX       = g_faceCX;
        faceCY       = g_faceCY;
        usingFaceData = YES;
    } else {
        faceCX = 0.5;
        faceCY = 0.42;
    }

    double r = clamp(region / 100.0, 0.1, 1.0);
    double minDim = (double)fmax(fmin((double)imgWidth, (double)imgHeight), 1.0);

    // IDA-confirmed: base radii swap roles depending on orientation.
    // Portrait (H >= W): RX uses smaller factor (narrower horizontal),
    //                    RY uses larger factor  (taller vertical).
    // Landscape (W > H): RX uses larger factor  (wider horizontal),
    //                    RY uses smaller factor (narrower vertical).
    double smallerBase = minDim * (r * 0.25 + 0.15);
    double largerBase  = minDim * (r * 0.36 + 0.24);
    BOOL portrait = (imgHeight >= imgWidth);
    double baseForRX = portrait ? smallerBase : largerBase;
    double baseForRY = portrait ? largerBase  : smallerBase;

    double rx_computed = baseForRX;
    double ry_computed = baseForRY;

    if (usingFaceData) {
        double scaleFactor = r * 0.2 + 0.84;
        double faceScaleX  = g_faceRX * (double)imgWidth  * 0.5;
        double faceScaleY  = g_faceRY * (double)imgHeight * 0.5;
        double faceSmall   = fmin(faceScaleX, faceScaleY);
        double faceLarge   = fmax(faceScaleX, faceScaleY);

        // IDA-confirmed: same swap as base radii.
        // Portrait: RX uses smaller face dim, RY uses larger.
        // Landscape: RX uses larger face dim, RY uses smaller.
        rx_computed = fmax(baseForRX, scaleFactor * (portrait ? faceSmall : faceLarge));
        ry_computed = fmax(baseForRY, scaleFactor * (portrait ? faceLarge : faceSmall));
    }

    // IDA: fmax(fmax(minDim*0.14, fmin(minDim*0.66, v)), 8.0)
    double maxR = minDim * 0.66;
    double minR = minDim * 0.14;

    double cx = clamp(faceCX, 0.08, 0.92) * (double)imgWidth;
    double cy = clamp(faceCY, 0.08, 0.92) * (double)imgHeight;
    double rx = fmax(fmax(minR, fmin(maxR, rx_computed)), 8.0);
    double ry = fmax(fmax(minR, fmin(maxR, ry_computed)), 8.0);

    *outCX = cx;
    *outCY = cy;
    *outRX = rx;
    *outRY = ry;
}

// ── sub_678C ──
// Called from the swizzled setUniformsWithLandmarks: hook.
// Iterates landmark array, computes face bounding box, stores in globals.
// IDA-confirmed: accepts NSValue(CGPoint) and NSDictionary{x/X/y/Y} elements.
// Points with coordinates outside [-1.2, 1.2] are rejected.
// [-1,1]-normalized coordinates are remapped to [0,1] if any coord < 0 or > 1.
void BINFlashUpdateFaceFromLandmarks(NSArray *landmarks) {
    if (!landmarks || landmarks.count < 3) return;
    if (![landmarks isKindOfClass:[NSArray class]]) return;

    double minX = DBL_MAX, minY = DBL_MAX;
    double maxX = -DBL_MAX, maxY = -DBL_MAX;
    NSUInteger validCount = 0;

    for (id point in landmarks) {
        CGPoint p = CGPointZero;
        BOOL gotPoint = NO;

        if ([point isKindOfClass:[NSValue class]]) {
            // IDA: checks strcmp(objCType, "{CGPoint=dd}") strictly
            NSValue *val = (NSValue *)point;
            if (strcmp(val.objCType, "{CGPoint=dd}") == 0) {
                [val getValue:&p];
                if (fabs(p.x) == INFINITY || fabs(p.y) == INFINITY) continue;
                gotPoint = YES;
            }
        } else if ([point isKindOfClass:[NSDictionary class]]) {
            // IDA: tries objectForKeyedSubscript: "x"/"X" and "y"/"Y" first,
            //      falls back to valueForKey: "x"/"y" if no doubleValue support.
            NSDictionary *d = (NSDictionary *)point;
            id xv = d[@"x"] ?: d[@"X"];
            if (!xv) xv = [d valueForKey:@"x"];
            id yv = d[@"y"] ?: d[@"Y"];
            if (!yv) yv = [d valueForKey:@"y"];
            if (![xv respondsToSelector:@selector(doubleValue)]) continue;
            if (![yv respondsToSelector:@selector(doubleValue)]) continue;
            p.x = [xv doubleValue];
            p.y = [yv doubleValue];
            if (fabs(p.x) == INFINITY || fabs(p.y) == INFINITY) continue;
            gotPoint = YES;
        }

        if (!gotPoint) continue;

        minX = fmin(minX, p.x);
        minY = fmin(minY, p.y);
        maxX = fmax(maxX, p.x);
        maxY = fmax(maxY, p.y);
        validCount++;
    }

    if (validCount < 3) return;
    if (!isfinite(minX) || !isfinite(minY) || !isfinite(maxX) || !isfinite(maxY)) return;

    // IDA: rejects coordinates outside [-1.2, 1.2] range entirely.
    BOOL inZeroOne  = (minX >= 0.0  && minY >= 0.0  && maxX <= 1.2 && maxY <= 1.2);
    BOOL inNegOne   = (minX >= -1.2 && minY >= -1.2 && maxX <= 1.2 && maxY <= 1.2);
    if (!inZeroOne && !inNegOne) return;

    double cx = (minX + maxX) * 0.5;
    double cy = (minY + maxY) * 0.5;
    double rx = fmax((maxX - minX) * 1.45, 0.18);
    double ry = fmax((maxY - minY) * 1.70, 0.24);

    // IDA: if any coord < 0 or maxX/Y > 1.2 → [-1,1] space → remap to [0,1]
    if (minX < 0.0 || minY < 0.0 || maxX > 1.2 || maxY > 1.2) {
        cx = (cx + 1.0) * 0.5;
        cy = (cy + 1.0) * 0.5;
        rx *= 0.5;
        ry *= 0.5;
    }

    g_faceCX        = clamp(cx, 0.15, 0.85);
    g_faceCY        = clamp(cy, 0.12, 0.88);
    g_faceRX        = clamp(rx, 0.20, 0.85);
    g_faceRY        = clamp(ry, 0.25, 0.95);
    g_faceTimestamp = CFAbsoluteTimeGetCurrent();
    g_faceEverDetected = YES;
}
