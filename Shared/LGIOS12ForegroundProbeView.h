#import <UIKit/UIKit.h>

// ===========================================================================
// ON-SCREEN FOREGROUND PROBE
//
// A self-diagnosing UIKit surface. It answers, visibly on the device screen,
// the one question the logs have not settled: does ANY mechanism on iOS 12
// yield actual Home Screen icon artwork?
//
// It captures the first visible SBIconView into a bitmap matching ONLY that
// icon's local bounds -- no wallpaper, no cardOrigin, no screen conversion,
// no refraction, no container -- through four independent mechanisms, and
// shows each result as a labelled thumbnail with its live pixel count.
//
// Deliberately contains no Metal, no shader, and no provider capture code. It
// is a plain UIView living in the standalone overlay window (already excluded
// from capture), so it cannot perturb the wallpaper path, the capture CTM, or
// the glass renderer, and cannot be captured by them either.
// ===========================================================================
@interface LGIOS12ForegroundProbeView : UIView

- (void)startProbing;
- (void)stopProbing;

@end
