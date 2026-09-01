#import "LGIOS12LiveBackdropProvider.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import "LGSharedSupport.h"
#import <mach/mach_time.h>

static void LGIOS12ProviderLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LGIOS12ProviderLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    LGLog(@"renderer.ios12.provider %@", message);
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

    // Performance diagnostics
    uint64_t _totalCaptureTime;
    uint64_t _totalUploadTime;
    uint64_t _captureCount;
    uint64_t _captureTickCount;
    uint64_t _textureDeliveryCount;
}

+ (instancetype)sharedProvider {
    static LGIOS12LiveBackdropProvider *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LGIOS12LiveBackdropProvider alloc] init];
    });
    return shared;
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
        LGIOS12ProviderLog(@"capture tick=%llu hostWindow=%@ windowsRendered=%lu excludedGlass=%lu sameWindowExcluded=%lu standaloneSeparateOverlay=%d exclusionStrategy=%@ success=%d activeClients=%lu",
                           (unsigned long long)tick,
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

    // Upload texture
    uint64_t uploadStart = mach_absolute_time();

    NSDictionary *options = @{
        MTKTextureLoaderOptionSRGB: @NO,
        MTKTextureLoaderOptionOrigin: MTKTextureLoaderOriginTopLeft,
    };

    NSError *error = nil;
    id<MTLTexture> texture = [_textureLoader newTextureWithCGImage:snapshot.CGImage
                                                           options:options
                                                             error:&error];

    uint64_t uploadEnd = mach_absolute_time();

    if (!texture) {
        [self finishCaptureWithError:error ?: [NSError errorWithDomain:@"LGIOS12"
            code:3 userInfo:@{NSLocalizedDescriptionKey: @"Texture upload failed"}]];
        return;
    }

    _currentBackdropTexture = texture;
    _currentSourceDescription = sourceDesc;

    // Diagnostics
    _captureCount++;
    _totalCaptureTime += (captureEnd - captureStart);
    _totalUploadTime += (uploadEnd - uploadStart);

    if (_captureCount % 60 == 0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        double captureMs = (double)(_totalCaptureTime / _captureCount) * tb.numer / tb.denom / 1000000.0;
        double uploadMs = (double)(_totalUploadTime / _captureCount) * tb.numer / tb.denom / 1000000.0;
        LGIOS12ProviderLog(@"Performance avg (60 captures): capture=%.2fms upload=%.2fms", captureMs, uploadMs);

        // Adaptive throttling logic
        double totalMs = captureMs + uploadMs;
        if (totalMs > 50.0) {
            // Increase interval under load, but keep the standalone capture
            // budget in the requested 15-30 FPS range.
            _targetRefreshInterval = MIN(1.0 / 15.0,
                                         _targetRefreshInterval * 1.25);
            LGIOS12ProviderLog(@"Throttling refresh rate to %.1f FPS due to load", 1.0 / _targetRefreshInterval);
        } else if (totalMs < 28.0 &&
                   _targetRefreshInterval > (1.0 / 30.0)) {
            // Raise capture cadence when the previous interval has headroom.
            _targetRefreshInterval = MAX(1.0 / 30.0,
                                         _targetRefreshInterval * 0.85);
            LGIOS12ProviderLog(@"Increasing refresh rate to %.1f FPS", 1.0 / _targetRefreshInterval);
        }

        _totalCaptureTime = 0;
        _totalUploadTime = 0;
        _captureCount = 0;
    }

    NSArray<id<LGIOS12LiveBackdropClient>> *clients = _clients.allObjects;
    uint64_t delivery = ++_textureDeliveryCount;
    if (LGIOS12ProviderShouldLogSequence(delivery)) {
        LGIOS12ProviderLog(@"texture delivery=%llu source=%@ dimensions=%lux%lu clients=%lu activeClients=%lu device=%@",
                           (unsigned long long)delivery,
                           sourceDesc ?: @"unknown",
                           (unsigned long)texture.width,
                           (unsigned long)texture.height,
                           (unsigned long)clients.count,
                           (unsigned long)[self activeClientCount],
                           texture.device.name ?: @"unknown");
    }
    for (id<LGIOS12LiveBackdropClient> client in clients) {
        [client providerDidUpdateBackdropTexture:texture source:sourceDesc];
    }

    _isCapturing = NO;
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

static NSString *LGIOS12HomeWallpaperPathProvider(void) {
    return @"/var/mobile/Library/SpringBoard/HomeBackground.cpbitmap";
}

// Re-using the cpbitmap decoder logic
- (UIImage *)decodeCPBitmap:(NSString *)path {
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

- (UIImage *)cachedDecodedWallpaperAtPath:(NSString *)path {
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
        _wallpaperCacheAttemptedForMetadata = NO;
        if (![_wallpaperCacheLastUnavailableReason isEqualToString:reason]) {
            _wallpaperCacheLastUnavailableReason = reason;
            LGIOS12ProviderLog(@"wallpaper cache=miss/redecode success=0 reason=%@ path=%@ fallback=host-window-or-black",
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
            LGIOS12ProviderLog(@"wallpaper cache=hit count=%llu decoded=%d modified=%@ size=%@",
                               (unsigned long long)hit,
                               _cachedWallpaperImage != nil,
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

    UIImage *decoded = [self decodeCPBitmap:path];
    _cachedWallpaperImage = decoded;
    _cachedWallpaperModificationDate = modificationDate;
    _cachedWallpaperFileSize = fileSize;
    _wallpaperCacheAttemptedForMetadata = YES;
    _wallpaperCacheHitCount = 0;
    LGIOS12ProviderLog(@"wallpaper cache=miss/redecode success=%d reason=%@ modified=%@ size=%@ dimensions={%.0f,%.0f}",
                       decoded != nil, reason, modificationDate, fileSize,
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

    UIImage *wallpaper = [self cachedDecodedWallpaperAtPath:
        LGIOS12HomeWallpaperPathProvider()];

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

    UIGraphicsBeginImageContextWithOptions(screenBounds.size, YES, screenScale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIImage *snapshot = nil;
    BOOL drewHostWindow = NO;

    if (context) {
        [[UIColor blackColor] setFill];
        UIRectFill(screenBounds);

        if (wallpaper) LGIOS12DrawAspectFillImageProvider(wallpaper, screenBounds);

        CGRect frame = hostWindow.frame;
        if (CGRectIsEmpty(frame)) frame = screenBounds;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, CGRectGetMinX(frame), CGRectGetMinY(frame));
        if (captureStats.usedModelLayerExclusion) {
            [hostWindow.layer renderInContext:context];
            drewHostWindow = YES;
        } else {
            drewHostWindow = [hostWindow
                drawViewHierarchyInRect:hostWindow.bounds
                      afterScreenUpdates:NO];
            if (!drewHostWindow) {
                [hostWindow.layer renderInContext:context];
                drewHostWindow = YES;
            }
        }
        CGContextRestoreGState(context);

        if (wallpaper || drewHostWindow) {
            snapshot = UIGraphicsGetImageFromCurrentImageContext();
        }
    }
    UIGraphicsEndImageContext();

    if (captureStats.usedModelLayerExclusion) {
        for (NSUInteger index = 0; index < sameWindowLayers.count; index++) {
            sameWindowLayers[index].hidden =
                originalLayerHiddenStates[index].boolValue;
        }
        [CATransaction commit];
    }

    captureStats.windowsRendered = drewHostWindow ? 1 : 0;
    if (stats) *stats = captureStats;
    if (sourceDescription && snapshot) {
        *sourceDescription = [NSString stringWithFormat:@"%@+host:%@+%@",
            wallpaper ? @"cpbitmap" : @"black-base",
            NSStringFromClass(hostWindow.class),
            captureStats.usedModelLayerExclusion
                ? @"model-layer-exclusion" : @"window-hierarchy"];
    }
    return snapshot;
}

@end
