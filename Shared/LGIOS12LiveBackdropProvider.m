#import "LGIOS12LiveBackdropProvider.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import "LGSharedSupport.h"
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <float.h>

static void LGIOS12ProviderLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LGIOS12ProviderLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
#if LIQUIDASS_DEBUG
    LGLog(@"renderer.ios12.provider %@", message);
#else
    NSLog(@"[LiquidAss] renderer.ios12.provider %@", message);
#endif
}

// ---------------------------------------------------------------------------
// DIAGNOSTIC MODES
//
// Selected at runtime (no rebuild) by writing an integer to:
//   /var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist
//   key: DiagMode  (NSNumber integer)
// then respringing. Read once per SpringBoard launch and cached.
//
//   0 NORMAL           Liquid Glass shader, full composite capture (default)
//   1 RAW_BACKDROP     (A) raw source crop in the card, no glass shader
//   2 WALLPAPER_ONLY   (B) provider composes wallpaper only, raw display
//   3 FOREGROUND_ONLY  (C) provider composes foreground only, raw display
//   4 COMPOSITE_RAW    (D) full composite, raw display (equivalent to 1;
//                          kept as a separate id to match the test plan)
//   5 FREEZE_PROVIDER  (E) capture exactly ONE frame then stop capturing
//                          forever; Metal redraw + dragging stay live
//   6 PROVIDER_OFF     (F) standalone glass/provider never starts at all;
//                          every other LiquidAss hook untouched
//   7 FOREGROUND_SINGLE_ICON  diagnostic: render exactly ONE visible
//                          SBIconView at its screen position, bypassing all
//                          container selection. Isolates the bitmap/
//                          coordinate/render pipeline from selection logic.
//
// Modes 3 and 7 deliberately have NO whole-host fallback: a blank card is a
// real result meaning the foreground produced nothing, and they draw a
// magenta debug outline at the intended foreground screen rect.
// ---------------------------------------------------------------------------
NSInteger LGIOS12CurrentDiagMode(void) {
    static NSInteger mode = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = @"/var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist";
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        id value = dict[@"DiagMode"];
        if ([value respondsToSelector:@selector(integerValue)]) {
            mode = [value integerValue];
        }
        LGLog(@"renderer.ios12.provider DIAG-MODE selected=%ld source=%@",
              (long)mode, dict ? path : @"default(no-plist)");
    });
    return mode;
}

BOOL LGIOS12DiagRawDisplay(void) {
    NSInteger m = LGIOS12CurrentDiagMode();
    return (m >= 1 && m <= 4) || m == 7;
}

// Runtime performance toggle -- see the header. Read once per launch.
BOOL LGIOS12PerfLegacyPath(void) {
    static BOOL legacy = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist"];
        legacy = [dict[@"PerfLegacyPath"] boolValue];
        LGLog(@"renderer.ios12.provider PERF path=%@",
              legacy ? @"LEGACY(optimizations disabled)" : @"OPTIMIZED");
    });
    return legacy;
}

// mach_absolute_time -> milliseconds. The timebase is queried once; calling
// mach_timebase_info() per sample (as the old 60-capture report did) is itself
// measurable overhead at 30 Hz across a dozen stages.
static double LGIOS12MsFromTicks(uint64_t ticks) {
    static double scale = 0.0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        scale = (double)tb.numer / (double)tb.denom / 1000000.0;
    });
    return (double)ticks * scale;
}

static void LGIOS12StatAddMs(LGIOS12Stat *stat, double milliseconds) {
    if (!stat) return;
    stat->ema = (stat->ema <= 0.0) ? milliseconds
                                   : (stat->ema * 0.9 + milliseconds * 0.1);
    if (milliseconds > stat->worst) stat->worst = milliseconds;
}

static void LGIOS12StatAddTicks(LGIOS12Stat *stat, uint64_t ticks) {
    LGIOS12StatAddMs(stat, LGIOS12MsFromTicks(ticks));
}

static BOOL LGIOS12ProviderShouldLogSequence(uint64_t sequence) {
    return sequence <= 3 || (sequence % 30) == 0;
}

static BOOL LGIOS12IsStandaloneOverlayWindow(UIWindow *window) {
    if (!window) return NO;
    return [NSStringFromClass(window.class)
        isEqualToString:@"LGIOS12StandaloneOverlayWindow"];
}

static void LGIOS12ProviderRunOnMain(dispatch_block_t block) {
    if (!block) return;
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static BOOL LGIOS12ViewIsVisibleForCapture(UIView *view) {
    return view && !view.hidden && view.alpha > 0.01 &&
           !CGRectIsEmpty(view.bounds);
}

static BOOL LGIOS12ClassNameContainsToken(id object, NSString *token) {
    if (!object || !token.length) return NO;
    return [NSStringFromClass([object class])
        rangeOfString:token options:NSCaseInsensitiveSearch].location !=
        NSNotFound;
}

static BOOL LGIOS12HierarchyContainsClassToken(UIView *view,
                                               NSString *token,
                                               NSUInteger depth) {
    if (!view || depth == 0) return NO;
    if (LGIOS12ClassNameContainsToken(view, token)) return YES;
    for (UIView *subview in view.subviews) {
        if (LGIOS12HierarchyContainsClassToken(subview, token, depth - 1))
            return YES;
    }
    return NO;
}

static BOOL LGIOS12WindowIsWallpaperCandidate(UIWindow *window,
                                              UIWindow *hostWindow) {
    if (!window || window == hostWindow || window.hidden ||
        window.alpha <= 0.01 || LGIOS12IsStandaloneOverlayWindow(window) ||
        window.windowLevel > hostWindow.windowLevel) return NO;
    if (LGIOS12ClassNameContainsToken(window, @"Wallpaper") ||
        LGIOS12ClassNameContainsToken(window.rootViewController,
                                      @"Wallpaper")) return YES;
    return LGIOS12HierarchyContainsClassToken(
        window.rootViewController.view, @"Wallpaper", 4);
}

static BOOL LGIOS12ViewIsIconView(UIView *view) {
    if (!view) return NO;
    static Class iconViewClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        iconViewClass = NSClassFromString(@"SBIconView");
    });
    if (iconViewClass && [view isKindOfClass:iconViewClass]) return YES;
    return [NSStringFromClass(view.class) isEqualToString:@"SBIconView"];
}

static void LGIOS12CollectVisibleIconViews(UIView *view,
                                           NSMutableArray<UIView *> *icons) {
    if (!LGIOS12ViewIsVisibleForCapture(view)) return;
    if (LGIOS12ViewIsIconView(view)) [icons addObject:view];
    for (UIView *subview in view.subviews)
        LGIOS12CollectVisibleIconViews(subview, icons);
}

static BOOL LGIOS12ViewIsAncestorOfView(UIView *ancestor, UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if (cursor == ancestor) return YES;
    }
    return NO;
}

static UIView *LGIOS12LowestCommonAncestor(NSArray<UIView *> *views,
                                           UIView *limit) {
    UIView *candidate = views.firstObject;
    while (candidate && candidate != limit.superview) {
        BOOL containsAll = YES;
        for (UIView *view in views) {
            if (!LGIOS12ViewIsAncestorOfView(candidate, view)) {
                containsAll = NO;
                break;
            }
        }
        if (containsAll) return candidate;
        candidate = candidate.superview;
    }
    return nil;
}

static CGFloat LGIOS12ViewBackgroundAlpha(UIView *view) {
    CGColorRef color = view.layer.backgroundColor;
    if (!color && view.backgroundColor) color = view.backgroundColor.CGColor;
    return color ? CGColorGetAlpha(color) : 0.0;
}

static BOOL LGIOS12ViewHasTransparentBase(UIView *view) {
    return view && !view.opaque && LGIOS12ViewBackgroundAlpha(view) <= 0.01;
}

static BOOL LGIOS12ViewContainsVisibleIcon(UIView *view) {
    if (!LGIOS12ViewIsVisibleForCapture(view)) return NO;
    if (LGIOS12ViewIsIconView(view)) return YES;
    for (UIView *subview in view.subviews) {
        if (LGIOS12ViewContainsVisibleIcon(subview)) return YES;
    }
    return NO;
}

static void LGIOS12CollectTransparentIconBranches(
    UIView *view, NSMutableArray<UIView *> *branches, NSUInteger depth) {
    if (!view || depth == 0 || !LGIOS12ViewContainsVisibleIcon(view)) return;
    if (!LGIOS12ViewIsIconView(view) && LGIOS12ViewHasTransparentBase(view) &&
        !LGIOS12HierarchyContainsClassToken(view, @"Wallpaper", 4)) {
        [branches addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) {
        LGIOS12CollectTransparentIconBranches(subview, branches, depth - 1);
    }
}

static BOOL LGIOS12ViewIsInsideAnyView(UIView *view,
                                      NSArray<UIView *> *containers) {
    for (UIView *container in containers) {
        if (LGIOS12ViewIsAncestorOfView(container, view)) return YES;
    }
    return NO;
}

// Known-stable SpringBoard foreground container class name tokens, most
// preferred first. These are the containers that hold the icon pages (and
// survive a page scroll unchanged), as opposed to the per-page or per-icon
// views whose membership churns mid-transition. Matched by class-name token
// through guarded runtime inspection -- no hardcoded private struct layouts,
// no assumed availability. If none of these exist on a given iOS 12 build we
// fall through to the previous dynamic search, so this can only improve on
// the old behavior, never fail closed.
static NSArray<NSString *> *LGIOS12StableForegroundContainerTokens(void) {
    static NSArray<NSString *> *tokens = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[
            @"SBIconContentView",   // holds all icon list views + page control
            @"SBRootFolderView",    // root folder's view, parent of the above
            @"SBIconController",    // (view of) the icon controller
            @"SBHomeScreenView",
        ];
    });
    return tokens;
}

// Depth-first search for the highest-priority stable container that (a)
// exists, (b) is visible, (c) has a transparent base so the wallpaper we
// drew underneath still shows through, and (d) actually contains icons.
static UIView *LGIOS12FindStableForegroundContainer(UIView *root,
                                                     NSString *token,
                                                     NSUInteger depth) {
    if (!root || depth == 0 || !LGIOS12ViewIsVisibleForCapture(root)) return nil;
    if (LGIOS12ClassNameContainsToken(root, token) &&
        LGIOS12ViewHasTransparentBase(root) &&
        LGIOS12ViewContainsVisibleIcon(root) &&
        !LGIOS12HierarchyContainsClassToken(root, @"Wallpaper", 3)) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = LGIOS12FindStableForegroundContainer(subview, token, depth - 1);
        if (found) return found;
    }
    return nil;
}

static void LGIOS12CollectPageControls(UIView *view,
                                       NSArray<UIView *> *existing,
                                       NSMutableArray<UIView *> *results) {
    if (!LGIOS12ViewIsVisibleForCapture(view)) return;
    if (LGIOS12ClassNameContainsToken(view, @"PageControl") &&
        !LGIOS12ViewIsInsideAnyView(view, existing)) {
        [results addObject:view];
        return;
    }
    for (UIView *subview in view.subviews)
        LGIOS12CollectPageControls(subview, existing, results);
}

// Renders a foreground view into the capture context at its true screen
// position.
//
// PRESENTATION LAYER: reverted to the model layer by default. The previous
// build used `layer.presentationLayer ?: layer` on the hypothesis that it
// would capture in-flight animated positions. That was never verified on
// device, and there is real reason to doubt it: presentationLayer returns a
// copy whose sublayer/mask/scroll-offset fidelity under -renderInContext: is
// not guaranteed, so it could silently drop icon sublayers -- which would
// look exactly like the reported symptom. Until a device test proves it
// helps, the model layer (the long-standing behavior) is the default.
// Set DiagPresentationLayer=true in the diag plist to A/B it.
static BOOL LGIOS12UsePresentationLayer(void) {
    static BOOL use = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist"];
        use = [dict[@"DiagPresentationLayer"] boolValue];
        LGLog(@"renderer.ios12.provider DIAG presentationLayer=%@ (default NO)",
              use ? @"YES" : @"NO");
    });
    return use;
}

// Core pixel probe. Renders `layer` (restricted to `boundsInLayer`) into its
// own small offscreen bitmap and counts non-transparent pixels. This is the
// only way to answer "does -renderInContext: on this object actually produce
// pixels?" -- finding an object whose class name sounds right proves nothing,
// and renderInContext: returning void proves nothing either.
//
// Downsamples to at most 64px on the long edge so this is cheap enough to run
// during strategy resolution. Reports the fraction of pixels with alpha > 20
// and the peak luminance among them, so an all-black-but-opaque result is
// distinguishable from real content.
static void LGIOS12ProbeLayerRendersPixels(CALayer *layer,
                                            CGRect boundsInLayer,
                                            double *outCoverage,
                                            double *outPeakLuma) {
    if (outCoverage) *outCoverage = -1.0;
    if (outPeakLuma) *outPeakLuma = -1.0;
    if (!layer || CGRectIsEmpty(boundsInLayer)) return;

    CGFloat longEdge = MAX(boundsInLayer.size.width, boundsInLayer.size.height);
    if (longEdge <= 0) return;
    CGFloat probeScale = MIN(1.0, 64.0 / longEdge);
    size_t w = (size_t)MAX(1.0, floor(boundsInLayer.size.width * probeScale));
    size_t h = (size_t)MAX(1.0, floor(boundsInLayer.size.height * probeScale));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return;

    // Same top-left-origin (UIKit-style) CTM as the real capture context.
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, probeScale, -probeScale);
    CGContextTranslateCTM(ctx, -CGRectGetMinX(boundsInLayer),
                          -CGRectGetMinY(boundsInLayer));
    [layer renderInContext:ctx];

    uint8_t *bytes = (uint8_t *)CGBitmapContextGetData(ctx);
    if (bytes) {
        size_t opaqueCount = 0;
        double peak = 0.0;
        for (size_t i = 0; i < w * h; i++) {
            uint8_t a = bytes[i * 4 + 3];          // host-order BGRA -> A last
            if (a > 20) {
                opaqueCount++;
                double luma = (bytes[i * 4 + 2] * 0.299 +
                               bytes[i * 4 + 1] * 0.587 +
                               bytes[i * 4 + 0] * 0.114) / 255.0;
                if (luma > peak) peak = luma;
            }
        }
        if (outCoverage) *outCoverage = (double)opaqueCount / (double)(w * h);
        if (outPeakLuma) *outPeakLuma = peak;
    }
    CGContextRelease(ctx);
}

