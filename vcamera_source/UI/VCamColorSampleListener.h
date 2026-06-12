// VCamColorSampleListener.h
// Runs inside the frontmost UIKit app (TikTok, camera apps, etc.)
// Listens for "com.vcam.samplerequest" Darwin notifications from SpringBoard,
// samples UIScreen from within the app's own process, and posts the hue back
// via "com.vcam.sampleresponse".  Because the snapshot runs inside the app
// that owns the pixels, cross-process content is guaranteed to be captured.

#pragma once
void vcamInstallColorSampleListener(void);
