# vcamera.dylib — Full Reverse Engineering Flow

> All claims in this document are backed by IDA decompilation, disassembly, or string cross-references. No guessing.

---

## 1. Binary Overview

| Property | Value |
|---|---|
| File | `vcamera.dylib` |
| Arch | ARM64 (iOS MobileSubstrate tweak) |
| Size | ~1.2 MB (`0x1313d8`) |
| Functions | 5,125 total (1,983 named) |
| Strings | 3,324 |
| IDB | `vcamera.dylib.i64` |

### Dependency
- `@rpath/CydiaSubstrate.framework/CydiaSubstrate` — imports `_MSHookMessageEx` (`0x1313d0`)

---

## 2. Injection Mechanism

### 2.1 MobileLoader Injection
The file `vcamera.plist` lists the apps/processes this dylib is injected into. MobileLoader (part of Cydia Substrate) reads this plist on process launch and calls `dlopen` on the dylib, triggering its `__init_offsets` constructors.

### 2.2 `__init_offsets` — Four Constructors

Located at segment `0xADDA0–0xADDAF`, containing 4 × 4-byte relative offsets:

| Constructor Address | Name | Purpose |
|---|---|---|
| `0x850FC` | `sub_850FC` | **Primary entry point** — process detection + thread spawn |
| `0x85264` | `nullsub_6` | Empty (no-op) |
| `0x852B4` | `sub_852B4` | **MSHookMessageEx installer** — 54 method hooks |
| `0x86A4C` | `sub_86A4C` | Registers `__cxa_atexit` cleanup (`sub_85268`) |

---

## 3. Primary Constructor: `sub_850FC` (`0x850FC`)

```
_dyld_register_func_for_add_image(_dyld_image_added)
processName = [NSProcessInfo processInfo].processName.lowercaseString

if processName contains "springboard":
    pthread_create(&assistiveThread, NULL, fTaqaTecczndwop, NULL)
else if processName contains "mediaserverd":
    serialNumber = MGCopyAnswer("SerialNumber")
    deviceKey    = MGCopyAnswer("k5lVWbXuiZHLA17KGiVUAA")   // ECID / device unique key
    pthread_create(&listenThread, NULL, fTaqadKfwromsnd, NULL)
```

**Key:** The dylib injects into **both** `mediaserverd` (the iOS camera daemon) and `SpringBoard` (the UI process), following different code paths.

### `_dyld_image_added` (`0x850D4`)
Calls `dladdr` on the new image header — used to locate the dylib's own base address for image tracking.

---

## 4. Process-Specific Threads

### 4.1 `mediaserverd` path — `fTaqadKfwromsnd` (`0x85094`)
```objc
iHwCjdhryRasdLfdeOsdPsa *shared = [iHwCjdhryRasdLfdeOsdPsa sharedInstance];
[shared listen];   // blocks — creates ServerSocket on port 22222
```

### 4.2 `springboard` path — `fTaqaTecczndwop` (`0x84C40`)
```objc
sleep(3);   // wait for mediaserverd server to start
iHwCjdhryRasdLfdeOsdPsa *shared = [iHwCjdhryRasdLfdeOsdPsa sharedInstance];
[shared connect];   // connects to 127.0.0.1:22222

while (!done) {
    if ([shared isConnected] && byte_130151 == 1) {
        dispatch_async(main_queue, ^{ /* show UI */ });
        usleep(200000);
    } else {
        usleep(600000);
    }
}
```

---

## 5. IPC: `iHwCjdhryRasdLfdeOsdPsa` (Singleton Bridge)

This is the central singleton connecting SpringBoard and mediaserverd over a local socket. The class name is obfuscated.

### 5.1 `listen` (mediaserverd side) — `0x8A214`
```objc
do {
    success = [_serverSocket create:22222 callback:^(connection){ /* handle */ }];
    usleep(10000);
} while (!success);
```
Creates a `ServerSocket` on **port 22222** (localhost TCP).

### 5.2 `connect` (springboard side) — `0x8AD84`
```objc
[_clientSocket create:@"127.0.0.1" port:22222];
```
Connects `iCsdweKdsfRwdaCbv` (client socket wrapper) to the server.

