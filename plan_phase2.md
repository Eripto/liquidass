## Phase 2 Integration Plan: `LGLiveBackdropView` using `LGIOS12LiveBackdropProvider`

**Objective:**
Modify `LGLiveBackdropView` so that on iOS 12 it utilizes the shared Metal backend (via `LGIOS12LiveBackdropProvider` and a `MTKView`) instead of the default `UIVisualEffectView` fallback, while maintaining `UIVisualEffectView` as a strict failure fallback.

### 1. Which methods need modification in `LGLiveBackdropView`

*   `@interface LGLiveBackdropView () <LGIOS12LiveBackdropClient, MTKViewDelegate>`: Adopt the protocols.
*   `-initWithFrame:groupName:filterType:`:
    *   Initialize Metal stack (`_device`, `_commandQueue`, `_computePipeline`, `_presentPipeline`, `_metalView`) if `LGIsIOS12()` is true.
    *   Register as a client with `[LGIOS12LiveBackdropProvider sharedProvider]` and register for exclusion to prevent self-capture.
    *   Retain the `UIVisualEffectView` setup, but keep it hidden/inactive unless Metal initialization fails or is disabled.
*   `-dealloc`:
    *   Unregister from `LGIOS12LiveBackdropProvider`.
*   `-lgRendererReady`:
    *   Update logic: if Metal is active, it's ready when `_backdropTexture != nil` AND Metal stack is fully initialized. If falling back to `UIVisualEffectView`, use the existing backdrop check.
*   `-applyFilters`:
    *   On iOS 12, if Metal is enabled/ready, apply settings (blur, tint, specular) to local ivars/properties that will feed into the Metal `Uniforms` struct instead of (or in addition to) trying to set them on `UIVisualEffectView`.
    *   Trigger `[_metalView setNeedsDisplay]` (or `draw`).
*   `-layoutSubviews`:
    *   Ensure `_metalView` matches `self.bounds`. Update uniform scale factors if size changes.
*   `didMoveToWindow` / `setHidden:` / `setAlpha:` (or observing visibility):
    *   Inform `LGIOS12LiveBackdropProvider` to `setNeedsActiveRefresh:YES` if the view is animating or interacting (might need to tie this to pan gestures on the host surface, or rely on the provider's display link).

### 2. How Metal initialization should be gated

*   Inside `-initWithFrame:groupName:filterType:`, wrap Metal initialization in `if (LGIsIOS12())`.
*   Attempt to create `MTLCreateSystemDefaultDevice()`, compile the shader string (`kLGIOS12MetalSource`), and create pipelines.
*   If *any* step fails (device nil, compile error, pipeline error), set a flag `_metalInitializationFailed = YES` and fall back entirely to the existing `UIVisualEffectView` path.

### 3. How the shared backdrop texture will be consumed

*   Implement the `LGIOS12LiveBackdropClient` protocol methods:
    *   `-providerDidUpdateBackdropTexture:source:`: Store the received `id<MTLTexture>` in `_backdropTexture`. Set `_metalRendererReady = YES`. Call `[_metalView draw]`.
    *   `-providerDidFailToUpdateBackdrop:`: Log error, potentially fallback if persistent.

### 4. How screen-space coordinates will be passed

*   In `-drawInMTKView:`, calculate the screen-space origin:
    ```objc
    CGRect screenRect = [self convertRect:self.bounds toView:nil];
    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;
    float cardOriginX = (float)(CGRectGetMinX(screenRect) * screenScale);
    float cardOriginY = (float)(CGRectGetMinY(screenRect) * screenScale);
    ```
*   Pass these values into the `LGIOS12TestUniforms.cardOrigin` field.

### 5. How existing blur/refraction/tint/specular settings map to the iOS 12 shader

*   **Blur**: Use `LGNativeBlurRadiusForFilterType(_lgFilterType)` mapped to `uniforms.blurRadius`.
*   **Tint**: Use `LGLegacyTintColorForFilterType(_lgFilterType)`. Extract RGBA using `LGColorRGBA` and pass to the shader (need to add a `tintColor` float4 to the iOS 12 shader uniforms, similar to the backboardd shader).
*   **Specular**: Use `LGSpecularEnabledForFilterType(_lgFilterType)` to enable/disable the `_specular` CAGradientLayers, OR integrate specular math into the shader (the iOS 12 shader already has `specularOpacity` and `specularAngle` uniforms).
*   **Corner Radius / Bezel / Thickness / Refraction Scale**: Extract these from the preference keys for `_lgFilterType` (similar to how `Tweak.mm` reads them) and pass to uniforms. E.g., `LGHostDefinitionForFilterType` or `LGGlassPreferenceValue`.

### 6. Exact fallback behavior if Metal/provider initialization fails

*   If `_device == nil` or shader compilation fails during init:
    *   Do NOT add `_metalView`.
    *   Allow the existing `UIVisualEffectView` setup code to run.
    *   `lgRendererReady` falls back to the old check (`LGFindVisualEffectBackdropView`).
*   If `_backdropTexture` fails to update:
    *   `_metalView` draws nothing (or transparent).
    *   `lgRendererReady` returns `NO`, preventing the stock UI from being hidden.

### 7. Guarantee stock UI is not hidden unless replacement is confirmed working

*   `LGUpdateMaterialReplacement` relies on `glass.lgRendererReady`.
*   `lgRendererReady` must return `NO` until `_backdropTexture` is successfully received from the provider AND pipelines are valid.
*   Therefore, the stock UI (`material.hidden = YES`) will NOT be triggered until the first successful Metal frame is ready to present.

### 8. Lifecycle/retain-cycle/threading risks

*   **Retain Cycles**: The provider holds a weak reference to clients (`NSHashTable weakObjectsHashTable`). The view holds the provider as a singleton. No retain cycle.
*   **Threading**: `LGIOS12LiveBackdropProvider` guarantees its callbacks (`providerDidUpdateBackdropTexture:`) are fired on the main thread. Metal encoding in `drawInMTKView:` is inherently safe on the main thread.
*   **Lifecycle**: `dealloc` must unregister the client and exclusion view. `MTKView` delegate must not strongly retain `self`.
