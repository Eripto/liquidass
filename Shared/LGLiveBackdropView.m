#import "LGLiveBackdropView.h"
#import "LGSharedSupport.h"
#import "LGHostRegistry.h"
#import "LGCoverSheetState.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "LGIOS12LiveBackdropProvider.h"
#import "LGIOS12MetalShader.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <time.h>
#import <math.h>
#import <unistd.h>

static const void *kLGOutsetKey = &kLGOutsetKey;
static const void *kLGRadiusKey = &kLGRadiusKey;
static const void *kLGSpecularEnabledOverrideKey = &kLGSpecularEnabledOverrideKey;
static const void *kLGMaterialSuppressedKey = &kLGMaterialSuppressedKey;
static const void *kLGMaterialOriginalHiddenKey = &kLGMaterialOriginalHiddenKey;
static const void *kLGMaterialOriginalAlphaKey = &kLGMaterialOriginalAlphaKey;

static BOOL LGIOS12LiveShouldLogSequence(uint64_t sequence) {
    return sequence <= 3 || (sequence % 30) == 0;
}

static NSDictionary<NSString *, id> *sLGGlassPreferences;

static NSString *LGGlassPreferencesPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = jbroot(@"/var/mobile/Library/Preferences/dylv.liquidassprefs.plist");
    });
    return path;
}

id LGGlassPreferenceValue(NSString *key) {
    if (!key.length) return nil;
    @synchronized([LGLiveBackdropView class]) {
        if (!sLGGlassPreferences) {
            sLGGlassPreferences =
                [NSDictionary dictionaryWithContentsOfFile:LGGlassPreferencesPath()] ?: @{};
        }
        return sLGGlassPreferences[key];
    }
}

void LGInvalidateGlassPreferenceCache(void) {
    @synchronized([LGLiveBackdropView class]) {
        sLGGlassPreferences = nil;
    }
}

NSString *LGFilterTypeForHostPrefix(NSString *prefix) {
    if (!prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    return host ? [NSString stringWithUTF8String:host->filterType] : nil;
}

static void sblog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void sblog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *format = [NSString stringWithUTF8String:fmt ?: ""];
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    LGLog(@"[LGSB] %@", message);
}

static const NSInteger kLGDynamicRadiusSteps = 32;

static CFStringRef const kLGParametersReloadedNotification =
    CFSTR("dylv.liquidglass/ParametersReloaded");
static NSHashTable<LGLiveBackdropView *> *sLGAllGlasses;
static BOOL sLGFilterRefreshSetup;
static BOOL LGSpecularEnabledForFilterType(NSString *type) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(type.UTF8String);
    if (host == &kLGHostRegistry[LGHostIdentifierCoverSheet]) return NO;
    if (host && host->specularOpacity <= 0.001f) return NO;
    NSString *prefix = host ? [NSString stringWithUTF8String:host->preferencePrefix] : nil;
    if (!prefix.length) return YES;
    id value = LGGlassPreferenceValue([prefix stringByAppendingString:@".SpecularEnabled"]);
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

static NSHashTable<LGLiveBackdropView *> *sLGMotionGlasses;
static CMMotionManager *sLGMotionManager;
static BOOL sLGMotionSetup;
static BOOL sLGMotionRunning;
static CGFloat sLGSpecularAngle = -M_PI_4;
static BOOL sLGMotionEnabled;
static CGFloat sLGMotionSensitivity = 2.0;
static CGFloat sLGMotionLoggedSensitivity = -1.0;
static CFStringRef const kLGMotionPrefsReloadNotification = CFSTR("dylv.liquidassprefs/Reload");

static void LGApplyMotionHighlightAngle(void);
static void LGRefreshMotionHighlights(void);
static void LGEnsureFilterRefreshObserver(void);
static void LGUpdateMaterialReplacement(UIView *material,
                                        LGLiveBackdropView *glass);


static BOOL LGIsSpringBoardBundle(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

static void LGReloadMotionHighlightPreferences(void) {
    id enabled = LGGlassPreferenceValue(@"Specular.Motion.Enabled");
    id sensitivity = LGGlassPreferenceValue(@"Specular.Motion.Sensitivity");
    BOOL previousEnabled = sLGMotionEnabled;
    CGFloat previousSensitivity = sLGMotionSensitivity;
    sLGMotionEnabled = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
    CGFloat value = [sensitivity respondsToSelector:@selector(doubleValue)] ? [sensitivity doubleValue] : 2.0;
    sLGMotionSensitivity = MAX(0.0, MIN(8.0, value));
    if (sLGMotionLoggedSensitivity < 0.0 || previousEnabled != sLGMotionEnabled ||
        fabs(previousSensitivity - sLGMotionSensitivity) > 0.01) {
        sLGMotionLoggedSensitivity = sLGMotionSensitivity;
        LGLog(@"motion highlights prefs enabled=%d sensitivity=%.2f", sLGMotionEnabled, sLGMotionSensitivity);
    }
}

static void LGMotionPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGInvalidateGlassPreferenceCache();
        LGReloadMotionHighlightPreferences();
        LGRefreshMotionHighlights();
    });
}

static BOOL LGUsesDynamicRadiusType(NSString *filterType) {

    return filterType.length &&
           LGHostIdentifierForFilterType(filterType.UTF8String) != LGHostIdentifierClock;
}

static BOOL LGUsesPrefsControlCaptureScale(NSString *filterType) {
    switch (LGHostIdentifierForFilterType(filterType.UTF8String)) {
        case LGHostIdentifierPrefsSlider:
        case LGHostIdentifierPrefsSwitch:
        case LGHostIdentifierPrefsButton:
        case LGHostIdentifierPrefsSegment:
            return YES;
        default:
            return NO;
    }
}

static CGFloat LGNativeBlurRadiusForFilterType(NSString *filterType) {
    const LGHostDefinition *host = LGHostDefinitionForFilterType(filterType.UTF8String);
    if (!host) return 0.0;
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    NSString *key = [prefix stringByAppendingString:@".Blur"];
    id value = LGGlassPreferenceValue(key);
    CGFloat radius = [value respondsToSelector:@selector(doubleValue)]
        ? MAX(0.0, [value doubleValue]) : host->blur;
    // The modern Cover Sheet is a zero-blur refraction surface. Its iOS 12
    // substitute has no custom Metal filter, so zero would create an effect
    // view with a nil effect and therefore no visible replacement at all.
    if (LGIsIOS12() &&
        LGHostIdentifierForFilterType(filterType.UTF8String) ==
            LGHostIdentifierCoverSheet && radius <= 0.01) {
        radius = 8.0;
    }
    return radius;
}

static BOOL LGLegacyIOS12UsesDarkMaterial(NSString *filterType) {
    switch (LGHostIdentifierForFilterType(filterType.UTF8String)) {
        case LGHostIdentifierNotification:
        case LGHostIdentifierPasscode:
        case LGHostIdentifierQuickActions:
            return YES;
        default:
            return NO;
    }
}

static NSInteger LGLegacyIOS12BlurStyleForFilterType(NSString *filterType,
                                                      CGFloat radius) {
    if (radius <= 0.01) return NSNotFound;
    // Blur "style" controls material color, not blur radius.  The previous
    // radius buckets selected ExtraLight for notifications (default blur 3),
    // which produced an opaque white-looking card.  Dark preserves the white
    // lock-screen foreground; Regular preserves wallpaper color elsewhere.
    return LGLegacyIOS12UsesDarkMaterial(filterType)
        ? UIBlurEffectStyleDark : UIBlurEffectStyleRegular;
}

