# BINFlashAddon.dylib — Full Flow Document

**Binary:** BINFlashAddon.dylib  
**Format:** ARM64 Mach-O dylib  
**IDA instance:** port 13338  
**Analyzed:** 2026-06-09  

---

## Section 1: Binary Overview

| Field | Value |
|---|---|
| Architecture | ARM64 (Apple Silicon) |
| File format | Mach-O dylib |
| Segments | `__TEXT`, `__DATA`, `__DATA_CONST`, `__OBJC_METHNAMES`, `__OBJC_CLASSREFS` |
| ObjC classes | BINFlashController, BINFlashPanel, BINFlashOvalView, BINFlashColorBar, BINFlashEffectBridge, BINFlashPassThroughWindow, BINFlashRootController |
| Key C functions | sub_6CDC (prefs loader), sub_7E78 (prefs saver), sub_89C4 (state packer), sub_B394 (white value), sub_7258 (bool getter), sub_72F0 (float getter) |
| Injection method | MobileLoader → `__mod_init_func` constructor |
| IPC mechanism | Darwin `notify_register_check` / `notify_set_state` / `notify_post` |
| Key dependency | GPUImage framework (GPUImageBaseBeautyFaceFilter, GPUImageBeautyFaceFilter) |
| Swizzle method | `method_setImplementation` (ObjC runtime, NOT Cydia Substrate) |
| Plist bundle ID | `com.meo.flashaddon` |

---

## Section 2: Injection Mechanism

BINFlashAddon.dylib is loaded by **MobileLoader** (Cydia Substrate layer) into the target camera app process.

The companion plist (`BINFlashAddon.plist`) specifies which process(es) to inject into. Once loaded, the Mach-O `__mod_init_func` section triggers the C++ constructor automatically.

### Constructor: `InitFunc_0` (0xB588)

```
__mod_init_func entry → InitFunc_0 (0xB588)
    │
    └─► dispatch_async(dispatch_get_main_queue(), stru_100F8)
               │
               └─► [[BINFlashController shared] startWhenReady]
```

`stru_100F8` is a global ObjC block struct in the `__const` section. It is dispatched to the **main queue** — meaning the real startup is deferred until the main run loop is active. This avoids crashing on early injection before UIKit is ready.

---

## Section 3: Startup Sequence

### `+[BINFlashController shared]` (0xAD60)
Singleton via `dispatch_once`. Returns the shared `BINFlashController` instance.

### `-[BINFlashController startWhenReady]` (0xAB60)
Registers for `UIApplicationDidFinishLaunchingNotification` via `NSNotificationCenter`. When the notification fires, it calls `-start`. This ensures the UIWindow is not created before UIKit's window hierarchy is established.

### `-[BINFlashController start]` (0x947C) — 827 instructions
This is the full UI builder. Called exactly once. Steps:

1. **Guard:** checks `self.window != nil` — if already built, returns immediately.

2. **Screen bounds:** `UIScreen.mainScreen.bounds` → used for frame sizing.

3. **WindowScene lookup:** iterates `UIApplication.sharedApplication.connectedScenes`,  
   finds a `UIWindowScene` with `activationState == UISceneActivationStateForegroundActive` (or `ForegroundInactive`).

4. **Creates `BINFlashPassThroughWindow`:**
   - Frame = full screen bounds
   - `windowLevel = UIWindowLevelAlert + 1000` (draws above all alerts)
   - `backgroundColor = UIColor.clearColor`
   - If scene found: `setWindowScene:` to attach to the scene
   - `setHidden:NO` → makes window visible

5. **Creates `BINFlashRootController`:**
   - Assigned as `window.rootViewController`
   - Root view background = clear

6. **Creates `BINFlashOvalView`:**
   - Frame = full screen bounds (sits behind everything)
   - Added as first subview of the window

