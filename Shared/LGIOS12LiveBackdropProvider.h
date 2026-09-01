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
- (void)setNeedsActiveRefresh:(BOOL)active;

- (void)registerGlassViewForExclusion:(UIView *)glassView;
- (void)unregisterGlassViewForExclusion:(UIView *)glassView;

@end
