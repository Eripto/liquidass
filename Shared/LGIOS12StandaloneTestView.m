#import "LGSharedSupport.h"
#import "LGIOS12MetalShader.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>
#import <stdarg.h>
#import "LGIOS12LiveBackdropProvider.h"
#import "LGIOS12ForegroundProbeView.h"
#import "LGIOS12PerfHUDView.h"

// The render-server CAFilter backend cannot be enabled on iOS 12 until the
// iOS 12 QuartzCore layouts have been independently recovered from that OS's
// binary.  This test surface deliberately uses no private QuartzCore offsets:
// it captures SpringBoard, uploads that real backdrop to Metal, refracts it in
// a compute pass, and presents the result in one isolated floating view.


static NSString * const kLGIOS12DiagnosticsPrefix = @"renderer.ios12.test";
static CFStringRef const kLGIOS12PrefsReloadNotification =
    CFSTR("dylv.liquidassprefs/Reload");

static void LGIOS12Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LGIOS12Log(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    LGLog(@"%@ %@", kLGIOS12DiagnosticsPrefix, message);
}

static BOOL LGIOS12ShouldLogSequence(uint64_t sequence) {
    return sequence <= 3 || (sequence % 30) == 0;
}

@interface LGIOS12StandaloneOverlayWindow : UIWindow
@end

@implementation LGIOS12StandaloneOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    UIView *rootView = self.rootViewController.view;
    if (hitView == self || hitView == rootView) return nil;
    return hitView;
}

@end

static UIWindow *LGIOS12SpringBoardHostWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIWindow *> *windows = [application.windows copy];
    UIWindow *fallback = nil;
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01) continue;
        NSString *className = NSStringFromClass(window.class);
        if ([className isEqualToString:@"LGIOS12StandaloneOverlayWindow"])
            continue;
        if ([className containsString:@"HomeScreenWindow"]) return window;
        if (!fallback && window.windowLevel == UIWindowLevelNormal)
            fallback = window;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *keyWindow = application.keyWindow;
#pragma clang diagnostic pop
    if (!fallback &&
        ![NSStringFromClass(keyWindow.class)
            isEqualToString:@"LGIOS12StandaloneOverlayWindow"]) {
        fallback = keyWindow;
    }
    return fallback;
}

@interface LGIOS12FloatingGlassTestView : UIView <MTKViewDelegate, LGIOS12LiveBackdropClient>
@property (nonatomic, readonly) BOOL rendererReady;
@property (nonatomic, readonly) BOOL metalInitialized;
- (instancetype)initWithFrame:(CGRect)frame;
- (void)updateContinuousRefreshState;
@end