static UIColor *LGLegacyTintColorForFilterType(NSString *filterType) {
    const LGHostDefinition *host =
        LGHostDefinitionForFilterType(filterType.UTF8String);
    if (!host) host = &kLGHostRegistry[LGHostIdentifierDefault];
    NSString *prefix = [NSString stringWithUTF8String:host->preferencePrefix];
    BOOL darkMaterial = LGLegacyIOS12UsesDarkMaterial(filterType);
    NSString *stored = LGGlassPreferenceValue(
        [prefix stringByAppendingString:darkMaterial
            ? @".DarkTintColor" : @".LightTintColor"]);
    NSString *hex = [stored isKindOfClass:NSString.class] && stored.length
        ? stored : [NSString stringWithUTF8String:
            darkMaterial ? host->darkTintHex : host->lightTintHex];
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]
        uppercaseString];
    if (clean.length != 6 && clean.length != 8) return UIColor.clearColor;
    unsigned long long rgba = 0;
    if (![[NSScanner scannerWithString:clean] scanHexLongLong:&rgba])
        return UIColor.clearColor;
    if (clean.length == 6) rgba = (rgba << 8) | 0xff;
    CGFloat red = ((rgba >> 24) & 0xff) / 255.0;
    CGFloat green = ((rgba >> 16) & 0xff) / 255.0;
    CGFloat blue = ((rgba >> 8) & 0xff) / 255.0;
    CGFloat alpha = (rgba & 0xff) / 255.0;
    // Public iOS 12 materials already supply their own tint/saturation pass.
    // Keep the custom tint subtle so configured #FFFFFFCC values do not turn
    // into a flat white overlay.  A small neutral tint keeps transparent
    // notification configurations visibly materialized.
    alpha = MIN(alpha, darkMaterial ? 0.16 : 0.12);
    if (LGHostIdentifierForFilterType(filterType.UTF8String) ==
            LGHostIdentifierNotification && alpha < 0.01) {
        red = green = blue = 0.0;
        alpha = 0.06;
    }
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

static UIView *LGFindVisualEffectBackdropView(UIView *view) {
    if (!view) return nil;
    NSString *className = NSStringFromClass(view.class);
    if ([className containsString:@"Backdrop"] &&
        ![view isKindOfClass:LGLiveBackdropView.class]) return view;
    for (UIView *subview in view.subviews) {
        UIView *backdrop = LGFindVisualEffectBackdropView(subview);
        if (backdrop) return backdrop;
    }
    return nil;
}

static void LGColorRGBA(UIColor *color, CGFloat *red, CGFloat *green,
                        CGFloat *blue, CGFloat *alpha) {
    *red = *green = *blue = 0.0;
    *alpha = 0.0;
    UIColor *resolved = LGResolvedColorForTraitCollection(
        color, UIScreen.mainScreen.traitCollection);
    if ([resolved getRed:red green:green blue:blue alpha:alpha]) return;
    CGFloat white = 0.0;
    if ([resolved getWhite:&white alpha:alpha]) {
        *red = *green = *blue = white;
    }
}

static id LGCreateNativeGaussianFilter(Class filterCls, CGFloat radius) {
    if (!filterCls || radius <= 0.0) return nil;
    id blurFilter = nil;
    SEL typeSelector = NSSelectorFromString(@"filterWithType:");
    if ([filterCls respondsToSelector:typeSelector]) {
        blurFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, typeSelector, @"gaussianBlur");
    }
    if (!blurFilter) {
        SEL nameSelector = NSSelectorFromString(@"filterWithName:");
        if ([filterCls respondsToSelector:nameSelector]) {
            blurFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
                filterCls, nameSelector, @"gaussianBlur");
        }
    }
    if (!blurFilter) return nil;
    @try {
        [blurFilter setValue:@(radius) forKey:@"inputRadius"];
    } @catch (__unused NSException *e) {
        return nil;
    }
    // Normalize-edges is optional on older CAFilter implementations.
    @try { [blurFilter setValue:@YES forKey:@"inputNormalizeEdges"]; }
    @catch (__unused NSException *e) {}
    return blurFilter;
}