7. **Creates `BINFlashPanel`:**
   - Width = `min(screenWidth - 20, 330)`, positioned at `(paddingX, 90)`
   - Initially `hidden = YES`
   - `hideHandler` block set (calls `start` cleanup on dismiss)
   - Added as subview of window
   - Gets a `UIPanGestureRecognizer` → `handlePanelPan:`

8. **Creates mini "BIN" button:**
   - Frame: `x = screenWidth - 68, y = 155, width = 54, height = 42`
   - Background color: `rgba(0.38, 0.9, 0.48, 0.72)` — green
   - Corner radius: 12, shadow color: black, shadow opacity: ~0.5, shadow radius: 8
   - Title: `"BIN"`, color: white, font: bold system 16pt
   - Tap action: `showPanel`
   - Gets `UIPanGestureRecognizer` → `handleMiniPan:` (for dragging the mini button)
   - Added as subview of window

9. **Creates repeating timer:**
   - Interval: 0.05 seconds (20 Hz)
   - Selector: `tick`
   - Added to `NSRunLoop.mainRunLoop` in `NSRunLoopCommonModes`

---

## Section 4: BINFlashController Methods

| Method | Address | Description |
|---|---|---|
| `+shared` | 0xAD60 | Singleton (dispatch_once) |
| `startWhenReady` | 0xAB60 | Wait for UIApplicationDidFinishLaunching, then call start |
| `start` | 0x947C | Full UI construction (see Section 3) |
| `showPanel` | 0xA808 | Unhide panel, reload prefs, begin panning |
| `tick` | 0xAA30 | 20Hz timer: drives animation, show/hide ovalView |
| `moveView:withPan:` | 0xA960 | Core drag logic (clamped within screen) |
| `handlePanelPan:` | 0xA6A4 | UIPanGestureRecognizer for panel drag |
| `handleMiniPan:` | 0xA504 | UIPanGestureRecognizer for mini button drag |

### `tick` (0xAA30)
Called 20 times/second:
- Uses `CACurrentMediaTime()` for animation state
- Shows/hides `ovalView` based on whether the panel is visible
- Calls `BINFlashEffectBridge.tick` to pulse beauty filter white values

### `showPanel` (0xA808)
- Unhides `self.panel`
- Calls `[panel reloadFromPrefs]` — syncs UI to current settings
- Hides mini button while panel is open

---

## Section 5: BINFlashPanel (Settings Panel)

`BINFlashPanel` is the full settings UI. Frame is `min(screenWidth-20, 330) × dynamic height`, initially positioned at y=90.

### `initWithFrame:` (0x5324) — 687 instructions
Builds the panel from scratch:

1. **Background:** white, corner radius, drop shadow (black, opacity ~0.5, radius 8)
2. **Live switch** — `addSwitchRow:key:y:` with key `"live"`, y offset from top
3. **Flash switch** — `addSwitchRow:key:y:` with key `"flash"`
4. **Speed slider** — `addSliderRow:key:min:max:y:valueLabel:`, key `"speed"`, min 0.5, max ~102.3
5. **Brightness slider** — key `"brightness"`, min 0, max 100
6. **Region slider** — key `"region"`, min 0, max 100
7. **Aim/nudge buttons** — 4 directional buttons (left/right/up/down) via `addAimButtonWithSystemName:fallback:frame:action:`
   - Actions: `nudgeLeftTapped`, `nudgeRightTapped`, `nudgeUpTapped`, `nudgeDownTapped`
8. **Color bar** — `BINFlashColorBar` showing current hue
9. **Value labels** — speed, brightness, region
10. **Reset button** — calls `resetTapped`
11. **Hide button** — calls `hideTapped`

### `reloadFromPrefs` (0x6AA0)
Reads current settings from `sub_6CDC()` and syncs UI:
```
liveSwitch.setOn:    ← sub_7258(prefs, "live",       default=YES)
flashSwitch.setOn:   ← sub_7258(prefs, "flash",      default=NO)
speedSlider.value    ← sub_72F0(prefs, "speed",      default=3.0)
brightnessSlider.value ← sub_72F0(prefs, "brightness", default=51.0)
regionSlider.value   ← sub_72F0(prefs, "region",     default=30.0)
colorBar.hue         ← sub_72F0(prefs, "hue",        default=0.33)
updateValueLabels
updateAimButtons: prefs
```

