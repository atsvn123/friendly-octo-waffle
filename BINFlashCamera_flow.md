# BINFlashCamera.dylib — Full Flow Document

**Binary:** BINFlashCamera.dylib  
**Format:** ARM64 Mach-O dylib  
**IDA instance:** port 13339  
**Analyzed:** 2026-06-09  

---

## Section 1: Binary Overview

| Field | Value |
|---|---|
| Architecture | ARM64 |
| File size | 0xC5C8 bytes (~50 KB) |
| Total functions | 118 (54 named) |
| Key string | `ifdsflwoWdasdYfsdfJd` — VCamLiveManager class (from vcamera.dylib) |
| Hook method 1 | `MSHookFunction` — 3 C-level CoreMedia hooks |
| Hook method 2 | `MSHookMessageEx` — 8 ObjC hooks on VCamLiveManager |
| Hook method 3 | `method_setImplementation` — 2 GPUImage swizzles |
| IPC mechanism | Darwin `notify_register_check` / `notify_get_state` (same channel as BINFlashAddon) |
| Prefs | `com.meo.flashaddon` plist, same 4 paths as BINFlashAddon |
| Core dependency | CoreMedia, CoreVideo, GPUImage (via dynamic class lookup) |
| vcamera.dylib dependency | Hooks `ifdsflwoWdasdYfsdfJd` (VCamLiveManager) by name |

---

## Section 2: Relationship to Other Modules

BINFlashCamera.dylib is the **pixel-level** flash effect engine. It complements BINFlashAddon.dylib:

| Module | Level | Method |
|---|---|---|
| BINFlashAddon.dylib | GPUImage filter parameter | `setWhite:` value override |
| BINFlashCamera.dylib | Raw pixel buffer data | Direct YUV/BGRA byte modification |

Both modules share the same IPC channel (`com.meo.flashaddon.changed`), the same plist format, and the same 64-bit packed state. Settings changed in BINFlashAddon's UI are immediately visible to BINFlashCamera.

BINFlashCamera also hooks into **vcamera.dylib's VCamLiveManager** (`ifdsflwoWdasdYfsdfJd`) — it post-processes every frame that vcamera.dylib produces, applying the flash effect to the virtual camera stream.

---

## Section 3: Injection and Constructor

### `InitFunc_0` (0x416C) — `__mod_init_func` constructor

Called immediately on dylib load by MobileLoader.

```
InitFunc_0 (0x416C)
│
├── sub_4270()          — install C-level CoreMedia hooks (MSHookFunction)
│                         (guarded by byte_C2D9)
│
├── sub_65C0()          — install GPUImage swizzles (method_setImplementation)
│                         (guarded by byte_C370)
│
├── sub_42F0(...)       — install VCamLiveManager ObjC hooks (MSHookMessageEx)
│                         (guarded by byte_C2D8)
│
└── if (not all hooks installed) && (no timer yet):
    └── GCD timer source on global background queue:
            initial delay : 500ms
            interval      : 500ms (0x1DCD6500 ns)
            leeway        : 100ms (0x5F5E100 ns)
            event handler : stru_8100
            → retries sub_4270() + sub_65C0() + sub_42F0() every 500ms
              until all three hook sets succeed
```

**Why the retry timer?** VCamLiveManager (`ifdsflwoWdasdYfsdfJd`) is defined in vcamera.dylib, which is loaded separately. On first call after inject, vcamera.dylib may not yet be loaded. The timer retries until the class exists. Similarly, GPUImage classes may not be in memory until the camera app initializes its pipeline.

**Timer interval:** `0x1DCD6500` = 500,000,000 ns = **500ms**. Fires at 2 Hz until all hooks are in place.

---

## Section 4: C-Level CoreMedia Hooks (`sub_4270`, 0x4270)

`MSHookFunction` patches the actual C function addresses in the CoreMedia binary. These intercept every call to these functions system-wide within the process.

