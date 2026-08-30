

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone                   = 0,
    SBSRelaunchActionOptionsRestartRenderServer    = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition     = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition  = 1 << 2,
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

static NSString * const kLGRespringNote = @"dylv.liquidassprefs/Respring";

static void LG_requestRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

    Class actionClass  = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;

    SEL actionSelector =
        NSSelectorFromString(@"actionWithReason:options:targetURL:");
    SEL serviceSelector = NSSelectorFromString(@"sharedService");
    SEL sendSelector = NSSelectorFromString(@"sendActions:withResult:");
    if (![actionClass respondsToSelector:actionSelector] ||
        ![serviceClass respondsToSelector:serviceSelector]) return;

    id restart = ((id (*)(Class, SEL, NSString *, NSUInteger, NSURL *))objc_msgSend)(
        actionClass, actionSelector, @"LiquidAss",
        (SBSRelaunchActionOptionsRestartRenderServer |
         SBSRelaunchActionOptionsFadeToBlackTransition), nil);
    if (!restart) return;
    id service = ((id (*)(Class, SEL))objc_msgSend)(serviceClass,
                                                    serviceSelector);
    if (!service || ![service respondsToSelector:sendSelector]) return;
    ((void (*)(id, SEL, NSSet *, id))objc_msgSend)(
        service, sendSelector, [NSSet setWithObject:restart], nil);
}

static void LG_respringRequested(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ LG_requestRespring(); });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LG_respringRequested, (__bridge CFStringRef)kLGRespringNote,
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
