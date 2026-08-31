# iOS 12 renderer architecture and `liquidass-next` findings

This document records the renderer audit performed against
`winaviation-tweaks/liquidass-next` commit
`ddf101acce286e14be54f67798a31d829793bbfb`. The implementation files—not only
the README—were reviewed: `Tweak.mm`, `LGSymbolResolver.h`,
`LGSymbolResolver.mm`, `LiquidGlassSB/Tweak.x`, the Makefiles, package filters,
and all history-visible renderer revisions.

It also records why the native render-server backend is not being enabled on
iOS 12 without an independently verified iOS 12 QuartzCore image.

## How the `liquidass-next` live backend works

The prototype is split between backboardd and SpringBoard.

### Render-server registration

The backboardd dylib interns `dylv.liquidglass.refraction` and calls the private
`CA::Render::add_filter(atom, context)` function. The context is a 256-byte
anonymous mapping whose first word points to a cloned FilterSubclass vtable.
The clone starts from the registered Gaussian blur implementation, copies 22
slots, then replaces:

- slot 0 with `ourIdentityStub`, which returns false so CoreAnimation evaluates
  the filter instead of treating it as an identity operation;
- the dynamically resolved render slot with `ourCustomRender13`.

The original Gaussian render entry is retained in `g_origGaussR13`. After the
custom Metal pass, the implementation temporarily redirects the input
surface's texture to its output texture, calls the real Gaussian renderer with
zero blur scale, and restores the original texture. Calling the original
renderer is essential: CoreAnimation still owns destination selection,
compositor routing, intermediate surfaces, and surface lifetime. Replacing it
entirely produces pixels but does not reliably put those pixels into the
compositor's output.

### Dynamic QuartzCore discovery

`LGSymbolResolver.mm` first discovers QuartzCore's loaded image, slide, text,
and C-string ranges. It uses several independent strategies:

- `dlsym` for an exported symbol when one remains available;
- ARM64 AOB/prologue scans when a private symbol is stripped;
- `ADRP+ADD` and `ADRP+LDR` decoding to turn PC-relative instructions into
  runtime data addresses;
- branch-target decoding for stripped callees;
- string-xref scans followed by backward function-start searches;
- forward data/code following for local static objects that have no symbol.

The central Gaussian-site scan looks for a cluster of at least four calls that
share one `BL` target and have the shape `ADRP+ADD context`, `MOVZ W0, atom`,
then `BL add_filter`. It identifies Gaussian using the runtime atom returned by
`CAInternAtomWithCString("gaussianBlur")`, not a fixed atom number. From that
one confirmed cluster it obtains:

- the common `add_filter` call target;
- the address of the Gaussian context static;
- the filter-table static, found by walking backward for the nearby
  `ADRP+LDR` load.

`CA::OGL::MetalContext::stop_encoders` is found through the
`!memoryless_in_use ()` string reference. The command-buffer field offset is
derived from the function referencing `Command buffer allocation failed!`:
the resolver follows register copies of `this` and decodes the large
`LDR/STR [this,#offset]` access. The known results differ—0xaa8 on iOS 15.8.8
and 0xb38 on iOS 16—so this is not a constant.

The render slot is also resolved rather than hardcoded. The resolver searches
the Gaussian vtable for the base BlurFilter forwarder. It recognizes both the
plain `LDR/LDR/BR` form and a PAC-hardened `LDR/LDR/BLRAA` form, then validates
the `K -> K+1` virtual dispatch relationship. The prototype observed render
slot 12 on iOS 15.8.8/16.2 and slot 13 on iOS 16.7. That shift is direct
evidence that an iOS 12 slot cannot be guessed.

### Compositor texture and shader inputs

In the supported builds the callback reads the compositor surface's source
`MTLTexture` at a verified offset of 0x58 and obtains the active command buffer
from the resolved MetalContext field. Public `MTLTexture` properties provide
device, dimensions, and pixel format once the object pointer is known.

The callback allocates/reuses an output texture, encodes the custom Metal work
onto the compositor's command buffer, and then lets Gaussian route that output.
The shader input structure carries the information needed for screen-space
sampling and a physical-looking edge:

- output and screen resolution;
- card origin and wallpaper origin;
- wallpaper/source resolution;
- X/Y sampling transforms, affine offset, and orientation;
- corner radius and optional shape mask;
- bezel width, glass thickness, refraction scale, and refractive index;
- body/blur mixing;
- specular opacity and angle.

This is why a translucent color or an ordinary blur view is not equivalent to
the native engine: neither has compositor surface coordinates nor an edge
refraction pass.

### Registration timing and the SpringBoard race

Registration must happen after CoreAnimation has initialized its filter table.
`add_filter` creates the table when it is null, while CoreAnimation's own
Filter constructor lazily installs the built-ins only when that table is null.
Calling `add_filter` first can therefore create an orphan table containing only
the custom entry and prevent system blur filters from being registered.

`registerCustomFilter` resolves the filter-table slot and retries every 250 ms
until the slot's value is non-null. Registration is idempotent after success.

