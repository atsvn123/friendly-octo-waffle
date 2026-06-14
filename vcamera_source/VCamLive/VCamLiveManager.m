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

// Effective rotation applied to the RTMP frame for the current/last modifyImageBuffer: call.
// 0 = no rotation (or same-orientation auto-branch), 90/180/270 = degrees CW.
// Read by BINFlashFaceRegion to adjust face ellipse and clear stale position on change.
int g_effectiveRTMPRotation = 0;

// ─────────────────────────────────────────────────────────────────────────────
@implementation VCamLiveManager {
    // IDA-confirmed: single NSRecursiveLock that serializes ALL frame operations.
    NSRecursiveLock    *_lock;

    // IDA-confirmed dedup dictionary (maps key → timestamp NSNumber).
    NSMutableDictionary *_dictionary;

    // User's intended live state — set ONLY by IPC code 1000 (YES) / 1001 (NO).
    // When something spuriously calls setLive:NO while the user wants LIVE,
    // setYUVSampleBuffer: auto-restores bLive to YES as long as _userIntentLive is set.
    BOOL _userIntentLive;

    // RTMP rotation: -1 = Auto (orientation-detect, IDA-original), 0/90/180/270 = fixed.
    // Updated via setRTMPRotation: (IPC code 1019 from SpringBoard menu).
    int _rtmpRotation;

    // Additional cached rotation sessions for 180° and 270° rotations.
    // The 90° session is the IDA-original _imageRotationSession.
    VTImageRotationSessionRef _imageRotationSession180;
    VTImageRotationSessionRef _imageRotationSession270;
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

        VTImageRotationSessionCreate(kCFAllocatorDefault, 180, &_imageRotationSession180);
        VTSessionSetProperty((VTSessionRef)(void *)_imageRotationSession180,
                             kVTImageRotationPropertyKey_EnableHighSpeedTransfer,
                             kCFBooleanTrue);

        VTImageRotationSessionCreate(kCFAllocatorDefault, 270, &_imageRotationSession270);
        VTSessionSetProperty((VTSessionRef)(void *)_imageRotationSession270,
                             kVTImageRotationPropertyKey_EnableHighSpeedTransfer,
                             kCFBooleanTrue);

        _rtmpRotation = -1;  // Auto by default (IDA-original orientation detection)
        _userIntentLive = NO;

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
    return [self createRotImageBuffer:src session:_imageRotationSession swapDims:YES];
}