static void LGIOS12ProbeViewRendersPixels(UIView *view,
                                           double *outCoverage,
                                           double *outPeakLuma) {
    if (!view) {
        if (outCoverage) *outCoverage = -1.0;
        if (outPeakLuma) *outPeakLuma = -1.0;
        return;
    }
    LGIOS12ProbeLayerRendersPixels(view.layer, view.bounds,
                                   outCoverage, outPeakLuma);
}

// Rate-limited, depth-limited hierarchy dump. Branches that contain an
// SBIconView are marked so the real icon-bearing subtree is identifiable
// from the log instead of guessed from class names.
static void LGIOS12DumpHierarchy(UIView *view, NSUInteger depth,
                                  NSUInteger maxDepth,
                                  NSMutableArray<NSString *> *lines) {
    if (!view || depth > maxDepth || lines.count > 60) return;
    BOOL hasIcon = LGIOS12ViewContainsVisibleIcon(view);
    [lines addObject:[NSString stringWithFormat:
        @"%@%@%@ frame={%.0f,%.0f,%.0f,%.0f} hidden=%d alpha=%.2f opaque=%d subs=%lu",
        [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
        hasIcon ? @"*ICONS* " : @"",
        NSStringFromClass(view.class),
        view.frame.origin.x, view.frame.origin.y,
        view.frame.size.width, view.frame.size.height,
        view.hidden, view.alpha, view.opaque,
        (unsigned long)view.subviews.count]];
    // Only descend into branches that actually contain icons once past the
    // shallow levels -- keeps the dump usable instead of dumping all of
    // SpringBoard.
    for (UIView *sub in view.subviews) {
        if (depth >= 2 && !LGIOS12ViewContainsVisibleIcon(sub)) continue;
        LGIOS12DumpHierarchy(sub, depth + 1, maxDepth, lines);
    }
}

static BOOL LGIOS12RenderViewAtScreenPositionLogged(UIView *view,
                                                     CGContextRef context,
                                                     CGRect *outScreenRect);

// COORDINATE AUDIT after the capture-context CTM change.
//
// The restored CTM (translate(0,pixelHeight) + scale(scale,-scale)) makes
// this context behave exactly like the UIGraphics image context it replaced:
// top-left origin, y-down, addressed in POINTS. That is the coordinate space
// this helper has always assumed, and it is the space -[CALayer
// renderInContext:] expects, so the translate/scale below is unchanged and
// is NOT double-flipping. Verified structurally; the transformed rect is now
// logged so it can be confirmed on device rather than trusted.
static BOOL LGIOS12RenderViewAtScreenPositionLogged(UIView *view,
                                                     CGContextRef context,
                                                     CGRect *outScreenRect) {
    if (outScreenRect) *outScreenRect = CGRectNull;
    if (!LGIOS12ViewIsVisibleForCapture(view) || !context) return NO;
    CGRect screenRect = [view convertRect:view.bounds toView:nil];
    if (CGRectIsEmpty(screenRect) || CGRectIsEmpty(view.bounds)) return NO;
    if (outScreenRect) *outScreenRect = screenRect;
    CGFloat scaleX = CGRectGetWidth(screenRect) / CGRectGetWidth(view.bounds);
    CGFloat scaleY = CGRectGetHeight(screenRect) / CGRectGetHeight(view.bounds);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMinX(screenRect),
                          CGRectGetMinY(screenRect));
    CGContextScaleCTM(context, scaleX, scaleY);
    CGContextTranslateCTM(context, -CGRectGetMinX(view.bounds),
                          -CGRectGetMinY(view.bounds));
    CALayer *renderLayer = view.layer;
    if (LGIOS12UsePresentationLayer() && view.layer.presentationLayer) {
        renderLayer = view.layer.presentationLayer;
    }
    [renderLayer renderInContext:context];
    CGContextRestoreGState(context);
    return YES;
}

// ===========================================================================
// PER-ICON FOREGROUND CAPTURE ENGINE
//
// Replaces the stable-container snapshot as the PRIMARY foreground path.
//
// Why the container approach was abandoned: it is all-or-nothing. One
// container is selected, and if that container is opaque, wallpaper-adjacent,
// mis-selected, or simply yields nothing from -renderInContext:, the ENTIRE
// foreground vanishes -- which is the observed device symptom (correct
// wallpaper, zero icons). There is no partial result and no way for one bad
// predicate to fail softly.
//
// This engine instead enumerates the live visible SBIconView instances on
// every capture and renders each one individually at its own screen
// coordinates, resolving per icon how to get pixels out of it:
//
//   1  IconLayer        -[SBIconView.layer renderInContext:] works -> use it
//   2  DescendantViews  the icon layer is blank, but artwork-bearing
//                       descendant UIViews (image views, labels, badges,
//                       anything with layer.contents) render -> draw those
//   3  LayerContents    -renderInContext: produces nothing anywhere in the
//                       subtree, but CALayers in it carry a CGImage in
//                       .contents -> blit those images directly, bypassing
//                       renderInContext: entirely
//
// Strategy 3 is the important one: if iOS 12 SpringBoard icon artwork is
// composited by the render server rather than replayed by renderInContext:,
// the layer's backing image is still reachable through .contents, and drawing
// it is not a "cheap visual hack" -- it is the actual artwork, at its actual
// coordinates.
//
// Enumerating per capture (rather than caching a container) is also what
// makes the icons follow a Home Screen page scroll: every icon's screen rect
// is re-read from the live hierarchy each frame.
//
// Nothing here touches the wallpaper path, the capture-context CTM, the Metal
// presentation path, or the overlay-window isolation.
// ===========================================================================

// A candidate must cover at least this fraction of its own probe bitmap to
// count as "actually renders pixels". 0.5% of a 64px probe is a handful of
// pixels -- low enough to accept a thin glyph, high enough to reject the
// single-pixel noise a blank render can leave behind.
static const double kLGIOS12IconArtworkCoverageThreshold = 0.005;

// An icon is small. Anything covering more than this fraction of the screen
// found while descending an icon subtree is a page/container/wallpaper
// surface that must never be drawn -- this is the guard that keeps opaque
// page backgrounds out of the composite.
static const double kLGIOS12IconMaxScreenAreaFraction = 0.25;

typedef NS_ENUM(NSInteger, LGIOS12IconRenderStrategy) {
    LGIOS12IconRenderStrategyUnresolved = 0,
    LGIOS12IconRenderStrategyIconLayer,
    LGIOS12IconRenderStrategyDescendantViews,
    LGIOS12IconRenderStrategyLayerContents,
    LGIOS12IconRenderStrategyFailed,
};

static NSString *LGIOS12IconRenderStrategyName(LGIOS12IconRenderStrategy s) {
    switch (s) {
        case LGIOS12IconRenderStrategyIconLayer:       return @"ICON-LAYER";
        case LGIOS12IconRenderStrategyDescendantViews: return @"DESCENDANT-VIEWS";
        case LGIOS12IconRenderStrategyLayerContents:   return @"LAYER-CONTENTS";
        case LGIOS12IconRenderStrategyFailed:          return @"FAILED";
        case LGIOS12IconRenderStrategyUnresolved:      break;
    }
    return @"UNRESOLVED";
}

static BOOL LGIOS12LayerIsVisibleForCapture(CALayer *layer) {
    return layer && !layer.hidden && layer.opacity > 0.01 &&
           !CGRectIsEmpty(layer.bounds);
}

// Screen rect for an arbitrary CALayer, including layers with no UIView of
// their own. Walks up to the nearest UIView-backed ancestor layer, converts
// into that layer's space (which honours every intermediate layer transform),
// then uses UIKit's own view->window conversion for the last hop. No manual
// transform composition, and no assumption that the layer belongs to a view.
static BOOL LGIOS12LayerScreenRect(CALayer *layer, CGRect *outRect) {
    if (!layer || CGRectIsEmpty(layer.bounds)) return NO;
    UIView *ownerView = nil;
    for (CALayer *cursor = layer; cursor; cursor = cursor.superlayer) {
        id delegate = cursor.delegate;
        if ([delegate isKindOfClass:UIView.class]) {
            ownerView = (UIView *)delegate;
            break;
        }
    }
    if (!ownerView || !ownerView.window) return NO;
    CGRect inOwner = (layer == ownerView.layer)
        ? layer.bounds
        : [layer convertRect:layer.bounds toLayer:ownerView.layer];
    CGRect screenRect = [ownerView convertRect:inOwner toView:nil];
    if (CGRectIsEmpty(screenRect)) return NO;
    if (outRect) *outRect = screenRect;
    return YES;
}

static BOOL LGIOS12ScreenRectIsIconSized(CGRect screenRect) {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat screenArea = CGRectGetWidth(screen) * CGRectGetHeight(screen);
    if (screenArea <= 0) return YES;
    CGFloat area = CGRectGetWidth(screenRect) * CGRectGetHeight(screenRect);
    return (area / screenArea) <= kLGIOS12IconMaxScreenAreaFraction;
}

// Returns a +1 CGImage for a layer's .contents when it holds one, honouring
// contentsRect so an atlas-backed layer contributes only its own slice.
// Returns NULL for IOSurface-backed or otherwise non-CGImage contents, which
// this path cannot draw.
static CGImageRef LGIOS12CopyLayerContentsImage(CALayer *layer) CF_RETURNS_RETAINED {
    id contents = layer.contents;
    if (!contents) return NULL;
    CFTypeRef ref = (__bridge CFTypeRef)contents;
    if (CFGetTypeID(ref) != CGImageGetTypeID()) return NULL;
    CGImageRef image = (CGImageRef)ref;
    size_t pixelWidth = CGImageGetWidth(image);
    size_t pixelHeight = CGImageGetHeight(image);
    if (pixelWidth == 0 || pixelHeight == 0) return NULL;

    CGRect contentsRect = layer.contentsRect;
    if (CGRectIsEmpty(contentsRect) ||
        CGRectEqualToRect(contentsRect, CGRectMake(0, 0, 1, 1))) {
        return CGImageRetain(image);
    }
    CGRect cropPixels = CGRectMake(contentsRect.origin.x * pixelWidth,
                                   contentsRect.origin.y * pixelHeight,
                                   contentsRect.size.width * pixelWidth,
                                   contentsRect.size.height * pixelHeight);
    CGImageRef cropped = CGImageCreateWithImageInRect(image, cropPixels);
    return cropped ?: CGImageRetain(image);
}

static BOOL LGIOS12LayerHasDrawableContents(CALayer *layer) {
    id contents = layer.contents;
    if (!contents) return NO;
    return CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID();
}

// CTM NOTE -- the one place an extra flip is mathematically required.
//
// The capture context CTM is translate(0,pixelHeight)+scale(scale,-scale):
// top-left origin, y-down, addressed in points. -[CALayer renderInContext:]
// understands that space natively, which is why the existing render helper
// applies no flip and must keep applying none.
//
// CGContextDrawImage is different: it always maps the image bottom-up onto
// the destination rect in the *current* CTM, so in a y-down space it lands
// vertically mirrored. The local flip below cancels exactly that, is confined
// to a save/restore pair around a single draw, and never touches the shared
// context CTM. It is required for this call and for this call only.
static void LGIOS12DrawImageInScreenRect(CGContextRef context,
                                          CGImageRef image,
                                          CGRect screenRect) {
    if (!context || !image || CGRectIsEmpty(screenRect)) return;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMinX(screenRect),
                          CGRectGetMinY(screenRect));
    CGContextTranslateCTM(context, 0, CGRectGetHeight(screenRect));
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context,
                       CGRectMake(0, 0, CGRectGetWidth(screenRect),
                                  CGRectGetHeight(screenRect)),
                       image);
    CGContextRestoreGState(context);
}

// Does this view look like it carries icon artwork rather than being a plain
// grouping container? Structural tests first (a backing image, a known UIKit
// artwork class), class-name tokens only as a supplement -- per the rule that
// a matching class name proves nothing on its own, every candidate this
// returns YES for is still pixel-probed before it is trusted.
static BOOL LGIOS12ViewLooksLikeIconArtwork(UIView *view) {
    if (!view) return NO;
    if (view.layer.contents != nil) return YES;
    if ([view isKindOfClass:UIImageView.class]) return YES;
    if ([view isKindOfClass:UILabel.class]) return YES;
    static NSArray<NSString *> *tokens = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[ @"IconImageView", @"IconImage", @"ImageView", @"Label",
                    @"Badge", @"Accessory", @"Artwork" ];
    });
    for (NSString *token in tokens) {
        if (LGIOS12ClassNameContainsToken(view, token)) return YES;
    }
    return NO;
}

