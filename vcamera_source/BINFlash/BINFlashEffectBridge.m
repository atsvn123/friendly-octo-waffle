// BINFlashEffectBridge.m
// Reconstructed from BINFlashEffectBridge + sub_B394 + sub_C924 + sub_CA08
// Updated for merged vcamera.dylib: import flat.

#import "BINFlashEffectBridge.h"
#import "BINFlashPrefs.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static IMP s_origSetWhite = NULL;
static IMP s_origSetUniformsWithLandmarks = NULL;

static void BINFlash_hook_setWhite(id self, SEL cmd, double white);
static void BINFlash_hook_setUniformsWithLandmarks(id self, SEL cmd, id landmarks);

// sub_B394 — compute flash white level for beauty filter
static double BINFlash_computeWhite(NSDictionary *prefs) {
    if (!BINFlashBoolForKey(prefs, kBINFlashKeyFlash, kBINFlashDefaultFlash))
        return NAN;

    double speed      = BINFlashDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    double brightness = BINFlashDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    double region     = BINFlashDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);

    double time = CACurrentMediaTime();
    if (fmod(fmax(speed, 0.5) * time, 1.0) < 0.5) {
        double b = fmax(fmin(brightness / 100.0, 1.0), 0.0);
        double r = fmax(fmin(region     / 100.0, 1.0), 0.1);
        return fmax(fmin(b * (r * 0.45 + 0.7), 1.0), 0.0);
    }
    return 0.0;
}

@implementation BINFlashEffectBridge {
    NSHashTable *_filters;
}

+ (instancetype)shared {
    static BINFlashEffectBridge *s_instance = nil;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{ s_instance = [[BINFlashEffectBridge alloc] init]; });
    return s_instance;
}

- (instancetype)init {
    self = [super init];
    if (self) _filters = [[NSHashTable weakObjectsHashTable] retain];
    return self;
}

- (void)tick {
    static dispatch_once_t s_swizzleOnce = 0;
    dispatch_once(&s_swizzleOnce, ^{
        Class cls = NSClassFromString(@"GPUImageBaseBeautyFaceFilter");
        if (cls) {
            Method m = class_getInstanceMethod(cls, @selector(setWhite:));
            if (m) {
                s_origSetWhite = method_getImplementation(m);
                method_setImplementation(m, (IMP)BINFlash_hook_setWhite);
            }
            Method m2 = class_getInstanceMethod(cls, @selector(setUniformsWithLandmarks:));
            if (m2) {
                s_origSetUniformsWithLandmarks = method_getImplementation(m2);
                method_setImplementation(m2, (IMP)BINFlash_hook_setUniformsWithLandmarks);
            }
        }
    });

    NSDictionary *prefs = BINFlashLoadPrefs();
    double white = BINFlash_computeWhite(prefs);

    for (id filter in _filters)
        ((void (*)(id, SEL, double))objc_msgSend)(filter, @selector(setWhite:), white);
}

- (void)registerFilter:(id)filter {
    if (filter) [_filters addObject:filter];
}

- (void)dealloc {
    [_filters release];
    [super dealloc];
}

@end

// sub_C924
static void BINFlash_hook_setWhite(id self, SEL cmd, double __unused white) {
    [[BINFlashEffectBridge shared] registerFilter:self];
    NSDictionary *prefs = BINFlashLoadPrefs();
    double flashWhite = BINFlash_computeWhite(prefs);
    if (s_origSetWhite)
        ((void (*)(id, SEL, double))s_origSetWhite)(self, cmd, flashWhite);
}

// sub_CA08
static void BINFlash_hook_setUniformsWithLandmarks(id self, SEL cmd, id landmarks) {
    [[BINFlashEffectBridge shared] registerFilter:self];
    if (s_origSetWhite) {
        NSDictionary *prefs = BINFlashLoadPrefs();
        ((void (*)(id, SEL, double))s_origSetWhite)(self, @selector(setWhite:),
                                                    BINFlash_computeWhite(prefs));
    }
    if (s_origSetUniformsWithLandmarks)
        ((void (*)(id, SEL, id))s_origSetUniformsWithLandmarks)(self, cmd, landmarks);
}
