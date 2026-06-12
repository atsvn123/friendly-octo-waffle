// BINFlashCameraHooks.m
// Reconstructed from:
//   sub_4270 (0x4270) — MSHookFunction C hooks
//   sub_42F0 (0x42F0) — MSHookMessageEx VCamLiveManager hooks
//   sub_65C0 (0x65C0) — GPUImage method_setImplementation swizzles
//   sub_44F8 (0x44F8) — CMSampleBufferGetImageBuffer replacement
//   sub_4538 (0x4538) — CMSampleBufferCreateCopy replacement
//   sub_4588 (0x4588) — CMSampleBufferCreateForImageBuffer replacement
//   sub_61D8 (0x61D8) — modifyPixelBuffer: hook
//   sub_6260 (0x6260) — modifyImageBuffer: hook
//   sub_62E8 (0x62E8) — createSampleBuffer: hook
//   sub_6368 (0x6368) — getSampleBuffer: hook
//   sub_63E8 (0x63E8) — get90SampleBuffer: hook
//   sub_6468 (0x6468) — setYUVPixelBuffer: hook
//   sub_64D8 (0x64D8) — setYUVSampleBuffer: hook
//   sub_654C (0x654C) — setBGRASampleBuffer: hook
//   sub_66E4 (0x66E4) — setWhite: swizzle (suppresses original)
//   sub_678C (0x678C) — setUniformsWithLandmarks: swizzle (face tracking)

#import "BINFlashCameraHooks.h"
#import "../Effect/BINFlashPixelEffect.h"
#import "../Prefs/BINFlashCameraPrefs.h"
#import "../FaceRegion/BINFlashFaceRegion.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <substrate.h>

// ── Guard flags ──
BOOL g_vcamHooksOk      = NO;  // byte_C2D8
BOOL g_coreMediaHooksOk = NO;  // byte_C2D9
BOOL g_gpuImageHooksOk  = NO;  // byte_C370

// ══════════════════════════════════════════════════════════════════════
// SECTION A — MSHookFunction on CoreMedia C functions (sub_4270)
// ══════════════════════════════════════════════════════════════════════

// Original function pointers (off_C2E0, off_C2E8, off_C2F0)
static CVImageBufferRef (*orig_GetImageBuffer)(CMSampleBufferRef)                    = NULL;
static OSStatus (*orig_CreateCopy)(CFAllocatorRef, CMSampleBufferRef, CMSampleBufferRef *) = NULL;

// CMSampleBufferCreateForImageBuffer takes 8 arguments.
// All 8 must be declared so ARM64 calling convention places X0–X7 correctly.
// Using void* for callback/refcon avoids importing CMSampleBufferMakeDataReadyCallback.
typedef OSStatus (*CMSampleBufferCreateForImageBufferFn)(
    CFAllocatorRef,
    CVImageBufferRef,
    Boolean,
    void *,
    void *,
    CMVideoFormatDescriptionRef,
    const CMSampleTimingInfo *,
    CMSampleBufferRef *);
static CMSampleBufferCreateForImageBufferFn orig_CreateForImageBuffer = NULL;

// sub_44F8 — CMSampleBufferGetImageBuffer hook
static CVImageBufferRef BINFlash_hook_GetImageBuffer(CMSampleBufferRef sbuf) {
    CVImageBufferRef ib = orig_GetImageBuffer(sbuf);
    BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    return ib;
}

// sub_4538 — CMSampleBufferCreateCopy hook
static OSStatus BINFlash_hook_CreateCopy(CFAllocatorRef alloc,
                                          CMSampleBufferRef sbuf,
                                          CMSampleBufferRef *outSbuf) {
    OSStatus err = orig_CreateCopy(alloc, sbuf, outSbuf);
    if (err == 0 && outSbuf && *outSbuf) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer(*outSbuf);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    return err;
}

// sub_4588 — CMSampleBufferCreateForImageBuffer hook
// CRASH FIX (v2.47): must declare ALL 8 parameters so ARM64 ABI maps X0–X7 into
// local variables. With only 5 params declared, BINFlashApplyToPixelBuffer() clobbers
// X5–X7 (fmtDesc, timing, outSbuf) and the original receives garbage — the corrupted
// outSbuf pointer causes a SIGSEGV the moment the camera pipeline calls this during
// camera setup, before BWNodeOutput::emitSampleBuffer: ever fires.
static OSStatus BINFlash_hook_CreateForImageBuffer(
    CFAllocatorRef alloc,
    CVImageBufferRef imageBuffer,
    Boolean dataReady,
    void *callback,
    void *refcon,
    CMVideoFormatDescriptionRef fmtDesc,
    const CMSampleTimingInfo *timing,
    CMSampleBufferRef *outSbuf)
{
    BINFlashApplyToPixelBuffer((CVPixelBufferRef)imageBuffer);
    return orig_CreateForImageBuffer(alloc, imageBuffer, dataReady, callback, refcon,
                                     fmtDesc, timing, outSbuf);
}

