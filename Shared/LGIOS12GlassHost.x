#import "LGIOS12GlassHost.h"
#import "LGIOS12MetalGlassView.h"
#import "LGIOS12LiveBackdropProvider.h"
#import "LGSharedSupport.h"
#import <objc/runtime.h>

static const void *kLGIOS12GlassKey = &kLGIOS12GlassKey;
static const void *kLGIOS12SuppressedKey = &kLGIOS12SuppressedKey;
static const void *kLGIOS12SurfaceNameKey = &kLGIOS12SurfaceNameKey;

@interface LGIOS12GlassSurfaceRegistration : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) LGIOS12GlassRadiusProvider radiusProvider;
@end
@implementation LGIOS12GlassSurfaceRegistration
@end

static NSMutableArray<LGIOS12GlassSurfaceRegistration *> *sSurfaces;

void LGIOS12RegisterGlassSurface(NSString *name,
                                 LGIOS12GlassRadiusProvider radiusProvider) {
    if (!name.length || !radiusProvider) return;
    if (!sSurfaces) sSurfaces = [NSMutableArray array];
    LGIOS12GlassSurfaceRegistration *registration =
        [LGIOS12GlassSurfaceRegistration new];
    registration.name = name;
    registration.radiusProvider = radiusProvider;
    [sSurfaces addObject:registration];
    LGLog(@"ios12.glasshost surface registered name=%@ total=%lu",
          name, (unsigned long)sSurfaces.count);
}

BOOL LGIOS12GlassSurfacesAvailable(void) {
    return LGIsIOS12() && LGIsSpringBoardProcess();
}

// First non-negative radius wins.
static BOOL LGIOS12GlassResolveSurface(UIView *material, CGFloat *outRadius,
                                        NSString **outName) {
    for (LGIOS12GlassSurfaceRegistration *registration in sSurfaces) {
        CGFloat radius = -1.0;
        @try {
            radius = registration.radiusProvider(material);
        } @catch (__unused NSException *exception) {
            // A surface predicate walking an unexpected hierarchy must never
            // take SpringBoard down with it.
            continue;
        }
        if (radius >= 0.0) {
            if (outRadius) *outRadius = radius;
            if (outName) *outName = registration.name;
            return YES;
        }
    }
    return NO;
}