// Depth-first collection of artwork-bearing descendant views. Stops
// descending once a view is accepted, because -renderInContext: on it already
// replays its whole subtree -- descending further would draw the same pixels
// twice and double-darken any translucent artwork.
static void LGIOS12CollectIconArtworkViews(UIView *view, NSUInteger depth,
                                            NSMutableArray<UIView *> *out) {
    if (!LGIOS12ViewIsVisibleForCapture(view) || depth == 0) return;
    if (out.count >= 24) return;
    CGRect screenRect = [view convertRect:view.bounds toView:nil];
    if (!LGIOS12ScreenRectIsIconSized(screenRect)) return;
    if (LGIOS12ClassNameContainsToken(view, @"Wallpaper")) return;
    if (LGIOS12ViewLooksLikeIconArtwork(view)) {
        [out addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) {
        LGIOS12CollectIconArtworkViews(subview, depth - 1, out);
    }
}

// Depth-first collection of CALayers carrying a drawable CGImage. Walks the
// raw layer tree, so it finds layers that have no UIView of their own -- the
// case the view-based passes structurally cannot reach. Stops descending once
// a layer is accepted, for the same double-draw reason as above.
static void LGIOS12CollectIconContentLayers(CALayer *layer, NSUInteger depth,
                                             NSMutableArray<CALayer *> *out) {
    if (!LGIOS12LayerIsVisibleForCapture(layer) || depth == 0) return;
    if (out.count >= 24) return;
    CGRect screenRect = CGRectZero;
    if (!LGIOS12LayerScreenRect(layer, &screenRect)) return;
    if (!LGIOS12ScreenRectIsIconSized(screenRect)) return;
    if (LGIOS12LayerHasDrawableContents(layer)) {
        [out addObject:layer];
        return;
    }
    for (CALayer *sublayer in layer.sublayers) {
        LGIOS12CollectIconContentLayers(sublayer, depth - 1, out);
    }
}

// Decide how pixels can actually be obtained from one SBIconView, cheapest
// and most faithful method first. Every candidate is pixel-probed; nothing is
// accepted on the strength of its class name. `evidence` receives a
// human-readable record of exactly which object answered, for the report.
static LGIOS12IconRenderStrategy LGIOS12ResolveIconRenderStrategy(
        UIView *icon, NSMutableString *evidence) {
    if (!icon) return LGIOS12IconRenderStrategyFailed;

    double coverage = -1.0, peakLuma = -1.0;
    LGIOS12ProbeViewRendersPixels(icon, &coverage, &peakLuma);
    if (coverage >= kLGIOS12IconArtworkCoverageThreshold) {
        [evidence appendFormat:@"iconLayer(%@) coverage=%.3f peakLuma=%.3f",
            NSStringFromClass(icon.class), coverage, peakLuma];
        return LGIOS12IconRenderStrategyIconLayer;
    }
    [evidence appendFormat:@"iconLayer(%@) BLANK coverage=%.3f; ",
        NSStringFromClass(icon.class), coverage];

    NSMutableArray<UIView *> *artworkViews = [NSMutableArray array];
    LGIOS12CollectIconArtworkViews(icon, 8, artworkViews);
    for (UIView *candidate in artworkViews) {
        double c = -1.0, l = -1.0;
        LGIOS12ProbeViewRendersPixels(candidate, &c, &l);
        if (c >= kLGIOS12IconArtworkCoverageThreshold) {
            [evidence appendFormat:@"descendantView(%@) coverage=%.3f "
                "peakLuma=%.3f candidates=%lu",
                NSStringFromClass(candidate.class), c, l,
                (unsigned long)artworkViews.count];
            return LGIOS12IconRenderStrategyDescendantViews;
        }
    }
    [evidence appendFormat:@"descendantViews=%lu all-blank; ",
        (unsigned long)artworkViews.count];

    NSMutableArray<CALayer *> *contentLayers = [NSMutableArray array];
    LGIOS12CollectIconContentLayers(icon.layer, 10, contentLayers);
    if (contentLayers.count > 0) {
        CALayer *first = contentLayers.firstObject;
        CGImageRef image = LGIOS12CopyLayerContentsImage(first);
        [evidence appendFormat:@"layerContents(%@) layers=%lu "
            "firstImage=%zux%zu delegate=%@",
            NSStringFromClass(first.class),
            (unsigned long)contentLayers.count,
            image ? CGImageGetWidth(image) : 0,
            image ? CGImageGetHeight(image) : 0,
            first.delegate ? NSStringFromClass([first.delegate class]) : @"none"];
        if (image) CGImageRelease(image);
        return LGIOS12IconRenderStrategyLayerContents;
    }

    [evidence appendString:@"no-contents-layers-either"];
    return LGIOS12IconRenderStrategyFailed;
}

// Render ONE icon with an already-resolved strategy. Returns how many
// primitives were actually drawn (0 means this strategy did not work for this
// icon, and the caller re-resolves). Records the class of every object that
// supplied pixels so the report can name it exactly.
static NSUInteger LGIOS12RenderIconWithStrategy(
        UIView *icon,
        LGIOS12IconRenderStrategy strategy,
        CGContextRef context,
        NSMutableSet<NSString *> *contributors,
        CGRect *outIconScreenRect) {
    if (!icon || !context) return 0;
    CGRect iconScreenRect = [icon convertRect:icon.bounds toView:nil];
    if (outIconScreenRect) *outIconScreenRect = iconScreenRect;
    if (CGRectIsEmpty(iconScreenRect)) return 0;

    switch (strategy) {
        case LGIOS12IconRenderStrategyIconLayer: {
            CGRect drawn = CGRectNull;
            if (LGIOS12RenderViewAtScreenPositionLogged(icon, context, &drawn)) {
                [contributors addObject:[NSString stringWithFormat:@"%@.layer",
                    NSStringFromClass(icon.class)]];
                return 1;
            }
            return 0;
        }
        case LGIOS12IconRenderStrategyDescendantViews: {
            NSMutableArray<UIView *> *artworkViews = [NSMutableArray array];
            LGIOS12CollectIconArtworkViews(icon, 8, artworkViews);
            NSUInteger drawnCount = 0;
            for (UIView *candidate in artworkViews) {
                CGRect drawn = CGRectNull;
                if (LGIOS12RenderViewAtScreenPositionLogged(candidate, context,
                                                            &drawn)) {
                    [contributors addObject:[NSString stringWithFormat:@"%@.layer",
                        NSStringFromClass(candidate.class)]];
                    drawnCount++;
                }
            }
            return drawnCount;
        }
        case LGIOS12IconRenderStrategyLayerContents: {
            NSMutableArray<CALayer *> *contentLayers = [NSMutableArray array];
            LGIOS12CollectIconContentLayers(icon.layer, 10, contentLayers);
            NSUInteger drawnCount = 0;
            for (CALayer *layer in contentLayers) {
                CGRect layerScreenRect = CGRectZero;
                if (!LGIOS12LayerScreenRect(layer, &layerScreenRect)) continue;
                CGImageRef image = LGIOS12CopyLayerContentsImage(layer);
                if (!image) continue;
                LGIOS12DrawImageInScreenRect(context, image, layerScreenRect);
                CGImageRelease(image);
                [contributors addObject:[NSString stringWithFormat:@"%@.contents",
                    NSStringFromClass(layer.class)]];
                drawnCount++;
            }
            return drawnCount;
        }
        case LGIOS12IconRenderStrategyFailed:
        case LGIOS12IconRenderStrategyUnresolved:
            break;
    }
    return 0;
}

// Render one icon, preferring the globally resolved strategy but escalating
// if that strategy finds nothing structural for THIS icon.
//
// The escalation deliberately never falls back TO IconLayer. IconLayer is
// chosen only when the pixel probe proved the icon layer produces pixels;
// -renderInContext: itself reports nothing back, so "falling back" to it
// would always look like success while drawing a blank -- precisely the
// failure mode this engine exists to eliminate.
static NSUInteger LGIOS12RenderIconResilient(
        UIView *icon,
        LGIOS12IconRenderStrategy preferred,
        CGContextRef context,
        NSMutableSet<NSString *> *contributors,
        CGRect *outIconScreenRect,
        LGIOS12IconRenderStrategy *outUsedStrategy) {
    if (outUsedStrategy) *outUsedStrategy = LGIOS12IconRenderStrategyFailed;

    NSUInteger drawn = LGIOS12RenderIconWithStrategy(icon, preferred, context,
                                                     contributors,
                                                     outIconScreenRect);
    if (drawn > 0) {
        if (outUsedStrategy) *outUsedStrategy = preferred;
        return drawn;
    }

    const LGIOS12IconRenderStrategy escalation[2] = {
        LGIOS12IconRenderStrategyDescendantViews,
        LGIOS12IconRenderStrategyLayerContents,
    };
    for (int i = 0; i < 2; i++) {
        if (escalation[i] == preferred) continue;
        drawn = LGIOS12RenderIconWithStrategy(icon, escalation[i], context,
                                              contributors, outIconScreenRect);
        if (drawn > 0) {
            if (outUsedStrategy) *outUsedStrategy = escalation[i];
            return drawn;
        }
    }
    return 0;
}

typedef struct {
    NSUInteger iconsEnumerated;
    NSUInteger iconsDrawn;
    NSUInteger primitivesDrawn;
    LGIOS12IconRenderStrategy strategy;
    BOOL       strategyReResolved;
} LGIOS12ForegroundResult;


// DEVICE-EVIDENCE FIX (2026-09-01 video, ~10.2-11.5s):
//
// This previously called -drawViewHierarchyInRect:afterScreenUpdates:NO on
// LIVE SpringBoard windows at 24-30 Hz. That is UIKit's *snapshotting* API:
// unlike -renderInContext:, it is not a read-only draw -- it routes through
// UIKit's snapshot machinery, which interacts with the live render tree. On
// an actively animating hierarchy (a Home Screen page scroll) at that call
// rate it corrupts what is actually on screen: icon content blanks out and
// only container/mask geometry survives, which is exactly the grid of large
// rounded-rectangle outlines visible in the device video.
//
// The decisive evidence that this is real-screen corruption rather than a
// bad source texture: in the video the ghost rectangles cover the whole
// display, far outside the glass card's bounds. The provider source texture
// is only ever sampled *inside* the glass, so a source-texture artifact is
// structurally incapable of drawing outside it.
//
// -renderInContext: cannot cause this: it draws the layer tree into our own
// bitmap context and has no path back into the live render server. So the
// capture path now uses it exclusively.
static BOOL LGIOS12RenderWindowAtScreenPosition(UIWindow *window,
                                                 CGContextRef context,
                                                 CGRect screenBounds) {
    if (!window || !context || window.hidden || window.alpha <= 0.01 ||
        LGIOS12IsStandaloneOverlayWindow(window)) return NO;
    CGRect frame = CGRectIsEmpty(window.frame) ? screenBounds : window.frame;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMinX(frame), CGRectGetMinY(frame));
    [window.layer renderInContext:context];
    CGContextRestoreGState(context);
    return YES;
}

typedef struct {
    NSUInteger windowsRendered;
    NSUInteger excludedGlassCount;
    NSUInteger sameWindowExcludedCount;
    BOOL standaloneOverlayPresent;
    BOOL usedModelLayerExclusion;
} LGIOS12CaptureStats;

@implementation LGIOS12LiveBackdropProvider {
    id<MTLDevice> _device;
    MTKTextureLoader *_textureLoader;
    NSHashTable<id<LGIOS12LiveBackdropClient>> *_clients;
    NSHashTable<id<LGIOS12LiveBackdropClient>> *_activeClients;
    NSHashTable<UIView *> *_excludedGlassViews;

    CADisplayLink *_displayLink;
    BOOL _applicationInBackground;
    NSTimeInterval _lastRefreshTime;
    NSTimeInterval _targetRefreshInterval;

    BOOL _isCapturing;
    BOOL _refreshPending;
    BOOL _refreshDirty;

    UIImage *_cachedWallpaperImage;
    NSDate *_cachedWallpaperModificationDate;
    NSNumber *_cachedWallpaperFileSize;
    BOOL _wallpaperCacheAttemptedForMetadata;
    uint64_t _wallpaperCacheHitCount;
    NSString *_wallpaperCacheLastUnavailableReason;
    NSString *_cachedWallpaperDecoder;
    NSTimeInterval _lastWallpaperMetadataCheckTime;

    // Performance diagnostics
    uint64_t _totalCaptureTime;
    uint64_t _totalUploadTime;
    uint64_t _captureCount;
    uint64_t _captureTickCount;
    uint64_t _textureDeliveryCount;

    // --- Reusable CPU capture buffer. One persistent CGContext, reused
    // every capture instead of UIGraphicsBeginImageContextWithOptions's
    // per-frame alloc/free. CGBitmapContextCreateImage's copy-on-write
    // guarantee (Apple-documented) means a CGImageRef snapshot taken from
    // this context stays correct even if the main thread immediately
    // reuses the same buffer for the next capture -- so no manual
    // double-buffering is needed on the CPU side, only on the GPU/texture
    // side below, where Metal's replaceRegion: has no such protection.
    CGContextRef _captureContext;
    size_t       _captureBufferPixelWidth;
    size_t       _captureBufferPixelHeight;
    size_t       _captureBufferBytesPerRow;

    // --- Reusable, double-buffered Metal textures. Clients only ever see
    // _currentBackdropTexture, swapped to the freshly-written slot only
    // after replaceRegion: finishes, so nothing can read a texture
    // mid-write. ---
    id<MTLTexture> _textureSlots[2];
    NSUInteger      _publishedTextureSlotIndex;
    BOOL            _publishedTextureSlotValid;

    // --- Background upload pipeline. At most one job executing and one
    // pending; a newer pending job replaces (drops) an older one that
    // hasn't started yet -- newest-frame-wins, no unbounded queue. ---
    dispatch_queue_t _uploadQueue;
    BOOL              _uploadBusy;
    CGImageRef        _pendingUploadImage;      // +1, released on replace/consume
    NSString         *_pendingUploadSourceDesc;
    uint32_t          _pendingUploadSequence;
    uint64_t          _pendingUploadCaptureStartTicks;
    uint64_t          _pendingUploadHierarchyTicks;
    uint32_t          _captureSequence;
    uint32_t          _lastPublishedSequence;
    uint64_t          _droppedStaleCount;
    uint64_t          _droppedSupersededCount;

    // --- Extended timing / delivery-rate diagnostics (rolling, aggregated
    // every 60 deliveries -- never logged per-frame) ---
    NSTimeInterval _lastDeliveryWallClock;
    double    _rollingDeliveryIntervalSumMs;
    uint64_t  _rollingDeliveryIntervalCount;

    // Stable foreground container cache (PRIORITY 1). __weak so a torn-down
    // SpringBoard hierarchy simply re-resolves instead of dangling.
    __weak UIView *_cachedForegroundContainer;
    NSString *_lastForegroundDescription;
    uint64_t  _foregroundSourceChangeCount;
    BOOL      _freezeNoticeLogged;

    // --- Per-icon foreground engine state.
    //
    // The strategy is resolved from a live icon and then reused, because
    // resolution pixel-probes several candidates and is far too expensive to
    // repeat for every icon on every frame. It is re-resolved whenever it
    // stops producing pixels, and periodically regardless, so a hierarchy
    // change can never leave a stale strategy in place permanently.
    //
    // The icon SET is never cached: it is re-enumerated every capture, which
    // is what makes rendered icons follow a Home Screen page scroll.
    LGIOS12IconRenderStrategy _iconRenderStrategy;
    NSString *_iconStrategyEvidence;
    uint64_t  _iconStrategyResolvedAtTick;
    NSString *_lastIconContributorSummary;

    // Published to the on-screen probe (see the header).
    NSUInteger _lastForegroundIconsEnumerated;
    NSUInteger _lastForegroundIconsDrawn;
    NSUInteger _lastForegroundPrimitivesDrawn;
    NSString  *_lastForegroundPathName;

    // --- Pipeline instrumentation (see the header). Plain scalars: no
    // allocation, no locking, main-thread-written except textureUpload which
    // is written on the upload queue and read for display only.
    LGIOS12PerfSnapshot _perf;
    uint64_t _lastDisplayLinkTicks;
    uint64_t _lastPublishTicks;
    uint64_t _lastRedrawTicks;
    uint64_t _perfWindowResetCounter;
}

