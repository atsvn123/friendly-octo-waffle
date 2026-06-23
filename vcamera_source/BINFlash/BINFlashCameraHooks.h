// BINFlashCameraHooks.h
// GPUImage swizzles for mediaserverd.
// BINFlashApplyToPixelBuffer is called directly from VCamLiveManager::modifyImageBuffer:
// after VTPixelTransferSessionTransferImage — no CMSampleBuffer hooks needed.

#import <Foundation/Foundation.h>

extern BOOL g_gpuImageHooksOk;

// Install all mediaserverd-side BINFlash hooks.
// Idempotent — safe to call multiple times.
void installBINFlashMediaHooks(void);
