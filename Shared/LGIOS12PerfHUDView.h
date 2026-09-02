#import <UIKit/UIKit.h>

// ===========================================================================
// MODE 9 PERFORMANCE HUD
//
// Displays the full pipeline instrumentation on screen. Exists because the
// alternative -- reading timings out of a log file -- costs a device round
// trip per measurement, and because the numbers that matter (delivered FPS,
// texture age, worst-frame stalls) are the ones a screen recording shows
// directly alongside the smoothness being judged.
//
// Mode 9 only. Mode 0 never creates this view.
// ===========================================================================
@interface LGIOS12PerfHUDView : UIView

- (void)startSampling;
- (void)stopSampling;

@end