### 5.3 `init` — `0x87EF0`
Initializes: `isPresent=NO`, `isLogin=NO`, `seconds` (timestamp), `menuViewController=nil`.

### 5.4 `run` — `0x88404`
Reads `username` and `password` from internal state, packs them into `NSMutableData` packets (8-byte headers).

### 5.5 `sigin` — `0x88608`
Dispatches sign-in action to the main queue.

### 5.6 `setResolution:height:` — `0x8A678`
Called from the video frame hook every ~3 seconds to report actual camera resolution.

### 5.7 Key Properties
- `_serverSocket` — `ServerSocket` (mediaserverd side)
- `_clientSocket` — `iCsdweKdsfRwdaCbv` (springboard side)
- `_springBoard` — captured SpringBoard instance
- `_menuViewController` — float overlay UI

---

## 6. Method Hooking: `sub_852B4` (`0x852B4`)

This constructor uses `MSHookMessageEx` to hook **54 methods** across **21 private Apple classes** in `mediaserverd`. All hooks store the original IMP in `off_130xxx` globals for trampoline call-through.

### 6.1 Camera Pipeline (Fig* classes — Apple private)

| Class | Method Hooked | Hook IMP |
|---|---|---|
| `FigCaptureSessionConfiguration` | `addConnectionConfiguration:` | `sub_85A74` |
| `FigCaptureSessionConfiguration` | `setSessionPreset:` | `sub_85A80` |
| `FigCaptureSourceConfiguration` (meta) | `stringForSourcePosition:` | `sub_85A8C` |
| `FigCaptureSourceConfiguration` | `sourcePosition` | `sub_85AA0` |
| `FigCaptureSourceConfiguration` | `_sourceAttributes` | `sub_85AAC` |
| `FigCaptureSourceConfiguration` | `initWithSource:` | `sub_85AB8` |
| `FigCaptureSourceConfiguration` | `initWithSourceType:` | `sub_85AC4` |
| `FigCapturePipeline` | `graph` | `sub_85AD0` |
| `FigVideoCaptureConnectionConfiguration` | `setOutputFormat:` | `sub_85B84` |
| `FigVideoCaptureConnectionConfiguration` | `setOutputHeight:` | `sub_85B90` |
| `FigVideoCaptureConnectionConfiguration` | `setOutputWidth:` | `sub_85B9C` |

### 6.2 Camera Graph (BW* classes — mediaserverd internal)