| Original C Function | Hook | Saved original | Behavior |
|---|---|---|---|
| `CMSampleBufferGetImageBuffer` | `sub_44F8` | `off_C2E0` | Calls original → applies `sub_4628` to returned CVPixelBuffer |
| `CMSampleBufferCreateCopy` | `sub_4538` | `off_C2E8` | Calls original → if new buffer created, applies `sub_4628` to its image buffer |
| `CMSampleBufferCreateForImageBuffer` | `sub_4588` | `off_C2F0` | Applies `sub_4628` to imageBuffer arg (a2) BEFORE calling original |

### `sub_44F8` — `CMSampleBufferGetImageBuffer` hook
```c
CVImageBufferRef sub_44F8(CMSampleBufferRef sbuf) {
    CVImageBufferRef imageBuffer = off_C2E0(sbuf);  // call original
    sub_4628(imageBuffer);                           // apply flash effect
    return imageBuffer;
}
```

### `sub_4538` — `CMSampleBufferCreateCopy` hook
```c
OSStatus sub_4538(allocator, sbuf, &outSbuf) {
    OSStatus err = off_C2E8(...);                   // call original
    if (outSbuf && err == 0) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer(outSbuf);
        sub_4628(ib);                                // apply flash effect to copy
    }
    return err;
}
```

### `sub_4588` — `CMSampleBufferCreateForImageBuffer` hook
```c
OSStatus sub_4588(allocator, imageBuffer, ...) {
    sub_4628(imageBuffer);          // apply flash effect FIRST (before buffer wrapping)
    return off_C2F0(...);           // then call original
}
```

---

## Section 5: GPUImage Swizzles (`sub_65C0`, 0x65C0)

Tries `GPUImageBaseBeautyFaceFilter` first, falls back to `GPUImageBeautyFaceFilter` if the base class doesn't exist.

| Class | Method | Hook | Saved IMP |
|---|---|---|---|
| `GPUImageBaseBeautyFaceFilter` or `GPUImageBeautyFaceFilter` | `setWhite:` | `sub_66E4` | `off_C388` |
| `GPUImageThinFaceFilter` | `setUniformsWithLandmarks:` | `sub_678C` | `off_C390` |

### `sub_66E4` — swizzled `setWhite:` (0x66E4)
```c
void sub_66E4(GPUImageBaseBeautyFaceFilter *self, SEL cmd, double white) {
    // Refresh prefs cache and flash state
    id prefs = sub_539C();   // load prefs (cached 100ms)
    sub_5C0C();              // update flash state
    // Always call original with 0.0 — suppress app's own white value,
    // the actual brightness is applied at the pixel level in sub_4628
    if (off_C388)
        off_C388(self, cmd, 0.0);
}
```
**Effect:** Neutralizes the beauty filter's white-level effect. The real brightness is applied directly to pixels in `sub_4628` — this prevents double-application.

### `sub_678C` — swizzled `setUniformsWithLandmarks:` on GPUImageThinFaceFilter (0x678C)
This is the **face tracking hook**. It extracts face position from GPUImage's landmark data for use by `sub_5F50` (the region calculator in `sub_4628`).

```c
void sub_678C(GPUImageThinFaceFilter *self, SEL cmd, NSArray *landmarks) {
    // Parse landmark array — accepts NSValue[CGPoint] or NSDictionary{x,y} per landmark
    // Builds bounding box: (minX, minY) → (maxX, maxY)
    
    if (validPoints >= 3 && bounds are finite) {
        if (bounds in [0, 1.2] range) {
            // Face region in [0,1] normalized coords
            double cx = (minX + maxX) * 0.5;
            double cy = (minY + maxY) * 0.5;
            double rx = max((maxX - minX) * 1.45, 0.18);
            double ry = max((maxY - minY) * 1.70, 0.24);
            
            if (any coord < 0 or > 1.0) {
                // [-1,1] normalized → convert to [0,1]
                cx = (cx + 1.0) * 0.5;  cy = (cy + 1.0) * 0.5;
                rx *= 0.5;               ry *= 0.5;
            }
            
            // Store clamped face region
            qword_C2B8 = clamp(cx, 0.15, 0.85);   // face center X (normalized)
            qword_C2C0 = clamp(cy, 0.12, 0.88);   // face center Y
            qword_C2C8 = clamp(rx, 0.20, 0.85);   // ellipse half-width
            qword_C2D0 = clamp(ry, 0.25, 0.95);   // ellipse half-height
            qword_C328 = CFAbsoluteTimeGetCurrent(); // face detection timestamp
        }
    }
    
    // Suppress original white effect, then call original setUniformsWithLandmarks:
    if (off_C388) off_C388(self, @selector(setWhite:), 0.0);
    if (off_C390) off_C390(self, cmd, landmarks);
}
```

