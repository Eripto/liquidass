#import "LGGlassKit.h"
#import "LGLiveBackdropView.h"
#import "LGHostRegistry.h"
#import "LGSharedSupport.h"
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - class / ancestry helpers

BOOL hasAncestorOfClassName(UIView *v, NSString *clsName) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return NO;
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([cur isKindOfClass:cls]) return YES;
    return NO;
}

BOOL ancestorNameContains(UIView *v, NSString *sub) {
    for (UIView *cur = v; cur; cur = cur.superview)
        if ([NSStringFromClass(cur.class) containsString:sub]) return YES;
    return NO;
}

BOOL isExactClass(UIView *v, NSString *name) {
    return v && [NSStringFromClass(v.class) isEqualToString:name];
}

#pragma mark - per-host enable prefs

BOOL lgHostEnabled(NSString *prefix) {
    if (!prefix.length) return YES;
    id global = LGGlassPreferenceValue(@"Global.Enabled");
    if (![prefix isEqualToString:@"Global"] && [global isKindOfClass:[NSNumber class]] && ![global boolValue])
        return NO;
    id v = LGGlassPreferenceValue([prefix stringByAppendingString:@".Enabled"]);

    if (!v) {
        static NSDictionary<NSString *, NSString *> *legacyPrefixes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            legacyPrefixes = @{
                @"OpenFolder":   @"FolderOpen",
                @"AppLibSearch": @"AppLibrary.Search",
                @"Passcode":     @"Lockscreen.Passcode",
                @"Clock":        @"Lockscreen.Clock",
                @"QuickActions": @"LockscreenQuickActions",
            };
        });
        NSString *legacy = legacyPrefixes[prefix];
        if (legacy) v = LGGlassPreferenceValue([legacy stringByAppendingString:@".Enabled"]);
    }
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];

    if ([prefix isEqualToString:@"AppIcons"]) return NO;
    return YES;
}

#pragma mark - uniform injection registry

@interface LGGlassRec : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, weak) UIView *glass;
@property (nonatomic, weak) UIView *material;
@end
@implementation LGGlassRec @end

void *kGlassKey = &kGlassKey;

static NSMapTable<UIView *, LGGlassRec *> *sGlassRecs;
static NSMapTable<UIView *, NSString *> *sSuppressed;
static NSMutableArray<void (^)(void)> *sReloadHandlers;
static NSMutableArray<NSString *> *sReloadHandlerNames;

@interface LGMaterialHostRoute : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic) NSInteger priority;
@property (nonatomic, copy) LGMaterialHostMatcher matcher;
@property (nonatomic) UIEdgeInsets outset;
@property (nonatomic, copy) LGMaterialHostCornerRadiusProvider cornerRadiusProvider;
@property (nonatomic, copy) NSString *groupName;
@property (nonatomic, copy) LGMaterialHostPostInstall postInstall;
@end
@implementation LGMaterialHostRoute @end
static NSMutableArray<LGMaterialHostRoute *> *sMaterialHostRoutes;

void lgObservePreferenceReload(void (^handler)(void)) {
    lgObservePreferenceReloadNamed(@"anonymous", handler);
}

void lgObservePreferenceReloadNamed(NSString *name, void (^handler)(void)) {
    if (!handler) return;
    if (!sReloadHandlers) {
        sReloadHandlers = [NSMutableArray array];
        sReloadHandlerNames = [NSMutableArray array];
    }
    [sReloadHandlers addObject:[handler copy]];
    [sReloadHandlerNames addObject:name.length ? [name copy] : @"anonymous"];
}

void lgTrackGlass(UIView *glass, NSString *prefix, UIView *material) {
    if (!glass || !prefix.length) return;
    if (!sGlassRecs) sGlassRecs = [NSMapTable weakToStrongObjectsMapTable];
    LGGlassRec *existing = [sGlassRecs objectForKey:glass];
    if (existing) {
        existing.prefix = prefix;
        existing.material = material;
        return;
    }
    LGGlassRec *rec = [LGGlassRec new];
    rec.prefix = prefix; rec.glass = glass; rec.material = material;
    [sGlassRecs setObject:rec forKey:glass];
}

