// MediaServerHooks.m
// Reconstructed from sub_852B4 (0x852B4)
// Hooks on Apple private BW*/Fig* classes in mediaserverd

#import "MediaServerHooks.h"
#import <substrate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import "../VCamBridge/VCamBridge.h"
#import "../VCamLive/VCamLiveManager.h"

// ============================================================
// Original IMP trampolines
// Only the hooks with real logic need trampolines.
// Pure-passthrough hooks from the original binary are not
// re-installed here — they have no side effects.
// ============================================================

// BWNodeOutput — CORE HOOK
static IMP orig_emitSampleBuffer = NULL;

// BWAmbientLightSensor (hooked in SpringBoard process — class lives in SpringBoard, not mediaserverd)
// These hooks are installed by installSpringBoardHooks(), not here.
// Definitions kept for reference only — see SpringBoardHooks.m

// g_lastResolutionUpdate is defined in VCamBridge.m
extern double g_lastResolutionUpdate;

// vcamSendDiag is defined in VCamBridge.m
extern void vcamSendDiag(NSString *msg);

// ============================================================
// HOOK IMPLEMENTATIONS
// ============================================================

// --- BWNodeOutput::emitSampleBuffer: ---
// Hook address: sub_85ED4 (0x85ED4)
// Primary video frame injection point
static void hook_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sbuf);
    if (imageBuffer) {
        CVPixelBufferGetPixelFormatType(imageBuffer);
        size_t width  = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sbuf);
        (void)pts;

        VCamLiveManager *state = [VCamLiveManager sharedInstance];
        BOOL isLive = [state getLive];

        // Once-per-second diagnostic: confirms hook is firing and shows frame state.
        // Shows dimensions (to catch portrait vs landscape) and bLive.
        static double s_emsLog = 0;
        double emsNow = [[NSDate date] timeIntervalSince1970];
        if (emsNow - s_emsLog >= 1.0) {
            s_emsLog = emsNow;
            vcamSendDiag([NSString stringWithFormat:@"ems:%dx%d L=%d",
                (int)width, (int)height, (int)isLive]);
        }

        if (isLive) {
            // IDA-confirmed (sub_85ED4 0x85f68): inject ONLY for landscape frames (Width >= Height).
            // Portrait frames are skipped entirely — they cause photo-mode orientation flip when
            // iOS Camera photo pipelines deliver portrait-rotated buffers interleaved with
            // landscape capture buffers. The NSRecursiveLock (v2.114) is the real RTMP-disconnect
            // fix; this guard restores IDA-exact behavior for photo/portrait correctness.
            if (width >= height) {
                // IDA: two separate [NSDate date] calls — one for elapsed check, one for store
                NSDate *checkDate = [NSDate date];
                double nowTS = [checkDate timeIntervalSince1970];
                double elapsed = nowTS - g_lastResolutionUpdate;
                // IDA threshold: 0.100000001 (float 0.1f widened to double)
                if (g_lastResolutionUpdate <= 0.100000001 || elapsed > 3.0) {
                    NSDate *storeDate = [NSDate date];
                    g_lastResolutionUpdate = [storeDate timeIntervalSince1970];
                    VCamBridge *bridge = [VCamBridge sharedInstance];
                    [bridge setResolution:(unsigned int)width height:(unsigned int)height];
                }
                [state modifyImageBuffer:sbuf];
            }
        }
    }
    ((void (*)(id, SEL, CMSampleBufferRef))orig_emitSampleBuffer)(self, _cmd, sbuf);
}

// ============================================================
// HOOK INSTALLER
// ============================================================

void installMediaServerHooks(void) {
    Class cls;

    // BWNodeOutput — PRIMARY FRAME INJECTION HOOK
    cls = objc_getClass("BWNodeOutput");
    if (cls)
        MSHookMessageEx(cls, @selector(emitSampleBuffer:), (IMP)hook_emitSampleBuffer, (IMP *)&orig_emitSampleBuffer);
}
