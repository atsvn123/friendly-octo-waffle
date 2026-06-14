// BINFlashFaceRegion.m
// Reconstructed from sub_5F50 + sub_678C (IDA-confirmed, BINFlashCamera.dylib).

#import "BINFlashFaceRegion.h"
#import "BINFlashPrefs.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

extern void vcamSendDiag(NSString *msg);

double g_faceCX           = 0.5;
double g_faceCY           = 0.50;   // true frame centre (RTMP face is centred in stream)
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
        faceCY = 0.50;   // true frame centre for RTMP content
    }

    double r      = clamp(region / 100.0, 0.1, 1.0);
    double minDim = (double)fmax(fmin((double)imgWidth, (double)imgHeight), 1.0);

    // Base radii for fallback (no face detection yet).
    // RTMP face is always upright in the buffer regardless of landscape/portrait:
    // rx = horizontal radius (face width, smaller), ry = vertical radius (face height, larger).
    double smallerBase = minDim * (r * 0.25 + 0.15);
    double largerBase  = minDim * (r * 0.36 + 0.24);
    double baseForRX = smallerBase;
    double baseForRY = largerBase;

    double rx_computed = baseForRX;
    double ry_computed = baseForRY;

    if (usingFaceData) {
        double scaleFactor = r * 0.2 + 0.84;
        // Vision bounding box is in normalized buffer space — no coordinate swap needed.
        // faceScaleX = half face width in pixels, faceScaleY = half face height in pixels.
        double faceScaleX  = g_faceRX * (double)imgWidth  * 0.5;
        double faceScaleY  = g_faceRY * (double)imgHeight * 0.5;
        rx_computed = fmax(baseForRX, scaleFactor * faceScaleX);
        ry_computed = fmax(baseForRY, scaleFactor * faceScaleY);
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

// ── Vision face detection ─────────────────────────────────────────────────────
// Persistent Y-plane buffer: allocated once, grown only when camera resolution
// increases, never freed between calls. Eliminates per-call malloc/free and
// prevents heap fragmentation that caused progressive lag under sustained use.
//
// Safety: s_visionBusy stays 1 from CAS→dispatch until __sync_lock_release
// inside the block. Nothing can realloc/overwrite s_visionCopyBuf while the
// block is in flight, so the captured pointer is always valid during Vision.
static void   *s_visionCopyBuf  = NULL;
static size_t  s_visionCopySize = 0;
static volatile int s_visionBusy = 0;

void BINFlashScheduleVisionDetection(const void *pixels,
                                      size_t width, size_t height,
                                      size_t bytesPerRow,
                                      int fmt) {
    if (!pixels || width == 0 || height == 0) return;

    // Skip if previous detection still running — prevents queue accumulation.
    if (!__sync_bool_compare_and_swap(&s_visionBusy, 0, 1)) return;

    size_t need = bytesPerRow * height;

    // Grow the persistent buffer only when needed — never shrink, never free.
    if (need > s_visionCopySize) {
        void *nb = realloc(s_visionCopyBuf, need);
        if (!nb) { __sync_lock_release(&s_visionBusy); return; }
        s_visionCopyBuf  = nb;
        s_visionCopySize = need;
    }

    memcpy(s_visionCopyBuf, pixels, need);

    // Log on camera thread (always works) so we can confirm this function is reached.
    vcamSendDiag([NSString stringWithFormat:@"vis:sched %zux%zu fmt=%d", width, height, fmt]);

    void *bufPtr = s_visionCopyBuf;
    size_t w = width, h = height, stride = bytesPerRow;
    int pixFmt = fmt;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            // Build CGImage from the CPU copy — supports both gray (fmt=0) and BGRA (fmt=1).
            CGColorSpaceRef cs;
            CGBitmapInfo   bi;
            size_t bpc, bpp;
            if (pixFmt == 1) {
                // BGRA: 4 bytes/pixel, DeviceRGB, little-endian 32-bit, skip alpha
                cs  = CGColorSpaceCreateDeviceRGB();
                bi  = (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
                bpc = 8; bpp = 32;
            } else {
                // Grayscale Y-plane: 1 byte/pixel
                cs  = CGColorSpaceCreateDeviceGray();
                bi  = (CGBitmapInfo)(kCGBitmapByteOrderDefault | kCGImageAlphaNone);
                bpc = 8; bpp = 8;
            }
            CGDataProviderRef dp = CGDataProviderCreateWithData(
                NULL, bufPtr, stride * h, NULL);
            CGImageRef cgImg = CGImageCreate(
                w, h, bpc, bpp, stride, cs, bi, dp, NULL, true, kCGRenderingIntentDefault);
            CGColorSpaceRelease(cs);
            CGDataProviderRelease(dp);

            if (!cgImg) {
                vcamSendDiag(@"vis:no-cgimg");
                __sync_lock_release(&s_visionBusy);
                return;
            }

            VNDetectFaceRectanglesRequest *req =
                [[VNDetectFaceRectanglesRequest alloc] init];
            VNImageRequestHandler *hdlr =
                [[VNImageRequestHandler alloc]
                    initWithCGImage:cgImg
                         orientation:kCGImagePropertyOrientationUp
                             options:@{}];
            [hdlr performRequests:@[req] error:nil];
            CGImageRelease(cgImg);

            NSArray *results = req.results;
            // Throttle: log first detection immediately, then every ~10 calls (~30s).
            static int s_diagCount = 0;
            BOOL shouldLog = (++s_diagCount >= 10);
            if (shouldLog) s_diagCount = 0;

            if (results.count > 0) {
                VNFaceObservation *face = results[0];
                CGRect bb = face.boundingBox;
                // Vision: (0,0) = bottom-left; flip Y for top-left pixel coords.
                double cx = bb.origin.x + bb.size.width  * 0.5;
                double cy = 1.0 - (bb.origin.y + bb.size.height * 0.5);
                double rx = bb.size.width  * 0.9;
                double ry = bb.size.height * 0.9;
                g_faceCX           = clamp(cx, 0.15, 0.85);
                g_faceCY           = clamp(cy, 0.12, 0.88);
                g_faceRX           = clamp(rx, 0.20, 0.85);
                g_faceRY           = clamp(ry, 0.25, 0.95);
                g_faceTimestamp    = CFAbsoluteTimeGetCurrent();
                BOOL firstDetect   = !g_faceEverDetected;
                g_faceEverDetected = YES;
                if (firstDetect || shouldLog) {
                    vcamSendDiag([NSString stringWithFormat:
                        @"vis:ok %zux%zu cx=%.2f cy=%.2f rx=%.2f ry=%.2f",
                        w, h, g_faceCX, g_faceCY, g_faceRX, g_faceRY]);
                }
            } else {
                if (shouldLog) {
                    vcamSendDiag([NSString stringWithFormat:
                        @"vis:miss %zux%zu evr=%d", w, h, (int)g_faceEverDetected]);
                }
            }
            [req release];
            [hdlr release];
        }
        // Release busy flag after autorelease pool drains.
        __sync_lock_release(&s_visionBusy);
    });
}

