# Camera Replace + RTMP Connection — Full Flow (IDA-Verified)

## Overview

Virtual camera replacement works in two coordinated processes:
- **mediaserverd**: runs RTMP server, decodes H.264, stores frames
- **SpringBoard**: sends IPC commands, shows UI

---

## 1. Startup Flow

### mediaserverd (`vcamera.dylib`)
```
InitFunc_0 (constructor)
  → detectProcess()
  → if mediaserverd/lskdd:
      installMediaServerHooks()
        → MSHookMessageEx on BWNodeOutput::emitSampleBuffer:
        → MSHookMessageEx on VTPixelTransferSession*
        → MSHookMessageEx on CMSampleBufferCreate* (3 functions)
      [VCamBridge sharedInstance].listen()
        → ServerSocket.create(port=22222, callback)
        → [CFRunLoop run] — blocks in media server thread
```

### SpringBoard (`vcamera.dylib`)
```
InitFunc_0 (constructor)
  → installSpringBoardHooks()
      → MSHookMessageEx on UIApplication hooks (gesture/float window)
  → [VCamBridge sharedInstance].connect()
      → [VCamClientSocket create:@"127.0.0.1" port:22222]
      → TCP connect to mediaserverd on port 22222
```

---

## 2. IPC Protocol (port 22222)

SpringBoard → mediaserverd (OUR sends):
```
1000 [4B]           — Enable virtual camera + start RTMP server
1001 [4B]           — Disable virtual camera + stop RTMP server
1002 [4B] [float]   — Set dermabrasion
1003 [4B] [float]   — Set thin face
1004 [4B] [5×float] — Set 5 beauty params
1005 [4B] [int]     — Set switch face mode (1=on, 0=off)
1008 [4B] [float]   — Set big eye
1009 [4B] [float]   — Set big nose
1013 [4B]           — Logout
1014 [4B] [paylen] [ulen] [user] [plen] [pass]  — Login
1018 [4B] [int]     — Set camera (0=back, 1=front)
```

mediaserverd → SpringBoard (server sends):
```
1007 [4B] [width:4B] [height:4B]  — Resolution update (after 1000)
1012 [4B] [msglen:4B] [msg]       — Login error
1013 [4B]                          — Logout from server
1015 [4B]                          — Login success
```

---

## 3. RTMP Server Startup (code 1000 received)

```
VCamBridge.parse:socketHandle: receives code 1000
  → [self stop]                              — kill previous server
  → [[VCamLiveManager sharedInstance] setLive:YES]
  → if !_server:
      → RTMPServer *s = [[RTMPServer alloc] init]
      → s.delegate = VCamBridge           — so VCamBridge gets decoded frames
      → [s startServerLoop]
          → H264Decoder *decoder = [[H264Decoder alloc] init]
          → decoder.delegate = RTMPServer  — so RTMPServer gets decoded frames
          → [NSThread start:handleRTMP]    — RTMPThread
  → send 1007 {1280,720} back to SpringBoard
```

---

## 4. RTMP Connection Loop (RTMPThread)

```
RTMPServer.handleRTMP
  → [RTMPServer runRTMPLoop:self]    (RTMPServerCXX.mm)
      → tcpServer = new TCPServer(port=1935)
      → g_tcpServer = tcpServer       — stored globally for destroy() on stop
      → while (server.isRunning):
          → clientFd = tcpServer.accept()   — blocks until OBS connects
          → layer    = new DataLayer(clientFd)
          → endpoint = new RTMPEndpoint(layer)
          → endpoint.doHandshake()          — RTMP C0/C1/S0/S1/S2 handshake
          → session  = new RTMPServerSession(endpoint)
              → sends WindowAckSize(2.5MB)
              → sends SetPeerBandwidth(2.5MB)
              → sends SetChunkSize(4096)
          → while (server.isRunning):
              → frame = session.GetRTMPMessage()
                  → loops internally until video message type arrives
                  → handles: connect → sendConnectResult
                  → handles: createStream → sendCreateStreamResult
                  → handles: publish → sendPublishStart
                  → handles: video message (type=9):
                      strips 5-byte RTMP AVC header
                      if avcPacketType==0 (sequence header):
                          parses AVCC record: SPS + PPS
                          frame.isSequenceHeader = true
                          frame.sps = raw SPS bytes
                          frame.pps = raw PPS bytes
                      if avcPacketType==1 (NALU):
                          frame.isSequenceHeader = false
                          frame.nalu = [4-byte-BE-len][NALU][4-byte-BE-len][NALU]...
                          (AVCC format, one entry per NAL in the video frame)
              → if frame.isSequenceHeader:
                  [decoder initDecoder:frame.sps.data() spsSize:frame.sps.size()
                               pps:frame.pps.data() ppsSize:frame.pps.size()]
              → else:
                  [decoder decode:frame.nalu.data() size:frame.nalu.size()]
```

---

## 5. H264Decoder — Session Initialization (`initDecoder:spsSize:pps:ppsSize:`)

