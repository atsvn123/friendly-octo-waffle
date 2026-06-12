// VCamLiveManager.h
// Reconstructed from ifdsflwoWdasdYfsdfJd (0x12ADB0)
// Singleton managing live virtual camera state + frame replacement

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "../include/VideoToolboxPrivate.h"

@interface VCamLiveManager : NSObject

// Virtual camera state
@property (nonatomic, assign) BOOL bLive;
@property (nonatomic, assign) BOOL hasFace;
@property (nonatomic, assign) int  sourcePosition;
@property (nonatomic, assign) BOOL floatWindow;
@property (nonatomic, assign) BOOL cameraSelected;
@property (nonatomic, assign) BOOL switchFace;

// Beauty filter parameters
@property (nonatomic, assign) float thinFacePercent;
@property (nonatomic, assign) float bigEyePercent;
@property (nonatomic, assign) float bigMouthPercent;
@property (nonatomic, assign) float bigNosePercent;
@property (nonatomic, assign) float dermabrasionPercent;

// Live frame buffers (all assign — manual CF memory management)
@property (nonatomic, assign) CMSampleBufferRef liveYUVSampleBuffer;   // _liveYUVSampleBuffer
@property (nonatomic, assign) CMSampleBufferRef liveBGRASampleBuffer;  // _liveBGRASampleBuffer

// Pixel buffers
@property (nonatomic, assign) CVPixelBufferRef pixelYUVBuffer;         // _pixelYUVBuffer
@property (nonatomic, assign) CVPixelBufferRef pixelYUVBuffer90;       // _pixelYUVBuffer90 (pre-rotated)
@property (nonatomic, assign) CVPixelBufferRef pixelBGRABuffer90;      // _pixelBGRABuffer90
@property (nonatomic, assign) CVPixelBufferRef pixelResultBuffer;      // _pixelResultBuffer (face swap result)
@property (nonatomic, assign) CVPixelBufferRef pixelResult90Buffer;    // _pixelResult90Buffer

// VideoToolbox sessions
@property (nonatomic, assign) VTPixelTransferSessionRef  pixelTransferSession;       // _pixelTransferSession
@property (nonatomic, assign) VTPixelTransferSessionRef  pixelSampleTransferSession; // _pixelSampleTransferSession
@property (nonatomic, assign) VTImageRotationSessionRef  imageRotationSession;       // _imageRotationSession

// App filter
@property (nonatomic, copy) NSString *applicationID;

+ (instancetype)sharedInstance;

// State accessors
- (BOOL)getLive;
- (void)setLive:(BOOL)live;
- (void)setSwitchFace:(BOOL)flag;
- (BOOL)getFloatWindow;

// ── Frame input (called by VCamBridge after RTMP decode) ──────────────────────
// setYUVSampleBuffer: is the PRIMARY path: stores decoded frame + pre-rotates
- (void)setYUVSampleBuffer:(CMSampleBufferRef)sbuf;
- (void)setYUVPixelBuffer:(CVPixelBufferRef)pixbuf;
- (void)setBGRASampleBuffer:(CMSampleBufferRef)sbuf;

// ── Frame injection (called from BWNodeOutput hook) ───────────────────────────
// Returns the input sampleBuffer if pixels were replaced in-place, nil otherwise.
// (Return type is id/CMSampleBufferRef so BINFlashCamera can hook and apply flash.)
- (CMSampleBufferRef)modifyImageBuffer:(CMSampleBufferRef)sampleBuffer;
- (CMSampleBufferRef)modifyPixelBuffer:(CMSampleBufferRef)sampleBuffer;

// ── Buffer factory (used in face-swap mode) ───────────────────────────────────
- (CMSampleBufferRef)createSampleBuffer:(CMSampleBufferRef)srcSbuf;
- (CMSampleBufferRef)getSampleBuffer:(CMSampleBufferRef)refSbuf;
- (CMSampleBufferRef)get90SampleBuffer:(CMSampleBufferRef)refSbuf;

// ── Beauty parameter setters ──────────────────────────────────────────────────
- (void)setThinFacePercent:(float)p;
- (void)setBigEyePercent:(float)p;
- (void)setBigMouthPercent:(float)p;
- (void)setBigNosePercent:(float)p;
- (void)setDermabrasionPercent:(float)p;

// ── Configuration ─────────────────────────────────────────────────────────────
- (void)setApplicationID:(NSString *)appID;
- (void)setOrientation:(int)orientation;

// ── Video file reading ────────────────────────────────────────────────────────
- (void)startReading:(NSURL *)url;
- (void)cancelReading;

// ── Background run loop ───────────────────────────────────────────────────────
- (void)run;

@end
