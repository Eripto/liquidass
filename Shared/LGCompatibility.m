#import "LGCompatibility.h"
#import <objc/message.h>
#import <objc/runtime.h>

BOOL LGSystemVersionAtLeast(NSInteger major, NSInteger minor, NSInteger patch) {
    NSOperatingSystemVersion wanted = {
        .majorVersion = major,
        .minorVersion = minor,
        .patchVersion = patch,
    };
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:wanted];
}

BOOL LGIsIOS12(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    return version.majorVersion == 12;
}

BOOL LGCanUseModernMenus(void) {
    return LGSystemVersionAtLeast(14, 0, 0) &&
           NSClassFromString(@"UIAction") != Nil &&
           NSClassFromString(@"UIMenu") != Nil &&
           [UIButton instancesRespondToSelector:NSSelectorFromString(@"setMenu:")] &&
           [UIButton instancesRespondToSelector:NSSelectorFromString(@"setShowsMenuAsPrimaryAction:")];
}

UIInterfaceOrientation LGInterfaceOrientationForView(UIView *view) {
    UIWindow *window = view.window;
    SEL windowSceneSelector = NSSelectorFromString(@"windowScene");
    SEL orientationSelector = NSSelectorFromString(@"interfaceOrientation");
    if (window && [window respondsToSelector:windowSceneSelector]) {
        id scene = ((id (*)(id, SEL))objc_msgSend)(window, windowSceneSelector);
        if (scene && [scene respondsToSelector:orientationSelector]) {
            return ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(
                scene, orientationSelector);
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
}

UIFont *LGMonospacedSystemFont(CGFloat size, UIFontWeight weight) {
    SEL selector = NSSelectorFromString(@"monospacedSystemFontOfSize:weight:");
    if ([UIFont respondsToSelector:selector]) {
        return ((UIFont *(*)(Class, SEL, CGFloat, UIFontWeight))objc_msgSend)(
            UIFont.class, selector, size, weight);
    }
    return [UIFont fontWithName:@"Menlo-Regular" size:size] ?:
           [UIFont systemFontOfSize:size weight:weight];
}

UIBlurEffect *LGMaterialBlurEffectForTraitCollection(UITraitCollection *traits) {
    if (LGSystemVersionAtLeast(13, 0, 0)) {
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
    // iOS 12 has no system materials or system-wide dark appearance.
    (void)traits;
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight];
}

UIColor *LGResolvedColorForTraitCollection(UIColor *color,
                                            UITraitCollection *traits) {
    if (!color) return nil;
    SEL selector = NSSelectorFromString(@"resolvedColorWithTraitCollection:");
    if ([color respondsToSelector:selector]) {
        UITraitCollection *effectiveTraits = traits ?: UIScreen.mainScreen.traitCollection;
        UIColor *resolved = ((UIColor *(*)(id, SEL, UITraitCollection *))objc_msgSend)(
            color, selector, effectiveTraits);
        return resolved ?: color;
    }
    // UIColor subclasses on iOS 12 (including UICachedDeviceWhiteColor) do not
    // implement trait-based resolution.  They are already concrete colors.
    return color;
}

UIColor *LGColorWithDynamicProvider(
    UIColor *(^provider)(UITraitCollection *traits)) {
    if (!provider) return UIColor.clearColor;
    SEL selector = NSSelectorFromString(@"colorWithDynamicProvider:");
    if ([UIColor respondsToSelector:selector]) {
        UIColor *dynamic = ((UIColor *(*)(Class, SEL, id))objc_msgSend)(
            UIColor.class, selector, provider);
        if (dynamic) return dynamic;
    }
    // iOS 12 has no dynamic UIColor objects.  Evaluate once using the current
    // traits and keep the returned concrete color.
    return provider(UIScreen.mainScreen.traitCollection) ?: UIColor.clearColor;
}

BOOL LGHasDifferentColorAppearance(UITraitCollection *traits,
                                   UITraitCollection *previousTraits) {
    if (!traits) return previousTraits != nil;
    SEL selector = NSSelectorFromString(
        @"hasDifferentColorAppearanceComparedToTraitCollection:");
    if ([traits respondsToSelector:selector]) {
        return ((BOOL (*)(id, SEL, UITraitCollection *))objc_msgSend)(
            traits, selector, previousTraits);
    }
    // userInterfaceStyle itself exists on iOS 12; this preserves a useful
    // fallback without sending the iOS 13 comparison selector.
    return !previousTraits ||
           traits.userInterfaceStyle != previousTraits.userInterfaceStyle;
}

static NSString *LGFallbackGlyphForSymbol(NSString *name) {
    if ([name containsString:@"chevron.left"]) return @"‹";
    if ([name containsString:@"chevron.right"]) return @"›";
    if ([name containsString:@"chevron.up"]) return @"⌃";
    if ([name containsString:@"chevron.down"]) return @"⌄";
    if ([name containsString:@"checkmark"]) return @"✓";
    if ([name containsString:@"arrow.counterclockwise"]) return @"↺";
    if ([name containsString:@"line.3.horizontal"]) return @"☰";
    if ([name containsString:@"info"]) return @"i";
    if ([name containsString:@"lock"]) return @"■";
    if ([name containsString:@"iphone"]) return @"▯";
    if ([name containsString:@"doc.on.doc"]) return @"▣";
    return @"•";
}

static UIImage *LGDrawFallbackSymbol(NSString *name) {
    CGSize size = CGSizeMake(28.0, 28.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    NSString *glyph = LGFallbackGlyphForSymbol(name ?: @"");
    UIFont *font = [UIFont systemFontOfSize:23.0 weight:UIFontWeightSemibold];
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: UIColor.blackColor,
    };
    CGSize glyphSize = [glyph sizeWithAttributes:attributes];
    [glyph drawAtPoint:CGPointMake((size.width - glyphSize.width) * 0.5,
                                   (size.height - glyphSize.height) * 0.5 - 1.0)
        withAttributes:attributes];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *LGSystemImageNamed(NSString *name) {
    SEL selector = NSSelectorFromString(@"systemImageNamed:");
    if ([UIImage respondsToSelector:selector]) {
        UIImage *image = ((UIImage *(*)(Class, SEL, NSString *))objc_msgSend)(
            UIImage.class, selector, name);
        if (image) return image;
    }
    return LGDrawFallbackSymbol(name);
}

UIImage *LGSystemImageNamedWithConfiguration(NSString *name, id configuration) {
    SEL selector = NSSelectorFromString(@"systemImageNamed:withConfiguration:");
    if ([UIImage respondsToSelector:selector]) {
        UIImage *image = ((UIImage *(*)(Class, SEL, NSString *, id))objc_msgSend)(
            UIImage.class, selector, name, configuration);
        if (image) return image;
    }
    return LGSystemImageNamed(name);
}

@interface LGControlBlockTarget : NSObject
@property (nonatomic, copy) LGControlActionBlock block;
- (void)invoke:(UIControl *)sender;
@end

@implementation LGControlBlockTarget
- (void)invoke:(UIControl *)sender {
    if (self.block) self.block(sender);
}
@end

static const void *kLGControlBlockTargetsKey = &kLGControlBlockTargetsKey;

void LGAddControlAction(UIControl *control,
                        UIControlEvents events,
                        LGControlActionBlock block) {
    if (!control || !block) return;
    LGControlBlockTarget *target = [LGControlBlockTarget new];
    target.block = block;
    NSMutableArray *targets = objc_getAssociatedObject(control,
                                                        kLGControlBlockTargetsKey);
    if (!targets) {
        targets = [NSMutableArray array];
        objc_setAssociatedObject(control, kLGControlBlockTargetsKey, targets,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [targets addObject:target];
    [control addTarget:target action:@selector(invoke:) forControlEvents:events];
}

static id LGCornerCurveGetter(id self, SEL _cmd) {
    (void)_cmd;
    return objc_getAssociatedObject(self, @selector(cornerCurve));
}

static void LGCornerCurveSetter(id self, SEL _cmd, id value) {
    (void)_cmd;
    objc_setAssociatedObject(self, @selector(cornerCurve), [value copy],
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static UIColor *LGColorLabel(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return UIColor.blackColor;
}
static UIColor *LGColorSecondaryLabel(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithWhite:0.30 alpha:1.0];
}
static UIColor *LGColorTertiaryLabel(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithWhite:0.48 alpha:1.0];
}
static UIColor *LGColorSeparator(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithWhite:0.65 alpha:0.45];
}
static UIColor *LGColorGroupedBackground(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithWhite:0.95 alpha:1.0];
}
static UIColor *LGColorSecondaryGroupedBackground(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return UIColor.whiteColor;
}
static UIColor *LGColorTertiaryFill(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithWhite:0.46 alpha:0.12];
}
static UIColor *LGColorIndigo(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
}
static UIColor *LGColorTeal(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return [UIColor colorWithRed:0.20 green:0.68 blue:0.90 alpha:1.0];
}
static UIImage *LGImageSystemName(id self, SEL _cmd, NSString *name) {
    (void)self; (void)_cmd;
    return LGDrawFallbackSymbol(name);
}
static UIImage *LGImageSystemNameConfiguration(id self, SEL _cmd,
                                                NSString *name,
                                                id configuration) {
    (void)self; (void)_cmd; (void)configuration;
    return LGDrawFallbackSymbol(name);
}

static void LGAddClassMethodIfMissing(Class cls, SEL selector, IMP implementation,
                                      const char *types) {
    Class meta = object_getClass(cls);
    if (meta && !class_getClassMethod(cls, selector)) {
        class_addMethod(meta, selector, implementation, types);
    }
}

void LGInstallCompatibilityShims(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (![CALayer instancesRespondToSelector:@selector(cornerCurve)]) {
            class_addMethod(CALayer.class, @selector(cornerCurve),
                            (IMP)LGCornerCurveGetter, "@@:");
            class_addMethod(CALayer.class, @selector(setCornerCurve:),
                            (IMP)LGCornerCurveSetter, "v@:@");
        }

        LGAddClassMethodIfMissing(UIColor.class, @selector(labelColor),
                                  (IMP)LGColorLabel, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(secondaryLabelColor),
                                  (IMP)LGColorSecondaryLabel, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(tertiaryLabelColor),
                                  (IMP)LGColorTertiaryLabel, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(separatorColor),
                                  (IMP)LGColorSeparator, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(systemGroupedBackgroundColor),
                                  (IMP)LGColorGroupedBackground, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(secondarySystemGroupedBackgroundColor),
                                  (IMP)LGColorSecondaryGroupedBackground, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(tertiarySystemFillColor),
                                  (IMP)LGColorTertiaryFill, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(systemIndigoColor),
                                  (IMP)LGColorIndigo, "@@:");
        LGAddClassMethodIfMissing(UIColor.class, @selector(systemTealColor),
                                  (IMP)LGColorTeal, "@@:");
        LGAddClassMethodIfMissing(UIImage.class, @selector(systemImageNamed:),
                                  (IMP)LGImageSystemName, "@@:@");
        LGAddClassMethodIfMissing(UIImage.class,
                                  @selector(systemImageNamed:withConfiguration:),
                                  (IMP)LGImageSystemNameConfiguration, "@@:@@");
    });
}

__attribute__((constructor(101)))
static void LGCompatibilityInitialize(void) {
    @autoreleasepool {
        LGInstallCompatibilityShims();
    }
}
