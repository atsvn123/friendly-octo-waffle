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
static double vcamSampleButtonBackground(CGImageRef img, float nx, float ny) {
    size_t imgW = CGImageGetWidth(img);
    size_t imgH = CGImageGetHeight(img);
    if (!imgW || !imgH) return -1.0;

    // Crop 300×300 px centered on button position.
    const size_t cropSz = 300;
    CGFloat cropX = (CGFloat)nx * imgW - cropSz * 0.5;
    CGFloat cropY = (CGFloat)ny * imgH - cropSz * 0.5;
    if (cropX < 0) cropX = 0;
    if (cropY < 0) cropY = 0;
    if (cropX + cropSz > imgW) cropX = (CGFloat)imgW - cropSz;
    if (cropY + cropSz > imgH) cropY = (CGFloat)imgH - cropSz;

    CGImageRef crop = CGImageCreateWithImageInRect(img,
        CGRectMake(cropX, cropY, (CGFloat)cropSz, (CGFloat)cropSz));
    if (!crop) return -1.0;

    // Render to full-res BGRA bitmap (300×300 × 4 = 360 KB).
    uint8_t *buf = (uint8_t *)malloc(cropSz * cropSz * 4);
    if (!buf) { CGImageRelease(crop); return -1.0; }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, cropSz, cropSz, 8, cropSz * 4, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); CGImageRelease(crop); return -1.0; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)cropSz, (CGFloat)cropSz), crop);
    CGContextRelease(ctx);
    CGImageRelease(crop);

    // Sample 8 pixels evenly around the button at radius 70px from center.
    // Ring outer edge: arc 30pt + half lineWidth 2pt = 32pt = 64px at 2x.
    // 70px puts samples 3pt outside the ring with a clean margin.
    double cx = (cropSz - 1) * 0.5;
    double cy = (cropSz - 1) * 0.5;
    const double sampleR = 70.0;

    double totalR = 0.0, totalG = 0.0, totalB = 0.0;
    int count = 0;
    for (int a = 0; a < 8; a++) {
        double angle = a * M_PI * 0.25;
        int sx = (int)(cx + sampleR * cos(angle) + 0.5);
        int sy = (int)(cy + sampleR * sin(angle) + 0.5);
        if (sx < 0 || sx >= (int)cropSz || sy < 0 || sy >= (int)cropSz) continue;
        size_t idx = (size_t)sy * cropSz + (size_t)sx;
        // kCGBitmapByteOrder32Little | AlphaPremultipliedFirst → [B,G,R,A]
        totalR += buf[idx*4+2] / 255.0;
        totalG += buf[idx*4+1] / 255.0;
        totalB += buf[idx*4+0] / 255.0;
        count++;
    }
    free(buf);

    if (count == 0) return -1.0;
    double r = totalR / count;
    double g = totalG / count;
    double b = totalB / count;

    double maxC  = r > g ? (r > b ? r : b) : (g > b ? g : b);
    double minC  = r < g ? (r < b ? r : b) : (g < b ? g : b);
    double delta = maxC - minC;
    if (delta < 0.05 || maxC < 0.04 || minC > 0.97) return -1.0;

    double h;
    if      (maxC == r) h = fmod((g - b) / delta, 6.0);
    else if (maxC == g) h = (b - r) / delta + 2.0;
    else                h = (r - g) / delta + 4.0;
    h /= 6.0;
    if (h < 0.0) h += 1.0;
    return (h >= 0.0 && h <= 1.0) ? h : -1.0;
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
            // Capture position on main thread — used in background to crop the image.
            float capturedNx = nx;
            float capturedNy = ny;
            dispatch_async(s_q, ^{
                CGImageRef screenImg = getScreenImage();
                double hue = -1.0;
                if (screenImg) {
                    hue = vcamSampleButtonBackground(screenImg, capturedNx, capturedNy);
                    CGImageRelease(screenImg);
                }
                s_fp2Running = NO;
                // Always dispatch — hue=-1 hides ring and sets noColor bit in prefs
                // so BINFlashPixelEffect returns early → flash off on black/white.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [g_floatButton setRingHue:hue];
                    BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
                    if (shouldLog)
                        vcamPickerDiag([NSString stringWithFormat:@"[FP2] h=%.2f", hue]);
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
