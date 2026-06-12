// VCamLiveManager.m
// Reconstructed from ifdsflwoWdasdYfsdfJd (0x12ADB0)

#import "VCamLiveManager.h"
#import "../BINFlash/BINFlashPixelEffect.h"
#import <os/lock.h>
#import <notify.h>
#include <string.h>
#include <math.h>

// ObjC runtime alias so BINFlashCamera's objc_getClass("ifdsflwoWdasdYfsdfJd")
// finds this class.  Must be in exactly one .m file.
@compatibility_alias ifdsflwoWdasdYfsdfJd VCamLiveManager;

// Cross-process diagnostic — defined in VCamBridge.m
extern void vcamSendDiag(NSString *msg);

// ── Dedup ring buffer ─────────────────────────────────────────────────────────
// Replaces NSMutableDictionary — 16 uint64 compares vs ObjC hash + alloc per frame.
#define VCAM_DEDUP_SIZE 16
typedef struct { uint64_t key; double ts; } VCamDedupEntry;
static VCamDedupEntry s_dedup[VCAM_DEDUP_SIZE];
static int            s_dedupHead = 0;

static BOOL vcamDedupCheck(uint64_t key, double now) {
    for (int i = 0; i < VCAM_DEDUP_SIZE; i++) {
        if (s_dedup[i].key == key && (now - s_dedup[i].ts) < 0.2) return YES;
    }
    return NO;
}
static void vcamDedupInsert(uint64_t key, double now) {
    s_dedup[s_dedupHead].key = key;
    s_dedup[s_dedupHead].ts  = now;
    s_dedupHead = (s_dedupHead + 1) % VCAM_DEDUP_SIZE;
}

// ─────────────────────────────────────────────────────────────────────────────
@implementation VCamLiveManager {
    // Replaces NSRecursiveLock — guards only pointer swaps (nanoseconds held).
    os_unfair_lock _spinlock;

    // Cross-tick RTMP buffer snapshot.
    // BWNodeOutput::emitSampleBuffer: fires N times per camera tick (preview, data output, …)
    // across multiple pipeline nodes. Each node may create its own CMSampleBuffer with a
    // different PTS, so PTS-based grouping is unreliable. Instead we use a dirty flag:
    //   _pixelDirty is set YES by setYUVPixelBuffer: (RTMP decode thread).
    //   modifyImageBuffer: snapshots _pixelYUVBuffer → _cycleBuffer on the FIRST firing
    //   after each new RTMP frame arrives, then clears the flag.
    //   All subsequent firings before the next RTMP frame reuse _cycleBuffer unchanged.
    // This guarantees every pipeline node in one batch sees the same RTMP frame.
    CVPixelBufferRef _cycleBuffer;    // RTMP frame locked for current batch
    CVPixelBufferRef _cycleBuffer90;  // 90°-rotated variant (from setYUVSampleBuffer: path)
    BOOL             _pixelDirty;     // YES = new RTMP frame arrived, snapshot needed

    // Lazy rotation cache for setYUVPixelBuffer: fast path (RTMP decode thread never
    // pre-computes rotation; we do it here on the camera thread to avoid GPU contention).
    // Camera pipeline is serial — these are accessed only from modifyImageBuffer:.
    CVPixelBufferRef _cachedRotBuf;    // last rotation result
    uintptr_t        _cachedRotSrcPtr; // _cycleBuffer pointer it was computed for
}

// ── +sharedInstance (0x900EC) ──────────────────────────────────────────────
+ (instancetype)sharedInstance {
    static VCamLiveManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCamLiveManager alloc] init];
    });
    return instance;
}