**Face position expires after 1 second** (checked in `sub_5F50`). If no fresh landmarks arrive, the effect falls back to the center of the frame (0.5, 0.42).

---

## Section 6: VCamLiveManager Hooks (`sub_42F0`, 0x42F0)

Hooks 8 methods on `ifdsflwoWdasdYfsdfJd` (= VCamLiveManager, from vcamera.dylib).
All hooks extract the pixel buffer from the sample buffer and call `sub_4628` to apply the flash effect.

| Method hooked | Hook function | Pattern |
|---|---|---|
| `modifyPixelBuffer:` | `sub_61D8` | Call original → CMSampleBufferGetImageBuffer → sub_4628 |
| `modifyImageBuffer:` | `sub_6260` | Call original → CMSampleBufferGetImageBuffer → sub_4628 |
| `createSampleBuffer:` | `sub_62E8` | Call original → CMSampleBufferGetImageBuffer → sub_4628 |
| `getSampleBuffer:` | `sub_6368` | Call original → CMSampleBufferGetImageBuffer → sub_4628 |
| `get90SampleBuffer:` | `sub_63E8` | Call original → CMSampleBufferGetImageBuffer → sub_4628 |
| `setYUVPixelBuffer:` | `sub_6468` | sub_4628(pixelBuffer arg directly) → call original |
| `setYUVSampleBuffer:` | `sub_64D8` | CMSampleBufferGetImageBuffer → sub_4628 → call original |
| `setBGRASampleBuffer:` | `sub_654C` | CMSampleBufferGetImageBuffer → sub_4628 → call original |

**Note:** `setYUVPixelBuffer:` receives a CVPixelBuffer directly (not a CMSampleBuffer), so it passes the arg directly to `sub_4628` without an intermediate `CMSampleBufferGetImageBuffer` call.

---

## Section 7: Core Pixel Effect Engine — `sub_4628` (0x4628)

This is the largest function (3328 bytes). It applies the brightness and hue flash effect directly to raw pixel data in a CVPixelBuffer.

### Entry guard
```c
// Only operates on CVPixelBuffer objects (not other CFTypes)
if (!a1) return;
if (CFGetTypeID(a1) != CVPixelBufferGetTypeID()) return;
```

### Prefs load and flash state check
```c
NSDictionary *prefs = sub_539C();   // load prefs (cached 100ms)
double brightness = sub_5C0C();     // compute flash brightness: NaN=off, 0=off-phase, >0=on-phase
if (brightness <= 0.001) return;   // no effect when dim/off
```

### Flash timing
```c
double speed = sub_5DA4(prefs, "speed", 3.0);
double time  = CFAbsoluteTimeGetCurrent();
int epoch    = (int)((speed + speed) * time);   // flash "tick" index
```

### Frame dedup (prevents double-processing on same frame)
```c
// Attach "com.meo.flashaddon.frame-epoch" to pixel buffer
// If the epoch value already matches → this frame was already processed this tick → skip
CFNumberRef existing = CVBufferGetAttachment(pixbuf, CFSTR("com.meo.flashaddon.frame-epoch"), NULL);
if (existing && CFNumberGetValue(existing, kCFNumberIntType) == epoch) return;
CFNumberRef epochNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &epoch);
CVBufferSetAttachment(pixbuf, CFSTR("com.meo.flashaddon.frame-epoch"), epochNum, kCVAttachmentMode_ShouldNotPropagate);
CFRelease(epochNum);
```

