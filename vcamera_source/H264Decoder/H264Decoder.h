// H264Decoder.h
// VideoToolbox-backed H.264 decoder.
// Reconstructed from the H264Decoder class referenced at 0xA2998 (RTMPServer::startServerLoop).
//
// Flow:
//   1. RTMPServer calls [initDecoder:sps:sps_size:pps:pps_size:] with first AVC sequence header.
//   2. RTMPServer calls [decode:size:] for each NAL unit payload.
//   3. Decoded CVPixelBuffer (NV12/420v YUV) is wrapped in a CMSampleBuffer and
//      forwarded to the delegate via outputFrame:presentationTimeStamp:presentationDuration:.

#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

@protocol H264DecoderDelegate <NSObject>
- (void)outputFrame:(void *)frameData
 presentationTimeStamp:(int64_t)pts
  presentationDuration:(int64_t)duration;
@end

@interface H264Decoder : NSObject

@property (nonatomic, assign) id<H264DecoderDelegate> delegate;

// Initialise the VTDecompressionSession with raw SPS and PPS.
// spsData/ppsData: raw NAL bytes (no start code, no AVCC length prefix).
- (BOOL)initDecoder:(const uint8_t *)spsData spsSize:(size_t)spsSize
                pps:(const uint8_t *)ppsData ppsSize:(size_t)ppsSize;

// Decode one AVCC NAL payload.
//   pts = RTMP display timestamp in ms (DTS + signedCTS)
// pts is forwarded to the software reorder buffer via sourceFrameRefCon so the
// buffer can sort decoded frames into display order (handles B-frames).
- (void)decode:(const uint8_t *)data size:(size_t)size pts:(int32_t)pts;

// Tear down the VTDecompressionSession.
- (void)endDecode;

// Try to reinitialize using saved SPS/PPS from last successful initDecoder:.
// Use after stopDecoding/endDecode to resume without waiting for a new sequence header.
- (BOOL)reinitFromSaved;

@end