// ── -init (0x90188) ───────────────────────────────────────────────────────
- (instancetype)init {
    self = [super init];
    if (self) {
        self.bLive      = NO;
        self.hasFace    = NO;
        self.floatWindow    = YES;
        self.cameraSelected = YES;
        _spinlock = OS_UNFAIR_LOCK_INIT;

        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_pixelTransferSession);
        VTSessionSetProperty((VTSessionRef)(void *)_pixelTransferSession,
                             kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                             kCVImageBufferColorPrimaries_ITU_R_709_2);
        VTSessionSetProperty((VTSessionRef)(void *)_pixelTransferSession,
                             kVTPixelTransferPropertyKey_DestinationTransferFunction,
                             kCVImageBufferTransferFunction_ITU_R_709_2);
        VTSessionSetProperty((VTSessionRef)(void *)_pixelTransferSession,
                             kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             kCVImageBufferYCbCrMatrix_ITU_R_601_4);
        VTSessionSetProperty((VTSessionRef)(void *)_pixelTransferSession,
                             kVTPixelTransferPropertyKey_ScalingMode,
                             kVTScalingMode_Trim);
        VTSessionSetProperty((VTSessionRef)(void *)_pixelTransferSession,
                             kVTPixelTransferPropertyKey_EnableGPUAcceleratedTransfer,
                             kCFBooleanTrue);

        VTImageRotationSessionCreate(kCFAllocatorDefault, 90, &_imageRotationSession);
        VTSessionSetProperty((VTSessionRef)(void *)_imageRotationSession,
                             kVTImageRotationPropertyKey_EnableHighSpeedTransfer,
                             kCFBooleanTrue);

        NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        [t start];
        [t release];
    }
    return self;
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE HELPERS
// ─────────────────────────────────────────────────────────────────────────────

- (CVPixelBufferRef)vcam_createPixelBuffer:(OSType)fmt
                                     width:(int)w
                                    height:(int)h
                                       src:(CVPixelBufferRef)src
{
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef dst = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h, fmt,
                        (__bridge CFDictionaryRef)attrs, &dst);
    if (dst && src) {
        VTPixelTransferSessionTransferImage(_pixelTransferSession,
                                            (CVImageBufferRef)src,
                                            (CVImageBufferRef)dst);
    }
    return dst;
}

- (CVPixelBufferRef)create90ImageBuffer:(CVPixelBufferRef)src {
    if (!src || !_imageRotationSession) return NULL;
    int srcW = (int)CVPixelBufferGetWidth(src);
    int srcH = (int)CVPixelBufferGetHeight(src);
    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef dst = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, (size_t)srcH, (size_t)srcW, fmt,
                        (__bridge CFDictionaryRef)attrs, &dst);
    if (!dst) return NULL;

    OSStatus st = VTImageRotationSessionTransferImage(_imageRotationSession, src, dst);
    if (st != noErr) { CVPixelBufferRelease(dst); return NULL; }
    return dst;
}

// ─────────────────────────────────────────────────────────────────────────────
// FRAME INPUT — called by VCamBridge after RTMP decode
// ─────────────────────────────────────────────────────────────────────────────

- (void)setYUVSampleBuffer:(CMSampleBufferRef)sbuf {
    if (!sbuf) return;

    // Pre-rotate and copy OUTSIDE the spinlock — both involve memory/GPU work.
    CVPixelBufferRef src = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sbuf);
    CVPixelBufferRef new90 = [self create90ImageBuffer:src];
    CMSampleBufferRef copy = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sbuf, &copy);

    os_unfair_lock_lock(&_spinlock);
    CMSampleBufferRef oldSbuf = _liveYUVSampleBuffer;
    _liveYUVSampleBuffer = copy;
    CVPixelBufferRef old90 = _pixelYUVBuffer90;
    _pixelYUVBuffer90 = new90;
    os_unfair_lock_unlock(&_spinlock);

    if (oldSbuf) CFRelease(oldSbuf);
    if (old90)   CVPixelBufferRelease(old90);
}

- (void)setYUVPixelBuffer:(CVPixelBufferRef)pixbuf {
    if (!pixbuf) return;

    // Skip create90ImageBuffer: here — on iOS 16 (A12+) at 60fps camera + 30fps RTMP,
    // calling VTImageRotationSessionTransferImage + CVPixelBufferCreate (IOSurface alloc)
    // on the RTMP decode thread 30/sec creates GPU pressure that stalls the decode loop,
    // causing TCP buffer fill → "periodic pause / auto-recover" symptom.
    // Rotation is now computed lazily in modifyImageBuffer: (camera thread) with a
    // pointer-keyed cache — computed once per new RTMP frame, reused for all camera ticks.
    CVPixelBufferRef retainedNew = (CVPixelBufferRef)CVBufferRetain(pixbuf);

    os_unfair_lock_lock(&_spinlock);
    CVPixelBufferRef oldBuf = _pixelYUVBuffer;
    CVPixelBufferRef old90  = _pixelYUVBuffer90;
    _pixelYUVBuffer   = retainedNew;
    _pixelYUVBuffer90 = NULL;  // rotation deferred; modifyImageBuffer: uses _cachedRotBuf
    _pixelDirty       = YES;
    if (!_bLive) _bLive = YES;
    os_unfair_lock_unlock(&_spinlock);

    if (oldBuf) CVPixelBufferRelease(oldBuf);
    if (old90)  CVPixelBufferRelease(old90);
}