| Class | Method Hooked | Hook IMP | Notes |
|---|---|---|---|
| `BWGraph` | `initWithConfigurationQueuePriority:` | `sub_85BA8` | Graph lifecycle |
| `BWGraph` | `_sinkNodes` | `sub_85C3C` | Output nodes |
| `BWGraph` | `_sourceNodes` | `sub_85C48` | Input nodes |
| `BWGraph` | `start:` | `sub_85C54` | Graph start |
| `BWGraph` | `stop:` | `sub_85D98` | Graph stop |
| `BWNodeOutput` | **`emitSampleBuffer:`** | `sub_85ED4` | **CORE: frame injection** |
| `BWPixelTransferNode` | `renderSampleBuffer:forInput:` | `sub_86070` | Pixel format conversion |
| `BWPixelTransferNode` | `setMaxInputLossyCompressionLevel:` | `sub_860D0` | |
| `BWPixelTransferNode` | `setMaxLossyCompressionLevel:` | `sub_860E0` | |
| `BWPixelTransferNode` | `setMaxOutputLossyCompressionLevel:` | `sub_860F0` | |
| `BWPixelTransferNode` | `setRotationDegrees:` | `sub_86100` | |
| `BWNode` | `renderSampleBuffer:forInput:` | `sub_8610C` | Base node render |
| `BWAudioConverterNode` | `renderSampleBuffer:forInput:` | `sub_8616C` | Audio passthrough |
| `BWAudioConverterNode` | `setSettings:` | `sub_86178` | |
| `BWVideoOrientationMetadataNode` | `setSourcePosition:` | `sub_85B18` | |
| `BWVideoOrientationMetadataNode` | `renderSampleBuffer:forInput:` | `sub_85B24` | |
| `BWStillImageScalerNode` | `_zoomAttachedMedias...scaleFactor:` | `sub_86184` | |
| `BWStillImageScalerNode` | `renderSampleBuffer:forInput:` | `sub_86230` | |
| `BWUBProcessorController` | `input:addFrame:isReferenceFrame:` | `sub_86290` | Ultra Blur |
| `BWPhotoEncoderNode` | `_generatePreviewForSampleBuffer:...` | `sub_86300` | |
| `BWPhotoEncoderNode` | `renderSampleBuffer:forInput:` | `sub_863AC` | Photo capture |
| `BWPhotoEncoderNode` | `_addAuxImages...(scaleFactor variant)` | `sub_8640C` | |
| `BWPhotoEncoderNode` | `_addAuxImages...(no scaleFactor)` | `sub_864C0` | |
| `BWPhotoEncoderNode` | `_encodePhotoForEncodingScheme:...` | `sub_86564` | |
| `BWPhotoEncoderNode` | `_addThumbnailForEncodingScheme:...` | `sub_86580` | |
| `BWCompressedShotBufferNode` | `renderSampleBuffer:forInput:` | `sub_86594` | |
| `BWCompressedShotBufferNode` | `setUncompressedEquivalentCapacity:` | `sub_865F4` | |
| `BWCompressedShotBufferNode` | `uncompressedEquivalentCapacity` | `sub_86600` | |
| `BWMetadataSourceNode` | `appendMetadataSampleBuffer:` | `sub_86618` | |
| `BWMetadataDetectorGatingNode` | `renderSampleBuffer:forInput:` | `sub_86660` | Face detection gate |
| `FBSOrientationUpdate` | `initWithOrientation:...` | `sub_8660C` | |
| `BWAmbientLightSensor` | `luxLevel` | `sub_86A00` | Lux data |
| `BWAmbientLightSensor` | `rearLuxLevel` | `sub_86A20` | |

### 6.3 SpringBoard Hooks

| Class | Method Hooked | Hook IMP | Purpose |
|---|---|---|---|
| `SpringBoard` | `applicationDidFinishLaunching:` | `sub_866C0` | Capture SpringBoard ref |
| `SpringBoard` | `isShowingHomescreen` | `sub_8673C` | |
| `SBLockScreenManager` | `lockScreenViewControllerWillDismiss` | `sub_86760` | Lock state |
| `SBLockScreenManager` | `lockScreenViewControllerWillPresent` | `sub_86784` | |
| `SBLockScreenManager` | `lockScreenViewControllerDidPresent` | `sub_867EC` | |
| `SBLockScreenManager` | `_isPasscodeVisible` | `sub_867F8` | |
| `SBLockScreenManager` | `isLockScreenActive` | `sub_86804` | |
| `SBLockScreenManager` | `setPasscodeVisible:animated:` | `sub_86810` | |
| `SBDashBoardLockScreenEnvironment` | `handleLockButtonPress` | `sub_8681C` | Button intercept |
| `SBDashBoardLockScreenEnvironment` | `handleVolumeUpButtonPress` | `sub_86878` | Volume up |
| `SBDashBoardLockScreenEnvironment` | `handleVolumeDownButtonPress` | `sub_8693C` | Volume down |

---

## 7. Core Video Injection: `sub_85ED4` (hook for `BWNodeOutput::emitSampleBuffer:`)

This is the function that performs the actual virtual camera frame injection.