@implementation LGIOS12FloatingGlassTestView {
    MTKView *_metalView;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLComputePipelineState> _computePipeline;
    id<MTLRenderPipelineState> _presentPipeline;
    id<MTLTexture> _backdropTexture;
    id<MTLTexture> _outputTexture;
    UILabel *_caption;
    CGPoint _panOffset;
    CADisplayLink *_dragRedrawDisplayLink;
    BOOL _loggedRenderCallback;
    BOOL _loggedUniforms;
    BOOL _rendererReady;
    NSMutableDictionary<NSString *, NSNumber *> *_earlyReturnCounts;
    uint64_t _textureDeliveryCount;
    uint64_t _metalRedrawCount;
    NSTimeInterval _backdropTextureReceivedAt; // for texture-age-at-render logging
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;
    self.layer.cornerRadius = 28.0;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.32;
    self.layer.shadowRadius = 16.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 8.0);

    _device = [LGIOS12LiveBackdropProvider sharedProvider].device;
    LGIOS12Log(@"Metal device creation success=%d device=%@",
               _device != nil, _device.name ?: @"nil");
    if (!_device) return self;

    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = YES;
    id<MTLLibrary> library = [_device newLibraryWithSource:kLGIOS12LiveMetalSource
                                                   options:options error:&error];
    LGIOS12Log(@"shader load success=%d error=%@",
               library != nil, error.localizedDescription ?: @"none");
    if (!library) return self;

    id<MTLFunction> computeFunction =
        [library newFunctionWithName:
            LGIOS12DiagRawDisplay() ? @"rawBackdropIOS12" : @"liquidGlassIOS12"];
    _computePipeline = computeFunction
        ? [_device newComputePipelineStateWithFunction:computeFunction error:&error]
        : nil;
    LGIOS12Log(@"DIAG kernel selected=%@ mode=%ld pipeline=%d",
               LGIOS12DiagRawDisplay() ? @"rawBackdropIOS12(no-glass-shader)"
                                        : @"liquidGlassIOS12(normal)",
               (long)LGIOS12CurrentDiagMode(), _computePipeline != nil);
    _metalView = [[MTKView alloc] initWithFrame:self.bounds device:_device];
    _metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
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

    id<MTLFunction> vertex = [library newFunctionWithName:@"presentVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"presentFragment"];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = _metalView.colorPixelFormat;
    descriptor.colorAttachments[0].blendingEnabled = YES;
    descriptor.colorAttachments[0].sourceRGBBlendFactor =
        MTLBlendFactorSourceAlpha;
    descriptor.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    descriptor.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    _presentPipeline = (vertex && fragment)
        ? [_device newRenderPipelineStateWithDescriptor:descriptor error:&error]
        : nil;
    _commandQueue = [_device newCommandQueue];
    LGIOS12Log(@"pipeline creation compute=%d present=%d queue=%d error=%@",
               _computePipeline != nil, _presentPipeline != nil,
               _commandQueue != nil, error.localizedDescription ?: @"none");
    if (!_computePipeline || !_presentPipeline || !_commandQueue) return self;

    [self addSubview:_metalView];
    _caption = [[UILabel alloc] initWithFrame:CGRectMake(12.0,
        CGRectGetHeight(self.bounds) - 31.0,
        CGRectGetWidth(self.bounds) - 24.0, 21.0)];
    _caption.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleTopMargin;
    _caption.text = @"iOS 12 Metal Glass Test";
    _caption.textAlignment = NSTextAlignmentCenter;
    _caption.textColor = UIColor.whiteColor;
    _caption.font = [UIFont boldSystemFontOfSize:11.0];
    _caption.layer.shadowColor = UIColor.blackColor.CGColor;
    _caption.layer.shadowOpacity = 0.8;
    _caption.layer.shadowRadius = 2.0;
    _caption.layer.shadowOffset = CGSizeZero;
    [self addSubview:_caption];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
    self.hidden = YES;
    [[LGIOS12LiveBackdropProvider sharedProvider] registerClient:self];
    [[LGIOS12LiveBackdropProvider sharedProvider] registerGlassViewForExclusion:self];
    return self;
}


- (BOOL)rendererReady { return _rendererReady; }
- (BOOL)metalInitialized { return _computePipeline && _presentPipeline && _commandQueue; }

- (void)willMoveToWindow:(UIWindow *)newWindow {
    if (!newWindow) {
        [_dragRedrawDisplayLink invalidate];
        _dragRedrawDisplayLink = nil;
        LGIOS12LiveBackdropProvider *provider =
            [LGIOS12LiveBackdropProvider sharedProvider];
        [provider setClient:self requestsContinuousRefresh:NO];
        [provider unregisterGlassViewForExclusion:self];
        [provider unregisterClient:self];
    }
    [super willMoveToWindow:newWindow];
}

- (void)updateContinuousRefreshState {
    BOOL visible = self.window != nil && !self.hidden && self.alpha > 0.01 &&
                   self.metalInitialized;
    [[LGIOS12LiveBackdropProvider sharedProvider]
        setClient:self requestsContinuousRefresh:visible];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        LGIOS12LiveBackdropProvider *provider =
            [LGIOS12LiveBackdropProvider sharedProvider];
        [provider registerClient:self];
        [provider registerGlassViewForExclusion:self];
    }
    [self updateContinuousRefreshState];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    if (hidden) {
        [_dragRedrawDisplayLink invalidate];
        _dragRedrawDisplayLink = nil;
    }
    [self updateContinuousRefreshState];
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    if (alpha <= 0.01) {
        [_dragRedrawDisplayLink invalidate];
        _dragRedrawDisplayLink = nil;
    }
    [self updateContinuousRefreshState];
}