- (void)setBGRASampleBuffer:(CMSampleBufferRef)sbuf {
    if (!sbuf) return;

    CVPixelBufferRef src = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sbuf);
    CVPixelBufferRef new90 = [self create90ImageBuffer:src];
    CMSampleBufferRef copy = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sbuf, &copy);

    os_unfair_lock_lock(&_spinlock);
    CMSampleBufferRef oldSbuf = _liveBGRASampleBuffer;
    _liveBGRASampleBuffer = copy;
    CVPixelBufferRef old90 = _pixelBGRABuffer90;
    _pixelBGRABuffer90 = new90;
    os_unfair_lock_unlock(&_spinlock);

    if (oldSbuf) CFRelease(oldSbuf);
    if (old90)   CVPixelBufferRelease(old90);
}

// ─────────────────────────────────────────────────────────────────────────────
// FRAME INJECTION — called from BWNodeOutput hook
// ─────────────────────────────────────────────────────────────────────────────

- (CMSampleBufferRef)modifyImageBuffer:(CMSampleBufferRef)sampleBuffer {
    // Once-per-second probe.
    static double s_mibInLog = 0;
    double now = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
    if (now - s_mibInLog >= 1.0) {
        s_mibInLog = now;
        vcamSendDiag([NSString stringWithFormat:@"mib:in bL=%d yb=%d",
            (int)_bLive, (_pixelYUVBuffer ? 1 : 0)]);
    }

    if (!_bLive || !_pixelYUVBuffer) return nil;

    CVImageBufferRef destBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!destBuffer) return nil;

    // Read dest dimensions outside the lock — destBuffer is caller-owned, no lock needed.
    int dstW = (int)CVPixelBufferGetWidth((CVPixelBufferRef)destBuffer);
    int dstH = (int)CVPixelBufferGetHeight((CVPixelBufferRef)destBuffer);

    CMTime   pts    = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    uint64_t keyVal = (uint64_t)(uintptr_t)destBuffer + (uint64_t)pts.value;
    now = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;

    os_unfair_lock_lock(&_spinlock);

    if (!_pixelYUVBuffer) {
        os_unfair_lock_unlock(&_spinlock);
        return nil;
    }
    if (vcamDedupCheck(keyVal, now)) {
        os_unfair_lock_unlock(&_spinlock);
        return nil;
    }
    vcamDedupInsert(keyVal, now);

    // Dirty-flag cycle buffer: snapshot _pixelYUVBuffer only on the FIRST modifyImageBuffer:
    // call after each setYUVPixelBuffer: call. All subsequent calls before the next RTMP
    // frame arrive reuse _cycleBuffer unchanged. This is correct regardless of whether the
    // multiple hook firings have the same PTS (which they often don't — each pipeline node
    // creates its own CMSampleBuffer). Without this, the RTMP decode thread can update
    // _pixelYUVBuffer between hook firings → different nodes see different RTMP frames
    // → the display alternates frames: "up a frame, back a frame."
    CVPixelBufferRef oldCycle   = NULL;
    CVPixelBufferRef oldCycle90 = NULL;
    if (_pixelDirty) {
        _pixelDirty  = NO;
        oldCycle     = _cycleBuffer;
        oldCycle90   = _cycleBuffer90;
        _cycleBuffer   = (CVPixelBufferRef)CVBufferRetain(_pixelYUVBuffer);
        _cycleBuffer90 = _pixelYUVBuffer90
                         ? (CVPixelBufferRef)CVBufferRetain(_pixelYUVBuffer90)
                         : NULL;
    }

    if (!_cycleBuffer) {
        os_unfair_lock_unlock(&_spinlock);
        return nil;
    }

    int srcW = (int)CVPixelBufferGetWidth(_cycleBuffer);
    int srcH = (int)CVPixelBufferGetHeight(_cycleBuffer);
    BOOL needRotation = ((srcW > srcH) != (dstW > dstH));

    CVImageBufferRef transferSrc;
    if (!needRotation) {
        transferSrc = (CVImageBufferRef)CVBufferRetain(_cycleBuffer);
    } else if (_cycleBuffer90) {
        transferSrc = (CVImageBufferRef)CVBufferRetain(_cycleBuffer90);
    } else {
        transferSrc = NULL;
    }

    os_unfair_lock_unlock(&_spinlock);

    // Release old cycle buffers outside the lock (avoids dealloc under spinlock).
    if (oldCycle)   CVPixelBufferRelease(oldCycle);
    if (oldCycle90) CVPixelBufferRelease(oldCycle90);

    // Lazy rotation: setYUVPixelBuffer: (RTMP fast path) does not pre-compute the 90°
    // buffer. Compute it here on the camera thread, cached by source pointer.
    // _cachedRotBuf/_cachedRotSrcPtr are accessed only from modifyImageBuffer: (camera
    // pipeline is serial), so no lock is needed.
    if (!transferSrc && needRotation && _cycleBuffer) {
        uintptr_t srcPtr = (uintptr_t)_cycleBuffer;
        if (_cachedRotSrcPtr != srcPtr || !_cachedRotBuf) {
            CVPixelBufferRelease(_cachedRotBuf);
            _cachedRotBuf    = [self create90ImageBuffer:_cycleBuffer];
            _cachedRotSrcPtr = _cachedRotBuf ? srcPtr : 0;
        }
        transferSrc = _cachedRotBuf ? (CVImageBufferRef)CVBufferRetain(_cachedRotBuf) : NULL;
    }

    if (!transferSrc) return nil;

    // VTPixelTransferSession OUTSIDE the spinlock — GPU call, ~1-3ms.
    // The RTMP decode thread can now store a new frame in parallel without stalling.
    OSStatus status = VTPixelTransferSessionTransferImage(
        _pixelTransferSession, transferSrc, destBuffer);
    CVBufferRelease(transferSrc);

    static double s_lastMibLog = 0;
    double mibNow = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
    if (mibNow - s_lastMibLog >= 1.0) {
        s_lastMibLog = mibNow;
        vcamSendDiag([NSString stringWithFormat:@"mib:st=%d", (int)status]);
    }

    // BINFlash applied OUTSIDE the spinlock — pixel loop + occasional plist I/O.
    if (status == noErr) {
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)destBuffer);
    }

    return (status == noErr) ? sampleBuffer : nil;
}