### Lock base address
```c
if (CVPixelBufferLockBaseAddress(pixbuf, 0) != 0) return;
```

### Format dispatch
Two processing paths based on pixel format:

#### Path A — YUV BiPlanar 420 (format codes `420f` and `420v`)
Check: `(pixelFormat & 0xFFFFFFEF) == 0x34323066`

Gets Y-plane (luma) and UV-plane (chroma):
```c
uint8_t *yPlane  = CVPixelBufferGetBaseAddressOfPlane(pixbuf, 0);
uint8_t *uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixbuf, 1);
size_t   yStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 0);
size_t  uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixbuf, 1);
```

**Sub-step 1: Compute face region**
```c
double cx, cy, rx, ry;
sub_5F50(prefs, width, height, &cx, &cy, &rx, &ry);
// cx,cy = face center in pixels; rx,ry = ellipse half-radii in pixels
```

**Sub-step 2: Y-plane brightness boost (per-pixel)**
```c
double brightFactor = clamp(brightness * 0.72, 0, 0.82);

for each pixel (x,y) within bounding box of ellipse {
    double d2 = ((x+0.5-cx)/rx)^2 + ((y+0.5-cy)/ry)^2;
    if (d2 <= 1.18) {
        double t = clamp((d2 - 0.3) / 0.88, 0, 1);
        double weight = (1-t)^2 * (3 - 2*(1-t));  // smooth-step falloff
        double alpha = brightFactor * weight;
        // Blend pixel toward 255 (white)
        Y[y][x] = clamp(alpha * (255 - Y[y][x]) + Y[y][x], 0, 255);
    }
}
```

**Sub-step 3: UV-plane hue tinting**
```c
double hue = sub_5DA4(prefs, "hue", 0.0);
// Hue → RGB (saturation=1, value=0.82): r,g,b in [0,1]
// → Scale to [0.18, 1.0]: r = r*0.82+0.18, etc.
// → Convert to YCbCr:
//   Cb = -0.168736*R - 0.331264*G + 0.5*B + 128
//   Cr =  0.5*R - 0.418688*G - 0.081312*B + 128
double targetCb = ...;
double targetCr = ...;

double chromaFactor = clamp(brightness * 1.02, 0, 0.98);
for each UV pixel (x,y) {
    // UV plane is half-resolution; process interleaved Cb,Cr pairs
    Cb[y][x] = blend(targetCb, existing Cb, chromaFactor * weight);
    Cr[y][x] = blend(targetCr, existing Cr, chromaFactor * weight);
}
```

#### Path B — Packed BGRA/ARGB variants
Format codes: `32` (ARGB), `0x42475241` (BGRA), `0x52474241` (RGBA), `0x41424752` (ABGR)

Per-pixel layout varies by format, but the algorithm is:
```c
double brightFactor = clamp(brightness * 0.70, 0, 0.78);
double chromaFactor = clamp(brightness * 0.90, 0, 0.96);

for each pixel (x,y) within face ellipse {
    // Extract R,G,B from packed format (format-specific byte offsets)
    // Step 1: brightness boost
    R = brightFactor * weight * (255 - R) + R;
    G = brightFactor * weight * (255 - G) + G;
    B = brightFactor * weight * (255 - B) + B;
    // Step 2: hue tinting (blend toward hue-derived R,G,B)
    R = hueR * chromaFactor * weight + (1 - chromaFactor*weight) * R;
    G = hueG * chromaFactor * weight + ...;
    B = hueB * chromaFactor * weight + ...;
    // Write back per-format byte offsets
}
```

---

## Section 8: Face Region Calculator — `sub_5F50` (0x5F50)

Returns face center (cx, cy) and ellipse half-radii (rx, ry) in pixel coordinates.