static BOOL LGIOS12HasReadyTrackedReplacement(UIView *stockView,
                                               NSString *prefix) {
    if (!stockView.window || !sGlassRecs.count) return NO;
    for (UIView *candidate in sGlassRecs.keyEnumerator.allObjects) {
        LGGlassRec *record = [sGlassRecs objectForKey:candidate];
        if (!record || ![record.prefix isEqualToString:prefix]) continue;
        if (!candidate.superview || candidate.window != stockView.window ||
            candidate.hidden || candidate.alpha <= 0.01 ||
            CGRectIsEmpty(candidate.bounds)) continue;
        if ([candidate isKindOfClass:[LGLiveBackdropView class]] &&
            !((LGLiveBackdropView *)candidate).lgRendererReady) continue;
        return YES;
    }
    return NO;
}

void lgSuppressStock(UIView *v, NSString *prefix, BOOL setHidden) {
    if (!v || !prefix.length) return;
    if (setHidden && LGIsIOS12() &&
        !LGIOS12HasReadyTrackedReplacement(v, prefix)) {
        // Widget/passcode hooks historically hid their stock surface before
        // their replacement was attached. Preserve it until a visible,
        // renderer-ready replacement in the same window is tracked.
        setHidden = NO;
        LGDiagnosticLog(@"suppression.ios12.blocked prefix=%@ stock=%@ reason=no-ready-replacement hidden=%d alpha=%.3f",
                        prefix, NSStringFromClass(v.class), v.hidden, v.alpha);
    }
    if (setHidden) v.hidden = YES;
    if (!sSuppressed) sSuppressed = [NSMapTable weakToStrongObjectsMapTable];
    [sSuppressed setObject:prefix forKey:v];
}

#pragma mark - registered material lifecycle

LGLiveBackdropView *LGCreateRegisteredGlass(CGRect frame,
                                             NSString *groupName,
                                             NSString *prefix) {
    if (!prefix.length) return nil;
    NSString *filterType = LGFilterTypeForHostPrefix(prefix);
    if (!filterType) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    return [[LGLiveBackdropView alloc]
        initWithFrame:frame
            groupName:groupName
           filterType:filterType];
}

LGLiveBackdropView *LGInstallRegisteredGlassInMaterial(UIView *material,
                                                        const void *associationKey,
                                                        NSString *prefix,
                                                        UIEdgeInsets outset,
                                                        CGFloat cornerRadius,
                                                        NSString *groupName) {
    if (!material || !associationKey || !prefix.length) return nil;
    const LGHostDefinition *host =
        LGHostDefinitionForPreferencePrefix(prefix.UTF8String);
    if (!host) {
        LGLog(@"lifecycle rejected unknown host prefix=%@", prefix);
        return nil;
    }
    if (!lgHostEnabled(prefix)) {
        LGRemoveGlassFromMaterial(material, associationKey);
        return nil;
    }

    NSString *filterType = [NSString stringWithUTF8String:host->filterType];
    LGInjectGlassIntoMaterialGroupType(material, associationKey, outset,
                                       cornerRadius, groupName, filterType);
    LGLiveBackdropView *glass = objc_getAssociatedObject(material, associationKey);
    if (glass) lgTrackGlass(glass, prefix, material);
    return glass;
}