### Control change handlers
All three (`switchChanged:`, `sliderChanged:`, `colorChanged:`) call `sub_79A4(key, value)`:

```
switchChanged:  → sub_79A4(switch.accessibilityIdentifier, @(switch.isOn))
sliderChanged:  → sub_79A4(slider.accessibilityIdentifier, @(slider.value))
                  + updateValueLabels
colorChanged:   → sub_79A4(@"hue", @(colorBar.hue))
```

`sub_79A4(key, value)` builds `@{value: key}` (NSDictionary), calls `sub_7E78(dict)`.

### `nudgeRegionByX:y:` (0x7C24)
- Reads current `regionX`/`regionY` from `sub_6CDC()`
- Clamps new values to `[0.0, 1.0]`
- Saves via `sub_7E78(@{@"regionX": @(x), @"regionY": @(y), @"manualRegion": @YES})`
- Calls `updateAimButtons: prefs`

### `resetTapped` (0x8344)
- Builds a default NSDictionary with reset values
- Writes to all 4 plist paths via `sub_7E78`
- Calls `reloadFromPrefs`
- Calls `notify_post("com.meo.flashaddon.changed")`

### `hideTapped` (0x82B0)
Calls the `hideHandler` block (set by `BINFlashController::start`), which hides the panel and shows mini button.

---

## Section 6: BINFlashOvalView (Color Picker)

`BINFlashOvalView` is a full-screen UIView subclass that renders a hue color wheel / oval gradient. The user can tap/drag to select a hue value. On change, it calls `colorChanged:` on the panel.

Key method: `-[BINFlashOvalView setHue:]` — updates the displayed color.

---

## Section 7: BINFlashColorBar (Hue Bar)

`BINFlashColorBar` is a gradient bar showing the hue spectrum. Has `-setHue:` method that moves an indicator and updates the displayed hue value.

---

## Section 8: BINFlashPassThroughWindow

`BINFlashPassThroughWindow` is a `UIWindow` subclass. It overrides `hitTest:withEvent:` to return `nil` for touches that land in the "pass-through" zone (the full-screen transparent area), so that the underlying app receives those touches. Only the panel, mini button, and oval view intercept touches.

---

## Section 9: BINFlashEffectBridge (GPUImage Swizzle)

`BINFlashEffectBridge` is the core hook mechanism. It intercepts GPUImage's beauty filter rendering pipeline.

### `+shared` (0xAD78)
Singleton. The `filters` property is an `NSHashTable` with **weak object references** — filters added here are automatically removed when they dealloc.

### `+tick` / `-tick` (0xB094) — called 20Hz by BINFlashController

**First call only (dispatch_once pattern via flag check at off_15E10):**
```objc
// Swizzle GPUImageBaseBeautyFaceFilter::setWhite:
Method origSetWhite = class_getInstanceMethod(
    NSClassFromString(@"GPUImageBaseBeautyFaceFilter"), @selector(setWhite:));
off_15E30 = method_getImplementation(origSetWhite);     // save original IMP
method_setImplementation(origSetWhite, (IMP)sub_C924);   // replace with hook

// Swizzle GPUImageBaseBeautyFaceFilter::setUniformsWithLandmarks:
Method origSetUniforms = class_getInstanceMethod(
    NSClassFromString(@"GPUImageBaseBeautyFaceFilter"), @selector(setUniformsWithLandmarks:));
off_15E50 = method_getImplementation(origSetUniforms);   // save original IMP
method_setImplementation(origSetUniforms, (IMP)sub_CA08); // replace with hook
```