// createRotImageBuffer:session:swapDims: — generic rotation into an IOSurface buffer.
// swapDims=YES for 90°/270° (output W/H swapped vs input), NO for 180° (same dims).
- (CVPixelBufferRef)createRotImageBuffer:(CVPixelBufferRef)src
                                 session:(VTImageRotationSessionRef)session
                                swapDims:(BOOL)swapDims
{
    if (!src || !session) return NULL;
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    int srcW = (int)CVPixelBufferGetWidth(src);
    int srcH = (int)CVPixelBufferGetHeight(src);
    int dstW = swapDims ? srcH : srcW;
    int dstH = swapDims ? srcW : srcH;

    NSDictionary *ioSurfaceProps = @{
        @"IOSurfacePreallocPages":    @0,
        @"IOSurfacePurgeWhenNotInUse": @1,
    };
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: ioSurfaceProps,
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, (size_t)dstW, (size_t)dstH, fmt,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess) {
        return NULL;
    }
    if (VTImageRotationSessionTransferImage(session, src, dst) != noErr) {
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
// Extended in v2.115:
//   - Logs OBS stream dimensions when they change (obs:WxH diagnostic).
//   - Creates pre-rotated buffer based on _rtmpRotation instead of always 90°.
//   - Auto-resumes bLive if _userIntentLive is YES but bLive was spuriously cleared.
- (void)setYUVSampleBuffer:(CMSampleBufferRef)sbuf {
    if (!sbuf) return;

    // Track OBS stream dimensions — log once when size changes.
    static int s_obsW = 0, s_obsH = 0;
    CVImageBufferRef ibuf = CMSampleBufferGetImageBuffer(sbuf);
    if (ibuf) {
        int w = (int)CVPixelBufferGetWidth((CVPixelBufferRef)ibuf);
        int h = (int)CVPixelBufferGetHeight((CVPixelBufferRef)ibuf);
        if (w != s_obsW || h != s_obsH) {
            s_obsW = w; s_obsH = h;
            vcamSendDiag([NSString stringWithFormat:@"obs:%dx%d", w, h]);
        }
    }

    [_lock lock];

    CMSampleBufferRef old = _liveYUVSampleBuffer;
    if (old) { CFRelease(old); _liveYUVSampleBuffer = NULL; }
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sbuf, &_liveYUVSampleBuffer);

    // Pre-rotate based on _rtmpRotation.
    // -1 (Auto) and 90: use 90° session (IDA-original; used by Auto orientation detection).
    // 0: no pre-rotation.
    // 180: use 180° session (same dimensions).
    // 270: use 270° session (dimensions swapped again).
    CVPixelBufferRef old90 = _pixelYUVBuffer90;
    if (old90) { CFRelease(old90); _pixelYUVBuffer90 = NULL; }

    CVPixelBufferRef src = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sbuf);
    int rot = _rtmpRotation;
    if (rot == 0) {
        // No pre-rotation needed; modifyImageBuffer: will use srcBuffer directly.
    } else if (rot == 180) {
        _pixelYUVBuffer90 = [self createRotImageBuffer:src
                                               session:_imageRotationSession180
                                              swapDims:NO];
    } else if (rot == 270) {
        _pixelYUVBuffer90 = [self createRotImageBuffer:src
                                               session:_imageRotationSession270
                                              swapDims:YES];
    } else {
        // Auto (-1) or explicit 90°: 90° rotation (IDA-original path).
        _pixelYUVBuffer90 = [self create90ImageBuffer:src];
    }

    [_lock unlock];

    // Auto-resume injection if RTMP frames are arriving but bLive was spuriously cleared.
    // _userIntentLive is only set by IPC code 1000 (YES) / 1001 (NO).
    // This prevents unknown callers of setLive:NO from permanently breaking injection
    // while the user wants LIVE on and frames are actively arriving.
    if (_userIntentLive && !self.bLive) {
        vcamSendDiag(@"bLive:auto-resume");
        self.bLive = YES;
    }
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

    // Prevent unbounded growth: pts is always unique per camera frame, so dedup hits
    // (and their built-in cleanup) never fire. Purge stale entries whenever we exceed
    // a reasonable cap (>20 entries = >650ms of frames at 30fps).
    if ([_dictionary count] > 20) {
        NSTimeInterval cleanNow = [[NSDate date] timeIntervalSince1970];
        NSMutableArray *stale = [NSMutableArray arrayWithCapacity:8];
        for (NSNumber *k in _dictionary) {
            if (cleanNow - [[_dictionary objectForKey:k] doubleValue] >= 0.2) [stale addObject:k];
        }
        for (id k in stale) [_dictionary removeObjectForKey:k];
    }

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

    // Source buffer selection — either auto (IDA-original) or user-configured rotation.
    // _rtmpRotation == -1: Auto — detect orientation from buffer dimensions.
    // _rtmpRotation == 0:  No rotation — always use srcBuffer directly.
    // _rtmpRotation > 0:   Fixed rotation — use pre-rotated _pixelYUVBuffer90.
    CVImageBufferRef transferSrc;
    int rot = _rtmpRotation;
    if (rot == 0) {
        // User selected "no rotation" — inject RTMP landscape as-is.
        transferSrc = srcBuffer;
        g_effectiveRTMPRotation = 0;
    } else if (rot > 0) {
        // User selected explicit angle — use the pre-rotated buffer.
        transferSrc = (CVImageBufferRef)_pixelYUVBuffer90;
        g_effectiveRTMPRotation = rot;  // 90, 180, or 270
    } else {
        // Auto (IDA-confirmed 0x92080): same orientation → srcBuffer, different → 90° buffer.
        if ((srcW > srcH) == (dstW > dstH)) {
            transferSrc = srcBuffer;
            g_effectiveRTMPRotation = 0;
        } else {
            transferSrc = (CVImageBufferRef)_pixelYUVBuffer90;
            g_effectiveRTMPRotation = 90;
        }
    }

    // Once-per-second orientation diagnostic.
    static double s_oriLog = 0;
    double oriNow = [[NSDate date] timeIntervalSince1970];
    if (oriNow - s_oriLog >= 1.0) {
        s_oriLog = oriNow;
        int branch = (transferSrc == srcBuffer) ? 0 : 1;
        vcamSendDiag([NSString stringWithFormat:@"ori:src%dx%d dst%dx%d r%d b%d",
            srcW, srcH, dstW, dstH, rot, branch]);
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
        // Log which thread called setLive:NO so we can trace spurious callers in the debug view.
        NSString *thr = [NSThread currentThread].name;
        if (!thr || thr.length == 0)
            thr = [NSString stringWithFormat:@"thr%p", (void *)[NSThread currentThread]];
        vcamSendDiag([NSString stringWithFormat:@"LIVE->NO[%@]", thr]);
    }
    self.bLive = live;
}

// Called by parse: code 1000 (YES) / 1001 (NO) to record the user's explicit intent.
// As long as _userIntentLive is YES, setYUVSampleBuffer: will auto-restore bLive=YES
// whenever RTMP frames arrive, preventing spurious setLive:NO from breaking injection.
- (void)setLiveUserIntent:(BOOL)intent {
    _userIntentLive = intent;
    if (!intent) {
        // User explicitly turned off — clear bLive immediately (no auto-resume for this frame).
        self.bLive = NO;
    }
}

// Set RTMP rotation angle. Valid values: -1 (Auto), 0, 90, 180, 270.
// The change takes effect on the next RTMP frame (setYUVSampleBuffer: call).
- (void)setRTMPRotation:(int)degrees {
    static const int kValidAngles[] = {-1, 0, 90, 180, 270};
    BOOL valid = NO;
    for (int i = 0; i < 5; i++) {
        if (degrees == kValidAngles[i]) { valid = YES; break; }
    }
    if (!valid) return;
    _rtmpRotation = degrees;
    vcamSendDiag([NSString stringWithFormat:@"rot:%d", degrees]);
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

@end
