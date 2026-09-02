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
// WHAT THE SETTING CONTROLS -- AND ONLY THIS
//
// The BACKDROP TEXTURE RESOLUTION. Nothing else. The slider value is used
// directly as the multiplier on the full-screen capture scale, monotonically
// and without tiers: 1.00 -> 1.00x native, 0.60 -> 0.60x, 0.10 -> 0.10x, with
// the aspect ratio preserved because one factor scales both axes.
//
// It does NOT change blur, blur radius, refraction, distortion, tint, Fresnel,
// specular, corner radius, or any other shader parameter.
//
// IT HAS NO CONNECTION TO TIMING AT ALL. This module exposes no FPS, no
// cadence and no interval, so quality cannot influence capture rate even by
// accident. Capture cadence is owned entirely by the provider and is derived
// from measured frame latency, never from this setting. 10% quality and 100%
// quality capture at exactly the same rate. The glass is rendered at the display's native scale
// at every quality level, so the effect looks identical -- it is simply
// sampling a sharper or softer source.
//
// This decoupling required one change in the kernel. It previously computed
// sampleUV = (cardOrigin + px + dispPx) / sourceResolution, adding OUTPUT-space
// pixels straight to a SOURCE-space origin, which is only valid when the two
// scales are equal. A sourceScale uniform (captureScale / outputScale) now
// makes the conversion explicit. At 100% quality sourceScale is 1.0 and every
// expression reduces to the previous one exactly, so the device-verified
// appearance is unchanged.

typedef NS_ENUM(NSInteger, LGIOS12QualityTier) {
    LGIOS12QualityTierLow = 0,
    LGIOS12QualityTierMedium,
    LGIOS12QualityTierHigh,
};

// Diagnostic label only (LOW/MEDIUM/HIGH). Gates nothing.
LGIOS12QualityTier LGIOS12QualityCurrentTier(void);
NSString *LGIOS12QualityTierName(LGIOS12QualityTier tier);

// The slider value used directly as a backdrop-resolution multiplier.
CGFloat LGIOS12QualityRenderScaleFactor(void);

// UIScreen.mainScreen.scale * the factor above -- the scale of the shared
// BACKDROP CAPTURE only. Glass rendering stays at the native screen scale.
CGFloat LGIOS12QualityEffectiveScale(void);

// Bumped whenever the setting changes. Clients compare a stored value against
// this to notice a live quality change without polling preferences.
uint32_t LGIOS12QualityGeneration(void);

// Called from the existing preference-reload path. Re-reads the setting and,
// if the effective configuration changed, bumps the generation.
void LGIOS12QualityReload(void);
