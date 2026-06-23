// BINFlashCameraHooks.h
// Reconstructed from:
//   sub_4270 (0x4270) — MSHookFunction on CoreMedia C functions
//   sub_42F0 (0x42F0) — MSHookMessageEx on VCamLiveManager (ifdsflwoWdasdYfsdfJd)
//   sub_65C0 (0x65C0) — method_setImplementation on GPUImage classes
//
// Three separate hook sets, each guarded by its own boolean flag.
// All three install functions are called from InitFunc_0 and the 500ms retry timer.

#import <Foundation/Foundation.h>

// Called from InitFunc_0 and retry timer.
// Each sets its guard flag on success and becomes a no-op on re-call.

// sub_4270 — MSHookFunction on:
//   CMSampleBufferGetImageBuffer
//   CMSampleBufferCreateCopy
//   CMSampleBufferCreateForImageBuffer
void BINFlashInstallCoreMHooks(void);

// sub_42F0 — MSHookMessageEx on ifdsflwoWdasdYfsdfJd (VCamLiveManager):
//   modifyPixelBuffer:, modifyImageBuffer:, createSampleBuffer:,
//   getSampleBuffer:, get90SampleBuffer:,
//   setYUVPixelBuffer:, setYUVSampleBuffer:, setBGRASampleBuffer:
void BINFlashInstallVCamHooks(void);

// sub_65C0 — method_setImplementation on:
//   GPUImageBaseBeautyFaceFilter (or GPUImageBeautyFaceFilter)::setWhite:
//   GPUImageThinFaceFilter::setUniformsWithLandmarks:
void BINFlashInstallGPUImageSwizzles(void);

// Install-success guards (checked by retry timer in Tweak.x)
extern BOOL g_vcamHooksOk;       // byte_C2D8
extern BOOL g_coreMediaHooksOk;  // byte_C2D9
extern BOOL g_gpuImageHooksOk;   // byte_C370
