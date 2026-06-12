// BINFlashPixelEffect.m

#import "BINFlashPixelEffect.h"
#import "BINFlashPrefs.h"
#import "BINFlashFaceRegion.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <math.h>
#import <stdlib.h>

#define clamp(x, lo, hi) fmax((lo), fmin((hi), (x)))

// Epoch base — prevents int32 overflow in phase math.
static double          s_epochBase = 0;
static dispatch_once_t s_epochOnce = 0;

// ── sub_5C0C ──────────────────────────────────────────────────────────────
double BINFlashCurrentBrightness(NSDictionary *prefs) {
    // "live" check omitted: in the merged vcamera.dylib, BINFlashApplyToPixelBuffer
    // is called only from VCamLiveManager::modifyImageBuffer: after
    // VTPixelTransferSessionTransferImage — the call site already guarantees live state.
    // Nothing in this process ever sets live=true in BINFlash prefs, so checking it
    // would permanently gate flash off.
    if (!BINFlashBoolForKey(prefs, kBINFlashKeyFlash, kBINFlashDefaultFlash))
        return NAN;

    double speed      = BINFlashDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    double brightness = BINFlashDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    double region     = BINFlashDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);

    double b = clamp(brightness / 100.0, 0.0, 1.0);
    double r = clamp(region     / 100.0, 0.1, 1.0);

    // Static flash: no strobing — constant brightness
    if (BINFlashBoolForKey(prefs, kBINFlashKeyStaticFlash, kBINFlashDefaultStaticFlash))
        return clamp(b * (r * 0.25 + 0.90), 0.0, 1.0);

    dispatch_once(&s_epochOnce, ^{
        s_epochBase = CFAbsoluteTimeGetCurrent();
    });
    double elapsed = CFAbsoluteTimeGetCurrent() - s_epochBase;
    double phase   = fmod(fmax(speed, 0.5) * elapsed, 1.0);

    double offThreshold = (speed > 15.0) ? fmax(0.0, 0.5 - (speed - 15.0) / 30.0) : 0.5;
    if (offThreshold > 0.0 && phase >= offThreshold) return 0.0;

    return clamp(b * (r * 0.25 + 0.90), 0.0, 1.0);
}

// Pure saturated hue → RGB [0,1].
static void HueToRGB(double hue, double *r, double *g, double *b) {
    double h = hue * 6.0;
    int    i = (int)h;
    double f = h - i;
    double q = 1.0 - f;
    switch (i % 6) {
        case 0: *r=1.0; *g=f;   *b=0.0; break;
        case 1: *r=q;   *g=1.0; *b=0.0; break;
        case 2: *r=0.0; *g=1.0; *b=f;   break;
        case 3: *r=0.0; *g=q;   *b=1.0; break;
        case 4: *r=f;   *g=0.0; *b=1.0; break;
        default:*r=1.0; *g=0.0; *b=q;   break;
    }
}

