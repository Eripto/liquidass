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
    LGDiagnosticLog(@"renderer.ios12.provider %@", message);
}

@implementation LGIOS12LiveBackdropProvider {
    id<MTLDevice> _device;
    MTKTextureLoader *_textureLoader;
    NSHashTable<id<LGIOS12LiveBackdropClient>> *_clients;
    NSHashTable<UIView *> *_excludedGlassViews;

    CADisplayLink *_displayLink;
    BOOL _needsActiveRefresh;
    NSTimeInterval _lastRefreshTime;
    NSTimeInterval _targetRefreshInterval;

    BOOL _isCapturing;

    // Performance diagnostics
    uint64_t _totalCaptureTime;
    uint64_t _totalUploadTime;
    uint64_t _captureCount;
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
        _excludedGlassViews = [NSHashTable weakObjectsHashTable];

        _targetRefreshInterval = 1.0 / 10.0; // Start at 10 FPS

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
    }
    return self;
}

- (void)registerClient:(id<LGIOS12LiveBackdropClient>)client {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (client) {
            [self->_clients addObject:client];
            if (self->_currentBackdropTexture) {
                [client providerDidUpdateBackdropTexture:self->_currentBackdropTexture source:self->_currentSourceDescription];
            } else {
                [self requestRefresh];
            }
        }
    });
}

- (void)unregisterClient:(id<LGIOS12LiveBackdropClient>)client {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (client) {
            [self->_clients removeObject:client];
            if (self->_clients.count == 0) {
                [self setNeedsActiveRefresh:NO];
            }
        }
    });
}

- (void)registerGlassViewForExclusion:(UIView *)glassView {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (glassView) {
            [self->_excludedGlassViews addObject:glassView];
        }
    });
}

- (void)unregisterGlassViewForExclusion:(UIView *)glassView {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (glassView) {
            [self->_excludedGlassViews removeObject:glassView];
        }
    });
}

- (void)setNeedsActiveRefresh:(BOOL)active {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_needsActiveRefresh == active) return;
        self->_needsActiveRefresh = active;

        if (active) {
            if (!self->_displayLink && self->_clients.count > 0) {
                self->_displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
                // preferredFramesPerSecond is available throughout the
                // project's iOS 12+ deployment range.
                self->_displayLink.preferredFramesPerSecond = 10;
                [self->_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
                LGIOS12ProviderLog(@"Active refresh loop started (target: %.1f FPS)", 1.0 / self->_targetRefreshInterval);
            }
        } else {
            [self->_displayLink invalidate];
            self->_displayLink = nil;
            LGIOS12ProviderLog(@"Active refresh loop stopped");
        }
    });
}

- (void)applicationDidEnterBackground {
    [self setNeedsActiveRefresh:NO];
}

- (void)applicationWillEnterForeground {
    if (_clients.count > 0) {
        [self requestRefresh];
    }
}

- (void)displayLinkFired:(CADisplayLink *)link {
    CFTimeInterval current = CACurrentMediaTime();
    if (current - _lastRefreshTime >= _targetRefreshInterval) {
        [self performCaptureAndUpload];
        _lastRefreshTime = current;
    }
}

- (void)requestRefresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performCaptureAndUpload];
    });
}

