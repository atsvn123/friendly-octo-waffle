// H264Decoder.m
// Reconstructed from ifQwsadqYeweSwedHse — verified against IDA decompile:
//   init           0x947DC
//   initDecoder:   0x94844
//   VTDecodeCallback sub_94BE0
//   decode:size:   0x94C9C
//   endDecode      0x94D9C

#import "H264Decoder.h"
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <Foundation/Foundation.h>
#include <unistd.h>

extern void vcamSendDiag(NSString *msg);

@implementation H264Decoder {
    VTDecompressionSessionRef    _session;
    CMVideoFormatDescriptionRef  _formatDesc;
    int                          _width;
    int                          _height;
    // Flag set by VTDecodeCallback when kVTInvalidSessionErr is received.
    // Read and cleared in decode:size:pts: (both on the same RTMP thread — no race).
    BOOL                         _sessionNeedsReset;
    // Saved SPS/PPS for automatic session recovery after invalidation.
    NSData                      *_savedSPS;
    NSData                      *_savedPPS;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _session    = NULL;
        _formatDesc = NULL;
        _width      = 1920;   // defaults from original: 0x780=1920, 0x438=1080
        _height     = 1080;
    }
    return self;
}

- (void)dealloc {
    [self endDecode];
    [_savedSPS release]; _savedSPS = nil;
    [_savedPPS release]; _savedPPS = nil;
    [super dealloc];
}

// ── Software B-frame reorder buffer ──────────────────────────────────────────
//
// With RealTime=YES, VT delivers decoded frames in DECODE order, not DISPLAY
// order. For H264 streams with B-frames the two orders diverge. Example:
//
//   Decode order (VT output): I(pts=0), P(pts=100), B(pts=33), B(pts=67)
//   Display order (correct):  I(pts=0), B(pts=33), B(pts=67), P(pts=100)
//
// We maintain a small sorted (ascending PTS) ring. On each new frame:
//   1. Insert at the correct PTS-sorted position.
//   2. When the ring has ≥ 2 entries: flush the oldest (lowest PTS) to the
//      delegate — ensuring we never output a frame whose PTS exceeds a frame
//      still held in the ring.
//
// Trace through the example above:
//   Arrive pts=0:   ring=[0],      output — (need ≥2 to establish order)
//   Arrive pts=100: ring=[0,100],  output I(0)    ✓
//   Arrive pts=33:  ring=[33,100], output B(33)   ✓  (inserted before 100)
//   Arrive pts=67:  ring=[67,100], output B(67)   ✓
//   Arrive pts=200: ring=[100,200],output P(100)  ✓
//
// Added latency: 1 RTMP frame period (≈33 ms at 30 fps). Acceptable for a
// virtual camera; far less than VT's RealTime=NO reorder window (~4 frames).
//
// Thread safety: with RealTime=YES, VTDecodeCallback fires synchronously on the
// RTMP thread inside VTDecompressionSessionDecodeFrame. initDecoder: and
// endDecode are also called from the RTMP thread. All s_rb* accesses are
// single-threaded — no locking required.

#define VCAM_REORDER_MAX 4

static CVImageBufferRef s_rbuf[VCAM_REORDER_MAX];
static int32_t          s_rpts[VCAM_REORDER_MAX];
static int              s_rn = 0;

static void vcamReorderReset(void) {
    for (int i = 0; i < s_rn; i++) {
        if (s_rbuf[i]) { CVBufferRelease(s_rbuf[i]); s_rbuf[i] = NULL; }
    }
    s_rn = 0;
}