// ── sub_4628 ──────────────────────────────────────────────────────────────
void BINFlashApplyToPixelBuffer(CVPixelBufferRef pixbuf) {
    if (!pixbuf) return;

    NSDictionary *prefs = BINFlashLoadPrefs();

    double brightness = BINFlashCurrentBrightness(prefs);
    // Bail out immediately — zero pixel work when flash is off.
    if (isnan(brightness) || brightness <= 0.0) return;

    size_t width       = CVPixelBufferGetWidth(pixbuf);
    size_t height      = CVPixelBufferGetHeight(pixbuf);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixbuf);

    // Face position from GPUImageThinFaceFilter landmarks (updated by BINFlashCamera swizzle).
    // Sticky: last known position held when GPUImage temporarily loses tracking.
    double cx, cy, rx, ry;
    BINFlashComputeFaceRegion(prefs, width, height, &cx, &cy, &rx, &ry);

    double hue = BINFlashDoubleForKey(prefs, kBINFlashKeyHue, kBINFlashDefaultHue);
    double hR, hG, hB;
    HueToRGB(hue, &hR, &hG, &hB);

    if (CVPixelBufferLockBaseAddress(pixbuf, 0) != kCVReturnSuccess) return;

    if ((pixelFormat & 0xFFFFFFEFU) == 0x34323066U) {
        // ── YUV 420 biplanar (420v / 420f) ────────────────────────────
        uint8_t *yPlane  = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
        uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
        size_t   yStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
        size_t  uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);

        // Face detection: copy Y-plane and dispatch Vision async every 9 frames.
        // Lock is still held here — memcpy is synchronous (~0.5ms for 720p).
        // Busy flag inside BINFlashScheduleVisionDetection prevents accumulation.
        static int s_visionThrottle = 0;
        if (++s_visionThrottle >= 9) {
            s_visionThrottle = 0;
            BINFlashScheduleVisionDetection(yPlane, width, height, yStride);
        }

        double brightFactor = clamp(brightness * 0.72, 0.0, 0.82);

        size_t yMinX = (size_t)fmax(0.0, cx - rx - 1.0);
        size_t yMaxX = (size_t)fmin((double)(width  - 1), cx + rx + 1.0);
        size_t yMinY = (size_t)fmax(0.0, cy - ry - 1.0);
        size_t yMaxY = (size_t)fmin((double)(height - 1), cy + ry + 1.0);

        for (size_t py = yMinY; py <= yMaxY; py++) {
            for (size_t px = yMinX; px <= yMaxX; px++) {
                double dx = ((double)px + 0.5 - cx) / rx;
                double dy = ((double)py + 0.5 - cy) / ry;
                double d2 = dx*dx + dy*dy;
                if (d2 > 1.18) continue;

                double t_fade = clamp((d2 - 0.30) / 0.88, 0.0, 1.0);
                double inv    = 1.0 - t_fade;
                double weight = inv * inv * (3.0 - 2.0 * inv);
                // 3D depth: centre full brightness, edges ~55%
                double depth  = clamp(1.0 - d2 * 0.45, 0.20, 1.0);
                double alpha  = brightFactor * weight * depth;

                uint8_t *yp = yPlane + py * yStride + px;
                *yp = (uint8_t)clamp(alpha * (255.0 - *yp) + *yp, 0.0, 255.0);
            }
        }

        double targetCb     = (-0.168736*hR - 0.331264*hG + 0.5*hB)      * 255.0 + 128.0;
        double targetCr     = ( 0.5*hR      - 0.418688*hG - 0.081312*hB) * 255.0 + 128.0;
        double chromaFactor = clamp(brightness * 1.02, 0.0, 0.98);

        size_t uvH = height / 2, uvW = width / 2;
        size_t uvMinX = yMinX / 2;
        size_t uvMaxX = (size_t)fmin((double)(uvW - 1), (double)(yMaxX / 2));
        size_t uvMinY = yMinY / 2;
        size_t uvMaxY = (size_t)fmin((double)(uvH - 1), (double)(yMaxY / 2));

        for (size_t vy = uvMinY; vy <= uvMaxY; vy++) {
            for (size_t vx = uvMinX; vx <= uvMaxX; vx++) {
                double dx = ((double)vx * 2.0 + 1.0 - cx) / rx;
                double dy = ((double)vy * 2.0 + 1.0 - cy) / ry;
                double d2 = dx*dx + dy*dy;
                if (d2 > 1.18) continue;

                double t_fade = clamp((d2 - 0.30) / 0.88, 0.0, 1.0);
                double inv    = 1.0 - t_fade;
                double weight = inv * inv * (3.0 - 2.0 * inv);
                double depth  = clamp(1.0 - d2 * 0.45, 0.20, 1.0);
                double alpha  = chromaFactor * weight * depth;

                uint8_t *uvp = uvPlane + vy * uvStride + vx * 2;
                uvp[0] = (uint8_t)clamp(alpha * (targetCb - uvp[0]) + uvp[0], 0.0, 255.0);
                uvp[1] = (uint8_t)clamp(alpha * (targetCr - uvp[1]) + uvp[1], 0.0, 255.0);
            }
        }
    } else {
        // ── BGRA / ARGB / RGBA ──────────────────────────────────────────
        int rOff, gOff, bOff;
        switch (pixelFormat) {
            case 32:           rOff=1; gOff=2; bOff=3; break;
            case 0x42475241:   rOff=2; gOff=1; bOff=0; break;
            case 0x52474241:   rOff=0; gOff=1; bOff=2; break;
            default:           rOff=3; gOff=2; bOff=1; break;
        }
        uint8_t *base   = (uint8_t *)CVPixelBufferGetBaseAddress(pixbuf);
        size_t   stride = CVPixelBufferGetBytesPerRow(pixbuf);

        double brightFactor = clamp(brightness * 0.70, 0.0, 0.78);
        double chromaFactor = clamp(brightness * 0.90, 0.0, 0.96);
        double hR255 = hR * 255.0, hG255 = hG * 255.0, hB255 = hB * 255.0;

        size_t bMinX = (size_t)fmax(0.0, cx - rx - 1.0);
        size_t bMaxX = (size_t)fmin((double)(width  - 1), cx + rx + 1.0);
        size_t bMinY = (size_t)fmax(0.0, cy - ry - 1.0);
        size_t bMaxY = (size_t)fmin((double)(height - 1), cy + ry + 1.0);

        for (size_t py = bMinY; py <= bMaxY; py++) {
            for (size_t px = bMinX; px <= bMaxX; px++) {
                double dx = ((double)px + 0.5 - cx) / rx;
                double dy = ((double)py + 0.5 - cy) / ry;
                double d2 = dx*dx + dy*dy;
                if (d2 > 1.18) continue;

                double t_fade = clamp((d2 - 0.30) / 0.88, 0.0, 1.0);
                double inv    = 1.0 - t_fade;
                double weight = inv * inv * (3.0 - 2.0 * inv);
                double depth  = clamp(1.0 - d2 * 0.45, 0.20, 1.0);

                uint8_t *pixel = base + py * stride + px * 4;
                double r = pixel[rOff], g = pixel[gOff], b = pixel[bOff];

                double ba = brightFactor * weight * depth;
                r = ba * (255.0 - r) + r;
                g = ba * (255.0 - g) + g;
                b = ba * (255.0 - b) + b;

                double ca = chromaFactor * weight * depth;
                r = hR255 * ca + (1.0 - ca) * r;
                g = hG255 * ca + (1.0 - ca) * g;
                b = hB255 * ca + (1.0 - ca) * b;

                pixel[rOff] = (uint8_t)clamp(r, 0.0, 255.0);
                pixel[gOff] = (uint8_t)clamp(g, 0.0, 255.0);
                pixel[bOff] = (uint8_t)clamp(b, 0.0, 255.0);
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(pixbuf, 0);
}
