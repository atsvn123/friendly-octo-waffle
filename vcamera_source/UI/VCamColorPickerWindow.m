// VCamColorPickerWindow.m

#import "VCamColorPickerWindow.h"
#import "../BINFlash/BINFlashPrefs.h"
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#import <notify.h>
#include <dlfcn.h>
#include <string.h>
#include <math.h>
#include <mach/mach.h>

// ── Circle view (transparent hole, colored ring) ──────────────────────────────

@interface VCamPickerCircleView : UIView
@property (nonatomic, strong) UIColor *ringColor;
@end

@implementation VCamPickerCircleView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _ringColor = [[UIColor colorWithHue:0.33 saturation:1.0 brightness:1.0 alpha:1.0] retain];
    }
    return self;
}

- (void)dealloc {
    [_ringColor release];
    [super dealloc];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat cx = rect.size.width  * 0.5;
    CGFloat cy = rect.size.height * 0.5;
    CGFloat r  = fmin(cx, cy) - 3.0;

    // Clear everything (makes center transparent)
    CGContextClearRect(ctx, rect);

    // White shadow ring for visibility over any background
    CGContextSetLineWidth(ctx, 6.0);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.7].CGColor);
    CGContextAddArc(ctx, cx, cy, r, 0, 2.0 * M_PI, 0);
    CGContextStrokePath(ctx);

    // Colored ring showing current hue
    CGContextSetLineWidth(ctx, 4.0);
    CGContextSetStrokeColorWithColor(ctx, _ringColor.CGColor);
    CGContextAddArc(ctx, cx, cy, r - 1.0, 0, 2.0 * M_PI, 0);
    CGContextStrokePath(ctx);

    // Crosshair
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.9 alpha:0.9].CGColor);
    CGContextMoveToPoint(ctx, cx - 8, cy);
    CGContextAddLineToPoint(ctx, cx + 8, cy);
    CGContextMoveToPoint(ctx, cx, cy - 8);
    CGContextAddLineToPoint(ctx, cx, cy + 8);
    CGContextStrokePath(ctx);
}

@end

// ── Pass-through root view (only hits on the circle pass through) ─────────────

@interface VCamPickerRootView : UIView
@property (nonatomic, assign) UIView *circleView;  // weak
@end

@implementation VCamPickerRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;  // passes through to windows below
    return hit;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// vcamSampleDisplayHue — reads a pixel from the composited display IOSurface
// directly inside SpringBoard via IOMobileFramebuffer (private, dlopen'd) +
// IOSurface (public, linked). Runs entirely in SpringBoard's process; no
// activity in TikTok or any other app — completely invisible to app security
// frameworks.
//
// Returns:
//   [0.0, 1.0)  — hue of the sampled pixel
//   -1.0        — IOSurface working but pixel is achromatic/neutral (skip, no RTMP)
//   -2.0        — IOSurface completely unavailable (caller falls back to RTMP)
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
    static vcam_IOObjectRelease_t s_ioRelease = NULL;
    static dispatch_once_t    s_once       = 0;

    dispatch_once(&s_once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                             RTLD_NOW | RTLD_GLOBAL);
        if (!iokit) return;
        vcam_IOServiceGetMatchingService_t ioGetService =
            (vcam_IOServiceGetMatchingService_t)
            dlsym(iokit, "IOServiceGetMatchingService");
        s_ioRelease =
            (vcam_IOObjectRelease_t)dlsym(iokit, "IOObjectRelease");
        vcam_IOServiceMatching_t ioMatching =
            (vcam_IOServiceMatching_t)dlsym(iokit, "IOServiceMatching");
        if (!ioGetService || !s_ioRelease || !ioMatching) return;

        void *fbLib = dlopen(
            "/System/Library/PrivateFrameworks/"
            "IOMobileFramebuffer.framework/IOMobileFramebuffer",
            RTLD_NOW);
        if (!fbLib) return;
        vcamFBOpen_t fbOpen =
            (vcamFBOpen_t)dlsym(fbLib, "IOMobileFramebufferOpen");
        s_getSurface =
            (vcamFBGetSurface_t)dlsym(fbLib,
                "IOMobileFramebufferGetLayerDefaultSurface");
        if (!fbOpen || !s_getSurface) return;

        // Try both iOS 15 and iOS 16+ service names.
        const char *names[] = {
            "IOMobileFramebuffer", "IOMobileFramebufferShim", NULL
        };
        for (int i = 0; names[i] && !s_fb; i++) {
            CFMutableDictionaryRef m = ioMatching(names[i]);
            if (!m) continue;
            vcam_io_service_t svc =
                ioGetService(0 /* kIOMasterPortDefault */, m);
            if (!svc) continue;
            fbOpen(svc, mach_task_self(), 0, &s_fb);
            s_ioRelease(svc);
        }
    });

    if (!s_fb || !s_getSurface) return -2.0;  // hardware unavailable → RTMP fallback

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
    // iOS display framebuffer: BGRA byte order  [0]=B [1]=G [2]=R [3]=A
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

