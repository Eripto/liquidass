#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGIOS12MetalGlassView.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, LGDockMode) {
    LGDockModeNone = 0,
    LGDockModeRegular,
    LGDockModeFloating,
};

static const void *kDockHomeButtonBorderKey = &kDockHomeButtonBorderKey;

static BOOL dockInsideCategoryStackBackground(UIView *view) {
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if ([NSStringFromClass(ancestor.class) containsString:@"StackViewBackground"])
            return YES;
    }
    return NO;
}

static LGDockMode dockModeForMaterial(UIView *material) {
    // each dock family exposes different host geometry
    if (!isExactClass(material, @"MTMaterialView") ||
        dockInsideCategoryStackBackground(material)) return LGDockModeNone;

    CGSize size = material.bounds.size;
    if (size.width < 160.0 || size.height < 40.0) return LGDockModeNone;

    if (hasAncestorOfClassName(material, @"SBFloatingDockPlatterView") &&
        size.width >= size.height * 2.0) {
        return LGDockModeFloating;
    }
    if (hasAncestorOfClassName(material, @"SBDockView")) {
        return LGDockModeRegular;
    }
    return LGDockModeNone;
}

static BOOL dockIsFullScreenPhone(UIView *material) {
    UIEdgeInsets safeArea = material.window.safeAreaInsets;
    return safeArea.top > 20.0 || safeArea.bottom > 0.0;
}

