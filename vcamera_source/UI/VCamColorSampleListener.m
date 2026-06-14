// VCamColorSampleListener.m

#import "VCamColorSampleListener.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <notify.h>
#include <string.h>
#include <math.h>

#define HUE_BINS 12

static UIWindow *vcamFindTargetWindow(void) {
    // iOS 13-15: [UIApplication windows] works reliably.
    NSArray *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *w in windows) {
        if (!w.isHidden && w.alpha > 0.0 && w.windowLevel == UIWindowLevelNormal)
            return w;
    }

    // iOS 16+: many apps migrate to UIWindowScene; [UIApplication windows]
    // returns an empty array for scene-based apps.  Enumerate via connectedScenes.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) continue;
        NSArray *sceneWindows = [scene valueForKey:@"windows"];
        for (UIWindow *w in sceneWindows) {
            if (!w.isHidden && w.alpha > 0.0 && w.windowLevel == UIWindowLevelNormal)
                return w;
        }
    }

    return [[UIApplication sharedApplication] keyWindow];
}

void vcamInstallColorSampleListener(void) {
    static int s_respToken = NOTIFY_TOKEN_INVALID;
    notify_register_check("com.vcam.sampleresponse", &s_respToken);

    static int s_reqToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(
        "com.vcam.samplerequest",
        &s_reqToken,
        dispatch_get_main_queue(),
        ^(int token) {
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive)
                return;

            // Read the float button's normalised position packed by SpringBoard.
            uint64_t packed = 0;
            notify_get_state(token, &packed);
            uint32_t xBits = (uint32_t)(packed >> 32);
            uint32_t yBits = (uint32_t)(packed & 0xFFFFFFFFULL);
            float nx = 0.0f, ny = 0.0f;
            memcpy(&nx, &xBits, 4);
            memcpy(&ny, &yBits, 4);
            if (nx < 0.0f || nx > 1.0f || ny < 0.0f || ny > 1.0f) return;

            CGSize sz = [UIScreen mainScreen].bounds.size;
            if (sz.width <= 0 || sz.height <= 0) return;

            float xf = nx * (float)sz.width;
            float yf = ny * (float)sz.height;

            UIWindow *targetWindow = vcamFindTargetWindow();
            if (!targetWindow) return;

            // Sample an 8x8 pt region centred on the float button position.
            // Negative-offset rect shifts (xf,yf) to canvas centre — no CTM needed,
            // drawViewHierarchyInRect: uses the rect origin directly.
            // afterScreenUpdates:NO excludes GPU-rendered camera layers (they appear
            // black and are filtered by the v<0.05 threshold below).
            const int DIM = 8;
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(DIM, DIM), YES, 1.0);
            CGRect viewRect = CGRectMake(-(CGFloat)xf + DIM * 0.5f,
                                          -(CGFloat)yf + DIM * 0.5f,
                                          sz.width, sz.height);
            [targetWindow drawViewHierarchyInRect:viewRect afterScreenUpdates:NO];
            UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (!img || !img.CGImage) return;

            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(img.CGImage));
            if (!data) return;

            const uint8_t *bytes = CFDataGetBytePtr(data);
            size_t bpr = CGImageGetBytesPerRow(img.CGImage);

            double binSin[HUE_BINS] = {0};
            double binCos[HUE_BINS] = {0};
            int    binCnt[HUE_BINS] = {0};

            for (int row = 0; row < DIM; row++) {
                for (int col = 0; col < DIM; col++) {
                    const uint8_t *p = bytes + row * bpr + col * 4;
                    // UIGraphicsBeginImageContextWithOptions on ARM: BGRA order.
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
            if (bestBin < 0) {
                notify_set_state(s_respToken, 0xFFFFFFFFFFFFFFFFULL);
                notify_post("com.vcam.sampleresponse");
                return;
            }

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
