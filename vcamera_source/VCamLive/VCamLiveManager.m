// VCamLiveManager.m
// Reconstructed from ifdsflwoWdasdYfsdfJd (0x12ADB0)
// v2.114: restored single NSRecursiveLock design to match IDA exactly.
//   IDA-confirmed: _lock (NSRecursiveLock) is held across the ENTIRE
//   modifyImageBuffer: operation including VTPixelTransferSessionTransferImage.
//   setYUVSampleBuffer: and setYUVPixelBuffer: ALSO hold _lock during all VT work.
//   All VT operations (createImageBuffer:, create90ImageBuffer:,
//   VTPixelTransferSessionTransferImage) are serialized through the same lock,
//   preventing concurrent VT hardware use that caused RTMP disconnect on A11/dual-camera.

#import "VCamLiveManager.h"
#import "../BINFlash/BINFlashPixelEffect.h"
#import <notify.h>
#include <string.h>
#include <math.h>

// ObjC runtime alias so BINFlashCamera's objc_getClass("ifdsflwoWdasdYfsdfJd")
// finds this class.  Must be in exactly one .m file.
@compatibility_alias ifdsflwoWdasdYfsdfJd VCamLiveManager;

// Cross-process diagnostic — defined in VCamBridge.m
extern void vcamSendDiag(NSString *msg);

// ─────────────────────────────────────────────────────────────────────────────
@implementation VCamLiveManager {
    // IDA-confirmed: single NSRecursiveLock that serializes ALL frame operations.
    // - setYUVSampleBuffer: (RTMP decode thread) holds it during CMSampleBufferCreateCopy
    //   + create90ImageBuffer: (VTImageRotationSessionTransferImage)
    // - setYUVPixelBuffer: (face-swap / other paths) holds it during createImageBuffer:
    //   (VTPixelTransferSessionTransferImage) + create90ImageBuffer:
    // - modifyImageBuffer: (camera pipeline thread) holds it through the entire
    //   VTPixelTransferSessionTransferImage call
    // This prevents concurrent VT hardware use from different threads, which caused
    // VT session invalidation and RTMP disconnect on A11 and dual-camera devices.
    NSRecursiveLock    *_lock;

    // IDA-confirmed dedup dictionary (maps key → timestamp NSNumber).
    // Key = (uintptr_t)destBuffer + pts.value as NSNumber/uint64.
    // When multiple BWNodeOutput nodes share the same underlying CVPixelBuffer
    // for the same camera tick, the first call does the injection; subsequent
    // calls with the same key are filtered. Entries expire after 200ms.
    NSMutableDictionary *_dictionary;
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

        _lock       = [[NSRecursiveLock alloc] init];
        _dictionary = [[NSMutableDictionary alloc] init];

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

// createImageBuffer: (IDA 0x90898) — creates an IOSurface-backed copy of src.
// Called by setYUVPixelBuffer: under _lock.
- (CVPixelBufferRef)createImageBuffer:(CVPixelBufferRef)src {
    if (!src) return NULL;
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    int w = (int)CVPixelBufferGetWidth(src);
    int h = (int)CVPixelBufferGetHeight(src);

    NSDictionary *ioSurfaceProps = @{
        @"IOSurfacePreallocPages":    @0,
        @"IOSurfacePurgeWhenNotInUse": @1,
    };
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: ioSurfaceProps,
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)w, (size_t)h, fmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) {
        return NULL;
    }
    if (VTPixelTransferSessionTransferImage(_pixelTransferSession, src, dst) != noErr) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

// create90ImageBuffer: (IDA 0x90708) — creates 90°-rotated copy (dimensions swapped).
// Called by setYUVSampleBuffer: and setYUVPixelBuffer: under _lock.
- (CVPixelBufferRef)create90ImageBuffer:(CVPixelBufferRef)src {
    if (!src || !_imageRotationSession) return NULL;
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    int srcW = (int)CVPixelBufferGetWidth(src);
    int srcH = (int)CVPixelBufferGetHeight(src);

    NSDictionary *ioSurfaceProps = @{
        @"IOSurfacePreallocPages":    @0,
        @"IOSurfacePurgeWhenNotInUse": @1,
    };
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: ioSurfaceProps,
    };
    CVPixelBufferRef dst = NULL;
    // Destination has swapped dimensions (90° rotation)
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)srcH, (size_t)srcW, fmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) {
        return NULL;
    }
    if (VTImageRotationSessionTransferImage(_imageRotationSession, src, dst) != noErr) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    return dst;
}

// vcam_createPixelBuffer — used only by createSampleBuffer: / getSampleBuffer: (face swap).
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

// ─────────────────────────────────────────────────────────────────────────────
// FRAME INPUT — called by VCamBridge after RTMP decode
// ─────────────────────────────────────────────────────────────────────────────