```objc
// Hook for -[BWNodeOutput emitSampleBuffer:sbuf]
void hooked_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sbuf) {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sbuf);
    if (imageBuffer) {
        CVPixelBufferGetPixelFormatType(imageBuffer);
        size_t width  = CVPixelBufferGetWidth(imageBuffer);
        size_t height = CVPixelBufferGetHeight(imageBuffer);
        CMSampleBufferGetPresentationTimeStamp(sbuf);

        ifdsflwoWdasdYfsdfJd *state = [ifdsflwoWdasdYfsdfJd sharedInstance];
        BOOL isLive = [state getLive];
        [state release];

        if (isLive && width >= height) {   // landscape check
            // Update reported resolution every ~3 seconds
            if (timeSinceLastUpdate > 3.0) {
                iHwCjdhryRasdLfdeOsdPsa *bridge = [iHwCjdhryRasdLfdeOsdPsa sharedInstance];
                [bridge setResolution:width height:height];
                [bridge release];
            }
            // Replace pixel data in-place
            ifdsflwoWdasdYfsdfJd *state2 = [ifdsflwoWdasdYfsdfJd sharedInstance];
            [state2 modifyImageBuffer:sbuf];
            [state2 release];
        }
    }
    // Always call original
    original_emitSampleBuffer(self, _cmd, sbuf);
}
```

---

## 8. `modifyImageBuffer:` (`0x92080`) — Pixel Replacement

The actual pixel replacement using VideoToolbox:

```objc
- (BOOL)modifyImageBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_bLive || !_liveYUVSampleBuffer) return NO;
    [_lock lock];

    CVImageBufferRef destBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    // Dedup: skip if this exact (buffer_ptr + pts) combo was already processed
    NSNumber *key = [NSNumber numberWithUnsignedLongLong:(uintptr_t)destBuffer + pts.value];
    if ([_dictionary objectForKey:key]) {
        // Clean up dictionary entries older than 200ms
        [_lock unlock];
        return NO;
    }

    // Mark as processing
    [_dictionary setObject:[NSDate date].timeIntervalSince1970 forKey:key];

    CVImageBufferRef srcBuffer = CMSampleBufferGetImageBuffer(_liveYUVSampleBuffer);
    int srcW = CVPixelBufferGetWidth(srcBuffer);
    int srcH = CVPixelBufferGetHeight(srcBuffer);
    int dstW = CVPixelBufferGetWidth(destBuffer);
    int dstH = CVPixelBufferGetHeight(destBuffer);

    // Handle portrait/landscape orientation mismatch
    CVImageBufferRef transferSrc;
    if ((srcW > srcH) == (dstW > dstH)) {
        transferSrc = srcBuffer;           // same orientation
    } else {
        transferSrc = _pixelYUVBuffer90;   // 90-degree rotated pre-computed buffer
    }

    // Copy virtual camera pixels into real camera buffer (in-place replacement)
    BOOL success = (VTPixelTransferSessionTransferImage(_pixelTransferSession, transferSrc, destBuffer) == 0);
    [_lock unlock];
    return success;
}
```

**Mechanism:** `VTPixelTransferSessionTransferImage` writes the virtual camera frame directly into the destination `CVPixelBuffer` that mediaserverd will deliver to the app. The app never knows the frames were replaced.

---

## 9. RTMP Server (`RTMPServer` + C++ `librtmp`)

The virtual camera video source is received via RTMP streaming on **port 1935**.

### 9.1 `startServerLoop` (`0xA2998`)
```objc
- (void)startServerLoop {
    // Create C++ TCPServer on port 1935 (0x78F)
    _tcpServer = new TCPServer(0x78F);
    _h264Decoder = [[H264Decoder alloc] init];
    _h264Decoder.delegate = self;
    _isRunning = YES;
    _RTMPThread = [[NSThread alloc] initWithTarget:self selector:@selector(handleRTMP) object:nil];
    [_RTMPThread start];
}
```

### 9.2 `handleRTMP` (`0xA2BB8`)
```objc
- (void)handleRTMP {
    while (_isRunning) {
        @try {
            int clientSocket = _tcpServer->accept();
            DataLayer *layer = new DataLayer(clientSocket);
            RTMPEndpoint *endpoint = new librtmp::RTMPEndpoint(layer);
            RTMPServerSession *session = new librtmp::RTMPServerSession(endpoint);

            while (true) {
                RTMPMessage msg = session->GetRTMPMessage();
                // detect SPS (0xe1/0x67) and PPS (0x68) NAL units
                // call [_h264Decoder initDecoder:sps_size:pps:pps_size:]
                // call [_h264Decoder decode:size:]
            }
        } @catch (...) { NSLog(...); }
    }
}
```

