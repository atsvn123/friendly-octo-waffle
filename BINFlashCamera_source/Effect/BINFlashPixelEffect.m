// BINFlashPixelEffect.m
// Reconstructed from:
//   sub_4628 (0x4628) — core pixel effect engine (3328 bytes)
//   sub_5C0C (0x5C0C) — flash brightness value
//
// HOW sub_4628 WORKS:
//   1. Guard: must be a CVPixelBuffer, prefs must show flash on, brightness > threshold
//   2. Frame dedup: uses CVBufferAttachment epoch tag to skip already-processed frames
//   3. Lock base address
//   4. Format dispatch: YUV biplanar → separate Y/UV planes; BGRA/ARGB → packed channels
//   5. Per-pixel: compute distance from face ellipse → smoothstep blend weight → apply
//   6. YUV path: Y=brighten (×0.72), UV=hue tint (×1.02)
//   7. BGRA/ARGB path: brighten (×0.70) + hue tint (×0.90) combined in one pass
//   8. Unlock

#import "BINFlashPixelEffect.h"
#import "../Prefs/BINFlashCameraPrefs.h"
#import "../FaceRegion/BINFlashFaceRegion.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>

#define clamp(x, lo, hi) fmax((lo), fmin((hi), (x)))

// CVBuffer attachment key for frame dedup (same string as BINFlashAddon)
static CFStringRef kFrameEpochKey = CFSTR("com.meo.flashaddon.frame-epoch");

// ── sub_5C0C ──
double BINFlashCurrentBrightness(NSDictionary *prefs) {
    // IDA: "live" is checked FIRST (default 0/NO), then "flash" (default 0/NO).
    // Both must be YES for flash to fire.
    if (!BINFlashCameraBoolForKey(prefs, kBINFlashKeyLive, NO))
        return NAN;
    if (!BINFlashCameraBoolForKey(prefs, kBINFlashKeyFlash, NO))
        return NAN;

    double speed      = BINFlashCameraDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    double brightness = BINFlashCameraDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    double region     = BINFlashCameraDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);

    // 50% duty-cycle square wave at `speed` Hz using CFAbsoluteTimeGetCurrent.
    // fmod works correctly with large doubles (t ≈ 800M fits in 53-bit mantissa).
    double t = CFAbsoluteTimeGetCurrent();
    double phase = fmod(fmax(speed, 0.5) * t, 1.0);
    if (phase >= 0.5) return 0.0;  // "off" half

    double b = clamp(brightness / 100.0, 0.0, 1.0);
    double r = clamp(region     / 100.0, 0.1, 1.0);

    // BINFlashCamera formula: r×0.25 + 0.90
    // (BINFlashAddon uses r×0.45 + 0.70 — different scale, same concept)
    return clamp(b * (r * 0.25 + 0.90), 0.0, 1.0);
}

// ── Hue → RGB conversion helper ──
// Given hue in [0,1], saturation=1, value=0.82 → R,G,B in [0.18, 1.0]
static void HueToRGB(double hue, double *r, double *g, double *b) {
    double h = hue * 6.0;
    int   i  = (int)h;
    double f = h - i;
    double q = 1.0 - f;
    double p = 0.0; // saturation = 1, so p = 0

    double rv, gv, bv;
    switch (i % 6) {
        case 0: rv=1.0; gv=f;   bv=p;   break;
        case 1: rv=q;   gv=1.0; bv=p;   break;
        case 2: rv=p;   gv=1.0; bv=f;   break;
        case 3: rv=p;   gv=q;   bv=1.0; break;
        case 4: rv=f;   gv=p;   bv=1.0; break;
        default:rv=1.0; gv=p;   bv=q;   break;
    }
    double val = 0.82;
    // Scale to [0.18, 1.0] range: c = c*val + (1-val) as minimum brightness
    *r = rv * val + 0.18;
    *g = gv * val + 0.18;
    *b = bv * val + 0.18;
}

