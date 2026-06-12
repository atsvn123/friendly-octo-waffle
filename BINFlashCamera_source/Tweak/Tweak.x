// Tweak.x
// Reconstructed from InitFunc_0 (0x416C) and stru_8100 GCD timer block
//
// BINFlashCamera.dylib entry point.
// Uses three distinct hook mechanisms:
//   1. MSHookFunction on CoreMedia C functions (sub_4270)
//   2. method_setImplementation on GPUImage ObjC classes (sub_65C0)
//   3. MSHookMessageEx on VCamLiveManager from vcamera.dylib (sub_42F0)
//
// The GCD retry timer fires every 500ms until all three hook sets succeed.
// This is necessary because vcamera.dylib (which defines VCamLiveManager)
// and GPUImage may not be loaded at constructor time.

#import "../Hooks/BINFlashCameraHooks.h"
#import <substrate.h>
#import <dispatch/dispatch.h>

// --- Guard flags (set by each install function on success) ---
extern BOOL g_vcamHooksOk;       // byte_C2D8: VCamLiveManager hooks
extern BOOL g_coreMediaHooksOk;  // byte_C2D9: CMSampleBuffer C hooks
extern BOOL g_gpuImageHooksOk;   // byte_C370: GPUImage swizzles

static dispatch_source_t s_retryTimer = nil;

static void BINFlashCamera_TryInstall(void) {
    BINFlashInstallCoreMHooks();    // sub_4270 — MSHookFunction
    BINFlashInstallGPUImageSwizzles(); // sub_65C0 — method_setImplementation
    BINFlashInstallVCamHooks();     // sub_42F0 — MSHookMessageEx
}

// Timer event handler — sub-8100 block
static void BINFlashCamera_RetryTick(void) {
    BINFlashCamera_TryInstall();
    if (g_vcamHooksOk && g_gpuImageHooksOk && g_coreMediaHooksOk) {
        if (s_retryTimer) {
            dispatch_source_cancel(s_retryTimer);
            s_retryTimer = nil;
        }
    }
}

// --- InitFunc_0 (0x416C) ---
// Called by __mod_init_func immediately after dylib load.
__attribute__((constructor))
static void BINFlashCamera_Init(void) {
    // Initial installation attempt
    BINFlashCamera_TryInstall();

    // If any hook set failed, start 500ms retry timer
    if (!g_vcamHooksOk || !g_gpuImageHooksOk || !g_coreMediaHooksOk) {
        dispatch_queue_t bgq = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, bgq);
        s_retryTimer = timer;

        // initial=500ms, interval=500ms (0x1DCD6500 ns), leeway=100ms (0x5F5E100 ns)
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
            500 * NSEC_PER_MSEC,
            100 * NSEC_PER_MSEC);

        dispatch_source_set_event_handler(timer, ^{
            BINFlashCamera_RetryTick();
        });
        dispatch_resume(timer);
    }
}
