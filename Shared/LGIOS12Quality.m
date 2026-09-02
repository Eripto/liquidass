#import "LGIOS12Quality.h"
#import "LGSharedSupport.h"

static LGIOS12QualityTier sTier = LGIOS12QualityTierHigh;
static CGFloat sRenderScaleFactor = 1.0;
static double sMaxCaptureFPS = 30.0;
static uint32_t sGeneration = 1;
static dispatch_once_t sLoadOnce;

// Tier thresholds over the existing 0.1-1.0 slider range. The default of 1.0
// lands in HIGH with a factor of exactly 1.0, so an untouched install is
// unchanged from the verified build.
static void LGIOS12QualityApplyValue(CGFloat quality) {
    if (!isfinite(quality)) quality = 1.0;
    quality = fmin(1.0, fmax(0.1, quality));

    LGIOS12QualityTier tier;
    CGFloat factor;
    double maxFPS;
    if (quality < 0.40) {
        tier = LGIOS12QualityTierLow;
        factor = 0.50;      // quarter of the pixels, CPU and GPU alike
        maxFPS = 20.0;
    } else if (quality < 0.80) {
        tier = LGIOS12QualityTierMedium;
        factor = 0.75;
        maxFPS = 24.0;
    } else {
        tier = LGIOS12QualityTierHigh;
        factor = 1.00;      // exactly the verified configuration
        maxFPS = 30.0;
    }

    BOOL changed = (tier != sTier) || (factor != sRenderScaleFactor) ||
                   (maxFPS != sMaxCaptureFPS);
    sTier = tier;
    sRenderScaleFactor = factor;
    sMaxCaptureFPS = maxFPS;
    if (changed) {
        sGeneration++;
        LGLog(@"ios12.quality tier=%@ sliderValue=%.2f renderScaleFactor=%.2f "
              "maxCaptureFPS=%.0f generation=%u",
              LGIOS12QualityTierName(tier), quality, factor, maxFPS, sGeneration);
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