- (void)logMetalEarlyReturn:(NSString *)reason {
    if (!reason.length) return;
    if (!_earlyReturnCounts) _earlyReturnCounts = [NSMutableDictionary dictionary];
    uint64_t count = [_earlyReturnCounts[reason] unsignedLongLongValue] + 1;
    _earlyReturnCounts[reason] = @(count);
    if (LGIOS12ShouldLogSequence(count)) {
        LGIOS12Log(@"render early-return reason=%@ count=%llu rendererReady=%d attached=%d hidden=%d alpha=%.3f",
                   reason, (unsigned long long)count, _rendererReady,
                   self.window != nil, self.hidden, self.alpha);
    }
}


- (void)providerDidUpdateBackdropTexture:(id<MTLTexture>)texture source:(NSString *)source {
    if (!texture) return;
    if (texture.device != _device) {
        LGIOS12Log(@"MTLTexture rejected: device mismatch (texture device=%@, renderer device=%@)", texture.device.name ?: @"nil", _device.name ?: @"nil");
        return;
    }
    _backdropTexture = texture;
    _backdropTextureReceivedAt = CACurrentMediaTime();
    _rendererReady = _computePipeline && _presentPipeline && _commandQueue && _backdropTexture != nil;
    if (_rendererReady && self.hidden) {
        self.hidden = NO;
    }
    uint64_t delivery = ++_textureDeliveryCount;
    if (LGIOS12ShouldLogSequence(delivery)) {
        LGIOS12Log(@"texture delivery=%llu acquired=1 source=%@ dimensions=%lux%lu format=%lu usage=%lu attached=%d hidden=%d",
                   (unsigned long long)delivery, source,
                   (unsigned long)texture.width,
                   (unsigned long)texture.height,
                   (unsigned long)texture.pixelFormat,
                   (unsigned long)texture.usage,
                   self.window != nil, self.hidden);
    }
    [_metalView draw];
}

- (void)providerDidFailToUpdateBackdrop:(NSError *)error {
    LGIOS12Log(@"MTLTexture acquired success=0 error=%@", error.localizedDescription ?: @"unknown");
}


- (void)layoutSubviews {
    [super layoutSubviews];
    _metalView.frame = self.bounds;
    _metalView.layer.cornerRadius = self.layer.cornerRadius;
    [_metalView draw];
}


- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self.superview];
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        _panOffset = CGPointMake(point.x - self.center.x,
                                 point.y - self.center.y);
        if (!_dragRedrawDisplayLink) {
            _dragRedrawDisplayLink = [CADisplayLink displayLinkWithTarget:self
                selector:@selector(dragRedrawDisplayLinkFired:)];
            [_dragRedrawDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                                         forMode:NSRunLoopCommonModes];
            LGIOS12Log(@"drag redraw loop=start captureRate=provider-adaptive renderRate=display-link");
        }
    } else if (recognizer.state == UIGestureRecognizerStateChanged) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.center = CGPointMake(point.x - _panOffset.x,
                                  point.y - _panOffset.y);
        [CATransaction commit];
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        [_dragRedrawDisplayLink invalidate];
        _dragRedrawDisplayLink = nil;
        LGIOS12Log(@"drag redraw loop=stop finalRefresh=YES");
        [[LGIOS12LiveBackdropProvider sharedProvider] requestRefresh];
        [_metalView draw];
    }
}

- (void)dragRedrawDisplayLinkFired:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (_rendererReady && self.window && !self.hidden && self.alpha > 0.01) {
        // Reuse the latest full-screen provider texture while cardOrigin is
        // recomputed from the current screen-space frame every display tick.
        // This never requests a full SpringBoard hierarchy capture.
        [_metalView draw];
    }
}


- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _outputTexture = nil;
}