```c
void sub_5F50(NSDictionary *prefs, size_t imgW, size_t imgH,
              double *cx, double *cy, double *rx, double *ry)
{
    double region      = sub_5DA4(prefs, "region", 30.0);   // 0–100
    BOOL manualRegion  = sub_5EB8(prefs, "manualRegion", NO);
    
    double faceCX, faceCY;  // normalized [0,1]
    BOOL usingFaceData;
    
    if (manualRegion) {
        // Use manually set region center from prefs
        faceCX = sub_5DA4(prefs, "regionX", 0.5);
        faceCY = sub_5DA4(prefs, "regionY", 0.42);
        usingFaceData = NO;
    } else if (CFAbsoluteTimeGetCurrent() - qword_C328 < 1.0) {
        // Use face landmark position (fresh within last 1 second)
        faceCX = qword_C2B8;
        faceCY = qword_C2C0;
        usingFaceData = YES;
    } else {
        // Default: center of frame with slight upward bias (0.5, 0.42)
        faceCX = 0.5;
        faceCY = 0.42;
        usingFaceData = NO;
    }
    
    // Normalize region to [0.1, 1.0]
    double r = clamp(region / 100.0, 0.1, 1.0);
    
    // Compute ellipse half-radii based on image size and region
    double minDim = min(imgW, imgH);
    double baseRX = minDim * (r * 0.25 + 0.15);
    double baseRY = minDim * (r * 0.36 + 0.24);
    
    // If face data is available: scale up the radii to match detected face size
    if (usingFaceData) {
        double faceScaleX = qword_C2C8 * imgW * 0.5;
        double faceScaleY = qword_C2D0 * imgH * 0.5;
        double scaleFactor = r * 0.2 + 0.84;
        rx_computed = max(baseRX, scaleFactor * (portrait ? min : max)(faceScaleX, faceScaleY));
        ry_computed = max(baseRY, scaleFactor * (portrait ? max : min)(faceScaleX, faceScaleY));
    }
    
    // Output: face center in pixels, radii in pixels, clamped to valid range
    *cx = clamp(faceCX, 0.08, 0.92) * imgW;
    *cy = clamp(faceCY, 0.08, 0.92) * imgH;
    *rx = max(max(minDim*0.14, min(minDim*0.66, rx_computed)), 8.0);
    *ry = max(max(minDim*0.14, min(minDim*0.66, ry_computed)), 8.0);
}
```

---

## Section 9: Prefs Loader — `sub_539C` (0x539C)

Full prefs cache with 100ms TTL. Identical structure to BINFlashAddon's `sub_6CDC` but cached with a timestamp.

```
sub_539C():
    if (cached AND fresh within 100ms) → return cached dict

    1. Build default dict: {live:YES, flash:YES, speed:3.0, brightness:51.0,
                            region:30.0, hue:0.33, manualRegion:NO, regionX:0.5, regionY:0.42}
    2. Try plist paths (stop at first valid dict):
       - /var/mobile/Library/Preferences/com.meo.flashaddon.plist
       - /var/jb/var/mobile/Library/Preferences/com.meo.flashaddon.plist
       - /var/tmp/com.meo.flashaddon.plist
       - /tmp/com.meo.flashaddon.plist
    3. Darwin notify check:
       dispatch_once: notify_register_check("com.meo.flashaddon.changed", &token)
       notify_get_state(token, &state64)
       if (state64 & 0x8000000000000000):
           unpack state64 → override dict values (same 64-bit layout as BINFlashAddon)
    4. Cache result with current timestamp
    return cached dict
```

**Token registration** uses `dispatch_once` (`stru_8080` block) called from `sub_539C`. This ensures `notify_register_check` is called exactly once — the token is stored in `qword_C318` (`token` global).

---

## Section 10: Flash Brightness Calculator — `sub_5C0C` (0x5C0C)

Nearly identical to BINFlashAddon's `sub_B394` but with different region coefficient:

```c
double sub_5C0C(NSDictionary *prefs) {
    if (!sub_5EB8(prefs, "flash", NO)) return NAN;

    double speed      = sub_5DA4(prefs, "speed",      3.0);
    double brightness = sub_5DA4(prefs, "brightness", 51.0);
    double region     = sub_5DA4(prefs, "region",     30.0);

    double time = CFAbsoluteTimeGetCurrent();

    // 50% duty-cycle square wave at `speed` Hz
    if (fmod(fmax(speed, 0.5) * time, 1.0) < 0.5) {
        double b = clamp(brightness / 100.0, 0, 1);
        double r = clamp(region / 100.0, 0.1, 1);
        // BINFlashCamera uses: r * 0.25 + 0.90 (vs BINFlashAddon's: r * 0.45 + 0.70)
        return clamp(b * (r * 0.25 + 0.9), 0, 1);
    }
    return 0.0;
}
```

**Comparison at default settings (brightness=51, region=30):**
- BINFlashAddon: `0.51 × (0.30×0.45 + 0.70)` = 0.426
- BINFlashCamera: `0.51 × (0.30×0.25 + 0.90)` = **0.497**

BINFlashCamera's pixel-level effect is slightly stronger at default settings.

---

## Section 11: Complete Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│              CAMERA APP PROCESS                                          │
│                                                                          │
│  BINFlashCamera.dylib loaded by MobileLoader                             │
│       │                                                                  │
│  InitFunc_0 (0x416C)                                                     │
│       ├── sub_4270(): MSHookFunction on CMSampleBufferGetImageBuffer,    │
│       │               CMSampleBufferCreateCopy, CMSampleBufferCreateForImageBuffer
│       ├── sub_65C0(): method_setImplementation on:                       │
│       │               GPUImageBaseBeautyFaceFilter::setWhite:            │
│       │               GPUImageThinFaceFilter::setUniformsWithLandmarks:  │
│       ├── sub_42F0(): MSHookMessageEx on ifdsflwoWdasdYfsdfJd:            │
│       │               modifyPixelBuffer:, modifyImageBuffer:,            │
│       │               createSampleBuffer:, getSampleBuffer:,             │
│       │               get90SampleBuffer:, setYUVPixelBuffer:,            │
│       │               setYUVSampleBuffer:, setBGRASampleBuffer:          │
│       │                                                                  │
│       └── GCD timer (500ms interval) → retry until all hooks succeed    │
│                                                                          │
│  ─────── CAMERA FRAME PIPELINE ─────────────────────────────────────    │
│                                                                          │
│  GPUImageThinFaceFilter processes frame with landmarks:                  │
│       │ setUniformsWithLandmarks:(landmarks)                             │
│       ▼ (swizzled → sub_678C)                                            │
│  Extract face bounding box from landmark array                           │
│  Store: qword_C2B8=cx, qword_C2C0=cy, qword_C2C8=rx, qword_C2D0=ry     │
│  Update: qword_C328 = CFAbsoluteTimeGetCurrent()                        │
│  Call original setUniformsWithLandmarks:                                 │
│                                                                          │
│  GPUImageBaseBeautyFaceFilter::setWhite: called:                        │
│       │ (swizzled → sub_66E4)                                            │
│       ▼                                                                  │
│  Call sub_539C() (prefs), sub_5C0C() (flash state)                      │
│  Call original setWhite:(0.0) — suppress app's brightness                │
│                                                                          │
│  VCamLiveManager::modifyPixelBuffer:(sampleBuffer) called:              │
│       │ (hooked → sub_61D8)                                              │
│       ▼                                                                  │
│  Call original first, then:                                              │
│  CMSampleBufferGetImageBuffer → CVPixelBuffer                            │
│       │                                                                  │
│       ▼                                                                  │
│  ┌────────────────────────────────────────────────────────────┐          │
│  │  sub_4628 (pixel effect engine):                           │          │
│  │   1. sub_539C() → prefs dict (100ms cache)                │          │
│  │   2. sub_5C0C() → brightness float                        │          │
│  │      └── if NaN or ≤0.001: return (no-op)                 │          │
│  │   3. Frame dedup via CVBufferAttachment epoch              │          │
│  │   4. CVPixelBufferLockBaseAddress                          │          │
│  │   5. sub_5F50 → face center (cx,cy) + radii (rx,ry):      │          │
│  │      priority: manualRegion > fresh landmarks > default   │          │
│  │   6a. YUV format (420f/420v):                             │          │
│  │       Y-plane: brighten within face ellipse (smoothstep)  │          │
│  │       UV-plane: tint toward hue-derived Cb/Cr             │          │
│  │   6b. BGRA/ARGB formats:                                  │          │
│  │       Blend RGB channels toward (brightened + hue-tinted) │          │
│  │   7. CVPixelBufferUnlockBaseAddress                        │          │
│  └────────────────────────────────────────────────────────────┘          │
│                                                                          │
│  Also triggered via:                                                     │
│  CMSampleBufferGetImageBuffer (C hook) → sub_4628 on any extracted buf  │
│  CMSampleBufferCreateForImageBuffer → sub_4628 on imageBuffer arg       │
│  CMSampleBufferCreateCopy → sub_4628 on copied buffer                   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Section 12: Flash Effect Parameters

