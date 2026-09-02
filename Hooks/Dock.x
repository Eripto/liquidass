#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGIOS12GlassHost.h"
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
// iOS 12 DOCK METAL GLASS -- OPT-IN, OFF BY DEFAULT
//
// The Dock attachment now goes through the shared LGIOS12GlassHost registry
// like every other surface, so there is one attachment implementation rather
// than one per element.
//
// It is disabled by default because it has never been verified on device, and
// shipping an unverified Dock change alongside the Control Center work would
// make "no crashes" and "no performance regression" ambiguous -- a failure
// could belong to either. Set EnableDockGlass=true in
// /var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist to turn it
// back on for a dedicated Dock test.
// ===========================================================================
static BOOL dockIOS12GlassEnabled(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/dylv.liquidass.ios12diag.plist"];
        enabled = [prefs[@"EnableDockGlass"] boolValue];
        LGLog(@"dock.ios12 metal glass enabled=%d (default NO, opt in with EnableDockGlass)",
              enabled);
    });
    return enabled;
}

// The Dock's real corner radius, read from the host rather than assumed, so
// the shader's Fresnel edge lands on the visible corner.
static CGFloat dockIOS12CornerRadius(UIView *material) {
    if (material.layer.cornerRadius > 0.0) return material.layer.cornerRadius;
    // A masked host reports zero; fall back to the platter's own rounding.
    for (UIView *ancestor = material; ancestor; ancestor = ancestor.superview) {
        if (ancestor.layer.cornerRadius > 0.0) return ancestor.layer.cornerRadius;
    }
    if (dockModeForMaterial(material) == LGDockModeFloating) {
        return MIN(22.0, CGRectGetHeight(material.bounds) * 0.5);
    }
    return dockIsFullScreenPhone(material) ? 22.0 : 0.0;
}

static void configureDockGlass(UIView *material, LGLiveBackdropView *glass) {
    // home button docks use a border instead of specular
    LGDockMode mode = dockModeForMaterial(material);
    BOOL homeButtonDock = mode == LGDockModeRegular &&
                          !dockIsFullScreenPhone(material);
    glass.lgSpecularEnabledOverride = homeButtonDock ? @NO : nil;
    dockUpdateHomeButtonBorder(glass, homeButtonDock);
}

%ctor {
    if (LGIOS12GlassSurfacesAvailable()) {
        LGIOS12RegisterGlassSurface(@"Dock", ^CGFloat(UIView *material) {
            if (!dockIOS12GlassEnabled()) return -1.0;
            if (dockModeForMaterial(material) == LGDockModeNone) return -1.0;
            return dockIOS12CornerRadius(material);
        });
    }

    LGRegisterMaterialHost(@"Dock", 80, ^BOOL(UIView *material) {
        // On iOS 12 the Metal path claims the Dock instead -- but only when it
        // is enabled. If it is off, the Dock must stay on the existing
        // LGLiveBackdropView implementation rather than losing its glass
        // entirely. Every other iOS version is unaffected either way.
        if (LGIsIOS12() && dockIOS12GlassEnabled()) return NO;
        return dockModeForMaterial(material) != LGDockModeNone;
    }, UIEdgeInsetsZero, ^CGFloat(__unused UIView *material) {

        return -1.0;
    }, nil, ^(UIView *material, LGLiveBackdropView *glass) {
        configureDockGlass(material, glass);
    });
}