void LGRegisterMaterialHost(NSString *prefix,
                            NSInteger priority,
                            LGMaterialHostMatcher matcher,
                            UIEdgeInsets outset,
                            LGMaterialHostCornerRadiusProvider cornerRadiusProvider,
                            NSString *groupName,
                            LGMaterialHostPostInstall postInstall) {
    if (!prefix.length || !matcher ||
        !LGHostDefinitionForPreferencePrefix(prefix.UTF8String)) {
        LGLog(@"router rejected invalid material host prefix=%@", prefix);
        return;
    }
    if (!sMaterialHostRoutes) sMaterialHostRoutes = [NSMutableArray array];
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if ([route.prefix isEqualToString:prefix]) return;
    }
    LGMaterialHostRoute *route = [LGMaterialHostRoute new];
    route.prefix = prefix;
    route.priority = priority;
    route.matcher = [matcher copy];
    route.outset = outset;
    route.cornerRadiusProvider = [cornerRadiusProvider copy];
    route.groupName = groupName;
    route.postInstall = [postInstall copy];
    [sMaterialHostRoutes addObject:route];
    // priority makes one host own each material
    [sMaterialHostRoutes sortUsingComparator:^NSComparisonResult(LGMaterialHostRoute *a,
                                                                   LGMaterialHostRoute *b) {
        if (a.priority == b.priority) return [a.prefix compare:b.prefix];
        return a.priority > b.priority ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static void lgRouteMaterialHost(UIView *material) {
    // A public UIVisualEffectView is the iOS 12 fallback renderer. Never
    // interpret any of its private implementation views as a host requiring
    // another LiquidAss glass, which would recursively nest renderers.
    for (UIView *ancestor = material; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[LGLiveBackdropView class]]) return;
    }
    if (!material.window) {
        LGRemoveGlassFromMaterial(material, kGlassKey);
        return;
    }
    for (LGMaterialHostRoute *route in sMaterialHostRoutes) {
        if (!route.matcher(material)) continue;
        CGFloat radius = route.cornerRadiusProvider
            ? route.cornerRadiusProvider(material) : -1.0;
        LGLiveBackdropView *glass = LGInstallRegisteredGlassInMaterial(
            material, kGlassKey, route.prefix, route.outset, radius, route.groupName);
        if (glass && route.postInstall) route.postInstall(material, glass);
        return;
    }
}

static void lgReconcileInjectionsForDisable(void) {
    // disabled hosts must restore stock views and remove live glass
    if (sGlassRecs.count) {
        for (UIView *glass in sGlassRecs.keyEnumerator.allObjects) {
            LGGlassRec *r = [sGlassRecs objectForKey:glass];
            if (!r) continue;
            if (!lgHostEnabled(r.prefix)) {
                if (r.material) LGRemoveGlassFromMaterial(r.material, kGlassKey);
                else            [glass removeFromSuperview];
                [sGlassRecs removeObjectForKey:glass];
            }
        }
    }
    for (UIView *v in sSuppressed.keyEnumerator.allObjects) {
        NSString *p = [sSuppressed objectForKey:v];
        if (p && !lgHostEnabled(p)) { v.hidden = NO; [sSuppressed removeObjectForKey:v]; }
    }
}

static void lgRouteIOS12MaterialHostsInView(UIView *view, Class materialClass,
                                            NSUInteger *visited,
                                            NSUInteger *materialCount) {
    if (!view || [view isKindOfClass:[LGLiveBackdropView class]]) return;
    if (visited) (*visited)++;
    if (materialClass && [view isKindOfClass:materialClass]) {
        if (materialCount) (*materialCount)++;
        lgRouteMaterialHost(view);
    }
    for (UIView *subview in [view.subviews copy]) {
        lgRouteIOS12MaterialHostsInView(subview, materialClass, visited,
                                       materialCount);
    }
}