| Parameter | Default | Effect in sub_4628 | Effect in sub_5C0C |
|---|---|---|---|
| `flash` (bool) | YES | — | Returns NaN → no-op if false |
| `speed` (float) | 3.0 Hz | Flash tick rate | Square wave frequency |
| `brightness` (float) | 51.0 | Y-plane boost scale: `×0.72`; chroma scale: `×1.02` | Base brightness multiplier |
| `region` (float) | 30.0 | Affects base ellipse radius in sub_5F50 | Scales amplitude: `r×0.25+0.9` |
| `hue` (float) | 0.33 | Chroma tint target (HSV→YUV/RGB) | — |
| `regionX` (float) | 0.5 | Manual face center X when `manualRegion=YES` | — |
| `regionY` (float) | 0.42 | Manual face center Y | — |
| `manualRegion` (bool) | NO | Use regionX/Y vs live face tracking | — |

---

## Section 13: Global State Variables

| Address | Name | Type | Contents |
|---|---|---|---|
| `qword_C2B8` | face_cx | double | Face center X [0,1], from landmark hook |
| `qword_C2C0` | face_cy | double | Face center Y [0,1] |
| `qword_C2C8` | face_rx | double | Face ellipse half-width [0,1] |
| `qword_C2D0` | face_ry | double | Face ellipse half-height [0,1] |
| `qword_C328` | face_timestamp | double | CFAbsoluteTime when face was last detected |
| `qword_C2F8` | prefs_cache | id | Cached NSDictionary from sub_539C |
| `qword_C300` | prefs_timestamp | double | When prefs_cache was last populated |
| `byte_C308` | prefs_dirty | BOOL | Force-refresh flag |
| `byte_C2D8` | vcam_hooks_ok | BOOL | Set when VCamLiveManager hooks installed |
| `byte_C2D9` | coremedia_hooks_ok | BOOL | Set when C function hooks installed |
| `byte_C370` | gpuimage_hooks_ok | BOOL | Set when GPUImage swizzles installed |
| `qword_C378` | retry_timer | dispatch_source_t | GCD timer for hook retry |
| `off_C2E0` | orig_GetImageBuffer | IMP | Original CMSampleBufferGetImageBuffer |
| `off_C2E8` | orig_CreateCopy | IMP | Original CMSampleBufferCreateCopy |
| `off_C2F0` | orig_CreateForImageBuffer | IMP | Original CMSampleBufferCreateForImageBuffer |
| `off_C330` | orig_modifyPixelBuffer | IMP | Original VCamLiveManager::modifyPixelBuffer: |
| `off_C338` | orig_modifyImageBuffer | IMP | Original VCamLiveManager::modifyImageBuffer: |
| `off_C388` | orig_setWhite | IMP | Original GPUImageBaseBeautyFaceFilter::setWhite: |
| `off_C390` | orig_setUniforms | IMP | Original GPUImageThinFaceFilter::setUniformsWithLandmarks: |
| `qword_C318` (`token`) | notify_token | int | Darwin notify channel token |
