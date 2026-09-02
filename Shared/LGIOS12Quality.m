#import "LGIOS12Quality.h"
#import "LGSharedSupport.h"

static LGIOS12QualityTier sTier = LGIOS12QualityTierHigh;
static CGFloat sRenderScaleFactor = 1.0;
// Global capture target. Quality does not modify it.
static const double kLGIOS12TargetCaptureFPS = 40.0;
static double sMaxCaptureFPS = kLGIOS12TargetCaptureFPS;
static uint32_t sGeneration = 1;
static dispatch_once_t sLoadOnce;

// Tier thresholds over the existing 0.1-1.0 slider range. The default of 1.0
// lands in HIGH with a factor of exactly 1.0, so an untouched install is
// unchanged from the verified build.
static void LGIOS12QualityApplyValue(CGFloat quality) {
    if (!isfinite(quality)) quality = 1.0;
    quality = fmin(1.0, fmax(0.1, quality));

    // MONOTONIC IDENTITY MAPPING. The slider value IS the backdrop resolution
    // multiplier: 1.00 -> 1.00x native, 0.60 -> 0.60x, 0.10 -> 0.10x. No tiers
    // and no rounding, so every slider movement changes the source texture
    // dimensions. Aspect ratio is preserved because the same factor scales both
    // axes of the full-screen capture.
    CGFloat factor = quality;

    // The tier is now a DIAGNOSTIC LABEL ONLY. It no longer gates anything --
    // it never changes cadence and never changes a visual parameter.
    LGIOS12QualityTier tier = (quality < 0.40) ? LGIOS12QualityTierLow
                            : (quality < 0.80) ? LGIOS12QualityTierMedium
                                               : LGIOS12QualityTierHigh;

    BOOL changed = (factor != sRenderScaleFactor);
    sTier = tier;
    sRenderScaleFactor = factor;
    sMaxCaptureFPS = kLGIOS12TargetCaptureFPS;   // quality never limits cadence
    if (changed) {
        sGeneration++;
        LGLog(@"ios12.quality value=%.2f backdropScaleFactor=%.2f label=%@ generation=%u "
              "(resolution only -- blur/refraction/tint/Fresnel/specular/radius unaffected)",
              quality, factor, LGIOS12QualityTierName(tier), sGeneration);
    }
}

static void LGIOS12QualityLoadIfNeeded(void) {
    dispatch_once(&sLoadOnce, ^{
        LGIOS12QualityReload();
    });
}

void LGIOS12QualityReload(void) {
    // Same key and same semantics as the existing slider.
    CGFloat quality = LG_prefFloat(@"Global.Quality", 1.0);
    LGIOS12QualityApplyValue(quality);
}

LGIOS12QualityTier LGIOS12QualityCurrentTier(void) {
    LGIOS12QualityLoadIfNeeded();
    return sTier;
}

NSString *LGIOS12QualityTierName(LGIOS12QualityTier tier) {
    switch (tier) {
        case LGIOS12QualityTierLow:    return @"LOW";
        case LGIOS12QualityTierMedium: return @"MEDIUM";
        case LGIOS12QualityTierHigh:   break;
    }
    return @"HIGH";
}

CGFloat LGIOS12QualityRenderScaleFactor(void) {
    LGIOS12QualityLoadIfNeeded();
    return sRenderScaleFactor;
}

CGFloat LGIOS12QualityEffectiveScale(void) {
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 2.0;
    CGFloat scale = screenScale * LGIOS12QualityRenderScaleFactor();
    return fmax(1.0, scale);
}

double LGIOS12QualityMaxCaptureFPS(void) {
    LGIOS12QualityLoadIfNeeded();
    return sMaxCaptureFPS;
}

uint32_t LGIOS12QualityGeneration(void) {
    LGIOS12QualityLoadIfNeeded();
    return sGeneration;
}