- (LGIOS12PerfSnapshot)performanceSnapshot {
    LGIOS12PerfSnapshot snapshot = _perf;
    snapshot.targetFPS = _targetRefreshInterval > 0 ? 1.0 / _targetRefreshInterval : 0.0;
    snapshot.iconsEnumerated = _lastForegroundIconsEnumerated;
    snapshot.iconsDrawn = _lastForegroundIconsDrawn;
    snapshot.primitivesDrawn = _lastForegroundPrimitivesDrawn;
    snapshot.droppedStale = _droppedStaleCount;
    snapshot.droppedSuperseded = _droppedSupersededCount;
    snapshot.captureBufferBytes =
        _captureBufferPixelHeight * _captureBufferBytesPerRow;
    snapshot.legacyPath = LGIOS12PerfLegacyPath();
    return snapshot;
}

- (void)noteClientRedraw {
    uint64_t now = mach_absolute_time();
    if (_lastRedrawTicks != 0) {
        double intervalMs = LGIOS12MsFromTicks(now - _lastRedrawTicks);
        LGIOS12StatAddMs(&_perf.metalRedrawInterval, intervalMs);
        if (_perf.metalRedrawInterval.ema > 0.0) {
            _perf.metalRedrawFPS = 1000.0 / _perf.metalRedrawInterval.ema;
        }
    }
    _lastRedrawTicks = now;
    if (_lastPublishTicks != 0) {
        LGIOS12StatAddMs(&_perf.textureAge,
                         LGIOS12MsFromTicks(now - _lastPublishTicks));
    }
}

- (NSUInteger)lastForegroundIconsEnumerated { return _lastForegroundIconsEnumerated; }
- (NSUInteger)lastForegroundIconsDrawn { return _lastForegroundIconsDrawn; }
- (NSUInteger)lastForegroundPrimitivesDrawn { return _lastForegroundPrimitivesDrawn; }
- (NSString *)lastForegroundPathName { return _lastForegroundPathName ?: @"(none yet)"; }

+ (instancetype)sharedProvider {
    static LGIOS12LiveBackdropProvider *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LGIOS12LiveBackdropProvider alloc] init];
    });
    return shared;
}

// This is a dispatch_once singleton in practice, so -dealloc never runs --
// included anyway for correctness rather than relying on that.
- (void)dealloc {
    if (_captureContext) CGContextRelease(_captureContext);
    if (_pendingUploadImage) CGImageRelease(_pendingUploadImage);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        if (_device) {
            _textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
        } else {
            LGIOS12ProviderLog(@"Failed to create Metal device");
        }

        _clients = [NSHashTable weakObjectsHashTable];
        _activeClients = [NSHashTable weakObjectsHashTable];
        _excludedGlassViews = [NSHashTable weakObjectsHashTable];

        _targetRefreshInterval = 1.0 / 24.0; // Start at 24 FPS
        _uploadQueue = dispatch_queue_create("dylv.liquidass.ios12.upload",
                                              DISPATCH_QUEUE_SERIAL);

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
    }
    return self;
}

- (NSUInteger)activeClientCount {
    return _activeClients.allObjects.count;
}

- (void)pruneWeakClientStateForReason:(NSString *)reason {
    // allObjects returns only live weak entries and compacts zeroed slots.
    // This lets delayed cleanup react to a vanished client without retaining
    // or dereferencing the object that was executing dealloc.
    (void)_clients.allObjects;
    (void)_activeClients.allObjects;
    (void)_excludedGlassViews.allObjects;
    [self updateRefreshLoopForReason:reason ?: @"weak-client-prune"];
}

- (void)updateRefreshLoopForReason:(NSString *)reason {
    NSUInteger activeCount = [self activeClientCount];
    NSUInteger registeredCount = _clients.allObjects.count;
    BOOL shouldRun = !_applicationInBackground && activeCount > 0 &&
                     registeredCount > 0;

    if (shouldRun && !_displayLink) {
        _displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(displayLinkFired:)];
        _displayLink.preferredFramesPerSecond = 30;
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop
                           forMode:NSRunLoopCommonModes];
        _lastRefreshTime = 0.0;
        LGIOS12ProviderLog(@"active-client loop=start reason=%@ active=%lu registered=%lu captureFPS=%.1f",
                           reason ?: @"unknown", (unsigned long)activeCount,
                           (unsigned long)registeredCount,
                           1.0 / _targetRefreshInterval);
        [self requestRefresh];
        _lastRefreshTime = CACurrentMediaTime();
    } else if (!shouldRun && _displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
        LGIOS12ProviderLog(@"active-client loop=stop reason=%@ active=%lu registered=%lu background=%d",
                           reason ?: @"unknown", (unsigned long)activeCount,
                           (unsigned long)registeredCount,
                           _applicationInBackground);
    }
}

- (void)registerClient:(id<LGIOS12LiveBackdropClient>)client {
    if (!client) return;
    LGIOS12ProviderRunOnMain(^{
        [self->_clients addObject:client];
        if (self->_currentBackdropTexture) {
            [client providerDidUpdateBackdropTexture:self->_currentBackdropTexture
                                              source:self->_currentSourceDescription];
        } else {
            [self requestRefresh];
        }
    });
}

- (void)unregisterClient:(id<LGIOS12LiveBackdropClient>)client {
    if (!client) return;
    void (^removeLiveClient)(id<LGIOS12LiveBackdropClient>) =
        ^(id<LGIOS12LiveBackdropClient> liveClient) {
        BOOL wasActive = [self->_activeClients containsObject:liveClient];
        [self->_activeClients removeObject:liveClient];
        [self->_clients removeObject:liveClient];
        if (wasActive) {
            LGIOS12ProviderLog(@"active-client event=unregister class=%@ active=%lu registered=%lu",
                               NSStringFromClass([liveClient class]),
                               (unsigned long)[self activeClientCount],
                               (unsigned long)self->_clients.allObjects.count);
        }
        [self updateRefreshLoopForReason:@"client-unregistered"];
    };
    if (NSThread.isMainThread) {
        removeLiveClient(client);
        return;
    }

    // A weak capture is essential here: unregister may be requested while a
    // client is tearing down.  If it dies before the main-queue block runs,
    // prune the provider's weak tables without touching a dangling pointer.
    __weak id<LGIOS12LiveBackdropClient> weakClient = client;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<LGIOS12LiveBackdropClient> liveClient = weakClient;
        if (liveClient) removeLiveClient(liveClient);
        else [self pruneWeakClientStateForReason:@"client-deallocated-before-unregister"];
    });
}

- (void)setClient:(id<LGIOS12LiveBackdropClient>)client
    requestsContinuousRefresh:(BOOL)active {
    if (!client) return;
    LGIOS12ProviderRunOnMain(^{
        BOOL wasActive = [self->_activeClients containsObject:client];
        if (active) {
            [self->_clients addObject:client];
            [self->_activeClients addObject:client];
        } else {
            [self->_activeClients removeObject:client];
        }
        if (wasActive != active) {
            UIView *view = [client isKindOfClass:UIView.class]
                ? (UIView *)client : nil;
            LGIOS12ProviderLog(@"active-client event=%@ class=%@ active=%lu registered=%lu window=%@ hidden=%d",
                               active ? @"start" : @"stop",
                               NSStringFromClass([client class]),
                               (unsigned long)[self activeClientCount],
                               (unsigned long)self->_clients.allObjects.count,
                               NSStringFromClass(view.window.class), view.hidden);
        }
        [self updateRefreshLoopForReason:active
            ? @"client-visible" : @"client-not-visible"];
    });
}

- (void)registerGlassViewForExclusion:(UIView *)glassView {
    if (!glassView) return;
    LGIOS12ProviderRunOnMain(^{
        [self->_excludedGlassViews addObject:glassView];
    });
}

- (void)unregisterGlassViewForExclusion:(UIView *)glassView {
    if (!glassView) return;
    if (NSThread.isMainThread) {
        [_excludedGlassViews removeObject:glassView];
        return;
    }
    __weak UIView *weakGlassView = glassView;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *liveGlassView = weakGlassView;
        if (liveGlassView) [self->_excludedGlassViews removeObject:liveGlassView];
        else [self pruneWeakClientStateForReason:@"excluded-view-deallocated-before-unregister"];
    });
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    _applicationInBackground = YES;
    [self updateRefreshLoopForReason:@"application-background"];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    (void)notification;
    _applicationInBackground = NO;
    [self updateRefreshLoopForReason:@"application-foreground"];
}

- (void)displayLinkFired:(CADisplayLink *)link {
    (void)link;
    if (_applicationInBackground || [self activeClientCount] == 0) {
        [self updateRefreshLoopForReason:@"display-link-no-active-clients"];
        return;
    }
    uint64_t nowTicks = mach_absolute_time();
    if (_lastDisplayLinkTicks != 0) {
        LGIOS12StatAddTicks(&_perf.displayLinkInterval,
                            nowTicks - _lastDisplayLinkTicks);
    }
    _lastDisplayLinkTicks = nowTicks;

    CFTimeInterval current = CACurrentMediaTime();
    if (current - _lastRefreshTime >= _targetRefreshInterval) {
        [self performCaptureAndUpload];
        _lastRefreshTime = current;
    }
}

- (void)requestRefresh {
    @synchronized (self) {
        _refreshDirty = YES;
        if (_refreshPending) return;
        _refreshPending = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL shouldCapture = NO;
        BOOL captureBusy = self->_isCapturing;
        @synchronized (self) {
            self->_refreshPending = NO;
            shouldCapture = self->_refreshDirty;
            if (shouldCapture && !captureBusy) self->_refreshDirty = NO;
        }
        if (!shouldCapture) return;
        if (captureBusy) {
            // Preserve a request made re-entrantly during texture delivery.
            // A single follow-up block will run after the synchronous capture.
            [self requestRefresh];
            return;
        }
        [self performCaptureAndUpload];
    });
}

- (void)performCaptureAndUpload {
    if (_isCapturing || !_device || _applicationInBackground) return;

    // MODE E (FREEZE_PROVIDER) / MODE F (PROVIDER_OFF): capture exactly one
    // frame, then never capture again. Metal redraw and glass dragging keep
    // running off the frozen texture. This is the decisive A/B: if the
    // whole-screen ghost rectangles still appear while swiping pages with
    // capture permanently stopped, repeated capture cannot be producing them.
    NSInteger diagMode = LGIOS12CurrentDiagMode();
    if (diagMode == 5 && _captureTickCount >= 1) {
        if (!_freezeNoticeLogged) {
            _freezeNoticeLogged = YES;
            LGIOS12ProviderLog(@"DIAG MODE 5 FREEZE_PROVIDER: one frame captured, "
                               "all further SpringBoard capture is now permanently "
                               "stopped. Metal redraw/dragging remain active.");
        }
        return;
    }

    _isCapturing = YES;
    uint64_t tick = ++_captureTickCount;
    uint32_t sequence = ++_captureSequence;

    uint64_t captureStart = mach_absolute_time();
    UIWindow *hostWindow = [self springBoardHostWindow];
    if (!hostWindow) {
        [self finishCaptureWithError:[NSError errorWithDomain:@"LGIOS12"
            code:1 userInfo:@{NSLocalizedDescriptionKey: @"No host window found"}]];
        return;
    }

    NSArray<UIView *> *excludedViews = _excludedGlassViews.allObjects;
    LGIOS12CaptureStats stats = { 0 };
    NSString *sourceDesc = nil;
    UIImage *snapshot = [self captureSpringBoardBackdrop:hostWindow
                                          excludingViews:excludedViews
                                                   stats:&stats
                                       sourceDescription:&sourceDesc];

    uint64_t captureEnd = mach_absolute_time();

    if (LGIOS12ProviderShouldLogSequence(tick)) {
        LGIOS12ProviderLog(@"capture tick=%llu sequence=%u hostWindow=%@ windowsRendered=%lu excludedGlass=%lu sameWindowExcluded=%lu standaloneSeparateOverlay=%d exclusionStrategy=%@ success=%d activeClients=%lu",
                           (unsigned long long)tick, sequence,
                           NSStringFromClass(hostWindow.class),
                           (unsigned long)stats.windowsRendered,
                           (unsigned long)stats.excludedGlassCount,
                           (unsigned long)stats.sameWindowExcludedCount,
                           stats.standaloneOverlayPresent,
                           stats.usedModelLayerExclusion
                               ? @"model-layer-render-no-commit"
                               : @"structural-window-separation",
                           snapshot != nil,
                           (unsigned long)[self activeClientCount]);
    }

    if (!snapshot) {
        [self finishCaptureWithError:[NSError errorWithDomain:@"LGIOS12"
            code:2 userInfo:@{NSLocalizedDescriptionKey: @"Capture failed"}]];
        return;
    }

    // Hand off to the background upload queue and release _isCapturing
    // *here*, not after the upload finishes -- this is the actual
    // throughput win: the display link's next tick can start capturing
    // the following frame while this one's Metal upload runs on
    // _uploadQueue. The CPU capture buffer is safe to reuse immediately
    // regardless (see captureSpringBoardBackdrop:'s copy-on-write note).
    CGImageRef cgImageRef = CGImageRetain(snapshot.CGImage);
    uint64_t hierarchyTicks = captureEnd - captureStart;
    _isCapturing = NO;

    BOOL startNow = NO;
    @synchronized (self) {
        if (_uploadBusy) {
            if (_pendingUploadImage) {
                _droppedSupersededCount++;
                CGImageRelease(_pendingUploadImage);
            }
            _pendingUploadImage = cgImageRef; // ownership transferred
            _pendingUploadSourceDesc = sourceDesc;
            _pendingUploadSequence = sequence;
            _pendingUploadCaptureStartTicks = captureStart;
            _pendingUploadHierarchyTicks = hierarchyTicks;
        } else {
            _uploadBusy = YES;
            startNow = YES;
        }
    }
    if (startNow) {
        [self dispatchUploadJobWithImage:cgImageRef
                               sourceDesc:sourceDesc
                                 sequence:sequence
                        captureStartTicks:captureStart
                           hierarchyTicks:hierarchyTicks];
    }
}

