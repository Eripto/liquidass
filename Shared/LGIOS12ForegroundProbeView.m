#import "LGIOS12ForegroundProbeView.h"
#import "LGIOS12LiveBackdropProvider.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// Bitmap helpers. Every probe renders into a context with the SAME convention
// as the real capture context -- top-left origin, y-down, addressed in points
// -- so a result here transfers directly to the capture path. What differs is
// the extent: these bitmaps are the size of ONE icon's local bounds, so no
// screen conversion, card origin, or container geometry can influence the
// outcome. If an icon is blank here, it is blank at the source.
// ---------------------------------------------------------------------------

static CGContextRef LGIOS12ProbeCreateContext(CGSize pointSize, CGFloat scale) {
    size_t w = (size_t)MAX(1.0, llround(pointSize.width * scale));
    size_t h = (size_t)MAX(1.0, llround(pointSize.height * scale));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, scale, -scale);
    return ctx;
}

static NSUInteger LGIOS12ProbeCountOpaquePixels(CGContextRef ctx) {
    uint8_t *bytes = (uint8_t *)CGBitmapContextGetData(ctx);
    if (!bytes) return 0;
    size_t w = CGBitmapContextGetWidth(ctx);
    size_t h = CGBitmapContextGetHeight(ctx);
    size_t stride = CGBitmapContextGetBytesPerRow(ctx);
    NSUInteger count = 0;
    for (size_t y = 0; y < h; y++) {
        uint8_t *row = bytes + y * stride;
        for (size_t x = 0; x < w; x++) {
            if (row[x * 4 + 3] > 20) count++;   // host-order BGRA -> A last
        }
    }
    return count;
}

static UIImage *LGIOS12ProbeImageFromContext(CGContextRef ctx, CGFloat scale) {
    CGImageRef cgImage = CGBitmapContextCreateImage(ctx);
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage
                                          scale:scale
                                    orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

// Render one layer into the probe context, mapped from `sourceRect` (in the
// destination's local coordinate space) -- the same translate/scale the real
// capture path uses, with no added flip, because -renderInContext: works
// natively in this top-left-origin space.
static void LGIOS12ProbeRenderLayer(CALayer *layer, CGRect layerBounds,
                                     CGRect destRect, CGContextRef ctx) {
    if (!layer || !ctx || CGRectIsEmpty(destRect) || CGRectIsEmpty(layerBounds)) return;
    CGFloat scaleX = CGRectGetWidth(destRect) / CGRectGetWidth(layerBounds);
    CGFloat scaleY = CGRectGetHeight(destRect) / CGRectGetHeight(layerBounds);
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, CGRectGetMinX(destRect), CGRectGetMinY(destRect));
    CGContextScaleCTM(ctx, scaleX, scaleY);
    CGContextTranslateCTM(ctx, -CGRectGetMinX(layerBounds),
                          -CGRectGetMinY(layerBounds));
    [layer renderInContext:ctx];
    CGContextRestoreGState(ctx);
}

// CGContextDrawImage maps images bottom-up in the current CTM, so in this
// y-down space it would land mirrored. The local flip below cancels exactly
// that; it is scoped to one draw and never touches the shared CTM.
static void LGIOS12ProbeDrawImage(CGContextRef ctx, CGImageRef image, CGRect destRect) {
    if (!ctx || !image || CGRectIsEmpty(destRect)) return;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, CGRectGetMinX(destRect), CGRectGetMinY(destRect));
    CGContextTranslateCTM(ctx, 0, CGRectGetHeight(destRect));
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGRectGetWidth(destRect),
                                       CGRectGetHeight(destRect)), image);
    CGContextRestoreGState(ctx);
}

static CGImageRef LGIOS12ProbeCopyContentsImage(CALayer *layer) CF_RETURNS_RETAINED {
    id contents = layer.contents;
    if (!contents) return NULL;
    if (CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) return NULL;
    CGImageRef image = (CGImageRef)(__bridge CFTypeRef)contents;
    size_t pw = CGImageGetWidth(image), ph = CGImageGetHeight(image);
    if (pw == 0 || ph == 0) return NULL;
    CGRect cr = layer.contentsRect;
    if (CGRectIsEmpty(cr) || CGRectEqualToRect(cr, CGRectMake(0, 0, 1, 1))) {
        return CGImageRetain(image);
    }
    CGRect crop = CGRectMake(cr.origin.x * pw, cr.origin.y * ph,
                             cr.size.width * pw, cr.size.height * ph);
    CGImageRef cropped = CGImageCreateWithImageInRect(image, crop);
    return cropped ?: CGImageRetain(image);
}

