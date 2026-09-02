#import "LGIOS12MetalGlassView.h"
#import "LGSharedSupport.h"
#import "LGIOS12MetalShader.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>
#import <stdarg.h>

static void LGIOS12GlassLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void LGIOS12GlassLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    LGLog(@"renderer.ios12.glass %@", message);
}

static BOOL LGIOS12GlassShouldLogSequence(uint64_t sequence) {
    return sequence <= 3 || (sequence % 60) == 0;
}

#define LGIOS12Log LGIOS12GlassLog
#define LGIOS12ShouldLogSequence LGIOS12GlassShouldLogSequence

@implementation LGIOS12MetalGlassView {
    MTKView *_metalView;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLComputePipelineState> _computePipeline;
    id<MTLRenderPipelineState> _presentPipeline;
    id<MTLTexture> _backdropTexture;
    id<MTLTexture> _outputTexture;
    BOOL _loggedRenderCallback;
    BOOL _loggedUniforms;
    BOOL _rendererReady;
    NSMutableDictionary<NSString *, NSNumber *> *_earlyReturnCounts;
    uint64_t _textureDeliveryCount;
    uint64_t _metalRedrawCount;
    NSTimeInterval _backdropTextureReceivedAt;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    _glassCornerRadius = 28.0;          // the verified standalone value
    self.layer.cornerRadius = _glassCornerRadius;

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

    // Hidden until the first backdrop texture arrives, so no host ever shows
    // an empty black rectangle while the pipeline warms up. A host that needs
    // to keep its stock background until then can test -rendererReady.
    self.hidden = YES;
    [[LGIOS12LiveBackdropProvider sharedProvider] registerClient:self];
    [[LGIOS12LiveBackdropProvider sharedProvider] registerGlassViewForExclusion:self];
    return self;
}

- (BOOL)rendererReady { return _rendererReady; }
- (BOOL)metalInitialized { return _computePipeline && _presentPipeline && _commandQueue; }

- (void)setGlassCornerRadius:(CGFloat)radius {
    if (radius == _glassCornerRadius) return;
    _glassCornerRadius = radius;
    self.layer.cornerRadius = radius;
    _metalView.layer.cornerRadius = radius;
    [self redraw];
}

- (void)redraw {
    [_metalView draw];
}

// Subclass hook: called when the view is detached, hidden, or made
// transparent. The standalone card overrides this to tear down its drag
// display link; the generic renderer has nothing of its own to release.
- (void)glassDidBecomeInvisible {
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    if (!newWindow) {
        [self glassDidBecomeInvisible];
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
    if (hidden) [self glassDidBecomeInvisible];
    [self updateContinuousRefreshState];
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    if (alpha <= 0.01) [self glassDidBecomeInvisible];
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
    // QUALITY: the compute output is sized by the SHARED scale, not the
    // drawable. At HIGH this is exactly the drawable size, so the verified
    // configuration is unchanged. Below HIGH the compute pass does
    // proportionally less work and the existing present pass upscales the
    // result -- it already samples with filter::linear over normalized
    // coordinates, so no shader change is required.
    //
    // This must match the provider's capture scale: the kernel adds output
    // pixel coordinates directly to the source-space cardOrigin, so the two
    // spaces share one scale or refraction misaligns.
    CGFloat renderScale =
        [LGIOS12LiveBackdropProvider sharedProvider].effectiveCaptureScale;
    NSUInteger width = MAX((NSUInteger)1,
        (NSUInteger)llround(CGRectGetWidth(self.bounds) * renderScale));
    NSUInteger height = MAX((NSUInteger)1,
        (NSUInteger)llround(CGRectGetHeight(self.bounds) * renderScale));
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
    // Every screen-space uniform below uses the same shared scale as the
    // capture buffer and the output texture.
    CGFloat screenScale = renderScale;
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