// Insert frame into the sorted ring. Returns the oldest frame (with the +1 retain
// transferred from the ring to the caller) when ≥ 2 entries exist, else NULL.
// Caller MUST CVBufferRelease the returned buffer.
static CVImageBufferRef vcamReorderInsert(CVImageBufferRef frame, int32_t pts,
                                           int32_t *outPTS)
{
    *outPTS = 0;

    // Find sorted insertion point (ascending PTS).
    int ins = s_rn;
    for (int i = 0; i < s_rn; i++) {
        if (pts < s_rpts[i]) { ins = i; break; }
    }

    // Overflow guard: ring is full; drop the highest-PTS tail entry to make room.
    // This only happens if > VCAM_REORDER_MAX B-frames arrive in succession —
    // extremely rare in practice; the dropped frame is the least critical one.
    if (s_rn == VCAM_REORDER_MAX) {
        if (ins == VCAM_REORDER_MAX) return NULL;  // new frame is the largest — skip
        CVBufferRelease(s_rbuf[VCAM_REORDER_MAX - 1]);
        s_rbuf[VCAM_REORDER_MAX - 1] = NULL;
        s_rn--;
    }

    // Shift right to open slot at ins.
    for (int i = s_rn; i > ins; i--) {
        s_rbuf[i] = s_rbuf[i - 1];
        s_rpts[i] = s_rpts[i - 1];
    }
    s_rbuf[ins] = (CVImageBufferRef)CVBufferRetain(frame);
    s_rpts[ins] = pts;
    s_rn++;

    if (s_rn < 2) return NULL;  // need ≥ 2 to establish ordering

    // Flush the oldest entry (index 0): transfer its +1 retain to the caller.
    CVImageBufferRef out = s_rbuf[0];
    *outPTS = s_rpts[0];
    for (int i = 0; i < s_rn - 1; i++) {
        s_rbuf[i] = s_rbuf[i + 1];
        s_rpts[i] = s_rpts[i + 1];
    }
    s_rbuf[s_rn - 1] = NULL;
    s_rn--;

    return out;  // caller owns the +1 retain from CVBufferRetain above
}

// ─── VTDecompressionOutputCallback ───────────────────────────────────────────
// sub_94BE0 — passes raw CVImageBufferRef to delegate (no CMSampleBuffer wrapping).
// Uses MRC retain/release on outputRefCon (H264Decoder).
//
// With RealTime=YES the callback fires synchronously (still inside
// VTDecompressionSessionDecodeFrame on the RTMP thread) in decode order.
// vcamReorderInsert sorts frames by PTS so the delegate always receives them
// in display order — correct B-frame sequencing without depending on VT internals.
// sourceFrameRefCon carries the RTMP display PTS (DTS+CTS) cast to a pointer.

static void VTDecodeCallback(void *outputRefCon,
                              void *sourceFrameRefCon,
                              OSStatus status,
                              VTDecodeInfoFlags infoFlags,
                              CVImageBufferRef imageBuffer,
                              CMTime presentationTS,
                              CMTime presentationDuration)
{
    // VTDecompressionSessionInvalidate MUST NOT be called from within the callback
    // (would deadlock — VT holds an internal lock during callback invocation).
    //
    // CORRECT approach: set a flag here; decode:size:pts: checks it at its entry
    // point and calls endDecode safely outside any VT callback.
    if (status != noErr) {
        if (status == kVTInvalidSessionErr) {
            ((H264Decoder *)outputRefCon)->_sessionNeedsReset = YES;
            vcamSendDiag(@"h264:inv");
        }
        return;
    }

    if (infoFlags & kVTDecodeInfo_FrameDropped) return;
    if (!imageBuffer) return;

    int32_t framePTS = (int32_t)(intptr_t)sourceFrameRefCon;

    int32_t outPTS = 0;
    CVImageBufferRef outBuf = vcamReorderInsert(imageBuffer, framePTS, &outPTS);
    if (!outBuf) return;  // still buffering — not enough frames to establish order yet

    // outBuf has a +1 retain transferred from the reorder ring; release after use.
    H264Decoder *decoder = (H264Decoder *)outputRefCon;
    [decoder retain];

    id<H264DecoderDelegate> del = [decoder delegate];
    if (del) {
        [del outputFrame:(void *)outBuf
     presentationTimeStamp:(int64_t)outPTS
      presentationDuration:0];
    }

    [decoder release];
    CVBufferRelease(outBuf);  // release the reorder ring's +1 retain
}

// ─── initDecoder:spsSize:pps:ppsSize: ────────────────────────────────────────
// Verified against IDA 0x94844.
// Pixel format: '420v' (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
// Passes width/height from CMFormatDescription + OpenGLCompatibility.
// Passes videoDecoderSpecification with ITU-R 709/601-4 color space.
// Sets ThreadCount=2 and RealTime=YES on the session.

