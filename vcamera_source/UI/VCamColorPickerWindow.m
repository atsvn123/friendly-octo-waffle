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
// Compute hue from a pre-extracted raw pixel buffer.
// bytes: raw pixel data from CGDataProviderCopyData (row 0 = screen TOP).
// Channel offsets depend on bitmapInfo — passed pre-computed.
// Returns hue [0,1) or -1.0 if achromatic.
static double vcamComputeHueFromRaw(const uint8_t *bytes,
                                     size_t imgW, size_t imgH,
                                     size_t bpr, size_t bpp,
                                     int rOff, int gOff, int bOff,
                                     float nx, float ny,
                                     NSString **diagOut) {
    int px = (int)(nx * (double)imgW + 0.5);
    int py = (int)(ny * (double)imgH + 0.5);

    const int SZ = 20;
    int x0 = px - SZ/2; if (x0 < 0) x0 = 0;
    int y0 = py - SZ/2; if (y0 < 0) y0 = 0;
    int x1 = x0 + SZ; if (x1 > (int)imgW) { x1 = (int)imgW; x0 = x1-SZ; if (x0<0) x0=0; }
    int y1 = y0 + SZ; if (y1 > (int)imgH) { y1 = (int)imgH; y0 = y1-SZ; if (y0<0) y0=0; }

    // On iOS 16+ with Display P3, UICreateScreenImage returns 64bpp (bpp=8 bytes/pixel):
    // kCGBitmapByteOrder16Little | kCGImageAlphaNoneSkipLast (bi=0x1005).
    // Layout: R(2 bytes LE), G(2 bytes LE), B(2 bytes LE), X(2 bytes LE).
    // On iOS 15 and non-P3 devices: 32bpp (bpp=4), use rOff/gOff/bOff as before.
    BOOL wide = (bpp == 8);

    double tR = 0.0, tG = 0.0, tB = 0.0;
    int count = 0;
    for (int row = y0; row < y1; row++) {
        const uint8_t *rp = bytes + (size_t)row * bpr;
        for (int col = x0; col < x1; col++) {
            const uint8_t *p = rp + (size_t)col * bpp;
            if (wide) {
                tR += (double)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
                tG += (double)((uint16_t)p[2] | ((uint16_t)p[3] << 8));
                tB += (double)((uint16_t)p[4] | ((uint16_t)p[5] << 8));
            } else {
                tR += p[rOff]; tG += p[gOff]; tB += p[bOff];
            }
            count++;
        }
    }
    if (count == 0) return -1.0;

    double scale = wide ? 65535.0 : 255.0;
    double r = tR / (count * scale);
    double g = tG / (count * scale);
    double b = tB / (count * scale);

    if (diagOut)
        *diagOut = [NSString stringWithFormat:@"%zux%zu px=%d py=%d R=%.2f G=%.2f B=%.2f",
                    imgW, imgH, px, py, r, g, b];

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
                BINFlashSavePrefs(@{ kBINFlashKeyHue: @(-1.0) });
                return;
            }
            uint32_t hueBits = (uint32_t)(state & 0xFFFFFFFFULL);
            float hf = 0.0f;
            memcpy(&hf, &hueBits, 4);
            double h = (double)hf;
            if (h < 0.0 || h > 1.0) return;
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
        BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
        [g_floatButton setRingHue:hue];
        return;
    }
    // -2.0 → no entitlement; falls through on A10/iOS 15

    // ── Fast path 2: UICreateScreenImage → crop (main) → bitmap (background) ──
    // UICreateScreenImage is UIKit — must stay on main thread (~16 ms typical).
    // CGContextDrawImage triggers IOSurface lock; in active apps the GPU can hold
    // the lock for a full frame (~16 ms at 60 fps). Running it on the background
    // queue keeps the main thread free so gesture recognizers stay responsive.
    // Rate-limited at 0.5 s: UICreateScreenImage is the unavoidable main-thread
    // cost; firing it every 200 ms (8 % + of main thread in-app) blocks drags.
    static CFAbsoluteTime   s_fp2LastTime = 0.0;
    static dispatch_queue_t s_q           = NULL;
    static volatile BOOL    s_fp2Running  = NO;
    static dispatch_once_t  s_qOnce       = 0;
    dispatch_once(&s_qOnce, ^{
        s_q = dispatch_queue_create("com.vcam.screencap", DISPATCH_QUEUE_SERIAL);
    });

    vcamUIGetScreenImage_t getScreenImage = vcamGetScreenImageFn();
    if (getScreenImage) {
        CFAbsoluteTime fp2Now = CFAbsoluteTimeGetCurrent();
        if (!s_fp2Running && (fp2Now - s_fp2LastTime >= 0.5)) {
            s_fp2Running  = YES;
            s_fp2LastTime = fp2Now;

            // ── Main thread: snapshot + crop reference (no pixel copy yet) ───
            CGImageRef screenImg = getScreenImage();
            if (!screenImg) { s_fp2Running = NO; return; }

            size_t imgW = CGImageGetWidth(screenImg);
            size_t imgH = CGImageGetHeight(screenImg);

            const size_t SZ = 60;
            size_t cx = (size_t)(nx * (double)imgW + 0.5);
            size_t cy = (size_t)(ny * (double)imgH + 0.5);
            size_t x0 = (cx >= SZ/2) ? (cx - SZ/2) : 0;
            size_t y0 = (cy >= SZ/2) ? (cy - SZ/2) : 0;
            if (x0 + SZ > imgW) x0 = (imgW >= SZ) ? (imgW - SZ) : 0;
            if (y0 + SZ > imgH) y0 = (imgH >= SZ) ? (imgH - SZ) : 0;
            size_t cropW = (x0 + SZ <= imgW) ? SZ : (imgW - x0);
            size_t cropH = (y0 + SZ <= imgH) ? SZ : (imgH - y0);

            // Creates a sub-image reference; pixel access is deferred to draw time.
            CGImageRef cropImg = CGImageCreateWithImageInRect(screenImg,
                CGRectMake((CGFloat)x0, (CGFloat)y0, (CGFloat)cropW, (CGFloat)cropH));
            CGImageRelease(screenImg);
            if (!cropImg) { s_fp2Running = NO; return; }

            if (shouldLog)
                vcamPickerDiag([NSString stringWithFormat:@"[FP2] crop %zux%zu at (%zu,%zu)",
                    cropW, cropH, x0, y0]);

            BOOL log = shouldLog;
            size_t capturedW = cropW;
            size_t capturedH = cropH;

            // ── Background queue: IOSurface pixel access + hue math ───────────
            // cropImg ownership transferred to block (CF — caller must release).
            dispatch_async(s_q, ^{
                uint8_t *buf = (uint8_t *)calloc(capturedW * capturedH, 4);
                if (buf) {
                    // BGRA 8bpp fixed format — no bitmapInfo detection needed.
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef ctx = CGBitmapContextCreate(buf, capturedW, capturedH, 8,
                        capturedW * 4, cs,
                        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
                    CGColorSpaceRelease(cs);
                    if (ctx) {
                        // IOSurface lock happens here — on background thread, safe.
                        CGContextDrawImage(ctx,
                            CGRectMake(0, 0, (CGFloat)capturedW, (CGFloat)capturedH),
                            cropImg);
                        CGContextRelease(ctx);
                    }
                }
                CGImageRelease(cropImg);

                NSString *diag = nil;
                // BGRA LE: p[0]=B p[1]=G p[2]=R → rOff=2 gOff=1 bOff=0
                // nx=0.5 ny=0.5 → sample center of the 60×60 crop
                double hue = buf ? vcamComputeHueFromRaw(buf, capturedW, capturedH,
                                       capturedW * 4, 4, 2, 1, 0, 0.5f, 0.5f,
                                       log ? &diag : NULL) : -1.0;
                if (buf) free(buf);
                s_fp2Running = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
                    [g_floatButton setRingHue:hue];
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
