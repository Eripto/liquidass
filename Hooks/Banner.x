#import <UIKit/UIKit.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGIOS12GlassHost.h"
#import "../Shared/LGSharedSupport.h"
#import <objc/runtime.h>

static BOOL LGHasMaterialAncestorBefore(UIView *material, NSString *stopClassName) {
    Class stopCls = NSClassFromString(stopClassName);
    Class materialClass = NSClassFromString(@"MTMaterialView");
    for (UIView *v = material.superview; v; v = v.superview) {
        if (stopCls && [v isKindOfClass:stopCls]) return NO;
        if (materialClass && [v isKindOfClass:materialClass]) return YES;
    }
    return NO;
}

static BOOL LGIsPlatterMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"PLPlatterView")) return NO;
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return !LGHasMaterialAncestorBefore(material, @"PLPlatterView");
}

static BOOL LGIsPlatterActionMaterial(UIView *material) {
    if (!hasAncestorOfClassName(material, @"PLPlatterActionButton")) return NO;
    if (hasAncestorOfClassName(material, @"SBSwitcherAppSuggestionBannerView")) return NO;
    return !LGHasMaterialAncestorBefore(material, @"PLPlatterActionButton");
}

static BOOL LGResponderChainContainsClass(UIResponder *responder, NSString *name) {
    Class cls = NSClassFromString(name);
    for (UIResponder *r = responder; r; r = r.nextResponder)
        if (cls && [r isKindOfClass:cls]) return YES;
    return NO;
}

static void *kLGPlatterClassificationKey = &kLGPlatterClassificationKey;

static BOOL LGIsTopBannerPresentation(UIView *view) {
    if (!view.window) return NO;
    if ([NSStringFromClass(view.window.class) isEqualToString:@"SBBannerWindow"]) return YES;
    if (hasAncestorOfClassName(view, @"BNContentViewControllerView")) return YES;
    if (LGResponderChainContainsClass(view, @"BNContentViewController")) return YES;
    return LGResponderChainContainsClass(view, @"SBNotificationPresentableViewController");
}

static BOOL LGIsLightLockscreenNotificationView(UIView *view) {
    if (!view || LGIsTopBannerPresentation(view)) return NO;
    if (view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight) return NO;
    return hasAncestorOfClassName(view, @"NCNotificationShortLookView") ||
           hasAncestorOfClassName(view, @"NCNotificationLongLookView") ||
           hasAncestorOfClassName(view, @"PLPlatterView");
}

static UIColor *LGForcedPlatterTextColor(UIView *view) {
    if (!view || view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight) return nil;
    if (LGIsTopBannerPresentation(view)) return UIColor.blackColor;
    return LGIsLightLockscreenNotificationView(view) ? UIColor.whiteColor : nil;
}

static NSAttributedString *LGAttributedTextWithColor(NSAttributedString *text, UIColor *color) {
    if (!color) return text;
    if (!text.length) return text;
    NSMutableAttributedString *copy = [text mutableCopy];
    [copy addAttribute:NSForegroundColorAttributeName
                 value:color
                 range:NSMakeRange(0, copy.length)];
    return copy;
}

static void LGDisableLockscreenStackDimming(id controller) {
    // stack dimming belongs to notifications and not top banners
    if (!controller || LGIsTopBannerPresentation([controller isKindOfClass:[UIViewController class]]
                                                   ? ((UIViewController *)controller).view : nil)) return;
    @try {
        id preview = [controller valueForKey:@"viewForPreview"];
        UIView *dimming = [preview valueForKey:@"stackDimmingOverlayView"];
        if (!dimming) {
            id contentSizeManager = [controller valueForKey:@"contentSizeManagingView"];
            dimming = [contentSizeManager valueForKey:@"stackDimmingView"];
        }
        if (dimming) dimming.hidden = lgHostEnabled(@"Notification");
    } @catch (__unused NSException *exception) {

    }
}

static CGFloat LGActionButtonRadius(UIView *material) {
    UIView *button = material;
    for (UIView *v = material; v; v = v.superview)
        if ([NSStringFromClass(v.class) isEqualToString:@"PLPlatterActionButton"]) {
            button = v;
            break;
        }
    if (button.layer.cornerRadius > 0.5) return button.layer.cornerRadius;
    if (material.layer.cornerRadius > 0.5) return material.layer.cornerRadius;
    return CGRectGetHeight(button.bounds) * 0.5;
}

