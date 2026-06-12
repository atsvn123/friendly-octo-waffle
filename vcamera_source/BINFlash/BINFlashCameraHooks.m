// BINFlashCameraHooks.m
// GPUImage swizzles for mediaserverd.
//
// CMSampleBuffer MSHookFunction hooks removed: BINFlashApplyToPixelBuffer is
// now called directly from VCamLiveManager::modifyImageBuffer: after
// VTPixelTransferSessionTransferImage, which guarantees it runs exactly once
// per frame on the RTMP content (not the camera frame that gets overwritten).

#import "BINFlashCameraHooks.h"
#import "BINFlashPixelEffect.h"
#import "BINFlashFaceRegion.h"
#import "BINFlashPrefs.h"
#import <objc/runtime.h>
#import <substrate.h>

BOOL g_gpuImageHooksOk = NO;

// ══════════════════════════════════════════════════════════════════════
// GPUImage method_setImplementation swizzles
// setWhite: suppresses the app's beauty white value (prevents double-brightening).
// setUniformsWithLandmarks: extracts face position for targeted brightening.
// ══════════════════════════════════════════════════════════════════════

static IMP orig_setWhite = NULL;
static IMP orig_setUniformsWithLandmarks = NULL;

static void BINFlash_swizzle_setWhite(id self, SEL cmd, double white) {
    (void)white;
    // Suppress app's brightness — BINFlash applies its own via pixel effect
    if (orig_setWhite)
        ((void (*)(id, SEL, double))orig_setWhite)(self, cmd, 0.0);
}

static void BINFlash_swizzle_setUniformsWithLandmarks(id self, SEL cmd, NSArray *landmarks) {
    BINFlashUpdateFaceFromLandmarks(landmarks);
    if (orig_setWhite)
        ((void (*)(id, SEL, double))orig_setWhite)(self, @selector(setWhite:), 0.0);
    if (orig_setUniformsWithLandmarks)
        ((void (*)(id, SEL, NSArray *))orig_setUniformsWithLandmarks)(self, cmd, landmarks);
}

static void installGPUImageSwizzles(void) {
    if (g_gpuImageHooksOk) return;

    Class beautyClass = objc_getClass("GPUImageBaseBeautyFaceFilter");
    if (!beautyClass) beautyClass = objc_getClass("GPUImageBeautyFaceFilter");

    if (beautyClass) {
        Method m = class_getInstanceMethod(beautyClass, @selector(setWhite:));
        if (m) orig_setWhite = method_setImplementation(m, (IMP)BINFlash_swizzle_setWhite);
    }

    Class thinFaceClass = objc_getClass("GPUImageThinFaceFilter");
    if (thinFaceClass) {
        Method m = class_getInstanceMethod(thinFaceClass, @selector(setUniformsWithLandmarks:));
        if (m) orig_setUniformsWithLandmarks =
                   method_setImplementation(m, (IMP)BINFlash_swizzle_setUniformsWithLandmarks);
    }

    if (orig_setWhite && orig_setUniformsWithLandmarks)
        g_gpuImageHooksOk = YES;
}

// ── Public entry point ─────────────────────────────────────────────────────────
void installBINFlashMediaHooks(void) {
    installGPUImageSwizzles();
}
