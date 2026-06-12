// BINFlashEffectBridge.m
// Reconstructed from:
//   BINFlashEffectBridge::tick       (0xB094)
//   sub_B394                         (0xB394) — white value computation
//   sub_C924                         (0xC924) — swizzled setWhite:
//   sub_CA08                         (0xCA08) — swizzled setUniformsWithLandmarks:
//   off_15E30                        — saved IMP for original setWhite:
//   off_15E50                        — saved IMP for original setUniformsWithLandmarks:

#import "BINFlashEffectBridge.h"
#import "../Prefs/BINFlashPrefs.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// Saved original IMPs (mirrors off_15E30 and off_15E50 globals in binary)
static IMP s_origSetWhite = NULL;
static IMP s_origSetUniformsWithLandmarks = NULL;

// Forward declarations for the swizzle functions
static void BINFlash_hook_setWhite(id self, SEL cmd, double white);
static void BINFlash_hook_setUniformsWithLandmarks(id self, SEL cmd, id landmarks);

// --- sub_B394 (0xB394) ---
// Computes the flash white value to apply to beauty filters.
// Returns NaN if flash is disabled (caller should skip setWhite: in that case).
// Returns 0.0 during the "off" half of the flash cycle.
static double BINFlash_computeWhite(NSDictionary *prefs) {
    if (!BINFlashBoolForKey(prefs, kBINFlashKeyFlash, kBINFlashDefaultFlash))
        return NAN;

    double speed      = BINFlashDoubleForKey(prefs, kBINFlashKeySpeed,      kBINFlashDefaultSpeed);
    double brightness = BINFlashDoubleForKey(prefs, kBINFlashKeyBrightness, kBINFlashDefaultBrightness);
    double region     = BINFlashDoubleForKey(prefs, kBINFlashKeyRegion,     kBINFlashDefaultRegion);

    double time = CACurrentMediaTime();

    // 50% duty-cycle square wave: fmod(max(speed,0.5) * time, 1.0) < 0.5
    if (fmod(fmax(speed, 0.5) * time, 1.0) < 0.5) {
        double b = fmax(fmin(brightness / 100.0, 1.0), 0.0);
        double r = fmax(fmin(region     / 100.0, 1.0), 0.1);
        return fmax(fmin(b * (r * 0.45 + 0.7), 1.0), 0.0);
    }
    return 0.0;
}

@implementation BINFlashEffectBridge {
    NSHashTable *_filters;      // weak references — mirrors BINFlashEffectBridge ivar
}

+ (instancetype)shared {
    static BINFlashEffectBridge *s_instance = nil;
    static dispatch_once_t s_once = 0;
    dispatch_once(&s_once, ^{
        s_instance = [[BINFlashEffectBridge alloc] init];
    });
    return s_instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _filters = [[NSHashTable weakObjectsHashTable] retain];  // MRC: must retain; autorelease without retain → dangling pointer → crash in tick
    }
    return self;
}

// --- BINFlashEffectBridge::tick (0xB094) ---
- (void)tick {
    static dispatch_once_t s_swizzleOnce = 0;
    dispatch_once(&s_swizzleOnce, ^{
        // Swizzle GPUImageBaseBeautyFaceFilter::setWhite:
        Class cls = NSClassFromString(@"GPUImageBaseBeautyFaceFilter");
        if (cls) {
            Method m = class_getInstanceMethod(cls, @selector(setWhite:));
            if (m) {
                s_origSetWhite = method_getImplementation(m);
                method_setImplementation(m, (IMP)BINFlash_hook_setWhite);
            }

            // Swizzle GPUImageBaseBeautyFaceFilter::setUniformsWithLandmarks:
            Method m2 = class_getInstanceMethod(cls, @selector(setUniformsWithLandmarks:));
            if (m2) {
                s_origSetUniformsWithLandmarks = method_getImplementation(m2);
                method_setImplementation(m2, (IMP)BINFlash_hook_setUniformsWithLandmarks);
            }
        }
    });

    NSDictionary *prefs = BINFlashLoadPrefs();
    double white = BINFlash_computeWhite(prefs);

    // Apply to all registered filters via the swizzled method (IDA confirmed).
    // objc_msgSend dispatches through the swizzled IMP (BINFlash_hook_setWhite).
    for (id filter in _filters) {
        ((void (*)(id, SEL, double))objc_msgSend)(filter, @selector(setWhite:), white);
    }
}

- (void)registerFilter:(id)filter {
    if (filter)
        [_filters addObject:filter];
}

- (void)dealloc {
    [_filters release];
    [super dealloc];
}

@end

// --- sub_C924 (0xC924) ---
// Replacement for GPUImageBaseBeautyFaceFilter::setWhite:
// Intercepts the call, registers the filter, overrides white with flash value.
static void BINFlash_hook_setWhite(id self, SEL cmd, double __unused white) {
    // Register this filter instance in the bridge's weak table
    [[BINFlashEffectBridge shared] registerFilter:self];

    // Compute the current flash white value and apply it via the original IMP
    NSDictionary *prefs = BINFlashLoadPrefs();
    double flashWhite = BINFlash_computeWhite(prefs);

    if (s_origSetWhite)
        ((void (*)(id, SEL, double))s_origSetWhite)(self, cmd, flashWhite);
}

// --- sub_CA08 (0xCA08) ---
// Replacement for GPUImageBaseBeautyFaceFilter::setUniformsWithLandmarks:
// Called per-frame when the GPU pipeline uploads uniforms.
// Registers the filter, syncs white level, then calls original for landmark processing.
static void BINFlash_hook_setUniformsWithLandmarks(id self, SEL cmd, id landmarks) {
    // Register filter
    [[BINFlashEffectBridge shared] registerFilter:self];

    // Apply current flash white level before uploading uniforms
    if (s_origSetWhite) {
        NSDictionary *prefs = BINFlashLoadPrefs();
        double flashWhite = BINFlash_computeWhite(prefs);
        ((void (*)(id, SEL, double))s_origSetWhite)(self, @selector(setWhite:), flashWhite);
    }

    // Call original setUniformsWithLandmarks: so landmark processing continues
    if (s_origSetUniformsWithLandmarks)
        ((void (*)(id, SEL, id))s_origSetUniformsWithLandmarks)(self, cmd, landmarks);
}