Verified from IDA decompile of `-[ifQwsadqYeweSwedHse initDecoder:sps_size:pps:pps_size:]` at 0x94844.

```
1. [self endDecode]           — destroy any previous session
2. CMVideoFormatDescriptionCreateFromH264ParameterSets(
       kCFAllocatorDefault, 2,
       {spsData, ppsData}, {spsSize, ppsSize},
       4,                         — 4-byte AVCC NAL length prefix
       &_decoderFormatDescription)
3. Parse video dimensions from format description:
       CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(_decoderFormatDescription)
       _width  = dim.width
       _height = dim.height
       (original uses sps_parser() — equivalent result)

4. destinationImageBufferAttributes = {
       kCVPixelBufferPixelFormatTypeKey:     kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ('420f')
       kCVPixelBufferWidthKey:               _width
       kCVPixelBufferHeightKey:              _height
       kCVPixelBufferOpenGLCompatibilityKey: YES
       ← NO IOSurface properties (common mistake to add these)
   }

5. videoDecoderSpecification = {
       kCVImageBufferChromaLocationBottomFieldKey: kCVImageBufferChromaLocation_Left
       kCVImageBufferChromaLocationTopFieldKey:    kCVImageBufferChromaLocation_Left
       kCVImageBufferColorPrimariesKey:            kCVImageBufferColorPrimaries_ITU_R_709_2
       kCVImageBufferTransferFunctionKey:          kCVImageBufferTransferFunction_ITU_R_709_2
       kCVImageBufferYCbCrMatrixKey:               kCVImageBufferYCbCrMatrix_ITU_R_601_4
   }

6. VTDecompressionSessionCreate(
       kCFAllocatorDefault,
       _decoderFormatDescription,
       videoDecoderSpecification,        — color space for output buffers
       destinationImageBufferAttributes, — pixel format + size
       &callback{VTDecodeCallback, self},
       &_decoderSession)

7. VTSessionSetProperty(_decoderSession, kVTDecompressionPropertyKey_ThreadCount, @2)
8. VTSessionSetProperty(_decoderSession, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue)
```

---

## 6. H264Decoder — Frame Decode (`decode:size:`)

Verified from IDA decompile of `-[ifQwsadqYeweSwedHse decode:size:]` at 0x94C9C.

```
data = AVCC-formatted: [4-byte-BE-len][NALU][4-byte-BE-len][NALU]...
       (NO start codes; NO additional wrapping needed)

1. CMBlockBufferCreateWithMemoryBlock(
       kCFAllocatorDefault,
       data, size,
       kCFAllocatorNull,      — NO ownership; data must outlive decode (safe: synchronous)
       NULL, 0, size, 0,
       &blockBuf)

2. CMSampleBufferCreateReady(
       kCFAllocatorDefault, blockBuf,
       _decoderFormatDescription,
       numSamples=1,
       numTimingEntries=0, timingArray=NULL,   — NO timing info
       numSizeEntries=1, &size,
       &sampleBuf)

3. VTDecompressionSessionDecodeFrame(
       _decoderSession, sampleBuf,
       flags=0,                — SYNCHRONOUS (blocks until callback fires)
       &sourceFrameRefCon,
       &infoFlagsOut)

4. CFRelease(sampleBuf)
5. CFRelease(blockBuf)
```

---

## 7. VTDecodeCallback (sub_94BE0)

```
if (status == noErr && infoFlags != kVTDecodeInfo_FrameDropped):
    id decoder = (H264Decoder *)outputRefCon
    [decoder retain]
    id delegate = [decoder delegate]
    if delegate:
        [delegate outputFrame:(CVImageBufferRef)imageBuffer
             presentationTimeStamp:pts    — CMTime passed as pointer (original)
              presentationDuration:duration]
    [decoder release]
```

Key: passes **raw CVImageBufferRef** directly to delegate. Does NOT wrap in CMSampleBuffer.

---

## 8. RTMPServer → VCamBridge → VCamLiveManager

```
RTMPServer.outputFrame:(CVImageBufferRef)frameData pts:... dur:...
  → VCamBridge.outputFrame:                           — (RTMPServerDelegate)

VCamBridge.outputFrame:(CVImageBufferRef)imageBuffer ...
  → CMSampleBufferRef sbuf = [self imageBufferToSampleBuffer:imageBuffer
                                                   timeStamp:_beginTimeYUV]
      → CVPixelBufferLockBaseAddress(imageBuffer, 0)
      → CMVideoFormatDescriptionCreateForImageBuffer(imageBuffer) → fmtDesc
      → CMSampleTimingInfo:
            duration = kCMTimeInvalid (zeroed)
            presentationTimeStamp = CMTime{_beginTimeYUV * 600, timescale=600, flags=Valid}
            decodeTimeStamp = kCMTimeInvalid (zeroed)
      → CMSampleBufferCreateForImageBuffer(imageBuffer, fmtDesc, &timing) → sbuf
      → CVPixelBufferUnlockBaseAddress(imageBuffer, 0)
      → CFRelease(fmtDesc)
      → return sbuf (+1 retained)
  → [[VCamLiveManager sharedInstance] setYUVSampleBuffer:sbuf]
  → CFRelease(sbuf)
  → _beginTimeYUV += 20.0
```