**Every call (20Hz):**
```objc
NSDictionary *prefs = sub_6CDC();          // load current settings
double white = sub_B394(prefs);             // compute flash white value
for (id filter in self.filters) {          // NSHashTable fast enumeration
    [filter setWhite:white];                // apply to each registered filter
}
```

### `-registerFilter:` 
Called from the swizzle hooks when a `GPUImageBaseBeautyFaceFilter` instance calls `setWhite:` or `setUniformsWithLandmarks:`. Adds the filter to the `filters` NSHashTable (weak reference — auto-removed on dealloc).

---

## Section 10: sub_C924 — Swizzled `setWhite:` Hook

Replaces `GPUImageBaseBeautyFaceFilter::setWhite:`:

```c
// Called whenever any GPUImageBaseBeautyFaceFilter instance calls setWhite:
void sub_C924(GPUImageBaseBeautyFaceFilter *self, SEL cmd, double white) {
    // Register this filter with the bridge (idempotent via weak table)
    [[BINFlashEffectBridge shared] registerFilter:self];
    
    // Compute current flash value and override what was passed in
    NSDictionary *prefs = sub_6CDC();
    double flashWhite = sub_B394(prefs);
    
    // Call original setWhite: IMP with the flash-computed value
    if (off_15E30)
        off_15E30(self, cmd, flashWhite);
}
```

**Effect:** Any call to `setWhite:` from the app's own beauty pipeline is intercepted. The filter auto-registers itself, and its white level is overridden by the flash computation.

---

## Section 11: sub_CA08 — Swizzled `setUniformsWithLandmarks:` Hook

Replaces `GPUImageBaseBeautyFaceFilter::setUniformsWithLandmarks:`:

```c
void sub_CA08(GPUImageBaseBeautyFaceFilter *self, SEL cmd, id landmarks) {
    // Register filter
    [[BINFlashEffectBridge shared] registerFilter:self];
    
    // Apply current flash white level
    if (off_15E30) {
        NSDictionary *prefs = sub_6CDC();
        double flashWhite = sub_B394(prefs);
        off_15E30(self, @selector(setWhite:), flashWhite);   // call original setWhite:
    }
    
    // Call original setUniformsWithLandmarks: (landmark processing continues normally)
    if (off_15E50)
        off_15E50(self, cmd, landmarks);
}
```

**Effect:** Each frame that the beauty pipeline uploads GPU uniforms, the white level is synchronized with the flash state. This ensures the flash effect is applied per-frame, not just when `setWhite:` is explicitly called.

---

## Section 12: sub_B394 — Flash White Value Computation

```c
double sub_B394(NSDictionary *prefs) {
    // If flash is disabled, return NaN (no effect)
    if (!sub_7258(prefs, @"flash", NO))
        return NAN;

    double speed      = sub_72F0(prefs, @"speed",      3.0);   // Hz (pulse frequency)
    double brightness = sub_72F0(prefs, @"brightness", 51.0);  // 0-100
    double region     = sub_72F0(prefs, @"region",     30.0);  // 0-100

    double time = CACurrentMediaTime();
    
    // Square wave: on during first half of each period
    if (fmod(fmax(speed, 0.5) * time, 1.0) < 0.5) {
        // Compute white = brightness × (region × 0.45 + 0.7), clamped [0,1]
        double b = fmax(fmin(brightness / 100.0, 1.0), 0.0);
        double r = fmax(fmin(region    / 100.0, 1.0), 0.1);
        return fmax(fmin(b * (r * 0.45 + 0.7), 1.0), 0.0);
    }
    return 0.0;  // off half of flash cycle
}
```

The flash pulses as a **50% duty-cycle square wave** at `speed` Hz. When "on":
- `brightness` scales the output linearly (0–100 → 0.0–1.0)
- `region` modulates the amplitude floor: higher region = higher minimum brightness

At default settings (`speed=3.0 Hz, brightness=51.0, region=30.0`):
- "On" white value = `0.51 × (0.30 × 0.45 + 0.7)` = `0.51 × 0.835` ≈ **0.426**
- Pulses at 3 Hz with 50% duty cycle

