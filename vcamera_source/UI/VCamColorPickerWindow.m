// VCamColorPickerWindow.m
// Pass-through window + color sampling for the float button.
// Sampling priority (all SpringBoard-side, no foreground-app injection needed):
//   1. IOMobileFramebuffer IOSurface        — fails -2 on A10/iOS 15 (no entitlement)
//   2. UIGetScreenImage() full-frame 60x90  — captures hardware compositor output
//   3. App icon dominant hue fallback        — 100% reliable for all apps incl. RootHide
//   4. Darwin notify cross-process          — non-RootHide apps only

#import "VCamColorPickerWindow.h"
#import "VCamFloatButton.h"
#import "../BINFlash/BINFlashPrefs.h"
#import "../VCamBridge/VCamBridge.h"
#import <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#include <dlfcn.h>
#include <string.h>
#include <math.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostic logging — main queue only
// Appends one line to g_vcamDiag (max 20 lines), visible in menu DEBUG panel.
// ─────────────────────────────────────────────────────────────────────────────
static void vcamPickerDiag(NSString *msg) {
    NSMutableArray *lines = [NSMutableArray array];
    if (g_vcamDiag && [g_vcamDiag length] > 0)
        [lines addObjectsFromArray:[g_vcamDiag componentsSeparatedByString:@"\n"]];
    [lines addObject:msg];
    while ([lines count] > 20) [lines removeObjectAtIndex:0];
    NSString *updated = [[lines componentsJoinedByString:@"\n"] retain];
    [g_vcamDiag release];
    g_vcamDiag = updated;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared hue-from-image sampling.
// Renders img into a dstW x dstH buffer and finds the dominant hue
// across ALL pixels. Returns [0,1) or -1.0 if no chromatic pixels found.
// ─────────────────────────────────────────────────────────────────────────────
// Sample the background color directly adjacent to the float button.
// Crops a 300×300 px region centered on (nx,ny), draws it to a full-res bitmap,
// then reads 8 pixels in a circle at sampleR px — just outside the ring outer
// edge (32pt = 64px at 2x). Averages their RGB and returns the hue, or -1 if
// the area is achromatic (white/black/gray).
// ─────────────────────────────────────────────────────────────────────────────
// Sample a 20×20 px cluster at the donut center from a full-screen CGImage.
// The donut hole is transparent so the background shows through at (nx,ny).
// Returns hue [0,1) or -1.0 if achromatic.
static double vcamSampleCenterCluster(CGImageRef img, float nx, float ny,
                                      NSString **diagOut) {
    size_t imgW = CGImageGetWidth(img);
    size_t imgH = CGImageGetHeight(img);
    if (!imgW || !imgH) return -1.0;

    int px = (int)(nx * (double)imgW + 0.5);
    int py = (int)(ny * (double)imgH + 0.5);

    const int SZ = 20;
    int x0 = px - SZ/2; if (x0 < 0) x0 = 0;
    int y0 = py - SZ/2; if (y0 < 0) y0 = 0;
    int x1 = x0 + SZ; if (x1 > (int)imgW) { x1 = (int)imgW; x0 = x1 - SZ; if (x0 < 0) x0 = 0; }
    int y1 = y0 + SZ; if (y1 > (int)imgH) { y1 = (int)imgH; y0 = y1 - SZ; if (y0 < 0) y0 = 0; }
    int w = x1 - x0, h = y1 - y0;
    if (w <= 0 || h <= 0) return -1.0;

    double r = 0.0, g = 0.0, b = 0.0;
    int count = 0;
    BOOL usedDirect = NO;

    // Primary path: read directly from the data provider.
    // CGImageRef stores row 0 at screen TOP (standard image convention).
    // Direct access: pixel at (col, row) = bytes + row*bpr + col*bpp.
    // No CGContext → no coordinate-system ambiguity.
    CFDataRef rawData = CGDataProviderCopyData(CGImageGetDataProvider(img));
    if (rawData) {
        size_t bpr = CGImageGetBytesPerRow(img);
        size_t bpp = CGImageGetBitsPerPixel(img) / 8;
        if (bpp >= 3) {
            const uint8_t *bytes = CFDataGetBytePtr(rawData);
            CGBitmapInfo bi = CGImageGetBitmapInfo(img);
            // kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst = BGRA
            // kCGBitmapByteOrder32Big   | kCGImageAlphaPremultipliedFirst = ARGB
            int rOff, gOff, bOff;
            if ((bi & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little) {
                rOff = 2; gOff = 1; bOff = 0; // BGRA
            } else {
                rOff = 1; gOff = 2; bOff = 3; // ARGB
            }
            double tR = 0.0, tG = 0.0, tB = 0.0;
            for (int row = y0; row < y1; row++) {
                const uint8_t *rp = bytes + (size_t)row * bpr;
                for (int col = x0; col < x1; col++) {
                    const uint8_t *p = rp + (size_t)col * bpp;
                    tR += p[rOff]; tG += p[gOff]; tB += p[bOff];
                    count++;
                }
            }
            if (count > 0) {
                r = tR / (count * 255.0);
                g = tG / (count * 255.0);
                b = tB / (count * 255.0);
                usedDirect = YES;
            }
        }
        CFRelease(rawData);
    }

    // Fallback: CGContext with Y-flip (sequential-access data providers).
    if (!usedDirect) {
        uint8_t buf[20*20*4];
        memset(buf, 0, sizeof(buf));
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, (size_t)w, (size_t)h, 8,
            (size_t)w * 4, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(cs);
        if (!ctx) return -1.0;
        CGContextTranslateCTM(ctx, 0, (CGFloat)h);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        CGContextDrawImage(ctx, CGRectMake(-(CGFloat)x0, -(CGFloat)y0,
                                           (CGFloat)imgW, (CGFloat)imgH), img);
        CGContextRelease(ctx);
        count = w * h;
        double tR = 0.0, tG = 0.0, tB = 0.0;
        for (int i = 0; i < count; i++) {
            tR += buf[i*4+2]; tG += buf[i*4+1]; tB += buf[i*4+0];
        }
        r = tR / (count * 255.0);
        g = tG / (count * 255.0);
        b = tB / (count * 255.0);
    }

    if (diagOut)
        *diagOut = [NSString stringWithFormat:@"%s %zux%zu px=%d py=%d R=%.2f G=%.2f B=%.2f",
                    usedDirect ? "DIR" : "CTX", imgW, imgH, px, py, r, g, b];

    if (count == 0) return -1.0;

    double maxC  = r > g ? (r > b ? r : b) : (g > b ? g : b);
    double minC  = r < g ? (r < b ? r : b) : (g < b ? g : b);
    double delta = maxC - minC;
    if (delta < 0.05 || maxC < 0.04 || minC > 0.97) return -1.0;

    double hue;
    if      (maxC == r) hue = fmod((g - b) / delta, 6.0);
    else if (maxC == g) hue = (b - r) / delta + 2.0;
    else                hue = (r - g) / delta + 4.0;
    hue /= 6.0;
    if (hue < 0.0) hue += 1.0;
    return (hue >= 0.0 && hue <= 1.0) ? hue : -1.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Fast path 1: IOMobileFramebuffer IOSurface direct read.
// Returns hue [0,1), -1.0 = achromatic, -2.0 = unavailable (no entitlement).
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

        const char *names[] = {
            "IOMobileFramebuffer", "IOMobileFramebufferShim", "AppleH10IOMFB", NULL
        };
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
// Fast path 2a: UIGetScreenImage() — removed from iOS 14+.
// Definitive search: check ALL loaded dyld images (not just UIKitCore) so we
// know if the symbol moved to a different framework. Runs once in dispatch_once.
// ─────────────────────────────────────────────────────────────────────────────
typedef CGImageRef (*vcamUIGetScreenImage_t)(void);

static vcamUIGetScreenImage_t vcamGetScreenImageFn(void) {
    static vcamUIGetScreenImage_t s_fn   = NULL;
    static dispatch_once_t        s_once = 0;
    dispatch_once(&s_once, ^{
        // iOS 15+: UIGetScreenImage was renamed to UICreateScreenImage.
        // It lives in UIKitCore's export trie → plain dlsym finds it.
        s_fn = (vcamUIGetScreenImage_t)dlsym(RTLD_DEFAULT, "UICreateScreenImage");
        // Older iOS fallback
        if (!s_fn) s_fn = (vcamUIGetScreenImage_t)dlsym(RTLD_DEFAULT, "UIGetScreenImage");

        void *fnAddr = (void *)(uintptr_t)s_fn;
        dispatch_async(dispatch_get_main_queue(), ^{
            vcamPickerDiag([NSString stringWithFormat:@"[init] screenImageFn=%p", fnAddr]);
        });
    });
    return s_fn;
}



// ─────────────────────────────────────────────────────────────────────────────
// Darwin notify infrastructure (fallback for non-RootHide apps)
// ─────────────────────────────────────────────────────────────────────────────
static int s_reqToken  = NOTIFY_TOKEN_INVALID;
static int s_respToken = NOTIFY_TOKEN_INVALID;

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

// ─────────────────────────────────────────────────────────────────────────────
// Main entry point — called every ~200 ms from vcamUpdateFloatButton (main queue)
// ─────────────────────────────────────────────────────────────────────────────
void vcamSendPickerSampleRequest(float nx, float ny) {
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width <= 0 || sz.height <= 0) return;

    CGPoint pt = CGPointMake((CGFloat)nx * sz.width, (CGFloat)ny * sz.height);

    // Rate-limit diagnostic output: log every ~3 seconds (15 calls × 200ms)
    static NSUInteger s_diagCount = 0;
    BOOL shouldLog = ((s_diagCount++ % 15) == 0);

    // ── Fast path 1: IOSurface ────────────────────────────────────────────────
    double hue = vcamSampleDisplayHue(pt);
    if (hue >= -1.5) {
        // >= -1.5 means IOSurface is operational (-1.0 achromatic, [0,1) has color)
        if (shouldLog)
            vcamPickerDiag([NSString stringWithFormat:@"[FP1] IOSurf h=%.2f", hue]);
        [g_floatButton setRingHue:hue];
        BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
        return;
    }
    // -2.0 → no entitlement; falls through on A10/iOS 15

    // ── Fast path 2: UICreateScreenImage (iOS 15+ rename of UIGetScreenImage) ──
    // GPU compositor readback (~30-50ms). Runs on a background serial queue so it
    // never blocks SpringBoard's main thread. No caching — ring only updates when a
    // fresh valid hue arrives. One capture at a time (s_fp2Running gate).
    static dispatch_queue_t s_q          = NULL;
    static volatile BOOL    s_fp2Running = NO;
    static dispatch_once_t  s_qOnce      = 0;
    dispatch_once(&s_qOnce, ^{
        s_q = dispatch_queue_create("com.vcam.screencap", DISPATCH_QUEUE_SERIAL);
    });

    vcamUIGetScreenImage_t getScreenImage = vcamGetScreenImageFn();
    if (getScreenImage) {
        if (!s_fp2Running) {
            s_fp2Running = YES;
            // Capture screen on main thread (UIKit API requirement).
            // We're already on the main thread here (called from NSTimer).
            // Only the hue computation runs on the background queue.
            CGImageRef screenImg = getScreenImage();
            if (!screenImg) {
                s_fp2Running = NO;
                return;
            }
            float capturedNx = nx;
            float capturedNy = ny;
            BOOL log = shouldLog;
            dispatch_async(s_q, ^{
                NSString *diag = nil;
                double hue = vcamSampleCenterCluster(screenImg, capturedNx, capturedNy,
                                                     log ? &diag : NULL);
                CGImageRelease(screenImg);
                s_fp2Running = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [g_floatButton setRingHue:hue];
                    BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
                    if (log)
                        vcamPickerDiag([NSString stringWithFormat:@"[FP2] h=%.2f %@",
                                        hue, diag ? diag : @""]);
                });
            });
        }
        return; // fp2 available — don't fall through to Darwin notify
    }

    // ── Fallback: cross-process Darwin notify ─────────────────────────────────
    // Foreground app's vcamInstallColorSampleListener() responds with a hue.
    // Only works when dylib is injected (non-RootHide apps).
    if (s_reqToken == NOTIFY_TOKEN_INVALID) return;
    uint32_t xBits = 0, yBits = 0;
    memcpy(&xBits, &nx, 4);
    memcpy(&yBits, &ny, 4);
    notify_set_state(s_reqToken, ((uint64_t)xBits << 32) | (uint64_t)yBits);
    notify_post("com.vcam.samplerequest");
    if (shouldLog)
        vcamPickerDiag([NSString stringWithFormat:@"[FB] notify nx=%.2f ny=%.2f", nx, ny]);
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

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

@end
