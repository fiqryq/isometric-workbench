<p align="center">
  <img src="isometric-workbench/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Isometric Workbench icon">
</p>

<h1 align="center">Isometric Workbench</h1>

<p align="center">Animated exploded-view isometric blueprints for macOS.</p>

Isometric Workbench turns simple parts into clean, animated isometric line art: exploded views, section cuts and labelled diagrams. Build parts from primitives and sketches, explode them on a timeline, and export crisp PNG, SVG, PDF, video, GIF or Lottie.

## Features

- **Model**: boxes, cylinders, spheres, cones, tubes, tori, prisms, wedges and stairs, or draw outlines with the shape and pen tools, then extrude or revolve them. Push faces, add loop cuts, scale or taper rings, and union or subtract primitives. Every part keeps an editable step history.
- **Annotate**: hatched section cuts, callouts, dimension lines, and text, SVG or image decals that follow the surface they sit on.
- **Frames**: optional Figma-style frames that hold parts, hug their contents or take a fixed size, fill and clip, and can carry blueprint marks (grid, FIG number, title, year). Without frames the page is an open canvas.
- **Animate**: explode presets, camera spin and a per-property timeline with easing per key. Pages each have their own camera, timing and part animation.
- **Export**: PNG, SVG and PDF; H.264, HEVC and ProRes 4444 video; animated GIF, PNG sequences, Lottie JSON and animated SVG.
- **Style**: Blueprint, Ink, Redline and Cyanotype palettes or your own colours, line weight and hatch spacing.
- **Interface**: Sketch-style window with Pages and Layers on the left, floating tool pills over the canvas, and an inspector with alignment and distribution.

All modelling and animation are free. A one-time **Workbench Pro** purchase removes the export mark and the free limits (1200 px images, 5 s / 720p video).

## Requirements

- macOS 14 or later (Liquid Glass styling on macOS 26+)
- Xcode 26 or later, Swift 6

## Getting started

```sh
git clone git@github.com:fiqryq/isometric-workbench.git
cd isometric-workbench
open isometric-workbench.xcodeproj
```

Run the `isometric-workbench` scheme. The welcome window offers templates, including the animated app logo.

In Debug builds, set the environment variable `WORKBENCH_PRO=1` to unlock Pro without a purchase. The StoreKit configuration in `isometric-workbenchTests/Workbench.storekit` covers purchase testing.

## Tests

```sh
# Geometry, rendering and document engine
cd Packages/IsoKit && swift test

# App tests (the test host launches without windows)
xcodebuild test -project isometric-workbench.xcodeproj -scheme isometric-workbench \
  -destination 'platform=macOS' -only-testing:isometric-workbenchTests CODE_SIGNING_ALLOWED=NO
```

CI runs both on every pull request and on pushes to `main`.

## Project layout

| Path | What's there |
| --- | --- |
| `Packages/IsoKit` | The engine as a Swift package: `IsoMath` (vectors, projection), `IsoGeometry` (ops, evaluator, BSP, SVG import), `IsoRender` (meshes, feature lines), `IsoDocument` (scenes, pages, frames, annotations, animation), `IsoExamples` (template scenes) |
| `isometric-workbench/Document` | `SceneDocument` and the editor model (`SceneModel` and its tools, timeline, pages, frames, layers and alignment) |
| `isometric-workbench/Viewport` | The Core Graphics canvas: drawing, hit-testing, mouse and keyboard |
| `isometric-workbench/Engine` | Frame composition, painting, SVG / Lottie / video export |
| `isometric-workbench/Views` | Window chrome, layers, pages, inspector, timeline, export sheets |
| `isometric-workbench/Home` | Welcome window: recents, folders, trash and templates |
| `isometric-workbench/Store` | StoreKit 2 Workbench Pro unlock |
| `AppStore/` | App Store metadata |
| `design/logo/` | Logo concepts and brand kit |
| `scripts/` | `make-icon.swift` (renders the app icon set), `release.sh` (archive and upload) |

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| V · A · R · O · G · P · L | Select · Frame · Rectangle · Ellipse · Polygon · Pen · Loop rings |
| F | Zoom to fit |
| ⌘-scroll / middle-drag | Zoom / pan |
| Space-drag | Pan |
| Space (tap) | Play or pause |
| E | Explode preset |
| ⌘K | Add keyframe |
| ⌥⌘G | Frame selection |
| ⌥⌘N | New page |
| ⇧⌘T | Show or hide the timeline |
| ⌃⌘S / ⌥⌘I | Show or hide layers / inspector |

## App icon

The icon is drawn in code. After changing the mark in `scripts/make-icon.swift`, regenerate every size:

```sh
swift scripts/make-icon.swift
```

## Releasing

Pushing a `v*` tag archives the app and uploads it to TestFlight (`.github/workflows/release.yml`). To do it locally:

```sh
TEAM_ID=XXXXXXXXXX scripts/release.sh            # archive and upload
TEAM_ID=XXXXXXXXXX scripts/release.sh --export-only   # signed .pkg in build/export
```

Upload uses an App Store Connect API key when `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` are set, and Xcode's signed-in account otherwise.