static void dockUpdateHomeButtonBorder(LGLiveBackdropView *glass,
                                       BOOL needsBorder) {
    CAShapeLayer *border =
        objc_getAssociatedObject(glass, kDockHomeButtonBorderKey);
    if (!needsBorder) {
        [border removeFromSuperlayer];
        objc_setAssociatedObject(glass, kDockHomeButtonBorderKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (!border) {
        border = [CAShapeLayer layer];
        border.fillColor = UIColor.clearColor.CGColor;
        border.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.42].CGColor;
        objc_setAssociatedObject(glass, kDockHomeButtonBorderKey, border,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [glass.layer addSublayer:border];
    CGFloat scale = glass.window.screen.scale;
    if (scale <= 0.0) scale = UIScreen.mainScreen.scale;
    CGFloat lineWidth = 1.0 / MAX(scale, 1.0);
    CGRect borderRect = CGRectInset(glass.bounds, lineWidth * 0.5,
                                    lineWidth * 0.5);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    border.frame = glass.bounds;
    border.contentsScale = scale;
    border.lineWidth = lineWidth;
    border.path = [UIBezierPath bezierPathWithRect:borderRect].CGPath;
    [CATransaction commit];
}

// ===========================================================================
// iOS 12 DOCK METAL GLASS
//
// iOS 12 only. Every other version keeps the existing LGLiveBackdropView path
// untouched -- the predicate below routes the Dock away from the generic
// registry on 12 alone, so exactly one glass implementation is ever attached.
//
// The Metal view is added as a subview of the Dock's own MTMaterialView. That
// placement gives the required stacking for free: the material sits behind the
// Dock icons in SpringBoard's own hierarchy, so anything inside it is above
// the wallpaper and below the icons, with no z-order fighting and no duplicate
// icons rendered into the glass. It also inherits the material's mask, so the
// Dock's real corner shape clips the glass exactly.
// ===========================================================================
static const void *kDockIOS12GlassKey = &kDockIOS12GlassKey;
static const void *kDockIOS12SuppressedKey = &kDockIOS12SuppressedKey;

// The Dock's real corner radius, read from the host rather than assumed, so
// the shader's Fresnel edge lands on the visible corner.
static CGFloat dockIOS12CornerRadius(UIView *material) {
    if (material.layer.cornerRadius > 0.0) return material.layer.cornerRadius;
    // A masked host reports zero; fall back to the platter's own rounding.
    for (UIView *ancestor = material; ancestor; ancestor = ancestor.superview) {
        if (ancestor.layer.cornerRadius > 0.0) return ancestor.layer.cornerRadius;
    }
    LGDockMode mode = dockModeForMaterial(material);
    if (mode == LGDockModeFloating) {
        return MIN(22.0, CGRectGetHeight(material.bounds) * 0.5);
    }
    return dockIsFullScreenPhone(material) ? 22.0 : 0.0;
}

// Hides the stock material's own content so it cannot double-blur or re-tint
// the Metal result, WITHOUT removing or destroying the material view itself --
// SpringBoard keeps using it for layout and hosting. Reversible: the original
// hidden flags are recorded so the stock look returns if the glass is removed.
static void dockIOS12SuppressStockMaterial(UIView *material, BOOL suppress) {
    NSNumber *alreadySuppressed =
        objc_getAssociatedObject(material, kDockIOS12SuppressedKey);
    BOOL changed = (alreadySuppressed.boolValue != suppress);

    // Re-applied on every sync rather than only on transitions: MTMaterialView
    // adds its backdrop/tint subviews lazily, and one that appears after the
    // first suppression would otherwise stay visible and double-blur the
    // Metal result. The loop is a handful of views and runs from layout.
    for (UIView *sub in material.subviews) {
        if ([sub isKindOfClass:LGIOS12MetalGlassView.class]) continue;
        sub.hidden = suppress;
    }
    if (suppress) material.backgroundColor = UIColor.clearColor;
    objc_setAssociatedObject(material, kDockIOS12SuppressedKey, @(suppress),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (changed) {
        LGLog(@"dock.ios12 stock material suppressed=%d host=%@ subviews=%lu",
              suppress, NSStringFromClass(material.class),
              (unsigned long)material.subviews.count);
    }
}

static void dockIOS12SyncGlass(UIView *material) {
    if (!LGIsIOS12()) return;
    if (dockModeForMaterial(material) == LGDockModeNone) return;

    LGIOS12MetalGlassView *glass =
        objc_getAssociatedObject(material, kDockIOS12GlassKey);

    if (!glass) {
        glass = [[LGIOS12MetalGlassView alloc] initWithFrame:material.bounds];
        // FALLBACK: if Metal, the shader library or a pipeline failed, leave
        // the stock Dock material exactly as it was. A broken renderer must
        // not cost the user their Dock background.
        if (!glass.metalInitialized) {
            LGLog(@"dock.ios12 glass init FAILED -- keeping stock material");
            return;
        }
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;   // icons stay tappable
        // Index 0 of the material: above the wallpaper, below the Dock icons
        // (which are siblings of the material, not its children), and clipped
        // by the material's own mask.
        [material insertSubview:glass atIndex:0];
        objc_setAssociatedObject(material, kDockIOS12GlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLog(@"dock.ios12 glass attached host=%@ mode=%ld bounds=%@ radius=%.1f",
              NSStringFromClass(material.class),
              (long)dockModeForMaterial(material),
              NSStringFromCGRect(material.bounds),
              dockIOS12CornerRadius(material));
    }

    // Geometry resync. Called from layoutSubviews / didMoveToWindow, so a
    // floating Dock that moves or resizes, and an orientation change, both
    // land here. The shader reads the view's live screen-space origin on every
    // draw, so refraction stays registered with what is behind the Dock.
    glass.frame = material.bounds;
    glass.glassCornerRadius = dockIOS12CornerRadius(material);
    dockIOS12SuppressStockMaterial(material, glass.rendererReady);
    [glass redraw];
}

static void dockIOS12DetachGlass(UIView *material) {
    LGIOS12MetalGlassView *glass =
        objc_getAssociatedObject(material, kDockIOS12GlassKey);
    if (!glass) return;
    // Removing from the superview drives the base class's -willMoveToWindow:,
    // which unregisters both the provider client and the capture exclusion.
    [glass removeFromSuperview];
    objc_setAssociatedObject(material, kDockIOS12GlassKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    dockIOS12SuppressStockMaterial(material, NO);
    LGLog(@"dock.ios12 glass detached host=%@", NSStringFromClass(material.class));
}

%hook MTMaterialView

- (void)layoutSubviews {
    %orig;
    if (LGIsIOS12() && LGIsSpringBoardProcess()) {
        dockIOS12SyncGlass((UIView *)self);
    }
}

- (void)didMoveToWindow {
    %orig;
    if (!LGIsIOS12() || !LGIsSpringBoardProcess()) return;
    if (((UIView *)self).window) {
        dockIOS12SyncGlass((UIView *)self);
    } else {
        dockIOS12DetachGlass((UIView *)self);
    }
}

%end

static void configureDockGlass(UIView *material, LGLiveBackdropView *glass) {
    // home button docks use a border instead of specular
    LGDockMode mode = dockModeForMaterial(material);
    BOOL homeButtonDock = mode == LGDockModeRegular &&
                          !dockIsFullScreenPhone(material);
    glass.lgSpecularEnabledOverride = homeButtonDock ? @NO : nil;
    dockUpdateHomeButtonBorder(glass, homeButtonDock);
}

%ctor {
    LGRegisterMaterialHost(@"Dock", 80, ^BOOL(UIView *material) {
        // iOS 12 uses the Metal path above instead, so the generic
        // LGLiveBackdropView registry must not also claim the Dock there --
        // two glass implementations in one host would double-composite.
        // Every other version is unaffected.
        if (LGIsIOS12()) return NO;
        return dockModeForMaterial(material) != LGDockModeNone;
    }, UIEdgeInsetsZero, ^CGFloat(__unused UIView *material) {

        return -1.0;
    }, nil, ^(UIView *material, LGLiveBackdropView *glass) {
        configureDockGlass(material, glass);
    });
}