- (BOOL)initDecoder:(const uint8_t *)spsData spsSize:(size_t)spsSize
                pps:(const uint8_t *)ppsData ppsSize:(size_t)ppsSize
{
    [self endDecode];  // also calls vcamReorderReset()

    if (!spsData || spsSize == 0 || !ppsData || ppsSize == 0) return NO;

    // Build CMVideoFormatDescription from SPS + PPS
    const uint8_t *paramSetPtrs[2]  = { spsData, ppsData };
    size_t         paramSetSizes[2] = { spsSize, ppsSize };
    OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2,
        paramSetPtrs,
        paramSetSizes,
        4,               // 4-byte AVCC NAL length prefix
        &_formatDesc);
    if (err != noErr || !_formatDesc) return NO;

    // Extract video dimensions (original calls sps_parser() — equivalent)
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(_formatDesc);
    _width  = dim.width;
    _height = dim.height;

    // destinationImageBufferAttributes — matches original v27 dict exactly:
    // PixelFormat='420v' (video range = 875704422 = 0x34323076), Width, Height, OpenGLCompatibility=YES.
    // NOTE: original does NOT include kCVPixelBufferIOSurfacePropertiesKey.
    NSDictionary *pixelAttrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (NSString *)kCVPixelBufferWidthKey:  @(_width),
        (NSString *)kCVPixelBufferHeightKey: @(_height),
        (NSString *)kCVPixelBufferOpenGLCompatibilityKey: @YES,
    };

    // videoDecoderSpecification — matches original v28 dict.
    // These color space keys are applied as attachments on decoded CVPixelBuffers,
    // which VTPixelTransferSession uses for correct source→destination conversion.
    NSDictionary *decoderSpec = @{
        (NSString *)kCVImageBufferChromaLocationBottomFieldKey:
            (NSString *)kCVImageBufferChromaLocation_Left,
        (NSString *)kCVImageBufferChromaLocationTopFieldKey:
            (NSString *)kCVImageBufferChromaLocation_Left,
        (NSString *)kCVImageBufferColorPrimariesKey:
            (NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2,
        (NSString *)kCVImageBufferTransferFunctionKey:
            (NSString *)kCVImageBufferTransferFunction_ITU_R_709_2,
        (NSString *)kCVImageBufferYCbCrMatrixKey:
            (NSString *)kCVImageBufferYCbCrMatrix_ITU_R_601_4,
    };

    VTDecompressionOutputCallbackRecord cb;
    cb.decompressionOutputCallback = VTDecodeCallback;
    cb.decompressionOutputRefCon   = (void *)self;  // MRC — plain cast

    err = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _formatDesc,
        (__bridge CFDictionaryRef)decoderSpec,   // videoDecoderSpecification (arg 3)
        (__bridge CFDictionaryRef)pixelAttrs,    // destinationImageBufferAttributes (arg 4)
        &cb,
        &_session);

    if (err != noErr || !_session) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
        return NO;
    }

    VTSessionSetProperty((VTSessionRef)_session,
                         kVTDecompressionPropertyKey_ThreadCount,
                         (__bridge CFTypeRef)@1);
    // RealTime=YES: callback fires synchronously (inside VTDecompressionSessionDecodeFrame)
    // on the RTMP thread, in decode order. B-frame display ordering is handled by our
    // software reorder buffer (vcamReorderInsert) — independent of VT internals and
    // reliable on all Apple SoCs and iOS versions.
    VTSessionSetProperty((VTSessionRef)_session,
                         kVTDecompressionPropertyKey_RealTime,
                         kCFBooleanTrue);
    // Prioritize decode speed over power efficiency — minimizes decode latency.
    VTSessionSetProperty((VTSessionRef)_session,
                         kVTDecompressionPropertyKey_MaximizePowerEfficiency,
                         kCFBooleanFalse);

    // Save SPS/PPS so we can auto-recover the session if it gets invalidated
    // (e.g. when camera opens and reclaims the VT hardware decoder on A10).
    [_savedSPS release];
    _savedSPS = [[NSData alloc] initWithBytes:spsData length:spsSize];
    [_savedPPS release];
    _savedPPS = [[NSData alloc] initWithBytes:ppsData length:ppsSize];

    return YES;
}

