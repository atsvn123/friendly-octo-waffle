// BINFlashPixelEffect.h
// Reconstructed from:
//   sub_4628 (0x4628) — core pixel effect engine (3328 bytes)
//   sub_5C0C (0x5C0C) — flash brightness value calculator

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

// Applies the flash brightness + hue tint effect to a CVPixelBuffer.
// Handles YUV biplanar (420f/420v) and packed BGRA/ARGB formats.
//
// sub_4628 — called from all CMSampleBuffer hooks and VCamLiveManager hooks.
// No-op if: buffer is nil, not a CVPixelBuffer, flash is off, or frame was already processed this tick.
void BINFlashApplyToPixelBuffer(CVPixelBufferRef pixbuf);

// Computes the current flash brightness multiplier.
// sub_5C0C.
//   Returns NAN  → flash pref is disabled
//   Returns 0.0  → in the "off" half of the duty cycle
//   Returns >0   → in the "on" half; value = brightness/100 × (region/100×0.25 + 0.90)
double BINFlashCurrentBrightness(NSDictionary *prefs);