SpringBoard has a second race. A `CABackdropLayer` may decode an unknown filter
before backboardd has registered its type and retain a nil/old state. The
companion creates the filter through runtime `CAFilter` lookup, assigns it to
the backdrop layer, and recommits a fresh filter at 1.5, 3, 5, 8, and 12
seconds. Those retries are not a substitute for backboardd registration; they
only repair a client layer that lost the startup race.

The companion also uses post-iOS-12 APIs (`cornerCurve`, `UIScene`,
`UIWindowScene`, and `connectedScenes`), so it cannot be copied unchanged to
iOS 12 even if the render-server internals are solved.

## What is independently known for iOS 12

No iOS 12 QuartzCore image or dyld shared cache is present in this workspace,
and no connected device/debug transport is available. Therefore these values
remain deliberately unverified for iOS 12:

| Private item | iOS 12 status | Required verification |
| --- | --- | --- |
| `CA::Render::add_filter` | unresolved | confirm call cluster and decoded target in the iOS 12 QuartzCore text |
| filter-table slot/layout | unresolved | confirm the local static and table initialization semantics |
| Gaussian context | unresolved | confirm context static and descriptor/vtable layout |
| render vtable slot | unresolved | recover and validate the iOS 12 base forwarder |
| MetalContext command buffer | unresolved | decode the iOS 12 start-command-buffer function and field access |
| compositor surface texture | unresolved | establish the iOS 12 surface type and texture representation; do not assume 0x58 |

Consequently, none of the iOS 15/16 offsets, signatures, vtable indices, or
structure layouts is used by the iOS 12 path. A registration retry cannot fix
the current zero-glass state because the old code stopped before attempting
registration at all.

## Exact blocker in the iOS 12 port

`LiquidAssBackboardd/Tweak.mm` exits its constructor for every OS below iOS 13.
That means on iOS 12:

1. the filter table is not resolved;
2. `add_filter` is not resolved or called;
3. no custom filter context/vtable exists;
4. no custom render callback can execute;
5. no compositor `MTLTexture` can be acquired by that backend.

Separately, `Shared/LGLiveBackdropView.m` uses an iOS 12
`UIVisualEffectView`/tint implementation and a plain `CALayer`; it never creates
the private filter. Calling that path "ready" only means its public fallback
views were attached. It does not prove refraction.

The registration race from `liquidass-next` is real on supported systems, but
it is not this failure: iOS 12 currently fails one layer earlier because
registration is intentionally never attempted.

## Backend decision

### Option A: native live CAFilter

This remains technically possible in principle on a non-PAC arm64 iOS 12
device, but only after analysis against that OS's QuartzCore binary proves all
items in the table above. Its advantage is a truly live compositor source and
correct system-managed output routing. Its risk is unusually high: one wrong
function signature, context layout, vtable entry, or surface field can crash
backboardd or corrupt all system filters.

The project must not activate Option A merely because a pattern happens to
match. A future resolver should require unique matches, structural validation,
address-range validation, Gaussian atom confirmation, and a fail-closed path.

### Option B: legacy snapshot/wallpaper Metal renderer

The pre-0.1.0b repository contains an independent `MTKView` renderer. It loads
rootful SpringBoard cpbitmaps, can capture the window hierarchy, uploads the
actual backdrop, performs screen-coordinate sampling, blur/body mixing,
refraction, bezel shaping, and specular work, and presents through public Metal
APIs available on iOS 12. It does not depend on QuartzCore structure offsets.

Option B is therefore the safer first iOS 12 backend. Its source is a snapshot
rather than a compositor-live surface, so refresh policy is its principal
limitation. It is nevertheless real backdrop sampling and shader distortion,
not a transparency-only fallback.

## Current isolated test stage

`Shared/LGIOS12StandaloneTestView.m` implements one draggable SpringBoard test
surface. It:

1. decodes `HomeBackground.cpbitmap` when possible;
2. captures the visible SpringBoard window hierarchy before creating the test
   surface;
3. uploads the full-screen image with `MTKTextureLoader`;
4. compiles an iOS 12 Metal compute/present pipeline at runtime;
5. samples by the test view's screen-space origin;
6. applies rounded-bezel refraction, multi-tap blur/body mixing, tint, Fresnel,
   and directional specular highlighting;
7. inserts only the test view and never clears/hides a stock view.

All existing UI hook groups are left uninitialized on iOS 12 while this test is
unproven. Newer OS behavior remains initialized as before.

The diagnostic log records these exact stages:

- `QuartzCore loaded`
- `filter_table resolved`
- `add_filter resolved`
- `gaussian context resolved`
- `render vtable slot resolved`
- `MetalContext resolved`
- `custom CAFilter registered`
- `SpringBoard created custom filter`
- `custom CAFilter render callback executed`
- `MTLTexture acquired`
- `custom render callback executed backend=legacy`
- `Metal compute dispatch executed`

For the legacy test, the private stages explicitly report `NOT_ATTEMPTED` or
`NO`; they are never presented as successes. The backend is not considered
device-proven until the legacy draw callback, valid texture dimensions, and a
completed Metal command buffer appear in the device log and the refracted
surface is visually confirmed.
