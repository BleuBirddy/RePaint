# RePaint

RePaint turns a picture into a filament painting: a thin, flat print you look at
from the top. Thin areas let the darker layers underneath show through, so the
image appears in the layers.

You choose a few filaments, from darkest to lightest. Each one has a color and a
**TD** (transmission distance), which is how thick that filament can get before
it stops letting light through. RePaint maps the image's brightness to a height
for every pixel and works out the layer where each filament starts. It exports:

- a binary **STL** heightmap (a closed solid, so slicers accept it without repair)
- a **print plan**, for example "Brass Silk: from layer 11 (Z 0.88 mm)"

RePaint is an original tool in the same genre as HueForge. It doesn't reuse
HueForge's UI, assets, or names. "TD" is the one exception, because it's the
community's standard term: makers such as Prusa and Polymaker publish TD values,
and testers like the BIQU AJAX TD1S measure it.

## Platform

A SwiftUI app for **iPhone, iPad and Mac** in a single xcodegen target, set up
like ReWatch. The Mac build is sandboxed, with user-selected Read/Write access
so it can save the STL.

- Bundle id: `dev.jey.repaint`. Needs iOS 17 or macOS 14.
- `RePaint.xcodeproj` is generated and gitignored. After adding or moving files,
  run `xcodegen generate`.
- The code started as the five-file FilamentPainter project from an earlier chat
  (`~/Downloads/FilamentPainter.zip`). This repo is its first compiled version.

```
RePaint/App/       SwiftUI app, ContentView, PainterModel (state, saving, print plan)
RePaint/Engine/    Image → height grid, light model, swap-layer search, STL writer
RePaintTests/      Engine checks and the squid reference print
```

## What v0.1 does (all in the code now)

1. Opens on a sample moon image, so there's a working preview right away.
2. Imports from Photos or Files and crops each edge.
3. Keeps a filament library (name, color, TD) that persists between launches.
   It starts with Jey's spools: Black, Brass Silk (TD 3.0), White Rock Marble
   (TD 2.0).
4. Picks swap layers automatically (it tries every combination and keeps the one
   whose simulated colors are closest to the image), or lets you set them by hand.
5. Shows a live print preview next to the original.
6. Exports the STL to Files/iCloud and shares the print plan as text.

### Reference print: the squid

Jey made a squid panel by hand: 83 × 160 mm, 2.4 mm thick, 0.08 mm layers (first
layer too), 100% infill. Black for layers 1–10, Brass Silk from layer 11
(Z 0.88), White Rock Marble from layer 18 (Z 1.44). `SquidPlanTests` checks that
RePaint's print plan gives exactly those numbers, and the app's defaults are
those settings.

The test sets the swaps by hand. Nobody has checked yet whether **automatic**
picking lands on layers 11 and 18 for the squid image, because that needs the
image itself.

## Next, in this order

| Version | Feature | Why this order |
|---|---|---|
| v0.2 | **Print plan in AMS-slot terms** ("layer 11 → slot 2") | Cheap, and it matches how Jey actually prints (Bambu + AMS, "Change filament" on the layer slider). |
| v0.3 | **3MF with the filament changes already in it** | It removes the hand-placed swaps. Bambu Studio's 3MF format needs checking against real files and docs before anyone writes code for it. |
| v0.4 | **3D preview** you can orbit | Nice to have. The 2D preview already answers "do the colors work?" |
| later | **Suggest which filaments** to use from the library | A real optimization problem, and easy to sink weeks into. It only makes sense once the light model has been checked against real prints. |

Scope test for anything new: does it help you get one good print from one image?

## Things to know

- **Light model.** Each layer lets through `exp(-3 · layer height / TD)` of the
  light below it, so a stack one TD thick blocks about 95%. This is RePaint's own
  estimate and needs tuning against a printed test strip. TD varies between
  spools.
- **Photos you don't own:** fine for personal prints, not for selling on Etsy.
- **Not checked yet:** whether another app called "RePaint" is already on the
  App Store, and the Mac UI by eye (only the iPhone simulator has been looked at).
