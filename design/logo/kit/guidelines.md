# Isometric Workbench — Logo Guidelines

## 1. The logo
- **Idea**: the top of the block lifts off — an exploded view in its simplest form. The moving part is marked in
  Redline, the body in Blueprint blue.
- **Versions**: horizontal lockup (primary) · stacked lockup · symbol · wordmark.
- **Files**
  | Use | File |
  |---|---|
  | Symbol, full colour | `symbol/iw-symbol-color.svg` |
  | Symbol below 32 px | `symbol/iw-symbol-small-color.svg` |
  | Symbol on dark / blue | `symbol/iw-symbol-reversed.svg` (white + Redline) · `symbol/iw-symbol-reversed-white.svg` |
  | One colour | `symbol/iw-symbol-black.svg` · `-white.svg` · `-mono-2d55e8.svg` |
  | Horizontal lockup | `lockups/iw-horizontal-color.svg` · `-reversed.svg` · `-black.svg` · `-white.svg` · `-mono-2d55e8.svg` |
  | Stacked lockup | `lockups/iw-stacked-color.svg` · `lockups/iw-stacked-reversed.svg` |
  | Wordmark only | `lockups/iw-wordmark.svg` |
  | Web icons | `web/` (favicon.ico, favicon.svg, PNG set, `site.webmanifest`, `head-snippet.html`) |
  | macOS app icon | `isometric-workbench/Assets.xcassets/AppIcon.appiconset` (from `scripts/make-icon.swift`) |

## 2. Clear space
Keep a clear zone of **1 × L** on every side, where **L** is the height of the red top face. It scales with the logo.

## 3. Minimum size
| Version | Screen | Print |
|---|---|---|
| Horizontal lockup | 140 px wide | 35 mm wide |
| Stacked lockup | 64 px wide | 18 mm wide |
| Symbol | 32 px (master) · 16 px (small cut) | 6 mm |

## 4. Colour
| Name | HEX | RGB | CMYK (approx.) | Pantone (approx.) | Use |
|---|---|---|---|---|---|
| Blueprint | #2D55E8 | 45 85 232 | 81 63 0 9 | 2728 C | The block; one-colour logo |
| Redline | #E04A2F | 224 74 47 | 0 67 79 12 | 7417 C | The lifted top only |
| Ink | #1A1A1A | 26 26 26 | 0 0 0 90 | Neutral Black C | Wordmark, text |
| Paper | #FBFBFA | 251 251 250 | 0 0 0 2 | — | App icon tile, backgrounds |

Pantone and CMYK values are approximations; proof against a physical guide before print.

**Approved logo/background pairs**: full colour on white or Paper · reversed (white + Redline) on Ink · all-white on
Blueprint · black or Ink on white. Don't put the full-colour version on Blueprint or other mid-to-dark colours — use the
reversed files there.

## 5. Typography
- Wordmark: **IBM Plex Sans SemiBold**, tracking −8/1000, converted to outlines (SIL Open Font Licence).
- App UI keeps the system font (SF Pro).

## 6. Don'ts
Don't close the gap between the top and the block · don't swap the two colours or colour the block red · don't stretch,
rotate or redraw the mark off the 30° grid · don't add outlines, shadows, gradients or effects · don't rearrange or
resize the parts of a lockup · don't retype the wordmark — use the files.

## 7. Source
- `design/logo/build_kit.py` generates every SVG
  (`uv run --with fonttools --with uharfbuzz python design/logo/build_kit.py <Plex-SemiBold.ttf>`).
- `scripts/make-icon.swift` draws the macOS app icon from the same geometry: block gap 0.36 and seam 0.04, opened to
  0.50 and 0.08 at 16 and 32 px. Keep the two in sync.
- Trademark clearance has not been checked; run a search before public launch.