- (void)performCaptureAndUpload {
    if (_isCapturing || !_device) return;
    _isCapturing = YES;

    uint64_t captureStart = mach_absolute_time();

    // Hide excluded views
    NSMutableArray<UIView *> *hiddenViews = [NSMutableArray array];
    NSMutableArray<NSNumber *> *originalHiddenStates = [NSMutableArray array];

    for (UIView *view in _excludedGlassViews) {
        if (!view.hidden) {
            [hiddenViews addObject:view];
            [originalHiddenStates addObject:@(view.hidden)];
            view.hidden = YES;
        }
    }

    // Capture
    UIWindow *hostWindow = [self springBoardHostWindow];
    if (!hostWindow) {
        [self finishCaptureWithHiddenViews:hiddenViews originalStates:originalHiddenStates error:[NSError errorWithDomain:@"LGIOS12" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No host window found"}]];
        return;
    }

    NSString *sourceDesc = nil;
    UIImage *snapshot = [self captureSpringBoardBackdrop:hostWindow sourceDescription:&sourceDesc];

    // Restore excluded views immediately after capture, even if it failed
    for (NSUInteger i = 0; i < hiddenViews.count; i++) {
        hiddenViews[i].hidden = originalHiddenStates[i].boolValue;
    }

    uint64_t captureEnd = mach_absolute_time();

    if (!snapshot) {
        [self finishCaptureWithHiddenViews:nil originalStates:nil error:[NSError errorWithDomain:@"LGIOS12" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Capture failed"}]];
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
        [self finishCaptureWithHiddenViews:nil originalStates:nil error:error];
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
        if (totalMs > 100.0) { // If it takes more than 100ms (10fps max limit)
            // Increase interval to lower FPS. Cap at 5 FPS (0.2s)
            _targetRefreshInterval = MIN(1.0 / 5.0, _targetRefreshInterval * 1.5);
            LGIOS12ProviderLog(@"Throttling refresh rate to %.1f FPS due to load", 1.0 / _targetRefreshInterval);
        } else if (totalMs < 60.0 && _targetRefreshInterval > (1.0 / 10.0)) { // If we have headroom
            // Decrease interval to raise FPS. Floor at 10 FPS (0.1s)
            _targetRefreshInterval = MAX(1.0 / 10.0, _targetRefreshInterval * 0.8);
            LGIOS12ProviderLog(@"Increasing refresh rate to %.1f FPS", 1.0 / _targetRefreshInterval);
        }

        _totalCaptureTime = 0;
        _totalUploadTime = 0;
        _captureCount = 0;
    }

    // Notify clients
    for (id<LGIOS12LiveBackdropClient> client in _clients) {
        [client providerDidUpdateBackdropTexture:texture source:sourceDesc];
    }

    _isCapturing = NO;
}

- (void)finishCaptureWithHiddenViews:(NSArray<UIView *> *)hiddenViews originalStates:(NSArray<NSNumber *> *)states error:(NSError *)error {
    // Failsafe restore if not already done
    if (hiddenViews) {
        for (NSUInteger i = 0; i < hiddenViews.count; i++) {
            hiddenViews[i].hidden = states[i].boolValue;
        }
    }

    LGIOS12ProviderLog(@"Capture/upload failed: %@", error.localizedDescription);
    for (id<LGIOS12LiveBackdropClient> client in _clients) {
        [client providerDidFailToUpdateBackdrop:error];
    }
    _isCapturing = NO;
}

// Reuse existing capture logic from standalone view, but centralized
- (UIWindow *)springBoardHostWindow {
    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIWindow *> *windows = [application.windows copy];
    UIWindow *fallback = nil;
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01) continue;
        NSString *className = NSStringFromClass(window.class);
        if ([className containsString:@"HomeScreenWindow"]) return window;
        if (!fallback && window.windowLevel == UIWindowLevelNormal)
            fallback = window;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return fallback ?: application.keyWindow;
#pragma clang diagnostic pop
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


- (UIImage *)captureSpringBoardBackdrop:(UIWindow *)hostWindow sourceDescription:(NSString **)sourceDescription {
    if (!hostWindow) return nil;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;

    UIImage *wallpaper = [self decodeCPBitmap:LGIOS12HomeWallpaperPathProvider()];

    UIGraphicsBeginImageContextWithOptions(screenBounds.size, YES, screenScale);
    CGContextRef context = UIGraphicsGetCurrentContext();

    [[UIColor blackColor] setFill];
    UIRectFill(screenBounds);

    BOOL drewWallpaper = wallpaper != nil;
    if (wallpaper) LGIOS12DrawAspectFillImageProvider(wallpaper, screenBounds);

    NSArray<UIWindow *> *windows = [[UIApplication sharedApplication].windows
        sortedArrayUsingComparator:^NSComparisonResult(UIWindow *left, UIWindow *right) {
            if (left.windowLevel < right.windowLevel) return NSOrderedAscending;
            if (left.windowLevel > right.windowLevel) return NSOrderedDescending;
            return NSOrderedSame;
        }];

    NSUInteger drawnWindows = 0;
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01 ||
            window.windowLevel > hostWindow.windowLevel + 0.01) continue;

        NSString *className = NSStringFromClass(window.class);
        if ([className containsString:@"Keyboard"] ||
            [className containsString:@"TextEffects"]) continue;

        CGRect frame = window.frame;
        if (CGRectIsEmpty(frame)) frame = screenBounds;

        CGContextSaveGState(context);
        CGContextTranslateCTM(context, CGRectGetMinX(frame), CGRectGetMinY(frame));

        BOOL drewHierarchy = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        if (!drewHierarchy) [window.layer renderInContext:context];

        CGContextRestoreGState(context);
        drawnWindows++;
        if (window == hostWindow) break;
    }

    UIImage *snapshot = (drewWallpaper || drawnWindows)
        ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();

    if (sourceDescription && snapshot) {
        *sourceDescription = [NSString stringWithFormat:@"%@+%lu-window%@",
            drewWallpaper ? @"cpbitmap" : @"window-hierarchy",
            (unsigned long)drawnWindows, drawnWindows == 1 ? @"" : @"s"];
    }

    return snapshot;
}

@end