---

## Section 13: Preferences System

### Loading: `sub_6CDC` (0x6CDC)

1. **Plist discovery** — tries 4 paths in order, uses first valid dict:
   ```
   /var/mobile/Library/Preferences/com.meo.flashaddon.plist     (rootful jailbreak)
   /var/jb/var/mobile/Library/Preferences/com.meo.flashaddon.plist  (rootless/Dopamine)
   /var/tmp/com.meo.flashaddon.plist                             (fallback)
   /tmp/com.meo.flashaddon.plist                                 (last resort)
   ```

2. **Darwin notify check** — `notify_register_check("com.meo.flashaddon.changed", &token)`:
   - Calls `notify_get_state(token, &state64)`
   - If bit 63 set (`state64 & 0x8000000000000000`): **unpacks** the 64-bit state (see Section 14) — **overrides plist values** with in-memory packed state

3. Returns `NSDictionary *` with current settings.

### Saving: `sub_7E78` (0x7E78)

1. Loads current prefs via `sub_6CDC()`
2. Merges new values: `[currentPrefs addEntriesFromDictionary:newValues]`
3. Writes to **all 4 paths** simultaneously:
   ```
   NSFileManager createDirectoryAtPath:withIntermediateDirectories:YES  (ensure parent)
   [dict writeToFile:path atomically:YES]
   NSFileManager setAttributes:{NSFilePosixPermissions: @(0644)} ofItemAtPath:path
   ```
4. Calls `sub_89C4(mergedDict)` — packs state and calls `notify_set_state`
5. Calls `notify_post("com.meo.flashaddon.changed")` — wakes all listeners

### Helper Functions

**`sub_7258(dict, key, default_bool)` — bool reader:**
```objc
id val = dict[key];
return [val respondsToSelector:@selector(boolValue)] ? [val boolValue] : default_bool;
```

**`sub_72F0(dict, key, default_double)` — double reader:**
```objc
id val = dict[key];
return [val respondsToSelector:@selector(doubleValue)] ? [val doubleValue] : default_double;
```

---

## Section 14: Darwin Notify State Bit-Packing (`sub_89C4`)

The 64-bit state value packed into `notify_set_state` / read back from `notify_get_state`:

```
Bit 63      : dirty flag (always 1 when written)
Bit  0      : live       (bool, 1=enabled)
Bit  1      : flash      (bool, 1=enabled)
Bit  2      : manualRegion (bool)
Bits  3..12 : speed      = (int)(clamp(speed, 0, 102.3) × 10)     [10 bits, mask 0x1FF8]
Bits 13..19 : brightness = (int)clamp(brightness, 0, 100)           [7 bits, mask 0xFE000]
Bits 20..26 : region     = (int)clamp(region, 0, 100)               [7 bits, mask 0x7F00000]
Bits 27..36 : hue        = (int)(clamp(hue, 0, 1.0) × 1000)        [10 bits]
Bits 37..46 : regionX    = (int)(clamp(regionX, 0, 1.0) × 1000)    [10 bits]
Bits 47..56 : regionY    = (int)(clamp(regionY, 0, 1.0) × 1000)    [10 bits]
Bits 57..62 : (unused)
```

**Packing formula (from sub_89C4):**
```c
uint64_t state =
    0x8000000000000000ULL                                       // dirty flag
  | (live  ? 1ULL : 0)                                         // bit 0
  | (flash ? 2ULL : 0)                                         // bit 1
  | (manualRegion ? 4ULL : 0)                                  // bit 2
  | ((llround(clamp(speed, 0, 102.3) * 10.0) * 8) & 0x1FF8)   // bits 3-12
  | ((llround(clamp(brightness, 0, 100)) << 13) & 0xFE000)     // bits 13-19
  | ((llround(clamp(region, 0, 100)) << 20) & 0x7F00000)       // bits 20-26
  | ((llround(clamp(hue, 0, 1.0) * 1000.0) & 0x3FF) << 27)    // bits 27-36
  | ((llround(clamp(regionX, 0, 1.0) * 1000.0) & 0x3FF) << 37)// bits 37-46
  | ((llround(clamp(regionY, 0, 1.0) * 1000.0) & 0x3FF) << 47);// bits 47-56
notify_set_state(token, state);
```