static void lgActivateIOS12FallbackForExistingHosts(void) {
    if (!LGIsIOS12()) return;
    Class materialClass = NSClassFromString(@"MTMaterialView");
    Class applicationClass = NSClassFromString(@"UIApplication");
    SEL sharedSelector = NSSelectorFromString(@"sharedApplication");
    SEL windowsSelector = NSSelectorFromString(@"windows");
    if (!materialClass || !applicationClass ||
        ![applicationClass respondsToSelector:sharedSelector]) {
        LGDiagnosticLog(@"springboard.reload.ios12.scan.skipped materialClass=%@ applicationClass=%@",
                        materialClass ? NSStringFromClass(materialClass) : @"missing",
                        applicationClass ? NSStringFromClass(applicationClass) : @"missing");
        return;
    }
    id application = ((id (*)(Class, SEL))objc_msgSend)(applicationClass,
                                                        sharedSelector);
    if (![application respondsToSelector:windowsSelector]) {
        LGDiagnosticLog(@"springboard.reload.ios12.scan.skipped selector=windows");
        return;
    }
    NSArray<UIWindow *> *windows = ((id (*)(id, SEL))objc_msgSend)(
        application, windowsSelector);
    NSUInteger visited = 0;
    NSUInteger materialCount = 0;
    LGDiagnosticLog(@"springboard.reload.ios12.scan.begin windows=%lu materialClass=%@",
                    (unsigned long)windows.count, NSStringFromClass(materialClass));
    for (UIWindow *window in [windows copy]) {
        lgRouteIOS12MaterialHostsInView(window, materialClass, &visited,
                                       &materialCount);
    }
    LGDiagnosticLog(@"springboard.reload.ios12.scan.end views=%lu materials=%lu",
                    (unsigned long)visited, (unsigned long)materialCount);
}

static void lgEnablePrefsReloadCallback(CFNotificationCenterRef c, void *o, CFStringRef n,
                                        const void *obj, CFDictionaryRef info) {
    LGLog(@"prefs Reload received; invalidating SpringBoard host-enable cache");
    LGDiagnosticLog(@"springboard.reload.begin notification=%@",
                    (__bridge NSString *)n);
    LGInvalidateGlassPreferenceCache();

    dispatch_async(dispatch_get_main_queue(), ^{
        LGDiagnosticLog(@"springboard.reload.reconcile.begin handlers=%lu",
                        (unsigned long)sReloadHandlers.count);
        lgReconcileInjectionsForDisable();
        LGDiagnosticLog(@"springboard.reload.reconcile.end");
        lgActivateIOS12FallbackForExistingHosts();
        LGLog(@"prefs Reload reconciled material hosts; extraHandlers=%lu",
              (unsigned long)sReloadHandlers.count);
        NSUInteger index = 0;
        for (void (^handler)(void) in [sReloadHandlers copy]) {
            NSString *handlerName = index < sReloadHandlerNames.count
                ? sReloadHandlerNames[index] : @"anonymous";
            LGDiagnosticLog(@"springboard.reload.handler.begin index=%lu name=%@",
                            (unsigned long)index, handlerName);
            @try {
                handler();
                LGDiagnosticLog(@"springboard.reload.handler.end index=%lu name=%@",
                                (unsigned long)index, handlerName);
            } @catch (NSException *exception) {
                LGDiagnosticLog(@"springboard.reload.handler.exception index=%lu handler=%@ exception=%@ reason=%@",
                                (unsigned long)index, handlerName,
                                exception.name, exception.reason);
            }
            index++;
        }
        LGDiagnosticLog(@"springboard.reload.end");
    });
}

__attribute__((constructor)) static void lgGlassInitEnableObserver(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, lgEnablePrefsReloadCallback, CFSTR("dylv.liquidassprefs/Reload"),
        NULL, CFNotificationSuspensionBehaviorCoalesce);
}

#pragma mark - shared material lifecycle

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    lgRouteMaterialHost((UIView *)self);
}

- (void)layoutSubviews { %orig; lgRouteMaterialHost((UIView *)self); }

- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}

- (void)setFrame:(CGRect)frame   { %orig(frame);  LGResyncGlassGeometry((UIView *)self, kGlassKey); }
- (void)setBounds:(CGRect)bounds { %orig(bounds); LGResyncGlassGeometry((UIView *)self, kGlassKey); }
- (void)setCenter:(CGPoint)center{ %orig(center); LGResyncGlassGeometry((UIView *)self, kGlassKey); }

%end

