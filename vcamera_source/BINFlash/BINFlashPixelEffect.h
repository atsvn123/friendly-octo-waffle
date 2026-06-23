// BINFlashPixelEffect.h
// Direct pixel brightening + hue tint effect applied to CVPixelBuffers.
// Handles YUV biplanar (420f/420v) and packed BGRA/ARGB formats.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

// Apply flash brightness + hue tint to a CVPixelBuffer.
// No-op if: buffer nil, flash disabled, or frame already processed this tick.
void BINFlashApplyToPixelBuffer(CVPixelBufferRef pixbuf);

// Compute current flash brightness multiplier (sub_5C0C).
// Returns NAN  → flash off
// Returns 0.0  → in the "off" half of duty cycle
// Returns >0   → in the "on" half
double BINFlashCurrentBrightness(NSDictionary *prefs);
