// BINFlashFaceRegion.m
// Reconstructed from sub_5F50 + sub_678C (IDA-confirmed, BINFlashCamera.dylib).

#import "BINFlashFaceRegion.h"
#import "BINFlashPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

double g_faceCX           = 0.5;
double g_faceCY           = 0.42;
double g_faceRX           = 0.30;
double g_faceRY           = 0.35;
double g_faceTimestamp    = 0.0;
BOOL   g_faceEverDetected = NO;

#define clamp(x, lo, hi) fmax((lo), fmin((hi), (x)))

// sub_5F50
void BINFlashComputeFaceRegion(NSDictionary *prefs,
                                size_t imgWidth, size_t imgHeight,
                                double *outCX, double *outCY,
                                double *outRX, double *outRY)
{
    BOOL manualRegion = BINFlashBoolForKey(prefs, kBINFlashKeyManualRegion, kBINFlashDefaultManualRegion);
    double region     = BINFlashDoubleForKey(prefs, kBINFlashKeyRegion, kBINFlashDefaultRegion);

    double faceCX, faceCY;
    BOOL usingFaceData = NO;

    if (manualRegion) {
        faceCX = BINFlashDoubleForKey(prefs, kBINFlashKeyRegionX, kBINFlashDefaultRegionX);
        faceCY = BINFlashDoubleForKey(prefs, kBINFlashKeyRegionY, kBINFlashDefaultRegionY);
    } else if (g_faceEverDetected) {
        // Sticky: hold last known face position — no jump to centre when GPUImage
        // briefly loses tracking (occlusion, head turn).
        faceCX        = g_faceCX;
        faceCY        = g_faceCY;
        usingFaceData = YES;
    } else {
        faceCX = 0.5;
        faceCY = 0.42;
    }

    double r      = clamp(region / 100.0, 0.1, 1.0);
    double minDim = (double)fmax(fmin((double)imgWidth, (double)imgHeight), 1.0);

    // Base radii.
    // Globals (g_faceRX/RY) are stored in raw BUFFER space (landscape for iPhone portrait).
    // For a landscape buffer, rx spans the wide axis (buffer-horizontal = portrait-vertical).
    // → rx needs the LARGER base; ry needs the SMALLER base.
    // For a portrait buffer (or no-rotation), the standard orientation applies.
    double smallerBase = minDim * (r * 0.25 + 0.15);
    double largerBase  = minDim * (r * 0.36 + 0.24);
    BOOL landscape = (imgWidth > imgHeight);
    double baseForRX = landscape ? largerBase  : smallerBase;
    double baseForRY = landscape ? smallerBase : largerBase;

    double rx_computed = baseForRX;
    double ry_computed = baseForRY;

    if (usingFaceData) {
        double scaleFactor = r * 0.2 + 0.84;
        double faceScaleX  = g_faceRX * (double)imgWidth  * 0.5;
        double faceScaleY  = g_faceRY * (double)imgHeight * 0.5;
        // In landscape buffer: rx (horizontal) corresponds to the large portrait dimension.
        rx_computed = fmax(baseForRX, scaleFactor * (landscape ? fmax(faceScaleX, faceScaleY) : fmin(faceScaleX, faceScaleY)));
        ry_computed = fmax(baseForRY, scaleFactor * (landscape ? fmin(faceScaleX, faceScaleY) : fmax(faceScaleX, faceScaleY)));
    }

    double cx  = clamp(faceCX, 0.08, 0.92) * imgWidth;
    double cy  = clamp(faceCY, 0.08, 0.92) * imgHeight;
    double maxR = minDim * 0.66;
    double minR = fmax(minDim * 0.14, 8.0);
    *outCX = cx;
    *outCY = cy;
    *outRX = clamp(rx_computed, minR, maxR);
    *outRY = clamp(ry_computed, minR, maxR);
}

// sub_678C
void BINFlashUpdateFaceFromLandmarks(NSArray *landmarks) {
    if (!landmarks || landmarks.count < 3) return;

    double minX = DBL_MAX, minY = DBL_MAX;
    double maxX = -DBL_MAX, maxY = -DBL_MAX;
    NSUInteger validCount = 0;

    for (id point in landmarks) {
        if (!point) continue;

        CGPoint p = CGPointZero;
        BOOL gotPoint = NO;

        if ([point isKindOfClass:[NSValue class]]) {
            [(NSValue *)point getValue:&p];
            if (!isfinite(p.x) || !isfinite(p.y)) continue;
            gotPoint = YES;
        } else if ([point isKindOfClass:[NSDictionary class]]) {
            id xv = ((NSDictionary *)point)[@"x"] ?: ((NSDictionary *)point)[@"X"];
            id yv = ((NSDictionary *)point)[@"y"] ?: ((NSDictionary *)point)[@"Y"];
            if (![xv respondsToSelector:@selector(doubleValue)] ||
                ![yv respondsToSelector:@selector(doubleValue)]) {
                xv = [point valueForKey:@"x"];
                yv = [point valueForKey:@"y"];
            }
            if (![xv respondsToSelector:@selector(doubleValue)] ||
                ![yv respondsToSelector:@selector(doubleValue)]) continue;
            p.x = [xv doubleValue];
            p.y = [yv doubleValue];
            if (!isfinite(p.x) || !isfinite(p.y)) continue;
            gotPoint = YES;
        }

        if (!gotPoint) continue;
        minX = fmin(minX, p.x); minY = fmin(minY, p.y);
        maxX = fmax(maxX, p.x); maxY = fmax(maxY, p.y);
        validCount++;
    }

    if (validCount < 3) return;
    if (!isfinite(minX) || !isfinite(maxX)) return;

    double cx = (minX + maxX) * 0.5;
    double cy = (minY + maxY) * 0.5;
    double rx = fmax((maxX - minX) * 1.45, 0.18);
    double ry = fmax((maxY - minY) * 1.70, 0.24);

    // Remap from [-1,1] NDC to [0,1] if center is outside [0,1]
    if (cx < 0.0 || cx > 1.0 || cy < 0.0 || cy > 1.0) {
        cx = (cx + 1.0) * 0.5; cy = (cy + 1.0) * 0.5;
        rx *= 0.5; ry *= 0.5;
    }

    g_faceCX           = clamp(cx, 0.15, 0.85);
    g_faceCY           = clamp(cy, 0.12, 0.88);
    g_faceRX           = clamp(rx, 0.20, 0.85);
    g_faceRY           = clamp(ry, 0.25, 0.95);
    g_faceTimestamp    = CFAbsoluteTimeGetCurrent();
    g_faceEverDetected = YES;
}

