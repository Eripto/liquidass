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

// Controlled-test source modes (PRIORITY 1 isolation). Compile-time only --
// no preference UI, per the task constraints. Leave at Composite for normal
// builds; flip to WallpaperOnly/ForegroundOnly to prove which stage an
// artifact originates from.
typedef NS_ENUM(NSUInteger, LGIOS12SourceMode) {
    LGIOS12SourceModeComposite = 0,
    LGIOS12SourceModeWallpaperOnly,
    LGIOS12SourceModeForegroundOnly,
};
#ifndef LGIOS12_SOURCE_MODE
#define LGIOS12_SOURCE_MODE LGIOS12SourceModeComposite
#endif

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
// Uses the *presentation* layer when one exists. -renderInContext: on a
// model layer draws final/committed values, so during a page-turn snap
// animation the captured icons would jump ahead of where they actually
// appear on screen. presentationLayer reflects the currently displayed
// in-flight state, which is what the backdrop must match. Falls back to the
// model layer when no presentation layer exists (i.e. nothing animating),
// where the two are equivalent anyway.
//
// Geometry is still taken from the model view (convertRect:toView:nil) --
// see the note in renderStableForegroundContainer: about why that is
// correct for a finger-tracked scroll.
static BOOL LGIOS12RenderViewAtScreenPosition(UIView *view,
                                               CGContextRef context) {
    if (!LGIOS12ViewIsVisibleForCapture(view) || !context) return NO;
    CGRect screenRect = [view convertRect:view.bounds toView:nil];
    if (CGRectIsEmpty(screenRect) || CGRectIsEmpty(view.bounds)) return NO;
    CGFloat scaleX = CGRectGetWidth(screenRect) / CGRectGetWidth(view.bounds);
    CGFloat scaleY = CGRectGetHeight(screenRect) / CGRectGetHeight(view.bounds);
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMinX(screenRect),
                          CGRectGetMinY(screenRect));
    CGContextScaleCTM(context, scaleX, scaleY);
    CGContextTranslateCTM(context, -CGRectGetMinX(view.bounds),
                          -CGRectGetMinY(view.bounds));
    CALayer *renderLayer = view.layer.presentationLayer ?: view.layer;
    [renderLayer renderInContext:context];
    CGContextRestoreGState(context);
    return YES;
}

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
}

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
        CGContextScaleCTM(_captureContext, scale, scale);
        _captureBufferPixelWidth = pixelWidth;
        _captureBufferPixelHeight = pixelHeight;
        _captureBufferBytesPerRow = bytesPerRow;
        LGIOS12ProviderLog(@"capture-buffer allocated pixels=%zux%zu scale=%.1f "
                           "reason=%@", pixelWidth, pixelHeight, scale,
                           _captureBufferPixelWidth ? @"size-changed" : @"first-use");
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
            LGIOS12ProviderLog(@"foreground source=stable-container class=%@ token=%@ "
                               "bounds={%.0f,%.0f} transparentBase=%d",
                               NSStringFromClass(container.class), token,
                               container.bounds.size.width, container.bounds.size.height,
                               LGIOS12ViewHasTransparentBase(container));
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