- (CMSampleBufferRef)modifyPixelBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.hasFace || !_pixelResultBuffer) return nil;

    CVImageBufferRef destIB = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!destIB) return nil;

    os_unfair_lock_lock(&_spinlock);
    CVPixelBufferRef resultBuf = _pixelResultBuffer
        ? (CVPixelBufferRef)CVBufferRetain(_pixelResultBuffer)
        : NULL;
    os_unfair_lock_unlock(&_spinlock);

    if (!resultBuf) return nil;

    OSStatus st = VTPixelTransferSessionTransferImage(
        _pixelTransferSession,
        (CVImageBufferRef)resultBuf,
        destIB);
    CVPixelBufferRelease(resultBuf);

    if (st == noErr) {
        int val = 1;
        CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &val);
        CMSetAttachment((CMAttachmentBearerRef)sampleBuffer,
                        CFSTR("CMSampleBufferTransitionID"),
                        num, kCMAttachmentMode_ShouldPropagate);
        CFRelease(num);
    }

    return (st == noErr) ? sampleBuffer : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// BUFFER FACTORY — face-swap mode
// ─────────────────────────────────────────────────────────────────────────────

- (CMSampleBufferRef)createSampleBuffer:(CMSampleBufferRef)srcSbuf {
    CVPixelBufferRef srcPB = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(srcSbuf);
    if (!srcPB) return nil;

    int w = (int)CVPixelBufferGetWidth(srcPB);
    int h = (int)CVPixelBufferGetHeight(srcPB);

    CVPixelBufferRef bgraBuf = [self vcam_createPixelBuffer:kCVPixelFormatType_32BGRA
                                                      width:w height:h src:srcPB];
    if (!bgraBuf) return nil;

    CVBufferPropagateAttachments((CVBufferRef)srcPB, (CVBufferRef)bgraBuf);

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, bgraBuf, &fmtDesc);
    if (!fmtDesc) { CVPixelBufferRelease(bgraBuf); return nil; }

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(srcSbuf);
    timing.decodeTimeStamp       = kCMTimeInvalid;
    timing.duration              = CMSampleBufferGetDuration(srcSbuf);

    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, bgraBuf, YES,
                                        NULL, NULL, fmtDesc, &timing, &result);
    CFRelease(fmtDesc);
    CVPixelBufferRelease(bgraBuf);
    return result;
}