// sub_4270 — installs MSHookFunction on all three CoreMedia functions
void BINFlashInstallCoreMHooks(void) {
    if (g_coreMediaHooksOk) return;

    MSHookFunction((void *)CMSampleBufferGetImageBuffer,
                   (void *)BINFlash_hook_GetImageBuffer,
                   (void **)&orig_GetImageBuffer);

    MSHookFunction((void *)CMSampleBufferCreateCopy,
                   (void *)BINFlash_hook_CreateCopy,
                   (void **)&orig_CreateCopy);

    MSHookFunction((void *)CMSampleBufferCreateForImageBuffer,
                   (void *)BINFlash_hook_CreateForImageBuffer,
                   (void **)&orig_CreateForImageBuffer);

    if (orig_GetImageBuffer && orig_CreateCopy && orig_CreateForImageBuffer)
        g_coreMediaHooksOk = YES;
}


// ══════════════════════════════════════════════════════════════════════
// SECTION B — MSHookMessageEx on VCamLiveManager (sub_42F0)
// ══════════════════════════════════════════════════════════════════════
// VCamLiveManager class name is obfuscated as "ifdsflwoWdasdYfsdfJd".
// It is defined in vcamera.dylib. MSHookMessageEx resolves via the ObjC
// runtime, so it works as long as vcamera.dylib has been loaded first.

// Saved original IMPs (off_C330 through off_C368)
static IMP orig_modifyPixelBuffer    = NULL;
static IMP orig_modifyImageBuffer    = NULL;
static IMP orig_createSampleBuffer   = NULL;
static IMP orig_getSampleBuffer      = NULL;
static IMP orig_get90SampleBuffer    = NULL;
static IMP orig_setYUVPixelBuffer    = NULL;
static IMP orig_setYUVSampleBuffer   = NULL;
static IMP orig_setBGRASampleBuffer  = NULL;

// sub_61D8 — modifyPixelBuffer: hook
// Pattern: call original first, then get image buffer, apply effect
static id BINFlash_hook_modifyPixelBuffer(id self, SEL cmd, id arg) {
    id result = ((id (*)(id, SEL, id))orig_modifyPixelBuffer)(self, cmd, arg);
    if (result) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)result);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    return result;
}

// sub_6260 — modifyImageBuffer: hook (identical pattern)
static id BINFlash_hook_modifyImageBuffer(id self, SEL cmd, id arg) {
    id result = ((id (*)(id, SEL, id))orig_modifyImageBuffer)(self, cmd, arg);
    if (result) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)result);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    return result;
}

// sub_62E8 — createSampleBuffer: hook
static id BINFlash_hook_createSampleBuffer(id self, SEL cmd, id arg) {
    id result = ((id (*)(id, SEL, id))orig_createSampleBuffer)(self, cmd, arg);
    if (result) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)result);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    return result;
}

// sub_6368 — getSampleBuffer: hook
static id BINFlash_hook_getSampleBuffer(id self, SEL cmd, id arg) {
    id result = ((id (*)(id, SEL, id))orig_getSampleBuffer)(self, cmd, arg);
    if (result) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)result);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    return result;
}

// sub_63E8 — get90SampleBuffer: hook
static id BINFlash_hook_get90SampleBuffer(id self, SEL cmd, id arg) {
    id result = ((id (*)(id, SEL, id))orig_get90SampleBuffer)(self, cmd, arg);
    if (result) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)result);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    return result;
}

// sub_6468 — setYUVPixelBuffer: hook
// Receives CVPixelBuffer directly (not CMSampleBuffer)
// Effect applied BEFORE calling original
static void BINFlash_hook_setYUVPixelBuffer(id self, SEL cmd, CVPixelBufferRef pixbuf) {
    BINFlashApplyToPixelBuffer(pixbuf);
    ((void (*)(id, SEL, CVPixelBufferRef))orig_setYUVPixelBuffer)(self, cmd, pixbuf);
}

// sub_64D8 — setYUVSampleBuffer: hook
// Effect applied BEFORE calling original
static void BINFlash_hook_setYUVSampleBuffer(id self, SEL cmd, id sbuf) {
    if (sbuf) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)sbuf);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    ((void (*)(id, SEL, id))orig_setYUVSampleBuffer)(self, cmd, sbuf);
}

// sub_654C — setBGRASampleBuffer: hook (same as setYUVSampleBuffer:)
static void BINFlash_hook_setBGRASampleBuffer(id self, SEL cmd, id sbuf) {
    if (sbuf) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer((CMSampleBufferRef)sbuf);
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)ib);
    }
    ((void (*)(id, SEL, id))orig_setBGRASampleBuffer)(self, cmd, sbuf);
}

