#import "LGSharedSupport.h"
#import "LGIOS12MetalShader.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>
#import <math.h>
#import <stdarg.h>

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
    LGDiagnosticLog(@"%@ %@", kLGIOS12DiagnosticsPrefix, message);
}

static UIWindow *LGIOS12SpringBoardHostWindow(void) {
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

static NSString * const kLGIOS12LiveMetalSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Uniforms {\n"
"  float2 outputResolution; float2 sourceResolution; float2 cardOrigin;\n"
"  float radius; float bezelWidth; float glassThickness; float refractionScale;\n"
"  float refractiveIndex; float blurRadius; float specularOpacity; float specularAngle;\n"
"};\n"
"float surfaceConvexSquircle(float x) { return pow(1.0-pow(1.0-x,4.0),0.25); }\n"
"float2 refractRay(float2 normal,float eta) {\n"
"  float cosI=-normal.y; float k=1.0-eta*eta*(1.0-cosI*cosI);\n"
"  if(k<0.0) return float2(0.0); float root=sqrt(k);\n"
"  return float2(-(eta*cosI+root)*normal.x, eta-(eta*cosI+root)*normal.y);\n"
"}\n"
"float rawRefraction(float ratio,float thickness,float bezel,float eta) {\n"
"  float x=clamp(ratio,0.05,0.95); float y=surfaceConvexSquircle(x);\n"
"  float derivative=(surfaceConvexSquircle(x+0.001)-y)/0.001;\n"
"  float magnitude=sqrt(derivative*derivative+1.0);\n"
"  float2 ray=refractRay(float2(-derivative/magnitude,-1.0/magnitude),eta);\n"
"  if(length(ray)<0.0001 || abs(ray.y)<0.0001) return 0.0;\n"
"  return ray.x*(y*bezel+thickness)/ray.y;\n"
"}\n"
"float displacement(float ratio,float thickness,float bezel,float eta) {\n"
"  float peak=rawRefraction(0.05,thickness,bezel,eta);\n"
"  if(abs(peak)<0.0001) return 0.0;\n"
"  return (rawRefraction(ratio,thickness,bezel,eta)/peak)*(1.0-smoothstep(0.0,1.0,ratio));\n"
"}\n"
"kernel void liquidGlassIOS12(texture2d<float,access::sample> source [[texture(0)]],\n"
"                             texture2d<float,access::write> output [[texture(1)]],\n"
"                             constant Uniforms &u [[buffer(0)]],\n"
"                             uint2 gid [[thread_position_in_grid]]) {\n"
"  uint W=output.get_width(), H=output.get_height(); if(gid.x>=W || gid.y>=H) return;\n"
"  constexpr sampler s(filter::linear,address::clamp_to_edge);\n"
"  float2 px=float2(gid)+0.5; float2 halfSize=u.outputResolution*0.5;\n"
"  float radius=min(u.radius,min(halfSize.x,halfSize.y)); float2 p=px-halfSize;\n"
"  float2 q=abs(p)-(halfSize-float2(radius));\n"
"  float signedDistance=length(max(q,float2(0.0)))+min(max(q.x,q.y),0.0)-radius;\n"
"  float edgeAlpha=clamp(0.5-signedDistance,0.0,1.0);\n"
"  if(edgeAlpha<=0.0){ output.write(float4(0.0),gid); return; }\n"
"  float edgeDistance=max(0.0,-signedDistance); float2 innerHalf=max(halfSize-float2(radius),float2(0.0));\n"
"  float2 cornerDelta=p-clamp(p,-innerHalf,innerHalf); float2 dir;\n"
"  if(length(cornerDelta)>0.001) dir=normalize(cornerDelta);\n"
"  else { float dx=halfSize.x-abs(p.x), dy=halfSize.y-abs(p.y);\n"
"         dir=(dx<dy)?float2(p.x<0.0?-1.0:1.0,0.0):float2(0.0,p.y<0.0?-1.0:1.0); }\n"
"  float bezel=max(u.bezelWidth,1.0); float ratio=clamp(edgeDistance/bezel,0.0,1.0);\n"
"  float normDisp=edgeDistance<bezel?displacement(ratio,u.glassThickness,bezel,1.0/max(u.refractiveIndex,1.001)):0.0;\n"
"  float2 dispPx=-dir*normDisp*bezel*u.refractionScale;\n"
"  float2 sampleUV=clamp((u.cardOrigin+px+dispPx)/u.sourceResolution,0.0,1.0);\n"
"  float2 texel=1.0/u.sourceResolution; float blurStep=max(1.0,u.blurRadius*0.35);\n"
"  float4 sharp=source.sample(s,sampleUV);\n"
"  float4 blurred=sharp*0.24;\n"
"  blurred+=source.sample(s,sampleUV+float2( blurStep,0.0)*texel)*0.11;\n"
"  blurred+=source.sample(s,sampleUV+float2(-blurStep,0.0)*texel)*0.11;\n"
"  blurred+=source.sample(s,sampleUV+float2(0.0, blurStep)*texel)*0.11;\n"
"  blurred+=source.sample(s,sampleUV+float2(0.0,-blurStep)*texel)*0.11;\n"
"  blurred+=source.sample(s,sampleUV+float2( blurStep, blurStep)*texel)*0.08;\n"
"  blurred+=source.sample(s,sampleUV+float2(-blurStep, blurStep)*texel)*0.08;\n"
"  blurred+=source.sample(s,sampleUV+float2( blurStep,-blurStep)*texel)*0.08;\n"
"  blurred+=source.sample(s,sampleUV+float2(-blurStep,-blurStep)*texel)*0.08;\n"
"  float4 color=mix(sharp,blurred,0.62);\n"
"  float2 lightDir=float2(cos(u.specularAngle),-sin(u.specularAngle));\n"
"  float stroke=clamp(1.0-edgeDistance/max(2.0,bezel*0.20),0.0,1.0);\n"
"  float lobe=pow(clamp(abs(dot(dir,lightDir)),0.0,1.0),7.0);\n"
"  float fresnel=pow(clamp(1.0-ratio,0.0,1.0),2.2);\n"
"  float highlight=(lobe*stroke*u.specularOpacity)+(fresnel*0.16);\n"
"  color.rgb=mix(color.rgb,float3(1.0),clamp(highlight,0.0,0.55));\n"
"  color.rgb=mix(color.rgb,color.rgb*0.94+float3(0.06),0.16);\n"
"  output.write(float4(color.rgb,edgeAlpha*0.96),gid);\n"
"}\n"
"struct PresentOut { float4 position [[position]]; float2 uv; };\n"
"vertex PresentOut presentVertex(uint vertexID [[vertex_id]]) {\n"
"  float2 positions[3]={float2(-1.0,-1.0),float2(3.0,-1.0),float2(-1.0,3.0)};\n"
"  float2 uvs[3]={float2(0.0,1.0),float2(2.0,1.0),float2(0.0,-1.0)};\n"
"  PresentOut out; out.position=float4(positions[vertexID],0.0,1.0); out.uv=uvs[vertexID]; return out;\n"
"}\n"
"fragment float4 presentFragment(PresentOut in [[stage_in]],\n"
"                                texture2d<float,access::sample> image [[texture(0)]]) {\n"
"  constexpr sampler s(filter::linear,address::clamp_to_edge); return image.sample(s,in.uv);\n"
"}\n";

#import "LGIOS12LiveBackdropProvider.h"

@interface LGIOS12FloatingGlassTestView : UIView <MTKViewDelegate, LGIOS12LiveBackdropClient>
@property (nonatomic, readonly) BOOL rendererReady;
@property (nonatomic, readonly) BOOL metalInitialized;
- (instancetype)initWithFrame:(CGRect)frame;
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
    BOOL _loggedRenderCallback;
    BOOL _loggedDispatchCompletion;
    BOOL _loggedUniforms;
    BOOL _rendererReady;
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
        [library newFunctionWithName:@"liquidGlassIOS12"];
    _computePipeline = computeFunction
        ? [_device newComputePipelineStateWithFunction:computeFunction error:&error]
        : nil;
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
    [[LGIOS12LiveBackdropProvider sharedProvider] registerClient:self];
    [[LGIOS12LiveBackdropProvider sharedProvider] registerGlassViewForExclusion:self];
    self.hidden = YES;
    return self;
}


- (BOOL)rendererReady { return _rendererReady; }
- (BOOL)metalInitialized { return _computePipeline && _presentPipeline && _commandQueue; }
- (void)dealloc {
    [[LGIOS12LiveBackdropProvider sharedProvider] unregisterClient:self];
    [[LGIOS12LiveBackdropProvider sharedProvider] unregisterGlassViewForExclusion:self];
}



- (void)providerDidUpdateBackdropTexture:(id<MTLTexture>)texture source:(NSString *)source {
    if (!texture) return;
    if (texture.device != _device) {
        LGIOS12Log(@"MTLTexture rejected: device mismatch (texture device=%@, renderer device=%@)", texture.device.name ?: @"nil", _device.name ?: @"nil");
        return;
    }
    _backdropTexture = texture;
    _rendererReady = _computePipeline && _presentPipeline && _commandQueue && _backdropTexture != nil;
    if (_rendererReady && self.hidden) {
        self.hidden = NO;
    }
    LGIOS12Log(@"MTLTexture acquired success=1 source=%@ dimensions=%lux%lu format=%lu usage=%lu",
               source, (unsigned long)texture.width,
               (unsigned long)texture.height,
               (unsigned long)texture.pixelFormat,
               (unsigned long)texture.usage);
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
        [[LGIOS12LiveBackdropProvider sharedProvider] setNeedsActiveRefresh:YES];
    } else if (recognizer.state == UIGestureRecognizerStateChanged) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.center = CGPointMake(point.x - _panOffset.x,
                                  point.y - _panOffset.y);
        [CATransaction commit];
        [_metalView draw];
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        [[LGIOS12LiveBackdropProvider sharedProvider] setNeedsActiveRefresh:NO];
        [[LGIOS12LiveBackdropProvider sharedProvider] requestRefresh];
    }
}


- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _outputTexture = nil;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_rendererReady || !_backdropTexture || CGRectIsEmpty(self.bounds)) return;
    if (!_loggedRenderCallback) {
        _loggedRenderCallback = YES;
        LGIOS12Log(@"custom render callback executed backend=legacy callback=drawInMTKView");
    }

    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *renderPass = view.currentRenderPassDescriptor;
    if (!drawable || !renderPass) {
        LGIOS12Log(@"render pass aborted drawable=%d descriptor=%d",
                   drawable != nil, renderPass != nil);
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
    if (!_outputTexture) return;

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
        LGIOS12Log(@"render pass aborted reason=command-buffer-allocation-failed");
        return;
    }
    id<MTLComputeCommandEncoder> compute =
        [commandBuffer computeCommandEncoder];
    if (!compute) {
        LGIOS12Log(@"render pass aborted reason=compute-encoder-allocation-failed");
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
        LGIOS12Log(@"render pass aborted reason=present-encoder-allocation-failed");
        return;
    }
    [present setRenderPipelineState:_presentPipeline];
    [present setFragmentTexture:_outputTexture atIndex:0];
    [present drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [present endEncoding];
    [commandBuffer presentDrawable:drawable];

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_loggedDispatchCompletion) return;
        self->_loggedDispatchCompletion = YES;
        LGIOS12Log(@"Metal compute dispatch executed status=%ld completed=%d error=%@",
                   (long)completed.status,
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
    LGIOS12Log(@"Metal compute dispatch encoded groups={%lu,%lu} threads={8,8} cardOrigin={%.0f,%.0f}",
               (unsigned long)groups.width, (unsigned long)groups.height,
               uniforms.cardOrigin.x, uniforms.cardOrigin.y);
}

@end

static LGIOS12FloatingGlassTestView *sLGIOS12TestView;

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
    if (!sLGIOS12TestView) return;
    LGIOS12Log(@"remove test surface view=%@ superview=%@",
               sLGIOS12TestView, sLGIOS12TestView.superview);
    [sLGIOS12TestView removeFromSuperview];
    sLGIOS12TestView = nil;
}



static void LGIOS12InstallOrUpdateTestSurface(void) {
    if (!LGIsIOS12() || !LGIsSpringBoardProcess()) return;
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
        [[LGIOS12LiveBackdropProvider sharedProvider] requestRefresh];
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
        return;
    }

    test.layer.zPosition = 10000.0;
    [hostWindow addSubview:test];
    sLGIOS12TestView = test;
    LGIOS12Log(@"addSubview complete view=%@ superview=%@ window=%@ hidden=%d alpha=%.3f frame=%@ z=%.1f",
               test, NSStringFromClass(test.superview.class),
               NSStringFromClass(test.window.class), test.hidden, test.alpha,
               NSStringFromCGRect(test.frame), test.layer.zPosition);
    [test setNeedsLayout];
    [test layoutIfNeeded];
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
