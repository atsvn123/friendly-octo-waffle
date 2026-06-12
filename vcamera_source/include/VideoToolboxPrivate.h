#pragma once
// Private VideoToolbox APIs used by vcamera.dylib on iOS.
// VTPixelTransferSession and VTImageRotationSession are excluded from the
// public iOS SDK headers (!TARGET_OS_IPHONE), but are present on device.

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef struct OpaqueVTImageRotationSession *VTImageRotationSessionRef;

extern int32_t VTPixelTransferSessionCreate(
    CFAllocatorRef allocator,
    VTPixelTransferSessionRef *pixelTransferSessionOut);

extern int32_t VTPixelTransferSessionTransferImage(
    VTPixelTransferSessionRef session,
    CVImageBufferRef sourceBuffer,
    CVImageBufferRef destinationBuffer);

extern int32_t VTImageRotationSessionCreate(
    CFAllocatorRef allocator,
    int rotationDegrees,
    VTImageRotationSessionRef *imageRotationSessionOut);

extern int32_t VTImageRotationSessionTransferImage(
    VTImageRotationSessionRef session,
    CVImageBufferRef sourceBuffer,
    CVImageBufferRef destinationBuffer);

// VTSessionSetProperty is in the public VideoToolbox.framework SDK — do NOT
// redeclare it here. Include <VideoToolbox/VideoToolbox.h> to get it.

// ── Private property keys NOT in the public iOS SDK ───────────────────────────
// kVTPixelTransferPropertyKey_ScalingMode and the destination color/matrix keys
// ARE in the public iOS SDK (VTPixelTransferProperties.h, available iOS 9.0+)
// and must NOT be re-declared here to avoid type-mismatch errors.
//
// Only declare keys that are genuinely private (absent from the SDK headers):

// Enables the Metal/GPU path in VTPixelTransferSessionTransferImage (0x130ab8)
extern const CFStringRef kVTPixelTransferPropertyKey_EnableGPUAcceleratedTransfer;

// Enables high-speed transfer in VTImageRotationSessionTransferImage (0x130a98)
extern const CFStringRef kVTImageRotationPropertyKey_EnableHighSpeedTransfer;

#ifdef __cplusplus
}
#endif