- (void)drawInMTKView:(MTKView *)view {
    // Feeds the redraw-rate and texture-age halves of the instrumentation.
    // Two clock reads; safe to leave on in mode 0.
    [[LGIOS12LiveBackdropProvider sharedProvider] noteClientRedraw];
    if (!_rendererReady) {
        [self logMetalEarlyReturn:@"renderer-not-ready"];
        return;
    }
    if (!_backdropTexture) {
        [self logMetalEarlyReturn:@"backdrop-texture-missing"];
        return;
    }
    if (CGRectIsEmpty(self.bounds)) {
        [self logMetalEarlyReturn:@"metal-view-bounds-empty"];
        return;
    }
    if (!_loggedRenderCallback) {
        _loggedRenderCallback = YES;
        LGIOS12Log(@"custom render callback executed backend=legacy callback=drawInMTKView");
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *renderPass = view.currentRenderPassDescriptor;
    if (!drawable || !renderPass) {
        if (!drawable) [self logMetalEarlyReturn:@"no-current-drawable"];
        if (!renderPass) [self logMetalEarlyReturn:@"no-render-pass-descriptor"];
        return;
    }
    NSUInteger width = MAX((NSUInteger)1, (NSUInteger)llround(view.drawableSize.width));
    NSUInteger height = MAX((NSUInteger)1, (NSUInteger)llround(view.drawableSize.height));
    if (!_outputTexture || _outputTexture.width != width ||
        _outputTexture.height != height) {
        MTLTextureDescriptor *outputDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        outputDescriptor.usage = MTLTextureUsageShaderRead |
                                 MTLTextureUsageShaderWrite;
        _outputTexture = [_device newTextureWithDescriptor:outputDescriptor];
        LGIOS12Log(@"output texture allocation success=%d dimensions=%lux%lu",
                   _outputTexture != nil, (unsigned long)width,
                   (unsigned long)height);
    }
    if (!_outputTexture) {
        [self logMetalEarlyReturn:@"output-texture-allocation-failed"];
        return;
    }

    CGRect screenRect = [self convertRect:self.bounds toView:nil];
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;
    LGIOS12LiveUniforms uniforms = {
        .outputResolution = { (float)width, (float)height },
        .sourceResolution = { (float)_backdropTexture.width,
                              (float)_backdropTexture.height },
        .cardOrigin = { (float)(CGRectGetMinX(screenRect) * screenScale),
                        (float)(CGRectGetMinY(screenRect) * screenScale) },
        .radius = (float)(self.layer.cornerRadius * screenScale),
        .bezelWidth = (float)(34.0 * screenScale),
        .glassThickness = 18.0f,
        .refractionScale = 2.2f,
        .refractiveIndex = 1.55f,
        .blurRadius = (float)(7.0 * screenScale),
        .specularOpacity = 0.72f,
        .specularAngle = (float)M_PI_4,
        .tintColor = { 0.06f, 0.06f, 0.06f, 0.16f }
    };

    if (!_loggedUniforms) {
        _loggedUniforms = YES;
        LGIOS12Log(@"shader uniforms output={%.0f,%.0f} backdrop={%.0f,%.0f} cardOrigin={%.0f,%.0f} radius=%.2f bezel=%.2f thickness=%.2f refractionScale=%.2f refractiveIndex=%.2f blurRadius=%.2f specularOpacity=%.2f specularAngle=%.4f tintRGBA={0.06,0.06,0.06,0.16}",
                   uniforms.outputResolution.x,
                   uniforms.outputResolution.y,
                   uniforms.sourceResolution.x,
                   uniforms.sourceResolution.y,
                   uniforms.cardOrigin.x, uniforms.cardOrigin.y,
                   uniforms.radius, uniforms.bezelWidth,
                   uniforms.glassThickness, uniforms.refractionScale,
                   uniforms.refractiveIndex, uniforms.blurRadius,
                   uniforms.specularOpacity, uniforms.specularAngle);
    }

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!commandBuffer) {
        [self logMetalEarlyReturn:@"command-buffer-allocation-failed"];
        return;
    }
    id<MTLComputeCommandEncoder> compute =
        [commandBuffer computeCommandEncoder];
    if (!compute) {
        [self logMetalEarlyReturn:@"compute-encoder-allocation-failed"];
        return;
    }
    [compute setComputePipelineState:_computePipeline];
    [compute setTexture:_backdropTexture atIndex:0];
    [compute setTexture:_outputTexture atIndex:1];
    [compute setBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    MTLSize threads = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((width + 7) / 8, (height + 7) / 8, 1);
    [compute dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [compute endEncoding];

    id<MTLRenderCommandEncoder> present =
        [commandBuffer renderCommandEncoderWithDescriptor:renderPass];
    if (!present) {
        [self logMetalEarlyReturn:@"render-encoder-allocation-failed"];
        return;
    }
    [present setRenderPipelineState:_presentPipeline];
    [present setFragmentTexture:_outputTexture atIndex:0];
    [present drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [present endEncoding];
    [commandBuffer presentDrawable:drawable];

    uint64_t redraw = ++_metalRedrawCount;
    BOOL shouldLogRedraw = LGIOS12ShouldLogSequence(redraw);
    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !shouldLogRedraw) return;
        LGIOS12Log(@"Metal redraw=%llu compute dispatch completed status=%ld completed=%d error=%@",
                   (unsigned long long)redraw, (long)completed.status,
                   completed.status == MTLCommandBufferStatusCompleted,
                   completed.error.localizedDescription ?: @"none");
        dispatch_async(dispatch_get_main_queue(), ^{
            LGIOS12Log(@"result submitted view=%@ superview=%@ window=%@ hidden=%d alpha=%.3f frame=%@ z=%.1f visualConfirmationRequired=YES",
                       NSStringFromClass(self.class),
                       NSStringFromClass(self.superview.class),
                       NSStringFromClass(self.window.class), self.hidden,
                       self.alpha, NSStringFromCGRect(self.frame),
                       self.layer.zPosition);
        });
    }];
    [commandBuffer commit];
    if (shouldLogRedraw) {
        NSTimeInterval textureAgeMs = _backdropTextureReceivedAt > 0.0
            ? (CACurrentMediaTime() - _backdropTextureReceivedAt) * 1000.0 : -1.0;
        LGIOS12Log(@"Metal redraw=%llu compute dispatch encoded groups={%lu,%lu} threads={8,8} "
                   "cardOrigin={%.0f,%.0f} backdropTextureAge=%.1fms",
                   (unsigned long long)redraw,
                   (unsigned long)groups.width, (unsigned long)groups.height,
                   uniforms.cardOrigin.x, uniforms.cardOrigin.y, textureAgeMs);
    }
}