// ---------------------------------------------------------------------------
// Live hierarchy inspection
// ---------------------------------------------------------------------------

static BOOL LGIOS12ProbeViewIsVisible(UIView *view) {
    return view && !view.hidden && view.alpha > 0.01 && !CGRectIsEmpty(view.bounds);
}

static BOOL LGIOS12ProbeIsIconView(UIView *view) {
    static Class iconClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ iconClass = NSClassFromString(@"SBIconView"); });
    if (iconClass && [view isKindOfClass:iconClass]) return YES;
    return [NSStringFromClass(view.class) isEqualToString:@"SBIconView"];
}

static void LGIOS12ProbeCollectIcons(UIView *view, NSMutableArray<UIView *> *out) {
    if (!LGIOS12ProbeViewIsVisible(view)) return;
    if (LGIOS12ProbeIsIconView(view)) { [out addObject:view]; return; }
    for (UIView *sub in view.subviews) LGIOS12ProbeCollectIcons(sub, out);
}

// Searches every visible window except our own overlay, so a wrong
// host-window guess can never masquerade as "no icons exist".
static NSArray<UIView *> *LGIOS12ProbeFindAllVisibleIcons(UIWindow *selfWindow) {
    NSMutableArray<UIView *> *icons = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window || window == selfWindow || window.hidden || window.alpha <= 0.01) continue;
        if ([NSStringFromClass(window.class)
                isEqualToString:@"LGIOS12StandaloneOverlayWindow"]) continue;
        LGIOS12ProbeCollectIcons(window.rootViewController.view ?: window, icons);
    }
    return icons;
}

static void LGIOS12ProbeCollectArtworkViews(UIView *view, NSUInteger depth,
                                             NSMutableArray<UIView *> *out) {
    if (!LGIOS12ProbeViewIsVisible(view) || depth == 0 || out.count >= 32) return;
    BOOL artwork = view.layer.contents != nil ||
                   [view isKindOfClass:UIImageView.class] ||
                   [view isKindOfClass:UILabel.class];
    if (artwork) { [out addObject:view]; return; }
    for (UIView *sub in view.subviews)
        LGIOS12ProbeCollectArtworkViews(sub, depth - 1, out);
}

static void LGIOS12ProbeCollectContentLayers(CALayer *layer, NSUInteger depth,
                                              NSMutableArray<CALayer *> *out) {
    if (!layer || layer.hidden || layer.opacity <= 0.01 || depth == 0 ||
        out.count >= 32 || CGRectIsEmpty(layer.bounds)) return;
    id contents = layer.contents;
    if (contents &&
        CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
        [out addObject:layer];
        return;
    }
    for (CALayer *sub in layer.sublayers)
        LGIOS12ProbeCollectContentLayers(sub, depth - 1, out);
}

// Compact description of what the icon subtree actually contains, so the
// on-screen report names real runtime classes rather than guessed ones.
static NSString *LGIOS12ProbeDescribeSubtree(UIView *icon) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIView *sub in icon.subviews) {
        [parts addObject:[NSString stringWithFormat:@"%@%@",
            NSStringFromClass(sub.class),
            sub.layer.contents ? @"*" : @""]];
        if (parts.count >= 4) break;
    }
    if (parts.count == 0) [parts addObject:@"(no subviews)"];
    return [parts componentsJoinedByString:@" "];
}

// ---------------------------------------------------------------------------

typedef struct {
    NSUInteger pixels;
    NSUInteger elements;
} LGIOS12ProbeOutcome;

@implementation LGIOS12ForegroundProbeView {
    UILabel *_titleLabel;
    UILabel *_verdictLabel;
    UIImageView *_heroImageView;
    UILabel *_heroCaption;
    NSArray<UIImageView *> *_thumbnailViews;
    NSArray<UILabel *> *_thumbnailCaptions;
    UILabel *_statusLabel;
    NSTimer *_timer;
    CGFloat _probeScale;
}