**Why two systems (plist + notify)?**
- The plist provides persistent storage across app launches
- The Darwin notify state provides **zero-latency in-process IPC** — `notify_get_state` is a single syscall, much faster than reading a plist from disk. BINFlashEffectBridge reads state 20× per second during the timer tick; using the notify channel means the app never hits disk.
- The `notify_post` call wakes the MediaServerd process (vcamera.dylib side) to pick up changes

---

## Section 15: Complete Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                   APP PROCESS (camera app)                          │
│                                                                     │
│  BINFlashAddon.dylib loaded by MobileLoader                         │
│       │                                                             │
│  InitFunc_0 (0xB588)                                                │
│       │ dispatch_async(main_queue)                                  │
│       ▼                                                             │
│  BINFlashController::startWhenReady                                 │
│       │ UIApplicationDidFinishLaunching                             │
│       ▼                                                             │
│  BINFlashController::start                                          │
│       │                                                             │
│       ├── BINFlashPassThroughWindow (UIWindowLevelAlert+1000)       │
│       │       ├── BINFlashOvalView (full-screen color picker)       │
│       │       ├── BINFlashPanel (settings, hidden initially)        │
│       │       └── BINFlashMiniButton "BIN" (visible at startup)     │
│       │                                                             │
│       └── NSTimer 0.05s → BINFlashController::tick                  │
│                                │                                    │
│                                ▼                                    │
│                   BINFlashEffectBridge::tick                        │
│                       │                                             │
│               (first call only)                                     │
│               method_setImplementation(                             │
│                 GPUImageBaseBeautyFaceFilter::setWhite: → sub_C924  │
│                 GPUImageBaseBeautyFaceFilter::setUniformsWithLandmarks: → sub_CA08)│
│                       │                                             │
│               (every call)                                          │
│               sub_6CDC() → load prefs                               │
│               sub_B394(prefs) → compute white value                 │
│               for filter in self.filters:                           │
│                   [filter setWhite:whiteValue]                      │
│                                                                     │
│                                                                     │
│  User taps "BIN" button                                             │
│       │                                                             │
│       ▼                                                             │
│  BINFlashController::showPanel                                      │
│       └── BINFlashPanel::reloadFromPrefs ← sub_6CDC()              │
│                                                                     │
│  User changes setting (switch/slider/color)                         │
│       │                                                             │
│       ▼                                                             │
│  sub_79A4(key, value)                                               │
│       │                                                             │
│       ▼                                                             │
│  sub_7E78(newValues)                                                │
│       ├── sub_6CDC() — merge with current                           │
│       ├── write plist to 4 paths                                    │
│       ├── sub_89C4(dict) — pack 64-bit state → notify_set_state()   │
│       └── notify_post("com.meo.flashaddon.changed")                 │
│                   │                                                 │
│                   ▼                                                 │
│       BINFlashEffectBridge::tick reads new state                    │
│       via sub_6CDC() → notify_get_state() → unpack                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