// Runs on _uploadQueue (background, serial). Extracts raw pixel bytes and
// writes them into whichever of the two reusable texture slots is NOT the
// currently-published one via replaceRegion: -- never a brand-new texture
// object, never the slot a client/GPU might currently be reading.
- (void)dispatchUploadJobWithImage:(CGImageRef)cgImageRef // +1, consumed here
                         sourceDesc:(NSString *)sourceDesc
                           sequence:(uint32_t)sequence
                  captureStartTicks:(uint64_t)captureStartTicks
                     hierarchyTicks:(uint64_t)hierarchyTicks {
    dispatch_async(_uploadQueue, ^{
        uint64_t uploadStart = mach_absolute_time();
        id<MTLTexture> texture = [self lgUploadTextureFromCGImage:cgImageRef];
        uint64_t uploadTicks = mach_absolute_time() - uploadStart;
        CGImageRelease(cgImageRef);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self completeUploadJobWithTexture:texture
                                     sourceDesc:sourceDesc
                                       sequence:sequence
                              captureStartTicks:captureStartTicks
                                 hierarchyTicks:hierarchyTicks
                                    uploadTicks:uploadTicks];
        });
    });
}

// Runs on _uploadQueue. Pure CPU/Metal work, no UIKit -- safe off-main.
- (id<MTLTexture>)lgUploadTextureFromCGImage:(CGImageRef)cgImageRef {
    if (!cgImageRef || !_device) return nil;
    size_t width = CGImageGetWidth(cgImageRef);
    size_t height = CGImageGetHeight(cgImageRef);
    if (width == 0 || height == 0) return nil;

    NSUInteger publishedSlot = NSUIntegerMax;
    @synchronized (self) {
        if (_publishedTextureSlotValid) publishedSlot = _publishedTextureSlotIndex;
    }
    NSUInteger targetSlot = (publishedSlot == 0) ? 1 : 0;

    id<MTLTexture> texture = _textureSlots[targetSlot];
    if (!texture || texture.width != width || texture.height != height) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                          width:width height:height mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        texture = [_device newTextureWithDescriptor:desc];
        _textureSlots[targetSlot] = texture;
        if (!texture) return nil;
        LGIOS12ProviderLog(@"texture-slot allocated slot=%lu pixels=%zux%zu",
                           (unsigned long)targetSlot, width, height);
    }

    // Our capture context is kCGImageAlphaPremultipliedFirst with host byte
    // order, i.e. BGRA on this (little-endian) hardware -- exactly what
    // MTLPixelFormatBGRA8Unorm expects, so this is a straight byte copy
    // with no channel reordering. CGDataProviderCopyData does allocate one
    // copy of the pixel buffer; a true zero-copy path would need a
    // self-owned capture buffer instead of letting CGBitmapContext own it,
    // which would give up the copy-on-write safety captureSpringBoardBackdrop:
    // relies on -- this is the deliberate tradeoff, documented rather than
    // silently accepted.
    CGDataProviderRef dataProvider = CGImageGetDataProvider(cgImageRef);
    CFDataRef data = dataProvider ? CGDataProviderCopyData(dataProvider) : NULL;
    if (!data) return nil;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    size_t bytesPerRow = CGImageGetBytesPerRow(cgImageRef);
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:bytes bytesPerRow:bytesPerRow];

    // ORIENTATION CHAIN, upload stage. Part B replaced MTKTextureLoader
    // (which honored MTKTextureLoaderOptionOrigin=TopLeft) with this raw
    // replaceRegion: path. replaceRegion: performs NO reorientation at all --
    // byte row 0 becomes texture row 0. A CGImage's bytes start at its top
    // row, so this is top-left origin and introduces no flip of its own. Any
    // vertical inversion therefore comes from the capture CTM upstream, not
    // from here. Logged once so this is verifiable on device rather than
    // assumed.
    static dispatch_once_t orientationOnce;
    dispatch_once(&orientationOnce, ^{
        LGIOS12ProviderLog(@"ORIENTATION upload path=replaceRegion(no-reorientation) "
                           "origin=top-left(byte-row-0=texture-row-0) "
                           "textureDims=%zux%zu bytesPerRow=%zu "
                           "note=MTKTextureLoaderOptionOrigin no longer applies",
                           width, height, bytesPerRow);
    });
    CFRelease(data);
    return texture;
}