- (CMSampleBufferRef)getSampleBuffer:(CMSampleBufferRef)refSbuf {
    if (!self.hasFace || !_pixelResultBuffer) return nil;

    CVPixelBufferRef refPB = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(refSbuf);
    OSType fmt = CVPixelBufferGetPixelFormatType(_pixelResultBuffer);
    int w = (int)CVPixelBufferGetWidth(_pixelResultBuffer);
    int h = (int)CVPixelBufferGetHeight(_pixelResultBuffer);

    CVPixelBufferRef newBuf = [self vcam_createPixelBuffer:fmt width:w height:h
                                                       src:_pixelResultBuffer];
    if (!newBuf) return nil;

    CVBufferPropagateAttachments((CVBufferRef)refPB, (CVBufferRef)newBuf);

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, newBuf, &fmtDesc);
    if (!fmtDesc) { CVPixelBufferRelease(newBuf); return nil; }

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(refSbuf);
    timing.decodeTimeStamp       = kCMTimeInvalid;
    timing.duration              = CMSampleBufferGetDuration(refSbuf);

    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, newBuf, YES,
                                        NULL, NULL, fmtDesc, &timing, &result);
    CFRelease(fmtDesc);
    CVPixelBufferRelease(newBuf);
    return result;
}

- (CMSampleBufferRef)get90SampleBuffer:(CMSampleBufferRef)refSbuf {
    if (!self.hasFace) return nil;

    CVPixelBufferRef refPB = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(refSbuf);
    OSType fmt = CVPixelBufferGetPixelFormatType(refPB);

    CVPixelBufferRef srcBuf;
    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    {
        srcBuf = _pixelYUVBuffer90;
    } else {
        srcBuf = _pixelResult90Buffer;
    }
    if (!srcBuf) return nil;

    CVBufferPropagateAttachments((CVBufferRef)refPB, (CVBufferRef)srcBuf);

    CMVideoFormatDescriptionRef fmtDesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, srcBuf, &fmtDesc);
    if (!fmtDesc) return nil;

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(refSbuf);
    timing.decodeTimeStamp       = kCMTimeInvalid;
    timing.duration              = CMSampleBufferGetDuration(refSbuf);

    CMSampleBufferRef result = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, srcBuf, YES,
                                        NULL, NULL, fmtDesc, &timing, &result);
    CFRelease(fmtDesc);
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// STATE ACCESSORS
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)getLive         { return self.bLive; }
- (BOOL)getFloatWindow  { return self.floatWindow; }

- (void)setLive:(BOOL)live { self.bLive = live; }

- (void)setSwitchFace:(BOOL)flag {
    _switchFace = flag;
    if (!flag) _hasFace = NO;
}

// ─────────────────────────────────────────────────────────────────────────────
// BEAUTY PARAMETER SETTERS
// ─────────────────────────────────────────────────────────────────────────────
- (void)setThinFacePercent:(float)p    { self.thinFacePercent    = p; }
- (void)setBigEyePercent:(float)p      { self.bigEyePercent      = p; }
- (void)setBigMouthPercent:(float)p    { self.bigMouthPercent    = p; }
- (void)setBigNosePercent:(float)p     { self.bigNosePercent     = p; }
- (void)setDermabrasionPercent:(float)p{ self.dermabrasionPercent= p; }

// ─────────────────────────────────────────────────────────────────────────────
// CONFIGURATION
// ─────────────────────────────────────────────────────────────────────────────

- (void)setApplicationID:(NSString *)appID {
    NSString *s = [NSString stringWithFormat:@"%@", appID];
    [_applicationID release];
    _applicationID = [s copy];
}

- (void)setOrientation:(int)orientation { (void)orientation; }

// ─────────────────────────────────────────────────────────────────────────────
// VIDEO FILE READING (stubs)
// ─────────────────────────────────────────────────────────────────────────────

- (void)startReading:(NSURL *)url { (void)url; }
- (void)cancelReading {}

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND RUN LOOP
// ─────────────────────────────────────────────────────────────────────────────
- (void)run {
    [[NSRunLoop currentRunLoop] run];
}

