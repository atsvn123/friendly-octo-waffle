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

// ── Vision-based face detection ────────────────────────────────────────────
// Serial queue — one detection at a time, no pipeline stall.
static dispatch_queue_t  s_visionQueue;
static dispatch_once_t   s_visionQueueOnce;

// Path for cross-process debug: mediaserverd writes, SpringBoard reads.
#define kFaceDebugFile "/tmp/vcam_face_dbg"

// Sticky orientation: remember the last one that found a face so we skip failed attempts.
static CGImagePropertyOrientation s_workingOrientation = kCGImagePropertyOrientationRight;

void BINFlashScheduleVisionDetection(uint8_t *ownedYBytes,  size_t yBPR,
                                     uint8_t *ownedUVBytes, size_t uvBPR,
                                     size_t width, size_t height)
{
    if (!ownedYBytes || !ownedUVBytes) {
        free(ownedYBytes);
        free(ownedUVBytes);
        return;
    }

    dispatch_once(&s_visionQueueOnce, ^{
        s_visionQueue = dispatch_queue_create("com.vcam.flash.facedetect",
                                              DISPATCH_QUEUE_SERIAL);
    });

    size_t bW = width, bH = height, bYBPR = yBPR, bUVBPR = uvBPR;

    dispatch_async(s_visionQueue, ^{
        // Compute mean Y luma to confirm the buffer has actual image content.
        uint32_t lumaSum = 0;
        size_t lumaCount = 0;
        for (size_t row = 0; row < bH; row += 16) {
            for (size_t col = 0; col < bW; col += 16) {
                lumaSum += ownedYBytes[row * bYBPR + col];
                lumaCount++;
            }
        }
        uint8_t meanY = lumaCount ? (uint8_t)(lumaSum / lumaCount) : 0;

        // Build a non-IOSurface YUV biplanar CVPixelBuffer from our CPU copies.
        void  *planeAddrs[2] = { ownedYBytes, ownedUVBytes };
        size_t planeWidths[2]  = { bW,    bW / 2 };
        size_t planeHeights[2] = { bH,    bH / 2 };
        size_t planeBPR[2]     = { bYBPR, bUVBPR };

        CVPixelBufferRef cpuBuf = NULL;
        CVReturn ret = CVPixelBufferCreateWithPlanarBytes(
            kCFAllocatorDefault,
            bW, bH,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            NULL, 0, 2,
            planeAddrs, planeWidths, planeHeights, planeBPR,
            NULL, NULL, NULL,
            &cpuBuf);

        FILE *dbgF = fopen(kFaceDebugFile, "w");

        if (ret != kCVReturnSuccess || !cpuBuf) {
            if (dbgF) { fprintf(dbgF, "ERR buf=%d w=%zu h=%zu meanY=%u\n", ret, bW, bH, meanY); fclose(dbgF); }
            free(ownedYBytes); free(ownedUVBytes);
            return;
        }

        // Try orientations starting from last known working one.
        // iPhone portrait = kCGImagePropertyOrientationRight (face rotated 90° CW in landscape buf).
        CGImagePropertyOrientation allOrientations[4] = {
            kCGImagePropertyOrientationRight,   // portrait, most common
            kCGImagePropertyOrientationUp,      // landscape
            kCGImagePropertyOrientationLeft,    // portrait upside-down
            kCGImagePropertyOrientationDown,    // landscape flipped
        };
        // Rotate the array so s_workingOrientation is first
        CGImagePropertyOrientation toTry[4];
        int startIdx = 0;
        for (int i = 0; i < 4; i++) { if (allOrientations[i] == s_workingOrientation) { startIdx = i; break; } }
        for (int i = 0; i < 4; i++) toTry[i] = allOrientations[(startIdx + i) % 4];

        CGRect foundBox     = CGRectZero;
        CGImagePropertyOrientation foundOrientation = s_workingOrientation;
        NSUInteger foundCount = 0;

        for (int attempt = 0; attempt < 4; attempt++) {
            VNDetectFaceRectanglesRequest *req = [[VNDetectFaceRectanglesRequest alloc] init];
            if ([req respondsToSelector:@selector(setRevision:)])
                req.revision = VNDetectFaceRectanglesRequestRevision1;

            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc]
                    initWithCVPixelBuffer:cpuBuf
                              orientation:toTry[attempt]
                                  options:@{}];
            NSError *err = nil;
            [handler performRequests:@[req] error:&err];

            if (!err && req.results.count > 0) {
                // Find largest face
                float bestArea = 0;
                for (VNFaceObservation *obs in req.results) {
                    float area = (float)(obs.boundingBox.size.width * obs.boundingBox.size.height);
                    if (area > bestArea) {
                        bestArea  = area;
                        foundBox  = obs.boundingBox;
                        foundOrientation = toTry[attempt];
                        foundCount = req.results.count;
                    }
                }
                [req release];
                [handler release];
                break; // stop at first orientation that finds a face
            }
            [req release];
            [handler release];
        }

        if (!CGRectIsEmpty(foundBox)) {
            s_workingOrientation = foundOrientation;

            // Vision: (0,0) = bottom-left → flip Y to top-left convention.
            // vx/vy are face center in DISPLAY (portrait) normalized coordinates.
            double vx = CGRectGetMidX(foundBox);
            double vy = 1.0 - CGRectGetMidY(foundBox);
            double rw = foundBox.size.width  * 0.5 * 1.20;  // half-width  in display-x
            double rh = foundBox.size.height * 0.5 * 1.40;  // half-height in display-y

            // Transform display-space coords → raw landscape buffer coords.
            // The camera pipeline buffer is landscape (1280×720). The display hardware
            // rotates it to portrait according to foundOrientation.
            // For kCGImagePropertyOrientationRight (6), 90° CW rotation:
            //   display(px,py) = buffer(1-ly, lx)  →  inverse: lx=py, ly=1-px
            // Portrait-y maps to buffer-x; portrait-x maps to buffer-y (inverted).
            double bx, by, brx, bry;
            switch (foundOrientation) {
                case kCGImagePropertyOrientationRight:  // 6: portrait, 90° CW
                    bx  = vy;
                    by  = 1.0 - vx;
                    brx = rh;   // portrait vertical → buffer horizontal
                    bry = rw;   // portrait horizontal → buffer vertical
                    break;
                case kCGImagePropertyOrientationLeft:   // 8: portrait upside-down, 90° CCW
                    bx  = 1.0 - vy;
                    by  = vx;
                    brx = rh;
                    bry = rw;
                    break;
                case kCGImagePropertyOrientationDown:   // 3: landscape 180°
                    bx  = 1.0 - vx;
                    by  = 1.0 - vy;
                    brx = rw;
                    bry = rh;
                    break;
                default:                                // 1 (Up): no rotation
                    bx  = vx;
                    by  = vy;
                    brx = rw;
                    bry = rh;
                    break;
            }

            g_faceCX           = clamp(bx,  0.10, 0.90);
            g_faceCY           = clamp(by,  0.10, 0.90);
            g_faceRX           = clamp(brx, 0.12, 0.85);
            g_faceRY           = clamp(bry, 0.15, 0.90);
            g_faceTimestamp    = CFAbsoluteTimeGetCurrent();
            g_faceEverDetected = YES;

            if (dbgF) {
                fprintf(dbgF, "YES bx=%.3f by=%.3f brx=%.3f bry=%.3f vx=%.3f vy=%.3f n=%lu ori=%d meanY=%u\n",
                        g_faceCX, g_faceCY, g_faceRX, g_faceRY,
                        vx, vy,
                        (unsigned long)foundCount, (int)foundOrientation, meanY);
                fclose(dbgF);
            }
        } else {
            if (dbgF) {
                fprintf(dbgF, "NO FACE w=%zu h=%zu meanY=%u (tried all 4 orientations)\n",
                        bW, bH, meanY);
                fclose(dbgF);
            }
        }

        CVPixelBufferRelease(cpuBuf);
        free(ownedYBytes);
        free(ownedUVBytes);
    });
}