// ── sub_4628 ──
void BINFlashApplyToPixelBuffer(CVPixelBufferRef pixbuf) {
    if (!pixbuf) return;

    // Must be a CVPixelBuffer (not other CoreFoundation type)
    if (CFGetTypeID(pixbuf) != CVPixelBufferGetTypeID()) return;

    // Load prefs (100ms cache)
    NSDictionary *prefs = BINFlashCameraLoadPrefs();

    // Compute flash brightness; skip if off
    double brightness = BINFlashCurrentBrightness(prefs);
    if (isnan(brightness) || brightness <= 0.001) return;

    double speed = BINFlashCameraDoubleForKey(prefs, kBINFlashKeySpeed, kBINFlashDefaultSpeed);
    double t     = CFAbsoluteTimeGetCurrent();

    // IDA: LODWORD(v140) = vcvtmd_s64_f64(v7 * Current + v7 * Current)
    // Binary uses int64 truncation (fcvtzs x0, d0) then takes low 32 bits.
    // Direct (int) cast uses fcvtzs w0, d0 which SATURATES to INT_MAX for
    // speed > ~1.34 Hz at t ≈ 800M. Once any buffer gets epoch=INT_MAX it is
    // permanently deduped → flash fires at startup only, then stops forever.
    int epoch = (int)((int64_t)((speed + speed) * t));

    // Check existing epoch attachment
    CFNumberRef existing = (CFNumberRef)CVBufferGetAttachment(pixbuf, kFrameEpochKey, NULL);
    if (existing) {
        int existingEpoch = 0;
        CFNumberGetValue(existing, kCFNumberIntType, &existingEpoch);
        if (existingEpoch == epoch) return;  // already processed this tick
    }

    // Tag this frame with the current epoch
    CFNumberRef epochNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &epoch);
    CVBufferSetAttachment(pixbuf, kFrameEpochKey, epochNum,
                          kCVAttachmentMode_ShouldNotPropagate);
    CFRelease(epochNum);

    if (CVPixelBufferLockBaseAddress(pixbuf, 0) != kCVReturnSuccess) return;

    size_t width       = CVPixelBufferGetWidth(pixbuf);
    size_t height      = CVPixelBufferGetHeight(pixbuf);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixbuf);

    double hue = BINFlashCameraDoubleForKey(prefs, kBINFlashKeyHue, kBINFlashDefaultHue);
    double hR, hG, hB;
    HueToRGB(hue, &hR, &hG, &hB);

    // Get face ellipse in pixel coordinates
    double cx, cy, rx, ry;
    BINFlashComputeFaceRegion(prefs, width, height, &cx, &cy, &rx, &ry);

    // ── YUV BiPlanar path (420f = 0x34323066, 420v = 0x34323076) ──
    // Check: (format & 0xFFFFFFEF) == 0x34323066 — handles both 420f and 420v
    if ((pixelFormat & 0xFFFFFFEFU) == 0x34323066U) {
        uint8_t *yPlane  = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
        uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
        size_t   yStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
        size_t  uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);

        double brightFactor = clamp(brightness * 0.72, 0.0, 0.82);

        // Y-plane: brighten pixels within face ellipse
        size_t yBound_minX = (size_t)fmax(0.0, cx - rx - 1.0);
        size_t yBound_maxX = (size_t)fmin((double)(width - 1),  cx + rx + 1.0);
        size_t yBound_minY = (size_t)fmax(0.0, cy - ry - 1.0);
        size_t yBound_maxY = (size_t)fmin((double)(height - 1), cy + ry + 1.0);

        for (size_t py = yBound_minY; py <= yBound_maxY; py++) {
            for (size_t px = yBound_minX; px <= yBound_maxX; px++) {
                double dx = ((double)px + 0.5 - cx) / rx;
                double dy = ((double)py + 0.5 - cy) / ry;
                double d2 = dx*dx + dy*dy;

                if (d2 > 1.18) continue;

                // Smoothstep falloff: strongest at center, fades toward edge
                double t_fade = clamp((d2 - 0.30) / 0.88, 0.0, 1.0);
                double inv    = 1.0 - t_fade;
                double weight = inv * inv * (3.0 - 2.0 * inv);
                double alpha  = brightFactor * weight;

                uint8_t *yp = yPlane + py * yStride + px;
                *yp = (uint8_t)clamp(alpha * (255.0 - *yp) + *yp, 0.0, 255.0);
            }
        }

        // UV-plane: tint toward hue-derived Cb/Cr
        // Convert hue RGB to YCbCr Cb/Cr components (BT.601)
        double targetCb = -0.168736*hR - 0.331264*hG + 0.5*hB   + 128.0;
        double targetCr =  0.5*hR      - 0.418688*hG - 0.081312*hB + 128.0;

        double chromaFactor = clamp(brightness * 1.02, 0.0, 0.98);

        size_t uvH = height / 2;
        size_t uvW = width  / 2;

        size_t uvBound_minX = yBound_minX / 2;
        size_t uvBound_maxX = fmin((double)(uvW - 1), (double)(yBound_maxX / 2));
        size_t uvBound_minY = yBound_minY / 2;
        size_t uvBound_maxY = fmin((double)(uvH - 1), (double)(yBound_maxY / 2));

        for (size_t vy = uvBound_minY; vy <= uvBound_maxY; vy++) {
            for (size_t vx = uvBound_minX; vx <= uvBound_maxX; vx++) {
                // Each UV pixel covers 4 Y pixels; use center of 2×2 block for distance
                double dx = ((double)vx * 2.0 + 1.0 - cx) / rx;
                double dy = ((double)vy * 2.0 + 1.0 - cy) / ry;
                double d2 = dx*dx + dy*dy;

                if (d2 > 1.18) continue;

                double t_fade = clamp((d2 - 0.30) / 0.88, 0.0, 1.0);
                double inv    = 1.0 - t_fade;
                double weight = inv * inv * (3.0 - 2.0 * inv);
                double alpha  = chromaFactor * weight;

                uint8_t *uvp = uvPlane + vy * uvStride + vx * 2;
                // Interleaved Cb,Cr
                uvp[0] = (uint8_t)clamp(alpha * (targetCb - uvp[0]) + uvp[0], 0.0, 255.0);
                uvp[1] = (uint8_t)clamp(alpha * (targetCr - uvp[1]) + uvp[1], 0.0, 255.0);
            }
        }

    } else {
        // ── Packed BGRA / ARGB / RGBA / ABGR path ──
        //
        // Channel offsets vary by format. IDA showed these four cases:
        //   32         (ARGB): A=0, R=1, G=2, B=3
        //   0x42475241 (BGRA): B=0, G=1, R=2, A=3
        //   0x52474241 (RGBA): R=0, G=1, B=2, A=3
        //   0x41424752 (ABGR): A=0, B=1, G=2, R=3

        int rOff, gOff, bOff;
        switch (pixelFormat) {
            case 32:           rOff=1; gOff=2; bOff=3; break;  // ARGB
            case 0x42475241:   rOff=2; gOff=1; bOff=0; break;  // BGRA
            case 0x52474241:   rOff=0; gOff=1; bOff=2; break;  // RGBA
            default:           rOff=3; gOff=2; bOff=1; break;  // ABGR fallback
        }

        uint8_t *base   = (uint8_t *)CVPixelBufferGetBaseAddress(pixbuf);
        size_t   stride = CVPixelBufferGetBytesPerRow(pixbuf);

        double brightFactor = clamp(brightness * 0.70, 0.0, 0.78);
        double chromaFactor = clamp(brightness * 0.90, 0.0, 0.96);

        // Hue target in 0-255 range
        double hR255 = hR * 255.0;
        double hG255 = hG * 255.0;
        double hB255 = hB * 255.0;

        size_t bnd_minX = (size_t)fmax(0.0, cx - rx - 1.0);
        size_t bnd_maxX = (size_t)fmin((double)(width - 1),  cx + rx + 1.0);
        size_t bnd_minY = (size_t)fmax(0.0, cy - ry - 1.0);
        size_t bnd_maxY = (size_t)fmin((double)(height - 1), cy + ry + 1.0);

        for (size_t py = bnd_minY; py <= bnd_maxY; py++) {
            for (size_t px = bnd_minX; px <= bnd_maxX; px++) {
                double dx = ((double)px + 0.5 - cx) / rx;
                double dy = ((double)py + 0.5 - cy) / ry;
                double d2 = dx*dx + dy*dy;

                if (d2 > 1.18) continue;

                double t_fade = clamp((d2 - 0.30) / 0.88, 0.0, 1.0);
                double inv    = 1.0 - t_fade;
                double weight = inv * inv * (3.0 - 2.0 * inv);

                uint8_t *pixel = base + py * stride + px * 4;

                double r = pixel[rOff];
                double g = pixel[gOff];
                double b = pixel[bOff];

                // Step 1: brightness boost (blend toward 255)
                r = brightFactor * weight * (255.0 - r) + r;
                g = brightFactor * weight * (255.0 - g) + g;
                b = brightFactor * weight * (255.0 - b) + b;

                // Step 2: hue tinting (blend toward hue-derived color)
                double ca = chromaFactor * weight;
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