static NSArray<NSString *> *LGIOS12ProbeThumbnailTitles(void) {
    return @[ @"MODEL", @"PRESENTATION", @"SUBVIEWS", @"LAYER CONTENTS", @"FULL FG (RAW)" ];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _probeScale = UIScreen.mainScreen.scale ?: 2.0;
    self.userInteractionEnabled = NO;      // never steals touches from the card
    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.86];
    self.layer.cornerRadius = 12.0;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    self.clipsToBounds = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"iOS 12 FOREGROUND PROBE";
    _titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
    _titleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_titleLabel];

    _verdictLabel = [[UILabel alloc] init];
    _verdictLabel.font = [UIFont boldSystemFontOfSize:19.0];
    _verdictLabel.textColor = UIColor.whiteColor;
    _verdictLabel.textAlignment = NSTextAlignmentCenter;
    _verdictLabel.numberOfLines = 2;
    _verdictLabel.adjustsFontSizeToFitWidth = YES;
    _verdictLabel.minimumScaleFactor = 0.5;
    [self addSubview:_verdictLabel];

    // The hero: the first mechanism that produced pixels, blown up large.
    // Seeing a recognisable app icon here IS the milestone.
    _heroImageView = [[UIImageView alloc] init];
    _heroImageView.contentMode = UIViewContentModeScaleAspectFit;
    _heroImageView.layer.magnificationFilter = kCAFilterNearest;
    _heroImageView.layer.borderWidth = 1.0;
    _heroImageView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.5].CGColor;
    _heroImageView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    [self addSubview:_heroImageView];

    _heroCaption = [[UILabel alloc] init];
    _heroCaption.font = [UIFont boldSystemFontOfSize:11.0];
    _heroCaption.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0];
    _heroCaption.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_heroCaption];

    NSMutableArray<UIImageView *> *thumbs = [NSMutableArray array];
    NSMutableArray<UILabel *> *captions = [NSMutableArray array];
    for (NSString *title in LGIOS12ProbeThumbnailTitles()) {
        UIImageView *thumb = [[UIImageView alloc] init];
        thumb.contentMode = UIViewContentModeScaleAspectFit;
        thumb.layer.magnificationFilter = kCAFilterNearest;
        thumb.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        thumb.layer.borderWidth = 1.0;
        thumb.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        [self addSubview:thumb];
        [thumbs addObject:thumb];

        UILabel *caption = [[UILabel alloc] init];
        caption.font = [UIFont systemFontOfSize:8.0];
        caption.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        caption.textAlignment = NSTextAlignmentCenter;
        caption.numberOfLines = 2;
        caption.text = title;
        [self addSubview:caption];
        [captions addObject:caption];
    }
    _thumbnailViews = thumbs;
    _thumbnailCaptions = captions;

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:9.5]
        ?: [UIFont systemFontOfSize:9.5];
    _statusLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _statusLabel.numberOfLines = 0;
    [self addSubview:_statusLabel];

    _verdictLabel.text = @"PROBING…";
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat pad = 8.0;
    CGFloat y = 6.0;

    _titleLabel.frame = CGRectMake(pad, y, width - pad * 2, 14.0);
    y += 16.0;
    _verdictLabel.frame = CGRectMake(pad, y, width - pad * 2, 46.0);
    y += 50.0;

    CGFloat heroSide = 118.0;
    _heroImageView.frame = CGRectMake((width - heroSide) * 0.5, y, heroSide, heroSide);
    y += heroSide + 2.0;
    _heroCaption.frame = CGRectMake(pad, y, width - pad * 2, 14.0);
    y += 18.0;

    NSUInteger count = _thumbnailViews.count;
    CGFloat gap = 6.0;
    CGFloat thumbSide = (width - pad * 2 - gap * (count - 1)) / (CGFloat)count;
    thumbSide = MIN(thumbSide, 60.0);
    CGFloat totalWidth = thumbSide * count + gap * (count - 1);
    CGFloat x = (width - totalWidth) * 0.5;
    for (NSUInteger i = 0; i < count; i++) {
        _thumbnailViews[i].frame = CGRectMake(x, y, thumbSide, thumbSide);
        _thumbnailCaptions[i].frame = CGRectMake(x - 3.0, y + thumbSide + 1.0,
                                                 thumbSide + 6.0, 20.0);
        x += thumbSide + gap;
    }
    y += thumbSide + 23.0;

    _statusLabel.frame = CGRectMake(pad, y, width - pad * 2,
                                    MAX(0.0, CGRectGetHeight(self.bounds) - y - 4.0));
}