// sub_42F0 — installs 8 MSHookMessageEx hooks on VCamLiveManager
void BINFlashInstallVCamHooks(void) {
    if (g_vcamHooksOk) return;

    Class cls = objc_getClass("ifdsflwoWdasdYfsdfJd");
    if (!cls) return;

    MSHookMessageEx(cls, @selector(modifyPixelBuffer:),   (IMP)BINFlash_hook_modifyPixelBuffer,   &orig_modifyPixelBuffer);
    MSHookMessageEx(cls, @selector(modifyImageBuffer:),   (IMP)BINFlash_hook_modifyImageBuffer,   &orig_modifyImageBuffer);
    MSHookMessageEx(cls, @selector(createSampleBuffer:),  (IMP)BINFlash_hook_createSampleBuffer,  &orig_createSampleBuffer);
    MSHookMessageEx(cls, @selector(getSampleBuffer:),     (IMP)BINFlash_hook_getSampleBuffer,     &orig_getSampleBuffer);
    MSHookMessageEx(cls, @selector(get90SampleBuffer:),   (IMP)BINFlash_hook_get90SampleBuffer,   &orig_get90SampleBuffer);
    MSHookMessageEx(cls, @selector(setYUVPixelBuffer:),   (IMP)BINFlash_hook_setYUVPixelBuffer,   &orig_setYUVPixelBuffer);
    MSHookMessageEx(cls, @selector(setYUVSampleBuffer:),  (IMP)BINFlash_hook_setYUVSampleBuffer,  &orig_setYUVSampleBuffer);
    MSHookMessageEx(cls, @selector(setBGRASampleBuffer:), (IMP)BINFlash_hook_setBGRASampleBuffer, &orig_setBGRASampleBuffer);

    // Confirm at least one hook succeeded
    if (orig_modifyPixelBuffer)
        g_vcamHooksOk = YES;
}


// ══════════════════════════════════════════════════════════════════════
// SECTION C — method_setImplementation GPUImage swizzles (sub_65C0)
// ══════════════════════════════════════════════════════════════════════

// Saved original IMPs (off_C388, off_C390)
static IMP orig_setWhite              = NULL;  // off_C388
static IMP orig_setUniformsWithLandmarks = NULL; // off_C390

// sub_66E4 — swizzled GPUImageBaseBeautyFaceFilter::setWhite:
// Forces 0.0 to suppress the app's own beauty white value.
// (Real brightness is applied directly to pixels in BINFlashApplyToPixelBuffer)
static void BINFlash_hook_setWhite(id self, SEL cmd, double white) {
    // Refresh prefs state
    BINFlashCameraLoadPrefs();
    // Call original with 0.0 — neutralize app's brightness request
    if (orig_setWhite)
        ((void (*)(id, SEL, double))orig_setWhite)(self, cmd, 0.0);
}

// sub_678C — swizzled GPUImageThinFaceFilter::setUniformsWithLandmarks:
// Extracts face bounding box from landmark array, stores globally,
// then calls original (with white suppressed).
static void BINFlash_hook_setUniformsWithLandmarks(id self, SEL cmd, NSArray *landmarks) {
    BINFlashUpdateFaceFromLandmarks(landmarks);

    // Suppress original white effect (same as BINFlash_hook_setWhite)
    if (orig_setWhite)
        ((void (*)(id, SEL, double))orig_setWhite)(self, @selector(setWhite:), 0.0);

    // Call original setUniformsWithLandmarks:
    if (orig_setUniformsWithLandmarks)
        ((void (*)(id, SEL, NSArray *))orig_setUniformsWithLandmarks)(self, cmd, landmarks);
}

// sub_65C0 — install GPUImage swizzles via method_setImplementation
void BINFlashInstallGPUImageSwizzles(void) {
    if (g_gpuImageHooksOk) return;

    // Try base class first (some builds use GPUImageBeautyFaceFilter directly)
    Class beautyClass = objc_getClass("GPUImageBaseBeautyFaceFilter");
    if (!beautyClass)
        beautyClass = objc_getClass("GPUImageBeautyFaceFilter");

    if (beautyClass) {
        Method m = class_getInstanceMethod(beautyClass, @selector(setWhite:));
        if (m) {
            orig_setWhite = method_setImplementation(m, (IMP)BINFlash_hook_setWhite);
        }
    }

    Class thinFaceClass = objc_getClass("GPUImageThinFaceFilter");
    if (thinFaceClass) {
        Method m = class_getInstanceMethod(thinFaceClass, @selector(setUniformsWithLandmarks:));
        if (m) {
            orig_setUniformsWithLandmarks = method_setImplementation(
                m, (IMP)BINFlash_hook_setUniformsWithLandmarks);
        }
    }

    if (orig_setWhite && orig_setUniformsWithLandmarks)
        g_gpuImageHooksOk = YES;
}
