# DesignSystem — Paladala Expressive

Design v2 tokens and components for Paladala, implementing the **Paladala Expressive**
design file (colour engine, polygon shapes, springs, type scale, components).
iOS 18+, no dependencies.

> One seed. Every colour. Pick a seed and the engine builds six tonal palettes, then maps
> them to roles for light and dark. Every screen re-themes from that one colour.

## Layout

- `Tokens/`
  - `DSColorEngine` — Foundation-only tonal engine. Tone is CIELAB L\*, chroma is clipped to
    sRGB per tone. `DSScheme(seed:variant:dark:)` produces every role; variants are
    `vibrant` (default), `expressive`, `tonal`, `fidelity`.
  - `DSTheme` — seed + variant → light and dark `DSColors`. Set with `.dsTheme(seed:)`,
    read with `@DSPalette private var c`. `DSTheme.seeds` is the eight Settings swatches.
  - `DSShape` / `DSPolygon` — 18 polygons sampled as the same 120-point outline, so any
    shape morphs into any other with a plain animation.
  - `DSMotion` — spatial (fast / default / slow) and effects springs, `.dsSpatial` /
    `.dsEffects` modifiers (spatial snaps under Reduce Motion, colour still crossfades).
  - `DSFont` / `DSTextRole` — SF Pro Rounded + PingFang TC; `.dsText(.labelL)` etc.
  - `DSLayout` — `DSSpacing` (4 pt grid, 16 pt gutter), `DSRadius` (8 · 12 · 16 · 28 · full),
    `DSSize`.
  - `DSColor` — legacy fixed pink/system colours kept for existing call sites; new code uses
    `@DSPalette`.
- `Components/`
  - Buttons: `.dsPrimary` / `.dsTonal` / `.dsOutlined` / `.dsTextButton` / `.dsIcon(_:)`
    (round → squircle + 0.95 scale on press), `DSButtonGroup` (connected segments),
    `DSChip`, `DSSectionHeader`.
  - Polygon controls: `DSPolygonToggle` (`.like` burst, `.coin` cookie 9, `.favorite`
    clover 4), `.dsSwitch` toggle style, `DSAvatar` (shape picked from the creator id).
  - `DSNavBar` + `DSMainTab` — each tab owns a polygon; the indicator grows from a dot.
  - `DSLoadingIndicator` (7-shape loop, replaces every spinner), `DSWavyProgress`
    (wave travels only while playing; SponsorBlock segments in tertiary).
  - `DSVideoCard` (standard + hero), `DSFeedGrid`, `DSCoverPlaceholder` (art generated
    from the video id), `DSSkeleton`, `.dsGlassBar()`.
- `Support/` — `DSFormat` (播放量 `1.2萬`, durations).

## Rules

- UI copy is Traditional Chinese (繁體中文), never Simplified.
- Semantic roles only (`c.primary`, `c.surfaceContainer`, …); no hardcoded black/white ink.
  The one exception is text over cover art, which uses `c.onScrim` on `c.scrim`.
- Shape carries state: idle is round, active becomes a polygon. Morph, never swap.
- One ambient loop per screen at most. Reduce Motion: shapes hold still, colour still
  crossfades, no loops.
- Only transform, clip shape, opacity and colour animate.
- Continuous corners; no hard borders or offset shadows. Touch targets ≥ 44 pt.
- Components never load images themselves: pass a `cover` view (or `DSCoverPlaceholder`).

## Motion tokens

| Token | ζ | k | ≈ ms | Use |
|---|---|---|---|---|
| `spatialFast` | 0.6 | 800 | 350 | shape morphs, like burst, nav indicator, press |
| `spatialDefault` | 0.8 | 380 | 410 | sheets, cover → player, list reorder |
| `spatialSlow` | 0.8 | 200 | 570 | full-screen transitions, hero morphs |
| `effectsFast` | 1 | 3800 | 140 | press states, icon swaps |
| `effectsDefault` | 1 | 1600 | 210 | colour and opacity crossfades |
| `effectsSlow` | 1 | 800 | 300 | theme re-seed, skeleton → content |

## Previews and tests

Previews live in `Components/DSPreviews.swift` (feed light / dark / re-seeded, hero card,
every control, shape library, AX5).

`DSColorEngineTests` checks the Swift engine and shape outlines against golden values
produced by the design file's reference JavaScript engine.
Run: `xcodebuild test -scheme DesignSystem -destination 'platform=iOS Simulator,name=iPhone 16'`
(also run by the `design-system` workflow).