static BOOL LGSafeSetLayerValue(CALayer *layer, id value, NSString *key) {
    if (!layer || !key.length) return NO;
    @try {
        [layer setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static const CGFloat kLGScaleMax    = 0.75;
static const CGFloat kLGScaleMin    = 0.25;

static const CGFloat kLGClockCaptureScale = 0.50;

static const CGFloat kLGCoverSheetCaptureScale = 1.00;

static const CGFloat kLGPrefsControlScale = 1.50;
static const CGFloat kLGDefaultScaleBudget = 8000.0;
static CGFloat LGQualityValue(void) {
    id value = LGGlassPreferenceValue(@"Global.Quality");
    CGFloat quality = [value respondsToSelector:@selector(doubleValue)]
        ? (CGFloat)[value doubleValue] : 1.0;
    if (!isfinite(quality)) quality = 1.0;
    return fmin(1.0, fmax(0.1, quality));
}

static CGFloat LGScaleBudget(void) {
    return kLGDefaultScaleBudget * LGQualityValue();
}

static CGFloat LGScaleForSize(CGSize s) {
    // area budget keeps total capture cost predictable
    CGFloat area = s.width * s.height;
    if (area <= 1.0) return kLGScaleMax;
    CGFloat scale = sqrt(LGScaleBudget() / area);
    return fmin(kLGScaleMax, fmax(kLGScaleMin, scale));
}

@interface LGLiveBackdropView () <LGIOS12LiveBackdropClient, MTKViewDelegate>
- (void)updateSpecular;
- (void)applySpecularAngle:(CGFloat)angle;
- (void)reapplyFilterForParameterReload;
- (void)updateIOS12ContinuousRefreshState;
@end

static void LGRefreshAllLiveGlasses(NSString *reason) {
    // Clear cached prefs before rebuilding every live filter.  This is also
    // the iOS 12 renderer reload path because backboardd deliberately does
    // not register the post-iOS-12 custom QuartzCore/Metal filter there.
    LGInvalidateGlassPreferenceCache();
    NSArray<LGLiveBackdropView *> *glasses = sLGAllGlasses.allObjects;
    LGDiagnosticLog(@"renderer.reload.begin reason=%@ filters=%lu process=%@",
                    reason ?: @"unknown", (unsigned long)glasses.count,
                    LGMainBundleIdentifier());
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSUInteger index = 0;
    for (LGLiveBackdropView *glass in glasses) {
        LGDiagnosticLog(@"renderer.reload.filter.begin reason=%@ index=%lu class=%@ type=%@ bounds=%@",
                        reason ?: @"unknown", (unsigned long)index,
                        NSStringFromClass(glass.class), glass.lgFilterType ?: @"default",
                        NSStringFromCGRect(glass.bounds));
        @try {
            [glass reapplyFilterForParameterReload];
            [glass updateSpecular];
            LGDiagnosticLog(@"renderer.reload.filter.end reason=%@ index=%lu",
                            reason ?: @"unknown", (unsigned long)index);
        } @catch (NSException *exception) {
            LGDiagnosticLog(@"renderer.reload.filter.exception reason=%@ index=%lu exception=%@ detail=%@",
                            reason ?: @"unknown", (unsigned long)index,
                            exception.name, exception.reason);
        }
        index++;
    }
    [CATransaction commit];
    LGDiagnosticLog(@"renderer.reload.end reason=%@ filters=%lu",
                    reason ?: @"unknown", (unsigned long)glasses.count);
}

static void LGParametersReloaded(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    NSString *reason = (__bridge NSString *)name ?: @"ParametersReloaded";
    dispatch_async(dispatch_get_main_queue(), ^{
        LGRefreshAllLiveGlasses(reason);
    });
}

static void LGIOS12PreferencesReloaded(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    NSString *reason = (__bridge NSString *)name ?: @"PreferencesReloaded";
    dispatch_async(dispatch_get_main_queue(), ^{
        LGDiagnosticLog(@"renderer.ios12.direct-reload.received notification=%@",
                        reason);
        LGRefreshAllLiveGlasses(reason);
    });
}

static void LGEnsureFilterRefreshObserver(void) {
    if (!sLGAllGlasses) sLGAllGlasses = [NSHashTable weakObjectsHashTable];
    if (sLGFilterRefreshSetup) return;
    sLGFilterRefreshSetup = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LGParametersReloaded,
                                    kLGParametersReloadedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    if (LGIsIOS12()) {
        // The modern backboardd renderer is unavailable on iOS 12 and thus
        // cannot translate Reload into ParametersReloaded.  Listen to the
        // original preference notification only on iOS 12.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        LGIOS12PreferencesReloaded,
                                        kLGMotionPrefsReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        LGDiagnosticLog(@"renderer.ios12.direct-reload.observer-installed process=%@",
                        LGMainBundleIdentifier());
    }
}

static void LGApplyMotionHighlightAngle(void) {
    for (LGLiveBackdropView *glass in sLGMotionGlasses.allObjects) {
        if (!glass.window || glass.hidden || glass.alpha <= 0.001) continue;
        [glass applySpecularAngle:sLGSpecularAngle];
    }
}

static void LGRefreshMotionHighlights(void) {
    if (!sLGMotionSetup || !LGIsSpringBoardBundle()) return;
    if (!sLGMotionEnabled) {
        [sLGMotionManager stopDeviceMotionUpdates];
        sLGMotionRunning = NO;
        sLGSpecularAngle = -M_PI_4;
        LGApplyMotionHighlightAngle();
        return;
    }
    if (sLGMotionRunning) return;

    CMAttitudeReferenceFrame frames = [CMMotionManager availableAttitudeReferenceFrames];
    CMAttitudeReferenceFrame frame = (frames & CMAttitudeReferenceFrameXMagneticNorthZVertical)
        ? CMAttitudeReferenceFrameXMagneticNorthZVertical
        : CMAttitudeReferenceFrameXArbitraryCorrectedZVertical;

    sLGMotionManager.deviceMotionUpdateInterval = 1.0 / 10.0;
    sLGMotionRunning = YES;
    [sLGMotionManager startDeviceMotionUpdatesUsingReferenceFrame:frame
                                                            toQueue:NSOperationQueue.mainQueue
                                                        withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion || error || !sLGMotionEnabled) return;
        CMAttitude *attitude = motion.attitude;

        CGFloat baseMotion = attitude.yaw + attitude.roll * 0.65 + attitude.pitch * 0.35;
        CGFloat target = baseMotion * (sLGMotionSensitivity / 1.5);

        CGFloat delta = atan2(sin(target - sLGSpecularAngle), cos(target - sLGSpecularAngle));
        CGFloat nextAngle = sLGSpecularAngle + delta * 0.40;
        static CGFloat lastAppliedAngle = CGFLOAT_MAX;
        if (lastAppliedAngle == CGFLOAT_MAX ||
            fabs(atan2(sin(nextAngle - lastAppliedAngle), cos(nextAngle - lastAppliedAngle))) >= 0.025) {
            sLGSpecularAngle = nextAngle;
            lastAppliedAngle = nextAngle;
            LGApplyMotionHighlightAngle();
        }
    }];
    LGLog(@"motion highlights started reference=%s", frame == CMAttitudeReferenceFrameXMagneticNorthZVertical ? "magnetic-north" : "corrected-arbitrary");
}

static void LGEnsureMotionHighlights(void) {
    if (!LGIsSpringBoardBundle()) return;
    if (!sLGMotionGlasses) sLGMotionGlasses = [NSHashTable weakObjectsHashTable];
    if (!sLGMotionManager) sLGMotionManager = [CMMotionManager new];
    if (!sLGMotionSetup) {
        sLGMotionSetup = YES;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        LGMotionPreferencesDidChange,
                                        kLGMotionPrefsReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    LGReloadMotionHighlightPreferences();
    LGRefreshMotionHighlights();
}

static const CGFloat kLGSpecularMinimumOpacity = 0.30;
static const CGFloat kLGSpecularBrightBoostOpacity = 0.70;


static id<MTLCommandQueue> sLGIOS12CommandQueue = nil;
static id<MTLComputePipelineState> sLGIOS12ComputePipeline = nil;
static id<MTLRenderPipelineState> sLGIOS12PresentPipeline = nil;
static BOOL sLGIOS12MetalInitAttempted = NO;
static BOOL sLGIOS12MetalInitSuccess = NO;

static void LGIOS12InitializeSharedMetal(id<MTLDevice> device) {
    if (sLGIOS12MetalInitAttempted) return;
    sLGIOS12MetalInitAttempted = YES;
    if (!device) return;

    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = YES;
    id<MTLLibrary> library = [device newLibraryWithSource:kLGIOS12LiveMetalSource options:options error:&error];
    if (!library) return;

    id<MTLFunction> computeFunction = [library newFunctionWithName:@"liquidGlassIOS12"];
    sLGIOS12ComputePipeline = computeFunction ? [device newComputePipelineStateWithFunction:computeFunction error:&error] : nil;

    id<MTLFunction> vertex = [library newFunctionWithName:@"presentVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"presentFragment"];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    sLGIOS12PresentPipeline = (vertex && fragment) ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;

    sLGIOS12CommandQueue = [device newCommandQueue];

    sLGIOS12MetalInitSuccess = sLGIOS12ComputePipeline && sLGIOS12PresentPipeline && sLGIOS12CommandQueue;
}

@implementation LGLiveBackdropView {
    NSString        *_lgGroupName;
    CAGradientLayer *_specular;
    CAGradientLayer *_specularBoost;
    CALayer         *_specularMask;
    CALayer         *_specularBoostMask;
    CALayer         *_nativeBlurLayer;
    CALayer         *_legacyTintLayer;
    UIVisualEffectView *_legacyIOS12BlurView;
    UIView           *_legacyIOS12TintView;
    CGFloat          _nativeBlurRadius;
    NSInteger        _legacyIOS12BlurStyle;
    BOOL             _legacyIOS12RendererReady;
    BOOL             _legacyIOS12LoggedReadyPass;
    NSUInteger       _legacyIOS12CaptureAttempts;
    NSString         *_legacyIOS12LastTintSignature;
    BOOL             _backdropConfigured;
    BOOL             _filterAttached;
    uint32_t         _lgId;
    CGFloat          _appliedScale;
    BOOL             _parameterRefreshVariant;
    MTKView *_metalView;
    id<MTLDevice> _device;
    id<MTLTexture> _backdropTexture;
    id<MTLTexture> _outputTexture;
    BOOL _metalInitializationFailed;
    BOOL _hasRenderedFirstFrame;
    uint64_t _ios12TextureDeliveryCount;
    uint64_t _ios12MetalRedrawCount;
}

- (NSString *)lgEffectiveFilterType {
    if (!_lgFilterType.length)
        return [NSString stringWithUTF8String:kLGHostRegistry[LGHostIdentifierDefault].filterType];
    NSString *base = _lgFilterType;

    if (LGUsesDynamicRadiusType(base) && !CGRectIsEmpty(self.bounds)) {
        CGFloat shortest = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
        CGFloat ratio = shortest > 0.0 ? self.layer.cornerRadius / shortest : 0.0;
        NSInteger step = (NSInteger)llround(MAX(0.0, MIN(0.5, ratio)) * kLGDynamicRadiusSteps);
        base = [base stringByAppendingFormat:@".r%ld", (long)step];
    }
    NSString *type = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? [base stringByAppendingString:@".dark"] : base;
    if (_parameterRefreshVariant) type = [type stringByAppendingString:@".refresh"];
    return type;
}

+ (Class)layerClass {
    // Never instantiate the private CABackdropLayer on iOS 12.  Setting its
    // private filter/KVC state can survive construction and then abort the
    // render-server transaction when the layer is committed.
    if (LGIsIOS12()) return [CALayer class];
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame groupName:nil filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName {
    return [self initWithFrame:frame groupName:groupName filterType:nil];
}

- (instancetype)initWithFrame:(CGRect)frame groupName:(NSString *)groupName filterType:(NSString *)filterType {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _lgFilterType = [filterType copy];
    static uint32_t idCounter = 0;
    _lgId = ++idCounter;
    if (groupName.length) {

        _lgGroupName = [groupName copy];
    } else {

        _lgGroupName = [NSString stringWithFormat:@"dylv.liquidglass.g%u", _lgId];
    }
    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];
    self.opaque                 = NO;

    _legacyIOS12BlurStyle = NSNotFound;
    if (LGIsIOS12()) {
        Class effectViewClass = NSClassFromString(@"UIVisualEffectView");
        SEL initializer = NSSelectorFromString(@"initWithEffect:");
        if (effectViewClass && [effectViewClass instancesRespondToSelector:initializer]) {
            _legacyIOS12BlurView = [[effectViewClass alloc] initWithEffect:nil];
            _legacyIOS12BlurView.frame = self.bounds;
            _legacyIOS12BlurView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                                    UIViewAutoresizingFlexibleHeight;
            _legacyIOS12BlurView.userInteractionEnabled = NO;
            _legacyIOS12BlurView.clipsToBounds = YES;
            [self insertSubview:_legacyIOS12BlurView atIndex:0];
            UIView *contentView = _legacyIOS12BlurView.contentView;
            _legacyIOS12TintView = [[UIView alloc] initWithFrame:contentView.bounds];
            _legacyIOS12TintView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                                     UIViewAutoresizingFlexibleHeight;
            _legacyIOS12TintView.userInteractionEnabled = NO;
            [contentView addSubview:_legacyIOS12TintView];
            LGDiagnosticLog(@"renderer.ios12.fallback.init process=%@ type=%@ class=%@ metalDevice=not-created shader=not-loaded pipeline=not-created reason=public-UIVisualEffectView",
                            LGMainBundleIdentifier(), _lgFilterType ?: @"default",
                            NSStringFromClass(effectViewClass));
        } else {
            LGDiagnosticLog(@"renderer.ios12.fallback.init tint-only process=%@ type=%@ reason=UIVisualEffectView-unavailable",
                            LGMainBundleIdentifier(), _lgFilterType ?: @"default");
        }
    }

    self.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if (LGIsIOS12()) {
        _device = [LGIOS12LiveBackdropProvider sharedProvider].device;
        if (_device) {
            LGIOS12InitializeSharedMetal(_device);
            if (sLGIOS12MetalInitSuccess) {
                _metalView = [[MTKView alloc] initWithFrame:self.bounds device:_device];
                _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
                _metalView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
                _metalView.opaque = NO;
                _metalView.layer.opaque = NO;
                _metalView.framebufferOnly = YES;
                _metalView.paused = YES;
                _metalView.enableSetNeedsDisplay = NO;
                _metalView.delegate = self;
                _metalView.layer.cornerRadius = self.layer.cornerRadius;
                _metalView.layer.masksToBounds = YES;
                [self addSubview:_metalView];

                [[LGIOS12LiveBackdropProvider sharedProvider] registerClient:self];
                [[LGIOS12LiveBackdropProvider sharedProvider] registerGlassViewForExclusion:self];
            } else {
                _metalInitializationFailed = YES;
            }
        } else {
            _metalInitializationFailed = YES;
        }
    }

    LGEnsureFilterRefreshObserver();
    [sLGAllGlasses addObject:self];
    LGEnsureMotionHighlights();
    [sLGMotionGlasses addObject:self];
    [self applyFilters];
    return self;
}

- (BOOL)lgRendererReady {
    if (!LGIsIOS12()) return YES;
    if (_metalView && !_metalInitializationFailed) {
        return _hasRenderedFirstFrame;
    }
    if (!_legacyIOS12BlurView || !_legacyIOS12BlurView.effect ||
        !self.window || CGRectIsEmpty(self.bounds)) return NO;
    UIView *backdrop = LGFindVisualEffectBackdropView(_legacyIOS12BlurView);
    if (backdrop) {
        return !CGRectIsEmpty(backdrop.bounds) && backdrop.alpha > 0.01 &&
               !backdrop.hidden;
    }
    // UIKit's private visual-effect subtree changed names across iOS 12.x.
    // The public contract is the attached UIVisualEffectView with a non-nil
    // effect; do not reject a functioning fallback merely because its private
    // backdrop class name does not contain the English word "Backdrop".
    return _legacyIOS12BlurView.window == self.window &&
           !CGRectIsEmpty(_legacyIOS12BlurView.bounds) &&
           !_legacyIOS12BlurView.hidden && _legacyIOS12BlurView.alpha > 0.01;
}

- (void)dealloc {
    if (LGIsIOS12()) {
        [[LGIOS12LiveBackdropProvider sharedProvider]
            setClient:self requestsContinuousRefresh:NO];
        [[LGIOS12LiveBackdropProvider sharedProvider] unregisterClient:self];
        [[LGIOS12LiveBackdropProvider sharedProvider] unregisterGlassViewForExclusion:self];
    }
    [sLGAllGlasses removeObject:self];
    [sLGMotionGlasses removeObject:self];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyFilters];
    [self updateIOS12ContinuousRefreshState];
}
- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateIOS12ContinuousRefreshState];
}
- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    [self updateIOS12ContinuousRefreshState];
}
- (void)updateIOS12ContinuousRefreshState {
    if (!LGIsIOS12()) return;
    UIWindow *window = self.window;
    BOOL visible = _metalView && !_metalInitializationFailed && window &&
                   !self.hidden && self.alpha > 0.01 &&
                   !window.hidden && window.alpha > 0.01;
    [[LGIOS12LiveBackdropProvider sharedProvider]
        setClient:self requestsContinuousRefresh:visible];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        _filterAttached = NO;
        [self applyFilters];
    }
}

