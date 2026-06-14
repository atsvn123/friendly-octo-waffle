// VCamColorPickerWindow.m
// Pass-through window + color sampling infrastructure for the float button.
// The float button (VCamFloatButton) lives inside this window.
//
// Sampling priority (all run in SpringBoard, no foreground-app injection needed):
//   1. IOMobileFramebuffer IOSurface direct pixel read  — fastest, 1 pixel
//   2. UIGetScreenImage() + 16x16pt region sample       — works on all apps
//                                                          including RootHide-protected ones
//   3. Darwin notify cross-process fallback             — last resort, non-RootHide only

#import "VCamColorPickerWindow.h"
#import "VCamFloatButton.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <IOSurface/IOSurfaceRef.h>
#import <notify.h>
#include <dlfcn.h>
#include <string.h>
#include <math.h>
#include <mach/mach.h>

// ─────────────────────────────────────────────────────────────────────────────
// Fast path 1: IOMobileFramebuffer IOSurface direct read.
// Returns [0,1) = hue, -1.0 = achromatic, -2.0 = IOSurface unavailable.
// On A10/iOS 15 IOMobileFramebufferOpen needs an entitlement we don't have;
// always returns -2.0, falling through to UIGetScreenImage.
// ─────────────────────────────────────────────────────────────────────────────
typedef uint32_t vcam_io_object_t;
typedef vcam_io_object_t vcam_io_service_t;
typedef vcam_io_service_t (*vcam_IOServiceGetMatchingService_t)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*vcam_IOObjectRelease_t)(vcam_io_object_t);
typedef CFMutableDictionaryRef (*vcam_IOServiceMatching_t)(const char *);
typedef kern_return_t (*vcamFBOpen_t)(vcam_io_service_t, mach_port_t, uint32_t, void **);
typedef kern_return_t (*vcamFBGetSurface_t)(void *, int, IOSurfaceRef *);

static double vcamSampleDisplayHue(CGPoint pt) {
    static void              *s_fb         = NULL;
    static vcamFBGetSurface_t s_getSurface = NULL;
    static dispatch_once_t    s_once       = 0;

    dispatch_once(&s_once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                             RTLD_NOW | RTLD_GLOBAL);
        if (!iokit) return;
        vcam_IOServiceGetMatchingService_t ioGetService =
            (vcam_IOServiceGetMatchingService_t)dlsym(iokit, "IOServiceGetMatchingService");
        vcam_IOObjectRelease_t ioRelease =
            (vcam_IOObjectRelease_t)dlsym(iokit, "IOObjectRelease");
        vcam_IOServiceMatching_t ioMatching =
            (vcam_IOServiceMatching_t)dlsym(iokit, "IOServiceMatching");
        if (!ioGetService || !ioRelease || !ioMatching) return;

        void *fbLib = dlopen(
            "/System/Library/PrivateFrameworks/"
            "IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
        if (!fbLib) return;
        vcamFBOpen_t fbOpen = (vcamFBOpen_t)dlsym(fbLib, "IOMobileFramebufferOpen");
        s_getSurface = (vcamFBGetSurface_t)dlsym(fbLib,
                           "IOMobileFramebufferGetLayerDefaultSurface");
        if (!fbOpen || !s_getSurface) return;

        const char *names[] = {"IOMobileFramebuffer", "IOMobileFramebufferShim", NULL};
        for (int i = 0; names[i] && !s_fb; i++) {
            CFMutableDictionaryRef m = ioMatching(names[i]);
            if (!m) continue;
            vcam_io_service_t svc = ioGetService(0, m);
            if (!svc) continue;
            fbOpen(svc, mach_task_self(), 0, &s_fb);
            ioRelease(svc);
        }
    });

    if (!s_fb || !s_getSurface) return -2.0;

    IOSurfaceRef surface = NULL;
    if (s_getSurface(s_fb, 0, &surface) != KERN_SUCCESS || !surface) return -2.0;

    CGFloat scale = [UIScreen mainScreen].scale;
    size_t px = (size_t)(pt.x * scale);
    size_t py = (size_t)(pt.y * scale);
    size_t sw = IOSurfaceGetWidth(surface);
    size_t sh = IOSurfaceGetHeight(surface);
    if (px >= sw || py >= sh) { CFRelease(surface); return -2.0; }

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    size_t   bpr  = IOSurfaceGetBytesPerRow(surface);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface);
    uint8_t *p    = base + py * bpr + px * 4;
    double r = p[2] / 255.0;
    double g = p[1] / 255.0;
    double b = p[0] / 255.0;
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);

    double maxC  = r > g ? (r > b ? r : b) : (g > b ? g : b);
    double minC  = r < g ? (r < b ? r : b) : (g < b ? g : b);
    double delta = maxC - minC;
    if (delta < 0.06 || maxC < 0.04 || (1.0 - minC) < 0.04) return -1.0;

    double h;
    if      (maxC == r) h = fmod((g - b) / delta, 6.0);
    else if (maxC == g) h = (b - r) / delta + 2.0;
    else                h = (r - g) / delta + 4.0;
    h /= 6.0;
    if (h < 0.0) h += 1.0;
    return h;
}

