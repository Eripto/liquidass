# Inactivity in the current project
So you may have noticed that there's not much activity in the repo right now, but of course it's still being developed by me locally. The next update will be a big rewrite and completely changes how the tweak works fundementally. Update is mostly done, ETA is August 10, 2026 (aka my birthday).

Additionally, my next school year is gonna be the toughest of my life, so updates will be less frequent. I also have different projects at the moment, so I hope you will understand.

Pull requests will still be reviewed and merged, and I encourage people contributing in the tweak, it will help a lot.

---

# Liquid (Gl)ass
This tweak is incomplete, issues WILL happen.

Nightly builds that contains the bleeding edge changes are available [here](https://github.com/winaviation-tweaks/liquidass/releases/tag/nightly)

## Applied to
- folders on the homescreen
- opened folders
- widgets
- underneath app icons
- dock
- lockscreen platter views (notifications & music player)
- quick actions buttons
- app library
- settings app
- clock
- or any view with the custom views feature introduced in 0.0.9a

## Quick explanation on how this tweak works
- the tweak injects a `LiquidGlassView` into specific/custom springboard surfaces, then feeds that view a backdrop source plus screenspace origin data
- most surfaces are still snapshot / wallpaper based:
  - homescreen, dock, folders, widgets, context menus, App Library, lockscreen platters, etc usually sample from cached wallpaper or cached composite snapshots
  - on iOS 15 and lower it can still decode cpbitmap wallpapers directly
- once a source image is captured, the tweak usually does not rebuild it every frame. the common path is:
  - cache the source image
  - upload it to Metal
  - keep the glass aligned by updating origin / sampling coordinates on display link ticks
  - except for the notification banners which uses a springboard-local live backdrop capture path
- the code splits to these folders:
  - `Runtime/` owns the Metal renderer
  - `Shared/` owns prefs / logging / hook helpers
  - `Hooks/` owns the per-surface injection logic

## The Metal shader
- the renderer uploads the source image as a Metal texture, bakes a blurred variant, then draws the glass in a custom fragment shader
- the normal rounded glass path uses the card bounds / corner radius to estimate edge distance, then uses that edge band to drive:
  - Snell's [law of refraction](https://en.wikipedia.org/wiki/Snell%27s_law)
  - blur/body mix
  - specular highlight / fresnel-ish lift
- there is also a shape mask path used for the lockscreen clock. the shader receives a second texture mask and derives edge behavior from the glyph shape instead of only from a rounded rect
- the blur is separable and baked in two compute passes, then reused until settings or source content actually require a rebake

## donation
i only accept crypto for now, wallet addreses:
```
BTC: bc1qlv830emqsffqslns2e3kglkgcdnlag0nfnyj4k
ETH: 0x6245EF47c749D1b5c2830b145cB943a8aD826bea 
LTC: ltc1q7j6vlgvymxdtwm46u0n22h7m4890cexfp22vfm 
DOGE: D76nuR1HWSymSLhFYYhkfpc4JHg1HjvgWD 
SOL: F1rH3PSMHFHXbGLGQiWXGLRaahfYoVULUwhsvrewM37W
TRX: TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX 
USDC (Polygon): 0x6245EF47c749D1b5c2830b145cB943a8aD826bea 
USDT (Tron/trc-20): TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX 
```
contact me if you dont see your desired cryptocurrency

### contributions to this tweak are welcomed
