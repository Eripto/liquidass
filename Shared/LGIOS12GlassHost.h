#import <UIKit/UIKit.h>

// ===========================================================================
// SHARED iOS 12 GLASS SURFACE REGISTRY
//
// One attachment implementation for every LiquidAss surface, so converting a
// new element is a registration rather than another copy of the same host
// logic. Each caller supplies only what is specific to it: how to recognise
// its own material and what corner radius that material should have.
//
// Everything else is common and lives here once: creating the reusable
// LGIOS12MetalGlassView, refusing to attach when Metal is unavailable,
// inserting at the correct z-order, suppressing the stock material without
// destroying it, resyncing geometry on layout, and tearing down cleanly.
//
// PERFORMANCE: every attached surface is a client of the ONE shared
// LGIOS12LiveBackdropProvider. N visible surfaces cost one capture and N Metal
// draws from the same latest backdrop texture -- never N captures.
//
// SELF-CAPTURE: each glass view registers itself for capture exclusion on
// attach and unregisters on detach. Note also that the provider composes its
// backdrop from wallpaper plus Home Screen icons only -- it never renders the
// whole host window -- so Control Center's own content cannot enter the
// backdrop even before exclusion is considered.
// ===========================================================================

// Return a corner radius for a material this surface owns, or a negative value
// if the material is not one of ours. Called from layout, so keep it cheap.
typedef CGFloat (^LGIOS12GlassRadiusProvider)(UIView *material);

// Register a surface. Registrations are consulted in order; the first
// non-negative radius wins, so a more specific surface should register first.
// `name` appears in logs and nowhere else.
void LGIOS12RegisterGlassSurface(NSString *name,
                                 LGIOS12GlassRadiusProvider radiusProvider);

// YES only on iOS 12 inside SpringBoard. Callers use this to decide whether to
// hand their material to this path or leave it on the existing
// LGLiveBackdropView implementation.
BOOL LGIOS12GlassSurfacesAvailable(void);