- (void)startProbing {
    [self stopProbing];
    // 2 Hz: fast enough to feel live on video, slow enough that the probe's
    // own bitmap work cannot be mistaken for the renderer's cost.
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                               target:self
                                             selector:@selector(runProbe)
                                             userInfo:nil
                                              repeats:YES];
    [self runProbe];
}

- (void)stopProbing {
    [_timer invalidate];
    _timer = nil;
}

- (void)dealloc {
    [_timer invalidate];
}

#pragma mark - The four mechanisms

// 1. MODEL -- what the capture path has always used.
- (UIImage *)captureModelLayerOfIcon:(UIView *)icon outcome:(LGIOS12ProbeOutcome *)outcome {
    CGContextRef ctx = LGIOS12ProbeCreateContext(icon.bounds.size, _probeScale);
    if (!ctx) return nil;
    LGIOS12ProbeRenderLayer(icon.layer, icon.bounds, icon.bounds, ctx);
    outcome->pixels = LGIOS12ProbeCountOpaquePixels(ctx);
    outcome->elements = 1;
    UIImage *image = LGIOS12ProbeImageFromContext(ctx, _probeScale);
    CGContextRelease(ctx);
    return image;
}

// 2. PRESENTATION -- the render-server-side copy of the tree. If the model
// layer is blank but this is not, the artwork exists only in the presentation
// tree and the capture path must read that instead.
- (UIImage *)capturePresentationLayerOfIcon:(UIView *)icon outcome:(LGIOS12ProbeOutcome *)outcome {
    CALayer *presentation = icon.layer.presentationLayer;
    if (!presentation) { outcome->pixels = 0; outcome->elements = 0; return nil; }
    CGContextRef ctx = LGIOS12ProbeCreateContext(icon.bounds.size, _probeScale);
    if (!ctx) return nil;
    LGIOS12ProbeRenderLayer(presentation, icon.bounds, icon.bounds, ctx);
    outcome->pixels = LGIOS12ProbeCountOpaquePixels(ctx);
    outcome->elements = 1;
    UIImage *image = LGIOS12ProbeImageFromContext(ctx, _probeScale);
    CGContextRelease(ctx);
    return image;
}

// 3. SUBVIEWS -- render artwork-bearing descendants individually, in the
// icon's own local space. Rendering the parent is explicitly NOT assumed to
// capture its children.
- (UIImage *)captureSubviewsOfIcon:(UIView *)icon outcome:(LGIOS12ProbeOutcome *)outcome {
    NSMutableArray<UIView *> *artwork = [NSMutableArray array];
    LGIOS12ProbeCollectArtworkViews(icon, 8, artwork);
    outcome->elements = artwork.count;
    if (artwork.count == 0) { outcome->pixels = 0; return nil; }

    CGContextRef ctx = LGIOS12ProbeCreateContext(icon.bounds.size, _probeScale);
    if (!ctx) return nil;
    for (UIView *sub in artwork) {
        CGRect dest = [sub convertRect:sub.bounds toView:icon];
        LGIOS12ProbeRenderLayer(sub.layer, sub.bounds, dest, ctx);
    }
    outcome->pixels = LGIOS12ProbeCountOpaquePixels(ctx);
    UIImage *image = LGIOS12ProbeImageFromContext(ctx, _probeScale);
    CGContextRelease(ctx);
    return image;
}

// 4. LAYER CONTENTS -- composite each layer's backing CGImage directly, with
// its own local transform. This is the mechanism that still works when
// -renderInContext: cannot replay render-server-backed contents.
- (UIImage *)captureLayerContentsOfIcon:(UIView *)icon outcome:(LGIOS12ProbeOutcome *)outcome {
    NSMutableArray<CALayer *> *layers = [NSMutableArray array];
    LGIOS12ProbeCollectContentLayers(icon.layer, 10, layers);
    outcome->elements = layers.count;
    if (layers.count == 0) { outcome->pixels = 0; return nil; }

    CGContextRef ctx = LGIOS12ProbeCreateContext(icon.bounds.size, _probeScale);
    if (!ctx) return nil;
    for (CALayer *layer in layers) {
        CGRect dest = (layer == icon.layer)
            ? icon.bounds
            : [layer convertRect:layer.bounds toLayer:icon.layer];
        CGImageRef image = LGIOS12ProbeCopyContentsImage(layer);
        if (!image) continue;
        LGIOS12ProbeDrawImage(ctx, image, dest);
        CGImageRelease(image);
    }
    outcome->pixels = LGIOS12ProbeCountOpaquePixels(ctx);
    UIImage *result = LGIOS12ProbeImageFromContext(ctx, _probeScale);
    CGContextRelease(ctx);
    return result;
}