// Runs on the main queue (dispatched from dispatchUploadJobWithImage:).
- (void)completeUploadJobWithTexture:(id<MTLTexture>)texture
                           sourceDesc:(NSString *)sourceDesc
                             sequence:(uint32_t)sequence
                    captureStartTicks:(uint64_t)captureStartTicks
                       hierarchyTicks:(uint64_t)hierarchyTicks
                          uploadTicks:(uint64_t)uploadTicks {
    if (sequence < _lastPublishedSequence) {
        // Shouldn't happen given the single-pending-slot coalescing in
        // performCaptureAndUpload (there is structurally at most one job
        // ahead of any other), but this is the explicit newest-wins
        // guarantee the doc asked for, kept as real insurance rather than
        // an assumption.
        _droppedStaleCount++;
        LGIOS12ProviderLog(@"upload dropped=stale sequence=%u lastPublished=%u",
                           sequence, _lastPublishedSequence);
    } else if (!texture) {
        [self finishCaptureWithError:[NSError errorWithDomain:@"LGIOS12" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Texture upload failed"}]];
    } else {
        @synchronized (self) {
            for (NSUInteger i = 0; i < 2; i++) {
                if (_textureSlots[i] == texture) {
                    _publishedTextureSlotIndex = i;
                    _publishedTextureSlotValid = YES;
                    break;
                }
            }
        }
        _lastPublishedSequence = sequence;
        _currentBackdropTexture = texture;
        _currentSourceDescription = sourceDesc;

        _captureCount++;
        _totalCaptureTime += hierarchyTicks;
        _totalUploadTime += uploadTicks;

        // Per-stage instrumentation. totalSourceFrame is wall time from the
        // start of capture to the moment the texture becomes visible to
        // clients -- the number that actually governs how stale the glass is.
        uint64_t publishTicks = mach_absolute_time();
        LGIOS12StatAddTicks(&_perf.textureUpload, uploadTicks);
        LGIOS12StatAddTicks(&_perf.totalSourceFrame, publishTicks - captureStartTicks);
        if (_lastPublishTicks != 0) {
            double deliveryIntervalMs =
                LGIOS12MsFromTicks(publishTicks - _lastPublishTicks);
            if (deliveryIntervalMs > 0.0) {
                _perf.deliveredBackdropFPS =
                    (_perf.deliveredBackdropFPS <= 0.0)
                        ? 1000.0 / deliveryIntervalMs
                        : _perf.deliveredBackdropFPS * 0.9 +
                          (1000.0 / deliveryIntervalMs) * 0.1;
            }
        }
        _lastPublishTicks = publishTicks;
        _perf.captureCount = _captureCount;

        // Worst-frame values are windowed: a stall stays visible for a while,
        // then clears, so the reading tracks current behaviour instead of
        // being pinned forever by one startup hitch.
        if (++_perfWindowResetCounter >= 120) {
            _perfWindowResetCounter = 0;
            _perf.displayLinkInterval.worst = 0.0;
            _perf.windowDiscovery.worst = 0.0;
            _perf.iconEnumeration.worst = 0.0;
            _perf.strategyLookup.worst = 0.0;
            _perf.iconComposition.worst = 0.0;
            _perf.wallpaperComposition.worst = 0.0;
            _perf.bitmapContext.worst = 0.0;
            _perf.imageCreation.worst = 0.0;
            _perf.textureUpload.worst = 0.0;
            _perf.totalSourceFrame.worst = 0.0;
            _perf.metalRedrawInterval.worst = 0.0;
            _perf.textureAge.worst = 0.0;
        }

        if (_captureCount % 60 == 0) {
            mach_timebase_info_data_t tb;
            mach_timebase_info(&tb);
            double captureMs = (double)(_totalCaptureTime / _captureCount) * tb.numer / tb.denom / 1000000.0;
            double uploadMs = (double)(_totalUploadTime / _captureCount) * tb.numer / tb.denom / 1000000.0;
            double deliveredFPS = _rollingDeliveryIntervalCount > 0
                ? 1000.0 / (_rollingDeliveryIntervalSumMs / _rollingDeliveryIntervalCount) : 0.0;
            LGIOS12ProviderLog(@"Performance avg (60 captures): hierarchyCapture=%.2fms upload=%.2fms "
                               "deliveredFPS(actual)=%.1f droppedStale=%llu droppedSuperseded=%llu",
                               captureMs, uploadMs, deliveredFPS,
                               (unsigned long long)_droppedStaleCount,
                               (unsigned long long)_droppedSupersededCount);

            // Adaptive throttling: explicit 30/24/20/15 tiers against the
            // ~33.3ms budget for 30 FPS, per the requested target model,
            // rather than a continuous multiplicative fudge.
            static const double kTierIntervals[] = {1.0/30.0, 1.0/24.0, 1.0/20.0, 1.0/15.0};
            double totalMs = captureMs + uploadMs;
            NSInteger currentTier = 0;
            double bestDelta = DBL_MAX;
            for (NSInteger i = 0; i < 4; i++) {
                double delta = fabs(_targetRefreshInterval - kTierIntervals[i]);
                if (delta < bestDelta) { bestDelta = delta; currentTier = i; }
            }
            if (totalMs > (1000.0 * kTierIntervals[currentTier]) && currentTier < 3) {
                _targetRefreshInterval = kTierIntervals[currentTier + 1];
                LGIOS12ProviderLog(@"Throttling refresh rate to %.1f FPS (measured %.2fms > %.2fms budget)",
                                   1.0 / _targetRefreshInterval, totalMs, 1000.0 * kTierIntervals[currentTier]);
            } else if (currentTier > 0 &&
                       totalMs < (1000.0 * kTierIntervals[currentTier - 1] * 0.85)) {
                _targetRefreshInterval = kTierIntervals[currentTier - 1];
                LGIOS12ProviderLog(@"Increasing refresh rate to %.1f FPS (measured %.2fms has headroom)",
                                   1.0 / _targetRefreshInterval, totalMs);
            }

            _totalCaptureTime = 0;
            _totalUploadTime = 0;
            _captureCount = 0;
            _rollingDeliveryIntervalSumMs = 0;
            _rollingDeliveryIntervalCount = 0;
        }

        NSTimeInterval now = CACurrentMediaTime();
        if (_lastDeliveryWallClock > 0.0) {
            _rollingDeliveryIntervalSumMs += (now - _lastDeliveryWallClock) * 1000.0;
            _rollingDeliveryIntervalCount++;
        }
        _lastDeliveryWallClock = now;

        NSArray<id<LGIOS12LiveBackdropClient>> *clients = _clients.allObjects;
        uint64_t delivery = ++_textureDeliveryCount;
        if (LGIOS12ProviderShouldLogSequence(delivery)) {
            LGIOS12ProviderLog(@"texture delivery=%llu sequence=%u source=%@ dimensions=%lux%lu "
                               "clients=%lu activeClients=%lu device=%@ textureSlot=%lu",
                               (unsigned long long)delivery, sequence,
                               sourceDesc ?: @"unknown",
                               (unsigned long)texture.width, (unsigned long)texture.height,
                               (unsigned long)clients.count,
                               (unsigned long)[self activeClientCount],
                               texture.device.name ?: @"unknown",
                               (unsigned long)_publishedTextureSlotIndex);
        }
        for (id<LGIOS12LiveBackdropClient> client in clients) {
            [client providerDidUpdateBackdropTexture:texture source:sourceDesc];
        }
    }

    // Drain a coalesced pending job (newest-wins queueing), or go idle.
    CGImageRef nextImage = NULL;
    NSString *nextSourceDesc = nil;
    uint32_t nextSequence = 0;
    uint64_t nextCaptureStart = 0, nextHierarchyTicks = 0;
    @synchronized (self) {
        if (_pendingUploadImage) {
            nextImage = _pendingUploadImage;
            nextSourceDesc = _pendingUploadSourceDesc;
            nextSequence = _pendingUploadSequence;
            nextCaptureStart = _pendingUploadCaptureStartTicks;
            nextHierarchyTicks = _pendingUploadHierarchyTicks;
            _pendingUploadImage = NULL;
            _pendingUploadSourceDesc = nil;
        } else {
            _uploadBusy = NO;
        }
    }
    if (nextImage) {
        [self dispatchUploadJobWithImage:nextImage
                               sourceDesc:nextSourceDesc
                                 sequence:nextSequence
                        captureStartTicks:nextCaptureStart
                           hierarchyTicks:nextHierarchyTicks];
    }
}

- (void)finishCaptureWithError:(NSError *)error {
    LGIOS12ProviderLog(@"Capture/upload failed: %@", error.localizedDescription);
    for (id<LGIOS12LiveBackdropClient> client in _clients.allObjects) {
        [client providerDidFailToUpdateBackdrop:error];
    }
    _isCapturing = NO;
}

- (UIWindow *)springBoardHostWindow {
    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIWindow *> *windows = [application.windows copy];
    UIWindow *fallback = nil;
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01 ||
            LGIOS12IsStandaloneOverlayWindow(window)) continue;
        NSString *className = NSStringFromClass(window.class);
        if ([className containsString:@"HomeScreenWindow"]) return window;
        if (!fallback && window.windowLevel == UIWindowLevelNormal)
            fallback = window;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *keyWindow = application.keyWindow;
#pragma clang diagnostic pop
    if (!fallback && !keyWindow.hidden && keyWindow.alpha > 0.01 &&
        !LGIOS12IsStandaloneOverlayWindow(keyWindow)) {
        fallback = keyWindow;
    }
    return fallback;
}

// Reusable, persistent bitmap context replacing per-call
// UIGraphicsBeginImageContextWithOptions/EndImageContext (which allocates
// and frees a full-screen backing buffer on every single capture -- real
// cost at 24-30 Hz). Only reallocated when the pixel size actually changes
// (rotation, screen change). CGBitmapContextCreateImage's documented
// copy-on-write behavior means a CGImageRef snapshot taken from this
// context stays correct even after we immediately reuse it for the next
// capture, so this is safe without any additional locking.
- (CGContextRef)ensureCaptureContextForPointSize:(CGSize)pointSize
                                            scale:(CGFloat)scale {
    size_t pixelWidth = (size_t)llround(pointSize.width * scale);
    size_t pixelHeight = (size_t)llround(pointSize.height * scale);
    if (pixelWidth == 0 || pixelHeight == 0) return NULL;

    if (_captureContext && pixelWidth == _captureBufferPixelWidth &&
        pixelHeight == _captureBufferPixelHeight) {
        return _captureContext;
    }

    if (_captureContext) {
        CGContextRelease(_captureContext);
        _captureContext = NULL;
    }

    size_t bytesPerRow = pixelWidth * 4;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    // NULL data: CGBitmapContextCreate allocates and owns the backing
    // store itself, which is exactly what we want to reuse across calls --
    // no manual malloc/free bookkeeping on our end either.
    _captureContext = CGBitmapContextCreate(
        NULL, pixelWidth, pixelHeight, 8, bytesPerRow, colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(colorSpace);

    if (_captureContext) {
        // ORIENTATION FIX (regression introduced by me in 7bf02a7, Part B).
        //
        // Part B replaced UIGraphicsBeginImageContextWithOptions with this
        // hand-rolled CGBitmapContext to avoid a per-frame alloc. But
        // UIGraphicsBeginImageContextWithOptions does not just allocate --
        // it also installs a flip CTM (translate(0,height) + scale(1,-1)),
        // because CoreGraphics bitmap contexts have their origin at the
        // BOTTOM-left while UIKit/CALayer drawing assumes TOP-left. The Part B
        // replacement applied only the scale and omitted that flip, so every
        // UIKit/-renderInContext: draw since then has gone in vertically
        // mirrored. That is the reported upside-down wallpaper, and it enters
        // the pipeline here -- at composition, before upload and before any
        // shader. Restoring the flip makes this context behave exactly like
        // the UIGraphics one it replaced.
        CGContextTranslateCTM(_captureContext, 0, pixelHeight);
        CGContextScaleCTM(_captureContext, scale, -scale);
        _captureBufferPixelWidth = pixelWidth;
        _captureBufferPixelHeight = pixelHeight;
        _captureBufferBytesPerRow = bytesPerRow;
        LGIOS12ProviderLog(@"capture-buffer allocated pixels=%zux%zu scale=%.1f "
                           "ctm=top-left-origin(flipped)", pixelWidth, pixelHeight, scale);
    } else {
        LGIOS12ProviderLog(@"capture-buffer allocation FAILED pixels=%zux%zu", pixelWidth, pixelHeight);
        _captureBufferPixelWidth = 0;
        _captureBufferPixelHeight = 0;
    }
    return _captureContext;
}

- (NSArray<UIWindow *> *)visibleSourceWindowsSortedByLevel {
    NSMutableArray<UIWindow *> *visible = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window || window.hidden || window.alpha <= 0.01 ||
            LGIOS12IsStandaloneOverlayWindow(window)) continue;
        [visible addObject:window];
    }
    return [visible sortedArrayUsingComparator:^NSComparisonResult(
        UIWindow *left, UIWindow *right) {
        if (left.windowLevel < right.windowLevel) return NSOrderedAscending;
        if (left.windowLevel > right.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (void)logWindowStack:(NSArray<UIWindow *> *)windows
             hostWindow:(UIWindow *)hostWindow {
    if (!LGIOS12ProviderShouldLogSequence(_captureTickCount)) return;
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (UIWindow *window in windows) {
        [entries addObject:[NSString stringWithFormat:
            @"%@{level=%.1f root=%@ opaque=%d alpha=%.2f key=%d}",
            NSStringFromClass(window.class), window.windowLevel,
            NSStringFromClass(window.rootViewController.class), window.opaque,
            window.alpha, window.isKeyWindow]];
    }
    LGIOS12ProviderLog(@"window stack visible=%lu selectedHost=%@ hostLevel=%.1f hostOpaque=%d hostRoot=%@ hostRootOpaque=%d excludedOverlay=LGIOS12StandaloneOverlayWindow entries=[%@]",
                       (unsigned long)windows.count,
                       NSStringFromClass(hostWindow.class),
                       hostWindow.windowLevel, hostWindow.opaque,
                       NSStringFromClass(hostWindow.rootViewController.class),
                       hostWindow.rootViewController.view.opaque,
                       [entries componentsJoinedByString:@", "]);
}

- (UIWindow *)wallpaperWindowBelowHostWindow:(UIWindow *)hostWindow
                              visibleWindows:(NSArray<UIWindow *> *)windows {
    UIWindow *candidate = nil;
    for (UIWindow *window in windows) {
        if (!LGIOS12WindowIsWallpaperCandidate(window, hostWindow)) continue;
        if (!candidate || window.windowLevel >= candidate.windowLevel)
            candidate = window;
    }
    return candidate;
}

- (NSArray<UIView *> *)foregroundViewsForHostWindow:(UIWindow *)hostWindow
                                         description:(NSString **)description {
    UIView *root = hostWindow.rootViewController.view ?: hostWindow;

    // PRIORITY 1 FIX: prefer one stable container over per-frame rederivation.
    //
    // The old path rebuilt the foreground set every single capture from
    // whatever SBIconViews happened to be visible, then walked up to their
    // lowest common ancestor. During a page scroll the visible icon set
    // changes between captures (page A leaving, page B entering), so the LCA
    // jumps between a single page's list view and the multi-page container --
    // and when it landed on something opaque or wallpaper-adjacent, the whole
    // foreground was dropped and the capture fell through to the whole-host
    // fallback. That fallback is what corrupted the live screen (see the
    // comment on LGIOS12RenderWindowAtScreenPosition).
    //
    // A cached stable container is immune to that churn: page scrolling moves
    // content *within* it, so it stays valid across the entire transition and
    // the foreground source never changes mid-scroll.
    if (_cachedForegroundContainer && _cachedForegroundContainer.window == hostWindow &&
        LGIOS12ViewIsVisibleForCapture(_cachedForegroundContainer) &&
        LGIOS12ViewContainsVisibleIcon(_cachedForegroundContainer)) {
        if (description) {
            *description = [NSString stringWithFormat:@"stable-container(cached):%@",
                NSStringFromClass(_cachedForegroundContainer.class)];
        }
        return @[_cachedForegroundContainer];
    }

    for (NSString *token in LGIOS12StableForegroundContainerTokens()) {
        UIView *container = LGIOS12FindStableForegroundContainer(root, token, 14);
        if (container) {
            _cachedForegroundContainer = container;
            // Full runtime identity of the object actually selected -- not an
            // assumption that the token matched something useful. If this
            // never appears in the device log, NO stable container was found
            // and the dynamic fallback below is what actually ran.
            NSMutableArray<NSString *> *superChain = [NSMutableArray array];
            UIView *walk = container.superview;
            for (NSUInteger i = 0; i < 6 && walk; i++) {
                [superChain addObject:NSStringFromClass(walk.class)];
                walk = walk.superview;
            }
            LGIOS12ProviderLog(@"foreground STABLE-CONTAINER-SELECTED token=%@ class=%@ "
                               "ptr=%p superclass=%@ isUIView=%d frame={%.0f,%.0f,%.0f,%.0f} "
                               "bounds={%.0f,%.0f} window=%@ opaque=%d backgroundAlpha=%.3f "
                               "subviews=%lu superChain=[%@]",
                               token, NSStringFromClass(container.class), container,
                               NSStringFromClass(container.superclass),
                               [container isKindOfClass:UIView.class],
                               container.frame.origin.x, container.frame.origin.y,
                               container.frame.size.width, container.frame.size.height,
                               container.bounds.size.width, container.bounds.size.height,
                               NSStringFromClass(container.window.class) ?: @"none",
                               container.opaque,
                               LGIOS12ViewBackgroundAlpha(container),
                               (unsigned long)container.subviews.count,
                               [superChain componentsJoinedByString:@"<-"]);
            if (description) {
                *description = [NSString stringWithFormat:@"stable-container:%@",
                    NSStringFromClass(container.class)];
            }
            return @[container];
        }
    }

    // Fallback: previous dynamic behavior, unchanged. Only reached if none of
    // the stable container classes exist on this build.
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    LGIOS12CollectVisibleIconViews(root, icons);
    if (!icons.count) {
        if (description) *description = @"none:no-visible-SBIconView";
        return @[];
    }

    UIView *common = LGIOS12LowestCommonAncestor(icons, root);
    NSMutableArray<UIView *> *foreground = [NSMutableArray array];
    BOOL commonIsUsable = common && common != hostWindow &&
        LGIOS12ViewHasTransparentBase(common) &&
        !LGIOS12HierarchyContainsClassToken(common, @"Wallpaper", 4);
    if (commonIsUsable) {
        [foreground addObject:common];
    } else if (common) {
        LGIOS12CollectTransparentIconBranches(common, foreground, 12);
        NSMutableArray<UIView *> *pageControls = [NSMutableArray array];
        LGIOS12CollectPageControls(root, foreground, pageControls);
        [foreground addObjectsFromArray:pageControls];
    }

    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    for (UIView *view in foreground)
        [classes addObject:NSStringFromClass(view.class)];
    if (description) {
        *description = [NSString stringWithFormat:
            @"dynamic-fallback icons=%lu common=%@ commonOpaque=%d commonBackgroundAlpha=%.3f sources=[%@]",
            (unsigned long)icons.count, NSStringFromClass(common.class),
            common.opaque, LGIOS12ViewBackgroundAlpha(common),
            [classes componentsJoinedByString:@","]];
    }
    return foreground;
}

static NSString *LGIOS12HomeWallpaperPathProvider(void) {
    return @"/var/mobile/Library/SpringBoard/HomeBackground.cpbitmap";
}

typedef CFArrayRef (*LGIOS12CPBitmapCreateImagesFromDataFn)(
    CFDataRef data, void *unused, int flags, void *unused2);

static LGIOS12CPBitmapCreateImagesFromDataFn
LGIOS12ResolveSystemCPBitmapDecoder(void) {
    static LGIOS12CPBitmapCreateImagesFromDataFn decoder = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport",
            RTLD_LAZY | RTLD_LOCAL);
        if (handle) {
            decoder = (LGIOS12CPBitmapCreateImagesFromDataFn)dlsym(
                handle, "CPBitmapCreateImagesFromData");
        }
    });
    return decoder;
}

static UIImage *LGIOS12DecodeCPBitmapWithSystemDecoder(NSData *data) {
    LGIOS12CPBitmapCreateImagesFromDataFn decoder =
        LGIOS12ResolveSystemCPBitmapDecoder();
    if (!decoder || !data.length) return nil;
    CFArrayRef images = decoder((__bridge CFDataRef)data, NULL, 1, NULL);
    if (!images) return nil;
    UIImage *image = nil;
    if (CFArrayGetCount(images) > 0) {
        CFTypeRef first = CFArrayGetValueAtIndex(images, 0);
        if (first && CFGetTypeID(first) == CGImageGetTypeID()) {
            image = [UIImage imageWithCGImage:(CGImageRef)first
                                        scale:(UIScreen.mainScreen.scale ?: 1.0)
                                  orientation:UIImageOrientationUp];
        }
    }
    CFRelease(images);
    return image;
}

// Raw-layout fallback for wallpaper tools/builds whose AppSupport decoder is
// unavailable.  The iOS 12 system decoder above is the authoritative path.
- (UIImage *)decodeCPBitmapManually:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![data isKindOfClass:NSData.class] || data.length < 24) return nil;

    const uint8_t *bytes = data.bytes;
    const NSUInteger length = data.length;
    static const size_t trailerCandidates[] = { 20, 24, 28, 32 };
    static const size_t alignmentCandidates[] = { 16, 8, 4 };
    size_t width = 0, height = 0, linePixels = 0;

    for (size_t ti = 0; ti < sizeof(trailerCandidates) / sizeof(trailerCandidates[0]); ti++) {
        size_t trailer = trailerCandidates[ti];
        if (length <= trailer) continue;
        uint32_t widthLE = 0, heightLE = 0;
        memcpy(&widthLE, bytes + length - trailer, sizeof(widthLE));
        memcpy(&heightLE, bytes + length - trailer + sizeof(widthLE),
               sizeof(heightLE));
        size_t candidateWidth = CFSwapInt32LittleToHost(widthLE);
        size_t candidateHeight = CFSwapInt32LittleToHost(heightLE);
        if (!candidateWidth || !candidateHeight ||
            candidateWidth > 10000 || candidateHeight > 10000) continue;

        for (size_t ai = 0; ai < sizeof(alignmentCandidates) / sizeof(alignmentCandidates[0]); ai++) {
            size_t alignment = alignmentCandidates[ai];
            size_t candidateLinePixels =
                ((candidateWidth + alignment - 1) / alignment) * alignment;
            size_t required = candidateLinePixels * candidateHeight * 4;
            if (required <= length - trailer) {
                width = candidateWidth;
                height = candidateHeight;
                linePixels = candidateLinePixels;
                break;
            }
        }
        if (width && height) break;
    }
    if (!width || !height || !linePixels) {
        return nil;
    }

    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *destination = rgba.mutableBytes;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *sourceRow = bytes + y * linePixels * 4;
        uint8_t *destinationRow = destination + y * width * 4;
        for (size_t x = 0; x < width; x++) {
            const uint8_t *sourcePixel = sourceRow + x * 4;
            uint8_t *destinationPixel = destinationRow + x * 4;
            destinationPixel[0] = sourcePixel[2];
            destinationPixel[1] = sourcePixel[1];
            destinationPixel[2] = sourcePixel[0];
            destinationPixel[3] = sourcePixel[3];
        }
    }

    CGDataProviderRef provider =
        CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    if (!provider) return nil;
    CGImageRef imageRef = CGImageCreate(width, height, 8, 32, width * 4,
                                        LGSharedRGBColorSpace(),
                                        kCGBitmapByteOrderDefault |
                                            kCGImageAlphaLast,
                                        provider, NULL, NO,
                                        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!imageRef) return nil;
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;
    UIImage *image = [UIImage imageWithCGImage:imageRef
                                         scale:screenScale
                                   orientation:UIImageOrientationUp];
    CGImageRelease(imageRef);
    return image;
}

