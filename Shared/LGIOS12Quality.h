#import <UIKit/UIKit.h>

// ===========================================================================
// SHARED iOS 12 LIQUID GLASS QUALITY PIPELINE
//
// One quality decision for the whole iOS 12 Metal path. Every client -- the
// standalone card, Control Center, Notification Center, the Dock when it is
// enabled -- reads the same tier through the shared provider, so there is no
// per-surface quality implementation.
//
// EXISTING UI SEMANTICS ARE PRESERVED. The setting is the existing
// Global.Quality slider: a continuous value from 0.1 to 1.0, default 1.0. It
// is not repurposed, relabelled or re-ranged; it is only given a real effect
// on iOS 12, where it previously did nothing at all (LGQualityValue() in
// LGLiveBackdropView.m is the non-iOS-12 consumer and is untouched).
//
// The default of 1.0 maps to HIGH with a render scale of exactly 1.0, so an
// untouched install renders bit-identically to the device-verified build.
//
// WHAT THE TIER CONTROLS
//
//   render scale     multiplies the screen scale for BOTH the CPU backdrop
//                    capture buffer AND the Metal compute output texture.
//                    Tying them together is not an optimisation -- it is
//                    required for correctness: the shader adds output-space
//                    pixel coordinates directly to the source-space cardOrigin
//                    (sampleUV = (cardOrigin + px + disp) / sourceResolution),
//                    so the two spaces MUST share a scale or refraction
//                    misaligns. One scale drives capture, output, cardOrigin,
//                    corner radius, bezel and blur together, which is why
//                    lowering quality reduces work without changing the look
//                    beyond resolution.
//
//   cadence ceiling  caps how fast the adaptive ladder may run. It is a
//                    CEILING, not a target: the existing 30/24/20/15 ladder
//                    still measures real latency and drops below it freely.
//                    Quality never forces MORE capturing.
//
// The compute output is upscaled by the existing present pass, which already
// samples with filter::linear over normalized coordinates, so no shader source
// change is needed to support this.
// ===========================================================================

typedef NS_ENUM(NSInteger, LGIOS12QualityTier) {
    LGIOS12QualityTierLow = 0,
    LGIOS12QualityTierMedium,
    LGIOS12QualityTierHigh,
};

// Current tier, derived from Global.Quality. Cheap; safe to call per frame.
LGIOS12QualityTier LGIOS12QualityCurrentTier(void);
NSString *LGIOS12QualityTierName(LGIOS12QualityTier tier);

// Multiplier applied to UIScreen.mainScreen.scale. 1.0 at HIGH.
CGFloat LGIOS12QualityRenderScaleFactor(void);

// UIScreen.mainScreen.scale * the factor above -- the single scale that the
// capture buffer, the compute output texture and the shader's screen-space
// uniforms all share.
CGFloat LGIOS12QualityEffectiveScale(void);

// Upper bound on capture rate for the tier. The adaptive ladder may still run
// slower than this; it may never run faster.
double LGIOS12QualityMaxCaptureFPS(void);

// Bumped whenever the setting changes. Clients compare a stored value against
// this to notice a live quality change without polling preferences.
uint32_t LGIOS12QualityGeneration(void);

// Called from the existing preference-reload path. Re-reads the setting and,
// if the effective configuration changed, bumps the generation.
void LGIOS12QualityReload(void);