- (NSNumber *)lgSpecularEnabledOverride {
    return objc_getAssociatedObject(self, kLGSpecularEnabledOverrideKey);
}

- (void)setLgSpecularEnabledOverride:(NSNumber *)override {
    NSNumber *previous = self.lgSpecularEnabledOverride;
    if ((previous == override) || [previous isEqualToNumber:override]) return;
    objc_setAssociatedObject(self, kLGSpecularEnabledOverrideKey, [override copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self updateSpecular];
}

- (void)layoutSubviews  {
    [super layoutSubviews];
    if (_metalView) {
        _metalView.frame = self.bounds;
        _metalView.layer.cornerRadius = self.layer.cornerRadius;
    }
    [self applyFilters];
    [self updateSpecular];
}

- (void)updateNativeBlurOverlayWithRadius:(CGFloat)radius filterClass:(Class)filterCls {
    if (radius <= 0.0 || !filterCls) {
        [_nativeBlurLayer removeFromSuperlayer];
        _nativeBlurLayer = nil;
        _nativeBlurRadius = 0.0;
        return;
    }

    BOOL needsFilter = !_nativeBlurLayer || fabs(_nativeBlurRadius - radius) > 0.001;
    id gaussian = needsFilter ? LGCreateNativeGaussianFilter(filterCls, radius) : nil;
    if (needsFilter && !gaussian) return;
    if (!_nativeBlurLayer) {
        Class backdropCls = NSClassFromString(@"CABackdropLayer");
        if (!backdropCls) return;
        _nativeBlurLayer = [backdropCls layer];
        @try {
            [_nativeBlurLayer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
            [_nativeBlurLayer setValue:@YES forKey:@"windowServerAware"];
            [_nativeBlurLayer setValue:[_lgGroupName stringByAppendingString:@".nativeblur"]
                                forKey:@"groupName"];
            [_nativeBlurLayer setValue:@"dylv.liquidglass.nativeblur" forKey:@"groupNamespace"];
            [_nativeBlurLayer setValue:@YES forKey:@"ignoresScreenClip"];

            [_nativeBlurLayer setValue:@1.0 forKey:@"scale"];
        } @catch (NSException *e) {
            LGLog(@"glass#%u native blur overlay configure failed: %@", _lgId, e.reason);
        }
        [self.layer insertSublayer:_nativeBlurLayer atIndex:0];
        if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) == LGHostIdentifierClock) {
            LGLog(@"clock native blur layer created radius=%.2f group=%@",
                  radius, _lgGroupName);
        }
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _nativeBlurLayer.frame = self.bounds;
    _nativeBlurLayer.cornerRadius = self.layer.cornerRadius;
    _nativeBlurLayer.masksToBounds = YES;
    @try { [_nativeBlurLayer setValue:[self.layer valueForKey:@"cornerCurve"] forKey:@"cornerCurve"]; }
    @catch (__unused NSException *e) {}
    if (gaussian) {
        _nativeBlurLayer.filters = @[gaussian];
        _nativeBlurRadius = radius;
        if (LGHostIdentifierForFilterType(_lgFilterType.UTF8String) == LGHostIdentifierClock) {
            LGLog(@"clock native blur filter applied radius=%.2f bounds=%@",
                  radius, NSStringFromCGRect(self.bounds));
        }
    }
    [CATransaction commit];
}

- (void)updateLegacyIOS12Tint {
    if (!LGIsIOS12()) {
        [_legacyTintLayer removeFromSuperlayer];
        _legacyTintLayer = nil;
        return;
    }
    UIColor *legacyTint = LGLegacyTintColorForFilterType(_lgFilterType);
    if (_legacyIOS12BlurView) {
        [_legacyTintLayer removeFromSuperlayer];
        _legacyTintLayer = nil;
        _legacyIOS12TintView.backgroundColor = legacyTint;
        CGFloat red, green, blue, alpha;
        LGColorRGBA(legacyTint, &red, &green, &blue, &alpha);
        NSString *signature = [NSString stringWithFormat:
            @"%.3f/%.3f/%.3f/%.3f/%.3f", red, green, blue, alpha, self.alpha];
        if (![_legacyIOS12LastTintSignature isEqualToString:signature]) {
            _legacyIOS12LastTintSignature = signature;
            LGDiagnosticLog(@"renderer.ios12.tint glass=%u type=%@ rgba={%.3f,%.3f,%.3f,%.3f} viewAlpha=%.3f compositing=UIKit-premultiplied",
                            _lgId, _lgFilterType ?: @"default",
                            red, green, blue, alpha, self.alpha);
        }
        return;
    }
    if (!_legacyTintLayer) {
        _legacyTintLayer = [CALayer layer];
        _legacyTintLayer.actions = @{
            @"bounds": NSNull.null,
            @"position": NSNull.null,
            @"backgroundColor": NSNull.null,
            @"cornerRadius": NSNull.null,
        };
        [self.layer insertSublayer:_legacyTintLayer atIndex:0];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _legacyTintLayer.frame = self.bounds;
    _legacyTintLayer.cornerRadius = self.layer.cornerRadius;
    _legacyTintLayer.cornerCurve = self.layer.cornerCurve;
    _legacyTintLayer.masksToBounds = YES;
    _legacyTintLayer.backgroundColor = legacyTint.CGColor;
    [CATransaction commit];
}

- (void)updateSpecular {
    if (CGRectIsEmpty(self.bounds)) return;

    NSNumber *override = self.lgSpecularEnabledOverride;
    BOOL enabled = override ? override.boolValue
                            : LGSpecularEnabledForFilterType(_lgFilterType);
    if (LGIsIOS12() && !self.lgRendererReady) enabled = NO;
    if (!enabled && !_specular) return;

    if (!_specular) {
        id clear = (id)UIColor.clearColor.CGColor;
        _specular = [CAGradientLayer layer];
        _specular.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularMinimumOpacity].CGColor,
                             clear,
                             (id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularMinimumOpacity].CGColor];
        _specular.locations = @[@0.0, @0.5, @1.0];
        _specularMask = [CALayer layer];
        _specularMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularMask.borderColor = UIColor.blackColor.CGColor;
        _specular.mask = _specularMask;
        [self.layer addSublayer:_specular];

        _specularBoost = [CAGradientLayer layer];
        _specularBoost.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularBrightBoostOpacity].CGColor,
                                  clear,
                                  (id)[UIColor colorWithWhite:1.0 alpha:kLGSpecularBrightBoostOpacity].CGColor];
        _specularBoost.locations = @[@0.0, @0.5, @1.0];
        if (LGIsIOS12()) {
            // iOS 12's render server is not asked to resolve a named
            // compositing filter. A plain alpha gradient is less refractive
            // but uses only public CoreAnimation behavior.
            _specular.opacity = 0.34;
            _specularBoost.opacity = 0.12;
        } else {
            _specularBoost.compositingFilter = @"overlayBlendMode";
        }
        _specularBoostMask = [CALayer layer];
        _specularBoostMask.backgroundColor = UIColor.clearColor.CGColor;
        _specularBoostMask.borderColor = UIColor.blackColor.CGColor;
        _specularBoost.mask = _specularBoostMask;
        [self.layer addSublayer:_specularBoost];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specular.hidden = !enabled;
    _specularBoost.hidden = !enabled;
    for (CALayer *gradient in @[_specular, _specularBoost]) gradient.frame = self.bounds;
    for (CALayer *mask in @[_specularMask, _specularBoostMask]) {
        mask.frame = self.bounds;
        mask.cornerRadius = self.layer.cornerRadius;
        mask.cornerCurve = self.layer.cornerCurve;
        mask.borderWidth = 0.75;
    }
    [CATransaction commit];
    [self applySpecularAngle:sLGSpecularAngle];
}