// ── RTMP color sampling ───────────────────────────────────────────────────────
// Reads the current RTMP pixel buffer under the spinlock (safe: only swaps
// pointer, does not hold lock during pixel read).
- (double)sampleHueAtNormalizedX:(double)nx y:(double)ny {
    os_unfair_lock_lock(&_spinlock);
    CVPixelBufferRef buf = _pixelYUVBuffer
                           ? (CVPixelBufferRef)CVBufferRetain(_pixelYUVBuffer)
                           : NULL;
    os_unfair_lock_unlock(&_spinlock);
    if (!buf) return -1.0;

    OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    if ((fmt & 0xFFFFFFEFU) != 0x34323066U) { CVPixelBufferRelease(buf); return -1.0; }

    size_t bW = CVPixelBufferGetWidth(buf);
    size_t bH = CVPixelBufferGetHeight(buf);
    if (!bW || !bH) { CVPixelBufferRelease(buf); return -1.0; }

    double nxc = nx < 0.0 ? 0.0 : (nx > 1.0 ? 1.0 : nx);
    double nyc = ny < 0.0 ? 0.0 : (ny > 1.0 ? 1.0 : ny);

    // RTMP buffer is landscape (bW > bH); displayed portrait via 90° rotation.
    // Screen Y → buffer X;  screen X → buffer Y (inverted).
    size_t bufX, bufY;
    if (bW > bH) {
        bufX = (size_t)(nyc * (double)(bW - 1));
        bufY = (size_t)((1.0 - nxc) * (double)(bH - 1));
    } else {
        bufX = (size_t)(nxc * (double)(bW - 1));
        bufY = (size_t)(nyc * (double)(bH - 1));
    }

    if (CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(buf); return -1.0;
    }

    size_t  yStride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
    uint8_t *yPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 0);
    size_t uvStride  = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
    uint8_t *uvPlane = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buf, 1);

    double Y  = (double)yPlane[bufY * yStride + bufX] / 255.0;
    uint8_t *uvp = uvPlane + (bufY / 2) * uvStride + (bufX / 2) * 2;
    double Pb = ((double)uvp[0] - 128.0) / 255.0;  // Cb
    double Pr = ((double)uvp[1] - 128.0) / 255.0;  // Cr

    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(buf);

    // BT.601 YCbCr → linear RGB
    double r = Y + 1.402   * Pr;
    double g = Y - 0.344136 * Pb - 0.714136 * Pr;
    double b = Y + 1.772   * Pb;
    r = r < 0.0 ? 0.0 : (r > 1.0 ? 1.0 : r);
    g = g < 0.0 ? 0.0 : (g > 1.0 ? 1.0 : g);
    b = b < 0.0 ? 0.0 : (b > 1.0 ? 1.0 : b);

    // RGB → hue
    double maxC  = r > g ? (r > b ? r : b) : (g > b ? g : b);
    double minC  = r < g ? (r < b ? r : b) : (g < b ? g : b);
    double delta = maxC - minC;
    if (delta < 0.08 || maxC < 0.04 || (1.0 - minC) < 0.04) return -1.0;

    double h;
    if      (maxC == r) h = fmod((g - b) / delta, 6.0);
    else if (maxC == g) h = (b - r) / delta + 2.0;
    else                h = (r - g) / delta + 4.0;
    h /= 6.0;
    if (h < 0.0) h += 1.0;
    return h;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// RTMP COLOR SAMPLER (runs in mediaserverd only)
// Eliminates the UIKit screen-capture path which cannot see GPU-rendered camera
// preview layers (AVCaptureVideoPreviewLayer returns black in renderInContext:).
// ─────────────────────────────────────────────────────────────────────────────
void vcamInstallRTMPColorSampler(void) {
    static int s_reqToken  = NOTIFY_TOKEN_INVALID;
    static int s_respToken = NOTIFY_TOKEN_INVALID;

    notify_register_check("com.vcam.sampleresponse", &s_respToken);
    notify_register_dispatch(
        "com.vcam.samplerequest",
        &s_reqToken,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
        ^(int token) {
            uint64_t packed = 0;
            notify_get_state(token, &packed);

            uint32_t xBits = (uint32_t)(packed >> 32);
            uint32_t yBits = (uint32_t)(packed & 0xFFFFFFFFULL);
            float xf = 0.0f, yf = 0.0f;
            memcpy(&xf, &xBits, 4);
            memcpy(&yf, &yBits, 4);
            if (xf < 0.0f || xf > 1.0f || yf < 0.0f || yf > 1.0f) return;

            VCamLiveManager *mgr = [VCamLiveManager sharedInstance];
            double hue = [mgr sampleHueAtNormalizedX:(double)xf y:(double)yf];
            if (hue < 0.0) return;

            float hf = (float)hue;
            uint32_t hueBits = 0;
            memcpy(&hueBits, &hf, 4);
            notify_set_state(s_respToken, (uint64_t)hueBits);
            notify_post("com.vcam.sampleresponse");
        });
}