---

## 9. VCamLiveManager — Frame Storage (`setYUVSampleBuffer:`)

```
setYUVSampleBuffer:(CMSampleBufferRef)sbuf
  → [self.lock lock]
  → CMSampleBufferCreateCopy(sbuf) → _liveYUVSampleBuffer
      (shallow copy; both reference same CVImageBuffer)
  → CVPixelBufferRef src = CMSampleBufferGetImageBuffer(sbuf)
  → _pixelYUVBuffer90 = [self create90ImageBuffer:src]
      → VTImageRotationSessionTransferImage(_imageRotationSession, src, dst90°)
  → [self.lock unlock]
```

---

## 10. Camera Frame Injection (`modifyImageBuffer:`)

Called from hooked `BWNodeOutput::emitSampleBuffer:` for EVERY camera frame.

```
BWNodeOutput::emitSampleBuffer:(CMSampleBufferRef)sampleBuffer
  → VCamLiveManager.modifyImageBuffer:(CMSampleBufferRef)sampleBuffer
      → if !bLive || !_liveYUVSampleBuffer: return nil
      → [self.lock lock]
      → destBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)  — real camera pixel buffer
      → dedup check (ptr + pts.value hash)
      → srcBuffer = CMSampleBufferGetImageBuffer(_liveYUVSampleBuffer)  — OBS frame
      → select orientation-matched source:
          if srcW>srcH == dstW>dstH → use srcBuffer
          else → use _pixelYUVBuffer90 (90° pre-rotated)
      → VTPixelTransferSessionTransferImage(
              _pixelTransferSession,   — configured for ITU-R 709/601 color space
              transferSrc,             — OBS decoded frame
              destBuffer)              — real camera frame (overwritten in-place!)
      → [self.lock unlock]
      → return sampleBuffer if status==noErr (so BINFlashCamera can also hook it)
```

After `modifyImageBuffer:` returns the modified sampleBuffer, the camera system uses the buffer
which now contains OBS video instead of real camera pixels.

---

## 11. Server Stop (code 1001 received or toggle off)

```
VCamBridge.parse: receives code 1001
  → [self stop]
      → [_server stopServer]
          → _server.isRunning = NO
          → [RTMPServer destroyActiveTCPServer]
              → g_tcpServer->destroy()       — shutdown() + close() on listen fd
              → unblocks tcpServer->accept()
          → sleep(1)
          → [self.RTMPThread cancel]
          → [self.h264Decoder endDecode]
              → VTDecompressionSessionInvalidate + CFRelease
              → CFRelease(_decoderFormatDescription)
              → free(_sps), free(_pps)
          → self.h264Decoder = nil
      → _server = nil
  → [[VCamLiveManager sharedInstance] setLive:NO]
```

---

## 12. Known Bugs Fixed in v2.16

| # | File | Bug | Fix |
|---|------|-----|-----|
| 1 | RTMPServerSession.cpp | Stripped AVCC 4-byte length prefix from frame.nalu | Keep prefix; store `[4-byte-len][NALU]` per NALU |
| 2 | H264Decoder.m decode:size: | Re-added length prefix to already-raw data; malloc+async | No prefix; kCFAllocatorNull; synchronous (flags=0) |
| 3 | H264Decoder.m initDecoder: | Wrong pixel format '420v' | Use '420f' (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) |
| 4 | H264Decoder.m initDecoder: | No width/height in pixelBufferAttrs | Add kCVPixelBufferWidthKey/HeightKey from CMFormatDescription |
| 5 | H264Decoder.m initDecoder: | IOSurface dict present; no OpenGLCompatibility | Remove IOSurface; add OpenGLCompatibility=YES |
| 6 | H264Decoder.m initDecoder: | NULL videoDecoderSpecification | Pass color space dict (ChromaLocation + ITU-R 709 + 601-4 matrix) |
| 7 | H264Decoder.m initDecoder: | No ThreadCount/RealTime session properties | VTSessionSetProperty ThreadCount=2, RealTime=YES |
| 8 | H264Decoder.m VTDecodeCallback | Wrapped CVImageBuffer in CMSampleBuffer | Pass raw CVImageBufferRef directly to delegate |
| 9 | VCamBridge.m outputFrame: | CFGetTypeID check for CMSampleBuffer/CVImageBuffer | Always call imageBufferToSampleBuffer: with raw CVImageBufferRef |
| 10 | VCamBridge.m imageBufferToSampleBuffer: | No CVPixelBufferLockBaseAddress | Lock before CMVideoFormatDescriptionCreateForImageBuffer, unlock after CMSampleBufferCreateForImageBuffer |