- (void)applySpecularAngle:(CGFloat)angle {
    if (!_specular) return;
    CGFloat dx = cos(angle) * 0.5;
    CGFloat dy = sin(angle) * 0.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _specular.startPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    _specular.endPoint = CGPointMake(0.5 - dx, 0.5 - dy);
    _specularBoost.startPoint = _specular.startPoint;
    _specularBoost.endPoint = _specular.endPoint;
    [CATransaction commit];
}

- (void)applyFilters {
    CALayer *layer = self.layer;
    if (LGIsIOS12()) {
        if (_metalView && !_metalInitializationFailed) {
            _legacyIOS12BlurView.hidden = YES;
            _legacyIOS12TintView.hidden = YES;
            _metalView.layer.cornerRadius = self.layer.cornerRadius;
            if (_hasRenderedFirstFrame) {
                [_metalView draw];
            }
            return;
        }
        CGFloat configuredRadius = LGNativeBlurRadiusForFilterType(_lgFilterType);
        NSInteger wantedStyle = LGLegacyIOS12BlurStyleForFilterType(
            _lgFilterType, configuredRadius);
        if (_legacyIOS12BlurView && _legacyIOS12BlurStyle != wantedStyle) {
            UIBlurEffect *effect = wantedStyle == NSNotFound
                ? nil : [UIBlurEffect effectWithStyle:(UIBlurEffectStyle)wantedStyle];
            SEL effectSelector = NSSelectorFromString(@"setEffect:");
            if ([_legacyIOS12BlurView respondsToSelector:effectSelector]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    _legacyIOS12BlurView, effectSelector, effect);
                _legacyIOS12BlurStyle = wantedStyle;
            }
        }
        _legacyIOS12BlurView.frame = self.bounds;
        _legacyIOS12BlurView.alpha = LGLegacyIOS12UsesDarkMaterial(_lgFilterType)
            ? 0.86 : 0.92;
        _legacyIOS12BlurView.layer.cornerRadius = self.layer.cornerRadius;
        _legacyIOS12BlurView.clipsToBounds = YES;
        [_legacyIOS12BlurView setNeedsLayout];
        [_legacyIOS12BlurView layoutIfNeeded];
        [self updateLegacyIOS12Tint];
        UIView *backdrop = LGFindVisualEffectBackdropView(_legacyIOS12BlurView);
        BOOL ready = self.lgRendererReady;
        _legacyIOS12CaptureAttempts++;
        if (ready != _legacyIOS12RendererReady ||
            (!_legacyIOS12LoggedReadyPass && ready) ||
            (_legacyIOS12CaptureAttempts <= 3 && self.window)) {
            CGFloat screenScale = UIScreen.mainScreen.scale;
            CGSize captureSize = backdrop ? backdrop.bounds.size : CGSizeZero;
            LGDiagnosticLog(@"renderer.ios12.capture glass=%u type=%@ success=%d verification=%@ effect=%@ effectAlpha=%.3f backdropClass=%@ points={%.1f,%.1f} estimatedPixels={%.0f,%.0f} backdropTexture=UIKit-system-managed window=%d finalAlpha=%.3f tintPremultiplication=UIKit-managed",
                            _lgId, _lgFilterType ?: @"default", ready,
                            backdrop ? @"private-backdrop-bounds" : @"public-effect-attached",
                            _legacyIOS12BlurView.effect
                                ? NSStringFromClass(_legacyIOS12BlurView.effect.class)
                                : @"nil",
                            _legacyIOS12BlurView.alpha,
                            backdrop ? NSStringFromClass(backdrop.class) : @"missing",
                            captureSize.width, captureSize.height,
                            captureSize.width * screenScale,
                            captureSize.height * screenScale,
                            self.window != nil, self.alpha);
        }
        _legacyIOS12RendererReady = ready;
        _legacyIOS12TintView.hidden = !ready;
        if (ready && !_legacyIOS12LoggedReadyPass) {
            _legacyIOS12LoggedReadyPass = YES;
            LGDiagnosticLog(@"renderer.ios12.renderpass glass=%u type=%@ execution=system-managed-ready blur=%.2f style=%ld saturation=UIVisualEffectView highlightLayers=2",
                            _lgId, _lgFilterType ?: @"default",
                            configuredRadius, (long)wantedStyle);
        }
        _backdropConfigured = ready;
        _filterAttached = NO;
        return;
    }
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;

    @try {

        if (!_backdropConfigured) {
            // these private flags keep capture in render server space
            LGSafeSetLayerValue(layer, @NO, @"layerUsesCoreImageFilters");
            LGSafeSetLayerValue(layer, @YES, @"windowServerAware");
            LGSafeSetLayerValue(layer, _lgGroupName, @"groupName");
            // iOS 12 returned through the public visual-effect path above;
            // these private keys therefore remain exclusive to the modern
            // renderer just as they were before the compatibility fallback.
            LGSafeSetLayerValue(layer, @"dylv.liquidglass",
                                @"groupNamespace");
            LGSafeSetLayerValue(layer, @YES, @"ignoresScreenClip");
            _backdropConfigured = YES;
        }

        CGFloat wantScale;
        switch (LGHostIdentifierForFilterType(_lgFilterType.UTF8String)) {
            case LGHostIdentifierClock:
                wantScale = kLGClockCaptureScale;
                break;
            case LGHostIdentifierCoverSheet:
                wantScale = kLGCoverSheetCaptureScale;
                break;
            default:
                wantScale = LGUsesPrefsControlCaptureScale(_lgFilterType)
                    ? kLGPrefsControlScale : LGScaleForSize(self.bounds.size);
                break;
        }
        if (fabs(wantScale - _appliedScale) > 0.02) {
            LGSafeSetLayerValue(layer, @(wantScale), @"scale");
            _appliedScale = wantScale;
            LGLog(@"glass#%u scale type=%@ bounds=%.1fx%.1f quality=%.2f budget=%.0f scale=%.3f",
                       _lgId,
                       _lgFilterType ?: @"default",
                       CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds),
                       LGQualityValue(), LGScaleBudget(), wantScale);
        }

        NSString *wantType = [self lgEffectiveFilterType];
        NSArray *existing = layer.filters;
        CGFloat nativeBlur = LGNativeBlurRadiusForFilterType(_lgFilterType ?: wantType);
        Class filterCls = NSClassFromString(@"CAFilter");

        [self updateLegacyIOS12Tint];
        [self updateNativeBlurOverlayWithRadius:nativeBlur filterClass:filterCls];

        if (_filterAttached && existing.count == 1) {
            NSString *type = nil;
            @try { type = [existing.firstObject valueForKey:@"type"]; } @catch (...) {}
            if ([type isEqualToString:wantType]) {
                return;
            }
        }
        if (!filterCls) { sblog("CAFilter class not found"); return; }

        SEL filterSelector = NSSelectorFromString(@"filterWithType:");
        if (![filterCls respondsToSelector:filterSelector]) {
            LGLog(@"glass#%u CAFilter does not implement filterWithType:", _lgId);
            return;
        }
        id glassFilter = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
            filterCls, filterSelector, wantType);

        if (!glassFilter) {
            LGLog(@"glass#%u filterWithType nil (not registered yet?)", _lgId);
            return;
        }

        layer.filters = @[glassFilter];
        _filterAttached = YES;
    } @catch (NSException *e) {
        sblog("applyFilters exception: %s", e.reason.UTF8String);
    }
}