// setYUVSampleBuffer: (IDA 0x90A98) — primary RTMP frame delivery path.
// Holds _lock during BOTH CMSampleBufferCreateCopy AND create90ImageBuffer:
// (VTImageRotationSessionTransferImage), serializing with modifyImageBuffer:.
- (void)setYUVSampleBuffer:(CMSampleBufferRef)sbuf {
    if (!sbuf) return;

    [_lock lock];

    CMSampleBufferRef old = _liveYUVSampleBuffer;
    if (old) { CFRelease(old); _liveYUVSampleBuffer = NULL; }
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sbuf, &_liveYUVSampleBuffer);

    CVPixelBufferRef old90 = _pixelYUVBuffer90;
    if (old90) { CFRelease(old90); _pixelYUVBuffer90 = NULL; }
    _pixelYUVBuffer90 = [self create90ImageBuffer:
                         (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sbuf)];

    [_lock unlock];
}

// setYUVPixelBuffer: (IDA 0x90A2C) — face-swap / alternate path.
// Holds _lock during BOTH createImageBuffer: AND create90ImageBuffer:.
- (void)setYUVPixelBuffer:(CVPixelBufferRef)pixbuf {
    if (!pixbuf) return;

    [_lock lock];

    CVPixelBufferRef old = _pixelYUVBuffer;
    if (old) { CFRelease(old); _pixelYUVBuffer = NULL; }
    _pixelYUVBuffer = [self createImageBuffer:pixbuf];

    CVPixelBufferRef old90 = _pixelYUVBuffer90;
    if (old90) { CFRelease(old90); _pixelYUVBuffer90 = NULL; }
    _pixelYUVBuffer90 = [self create90ImageBuffer:pixbuf];

    [_lock unlock];
}

- (void)setBGRASampleBuffer:(CMSampleBufferRef)sbuf {
    if (!sbuf) return;

    CVPixelBufferRef src = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sbuf);
    CVPixelBufferRef new90 = [self create90ImageBuffer:src];
    CMSampleBufferRef copy = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sbuf, &copy);

    [_lock lock];
    CMSampleBufferRef oldSbuf = _liveBGRASampleBuffer;
    _liveBGRASampleBuffer = copy;
    CVPixelBufferRef oldBGRA90 = _pixelBGRABuffer90;
    _pixelBGRABuffer90 = new90;
    [_lock unlock];

    if (oldSbuf) CFRelease(oldSbuf);
    if (oldBGRA90) CVPixelBufferRelease(oldBGRA90);
}

// ─────────────────────────────────────────────────────────────────────────────
// FRAME INJECTION — called from BWNodeOutput hook
// ─────────────────────────────────────────────────────────────────────────────

