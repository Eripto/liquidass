#pragma once

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// These constants are exported by QuartzCore only on iOS 13+.  Using literal
// values avoids a hard dyld reference while preserving the newer behaviour.
#ifdef kCACornerCurveContinuous
#undef kCACornerCurveContinuous
#endif
#define kCACornerCurveContinuous @"continuous"

#ifdef kCACornerCurveCircular
#undef kCACornerCurveCircular
#endif
#define kCACornerCurveCircular @"circular"

FOUNDATION_EXPORT BOOL LGSystemVersionAtLeast(NSInteger major,
                                               NSInteger minor,
                                               NSInteger patch);
FOUNDATION_EXPORT BOOL LGIsIOS12(void);
FOUNDATION_EXPORT BOOL LGCanUseModernMenus(void);

FOUNDATION_EXPORT UIInterfaceOrientation LGInterfaceOrientationForView(UIView *view);
FOUNDATION_EXPORT UIFont *LGMonospacedSystemFont(CGFloat size, UIFontWeight weight);
FOUNDATION_EXPORT UIBlurEffect *LGMaterialBlurEffectForTraitCollection(UITraitCollection *traits);

// Dynamic UIColor APIs arrived in iOS 13.  Keep all calls behind runtime
// dispatch so an iOS 12 UIColor subclass is never sent a newer selector.
FOUNDATION_EXPORT UIColor *LGResolvedColorForTraitCollection(UIColor *color,
                                                              UITraitCollection *traits);
FOUNDATION_EXPORT UIColor *LGColorWithDynamicProvider(
    UIColor *(^provider)(UITraitCollection *traits));
FOUNDATION_EXPORT BOOL LGHasDifferentColorAppearance(
    UITraitCollection *traits,
    UITraitCollection *previousTraits);

FOUNDATION_EXPORT UIImage *LGSystemImageNamed(NSString *name);
FOUNDATION_EXPORT UIImage *LGSystemImageNamedWithConfiguration(NSString *name,
                                                                id configuration);

typedef void (^LGControlActionBlock)(__kindof UIControl *sender);
FOUNDATION_EXPORT void LGAddControlAction(UIControl *control,
                                          UIControlEvents events,
                                          LGControlActionBlock block);

// Installs narrowly-scoped methods that UIKit did not expose until iOS 13.
// Existing implementations are never replaced, so iOS 13+ stays untouched.
FOUNDATION_EXPORT void LGInstallCompatibilityShims(void);
