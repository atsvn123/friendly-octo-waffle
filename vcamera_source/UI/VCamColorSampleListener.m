// VCamColorSampleListener.m

#import "VCamColorSampleListener.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <notify.h>
#include <string.h>
#include <math.h>

// Number of hue bins used when finding the dominant colour among the 4 pixels.
// 12 bins = 30° each (red, orange, yellow, yellow-green, green, cyan-green,
// cyan, azure, blue, violet, magenta, rose).
#define HUE_BINS 12

void vcamInstallColorSampleListener(void) {
    static int s_respToken = NOTIFY_TOKEN_INVALID;
    notify_register_check("com.vcam.sampleresponse", &s_respToken);

    static int s_reqToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(
        "com.vcam.samplerequest",
        &s_reqToken,
        dispatch_get_main_queue(),
        ^(int token) {
            // Only the foreground app should respond. Every UIKit app receives this
            // notification (com.apple.UIKit filter injects us everywhere). If a
            // background app responds last it overwrites the correct foreground hue
            // with a black-window sample, making the picker appear broken.
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive)
                return;

            uint64_t packed = 0;
            notify_get_state(token, &packed);

            // VCamColorPickerWindow sends normalized [0,1] coords.
            uint32_t xBits = (uint32_t)(packed >> 32);
            uint32_t yBits = (uint32_t)(packed & 0xFFFFFFFFULL);
            float nx = 0.0f, ny = 0.0f;
            memcpy(&nx, &xBits, 4);
            memcpy(&ny, &yBits, 4);

            CGSize sz = [UIScreen mainScreen].bounds.size;
            if (nx < 0.0f || ny < 0.0f || nx > 1.0f || ny > 1.0f) return;
            if (sz.width <= 0 || sz.height <= 0) return;

            // Convert normalized → screen points
            float xf = nx * (float)sz.width;
            float yf = ny * (float)sz.height;

            UIWindow *targetWindow = nil;
            NSArray *windows = [[UIApplication sharedApplication] windows];
            for (UIWindow *w in windows) {
                if (!w.isHidden && w.alpha > 0.0 && w.windowLevel == UIWindowLevelNormal) {
                    targetWindow = w;
                    break;
                }
            }
            if (!targetWindow) targetWindow = [[UIApplication sharedApplication] keyWindow];
            if (!targetWindow) return;

            // Sample an 8×8 point region centred on the circle.
            // The dominant colour (most-represented hue bin) is returned,
            // so a single outlier pixel does not skew the result.
            // drawViewHierarchyInRect:afterScreenUpdates:YES goes through the
            // display compositor and captures AVCaptureVideoPreviewLayer content
            // that renderInContext: cannot see (GPU-rendered, always black there).
            // It ignores the CTM, so pass the offset rect directly.
            const int DIM = 8;

            UIGraphicsBeginImageContextWithOptions(CGSizeMake(DIM, DIM), YES, 1.0);
            // Place the window so (xf, yf) maps to the centre of the DIM×DIM canvas.
            CGRect viewRect = CGRectMake(-(CGFloat)xf + DIM * 0.5f,
                                         -(CGFloat)yf + DIM * 0.5f,
                                         (CGFloat)sz.width, (CGFloat)sz.height);
            // afterScreenUpdates:NO — faster (no compositor wait) and excludes
            // AVCaptureVideoPreviewLayer/AVSampleBufferDisplayLayer (GPU-rendered camera
            // content). We want the app's background color, not the camera feed.
            [targetWindow drawViewHierarchyInRect:viewRect afterScreenUpdates:NO];

            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (!img || !img.CGImage) return;

            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img.CGImage));
            if (!data) return;

            const uint8_t *bytes = CFDataGetBytePtr(data);
            size_t          bpr  = CGImageGetBytesPerRow(img.CGImage);

            // Per-bin accumulators for circular mean (sin/cos) and pixel count.
            double binSin[HUE_BINS] = {0};
            double binCos[HUE_BINS] = {0};
            int    binCnt[HUE_BINS] = {0};

            for (int row = 0; row < DIM; row++) {
                for (int col = 0; col < DIM; col++) {
                    const uint8_t *p = bytes + row * bpr + col * 4;
                    // UIGraphicsBeginImageContextWithOptions ARM: BGRA byte order.
                    CGFloat r = p[2] / 255.0;
                    CGFloat g = p[1] / 255.0;
                    CGFloat b = p[0] / 255.0;

                    UIColor *c = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
                    CGFloat h = 0, s = 0, v = 0, a = 0;
                    if (![c getHue:&h saturation:&s brightness:&v alpha:&a]) continue;
                    if (s < 0.08 || v < 0.05 || v > 0.97) continue;

                    int bin = (int)(h * HUE_BINS) % HUE_BINS;
                    double angle = h * 2.0 * M_PI;
                    binSin[bin] += sin(angle);
                    binCos[bin] += cos(angle);
                    binCnt[bin]++;
                }
            }

            CFRelease(data);

            // Find the bin that contains the most pixels (dominant colour).
            int bestBin = -1, bestCount = 0;
            for (int i = 0; i < HUE_BINS; i++) {
                if (binCnt[i] > bestCount) { bestCount = binCnt[i]; bestBin = i; }
            }
            if (bestBin < 0) {
                // All pixels achromatic — tell SpringBoard to hide the ring.
                notify_set_state(s_respToken, 0xFFFFFFFFFFFFFFFFULL);
                notify_post("com.vcam.sampleresponse");
                return;
            }

            // Circular mean within the dominant bin.
            double meanAngle = atan2(binSin[bestBin] / bestCount,
                                     binCos[bestBin] / bestCount);
            if (meanAngle < 0.0) meanAngle += 2.0 * M_PI;
            double h = meanAngle / (2.0 * M_PI);
            if (h < 0.0 || h > 1.0) return;

            float hf = (float)h;
            uint32_t hueBits = 0;
            memcpy(&hueBits, &hf, 4);

            notify_set_state(s_respToken, (uint64_t)hueBits);
            notify_post("com.vcam.sampleresponse");
        }
    );
}