- (UIImage *)decodeCPBitmap:(NSString *)path
                decoderName:(NSString **)decoderName {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![data isKindOfClass:NSData.class] || data.length < 24) {
        if (decoderName) *decoderName = @"unreadable-or-empty";
        return nil;
    }

    UIImage *image = LGIOS12DecodeCPBitmapWithSystemDecoder(data);
    if (image) {
        if (decoderName)
            *decoderName = @"AppSupport.CPBitmapCreateImagesFromData";
        return image;
    }

    image = [self decodeCPBitmapManually:path];
    if (decoderName) {
        *decoderName = image ? @"manual-raw-layout-fallback"
                             : @"all-decoders-failed";
    }
    return image;
}

- (UIImage *)cachedDecodedWallpaperAtPath:(NSString *)path {
    // Throttle the stat() itself, not just the decode: at 24-30 capture/sec
    // this was checking file metadata on every single frame. The wallpaper
    // changing mid-second is not a real scenario worth paying for -- only
    // actually check metadata at most once per second, reusing whatever we
    // last had in between.
    NSTimeInterval now = CACurrentMediaTime();
    if (_wallpaperCacheAttemptedForMetadata &&
        (now - _lastWallpaperMetadataCheckTime) < 1.0) {
        uint64_t hit = ++_wallpaperCacheHitCount;
        if (LGIOS12ProviderShouldLogSequence(hit)) {
            LGIOS12ProviderLog(@"wallpaper cache=hit(throttled-stat) count=%llu decoded=%d "
                               "secondsSinceLastStat=%.2f",
                               (unsigned long long)hit, _cachedWallpaperImage != nil,
                               now - _lastWallpaperMetadataCheckTime);
        }
        return _cachedWallpaperImage;
    }
    _lastWallpaperMetadataCheckTime = now;

    NSError *attributesError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                         error:&attributesError];
    NSDate *modificationDate = attributes[NSFileModificationDate];
    NSNumber *fileSize = attributes[NSFileSize];
    if (!modificationDate || !fileSize) {
        NSString *reason = attributesError
            ? [NSString stringWithFormat:@"metadata-unavailable:%ld",
                (long)attributesError.code]
            : @"metadata-incomplete";
        if (_wallpaperCacheAttemptedForMetadata || _cachedWallpaperImage) {
            LGIOS12ProviderLog(@"wallpaper cache=invalidate reason=%@ previousModified=%@ previousSize=%@",
                               reason,
                               _cachedWallpaperModificationDate ?: @"none",
                               _cachedWallpaperFileSize ?: @"none");
        }
        _cachedWallpaperImage = nil;
        _cachedWallpaperModificationDate = nil;
        _cachedWallpaperFileSize = nil;
        _cachedWallpaperDecoder = nil;
        _wallpaperCacheAttemptedForMetadata = NO;
        if (![_wallpaperCacheLastUnavailableReason isEqualToString:reason]) {
            _wallpaperCacheLastUnavailableReason = reason;
            LGIOS12ProviderLog(@"wallpaper cpbitmap readable=0 decodeSuccess=0 reason=%@ path=%@ fallback=wallpaper-window-or-black",
                               reason, path);
        }
        return nil;
    }

    _wallpaperCacheLastUnavailableReason = nil;
    BOOL metadataMatches = _wallpaperCacheAttemptedForMetadata &&
        [_cachedWallpaperModificationDate isEqualToDate:modificationDate] &&
        [_cachedWallpaperFileSize isEqualToNumber:fileSize];
    if (metadataMatches) {
        uint64_t hit = ++_wallpaperCacheHitCount;
        if (LGIOS12ProviderShouldLogSequence(hit)) {
            size_t pixelWidth = _cachedWallpaperImage.CGImage
                ? CGImageGetWidth(_cachedWallpaperImage.CGImage) : 0;
            size_t pixelHeight = _cachedWallpaperImage.CGImage
                ? CGImageGetHeight(_cachedWallpaperImage.CGImage) : 0;
            LGIOS12ProviderLog(@"wallpaper cache=hit count=%llu readable=1 decoded=%d decoder=%@ pixels=%lux%lu modified=%@ size=%@",
                               (unsigned long long)hit,
                               _cachedWallpaperImage != nil,
                               _cachedWallpaperDecoder ?: @"none",
                               (unsigned long)pixelWidth,
                               (unsigned long)pixelHeight,
                               modificationDate, fileSize);
        }
        return _cachedWallpaperImage;
    }

    NSString *reason = @"cold-cache";
    if (_wallpaperCacheAttemptedForMetadata) {
        if (![_cachedWallpaperModificationDate isEqualToDate:modificationDate])
            reason = @"file-modification-date-changed";
        else if (![_cachedWallpaperFileSize isEqualToNumber:fileSize])
            reason = @"file-size-changed";
        else
            reason = @"metadata-changed";
        LGIOS12ProviderLog(@"wallpaper cache=invalidate reason=%@ previousModified=%@ currentModified=%@ previousSize=%@ currentSize=%@",
                           reason,
                           _cachedWallpaperModificationDate ?: @"none",
                           modificationDate,
                           _cachedWallpaperFileSize ?: @"none",
                           fileSize);
    }

    NSString *decoderName = nil;
    UIImage *decoded = [self decodeCPBitmap:path decoderName:&decoderName];
    _cachedWallpaperImage = decoded;
    _cachedWallpaperDecoder = decoderName;
    _cachedWallpaperModificationDate = modificationDate;
    _cachedWallpaperFileSize = fileSize;
    _wallpaperCacheAttemptedForMetadata = YES;
    _wallpaperCacheHitCount = 0;
    size_t pixelWidth = decoded.CGImage ? CGImageGetWidth(decoded.CGImage) : 0;
    size_t pixelHeight = decoded.CGImage ? CGImageGetHeight(decoded.CGImage) : 0;
    LGIOS12ProviderLog(@"wallpaper cache=miss/redecode readable=%d decodeSuccess=%d decoder=%@ reason=%@ modified=%@ size=%@ pixels=%lux%lu points={%.0f,%.0f}",
                       [[NSFileManager defaultManager]
                           isReadableFileAtPath:path],
                       decoded != nil, decoderName ?: @"none", reason,
                       modificationDate, fileSize,
                       (unsigned long)pixelWidth,
                       (unsigned long)pixelHeight,
                       decoded.size.width, decoded.size.height);
    return decoded;
}

static void LGIOS12DrawAspectFillImageProvider(UIImage *image, CGRect bounds) {
    if (!image || CGRectIsEmpty(bounds) ||
        image.size.width <= 0.0 || image.size.height <= 0.0) return;
    CGFloat scale = MAX(CGRectGetWidth(bounds) / image.size.width,
                        CGRectGetHeight(bounds) / image.size.height);
    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
    CGRect destination = CGRectMake(CGRectGetMidX(bounds) - size.width * 0.5,
                                    CGRectGetMidY(bounds) - size.height * 0.5,
                                    size.width, size.height);
    [image drawInRect:destination];
}


// Enumerate the live visible SBIconView instances, every capture, no cache.
//
// The host window is tried first. If it yields no icons, every other visible
// non-overlay window is searched and the first one that actually contains
// icons wins. That widening exists because -springBoardHostWindow selects by
// the class-name substring "HomeScreenWindow"; if that match is wrong on this
// build, the old code reported "no visible SBIconView" and stopped, which is
// indistinguishable from "icons cannot be captured". Searching the rest of
// the window list removes that entire failure class as an explanation.
//
// Our own overlay window is excluded throughout, so this can never re-enter
// the glass and self-capture.
- (NSArray<UIView *> *)visibleIconViewsForHostWindow:(UIWindow *)hostWindow
                                       resolvedWindow:(UIWindow **)outWindow
                                           searchNote:(NSString **)outNote {
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    if (hostWindow) {
        LGIOS12CollectVisibleIconViews(
            hostWindow.rootViewController.view ?: hostWindow, icons);
    }
    if (icons.count > 0) {
        if (outWindow) *outWindow = hostWindow;
        if (outNote) *outNote = @"host-window";
        return icons;
    }

    NSMutableArray<NSString *> *scanned = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window || window.hidden || window.alpha <= 0.01 ||
            LGIOS12IsStandaloneOverlayWindow(window)) continue;
        [scanned addObject:NSStringFromClass(window.class)];
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        LGIOS12CollectVisibleIconViews(
            window.rootViewController.view ?: window, found);
        if (found.count > 0) {
            if (outWindow) *outWindow = window;
            if (outNote) {
                *outNote = [NSString stringWithFormat:
                    @"widened-window-search:%@(host=%@ had none)",
                    NSStringFromClass(window.class),
                    NSStringFromClass(hostWindow.class) ?: @"nil"];
            }
            return found;
        }
    }

    if (outWindow) *outWindow = hostWindow;
    if (outNote) {
        *outNote = [NSString stringWithFormat:
            @"no-icons-in-any-window scanned=[%@]",
            [scanned componentsJoinedByString:@","]];
    }
    return @[];
}

// Composite the foreground as individually rendered icons on top of the
// already-drawn wallpaper. Never draws a container, a page background, or the
// host window, so there is nothing here that can occlude the wallpaper.
- (LGIOS12ForegroundResult)renderPerIconForegroundIntoContext:(CGContextRef)context
                                                         icons:(NSArray<UIView *> *)icons
                                                  contributors:(NSMutableSet<NSString *> *)contributors
                                                 firstIconRect:(CGRect *)outFirstIconRect {
    LGIOS12ForegroundResult result = { 0 };
    result.iconsEnumerated = icons.count;
    result.strategy = _iconRenderStrategy;
    if (!context || icons.count == 0) return result;

    // Resolve the strategy when unset, when the last resolution is stale, or
    // when the last attempt drew nothing. Resolution pixel-probes several
    // candidates, so it must not run for every icon on every frame.
    BOOL stale = (_captureTickCount - _iconStrategyResolvedAtTick) > 300;
    if (_iconRenderStrategy == LGIOS12IconRenderStrategyUnresolved || stale) {
        NSMutableString *evidence = [NSMutableString string];
        _iconRenderStrategy = LGIOS12ResolveIconRenderStrategy(icons.firstObject,
                                                                evidence);
        _iconStrategyEvidence = [evidence copy];
        _iconStrategyResolvedAtTick = _captureTickCount;
        result.strategyReResolved = YES;
        LGIOS12ProviderLog(@"foreground STRATEGY-RESOLVED strategy=%@ probedIcon=%@ "
                           "evidence=%@",
                           LGIOS12IconRenderStrategyName(_iconRenderStrategy),
                           NSStringFromClass(icons.firstObject.class),
                           _iconStrategyEvidence);
    }
    result.strategy = _iconRenderStrategy;

    CGRect firstRect = CGRectNull;
    for (UIView *icon in icons) {
        CGRect iconRect = CGRectNull;
        LGIOS12IconRenderStrategy used = LGIOS12IconRenderStrategyFailed;
        NSUInteger drawn = LGIOS12RenderIconResilient(icon, _iconRenderStrategy,
                                                       context, contributors,
                                                       &iconRect, &used);
        if (drawn > 0) {
            result.iconsDrawn++;
            result.primitivesDrawn += drawn;
            if (CGRectIsNull(firstRect)) firstRect = iconRect;
        }
    }

    // Nothing came out at all: force a fresh resolution against a live icon so
    // the very next capture tries a different strategy rather than repeating a
    // strategy that is known not to work.
    if (result.primitivesDrawn == 0 && !result.strategyReResolved) {
        NSMutableString *evidence = [NSMutableString string];
        _iconRenderStrategy = LGIOS12ResolveIconRenderStrategy(icons.firstObject,
                                                                evidence);
        _iconStrategyEvidence = [evidence copy];
        _iconStrategyResolvedAtTick = _captureTickCount;
        result.strategyReResolved = YES;
        result.strategy = _iconRenderStrategy;
        LGIOS12ProviderLog(@"foreground STRATEGY-RE-RESOLVED (previous drew nothing) "
                           "strategy=%@ evidence=%@",
                           LGIOS12IconRenderStrategyName(_iconRenderStrategy),
                           _iconStrategyEvidence);
    }

    if (outFirstIconRect) *outFirstIconRect = firstRect;
    return result;
}

