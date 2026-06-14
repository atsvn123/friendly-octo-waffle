// VCamColorSampleListener.m

#import "VCamColorSampleListener.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <notify.h>
#include <string.h>
#include <math.h>

#define HUE_BINS 12

static UIWindow *vcamFindTargetWindow(void) {
    NSArray *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *w in windows) {
        if (!w.isHidden && w.alpha > 0.0 && w.windowLevel == UIWindowLevelNormal)
            return w;
    }
    return [[UIApplication sharedApplication] keyWindow];
}

// Captures the FULL app window and finds the dominant chromatic hue across the
// LEFT 25% and RIGHT 25% of screen columns (centre 50% excluded).
//
// Two-step approach avoids the CGContextScaleCTM issue:
// drawViewHierarchyInRect: ignores the current CTM on some iOS versions, so
// scaling the context before calling it just clips to the top-left corner
// instead of downscaling.  We instead render at full size (375x667 pt = ~971 KB)
// then downsample via [UIImage drawInRect:] which DOES respect the context size.
//
// Column filter (left 25% + right 25%):
//   * Excludes the centre where the face/camera-preview oval lives in KYC apps
//   * The background colour (green, white, etc.) always extends to both edges
//   * Navigation bar colours at the top are included but typically white ->
//     achromatic -> filtered by the s/v thresholds anyway
//
// afterScreenUpdates:NO -- avoids AVCaptureVideoPreviewLayer GPU content AND
// avoids capturing the springboard wallpaper that bleeds through during the
// home-screen transition animation.
//
// Returns hue in [0, 1] if a chromatic dominant colour exists, -1.0 otherwise.
static double vcamSampleFullScreenHue(UIWindow *targetWindow) {
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width <= 0 || sz.height <= 0) return -1.0;

    // Step 1: render window at full layout size (no CTM trickery).
    UIGraphicsBeginImageContextWithOptions(sz, YES, 1.0);
    [targetWindow drawViewHierarchyInRect:CGRectMake(0, 0, sz.width, sz.height)
                       afterScreenUpdates:NO];
    UIImage *fullImg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!fullImg) return -1.0;

    // Step 2: downscale to a small analysis canvas (~1/8 linear scale).
    const int SAMP_W = 48;
    const int SAMP_H = 86;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(SAMP_W, SAMP_H), YES, 1.0);
    [fullImg drawInRect:CGRectMake(0, 0, SAMP_W, SAMP_H)];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img || !img.CGImage) return -1.0;

    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img.CGImage));
    if (!data) return -1.0;

    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t bpr    = CGImageGetBytesPerRow(img.CGImage);
    size_t height = CGImageGetHeight(img.CGImage);
    size_t width  = CGImageGetWidth(img.CGImage);

    // Column thresholds for the left-25% and right-25% strips.
    size_t colLeftEnd  = (size_t)(width * 0.25);   // 0 .. colLeftEnd-1
    size_t colRightBeg = (size_t)(width * 0.75);   // colRightBeg .. width-1

    double binSin[HUE_BINS] = {0};
    double binCos[HUE_BINS] = {0};
    int    binCnt[HUE_BINS] = {0};

    for (size_t row = 0; row < height; row++) {
        for (size_t col = 0; col < width; col++) {
            // Only analyse left-25% and right-25% columns.
            if (col >= colLeftEnd && col < colRightBeg) continue;

            const uint8_t *p = bytes + row * bpr + col * 4;
            // UIGraphicsBeginImageContextWithOptions on ARM: BGRA byte order.
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

    int bestBin = -1, bestCount = 0;
    for (int i = 0; i < HUE_BINS; i++) {
        if (binCnt[i] > bestCount) { bestCount = binCnt[i]; bestBin = i; }
    }
    if (bestBin < 0) return -1.0;

    double meanAngle = atan2(binSin[bestBin] / bestCount,
                             binCos[bestBin] / bestCount);
    if (meanAngle < 0.0) meanAngle += 2.0 * M_PI;
    double hue = meanAngle / (2.0 * M_PI);
    if (hue < 0.0 || hue > 1.0) return -1.0;
    return hue;
}

void vcamInstallColorSampleListener(void) {
    static int s_respToken = NOTIFY_TOKEN_INVALID;
    notify_register_check("com.vcam.sampleresponse", &s_respToken);

    static int s_reqToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(
        "com.vcam.samplerequest",
        &s_reqToken,
        dispatch_get_main_queue(),
        ^(int __unused token) {
            // Only the foreground app should respond.
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive)
                return;

            UIWindow *targetWindow = vcamFindTargetWindow();
            if (!targetWindow) return;

            double h = vcamSampleFullScreenHue(targetWindow);
            if (h < 0.0) {
                // All pixels achromatic -- tell SpringBoard: clear ring, no flash.
                notify_set_state(s_respToken, 0xFFFFFFFFFFFFFFFFULL);
                notify_post("com.vcam.sampleresponse");
                return;
            }

            float hf = (float)h;
            uint32_t hueBits = 0;
            memcpy(&hueBits, &hf, 4);
            notify_set_state(s_respToken, (uint64_t)hueBits);
            notify_post("com.vcam.sampleresponse");
        }
    );
}

// -- Debug capture --
// Triggered by volume-down double-tap ("com.vcam.debugcapture" Darwin notify).
// Saves a full-screen snapshot to:
//   1. Device Photos library (visible in camera roll immediately)
//   2. /var/mobile/Documents/vcam_color_YYYYMMDD_HHmmss.png (SSH fallback)
void vcamInstallDebugCaptureListener(void) {
    static int s_token = NOTIFY_TOKEN_INVALID;
    if (s_token != NOTIFY_TOKEN_INVALID) return;

    notify_register_dispatch(
        "com.vcam.debugcapture",
        &s_token,
        dispatch_get_main_queue(),
        ^(int __unused tok) {
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive)
                return;

            CGSize sz = [UIScreen mainScreen].bounds.size;
            if (sz.width <= 0 || sz.height <= 0) return;

            UIWindow *targetWindow = vcamFindTargetWindow();
            if (!targetWindow) return;

            // Full-screen capture at device pixel scale (2x on iPhone 7).
            UIGraphicsBeginImageContextWithOptions(sz, YES, 0.0);
            [targetWindow drawViewHierarchyInRect:CGRectMake(0, 0, sz.width, sz.height)
                               afterScreenUpdates:NO];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (!img) return;

            // Primary: save to Photos library (camera roll).
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);

            // Fallback: also write PNG to Documents for SSH retrieval.
            NSData *png = UIImagePNGRepresentation(img);
            if (png) {
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                [fmt setDateFormat:@"yyyyMMdd_HHmmss"];
                NSString *ts = [fmt stringFromDate:[NSDate date]];
                [fmt release];
                NSString *dir  = @"/var/mobile/Documents";
                NSString *path = [NSString stringWithFormat:@"%@/vcam_color_%@.png", dir, ts];
                [[NSFileManager defaultManager]
                    createDirectoryAtPath:dir
                    withIntermediateDirectories:YES attributes:nil error:nil];
                [png writeToFile:path atomically:YES];
            }
        }
    );
}
