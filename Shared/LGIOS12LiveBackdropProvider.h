#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

// ===========================================================================
// PIPELINE INSTRUMENTATION
//
// Every stage is timed separately so optimization targets measured cost
// rather than suspicion. Averages are exponential moving averages (alpha
// 0.1); worst values are the maximum over a window that resets every 120
// captures, so a single stall stays visible without permanently poisoning
// the reading.
//
// Collection is deliberately cheap enough to leave on in Mode 0: two
// mach_absolute_time() reads and a few adds per stage, no allocation and no
// string work. DISPLAY of these numbers is what costs, and that happens only
// in the Mode 9 perf HUD or in rate-limited debug logging.
// ===========================================================================
typedef struct {
    double ema;
    double worst;
} LGIOS12Stat;

typedef struct {
    LGIOS12Stat displayLinkInterval;
    LGIOS12Stat windowDiscovery;
    LGIOS12Stat iconEnumeration;
    LGIOS12Stat strategyLookup;
    LGIOS12Stat iconComposition;
    LGIOS12Stat wallpaperComposition;
    LGIOS12Stat bitmapContext;
    LGIOS12Stat imageCreation;
    LGIOS12Stat textureUpload;
    LGIOS12Stat totalSourceFrame;
    LGIOS12Stat metalRedrawInterval;
    LGIOS12Stat textureAge;

    double deliveredBackdropFPS;
    double metalRedrawFPS;
    double targetFPS;

    NSUInteger iconsEnumerated;
    NSUInteger iconsDrawn;
    NSUInteger primitivesDrawn;

    NSUInteger iconCacheHits;
    NSUInteger iconCacheMisses;
    NSUInteger iconCacheEntries;
    NSUInteger iconCacheBytes;
    NSUInteger captureBufferBytes;
    NSUInteger backdropTextureWidth;
    NSUInteger backdropTextureHeight;

    unsigned long long droppedStale;
    unsigned long long droppedSuperseded;
    unsigned long long captureCount;

    BOOL legacyPath;

    // Quality diagnostics
    NSInteger qualityTier;          // LGIOS12QualityTier
    double    qualityEffectiveScale;
    double    qualityMaxCaptureFPS;
} LGIOS12PerfSnapshot;

@protocol LGIOS12LiveBackdropClient <NSObject>
- (void)providerDidUpdateBackdropTexture:(id<MTLTexture>)texture source:(NSString *)source;
- (void)providerDidFailToUpdateBackdrop:(NSError *)error;
@end

@interface LGIOS12LiveBackdropProvider : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLTexture> currentBackdropTexture;
@property (nonatomic, readonly) NSString *currentSourceDescription;

+ (instancetype)sharedProvider;

- (void)registerClient:(id<LGIOS12LiveBackdropClient>)client;
- (void)unregisterClient:(id<LGIOS12LiveBackdropClient>)client;

- (void)requestRefresh;
- (void)setClient:(id<LGIOS12LiveBackdropClient>)client
    requestsContinuousRefresh:(BOOL)active;

- (void)registerGlassViewForExclusion:(UIView *)glassView;
- (void)unregisterGlassViewForExclusion:(UIView *)glassView;

// Read-only snapshot of the most recent foreground composition, published for
// the on-screen visual probe so it can distinguish "no icon pixels exist" from
// "icon pixels exist but composition dropped them" without reading a log.
// Written on the main thread during capture; no side effects on read.
@property (nonatomic, readonly) NSUInteger lastForegroundIconsEnumerated;
@property (nonatomic, readonly) NSUInteger lastForegroundIconsDrawn;
@property (nonatomic, readonly) NSUInteger lastForegroundPrimitivesDrawn;
@property (nonatomic, readonly, copy) NSString *lastForegroundPathName;

// The single shared scale for the capture buffer, the Metal compute output
// texture and the shader's screen-space uniforms. Driven by the Global.Quality
// tier. Glass clients MUST use this rather than UIScreen.scale, because the
// shader adds output-space pixels to the source-space cardOrigin and the two
// spaces have to share a scale.
- (CGFloat)effectiveCaptureScale;

// Live pipeline timings. Cheap to read; safe on the main thread.
- (LGIOS12PerfSnapshot)performanceSnapshot;

// Called by a client from its Metal draw callback so redraw rate and texture
// age can be reported alongside the capture-side numbers. Cheap: two clock
// reads and a couple of adds.
- (void)noteClientRedraw;

@end

// Runtime performance toggles, read once per SpringBoard launch from
// /var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist:
//
//   PerfLegacyPath (Boolean)  YES disables every optimization added in the
//                             performance phase -- icon artwork/strategy
//                             caching, the wallpaper base cache and the
//                             self-owned capture buffers -- so the SAME build
//                             can produce genuine before/after numbers on the
//                             same hardware. Default NO.
extern BOOL LGIOS12PerfLegacyPath(void);

// Diagnostic mode selection -- see the block comment in
// LGIOS12LiveBackdropProvider.m for the full mode table and the plist path.
// 0=NORMAL 1=RAW_BACKDROP 2=WALLPAPER_ONLY 3=FOREGROUND_ONLY
// 4=COMPOSITE_RAW 5=FREEZE_PROVIDER 6=PROVIDER_OFF
extern NSInteger LGIOS12CurrentDiagMode(void);
// YES for modes 1-4: bypass the Liquid Glass shader and show the raw source
// crop, so spatial/orientation errors can be seen before any glass math.
extern BOOL LGIOS12DiagRawDisplay(void);