// 5. FULL FOREGROUND (RAW) -- every visible icon composed at its real screen
// position into a screen-sized bitmap, no wallpaper and no glass shader. This
// is the next milestone rendered as evidence: if the single icon works but
// this is blank, the failure is composition, not capture.
- (UIImage *)captureFullForegroundRaw:(NSArray<UIView *> *)icons
                             mechanism:(NSString *)mechanism
                               outcome:(LGIOS12ProbeOutcome *)outcome {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat downscale = 0.25;   // whole screen, small: this is a thumbnail
    CGContextRef ctx = LGIOS12ProbeCreateContext(screen.size, downscale);
    if (!ctx) return nil;

    NSUInteger drawn = 0;
    for (UIView *icon in icons) {
        CGRect dest = [icon convertRect:icon.bounds toView:nil];
        if (CGRectIsEmpty(dest)) continue;
        if ([mechanism isEqualToString:@"LAYER CONTENTS"]) {
            NSMutableArray<CALayer *> *layers = [NSMutableArray array];
            LGIOS12ProbeCollectContentLayers(icon.layer, 10, layers);
            for (CALayer *layer in layers) {
                CGRect local = (layer == icon.layer)
                    ? icon.bounds
                    : [layer convertRect:layer.bounds toLayer:icon.layer];
                CGRect onScreen = CGRectMake(CGRectGetMinX(dest) + CGRectGetMinX(local),
                                             CGRectGetMinY(dest) + CGRectGetMinY(local),
                                             CGRectGetWidth(local),
                                             CGRectGetHeight(local));
                CGImageRef image = LGIOS12ProbeCopyContentsImage(layer);
                if (!image) continue;
                LGIOS12ProbeDrawImage(ctx, image, onScreen);
                CGImageRelease(image);
                drawn++;
            }
        } else if ([mechanism isEqualToString:@"SUBVIEWS"]) {
            NSMutableArray<UIView *> *artwork = [NSMutableArray array];
            LGIOS12ProbeCollectArtworkViews(icon, 8, artwork);
            for (UIView *sub in artwork) {
                CGRect onScreen = [sub convertRect:sub.bounds toView:nil];
                LGIOS12ProbeRenderLayer(sub.layer, sub.bounds, onScreen, ctx);
                drawn++;
            }
        } else if ([mechanism isEqualToString:@"PRESENTATION"]) {
            CALayer *presentation = icon.layer.presentationLayer;
            if (!presentation) continue;
            LGIOS12ProbeRenderLayer(presentation, icon.bounds, dest, ctx);
            drawn++;
        } else {
            LGIOS12ProbeRenderLayer(icon.layer, icon.bounds, dest, ctx);
            drawn++;
        }
    }
    outcome->elements = drawn;
    outcome->pixels = LGIOS12ProbeCountOpaquePixels(ctx);
    UIImage *result = LGIOS12ProbeImageFromContext(ctx, downscale);
    CGContextRelease(ctx);
    return result;
}

#pragma mark - Probe cycle