### 9.3 RTMP AMF Message Handling (`RTMPServerSession::HandleAMF`) — `0xA0B44`
Full RTMP protocol implemented in C++ (`librtmp` namespace):
- `connect` → responds with `NetConnection.Connect.Success`, FMS version `3,5,3,824`
- `createStream` → allocates stream ID
- `publish` → responds with `NetStream.Publish.Start`
- `@setDataFrame` / `onMetaData` → reads `videocodecid` (`avc1`)
- Window Acknowledgement, Set Peer Bandwidth, User Control messages

### 9.4 H.264 Decode → Frame Buffer
Decoded YUV frames from H.264 are stored in `ifdsflwoWdasdYfsdfJd._liveYUVSampleBuffer`, which `modifyImageBuffer:` reads to replace camera frames.

---

## 10. `ifdsflwoWdasdYfsdfJd` — Live State Manager (Singleton)

Obfuscated class name. Manages the live virtual camera state.

### Key Properties
- `_bLive` — BOOL: virtual camera active
- `_liveYUVSampleBuffer` — `CMSampleBufferRef`: current virtual frame
- `_pixelTransferSession` — `VTPixelTransferSession`: VideoToolbox transfer
- `_pixelYUVBuffer90` — `CVPixelBuffer`: 90°-rotated version of live frame
- `_imageRotationSession` — `VTImageRotationSession`: for rotation
- `_lock` — `NSRecursiveLock`
- `_dictionary` — `NSMutableDictionary`: dedup timestamps
- `_applicationID` — bundle ID filter
- `_cameraSelected` — which camera position
- `_sourcePosition` — `AVCaptureDevicePosition`
- `_floatWindow` — floating UI window

### Key Methods
| Method | Address | Purpose |
|---|---|---|
| `+sharedInstance` | `0x900EC` | Singleton |
| `-init` | `0x90188` | Init VTPixelTransferSession + VTImageRotationSession |
| `-getLive` | `0x906F0` | Returns `_bLive` |
| `-modifyImageBuffer:` | `0x92080` | **Frame replacement** |
| `-setApplicationID:` | `0x90578` | Set bundle ID filter |
| `-startReading:` | `0x905F0` | Start reading from AVAsset (local file mode) |
| `-cancelReading` | `0x90674` | Stop reading |

---

## 11. GPU Image Processing Pipeline

The tweak includes a full GPU-accelerated beauty filter pipeline (open-source `GPUImage` framework):

| Class | Purpose |
|---|---|
| `GPUImageBaseBeautyFaceFilter` | Base beauty filter |
| `GPUImageBeautyFaceFilter` | Combined face beauty |
| `GPUImageBoxBlurFilter` | Box blur |
| `GPUImageBoxDifferenceFilter` | Frequency separation |
| `GPUImageBoxHighPassFilter` | High-pass sharpening |
| `GPUImageGaussianBlurFilter` | Gaussian blur |
| `GPUImageThinFaceFilter` | Face thinning (mesh warp) |
| `GPUImageContext` | OpenGL ES context |
| `GPUImageFilter` | Base filter class |
| `GPUImageOutput` | Output base |
| `GPUImageFramebuffer` | FBO management |
| `GPUImageMovieWriter` | Write processed video |
| `GPUImageRawDataInput/Output` | Raw pixel I/O |
| `GPUImageTextureInput/Output` | GPU texture I/O |

---

## 12. UI Components

| Class | Purpose |
|---|---|
| `FaceTableViewController` | Face selection list UI |
| `CustomPresentation` | Modal presentation controller |
| `CustomTransition` | Animated transition |
| `iQkewriBdakUeweLk` | Unknown obfuscated UI |
| `ifQwsadqYeweSwedHse` | Unknown obfuscated UI |
| `iFawadWjfhYjfsdfQpo` | Unknown obfuscated UI |
| `iCdfsIdfdEdfsNdfdftqWer` | Unknown obfuscated UI |

---

## 13. License / Activation

From constructor `sub_850FC`:
```objc
MGCopyAnswer("SerialNumber")           // device serial
MGCopyAnswer("k5lVWbXuiZHLA17KGiVUAA") // ECID or device unique identifier
```