// ─── decode:size:pts: ─────────────────────────────────────────────────────────
// Verified against IDA 0x94C9C.
// data = AVCC-formatted: [4-byte-BE-len][NALU][4-byte-BE-len][NALU]...
// kCFAllocatorNull = no ownership (safe: synchronous decode — callback fires
// before VTDecompressionSessionDecodeFrame returns, before data is freed).
// No CMSampleTimingInfo (numSampleTimingEntries=0) — matches original.
// flags=0 = synchronous — matches original.
// pts is passed via sourceFrameRefCon for the software reorder buffer.

- (void)decode:(const uint8_t *)data size:(size_t)size pts:(int32_t)pts {
    if (!data || size == 0) return;

    // Handle VT session invalidation set by VTDecodeCallback.
    // With RealTime=YES the callback fires synchronously on THIS thread (inside
    // VTDecompressionSessionDecodeFrame), so when we arrive here the previous
    // DecodeFrame call has already returned — no race.
    if (_sessionNeedsReset) {
        _sessionNeedsReset = NO;
        vcamSendDiag(@"h264:rst");
        [self endDecode];
    }

    // Session gone (invalidated, or reinit pending). Try to recover at most 1Hz.
    if (!_session) {
        static double s_lastReinit = 0;
        double now = [[NSDate date] timeIntervalSince1970];
        if (now - s_lastReinit >= 0.2 && _savedSPS && _savedPPS) {
            s_lastReinit = now;
            if ([self initDecoder:(const uint8_t *)[_savedSPS bytes] spsSize:[_savedSPS length]
                             pps:(const uint8_t *)[_savedPPS bytes] ppsSize:[_savedPPS length]]) {
                vcamSendDiag(@"h264:rir");
            }
        }
        if (!_session) return;
    }

    if (!_formatDesc) return;

    CMBlockBufferRef blockBuf = NULL;
    OSStatus err = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        (void *)data,
        size,
        kCFAllocatorNull,  // no ownership — data lives for the duration of this call
        NULL, 0, size, 0,
        &blockBuf);
    if (err != noErr || !blockBuf) return;

    // No timing info (numSampleTimingEntries=0) — matches original.
    // B-frame display ordering is handled by our software reorder buffer, not VT.
    CMSampleBufferRef sampleBuf = NULL;
    size_t sampleSize = size;
    err = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuf,
        _formatDesc,
        1,    // numSamples
        0,    // numSampleTimingEntries = 0 (no timing — matches original)
        NULL,
        1,
        &sampleSize,
        &sampleBuf);
    CFRelease(blockBuf);
    if (err != noErr || !sampleBuf) return;

    // flags=0: synchronous decode — callback fires before this function returns.
    // pts forwarded via sourceFrameRefCon to the reorder buffer in VTDecodeCallback.
    VTDecodeInfoFlags infoFlags = 0;
    OSStatus vtErr = VTDecompressionSessionDecodeFrame(
        _session, sampleBuf,
        0,                          // flags=0: synchronous, matches original
        (void *)(intptr_t)pts,      // forwarded to VTDecodeCallback as sourceFrameRefCon
        &infoFlags);
    CFRelease(sampleBuf);

    if (vtErr == kVTInvalidSessionErr) {
        _sessionNeedsReset = YES;
    }
}

// ─── reinitFromSaved ─────────────────────────────────────────────────────────
- (BOOL)reinitFromSaved {
    if (!_savedSPS || !_savedPPS) return NO;
    return [self initDecoder:(const uint8_t *)[_savedSPS bytes] spsSize:[_savedSPS length]
                        pps:(const uint8_t *)[_savedPPS bytes] ppsSize:[_savedPPS length]];
}

// ─── endDecode ───────────────────────────────────────────────────────────────
// Verified against IDA 0x94D9C.

- (void)endDecode {
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
    // Release any frames held in the software reorder ring.
    vcamReorderReset();
}

@end