- (void)reapplyFilterForParameterReload {

    _parameterRefreshVariant = !_parameterRefreshVariant;

    _appliedScale = -1.0;
    _filterAttached = NO;
    [self applyFilters];
    [self.layer setNeedsDisplay];
}

#pragma mark - LGIOS12LiveBackdropClient

- (void)providerDidUpdateBackdropTexture:(id<MTLTexture>)texture source:(NSString *)source {
    if (!texture) return;
    if (texture.device != _device) {
        LGDiagnosticLog(@"renderer.ios12.live texture-rejected reason=device-mismatch textureDevice=%@ rendererDevice=%@",
                        texture.device.name ?: @"nil", _device.name ?: @"nil");
        return;
    }
    _backdropTexture = texture;
    uint64_t delivery = ++_ios12TextureDeliveryCount;
    if (LGIOS12LiveShouldLogSequence(delivery)) {
        LGDiagnosticLog(@"renderer.ios12.live texture-delivery=%llu source=%@ dimensions=%lux%lu attached=%d hidden=%d alpha=%.3f",
                        (unsigned long long)delivery, source ?: @"unknown",
                        (unsigned long)texture.width,
                        (unsigned long)texture.height,
                        self.window != nil, self.hidden, self.alpha);
    }
    [_metalView draw];
}

