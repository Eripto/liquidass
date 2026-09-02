#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import "LGIOS12LiveBackdropProvider.h"

// ===========================================================================
// GENERIC iOS 12 METAL LIQUID GLASS VIEW
//
// The renderer that was verified on device, with the standalone test surface's
// concerns removed. It owns the MTKView, the compute and present pipelines and
// the provider client lifecycle, and nothing else: no pan gesture, no caption,
// no overlay window, no drag display link. Those belong to the standalone test
// card, which now subclasses this.
//
// It is a plain UIView, so it can be embedded anywhere in the SpringBoard
// hierarchy -- including inside the Dock's own material -- rather than
// requiring an overlay window of its own.
//
// Every instance is a client of the ONE shared LGIOS12LiveBackdropProvider.
// Additional instances therefore cost only their own Metal draws from the
// latest shared backdrop texture; they never start a second capture loop.
//
// SELF-CAPTURE: instances register themselves for capture exclusion on attach
// and unregister on detach. The standalone card also lives in an excluded
// overlay window, but a view embedded in the SpringBoard hierarchy (the Dock)
// depends on this registration alone to avoid recursive feedback.
// ===========================================================================
@interface LGIOS12MetalGlassView : UIView <MTKViewDelegate, LGIOS12LiveBackdropClient>

// NO if Metal, the shader library or a pipeline failed to initialize. Callers
// embedding this in real UI must check it and fall back to the stock material.
@property (nonatomic, readonly) BOOL metalInitialized;

// YES once a backdrop texture has arrived and the view can actually draw.
@property (nonatomic, readonly) BOOL rendererReady;

// Drives both the view's own corner rounding and the shader's radius uniform,
// so the Fresnel edge follows the host's shape. Defaults to 28 (the verified
// standalone value).
@property (nonatomic, assign) CGFloat glassCornerRadius;

- (void)updateContinuousRefreshState;
- (void)redraw;

// Subclass hook, called when the view becomes detached/hidden/transparent.
- (void)glassDidBecomeInvisible;

@end
