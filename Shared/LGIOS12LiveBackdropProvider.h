#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

@protocol LGIOS12LiveBackdropClient <NSObject>
- (void)providerDidUpdateBackdropTexture:(id<MTLTexture>)texture source:(NSString *)source;
- (void)providerDidFailToUpdateBackdrop:(NSError *)error;
@end

@interface LGIOS12LiveBackdropProvider : NSObject

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLTexture> currentBackdropTexture;
@property (nonatomic, readonly) NSString *currentSourceDescription;

+ (instancetype)sharedProvider;

- (void)registerClient:(id<LGIOS12LiveBackdropClient>)client;
- (void)unregisterClient:(id<LGIOS12LiveBackdropClient>)client;

- (void)requestRefresh;
- (void)setClient:(id<LGIOS12LiveBackdropClient>)client
    requestsContinuousRefresh:(BOOL)active;

- (void)registerGlassViewForExclusion:(UIView *)glassView;
- (void)unregisterGlassViewForExclusion:(UIView *)glassView;

@end

// Diagnostic mode selection -- see the block comment in
// LGIOS12LiveBackdropProvider.m for the full mode table and the plist path.
// 0=NORMAL 1=RAW_BACKDROP 2=WALLPAPER_ONLY 3=FOREGROUND_ONLY
// 4=COMPOSITE_RAW 5=FREEZE_PROVIDER 6=PROVIDER_OFF
extern NSInteger LGIOS12CurrentDiagMode(void);
// YES for modes 1-4: bypass the Liquid Glass shader and show the raw source
// crop, so spatial/orientation errors can be seen before any glass math.
extern BOOL LGIOS12DiagRawDisplay(void);