- (void)providerDidFailToUpdateBackdrop:(NSError *)error {
    LGLog(@"LGLiveBackdropView failed to update backdrop: %@", error.localizedDescription);
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _outputTexture = nil;
}

- (void)drawInMTKView:(MTKView *)view {
    if (_metalInitializationFailed || !_backdropTexture || CGRectIsEmpty(self.bounds) || !self.window) return;

    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *renderPass = view.currentRenderPassDescriptor;
    if (!drawable || !renderPass) return;

    NSUInteger width = MAX((NSUInteger)1, (NSUInteger)llround(view.drawableSize.width));
    NSUInteger height = MAX((NSUInteger)1, (NSUInteger)llround(view.drawableSize.height));

    if (!_outputTexture || _outputTexture.width != width || _outputTexture.height != height) {
        MTLTextureDescriptor *outputDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        outputDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        _outputTexture = [_device newTextureWithDescriptor:outputDescriptor];
    }
    if (!_outputTexture) return;

    CGRect screenRect = [self convertRect:self.bounds toView:nil];
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;

    NSString *effectiveType = [self lgEffectiveFilterType];
    const LGHostDefinition *hostDef = LGHostDefinitionForFilterType(effectiveType.UTF8String);
    if (!hostDef) hostDef = &kLGHostRegistry[LGHostIdentifierDefault];
    NSString *prefix = [NSString stringWithUTF8String:hostDef->preferencePrefix];

    CGFloat blurRadius = LGNativeBlurRadiusForFilterType(effectiveType);

    id tkValue = LGGlassPreferenceValue([prefix stringByAppendingString:@".GlassThickness"]);
    float glassThickness = [tkValue respondsToSelector:@selector(doubleValue)] ? [tkValue doubleValue] : hostDef->glassThickness;

    id rsValue = LGGlassPreferenceValue([prefix stringByAppendingString:@".RefractionScale"]);
    float refractionScale = [rsValue respondsToSelector:@selector(doubleValue)] ? [rsValue doubleValue] : hostDef->refractionScale;

    id riValue = LGGlassPreferenceValue([prefix stringByAppendingString:@".RefractiveIndex"]);
    float refractiveIndex = [riValue respondsToSelector:@selector(doubleValue)] ? [riValue doubleValue] : hostDef->refractiveIndex;

    float bezelWidth = 34.0f;
    id bwValue = LGGlassPreferenceValue([prefix stringByAppendingString:@".BezelRatio"]);
    if ([bwValue respondsToSelector:@selector(doubleValue)]) {
        bezelWidth = MIN(width, height) * [bwValue doubleValue] / screenScale;
    }

    UIColor *legacyTint = LGLegacyTintColorForFilterType(effectiveType);
    CGFloat r, g, b, a;
    LGColorRGBA(legacyTint, &r, &g, &b, &a);

    LGIOS12LiveUniforms uniforms = {
        .outputResolution = { (float)width, (float)height },
        .sourceResolution = { (float)_backdropTexture.width, (float)_backdropTexture.height },
        .cardOrigin = { (float)(CGRectGetMinX(screenRect) * screenScale), (float)(CGRectGetMinY(screenRect) * screenScale) },
        .radius = (float)(self.layer.cornerRadius * screenScale),
        .bezelWidth = (float)(bezelWidth * screenScale),
        .glassThickness = glassThickness,
        .refractionScale = refractionScale,
        .refractiveIndex = refractiveIndex,
        .blurRadius = (float)(blurRadius * screenScale),
        .specularOpacity = LGSpecularEnabledForFilterType(effectiveType) ? 0.72f : 0.0f,
        .specularAngle = (float)sLGSpecularAngle,
        .tintColor = { (float)r, (float)g, (float)b, (float)a }
    };

    id<MTLCommandBuffer> commandBuffer = [sLGIOS12CommandQueue commandBuffer];
    if (!commandBuffer) return;

    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
    if (!compute) return;

    [compute setComputePipelineState:sLGIOS12ComputePipeline];
    [compute setTexture:_backdropTexture atIndex:0];
    [compute setTexture:_outputTexture atIndex:1];
    [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];

    MTLSize threads = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1);
    [compute dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [compute endEncoding];

    id<MTLRenderCommandEncoder> present = [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    if (!present) return;

    [present setRenderPipelineState:sLGIOS12PresentPipeline];
    [present setFragmentTexture:_outputTexture atIndex:0];
    [present drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [present endEncoding];

    uint64_t redraw = ++_ios12MetalRedrawCount;
    BOOL shouldLogRedraw = LGIOS12LiveShouldLogSequence(redraw);
    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (completed.status == MTLCommandBufferStatusCompleted && completed.error == nil) {
                if (!strongSelf->_hasRenderedFirstFrame) {
                    strongSelf->_hasRenderedFirstFrame = YES;
                    [strongSelf setNeedsLayout];
                    if (strongSelf.lgInjectedMaterial) {
                        LGUpdateMaterialReplacement(strongSelf.lgInjectedMaterial, strongSelf);
                    }
                }
            } else {
                LGLog(@"LGLiveBackdropView render failed: %@", completed.error.localizedDescription);
            }
            if (shouldLogRedraw) {
                LGDiagnosticLog(@"renderer.ios12.live Metal-redraw=%llu status=%ld completed=%d error=%@ firstFrameReady=%d",
                                (unsigned long long)redraw,
                                (long)completed.status,
                                completed.status == MTLCommandBufferStatusCompleted,
                                completed.error.localizedDescription ?: @"none",
                                strongSelf->_hasRenderedFirstFrame);
            }
        });
    }];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (shouldLogRedraw) {
        LGDiagnosticLog(@"renderer.ios12.live Metal-redraw=%llu encoded cardOrigin={%.0f,%.0f} output=%lux%lu",
                        (unsigned long long)redraw,
                        uniforms.cardOrigin.x, uniforms.cardOrigin.y,
                        (unsigned long)width, (unsigned long)height);
    }
}