static void LGUpdatePlatterGlass(UIView *material) {
    // one platter class serves banners notifications and action buttons

    if (!material.window) return;

    if (LGIsPlatterMaterial(material)) {
        BOOL topBanner = LGIsTopBannerPresentation(material);
        // iOS 12: Notification Center platters are claimed by the shared Metal
        // glass registry instead. Running both would double-composite the same
        // host. Transient top banners are NOT claimed and stay here -- see the
        // registration in %ctor for why.
        if (!topBanner && LGIOS12GlassSurfacesAvailable()) return;
        NSString *prefix = topBanner ? @"Banner" : @"Notification";
        NSString *previous = objc_getAssociatedObject(material, kLGPlatterClassificationKey);
        if (previous && ![previous isEqualToString:prefix]) {

            LGRemoveGlassFromMaterial(material, kGlassKey);
        }
        if (![previous isEqualToString:prefix]) {
            objc_setAssociatedObject(material, kLGPlatterClassificationKey, prefix,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        LGInstallRegisteredGlassInMaterial(material, kGlassKey, prefix,
                                           UIEdgeInsetsZero, -1.0, nil);
    } else if (LGIsPlatterActionMaterial(material)) {

        LGInstallRegisteredGlassInMaterial(material, kGlassKey, @"Notification",
                                           UIEdgeInsetsZero,
                                           LGActionButtonRadius(material), nil);
    }
}

%hook MTMaterialView
- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (self_.window) LGUpdatePlatterGlass(self_);
}
- (void)layoutSubviews {
    %orig;
    LGUpdatePlatterGlass((UIView *)self);
}
%end

%hook UILabel
- (void)setTextColor:(UIColor *)color {
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (forced) color = forced;
    %orig(color);
}
- (void)setAttributedText:(NSAttributedString *)text {
    text = LGAttributedTextWithColor(text, LGForcedPlatterTextColor((UIView *)self));
    %orig(text);
}
- (void)didMoveToWindow {
    %orig;
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (!forced) return;
    if (self.attributedText.length) self.attributedText = LGAttributedTextWithColor(self.attributedText, forced);
    self.textColor = forced;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig(previousTraitCollection);
    UIColor *forced = LGForcedPlatterTextColor((UIView *)self);
    if (!forced) return;
    if (self.attributedText.length) self.attributedText = LGAttributedTextWithColor(self.attributedText, forced);
    self.textColor = forced;
}
%end

%hook NCNotificationShortLookViewController
- (void)viewDidLoad {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGDisableLockscreenStackDimming(self);
}
%end

%ctor {
    // ===================================================================
    // PHASE 2: iOS 12 Notification Center on the verified Metal glass.
    //
    // HOST: the same MTMaterialView instances this file already identifies as
    // platter backgrounds via LGIsPlatterMaterial() -- the outermost material
    // inside a PLPlatterView. No new class-name guessing: the existing
    // detection already excludes nested materials
    // (LGHasMaterialAncestorBefore) and the switcher's app-suggestion banner,
    // and those exclusions are inherited exactly.
    //
    // BANNERS ARE DELIBERATELY EXCLUDED, and this is a correctness decision,
    // not a scope cut. This file already separates the two presentations:
    // LGIsTopBannerPresentation() distinguishes a transient banner from a
    // Notification Center / lock screen notification. The shared backdrop is
    // composed from wallpaper plus Home Screen icons ONLY, so it is the right
    // backdrop for Notification Center -- which is presented over the Home or
    // Lock Screen -- but the WRONG one for a banner, which floats over
    // whatever app is in the foreground. A banner would refract the Home
    // Screen while sitting over an app. Banners stay on the existing
    // implementation until the provider can supply an app-content backdrop.
    //
    // PLATTER ACTION BUTTONS are also left alone: they sit inside a platter
    // that now carries glass of its own, and nesting a second glass surface
    // inside the first would double-composite.
    //
    // FOREGROUND: notification text, icons and buttons are sibling views above
    // the platter material, not children of it, so inserting at index 0 of the
    // material keeps them above the glass and interactive.
    // ===================================================================
    if (LGIOS12GlassSurfacesAvailable()) {
        LGIOS12RegisterGlassSurface(@"NotificationCenter", ^CGFloat(UIView *material) {
            if (!LGIsPlatterMaterial(material)) return -1.0;
            if (LGIsTopBannerPresentation(material)) return -1.0;
            CGSize size = material.bounds.size;
            if (size.width < 100.0 || size.height < 30.0) return -1.0;
            // iOS 12 notification platter rounding, used only if the host
            // exposes none of its own.
            return LGIOS12GlassInheritedCornerRadius(material, 13.0);
        });
    }
}