- (UIImage *)captureSpringBoardBackdrop:(UIWindow *)hostWindow
                          excludingViews:(NSArray<UIView *> *)excludedViews
                                   stats:(LGIOS12CaptureStats *)stats
                       sourceDescription:(NSString **)sourceDescription {
    if (!hostWindow) return nil;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;

    uint64_t stageStart = mach_absolute_time();
    NSArray<UIWindow *> *visibleWindows =
        [self visibleSourceWindowsSortedByLevel];
    [self logWindowStack:visibleWindows hostWindow:hostWindow];
    UIWindow *wallpaperWindow =
        [self wallpaperWindowBelowHostWindow:hostWindow
                              visibleWindows:visibleWindows];
    UIImage *wallpaper = [self cachedDecodedWallpaperAtPath:
        LGIOS12HomeWallpaperPathProvider()];
    LGIOS12StatAddTicks(&_perf.windowDiscovery, mach_absolute_time() - stageStart);
    // PRIMARY FOREGROUND PATH: enumerate the live visible icons every capture.
    // No container selection, no cached view set -- re-reading the hierarchy
    // each frame is what makes the rendered icons follow a page scroll.
    UIWindow *iconWindow = nil;
    NSString *iconSearchNote = nil;
    stageStart = mach_absolute_time();
    NSArray<UIView *> *visibleIcons =
        [self visibleIconViewsForHostWindow:hostWindow
                             resolvedWindow:&iconWindow
                                 searchNote:&iconSearchNote];
    LGIOS12StatAddTicks(&_perf.iconEnumeration, mach_absolute_time() - stageStart);

    LGIOS12CaptureStats captureStats = { 0 };
    captureStats.excludedGlassCount = excludedViews.count;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (LGIOS12IsStandaloneOverlayWindow(window) &&
            !window.hidden && window.alpha > 0.01) {
            captureStats.standaloneOverlayPresent = YES;
            break;
        }
    }

    NSMutableArray<CALayer *> *sameWindowLayers = [NSMutableArray array];
    NSMutableArray<NSNumber *> *originalLayerHiddenStates =
        [NSMutableArray array];
    for (UIView *glassView in excludedViews) {
        if (!glassView || glassView.window != hostWindow || glassView.hidden ||
            glassView.alpha <= 0.01) continue;
        [sameWindowLayers addObject:glassView.layer];
        [originalLayerHiddenStates addObject:@(glassView.layer.hidden)];
    }
    captureStats.sameWindowExcludedCount = sameWindowLayers.count;
    captureStats.usedModelLayerExclusion = sameWindowLayers.count > 0;

    // A standalone test view lives in a separate overlay UIWindow and can
    // never enter this source image.  Production views may eventually share
    // the host hierarchy, so render their model tree with only the glass
    // layers hidden.  The state is restored before this transaction commits;
    // there is no visible UIView hide/show and no forced CA flush.
    if (captureStats.usedModelLayerExclusion) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *layer in sameWindowLayers) layer.hidden = YES;
    }

    stageStart = mach_absolute_time();
    CGContextRef context = [self ensureCaptureContextForPointSize:screenBounds.size
                                                              scale:screenScale];
    if (context) {
        // Reused from a prior capture -- must clear before drawing, or
        // regions no longer covered by any content this frame (e.g. a
        // dismissed widget) would show stale pixels from last time. The
        // context's CTM is pre-scaled (see ensureCaptureContextForPointSize:),
        // so this rect is in points, matching every other draw call below.
        CGContextClearRect(context, screenBounds);
        UIGraphicsPushContext(context);
    }
    LGIOS12StatAddTicks(&_perf.bitmapContext, mach_absolute_time() - stageStart);
    UIImage *snapshot = nil;
    BOOL drewWallpaperWindow = NO;
    BOOL drewCPBitmap = NO;
    BOOL drewForeground = NO;
    NSUInteger foregroundRenderCount = 0;
    NSString *wallpaperSource = @"black-base";
    NSString *foregroundSource = @"none";
    CGRect firstForegroundScreenRectForLog = CGRectNull;
    LGIOS12ForegroundResult foregroundResult = { 0 };
    NSMutableArray<NSString *> *renderedClasses = [NSMutableArray array];

    if (context) {
        stageStart = mach_absolute_time();
        [[UIColor blackColor] setFill];
        UIRectFill(screenBounds);

        if (wallpaperWindow && LGIOS12CurrentDiagMode() != 3) {
            drewWallpaperWindow = LGIOS12RenderWindowAtScreenPosition(
                wallpaperWindow, context, screenBounds);
            if (drewWallpaperWindow) {
                wallpaperSource = [NSString stringWithFormat:@"window:%@",
                    NSStringFromClass(wallpaperWindow.class)];
            }
        }
        if (!drewWallpaperWindow && wallpaper &&
            LGIOS12CurrentDiagMode() != 3) {
            LGIOS12DrawAspectFillImageProvider(wallpaper, screenBounds);
            drewCPBitmap = YES;
            wallpaperSource = [NSString stringWithFormat:@"cpbitmap:%@",
                _cachedWallpaperDecoder ?: @"unknown-decoder"];
        }

        LGIOS12StatAddTicks(&_perf.wallpaperComposition,
                            mach_absolute_time() - stageStart);

        NSInteger diagMode = LGIOS12CurrentDiagMode();
        NSMutableSet<NSString *> *contributors = [NSMutableSet set];

        // MODE 7 (FOREGROUND_SINGLE_ICON): render exactly ONE visible icon,
        // through the same per-icon engine the normal path uses, so what it
        // proves transfers directly. Isolates one icon's render from the
        // enumeration of the rest.
        NSArray<UIView *> *iconsToRender = visibleIcons;
        if (diagMode == 7 && visibleIcons.count > 0) {
            iconsToRender = @[ visibleIcons.firstObject ];
        }

        stageStart = mach_absolute_time();
        if (diagMode != 2) {
            foregroundResult =
                [self renderPerIconForegroundIntoContext:context
                                                   icons:iconsToRender
                                            contributors:contributors
                                           firstIconRect:&firstForegroundScreenRectForLog];
            foregroundRenderCount = foregroundResult.primitivesDrawn;
            drewForeground = foregroundResult.primitivesDrawn > 0;
            for (NSString *contributor in contributors)
                [renderedClasses addObject:contributor];
        }
        LGIOS12StatAddTicks(&_perf.iconComposition, mach_absolute_time() - stageStart);

        _lastForegroundIconsEnumerated = foregroundResult.iconsEnumerated;
        _lastForegroundIconsDrawn = foregroundResult.iconsDrawn;
        _lastForegroundPrimitivesDrawn = foregroundResult.primitivesDrawn;
        _lastForegroundPathName =
            LGIOS12IconRenderStrategyName(foregroundResult.strategy);

        // Diagnostic outline anchor: if nothing drew, still record where the
        // first enumerated icon actually is, so modes 3 and 7 outline the
        // icon's real screen rect. An outline with no artwork inside it is the
        // evidence that separates "wrong coordinates" from "no pixels".
        if (CGRectIsNull(firstForegroundScreenRectForLog) && visibleIcons.count > 0) {
            UIView *anchorIcon = visibleIcons.firstObject;
            firstForegroundScreenRectForLog =
                [anchorIcon convertRect:anchorIcon.bounds toView:nil];
        }

        if (diagMode == 2) {
            foregroundSource = @"skipped:wallpaper-only-diagnostic-mode";
        } else if (drewForeground) {
            // Names the objects that actually supplied pixels, not the
            // container we hoped would.
            foregroundSource = [NSString stringWithFormat:
                @"per-icon:%@ icons=%lu/%lu primitives=%lu via=[%@]",
                LGIOS12IconRenderStrategyName(foregroundResult.strategy),
                (unsigned long)foregroundResult.iconsDrawn,
                (unsigned long)foregroundResult.iconsEnumerated,
                (unsigned long)foregroundResult.primitivesDrawn,
                [[contributors.allObjects sortedArrayUsingSelector:@selector(compare:)]
                    componentsJoinedByString:@","]];
        } else {
            // NO WHOLE-HOST FALLBACK, in any mode. It masked foreground
            // failure behind an opaque copy of the whole screen, and it is the
            // call that previously corrupted the live hierarchy. A blank card
            // is now always a truthful result.
            foregroundSource = [NSString stringWithFormat:
                @"FAILED:no-icon-pixels(strategy=%@ icons=%lu)",
                LGIOS12IconRenderStrategyName(foregroundResult.strategy),
                (unsigned long)foregroundResult.iconsEnumerated];
        }

        // FOREGROUND DEBUG OUTLINE -- diagnostic modes 3 and 7 only, never
        // shipped in normal mode. Draws a bright magenta stroke around the
        // exact screen rect where the foreground source was supposed to land.
        //   outline visible, no icons  -> selection/rendering is wrong
        //   outline offscreen/mirrored -> coordinate transform is wrong
        //   no outline at all          -> no source was selected
        if ((diagMode == 3 || diagMode == 7) && !CGRectIsNull(firstForegroundScreenRectForLog)) {
            CGContextSaveGState(context);
            CGContextSetRGBStrokeColor(context, 1.0, 0.0, 1.0, 1.0);
            CGContextSetLineWidth(context, 3.0);
            CGContextStrokeRect(context, firstForegroundScreenRectForLog);
            CGContextRestoreGState(context);
        }

        // Force a snapshot in the no-fallback diagnostic modes even when
        // nothing rendered, so a genuinely blank card is delivered as a
        // result rather than silently reusing the previous frame.
        BOOL forceSnapshotForDiagnostic = (diagMode == 3 || diagMode == 7);

        if (drewWallpaperWindow || drewCPBitmap || drewForeground ||
            forceSnapshotForDiagnostic) {
            // CGBitmapContextCreateImage's copy-on-write guarantee means
            // this snapshot stays correct even once we clear/redraw
            // _captureContext for the next capture -- no need to wait for
            // whatever consumes this image before reusing the buffer.
            uint64_t imageStart = mach_absolute_time();
            CGImageRef cgImage = CGBitmapContextCreateImage(context);
            LGIOS12StatAddTicks(&_perf.imageCreation,
                                mach_absolute_time() - imageStart);
            if (cgImage) {
                snapshot = [UIImage imageWithCGImage:cgImage
                                                scale:screenScale
                                          orientation:UIImageOrientationUp];
                CGImageRelease(cgImage);
            }
        }
        UIGraphicsPopContext();
    }

    if (captureStats.usedModelLayerExclusion) {
        for (NSUInteger index = 0; index < sameWindowLayers.count; index++) {
            sameWindowLayers[index].hidden =
                originalLayerHiddenStates[index].boolValue;
        }
        [CATransaction commit];
    }

    captureStats.windowsRendered = (drewWallpaperWindow ? 1 : 0);
    if (stats) *stats = captureStats;
    if (sourceDescription && snapshot) {
        *sourceDescription = [NSString stringWithFormat:
            @"wallpaper=%@+foreground=%@+composition=wallpaper-then-per-icon-foreground",
            wallpaperSource, foregroundSource];
    }
    // ===================================================================
    // SINGLE FOREGROUND VERDICT LINE -- the one line to grep for.
    // Emitted on every change of outcome plus on the normal rate-limited
    // schedule, so it is always present without flooding the log.
    // ===================================================================
    BOOL foregroundOK = drewForeground && foregroundRenderCount > 0;
    if (![_lastForegroundDescription isEqualToString:foregroundSource] ||
        LGIOS12ProviderShouldLogSequence(_captureTickCount)) {

        // Probe the first live icon so the verdict always carries independent
        // evidence about whether icon pixels are obtainable at all, separate
        // from whether this frame happened to draw any.
        double iconProbeCoverage = -1.0, iconProbePeakLuma = -1.0;
        UIView *probeIcon = visibleIcons.firstObject;
        if (probeIcon) {
            LGIOS12ProbeViewRendersPixels(probeIcon, &iconProbeCoverage,
                                          &iconProbePeakLuma);
        }

        NSString *contributorSummary =
            [[renderedClasses sortedArrayUsingSelector:@selector(compare:)]
                componentsJoinedByString:@","];
        if (contributorSummary.length == 0) contributorSummary = @"none";
        _lastIconContributorSummary = contributorSummary;

        // ===============================================================
        // THE ONE LINE TO GREP: names the exact objects that supplied the
        // icon pixels, or the exact stage that failed.
        // ===============================================================
        LGIOS12ProviderLog(@"foreground result=%@ path=per-icon strategy=%@ "
                           "iconsEnumerated=%lu iconsDrawn=%lu primitivesDrawn=%lu "
                           "pixelSuppliers=[%@] iconWindow=%@ iconSearch=%@ "
                           "firstIconProbeCoverage=%.3f firstIconProbePeakLuma=%.3f "
                           "firstIconClass=%@ firstIconScreenRect={%.0f,%.0f,%.0f,%.0f} "
                           "strategyEvidence=%@ wholeHostFallback=REMOVED reason=%@",
                           foregroundOK ? @"SUCCESS" : @"FAILED",
                           LGIOS12IconRenderStrategyName(foregroundResult.strategy),
                           (unsigned long)foregroundResult.iconsEnumerated,
                           (unsigned long)foregroundResult.iconsDrawn,
                           (unsigned long)foregroundResult.primitivesDrawn,
                           contributorSummary,
                           NSStringFromClass(iconWindow.class) ?: @"none",
                           iconSearchNote ?: @"n/a",
                           iconProbeCoverage, iconProbePeakLuma,
                           NSStringFromClass(probeIcon.class) ?: @"none",
                           firstForegroundScreenRectForLog.origin.x,
                           firstForegroundScreenRectForLog.origin.y,
                           firstForegroundScreenRectForLog.size.width,
                           firstForegroundScreenRectForLog.size.height,
                           _iconStrategyEvidence ?: @"none",
                           foregroundOK ? @"n/a"
                               : (foregroundResult.iconsEnumerated == 0
                                   ? @"no-visible-SBIconView-in-any-window"
                                   : (foregroundResult.strategy ==
                                        LGIOS12IconRenderStrategyFailed
                                       ? @"icons-found-but-no-artwork-source-in-subtree"
                                       : @"artwork-source-resolved-but-drew-nothing")));

        // What the abandoned container path WOULD have selected. Kept purely
        // as comparative evidence -- it no longer influences the capture.
        if (LGIOS12ProviderShouldLogSequence(_captureTickCount)) {
            NSString *legacyDescription = nil;
            (void)[self foregroundViewsForHostWindow:hostWindow
                                          description:&legacyDescription];
            LGIOS12ProviderLog(@"foreground LEGACY-CONTAINER-PATH (informational, "
                               "not used) would-have-selected=%@",
                               legacyDescription ?: @"nothing");
        }

        // Hierarchy dump when the foreground is failing -- this is what
        // identifies the real icon-bearing subtree instead of guessing at
        // class names.
        if (!foregroundOK && LGIOS12ProviderShouldLogSequence(_captureTickCount)) {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
            LGIOS12DumpHierarchy((iconWindow ?: hostWindow).rootViewController.view
                                     ?: (iconWindow ?: hostWindow),
                                  0, 7, lines);
            LGIOS12ProviderLog(@"foreground HIERARCHY-DUMP (branches marked *ICONS* "
                               "contain a visible SBIconView):\n%@",
                               [lines componentsJoinedByString:@"\n"]);
        }

        _lastForegroundDescription = foregroundSource;
    }

    if (LGIOS12ProviderShouldLogSequence(_captureTickCount)) {
        LGIOS12ProviderLog(@"wallpaper composition finalSource=%@ wallpaperWindowCandidate=%@ wallpaperWindowRendered=%d cpbitmapDecoded=%d cpbitmapRendered=%d foregroundSource=%@ foregroundPrimitivesRendered=%lu iconsDrawn=%lu hostOpaque=%d sourceMode=%lu finalPath=%@",
                           wallpaperSource,
                           NSStringFromClass(wallpaperWindow.class),
                           drewWallpaperWindow, wallpaper != nil, drewCPBitmap,
                           foregroundSource,
                           (unsigned long)foregroundRenderCount,
                           (unsigned long)foregroundResult.iconsDrawn,
                           hostWindow.opaque,
                           (unsigned long)LGIOS12CurrentDiagMode(),
                           @"wallpaper+per-icon-foreground");
    }
    return snapshot;
}

@end