// ─────────────────────────────────────────────────────────────────────────────
// Fast path 2: UIGetScreenImage() — UIKit private API.
// Captures the full hardware compositor output (foreground app + all overlays)
// from SpringBoard context. Works on iOS 15 and 16 on jailbroken devices.
// Resolved at runtime via dlsym so we degrade gracefully if unavailable.
// ─────────────────────────────────────────────────────────────────────────────
typedef CGImageRef (*vcamUIGetScreenImage_t)(void);

static vcamUIGetScreenImage_t vcamGetScreenImageFn(void) {
    static vcamUIGetScreenImage_t s_fn = NULL;
    static dispatch_once_t        s_once = 0;
    dispatch_once(&s_once, ^{
        s_fn = (vcamUIGetScreenImage_t)dlsym(RTLD_DEFAULT, "UIGetScreenImage");
    });
    return s_fn;
}

#define VCAM_HUE_BINS 12

// Sample a 16x16pt region centered on pt from a full-screen CGImageRef.
// Returns dominant hue [0,1) or -1.0 if all pixels are achromatic.
static double vcamSampleScreenImageHueAt(CGImageRef screenImg, CGPoint pt) {
    CGFloat scale = [UIScreen mainScreen].scale;
    size_t imgW = CGImageGetWidth(screenImg);
    size_t imgH = CGImageGetHeight(screenImg);

    // 8pt half-extent → 16pt square, converted to pixels
    size_t halfPx = (size_t)(8.0 * scale);
    size_t sampPx = halfPx * 2;

    size_t px = (size_t)(pt.x * scale);
    size_t py = (size_t)(pt.y * scale);

    size_t x0 = (px > halfPx) ? (px - halfPx) : 0;
    size_t y0 = (py > halfPx) ? (py - halfPx) : 0;
    size_t x1 = (x0 + sampPx < imgW) ? (x0 + sampPx) : imgW;
    size_t y1 = (y0 + sampPx < imgH) ? (y0 + sampPx) : imgH;
    size_t cw = x1 - x0;
    size_t ch = y1 - y0;
    if (!cw || !ch) return -1.0;

    // Crop to the small region we need
    CGImageRef crop = CGImageCreateWithImageInRect(screenImg, CGRectMake(x0, y0, cw, ch));
    if (!crop) return -1.0;

    uint8_t *buf = (uint8_t *)malloc(cw * ch * 4);
    if (!buf) { CGImageRelease(crop); return -1.0; }

    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceRGB();
    // ByteOrder32Little | AlphaPremultipliedFirst → bytes in memory: [B, G, R, A]
    CGContextRef ctx = CGBitmapContextCreate(buf, cw, ch, 8, cw * 4, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); CGImageRelease(crop); return -1.0; }

    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)cw, (CGFloat)ch), crop);
    CGContextRelease(ctx);
    CGImageRelease(crop);

    double binSin[VCAM_HUE_BINS];
    double binCos[VCAM_HUE_BINS];
    int    binCnt[VCAM_HUE_BINS];
    memset(binSin, 0, sizeof(binSin));
    memset(binCos, 0, sizeof(binCos));
    memset(binCnt, 0, sizeof(binCnt));

    size_t total = cw * ch;
    for (size_t i = 0; i < total; i++) {
        // [B, G, R, A] byte order
        UIColor *c = [UIColor colorWithRed:buf[i*4+2]/255.0
                                     green:buf[i*4+1]/255.0
                                      blue:buf[i*4+0]/255.0
                                     alpha:1.0];
        CGFloat h=0, s=0, v=0, a=0;
        if (![c getHue:&h saturation:&s brightness:&v alpha:&a]) continue;
        if (s < 0.08 || v < 0.05 || v > 0.97) continue;
        int bin = (int)(h * VCAM_HUE_BINS) % VCAM_HUE_BINS;
        double angle = h * 2.0 * M_PI;
        binSin[bin] += sin(angle);
        binCos[bin] += cos(angle);
        binCnt[bin]++;
    }
    free(buf);

    int bestBin = -1, bestCount = 0;
    for (int i = 0; i < VCAM_HUE_BINS; i++) {
        if (binCnt[i] > bestCount) { bestCount = binCnt[i]; bestBin = i; }
    }
    if (bestBin < 0) return -1.0;

    double meanAngle = atan2(binSin[bestBin] / bestCount, binCos[bestBin] / bestCount);
    if (meanAngle < 0.0) meanAngle += 2.0 * M_PI;
    double hue = meanAngle / (2.0 * M_PI);
    return (hue >= 0.0 && hue <= 1.0) ? hue : -1.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Darwin notify infrastructure