@end

static LGIOS12FloatingGlassTestView *sLGIOS12TestView;
static LGIOS12StandaloneOverlayWindow *sLGIOS12OverlayWindow;
static LGIOS12ForegroundProbeView *sLGIOS12ProbeView;
static LGIOS12PerfHUDView *sLGIOS12PerfHUD;

static void LGIOS12LogLiveCAFilterStages(void) {
    // QuartzCore itself is loaded because CALayer is live.  Every deeper stage
    // is intentionally left untouched until an iOS 12 binary is available for
    // independent signature/layout recovery.
    LGIOS12Log(@"QuartzCore loaded status=%d CALayer=%@",
               NSClassFromString(@"CALayer") != Nil,
               NSStringFromClass(NSClassFromString(@"CALayer")));
    LGIOS12Log(@"filter_table resolved status=NOT_ATTEMPTED reason=unverified-iOS12-QuartzCore-layout");
    LGIOS12Log(@"add_filter resolved status=NOT_ATTEMPTED reason=unverified-iOS12-signature");
    LGIOS12Log(@"gaussian context resolved status=NOT_ATTEMPTED reason=unverified-iOS12-layout");
    LGIOS12Log(@"render vtable slot resolved status=NOT_ATTEMPTED reason=unverified-iOS12-vtable");
    LGIOS12Log(@"MetalContext resolved status=NOT_ATTEMPTED reason=unverified-iOS12-layout");
    LGIOS12Log(@"custom CAFilter registered status=NO backend=legacy-snapshot");
    LGIOS12Log(@"SpringBoard created custom filter status=NO backend=legacy-snapshot");
    LGIOS12Log(@"custom CAFilter render callback executed status=NO backend=legacy-snapshot");
}