These are read and passed via `iHwCjdhryRasdLfdeOsdPsa::run` which assembles `username`/`password` data packets for the `sigin` method. The `Result` and `LoginResp` classes (`0x12AFE0`, `0x12B058`) are response parsers.

PolarSSL (`polarssl/library/ssl_tls.c`, `ssl_srv.c`, `ssl_cli.c`) is compiled in to handle HTTPS for license server communication without using Apple's certificate validation.

---

## 14. Complete Data Flow Diagram

```
[iOS App] (Camera.app, Instagram, etc.)
    │
    │ AVCaptureSession → AVCaptureVideoDataOutput
    │
    ▼
[mediaserverd] ← dylib injected here
    │
    ├─ BWGraph (camera processing pipeline)
    │      │
    │      ├─ FigCaptureSourceConfiguration (hooks: source spoofing)
    │      ├─ FigCapturePipeline → BWGraph nodes
    │      ├─ BWPixelTransferNode (pixel format conversion, hooks intercept)
    │      ├─ BWVideoOrientationMetadataNode (orientation hooks)
    │      └─ BWNodeOutput::emitSampleBuffer: ← *** HOOK sub_85ED4 ***
    │              │
    │              ▼
    │         [ifdsflwoWdasdYfsdfJd sharedInstance]
    │              │
    │              ├─ _bLive? YES → modifyImageBuffer:
    │              │      │
    │              │      └─ VTPixelTransferSessionTransferImage(
    │              │              _pixelTransferSession,
    │              │              _liveYUVSampleBuffer,   ← virtual frame
    │              │              realCameraBuffer        ← overwritten in-place
    │              │         )
    │              │
    │              └─ _bLive? NO → passthrough (real camera)
    │
    ├─ RTMPServer (port 1935)
    │      │
    │      ├─ TCPServer::accept() → RTMPEndpoint → RTMPServerSession
    │      ├─ librtmp: connect/createStream/publish/onMetaData AMF parsing
    │      ├─ H264Decoder: decode NAL units
    │      └─ decoded YUV → _liveYUVSampleBuffer
    │
    └─ iHwCjdhryRasdLfdeOsdPsa (IPC singleton)
           │ ServerSocket port 22222
           │
           ▼
[SpringBoard] ← dylib injected here too
    │
    ├─ iHwCjdhryRasdLfdeOsdPsa::connect() → 127.0.0.1:22222
    ├─ FloatWindow UI overlay
    ├─ FaceTableViewController
    └─ Button intercepts (volume up/down → menu toggle)
```

---

## 15. PolarSSL Network Layer

Source embedded at compile time from `/Volumes/space/objcwork/vcam/polarssl/`:
- `ssl_tls.c` — TLS handshake engine
- `ssl_srv.c` — TLS server
- `ssl_cli.c` — TLS client

Used for license validation HTTP requests. Bypasses iOS's native TLS stack (which would enforce App Transport Security and certificate pinning).

---

## 16. Identified Obfuscated Class Name Mappings

| Obfuscated | Likely Real Name | Evidence |
|---|---|---|
| `iHwCjdhryRasdLfdeOsdPsa` | `VCamBridge` / `VCamController` | listen/connect, setSpringBoard:, setResolution: |
| `ifdsflwoWdasdYfsdfJd` | `VCamState` / `VCamLiveManager` | getLive, modifyImageBuffer:, _bLive, _liveYUVSampleBuffer |
| `iCsdweKdsfRwdaCbv` | `VCamClientSocket` | create:port: to 127.0.0.1:22222 |
| `iMswGsfawYfewewUfdsmn` | `VCamMenuItem` or UI class | class methods only |
| `iRdsfsWqsdJfeefEaawUfj` | unknown | |
| `ifQwsadqYeweSwedHse` | unknown | |
| `iFawadWjfhYjfsdfQpo` | unknown | |
| `iCdfsIdfdEdfsNdfdftqWer` | unknown | |
| `ifwsjWkhQofRsxnvAwes` | unknown | |
| `iHsfaTkdhwkzopQfsnwBd` | unknown | |
| `iQkewriBdakUeweLk` | unknown | |