// Hides the stock material's own content so it cannot double-blur or re-tint
// the Metal result, WITHOUT removing or destroying the material view -- the
// owning framework keeps using it for layout and lifecycle. Fully reversible.
//
// Re-applied on every sync rather than only on transitions: MTMaterialView
// creates its backdrop/tint subviews lazily, and one appearing after the first
// suppression would otherwise stay visible and double-composite.
static void LGIOS12GlassSuppressStock(UIView *material, BOOL suppress) {
    NSNumber *previous = objc_getAssociatedObject(material, kLGIOS12SuppressedKey);
    BOOL changed = (previous.boolValue != suppress);
    for (UIView *sub in material.subviews) {
        if ([sub isKindOfClass:LGIOS12MetalGlassView.class]) continue;
        sub.hidden = suppress;
    }
    if (suppress) material.backgroundColor = UIColor.clearColor;
    objc_setAssociatedObject(material, kLGIOS12SuppressedKey, @(suppress),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (changed) {
        LGLog(@"ios12.glasshost stock suppressed=%d host=%@ surface=%@ subviews=%lu",
              suppress, NSStringFromClass(material.class),
              objc_getAssociatedObject(material, kLGIOS12SurfaceNameKey) ?: @"?",
              (unsigned long)material.subviews.count);
    }
}

static void LGIOS12GlassSync(UIView *material);

static void LGIOS12GlassDetach(UIView *material) {
    LGIOS12MetalGlassView *glass =
        objc_getAssociatedObject(material, kLGIOS12GlassKey);
    if (!glass) return;
    // -removeFromSuperview drives the glass view's own -willMoveToWindow:,
    // which unregisters both the provider client and the capture exclusion.
    [glass removeFromSuperview];
    objc_setAssociatedObject(material, kLGIOS12GlassKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    LGIOS12GlassSuppressStock(material, NO);
    LGLog(@"ios12.glasshost detached host=%@ surface=%@",
          NSStringFromClass(material.class),
          objc_getAssociatedObject(material, kLGIOS12SurfaceNameKey) ?: @"?");
}

static void LGIOS12GlassSync(UIView *material) {
    if (!LGIOS12GlassSurfacesAvailable() || !material) return;

    CGFloat radius = -1.0;
    NSString *surfaceName = nil;
    if (!LGIOS12GlassResolveSurface(material, &radius, &surfaceName)) {
        // No longer (or never) one of ours. If we previously attached to it,
        // put it back the way we found it.
        if (objc_getAssociatedObject(material, kLGIOS12GlassKey)) {
            LGIOS12GlassDetach(material);
        }
        return;
    }

    LGIOS12MetalGlassView *glass =
        objc_getAssociatedObject(material, kLGIOS12GlassKey);

    if (!glass) {
        glass = [[LGIOS12MetalGlassView alloc] initWithFrame:material.bounds];
        // FALLBACK: Metal, the shader library or a pipeline failed. Leave the
        // stock material exactly as it was -- a renderer that cannot start
        // must never cost the user the element's background.
        if (!glass.metalInitialized) {
            LGLog(@"ios12.glasshost init FAILED surface=%@ host=%@ -- keeping stock material",
                  surfaceName, NSStringFromClass(material.class));
            return;
        }
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        // Never intercepts touches: the element's real controls stay live.
        glass.userInteractionEnabled = NO;
        // Index 0 of the material. The material is the element's BACKGROUND,
        // and the element's real content lives in sibling views above it, so
        // this is above the wallpaper and below the foreground content with no
        // z-order fighting and no duplicated content rendered into the glass.
        // Being a subview also inherits the material's mask, so the element's
        // real shape clips the glass.
        [material insertSubview:glass atIndex:0];
        objc_setAssociatedObject(material, kLGIOS12GlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(material, kLGIOS12SurfaceNameKey, surfaceName,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        LGLog(@"ios12.glasshost attached surface=%@ host=%@ bounds=%@ radius=%.1f",
              surfaceName, NSStringFromClass(material.class),
              NSStringFromCGRect(material.bounds), radius);
    }

    // Geometry resync. Driven from -layoutSubviews, so element layout,
    // orientation and size changes, and a moving/resizing element all land
    // here. The shader reads the view's live screen-space origin on every draw,
    // so refraction stays registered with what is actually behind the element.
    glass.frame = material.bounds;
    glass.glassCornerRadius = radius;
    // Only suppress once the glass can actually draw, so a surface never
    // flashes empty while the first backdrop texture is still in flight.
    LGIOS12GlassSuppressStock(material, glass.rendererReady);
    [glass redraw];

    // The first backdrop texture arrives asynchronously, and a surface that
    // has finished laying out will not call us again on its own. Without this
    // retry the stock material would stay visible underneath the glass until
    // some unrelated layout happened to occur. Self-limiting: it stops as soon
    // as the renderer is ready, and only runs while the glass is still
    // attached to this material.
    if (!glass.rendererReady) {
        __weak UIView *weakMaterial = material;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *strongMaterial = weakMaterial;
            if (!strongMaterial) return;
            if (objc_getAssociatedObject(strongMaterial, kLGIOS12GlassKey) != glass) return;
            LGIOS12GlassSync(strongMaterial);
        });
    }
}

%hook MTMaterialView

- (void)layoutSubviews {
    %orig;
    LGIOS12GlassSync((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    if (!LGIOS12GlassSurfacesAvailable()) return;
    if (((UIView *)self).window) {
        LGIOS12GlassSync((UIView *)self);
    } else {
        LGIOS12GlassDetach((UIView *)self);
    }
}

%end