// ─────────────────────────────────────────────────────────────────────────────
static int s_reqToken  = NOTIFY_TOKEN_INVALID;
static int s_respToken = NOTIFY_TOKEN_INVALID;

// g_floatButton is defined in VCamFloatButton.m, declared extern in VCamFloatButton.h
void vcamInstallPickerNotifyHandler(void) {
    if (s_reqToken != NOTIFY_TOKEN_INVALID) return;

    notify_register_check("com.vcam.samplerequest", &s_reqToken);

    notify_register_dispatch(
        "com.vcam.sampleresponse",
        &s_respToken,
        dispatch_get_main_queue(),
        ^(int token) {
            uint64_t state = 0;
            notify_get_state(token, &state);

            // Sentinel 0xFFFFFFFFFFFFFFFF = UIKit sampler saw only achromatic pixels
            if (state == 0xFFFFFFFFFFFFFFFFULL) {
                [g_floatButton setRingHue:-1.0];
                BINFlashSavePrefs(@{ kBINFlashKeyHue: @(-1.0) });
                return;
            }

            uint32_t hueBits = (uint32_t)(state & 0xFFFFFFFFULL);
            float hf = 0.0f;
            memcpy(&hf, &hueBits, 4);
            double h = (double)hf;
            if (h < 0.0 || h > 1.0) return;

            [g_floatButton setRingHue:h];
            BINFlashSavePrefs(@{ kBINFlashKeyHue: @(h) });
        });
}