static void LGIOS12RemoveTestSurface(void) {
    [sLGIOS12ProbeView stopProbing];
    [sLGIOS12ProbeView removeFromSuperview];
    sLGIOS12ProbeView = nil;
    [sLGIOS12PerfHUD stopSampling];
    [sLGIOS12PerfHUD removeFromSuperview];
    sLGIOS12PerfHUD = nil;
    if (sLGIOS12TestView) {
        LGIOS12Log(@"remove test surface view=%@ superview=%@ overlay=%@",
                   sLGIOS12TestView, sLGIOS12TestView.superview,
                   sLGIOS12OverlayWindow);
        LGIOS12LiveBackdropProvider *provider =
            [LGIOS12LiveBackdropProvider sharedProvider];
        [provider setClient:sLGIOS12TestView requestsContinuousRefresh:NO];
        [provider unregisterGlassViewForExclusion:sLGIOS12TestView];
        [provider unregisterClient:sLGIOS12TestView];
        sLGIOS12TestView.hidden = YES;
        [sLGIOS12TestView removeFromSuperview];
        sLGIOS12TestView = nil;
    }
    sLGIOS12OverlayWindow.hidden = YES;
    sLGIOS12OverlayWindow.rootViewController = nil;
    sLGIOS12OverlayWindow = nil;
}