GPUImage render frame (triggered by app's camera pipeline):
    GPUImageBaseBeautyFaceFilter::setUniformsWithLandmarks: called
        │
        ▼ (swizzled by BINFlashEffectBridge)
    sub_CA08:
        registerFilter: self     (weak ref in NSHashTable)
        off_15E30(self, setWhite:, sub_B394(sub_6CDC()))  → original setWhite:
        off_15E50(self, cmd, landmarks)                    → original setUniformsWithLandmarks:
```

---

## Section 16: Settings Reference Table

| Key | Type | Default | Range | Packing |
|---|---|---|---|---|
| `live` | bool | YES | on/off | bit 0 |
| `flash` | bool | NO | on/off | bit 1 |
| `manualRegion` | bool | NO | on/off | bit 2 |
| `speed` | float | 3.0 | 0.5–102.3 | bits 3–12 (×10) |
| `brightness` | float | 51.0 | 0–100 | bits 13–19 (int) |
| `region` | float | 30.0 | 0–100 | bits 20–26 (int) |
| `hue` | float | 0.33 | 0.0–1.0 | bits 27–36 (×1000) |
| `regionX` | float | 0.5 | 0.0–1.0 | bits 37–46 (×1000) |
| `regionY` | float | 0.42 | 0.0–1.0 | bits 47–56 (×1000) |

---

## Section 17: ObjC Class / Method Table

### BINFlashController
| Method | Addr | Role |
|---|---|---|
| `+shared` | 0xAD60 | Singleton |
| `startWhenReady` | 0xAB60 | Post-launch init |
| `start` | 0x947C | Full UI construction |
| `showPanel` | 0xA808 | Show settings panel |
| `tick` | 0xAA30 | 20Hz animation/effect tick |
| `moveView:withPan:` | 0xA960 | Drag helper |
| `handlePanelPan:` | 0xA6A4 | Panel gesture |
| `handleMiniPan:` | 0xA504 | Mini button gesture |

### BINFlashPanel
| Method | Addr | Role |
|---|---|---|
| `initWithFrame:` | 0x5324 | Build full panel UI |
| `reloadFromPrefs` | 0x6AA0 | Sync controls from prefs |
| `addSwitchRow:key:y:` | 0x6100 | Factory: UISwitch row |
| `addAimButtonWithSystemName:fallback:frame:action:` | 0x6404 | Factory: direction button |
| `addSliderRow:key:min:max:y:valueLabel:` | 0x6768 | Factory: UISlider row |
| `updateValueLabels` | 0x7388 | Refresh numeric labels |
| `updateAimButtons:` | 0x75EC | Highlight active region button |
| `switchChanged:` | 0x78CC | Handle UISwitch toggle |
| `sliderChanged:` | 0x7A98 | Handle UISlider change |
| `colorChanged:` | 0x7B84 | Handle hue selection |
| `nudgeRegionByX:y:` | 0x7C24 | Move region target ±delta |
| `nudgeLeftTapped` | 0x8250 | → nudgeRegionByX:-0.1 y:0 |
| `nudgeRightTapped` | 0x8268 | → nudgeRegionByX:+0.1 y:0 |
| `nudgeUpTapped` | 0x8280 | → nudgeRegionByX:0 y:-0.1 |
| `nudgeDownTapped` | 0x8298 | → nudgeRegionByX:0 y:+0.1 |
| `hideTapped` | 0x82B0 | Call hideHandler block |
| `resetTapped` | 0x8344 | Reset to defaults, save |

### BINFlashEffectBridge
| Method | Addr | Role |
|---|---|---|
| `+shared` | 0xAD78 | Singleton |
| `tick` | 0xB094 | Swizzle once, then apply white 20Hz |
| `registerFilter:` | — | Add filter to weak NSHashTable |

### Key C Functions
| Symbol | Addr | Role |
|---|---|---|
| `sub_6CDC` | 0x6CDC | Load prefs (plist + notify state) |
| `sub_7E78` | 0x7E78 | Save prefs (plist + notify_post) |
| `sub_89C4` | 0x89C4 | Pack 64-bit state → notify_set_state |
| `sub_B394` | 0xB394 | Flash white value computation |
| `sub_7258` | 0x7258 | Bool dict getter with default |
| `sub_72F0` | 0x72F0 | Double dict getter with default |
| `sub_C924` | 0xC924 | Swizzled setWhite: hook |
| `sub_CA08` | 0xCA08 | Swizzled setUniformsWithLandmarks: hook |
| `InitFunc_0` | 0xB588 | __mod_init_func constructor |