// ── Color picker window ───────────────────────────────────────────────────────

@interface VCamColorPickerWindow () {
    VCamPickerCircleView        *_circleView;
    NSTimer                     *_sampleTimer;
    CGPoint                      _touchOffset;
    UIPanGestureRecognizer       *_panGesture;
}
@end

@implementation VCamColorPickerWindow

// Pass through all touches that don't hit the circle itself.
// Without this override, UIView's default hitTest returns self (the window) when
// no subview claims the touch — blocking every touch from reaching lower windows.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == nil || hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

+ (instancetype)sharedWindow {
    static VCamColorPickerWindow *s_window = nil;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{
        s_window = [[VCamColorPickerWindow alloc]
                    initWithFrame:[UIScreen mainScreen].bounds];
    });
    return s_window;
}

- (instancetype)initWithFrame:(CGRect)frame {
    // iOS 13+: UIWindows without a UIWindowScene are invisible in SpringBoard.
    UIWindowScene *scene = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
        if (!scene) scene = (UIWindowScene *)sc;
    }
    if (scene) {
        self = [super initWithWindowScene:scene];
        if (self) self.frame = frame;
    } else {
        self = [super initWithFrame:frame];
    }
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.windowLevel = UIWindowLevelStatusBar + 8000.0;
        self.hidden = YES;

        VCamPickerRootView *root = [[VCamPickerRootView alloc] initWithFrame:frame];
        root.backgroundColor = [UIColor clearColor];

        // Start circle at screen center
        CGFloat d = 64.0;
        CGFloat cx = frame.size.width  * 0.5;
        CGFloat cy = frame.size.height * 0.45;
        _circleView = [[VCamPickerCircleView alloc] initWithFrame:
                       CGRectMake(cx - d*0.5, cy - d*0.5, d, d)];
        _circleView.userInteractionEnabled = YES;

        // Drag gesture — retained so setDraggable: can toggle it
        _panGesture = [[UIPanGestureRecognizer alloc]
                       initWithTarget:self action:@selector(handlePan:)];
        [_circleView addGestureRecognizer:_panGesture];

        root.circleView = _circleView;
        [root addSubview:_circleView];
        self.rootViewController = [[UIViewController alloc] init];
        self.rootViewController.view = root;
        [root release];
    }
    return self;
}

- (void)dealloc {
    [_circleView release];
    [_panGesture release];
    [_sampleTimer invalidate];
    [_sampleTimer release];
    [super dealloc];
}

// notify tokens — static, registered once for the lifetime of the picker
static int s_reqToken  = NOTIFY_TOKEN_INVALID;
static int s_respToken = NOTIFY_TOKEN_INVALID;