@end

#pragma mark - generic host injection

static CGRect LGOutsetFrame(CGRect mf, UIEdgeInsets outset) {
    return CGRectMake(mf.origin.x - outset.left,
                      mf.origin.y - outset.top,
                      mf.size.width  + outset.left + outset.right,
                      mf.size.height + outset.top  + outset.bottom);
}

static void LGUpdateMaterialReplacement(UIView *material,
                                        LGLiveBackdropView *glass) {
    if (!material || !glass) return;
    BOOL rendererReady = glass.lgRendererReady;
    BOOL wasSuppressed = [objc_getAssociatedObject(
        material, kLGMaterialSuppressedKey) boolValue];

    if (rendererReady) {
        if (!wasSuppressed) {
            objc_setAssociatedObject(material, kLGMaterialOriginalHiddenKey,
                                     @(material.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(material, kLGMaterialOriginalAlphaKey,
                                     @(material.alpha),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(material, kLGMaterialSuppressedKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        glass.hidden = NO;
        material.hidden = YES;
    } else {
        // Keep the system material intact until the public iOS 12 backdrop is
        // demonstrably live.  This prevents a transparent/tint-only card.
        // Stay in the hierarchy so UIVisualEffectView can allocate and update
        // its private backdrop.  Tint/highlight layers remain hidden until the
        // readiness check succeeds, while the stock material stays visible.
        glass.hidden = NO;
        if (wasSuppressed) {
            NSNumber *originalHidden = objc_getAssociatedObject(
                material, kLGMaterialOriginalHiddenKey);
            NSNumber *originalAlpha = objc_getAssociatedObject(
                material, kLGMaterialOriginalAlphaKey);
            objc_setAssociatedObject(material, kLGMaterialSuppressedKey, @NO,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            material.hidden = originalHidden.boolValue;
            if (originalAlpha) material.alpha = originalAlpha.doubleValue;
        }
    }

    if (rendererReady != wasSuppressed) {
        CGFloat red, green, blue, alpha;
        LGColorRGBA(material.backgroundColor, &red, &green, &blue, &alpha);
        LGDiagnosticLog(@"renderer.material-handoff type=%@ ready=%d stockClass=%@ stockHidden=%d stockAlpha=%.3f stockBackgroundRGBA={%.3f,%.3f,%.3f,%.3f} glassHidden=%d glassAlpha=%.3f order=glass-above-stock",
                        glass.lgFilterType ?: @"default", rendererReady,
                        NSStringFromClass(material.class), material.hidden,
                        material.alpha, red, green, blue, alpha,
                        glass.hidden, glass.alpha);
    }
}

void LGInjectGlassIntoMaterialGroupType(UIView *mat, const void *assocKey,
                                        UIEdgeInsets outset, CGFloat cornerRadius,
                                        NSString *groupName, NSString *filterType) {
    UIView *parent = mat.superview;
    if (!parent) return;

    CGRect gf = LGOutsetFrame(mat.frame, outset);

    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) {
        glass = [[LGLiveBackdropView alloc] initWithFrame:gf groupName:groupName filterType:filterType];
        __weak LGLiveBackdropView *weakGlass = glass;
        __weak UIView *weakMaterial = mat;
        for (NSNumber *delay in @[ @1.5, @3.0, @5.0, @8.0, @12.0 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *strongMaterial = weakMaterial;
                if (!strongMaterial || objc_getAssociatedObject(strongMaterial, assocKey) != weakGlass)
                    return;
                LGResyncGlassGeometry(strongMaterial, assocKey);
            });
        }
        [parent insertSubview:glass aboveSubview:mat];
        objc_setAssociatedObject(mat, assocKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != parent) [parent insertSubview:glass aboveSubview:mat];
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;
    if (!CGRectEqualToRect(glass.frame, gf))          glass.frame              = gf;
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    glass.layer.cornerCurve   = kCACornerCurveContinuous;
    glass.layer.masksToBounds = YES;

    objc_setAssociatedObject(glass, kLGOutsetKey, [NSValue valueWithUIEdgeInsets:outset],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(glass, kLGRadiusKey, @(cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [glass applyFilters];
    glass.lgInjectedMaterial = mat;
    LGUpdateMaterialReplacement(mat, glass);
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius);

void LGResyncGlassGeometry(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    NSValue *ov  = objc_getAssociatedObject(glass, kLGOutsetKey);
    NSNumber *rv = objc_getAssociatedObject(glass, kLGRadiusKey);
    LGSyncGlassGeometry(mat, assocKey, ov ? ov.UIEdgeInsetsValue : UIEdgeInsetsZero,
                        rv ? rv.doubleValue : -1.0);
}

static void LGSyncGlassGeometry(UIView *mat, const void *assocKey,
                                UIEdgeInsets outset, CGFloat cornerRadius) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    CGRect gf = LGOutsetFrame(mat.frame, outset);
    CGFloat radius = (cornerRadius >= 0.0) ? cornerRadius : mat.layer.cornerRadius;

    if (!CGRectEqualToRect(glass.frame, gf)) {
        glass.frame = gf;
    }
    if (fabs(glass.layer.cornerRadius - radius) > 0.5) {
        glass.layer.cornerRadius = radius;
        [glass updateSpecular];
        [glass applyFilters];
    }
    [glass applyFilters];
    glass.lgInjectedMaterial = mat;
    LGUpdateMaterialReplacement(mat, glass);
}

void LGRemoveGlassFromMaterial(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return;
    objc_setAssociatedObject(mat, assocKey, nil, OBJC_ASSOCIATION_ASSIGN);
    NSNumber *originalHidden = objc_getAssociatedObject(
        mat, kLGMaterialOriginalHiddenKey);
    NSNumber *originalAlpha = objc_getAssociatedObject(
        mat, kLGMaterialOriginalAlphaKey);
    objc_setAssociatedObject(mat, kLGMaterialSuppressedKey, @NO,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    mat.hidden = originalHidden ? originalHidden.boolValue : NO;
    if (originalAlpha) mat.alpha = originalAlpha.doubleValue;
    objc_setAssociatedObject(mat, kLGMaterialOriginalHiddenKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(mat, kLGMaterialOriginalAlphaKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);

    [glass removeFromSuperview];
}

BOOL LGMaterialHasGlass(UIView *mat, const void *assocKey) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(mat, assocKey);
    if (!glass) return NO;
    if (!LGIsIOS12()) return YES;
    return [objc_getAssociatedObject(mat, kLGMaterialSuppressedKey) boolValue] &&
           glass.lgRendererReady;
}