- (void)runProbe {
    NSArray<UIView *> *icons = LGIOS12ProbeFindAllVisibleIcons(self.window);

    // FAILURE CASE 1 -- nothing to capture from. Shown large; no log needed.
    if (icons.count == 0) {
        _verdictLabel.text = @"SBIconView SEARCH FAILED";
        _verdictLabel.textColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
        _heroImageView.image = nil;
        _heroCaption.text = @"no icon to capture";
        for (UIImageView *thumb in _thumbnailViews) thumb.image = nil;
        _statusLabel.text = @"SBIconView count=0\n"
                             "selected icon=(none)\n"
                             "searched every visible non-overlay window";
        return;
    }

    UIView *icon = icons.firstObject;
    LGIOS12ProbeOutcome model = {0}, presentation = {0}, subviews = {0},
                        contents = {0}, full = {0};

    UIImage *modelImage        = [self captureModelLayerOfIcon:icon outcome:&model];
    UIImage *presentationImage = [self capturePresentationLayerOfIcon:icon outcome:&presentation];
    UIImage *subviewsImage     = [self captureSubviewsOfIcon:icon outcome:&subviews];
    UIImage *contentsImage     = [self captureLayerContentsOfIcon:icon outcome:&contents];

    // Whichever single-icon mechanism actually produced artwork becomes the
    // hero and drives the full-foreground composition below.
    NSString *winner = nil;
    UIImage *heroImage = nil;
    NSUInteger heroPixels = 0;
    if (model.pixels > 0)              { winner = @"MODEL";          heroImage = modelImage;        heroPixels = model.pixels; }
    else if (presentation.pixels > 0)  { winner = @"PRESENTATION";   heroImage = presentationImage; heroPixels = presentation.pixels; }
    else if (subviews.pixels > 0)      { winner = @"SUBVIEWS";       heroImage = subviewsImage;     heroPixels = subviews.pixels; }
    else if (contents.pixels > 0)      { winner = @"LAYER CONTENTS"; heroImage = contentsImage;     heroPixels = contents.pixels; }

    UIImage *fullImage = [self captureFullForegroundRaw:icons
                                               mechanism:winner ?: @"MODEL"
                                                 outcome:&full];

    _heroImageView.image = heroImage;
    _heroCaption.text = winner
        ? [NSString stringWithFormat:@"%@ — %lu px (enlarged)", winner,
            (unsigned long)heroPixels]
        : @"no mechanism produced pixels";

    NSArray<UIImage *> *images = @[ modelImage ?: (id)NSNull.null,
                                    presentationImage ?: (id)NSNull.null,
                                    subviewsImage ?: (id)NSNull.null,
                                    contentsImage ?: (id)NSNull.null,
                                    fullImage ?: (id)NSNull.null ];
    NSArray<NSNumber *> *pixelCounts = @[ @(model.pixels), @(presentation.pixels),
                                          @(subviews.pixels), @(contents.pixels),
                                          @(full.pixels) ];
    NSArray<NSString *> *titles = LGIOS12ProbeThumbnailTitles();
    for (NSUInteger i = 0; i < _thumbnailViews.count; i++) {
        id image = images[i];
        _thumbnailViews[i].image = (image == NSNull.null) ? nil : image;
        NSUInteger px = pixelCounts[i].unsignedIntegerValue;
        _thumbnailCaptions[i].text = [NSString stringWithFormat:@"%@\n%lu px",
            titles[i], (unsigned long)px];
        _thumbnailCaptions[i].textColor = px > 0
            ? [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0]
            : [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
    }

    LGIOS12LiveBackdropProvider *provider = LGIOS12LiveBackdropProvider.sharedProvider;
    NSUInteger compositionPrimitives = provider.lastForegroundPrimitivesDrawn;
    NSString *compositionPath = provider.lastForegroundPathName ?: @"(none yet)";

    // FAILURE CASES 2 AND 3 -- both stated in large text, both distinguishable
    // without a single log line.
    if (!winner) {
        _verdictLabel.text = [NSString stringWithFormat:
            @"FOUND ICONS: %lu\nCAPTURED PIXELS: 0", (unsigned long)icons.count];
        _verdictLabel.textColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
    } else if (compositionPrimitives == 0) {
        _verdictLabel.text = @"ICON PROBE OK / COMPOSITION FAILED";
        _verdictLabel.textColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.3 alpha:1.0];
    } else {
        _verdictLabel.text = @"ICON PROBE OK / COMPOSITION OK";
        _verdictLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0];
    }

    _statusLabel.text = [NSString stringWithFormat:
        @"SBIconView count=%lu\n"
         "selected icon=%@\n"
         "icon bounds=%.0fx%.0f\n"
         "model pixels=%lu\n"
         "presentation pixels=%lu%@\n"
         "subview elements=%lu  subview pixels=%lu\n"
         "contents layers=%lu  contents pixels=%lu\n"
         "full-foreground elements=%lu  pixels=%lu\n"
         "foreground pixels=%lu\n"
         "foreground path=%@\n"
         "subtree: %@",
        (unsigned long)icons.count,
        NSStringFromClass(icon.class),
        icon.bounds.size.width, icon.bounds.size.height,
        (unsigned long)model.pixels,
        (unsigned long)presentation.pixels,
        presentation.elements == 0 ? @" (no presentationLayer)" : @"",
        (unsigned long)subviews.elements, (unsigned long)subviews.pixels,
        (unsigned long)contents.elements, (unsigned long)contents.pixels,
        (unsigned long)full.elements, (unsigned long)full.pixels,
        (unsigned long)compositionPrimitives,
        compositionPath,
        LGIOS12ProbeDescribeSubtree(icon)];
}

@end