- (void)showPicker {
    self.hidden = NO;
    _panGesture.enabled = YES;

    // Register request-post token once (used only to set state before posting).
    if (s_reqToken == NOTIFY_TOKEN_INVALID) {
        notify_register_check("com.vcam.samplerequest", &s_reqToken);
    }

    // Register response listener once — only needed when IOSurface direct
    // sampling is unavailable and the RTMP fallback path fires.
    if (s_respToken == NOTIFY_TOKEN_INVALID) {
        VCamColorPickerWindow *bSelf = self;  // singleton, never deallocated
        notify_register_dispatch(
            "com.vcam.sampleresponse",
            &s_respToken,
            dispatch_get_main_queue(),
            ^(int token) {
                if (bSelf.hidden) return;  // picker was hidden, ignore stale response

                uint64_t state = 0;
                notify_get_state(token, &state);
                uint32_t hueBits = (uint32_t)(state & 0xFFFFFFFFULL);
                float hf = 0.0f;
                memcpy(&hf, &hueBits, 4);
                double h = (double)hf;
                if (h < 0.0 || h > 1.0) return;

                // Update ring to reflect sampled hue
                bSelf->_circleView.ringColor =
                    [UIColor colorWithHue:h saturation:1.0 brightness:1.0 alpha:1.0];
                [bSelf->_circleView setNeedsDisplay];

                // Persist hue for flash effect in mediaserverd
                BINFlashSavePrefs(@{ kBINFlashKeyHue: @(h) });
            });
    }

    if (!_sampleTimer) {
        _sampleTimer = [[NSTimer scheduledTimerWithTimeInterval:0.35
                                                         target:self
                                                       selector:@selector(sampleTick)
                                                       userInfo:nil
                                                        repeats:YES] retain];
    }
}

- (void)hidePicker {
    [_sampleTimer invalidate];
    [_sampleTimer release];
    _sampleTimer = nil;
    _panGesture.enabled = NO;
    self.hidden = YES;
}

- (void)setDraggable:(BOOL)draggable {
    _panGesture.enabled = draggable;
}

// ── Drag ──────────────────────────────────────────────────────────────────────
- (void)handlePan:(UIPanGestureRecognizer *)gr {
    CGPoint translation = [gr translationInView:self.rootViewController.view];
    CGPoint center = _circleView.center;
    center.x += translation.x;
    center.y += translation.y;

    CGFloat margin = 40.0;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    center.x = fmax(margin, fmin(sw - margin, center.x));
    center.y = fmax(margin, fmin(sh - margin, center.y));

    _circleView.center = center;
    [gr setTranslation:CGPointZero inView:self.rootViewController.view];
}

// ── Sample tick ───────────────────────────────────────────────────────────────
- (void)sampleTick {
    CGPoint pt = _circleView.center;

    // Primary: read composited display IOSurface directly in SpringBoard.
    // Returns >= 0  → colored pixel found
    //         -1.0  → IOSurface working but pixel is grey/neutral → skip (no RTMP)
    //         -2.0  → IOSurface unavailable → use RTMP fallback
    double hue = vcamSampleDisplayHue(pt);
    if (hue >= 0.0) {
        _circleView.ringColor = [UIColor colorWithHue:(CGFloat)hue
                                           saturation:1.0 brightness:1.0 alpha:1.0];
        [_circleView setNeedsDisplay];
        BINFlashSavePrefs(@{ kBINFlashKeyHue: @(hue) });
        return;
    }
    if (hue > -1.5) return;  // -1.0: achromatic pixel, IOSurface is fine — do nothing

    // -2.0: IOSurface completely unavailable → Darwin notify → RTMP fallback.
    if (s_reqToken == NOTIFY_TOKEN_INVALID) return;
    CGSize sz = [UIScreen mainScreen].bounds.size;
    if (sz.width <= 0.0 || sz.height <= 0.0) return;
    float xf = (float)(pt.x / sz.width);
    float yf = (float)(pt.y / sz.height);
    uint32_t xBits = 0, yBits = 0;
    memcpy(&xBits, &xf, 4);
    memcpy(&yBits, &yf, 4);
    notify_set_state(s_reqToken, ((uint64_t)xBits << 32) | (uint64_t)yBits);
    notify_post("com.vcam.samplerequest");
    // Response arrives asynchronously in the handler registered in showPicker.
}

@end