static LGIOS12StandaloneOverlayWindow *
LGIOS12EnsureStandaloneOverlayWindow(UIWindow *hostWindow) {
    if (!hostWindow) return nil;
    if (!sLGIOS12OverlayWindow) {
        sLGIOS12OverlayWindow = [[LGIOS12StandaloneOverlayWindow alloc]
            initWithFrame:UIScreen.mainScreen.bounds];
        sLGIOS12OverlayWindow.backgroundColor = UIColor.clearColor;
        sLGIOS12OverlayWindow.opaque = NO;

        UIViewController *rootController = [UIViewController new];
        rootController.view.backgroundColor = UIColor.clearColor;
        rootController.view.opaque = NO;
        rootController.view.frame = sLGIOS12OverlayWindow.bounds;
        rootController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                               UIViewAutoresizingFlexibleHeight;
        sLGIOS12OverlayWindow.rootViewController = rootController;
    }
    sLGIOS12OverlayWindow.frame = UIScreen.mainScreen.bounds;
    sLGIOS12OverlayWindow.windowLevel = hostWindow.windowLevel + 1.0;
    sLGIOS12OverlayWindow.hidden = NO;
    LGIOS12Log(@"standalone overlay ready class=%@ hostClass=%@ hostLevel=%.1f overlayLevel=%.1f separateOverlay=YES key=%d",
               NSStringFromClass(sLGIOS12OverlayWindow.class),
               NSStringFromClass(hostWindow.class), hostWindow.windowLevel,
               sLGIOS12OverlayWindow.windowLevel,
               sLGIOS12OverlayWindow.isKeyWindow);
    return sLGIOS12OverlayWindow;
}
static void LGIOS12InstallOrUpdateTestSurface(void) {
    if (!LGIsIOS12() || !LGIsSpringBoardProcess()) return;

    // MODE F (PROVIDER_OFF) control build: the standalone glass and its
    // provider never start. Every other LiquidAss hook is untouched. If the
    // whole-screen ghost rectangles still appear while swiping pages in this
    // mode, they are pre-existing LiquidAss behavior and have nothing to do
    // with the live-backdrop provider.
    if (LGIOS12CurrentDiagMode() == 6) {
        LGIOS12Log(@"DIAG MODE 6 PROVIDER_OFF: standalone glass/provider disabled. "
                   "All other LiquidAss hooks unchanged. Swipe pages now -- if the "
                   "rounded-rectangle corruption still occurs, the provider is not "
                   "the cause.");
        LGIOS12RemoveTestSurface();
        return;
    }

    LGReloadPreferences();
    BOOL enabled = LG_prefBool(@"Global.Enabled", NO);
    LGIOS12Log(@"LiquidAss: enabled=%@, liquidGlass=%@, iOS12 renderer selected backend=legacy-snapshot-metal",
               enabled ? @"YES" : @"NO", enabled ? @"YES" : @"NO");
    if (!enabled) {
        LGIOS12RemoveTestSurface();
        return;
    }

    UIWindow *hostWindow = LGIOS12SpringBoardHostWindow();
    LGIOS12Log(@"host lookup class=%@ found=%d frame=%@ hidden=%d alpha=%.3f",
               NSStringFromClass(hostWindow.class), hostWindow != nil,
               hostWindow ? NSStringFromCGRect(hostWindow.frame) : @"(null)",
               hostWindow.hidden, hostWindow.alpha);
    if (!hostWindow) return;

    if (sLGIOS12TestView) {
        sLGIOS12OverlayWindow.hidden = NO;
        [sLGIOS12TestView updateContinuousRefreshState];
        [[LGIOS12LiveBackdropProvider sharedProvider] requestRefresh];
        return;
    }

    LGIOS12StandaloneOverlayWindow *overlayWindow =
        LGIOS12EnsureStandaloneOverlayWindow(hostWindow);
    UIView *overlayRootView = overlayWindow.rootViewController.view;
    if (!overlayWindow || !overlayRootView) {
        LGIOS12Log(@"standalone install aborted reason=overlay-window-init-failed stockUI=untouched");
        return;
    }

    CGFloat side = MIN(220.0, MIN(CGRectGetWidth(hostWindow.bounds) - 36.0,
                                  CGRectGetHeight(hostWindow.bounds) * 0.34));
    side = MAX(side, 150.0);
    CGRect frame = CGRectMake((CGRectGetWidth(hostWindow.bounds) - side) * 0.5,
                              CGRectGetHeight(hostWindow.bounds) * 0.28,
                              side, side);
    LGIOS12FloatingGlassTestView *test =
        [[LGIOS12FloatingGlassTestView alloc] initWithFrame:frame];

    LGIOS12Log(@"LiquidGlassView allocation class=%@ success=%d frame=%@ metalInitialized=%d",
               NSStringFromClass(test.class), test != nil,
               NSStringFromCGRect(frame), test.metalInitialized);
    if (!test || !test.metalInitialized) {
        LGIOS12Log(@"standalone install aborted reason=renderer-init-failed stockUI=untouched");
        overlayWindow.hidden = YES;
        sLGIOS12OverlayWindow = nil;
        return;
    }

    test.layer.zPosition = 10000.0;
    [overlayRootView addSubview:test];
    sLGIOS12TestView = test;
    // The view starts hidden during construction so it cannot enter an early
    // source capture.  Once attached to its separate overlay, make it visible
    // and let its client lifecycle keep the provider alive even if the first
    // texture upload needs to retry.
    test.hidden = NO;
    LGIOS12Log(@"addSubview complete view=%@ superview=%@ window=%@ hostWindow=%@ separateOverlay=%d hidden=%d alpha=%.3f frame=%@ z=%.1f",
               test, NSStringFromClass(test.superview.class),
               NSStringFromClass(test.window.class),
               NSStringFromClass(hostWindow.class),
               test.window == overlayWindow, test.hidden, test.alpha,
               NSStringFromCGRect(test.frame), test.layer.zPosition);
    [test setNeedsLayout];
    [test layoutIfNeeded];

    // ON-SCREEN FOREGROUND PROBE -- MODE 7 ONLY.
    //
    // This panel did its job: it established on device that icon pixels are
    // obtainable and that composition works. It is diagnostic apparatus, not
    // product, so it is now strictly gated behind the diagnostic mode that
    // owns it. Mode 0 is normal Liquid Glass and nothing else: no panel, no
    // enlarged icon, no mechanism thumbnails, no debug text, no labels. (The
    // magenta foreground outline is likewise confined to modes 3 and 7, and
    // the raw-source shader to modes 1-4 and 7, so neither can reach mode 0.)
    //
    // It was previously on by default, which is what covered the glass card.
    // The card itself was always being created -- it was hidden behind the
    // panel, not replaced by it.
    if (LGIOS12CurrentDiagMode() == 7) {
        CGFloat probeWidth = MIN(340.0, CGRectGetWidth(hostWindow.bounds) - 16.0);
        CGFloat probeHeight = MIN(430.0, CGRectGetHeight(hostWindow.bounds) - 80.0);
        CGRect probeFrame = CGRectMake(
            (CGRectGetWidth(hostWindow.bounds) - probeWidth) * 0.5,
            MAX(30.0, CGRectGetHeight(hostWindow.bounds) * 0.06),
            probeWidth, probeHeight);
        LGIOS12ForegroundProbeView *probe =
            [[LGIOS12ForegroundProbeView alloc] initWithFrame:probeFrame];
        probe.layer.zPosition = 20000.0;   // above the glass card
        [overlayRootView addSubview:probe];
        sLGIOS12ProbeView = probe;
        [probe startProbing];
        LGIOS12Log(@"visual foreground probe installed (MODE 7 ONLY) frame=%@ window=%@",
                   NSStringFromCGRect(probeFrame),
                   NSStringFromClass(probe.window.class));
    }

    // MODE 9 PERF HUD. Same gating discipline as the mode 7 probe: diagnostic
    // surfaces exist only in the mode that owns them, never in mode 0.
    if (LGIOS12CurrentDiagMode() == 9) {
        CGFloat hudWidth = MIN(320.0, CGRectGetWidth(hostWindow.bounds) - 16.0);
        CGRect hudFrame = CGRectMake(
            (CGRectGetWidth(hostWindow.bounds) - hudWidth) * 0.5,
            MAX(28.0, CGRectGetHeight(hostWindow.bounds) * 0.05),
            hudWidth, 268.0);
        LGIOS12PerfHUDView *hud = [[LGIOS12PerfHUDView alloc] initWithFrame:hudFrame];
        hud.layer.zPosition = 20000.0;
        [overlayRootView addSubview:hud];
        sLGIOS12PerfHUD = hud;
        [hud startSampling];
        LGIOS12Log(@"perf HUD installed (MODE 9 ONLY) frame=%@",
                   NSStringFromCGRect(hudFrame));
    }

    // Surface census. Confirms from the device itself that mode 0 puts exactly
    // one thing on screen -- the Liquid Glass card -- and that the probe panel
    // is absent rather than merely moved.
    LGIOS12Log(@"surface census mode=%ld glassCard=%d glassCardVisible=%d "
               "glassShader=%@ probePanel=%d overlaySubviews=%lu",
               (long)LGIOS12CurrentDiagMode(),
               sLGIOS12TestView != nil,
               sLGIOS12TestView != nil && !sLGIOS12TestView.hidden,
               LGIOS12DiagRawDisplay() ? @"rawBackdropIOS12" : @"liquidGlassIOS12",
               sLGIOS12ProbeView != nil,
               (unsigned long)overlayRootView.subviews.count);
    (void)sLGIOS12PerfHUD;
}


static void LGIOS12TestPrefsReloaded(CFNotificationCenterRef center,
                                     void *observer, CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        LGIOS12Log(@"preference reload notification received name=%@",
                   (__bridge NSString *)name);
        LGIOS12InstallOrUpdateTestSurface();
    });
}

__attribute__((constructor))
static void LGIOS12StandaloneTestInit(void) {
    @autoreleasepool {
        if (!LGIsIOS12() || !LGIsSpringBoardProcess()) return;
        LGIOS12Log(@"standalone constructor entered process=%@",
                   LGMainBundleIdentifier());
        LGIOS12LogLiveCAFilterStages();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            LGIOS12TestPrefsReloaded, kLGIOS12PrefsReloadNotification,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LGIOS12InstallOrUpdateTestSurface();
        });
    }
}