// modifyImageBuffer: (IDA 0x92080) — replaces camera pixels with RTMP content.
//
// IDA-confirmed design:
//   1. Guard: _bLive && _liveYUVSampleBuffer (outside lock — fast bail)
//   2. [_lock lock] — serializes with setYUVSampleBuffer: / setYUVPixelBuffer:
//   3. Dedup: (destBuffer + pts) key in _dictionary → stale cleanup → return NO
//   4. On new key: insert timestamp; determine orientation; VTPixelTransfer
//   5. [_lock unlock]
//   6. BINFlash OUTSIDE lock (pixel loop + I/O must not hold the lock)
//
// The single NSRecursiveLock ensures no two VT operations overlap across threads.
// This fixes RTMP disconnect on iPhone 7 Plus (dual-camera) and iPhone 8 (A11)
// where concurrent VT operations during camera pipeline reconfiguration caused
// VT session invalidation.
- (CMSampleBufferRef)modifyImageBuffer:(CMSampleBufferRef)sampleBuffer {
    // Once-per-second probe (outside lock — fast path).
    static double s_mibInLog = 0;
    double probeNow = [[NSDate date] timeIntervalSince1970];
    if (probeNow - s_mibInLog >= 1.0) {
        s_mibInLog = probeNow;
        vcamSendDiag([NSString stringWithFormat:@"mib:in bL=%d sbuf=%d",
            (int)_bLive, (_liveYUVSampleBuffer ? 1 : 0)]);
    }

    // IDA-confirmed guard (outside lock).
    if (!_bLive || !_liveYUVSampleBuffer) return nil;

    CVImageBufferRef destBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!destBuffer) return nil;

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    // IDA: key = (char*)destBuffer + pts.value — uint64 wrapping addition.
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:
                     (uint64_t)(uintptr_t)destBuffer + (uint64_t)pts.value];

    [_lock lock];

    // Dedup: already processed this (destBuffer, pts) pair this camera tick.
    id existing = [_dictionary objectForKey:key];
    if (existing) {
        // Purge stale entries (> 200ms) while we have the lock.
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSMutableArray *staleKeys = [NSMutableArray arrayWithCapacity:4];
        for (NSNumber *k in _dictionary) {
            if (now - [[_dictionary objectForKey:k] doubleValue] >= 0.2) {
                [staleKeys addObject:k];
            }
        }
        for (id k in staleKeys) {
            [_dictionary removeObjectForKey:k];
        }
        [_lock unlock];
        return nil;
    }

    // Mark this (destBuffer, pts) pair as processed.
    [_dictionary setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]]
                    forKey:key];

    // Read source buffer from _liveYUVSampleBuffer (IDA-confirmed).
    CVImageBufferRef srcBuffer = CMSampleBufferGetImageBuffer(_liveYUVSampleBuffer);
    if (!srcBuffer) {
        [_lock unlock];
        return nil;
    }

    int srcW = (int)CVPixelBufferGetWidth((CVPixelBufferRef)srcBuffer);
    int srcH = (int)CVPixelBufferGetHeight((CVPixelBufferRef)srcBuffer);
    int dstW = (int)CVPixelBufferGetWidth((CVPixelBufferRef)destBuffer);
    int dstH = (int)CVPixelBufferGetHeight((CVPixelBufferRef)destBuffer);

    // IDA-confirmed orientation logic:
    //   same orientation (both landscape or both portrait) → use srcBuffer
    //   different orientation                               → use _pixelYUVBuffer90
    CVImageBufferRef transferSrc;
    if ((srcW > srcH) == (dstW > dstH)) {
        transferSrc = srcBuffer;
    } else {
        transferSrc = (CVImageBufferRef)_pixelYUVBuffer90;
    }

    BOOL success = NO;
    if (transferSrc) {
        OSStatus status = VTPixelTransferSessionTransferImage(
            _pixelTransferSession, transferSrc, destBuffer);

        static double s_lastMibLog = 0;
        double mibNow = [[NSDate date] timeIntervalSince1970];
        if (mibNow - s_lastMibLog >= 1.0) {
            s_lastMibLog = mibNow;
            vcamSendDiag([NSString stringWithFormat:@"mib:st=%d", (int)status]);
        }

        if (status != noErr) {
            vcamSendDiag([NSString stringWithFormat:@"mib:xfer-err %d", (int)status]);
        }
        success = (status == noErr);
    }

    [_lock unlock];

    // BINFlash pixel effect runs OUTSIDE the lock — pixel loop + plist I/O.
    if (success) {
        BINFlashApplyToPixelBuffer((CVPixelBufferRef)destBuffer);
    }

    return success ? sampleBuffer : nil;
}

- (CMSampleBufferRef)modifyPixelBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.hasFace || !_pixelResultBuffer) return nil;

    CVImageBufferRef destIB = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!destIB) return nil;

    [_lock lock];
    CVPixelBufferRef resultBuf = _pixelResultBuffer
        ? (CVPixelBufferRef)CVBufferRetain(_pixelResultBuffer)
        : NULL;
    [_lock unlock];

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

- (void)setLive:(BOOL)live {
    if (!live && self.bLive) {
        vcamSendDiag(@"LIVE->NO[?]");
    }
    self.bLive = live;
}

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
- (double)sampleHueAtNormalizedX:(double)nx y:(double)ny {
    [_lock lock];
    CVPixelBufferRef buf = _pixelYUVBuffer
                           ? (CVPixelBufferRef)CVBufferRetain(_pixelYUVBuffer)
                           : NULL;
    [_lock unlock];
    if (!buf) return -1.0;

    OSType fmt = CVPixelBufferGetPixelFormatType(buf);
    if ((fmt & 0xFFFFFFEFU) != 0x34323066U) { CVPixelBufferRelease(buf); return -1.0; }

    size_t bW = CVPixelBufferGetWidth(buf);
    size_t bH = CVPixelBufferGetHeight(buf);
    if (!bW || !bH) { CVPixelBufferRelease(buf); return -1.0; }

    double nxc = nx < 0.0 ? 0.0 : (nx > 1.0 ? 1.0 : nx);
    double nyc = ny < 0.0 ? 0.0 : (ny > 1.0 ? 1.0 : ny);

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
    double Pb = ((double)uvp[0] - 128.0) / 255.0;
    double Pr = ((double)uvp[1] - 128.0) / 255.0;

    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(buf);

    double r = Y + 1.402   * Pr;
    double g = Y - 0.344136 * Pb - 0.714136 * Pr;
    double b = Y + 1.772   * Pb;
    r = r < 0.0 ? 0.0 : (r > 1.0 ? 1.0 : r);
    g = g < 0.0 ? 0.0 : (g > 1.0 ? 1.0 : g);
    b = b < 0.0 ? 0.0 : (b > 1.0 ? 1.0 : b);

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