- (UIImage *)captureSpringBoardBackdrop:(UIWindow *)hostWindow
                          excludingViews:(NSArray<UIView *> *)excludedViews
                                   stats:(LGIOS12CaptureStats *)stats
                       sourceDescription:(NSString **)sourceDescription {
    if (!hostWindow) return nil;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;

    NSArray<UIWindow *> *visibleWindows =
        [self visibleSourceWindowsSortedByLevel];
    [self logWindowStack:visibleWindows hostWindow:hostWindow];
    UIWindow *wallpaperWindow =
        [self wallpaperWindowBelowHostWindow:hostWindow
                              visibleWindows:visibleWindows];
    UIImage *wallpaper = [self cachedDecodedWallpaperAtPath:
        LGIOS12HomeWallpaperPathProvider()];
    NSString *foregroundDescription = nil;
    NSArray<UIView *> *foregroundViews =
        [self foregroundViewsForHostWindow:hostWindow
                               description:&foregroundDescription];

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
    UIImage *snapshot = nil;
    BOOL drewWallpaperWindow = NO;
    BOOL drewCPBitmap = NO;
    BOOL drewForeground = NO;
    BOOL usedWholeHostFallback = NO;
    NSUInteger foregroundRenderCount = 0;
    NSString *wallpaperSource = @"black-base";
    NSString *foregroundSource = @"none";

    if (context) {
        [[UIColor blackColor] setFill];
        UIRectFill(screenBounds);

        if (wallpaperWindow && LGIOS12_SOURCE_MODE != LGIOS12SourceModeForegroundOnly) {
            drewWallpaperWindow = LGIOS12RenderWindowAtScreenPosition(
                wallpaperWindow, context, screenBounds);
            if (drewWallpaperWindow) {
                wallpaperSource = [NSString stringWithFormat:@"window:%@",
                    NSStringFromClass(wallpaperWindow.class)];
            }
        }
        if (!drewWallpaperWindow && wallpaper &&
            LGIOS12_SOURCE_MODE != LGIOS12SourceModeForegroundOnly) {
            LGIOS12DrawAspectFillImageProvider(wallpaper, screenBounds);
            drewCPBitmap = YES;
            wallpaperSource = [NSString stringWithFormat:@"cpbitmap:%@",
                _cachedWallpaperDecoder ?: @"unknown-decoder"];
        }

        if (LGIOS12_SOURCE_MODE != LGIOS12SourceModeWallpaperOnly) {
            for (UIView *foregroundView in foregroundViews) {
                if (LGIOS12RenderViewAtScreenPosition(foregroundView, context)) {
                    drewForeground = YES;
                    foregroundRenderCount++;
                }
            }
        }
        if (drewForeground) {
            foregroundSource = [NSString stringWithFormat:
                @"transparent-icon-hierarchy:%@",
                foregroundDescription ?: @"unknown"];
        } else if (LGIOS12_SOURCE_MODE == LGIOS12SourceModeWallpaperOnly) {
            foregroundSource = @"skipped:wallpaper-only-diagnostic-mode";
        } else {
            // Last resort. NOTE: this no longer uses
            // -drawViewHierarchyInRect: (see the comment on
            // LGIOS12RenderWindowAtScreenPosition -- that call is what
            // corrupted the live screen during page scroll in the device
            // video). It is now a read-only -renderInContext: of the host
            // window, which cannot disturb SpringBoard. It can still occlude
            // the wallpaper base if the host window is opaque, so it stays
            // explicitly identified in diagnostics rather than silently
            // passing as a successful composite.
            usedWholeHostFallback = LGIOS12RenderWindowAtScreenPosition(
                hostWindow, context, screenBounds);
            foregroundSource = usedWholeHostFallback
                ? @"whole-host-window-fallback"
                : @"foreground-render-failed";
        }

        if (drewWallpaperWindow || drewCPBitmap || drewForeground ||
            usedWholeHostFallback) {
            // CGBitmapContextCreateImage's copy-on-write guarantee means
            // this snapshot stays correct even once we clear/redraw
            // _captureContext for the next capture -- no need to wait for
            // whatever consumes this image before reusing the buffer.
            CGImageRef cgImage = CGBitmapContextCreateImage(context);
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

    captureStats.windowsRendered = (drewWallpaperWindow ? 1 : 0) +
                                   (usedWholeHostFallback ? 1 : 0);
    if (stats) *stats = captureStats;
    if (sourceDescription && snapshot) {
        *sourceDescription = [NSString stringWithFormat:
            @"wallpaper=%@+foreground=%@+composition=wallpaper-then-transparent-foreground",
            wallpaperSource, foregroundSource];
    }
    // Foreground-source instability diagnostics. Logged on *change* rather
    // than on a fixed cadence, because a change mid-page-scroll is precisely
    // the failure signature we are hunting: if the source flips while
    // scrolling, the stable-container cache is not holding and the old
    // per-frame rederivation is still in play.
    if (![_lastForegroundDescription isEqualToString:foregroundSource]) {
        uint64_t changeCount = ++_foregroundSourceChangeCount;
        NSMutableArray<NSString *> *sourceDetails = [NSMutableArray array];
        for (UIView *view in foregroundViews) {
            CGRect screenRect = [view convertRect:view.bounds toView:nil];
            [sourceDetails addObject:[NSString stringWithFormat:
                @"{%@ bounds={%.0f,%.0f} screen={%.0f,%.0f,%.0f,%.0f} super=%@ hasPresentation=%d}",
                NSStringFromClass(view.class),
                view.bounds.size.width, view.bounds.size.height,
                screenRect.origin.x, screenRect.origin.y,
                screenRect.size.width, screenRect.size.height,
                NSStringFromClass(view.superview.class) ?: @"none",
                view.layer.presentationLayer != nil]];
        }
        NSMutableArray<UIView *> *visibleIcons = [NSMutableArray array];
        LGIOS12CollectVisibleIconViews(hostWindow.rootViewController.view ?: hostWindow,
                                        visibleIcons);
        LGIOS12ProviderLog(@"foreground SOURCE-CHANGED change=%llu previous=%@ current=%@ "
                           "detail=%@ viewCount=%lu visibleSBIconViews=%lu "
                           "captureMethod=%@ sources=[%@]",
                           (unsigned long long)changeCount,
                           _lastForegroundDescription ?: @"none", foregroundSource,
                           foregroundDescription ?: @"none",
                           (unsigned long)foregroundViews.count,
                           (unsigned long)visibleIcons.count,
                           usedWholeHostFallback
                               ? @"renderInContext:host-window-fallback"
                               : @"renderInContext:presentationLayer-per-view",
                           [sourceDetails componentsJoinedByString:@","]);
        _lastForegroundDescription = foregroundSource;
    }

    if (LGIOS12ProviderShouldLogSequence(_captureTickCount)) {
        LGIOS12ProviderLog(@"wallpaper composition finalSource=%@ wallpaperWindowCandidate=%@ wallpaperWindowRendered=%d cpbitmapDecoded=%d cpbitmapRendered=%d foregroundSource=%@ foregroundViewsRendered=%lu wholeHostFallback=%d hostOpaque=%d sourceMode=%lu finalPath=%@",
                           wallpaperSource,
                           NSStringFromClass(wallpaperWindow.class),
                           drewWallpaperWindow, wallpaper != nil, drewCPBitmap,
                           foregroundSource,
                           (unsigned long)foregroundRenderCount,
                           usedWholeHostFallback, hostWindow.opaque,
                           (unsigned long)LGIOS12_SOURCE_MODE,
                           usedWholeHostFallback
                               ? @"wallpaper+opaque-host-fallback"
                               : @"wallpaper+transparent-icon-foreground");
    }
    return snapshot;
}

@end
