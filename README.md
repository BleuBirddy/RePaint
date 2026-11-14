# RePaint: Slicer & Filament Painter

Two tools for 3D printing in one app, for iPhone, iPad and Mac:

- **Slicer.** Open an STL, see it on the print bed, slice it into layers and
  save the G-code.
- **Painter.** Turn a picture into a filament painting: a thin, flat print you
  look at from the top. Thin areas let the darker layers underneath show
  through, so the image appears in the layers.

The Painter hands its result straight to the Slicer ("Open in Slicer"), with
the thin layers and solid fill a painting needs already set.

## Painter

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
so it can save the STL and the G-code.

- Bundle id: `dev.jey.repaint`. Needs iOS 17 or macOS 14.
- `RePaint.xcodeproj` is generated and gitignored. After adding or moving files,
  run `xcodegen generate`.
- The code started as the five-file FilamentPainter project from an earlier chat
  (`~/Downloads/FilamentPainter.zip`). This repo is its first compiled version.

```
RePaint/App/            App entry and the two-tab root view
RePaint/Painter/        Painter screen, state, and its engine (image → height
                        grid, light model, swap-layer search, STL writer)
RePaint/Slicer/         Slicer screen, 3D view, layer preview, G-code file
RePaint/Slicer/Engine/  STL reader, layer cutting, walls and infill, G-code
                        writer, and the small C doorway to Clipper2
RePaint/Vendor/Clipper2 The Clipper2 polygon library (C++), copied in unchanged
RePaintTests/           Painter and slicer engine checks, the squid reference print
```

## Slicer

The slicing engine is RePaint's own Swift code. It started on 2026-11-14 as a
separate project, McSlicer, and was folded in the same day.

- [x] Open binary and ASCII STL files
- [x] Show the model on the print bed in 3D, with its size and a warning if it doesn't fit
- [x] Slice: walls, solid top and bottom, sparse line infill, skirt
- [x] Supports: off, from the bed only, or everywhere, with an overhang angle
- [x] Filament swaps at chosen layers (AMS slot per swap); the Painter fills them in from its print plan
- [x] Layer preview with a slider
- [x] Save the G-code to Files
- [x] Take a painting from the Painter tab
- [ ] Printer start/end G-code that is checked on a real printer
- [ ] Filament swap G-code that is checked on a real printer, with flushing
- [ ] More settings (layer height, walls, infill, temperatures are fixed defaults for now)
- [ ] Get the file to the printer without a card

**Not safe to print yet.** The start-up G-code is a generic heat-and-home
sequence that has never run on a Bambu. Bambu publishes no G-code reference,
and its own start sequence (bed levelling, nozzle wipe) is not in here. The
AMS load and swap commands (`M620`, `T`, `M621`) follow what Bambu owners
describe on Bambu's forum and are untested too; they don't flush the old
colour out, so the first lines after a swap come out mixed.

Supports are the simple kind: straight columns under overhangs, no bridge
detection, no tree supports, no dense top layer. Not done at all: bridges,
brims, seam placement, thin-wall handling.

First target printer: Bambu P1P (256 mm bed) with an AMS 2 Pro.

## What the Painter does

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
| v0.3 | **Filament changes written by RePaint's own slicer** | It removes the hand-placed swaps. The slicer takes the painting and its swaps and writes them into the G-code; what is missing is a start sequence and AMS change commands checked on the printer, with flushing. (This replaces the earlier plan of writing a Bambu Studio 3MF.) |
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
  App Store. On the Mac, the tab bar and the Slicer's 3D view haven't been
  looked at by eye (the iPhone simulator has).

## License

MIT. See [LICENSE](LICENSE).

The slicer uses Clipper2 by Angus Johnson for outline maths, under the Boost
Software License (`RePaint/Vendor/Clipper2/LICENSE.txt`).

RePaint is an independent project. It isn't affiliated with or endorsed by
HueForge or its developer, and HueForge is mentioned only to describe the
kind of tool this is.