void vcamSendPickerSampleRequest(float nx, float ny) {
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width <= 0 || sz.height <= 0) return;

    CGPoint pt = CGPointMake((CGFloat)nx * sz.width, (CGFloat)ny * sz.height);

    // ── Fast path 1: IOSurface direct pixel read ──────────────────────────────
    double hue = vcamSampleDisplayHue(pt);
    if (hue >= -1.5) {
        // >= -1.5 means IOSurface is working (-1.0 = achromatic, [0,1) = hue)
        [g_floatButton setRingHue:hue];
        BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
        return;
    }
    // -2.0 → IOSurface unavailable (entitlement not present); fall through.

    // ── Fast path 2: UIGetScreenImage() ──────────────────────────────────────
    // Captures full compositor output from SpringBoard: foreground app content
    // is visible regardless of whether our dylib is injected into that app.
    // This makes it work for RootHide-protected apps (Sileo, Dopamine, etc.)
    // where dylib injection is blocked.
    //
    // Sample 60pt INWARD from the button's edge, NOT at the button center.
    // The button always snaps to the left or right screen edge; 60pt inward
    // always lands on app content, never on the button's own pink background.
    vcamUIGetScreenImage_t getScreenImage = vcamGetScreenImageFn();
    if (getScreenImage) {
        CGFloat sampleX = (pt.x > sz.width * 0.5f)
            ? (pt.x - 60.0f)   // button on right edge → sample left
            : (pt.x + 60.0f);  // button on left edge  → sample right
        sampleX = (sampleX < 16.0f)            ? 16.0f            : sampleX;
        sampleX = (sampleX > sz.width - 16.0f) ? sz.width - 16.0f : sampleX;
        CGFloat sampleY = pt.y;
        sampleY = (sampleY < 16.0f)             ? 16.0f             : sampleY;
        sampleY = (sampleY > sz.height - 16.0f) ? sz.height - 16.0f : sampleY;

        CGImageRef screenImg = getScreenImage();
        if (screenImg) {
            double screenHue = vcamSampleScreenImageHueAt(screenImg,
                                   CGPointMake(sampleX, sampleY));
            CGImageRelease(screenImg);
            [g_floatButton setRingHue:screenHue];
            BINFlashSavePrefs(@{ kBINFlashKeyHue: @(screenHue) });
            return;
        }
    }

    // ── Fallback: cross-process Darwin notify ─────────────────────────────────
    // The foreground app's vcamInstallColorSampleListener() receives this,
    // renders an 8x8pt region at (nx, ny) with drawViewHierarchyInRect:, and
    // posts com.vcam.sampleresponse. Only works when our dylib is injected
    // (non-RootHide apps). vcamInstallPickerNotifyHandler() handles the response.
    if (s_reqToken == NOTIFY_TOKEN_INVALID) return;
    uint32_t xBits = 0, yBits = 0;
    memcpy(&xBits, &nx, 4);
    memcpy(&yBits, &ny, 4);
    notify_set_state(s_reqToken, ((uint64_t)xBits << 32) | (uint64_t)yBits);
    notify_post("com.vcam.samplerequest");
}

// ─────────────────────────────────────────────────────────────────────────────
// VCamColorPickerWindow — pass-through container for the float button
// ─────────────────────────────────────────────────────────────────────────────
@implementation VCamColorPickerWindow

+ (instancetype)sharedWindow {
    static VCamColorPickerWindow *s_window = nil;
    static dispatch_once_t        s_once   = 0;
    dispatch_once(&s_once, ^{
        UIWindowScene *scene = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)sc; break;
            }
            if (!scene) scene = (UIWindowScene *)sc;
        }
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (scene) {
            s_window = [[VCamColorPickerWindow alloc] initWithWindowScene:scene];
            s_window.frame = bounds;
        } else {
            s_window = [[VCamColorPickerWindow alloc] initWithFrame:bounds];
        }
        s_window.backgroundColor = [UIColor clearColor];
        s_window.opaque          = NO;
        s_window.windowLevel     = UIWindowLevelAlert + 10000.0;

        UIViewController *rvc = [[UIViewController alloc] init];
        rvc.view.backgroundColor       = [UIColor clearColor];
        rvc.view.userInteractionEnabled = YES;
        s_window.rootViewController = rvc;
        [rvc release];
        s_window.hidden = NO;
    });
    return s_window;
}

// Pass through touches that don't land on the float button.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

@end
