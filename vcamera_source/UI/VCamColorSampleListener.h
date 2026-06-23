// VCamColorSampleListener.h
// Runs inside the frontmost UIKit app (TikTok, camera apps, etc.)
// Listens for "com.vcam.samplerequest" Darwin notifications from SpringBoard,
// samples UIScreen from within the app's own process, and posts the hue back
// via "com.vcam.sampleresponse".  Because the snapshot runs inside the app
// that owns the pixels, cross-process content is guaranteed to be captured.

#pragma once
void vcamInstallColorSampleListener(void);
// Listens for "com.vcam.debugcapture" (volume-down double-tap from SpringBoard)
// and saves a 300×300 PNG of the colour-picker sample area to
// /var/mobile/Documents/vcam_color_YYYYMMDD_HHmmss.png.
void vcamInstallDebugCaptureListener(void);
